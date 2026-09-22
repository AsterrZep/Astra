#ifndef ASTRA_CODEGEN_RUNTIME_H
#define ASTRA_CODEGEN_RUNTIME_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <math.h>      /* fmod, for float remainder */
#include <setjmp.h>

/* ================================================================
 * Astra C Runtime — included by every --emit-c generated file
 * ================================================================ */

/* ---------- Frame stack size ----------
 *
 * Slots available to the generated code. It mirrors the VM's VM_STACK_SIZE
 * (see src/priv.h): both backends must be able to run the same programs, so
 * they get the same stack budget. The value is a *hard* limit and is enforced
 * by ASTRA_PUSH below — before that existed, deep recursion in the compiled
 * program wrote past this array (ASan-confirmed stack-buffer-overflow in
 * generated C), which is the same class of failure as the VM's 8-bit frame
 * base truncation fixed alongside it. */
#define ASTRA_FRAME_SIZE 1024

/* ---------- Tag enum ---------- */
typedef enum {
    AST_NIL = 0,
    AST_BOOL,
    AST_INT,
    AST_FLOAT,
    AST_STRING,
    AST_ARRAY,
    AST_STRUCT,
    AST_ENUM,
    AST_ENUM_DATA,
    AST_FN,
    AST_OK,
    AST_ERR,
    AST_SOME,
    AST_PTR
} AstraTag;

/* ---------- Forward declarations ---------- */
typedef struct AstraValue AstraValue;
typedef struct AstraString AstraString;
typedef struct AstraArray AstraArray;

/* Function pointer type: takes array of args + argc, returns value */
typedef AstraValue (*AstraFnPtr)(AstraValue *args, uint8_t argc);

/* ---------- Function object ---------- */
typedef struct {
    AstraFnPtr fun;
    uint8_t    param_count;
} AstraFn;

/* ---------- StructDef + StructObj (matches VM layout) ---------- */
typedef struct {
    const char  *name;
    const char **field_names;
    size_t       field_count;
} AstraStructDef;

typedef struct {
    const AstraStructDef *def;
    AstraValue           *fields;
} AstraStruct;

/* ---------- EnumObj (matches VM layout) ---------- */
typedef struct {
    const void *def;      /* EnumDef* — opaque here */
    size_t      variant;
    AstraValue *fields;
    size_t      field_count;   /* live entries of `fields`; structural equality needs it */
    const char *enum_name;     /* for pattern matching */
    const char *variant_name;  /* for pattern matching */
} AstraEnumObj;

/* ---------- Value ---------- */
struct AstraValue {
    AstraTag tag;
    union {
        uint8_t          bool_val;
        int64_t          int_val;
        double           float_val;
        AstraString     *string_val;
        AstraArray      *array_val;
        void            *struct_val;   /* any struct — access via cast */
        struct { const char *enum_name; const char *variant_name; } enum_val;
        void            *enum_obj;     /* EnumObj* — for data-carrying variants */
        AstraFn         *fn_val;
        struct AstraValue *wrapped;    /* for OK/ERR/SOME */
        void            *ptr_val;      /* generic pointer (struct defs, etc.) */
    } as;
};

/* ---------- Runtime error reporting ----------
 *
 * The VM and the compiled program have to be *observably the same language*, so
 * this backend words its runtime errors exactly like vm_runtime_error() does
 * ("cannot add int and bool", not "unsupported + operands") and names types the
 * way the VM's type_name() does. The conformance runner compares the two
 * backends' output, and identical wording is what makes a strict comparison of
 * runtime failures possible at all.
 *
 * astra_runtime_error() itself sits at the bottom of this header; declaring it
 * here lets the operations above it report through it. */
static inline void astra_runtime_error(const char *msg);

static inline void astra_errorf(const char *fmt, ...) {
    char msg[192];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    astra_runtime_error(msg);
}

