#include "priv.h"

/* -----------------------------------------------------------
 * Helper: emit a single instruction
 * ----------------------------------------------------------- */

/* -----------------------------------------------------------
 * Compile-time stack-height model
 * -----------------------------------------------------------
 * AGENTS.md invariant #1 requires every emitter path to leave the VM stack
 * at a predictable height. It was documented but never checked, which is why
 * an imbalance surfaced as a silent read of a stale stack slot rather than a
 * compile error. Every emitted instruction updates a model of the height and
 * emit_expr / emit_stmt assert the effect their node must have.
 *
 * The model is linear, so branchy constructs (`if`, `match`, `&&`, `||`,
 * loops) resynchronise it explicitly where their paths rejoin.
 * ----------------------------------------------------------- */

/* Net effect of one instruction on the VM stack height. Checked against the
 * real semantics in vm.c: SET_LOCAL/SET_GLOBAL pop, NEW_ARRAY pops N and
 * pushes one, NEW_STRUCT pops N, GET_FIELD pops one and pushes one, CALL pops
 * the callee and its arguments and pushes the result. */
static int opcode_stack_effect(OpCode op, uint32_t operand) {
    switch (op) {
    case OPCODE_CONST:
    case OPCODE_DUP:
    case OPCODE_GET_LOCAL:
    case OPCODE_GET_GLOBAL:
        return 1;

    case OPCODE_POP:
        return -(int)(operand ? operand : 1);

    case OPCODE_SET_LOCAL:
    case OPCODE_SET_GLOBAL:
    case OPCODE_JUMP_IF_FALSE:
    case OPCODE_JUMP_IF_TRUE:
    case OPCODE_INDEX:
    case OPCODE_PRINT:
    case OPCODE_ADD:
    case OPCODE_SUB:
    case OPCODE_MUL:
    case OPCODE_DIV:
    case OPCODE_MOD:
    case OPCODE_EQ:
    case OPCODE_NEQ:
    case OPCODE_LT:
    case OPCODE_GT:
    case OPCODE_LE:
    case OPCODE_GE:
    case OPCODE_AND:
    case OPCODE_OR:
    case OPCODE_RET:
        return -1;

    case OPCODE_NEW_ARRAY:
        return 1 - (int)operand;

    case OPCODE_NEW_STRUCT:
    case OPCODE_CALL:
        return -(int)operand;

    case OPCODE_SWAP:
    case OPCODE_NEG:
    case OPCODE_NOT:
    case OPCODE_LEN:
    case OPCODE_GET_FIELD:
    case OPCODE_JUMP:
    case OPCODE_HALT:
        return 0;

    /* SET_FIELD pops value + object and pushes the value back; SET_INDEX
     * additionally pops the index. In both the aggregate handle is consumed
     * by the store, which is exactly why the NODE_ASSIGN path below needs no
     * resynchronisation. */
    case OPCODE_SET_FIELD:
        return -1;
    case OPCODE_SET_INDEX:
        return -2;

    /* GET_ENUM_FIELD pops an enum data value and pushes one field; net +0. */
    case OPCODE_GET_ENUM_FIELD:
    case OPCODE_TRY_UNWRAP:
    case OPCODE_WRAP_OK:
    case OPCODE_WRAP_ERR:
    case OPCODE_WRAP_SOME:
        return 0;

    /* The layout constant sits under the N payload values; the VM consumes
     * layout + fields and pushes the finished enum handle. Emission sets the
     * packed operand afterwards, which is why the extra sp_advance lives at
     * the construction site. */
    case OPCODE_NEW_ENUM:
        return 1;
    }
    return 0;
}

static void sp_advance(Emitter *e, int32_t delta) {
    e->sp += delta;
    if (e->sp > e->sp_high) e->sp_high = e->sp;
}

/* Emit a store into the last link of an lvalue chain. `place` is the final
 * `.field` / `[index]` link with its `object` stripped: the caller already
 * emitted the read of the aggregate the chain walks to. Both store forms
 * consume the handle and push the stored value back, so the node's net effect
 * stays "one value" and no stack-model resync is needed. */
static void emit_expr(Emitter *e, Node *node);
static void emit_inst(Emitter *e, OpCode op, uint32_t line);
static void emit_inst_index(Emitter *e, OpCode op, uint32_t index, uint32_t line);
static uint32_t add_constant(Emitter *e, Value value);

static void emit_assign_into(Emitter *e, Node *place, Node *value, uint32_t line) {
    if (place->kind == NODE_INDEX) {
        emit_expr(e, place->as.index.index);
        emit_expr(e, value);
        emit_inst(e, OPCODE_SET_INDEX, line);
    } else if (place->kind == NODE_FIELD_ACCESS) {
        uint32_t idx = add_constant(e, value_string(place->as.field_access.field.str));
        emit_expr(e, value);
        emit_inst_index(e, OPCODE_SET_FIELD, idx, line);
    } else {
        fprintf(stderr, "error: invalid assignment target\n");
        e->error_count++;
        return;
    }
}

static void emit_inst(Emitter *e, OpCode op, uint32_t line) {
    if (e->code_len >= EMITTER_MAX_CODE) {
        return;
    }
    if (e->code_len >= e->code_cap) {
        size_t new_cap = e->code_cap == 0 ? 256 : e->code_cap * 2;
        Instruction *new_code = arena_alloc(e->arena,
            sizeof(Instruction) * new_cap, _Alignof(Instruction));
        if (new_code && e->code) {
            memcpy(new_code, e->code, sizeof(Instruction) * e->code_len);
        }
        e->code = new_code;
        e->code_cap = new_cap;
    }
    Instruction inst = {0};
    inst.op  = op;
    inst.line = line;
    e->code[e->code_len++] = inst;
    sp_advance(e, opcode_stack_effect(op, 0));
}

/* Some operands are counts of values, so patching one changes the stack
 * effect. These two helpers keep the model honest about that. */
static void sp_set_index(Emitter *e, size_t code_index, uint32_t value) {
    if (code_index >= e->code_len) return;
    OpCode op = e->code[code_index].op;
    uint32_t old = e->code[code_index].arg.index;
    e->code[code_index].arg.index = value;
    sp_advance(e, opcode_stack_effect(op, value) - opcode_stack_effect(op, old));
}

static void sp_set_argcount(Emitter *e, size_t code_index, uint8_t value) {
    if (code_index >= e->code_len) return;
    OpCode op = e->code[code_index].op;
    uint8_t old = e->code[code_index].arg.arg_count;
    e->code[code_index].arg.arg_count = value;
    sp_advance(e, opcode_stack_effect(op, value) - opcode_stack_effect(op, old));
}

static void emit_inst_index(Emitter *e, OpCode op, uint32_t index, uint32_t line) {
    size_t base = e->code_len;
    emit_inst(e, op, line);
    sp_set_index(e, base, index);
}

static void emit_inst_offset(Emitter *e, OpCode op, int32_t offset, uint32_t line) {
    size_t base = e->code_len;
    emit_inst(e, op, line);
    e->code[base].arg.offset = offset;
}

/* -----------------------------------------------------------
 * Helper: add a constant to the pool
 * ----------------------------------------------------------- */

static uint32_t add_constant(Emitter *e, Value val) {
    for (size_t i = 0; i < e->const_len; i++) {
        if (e->constants[i].kind != val.kind) continue;
        switch (val.kind) {
            case VAL_NIL:   return (uint32_t)i;
            case VAL_BOOL:  if (e->constants[i].as.bool_val == val.as.bool_val) return (uint32_t)i; break;
            case VAL_INT:   if (e->constants[i].as.int_val == val.as.int_val) return (uint32_t)i; break;
            case VAL_FLOAT: if (e->constants[i].as.float_val == val.as.float_val) return (uint32_t)i; break;
            case VAL_STRUCT_DEF:
                if (e->constants[i].as.struct_def == val.as.struct_def) return (uint32_t)i;
                break;
            default: break;
        }
    }

    if (e->const_len >= EMITTER_MAX_CONSTS) return 0;
    if (e->const_len >= e->const_cap) {
        size_t new_cap = e->const_cap == 0 ? 64 : e->const_cap * 2;
        Value *new_consts = arena_alloc(e->arena,
            sizeof(Value) * new_cap, _Alignof(Value));
        if (new_consts && e->constants) {
            memcpy(new_consts, e->constants, sizeof(Value) * e->const_len);
        }
        e->constants = new_consts;
        e->const_cap = new_cap;
    }
    uint32_t idx = (uint32_t)e->const_len;
    e->constants[e->const_len++] = val;
    return idx;
}

/* -----------------------------------------------------------
 * Local variable helpers
 * ----------------------------------------------------------- */

static uint8_t add_local(Emitter *e, InternedString name) {
    if (e->local_count >= EMITTER_MAX_LOCALS) return 0xFF;
    uint8_t slot = e->local_count;
    e->locals[slot].name  = name;
    e->locals[slot].slot  = slot;
    e->locals[slot].depth = e->scope_depth;
    e->local_count++;
    return slot;
}

