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
    case VAL_FN:     printf("<fn>"); break;
    }
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

static bool vm_push_frame(VM *vm, const Instruction *ret_ip, uint8_t base) {
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

VMResult vm_run(VM *vm, const Instruction *code, size_t code_len,
                Value *constants, size_t const_len) {
    if (!vm || !code || code_len == 0) return VM_RUNTIME_ERROR;

    vm->code      = code;
    vm->code_len  = code_len;
    vm->constants = constants;
    vm->const_len = const_len;

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
                /* Create a wrapper fn_obj for builtin print */
                FnObj *fn = arena_alloc(vm->arena, sizeof(FnObj), _Alignof(FnObj));
                fn->code = NULL;
                fn->code_len = 0;
                fn->constants = NULL;
                fn->const_len = 0;
                fn->param_count = 255; /* sentinel for builtins */
                fn->local_count = 0;
                if (!vm_push(vm, value_fn(fn))) return VM_RUNTIME_ERROR;
            } else {
                if (!vm_push(vm, value_nil())) return VM_RUNTIME_ERROR;
            }
        } break;

        case OPCODE_SET_GLOBAL: {
            if (inst.arg.index >= vm->const_len) {
                vm_runtime_error(vm, line, "global name index %u out of range", inst.arg.index);
                return VM_RUNTIME_ERROR;
            }
            /* Pop and discard for now (simplified) */
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on set_global");
                return VM_RUNTIME_ERROR;
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
            bool result = false;
            if (a.kind == b.kind) {
                switch (a.kind) {
                case VAL_NIL:    result = true; break;
                case VAL_BOOL:   result = (a.as.bool_val == b.as.bool_val); break;
                case VAL_INT:    result = (a.as.int_val == b.as.int_val); break;
                case VAL_FLOAT:  result = (a.as.float_val == b.as.float_val); break;
                case VAL_STRING: result = (a.as.string_val == b.as.string_val); break;
                case VAL_FN:     result = (a.as.fn_val == b.as.fn_val); break;
                }
            }
            if (!vm_push(vm, value_bool(result))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_NEQ: {
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on neq");
                return VM_RUNTIME_ERROR;
            }
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            bool result = true;
            if (a.kind == b.kind) {
                switch (a.kind) {
                case VAL_NIL:    result = false; break;
                case VAL_BOOL:   result = (a.as.bool_val != b.as.bool_val); break;
                case VAL_INT:    result = (a.as.int_val != b.as.int_val); break;
                case VAL_FLOAT:  result = (a.as.float_val != b.as.float_val); break;
                case VAL_STRING: result = (a.as.string_val != b.as.string_val); break;
                case VAL_FN:     result = (a.as.fn_val != b.as.fn_val); break;
                }
            }
            if (!vm_push(vm, value_bool(result))) return VM_RUNTIME_ERROR;
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

            uint8_t base = (uint8_t)fn_idx;
            if (!vm_push_frame(vm, ip + 1, base)) return VM_RUNTIME_ERROR;

            /* Switch to function's code and constants */
            vm->code      = fn->code;
            vm->code_len  = fn->code_len;
            vm->constants = fn->constants;
            vm->const_len = fn->const_len;

            ip = fn->code - 1;
            end = fn->code + fn->code_len;
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
    return vm;
}

void vm_destroy(VM *vm) {
    (void)vm;
}