/* Type names as the VM spells them (vm.c:type_name). */
static inline const char *astra_tag_name(AstraTag t) {
    switch (t) {
    case AST_NIL:       return "nil";
    case AST_BOOL:      return "bool";
    case AST_INT:       return "int";
    case AST_FLOAT:     return "float";
    case AST_STRING:    return "string";
    case AST_ARRAY:     return "array";
    case AST_STRUCT:    return "struct";
    case AST_ENUM:
    case AST_ENUM_DATA: return "enum";
    case AST_FN:        return "function";
    case AST_OK:        return "ok";
    case AST_ERR:       return "err";
    case AST_SOME:      return "some";
    case AST_PTR:       return "ptr";
    }
    return "unknown";
}

static inline AstraStruct *astra_struct_new(const AstraStructDef *def) {
    AstraStruct *s = (AstraStruct *)malloc(sizeof(AstraStruct));
    s->def = def;
    s->fields = (AstraValue *)calloc(def->field_count, sizeof(AstraValue));
    return s;
}

/* ---------- String ---------- */
struct AstraString {
    int64_t   len;
    char     *data;
    int64_t   refcount;
};

/* ---------- Array ---------- */
struct AstraArray {
    AstraValue *elems;
    int64_t     len;
    int64_t     capacity;
    int64_t     refcount;
};

/* ---------- Error handling ---------- */
extern jmp_buf  astra_error_jmp;
extern int      astra_error_active;
extern AstraValue astra_error_value;

#define ASTRA_TRY_UNWRAP(val) do { \
    if ((val).tag == AST_OK || (val).tag == AST_SOME) { \
        (val) = *(val).as.wrapped; \
    } else if ((val).tag == AST_ERR || (val).tag == AST_NIL) { \
        astra_error_value = (val); \
        longjmp(astra_error_jmp, 1); \
    } else { \
        /* Same wording as the VM's TRY_UNWRAP default arm, so a `?` on a plain
         * value reads identically from either backend. */ \
        astra_errorf("? operator requires Result or Option, got %s", \
                     astra_tag_name(val.tag)); \
        (val) = astra_nil(); \
    } \
} while(0)

/* Set up error recovery context. Call once per function that uses ?. */
#define ASTRA_TRY_CONTEXT() (astra_error_active = 1, setjmp(astra_error_jmp))

/* ---------- Constructors ---------- */
static inline AstraValue astra_int(int64_t v) {
    AstraValue r; r.tag = AST_INT; r.as.int_val = v; return r;
}
static inline AstraValue astra_float(double v) {
    AstraValue r; r.tag = AST_FLOAT; r.as.float_val = v; return r;
}
static inline AstraValue astra_bool(uint8_t v) {
    AstraValue r; r.tag = AST_BOOL; r.as.bool_val = v; return r;
}
static inline AstraValue astra_nil(void) {
    AstraValue r; r.tag = AST_NIL; memset(&r.as, 0, sizeof(r.as)); return r;
}

/* Allocate a new string (copies data). Caller owns the memory. */
static inline AstraValue astra_string_new(const char *s, int64_t len) {
    AstraString *str = (AstraString *)malloc(sizeof(AstraString) + (size_t)len + 1);
    str->len = len;
    str->data = (char *)(str + 1);
    if (s && len > 0) memcpy(str->data, s, (size_t)len);
    str->data[len] = '\0';
    str->refcount = 1;
    AstraValue r; r.tag = AST_STRING; r.as.string_val = str; return r;
}

/* Wrap an existing C string (NUL-terminated, borrowed). */
static inline AstraValue astra_string_lit(const char *s) {
    return astra_string_new(s, (int64_t)strlen(s));
}

/* Allocate a new array with given elements. Takes ownership of elems buf. */
/* Build an array that owns `heap_elems` (a heap buffer it may free). */
static inline AstraValue astra_array_take(AstraValue *heap_elems, int64_t len) {
    AstraArray *a = (AstraArray *)malloc(sizeof(AstraArray));
    a->elems = heap_elems;
    a->len = len;
    a->capacity = len;
    a->refcount = 1;
    AstraValue r; r.tag = AST_ARRAY; r.as.array_val = a; return r;
}

