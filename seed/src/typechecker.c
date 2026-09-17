#include "priv.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* ============================================================
 * §1: Type Helpers
 * ============================================================ */

Type *type_new(Arena *a, TypeKind kind) {
    Type *t = arena_new(a, Type);
    t->kind = kind;
    return t;
}

static Type *type_new_optional(Arena *a, Type *inner) {
    Type *t = type_new(a, TYPE_OPTIONAL);
    t->as.optional.inner = inner;
    return t;
}

static Type *type_new_array(Arena *a, Type *elem, Node *size) {
    Type *t = type_new(a, TYPE_ARRAY);
    t->as.array.elem = elem;
    t->as.array.size = size;
    return t;
}

static Type *type_new_fn(Arena *a, Type **params, size_t param_count, Type *ret) {
    Type *t = type_new(a, TYPE_FN);
    t->as.fn.params      = params;
    t->as.fn.param_count = param_count;
    t->as.fn.ret         = ret;
    return t;
}

bool type_eq(Type *a, Type *b) {
    if (!a || !b) return a == b;
    /* TYPE_UNKNOWN matches any type (for built-in polymorphic functions) */
    if (a->kind == TYPE_UNKNOWN || b->kind == TYPE_UNKNOWN) return true;
    if (a->kind != b->kind) return false;
    switch (a->kind) {
    case TYPE_OPTIONAL:
        return type_eq(a->as.optional.inner, b->as.optional.inner);
    case TYPE_ARRAY:
        return type_eq(a->as.array.elem, b->as.array.elem);
    case TYPE_FN:
        if (a->as.fn.param_count != b->as.fn.param_count) return false;
        for (size_t i = 0; i < a->as.fn.param_count; i++) {
            if (!type_eq(a->as.fn.params[i], b->as.fn.params[i])) return false;
        }
        return type_eq(a->as.fn.ret, b->as.fn.ret);
    case TYPE_STRUCT:
        return string_eq(a->as.struc.name, b->as.struc.name);
    case TYPE_ENUM:
        return string_eq(a->as.enumeration.name, b->as.enumeration.name);
    default:
        return true;
    }
}

static bool type_is_numeric(Type *t) {
    return t && (t->kind == TYPE_INT || t->kind == TYPE_FLOAT);
}

static bool type_is_error(Type *t) {
    return t && t->kind == TYPE_ERROR;
}

static const char *type_kind_name(TypeKind kind) {
    switch (kind) {
    case TYPE_VOID:     return "void";
    case TYPE_BOOL:     return "bool";
    case TYPE_INT:      return "i32";
    case TYPE_FLOAT:    return "f64";
    case TYPE_STRING:   return "string";
    case TYPE_OPTIONAL: return "optional";
    case TYPE_ARRAY:    return "array";
    case TYPE_FN:       return "fn";
    case TYPE_STRUCT:   return "struct";
    case TYPE_ENUM:     return "enum";
    case TYPE_UNKNOWN:  return "unknown";
    case TYPE_ERROR:    return "<error>";
    }
    return "<unknown>";
}

void type_print(Type *t) {
    if (!t) { printf("(null)"); return; }
    switch (t->kind) {
    case TYPE_VOID:     printf("void");     break;
    case TYPE_BOOL:     printf("bool");     break;
    case TYPE_INT:      printf("i32");      break;
    case TYPE_FLOAT:    printf("f64");      break;
    case TYPE_STRING:   printf("string");   break;
    case TYPE_OPTIONAL:
        printf("?");
        type_print(t->as.optional.inner);
        break;
    case TYPE_ARRAY:
        printf("[");
        type_print(t->as.array.elem);
        printf("]");
        break;
    case TYPE_FN:
        printf("fn(");
        for (size_t i = 0; i < t->as.fn.param_count; i++) {
            if (i > 0) printf(", ");
            type_print(t->as.fn.params[i]);
        }
        printf(") -> ");
        type_print(t->as.fn.ret);
        break;
    case TYPE_STRUCT:
        printf("%.*s", (int)t->as.struc.name.len, t->as.struc.name.str);
        break;
    case TYPE_ENUM:
        printf("%.*s", (int)t->as.enumeration.name.len, t->as.enumeration.name.str);
        break;
    case TYPE_UNKNOWN:  printf("unknown");  break;
    case TYPE_ERROR:    printf("<error>");   break;
    }
}

/* ============================================================
 * §2: Symbol Table
 * ============================================================ */

#define ST_INITIAL_CAP 64

struct SymbolTable {
    Arena    *arena;
    Symbol  **buckets;
    size_t    capacity;
    size_t    count;
    /* scope tracking */
    int       scope_depth;
    /* each scope level stores the insertion sequence at push time;
     * popping removes every symbol with seq >= that value */
    uint32_t *scope_counts;
    int       scope_cap;
    uint32_t  next_seq;
};

SymbolTable *symbol_table_create(Arena *a, size_t size) {
    SymbolTable *st = arena_new(a, SymbolTable);
    st->arena     = a;
    st->capacity  = size > 0 ? size : ST_INITIAL_CAP;
    st->buckets   = arena_alloc_zero(a, sizeof(Symbol *) * st->capacity, _Alignof(Symbol *));
    st->count     = 0;
    st->scope_depth = 0;
    st->scope_cap = 16;
    st->scope_counts = arena_alloc_zero(a, sizeof(uint32_t) * st->scope_cap, _Alignof(uint32_t));
    st->next_seq  = 0;
    return st;
}

static size_t st_hash(InternedString name) {
    return (size_t)name.hash;
}

static void st_grow(SymbolTable *st) {
    size_t old_cap = st->capacity;
    Symbol **old   = st->buckets;

    st->capacity = old_cap * 2;
    st->buckets  = arena_alloc_zero(st->arena, sizeof(Symbol *) * st->capacity, _Alignof(Symbol *));

    for (size_t i = 0; i < old_cap; i++) {
        Symbol *s = old[i];
        while (s) {
            Symbol *next = s->next;
            size_t idx = st_hash(s->name) % st->capacity;
            s->next = st->buckets[idx];
            st->buckets[idx] = s;
            s = next;
        }
    }
}

void symbol_table_insert(SymbolTable *st, Symbol sym) {
    if (st->count * 10 >= st->capacity * 7) {
        st_grow(st);
    }

    Symbol *s = arena_new(st->arena, Symbol);
    *s = sym;
    s->seq = st->next_seq++;

    size_t idx = st_hash(sym.name) % st->capacity;
    s->next = st->buckets[idx];
    st->buckets[idx] = s;
    st->count++;
}

Symbol *symbol_table_lookup(SymbolTable *st, InternedString name) {
    size_t idx = st_hash(name) % st->capacity;
    Symbol *s = st->buckets[idx];
    while (s) {
        if (string_eq(s->name, name)) return s;
        s = s->next;
    }
    return NULL;
}

