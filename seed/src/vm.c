#include "priv.h"
#include <stdio.h>
#include <math.h>
#include <stdarg.h>

/* -----------------------------------------------------------
 * Value constructors
 * ----------------------------------------------------------- */

Value value_nil(void) {
    Value v = {0};
    v.kind = VAL_NIL;
    return v;
}

Value value_bool(bool b) {
    Value v = {0};
    v.kind = VAL_BOOL;
    v.as.bool_val = b;
    return v;
}

Value value_int(int64_t i) {
    Value v = {0};
    v.kind = VAL_INT;
    v.as.int_val = i;
    return v;
}

Value value_float(double f) {
    Value v = {0};
    v.kind = VAL_FLOAT;
    v.as.float_val = f;
    return v;
}

Value value_string(const char *s) {
    Value v = {0};
    v.kind = VAL_STRING;
    v.as.string_val = s;
    return v;
}

Value value_array(ArrayObj *a) {
    Value v = {0};
    v.kind = VAL_ARRAY;
    v.as.array_val = a;
    return v;
}

ArrayObj *array_obj_new(Arena *a, size_t len) {
    ArrayObj *obj = arena_new(a, ArrayObj);
    if (!obj) return NULL;
    obj->len = len;
    obj->elems = len > 0 ? arena_new_array(a, Value, len) : NULL;
    return obj;
}

Value value_struct(StructObj *s) {
    Value v = {0};
    v.kind = VAL_STRUCT;
    v.as.struct_val = s;
    return v;
}

Value value_struct_def(StructDef *d) {
    Value v = {0};
    v.kind = VAL_STRUCT_DEF;
    v.as.struct_def = d;
    return v;
}

Value value_enum(const char *enum_name, const char *variant_name) {
    Value v = {0};
    v.kind = VAL_ENUM;
    v.as.enum_val.enum_name    = enum_name;
    v.as.enum_val.variant_name = variant_name;
    return v;
}

StructObj *struct_obj_new(Arena *a, const StructDef *def) {
    StructObj *obj = arena_new(a, StructObj);
    if (!obj) return NULL;
    obj->def = def;
    size_t n = def ? def->field_count : 0;
    obj->fields = n > 0 ? arena_new_array(a, Value, n) : NULL;
    return obj;
}

Value value_fn(FnObj *f) {
    Value v = {0};
    v.kind = VAL_FN;
    v.as.fn_val = f;
    return v;
}

/* -----------------------------------------------------------
 * Value utilities
 * ----------------------------------------------------------- */

bool value_is_truthy(Value v) {
    switch (v.kind) {
    case VAL_NIL:    return false;
    case VAL_BOOL:   return v.as.bool_val;
    case VAL_INT:    return v.as.int_val != 0;
    case VAL_FLOAT:  return v.as.float_val != 0.0;
    case VAL_STRING: return v.as.string_val != NULL && v.as.string_val[0] != '\0';
    case VAL_ARRAY:  return v.as.array_val != NULL && v.as.array_val->len > 0;
    case VAL_STRUCT: return v.as.struct_val != NULL;
    case VAL_STRUCT_DEF: return v.as.struct_def != NULL;
    case VAL_ENUM:   return true;
    case VAL_FN:     return v.as.fn_val != NULL;
    }
    return false;
}

static const char *type_name(Value v) {
    switch (v.kind) {
    case VAL_NIL:    return "nil";
    case VAL_BOOL:   return "bool";
    case VAL_INT:    return "int";
    case VAL_FLOAT:  return "float";
    case VAL_STRING: return "string";
    case VAL_ARRAY:  return "array";
    case VAL_STRUCT: return "struct";
    case VAL_STRUCT_DEF: return "struct_def";
    case VAL_ENUM:   return "enum";
    case VAL_FN:     return "function";
    }
    return "unknown";
}