/* Build an array literal by *copying* n values out of `elems`.
 *
 * The generated code evaluates an array literal into a local `AstraValue
 * _elems[n]` of the surrounding C function and then called this constructor.
 * When the constructor adopted that pointer instead of copying, the array
 * pointed into a stack frame that no longer existed as soon as the creating
 * function returned — ASan-reported stack-use-after-scope for
 * `fn mk() -> [i32] { return [1, 2, 3] }`. The VM's NEW_ARRAY copies from its
 * operand stack, so copying here is also what keeps the two backends identical. */
static inline AstraValue astra_array_new(const AstraValue *elems, int64_t len) {
    AstraValue *buf = (AstraValue *)calloc((size_t)(len > 0 ? len : 1), sizeof(AstraValue));
    for (int64_t i = 0; i < len; i++) buf[i] = elems[i];
    return astra_array_take(buf, len);
}

/* Allocate an empty array with given capacity. */
static inline AstraValue astra_array_empty(int64_t capacity) {
    AstraValue *buf = (AstraValue *)calloc((size_t)capacity, sizeof(AstraValue));
    return astra_array_take(buf, 0);
}

/* Create a raw pointer value. Used for struct/enum definition objects, which the
 * generated code stores in a global and pushes as an opaque handle. */
static inline AstraValue astra_ptr(void *p) {
    AstraValue r; r.tag = AST_PTR; r.as.ptr_val = p; return r;
}

/* Create a unit enum variant value (`Color.Red`). Pattern matching compares the
 * pair by name, exactly like the VM does for VAL_ENUM. */
static inline AstraValue astra_enum_val(const char *enum_name, const char *variant_name) {
    AstraValue r;
    r.tag = AST_ENUM;
    r.as.enum_val.enum_name = enum_name;
    r.as.enum_val.variant_name = variant_name;
    return r;
}

/* Create a function value. */
static inline AstraValue astra_fn_new(AstraFnPtr fun, uint8_t param_count) {
    AstraFn *f = (AstraFn *)malloc(sizeof(AstraFn));
    f->fun = fun;
    f->param_count = param_count;
    AstraValue r; r.tag = AST_FN; r.as.fn_val = f; return r;
}

/* Create tagged wrappers. */
static inline AstraValue astra_wrap_ok(AstraValue inner) {
    AstraValue *heap = (AstraValue *)malloc(sizeof(AstraValue));
    *heap = inner;
    AstraValue r; r.tag = AST_OK; r.as.wrapped = heap; return r;
}
static inline AstraValue astra_wrap_err(AstraValue inner) {
    AstraValue *heap = (AstraValue *)malloc(sizeof(AstraValue));
    *heap = inner;
    AstraValue r; r.tag = AST_ERR; r.as.wrapped = heap; return r;
}
static inline AstraValue astra_wrap_some(AstraValue inner) {
    AstraValue *heap = (AstraValue *)malloc(sizeof(AstraValue));
    *heap = inner;
    AstraValue r; r.tag = AST_SOME; r.as.wrapped = heap; return r;
}
static inline AstraValue astra_unwrap(AstraValue val) {
    AstraValue inner = *val.as.wrapped;
    free(val.as.wrapped);
    return inner;
}
static inline uint8_t astra_tag_is(AstraValue val, int tag) {
    return (uint8_t)(val.tag == (AstraTag)tag);
}

/* ---------- Truthiness ---------- */
static inline uint8_t astra_truthy(AstraValue v) {
    switch (v.tag) {
    case AST_NIL:   return 0;
    case AST_BOOL:  return v.as.bool_val;
    case AST_INT:   return (uint8_t)(v.as.int_val != 0);
    case AST_FLOAT: return (uint8_t)(v.as.float_val != 0.0);
    case AST_STRING:return (uint8_t)(v.as.string_val && v.as.string_val->len > 0);
    case AST_ARRAY: return (uint8_t)(v.as.array_val && v.as.array_val->len > 0);
    default:        return 1;
    }
}