void symbol_table_push_scope(SymbolTable *st) {
    st->scope_depth++;
    if (st->scope_depth >= st->scope_cap) {
        int new_cap = st->scope_cap * 2;
        uint32_t *new_arr = arena_alloc_zero(st->arena, sizeof(uint32_t) * new_cap, _Alignof(uint32_t));
        memcpy(new_arr, st->scope_counts, sizeof(uint32_t) * st->scope_cap);
        st->scope_counts = new_arr;
        st->scope_cap = new_cap;
    }
    st->scope_counts[st->scope_depth] = st->next_seq;
}

void symbol_table_pop_scope(SymbolTable *st) {
    if (st->scope_depth <= 0) return;

    uint32_t cutoff = st->scope_counts[st->scope_depth];
    st->scope_depth--;

    /* Remove exactly the symbols introduced since this scope was pushed.
     * Symbols carry a monotonic insertion sequence, so outer symbols
     * (e.g. built-ins like `print`) can never be evicted by an inner pop. */
    for (size_t i = 0; i < st->capacity; i++) {
        Symbol **pp = &st->buckets[i];
        while (*pp) {
            Symbol *s = *pp;
            if (s->seq >= cutoff) {
                *pp = s->next;
                s->next = NULL;
                st->count--;
            } else {
                pp = &s->next;
            }
        }
    }
}

/* ============================================================
 * §3: Type Checker
 * ============================================================ */

struct TypeChecker {
    Arena     *arena;
    StringTable *strings;
    SymbolTable *symbols;
    Type      *current_fn_return; /* return type of enclosing fn, or NULL */
    int        error_count;
};