void value_print(Value v) {
    switch (v.kind) {
    case VAL_NIL:    printf("nil"); break;
    case VAL_BOOL:   printf(v.as.bool_val ? "true" : "false"); break;
    case VAL_INT:    printf("%ld", (long)v.as.int_val); break;
    case VAL_FLOAT:  printf("%g", v.as.float_val); break;
    case VAL_STRING: printf("%s", v.as.string_val); break;
    case VAL_ARRAY:
        printf("[");
        if (v.as.array_val) {
            for (size_t i = 0; i < v.as.array_val->len; i++) {
                if (i > 0) printf(", ");
                value_print(v.as.array_val->elems[i]);
            }
        }
        printf("]");
        break;
    case VAL_STRUCT: {
        StructObj *s = v.as.struct_val;
        if (!s || !s->def) { printf("<struct>"); break; }
        printf("%s { ", s->def->name ? s->def->name : "?");
        for (size_t i = 0; i < s->def->field_count; i++) {
            if (i > 0) printf(", ");
            printf("%s: ", s->def->field_names[i]);
            value_print(s->fields[i]);
        }
        printf(" }");
        break;
    }
    case VAL_STRUCT_DEF: printf("<struct_def>"); break;
    case VAL_ENUM:
        printf("%s.%s",
               v.as.enum_val.enum_name ? v.as.enum_val.enum_name : "?",
               v.as.enum_val.variant_name ? v.as.enum_val.variant_name : "?");
        break;
    case VAL_FN:     printf("<fn>"); break;
    }
}

/* Structural equality: arrays compare element-wise. */
static bool value_eq(Value a, Value b) {
    if (a.kind == VAL_ARRAY && b.kind == VAL_ARRAY) {
        ArrayObj *x = a.as.array_val;
        ArrayObj *y = b.as.array_val;
        if (x == y) return true;
        if (!x || !y || x->len != y->len) return false;
        for (size_t i = 0; i < x->len; i++) {
            if (!value_eq(x->elems[i], y->elems[i])) return false;
        }
        return true;
    }
    if (a.kind != b.kind) return false;
    switch (a.kind) {
    case VAL_NIL:    return true;
    case VAL_BOOL:   return a.as.bool_val == b.as.bool_val;
    case VAL_INT:    return a.as.int_val == b.as.int_val;
    case VAL_FLOAT:  return a.as.float_val == b.as.float_val;
    case VAL_STRING:
        if (a.as.string_val == b.as.string_val) return true;
        if (!a.as.string_val || !b.as.string_val) return false;
        return strcmp(a.as.string_val, b.as.string_val) == 0;
    case VAL_ARRAY:  return a.as.array_val == b.as.array_val;
    case VAL_STRUCT: {
        StructObj *x = a.as.struct_val;
        StructObj *y = b.as.struct_val;
        if (x == y) return true;
        if (!x || !y || !x->def || !y->def) return false;
        if (strcmp(x->def->name, y->def->name) != 0) return false;
        if (x->def->field_count != y->def->field_count) return false;
        for (size_t i = 0; i < x->def->field_count; i++) {
            if (!value_eq(x->fields[i], y->fields[i])) return false;
        }
        return true;
    }
    case VAL_STRUCT_DEF: return a.as.struct_def == b.as.struct_def;
    case VAL_ENUM: {
        const char *an = a.as.enum_val.enum_name;
        const char *bn = b.as.enum_val.enum_name;
        const char *av = a.as.enum_val.variant_name;
        const char *bv = b.as.enum_val.variant_name;
        if (an == av && bn == bv) return true;
        if (!an || !bn || !av || !bv) return false;
        return strcmp(an, bn) == 0 && strcmp(av, bv) == 0;
    }
    case VAL_FN:     return a.as.fn_val == b.as.fn_val;
    }
    return false;
}

/* -----------------------------------------------------------
 * Built-in functions
 * ----------------------------------------------------------- */

static Value builtin_print(Value *args, uint8_t argc) {
    for (uint8_t i = 0; i < argc; i++) {
        if (i > 0) printf(" ");
        value_print(args[i]);
    }
    printf("\n");
    return value_nil();
}

/* -----------------------------------------------------------
 * VM stack operations
 * ----------------------------------------------------------- */

static bool vm_push(VM *vm, Value val) {
    if (vm->sp >= VM_STACK_SIZE) {
        vm->error_msg = "stack overflow";
        vm->error_line = 0;
        return false;
    }
    vm->stack[vm->sp++] = val;
    return true;
}

static Value vm_pop(VM *vm) {
    if (vm->sp == 0) {
        vm->error_msg = "stack underflow";
        vm->error_line = 0;
        return value_nil();
    }
    return vm->stack[--vm->sp];
}

/* -----------------------------------------------------------
 * Call frame management
 * ----------------------------------------------------------- */

