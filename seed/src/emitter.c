#include "priv.h"

/* -----------------------------------------------------------
 * Helper: emit a single instruction
 * ----------------------------------------------------------- */

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
}

static void emit_inst_index(Emitter *e, OpCode op, uint32_t index, uint32_t line) {
    size_t base = e->code_len;
    emit_inst(e, op, line);
    e->code[base].arg.index = index;
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

static void pop_scope(Emitter *e) {
    uint8_t popped = 0;
    while (e->local_count > 0 &&
           e->locals[e->local_count - 1].depth >= e->scope_depth) {
        e->local_count--;
        popped++;
    }
    if (popped > 0) {
        emit_inst(e, OPCODE_POP, 0);
        e->code[e->code_len - 1].arg.index = popped;
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

/* Collect struct declarations before emitting code so literals and field
 * accesses can be resolved without a type table. */
static void register_structs(Emitter *e, Node *module) {
    for (size_t i = 0; i < module->as.module.items.len; i++) {
        Node *item = module->as.module.items.data[i];
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

/* Hidden loop temporaries use names that cannot collide with user
 * identifiers, so slot lookups stay unambiguous. */
static InternedString hidden_local(Emitter *e, const char *tag) {
    char buf[32];
    snprintf(buf, sizeof(buf), "$%s", tag);
    return string_intern_cstr(e->strings, buf);
}

/* -----------------------------------------------------------
 * Expression emitter — leaves a value on the stack
 * ----------------------------------------------------------- */

static void emit_expr(Emitter *e, Node *node) {
    if (!node) return;

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
            /* Short-circuit AND: if left is false, skip right and return false */
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
            uint32_t false_idx = add_constant(e, value_bool(false));
            emit_inst_index(e, OPCODE_CONST, false_idx, line);
            e->code[patch_right_false].arg.offset = (int32_t)(e->code_len - patch_right_false);
            emit_inst_index(e, OPCODE_CONST, false_idx, line);
            e->code[patch_end].arg.offset = (int32_t)(e->code_len - patch_end);
        } else if (node->as.binary.op == OP_OR) {
            /* Short-circuit OR: if left is true, skip right and return true */
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
            uint32_t true_idx = add_constant(e, value_bool(true));
            emit_inst_index(e, OPCODE_CONST, true_idx, line);
            e->code[patch_right_true].arg.offset = (int32_t)(e->code_len - patch_right_true);
            emit_inst_index(e, OPCODE_CONST, true_idx, line);
            e->code[patch_end].arg.offset = (int32_t)(e->code_len - patch_end);
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
        emit_expr(e, node->as.call.callee);
        for (size_t i = 0; i < node->as.call.args.len; i++) {
            emit_expr(e, node->as.call.args.data[i]);
        }
        emit_inst(e, OPCODE_CALL, node->loc.line);
        e->code[e->code_len - 1].arg.arg_count = (uint8_t)node->as.call.args.len;
    } break;

    case NODE_ARRAY_LIT: {
        for (size_t i = 0; i < node->as.array_lit.elems.len; i++) {
            emit_expr(e, node->as.array_lit.elems.data[i]);
        }
        emit_inst(e, OPCODE_NEW_ARRAY, node->loc.line);
        e->code[e->code_len - 1].arg.index = (uint32_t)node->as.array_lit.elems.len;
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
        e->code[e->code_len - 1].arg.index = (uint32_t)si->field_count;
    } break;

    case NODE_FIELD_ACCESS: {
        emit_expr(e, node->as.field_access.object);
        uint32_t idx = add_constant(e, value_string(node->as.field_access.field.str));
        emit_inst_index(e, OPCODE_GET_FIELD, idx, node->loc.line);
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
        emit_expr(e, node->as.if_expr.cond);
        emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, line2);
        size_t patch_false = e->code_len - 1;
        emit_value_branch(e, node->as.if_expr.then_block);
        emit_inst_offset(e, OPCODE_JUMP, 0, line2);
        size_t patch_over = e->code_len - 1;
        e->code[patch_false].arg.offset = (int32_t)(e->code_len - patch_false);
        if (node->as.if_expr.else_block) {
            emit_value_branch(e, node->as.if_expr.else_block);
        } else {
            uint32_t z = add_constant(e, value_nil());
            emit_inst_index(e, OPCODE_CONST, z, line2);
        }
        e->code[patch_over].arg.offset = (int32_t)(e->code_len - patch_over);
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
         * safely be the tail of a block. */
        uint32_t line = node->loc.line;
        emit_expr(e, node->as.assign.value);
        int slot = find_local(e, node->as.assign.name);
        if (slot >= 0) {
            emit_inst_index(e, OPCODE_SET_LOCAL, (uint32_t)slot, line);
            emit_inst_index(e, OPCODE_GET_LOCAL, (uint32_t)slot, line);
        } else {
            uint32_t idx = add_constant(e, value_string(node->as.assign.name.str));
            emit_inst_index(e, OPCODE_SET_GLOBAL, idx, line);
            emit_inst_index(e, OPCODE_GET_GLOBAL, idx, line);
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

    default:
        break;
    }
}

/* -----------------------------------------------------------
 * Statement emitter
 * ----------------------------------------------------------- */

static void emit_stmt(Emitter *e, Node *node) {
    if (!node) return;

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

        e->code = NULL;
        e->code_len = 0;
        e->code_cap = 0;
        e->constants = NULL;
        e->const_len = 0;
        e->const_cap = 0;
        e->scope_depth = 1;
        e->local_count = 0;

        /* Reserve slot 0 for the callee/return value: the VM reuses the
         * function-value slot as the return-value slot, so parameters must
         * start at slot 1. */
        add_local(e, hidden_local(e, "ret"));

        fn->param_count = (uint8_t)node->as.fn_decl.params.len;
        for (size_t i = 0; i < fn->param_count; i++) {
            add_local(e, node->as.fn_decl.params.data[i]);
        }

        if (node->as.fn_decl.body) {
            emit_expr(e, node->as.fn_decl.body);
        }

        if (e->code_len == 0 || e->code[e->code_len - 1].op != OPCODE_RET) {
            uint32_t nil_idx = add_constant(e, value_nil());
            emit_inst_index(e, OPCODE_CONST, nil_idx, line);
            emit_inst(e, OPCODE_RET, line);
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
        emit_inst(e, OPCODE_POP, node->loc.line);
        e->code[e->code_len - 1].arg.index = 1;
    } break;
    }
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
    register_structs(e, module);
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