static int find_local(Emitter *e, InternedString name) {
    for (int i = e->local_count - 1; i >= 0; i--) {
        if (string_eq(e->locals[i].name, name)) {
            return i;
        }
    }
    return -1;
}

/* Release the slots of the locals declared in the scope being left.
 *
 * This deliberately emits no POP. Locals live in VM stack slots *below* sp
 * (SET_LOCAL writes stack[base+slot] and pads with nil to get there), so a
 * `POP n` here would not remove them: it would remove the n values sitting on
 * top, which is exactly the block's result. That POP was the reason a block
 * used as a value lost its tail expression and the enclosing binding then
 * read a stale slot. Dropping the slot index from the local table is enough; a
 * later binding reuses the slot and SET_LOCAL overwrites it. */
static void pop_scope(Emitter *e) {
    while (e->local_count > 0 &&
           e->locals[e->local_count - 1].depth >= e->scope_depth) {
        e->local_count--;
    }
}

/* -----------------------------------------------------------
 * Struct layout registry
 * ----------------------------------------------------------- */

static StructInfo *find_struct(Emitter *e, InternedString name) {
    for (size_t i = 0; i < e->struct_count; i++) {
        if (string_eq(e->structs[i].name, name)) return &e->structs[i];
    }
    return NULL;
}

static EnumInfo *find_enum(Emitter *e, InternedString name) {
    for (size_t i = 0; i < e->enum_count; i++) {
        if (string_eq(e->enums[i].name, name)) return &e->enums[i];
    }
    return NULL;
}

/* Index of a variant within an enum, or -1. */
static int enum_variant_index(EnumInfo *ei, InternedString variant) {
    if (!ei) return -1;
    for (size_t i = 0; i < ei->variant_count; i++) {
        if (string_eq(ei->variants[i], variant)) return (int)i;
    }
    return -1;
}

/* Which enum declares this variant name, or NULL. */
static EnumInfo *find_enum_by_variant(Emitter *e, InternedString variant) {
    for (size_t i = 0; i < e->variant_index_count; i++) {
        if (string_eq(e->variant_index[i].variant, variant)) {
            return &e->enums[e->variant_index[i].enum_idx];
        }
    }
    return NULL;
}

static bool is_known_fn(Emitter *e, InternedString name) {
    for (size_t i = 0; i < e->fn_count; i++) {
        if (string_eq(e->fns[i].name, name)) return true;
    }
    return false;
}

/* Collect struct/enum declarations before emitting code so literals, field
 * accesses and variants can be resolved without a type table. */
static void register_types(Emitter *e, Node *module) {
    for (size_t i = 0; i < module->as.module.items.len; i++) {
        Node *item = module->as.module.items.data[i];

        if (item->kind == NODE_FN_DECL) {
            if (e->fn_count >= EMITTER_MAX_FNS) {
                fprintf(stderr, "error: too many functions (max %d)\n",
                        EMITTER_MAX_FNS);
                e->error_count++;
                continue;
            }
            e->fns[e->fn_count++].name = item->as.fn_decl.name;
            continue;
        }

        if (item->kind == NODE_ENUM_DECL) {
            if (e->enum_count >= EMITTER_MAX_ENUMS) {
                fprintf(stderr, "error: too many enum declarations (max %d)\n",
                        EMITTER_MAX_ENUMS);
                e->error_count++;
                continue;
            }
            size_t nv = item->as.enum_decl.variants.len;
            EnumInfo *ei = &e->enums[e->enum_count++];
            ei->name          = item->as.enum_decl.name;
            ei->variant_count = nv;
            ei->variants      = nv > 0 ? arena_new_array(e->arena, InternedString, nv) : NULL;
            ei->field_names   = nv > 0 ? arena_new_array(e->arena, const char **, nv) : NULL;
            ei->field_counts  = nv > 0 ? arena_new_array(e->arena, uint32_t, nv) : NULL;
            for (size_t j = 0; j < nv; j++) {
                ei->variants[j] = item->as.enum_decl.variants.data[j];
                Node *payload = item->as.enum_decl.variant_payloads.len > j
                    ? item->as.enum_decl.variant_payloads.data[j] : NULL;
                size_t nf = payload ? payload->as.payload.fields.len : 0;
                ei->field_counts[j] = (uint32_t)nf;
                ei->field_names[j]  = nf > 0
                    ? arena_new_array(e->arena, const char *, nf) : NULL;
                for (size_t k = 0; k < nf; k++) {
                    PayloadField *pf = &payload->as.payload.fields.data[k];
                    ei->field_names[j][k] = pf->name.str ? pf->name.str : NULL;
                }
            }
            /* Only data-carrying variants need construction resolution. */
            for (size_t j = 0; j < nv; j++) {
                if (ei->field_counts[j] == 0) continue;
                if (e->variant_index_count >= EMITTER_MAX_VARIANTS) {
                    fprintf(stderr, "error: too many enum variants (max %d)\n",
                            EMITTER_MAX_VARIANTS);
                    e->error_count++;
                    break;
                }
                e->variant_index[e->variant_index_count].variant  = ei->variants[j];
                e->variant_index[e->variant_index_count].enum_idx = e->enum_count - 1;
                e->variant_index_count++;
            }
            continue;
        }

        if (item->kind != NODE_STRUCT_DECL) continue;

        if (e->struct_count >= EMITTER_MAX_STRUCTS) {
            fprintf(stderr, "error: too many struct declarations (max %d)\n",
                    EMITTER_MAX_STRUCTS);
            e->error_count++;
            continue;
        }

        size_t n = item->as.struct_decl.field_names.len;
        StructInfo *si = &e->structs[e->struct_count++];
        si->name        = item->as.struct_decl.name;
        si->field_count = n;
        si->fields      = n > 0 ? arena_new_array(e->arena, InternedString, n) : NULL;

        StructDef *def = arena_new(e->arena, StructDef);
        def->name        = si->name.str;
        def->field_count = n;
        def->field_names = n > 0 ? arena_new_array(e->arena, const char *, n) : NULL;

        for (size_t j = 0; j < n; j++) {
            si->fields[j]      = item->as.struct_decl.field_names.data[j];
            def->field_names[j] = si->fields[j].str;
        }

        si->def = def;
    }
}

/* -----------------------------------------------------------
 * Forward declarations
 * ----------------------------------------------------------- */

static void emit_node(Emitter *e, Node *node);
static void emit_stmt(Emitter *e, Node *node);
static void emit_expr(Emitter *e, Node *node);

static void emit_pattern_tests(Emitter *e, Node *pat, uint8_t slot,
                               uint32_t line, size_t **hits,
                               size_t *hit_len, size_t *hit_cap);

/* -----------------------------------------------------------
 * Loop patch lists (break / continue)
 * ----------------------------------------------------------- */

static void patch_push(Emitter *e, size_t **data, size_t *len, size_t *cap, size_t idx) {
    if (*len >= *cap) {
        size_t new_cap = *cap == 0 ? 8 : *cap * 2;
        size_t *nd = arena_alloc(e->arena, sizeof(size_t) * new_cap, _Alignof(size_t));
        if (nd && *data) memcpy(nd, *data, sizeof(size_t) * (*len));
        *data = nd;
        *cap  = new_cap;
    }
    (*data)[(*len)++] = idx;
}

static LoopPatch *loop_enter(Emitter *e) {
    if (e->loop_depth >= EMITTER_MAX_LOOP_DEPTH) {
        fprintf(stderr, "error: loop nesting too deep (max %d)\n", EMITTER_MAX_LOOP_DEPTH);
        e->error_count++;
        return NULL;
    }
    LoopPatch *lp = &e->loops[e->loop_depth++];
    memset(lp, 0, sizeof(*lp));
    return lp;
}

static void loop_leave(Emitter *e, LoopPatch *lp, size_t exit_target) {
    if (!lp) return;
    for (size_t i = 0; i < lp->break_len; i++) {
        e->code[lp->breaks[i]].arg.offset = (int32_t)(exit_target - lp->breaks[i]);
    }
    for (size_t i = 0; i < lp->cont_len; i++) {
        e->code[lp->conts[i]].arg.offset =
            (int32_t)(lp->continue_target - lp->conts[i]);
    }
    e->loop_depth--;
}

/* Emit a branch so that it always leaves exactly one value on the stack.
 * Blocks without a tail expression would otherwise leave nothing, making
 * `if`/`else` paths disagree on stack height. */
static void emit_value_branch(Emitter *e, Node *n) {
    if (n && n->kind == NODE_BLOCK && n->as.block.last_expr == NULL) {
        emit_expr(e, n);
        uint32_t z = add_constant(e, value_nil());
        emit_inst_index(e, OPCODE_CONST, z, n->loc.line);
    } else {
        emit_expr(e, n);
    }
}