static bool vm_push_frame(VM *vm, const Instruction *ret_ip, uint16_t base) {
    if (vm->frame_count >= VM_CALL_DEPTH) {
        vm->error_msg = "call depth exceeded";
        vm->error_line = 0;
        return false;
    }
    vm->frames[vm->frame_count].ip   = ret_ip;
    vm->frames[vm->frame_count].base = base;
    vm->frames[vm->frame_count].saved_code      = vm->code;
    vm->frames[vm->frame_count].saved_code_len  = vm->code_len;
    vm->frames[vm->frame_count].saved_constants = vm->constants;
    vm->frames[vm->frame_count].saved_const_len = vm->const_len;
    vm->frame_count++;
    return true;
}

static bool vm_pop_frame(VM *vm, Value return_val) {
    if (vm->frame_count == 0) {
        vm->error_msg = "return from top-level";
        vm->error_line = 0;
        return false;
    }
    vm->frame_count--;
    vm->sp = vm->frames[vm->frame_count].base;
    /* Restore parent's code and constants */
    vm->code      = vm->frames[vm->frame_count].saved_code;
    vm->code_len  = vm->frames[vm->frame_count].saved_code_len;
    vm->constants = vm->frames[vm->frame_count].saved_constants;
    vm->const_len = vm->frames[vm->frame_count].saved_const_len;
    return vm_push(vm, return_val);
}

/* -----------------------------------------------------------
 * Runtime error
 * ----------------------------------------------------------- */

static void vm_runtime_error(VM *vm, uint32_t line, const char *fmt, ...) {
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    vm->error_msg  = arena_strdup(vm->arena, buf, strlen(buf));
    vm->error_line = line;
}

/* -----------------------------------------------------------
 * VM execution
 * ----------------------------------------------------------- */

static const char *opname(OpCode op) {
    switch (op) {
    case OPCODE_CONST:        return "CONST";
    case OPCODE_POP:          return "POP";
    case OPCODE_DUP:          return "DUP";
    case OPCODE_SWAP:         return "SWAP";
    case OPCODE_GET_LOCAL:    return "GET_LOCAL";
    case OPCODE_SET_LOCAL:    return "SET_LOCAL";
    case OPCODE_GET_GLOBAL:   return "GET_GLOBAL";
    case OPCODE_SET_GLOBAL:   return "SET_GLOBAL";
    case OPCODE_ADD:          return "ADD";
    case OPCODE_SUB:          return "SUB";
    case OPCODE_MUL:          return "MUL";
    case OPCODE_DIV:          return "DIV";
    case OPCODE_MOD:          return "MOD";
    case OPCODE_NEG:          return "NEG";
    case OPCODE_EQ:           return "EQ";
    case OPCODE_NEQ:          return "NEQ";
    case OPCODE_LT:           return "LT";
    case OPCODE_GT:           return "GT";
    case OPCODE_LE:           return "LE";
    case OPCODE_GE:           return "GE";
    case OPCODE_AND:          return "AND";
    case OPCODE_OR:           return "OR";
    case OPCODE_NOT:          return "NOT";
    case OPCODE_JUMP:         return "JUMP";
    case OPCODE_JUMP_IF_FALSE:return "JUMP_IF_FALSE";
    case OPCODE_JUMP_IF_TRUE: return "JUMP_IF_TRUE";
    case OPCODE_NEW_ARRAY:    return "NEW_ARRAY";
    case OPCODE_INDEX:        return "INDEX";
    case OPCODE_LEN:          return "LEN";
    case OPCODE_NEW_STRUCT:   return "NEW_STRUCT";
    case OPCODE_GET_FIELD:    return "GET_FIELD";
    case OPCODE_CALL:         return "CALL";
    case OPCODE_RET:          return "RET";
    case OPCODE_PRINT:        return "PRINT";
    case OPCODE_HALT:         return "HALT";
    default:                  return "???";
    }
}