/* ---------- Print helpers ---------- */
static inline void astra_print_value(AstraValue v);

static inline void astra_print_string(AstraString *s) {
    printf("%.*s", (int)s->len, s->data);
}

static inline void astra_print_array(AstraArray *a) {
    printf("[");
    for (int64_t i = 0; i < a->len; i++) {
        if (i > 0) printf(", ");
        astra_print_value(a->elems[i]);
    }
    printf("]");
}

/* Print any value to stdout (no newline). */
static inline void astra_print_value(AstraValue v) {
    switch (v.tag) {
    case AST_NIL:      printf("nil"); break;
    case AST_BOOL:     printf("%s", v.as.bool_val ? "true" : "false"); break;
    case AST_INT:      printf("%ld", (long)v.as.int_val); break;
    case AST_FLOAT:    printf("%g", v.as.float_val); break;
    case AST_STRING:   astra_print_string(v.as.string_val); break;
    case AST_ARRAY:    astra_print_array(v.as.array_val); break;
    case AST_STRUCT: {
        AstraStruct *s = (AstraStruct *)v.as.struct_val;
        if (s && s->def) {
            printf("%s { ", s->def->name);
            for (size_t i = 0; i < s->def->field_count; i++) {
                if (i > 0) printf(", ");
                printf("%s: ", s->def->field_names[i]);
                astra_print_value(s->fields[i]);
            }
            printf(" }");
        } else {
            printf("struct");
        }
    } break;
    case AST_ENUM:     printf("%s.%s", v.as.enum_val.enum_name, v.as.enum_val.variant_name); break;
    case AST_ENUM_DATA: {
        AstraEnumObj *eo = (AstraEnumObj *)v.as.enum_obj;
        if (eo && eo->enum_name && eo->variant_name && eo->enum_name[0])
            printf("%s.%s", eo->enum_name, eo->variant_name);
        else
            printf("enum_data");
    } break;
    case AST_FN:       printf("fn"); break;
    case AST_OK:       printf("ok("); astra_print_value(*v.as.wrapped); printf(")"); break;
    case AST_ERR:      printf("err("); astra_print_value(*v.as.wrapped); printf(")"); break;
    case AST_SOME:     printf("some("); astra_print_value(*v.as.wrapped); printf(")"); break;
    case AST_PTR:      printf("<ptr>"); break;
    }
}

/* ---------- Arithmetic operations ---------- */
static inline AstraValue astra_add(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val + b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_float(a.as.float_val + b.as.float_val);
    if (a.tag == AST_INT && b.tag == AST_FLOAT)
        return astra_float((double)a.as.int_val + b.as.float_val);
    if (a.tag == AST_FLOAT && b.tag == AST_INT)
        return astra_float(a.as.float_val + (double)b.as.int_val);
    /* String concatenation */
    if (a.tag == AST_STRING && b.tag == AST_STRING) {
        int64_t len = a.as.string_val->len + b.as.string_val->len;
        char *buf = (char *)malloc((size_t)len + 1);
        memcpy(buf, a.as.string_val->data, (size_t)a.as.string_val->len);
        memcpy(buf + a.as.string_val->len, b.as.string_val->data, (size_t)b.as.string_val->len);
        buf[len] = '\0';
        AstraValue result = astra_string_new(buf, len);
        free(buf);
        return result;
    }
    astra_errorf("cannot add %s and %s", astra_tag_name(a.tag), astra_tag_name(b.tag));
    return astra_nil();   /* not reached: astra_errorf exits */
}

static inline AstraValue astra_sub(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val - b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_float(a.as.float_val - b.as.float_val);
    if (a.tag == AST_INT && b.tag == AST_FLOAT)
        return astra_float((double)a.as.int_val - b.as.float_val);
    if (a.tag == AST_FLOAT && b.tag == AST_INT)
        return astra_float(a.as.float_val - (double)b.as.int_val);
    /* Operand order in the message follows the VM: "subtract <b> from <a>". */
    astra_errorf("cannot subtract %s from %s", astra_tag_name(b.tag), astra_tag_name(a.tag));
    return astra_nil();
}