/* A branch body must leave exactly one value, which is what `if` and `match`
 * require of every arm. */
static void emit_branch_value(Emitter *e, Node *n, const char *where, uint32_t line) {
    int32_t before = e->sp;
    emit_value_branch(e, n);
    if (e->sp != before + 1) {
        fprintf(stderr, "error:%u: internal: %s body left %d values, expected 1\n",
                line, where, e->sp - before);
        e->error_count++;
        e->sp = before + 1;
    }
}

/* Emit a loop body, discarding its tail value if the block has one.
 * Loop bodies are statements: any value they produce must not accumulate
 * on the VM stack across iterations. */
static void emit_loop_body(Emitter *e, Node *body) {
    if (body && body->kind == NODE_BLOCK) {
        bool has_tail = body->as.block.last_expr != NULL;
        emit_expr(e, body);
        if (has_tail) {
            emit_inst(e, OPCODE_POP, body->loc.line);
            e->code[e->code_len - 1].arg.index = 1;
        }
    } else {
        emit_stmt(e, body);
    }
}

/* Emit the value a single pattern alternative matches against. */
static void emit_pattern_value(Emitter *e, Node *pat, uint32_t line) {
    if (!pat) return;

    switch (pat->kind) {
    case NODE_INT_LIT:
    case NODE_FLOAT_LIT:
    case NODE_STRING_LIT:
    case NODE_BOOL_LIT:
    case NODE_NULL_LIT:
    case NODE_UNARY_OP:
        emit_expr(e, pat);
        return;

    case NODE_FIELD_ACCESS: {
        Node *obj = pat->as.field_access.object;
        EnumInfo *ei = (obj && obj->kind == NODE_IDENT)
            ? find_enum(e, obj->as.ident.name) : NULL;
        if (!ei) {
            fprintf(stderr, "error: pattern must be a literal, `_` or Enum.Variant\n");
            e->error_count++;
            break;
        }
        InternedString variant = pat->as.field_access.field;
        if (enum_variant_index(ei, variant) < 0) {
            fprintf(stderr, "error: enum '%.*s' has no variant '%.*s'\n",
                    (int)ei->name.len, ei->name.str,
                    (int)variant.len, variant.str);
            e->error_count++;
        }
        uint32_t idx = add_constant(e, value_enum(ei->name.str, variant.str));
        emit_inst_index(e, OPCODE_CONST, idx, line);
        return;
    }

    default:
        fprintf(stderr, "error: unsupported pattern in match arm\n");
        e->error_count++;
        break;
    }

    /* Fall back to nil so the test is well-formed even after an error. */
    uint32_t z = add_constant(e, value_nil());
    emit_inst_index(e, OPCODE_CONST, z, line);
}

/* Emit `target == pattern` tests; on success jump to the arm body. */
static void emit_pattern_tests(Emitter *e, Node *pat, uint8_t slot,
                               uint32_t line, size_t **hits,
                               size_t *hit_len, size_t *hit_cap) {
    if (!pat) return;

    if (pat->kind == NODE_PATTERN_OR) {
        for (size_t i = 0; i < pat->as.pattern_or.alts.len; i++) {
            emit_pattern_tests(e, pat->as.pattern_or.alts.data[i], slot, line,
                               hits, hit_len, hit_cap);
        }
        return;
    }

    /* Binding pattern: always matches, no comparison needed. The caller
     * will create the local and store the value before emitting the body. */
    if (pat->kind == NODE_PATTERN_BIND) {
        emit_inst_offset(e, OPCODE_JUMP, 0, line);
        patch_push(e, hits, hit_len, hit_cap, e->code_len - 1);
        return;
    }

    /* Enum variant with payload bindings: check the variant tag, then let
     * the caller extract payload fields into binding locals. */
    if (pat->kind == NODE_PATTERN_VARIANT_BIND) {
        Node *var_path = pat->as.pattern_variant_bind.variant;
        if (!var_path || var_path->kind != NODE_FIELD_ACCESS) {
            fprintf(stderr, "error: pattern must be a literal, `_` or Enum.Variant\n");
            e->error_count++;
            return;
        }
        Node *obj = var_path->as.field_access.object;
        EnumInfo *ei = (obj && obj->kind == NODE_IDENT)
            ? find_enum(e, obj->as.ident.name) : NULL;
        if (!ei) {
            fprintf(stderr, "error: pattern must be a literal, `_` or Enum.Variant\n");
            e->error_count++;
            return;
        }
        InternedString variant = var_path->as.field_access.field;
        if (enum_variant_index(ei, variant) < 0) {
            fprintf(stderr, "error: enum '%.*s' has no variant '%.*s'\n",
                    (int)ei->name.len, ei->name.str,
                    (int)variant.len, variant.str);
            e->error_count++;
        }
        uint32_t idx = add_constant(e, value_enum(ei->name.str, variant.str));
        emit_inst_index(e, OPCODE_GET_LOCAL, slot, line);
        emit_inst_index(e, OPCODE_CONST, idx, line);
        emit_inst(e, OPCODE_EQ, line);
        emit_inst_offset(e, OPCODE_JUMP_IF_TRUE, 0, line);
        patch_push(e, hits, hit_len, hit_cap, e->code_len - 1);
        return;
    }

    emit_inst_index(e, OPCODE_GET_LOCAL, slot, line);
    emit_pattern_value(e, pat, line);
    emit_inst(e, OPCODE_EQ, line);
    emit_inst_offset(e, OPCODE_JUMP_IF_TRUE, 0, line);
    patch_push(e, hits, hit_len, hit_cap, e->code_len - 1);
}

/* Hidden loop temporaries use names that cannot collide with user
 * identifiers, so slot lookups stay unambiguous. */
static InternedString hidden_local(Emitter *e, const char *tag) {
    char buf[32];
    snprintf(buf, sizeof(buf), "$%s", tag);
    return string_intern_cstr(e->strings, buf);
}

/* -----------------------------------------------------------
 * Stack-height assertions
 * ----------------------------------------------------------- */

static const char *node_kind_name(NodeKind kind) {
    switch (kind) {
    case NODE_INT_LIT:           return "IntLit";
    case NODE_FLOAT_LIT:         return "FloatLit";
    case NODE_STRING_LIT:        return "StringLit";
    case NODE_BOOL_LIT:          return "BoolLit";
    case NODE_NULL_LIT:          return "NullLit";
    case NODE_SOME_EXPR:         return "SomeExpr";
    case NODE_NONE_EXPR:         return "NoneExpr";
    case NODE_OK_EXPR:           return "OkExpr";
    case NODE_ERR_EXPR:          return "ErrExpr";
    case NODE_TRY_EXPR:          return "TryExpr";
    case NODE_IDENT:             return "Ident";
    case NODE_BINARY_OP:         return "BinaryOp";
    case NODE_UNARY_OP:          return "UnaryOp";
    case NODE_CALL:              return "Call";
    case NODE_INDEX:             return "Index";
    case NODE_ARRAY_LIT:         return "ArrayLit";
    case NODE_RANGE:             return "Range";
    case NODE_STRUCT_LIT:        return "StructLit";
    case NODE_PAYLOAD:           return "Payload";
    case NODE_FIELD_ACCESS:      return "FieldAccess";
    case NODE_PATTERN_WILDCARD:    return "PatternWildcard";
    case NODE_PATTERN_BIND:        return "PatternBind";
    case NODE_PATTERN_VARIANT_BIND: return "PatternVariantBind";
    case NODE_PATTERN_OR:          return "PatternOr";
    case NODE_OPTIONAL_CHAIN:    return "OptionalChain";
    case NODE_BLOCK:             return "Block";
    case NODE_IF:                return "If";
    case NODE_WHILE:             return "While";
    case NODE_FOR:               return "For";
    case NODE_MATCH:             return "Match";
    case NODE_RETURN:            return "Return";
    case NODE_BREAK:             return "Break";
    case NODE_CONTINUE:          return "Continue";
    case NODE_ASSIGN:            return "Assign";
    case NODE_COMPOUND_ASSIGN:   return "CompoundAssign";
    case NODE_FN_DECL:           return "FnDecl";
    case NODE_STRUCT_DECL:       return "StructDecl";
    case NODE_ENUM_DECL:         return "EnumDecl";
    case NODE_CONST_DECL:        return "ConstDecl";
    case NODE_VAR_DECL:          return "VarDecl";
    case NODE_TYPE_IDENT:        return "TypeIdent";
    case NODE_TYPE_OPTIONAL:     return "TypeOptional";
    case NODE_TYPE_ARRAY:        return "TypeArray";
    case NODE_TYPE_FN:           return "TypeFn";
    case NODE_MODULE:            return "Module";
    case NODE_USE:               return "Use";
    case NODE_IMPL:              return "Impl";
    }
    return "?";
}

