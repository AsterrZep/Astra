#ifndef ASTRA_CODEGEN_RUNTIME_H
#define ASTRA_CODEGEN_RUNTIME_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <setjmp.h>

/* ================================================================
 * Astra C Runtime — included by every --emit-c generated file
 * ================================================================ */

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
        fprintf(stderr, "runtime error: ? requires Result or Option\n"); \
        exit(1); \
    } \
} while(0)

/* Set up error recovery context. Call once per function that uses ?. */
#define ASTRA_TRY_CONTEXT() setjmp(astra_error_jmp)

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
static inline AstraValue astra_array_new(AstraValue *elems, int64_t len) {
    AstraArray *a = (AstraArray *)malloc(sizeof(AstraArray));
    a->elems = elems;
    a->len = len;
    a->capacity = len;
    a->refcount = 1;
    AstraValue r; r.tag = AST_ARRAY; r.as.array_val = a; return r;
}

/* Allocate an empty array with given capacity. */
static inline AstraValue astra_array_empty(int64_t capacity) {
    AstraValue *buf = (AstraValue *)calloc((size_t)capacity, sizeof(AstraValue));
    return astra_array_new(buf, 0);
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
        return astra_string_new(buf, len);
    }
    fprintf(stderr, "runtime error: unsupported + operands\n");
    exit(1);
}

static inline AstraValue astra_sub(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val - b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_float(a.as.float_val - b.as.float_val);
    fprintf(stderr, "runtime error: unsupported - operands\n");
    exit(1);
}

static inline AstraValue astra_mul(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_int(a.as.int_val * b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_float(a.as.float_val * b.as.float_val);
    fprintf(stderr, "runtime error: unsupported * operands\n");
    exit(1);
}

static inline AstraValue astra_div(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT) {
        if (b.as.int_val == 0) { fprintf(stderr, "runtime error: division by zero\n"); exit(1); }
        return astra_int(a.as.int_val / b.as.int_val);
    }
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_float(a.as.float_val / b.as.float_val);
    fprintf(stderr, "runtime error: unsupported / operands\n");
    exit(1);
}

static inline AstraValue astra_mod(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT) {
        if (b.as.int_val == 0) { fprintf(stderr, "runtime error: modulo by zero\n"); exit(1); }
        return astra_int(a.as.int_val % b.as.int_val);
    }
    fprintf(stderr, "runtime error: unsupported %% operands\n");
    exit(1);
}

static inline AstraValue astra_neg(AstraValue a) {
    if (a.tag == AST_INT) return astra_int(-a.as.int_val);
    if (a.tag == AST_FLOAT) return astra_float(-a.as.float_val);
    fprintf(stderr, "runtime error: unsupported -unary operand\n");
    exit(1);
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

static inline AstraValue astra_lt(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_bool(a.as.int_val < b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_bool(a.as.float_val < b.as.float_val);
    return astra_bool(0);
}

static inline AstraValue astra_gt(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_bool(a.as.int_val > b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_bool(a.as.float_val > b.as.float_val);
    return astra_bool(0);
}

static inline AstraValue astra_le(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_bool(a.as.int_val <= b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_bool(a.as.float_val <= b.as.float_val);
    return astra_bool(0);
}

static inline AstraValue astra_ge(AstraValue a, AstraValue b) {
    if (a.tag == AST_INT && b.tag == AST_INT)
        return astra_bool(a.as.int_val >= b.as.int_val);
    if (a.tag == AST_FLOAT && b.tag == AST_FLOAT)
        return astra_bool(a.as.float_val >= b.as.float_val);
    return astra_bool(0);
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
    exit(1);
}

/* ---------- Global error state ---------- */
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
