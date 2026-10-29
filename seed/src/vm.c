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

Value value_string(const char *s, size_t len) {
    Value v = {0};
    v.kind = VAL_STRING;
    v.as.string_val.str = s;
    v.as.string_val.len = len;
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

Value value_enum_def(EnumDef *d) {
    Value v = {0};
    v.kind = VAL_ENUM_DEF;
    v.as.enum_def = d;
    return v;
}

Value value_enum_with_payload(EnumObj *obj) {
    Value v = {0};
    v.kind = VAL_ENUM_DATA;
    v.as.enum_obj = obj;
    return v;
}

/* Materialise a data-carrying enum: clone the packed layout (the constant is
 * shared by every construction site) and take the payload from the stack. */
static EnumObj *enum_obj_new(Arena *a, const EnumDef *def, size_t variant,
                             Value *fields) {
    EnumObj *obj = arena_new(a, EnumObj);
    if (!obj) return NULL;
    obj->def = def;
    obj->variant = variant;
    size_t n = (def && variant < def->variant_count)
        ? def->variants[variant].field_count : 0;
    obj->fields = n > 0 ? arena_new_array(a, Value, n) : NULL;
    for (size_t i = 0; i < n; i++) obj->fields[i] = fields[i];
    return obj;
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

Value value_ok(Arena *a, Value inner) {
    Value v = {0};
    v.kind = VAL_OK;
    Value *p = arena_new(a, Value);
    *p = inner;
    v.as.ok_val.inner = p;
    return v;
}

Value value_err(Arena *a, Value inner) {
    Value v = {0};
    v.kind = VAL_ERR;
    Value *p = arena_new(a, Value);
    *p = inner;
    v.as.err_val.inner = p;
    return v;
}

Value value_some(Arena *a, Value inner) {
    Value v = {0};
    v.kind = VAL_SOME;
    Value *p = arena_new(a, Value);
    *p = inner;
    v.as.some_val.inner = p;
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
    case VAL_STRING: return v.as.string_val.str != NULL && v.as.string_val.len > 0;
    case VAL_ARRAY:  return v.as.array_val != NULL && v.as.array_val->len > 0;
    case VAL_STRUCT: return v.as.struct_val != NULL;
    case VAL_STRUCT_DEF: return v.as.struct_def != NULL;
    case VAL_ENUM:   return true;
    case VAL_ENUM_DATA: return v.as.enum_obj != NULL;
    case VAL_ENUM_DEF: return v.as.enum_def != NULL;
    case VAL_FN:     return v.as.fn_val != NULL;
    case VAL_OK:     return true;
    case VAL_ERR:    return true;
    case VAL_SOME:   return true;
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
    case VAL_ENUM_DATA: return "enum";
    case VAL_ENUM_DEF: return "enum_def";
    case VAL_FN:     return "function";
    case VAL_OK:     return "ok";
    case VAL_ERR:    return "err";
    case VAL_SOME:   return "some";
    }
    return "unknown";
}

/* Renders a value to an explicit stream. The dumps (bytecode, ASTRA_DUMP_VM,
 * ASTRA_TRACE) use this with stderr so that program output (stdout) never
 * interleaves with diagnostics — matching the Zig compiler. */
static void value_print_stream(FILE *out, Value v) {
    switch (v.kind) {
    case VAL_NIL:    fprintf(out, "nil"); break;
    case VAL_BOOL:   fprintf(out, "%s", v.as.bool_val ? "true" : "false"); break;
    case VAL_INT:    fprintf(out, "%ld", (long)v.as.int_val); break;
    case VAL_FLOAT:  fprintf(out, "%g", v.as.float_val); break;
    /* fwrite, not "%.*s": printf's %s stops at a NUL byte even when the
     * precision allows more (audit §2.14). */
    case VAL_STRING: fwrite(v.as.string_val.str, 1, v.as.string_val.len, out); break;
    case VAL_ARRAY:
        fprintf(out, "[");
        if (v.as.array_val) {
            for (size_t i = 0; i < v.as.array_val->len; i++) {
                if (i > 0) fprintf(out, ", ");
                value_print_stream(out, v.as.array_val->elems[i]);
            }
        }
        fprintf(out, "]");
        break;
    case VAL_STRUCT: {
        StructObj *s = v.as.struct_val;
        if (!s || !s->def) { fprintf(out, "<struct>"); break; }
        fprintf(out, "%s { ", s->def->name ? s->def->name : "?");
        for (size_t i = 0; i < s->def->field_count; i++) {
            if (i > 0) fprintf(out, ", ");
            fprintf(out, "%s: ", s->def->field_names[i]);
            value_print_stream(out, s->fields[i]);
        }
        fprintf(out, " }");
        break;
    }
    case VAL_STRUCT_DEF: fprintf(out, "<struct_def>"); break;
    case VAL_ENUM:
        fprintf(out, "%s.%s",
               v.as.enum_val.enum_name ? v.as.enum_val.enum_name : "?",
               v.as.enum_val.variant_name ? v.as.enum_val.variant_name : "?");
        break;
    case VAL_ENUM_DATA: {
        /* Data-carrying value: print with a Rust-like constructor form. */
        const EnumDef *d = v.as.enum_obj->def;
        size_t vi = v.as.enum_obj->variant;
        fprintf(out, "%s.%s",
               (d && d->name) ? d->name : "?",
               (d && vi < d->variant_count && d->variants[vi].name)
                   ? d->variants[vi].name : "?");
        size_t nf = (d && vi < d->variant_count) ? d->variants[vi].field_count : 0;
        if (nf == 1) {
            fprintf(out, "(");
            value_print_stream(out, v.as.enum_obj->fields[0]);
            fprintf(out, ")");
        } else if (nf > 1) {
            fprintf(out, "(");
            for (size_t i = 0; i < nf; i++) {
                if (i > 0) fprintf(out, ", ");
                value_print_stream(out, v.as.enum_obj->fields[i]);
            }
            fprintf(out, ")");
        }
    } break;
    case VAL_ENUM_DEF: fprintf(out, "<enum_def>"); break;
    case VAL_FN:     fprintf(out, "<fn>"); break;
    case VAL_OK:     fprintf(out, "ok("); value_print_stream(out, *v.as.ok_val.inner); fprintf(out, ")"); break;
    case VAL_ERR:    fprintf(out, "err("); value_print_stream(out, *v.as.err_val.inner); fprintf(out, ")"); break;
    case VAL_SOME:   fprintf(out, "some("); value_print_stream(out, *v.as.some_val.inner); fprintf(out, ")"); break;
    }
}

/* Public API: the print builtin and OPCODE_PRINT always write program output
 * to stdout. */
void value_print(Value v) { value_print_stream(stdout, v); }

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
    /* Handle cross-kind comparison between VAL_ENUM and VAL_ENUM_DATA:
     * pattern constants are VAL_ENUM but runtime values are VAL_ENUM_DATA. */
    if (a.kind != b.kind) {
        if ((a.kind == VAL_ENUM && b.kind == VAL_ENUM_DATA) ||
            (a.kind == VAL_ENUM_DATA && b.kind == VAL_ENUM)) {
            const char *an, *av, *bn, *bv;
            if (a.kind == VAL_ENUM) {
                an = a.as.enum_val.enum_name;
                av = a.as.enum_val.variant_name;
                EnumObj *y = b.as.enum_obj;
                if (!y || !y->def) return false;
                bn = y->def->name;
                bv = (y->variant < y->def->variant_count)
                    ? y->def->variants[y->variant].name : NULL;
            } else {
                EnumObj *x = a.as.enum_obj;
                if (!x || !x->def) return false;
                an = x->def->name;
                av = (x->variant < x->def->variant_count)
                    ? x->def->variants[x->variant].name : NULL;
                bn = b.as.enum_val.enum_name;
                bv = b.as.enum_val.variant_name;
            }
            if (!an || !av || !bn || !bv) return false;
            return strcmp(an, bn) == 0 && strcmp(av, bv) == 0;
        }
        return false;
    }
    switch (a.kind) {
    case VAL_NIL:    return true;
    case VAL_BOOL:   return a.as.bool_val == b.as.bool_val;
    case VAL_INT:    return a.as.int_val == b.as.int_val;
    case VAL_FLOAT:  return a.as.float_val == b.as.float_val;
    case VAL_STRING:
        if (a.as.string_val.str == b.as.string_val.str) return true;
        if (a.as.string_val.len != b.as.string_val.len) return false;
        /* Two empty strings are equal even when one came from a literal
         * (interned with str == NULL) and the other from a concatenation
         * (allocated, len 0). The old NULL check returned false here, so
         * `"" == "" + ""` diverged from the zig VM (M3 differential fuzz). */
        if (a.as.string_val.len == 0) return true;
        if (!a.as.string_val.str || !b.as.string_val.str) return false;
        return memcmp(a.as.string_val.str, b.as.string_val.str,
                      a.as.string_val.len) == 0;
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
    case VAL_ENUM_DEF:  return a.as.enum_def == b.as.enum_def;
    case VAL_ENUM: {
        const char *an = a.as.enum_val.enum_name;
        const char *bn = b.as.enum_val.enum_name;
        const char *av = a.as.enum_val.variant_name;
        const char *bv = b.as.enum_val.variant_name;
        if (an == av && bn == bv) return true;
        if (!an || !bn || !av || !bv) return false;
        return strcmp(an, bn) == 0 && strcmp(av, bv) == 0;
    }
    case VAL_ENUM_DATA: {
        /* Structural: same enum, same tag, equal payloads. */
        EnumObj *x = a.as.enum_obj;
        EnumObj *y = b.as.enum_obj;
        if (x == y) return true;
        if (!x || !y || !x->def || !y->def) return false;
        if (strcmp(x->def->name, y->def->name) != 0) return false;
        if (x->variant != y->variant) return false;
        size_t nf = (x->variant < x->def->variant_count)
            ? x->def->variants[x->variant].field_count : 0;
        for (size_t i = 0; i < nf; i++) {
            if (!value_eq(x->fields[i], y->fields[i])) return false;
        }
        return true;
    }
    case VAL_FN:     return a.as.fn_val == b.as.fn_val;
    case VAL_OK:     return value_eq(*a.as.ok_val.inner, *b.as.ok_val.inner);
    case VAL_ERR:    return value_eq(*a.as.err_val.inner, *b.as.err_val.inner);
    case VAL_SOME:   return value_eq(*a.as.some_val.inner, *b.as.some_val.inner);
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

static bool vm_push_frame(VM *vm, const Instruction *ret_ip, uint16_t base, uint32_t line) {
    if (vm->frame_count >= VM_CALL_DEPTH) {
        /* `line` is the call site, so the diagnostic points at the recursion
         * instead of at line 0 (which is what the frame layer could see by
         * itself, and useless to anyone reading the message). */
        vm->error_msg = "call depth exceeded";
        vm->error_line = line;
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

/* Builtin `len(x) -> i64` (DEC-013, research/028 PR1): arrays and strings.
 * Arity and receiver wording mirror the OPCODE_LEN handler (`expected 1
 * arguments but got %u` = OPCODE_CALL's phrasing, `cannot take length of %s`
 * = OPCODE_LEN's) so all four routes report identical text. Returns false
 * with the VM error set. */
static bool builtin_len(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    if (argc != 1) {
        vm_runtime_error(vm, line, "expected 1 arguments but got %u", (unsigned)argc);
        return false;
    }
    Value obj = args[0];
    size_t n;
    if (obj.kind == VAL_ARRAY && obj.as.array_val) {
        n = obj.as.array_val->len;
    } else if (obj.kind == VAL_STRING) {
        /* `""` interns to {str: NULL, len: 0} (string_intern returns the empty
         * pair for len 0), so the NULL-ness of the pointer says nothing about
         * emptiness — only VAL_NIL (an uninitialized `let s: string`) is nil. */
        n = obj.as.string_val.len;
    } else {
        vm_runtime_error(vm, line, "cannot take length of %s", type_name(obj));
        return false;
    }
    *out = value_int((int64_t)n);
    return true;
}

/* Builtin `to_string(x) -> string` (DEC-014, research/028 PR2): integers
 * only, rendered with the conversion `print` already uses (`%ld`), so
 * `print(to_string(n))` is byte-identical to `print(n)` on every route. A
 * non-int value reports the same defensive text everywhere. */
static bool builtin_to_string(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    if (argc != 1) {
        vm_runtime_error(vm, line, "expected 1 arguments but got %u", (unsigned)argc);
        return false;
    }
    Value v = args[0];
    if (v.kind != VAL_INT) {
        vm_runtime_error(vm, line, "to_string expects an int, got %s", type_name(v));
        return false;
    }
    char buf[32]; /* int64 min is 20 chars + sign */
    int n = snprintf(buf, sizeof(buf), "%ld", (long)v.as.int_val);
    if (n < 0) {
        vm_runtime_error(vm, line, "to_string conversion failed");
        return false;
    }
    *out = value_string(arena_strdup(vm->arena, buf, (size_t)n), (size_t)n);
    return true;
}

/* Builtin `read_file(path) -> string` (DEC-014, research/028 PR2). Every
 * failure mode collapses into one runtime error so the four routes report
 * byte-identical text; the path is copied NUL-terminated into the arena first
 * because an interned string may be {NULL, 0} and a slice is not
 * NUL-terminated. The buffer is arena-allocated: compiler phases never free
 * (invariant 5). */
static bool builtin_read_file(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    if (argc != 1) {
        vm_runtime_error(vm, line, "expected 1 arguments but got %u", (unsigned)argc);
        return false;
    }
    Value p = args[0];
    if (p.kind != VAL_STRING) {
        vm_runtime_error(vm, line, "expected string path, got %s", type_name(p));
        return false;
    }
    size_t plen = p.as.string_val.len;
    char *path = arena_alloc(vm->arena, plen + 1, _Alignof(char));
    if (!path) {
        vm_runtime_error(vm, line, "out of memory reading '%s'", p.as.string_val.str ? p.as.string_val.str : "");
        return false;
    }
    if (plen > 0 && p.as.string_val.str) memcpy(path, p.as.string_val.str, plen);
    path[plen] = '\0';

    FILE *f = fopen(path, "rb");
    if (!f) {
        vm_runtime_error(vm, line, "cannot open file '%s'", path);
        return false;
    }
    /* Chunked read (no fseek/ftell: a length-prefix route may not be seekable
     * and /proc-style files report size 0). Grows by doubling in the arena. */
    size_t cap = 4096, len = 0;
    char *buf = arena_alloc(vm->arena, cap, _Alignof(char));
    if (!buf) { fclose(f); vm_runtime_error(vm, line, "out of memory reading '%s'", path); return false; }
    for (;;) {
        if (len == cap) {
            char *bigger = arena_alloc(vm->arena, cap * 2, _Alignof(char));
            if (!bigger) { fclose(f); vm_runtime_error(vm, line, "out of memory reading '%s'", path); return false; }
            memcpy(bigger, buf, len);
            buf = bigger;
            cap *= 2;
        }
        size_t got = fread(buf + len, 1, cap - len, f);
        len += got;
        if (got == 0) break; /* EOF or read error */
    }
    bool io_err = ferror(f) != 0;
    fclose(f);
    if (io_err) {
        vm_runtime_error(vm, line, "cannot open file '%s'", path);
        return false;
    }
    buf[len] = '\0';
    *out = value_string(buf, len);
    return true;
}

/* Builtin `ord(s) -> i64` (DEC-018, research/028 M2a): the value of the
 * FIRST BYTE of `s` (0..255) — a byte, not a codepoint, because `s[i]`
 * already hands back a 1-byte string (DEC-013) and the seed's lexer walks
 * bytes, so the four routes and a future lexer.astra all agree. An empty
 * string has no first byte: it reports instead of reading past the buffer. */
static bool builtin_ord(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    if (argc != 1) {
        vm_runtime_error(vm, line, "expected 1 arguments but got %u", (unsigned)argc);
        return false;
    }
    Value s = args[0];
    if (s.kind != VAL_STRING) {
        vm_runtime_error(vm, line, "ord expects a string, got %s", type_name(s));
        return false;
    }
    if (s.as.string_val.len == 0) {
        vm_runtime_error(vm, line, "ord() of empty string");
        return false;
    }
    *out = value_int((int64_t)(unsigned char)s.as.string_val.str[0]);
    return true;
}

/* Builtin `substr(s, start, len) -> string` (DEC-018, research/028 M2a):
 * `len` bytes of `s` from `start`, or a runtime error — no silent clipping,
 * so a caller that asked for more than the string holds learns it here (the
 * same contract as `s[i]`, whose OOB is an error too). The slice borrows the
 * source bytes like `s[i]` does: every string is arena-allocated (invariant
 * 5) and immutable, so the pointer outlives the expression. */
static bool builtin_substr(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    if (argc != 3) {
        vm_runtime_error(vm, line, "expected 3 arguments but got %u", (unsigned)argc);
        return false;
    }
    Value sv = args[0], st = args[1], ln = args[2];
    if (sv.kind != VAL_STRING) {
        vm_runtime_error(vm, line, "substr expects a string, got %s", type_name(sv));
        return false;
    }
    /* Both integer parameters word their rejection the same way, so the
     * emitter's per-argument guards can reuse the text verbatim. */
    if (st.kind != VAL_INT) {
        vm_runtime_error(vm, line, "substr expects an int, got %s", type_name(st));
        return false;
    }
    if (ln.kind != VAL_INT) {
        vm_runtime_error(vm, line, "substr expects an int, got %s", type_name(ln));
        return false;
    }
    size_t slen = sv.as.string_val.len;
    int64_t start = st.as.int_val, n = ln.as.int_val;
    if (start < 0 || (uint64_t)start > slen) {
        vm_runtime_error(vm, line, "substr start %ld out of bounds (len %zu)",
                         (long)start, slen);
        return false;
    }
    /* `start <= slen` is established above, so `slen - start` is the exact
     * room left and the comparison can never overflow (a huge `n` such as
     * 9223372036854775807 must fail, not wrap). */
    if (n < 0 || n > (int64_t)(slen - (size_t)start)) {
        vm_runtime_error(vm, line, "substr length %ld out of bounds (len %zu)",
                         (long)n, slen);
        return false;
    }
    *out = value_string(sv.as.string_val.str ? sv.as.string_val.str + start : NULL,
                        (size_t)n);
    return true;
}

/* Builtin `push(arr, value) -> array` (DEC-019, research/028 M2b): a NEW
 * array with `value` appended — the caller rebinds (`a = push(a, x)`), so
 * the old array is untouched for everyone who still holds it. In-place
 * growth is possible here (the arena just bumps), but not in the LLVM
 * backend, whose array object stores its elements inline and is shared by
 * every binding (DEC-019: growing would relocate the object and leave every
 * alias pointing at the old one). The copy is O(n) — the arena has no
 * realloc — so n pushes are O(n²); honest for the token-buffer scale this
 * stdlib targets.
 *
 * The element must match the array's element kind (Astra-0 arrays are
 * homogeneous and the checker enforces it everywhere except an `unknown`
 * builtin parameter): `push` compares against the first element, the same
 * representative the print/eq paths use, and reports with the checker's
 * phrasing (`array element N has type X, expected Y`). */
static bool builtin_push(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    if (argc != 2) {
        vm_runtime_error(vm, line, "expected 2 arguments but got %u", (unsigned)argc);
        return false;
    }
    Value av = args[0], v = args[1];
    if (av.kind != VAL_ARRAY || !av.as.array_val) {
        vm_runtime_error(vm, line, "push expects an array, got %s", type_name(av));
        return false;
    }
    ArrayObj *a = av.as.array_val;
    if (a->len > 0 && a->elems[0].kind != v.kind) {
        vm_runtime_error(vm, line, "push element has type %s, expected %s",
                         type_name(v), type_name(a->elems[0]));
        return false;
    }
    ArrayObj *na = array_obj_new(vm->arena, a->len + 1);
    if (!na) {
        vm_runtime_error(vm, line, "out of memory pushing to array");
        return false;
    }
    for (size_t i = 0; i < a->len; i++) na->elems[i] = a->elems[i];
    na->elems[a->len] = v;
    *out = value_array(na);
    return true;
}

/* ---------- builtin: copy (DEC-027, fase E2) ----------
 *
 * Deep structural copy: arrays/structs/enums/wrapped optionals recurse,
 * strings and unit variants are shared (immutable), plain fns are shared
 * (no state) and closures clone the shell with a deep env (the
 * OPCODE_CLOSURE template shares code/constants). Builtin markers are
 * shared BY POINTER — OPCODE_CALL dispatches them by identity
 * (`param_count == 255 && code == NULL`), so cloning one would make it
 * undispatchable. The walk is depth-capped: cycles are constructible
 * (`n.kid = some(n)`, DEC-027) and an unguarded walk would diverge. */
#define COPY_MAX_DEPTH 64

/* Returns 0 ok, 1 depth limit, 2 out of memory. */
static int value_copy(VM *vm, Value v, Value *out, int depth) {
    if (depth > COPY_MAX_DEPTH) return 1;
    switch (v.kind) {
    case VAL_ARRAY: {
        ArrayObj *a = v.as.array_val;
        if (!a) { *out = v; return 0; }
        ArrayObj *na = array_obj_new(vm->arena, a->len);
        if (!na) return 2;
        for (size_t i = 0; i < a->len; i++) {
            int rc = value_copy(vm, a->elems[i], &na->elems[i], depth + 1);
            if (rc) return rc;
        }
        *out = value_array(na);
        return 0;
    }
    case VAL_STRUCT: {
        StructObj *st = v.as.struct_val;
        if (!st) { *out = v; return 0; }
        StructObj *ns = struct_obj_new(vm->arena, st->def);
        if (!ns) return 2;
        size_t n = st->def ? st->def->field_count : 0;
        for (size_t i = 0; i < n; i++) {
            int rc = value_copy(vm, st->fields[i], &ns->fields[i], depth + 1);
            if (rc) return rc;
        }
        *out = value_struct(ns);
        return 0;
    }
    case VAL_ENUM_DATA: {
        EnumObj *eo = v.as.enum_obj;
        if (!eo) { *out = v; return 0; }
        EnumObj *ne = enum_obj_new(vm->arena, eo->def, eo->variant, eo->fields);
        if (!ne) return 2;
        size_t n = (eo->def && eo->variant < eo->def->variant_count)
                 ? eo->def->variants[eo->variant].field_count : 0;
        for (size_t i = 0; i < n; i++) {
            int rc = value_copy(vm, eo->fields[i], &ne->fields[i], depth + 1);
            if (rc) return rc;
        }
        *out = (Value){ .kind = VAL_ENUM_DATA, .as = { .enum_obj = ne } };
        return 0;
    }
    case VAL_FN: {
        FnObj *f = v.as.fn_val;
        /* Builtin markers (code == NULL) and stateless fns: share. */
        if (!f || f->env == NULL || f->env_len == 0) { *out = v; return 0; }
        FnObj *clos = arena_alloc_zero(vm->arena, sizeof(FnObj), _Alignof(FnObj));
        if (!clos) return 2;
        clos->code = f->code;
        clos->code_len = f->code_len;
        clos->constants = f->constants;
        clos->const_len = f->const_len;
        clos->param_count = f->param_count;
        clos->local_count = f->local_count;
        clos->env_len = f->env_len;
        clos->env = arena_new_array(vm->arena, Value, f->env_len);
        if (!clos->env) return 2;
        for (uint8_t i = 0; i < f->env_len; i++) {
            int rc = value_copy(vm, f->env[i], &clos->env[i], depth + 1);
            if (rc) return rc;
        }
        *out = value_fn(clos);
        return 0;
    }
    case VAL_OK: {
        Value inner;
        int rc = value_copy(vm, *v.as.ok_val.inner, &inner, depth + 1);
        if (rc) return rc;
        *out = value_ok(vm->arena, inner);
        return 0;
    }
    case VAL_ERR: {
        Value inner;
        int rc = value_copy(vm, *v.as.err_val.inner, &inner, depth + 1);
        if (rc) return rc;
        *out = value_err(vm->arena, inner);
        return 0;
    }
    case VAL_SOME: {
        Value inner;
        int rc = value_copy(vm, *v.as.some_val.inner, &inner, depth + 1);
        if (rc) return rc;
        *out = value_some(vm->arena, inner);
        return 0;
    }
    default:
        /* scalars, strings, unit variants, defs, nil: values or immutable */
        *out = v;
        return 0;
    }
}

/* `copy(x) -> x` — only reachable as the method `x.copy()` (DEC-027):
 * typecheck rejects every scalar receiver and the bare form. */
static bool builtin_copy(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    if (argc != 1) {
        vm_runtime_error(vm, line, "expected 1 arguments but got %u", (unsigned)argc);
        return false;
    }
    int rc = value_copy(vm, args[0], out, 0);
    if (rc == 1) {
        vm_runtime_error(vm, line, "copy depth limit exceeded");
        return false;
    }
    if (rc == 2) {
        vm_runtime_error(vm, line, "out of memory copying value");
        return false;
    }
    return true;
}

/* Builtin `str_to_int(s) -> i64` (DEC-019, research/028 M2b): the decimal
 * rendering `to_string` produces, round-tripping `str_to_int(to_string(n))`
 * for every int the language can name. A leading `-` is part of that
 * rendering, so it is accepted; `+`, whitespace, `_` and `0x`/`0b`/`0o` are
 * not (the lexer owns those spellings and its literal would fail the same
 * way for a space or a `+`). Anything else — including the empty string — is
 * a runtime error naming the offending input, and the magnitude is capped at
 * INT64_MAX exactly like the lexer's `accumulate_digit`, so
 * `-9223372036854775808` fails just as the source literal does. */
static bool builtin_str_to_int(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    if (argc != 1) {
        vm_runtime_error(vm, line, "expected 1 arguments but got %u", (unsigned)argc);
        return false;
    }
    Value s = args[0];
    if (s.kind != VAL_STRING) {
        vm_runtime_error(vm, line, "str_to_int expects a string, got %s", type_name(s));
        return false;
    }
    const char *p = s.as.string_val.str;
    size_t len = s.as.string_val.len, i = 0;
    bool neg = false;
    if (i < len && p[i] == '-') { neg = true; i++; }
    uint64_t acc = 0;
    bool any = false;
    /* The offending literal is DISPLAYED truncated to 64 bytes (and, like
     * every %s in these runtimes, up to the first NUL): the four routes must
     * word an arbitrary input identically — the seed's vsnprintf, the C
     * backend's astra_errorf and the LLVM snprintf each cap their own buffer
     * at a different size otherwise. */
    for (; i < len; i++) {
        char c = p[i];
        if (c < '0' || c > '9') {
            vm_runtime_error(vm, line, "str_to_int: invalid integer literal '%.*s'",
                             (int)(len < 64 ? len : 64), p ? p : "");
            return false;
        }
        any = true;
        uint64_t d = (uint64_t)(c - '0');
        if (acc > ((uint64_t)INT64_MAX - d) / 10) {
            vm_runtime_error(vm, line, "str_to_int: integer literal is out of range for i64");
            return false;
        }
        acc = acc * 10 + d;
    }
    if (!any) {
        vm_runtime_error(vm, line, "str_to_int: invalid integer literal '%.*s'",
                         (int)(len < 64 ? len : 64), p ? p : "");
        return false;
    }
    *out = value_int(neg ? -(int64_t)acc : (int64_t)acc);
    return true;
}

/* Builtin `chr(i) -> string` (DEC-020, research/028 M3): the 1-byte string
 * whose FIRST BYTE is `i` (0..255) — the inverse of `ord` (DEC-018), byte and
 * not codepoint, because `s[i]` hands back a 1-byte string and the seed's
 * lexer walks bytes; a future lexer.astra emits strings with it. Out of range
 * is a runtime error (`chr value N out of bounds (0..255)`), never a masked
 * low byte: a caller that passed 300 meant something else and must learn it
 * here (same no-silent-clipping contract as `substr` bounds, DEC-018). */
static bool builtin_chr(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    if (argc != 1) {
        vm_runtime_error(vm, line, "expected 1 arguments but got %u", (unsigned)argc);
        return false;
    }
    Value i = args[0];
    if (i.kind != VAL_INT) {
        vm_runtime_error(vm, line, "chr expects an int, got %s", type_name(i));
        return false;
    }
    int64_t code = i.as.int_val;
    if (code < 0 || code > 255) {
        vm_runtime_error(vm, line, "chr value %ld out of bounds (0..255)", (long)code);
        return false;
    }
    char b = (char)(unsigned char)code;
    *out = value_string(arena_strdup(vm->arena, &b, 1), 1);
    return true;
}

/* Builtin `read_line() -> string` (DEC-020, research/028 M3): one line of
 * STANDARD INPUT up to (not including) the trailing `\n`, or a runtime error
 * `end of input` on EOF with no data. stdin is read a byte at a time through
 * fgetc so the SAME buffer serves every consecutive call (a lexer reads the
 * source line by line): fread-by-blocks would consume the bytes of the NEXT
 * line into a discarded buffer. A final line without `\n` returns what it has
 * (standard reader convention); an empty line yields "". On a closed or
 * /dev/null stdin (every conformance harness) the first call is EOF, i.e. the
 * deterministic `end of input` error the conformance case pins. */
static bool builtin_read_line(VM *vm, Value *args, uint8_t argc, uint32_t line, Value *out) {
    (void)args;
    if (argc != 0) {
        vm_runtime_error(vm, line, "expected 0 arguments but got %u", (unsigned)argc);
        return false;
    }
    if (vm->stdin_buf == NULL) {
        vm->stdin_cap = 4096;
        vm->stdin_buf = arena_alloc(vm->arena, vm->stdin_cap, _Alignof(char));
        if (!vm->stdin_buf) {
            vm_runtime_error(vm, line, "out of memory reading stdin");
            return false;
        }
    }
    size_t len = 0;
    int c;
    while ((c = fgetc(stdin)) != EOF && c != '\n') {
        if (len == vm->stdin_cap) {
            char *bigger = arena_alloc(vm->arena, vm->stdin_cap * 2, _Alignof(char));
            if (!bigger) {
                vm_runtime_error(vm, line, "out of memory reading stdin");
                return false;
            }
            memcpy(bigger, vm->stdin_buf, len);
            vm->stdin_buf = bigger;
            vm->stdin_cap *= 2;
        }
        vm->stdin_buf[len++] = (char)c;
    }
    if (c == EOF && len == 0 && ferror(stdin) == 0) {
        vm_runtime_error(vm, line, "end of input");
        return false;
    }
    *out = value_string(vm->stdin_buf, len);
    return true;
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
    case OPCODE_BIT_AND:      return "BIT_AND";
    case OPCODE_BIT_OR:       return "BIT_OR";
    case OPCODE_BIT_XOR:      return "BIT_XOR";
    case OPCODE_SHL:          return "SHL";
    case OPCODE_SHR:          return "SHR";
    case OPCODE_BIT_NOT:      return "BIT_NOT";
    case OPCODE_JUMP:         return "JUMP";
    case OPCODE_JUMP_IF_FALSE:return "JUMP_IF_FALSE";
    case OPCODE_JUMP_IF_TRUE: return "JUMP_IF_TRUE";
    case OPCODE_NEW_ARRAY:    return "NEW_ARRAY";
    case OPCODE_INDEX:        return "INDEX";
    case OPCODE_LEN:          return "LEN";
    case OPCODE_NEW_STRUCT:   return "NEW_STRUCT";
    case OPCODE_GET_FIELD:    return "GET_FIELD";
    case OPCODE_SET_FIELD:    return "SET_FIELD";
    case OPCODE_SET_INDEX:    return "SET_INDEX";
    case OPCODE_NEW_ENUM:     return "NEW_ENUM";
    case OPCODE_GET_ENUM_FIELD: return "GET_ENUM_FIELD";
    case OPCODE_CALL:         return "CALL";
    case OPCODE_RET:          return "RET";
    case OPCODE_CLOSURE:      return "CLOSURE";
    case OPCODE_GET_CAPTURE:  return "GET_CAPTURE";
    case OPCODE_PRINT:        return "PRINT";
    case OPCODE_WRAP_OK:      return "WRAP_OK";
    case OPCODE_WRAP_ERR:     return "WRAP_ERR";
    case OPCODE_WRAP_SOME:    return "WRAP_SOME";
    case OPCODE_HALT:         return "HALT";
    case OPCODE_TRY_UNWRAP:   return "TRY_UNWRAP";
    case OPCODE_TAG_IS:       return "TAG_IS";
    case OPCODE_UNWRAP:       return "UNWRAP";
    case OPCODE_MATCH_NONE:   return "MATCH_NONE";
    default:                  return "???";
    }
}

/* Dump a module's bytecode.
 *
 * Public because it is the compiler's own view of a program: `--dump-bytecode`
 * and ASTRA_DUMP_VM both go through here, so there is exactly one place that
 * decides how an instruction and its operands are rendered — constants
 * included (value_print_stream). Everything goes to stderr so program output
 * on stdout never interleaves with diagnostics, matching the Zig compiler. */
void vm_dump_bytecode(const Instruction *code, size_t code_len,
                      const Value *constants, size_t const_len) {
    fprintf(stderr, "=== Bytecode (%zu instructions, %zu constants) ===\n",
            code_len, const_len);
    for (size_t i = 0; i < code_len; i++) {
        fprintf(stderr, "  [%3zu] %-16s", i, opname(code[i].op));
        switch (code[i].op) {
        case OPCODE_CONST:
        case OPCODE_GET_GLOBAL:
        case OPCODE_SET_GLOBAL:
            fprintf(stderr, " %u", code[i].arg.index);
            if (code[i].op == OPCODE_CONST && constants && code[i].arg.index < const_len) {
                fprintf(stderr, " (");
                value_print_stream(stderr, constants[code[i].arg.index]);
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
        case OPCODE_CLOSURE:
            /* (fn_const << 8) | capture_count, same packing style as NEW_ENUM */
            fprintf(stderr, " fn=%u captures=%u", code[i].arg.index >> 8,
                    code[i].arg.index & 0xFF);
            break;
        case OPCODE_GET_CAPTURE:
            fprintf(stderr, " cap=%u", code[i].arg.index);
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

VMResult vm_run(VM *vm, const Instruction *code, size_t code_len,
                Value *constants, size_t const_len) {
    if (!vm || !code || code_len == 0) return VM_RUNTIME_ERROR;

    vm->code      = code;
    vm->code_len  = code_len;
    vm->constants = constants;
    vm->const_len = const_len;

    if (getenv("ASTRA_DUMP_VM")) {
        vm_dump_bytecode(code, code_len, constants, const_len);
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
            /* `base` is a stack *slot number* in [0, VM_STACK_SIZE), so it must
             * not be narrowed to 8 bits. CallFrame.base is already uint16_t, but
             * reading it through a uint8_t silently wrapped it at 256: any
             * program with ~127 nested calls (each frame takes at least the
             * callee slot plus one argument) then read the wrong stack slot and
             * returned a wrong value with no diagnostic at all — `f(127)` on a
             * simple recursive function failed with "cannot compare function and
             * int". Keeping the width also keeps the bound check below honest;
             * with a truncated base it compared against the wrong slot too. */
            uint16_t slot = (uint16_t)inst.arg.index;
            uint16_t base = vm->frame_count > 0 ? vm->frames[vm->frame_count - 1].base : 0;
            if (base + slot >= vm->sp) {
                vm_runtime_error(vm, line, "local variable at slot %u not initialized", slot);
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, vm->stack[base + slot])) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_SET_LOCAL: {
            /* Same 8-bit narrowing as GET_LOCAL above. */
            uint16_t slot = (uint16_t)inst.arg.index;
            uint16_t base = vm->frame_count > 0 ? vm->frames[vm->frame_count - 1].base : 0;
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
            const char *name = vm->constants[inst.arg.index].as.string_val.str;
            /* Check built-in globals (research/028 PR1: one branch per builtin) */
            if (name && strcmp(name, "print") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_print_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "len") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_len_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "to_string") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_to_string_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "read_file") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_read_file_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "ord") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_ord_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "substr") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_substr_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "push") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_push_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "str_to_int") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_str_to_int_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "chr") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_chr_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "read_line") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_read_line_fn))) return VM_RUNTIME_ERROR;
            } else if (name && strcmp(name, "copy") == 0) {
                if (!vm_push(vm, value_fn(vm->builtin_copy_fn))) return VM_RUNTIME_ERROR;
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
            const char *name = vm->constants[inst.arg.index].as.string_val.str;
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
                /* Wrapping arithmetic through uint64: the raw `+` was UB on
                 * overflow (UBSan reported it on a legal program) while zig
                 * defines the wrap with `+%` (audit §4.2). */
                if (!vm_push(vm, value_int((int64_t)((uint64_t)a.as.int_val + (uint64_t)b.as.int_val)))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float(a.as.float_val + b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_INT && b.kind == VAL_FLOAT) {
                if (!vm_push(vm, value_float((double)a.as.int_val + b.as.float_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_FLOAT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_float(a.as.float_val + (double)b.as.int_val))) return VM_RUNTIME_ERROR;
            } else if (a.kind == VAL_STRING && b.kind == VAL_STRING) {
                /* String concatenation (length-bounded: a NUL byte inside
                 * either operand must not truncate the result, audit §2.14) */
                size_t len_a = a.as.string_val.len;
                size_t len_b = b.as.string_val.len;
                char *buf = arena_alloc(vm->arena, len_a + len_b + 1, 1);
                if (!buf) {
                    vm_runtime_error(vm, line, "out of memory");
                    return VM_RUNTIME_ERROR;
                }
                /* An empty literal is interned with str == NULL (len 0): a
                 * zero-length memcpy from NULL is still UB per the nonnull
                 * attribute, and UBSan flagged it on `"" + ""` (M3
                 * differential fuzz). */
                if (len_a > 0) memcpy(buf, a.as.string_val.str, len_a);
                if (len_b > 0) memcpy(buf + len_a, b.as.string_val.str, len_b);
                buf[len_a + len_b] = '\0';
                if (!vm_push(vm, value_string(buf, len_a + len_b))) return VM_RUNTIME_ERROR;
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
                if (!vm_push(vm, value_int((int64_t)((uint64_t)a.as.int_val - (uint64_t)b.as.int_val)))) return VM_RUNTIME_ERROR;
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
                if (!vm_push(vm, value_int((int64_t)((uint64_t)a.as.int_val * (uint64_t)b.as.int_val)))) return VM_RUNTIME_ERROR;
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
                /* INT64_MIN / -1 traps the hardware (SIGFPE/ASan FPE) and no
                 * backend produced a diagnostic (audit §4.1). */
                if (a.as.int_val == INT64_MIN && b.as.int_val == -1) {
                    vm_runtime_error(vm, line, "integer overflow");
                    return VM_RUNTIME_ERROR;
                }
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
                /* Same hardware trap as DIV (audit §4.1). */
                if (a.as.int_val == INT64_MIN && b.as.int_val == -1) {
                    vm_runtime_error(vm, line, "integer overflow");
                    return VM_RUNTIME_ERROR;
                }
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
                /* Wrapping negation: -INT64_MIN is UB with a raw unary minus
                 * (audit §4.2); the uint64 wrap matches zig's `-%`. */
                if (!vm_push(vm, value_int((int64_t)(0u - (uint64_t)a.as.int_val)))) return VM_RUNTIME_ERROR;
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

        /* ---- Bitwise ---- */

        case OPCODE_BIT_AND: {
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_int(a.as.int_val & b.as.int_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "bitwise & requires integer operands");
                return VM_RUNTIME_ERROR;
            }
        } break;
        case OPCODE_BIT_OR: {
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_int(a.as.int_val | b.as.int_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "bitwise | requires integer operands");
                return VM_RUNTIME_ERROR;
            }
        } break;
        case OPCODE_BIT_XOR: {
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (!vm_push(vm, value_int(a.as.int_val ^ b.as.int_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "bitwise ^ requires integer operands");
                return VM_RUNTIME_ERROR;
            }
        } break;
        case OPCODE_SHL: {
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (b.as.int_val < 0 || b.as.int_val >= 64) {
                    vm_runtime_error(vm, line, "shift amount out of range (must be 0..63)");
                    return VM_RUNTIME_ERROR;
                }
                if (!vm_push(vm, value_int((uint64_t)a.as.int_val << (int)b.as.int_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "bitwise << requires integer operands");
                return VM_RUNTIME_ERROR;
            }
        } break;
        case OPCODE_SHR: {
            Value b = vm_pop(vm);
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT && b.kind == VAL_INT) {
                if (b.as.int_val < 0 || b.as.int_val >= 64) {
                    vm_runtime_error(vm, line, "shift amount out of range (must be 0..63)");
                    return VM_RUNTIME_ERROR;
                }
                if (!vm_push(vm, value_int(a.as.int_val >> (int)b.as.int_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "bitwise >> requires integer operands");
                return VM_RUNTIME_ERROR;
            }
        } break;
        case OPCODE_BIT_NOT: {
            Value a = vm_pop(vm);
            if (a.kind == VAL_INT) {
                if (!vm_push(vm, value_int(~a.as.int_val))) return VM_RUNTIME_ERROR;
            } else {
                vm_runtime_error(vm, line, "bitwise ~ requires integer operand");
                return VM_RUNTIME_ERROR;
            }
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
            if (obj.kind == VAL_STRING) {
                /* DEC-013: `s[i]` reads byte i as a one-byte string. The
                 * receiver/int/bounds order and every message mirror the
                 * array arm below so the four routes stay comparable. `""` is
                 * VAL_STRING with a NULL pointer and len 0 (string_intern), so
                 * the kind alone decides the receiver — `""[0]` is simply out
                 * of bounds (len 0), like the C backend says. */
                if (idx.kind != VAL_INT) {
                    vm_runtime_error(vm, line, "array index must be int, got %s", type_name(idx));
                    return VM_RUNTIME_ERROR;
                }
                size_t slen = obj.as.string_val.len;
                if (idx.as.int_val < 0 || (uint64_t)idx.as.int_val >= slen) {
                    vm_runtime_error(vm, line, "index %ld out of bounds (len %zu)",
                        (long)idx.as.int_val, slen);
                    return VM_RUNTIME_ERROR;
                }
                if (!vm_push(vm,
                        value_string(obj.as.string_val.str + idx.as.int_val, 1)))
                    return VM_RUNTIME_ERROR;
            } else if (obj.kind != VAL_ARRAY || !obj.as.array_val) {
                vm_runtime_error(vm, line, "cannot index %s", type_name(obj));
                return VM_RUNTIME_ERROR;
            } else {
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
            }
        } break;

        case OPCODE_LEN: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on len");
                return VM_RUNTIME_ERROR;
            }
            Value obj = vm_pop(vm);
            size_t n = 0;
            if (obj.kind == VAL_ARRAY && obj.as.array_val) n = obj.as.array_val->len;
            /* `""` is VAL_STRING with a NULL pointer and len 0 (string_intern),
             * so only the kind — not pointer NULL-ness — decides emptiness. */
            else if (obj.kind == VAL_STRING) n = obj.as.string_val.len;
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

        /* Store into an aggregate *element*, not into a binding: `xs[i] = v`.
         * The array is a shared handle, so the write goes through the handle
         * and is visible to every copy of it (see PHASE1_PROGRESS §3bis). */
        case OPCODE_SET_INDEX: {
            if (vm->sp < 3) {
                vm_runtime_error(vm, line, "stack underflow on set_index");
                return VM_RUNTIME_ERROR;
            }
            Value val = vm_pop(vm);
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
            arr->elems[idx.as.int_val] = val;
            if (!vm_push(vm, val)) return VM_RUNTIME_ERROR;
        } break;

        /* Store into a struct *field*: `p.x = v`. Like SET_INDEX, the struct
         * is a shared handle and the write is visible through every copy. */
        case OPCODE_SET_FIELD: {
            if (inst.arg.index >= vm->const_len) {
                vm_runtime_error(vm, line, "field name index %u out of range", inst.arg.index);
                return VM_RUNTIME_ERROR;
            }
            if (vm->sp < 2) {
                vm_runtime_error(vm, line, "stack underflow on set_field");
                return VM_RUNTIME_ERROR;
            }
            Value val = vm_pop(vm);
            Value obj = vm_pop(vm);
            const char *field = vm->constants[inst.arg.index].as.string_val.str;
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
            s->fields[found] = val;
            if (!vm_push(vm, val)) return VM_RUNTIME_ERROR;
        } break;

        /* Construct a data-carrying enum value. The operand packs the
         * variant tag and the payload count: `(variant << 16) | count`. The
         * layout arrives as a constant and is cloned per value. */
        case OPCODE_NEW_ENUM: {
            size_t n = inst.arg.index & 0xFFFF;
            size_t variant = inst.arg.index >> 16;
            if (vm->sp < n + 1) {
                vm_runtime_error(vm, line, "stack underflow building enum");
                return VM_RUNTIME_ERROR;
            }
            Value def_val = vm->stack[vm->sp - n - 1];
            if (def_val.kind != VAL_ENUM_DEF || !def_val.as.enum_def) {
                vm_runtime_error(vm, line, "invalid enum layout on stack");
                return VM_RUNTIME_ERROR;
            }
            const EnumDef *def = def_val.as.enum_def;
            if (variant >= def->variant_count) {
                vm_runtime_error(vm, line, "enum '%s' has no variant %zu",
                    def->name ? def->name : "?", variant);
                return VM_RUNTIME_ERROR;
            }
            if (n != def->variants[variant].field_count) {
                vm_runtime_error(vm, line,
                    "variant '%s.%s' expects %zu fields, got %zu",
                    def->name ? def->name : "?",
                    def->variants[variant].name ? def->variants[variant].name : "?",
                    def->variants[variant].field_count, n);
                return VM_RUNTIME_ERROR;
            }
            EnumObj *obj = enum_obj_new(vm->arena, def, variant,
                                        &vm->stack[vm->sp - n]);
            vm->sp = (uint16_t)(vm->sp - n - 1);
            if (!vm_push(vm, value_enum_with_payload(obj))) return VM_RUNTIME_ERROR;
        } break;

        /* Extract a payload field from a data-carrying enum by numeric index.
         * The operand is the field index (0-based). */
        case OPCODE_GET_ENUM_FIELD: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on get_enum_field");
                return VM_RUNTIME_ERROR;
            }
            Value obj = vm_pop(vm);
            if (obj.kind != VAL_ENUM_DATA || !obj.as.enum_obj) {
                vm_runtime_error(vm, line, "cannot extract field from %s", type_name(obj));
                return VM_RUNTIME_ERROR;
            }
            EnumObj *eo = obj.as.enum_obj;
            size_t fi = inst.arg.index;
            const EnumDef *def = eo->def;
            size_t nf = (def && eo->variant < def->variant_count)
                ? def->variants[eo->variant].field_count : 0;
            if (fi >= nf) {
                vm_runtime_error(vm, line, "enum field index %zu out of range (have %zu)", fi, nf);
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, eo->fields[fi])) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_GET_FIELD: {
            if (inst.arg.index >= vm->const_len) {
                vm_runtime_error(vm, line, "field name index %u out of range", inst.arg.index);
                return VM_RUNTIME_ERROR;
            }
            Value obj = vm_pop(vm);
            const char *field = vm->constants[inst.arg.index].as.string_val.str;
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

            /* Handle built-in functions (param_count == 255), one arm per
             * builtin: GET_GLOBAL resolved the name to its own marker, so
             * pointer identity is the dispatch key (research/028 §1.3 B). */
            if (fn->param_count == 255 && fn->code == NULL) {
                Value result;
                if (fn == vm->builtin_len_fn) {
                    if (!builtin_len(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else if (fn == vm->builtin_to_string_fn) {
                    if (!builtin_to_string(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else if (fn == vm->builtin_read_file_fn) {
                    if (!builtin_read_file(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else if (fn == vm->builtin_ord_fn) {
                    if (!builtin_ord(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else if (fn == vm->builtin_substr_fn) {
                    if (!builtin_substr(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else if (fn == vm->builtin_push_fn) {
                    if (!builtin_push(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else if (fn == vm->builtin_str_to_int_fn) {
                    if (!builtin_str_to_int(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else if (fn == vm->builtin_chr_fn) {
                    if (!builtin_chr(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else if (fn == vm->builtin_read_line_fn) {
                    if (!builtin_read_line(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else if (fn == vm->builtin_copy_fn) {
                    if (!builtin_copy(vm, &vm->stack[fn_idx + 1], argc, line, &result))
                        return VM_RUNTIME_ERROR;
                } else {
                    result = builtin_print(&vm->stack[fn_idx + 1], argc);
                }
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
            if (!vm_push_frame(vm, ip + 1, base, line)) return VM_RUNTIME_ERROR;

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
                            value_print_stream(stderr, fn->constants[fn->code[di].arg.index]);
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
                    case OPCODE_CLOSURE:
                        fprintf(stderr, " fn=%u captures=%u", fn->code[di].arg.index >> 8,
                                fn->code[di].arg.index & 0xFF);
                        break;
                    case OPCODE_GET_CAPTURE:
                        fprintf(stderr, " cap=%u", fn->code[di].arg.index);
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

        case OPCODE_CLOSURE: {
            /* operand: (fn_const << 8) | capture_count. Pop the captured
             * values (pushed in capture order by the emitter), clone the
             * template FnObj, and attach them as env. Capture-by-value
             * (ARCHITECTURE.md §30.5): the env holds the values as they were
             * at creation time. The clone shares code/constants pointers, so
             * only the shell is arena-allocated. */
            uint32_t packed   = inst.arg.index;
            uint32_t fn_const = packed >> 8;
            uint8_t  n_cap    = (uint8_t)(packed & 0xFF);
            if (fn_const >= vm->const_len ||
                vm->constants[fn_const].kind != VAL_FN ||
                !vm->constants[fn_const].as.fn_val) {
                vm_runtime_error(vm, line, "closure template is not a function");
                return VM_RUNTIME_ERROR;
            }
            if (vm->sp < n_cap) {
                vm_runtime_error(vm, line, "not enough captured values on stack");
                return VM_RUNTIME_ERROR;
            }
            FnObj *tmpl = vm->constants[fn_const].as.fn_val;
            FnObj *clos = arena_alloc_zero(vm->arena, sizeof(FnObj), _Alignof(FnObj));
            if (!clos) {
                vm_runtime_error(vm, line, "out of memory allocating closure");
                return VM_RUNTIME_ERROR;
            }
            clos->code       = tmpl->code;
            clos->code_len   = tmpl->code_len;
            clos->constants  = tmpl->constants;
            clos->const_len  = tmpl->const_len;
            clos->param_count = tmpl->param_count;
            clos->local_count = tmpl->local_count;
            clos->env_len    = n_cap;
            clos->env        = n_cap > 0
                ? arena_new_array(vm->arena, Value, n_cap)
                : NULL;
            /* The emitter pushed captures in order, so env[0] is the deepest
             * stack entry: copy from the bottom of the popped range up. */
            for (uint8_t i = 0; i < n_cap; i++) {
                clos->env[i] = vm->stack[vm->sp - n_cap + i];
            }
            vm->sp = (uint16_t)(vm->sp - n_cap);
            if (!vm_push(vm, value_fn(clos))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_GET_CAPTURE: {
            /* Slot 0 of the current frame holds the callee (the closure), and
             * is never overwritten inside the body (no SET_LOCAL 0 is emitted
             * in function bodies), so env is readable for the whole call. */
            uint32_t cap = inst.arg.index;
            if (vm->frame_count == 0) {
                vm_runtime_error(vm, line, "GET_CAPTURE outside a function");
                return VM_RUNTIME_ERROR;
            }
            uint16_t base = vm->frames[vm->frame_count - 1].base;
            Value callee = vm->stack[base];
            if (callee.kind != VAL_FN || !callee.as.fn_val ||
                !callee.as.fn_val->env || cap >= callee.as.fn_val->env_len) {
                vm_runtime_error(vm, line, "no captured variable at index %u", cap);
                return VM_RUNTIME_ERROR;
            }
            if (!vm_push(vm, callee.as.fn_val->env[cap])) return VM_RUNTIME_ERROR;
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

        /* ---- Option/Result wrapping ---- */

        case OPCODE_WRAP_OK: {
            Value inner = vm_pop(vm);
            if (!vm_push(vm, value_ok(vm->arena, inner))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_WRAP_ERR: {
            Value inner = vm_pop(vm);
            if (!vm_push(vm, value_err(vm->arena, inner))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_WRAP_SOME: {
            Value inner = vm_pop(vm);
            if (!vm_push(vm, value_some(vm->arena, inner))) return VM_RUNTIME_ERROR;
        } break;

        case OPCODE_TRY_UNWRAP: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on try unwrap");
                return VM_RUNTIME_ERROR;
            }
            Value val = vm->stack[vm->sp - 1];
            switch (val.kind) {
            case VAL_OK:
                vm->stack[vm->sp - 1] = *val.as.ok_val.inner;
                break;
            case VAL_SOME:
                vm->stack[vm->sp - 1] = *val.as.some_val.inner;
                break;
            case VAL_ERR: {
                if (vm->frame_count == 0) {
                    vm_runtime_error(vm, line, "try operator outside function");
                    return VM_RUNTIME_ERROR;
                }
                vm->frame_count--;
                vm->sp = vm->frames[vm->frame_count].base;
                vm->code      = vm->frames[vm->frame_count].saved_code;
                vm->code_len  = vm->frames[vm->frame_count].saved_code_len;
                vm->constants = vm->frames[vm->frame_count].saved_constants;
                vm->const_len = vm->frames[vm->frame_count].saved_const_len;
                if (!vm_push(vm, val)) return VM_RUNTIME_ERROR;
                ip = vm->frames[vm->frame_count].ip - 1;
                end = vm->code + vm->code_len;
            } break;
            case VAL_NIL: {
                if (vm->frame_count == 0) {
                    vm_runtime_error(vm, line, "try operator outside function");
                    return VM_RUNTIME_ERROR;
                }
                vm->frame_count--;
                vm->sp = vm->frames[vm->frame_count].base;
                vm->code      = vm->frames[vm->frame_count].saved_code;
                vm->code_len  = vm->frames[vm->frame_count].saved_code_len;
                vm->constants = vm->frames[vm->frame_count].saved_constants;
                vm->const_len = vm->frames[vm->frame_count].saved_const_len;
                if (!vm_push(vm, val)) return VM_RUNTIME_ERROR;
                ip = vm->frames[vm->frame_count].ip - 1;
                end = vm->code + vm->code_len;
            } break;
            default:
                vm_runtime_error(vm, line,
                    "? operator requires Result or Option, got %s",
                    type_name(val));
                return VM_RUNTIME_ERROR;
            }
        } break;

        /* ---- Special ---- */

        case OPCODE_HALT:
            return VM_OK;

        /* ---- Builtin variant pattern matching ---- */

        case OPCODE_TAG_IS: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on tag_is");
                return VM_RUNTIME_ERROR;
            }
            Value val = vm->stack[vm->sp - 1];
            uint32_t tag = inst.arg.index;
            bool match = false;
            switch (tag) {
                case 0: match = (val.kind == VAL_OK);   break;
                case 1: match = (val.kind == VAL_ERR);  break;
                case 2: match = (val.kind == VAL_SOME); break;
                case 3: match = (val.kind == VAL_NIL);  break;
            }
            vm->stack[vm->sp - 1] = value_bool(match);
        } break;

        case OPCODE_UNWRAP: {
            if (vm->sp == 0) {
                vm_runtime_error(vm, line, "stack underflow on unwrap");
                return VM_RUNTIME_ERROR;
            }
            Value val = vm->stack[vm->sp - 1];
            switch (val.kind) {
                case VAL_OK:
                    vm->stack[vm->sp - 1] = *val.as.ok_val.inner;
                    break;
                case VAL_ERR:
                    vm->stack[vm->sp - 1] = *val.as.err_val.inner;
                    break;
                case VAL_SOME:
                    vm->stack[vm->sp - 1] = *val.as.some_val.inner;
                    break;
                default:
                    vm_runtime_error(vm, line,
                        "unwrap requires ok, err, or some, got %s",
                        type_name(val));
                    return VM_RUNTIME_ERROR;
            }
        } break;

        case OPCODE_MATCH_NONE:
            /* Backstop of the exhaustiveness checker (audit §3.8): no arm
             * matched at run time. Unreachable for provably-total targets,
             * reachable through Tier-2 optional aliasing (an ok/err value
             * flowing where some/none was expected) — abort with position
             * instead of yielding a nil under the promised type. */
            vm_runtime_error(vm, line, "no match arm matched");
            return VM_RUNTIME_ERROR;

        default:
            vm_runtime_error(vm, line, "unknown opcode %d", (int)inst.op);
            return VM_RUNTIME_ERROR;
        }

        if (getenv("ASTRA_TRACE")) {
            uint16_t base = vm->frame_count > 0 ? vm->frames[vm->frame_count - 1].base : 0;
            fprintf(stderr, "  sp=%u base=%u frame=%u | ", vm->sp, base, vm->frame_count);
            for (uint16_t s = 0; s < vm->sp && s < 20; s++) {
                fprintf(stderr, "[");
                value_print_stream(stderr, vm->stack[s]);
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
    /* Cache the built-in marker functions (param_count = 255, no code). One
     * marker per builtin: GET_GLOBAL maps each builtin name to its marker and
     * OPCODE_CALL dispatches on pointer identity. */
    FnObj *print_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    print_fn->code = NULL;
    print_fn->code_len = 0;
    print_fn->constants = NULL;
    print_fn->const_len = 0;
    print_fn->param_count = 255;
    print_fn->local_count = 0;
    vm->builtin_print_fn = print_fn;
    FnObj *len_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    len_fn->code = NULL;
    len_fn->code_len = 0;
    len_fn->constants = NULL;
    len_fn->const_len = 0;
    len_fn->param_count = 255;
    len_fn->local_count = 0;
    vm->builtin_len_fn = len_fn;
    FnObj *ts_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    ts_fn->code = NULL;
    ts_fn->code_len = 0;
    ts_fn->constants = NULL;
    ts_fn->const_len = 0;
    ts_fn->param_count = 255;
    ts_fn->local_count = 0;
    vm->builtin_to_string_fn = ts_fn;
    FnObj *rf_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    rf_fn->code = NULL;
    rf_fn->code_len = 0;
    rf_fn->constants = NULL;
    rf_fn->const_len = 0;
    rf_fn->param_count = 255;
    rf_fn->local_count = 0;
    vm->builtin_read_file_fn = rf_fn;
    FnObj *ord_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    ord_fn->code = NULL;
    ord_fn->code_len = 0;
    ord_fn->constants = NULL;
    ord_fn->const_len = 0;
    ord_fn->param_count = 255;
    ord_fn->local_count = 0;
    vm->builtin_ord_fn = ord_fn;
    FnObj *sub_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    sub_fn->code = NULL;
    sub_fn->code_len = 0;
    sub_fn->constants = NULL;
    sub_fn->const_len = 0;
    sub_fn->param_count = 255;
    sub_fn->local_count = 0;
    vm->builtin_substr_fn = sub_fn;
    FnObj *push_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    push_fn->code = NULL;
    push_fn->code_len = 0;
    push_fn->constants = NULL;
    push_fn->const_len = 0;
    push_fn->param_count = 255;
    push_fn->local_count = 0;
    vm->builtin_push_fn = push_fn;
    FnObj *sti_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    sti_fn->code = NULL;
    sti_fn->code_len = 0;
    sti_fn->constants = NULL;
    sti_fn->const_len = 0;
    sti_fn->param_count = 255;
    sti_fn->local_count = 0;
    vm->builtin_str_to_int_fn = sti_fn;
    FnObj *chr_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    chr_fn->code = NULL;
    chr_fn->code_len = 0;
    chr_fn->constants = NULL;
    chr_fn->const_len = 0;
    chr_fn->param_count = 255;
    chr_fn->local_count = 0;
    vm->builtin_chr_fn = chr_fn;
    FnObj *rl_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    rl_fn->code = NULL;
    rl_fn->code_len = 0;
    rl_fn->constants = NULL;
    rl_fn->const_len = 0;
    rl_fn->param_count = 255;
    rl_fn->local_count = 0;
    vm->builtin_read_line_fn = rl_fn;
    FnObj *copy_fn = arena_alloc_zero(arena, sizeof(FnObj), _Alignof(FnObj));
    copy_fn->code = NULL;
    copy_fn->code_len = 0;
    copy_fn->constants = NULL;
    copy_fn->const_len = 0;
    copy_fn->param_count = 255;
    copy_fn->local_count = 0;
    vm->builtin_copy_fn = copy_fn;
    return vm;
}

void vm_destroy(VM *vm) {
    (void)vm;
}