/* Height a node is required to leave behind when emitted as an expression:
 * one value when it produces one, zero for declarations and for constructs
 * that are statements (`while`, `for`, `return`, `break`, `continue`). */
static int node_value_effect(Node *node) {
    if (!node) return 0;
    switch (node->kind) {
    case NODE_WHILE:
    case NODE_FOR:
    case NODE_RETURN:
    case NODE_BREAK:
    case NODE_CONTINUE:
    case NODE_FN_DECL:
    case NODE_STRUCT_DECL:
    case NODE_ENUM_DECL:
    case NODE_CONST_DECL:
    case NODE_VAR_DECL:
    case NODE_USE:
    case NODE_IMPL:
    case NODE_MODULE:
    case NODE_RANGE:
        return 0;
    case NODE_BLOCK:
        return node->as.block.last_expr ? 1 : 0;
    default:
        return 1;
    }
}

/* Assert the height a node was required to produce, then resynchronise so a
 * single bug does not cascade into a flood of follow-on reports. */
static void sp_check(Emitter *e, Node *node, int32_t before, int expected,
                     const char *where) {
    int32_t want = before + expected;
    if (e->sp == want) return;

    fprintf(stderr, "error:%s:%u: internal: stack imbalance in %s %s: "
                    "expected height %d, emitter computed %d\n",
            node->loc.filename ? node->loc.filename : "?", node->loc.line,
            where, node_kind_name(node->kind), want, e->sp);
    e->error_count++;
    e->sp = want;
}

/* -----------------------------------------------------------
 * Expression emitter — leaves a value on the stack
 * ----------------------------------------------------------- */