static inline AstraValue astra_mul(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val * b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_float(a.as.float_val * b.as.float_val);
    if (a.tag == AST_INT && b.tag == AST_FLOAT)
        return astra_float((double)a.as.int_val * b.as.float_val);
    if (a.tag == AST_FLOAT && b.tag == AST_INT)
        return astra_float(a.as.float_val * (double)b.as.int_val);
    astra_errorf("cannot multiply %s and %s", astra_tag_name(a.tag), astra_tag_name(b.tag));
    return astra_nil();
}

static inline AstraValue astra_div(AstraValue a, AstraValue b) {
    /* The VM rejects a zero divisor for floats as well as ints, even though
     * IEEE-754 would produce inf. Keeping that rule here is what makes
     * `1.0 / 0.0` behave the same in both backends; whether the language should
     * prefer inf instead is a design question the specification does not
     * answer (PHASE1_PROGRESS.md §6, S14). */
    if (b.tag == AST_INT && b.as.int_val == 0) {
        astra_runtime_error("division by zero");
    }
    if (b.tag == AST_FLOAT && b.as.float_val == 0.0) {
        astra_runtime_error("division by zero");
    }
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val / b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_float(a.as.float_val / b.as.float_val);
    if (a.tag == AST_INT && b.tag == AST_FLOAT)
        return astra_float((double)a.as.int_val / b.as.float_val);
    if (a.tag == AST_FLOAT && b.tag == AST_INT)
        return astra_float(a.as.float_val / (double)b.as.int_val);
    astra_errorf("cannot divide %s by %s", astra_tag_name(a.tag), astra_tag_name(b.tag));
    return astra_nil();
}

static inline AstraValue astra_mod(AstraValue a, AstraValue b) {
    if (b.tag == AST_INT && b.as.int_val == 0) {
        astra_runtime_error("modulo by zero");
    }
    if (b.tag == AST_FLOAT && b.as.float_val == 0.0) {
        astra_runtime_error("modulo by zero");
    }
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val % b.as.int_val);
    /* Float remainder goes through fmod, like the VM's OPCODE_MOD. Without this
     * the C backend errored on `7.5 % 2.0`, which the VM evaluates to 1.5. */
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_float(fmod(a.as.float_val, b.as.float_val));
    astra_errorf("cannot apply modulo to %s and %s",
                 astra_tag_name(a.tag), astra_tag_name(b.tag));
    return astra_nil();
}

static inline AstraValue astra_neg(AstraValue a) {
    if (a.tag == AST_INT) return astra_int(-a.as.int_val);
    if (a.tag == AST_FLOAT) return astra_float(-a.as.float_val);
    astra_errorf("cannot negate %s", astra_tag_name(a.tag));
    return astra_nil();
}

/* ---------- Bitwise operations ---------- */
/* Integer-only, mirroring the VM's OPCODE_BIT_* handlers opcode for opcode so
 * the generated program and `astra-seed` stay observably identical. */
static inline AstraValue astra_bit_and(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val & b.as.int_val);
    astra_runtime_error("bitwise & requires integer operands");
    return astra_nil();
}

static inline AstraValue astra_bit_or(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val | b.as.int_val);
    astra_runtime_error("bitwise | requires integer operands");
    return astra_nil();
}

static inline AstraValue astra_bit_xor(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val ^ b.as.int_val);
    astra_runtime_error("bitwise ^ requires integer operands");
    return astra_nil();
}

static inline AstraValue astra_shl(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT) {
        if (b.as.int_val < 0 || b.as.int_val >= 64)
            astra_runtime_error("shift amount out of range (must be 0..63)");
        return astra_int((uint64_t)a.as.int_val << (int)b.as.int_val);
    }
    astra_runtime_error("bitwise << requires integer operands");
    return astra_nil();
}

