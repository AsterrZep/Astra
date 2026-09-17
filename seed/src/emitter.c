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
 * Forward declarations
 * ----------------------------------------------------------- */

static void emit_node(Emitter *e, Node *node);
static void emit_stmt(Emitter *e, Node *node);
static void emit_expr(Emitter *e, Node *node);

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
        emit_expr(e, node->as.if_expr.cond);
        emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, node->loc.line);
        size_t patch_false = e->code_len - 1;
        emit_expr(e, node->as.if_expr.then_block);
        if (node->as.if_expr.else_block) {
            emit_inst_offset(e, OPCODE_JUMP, 0, node->loc.line);
            size_t patch_over = e->code_len - 1;
            e->code[patch_false].arg.offset = (int32_t)(e->code_len - patch_false);
            emit_expr(e, node->as.if_expr.else_block);
            e->code[patch_over].arg.offset = (int32_t)(e->code_len - patch_over);
        } else {
            e->code[patch_false].arg.offset = (int32_t)(e->code_len - patch_false);
        }
    } break;

    case NODE_WHILE: {
        size_t loop_start = e->code_len;
        emit_expr(e, node->as.while_expr.cond);
        emit_inst_offset(e, OPCODE_JUMP_IF_FALSE, 0, node->loc.line);
        size_t patch_exit = e->code_len - 1;
        emit_expr(e, node->as.while_expr.body);
        emit_inst_offset(e, OPCODE_JUMP,
            (int32_t)((int64_t)loop_start - (int64_t)e->code_len), node->loc.line);
        e->code[patch_exit].arg.offset = (int32_t)(e->code_len - patch_exit);
    } break;

    case NODE_FOR: {
        /* Simplified: reserve slot for loop variable, emit body */
        emit_expr(e, node->as.for_expr.iter);
        uint8_t var_slot = add_local(e, node->as.for_expr.var);
        size_t loop_start = e->code_len;
        emit_inst_index(e, OPCODE_SET_LOCAL, var_slot, node->loc.line);
        emit_expr(e, node->as.for_expr.body);
        /* Jump back for iteration (placeholder) */
        emit_inst_offset(e, OPCODE_JUMP,
            (int32_t)((int64_t)loop_start - (int64_t)e->code_len), node->loc.line);
        pop_scope(e);
        (void)loop_start;
    } break;

    case NODE_ASSIGN: {
        emit_expr(e, node->as.assign.value);
        int slot = find_local(e, node->as.assign.name);
        if (slot >= 0) {
            emit_inst_index(e, OPCODE_SET_LOCAL, (uint32_t)slot, node->loc.line);
        } else {
            uint32_t idx = add_constant(e, value_string(node->as.assign.name.str));
            emit_inst_index(e, OPCODE_SET_GLOBAL, idx, node->loc.line);
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
        emit_inst(e, OPCODE_HALT, node->loc.line);
    } break;

    case NODE_CONTINUE: {
        emit_inst(e, OPCODE_HALT, node->loc.line);
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

        uint32_t fn_idx = add_constant(e, value_fn(fn));
        uint8_t slot = add_local(e, node->as.fn_decl.name);
        if (slot != 0xFF) {
            emit_inst_index(e, OPCODE_CONST, fn_idx, line);
            emit_inst_index(e, OPCODE_SET_LOCAL, slot, line);
        } else {
            emit_inst_index(e, OPCODE_CONST, fn_idx, line);
            emit_inst_index(e, OPCODE_SET_GLOBAL, fn_idx, line);
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
        uint8_t slot = add_local(e, node->as.var_decl.name);
        if (slot == 0xFF) {
            uint32_t name_idx = add_constant(e, value_string(node->as.var_decl.name.str));
            emit_inst_index(e, OPCODE_SET_GLOBAL, name_idx, line);
        } else {
            emit_inst_index(e, OPCODE_SET_LOCAL, slot, line);
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
        uint8_t slot = add_local(e, node->as.const_decl.name);
        if (slot == 0xFF) {
            uint32_t name_idx = add_constant(e, value_string(node->as.const_decl.name.str));
            emit_inst_index(e, OPCODE_SET_GLOBAL, name_idx, line);
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
    emit_node(e, module);

    /* For Astra-0: automatically call main() if it exists */
    /* Search for a main function in the module */
    for (size_t i = 0; i < module->as.module.items.len; i++) {
        Node *item = module->as.module.items.data[i];
        if (item->kind == NODE_FN_DECL &&
            string_eq(item->as.fn_decl.name, string_intern_cstr(e->strings, "main"))) {
            /* Found main, emit a call to it */
            /* We need to find the local slot where main is stored */
            for (uint16_t j = 0; j < e->local_count; j++) {
                if (e->locals[j].depth == 0 &&
                    string_eq(e->locals[j].name, string_intern_cstr(e->strings, "main"))) {
                    emit_inst_index(e, OPCODE_GET_LOCAL, e->locals[j].slot, item->loc.line);
                    emit_inst(e, OPCODE_CALL, item->loc.line);
                    e->code[e->code_len - 1].arg.arg_count = 0;
                    break;
                }
            }
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