static void emit_expr(Emitter *e, Node *node) {
    if (!node) return;

    int32_t sp_before = e->sp;

    switch (node->kind) {
    case NODE_INT_LIT: {
        uint32_t idx = add_constant(e, value_int(node->as.int_lit.value));
        emit_inst_index(e, OPCODE_CONST, idx, node->loc.line);
    } break;

    case NODE_FLOAT_LIT: {
        uint32_t idx = add_constant(e, value_float(node->as.float_lit.value));
        emit_inst_index(e, OPCODE_CONST, idx, node->loc.line);
    } break;

    case NODE_STRING_LIT: {
        uint32_t idx = add_constant(e, value_string(node->as.string_lit.value.str));
        emit_inst_index(e, OPCODE_CONST, idx, node->loc.line);
    } break;

    case NODE_BOOL_LIT: {
        uint32_t idx = add_constant(e, value_bool(node->as.bool_lit.value));
        emit_inst_index(e, OPCODE_CONST, idx, node->loc.line);
    } break;

    case NODE_NULL_LIT: {
        uint32_t idx = add_constant(e, value_nil());
        emit_inst_index(e, OPCODE_CONST, idx, node->loc.line);
    } break;

    case NODE_IDENT: {
        int slot = find_local(e, node->as.ident.name);
        if (slot >= 0) {
            emit_inst_index(e, OPCODE_GET_LOCAL, (uint32_t)slot, node->loc.line);
        } else {
            uint32_t idx = add_constant(e, value_string(node->as.ident.name.str));
            emit_inst_index(e, OPCODE_GET_GLOBAL, idx, node->loc.line);
        }
    } break;

    case NODE_BINARY_OP: {
        uint32_t line = node->loc.line;
        if (node->as.binary.op == OP_AND) {
            /* Short-circuit AND: any false operand decides the result. Each
             * skip target is entered right after a JUMP_IF_FALSE popped its
             * condition, so both rejoin at the same height. */
            int32_t base = e->sp;
            emit_expr(e, node->as.binary.left);
            emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line);
            size_t patch_false = e->code_len - 1;
            emit_expr(e, node->as.binary.right);
            emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line);
            size_t patch_right_false = e->code_len - 1;
            uint32_t true_idx = add_constant(e, value_bool(true));
            emit_inst_index(e, OPCODE_CONST, true_idx, line);
            emit_inst_offset(e, OPCODE_JUMP, 0, line);
            size_t patch_end = e->code_len - 1;

            e->code[patch_false].arg.offset = (int32_t)(e->code_len - patch_false);
            e->sp = base;
            uint32_t false_idx = add_constant(e, value_bool(false));
            emit_inst_index(e, OPCODE_CONST, false_idx, line);

            e->code[patch_right_false].arg.offset = (int32_t)(e->code_len - patch_right_false);
            e->sp = base;
            emit_inst_index(e, OPCODE_CONST, false_idx, line);

            e->code[patch_end].arg.offset = (int32_t)(e->code_len - patch_end);
            e->sp = base + 1;
        } else if (node->as.binary.op == OP_OR) {
            /* Short-circuit OR: any true operand decides the result. */
            int32_t base = e->sp;
            emit_expr(e, node->as.binary.left);
            emit_inst_offset(e, OPCODE_JUMP_IF_TRUE, 0, line);
            size_t patch_true = e->code_len - 1;
            emit_expr(e, node->as.binary.right);
            emit_inst_offset(e, OPCODE_JUMP_IF_TRUE, 0, line);
            size_t patch_right_true = e->code_len - 1;
            uint32_t false_idx = add_constant(e, value_bool(false));
            emit_inst_index(e, OPCODE_CONST, false_idx, line);
            emit_inst_offset(e, OPCODE_JUMP, 0, line);
            size_t patch_end = e->code_len - 1;

            e->code[patch_true].arg.offset = (int32_t)(e->code_len - patch_true);
            e->sp = base;
            uint32_t true_idx = add_constant(e, value_bool(true));
            emit_inst_index(e, OPCODE_CONST, true_idx, line);

            e->code[patch_right_true].arg.offset = (int32_t)(e->code_len - patch_right_true);
            e->sp = base;
            emit_inst_index(e, OPCODE_CONST, true_idx, line);

            e->code[patch_end].arg.offset = (int32_t)(e->code_len - patch_end);
            e->sp = base + 1;
        } else {
            emit_expr(e, node->as.binary.left);
            emit_expr(e, node->as.binary.right);
            switch (node->as.binary.op) {
                case OP_ADD: emit_inst(e, OPCODE_ADD, line); break;
                case OP_SUB: emit_inst(e, OPCODE_SUB, line); break;
                case OP_MUL: emit_inst(e, OPCODE_MUL, line); break;
                case OP_DIV: emit_inst(e, OPCODE_DIV, line); break;
                case OP_MOD: emit_inst(e, OPCODE_MOD, line); break;
                case OP_EQ:  emit_inst(e, OPCODE_EQ,  line); break;
                case OP_NEQ: emit_inst(e, OPCODE_NEQ, line); break;
                case OP_LT:  emit_inst(e, OPCODE_LT,  line); break;
                case OP_GT:  emit_inst(e, OPCODE_GT,  line); break;
                case OP_LE:  emit_inst(e, OPCODE_LE,  line); break;
                case OP_GE:  emit_inst(e, OPCODE_GE,  line); break;
                default: break;
            }
        }
    } break;

    case NODE_UNARY_OP: {
        emit_expr(e, node->as.unary.operand);
        switch (node->as.unary.op) {
            case UNOP_NEG: emit_inst(e, OPCODE_NEG, node->loc.line); break;
            case UNOP_NOT: emit_inst(e, OPCODE_NOT, node->loc.line); break;
            default: break;
        }
    } break;

    case NODE_CALL: {
        /* A bare-identifier callee may name a data-carrying enum variant
         * (`Paso(x)`); the checker already decided, so mirror its rule here:
         * variant first, function call otherwise. */
        Node *callee = node->as.call.callee;
        if (callee->kind == NODE_IDENT && !is_known_fn(e, callee->as.ident.name)) {
            EnumInfo *ei = find_enum_by_variant(e, callee->as.ident.name);
            if (ei) {
                int vi = enum_variant_index(ei, callee->as.ident.name);
                if (vi >= 0) {
                    size_t nf = (size_t)ei->field_counts[vi];
                    if (node->as.call.args.len != nf) {
                        fprintf(stderr,
                                "error: variant '%.*s.%.*s' expects %zu field(s), got %zu\n",
                                (int)ei->name.len, ei->name.str,
                                (int)callee->as.ident.name.len, callee->as.ident.name.str,
                                nf, node->as.call.args.len);
                        e->error_count++;
                        break;
                    }
                    /* Pack the runtime layout: shared by value_print/equality.
                     * The value stack only ever sees the finished handle. */
                    EnumDef *ed = arena_new(e->arena, EnumDef);
                    ed->name = ei->name.str;
                    ed->variant_count = ei->variant_count;
                    ed->variants = arena_new_array(e->arena, VariantDef, ei->variant_count);
                    for (size_t v = 0; v < ei->variant_count; v++) {
                        ed->variants[v].name = ei->variants[v].str;
                        ed->variants[v].field_count = ei->field_counts[v];
                        ed->variants[v].field_names = ei->field_names
                            ? ei->field_names[v] : NULL;
                    }
                    uint32_t def_idx = add_constant(e, value_enum_def(ed));
                    emit_inst_index(e, OPCODE_CONST, def_idx, node->loc.line);
                    for (size_t i = 0; i < node->as.call.args.len; i++) {
                        emit_expr(e, node->as.call.args.data[i]);
                    }
                    emit_inst(e, OPCODE_NEW_ENUM, node->loc.line);
                    e->code[e->code_len - 1].arg.index =
                        ((uint32_t)vi << 16) | (uint32_t)nf;
                    /* emit_inst applied opcode_stack_effect(op, 0) = +1, but
                     * the real effect is -(nf) [pops nf+1, pushes 1]. Correct
                     * the model: +1 already applied, need total -(nf), so
                     * adjust by -(nf) - (+1) = -(nf+1). */
                    sp_advance(e, -(int)nf - 1);
                    break;
                }
            }
        }
        emit_expr(e, node->as.call.callee);
        for (size_t i = 0; i < node->as.call.args.len; i++) {
            emit_expr(e, node->as.call.args.data[i]);
        }
        emit_inst(e, OPCODE_CALL, node->loc.line);
        sp_set_argcount(e, e->code_len - 1, (uint8_t)node->as.call.args.len);
    } break;

    case NODE_ARRAY_LIT: {
        for (size_t i = 0; i < node->as.array_lit.elems.len; i++) {
            emit_expr(e, node->as.array_lit.elems.data[i]);
        }
        emit_inst(e, OPCODE_NEW_ARRAY, node->loc.line);
        sp_set_index(e, e->code_len - 1, (uint32_t)node->as.array_lit.elems.len);
    } break;

    case NODE_INDEX: {
        emit_expr(e, node->as.index.object);
        emit_expr(e, node->as.index.index);
        emit_inst(e, OPCODE_INDEX, node->loc.line);
    } break;

    case NODE_STRUCT_LIT: {
        uint32_t line = node->loc.line;
        InternedString sname = node->as.struct_lit.name;
        StructInfo *si = find_struct(e, sname);
        if (!si) {
            fprintf(stderr, "error: unknown struct '%.*s'\n", (int)sname.len, sname.str);
            e->error_count++;
            break;
        }

        bool ok = true;

        /* Reject fields the struct does not declare. */
        for (size_t j = 0; j < node->as.struct_lit.field_names.len; j++) {
            InternedString fname = node->as.struct_lit.field_names.data[j];
            bool found = false;
            for (size_t i = 0; i < si->field_count; i++) {
                if (string_eq(si->fields[i], fname)) { found = true; break; }
            }
            if (!found) {
                fprintf(stderr, "error: struct '%.*s' has no field '%.*s'\n",
                        (int)sname.len, sname.str, (int)fname.len, fname.str);
                e->error_count++;
                ok = false;
            }
        }

        /* Values are pushed in declaration order, so the runtime layout and
         * the stack always agree regardless of literal field order. The
         * layout constant is added per function pool, since each function
         * owns its own constant table. */
        uint32_t def_idx = add_constant(e, value_struct_def((StructDef *)si->def));
        emit_inst_index(e, OPCODE_CONST, def_idx, line);
        for (size_t i = 0; i < si->field_count; i++) {
            int vi = -1;
            for (size_t j = 0; j < node->as.struct_lit.field_names.len; j++) {
                if (string_eq(node->as.struct_lit.field_names.data[j], si->fields[i])) {
                    vi = (int)j;
                    break;
                }
            }
            if (vi < 0) {
                fprintf(stderr, "error: missing field '%.*s' in initializer of '%.*s'\n",
                        (int)si->fields[i].len, si->fields[i].str,
                        (int)sname.len, sname.str);
                e->error_count++;
                ok = false;
                uint32_t z = add_constant(e, value_nil());
                emit_inst_index(e, OPCODE_CONST, z, line);
            } else {
                emit_expr(e, node->as.struct_lit.field_values.data[vi]);
            }
        }
        (void)ok;
        emit_inst(e, OPCODE_NEW_STRUCT, line);
        sp_set_index(e, e->code_len - 1, (uint32_t)si->field_count);
    } break;

    case NODE_FIELD_ACCESS: {
        Node *obj = node->as.field_access.object;
        /* `Enum.Variant` is a value, not a field read. */
        if (obj && obj->kind == NODE_IDENT) {
            EnumInfo *ei = find_enum(e, obj->as.ident.name);
            if (ei) {
                InternedString variant = node->as.field_access.field;
                if (enum_variant_index(ei, variant) < 0) {
                    fprintf(stderr, "error: enum '%.*s' has no variant '%.*s'\n",
                            (int)ei->name.len, ei->name.str,
                            (int)variant.len, variant.str);
                    e->error_count++;
                }
                uint32_t idx = add_constant(e,
                    value_enum(ei->name.str, variant.str));
                emit_inst_index(e, OPCODE_CONST, idx, node->loc.line);
                break;
            }
        }
        emit_expr(e, obj);
        uint32_t idx = add_constant(e, value_string(node->as.field_access.field.str));
        emit_inst_index(e, OPCODE_GET_FIELD, idx, node->loc.line);
    } break;

    case NODE_MATCH: {
        uint32_t line = node->loc.line;
        size_t n_arms = node->as.match_expr.arms.len;
        int32_t base = e->sp;

        /* The matched value lives in a hidden local; every arm tests against
         * it and the arm body supplies the match's result. */
        uint8_t slot = add_local(e, hidden_local(e, "match_val"));
        if (slot == 0xFF) {
            fprintf(stderr, "error: too many locals for match\n");
            e->error_count++;
            break;
        }
        emit_expr(e, node->as.match_expr.target);
        emit_inst_index(e, OPCODE_SET_LOCAL, slot, line);

        size_t *end_jumps = NULL;
        size_t  end_len = 0, end_cap = 0;
        bool    has_wildcard = false;

        for (size_t i = 0; i < n_arms; i++) {
            Node *pat  = node->as.match_expr.arms.data[i].pattern;
            Node *body = node->as.match_expr.arms.data[i].body;

            /* Each arm is entered after the previous arm's body jumped away, so
             * it starts at the height the scrutinee store left behind. The
             * pattern tests are net zero: GET_LOCAL, push the pattern, EQ,
             * JUMP_IF_TRUE. */
            e->sp = base;

            if (pat && pat->kind == NODE_PATTERN_WILDCARD) {
                has_wildcard = true;
                Node *guard = node->as.match_expr.arms.data[i].guard;
                if (guard) {
                    emit_expr(e, guard);
                    emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line);
                    size_t guard_false = e->code_len - 1;
                    emit_branch_value(e, body, "match arm", line);
                    emit_inst_offset(e, OPCODE_JUMP, 0, line);
                    patch_push(e, &end_jumps, &end_len, &end_cap, e->code_len - 1);
                    /* Guard failed: push nil as the arm result. */
                    uint32_t z = add_constant(e, value_nil());
                    emit_inst_index(e, OPCODE_CONST, z, line);
                    e->code[guard_false].arg.offset = (int32_t)(e->code_len - guard_false);
                } else {
                    emit_branch_value(e, body, "match arm", line);
                    emit_inst_offset(e, OPCODE_JUMP, 0, line);
                    patch_push(e, &end_jumps, &end_len, &end_cap, e->code_len - 1);
                }
                break; /* a wildcard makes later arms unreachable */
            }

            /* Binding pattern: always matches. Bind the scrutinee to a local
             * and jump directly to the arm body. */
            if (pat && pat->kind == NODE_PATTERN_BIND) {
                uint8_t bind_slot = add_local(e, pat->as.pattern_bind.name);
                if (bind_slot == 0xFF) {
                    fprintf(stderr, "error: too many locals for match\n");
                    e->error_count++;
                    break;
                }
                emit_inst_index(e, OPCODE_GET_LOCAL, slot, line);
                emit_inst_index(e, OPCODE_SET_LOCAL, bind_slot, line);
                Node *guard = node->as.match_expr.arms.data[i].guard;
                if (guard) {
                    emit_expr(e, guard);
                    emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line);
                    size_t guard_false = e->code_len - 1;
                    emit_branch_value(e, body, "match arm", line);
                    emit_inst_offset(e, OPCODE_JUMP, 0, line);
                    patch_push(e, &end_jumps, &end_len, &end_cap, e->code_len - 1);
                    /* Guard failed: push nil as the arm result. */
                    uint32_t z = add_constant(e, value_nil());
                    emit_inst_index(e, OPCODE_CONST, z, line);
                    e->code[guard_false].arg.offset = (int32_t)(e->code_len - guard_false);
                } else {
                    emit_branch_value(e, body, "match arm", line);
                    emit_inst_offset(e, OPCODE_JUMP, 0, line);
                    patch_push(e, &end_jumps, &end_len, &end_cap, e->code_len - 1);
                }
                break; /* binding makes later arms unreachable */
            }

            /* Enum variant with payload bindings: check the variant tag, then
             * extract payload fields into binding locals. */
            if (pat && pat->kind == NODE_PATTERN_VARIANT_BIND) {
                size_t *hits = NULL;
                size_t  hit_len = 0, hit_cap = 0;
                emit_pattern_tests(e, pat, slot, line, &hits, &hit_len, &hit_cap);

                emit_inst_offset(e, OPCODE_JUMP, 0, line);
                size_t no_match = e->code_len - 1;

                size_t body_start = e->code_len;
                for (size_t k = 0; k < hit_len; k++) {
                    e->code[hits[k]].arg.offset = (int32_t)(body_start - hits[k]);
                }

                /* Extract payload fields into binding locals. We re-fetch the
                 * enum value from the match local for each field extraction
                 * to avoid stack corruption: SET_LOCAL writes to a fixed stack
                 * slot, which can overwrite the enum data if the binding slot
                 * happens to coincide with the enum value's stack position. */
                size_t bind_count = pat->as.pattern_variant_bind.bindings.len;
                for (size_t b = 0; b < bind_count; b++) {
                    emit_inst_index(e, OPCODE_GET_LOCAL, slot, line);
                    emit_inst_index(e, OPCODE_GET_ENUM_FIELD, (uint32_t)b, line);

                    uint8_t bind_slot = add_local(e, pat->as.pattern_variant_bind.bindings.data[b]);
                    if (bind_slot == 0xFF) {
                        fprintf(stderr, "error: too many locals for match\n");
                        e->error_count++;
                        break;
                    }
                    emit_inst_index(e, OPCODE_SET_LOCAL, bind_slot, line);
                }

                /* Guard: after binding extraction, evaluate the guard. */
                Node *guard = node->as.match_expr.arms.data[i].guard;
                size_t guard_false_jump = 0;
                bool has_guard = (guard != NULL);
                if (has_guard) {
                    emit_expr(e, guard);
                    emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line);
                    guard_false_jump = e->code_len - 1;
                }

                emit_branch_value(e, body, "match arm", line);
                emit_inst_offset(e, OPCODE_JUMP, 0, line);
                patch_push(e, &end_jumps, &end_len, &end_cap, e->code_len - 1);

                size_t next_arm = e->code_len;
                e->code[no_match].arg.offset = (int32_t)(next_arm - no_match);
                if (has_guard) {
                    e->code[guard_false_jump].arg.offset = (int32_t)(next_arm - guard_false_jump);
                }
            }

            size_t *hits = NULL;
            size_t  hit_len = 0, hit_cap = 0;
            emit_pattern_tests(e, pat, slot, line, &hits, &hit_len, &hit_cap);

            emit_inst_offset(e, OPCODE_JUMP, 0, line);
            size_t no_match = e->code_len - 1;

            size_t body_start = e->code_len;
            for (size_t k = 0; k < hit_len; k++) {
                e->code[hits[k]].arg.offset = (int32_t)(body_start - hits[k]);
            }

            /* Guard: after pattern match, evaluate the guard expression.
             * If false, jump past the arm body to the next arm. */
            Node *guard = node->as.match_expr.arms.data[i].guard;
            size_t guard_false_jump = 0;
            bool has_guard = (guard != NULL);
            if (has_guard) {
                emit_expr(e, guard);
                emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line);
                guard_false_jump = e->code_len - 1;
            }

            emit_branch_value(e, body, "match arm", line);
            emit_inst_offset(e, OPCODE_JUMP, 0, line);
            patch_push(e, &end_jumps, &end_len, &end_cap, e->code_len - 1);

            size_t next_arm = e->code_len;
            e->code[no_match].arg.offset = (int32_t)(next_arm - no_match);
            if (has_guard) {
                e->code[guard_false_jump].arg.offset = (int32_t)(next_arm - guard_false_jump);
            }
        }

        if (!has_wildcard) {
            /* No arm matched: yield nil so a match always produces a value. */
            e->sp = base;
            uint32_t z = add_constant(e, value_nil());
            emit_inst_index(e, OPCODE_CONST, z, line);
        }

        size_t end_target = e->code_len;
        for (size_t k = 0; k < end_len; k++) {
            e->code[end_jumps[k]].arg.offset = (int32_t)(end_target - end_jumps[k]);
        }

        /* The hidden local occupied a stack slot *below* the result, and
         * slots are reclaimed by dropping the index from the local table, not
         * by popping the values on top of them. The old SWAP+POP here removed
         * one value at the join, which happened to be a live local slot. */
        e->local_count--;
        e->sp = base + 1;
    } break;

    case NODE_RANGE: {
        fprintf(stderr, "error: range expression is only valid as a for-loop iterator\n");
        e->error_count++;
    } break;

    case NODE_BLOCK: {
        uint8_t saved_depth = e->scope_depth;
        e->scope_depth++;
        for (size_t i = 0; i < node->as.block.stmts.len; i++) {
            emit_stmt(e, node->as.block.stmts.data[i]);
        }
        if (node->as.block.last_expr) {
            emit_expr(e, node->as.block.last_expr);
        }
        pop_scope(e);
        e->scope_depth = saved_depth;
    } break;

    case NODE_IF: {
        uint32_t line2 = node->loc.line;
        int32_t base = e->sp;
        emit_expr(e, node->as.if_expr.cond);
        emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line2);
        size_t patch_false = e->code_len - 1;
        emit_branch_value(e, node->as.if_expr.then_block, "if", line2);
        emit_inst_offset(e, OPCODE_JUMP, 0, line2);
        size_t patch_over = e->code_len - 1;
        e->code[patch_false].arg.offset = (int32_t)(e->code_len - patch_false);
        /* The else arm is entered after JUMP_IF_FALSE popped the condition, so
         * it starts at the height the then arm did. Both arms must then agree,
         * which emit_branch_value enforces. */
        e->sp = base;
        if (node->as.if_expr.else_block) {
            emit_branch_value(e, node->as.if_expr.else_block, "else", line2);
        } else {
            uint32_t z = add_constant(e, value_nil());
            emit_inst_index(e, OPCODE_CONST, z, line2);
        }
        e->code[patch_over].arg.offset = (int32_t)(e->code_len - patch_over);
        e->sp = base + 1;
    } break;

    case NODE_WHILE: {
        uint32_t line = node->loc.line;
        size_t loop_start = e->code_len;
        LoopPatch *lp = loop_enter(e);
        if (lp) lp->continue_target = loop_start;
        emit_expr(e, node->as.while_expr.cond);
        emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line);
        size_t patch_exit = e->code_len - 1;
        emit_loop_body(e, node->as.while_expr.body);
        emit_inst_offset(e, OPCODE_JUMP,
            (int32_t)((int64_t)loop_start - (int64_t)e->code_len), line);
        size_t exit_target = e->code_len;
        e->code[patch_exit].arg.offset = (int32_t)(exit_target - patch_exit);
        loop_leave(e, lp, exit_target);
    } break;

    case NODE_FOR: {
        uint32_t line = node->loc.line;
        Node *iter = node->as.for_expr.iter;
        uint8_t saved_depth = e->scope_depth;
        e->scope_depth++;

        uint8_t slot_idx = add_local(e, hidden_local(e, "for_i"));
        size_t loop_start;
        size_t patch_exit;
        LoopPatch *lp;
        uint8_t var_slot;

        if (iter && iter->kind == NODE_RANGE) {
            /* for i in start..end  /  start..=end */
            uint8_t slot_end = add_local(e, hidden_local(e, "for_end"));

            if (iter->as.range.start) {
                emit_expr(e, iter->as.range.start);
            } else {
                uint32_t z = add_constant(e, value_int(0));
                emit_inst_index(e, OPCODE_CONST, z, line);
            }
            emit_inst_index(e, OPCODE_SET_LOCAL, slot_idx, line);

            if (iter->as.range.end) {
                emit_expr(e, iter->as.range.end);
            } else {
                e->error_count++;
                fprintf(stderr, "error: open-ended range is not supported in Astra-0\n");
                uint32_t z = add_constant(e, value_int(0));
                emit_inst_index(e, OPCODE_CONST, z, line);
            }
            emit_inst_index(e, OPCODE_SET_LOCAL, slot_end, line);

            loop_start = e->code_len;
            lp = loop_enter(e);

            emit_inst_index(e, OPCODE_GET_LOCAL, slot_idx, line);
            emit_inst_index(e, OPCODE_GET_LOCAL, slot_end, line);
            emit_inst(e, iter->as.range.inclusive ? OPCODE_LE : OPCODE_LT, line);
            emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line);
            patch_exit = e->code_len - 1;

            var_slot = add_local(e, node->as.for_expr.var);
            emit_inst_index(e, OPCODE_GET_LOCAL, slot_idx, line);
            emit_inst_index(e, OPCODE_SET_LOCAL, var_slot, line);

            emit_loop_body(e, node->as.for_expr.body);

            if (lp) lp->continue_target = e->code_len;
            emit_inst_index(e, OPCODE_GET_LOCAL, slot_idx, line);
            uint32_t one = add_constant(e, value_int(1));
            emit_inst_index(e, OPCODE_CONST, one, line);
            emit_inst(e, OPCODE_ADD, line);
            emit_inst_index(e, OPCODE_SET_LOCAL, slot_idx, line);
        } else {
            /* for x in array */
            uint8_t slot_arr = add_local(e, hidden_local(e, "for_arr"));

            emit_expr(e, iter);
            emit_inst_index(e, OPCODE_SET_LOCAL, slot_arr, line);
            uint32_t z = add_constant(e, value_int(0));
            emit_inst_index(e, OPCODE_CONST, z, line);
            emit_inst_index(e, OPCODE_SET_LOCAL, slot_idx, line);

            loop_start = e->code_len;
            lp = loop_enter(e);

            emit_inst_index(e, OPCODE_GET_LOCAL, slot_idx, line);
            emit_inst_index(e, OPCODE_GET_LOCAL, slot_arr, line);
            emit_inst(e, OPCODE_LEN, line);
            emit_inst(e, OPCODE_LT, line);
            emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line);
            patch_exit = e->code_len - 1;

            var_slot = add_local(e, node->as.for_expr.var);
            emit_inst_index(e, OPCODE_GET_LOCAL, slot_arr, line);
            emit_inst_index(e, OPCODE_GET_LOCAL, slot_idx, line);
            emit_inst(e, OPCODE_INDEX, line);
            emit_inst_index(e, OPCODE_SET_LOCAL, var_slot, line);

            emit_loop_body(e, node->as.for_expr.body);

            if (lp) lp->continue_target = e->code_len;
            emit_inst_index(e, OPCODE_GET_LOCAL, slot_idx, line);
            uint32_t one = add_constant(e, value_int(1));
            emit_inst_index(e, OPCODE_CONST, one, line);
            emit_inst(e, OPCODE_ADD, line);
            emit_inst_index(e, OPCODE_SET_LOCAL, slot_idx, line);
        }

        emit_inst_offset(e, OPCODE_JUMP,
            (int32_t)((int64_t)loop_start - (int64_t)e->code_len), line);
        size_t exit_target = e->code_len;
        e->code[patch_exit].arg.offset = (int32_t)(exit_target - patch_exit);
        loop_leave(e, lp, exit_target);

        pop_scope(e);
        e->scope_depth = saved_depth;
    } break;

    case NODE_ASSIGN: {
        /* Assignment is an expression: it yields the assigned value so it can
         * safely be the tail of a block. The target is an LValue
         * (`Identifier | LValue "." Identifier | LValue "[" Expression"]"`);
         * plain identifiers store into the binding, anything else stores
         * through the binding into the aggregate it names. */
        uint32_t line = node->loc.line;
        Node *target = node->as.assign.target;
        if (!target) {
            fprintf(stderr, "error: assignment without a target\n");
            e->error_count++;
            break;
        }
        if (target->kind == NODE_IDENT) {
            emit_expr(e, node->as.assign.value);
            InternedString name = target->as.ident.name;
            int slot = find_local(e, name);
            if (slot >= 0) {
                emit_inst_index(e, OPCODE_SET_LOCAL, (uint32_t)slot, line);
                emit_inst_index(e, OPCODE_GET_LOCAL, (uint32_t)slot, line);
            } else {
                uint32_t idx = add_constant(e, value_string(name.str));
                emit_inst_index(e, OPCODE_SET_GLOBAL, idx, line);
                emit_inst_index(e, OPCODE_GET_GLOBAL, idx, line);
            }
        } else if (target->kind == NODE_INDEX || target->kind == NODE_FIELD_ACCESS) {
            /* The chain may be deeper than one link (`xs[i].f = v`), so emit
             * the read of everything above the *last* link, reusing emit_expr:
             * that keeps one path for how a node reads, instead of a second
             * emitter that can drift from it. */
            Node *inner = target->kind == NODE_INDEX
                ? target->as.index.object
                : target->as.field_access.object;
            emit_expr(e, inner);                       /* aggregate handle */
            Node leaf = *target;                       /* detached last link */
            if (target->kind == NODE_INDEX) {
                leaf.as.index.object = NULL;
            } else {
                leaf.as.field_access.object = NULL;
            }
            emit_assign_into(e, &leaf, node->as.assign.value, line);
        } else {
            fprintf(stderr, "error: invalid assignment target\n");
            e->error_count++;
        }
    } break;

    case NODE_RETURN: {
        if (node->as.return_expr.value) {
            emit_expr(e, node->as.return_expr.value);
        } else {
            uint32_t idx = add_constant(e, value_nil());
            emit_inst_index(e, OPCODE_CONST, idx, node->loc.line);
        }
        emit_inst(e, OPCODE_RET, node->loc.line);
    } break;

    case NODE_BREAK: {
        if (e->loop_depth == 0) {
            fprintf(stderr, "error: 'break' used outside of a loop\n");
            e->error_count++;
            break;
        }
        emit_inst_offset(e, OPCODE_JUMP, 0, node->loc.line);
        LoopPatch *lp = &e->loops[e->loop_depth - 1];
        patch_push(e, &lp->breaks, &lp->break_len, &lp->break_cap, e->code_len - 1);
    } break;

    case NODE_CONTINUE: {
        if (e->loop_depth == 0) {
            fprintf(stderr, "error: 'continue' used outside of a loop\n");
            e->error_count++;
            break;
        }
        emit_inst_offset(e, OPCODE_JUMP, 0, node->loc.line);
        LoopPatch *lp = &e->loops[e->loop_depth - 1];
        patch_push(e, &lp->conts, &lp->cont_len, &lp->cont_cap, e->code_len - 1);
    } break;

    case NODE_SOME_EXPR: {
        emit_expr(e, node->as.some_expr.value);
        emit_inst(e, OPCODE_WRAP_SOME, node->loc.line);
    } break;

    case NODE_NONE_EXPR: {
        uint32_t idx = add_constant(e, value_nil());
        emit_inst_index(e, OPCODE_CONST, idx, node->loc.line);
    } break;

    case NODE_OK_EXPR: {
        emit_expr(e, node->as.ok_expr.value);
        emit_inst(e, OPCODE_WRAP_OK, node->loc.line);
    } break;

    case NODE_ERR_EXPR: {
        emit_expr(e, node->as.err_expr.value);
        emit_inst(e, OPCODE_WRAP_ERR, node->loc.line);
    } break;

    case NODE_TRY_EXPR: {
        emit_expr(e, node->as.try_expr.inner);
        emit_inst(e, OPCODE_TRY_UNWRAP, node->loc.line);
    } break;

    default:
        break;
    }

    sp_check(e, node, sp_before, node_value_effect(node), "expression");
}