static inline AstraValue astra_shr(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT) {
        if (b.as.int_val < 0 || b.as.int_val >= 64)
            astra_runtime_error("shift amount out of range (must be 0..63)");
        return astra_int(a.as.int_val >> (int)b.as.int_val);
    }
    astra_runtime_error("bitwise >> requires integer operands");
    return astra_nil();
}

static inline AstraValue astra_bit_not(AstraValue a) {
    if (a.tag == AST_INT) return astra_int(~a.as.int_val);
    astra_runtime_error("bitwise ~ requires integer operand");
    return astra_nil();
}

/* ---------- Comparison operations ---------- */
static inline AstraValue astra_eq(AstraValue a, AstraValue b) {
    if (a.tag != b.tag) {
        /* Cross-kind: unit enum pattern (AST_ENUM) vs data-carrying instance (AST_ENUM_DATA) */
        if ((a.tag == AST_ENUM && b.tag == AST_ENUM_DATA) ||
            (a.tag == AST_ENUM_DATA && b.tag == AST_ENUM)) {
            const char *an, *av, *bn, *bv;
            if (a.tag == AST_ENUM) {
                an = a.as.enum_val.enum_name;
                av = a.as.enum_val.variant_name;
                AstraEnumObj *y = (AstraEnumObj *)b.as.enum_obj;
                if (!y) return astra_bool(0);
                bn = y->enum_name;
                bv = y->variant_name;
            } else {
                AstraEnumObj *x = (AstraEnumObj *)a.as.enum_obj;
                if (!x) return astra_bool(0);
                an = x->enum_name;
                av = x->variant_name;
                bn = b.as.enum_val.enum_name;
                bv = b.as.enum_val.variant_name;
            }
            if (!an || !av || !bn || !bv) return astra_bool(0);
            return astra_bool(strcmp(an, bn) == 0 && strcmp(av, bv) == 0);
        }
        return astra_bool(0);
    }
    switch (a.tag) {
    case AST_NIL:   return astra_bool(1);
    case AST_BOOL:  return astra_bool(a.as.bool_val == b.as.bool_val);
    case AST_INT:   return astra_bool(a.as.int_val == b.as.int_val);
    case AST_FLOAT: return astra_bool(a.as.float_val == b.as.float_val);
    case AST_STRING:
        return astra_bool(a.as.string_val->len == b.as.string_val->len &&
                          memcmp(a.as.string_val->data, b.as.string_val->data,
                                 (size_t)a.as.string_val->len) == 0);
    case AST_ENUM:
        return astra_bool(
            strcmp(a.as.enum_val.enum_name, b.as.enum_val.enum_name) == 0 &&
            strcmp(a.as.enum_val.variant_name, b.as.enum_val.variant_name) == 0);
    case AST_ARRAY: {
        /* Structural, like the VM's value_eq: identity first, then same length
         * and element-wise equality. Without this case `[1, 2] == [1, 2]` was
         * false in the compiled program and true in the VM. */
        AstraArray *x = a.as.array_val;
        AstraArray *y = b.as.array_val;
        if (x == y) return astra_bool(1);
        if (!x || !y || x->len != y->len) return astra_bool(0);
        for (int64_t i = 0; i < x->len; i++)
            if (!astra_eq(x->elems[i], y->elems[i]).as.bool_val) return astra_bool(0);
        return astra_bool(1);
    }
    case AST_STRUCT: {
        /* Same struct definition (by name), then field-wise. Field order is the
         * definition's order in both backends. */
        AstraStruct *x = (AstraStruct *)a.as.struct_val;
        AstraStruct *y = (AstraStruct *)b.as.struct_val;
        if (x == y) return astra_bool(1);
        if (!x || !y || !x->def || !y->def) return astra_bool(0);
        if (strcmp(x->def->name, y->def->name) != 0) return astra_bool(0);
        if (x->def->field_count != y->def->field_count) return astra_bool(0);
        for (size_t i = 0; i < x->def->field_count; i++)
            if (!astra_eq(x->fields[i], y->fields[i]).as.bool_val) return astra_bool(0);
        return astra_bool(1);
    }
    case AST_ENUM_DATA: {
        /* Structural: same enum, same variant, equal payloads (VM's
         * VAL_ENUM_DATA case). Needs field_count, which the generated code now
         * stores on the object. */
        AstraEnumObj *x = (AstraEnumObj *)a.as.enum_obj;
        AstraEnumObj *y = (AstraEnumObj *)b.as.enum_obj;
        if (x == y) return astra_bool(1);
        if (!x || !y) return astra_bool(0);
        if (x->variant != y->variant) return astra_bool(0);
        if (!x->enum_name || !y->enum_name || strcmp(x->enum_name, y->enum_name) != 0)
            return astra_bool(0);
        if (x->field_count != y->field_count) return astra_bool(0);
        for (size_t i = 0; i < x->field_count; i++)
            if (!astra_eq(x->fields[i], y->fields[i]).as.bool_val) return astra_bool(0);
        return astra_bool(1);
    }
    case AST_FN:    return astra_bool(a.as.fn_val == b.as.fn_val);
    case AST_PTR:   return astra_bool(a.as.ptr_val == b.as.ptr_val);
    case AST_OK:
    case AST_ERR:
    case AST_SOME:
        return astra_bool(
            a.tag == b.tag &&
            a.as.wrapped != NULL && b.as.wrapped != NULL &&
            astra_eq(*a.as.wrapped, *b.as.wrapped).as.bool_val);
    default: return astra_bool(0);
    }
}