TypeChecker *typechecker_create(Arena *arena, StringTable *strings) {
    TypeChecker *tc = arena_new(arena, TypeChecker);
    tc->arena    = arena;
    tc->strings  = strings;
    tc->symbols  = symbol_table_create(arena, 128);

    /* Register built-in functions */
    /* print(value) -> void */
    {
        Type **params = arena_new_array(arena, Type *, 1);
        params[0] = type_new(arena, TYPE_UNKNOWN); /* accepts any type */
        Type *print_type = type_new_fn(arena, params, 1, type_new(arena, TYPE_VOID));
        Symbol sym = {
            .name = string_intern_cstr(strings, "print"),
            .type = print_type,
            .is_mut = false,
            .is_fn = true,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    return tc;
}

void typechecker_destroy(TypeChecker *tc) {
    (void)tc;
}

int typechecker_error_count(TypeChecker *tc) {
    return tc ? tc->error_count : 0;
}

/* --- Error Reporting --- */

static void tc_error(TypeChecker *tc, SrcLoc loc, const char *fmt, ...) {
    tc->error_count++;
    fprintf(stderr, "%s:%u:%u: error: ", loc.filename, loc.line, loc.column);
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fprintf(stderr, "\n");
}

static Type *tc_error_type(TypeChecker *tc, SrcLoc loc, const char *fmt, ...) {
    tc->error_count++;
    fprintf(stderr, "%s:%u:%u: error: ", loc.filename, loc.line, loc.column);
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fprintf(stderr, "\n");
    return type_new(tc->arena, TYPE_ERROR);
}

/* --- Type Node Resolution --- */

static Type *resolve_type_node(TypeChecker *tc, Node *node);

/* --- Forward Declarations --- */

static Type *typecheck_node(TypeChecker *tc, Node *node);
static void  typecheck_fn_body(TypeChecker *tc, Node *fn_node);
static int   enum_variant_index(Type *en, InternedString variant);

/* ============================================================
 * §4: Type Node Resolution
 * ============================================================ */

static Type *resolve_type_node(TypeChecker *tc, Node *node) {
    if (!node) return NULL;

    switch (node->kind) {
    case NODE_TYPE_IDENT: {
        InternedString name = node->as.type_ident.name;
        if (name.len == 4 && memcmp(name.str, "void", 4) == 0) return type_new(tc->arena, TYPE_VOID);
        if (name.len == 4 && memcmp(name.str, "bool", 4) == 0) return type_new(tc->arena, TYPE_BOOL);
        if (name.len == 3 && memcmp(name.str, "i32", 3) == 0) return type_new(tc->arena, TYPE_INT);
        if (name.len == 3 && memcmp(name.str, "f64", 3) == 0) return type_new(tc->arena, TYPE_FLOAT);
        if (name.len == 6 && memcmp(name.str, "string", 6) == 0) return type_new(tc->arena, TYPE_STRING);

        /* Check for struct/enum types in symbol table */
        Symbol *sym = symbol_table_lookup(tc->symbols, name);
        if (sym && sym->type) return sym->type;

        return tc_error_type(tc, node->loc, "unknown type '%.*s'", (int)name.len, name.str);
    }
    case NODE_TYPE_OPTIONAL: {
        Type *inner = resolve_type_node(tc, node->as.type_optional.inner);
        if (type_is_error(inner)) return inner;
        return type_new_optional(tc->arena, inner);
    }
    case NODE_TYPE_ARRAY: {
        Type *elem = resolve_type_node(tc, node->as.type_array.elem_type);
        if (type_is_error(elem)) return elem;
        return type_new_array(tc->arena, elem, node->as.type_array.size);
    }
    case NODE_TYPE_FN: {
        size_t count = node->as.type_fn.param_types.len;
        Type **params = arena_new_array(tc->arena, Type *, count);
        for (size_t i = 0; i < count; i++) {
            params[i] = resolve_type_node(tc, node->as.type_fn.param_types.data[i]);
            if (type_is_error(params[i])) return type_new(tc->arena, TYPE_ERROR);
        }
        Type *ret = resolve_type_node(tc, node->as.type_fn.return_type);
        if (ret && type_is_error(ret)) return ret;
        return type_new_fn(tc->arena, params, count, ret);
    }
    default:
        return tc_error_type(tc, node->loc, "invalid type expression");
    }
}

/* ============================================================
 * §5: Expression Type Checking
 * ============================================================ */

static Type *typecheck_int_lit(TypeChecker *tc, Node *node) {
    (void)node;
    return type_new(tc->arena, TYPE_INT);
}

static Type *typecheck_float_lit(TypeChecker *tc, Node *node) {
    (void)node;
    return type_new(tc->arena, TYPE_FLOAT);
}

static Type *typecheck_string_lit(TypeChecker *tc, Node *node) {
    (void)node;
    return type_new(tc->arena, TYPE_STRING);
}

static Type *typecheck_bool_lit(TypeChecker *tc, Node *node) {
    (void)node;
    return type_new(tc->arena, TYPE_BOOL);
}

static Type *typecheck_null_lit(TypeChecker *tc, Node *node) {
    (void)node;
    /* null has type ?T (optional) — we use TYPE_OPTIONAL with NULL inner as sentinel */
    return type_new_optional(tc->arena, NULL);
}

static Type *typecheck_ident(TypeChecker *tc, Node *node) {
    InternedString name = node->as.ident.name;
    Symbol *sym = symbol_table_lookup(tc->symbols, name);
    if (!sym) {
        return tc_error_type(tc, node->loc, "undefined variable '%.*s'",
                             (int)name.len, name.str);
    }
    return sym->type;
}

static Type *typecheck_binary(TypeChecker *tc, Node *node) {
    Type *left  = typecheck_node(tc, node->as.binary.left);
    Type *right = typecheck_node(tc, node->as.binary.right);

    if (type_is_error(left))  return left;
    if (type_is_error(right)) return right;

    BinaryOp op = node->as.binary.op;

    /* Logical operators require bool operands */
    if (op == OP_AND || op == OP_OR) {
        if (left->kind != TYPE_BOOL) {
            return tc_error_type(tc, node->as.binary.left->loc,
                                 "logical operator requires bool, got %s",
                                 type_kind_name(left->kind));
        }
        if (right->kind != TYPE_BOOL) {
            return tc_error_type(tc, node->as.binary.right->loc,
                                 "logical operator requires bool, got %s",
                                 type_kind_name(right->kind));
        }
        return type_new(tc->arena, TYPE_BOOL);
    }

    /* Arithmetic operators require matching numeric types */
    if (op == OP_ADD || op == OP_SUB || op == OP_MUL || op == OP_DIV || op == OP_MOD) {
        if (!type_is_numeric(left)) {
            return tc_error_type(tc, node->as.binary.left->loc,
                                 "arithmetic operator requires numeric type, got %s",
                                 type_kind_name(left->kind));
        }
        if (!type_is_numeric(right)) {
            return tc_error_type(tc, node->as.binary.right->loc,
                                 "arithmetic operator requires numeric type, got %s",
                                 type_kind_name(right->kind));
        }
        if (!type_eq(left, right)) {
            return tc_error_type(tc, node->loc,
                                 "type mismatch: cannot apply '%s' to %s and %s",
                                 op == OP_ADD ? "+" : op == OP_SUB ? "-" :
                                 op == OP_MUL ? "*" : op == OP_DIV ? "/" : "%",
                                 type_kind_name(left->kind),
                                 type_kind_name(right->kind));
        }
        return left;
    }

    /* Comparison operators require matching types, return bool */
    if (op == OP_EQ || op == OP_NEQ || op == OP_LT || op == OP_GT ||
        op == OP_LE || op == OP_GE) {
        if (!type_eq(left, right)) {
            return tc_error_type(tc, node->loc,
                                 "type mismatch: cannot compare %s and %s",
                                 type_kind_name(left->kind),
                                 type_kind_name(right->kind));
        }
        return type_new(tc->arena, TYPE_BOOL);
    }

    /* Bitwise operators require matching types */
    if (op == OP_BIT_AND || op == OP_BIT_OR || op == OP_BIT_XOR ||
        op == OP_SHL || op == OP_SHR) {
        if (left->kind != TYPE_INT) {
            return tc_error_type(tc, node->as.binary.left->loc,
                                 "bitwise operator requires i32, got %s",
                                 type_kind_name(left->kind));
        }
        if (right->kind != TYPE_INT) {
            return tc_error_type(tc, node->as.binary.right->loc,
                                 "bitwise operator requires i32, got %s",
                                 type_kind_name(right->kind));
        }
        return type_new(tc->arena, TYPE_INT);
    }

    return type_new(tc->arena, TYPE_ERROR);
}

static Type *typecheck_unary(TypeChecker *tc, Node *node) {
    Type *operand = typecheck_node(tc, node->as.unary.operand);
    if (type_is_error(operand)) return operand;

    UnaryOp op = node->as.unary.op;

    switch (op) {
    case UNOP_NEG:
        if (!type_is_numeric(operand)) {
            return tc_error_type(tc, node->loc,
                                 "negation requires numeric type, got %s",
                                 type_kind_name(operand->kind));
        }
        return operand;
    case UNOP_NOT:
        if (operand->kind != TYPE_BOOL) {
            return tc_error_type(tc, node->loc,
                                 "logical not requires bool, got %s",
                                 type_kind_name(operand->kind));
        }
        return type_new(tc->arena, TYPE_BOOL);
    case UNOP_BIT_NOT:
        if (operand->kind != TYPE_INT) {
            return tc_error_type(tc, node->loc,
                                 "bitwise not requires i32, got %s",
                                 type_kind_name(operand->kind));
        }
        return type_new(tc->arena, TYPE_INT);
    case UNOP_REF:
    case UNOP_DEREF:
        /* Not supported in minimal seed */
        return tc_error_type(tc, node->loc, "operator not supported in Astra-0");
    }

    return type_new(tc->arena, TYPE_ERROR);
}

static Type *typecheck_call(TypeChecker *tc, Node *node) {
    Type *callee = typecheck_node(tc, node->as.call.callee);
    if (type_is_error(callee)) return callee;

    if (callee->kind != TYPE_FN) {
        return tc_error_type(tc, node->as.call.callee->loc,
                             "cannot call non-function type %s",
                             type_kind_name(callee->kind));
    }

    size_t arg_count = node->as.call.args.len;
    if (arg_count != callee->as.fn.param_count) {
        return tc_error_type(tc, node->loc,
                             "expected %zu arguments, got %zu",
                             callee->as.fn.param_count, arg_count);
    }

    for (size_t i = 0; i < arg_count; i++) {
        Type *arg_type = typecheck_node(tc, node->as.call.args.data[i]);
        if (type_is_error(arg_type)) return arg_type;
        if (!type_eq(arg_type, callee->as.fn.params[i])) {
            return tc_error_type(tc, node->loc,
                                 "argument %zu: expected %s, got %s",
                                 i + 1,
                                 type_kind_name(callee->as.fn.params[i]->kind),
                                 type_kind_name(arg_type->kind));
        }
    }

    return callee->as.fn.ret ? callee->as.fn.ret : type_new(tc->arena, TYPE_VOID);
}

static Type *typecheck_array_lit(TypeChecker *tc, Node *node) {
    size_t n = node->as.array_lit.elems.len;
    if (n == 0) {
        /* Empty array: element type is unknown until context provides it. */
        return type_new_array(tc->arena, type_new(tc->arena, TYPE_UNKNOWN), NULL);
    }

    Type *elem_type = typecheck_node(tc, node->as.array_lit.elems.data[0]);
    if (type_is_error(elem_type)) return elem_type;

    for (size_t i = 1; i < n; i++) {
        Type *t = typecheck_node(tc, node->as.array_lit.elems.data[i]);
        if (type_is_error(t)) return t;
        if (!type_eq(elem_type, t)) {
            return tc_error_type(tc, node->as.array_lit.elems.data[i]->loc,
                                 "array element %zu has type %s, expected %s",
                                 i + 1,
                                 type_kind_name(t->kind),
                                 type_kind_name(elem_type->kind));
        }
    }

    return type_new_array(tc->arena, elem_type, NULL);
}

static Type *typecheck_index(TypeChecker *tc, Node *node) {
    Type *object = typecheck_node(tc, node->as.index.object);
    if (type_is_error(object)) return object;

    if (object->kind != TYPE_ARRAY) {
        return tc_error_type(tc, node->as.index.object->loc,
                             "cannot index non-array type %s",
                             type_kind_name(object->kind));
    }

    Type *index = typecheck_node(tc, node->as.index.index);
    if (type_is_error(index)) return index;

    if (index->kind != TYPE_INT) {
        return tc_error_type(tc, node->as.index.index->loc,
                             "array index must be i32, got %s",
                             type_kind_name(index->kind));
    }

    return object->as.array.elem;
}

static Type *typecheck_struct_lit(TypeChecker *tc, Node *node) {
    InternedString name = node->as.struct_lit.name;
    Symbol *sym = symbol_table_lookup(tc->symbols, name);
    if (!sym || !sym->type || sym->type->kind != TYPE_STRUCT) {
        return tc_error_type(tc, node->loc, "unknown struct '%.*s'",
                             (int)name.len, name.str);
    }
    Type *st = sym->type;
    size_t declared = st->as.struc.field_count;

    /* No unknown fields. */
    for (size_t i = 0; i < node->as.struct_lit.field_names.len; i++) {
        InternedString fname = node->as.struct_lit.field_names.data[i];
        bool found = false;
        for (size_t j = 0; j < declared; j++) {
            if (string_eq(st->as.struc.fields[j].name, fname)) { found = true; break; }
        }
        if (!found) {
            return tc_error_type(tc, node->loc, "struct '%.*s' has no field '%.*s'",
                                 (int)name.len, name.str, (int)fname.len, fname.str);
        }
    }

    /* Every declared field must be initialised exactly once, with a
     * compatible type. */
    for (size_t i = 0; i < declared; i++) {
        InternedString fname = st->as.struc.fields[i].name;
        int vi = -1;
        for (size_t j = 0; j < node->as.struct_lit.field_names.len; j++) {
            if (string_eq(node->as.struct_lit.field_names.data[j], fname)) { vi = (int)j; break; }
        }
        if (vi < 0) {
            return tc_error_type(tc, node->loc, "missing field '%.*s' in '%.*s' literal",
                                 (int)fname.len, fname.str, (int)name.len, name.str);
        }
        Node *val = node->as.struct_lit.field_values.data[vi];
        Type *vt = typecheck_node(tc, val);
        if (type_is_error(vt)) return vt;
        Type *expected = st->as.struc.fields[i].type;
        if (!type_eq(expected, vt)) {
            return tc_error_type(tc, val->loc,
                                 "field '%.*s' expects %s, got %s",
                                 (int)fname.len, fname.str,
                                 type_kind_name(expected->kind),
                                 type_kind_name(vt->kind));
        }
    }

    return st;
}

static Type *typecheck_field_access(TypeChecker *tc, Node *node) {
    Type *object = typecheck_node(tc, node->as.field_access.object);
    if (type_is_error(object)) return object;

    /* `Enum.Variant` is a value of the enum's type, not a field read. */
    if (object->kind == TYPE_ENUM) {
        InternedString v = node->as.field_access.field;
        if (enum_variant_index(object, v) < 0) {
            return tc_error_type(tc, node->loc, "enum '%.*s' has no variant '%.*s'",
                                 (int)object->as.enumeration.name.len,
                                 object->as.enumeration.name.str,
                                 (int)v.len, v.str);
        }
        return object;
    }

    if (object->kind != TYPE_STRUCT) {
        return tc_error_type(tc, node->as.field_access.object->loc,
                             "cannot access field on non-struct type %s",
                             type_kind_name(object->kind));
    }

    InternedString field = node->as.field_access.field;

    for (size_t i = 0; i < object->as.struc.field_count; i++) {
        if (string_eq(object->as.struc.fields[i].name, field)) {
            return object->as.struc.fields[i].type;
        }
    }

    return tc_error_type(tc, node->loc, "struct '%.*s' has no field '%.*s'",
                         (int)object->as.struc.name.len, object->as.struc.name.str,
                         (int)field.len, field.str);
}

/* A block's value is its trailing expression
 * (`Block ::= "{" Statement* Expression? "}"`, research/010 §12.1 and §4.2).
 * A block that ends in a statement — including an expression statement
 * terminated by `;`, which is how §4.2 says a value is discarded — has no
 * value at all, so its type is void and it cannot be bound. Tracking the type
 * of the last *statement* instead made `let b = { 7; };` look like an i32
 * while the emitter correctly produced nothing. */
static Type *typecheck_block(TypeChecker *tc, Node *node) {
    symbol_table_push_scope(tc->symbols);

    for (size_t i = 0; i < node->as.block.stmts.len; i++) {
        typecheck_node(tc, node->as.block.stmts.data[i]);
    }

    Type *type = type_new(tc->arena, TYPE_VOID);
    if (node->as.block.last_expr) {
        type = typecheck_node(tc, node->as.block.last_expr);
    }

    symbol_table_pop_scope(tc->symbols);
    return type;
}

static Type *typecheck_if(TypeChecker *tc, Node *node) {
    Type *cond = typecheck_node(tc, node->as.if_expr.cond);
    if (type_is_error(cond)) return cond;

    if (cond->kind != TYPE_BOOL && cond->kind != TYPE_OPTIONAL) {
        tc_error(tc, node->as.if_expr.cond->loc,
                 "if condition must be bool, got %s",
                 type_kind_name(cond->kind));
    }

    Type *then_type = typecheck_node(tc, node->as.if_expr.then_block);

    if (node->as.if_expr.else_block) {
        Type *else_type = typecheck_node(tc, node->as.if_expr.else_block);
        if (!type_eq(then_type, else_type)) {
            return tc_error_type(tc, node->loc,
                                 "if branches have different types: %s vs %s",
                                 type_kind_name(then_type->kind),
                                 type_kind_name(else_type->kind));
        }
        return then_type;
    }

    return type_new(tc->arena, TYPE_VOID);
}

static Type *typecheck_while(TypeChecker *tc, Node *node) {
    Type *cond = typecheck_node(tc, node->as.while_expr.cond);
    if (type_is_error(cond)) return cond;

    if (cond->kind != TYPE_BOOL) {
        tc_error(tc, node->as.while_expr.cond->loc,
                 "while condition must be bool, got %s",
                 type_kind_name(cond->kind));
    }

    typecheck_node(tc, node->as.while_expr.body);
    return type_new(tc->arena, TYPE_VOID);
}

static Type *typecheck_for(TypeChecker *tc, Node *node) {
    Node *iter_node = node->as.for_expr.iter;
    Type *var_type = NULL;

    if (iter_node && iter_node->kind == NODE_RANGE) {
        /* `for i in start..end` — bounds must be integers. */
        Node *start = iter_node->as.range.start;
        Node *end   = iter_node->as.range.end;

        if (!end) {
            return tc_error_type(tc, iter_node->loc,
                                 "open-ended ranges are not supported in Astra-0");
        }
        if (start) {
            Type *st = typecheck_node(tc, start);
            if (type_is_error(st)) return st;
            if (st->kind != TYPE_INT) {
                return tc_error_type(tc, start->loc,
                                     "range start must be i32, got %s",
                                     type_kind_name(st->kind));
            }
        }
        Type *et = typecheck_node(tc, end);
        if (type_is_error(et)) return et;
        if (et->kind != TYPE_INT) {
            return tc_error_type(tc, end->loc,
                                 "range end must be i32, got %s",
                                 type_kind_name(et->kind));
        }
        var_type = type_new(tc->arena, TYPE_INT);
    } else {
        Type *iter = typecheck_node(tc, iter_node);
        if (type_is_error(iter)) return iter;

        if (iter->kind != TYPE_ARRAY) {
            return tc_error_type(tc, iter_node->loc,
                                 "for loop must iterate over an array or range, got %s",
                                 type_kind_name(iter->kind));
        }
        var_type = iter->as.array.elem;
    }

    symbol_table_push_scope(tc->symbols);
    Symbol sym = {
        .name    = node->as.for_expr.var,
        .type    = var_type,
        .is_mut  = false,
        .is_fn   = false,
        .def_loc = node->loc,
    };
    symbol_table_insert(tc->symbols, sym);
    typecheck_node(tc, node->as.for_expr.body);
    symbol_table_pop_scope(tc->symbols);
    return type_new(tc->arena, TYPE_VOID);
}

/* Validate one pattern against the match target. `covered` records which
 * variants of an enum target were handled, for exhaustiveness checking. */
static void check_pattern(TypeChecker *tc, Node *pat, Type *target,
                          bool *has_wildcard, bool *covered, size_t covered_n) {
    if (!pat) return;

    switch (pat->kind) {
    case NODE_PATTERN_WILDCARD:
        *has_wildcard = true;
        return;

    case NODE_PATTERN_OR: {
        for (size_t i = 0; i < pat->as.pattern_or.alts.len; i++) {
            check_pattern(tc, pat->as.pattern_or.alts.data[i], target,
                          has_wildcard, covered, covered_n);
        }
        return;
    }

    case NODE_FIELD_ACCESS: {
        Node *obj = pat->as.field_access.object;
        if (!obj || obj->kind != NODE_IDENT) {
            tc_error(tc, pat->loc, "pattern must be a literal, `_` or Enum.Variant");
            return;
        }
        Type *et = typecheck_ident(tc, obj);
        if (type_is_error(et)) return;
        if (et->kind != TYPE_ENUM) {
            tc_error(tc, pat->loc, "pattern must be a literal, `_` or Enum.Variant");
            return;
        }
        if (!type_eq(et, target)) {
            tc_error(tc, pat->loc,
                     "pattern type %s does not match match target type %s",
                     type_kind_name(et->kind), type_kind_name(target->kind));
            return;
        }
        InternedString v = pat->as.field_access.field;
        int vi = enum_variant_index(et, v);
        if (vi < 0) {
            tc_error(tc, pat->loc, "enum '%.*s' has no variant '%.*s'",
                     (int)et->as.enumeration.name.len, et->as.enumeration.name.str,
                     (int)v.len, v.str);
            return;
        }
        if (covered && (size_t)vi < covered_n) covered[vi] = true;
        return;
    }

    /* Literal patterns (including negated literals). */
    case NODE_INT_LIT:
    case NODE_FLOAT_LIT:
    case NODE_STRING_LIT:
    case NODE_BOOL_LIT:
    case NODE_NULL_LIT:
    case NODE_UNARY_OP: {
        Type *pt = typecheck_node(tc, pat);
        if (type_is_error(pt)) return;
        if (!type_eq(pt, target)) {
            tc_error(tc, pat->loc,
                     "pattern type %s does not match match target type %s",
                     type_kind_name(pt->kind), type_kind_name(target->kind));
        }
        return;
    }

    default:
        tc_error(tc, pat->loc, "unsupported pattern in match arm");
        return;
    }
}

static Type *typecheck_match(TypeChecker *tc, Node *node) {
    Type *target = typecheck_node(tc, node->as.match_expr.target);
    if (type_is_error(target)) return target;

    size_t covered_n = (target->kind == TYPE_ENUM)
        ? target->as.enumeration.variant_count : 0;
    bool *covered = arena_new_array(tc->arena, bool, covered_n > 0 ? covered_n : 1);
    bool has_wildcard = false;

    Type *result_type = NULL;

    for (size_t i = 0; i < node->as.match_expr.arms.len; i++) {
        MatchArm *arm = &node->as.match_expr.arms.data[i];
        symbol_table_push_scope(tc->symbols);

        check_pattern(tc, arm->pattern, target, &has_wildcard, covered, covered_n);

        Type *arm_type = typecheck_node(tc, arm->body);

        if (result_type) {
            if (!type_eq(result_type, arm_type)) {
                tc_error(tc, arm->body->loc,
                         "match arm type %s does not match previous arm type %s",
                         type_kind_name(arm_type->kind),
                         type_kind_name(result_type->kind));
            }
        } else {
            result_type = arm_type;
        }

        symbol_table_pop_scope(tc->symbols);
    }

    /* Exhaustiveness: an enum match without a wildcard must cover every
     * variant (research/04 §9 and ARCHITECTURE.md §11.3). */
    if (target->kind == TYPE_ENUM && !has_wildcard) {
        for (size_t v = 0; v < covered_n; v++) {
            if (!covered[v]) {
                tc_error(tc, node->loc,
                         "non-exhaustive match: missing variant '%.*s.%.*s'",
                         (int)target->as.enumeration.name.len,
                         target->as.enumeration.name.str,
                         (int)target->as.enumeration.variants[v].len,
                         target->as.enumeration.variants[v].str);
            }
        }
    }

    return result_type ? result_type : type_new(tc->arena, TYPE_VOID);
}

static Type *typecheck_return(TypeChecker *tc, Node *node) {
    Type *value_type = type_new(tc->arena, TYPE_VOID);

    if (node->as.return_expr.value) {
        value_type = typecheck_node(tc, node->as.return_expr.value);
        if (type_is_error(value_type)) return value_type;
    }

    if (tc->current_fn_return) {
        if (!type_eq(value_type, tc->current_fn_return)) {
            return tc_error_type(tc, node->loc,
                                 "return type %s does not match function return type %s",
                                 type_kind_name(value_type->kind),
                                 type_kind_name(tc->current_fn_return->kind));
        }
    }

    return value_type;
}

static Type *typecheck_break(TypeChecker *tc, Node *node) {
    (void)node;
    return type_new(tc->arena, TYPE_VOID);
}

static Type *typecheck_continue(TypeChecker *tc, Node *node) {
    (void)node;
    return type_new(tc->arena, TYPE_VOID);
}

/* The root binding of an lvalue chain: `xs[i].name` → `xs`. Mutating through
 * an lvalue mutates the binding's referent, so the binding itself has to be
 * declared mutable — `let xs = ...; xs[0] = 9` is rejected.
 * `LValue ::= Identifier | LValue "." Identifier | LValue "[" Expression "]"`
 * (see constructs/assign.c, which owns the Assignment production;
 * research/010 §12.1 uses LValue without defining it). */
static Node *lvalue_root(Node *n) {
    while (n) {
        if (n->kind == NODE_FIELD_ACCESS)  { n = n->as.field_access.object; continue; }
        if (n->kind == NODE_INDEX)         { n = n->as.index.object;        continue; }
        return n;
    }
    return NULL;
}

static Type *typecheck_assign(TypeChecker *tc, Node *node) {
    Node *target = node->as.assign.target;
    if (!target) {
        return tc_error_type(tc, node->loc, "assignment without a target");
    }

    /* `Color.Rojo = x` parses as a field access on a type name; reject it
     * before typecheck_field_access mistakes it for a valid enum value. */
    if (target->kind == NODE_FIELD_ACCESS) {
        Type *obj = typecheck_node(tc, target->as.field_access.object);
        if (type_is_error(obj)) return obj;
        if (obj->kind == TYPE_ENUM) {
            return tc_error_type(tc, target->loc, "cannot assign to enum variant '%.*s.%.*s'",
                                 (int)obj->as.enumeration.name.len,
                                 obj->as.enumeration.name.str,
                                 (int)target->as.field_access.field.len,
                                 target->as.field_access.field.str);
        }
    }

    Node *root = lvalue_root(target);
    if (!root || root->kind != NODE_IDENT) {
        return tc_error_type(tc, target->loc, "invalid assignment target");
    }

    InternedString name = root->as.ident.name;
    Symbol *sym = symbol_table_lookup(tc->symbols, name);
    if (!sym) {
        return tc_error_type(tc, root->loc, "undefined variable '%.*s'",
                             (int)name.len, name.str);
    }

    if (sym->is_fn) {
        return tc_error_type(tc, root->loc, "cannot reassign function '%.*s'",
                             (int)name.len, name.str);
    }

    if (!sym->is_mut) {
        /* For `xs[0] = 9` the binding is the problem, not the element, so the
         * diagnostic points at the binding and says so. */
        if (target->kind != NODE_IDENT) {
            return tc_error_type(tc, root->loc,
                                 "cannot assign through immutable variable '%.*s'"
                                 " (declare it with 'let mut')",
                                 (int)name.len, name.str);
        }
        return tc_error_type(tc, root->loc, "cannot assign to immutable variable '%.*s'",
                             (int)name.len, name.str);
    }

    /* Type of the place being written. */
    Type *target_type = typecheck_node(tc, target);
    if (type_is_error(target_type)) return target_type;

    Type *val_type = typecheck_node(tc, node->as.assign.value);
    if (type_is_error(val_type)) return val_type;

    if (!type_eq(target_type, val_type)) {
        const char *what = target->kind == NODE_INDEX ? "array element"
                         : target->kind == NODE_FIELD_ACCESS ? "struct field"
                         : "variable";
        return tc_error_type(tc, node->loc,
                             "type mismatch: cannot assign %s to %s of type %s",
                             type_kind_name(val_type->kind), what,
                             type_kind_name(target_type->kind));
    }

    return target_type;
}

/* ============================================================
 * §6: Declaration Type Checking
 * ============================================================ */

static void typecheck_var_decl(TypeChecker *tc, Node *node) {
    InternedString name = node->as.var_decl.name;
    Type *decl_type = NULL;

    if (node->as.var_decl.type) {
        decl_type = resolve_type_node(tc, node->as.var_decl.type);
        if (type_is_error(decl_type)) return;
    }

    Type *val_type = NULL;
    if (node->as.var_decl.value) {
        val_type = typecheck_node(tc, node->as.var_decl.value);
        if (type_is_error(val_type)) return;
    }

    if (val_type && val_type->kind == TYPE_VOID) {
        tc_error(tc, node->loc,
                 "variable '%.*s' cannot be initialized with a void expression: "
                 "a block whose last statement ends in `;` has no value, "
                 "so leave the trailing expression without a semicolon",
                 (int)name.len, name.str);
        return;
    }

    Type *final_type;
    if (decl_type && val_type) {
        if (!type_eq(decl_type, val_type)) {
            tc_error(tc, node->loc,
                     "type mismatch: variable '%.*s' declared as %s but initialized with %s",
                     (int)name.len, name.str,
                     type_kind_name(decl_type->kind),
                     type_kind_name(val_type->kind));
        }
        final_type = decl_type;
    } else if (decl_type) {
        final_type = decl_type;
    } else if (val_type) {
        final_type = val_type;
    } else {
        tc_error(tc, node->loc,
                 "variable '%.*s' must have a type annotation or initializer",
                 (int)name.len, name.str);
        final_type = type_new(tc->arena, TYPE_ERROR);
    }

    Symbol sym = {
        .name    = name,
        .type    = final_type,
        .is_mut  = node->as.var_decl.is_mut,
        .is_fn   = false,
        .def_loc = node->loc,
    };
    symbol_table_insert(tc->symbols, sym);
}

static void typecheck_const_decl(TypeChecker *tc, Node *node) {
    InternedString name = node->as.const_decl.name;
    Type *decl_type = NULL;

    if (node->as.const_decl.type) {
        decl_type = resolve_type_node(tc, node->as.const_decl.type);
        if (type_is_error(decl_type)) return;
    }

    Type *val_type = NULL;
    if (node->as.const_decl.value) {
        val_type = typecheck_node(tc, node->as.const_decl.value);
        if (type_is_error(val_type)) return;
    }

    Type *final_type;
    if (decl_type && val_type) {
        if (!type_eq(decl_type, val_type)) {
            tc_error(tc, node->loc,
                     "type mismatch: const '%.*s' declared as %s but initialized with %s",
                     (int)name.len, name.str,
                     type_kind_name(decl_type->kind),
                     type_kind_name(val_type->kind));
        }
        final_type = decl_type;
    } else if (decl_type) {
        final_type = decl_type;
    } else if (val_type) {
        final_type = val_type;
    } else {
        tc_error(tc, node->loc,
                 "const '%.*s' must have a type annotation or initializer",
                 (int)name.len, name.str);
        final_type = type_new(tc->arena, TYPE_ERROR);
    }

    Symbol sym = {
        .name    = name,
        .type    = final_type,
        .is_mut  = false,
        .is_fn   = false,
        .def_loc = node->loc,
    };
    symbol_table_insert(tc->symbols, sym);
}

static void typecheck_fn_decl(TypeChecker *tc, Node *fn_node) {
    InternedString name = fn_node->as.fn_decl.name;

    /* Resolve parameter types */
    size_t param_count = fn_node->as.fn_decl.params.len;
    Type **param_types = arena_new_array(tc->arena, Type *, param_count);
    for (size_t i = 0; i < param_count; i++) {
        param_types[i] = resolve_type_node(tc, fn_node->as.fn_decl.param_types.data[i]);
        if (type_is_error(param_types[i])) return;
    }

    /* Resolve return type */
    Type *ret_type = NULL;
    if (fn_node->as.fn_decl.return_type) {
        ret_type = resolve_type_node(tc, fn_node->as.fn_decl.return_type);
        if (type_is_error(ret_type)) return;
    }

    Type *fn_type = type_new_fn(tc->arena, param_types, param_count, ret_type);

    /* Insert function symbol */
    Symbol sym = {
        .name    = name,
        .type    = fn_type,
        .is_mut  = false,
        .is_fn   = true,
        .def_loc = fn_node->loc,
    };

    /* Update existing symbol if forward-declared */
    Symbol *existing = symbol_table_lookup(tc->symbols, name);
    if (existing) {
        existing->type = fn_type;
    } else {
        symbol_table_insert(tc->symbols, sym);
    }

    /* Type-check body */
    if (fn_node->as.fn_decl.body) {
        typecheck_fn_body(tc, fn_node);
    }
}

/* True when `node` contains a `return` anywhere. A function whose body
 * produces no tail value is still legitimate if some path returns
 * explicitly, so the check for a missing return value has to look inside
 * statements. */
static bool node_contains_return(Node *node) {
    if (!node) return false;

    switch (node->kind) {
    case NODE_RETURN:
        return true;

    case NODE_BLOCK: {
        for (size_t i = 0; i < node->as.block.stmts.len; i++) {
            if (node_contains_return(node->as.block.stmts.data[i])) return true;
        }
        return node_contains_return(node->as.block.last_expr);
    }

    case NODE_IF:
        return node_contains_return(node->as.if_expr.then_block) ||
               node_contains_return(node->as.if_expr.else_block);

    case NODE_WHILE:
        return node_contains_return(node->as.while_expr.body);

    case NODE_FOR:
        return node_contains_return(node->as.for_expr.body);

    case NODE_MATCH: {
        for (size_t i = 0; i < node->as.match_expr.arms.len; i++) {
            if (node_contains_return(node->as.match_expr.arms.data[i].body)) return true;
        }
        return false;
    }

    default:
        return false;
    }
}

static void typecheck_fn_body(TypeChecker *tc, Node *fn_node) {
    symbol_table_push_scope(tc->symbols);

    /* Save and set current return type */
    Type *prev_return = tc->current_fn_return;
    tc->current_fn_return = fn_node->as.fn_decl.return_type
        ? resolve_type_node(tc, fn_node->as.fn_decl.return_type)
        : NULL;

    /* Insert parameters into scope */
    size_t param_count = fn_node->as.fn_decl.params.len;
    for (size_t i = 0; i < param_count; i++) {
        Type *pt = resolve_type_node(tc, fn_node->as.fn_decl.param_types.data[i]);
        Symbol sym = {
            .name    = fn_node->as.fn_decl.params.data[i],
            .type    = pt,
            .is_mut  = false,
            .is_fn   = false,
            .def_loc = fn_node->loc,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    /* Type-check body */
    if (fn_node->as.fn_decl.body) {
        Type *body_type = typecheck_node(tc, fn_node->as.fn_decl.body);

        /* The body's value must satisfy the declared return type, whether it
         * arrives through the tail expression (research/010 §4.2) or through an
         * explicit `return`. Without this `fn f() -> i32 { }` compiled cleanly
         * and returned nil at run time — the declared type simply lied. */
        Type *declared = tc->current_fn_return;
        bool declared_real = declared && declared->kind != TYPE_VOID &&
                             declared->kind != TYPE_ERROR &&
                             declared->kind != TYPE_UNKNOWN;

        if (declared_real) {
            if (body_type->kind != TYPE_VOID) {
                if (!type_eq(declared, body_type)) {
                    tc_error(tc, fn_node->loc,
                             "function '%.*s' returns %s but its body has type %s",
                             (int)fn_node->as.fn_decl.name.len,
                             fn_node->as.fn_decl.name.str,
                             type_kind_name(declared->kind),
                             type_kind_name(body_type->kind));
                }
            } else if (!node_contains_return(fn_node->as.fn_decl.body)) {
                tc_error(tc, fn_node->loc,
                         "function '%.*s' declares that it returns %s but its body "
                         "produces no value: end the body with an expression "
                         "without a trailing `;`, or add a `return`",
                         (int)fn_node->as.fn_decl.name.len,
                         fn_node->as.fn_decl.name.str,
                         type_kind_name(declared->kind));
            }
        }
    }

    tc->current_fn_return = prev_return;
    symbol_table_pop_scope(tc->symbols);
}

static void typecheck_struct_decl(TypeChecker *tc, Node *node) {
    InternedString name = node->as.struct_decl.name;

    /* Create struct type */
    Type *st_type = type_new(tc->arena, TYPE_STRUCT);
    st_type->as.struc.name = name;

    /* Populate fields */
    size_t field_count = node->as.struct_decl.field_names.len;
    if (field_count > 0) {
        st_type->as.struc.fields = arena_new_array(tc->arena, StructField, field_count);
        st_type->as.struc.field_count = field_count;
        for (size_t i = 0; i < field_count; i++) {
            Type *ft = resolve_type_node(tc, node->as.struct_decl.field_types.data[i]);
            if (type_is_error(ft)) return;
            st_type->as.struc.fields[i].name = node->as.struct_decl.field_names.data[i];
            st_type->as.struc.fields[i].type = ft;
        }
    } else {
        st_type->as.struc.fields = NULL;
        st_type->as.struc.field_count = 0;
    }

    Symbol sym = {
        .name    = name,
        .type    = st_type,
        .is_mut  = false,
        .is_fn   = false,
        .def_loc = node->loc,
    };
    symbol_table_insert(tc->symbols, sym);
}

static int enum_variant_index(Type *en, InternedString variant) {
    if (!en || en->kind != TYPE_ENUM) return -1;
    for (size_t i = 0; i < en->as.enumeration.variant_count; i++) {
        if (string_eq(en->as.enumeration.variants[i], variant)) return (int)i;
    }
    return -1;
}

static void typecheck_enum_decl(TypeChecker *tc, Node *node) {
    InternedString name = node->as.enum_decl.name;

    Type *en_type = type_new(tc->arena, TYPE_ENUM);
    en_type->as.enumeration.name = name;

    size_t nv = node->as.enum_decl.variants.len;
    en_type->as.enumeration.variant_count = nv;
    en_type->as.enumeration.variants =
        nv > 0 ? arena_new_array(tc->arena, InternedString, nv) : NULL;
    for (size_t i = 0; i < nv; i++) {
        en_type->as.enumeration.variants[i] = node->as.enum_decl.variants.data[i];
    }

    Symbol sym = {
        .name    = name,
        .type    = en_type,
        .is_mut  = false,
        .is_fn   = false,
        .def_loc = node->loc,
    };
    symbol_table_insert(tc->symbols, sym);
}

/* ============================================================
 * §7: Module Type Checking
 * ============================================================ */

static void typecheck_module_pass(TypeChecker *tc, Node *module) {
    for (size_t i = 0; i < module->as.module.items.len; i++) {
        Node *item = module->as.module.items.data[i];
        switch (item->kind) {
        case NODE_FN_DECL:
            /* First pass: register function signature only */
            {
                size_t param_count = item->as.fn_decl.params.len;
                Type **param_types = arena_new_array(tc->arena, Type *, param_count);
                for (size_t j = 0; j < param_count; j++) {
                    param_types[j] = resolve_type_node(tc, item->as.fn_decl.param_types.data[j]);
                }
                Type *ret_type = NULL;
                if (item->as.fn_decl.return_type) {
                    ret_type = resolve_type_node(tc, item->as.fn_decl.return_type);
                }
                Type *fn_type = type_new_fn(tc->arena, param_types, param_count, ret_type);
                Symbol sym = {
                    .name    = item->as.fn_decl.name,
                    .type    = fn_type,
                    .is_mut  = false,
                    .is_fn   = true,
                    .def_loc = item->loc,
                };
                symbol_table_insert(tc->symbols, sym);
            }
            break;
        case NODE_STRUCT_DECL:
            typecheck_struct_decl(tc, item);
            break;
        case NODE_ENUM_DECL:
            typecheck_enum_decl(tc, item);
            break;
        default:
            break;
        }
    }
}

static void typecheck_module_body(TypeChecker *tc, Node *module) {
    for (size_t i = 0; i < module->as.module.items.len; i++) {
        Node *item = module->as.module.items.data[i];
        switch (item->kind) {
        case NODE_FN_DECL:
            /* Skip pure declarations, only type-check bodies */
            if (item->as.fn_decl.body) {
                typecheck_fn_decl(tc, item);
            }
            break;
        case NODE_VAR_DECL:
            typecheck_var_decl(tc, item);
            break;
        case NODE_CONST_DECL:
            typecheck_const_decl(tc, item);
            break;
        default:
            typecheck_node(tc, item);
            break;
        }
    }
}

/* ============================================================
 * §8: Main Dispatch
 * ============================================================ */

static Type *typecheck_node(TypeChecker *tc, Node *node) {
    if (!node) return type_new(tc->arena, TYPE_VOID);

    switch (node->kind) {
    /* Literals */
    case NODE_INT_LIT:    return typecheck_int_lit(tc, node);
    case NODE_FLOAT_LIT:  return typecheck_float_lit(tc, node);
    case NODE_STRING_LIT: return typecheck_string_lit(tc, node);
    case NODE_BOOL_LIT:   return typecheck_bool_lit(tc, node);
    case NODE_NULL_LIT:   return typecheck_null_lit(tc, node);

    /* Expressions */
    case NODE_IDENT:      return typecheck_ident(tc, node);
    case NODE_BINARY_OP:  return typecheck_binary(tc, node);
    case NODE_UNARY_OP:   return typecheck_unary(tc, node);
    case NODE_CALL:       return typecheck_call(tc, node);
    case NODE_INDEX:      return typecheck_index(tc, node);
    case NODE_ARRAY_LIT:  return typecheck_array_lit(tc, node);
    case NODE_STRUCT_LIT: return typecheck_struct_lit(tc, node);
    case NODE_RANGE:      return tc_error_type(tc, node->loc,
                                "range expression is only valid as a for-loop iterator");
    case NODE_FIELD_ACCESS: return typecheck_field_access(tc, node);

    /* Control flow */
    case NODE_BLOCK:      return typecheck_block(tc, node);
    case NODE_IF:         return typecheck_if(tc, node);
    case NODE_WHILE:      return typecheck_while(tc, node);
    case NODE_FOR:        return typecheck_for(tc, node);
    case NODE_MATCH:      return typecheck_match(tc, node);
    case NODE_RETURN:     return typecheck_return(tc, node);
    case NODE_BREAK:      return typecheck_break(tc, node);
    case NODE_CONTINUE:   return typecheck_continue(tc, node);

    /* Assignment */
    case NODE_ASSIGN:         return typecheck_assign(tc, node);
    case NODE_COMPOUND_ASSIGN: {
        /* Treat x += e as x = x + e (using the stored operator) */
        Node *ident_node = node_new(tc->arena, NODE_IDENT, node->loc);
        ident_node->as.ident.name = node->as.assign.name;
        Node *bin = node_new(tc->arena, NODE_BINARY_OP, node->loc);
        bin->as.binary.op    = node->as.assign.op;
        bin->as.binary.left  = ident_node;
        bin->as.binary.right = node->as.assign.value;
        Node *assign = node_new(tc->arena, NODE_ASSIGN, node->loc);
        assign->as.assign.name  = node->as.assign.name;
        assign->as.assign.value = bin;
        return typecheck_assign(tc, assign);
    }

    /* Declarations */
    case NODE_FN_DECL:      typecheck_fn_decl(tc, node); return type_new(tc->arena, TYPE_VOID);
    case NODE_STRUCT_DECL:  typecheck_struct_decl(tc, node); return type_new(tc->arena, TYPE_VOID);
    case NODE_ENUM_DECL:    typecheck_enum_decl(tc, node); return type_new(tc->arena, TYPE_VOID);
    case NODE_VAR_DECL:     typecheck_var_decl(tc, node); return type_new(tc->arena, TYPE_VOID);
    case NODE_CONST_DECL:   typecheck_const_decl(tc, node); return type_new(tc->arena, TYPE_VOID);

    /* Module */
    case NODE_MODULE:
        typecheck_module_pass(tc, node);
        typecheck_module_body(tc, node);
        return type_new(tc->arena, TYPE_VOID);

    default:
        return tc_error_type(tc, node->loc, "unhandled node kind %d", node->kind);
    }
}

/* ============================================================
 * §9: Public API
 * ============================================================ */

Type *typecheck(TypeChecker *tc, Node *node) {
    return typecheck_node(tc, node);
}