/* -----------------------------------------------------------
 * Statement emitter
 * ----------------------------------------------------------- */

static void emit_stmt(Emitter *e, Node *node) {
    if (!node) return;

    int32_t sp_before = e->sp;

    switch (node->kind) {
    case NODE_FN_DECL: {
        uint32_t line = node->loc.line;
        FnObj *fn = arena_alloc_zero(e->arena, sizeof(FnObj), _Alignof(FnObj));
        if (!fn) return;

        Instruction *saved_code = e->code;
        size_t saved_len = e->code_len;
        Value *saved_consts = e->constants;
        size_t saved_clen = e->const_len;
        uint16_t saved_local_count = e->local_count;
        uint8_t saved_scope_depth = e->scope_depth;
        int32_t saved_sp = e->sp;

        e->code = NULL;
        e->code_len = 0;
        e->code_cap = 0;
        e->constants = NULL;
        e->const_len = 0;
        e->const_cap = 0;
        e->scope_depth = 1;
        e->local_count = 0;
        e->sp = 0;   /* the callee starts with an empty frame of its own */

        /* Reserve slot 0 for the callee/return value: the VM reuses the
         * function-value slot as the return-value slot, so parameters must
         * start at slot 1. */
        add_local(e, hidden_local(e, "ret"));

        fn->param_count = (uint8_t)node->as.fn_decl.params.len;
        for (size_t i = 0; i < fn->param_count; i++) {
            add_local(e, node->as.fn_decl.params.data[i]);
        }

        /* A block ending in a tail expression already left that value on the
         * stack, so it becomes the return value: this is the Rust-style
         * implicit tail return of research/010 §4.2. Without this the body's
         * value was thrown away and the function returned nil. */
        bool body_is_block = node->as.fn_decl.body &&
                             node->as.fn_decl.body->kind == NODE_BLOCK;
        bool implicit_return = body_is_block &&
            node->as.fn_decl.body->as.block.last_expr != NULL;

        if (node->as.fn_decl.body) {
            emit_expr(e, node->as.fn_decl.body);
        }

        if (e->code_len == 0 || e->code[e->code_len - 1].op != OPCODE_RET) {
            if (!implicit_return) {
                uint32_t nil_idx = add_constant(e, value_nil());
                emit_inst_index(e, OPCODE_CONST, nil_idx, line);
            }
            emit_inst(e, OPCODE_RET, line);
        }

        /* RET hands exactly one value back to the caller, so a function frame
         * must be empty at that point. Leaving something behind means some
         * path inside the body unbalanced the stack — which is how the missing
         * implicit return used to pass unnoticed. */
        if (e->sp != 0) {
            fprintf(stderr, "error:%s:%u: internal: function '%.*s' leaves %d "
                            "value(s) on the stack at return\n",
                    node->loc.filename ? node->loc.filename : "?", node->loc.line,
                    (int)node->as.fn_decl.name.len, node->as.fn_decl.name.str,
                    (int)e->sp);
            e->error_count++;
        }

        fn->local_count = e->local_count;
        fn->code     = e->code;
        fn->code_len = e->code_len;
        fn->constants     = e->constants;
        fn->const_len     = e->const_len;

        e->code = saved_code;
        e->code_len = saved_len;
        e->code_cap = saved_len;
        e->constants = saved_consts;
        e->const_len = saved_clen;
        e->const_cap = saved_clen;
        e->local_count = saved_local_count;
        e->scope_depth = saved_scope_depth;
        e->sp = saved_sp;

        /* Top-level functions become globals so any function can call them
         * (function frames reset their local table). */
        uint32_t fn_idx = add_constant(e, value_fn(fn));
        uint32_t name_idx = add_constant(e, value_string(node->as.fn_decl.name.str));
        if (e->scope_depth == 0) {
            emit_inst_index(e, OPCODE_CONST, fn_idx, line);
            emit_inst_index(e, OPCODE_SET_GLOBAL, name_idx, line);
        } else {
            uint8_t slot = add_local(e, node->as.fn_decl.name);
            if (slot != 0xFF) {
                emit_inst_index(e, OPCODE_CONST, fn_idx, line);
                emit_inst_index(e, OPCODE_SET_LOCAL, slot, line);
            } else {
                emit_inst_index(e, OPCODE_CONST, fn_idx, line);
                emit_inst_index(e, OPCODE_SET_GLOBAL, name_idx, line);
            }
        }
    } break;

    case NODE_VAR_DECL: {
        uint32_t line = node->loc.line;
        if (node->as.var_decl.value) {
            emit_expr(e, node->as.var_decl.value);
        } else {
            uint32_t idx = add_constant(e, value_nil());
            emit_inst_index(e, OPCODE_CONST, idx, line);
        }
        if (e->scope_depth == 0) {
            /* Module-level bindings are globals, visible from every function. */
            uint32_t name_idx = add_constant(e, value_string(node->as.var_decl.name.str));
            emit_inst_index(e, OPCODE_SET_GLOBAL, name_idx, line);
        } else {
            uint8_t slot = add_local(e, node->as.var_decl.name);
            if (slot == 0xFF) {
                uint32_t name_idx = add_constant(e, value_string(node->as.var_decl.name.str));
                emit_inst_index(e, OPCODE_SET_GLOBAL, name_idx, line);
            } else {
                emit_inst_index(e, OPCODE_SET_LOCAL, slot, line);
            }
        }
    } break;

    case NODE_CONST_DECL: {
        uint32_t line = node->loc.line;
        if (node->as.const_decl.value) {
            emit_expr(e, node->as.const_decl.value);
        } else {
            uint32_t idx = add_constant(e, value_nil());
            emit_inst_index(e, OPCODE_CONST, idx, line);
        }
        if (e->scope_depth == 0) {
            uint32_t name_idx = add_constant(e, value_string(node->as.const_decl.name.str));
            emit_inst_index(e, OPCODE_SET_GLOBAL, name_idx, line);
        } else {
            uint8_t slot = add_local(e, node->as.const_decl.name);
            if (slot == 0xFF) {
                uint32_t name_idx = add_constant(e, value_string(node->as.const_decl.name.str));
                emit_inst_index(e, OPCODE_SET_GLOBAL, name_idx, line);
            } else {
                /* Without this store a `const` declared inside a function left
                 * its value on the stack, unbalancing every following
                 * statement. */
                emit_inst_index(e, OPCODE_SET_LOCAL, slot, line);
            }
        }
    } break;

    case NODE_STRUCT_DECL:
    case NODE_ENUM_DECL:
    case NODE_USE:
    case NODE_IMPL:
        break;

    case NODE_MODULE: {
        for (size_t i = 0; i < node->as.module.items.len; i++) {
            emit_node(e, node->as.module.items.data[i]);
        }
    } break;

    /* Block statements discard their tail value (if any). */
    case NODE_BLOCK: {
        bool has_tail = node->as.block.last_expr != NULL;
        emit_expr(e, node);
        if (has_tail) {
            emit_inst(e, OPCODE_POP, node->loc.line);
            e->code[e->code_len - 1].arg.index = 1;
        }
    } break;

    /* Statements that produce no value on the stack. */
    case NODE_WHILE:
    case NODE_FOR:
    case NODE_RETURN:
    case NODE_BREAK:
    case NODE_CONTINUE:
        emit_expr(e, node);
        break;

    default: {
        emit_expr(e, node);
        /* Pop unused expression result from statement context */
        if (node_value_effect(node) != 0) {
            emit_inst(e, OPCODE_POP, node->loc.line);
            sp_set_index(e, e->code_len - 1, 1);
        }
    } break;
    }

    /* A statement is stack neutral by definition. */
    sp_check(e, node, sp_before, 0, "statement");
}