static inline AstraValue astra_neq(AstraValue a, AstraValue b) {
    AstraValue r = astra_eq(a, b);
    r.as.bool_val = !r.as.bool_val;
    return r;
}

/* Ordering comparisons are numeric-only, exactly like the VM's OPCODE_LT family:
 * an unsupported pair is a runtime error, not a silent `false`. Returning false
 * for e.g. two strings is worse than an error — the program keeps running with a
 * wrong answer that no test comparing a boolean can notice. */
static inline AstraValue astra_cmp_error(AstraValue a, AstraValue b) {
    astra_errorf("cannot compare %s and %s", astra_tag_name(a.tag), astra_tag_name(b.tag));
    return astra_bool(0);
}

static inline AstraValue astra_lt(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)     return astra_bool(a.as.int_val < b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT) return astra_bool(a.as.float_val < b.as.float_val);
    if (a.tag == AST_INT && b.tag == AST_FLOAT)   return astra_bool((double)a.as.int_val < b.as.float_val);
    if (a.tag == AST_FLOAT && b.tag == AST_INT)   return astra_bool(a.as.float_val < (double)b.as.int_val);
    return astra_cmp_error(a, b);
}

static inline AstraValue astra_gt(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)     return astra_bool(a.as.int_val > b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT) return astra_bool(a.as.float_val > b.as.float_val);
    if (a.tag == AST_INT && b.tag == AST_FLOAT)   return astra_bool((double)a.as.int_val > b.as.float_val);
    if (a.tag == AST_FLOAT && b.tag == AST_INT)   return astra_bool(a.as.float_val > (double)b.as.int_val);
    return astra_cmp_error(a, b);
}

static inline AstraValue astra_le(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)     return astra_bool(a.as.int_val <= b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT) return astra_bool(a.as.float_val <= b.as.float_val);
    if (a.tag == AST_INT && b.tag == AST_FLOAT)   return astra_bool((double)a.as.int_val <= b.as.float_val);
    if (a.tag == AST_FLOAT && b.tag == AST_INT)   return astra_bool(a.as.float_val <= (double)b.as.int_val);
    return astra_cmp_error(a, b);
}

static inline AstraValue astra_ge(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)     return astra_bool(a.as.int_val >= b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT) return astra_bool(a.as.float_val >= b.as.float_val);
    if (a.tag == AST_INT && b.tag == AST_FLOAT)   return astra_bool((double)a.as.int_val >= b.as.float_val);
    if (a.tag == AST_FLOAT && b.tag == AST_INT)   return astra_bool(a.as.float_val >= (double)b.as.int_val);
    return astra_cmp_error(a, b);
}