VMResult vm_run(VM *vm, const Instruction *code, size_t code_len,
                Value *constants, size_t const_len) {
    if (!vm || !code || code_len == 0) return VM_RUNTIME_ERROR;

    vm->code      = code;
    vm->code_len  = code_len;
    vm->constants = constants;
    vm->const_len = const_len;

    /* Dump bytecode for debugging */
    if (getenv("ASTRA_DUMP_VM")) {
        fprintf(stderr, "=== Bytecode (%zu instructions, %zu constants) ===\n", code_len, const_len);
        for (size_t i = 0; i < code_len; i++) {
            fprintf(stderr, "  [%3zu] %-16s", i, opname(code[i].op));
            switch (code[i].op) {
            case OPCODE_CONST:
            case OPCODE_GET_GLOBAL:
            case OPCODE_SET_GLOBAL:
                fprintf(stderr, " %u", code[i].arg.index);
                if (code[i].op == OPCODE_CONST && constants && code[i].arg.index < const_len) {
                    fprintf(stderr, " (");
                    value_print(constants[code[i].arg.index]);
                    fprintf(stderr, ")");
                }
                break;
            case OPCODE_GET_LOCAL:
            case OPCODE_SET_LOCAL:
                fprintf(stderr, " slot=%u", code[i].arg.index);
                break;
            case OPCODE_CALL:
                fprintf(stderr, " argc=%u", code[i].arg.arg_count);
                break;
            case OPCODE_JUMP:
            case OPCODE_JUMP_IF_FALSE:
            case OPCODE_JUMP_IF_TRUE:
                fprintf(stderr, " offset=%d", code[i].arg.offset);
                break;
            default:
                break;
            }
            fprintf(stderr, "\n");
        }
        fprintf(stderr, "=== End bytecode ===\n");
    }

    const Instruction *ip   = code;
    const Instruction *end  = code + code_len;

    while (ip < end) {
        Instruction inst = *ip;
        uint32_t line = inst.line;

        switch (inst.op) {

        /* ---- Stack operations ---- */

        case OPCODE_CONST: {
            if (inst.arg.index >= vm->const_len) {
                vm_runtime_error(vm, line, "constant index %u out of range (have %zu)",
                    inst.arg.index, vm->const_len);
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, vm->constants[inst.arg.index])) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_POP: {
            uint8_t count = inst.arg.index;
            if (count == 0) count = 1;
            if (vm->sp < count) {
                vm_runtime_error(vm, line, "stack underflow: tried to pop %u but only %u values", count, vm->sp);
                return VM_RUNTIME_ERROR;
            }
            vm->sp -= count;
        } break;

        case OPCODE_DUP: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on dup");
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, vm->stack[vm->sp - 1])) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_SWAP: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on swap");
                return VM_RUNTIME_ERROR;
            }
            Value tmp = vm->stack[vm->sp - 1];
            vm->stack[vm->sp - 1] = vm->stack[vm->sp - 2];
            vm->stack[vm->sp - 2] = tmp;
        } break;

        /* ---- Local variables ---- */

        case OPCODE_GET_LOCAL: {
            uint8_t slot = (uint8_t)inst.arg.index;
            uint8_t base = vm->frame_count > 0 ? vm->frames[vm->frame_count - 1].base : 0;
            if (base + slot >= vm->sp) {
                vm_runtime_error(vm, line, "local variable at slot %u not initialized", slot);
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, vm->stack[base + slot])) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_SET_LOCAL: {
            uint8_t slot = (uint8_t)inst.arg.index;
            uint8_t base = vm->frame_count > 0 ? vm->frames[vm->frame_count - 1].base : 0;
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on set_local");
                return VM_RUNTIME_ERROR;
            }
            Value val = vm_pop(vm);
            /* Ensure stack has room */
            while (base + slot >= vm->sp) {
                if (!vm_push(vm, value_nil())) return VM_RUNTIME_ERROR;
            }
            vm->stack[base + slot] = val;
        } break;

        /* ---- Global variables ---- */

        case OPCODE_GET_GLOBAL: {
            if (inst.arg.index >= vm->const_len) {
                vm_runtime_error(vm, line, "global name index %u out of range", inst.arg.index);
                return VM_RUNTIME_ERROR;
            }
            const char *name = vm->constants[inst.arg.index].as.string_val;
            /* Check built-in globals */
            if (name && strcmp(name, "print") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_print_fn))) return VM_RUNTIME_ERROR;
            } else {
                /* Look up in globals table */
                bool found = false;
                for (uint16_t i = 0; i < vm->global_count; i++) {
                    if (vm->globals[i].name && strcmp(vm->globals[i].name, name) == 0) {
                        if (!vm_push(vm, vm->globals[i].value)) return VM_RUNTIME_ERROR;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    vm_runtime_error(vm, line, "undefined global variable '%s'", name);
                    return VM_RUNTIME_ERROR;
                }
            }
        } break;

        case OPCODE_SET_GLOBAL: {
            if (inst.arg.index >= vm->const_len) {
                vm_runtime_error(vm, line, "global name index %u out of range", inst.arg.index);
                return VM_RUNTIME_ERROR;
            }
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on set_global");
                return VM_RUNTIME_ERROR;
            }
            const char *name = vm->constants[inst.arg.index].as.string_val;
            Value val = vm_pop(vm);
            /* Look up in globals table and update if found */
            bool found = false;
            for (uint16_t i = 0; i < vm->global_count; i++) {
                if (vm->globals[i].name && strcmp(vm->globals[i].name, name) == 0) {
                    vm->globals[i].value = val;
                    found = true;
                    break;
                }
            }
            /* If not found, add new global */
            if (!found) {
                if (vm->global_count >= VM_MAX_GLOBALS) {
                    vm_runtime_error(vm, line, "too many global variables");
                    return VM_RUNTIME_ERROR;
                }
                vm->globals[vm->global_count].name = name;
                vm->globals[vm->global_count].value = val;
                vm->global_count++;
            }
        } break;

        /* ---- Arithmetic ---- */

        case OPCODE_ADD: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on add");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_int(a.as.int_val + b.as.int_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float(a.as.float_val + b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_INT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float((double)a.as.int_val + b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_float(a.as.float_val + (double)b.as.int_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_STRING && b.kind == VAL_STRING) {
                /* String concatenation */
                size_t len_a = strlen(a.as.string_val);
                size_t len_b = strlen(b.as.string_val);
                char *buf = arena_alloc(vm->arena, len_a + len_b + 1, 1);
                if (!buf) {
                    vm_runtime_error(vm, line, "out of memory");
                    return VM_RUNTIME_ERROR;
                }
                memcpy(buf, a.as.string_val, len_a);
                memcpy(buf + len_a, b.as.string_val, len_b);
                buf[len_a + len_b] = '\0';
                if (!vm_push(vm, value_string(buf))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "cannot add %s and %s", type_name(a), type_name(b));
                return VM_RUNTIME_ERROR;
            }
        } break;

        case OPCODE_SUB: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on sub");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_int(a.as.int_val - b.as.int_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float(a.as.float_val - b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_INT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float((double)a.as.int_val - b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_float(a.as.float_val - (double)b.as.int_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "cannot subtract %s from %s", type_name(b), type_name(a));
                return VM_RUNTIME_ERROR;
            }
        } break;

        case OPCODE_MUL: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on mul");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_int(a.as.int_val * b.as.int_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float(a.as.float_val * b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_INT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float((double)a.as.int_val * b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_float(a.as.float_val * (double)b.as.int_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "cannot multiply %s and %s", type_name(a), type_name(b));
                return VM_RUNTIME_ERROR;
            }
        } break;

        case OPCODE_DIV: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on div");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if ((b.kind == VAL_INT && b.as.int_val == 0) ||
                (b.kind == VAL_FLOAT && b.as.float_val == 0.0)) {
                vm_runtime_error(vm, line, "division by zero");
                return VM_RUNTIME_ERROR;
            }
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_int(a.as.int_val / b.as.int_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float(a.as.float_val / b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_INT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float((double)a.as.int_val / b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_float(a.as.float_val / (double)b.as.int_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "cannot divide %s by %s", type_name(a), type_name(b));
                return VM_RUNTIME_ERROR;
            }
        } break;

        case OPCODE_MOD: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on mod");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if ((b.kind == VAL_INT && b.as.int_val == 0) ||
                (b.kind == VAL_FLOAT && b.as.float_val == 0.0)) {
                vm_runtime_error(vm, line, "modulo by zero");
                return VM_RUNTIME_ERROR;
            }
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_int(a.as.int_val % b.as.int_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float(fmod(a.as.float_val, b.as.float_val)))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "cannot apply modulo to %s and %s", type_name(a), type_name(b));
                return VM_RUNTIME_ERROR;
            }
        } break;

        case OPCODE_NEG: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on neg");
                return VM_RUNTIME_ERROR;
            }
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT) {
                if (!vm_push(vm, value_int(-a.as.int_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float(-a.as.float_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "cannot negate %s", type_name(a));
                return VM_RUNTIME_ERROR;
            }
        } break;

        /* ---- Comparison ---- */

        case OPCODE_EQ: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on eq");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (!vm_push(vm, value_bool(value_eq(a, b)))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_NEQ: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on neq");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (!vm_push(vm, value_bool(!value_eq(a, b)))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_LT: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on lt");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            bool result = false;
            if (a.kind == VAL_INT && b.kind == VAL_INT)
                result = a.as.int_val < b.as.int_val;
            else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT)
                result = a.as.float_val < b.as.float_val;
            else if (a.kind == VAL_INT && b.kind == VAL_FLOAT)
                result = (double)a.as.int_val < b.as.float_val;
            else if (a.kind == VAL_FLOAT && b.kind == VAL_INT)
                result = a.as.float_val < (double)b.as.int_val;
            else {
                vm_runtime_error(vm, line, "cannot compare %s and %s", type_name(a), type_name(b));
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, value_bool(result))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_GT: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on gt");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            bool result = false;
            if (a.kind == VAL_INT && b.kind == VAL_INT)
                result = a.as.int_val > b.as.int_val;
            else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT)
                result = a.as.float_val > b.as.float_val;
            else if (a.kind == VAL_INT && b.kind == VAL_FLOAT)
                result = (double)a.as.int_val > b.as.float_val;
            else if (a.kind == VAL_FLOAT && b.kind == VAL_INT)
                result = a.as.float_val > (double)b.as.int_val;
            else {
                vm_runtime_error(vm, line, "cannot compare %s and %s", type_name(a), type_name(b));
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, value_bool(result))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_LE: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on le");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            bool result = false;
            if (a.kind == VAL_INT && b.kind == VAL_INT)
                result = a.as.int_val <= b.as.int_val;
            else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT)
                result = a.as.float_val <= b.as.float_val;
            else if (a.kind == VAL_INT && b.kind == VAL_FLOAT)
                result = (double)a.as.int_val <= b.as.float_val;
            else if (a.kind == VAL_FLOAT && b.kind == VAL_INT)
                result = a.as.float_val <= (double)b.as.int_val;
            else {
                vm_runtime_error(vm, line, "cannot compare %s and %s", type_name(a), type_name(b));
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, value_bool(result))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_GE: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on ge");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            bool result = false;
            if (a.kind == VAL_INT && b.kind == VAL_INT)
                result = a.as.int_val >= b.as.int_val;
            else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT)
                result = a.as.float_val >= b.as.float_val;
            else if (a.kind == VAL_INT && b.kind == VAL_FLOAT)
                result = (double)a.as.int_val >= b.as.float_val;
            else if (a.kind == VAL_FLOAT && b.kind == VAL_INT)
                result = a.as.float_val >= (double)b.as.int_val;
            else {
                vm_runtime_error(vm, line, "cannot compare %s and %s", type_name(a), type_name(b));
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, value_bool(result))) return VM_RUNTIME_ERROR;
        } break;

        /* ---- Logical ---- */

        case OPCODE_AND: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on and");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (!vm_push(vm, value_bool(value_is_truthy(a) && value_is_truthy(b))))
                return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_OR: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on or");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (!vm_push(vm, value_bool(value_is_truthy(a) || value_is_truthy(b))))
                return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_NOT: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on not");
                return VM_RUNTIME_ERROR;
            }
            Value a = vm_pop(vm);
            if (!vm_push(vm, value_bool(!value_is_truthy(a)))) return VM_RUNTIME_ERROR;
        } break;

        /* ---- Aggregates ---- */

        case OPCODE_NEW_ARRAY: {
            size_t n = inst.arg.index;
            if (vm->sp < n) {
                vm_runtime_error(vm, line, "stack underflow building array of %zu", n);
                return VM_RUNTIME_ERROR;
            }
            ArrayObj *arr = array_obj_new(vm->arena, n);
            if (!arr) {
                vm_runtime_error(vm, line, "out of memory building array");
                return VM_RUNTIME_ERROR;
            }
            for (size_t i = 0; i < n; i++) {
                arr->elems[i] = vm->stack[vm->sp - n + i];
            }
            vm->sp = (uint16_t)(vm->sp - n);
            if (!vm_push(vm, value_array(arr))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_INDEX: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on index");
                return VM_RUNTIME_ERROR;
            }
            Value idx = vm_pop(vm);
            Value obj = vm_pop(vm);
            if (obj.kind != VAL_ARRAY || !obj.as.array_val) {
                vm_runtime_error(vm, line, "cannot index %s", type_name(obj));
                return VM_RUNTIME_ERROR;
            }
            if (idx.kind != VAL_INT) {
                vm_runtime_error(vm, line, "array index must be int, got %s", type_name(idx));
                return VM_RUNTIME_ERROR;
            }
            ArrayObj *arr = obj.as.array_val;
            if (idx.as.int_val < 0 || (uint64_t)idx.as.int_val >= arr->len) {
                vm_runtime_error(vm, line, "index %ld out of bounds (len %zu)",
                    (long)idx.as.int_val, arr->len);
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, arr->elems[idx.as.int_val])) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_LEN: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on len");
                return VM_RUNTIME_ERROR;
            }
            Value obj = vm_pop(vm);
            size_t n = 0;
            if (obj.kind == VAL_ARRAY && obj.as.array_val) n = obj.as.array_val->len;
            else if (obj.kind == VAL_STRING && obj.as.string_val) n = strlen(obj.as.string_val);
            else {
                vm_runtime_error(vm, line, "cannot take length of %s", type_name(obj));
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, value_int((int64_t)n))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_NEW_STRUCT: {
            size_t n = inst.arg.index;
            if (vm->sp < n + 1) {
                vm_runtime_error(vm, line, "stack underflow building struct");
                return VM_RUNTIME_ERROR;
            }
            Value def_val = vm->stack[vm->sp - n - 1];
            if (def_val.kind != VAL_STRUCT_DEF || !def_val.as.struct_def) {
                vm_runtime_error(vm, line, "invalid struct layout on stack");
                return VM_RUNTIME_ERROR;
            }
            const StructDef *def = def_val.as.struct_def;
            if (n != def->field_count) {
                vm_runtime_error(vm, line, "struct '%s' expects %zu fields, got %zu",
                    def->name, def->field_count, n);
                return VM_RUNTIME_ERROR;
            }
            StructObj *obj = struct_obj_new(vm->arena, def);
            if (!obj) {
                vm_runtime_error(vm, line, "out of memory building struct");
                return VM_RUNTIME_ERROR;
            }
            for (size_t i = 0; i < n; i++) {
                obj->fields[i] = vm->stack[vm->sp - n + i];
            }
            vm->sp = (uint16_t)(vm->sp - n - 1);
            if (!vm_push(vm, value_struct(obj))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_GET_FIELD: {
            if (inst.arg.index >= vm->const_len) {
                vm_runtime_error(vm, line, "field name index %u out of range", inst.arg.index);
                return VM_RUNTIME_ERROR;
            }
            Value obj = vm_pop(vm);
            const char *field = vm->constants[inst.arg.index].as.string_val;
            if (obj.kind != VAL_STRUCT || !obj.as.struct_val) {
                vm_runtime_error(vm, line, "cannot access field on %s", type_name(obj));
                return VM_RUNTIME_ERROR;
            }
            StructObj *s = obj.as.struct_val;
            int found = -1;
            for (size_t i = 0; i < s->def->field_count; i++) {
                if (strcmp(s->def->field_names[i], field) == 0) { found = (int)i; break; }
            }
            if (found < 0) {
                vm_runtime_error(vm, line, "struct '%s' has no field '%s'", s->def->name, field);
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, s->fields[found])) return VM_RUNTIME_ERROR;
        } break;

        /* ---- Control flow ---- */

        case OPCODE_JUMP: {
            int32_t offset = inst.arg.offset;
            ip += offset;
            /* ip will be incremented at end of loop, adjust */
            ip--;
        } break;

        case OPCODE_JUMP_IF_FALSE: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on jump_if_false");
                return VM_RUNTIME_ERROR;
            }
            Value cond = vm_pop(vm);
            if (!value_is_truthy(cond)) {
                int32_t offset = inst.arg.offset;
                ip += offset;
                ip--;
            }
        } break;

        case OPCODE_JUMP_IF_TRUE: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on jump_if_true");
                return VM_RUNTIME_ERROR;
            }
            Value cond = vm_pop(vm);
            if (value_is_truthy(cond)) {
                int32_t offset = inst.arg.offset;
                ip += offset;
                ip--;
            }
        } break;

        /* ---- Functions ---- */

        case OPCODE_CALL: {
            uint8_t argc = inst.arg.arg_count;
            if (vm->sp < argc + 1) {
                vm_runtime_error(vm, line, "not enough arguments on stack for call");
                return VM_RUNTIME_ERROR;
            }
            int fn_idx = (int)vm->sp - 1 - argc;
            Value fn_val = vm->stack[fn_idx];
            if (fn_val.kind != VAL_FN || !fn_val.as.fn_val) {
                vm_runtime_error(vm, line, "cannot call non-function value");
                return VM_RUNTIME_ERROR;
            }
            FnObj *fn = fn_val.as.fn_val;

            /* Handle built-in functions (param_count == 255) */
            if (fn->param_count == 255 && fn->code == NULL) {
                /* Built-in: print */
                Value result = builtin_print(&vm->stack[fn_idx + 1], argc);
                /* Remove args + fn from stack */
                vm->sp = (uint16_t)fn_idx;
                if (!vm_push(vm, result)) return VM_RUNTIME_ERROR;
                break;
            }

            if (argc != fn->param_count) {
                vm_runtime_error(vm, line, "expected %u arguments but got %u",
                    fn->param_count, argc);
                return VM_RUNTIME_ERROR;
            }

            uint16_t base = (uint16_t)fn_idx;
            if (!vm_push_frame(vm, ip + 1, base)) return VM_RUNTIME_ERROR;

            /* Switch to function's code and constants */
            vm->code      = fn->code;
            vm->code_len  = fn->code_len;
            vm->constants = fn->constants;
            vm->const_len = fn->const_len;

            ip = fn->code - 1;
            end = fn->code + fn->code_len;

            if (getenv("ASTRA_DUMP_VM")) {
                fprintf(stderr, "  >> CALL fn (base=%u, %zu instructions, %zu constants)\n",
                    base, fn->code_len, fn->const_len);
                for (size_t di = 0; di < fn->code_len; di++) {
                    fprintf(stderr, "     [%3zu] %-16s", di, opname(fn->code[di].op));
                    switch (fn->code[di].op) {
                    case OPCODE_CONST:
                    case OPCODE_GET_GLOBAL:
                    case OPCODE_SET_GLOBAL:
                        fprintf(stderr, " %u", fn->code[di].arg.index);
                        if (fn->code[di].op == OPCODE_CONST && fn->constants && fn->code[di].arg.index < fn->const_len) {
                            fprintf(stderr, " (");
                            value_print(fn->constants[fn->code[di].arg.index]);
                            fprintf(stderr, ")");
                        }
                        break;
                    case OPCODE_GET_LOCAL:
                    case OPCODE_SET_LOCAL:
                        fprintf(stderr, " slot=%u", fn->code[di].arg.index);
                        break;
                    case OPCODE_CALL:
                        fprintf(stderr, " argc=%u", fn->code[di].arg.arg_count);
                        break;
                    case OPCODE_JUMP:
                    case OPCODE_JUMP_IF_FALSE:
                    case OPCODE_JUMP_IF_TRUE:
                        fprintf(stderr, " offset=%d", fn->code[di].arg.offset);
                        break;
                    default:
                        break;
                    }
                    fprintf(stderr, "\n");
                }
            }
        } break;

        case OPCODE_RET: {
            Value return_val = value_nil();
            if (vm->sp > 0) {
                return_val = vm_pop(vm);
            }
            if (!vm_pop_frame(vm, return_val)) {
                /* Top-level return — we're done */
                return VM_OK;
            }
            ip = vm->frames[vm->frame_count].ip - 1;
            end = vm->code + vm->code_len;
        } break;

        /* ---- I/O ---- */

        case OPCODE_PRINT: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on print");
                return VM_RUNTIME_ERROR;
            }
            Value val = vm_pop(vm);
            value_print(val);
            printf("\n");
        } break;

        /* ---- Special ---- */

        case OPCODE_HALT:
            return VM_OK;

        default:
            vm_runtime_error(vm, line, "unknown opcode %d", (int)inst.op);
            return VM_RUNTIME_ERROR;
        }

        if (getenv("ASTRA_TRACE")) {
            uint8_t base = vm->frame_count > 0 ? vm->frames[vm->frame_count - 1].base : 0;
            fprintf(stderr, "  sp=%u base=%u frame=%u | ", vm->sp, base, vm->frame_count);
            for (uint16_t s = 0; s < vm->sp && s < 20; s++) {
                fprintf(stderr, "[");
                value_print(vm->stack[s]);
                fprintf(stderr, "]");
            }
            fprintf(stderr, "\n");
        }

        ip++;
    }

    return VM_OK;
}

/* -----------------------------------------------------------
 * Public API
 * ----------------------------------------------------------- */

VM *vm_create(Arena *arena) {
    VM *vm = arena_alloc_zero(arena, sizeof(VM), _Alignof(VM));
    if (!vm) return NULL;
    vm->arena = arena;
    /* Cache built-in print function */
    FnObj *print_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    print_fn->code = NULL;
    print_fn->code_len = 0;
    print_fn->constants = NULL;
    print_fn->const_len = 0;
    print_fn->param_count = 255;
    print_fn->local_count = 0;
    vm->builtin_print_fn = print_fn;
    return vm;
}

void vm_destroy(VM *vm) {
    (void)vm;
}