/* -----------------------------------------------------------
 * Node dispatcher
 * ----------------------------------------------------------- */

static void emit_node(Emitter *e, Node *node) {
    if (!node) return;

    switch (node->kind) {
    case NODE_MODULE:
        emit_stmt(e, node);
        break;

    case NODE_FN_DECL:
    case NODE_VAR_DECL:
    case NODE_CONST_DECL:
    case NODE_STRUCT_DECL:
    case NODE_ENUM_DECL:
    case NODE_USE:
    case NODE_IMPL:
        emit_stmt(e, node);
        break;

    case NODE_BLOCK:
    case NODE_IF:
    case NODE_WHILE:
    case NODE_FOR:
    case NODE_RETURN:
    case NODE_BREAK:
    case NODE_CONTINUE:
    case NODE_ASSIGN:
        emit_expr(e, node);
        break;

    case NODE_INT_LIT:
    case NODE_FLOAT_LIT:
    case NODE_STRING_LIT:
    case NODE_BOOL_LIT:
    case NODE_NULL_LIT:
    case NODE_IDENT:
    case NODE_BINARY_OP:
    case NODE_UNARY_OP:
    case NODE_CALL:
        emit_expr(e, node);
        break;

    default:
        break;
    }
}

/* -----------------------------------------------------------
 * Public API
 * ----------------------------------------------------------- */