static inline AstraValue astra_not(AstraValue a) {
    return astra_bool(!astra_truthy(a));
}

/* ---------- Built-in: print ---------- */
static inline AstraValue astra_builtin_print(AstraValue *args, uint8_t argc) {
    for (uint8_t i = 0; i < argc; i++) {
        if (i > 0) printf(" ");
        astra_print_value(args[i]);
    }
    printf("\n");
    return astra_nil();
}

/* ---------- Runtime error ---------- */
static inline void astra_runtime_error(const char *msg) {
    fprintf(stderr, "runtime error: %s\n", msg);
    if (astra_error_active) {
        longjmp(astra_error_jmp, 1);
    }
    exit(1);
}

/* ---------- Bounds-checked array access ----------
 *
 * The only way in from generated code. Indexing `elems[]` directly made an
 * out-of-bounds index a *silent wrong value* on read (the VM stops with
 * "index 5 out of bounds (len 3)") and an out-of-bounds heap write on
 * assignment — ASan-confirmed corruption from nothing worse than a bad index in
 * a .astra file. The message is worded like the VM's so that the two backends
 * stay comparable. */
static inline void astra_array_bounds(AstraArray *a, int64_t idx) {
    if (idx < 0 || idx >= a->len) {
        char msg[96];
        snprintf(msg, sizeof(msg), "index %ld out of bounds (len %ld)",
                 (long)idx, (long)a->len);
        astra_runtime_error(msg);
    }
}

static inline AstraValue astra_array_get(AstraArray *a, int64_t idx) {
    astra_array_bounds(a, idx);
    return a->elems[idx];
}

static inline void astra_array_set(AstraArray *a, int64_t idx, AstraValue val) {
    astra_array_bounds(a, idx);
    a->elems[idx] = val;
}

/* ---------- Bounds-checked push ----------
 *
 * The mirror of the VM's vm_push() guard. Every push in generated code grows
 * `sp`, and an unchecked `frame[sp] = ...; sp++;` let a program that recurses
 * deeply enough write past the end of the frame array — an ASan-confirmed
 * stack-buffer-overflow in generated C. Routing every push through this macro
 * makes the frame a bounded resource with a diagnostic, exactly like the VM
 * (vm_push refuses to grow the stack past VM_STACK_SIZE).
 *
 * Note the bound is on the *absolute* slot, not on `sp`: inside a function,
 * `frame` points into the middle of astra_frame (the caller passed
 * `astra_frame + _fn_slot`), so comparing `sp` alone would happily allow
 * frame_base + sp to run off the end. */
#define ASTRA_PUSH(frame, sp, val) do {                                          \
        if ((size_t)((frame) - astra_frame) + (size_t)(sp) >= ASTRA_FRAME_SIZE) { \
            astra_runtime_error("frame stack overflow (recursion too deep)");     \
        }                                                                        \
        (frame)[(sp)] = (val);                                                   \
        (sp)++;                                                                  \
    } while (0)

/* ---------- Global error state ---------- */

/* The operand stack of the generated program.
 *
 * It is one global array shared by every generated function: a call passes
 * `astra_frame + _fn_slot`, i.e. a pointer into the middle of it, which is how
 * the C backend mimics the VM's slot addressing. Declaring it here rather than
 * as a local of astra_module_main is what lets ASTRA_PUSH know where a frame
 * starts and therefore how much room is actually left. */
AstraValue astra_frame[ASTRA_FRAME_SIZE];

jmp_buf    astra_error_jmp;
int        astra_error_active;
AstraValue astra_error_value;

/* ---------- Module init/cleanup ---------- */
static inline void astra_runtime_init(void) {
    /* nothing to init yet */
}

static inline void astra_runtime_cleanup(void) {
    /* nothing to cleanup yet */
}

#endif /* ASTRA_CODEGEN_RUNTIME_H */