Emitter *emitter_create(Arena *arena, StringTable *strings) {
    Emitter *e = arena_alloc_zero(arena, sizeof(Emitter), _Alignof(Emitter));
    if (!e) return NULL;
    e->arena   = arena;
    e->strings = strings;
    return e;
}

void emitter_emit(Emitter *e, Node *module) {
    if (!e || !module) return;
    register_types(e, module);
    emit_node(e, module);

    /* If the module defines main(), call it. Top-level functions live in the
     * globals table, so a name lookup is enough. */
    InternedString main_name = string_intern_cstr(e->strings, "main");
    for (size_t i = 0; i < module->as.module.items.len; i++) {
        Node *item = module->as.module.items.data[i];
        if (item->kind == NODE_FN_DECL && string_eq(item->as.fn_decl.name, main_name)) {
            uint32_t name_idx = add_constant(e, value_string(main_name.str));
            emit_inst_index(e, OPCODE_GET_GLOBAL, name_idx, item->loc.line);
            emit_inst(e, OPCODE_CALL, item->loc.line);
            e->code[e->code_len - 1].arg.arg_count = 0;
            break;
        }
    }

    emit_inst(e, OPCODE_HALT, 0);
}

void emitter_destroy(Emitter *e) {
    (void)e;
}

const Instruction *emitter_get_code(Emitter *e, size_t *out_len) {
    if (!e) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    if (out_len) *out_len = e->code_len;
    return e->code;
}

const Value *emitter_get_constants(Emitter *e, size_t *out_len) {
    if (!e) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    if (out_len) *out_len = e->const_len;
    return e->constants;
}

int emitter_error_count(Emitter *e) {
    return e ? e->error_count : 0;
}
