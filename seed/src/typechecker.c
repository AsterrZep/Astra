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

/* True for the signed/unsigned integer kinds, including the polymorphic
 * literal kind. Bitwise operators, indices, ranges and the length of an array all
 * want "integer", not "numeric", and they had six copies of that enumeration
 * between them; a literal has to be accepted by all of them or `a[0]` and
 * `0..n` would stop working. */
static bool type_is_integer(Type *t) {
    return t && (t->kind == TYPE_INT || t->kind == TYPE_INT64 ||
                 t->kind == TYPE_UINT32 || t->kind == TYPE_UINT64 ||
                 t->kind == TYPE_INT_LITERAL);
}

bool type_eq(Type *a, Type *b) {
    if (!a || !b) return a == b;
    /* TYPE_UNKNOWN matches any type (for built-in polymorphic functions) */
    if (a->kind == TYPE_UNKNOWN || b->kind == TYPE_UNKNOWN) return true;
    /* TYPE_NIL matches any TYPE_OPTIONAL (none can be assigned to any Option) */
    if ((a->kind == TYPE_NIL && b->kind == TYPE_OPTIONAL) ||
        (a->kind == TYPE_OPTIONAL && b->kind == TYPE_NIL)) return true;
    /* An integer literal adopts the integer type it meets. This is the whole
     * adoption rule: it is what makes `let x: i64 = 5`, `f(5)` for `f(x: u32)`,
     * `return 0` in `-> i64`, `P { x: 5 }` and `0..n` work without a coercion
     * (no value changes type — the literal simply did not have one yet). */
    if (a->kind == TYPE_INT_LITERAL && b->kind != TYPE_INT_LITERAL)
        return type_is_integer(b);
    if (b->kind == TYPE_INT_LITERAL && a->kind != TYPE_INT_LITERAL)
        return type_is_integer(a);
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
    case TYPE_PARAM:
        return a->as.type_param.owner == b->as.type_param.owner &&
               string_eq(a->as.type_param.name, b->as.type_param.name);
    default:
        return true;
    }
}

static bool type_is_numeric(Type *t) {
    return t && (type_is_integer(t) || t->kind == TYPE_FLOAT);
}

/* The type an arithmetic or bitwise operation yields once integer literals have
 * adopted a type. `i64 + 1` is i64, not "still a literal": the literal takes the
 * type of the operand that has one, and if neither has one the result stays
 * untyped until some context gives it a type. */
static Type *numeric_result_type(Type *left, Type *right) {
    if (left->kind == TYPE_INT_LITERAL) return right;
    return left;
}

static bool type_is_error(Type *t) {
    return t && t->kind == TYPE_ERROR;
}

static const char *type_kind_name(TypeKind kind) {
    switch (kind) {
    case TYPE_VOID:     return "void";
    case TYPE_BOOL:     return "bool";
    case TYPE_INT:      return "i32";
    case TYPE_INT_LITERAL: return "integer literal";
    case TYPE_INT64:    return "i64";
    case TYPE_UINT32:   return "u32";
    case TYPE_UINT64:   return "u64";
    case TYPE_FLOAT:    return "f64";
    case TYPE_STRING:   return "string";
    case TYPE_OPTIONAL: return "optional";
    case TYPE_ARRAY:    return "array";
    case TYPE_FN:       return "fn";
    case TYPE_STRUCT:   return "struct";
    case TYPE_ENUM:     return "enum";
    case TYPE_NIL:      return "nil";
    case TYPE_PARAM:    return "type parameter";
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
    case TYPE_INT_LITERAL: printf("integer literal"); break;
    case TYPE_INT64:    printf("i64");      break;
    case TYPE_UINT32:   printf("u32");     break;
    case TYPE_UINT64:   printf("u64");     break;
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
    case TYPE_NIL:      printf("nil");      break;
    case TYPE_PARAM:
        printf("%.*s", (int)t->as.type_param.name.len, t->as.type_param.name.str);
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

/* One entry per declared variant, in registration order. Variant names do
 * not live in the symbol table (they are not bindings), so a data-carrying
 * construction `Paso(x)` cannot resolve through it; this flat registry is
 * the checker's view of "which enum does this variant name belong to".
 * DEC-008 (research/027 §4): the bare spelling is only legal for the
 * built-in Option/Result variants (`some/ok/err/none`), so every entry
 * records which kind it is. */
typedef struct {
    InternedString variant;
    Type          *enum_type;
    bool           builtin;
} VariantEntry;

/* One entry per method declared in an `impl` block (research/001 §12). The
 * registry is keyed by the receiver's *nominal* type name plus the method
 * name — there is no vtable: `x.m()` resolves at compile time to the mangled
 * global `Type.method` (static dispatch, Phase 2.3 step 3-4). `fn_type`
 * includes the receiver as parameter 0, so a call site checks its arguments
 * against `params[1..]`. `trait_name` is empty for an inherent impl and
 * participates in the duplicate check, so an inherent method may shadow a
 * trait method of the same name (precedence: inherent first). */
typedef struct {
    InternedString type_name;
    InternedString method_name;
    InternedString trait_name; /* empty for an inherent impl */
    InternedString global;     /* mangled runtime global `Type.method` */
    bool           inherent;
    Type          *fn_type;    /* fn(self: T, ...) -> R */
    SrcLoc         loc;        /* the impl item, for conformance errors */
} MethodEntry;

/* Trait signature registry (Phase 2.3 step 5): a trait declaration is a list
 * of required method signatures (research/001 §12). Signatures are collected
 * in their own pre-pass so an `impl T for X` may appear before `trait T`,
 * and a body on a trait item is rejected there — default methods are a later
 * phase. */
typedef struct {
    InternedString name;
    Type         **param_types; /* parameters after `self` */
    size_t         param_count;
    Type          *ret;         /* NULL when the signature omits `->` */
} TraitMethod;

typedef struct {
    InternedString name;
    TraitMethod   *methods;
    size_t         method_count;
} TraitInfo;

/* One `impl T for X` block (Phase 2.4 step 4): bound checking asks this
 * registry whether a concrete type carries the trait. The method table
 * alone cannot answer — an impl of a method-less trait registers no method
 * entry, so scanning it would report a satisfied bound as missing. */
typedef struct {
    InternedString type_name;
    InternedString trait_name;
} ImplRecord;

typedef struct { InternedString name; Type *type; } GenericBinding;

struct TypeChecker {
    Arena     *arena;
    StringTable *strings;
    SymbolTable *symbols;
    Type      *current_fn_return; /* return type of enclosing fn, or NULL */
    /* Depth of enclosing fn/lambda bodies: `current_fn_return` is also NULL
     * for an *unannotated* fn, so module scope is detected with this
     * counter, not with the annotation (audit §4.5). */
    int        fn_depth;
    /* Generic parameters of the fn currently being checked (Phase 2.4 step
     * 2a): a flat stack with save/restore marks, so `T` in an annotation
     * resolves to the enclosing generic fn's placeholder. */
    GenericBinding *generic_stack;
    size_t     generic_len;
    /* The generic fn whose body is being checked (Phase 2.4 step 2b):
     * call sites whose bindings still mention its parameters are recorded
     * as pending and resolved per instance. */
    Node      *current_generic_fn;
    int        error_count;
    /* Phase 2.4 step 2b: instantiations materialized so far, and the
     * not-yet-concrete call sites inside generic bodies that reference
     * them. Both arena-owned, grown geometrically. */
    GenericInstance *instances;
    size_t     inst_count;
    size_t     inst_cap;
    struct {
        Node *fn_decl;     /* the generic fn whose body holds the call */
        Node *callee;      /* the callee NODE_IDENT inside that body */
        Node *target;      /* the generic fn being called */
        GenericBinding *bindings;
        size_t binding_count;
    } *pending;
    size_t     pending_count;
    size_t     pending_cap;
    VariantEntry *variants;
    size_t     variant_count;
    size_t     variant_cap;
    MethodEntry *methods;
    size_t     method_count;
    size_t     method_cap;
    TraitInfo  *traits;
    size_t     trait_count;
    size_t     trait_cap;
    ImplRecord *impls;
    size_t     impl_count;
    size_t     impl_cap;
};

static void checker_add_variant(TypeChecker *tc, InternedString variant, Type *et, bool builtin) {
    if (tc->variant_count >= tc->variant_cap) {
        size_t nc = tc->variant_cap == 0 ? 16 : tc->variant_cap * 2;
        VariantEntry *nd = arena_new_array(tc->arena, VariantEntry, nc);
        if (tc->variants) {
            memcpy(nd, tc->variants, sizeof(VariantEntry) * tc->variant_count);
        }
        tc->variants = nd;
        tc->variant_cap = nc;
    }
    tc->variants[tc->variant_count].variant   = variant;
    tc->variants[tc->variant_count].enum_type = et;
    tc->variants[tc->variant_count].builtin   = builtin;
    tc->variant_count++;
}

/* First registry entry for `name`, or NULL. `builtin` (when non-NULL)
 * reports whether it is one of the Option/Result variants, which are the
 * only ones the bare spelling `some(x)` may still construct. */
static Type *checker_find_variant(TypeChecker *tc, InternedString name, bool *builtin) {
    for (size_t i = 0; i < tc->variant_count; i++) {
        if (string_eq(tc->variants[i].variant, name)) {
            if (builtin) *builtin = tc->variants[i].builtin;
            return tc->variants[i].enum_type;
        }
    }
    return NULL;
}

static void tc_error(TypeChecker *tc, SrcLoc loc, const char *fmt, ...);

/* The runtime global a method compiles to: `Type.method` for an inherent
 * impl, `Type.Trait.method` for a trait impl. The trait segment keeps two
 * impls of the same method name from sharing one runtime slot — without it
 * the inherent and the trait version of `show` both write `Point.show` and
 * emission order alone decides which one every call site gets (the VM masks
 * it as last-write-wins; the C backend maps a name to one function and
 * silently kept the first). No module prefix: the seed is one file, and '.'
 * cannot collide with a source identifier (codegen sanitizes it to '_'). */
static InternedString checker_method_global(TypeChecker *tc,
                                            InternedString type_name,
                                            InternedString trait_name,
                                            InternedString method_name) {
    size_t len = type_name.len + 1;
    if (trait_name.str) len += trait_name.len + 1;
    len += method_name.len;
    char *buf = arena_alloc(tc->arena, len + 1, 1);
    if (!buf) return method_name;
    char *p = buf;
    memcpy(p, type_name.str, type_name.len);
    p += type_name.len;
    *p++ = '.';
    if (trait_name.str) {
        memcpy(p, trait_name.str, trait_name.len);
        p += trait_name.len;
        *p++ = '.';
    }
    memcpy(p, method_name.str, method_name.len);
    p += method_name.len;
    *p = '\0';
    return string_intern(tc->strings, buf, len);
}

static void checker_add_method(TypeChecker *tc, InternedString type_name,
                               InternedString method_name,
                               InternedString trait_name, bool inherent,
                               Type *fn_type, SrcLoc loc) {
    for (size_t i = 0; i < tc->method_count; i++) {
        MethodEntry *m = &tc->methods[i];
        if (string_eq(m->type_name, type_name) &&
            string_eq(m->method_name, method_name) &&
            string_eq(m->trait_name, trait_name)) {
            tc_error(tc, loc, "method '%.*s' is already defined for type '%.*s'",
                     (int)method_name.len, method_name.str,
                     (int)type_name.len, type_name.str);
            return;
        }
    }
    if (tc->method_count >= tc->method_cap) {
        size_t nc = tc->method_cap == 0 ? 16 : tc->method_cap * 2;
        MethodEntry *nd = arena_new_array(tc->arena, MethodEntry, nc);
        if (tc->methods) {
            memcpy(nd, tc->methods, sizeof(MethodEntry) * tc->method_count);
        }
        tc->methods = nd;
        tc->method_cap = nc;
    }
    tc->methods[tc->method_count] = (MethodEntry){
        .type_name   = type_name,
        .method_name = method_name,
        .trait_name  = trait_name,
        .global      = checker_method_global(tc, type_name, trait_name, method_name),
        .inherent    = inherent,
        .fn_type     = fn_type,
        .loc         = loc,
    };
    tc->method_count++;
}

/* Static-dispatch lookup for `recv.name()`. Inherent impls beat trait impls
 * regardless of declaration order; between trait impls the first declared
 * wins (ambiguity across traits is a documented Phase 2.4 limitation). Only
 * struct and enum receivers have a nominal name, so primitives resolve to
 * nothing — the impl pass rejects them up front. */
static MethodEntry *checker_find_method(TypeChecker *tc, Type *recv,
                                        InternedString name) {
    if (!recv) return NULL;
    InternedString tname;
    if (recv->kind == TYPE_STRUCT) {
        tname = recv->as.struc.name;
    } else if (recv->kind == TYPE_ENUM) {
        tname = recv->as.enumeration.name;
    } else {
        return NULL;
    }
    MethodEntry *trait_fallback = NULL;
    for (size_t i = 0; i < tc->method_count; i++) {
        MethodEntry *m = &tc->methods[i];
        if (!string_eq(m->method_name, name) ||
            !string_eq(m->type_name, tname)) {
            continue;
        }
        if (m->inherent) return m;
        if (!trait_fallback) trait_fallback = m;
    }
    return trait_fallback;
}

static void checker_add_trait(TypeChecker *tc, InternedString name,
                              TraitMethod *methods, size_t method_count) {
    if (tc->trait_count >= tc->trait_cap) {
        size_t nc = tc->trait_cap == 0 ? 8 : tc->trait_cap * 2;
        TraitInfo *nd = arena_new_array(tc->arena, TraitInfo, nc);
        if (tc->traits) {
            memcpy(nd, tc->traits, sizeof(TraitInfo) * tc->trait_count);
        }
        tc->traits = nd;
        tc->trait_cap = nc;
    }
    tc->traits[tc->trait_count] = (TraitInfo){
        .name         = name,
        .methods      = methods,
        .method_count = method_count,
    };
    tc->trait_count++;
}

static TraitInfo *checker_find_trait(TypeChecker *tc, InternedString name) {
    for (size_t i = 0; i < tc->trait_count; i++) {
        if (string_eq(tc->traits[i].name, name)) return &tc->traits[i];
    }
    return NULL;
}

/* Phase 2.4 step 4: record `impl T for X` so bound checking can ask whether
 * a concrete type carries a trait. Appended for every trait impl whose
 * target resolved to a struct/enum — conformance errors do not remove it
 * (the compile already failed, and a partial impl still names intent). */
static void checker_add_impl(TypeChecker *tc, InternedString type_name,
                             InternedString trait_name) {
    if (tc->impl_count >= tc->impl_cap) {
        size_t nc = tc->impl_cap == 0 ? 8 : tc->impl_cap * 2;
        ImplRecord *nd = arena_new_array(tc->arena, ImplRecord, nc);
        if (tc->impls) {
            memcpy(nd, tc->impls, sizeof(ImplRecord) * tc->impl_count);
        }
        tc->impls = nd;
        tc->impl_cap = nc;
    }
    tc->impls[tc->impl_count] = (ImplRecord){
        .type_name  = type_name,
        .trait_name = trait_name,
    };
    tc->impl_count++;
}

/* Does the concrete type `ty` carry an `impl T for ...` record? Nominal
 * types answer by name; everything else cannot have an impl at all (the
 * impl pass requires struct or enum), and TYPE_PARAM is abstract — the
 * caller skips it before reaching here. */
static bool impl_record_exists(TypeChecker *tc, Type *ty,
                               InternedString trait_name) {
    InternedString tn;
    if (ty->kind == TYPE_STRUCT) tn = ty->as.struc.name;
    else if (ty->kind == TYPE_ENUM) tn = ty->as.enumeration.name;
    else return false;
    for (size_t i = 0; i < tc->impl_count; i++) {
        if (string_eq(tc->impls[i].type_name, tn) &&
            string_eq(tc->impls[i].trait_name, trait_name))
            return true;
    }
    return false;
}

/* Exact (type, method, trait) lookup for conformance — unlike
 * checker_find_method it never falls back to an inherent entry or another
 * trait of the same name. */
static MethodEntry *checker_find_trait_method(TypeChecker *tc,
                                              InternedString type_name,
                                              InternedString method_name,
                                              InternedString trait_name) {
    for (size_t i = 0; i < tc->method_count; i++) {
        MethodEntry *m = &tc->methods[i];
        if (string_eq(m->type_name, type_name) &&
            string_eq(m->method_name, method_name) &&
            string_eq(m->trait_name, trait_name)) {
            return m;
        }
    }
    return NULL;
}

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

    /* len(value) -> i64 — length of an array or a string (DEC-013,
     * research/028 PR1). The parameter is unknown like print's, so any
     * receiver is accepted at compile time and each runtime words its
     * defensive rejection identically (`cannot take length of int`), the
     * same text the OPCODE_LEN handlers already use. */
    {
        Type **params = arena_new_array(arena, Type *, 1);
        params[0] = type_new(arena, TYPE_UNKNOWN);
        Type *len_type = type_new_fn(arena, params, 1, type_new(arena, TYPE_INT64));
        Symbol sym = {
            .name = string_intern_cstr(strings, "len"),
            .type = len_type,
            .is_mut = false,
            .is_fn = true,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    /* to_string(value) -> string — int -> string, el conversor mínimo que
     * desbloquea salida con números (research/028 PR2, DEC-014). El
     * parámetro es unknown como el de print: el checker no puede expresar
     * "cualquier entero" sin romper la regla de literal i32 por defecto
     * (DEC-006), así que cada runtime rechaza valores no enteros con el
     * mismo texto defensivo (`to_string expects an int, got <tipo>`). */
    {
        Type **params = arena_new_array(arena, Type *, 1);
        params[0] = type_new(arena, TYPE_UNKNOWN);
        Type *ts_type = type_new_fn(arena, params, 1, type_new(arena, TYPE_STRING));
        Symbol sym = {
            .name = string_intern_cstr(strings, "to_string"),
            .type = ts_type,
            .is_mut = false,
            .is_fn = true,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    /* read_file(path: string) -> string — la semilla de I/O que desbloquea
     * `demo/lexer.astra` (research/028 PR2, DEC-014). El parámetro está
     * anotado string, así que `read_file(42)` es error de compilación; los
     * fallos de apertura/lectura son runtime error unificado
     * `cannot open file '<path>'` en las cuatro rutas. */
    {
        Type **params = arena_new_array(arena, Type *, 1);
        params[0] = type_new(arena, TYPE_STRING);
        Type *rf_type = type_new_fn(arena, params, 1, type_new(arena, TYPE_STRING));
        Symbol sym = {
            .name = string_intern_cstr(strings, "read_file"),
            .type = rf_type,
            .is_mut = false,
            .is_fn = true,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    /* ord(s) -> i64 — primer BYTE de un string (DEC-018, research/028 M2a).
     * El parámetro es unknown como el de print/len/to_string: el rechazo es
     * de runtime con el `type_name` del VM (`ord expects a string, got <tipo>`
     * y `ord() of empty string`), que las cuatro rutas escriben igual. */
    {
        Type **params = arena_new_array(arena, Type *, 1);
        params[0] = type_new(arena, TYPE_UNKNOWN);
        Type *ord_type = type_new_fn(arena, params, 1, type_new(arena, TYPE_INT64));
        Symbol sym = {
            .name = string_intern_cstr(strings, "ord"),
            .type = ord_type,
            .is_mut = false,
            .is_fn = true,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    /* substr(s, start, len) -> string — subcadena de `len` bytes desde
     * `start` (DEC-018, research/028 M2a). Los tres parámetros son unknown
     * porque Astra-0 no tiene coerción en la llamada (`type_eq` exacto): un
     * parámetro anotado i64 rechazaría `substr(s, 1, 3)` (literal i32 por
     * DEC-006) y `len(s)` (i64) no calzaría con un i32 anotado. El checker
     * acepta cualquier valor y cada runtime rechaza con el mismo texto. */
    {
        Type **params = arena_new_array(arena, Type *, 3);
        params[0] = type_new(arena, TYPE_UNKNOWN);
        params[1] = type_new(arena, TYPE_UNKNOWN);
        params[2] = type_new(arena, TYPE_UNKNOWN);
        Type *sub_type = type_new_fn(arena, params, 3, type_new(arena, TYPE_STRING));
        Symbol sym = {
            .name = string_intern_cstr(strings, "substr"),
            .type = sub_type,
            .is_mut = false,
            .is_fn = true,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    /* push(arr, value) -> array — un array NUEVO con value añadido al final
     * (DEC-019, research/028 M2b): el llamante re-bindea (`a = push(a, x)`),
     * así el array viejo queda intacto para quien lo retenga. Los dos
     * parámetros son unknown (patrón print/len, DEC-018): el receptor se
     * rechaza en runtime con `push expects an array, got <tipo>` y el
     * elemento con `push element has type X, expected Y` — el checker no
     * puede comparar el elemento contra el tipo del array sin romper la
     * adopción de literales (DEC-006). El retorno es array<unknown>: `let b
     * = push(a, 1)` hereda un array cuyo elemento se sigue chequeando por
     * uso. */
    {
        Type **params = arena_new_array(arena, Type *, 2);
        params[0] = type_new(arena, TYPE_UNKNOWN);
        params[1] = type_new(arena, TYPE_UNKNOWN);
        Type *elem = type_new(arena, TYPE_UNKNOWN);
        Type *push_type = type_new_fn(arena, params, 2, type_new_array(arena, elem, NULL));
        Symbol sym = {
            .name = string_intern_cstr(strings, "push"),
            .type = push_type,
            .is_mut = false,
            .is_fn = true,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    /* str_to_int(s) -> i64 — el decimal que to_string produce, redondeando
     * `str_to_int(to_string(n))` (DEC-019, research/028 M2b). Parámetro
     * unknown como ord: receptor no-string → `str_to_int expects a string,
     * got <tipo>` en runtime; entrada inválida (incluido "") o fuera de
     * rango i64 → error de runtime, no un optional — el estilo del repo es
     * el error consistente de substr bounds, y un `i64?` obligaría a
     * construir some/none desde un builtin en las cuatro rutas. */
    {
        Type **params = arena_new_array(arena, Type *, 1);
        params[0] = type_new(arena, TYPE_UNKNOWN);
        Type *sti_type = type_new_fn(arena, params, 1, type_new(arena, TYPE_INT64));
        Symbol sym = {
            .name = string_intern_cstr(strings, "str_to_int"),
            .type = sti_type,
            .is_mut = false,
            .is_fn = true,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    /* Register built-in Option enum: some(T) -> Option[T], none -> Option[T] */
    {
        Type *opt_type = type_new(arena, TYPE_ENUM);
        opt_type->as.enumeration.name = string_intern_cstr(strings, "Option");
        opt_type->as.enumeration.variant_count = 2;
        opt_type->as.enumeration.variants = arena_new_array(arena, InternedString, 2);
        opt_type->as.enumeration.variants[0] = string_intern_cstr(strings, "some");
        opt_type->as.enumeration.variants[1] = string_intern_cstr(strings, "none");
        opt_type->as.enumeration.payloads = arena_new_array(arena, VariantLayout, 2);
        /* some(T): one payload of unknown type */
        opt_type->as.enumeration.payloads[0].field_count = 1;
        opt_type->as.enumeration.payloads[0].types = arena_new_array(arena, Type *, 1);
        opt_type->as.enumeration.payloads[0].types[0] = type_new(arena, TYPE_UNKNOWN);
        opt_type->as.enumeration.payloads[0].names = NULL;
        /* none: unit variant, no payload */
        opt_type->as.enumeration.payloads[1].field_count = 0;
        opt_type->as.enumeration.payloads[1].types = NULL;
        opt_type->as.enumeration.payloads[1].names = NULL;

        checker_add_variant(tc, string_intern_cstr(strings, "some"), opt_type, true);
        checker_add_variant(tc, string_intern_cstr(strings, "none"), opt_type, true);
    }

    /* Register built-in Result enum: ok(T) -> Result[T, E], err(E) -> Result[T, E] */
    {
        Type *res_type = type_new(arena, TYPE_ENUM);
        res_type->as.enumeration.name = string_intern_cstr(strings, "Result");
        res_type->as.enumeration.variant_count = 2;
        res_type->as.enumeration.variants = arena_new_array(arena, InternedString, 2);
        res_type->as.enumeration.variants[0] = string_intern_cstr(strings, "ok");
        res_type->as.enumeration.variants[1] = string_intern_cstr(strings, "err");
        res_type->as.enumeration.payloads = arena_new_array(arena, VariantLayout, 2);
        /* ok(T): one payload of unknown type */
        res_type->as.enumeration.payloads[0].field_count = 1;
        res_type->as.enumeration.payloads[0].types = arena_new_array(arena, Type *, 1);
        res_type->as.enumeration.payloads[0].types[0] = type_new(arena, TYPE_UNKNOWN);
        res_type->as.enumeration.payloads[0].names = NULL;
        /* err(E): one payload of unknown type */
        res_type->as.enumeration.payloads[1].field_count = 1;
        res_type->as.enumeration.payloads[1].types = arena_new_array(arena, Type *, 1);
        res_type->as.enumeration.payloads[1].types[0] = type_new(arena, TYPE_UNKNOWN);
        res_type->as.enumeration.payloads[1].names = NULL;

        checker_add_variant(tc, string_intern_cstr(strings, "ok"), res_type, true);
        checker_add_variant(tc, string_intern_cstr(strings, "err"), res_type, true);
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
static Type *resolve_type_with_args(TypeChecker *tc, Node *node, InternedString name);
static Type *ensure_struct_instance(TypeChecker *tc, Node *decl,
                                    GenericBinding *env, size_t env_n,
                                    SrcLoc loc);

/* --- Forward Declarations --- */

static Type *typecheck_node(TypeChecker *tc, Node *node);
static void  typecheck_fn_body(TypeChecker *tc, Node *fn_node);
static int   enum_variant_index(Type *en, InternedString variant);

/* ============================================================
 * §4: Type Resolution
 * ============================================================ */

/* Phase 2.4 step 2a: bind the `<T, U: Show>` parameters of `fn` as TYPE_PARAM
 * placeholders for the duration of the signature and body check. The owner
 * pointer makes `T` of two different fns distinct even when they share a
 * name. Save/restore the mark like `current_fn_return` — a nested generic
 * fn (an impl method) may push its own. Step 3b: struct declarations reuse
 * this with their own `<...>` list, owning the parameters for field
 * resolution and literal unification. */
static size_t push_generic_bindings(TypeChecker *tc, NodeList *gens, Node *owner) {
    size_t mark = tc->generic_len;
    size_t n = gens->len;
    for (size_t i = 0; i < n; i++) {
        Node *tp = gens->data[i];
        if (!tp || tp->kind != NODE_TYPE_PARAM) continue;
        /* Step 4: every bound must name a known trait. Checked at binding
         * time (eager, like Rust): the trait pre-pass has run before any
         * signature or field resolves, so the registry is complete. Only
         * fn and struct declarations bind their parameters — enum/trait/
         * impl generics stay inert until their own step. */
        for (size_t j = 0; j < tp->as.type_param.bounds.len; j++) {
            Node *b = tp->as.type_param.bounds.data[j];
            if (!b || b->kind != NODE_TYPE_IDENT) continue;
            InternedString bound = b->as.type_ident.name;
            if (!checker_find_trait(tc, bound))
                tc_error(tc, b->loc, "unknown trait '%.*s'",
                         (int)bound.len, bound.str);
        }
        Type *pt = type_new(tc->arena, TYPE_PARAM);
        pt->as.type_param.name  = tp->as.type_param.name;
        pt->as.type_param.owner = owner;
        if (tc->generic_len >= 32) break; /* the parser caps the list at 32 */
        if (!tc->generic_stack) {
            tc->generic_stack = arena_new_array(tc->arena, GenericBinding, 32);
        }
        tc->generic_stack[tc->generic_len].name = tp->as.type_param.name;
        tc->generic_stack[tc->generic_len].type = pt;
        tc->generic_len++;
    }
    return mark;
}

static size_t push_generic_scope(TypeChecker *tc, Node *fn) {
    return push_generic_bindings(tc, &fn->as.fn_decl.generics, fn);
}

static void pop_generic_scope(TypeChecker *tc, size_t mark) {
    tc->generic_len = mark;
}

static Type *resolve_type_node(TypeChecker *tc, Node *node) {
    if (!node) return NULL;

    switch (node->kind) {
    case NODE_TYPE_IDENT: {
        InternedString name = node->as.type_ident.name;
        if (name.len == 4 && memcmp(name.str, "void", 4) == 0) return type_new(tc->arena, TYPE_VOID);
        if (name.len == 4 && memcmp(name.str, "bool", 4) == 0) return type_new(tc->arena, TYPE_BOOL);
        if (name.len == 3 && memcmp(name.str, "i32", 3) == 0) return type_new(tc->arena, TYPE_INT);
        if (name.len == 3 && memcmp(name.str, "i64", 3) == 0) return type_new(tc->arena, TYPE_INT64);
        if (name.len == 3 && memcmp(name.str, "u32", 3) == 0) return type_new(tc->arena, TYPE_UINT32);
        if (name.len == 3 && memcmp(name.str, "u64", 3) == 0) return type_new(tc->arena, TYPE_UINT64);
        if (name.len == 3 && memcmp(name.str, "f64", 3) == 0) return type_new(tc->arena, TYPE_FLOAT);
        if (name.len == 6 && memcmp(name.str, "string", 6) == 0) return type_new(tc->arena, TYPE_STRING);

        /* Type arguments (Phase 2.4 step 3b): `Box<i32>` materializes a
         * cached instance of the generic declaration. Primitives above never
         * take arguments, and a bare unknown base keeps the plain message
         * so `Vec<Vec<i32>>` still reports the missing name first. */
        if (node->as.type_ident.generics.len > 0)
            return resolve_type_with_args(tc, node, name);

        /* A generic parameter of the fn being checked shadows every other
         * binding (Phase 2.4 step 2a). */
        for (size_t i = tc->generic_len; i > 0; i--) {
            if (string_eq(tc->generic_stack[i - 1].name, name))
                return tc->generic_stack[i - 1].type;
        }

        /* Check for struct/enum types in symbol table */
        Symbol *sym = symbol_table_lookup(tc->symbols, name);
        if (sym && sym->type) {
            /* The declaration exists but its `<...>` list was omitted. */
            if (sym->is_generic && sym->type->kind == TYPE_STRUCT)
                return tc_error_type(tc, node->loc,
                                     "type '%.*s' requires type arguments",
                                     (int)name.len, name.str);
            return sym->type;
        }

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
    /* No type yet: the literal adopts one from its context (see type_eq). */
    return type_new(tc->arena, TYPE_INT_LITERAL);
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

static Type *typecheck_ident(TypeChecker *tc, Node *node) {
    InternedString name = node->as.ident.name;
    Symbol *sym = symbol_table_lookup(tc->symbols, name);
    if (!sym) {
        return tc_error_type(tc, node->loc, "undefined variable '%.*s'",
                             (int)name.len, name.str);
    }
    /* Phase 2.4 step 2a: a generic function has no single runtime value
     * before call-site inference names an instance. */
    if (sym->is_fn && sym->is_generic) {
        return tc_error_type(tc, node->loc,
                             "generic function '%.*s' used as a value",
                             (int)name.len, name.str);
    }
    if (!sym->type) {
        /* Every binding path types its symbol (lambda and fn parameters
         * without an annotation default to unknown at insertion). A symbol
         * that still reaches here without a type degrades to unknown — the
         * same flow zig uses — instead of seed's old "has no type" error,
         * which diverged from zig and pointed at the symptom rather than
         * the untyped binding (audit §1.6/§3.6). */
        return type_new(tc->arena, TYPE_UNKNOWN);
    }
    return sym->type;
}

static const char *op_symbol(BinaryOp op) {
    switch (op) {
    case OP_ADD: return "+";
    case OP_SUB: return "-";
    case OP_MUL: return "*";
    case OP_DIV: return "/";
    case OP_MOD: return "%";
    case OP_EQ:  return "==";
    case OP_NEQ: return "!=";
    case OP_LT:  return "<";
    case OP_GT:  return ">";
    case OP_LE:  return "<=";
    case OP_GE:  return ">=";
    case OP_AND: return "and";
    case OP_OR:  return "or";
    case OP_BIT_AND: return "&";
    case OP_BIT_OR:  return "|";
    case OP_BIT_XOR: return "^";
    case OP_SHL: return "<<";
    case OP_SHR: return ">>";
    }
    return "?";
}

static Type *typecheck_binary(TypeChecker *tc, Node *node) {
    Type *left  = typecheck_node(tc, node->as.binary.left);
    Type *right = typecheck_node(tc, node->as.binary.right);

    if (type_is_error(left))  return left;
    if (type_is_error(right)) return right;

    BinaryOp op = node->as.binary.op;

    /* Phase 2.4 step 2a: a type parameter carries no operations of its own.
     * Bounds (`<T: Show>`) land with step 4; until then only pass-through
     * (calls, returns, bindings) is valid. */
    if (left->kind == TYPE_PARAM || right->kind == TYPE_PARAM) {
        Type *tp = left->kind == TYPE_PARAM ? left : right;
        return tc_error_type(tc, node->loc,
                             "operator '%s' cannot be applied to type parameter '%.*s'",
                             op_symbol(op),
                             (int)tp->as.type_param.name.len,
                             tp->as.type_param.name.str);
    }

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

    /* String concatenation: string + string -> string */
    if (op == OP_ADD && left->kind == TYPE_STRING && right->kind == TYPE_STRING) {
        return left;
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
                                 op_symbol(op),
                                 type_kind_name(left->kind),
                                 type_kind_name(right->kind));
        }
        return numeric_result_type(left, right);
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
        if (!type_is_integer(left)) {
            return tc_error_type(tc, node->as.binary.left->loc,
                                 "bitwise operator requires integer type, got %s",
                                 type_kind_name(left->kind));
        }
        if (!type_is_integer(right)) {
            return tc_error_type(tc, node->as.binary.right->loc,
                                 "bitwise operator requires integer type, got %s",
                                 type_kind_name(right->kind));
        }
        return numeric_result_type(left, right);
    }

    return type_new(tc->arena, TYPE_ERROR);
}

static Type *typecheck_unary(TypeChecker *tc, Node *node) {
    Type *operand = typecheck_node(tc, node->as.unary.operand);
    if (type_is_error(operand)) return operand;

    UnaryOp op = node->as.unary.op;

    /* Phase 2.4 step 2a: see the binary counterpart. */
    if (operand->kind == TYPE_PARAM) {
        return tc_error_type(tc, node->loc,
                             "operator not applicable to type parameter '%.*s'",
                             (int)operand->as.type_param.name.len,
                             operand->as.type_param.name.str);
    }

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
        {
            if (!type_is_integer(operand)) {
                return tc_error_type(tc, node->loc,
                                     "bitwise not requires integer type, got %s",
                                     type_kind_name(operand->kind));
            }
            return operand;
        }
    case UNOP_REF:
    case UNOP_DEREF:
        /* Not supported in minimal seed */
        return tc_error_type(tc, node->loc, "operator not supported in Astra-0");
    }

    return type_new(tc->arena, TYPE_ERROR);
}

/* Argument checking for a resolved method call. The registered signature
 * keeps the receiver at parameter 0 (it is what the callee slot + first
 * argument bind to at run time), so source-level arguments check against
 * params[1..] with the same messages an ordinary call produces. */
static Type *typecheck_method_call(TypeChecker *tc, Node *node, MethodEntry *m) {
    size_t want = m->fn_type->as.fn.param_count - 1;
    size_t got = node->as.call.args.len;
    if (got != want) {
        return tc_error_type(tc, node->loc,
                             "expected %zu arguments, got %zu", want, got);
    }
    for (size_t i = 0; i < got; i++) {
        Type *arg_type = typecheck_node(tc, node->as.call.args.data[i]);
        if (type_is_error(arg_type)) return arg_type;
        Type *expected = m->fn_type->as.fn.params[i + 1];
        if (!type_eq(arg_type, expected)) {
            return tc_error_type(tc, node->loc,
                                 "argument %zu: expected %s, got %s",
                                 i + 1,
                                 type_kind_name(expected->kind),
                                 type_kind_name(arg_type->kind));
        }
    }
    return m->fn_type->as.fn.ret ? m->fn_type->as.fn.ret
                                 : type_new(tc->arena, TYPE_VOID);
}

/* ============================================================
 * §4bis: Generic call-site inference & instances (Phase 2.4 step 2b)
 * ============================================================ */

/* True when `t` mentions a type parameter owned by `fn` — i.e. the type is
 * still abstract with respect to that declaration. */
static bool type_mentions_param_of(Type *t, Node *fn) {
    if (!t) return false;
    switch (t->kind) {
    case TYPE_PARAM:   return t->as.type_param.owner == fn;
    case TYPE_OPTIONAL: return type_mentions_param_of(t->as.optional.inner, fn);
    case TYPE_ARRAY:   return type_mentions_param_of(t->as.array.elem, fn);
    case TYPE_FN:
        for (size_t i = 0; i < t->as.fn.param_count; i++)
            if (type_mentions_param_of(t->as.fn.params[i], fn)) return true;
        return type_mentions_param_of(t->as.fn.ret, fn);
    default: return false;
    }
}

/* Replace the type parameters of `fn` inside `t` with their binding in
 * `env`; everything else (including parameters of *other* fns, which stay
 * abstract for the enclosing symbolic check) passes through. */
static Type *type_subst(TypeChecker *tc, Type *t, Node *fn,
                        GenericBinding *env, size_t env_n) {
    if (!t) return t;
    switch (t->kind) {
    case TYPE_PARAM:
        if (t->as.type_param.owner == fn) {
            for (size_t i = 0; i < env_n; i++) {
                if (string_eq(env[i].name, t->as.type_param.name) && env[i].type)
                    return env[i].type;
            }
        }
        return t;
    case TYPE_OPTIONAL: {
        Type *inner = type_subst(tc, t->as.optional.inner, fn, env, env_n);
        if (inner == t->as.optional.inner) return t;
        return type_new_optional(tc->arena, inner);
    }
    case TYPE_ARRAY: {
        Type *elem = type_subst(tc, t->as.array.elem, fn, env, env_n);
        if (elem == t->as.array.elem) return t;
        return type_new_array(tc->arena, elem, NULL);
    }
    case TYPE_FN: {
        bool changed = false;
        Type **params = arena_new_array(tc->arena, Type *, t->as.fn.param_count);
        for (size_t i = 0; i < t->as.fn.param_count; i++) {
            params[i] = type_subst(tc, t->as.fn.params[i], fn, env, env_n);
            if (params[i] != t->as.fn.params[i]) changed = true;
        }
        Type *ret = type_subst(tc, t->as.fn.ret, fn, env, env_n);
        if (ret != t->as.fn.ret) changed = true;
        if (!changed) return t;
        return type_new_fn(tc->arena, params, t->as.fn.param_count, ret);
    }
    default:
        return t;
    }
}

/* Mangled instance name: `identity<i32,string>` — the `<...>` cannot appear
 * in a source identifier, so the name is unique per binding tuple; the C
 * backend sanitizes the punctuation into `_`. Overflow of the fixed buffer
 * sets `*ov`: a truncated name would collide with another truncated name
 * and silently merge two different instances. */
static void mangle_type_str(Type *t, char *buf, size_t cap, size_t *pos,
                            bool *ov) {
#define PUT(c) do { if (*pos + 1 < cap) buf[(*pos)++] = (c); else *ov = true; } while (0)
#define PUTS(s, n) do { \
        for (size_t i_ = 0; i_ < (n); i_++) { \
            if (*pos + 1 < cap) buf[(*pos)++] = (s)[i_]; \
            else { *ov = true; break; } \
        } \
    } while (0)
    if (!t) { PUTS("void", 4); return; }
    switch (t->kind) {
    case TYPE_VOID:  PUTS("void", 4); break;
    case TYPE_BOOL:  PUTS("bool", 4); break;
    case TYPE_INT:   PUTS("i32", 3); break;
    case TYPE_INT_LITERAL: PUTS("i32", 3); break; /* defaulted at binding */
    case TYPE_INT64: PUTS("i64", 3); break;
    case TYPE_UINT32: PUTS("u32", 3); break;
    case TYPE_UINT64: PUTS("u64", 3); break;
    case TYPE_FLOAT: PUTS("f64", 3); break;
    case TYPE_STRING: PUTS("string", 6); break;
    case TYPE_NIL:   PUTS("nil", 3); break;
    case TYPE_OPTIONAL:
        PUT('?');
        mangle_type_str(t->as.optional.inner, buf, cap, pos, ov);
        break;
    case TYPE_ARRAY:
        PUT('[');
        mangle_type_str(t->as.array.elem, buf, cap, pos, ov);
        PUT(']');
        break;
    case TYPE_FN:    PUTS("fn", 2); break;
    case TYPE_STRUCT:
    case TYPE_ENUM:
        PUTS(t->kind == TYPE_STRUCT ? t->as.struc.name.str
                                    : t->as.enumeration.name.str,
             t->kind == TYPE_STRUCT ? t->as.struc.name.len
                                    : t->as.enumeration.name.len);
        break;
    case TYPE_PARAM:
        PUTS(t->as.type_param.name.str, t->as.type_param.name.len);
        break;
    default:         PUTS("unknown", 7); break;
    }
#undef PUT
#undef PUTS
}

static InternedString mangle_instance(TypeChecker *tc, InternedString fn_name,
                                      GenericBinding *env, size_t env_n) {
    char buf[512];
    size_t pos = 0;
    bool ov = false;
    if (fn_name.len < sizeof buf - 2) {
        memcpy(buf, fn_name.str, fn_name.len);
        pos = fn_name.len;
    } else {
        ov = true;
    }
    if (pos + 1 < sizeof buf) buf[pos++] = '<';
    else ov = true;
    for (size_t i = 0; i < env_n; i++) {
        if (i > 0) {
            if (pos + 1 < sizeof buf) buf[pos++] = ',';
            else ov = true;
        }
        mangle_type_str(env[i].type, buf, sizeof buf, &pos, &ov);
    }
    if (pos + 2 < sizeof buf) { buf[pos++] = '>'; buf[pos] = '\0'; }
    else { buf[sizeof buf - 1] = '\0'; ov = true; }
    if (ov) return (InternedString){0};
    return string_intern(tc->strings, buf, pos);
}

static void tc_inst_grow(TypeChecker *tc) {
    if (tc->inst_count < tc->inst_cap) return;
    size_t nc = tc->inst_cap == 0 ? 8 : tc->inst_cap * 2;
    GenericInstance *nd = arena_new_array(tc->arena, GenericInstance, nc);
    if (tc->instances)
        memcpy(nd, tc->instances, sizeof(GenericInstance) * tc->inst_count);
    tc->instances = nd;
    tc->inst_cap = nc;
}

static void tc_pending_add(TypeChecker *tc, Node *fn, Node *callee, Node *target,
                           GenericBinding *env, size_t env_n) {
    if (tc->pending_count >= tc->pending_cap) {
        size_t nc = tc->pending_cap == 0 ? 8 : tc->pending_cap * 2;
        void *nd = arena_new_array(tc->arena, char, nc * sizeof(*tc->pending));
        if (tc->pending)
            memcpy(nd, tc->pending, sizeof(*tc->pending) * tc->pending_count);
        tc->pending = nd;
        tc->pending_cap = nc;
    }
    GenericBinding *env_copy = arena_new_array(tc->arena, GenericBinding, env_n ? env_n : 1);
    memcpy(env_copy, env, sizeof(GenericBinding) * env_n);
    tc->pending[tc->pending_count].fn_decl = fn;
    tc->pending[tc->pending_count].callee = callee;
    tc->pending[tc->pending_count].target = target;
    tc->pending[tc->pending_count].bindings = env_copy;
    tc->pending[tc->pending_count].binding_count = env_n;
    tc->pending_count++;
}

/* Materialize (or find) the instance of generic `fn` under `env` and
 * resolve the pending call sites recorded in `fn`'s body against it. The
 * instance is registered *before* those resolutions so a recursive call
 * inside the body finds this very instance instead of recursing forever. */
static GenericInstance *ensure_instance(TypeChecker *tc, Node *fn,
                                        GenericBinding *env, size_t env_n) {
    InternedString mangled = mangle_instance(tc, fn->as.fn_decl.name, env, env_n);
    if (!mangled.str) {
        tc_error(tc, fn->loc,
                 "generic instance name for '%.*s' is too long",
                 (int)fn->as.fn_decl.name.len, fn->as.fn_decl.name.str);
        return NULL;
    }
    for (size_t i = 0; i < tc->inst_count; i++) {
        if (string_eq(tc->instances[i].wrapper->as.fn_decl.name, mangled))
            return &tc->instances[i];
    }

    /* Hard cap: a recursive generic that grows its binding every step
     * (`f([x])` instantiating f<[i32]>, f<[[i32]]>, ...) would otherwise
     * chain until the global limit with a misleading message. */
    if (tc->inst_count >= 256) {
        tc_error(tc, fn->loc, "too many generic instances (max 256)");
        return NULL;
    }

    Node *w = node_new(tc->arena, NODE_FN_DECL, fn->loc);
    w->as.fn_decl = fn->as.fn_decl; /* shares params/body; one emission each */
    w->as.fn_decl.name = mangled;
    w->as.fn_decl.generics.data = NULL;
    w->as.fn_decl.generics.len = 0;
    w->as.fn_decl.generics.cap = 0;

    tc_inst_grow(tc);
    /* Index, not pointer: the recursive ensure_instance calls below may
     * grow tc->instances and reallocate it. */
    size_t gi_idx = tc->inst_count++;
    tc->instances[gi_idx].source = fn;
    tc->instances[gi_idx].wrapper = w;
    tc->instances[gi_idx].rewrites = NULL;
    tc->instances[gi_idx].rewrite_count = 0;

    for (size_t p = 0; p < tc->pending_count; p++) {
        if (tc->pending[p].fn_decl != fn) continue;
        /* Substitute this instance's bindings into the recorded (abstract)
         * ones; a leftover parameter of `fn` means the env did not cover it
         * and the resolution is skipped (unreachable: completeness checked
         * the env at the call site). */
        GenericBinding *nb = arena_new_array(tc->arena, GenericBinding,
                                             tc->pending[p].binding_count);
        bool still = false;
        for (size_t j = 0; j < tc->pending[p].binding_count; j++) {
            nb[j].name = tc->pending[p].bindings[j].name;
            nb[j].type = type_subst(tc, tc->pending[p].bindings[j].type,
                                    fn, env, env_n);
            if (type_mentions_param_of(nb[j].type, fn)) still = true;
        }
        if (still) continue;
        GenericInstance *ti = ensure_instance(tc, tc->pending[p].target,
                                              nb, tc->pending[p].binding_count);
        if (!ti) continue; /* overflow reported; compilation fails anyway */
        GenericInstance *gi = &tc->instances[gi_idx]; /* re-fetch after grow */
        size_t rc = gi->rewrite_count;
        GenericRewrite *nr = arena_new_array(tc->arena, GenericRewrite, rc + 1);
        if (gi->rewrites)
            memcpy(nr, gi->rewrites, sizeof(GenericRewrite) * rc);
        nr[rc].callee = tc->pending[p].callee;
        nr[rc].name = ti->wrapper->as.fn_decl.name;
        gi->rewrites = nr;
        gi->rewrite_count = rc + 1;
    }
    return &tc->instances[gi_idx];
}

/* One unification step of call-site inference: bind the type parameters of
 * `fn` inside `template` to `arg`. On a conflict the offending parameter
 * name and the rejected type are reported through the out-params. */
static bool unify_bind(TypeChecker *tc, Type *template, Type *arg, Node *fn,
                       GenericBinding *env, size_t env_n,
                       InternedString *conflict_name, Type **conflict_type) {
    if (template->kind == TYPE_PARAM && template->as.type_param.owner == fn) {
        Type *bound = arg;
        if (bound->kind == TYPE_INT_LITERAL) bound = type_new(tc->arena, TYPE_INT);
        for (size_t i = 0; i < env_n; i++) {
            if (!string_eq(env[i].name, template->as.type_param.name)) continue;
            if (env[i].type == NULL) { env[i].type = bound; return true; }
            if (!type_eq(env[i].type, bound)) {
                *conflict_name = template->as.type_param.name;
                *conflict_type = bound;
                return false;
            }
            return true;
        }
        return true; /* not one of fn's declared parameters: nothing to bind */
    }
    if (template->kind == TYPE_OPTIONAL && arg->kind == TYPE_OPTIONAL)
        return unify_bind(tc, template->as.optional.inner, arg->as.optional.inner,
                          fn, env, env_n, conflict_name, conflict_type);
    if (template->kind == TYPE_ARRAY && arg->kind == TYPE_ARRAY)
        return unify_bind(tc, template->as.array.elem, arg->as.array.elem,
                          fn, env, env_n, conflict_name, conflict_type);
    if (template->kind == TYPE_FN && arg->kind == TYPE_FN) {
        if (template->as.fn.param_count != arg->as.fn.param_count) return true;
        for (size_t i = 0; i < template->as.fn.param_count; i++) {
            if (!unify_bind(tc, template->as.fn.params[i], arg->as.fn.params[i],
                            fn, env, env_n, conflict_name, conflict_type))
                return false;
        }
        if (template->as.fn.ret && arg->as.fn.ret)
            return unify_bind(tc, template->as.fn.ret, arg->as.fn.ret,
                              fn, env, env_n, conflict_name, conflict_type);
    }
    return true;
}

/* Materialize (or find) the instance of a generic struct under `env`: the
 * declaration's field types are re-resolved in a scope where each parameter
 * binds to its argument, so nested arguments (`Box<T>` inside another
 * template, or `Vec<Vec<i32>>` at a use site) instantiate naturally. The
 * symbol is registered before its own fields resolve so a recursive field
 * finds the cached type instead of looping forever. Registered in whatever
 * scope is active; `type_eq` on struct names keeps a re-created instance
 * from a popped scope equal to the original. */
static Type *ensure_struct_instance(TypeChecker *tc, Node *decl,
                                    GenericBinding *env, size_t env_n,
                                    SrcLoc loc) {
    InternedString mangled = mangle_instance(tc, decl->as.struct_decl.name,
                                             env, env_n);
    if (!mangled.str) {
        tc_error(tc, loc, "generic instance name for '%.*s' is too long",
                 (int)decl->as.struct_decl.name.len,
                 decl->as.struct_decl.name.str);
        return type_new(tc->arena, TYPE_ERROR);
    }
    Symbol *cached = symbol_table_lookup(tc->symbols, mangled);
    if (cached && cached->type) return cached->type;

    Type *st = type_new(tc->arena, TYPE_STRUCT);
    st->as.struc.name = mangled;
    st->as.struc.fields = NULL;
    st->as.struc.field_count = 0;
    Symbol sym = {
        .name      = mangled,
        .type      = st,
        .is_mut    = false,
        .is_fn     = false,
        .is_generic = false,
        .fn_ast    = NULL,
        .type_ast  = decl,
        .def_loc   = loc,
    };
    symbol_table_insert(tc->symbols, sym);

    size_t mark = tc->generic_len;
    for (size_t i = 0; i < env_n && tc->generic_len < 32; i++) {
        if (!tc->generic_stack)
            tc->generic_stack = arena_new_array(tc->arena, GenericBinding, 32);
        tc->generic_stack[tc->generic_len].name = env[i].name;
        tc->generic_stack[tc->generic_len].type = env[i].type;
        tc->generic_len++;
    }

    size_t fc = decl->as.struct_decl.field_names.len;
    if (fc > 0) {
        st->as.struc.fields = arena_new_array(tc->arena, StructField, fc);
        st->as.struc.field_count = fc;
        for (size_t i = 0; i < fc; i++) {
            Type *ft = resolve_type_node(tc, decl->as.struct_decl.field_types.data[i]);
            if (type_is_error(ft)) {
                pop_generic_scope(tc, mark);
                return ft;
            }
            st->as.struc.fields[i].name = decl->as.struct_decl.field_names.data[i];
            st->as.struc.fields[i].type = ft;
        }
    }
    pop_generic_scope(tc, mark);
    return st;
}

/* Phase 2.4 step 4: at each instantiation, every bound declared on the
 * parameter list must hold for the concrete binding. Abstract bindings
 * (TYPE_PARAM — a call inside another generic body) are skipped: bodies
 * are checked once symbolically, so verifying them would need a
 * per-instance re-check (documented gap, §9). A bound whose trait is
 * unknown was already reported when the declaration bound its parameters
 * (push_generic_bindings), so it is skipped here instead of duplicated. */
static void check_generic_bounds(TypeChecker *tc, NodeList *generics,
                                 GenericBinding *env, size_t env_n,
                                 InternedString owner, SrcLoc loc) {
    size_t n = generics->len < env_n ? generics->len : env_n;
    for (size_t i = 0; i < n; i++) {
        Type *ty = env[i].type;
        if (!ty || ty->kind == TYPE_PARAM || ty->kind == TYPE_ERROR) continue;
        Node *tp = generics->data[i];
        if (!tp || tp->kind != NODE_TYPE_PARAM) continue;
        for (size_t j = 0; j < tp->as.type_param.bounds.len; j++) {
            Node *b = tp->as.type_param.bounds.data[j];
            if (!b || b->kind != NODE_TYPE_IDENT) continue;
            InternedString bound = b->as.type_ident.name;
            if (!checker_find_trait(tc, bound)) continue;
            if (impl_record_exists(tc, ty, bound)) continue;
            char tbuf[512];
            int tn;
            if (ty->kind == TYPE_STRUCT)
                tn = snprintf(tbuf, sizeof tbuf, "%.*s",
                              (int)ty->as.struc.name.len, ty->as.struc.name.str);
            else if (ty->kind == TYPE_ENUM)
                tn = snprintf(tbuf, sizeof tbuf, "%.*s",
                              (int)ty->as.enumeration.name.len,
                              ty->as.enumeration.name.str);
            else
                tn = snprintf(tbuf, sizeof tbuf, "%s", type_kind_name(ty->kind));
            if (tn < 0 || (size_t)tn >= sizeof tbuf) tn = (int)sizeof tbuf - 1;
            tc_error(tc, loc,
                     "type parameter '%.*s' of '%.*s' requires bound "
                     "'%.*s': type '%.*s' does not implement trait '%.*s'",
                     (int)tp->as.type_param.name.len, tp->as.type_param.name.str,
                     (int)owner.len, owner.str,
                     (int)bound.len, bound.str,
                     tn, tbuf,
                     (int)bound.len, bound.str);
        }
    }
}

/* `Name<args...>` in a type position (Phase 2.4 step 3b): resolve the
 * arguments, mangle them into the instance key and materialize the cached
 * struct type. The base must be a generic struct declaration; anything else
 * that exists rejects the arguments instead of silently dropping them, and
 * an unknown base keeps the ordinary "unknown type" message (the UI test
 * for nested arguments depends on it). */
static Type *resolve_type_with_args(TypeChecker *tc, Node *node,
                                    InternedString name) {
    Symbol *bsym = symbol_table_lookup(tc->symbols, name);
    if (!bsym || !bsym->type) {
        return tc_error_type(tc, node->loc, "unknown type '%.*s'",
                             (int)name.len, name.str);
    }
    if (bsym->type->kind != TYPE_STRUCT || !bsym->is_generic || !bsym->type_ast) {
        return tc_error_type(tc, node->loc,
                             "type '%.*s' does not take type arguments",
                             (int)name.len, name.str);
    }

    Node *decl = bsym->type_ast;
    NodeList *gargs = &node->as.type_ident.generics;
    size_t n = decl->as.struct_decl.generics.len;
    if (gargs->len != n) {
        return tc_error_type(tc, node->loc,
                             "wrong number of type arguments for '%.*s' "
                             "(expected %zu, got %zu)",
                             (int)name.len, name.str, n, gargs->len);
    }

    GenericBinding *env = arena_new_array(tc->arena, GenericBinding, n ? n : 1);
    for (size_t i = 0; i < n; i++) {
        Node *tp = decl->as.struct_decl.generics.data[i];
        env[i].name = tp && tp->kind == NODE_TYPE_PARAM
                          ? tp->as.type_param.name : (InternedString){0};
        env[i].type = resolve_type_node(tc, gargs->data[i]);
        if (type_is_error(env[i].type)) return env[i].type;
    }
    check_generic_bounds(tc, &decl->as.struct_decl.generics, env, n,
                         name, node->loc);
    return ensure_struct_instance(tc, decl, env, n, node->loc);
}

/* Call-site of a generic function: infer the bindings from the arguments,
 * instantiate the concrete ones and record the abstract ones (a call inside
 * another generic body) for per-instance resolution. The call type is the
 * return type with the bindings substituted in. */
static Type *typecheck_generic_call(TypeChecker *tc, Node *node, Symbol *csym) {
    Node *fn = csym->fn_ast;
    Type *fn_type = csym->type;
    size_t argc = node->as.call.args.len;

    if (argc != fn_type->as.fn.param_count) {
        return tc_error_type(tc, node->loc,
                             "expected %zu arguments, got %zu",
                             fn_type->as.fn.param_count, argc);
    }

    /* Env pre-seeded with the declared parameter names in declaration
     * order (the mangle depends on that order). */
    size_t env_n = fn->as.fn_decl.generics.len;
    GenericBinding *env = arena_new_array(tc->arena, GenericBinding, env_n ? env_n : 1);
    for (size_t i = 0; i < env_n; i++) {
        Node *tp = fn->as.fn_decl.generics.data[i];
        env[i].name = tp && tp->kind == NODE_TYPE_PARAM ? tp->as.type_param.name
                                                        : (InternedString){0};
        env[i].type = NULL;
    }

    for (size_t i = 0; i < argc; i++) {
        Type *arg_type = typecheck_node(tc, node->as.call.args.data[i]);
        if (type_is_error(arg_type)) return arg_type;
        InternedString cname = {0};
        Type *conflict = NULL;
        if (!unify_bind(tc, fn_type->as.fn.params[i], arg_type, fn,
                        env, env_n, &cname, &conflict)) {
            /* Recover the previously bound type of the conflicting name. */
            Type *prev = NULL;
            for (size_t j = 0; j < env_n; j++)
                if (string_eq(env[j].name, cname)) prev = env[j].type;
            return tc_error_type(tc, node->loc,
                                 "type parameter '%.*s' of '%.*s' cannot be both %s and %s",
                                 (int)cname.len, cname.str,
                                 (int)csym->name.len, csym->name.str,
                                 type_kind_name(prev ? prev->kind : TYPE_UNKNOWN),
                                 type_kind_name(conflict->kind));
        }
    }

    for (size_t i = 0; i < env_n; i++) {
        if (env[i].type == NULL) {
            return tc_error_type(tc, node->loc,
                                 "cannot infer type parameter '%.*s' of '%.*s'",
                                 (int)env[i].name.len, env[i].name.str,
                                 (int)csym->name.len, csym->name.str);
        }
    }
    check_generic_bounds(tc, &fn->as.fn_decl.generics, env, env_n,
                         csym->name, node->loc);

    Type *ret = fn_type->as.fn.ret
        ? type_subst(tc, fn_type->as.fn.ret, fn, env, env_n)
        : type_new(tc->arena, TYPE_VOID);

    /* Abstract bindings (an argument typed by the *enclosing* generic fn)
     * cannot name an instance yet: the call is recorded and resolved when
     * that fn is instantiated. Concrete calls instantiate now and rename
     * the callee — safe, because a callee inside a non-generic body is
     * emitted exactly once. */
    bool abstract = false;
    if (tc->generic_len > 0 && tc->current_generic_fn) {
        for (size_t i = 0; i < env_n; i++) {
            if (type_mentions_param_of(env[i].type, tc->current_generic_fn)) {
                abstract = true;
                break;
            }
        }
    }
    if (abstract) {
        tc_pending_add(tc, tc->current_generic_fn, node->as.call.callee, fn,
                       env, env_n);
        return ret;
    }

    GenericInstance *gi = ensure_instance(tc, fn, env, env_n);
    if (!gi) return type_new(tc->arena, TYPE_ERROR); /* already reported */
    node->as.call.callee->as.ident.name = gi->wrapper->as.fn_decl.name;
    return ret;
}

/* Check a data-carrying variant construction `Enum.Variant(args)`
 * (research/004 §9.2): positional construction against the payload layout.
 * DEC-008 (research/027 §4) routes both spellings here — the qualified
 * `Enum.Variant(...)` (the only legal one for user variants) and the bare
 * builtin `some(x)` / `ok(x)` / `err(x)`. Returns the enum's type, or an
 * error type. */
static Type *check_variant_construction(TypeChecker *tc, Node *node, Type *et,
                                        InternedString vname) {
    int vi = enum_variant_index(et, vname);
    if (vi < 0) return type_new(tc->arena, TYPE_ERROR); /* defensive */
    const VariantLayout *vl =
        et->as.enumeration.payloads ? &et->as.enumeration.payloads[vi] : NULL;
    size_t nf = vl ? vl->field_count : 0;

    if (node->as.call.args.len != nf) {
        return tc_error_type(tc, node->loc,
                             "variant '%.*s.%.*s' expects %zu field(s), got %zu",
                             (int)et->as.enumeration.name.len, et->as.enumeration.name.str,
                             (int)vname.len, vname.str, nf, node->as.call.args.len);
    }
    /* Construction is positional in Astra-0: `PasoDoble(1, 2)`.
     * Declared field names are kept for pattern bindings, not
     * for named construction — the shared call grammar has no
     * `name:` argument form yet. */
    if (vl) {
        for (size_t i = 0; i < node->as.call.args.len; i++) {
            Type *at = typecheck_node(tc, node->as.call.args.data[i]);
            if (type_is_error(at)) return at;
            Type *expected = vl->types[i];
            if (expected && expected->kind == TYPE_UNKNOWN) expected = NULL;
            if (expected && !type_eq(at, expected)) {
                return tc_error_type(tc, node->loc,
                                     "field %zu of '%.*s.%.*s' expects %s, got %s",
                                     i + 1,
                                     (int)et->as.enumeration.name.len, et->as.enumeration.name.str,
                                     (int)vname.len, vname.str,
                                     type_kind_name(expected->kind),
                                     type_kind_name(at->kind));
            }
        }
    }
    return et;
}

static Type *typecheck_call(TypeChecker *tc, Node *node) {
    Node *callee_node = node->as.call.callee;

    /* A bare identifier callee may name a built-in Option/Result variant:
     * `some(x)` / `ok(x)` / `err(x)`. DEC-008 (research/027 §4): a *user*
     * variant is only legal in the qualified spelling `Enum.Variant(...)`,
     * so the bare form resolves to a variant and is rejected with a hint —
     * the flat registry that used to let the first-registered enum win
     * (colliding homonyms) now only serves the built-ins. */
    if (callee_node->kind == NODE_IDENT) {
        bool builtin = false;
        Type *et = checker_find_variant(tc, callee_node->as.ident.name, &builtin);
        Symbol *sym = symbol_table_lookup(tc->symbols, callee_node->as.ident.name);
        if (type_is_error(et)) return et;
        if (et && !(sym && sym->is_fn)) {
            if (builtin) {
                return check_variant_construction(tc, node, et,
                                                  callee_node->as.ident.name);
            }
            return tc_error_type(tc, node->loc,
                                 "use Enum.Variant to construct '%.*s'",
                                 (int)callee_node->as.ident.name.len,
                                 callee_node->as.ident.name.str);
        }
    }

    /* `x.m(args)` is a static method call when `m` resolves in the receiver's
     * method table (Phase 2.3 step 3-4): the callee node is annotated with
     * the mangled global and the arguments check against the signature with
     * the receiver removed. A field that holds a function still works — the
     * method table is consulted only when it has an entry. Module-namespace
     * callees do not exist in the seed (single file), so no export layer
     * precedes this. */
    if (callee_node->kind == NODE_FIELD_ACCESS) {
        Type *obj = typecheck_node(tc, callee_node->as.field_access.object);
        if (type_is_error(obj)) return obj;
        /* DEC-008 (research/027 §4): `Enum.Variant(args)` is a variant
         * construction, not a method call — checked before the method table
         * so a method may not shadow a variant of the same name. */
        if (obj->kind == TYPE_ENUM &&
            enum_variant_index(obj, callee_node->as.field_access.field) >= 0) {
            return check_variant_construction(tc, node, obj,
                                              callee_node->as.field_access.field);
        }
        MethodEntry *m = checker_find_method(tc, obj,
                                             callee_node->as.field_access.field);
        if (m) {
            callee_node->as.field_access.method = m->global;
            return typecheck_method_call(tc, node, m);
        }
        /* No method: fall through — the object re-typechecks below, but it
         * was clean (an error type returns above), so no message repeats. */
    }

    /* Phase 2.4 step 2b: a generic callee is instantiated per call site
     * instead of being rejected (the generic-as-value rule still fires on
     * every non-call use, handled by typecheck_ident). */
    if (callee_node->kind == NODE_IDENT) {
        Symbol *csym = symbol_table_lookup(tc->symbols, callee_node->as.ident.name);
        if (csym && csym->is_fn && csym->is_generic && csym->fn_ast) {
            return typecheck_generic_call(tc, node, csym);
        }
    }

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
        /* An unannotated parameter is unknown and unknown accepts anything
         * (type_eq). Guard the NULL defensively: the error path below would
         * dereference it (audit §3.1 crash at this exact line). */
        Type *pt = callee->as.fn.params[i];
        if (pt && !type_eq(arg_type, pt)) {
            return tc_error_type(tc, node->loc,
                                 "argument %zu: expected %s, got %s",
                                 i + 1,
                                 type_kind_name(pt->kind),
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

    /* DEC-013 (research/028 PR1): strings index for reading — `s[i]` yields
     * the one-byte string at byte i. Everything else keeps the historical
     * rejection (`ui/index_non_array.astra`), including as an assignment
     * target: typecheck_assign rejects `s[0] = …` separately, strings being
     * immutable. */
    if (object->kind != TYPE_ARRAY && object->kind != TYPE_STRING) {
        return tc_error_type(tc, node->as.index.object->loc,
                             "cannot index non-array type %s",
                             type_kind_name(object->kind));
    }

    Type *index = typecheck_node(tc, node->as.index.index);
    if (type_is_error(index)) return index;

    bool idx_int = type_is_integer(index);
    if (!idx_int) {
        return tc_error_type(tc, node->as.index.index->loc,
                             "array index must be integer type, got %s",
                             type_kind_name(index->kind));
    }

    if (object->kind == TYPE_STRING) return type_new(tc->arena, TYPE_STRING);
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

    /* No duplicate keys, no unknown fields. */
    for (size_t i = 0; i < node->as.struct_lit.field_names.len; i++) {
        InternedString fname = node->as.struct_lit.field_names.data[i];
        for (size_t j = 0; j < i; j++) {
            if (string_eq(node->as.struct_lit.field_names.data[j], fname)) {
                return tc_error_type(tc, node->loc,
                                     "duplicate field '%.*s' in struct literal",
                                     (int)fname.len, fname.str);
            }
        }
        bool found = false;
        for (size_t j = 0; j < declared; j++) {
            if (string_eq(st->as.struc.fields[j].name, fname)) { found = true; break; }
        }
        if (!found) {
            return tc_error_type(tc, node->loc, "struct '%.*s' has no field '%.*s'",
                                 (int)name.len, name.str, (int)fname.len, fname.str);
        }
    }

    /* A generic literal infers its arguments from the field values
     * (Phase 2.4 step 3b): unify each value against the template field and
     * materialize `Box<i32>` — the same unification a generic call does,
     * owned by the struct declaration instead of a function. Each value is
     * typechecked exactly once here and the results feed the normal field
     * checks below. */
    Type **vts = NULL;
    if (sym->is_generic && sym->type_ast &&
        sym->type_ast->as.struct_decl.generics.len > 0) {
        Node *decl = sym->type_ast;
        size_t n = decl->as.struct_decl.generics.len;
        size_t lit_n = node->as.struct_lit.field_names.len;
        GenericBinding *env = arena_new_array(tc->arena, GenericBinding, n ? n : 1);
        for (size_t i = 0; i < n; i++) {
            Node *tp = decl->as.struct_decl.generics.data[i];
            env[i].name = tp && tp->kind == NODE_TYPE_PARAM
                              ? tp->as.type_param.name : (InternedString){0};
            env[i].type = NULL;
        }

        vts = arena_new_array(tc->arena, Type *, lit_n ? lit_n : 1);
        for (size_t j = 0; j < lit_n; j++) {
            vts[j] = typecheck_node(tc, node->as.struct_lit.field_values.data[j]);
            if (type_is_error(vts[j])) return vts[j];
        }

        for (size_t j = 0; j < lit_n; j++) {
            InternedString fname = node->as.struct_lit.field_names.data[j];
            Type *tf = NULL;
            for (size_t k = 0; k < declared; k++) {
                if (string_eq(st->as.struc.fields[k].name, fname)) {
                    tf = st->as.struc.fields[k].type;
                    break;
                }
            }
            InternedString cname = {0};
            Type *conflict = NULL;
            if (tf && !unify_bind(tc, tf, vts[j], decl, env, n, &cname, &conflict)) {
                Type *prev = NULL;
                for (size_t i = 0; i < n; i++)
                    if (string_eq(env[i].name, cname)) prev = env[i].type;
                return tc_error_type(tc, node->loc,
                                     "type parameter '%.*s' of '%.*s' cannot be both %s and %s",
                                     (int)cname.len, cname.str,
                                     (int)name.len, name.str,
                                     type_kind_name(prev ? prev->kind : TYPE_UNKNOWN),
                                     type_kind_name(conflict->kind));
            }
        }
        for (size_t i = 0; i < n; i++) {
            if (env[i].type == NULL) {
                return tc_error_type(tc, node->loc,
                                     "cannot infer type parameter '%.*s' of '%.*s'",
                                     (int)env[i].name.len, env[i].name.str,
                                     (int)name.len, name.str);
            }
        }
        check_generic_bounds(tc, &decl->as.struct_decl.generics, env, n,
                             name, node->loc);
        Type *inst = ensure_struct_instance(tc, decl, env, n, node->loc);
        if (type_is_error(inst)) return inst;
        st = inst;
        declared = st->as.struc.field_count;
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
        Type *vt = vts ? vts[vi] : typecheck_node(tc, val);
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
            /* Not a variant, but maybe a method: say so instead of pretending
             * the name is a typo (fields and variants win over methods on a
             * bare access — same split as Rust's `x.m` vs `x.m()`). */
            if (checker_find_method(tc, object, v)) {
                return tc_error_type(tc, node->loc,
                                     "method '%.*s' of '%.*s' must be called",
                                     (int)v.len, v.str,
                                     (int)object->as.enumeration.name.len,
                                     object->as.enumeration.name.str);
            }
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

    if (checker_find_method(tc, object, field)) {
        return tc_error_type(tc, node->loc,
                             "method '%.*s' of '%.*s' must be called",
                             (int)field.len, field.str,
                             (int)object->as.struc.name.len,
                             object->as.struc.name.str);
    }

    return tc_error_type(tc, node->loc, "struct '%.*s' has no field '%.*s'",
                         (int)object->as.struc.name.len, object->as.struc.name.str,
                         (int)field.len, field.str);
}

/* A block's value is its trailing expression
 * (`Block ::= "{" Statement* Expression? "}"`, research/001 §12.1 and §4.2).
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
            bool st_int = type_is_integer(st);
            if (!st_int) {
                return tc_error_type(tc, start->loc,
                                     "range start must be integer type, got %s",
                                     type_kind_name(st->kind));
            }
        }
        Type *et = typecheck_node(tc, end);
        if (type_is_error(et)) return et;
        bool et_int = type_is_integer(et);
        if (!et_int) {
            return tc_error_type(tc, end->loc,
                                 "range end must be integer type, got %s",
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
    case NODE_UNARY_OP: {
        Type *pt = typecheck_node(tc, pat);
        if (type_is_error(pt)) return;
        if (!type_eq(pt, target)) {
            tc_error(tc, pat->loc,
                     "pattern type %s does not match match target type %s",
                     type_kind_name(pt->kind), type_kind_name(target->kind));
            return;
        }
        /* A bool literal marks its slot on a bool target (audit §3.8):
         * covered[0] = false arm, covered[1] = true arm. */
        if (pat->kind == NODE_BOOL_LIT && covered &&
            target->kind == TYPE_BOOL && covered_n > 1)
            covered[pat->as.bool_lit.value ? 1 : 0] = true;
        return;
    }

    case NODE_PATTERN_BIND: {
        /* Binding pattern: captures the whole matched value. */
        Symbol sym = {
            .name    = pat->as.pattern_bind.name,
            .type    = target,
            .is_mut  = false,
            .is_fn   = false,
            .def_loc = pat->loc,
        };
        symbol_table_insert(tc->symbols, sym);
        return;
    }

    case NODE_PATTERN_VARIANT_BIND: {
        /* Enum variant with payload bindings: Color.Rgb(r, g, b) */
        Node *var_path = pat->as.pattern_variant_bind.variant;
        if (!var_path || var_path->kind != NODE_FIELD_ACCESS) {
            tc_error(tc, pat->loc, "pattern must be a literal, `_` or Enum.Variant");
            return;
        }
        Node *obj = var_path->as.field_access.object;
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
        InternedString v = var_path->as.field_access.field;
        int vi = enum_variant_index(et, v);
        if (vi < 0) {
            tc_error(tc, pat->loc, "enum '%.*s' has no variant '%.*s'",
                     (int)et->as.enumeration.name.len, et->as.enumeration.name.str,
                     (int)v.len, v.str);
            return;
        }
        if (covered && (size_t)vi < covered_n) covered[vi] = true;

        /* Bind each name to the corresponding payload field type. */
        VariantLayout *vl = et->as.enumeration.payloads
            ? &et->as.enumeration.payloads[vi] : NULL;
        size_t bind_count = pat->as.pattern_variant_bind.bindings.len;
        if (vl) {
            if (bind_count != vl->field_count) {
                tc_error(tc, pat->loc,
                         "variant '%.*s' has %zu fields but pattern binds %zu",
                         (int)v.len, v.str, vl->field_count, bind_count);
                return;
            }
            for (size_t i = 0; i < bind_count; i++) {
                Symbol sym = {
                    .name    = pat->as.pattern_variant_bind.bindings.data[i],
                    .type    = vl->types[i],
                    .is_mut  = false,
                    .is_fn   = false,
                    .def_loc = pat->loc,
                };
                symbol_table_insert(tc->symbols, sym);
            }
        } else {
            /* Unit variant: no bindings expected. */
            if (bind_count > 0) {
                tc_error(tc, pat->loc,
                         "variant '%.*s' has no payload but pattern binds %zu names",
                         (int)v.len, v.str, bind_count);
                return;
            }
        }
        return;
    }

    case NODE_PATTERN_BUILTIN_VARIANT: {
        /* ok(v), err(e), some(x), none — builtin variant patterns */
        BuiltinVariantKind bvk = pat->as.pattern_builtin_variant.kind;
        Node *payload = pat->as.pattern_builtin_variant.payload;
        if (bvk == BUILTIN_VARIANT_NONE) {
            /* none matches nil (no payload to bind); on an optional target
             * it covers the absence slot (audit §3.4). */
            if (covered && target->kind == TYPE_OPTIONAL && covered_n > 1)
                covered[1] = true;
            return;
        }
        /* some/ok/err carry the payload tag (slot 0 of an optional). */
        if (covered && target->kind == TYPE_OPTIONAL && covered_n > 0)
            covered[0] = true;
        /* ok/err/some: bind the payload pattern against the payload type.
         * The constructors return TYPE_OPTIONAL wrapping the payload, so
         * handing `target` down typed every binding as `optional` while the
         * VM extracted the payload value — `w + 1` was rejected as
         * "requires numeric type, got optional" even though it runs fine,
         * and literal payloads like `some(1)` were rejected outright
         * (audit §3.3). */
        if (payload) {
            Type *pt = target;
            if (target->kind == TYPE_OPTIONAL && target->as.optional.inner)
                pt = target->as.optional.inner;
            check_pattern(tc, payload, pt, has_wildcard, covered, covered_n);
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
        ? target->as.enumeration.variant_count
        /* Option/Result static type is TYPE_OPTIONAL: slot 0 = payload tag
         * (some/ok/err), slot 1 = none. Without this the check never ran
         * for optionals and `match x { some(v) => v }` returned nil under
         * an i32 promise (audit §3.4). */
        : (target->kind == TYPE_OPTIONAL ? 2
        /* bool has a finite, enumerable space too: slot 0 = false,
         * slot 1 = true (audit §3.8). Scalars get no slots: their space
         * is infinite (and Astra-0 has no range patterns), so coverage
         * means a catch-all arm, which sets has_wildcard instead. */
        : (target->kind == TYPE_BOOL ? 2 : 0));
    bool *covered = arena_new_array(tc->arena, bool, covered_n > 0 ? covered_n : 1);
    bool has_wildcard = false;

    Type *result_type = NULL;

    for (size_t i = 0; i < node->as.match_expr.arms.len; i++) {
        MatchArm *arm = &node->as.match_expr.arms.data[i];
        symbol_table_push_scope(tc->symbols);

        /* A guarded arm only covers its variant when the guard holds at
         * run time (audit §3.4): it must neither mark coverage nor waive
         * exhaustiveness — `E.B if flag =>` alone used to accept a match
         * that printed nil under an i32 promise. */
        bool guard_wildcard = false;
        check_pattern(tc, arm->pattern, target,
                      arm->guard ? &guard_wildcard : &has_wildcard,
                      arm->guard ? NULL : covered, covered_n);
        /* An unguarded bare binding matches every value, like `_`. */
        if (!arm->guard && arm->pattern->kind == NODE_PATTERN_BIND)
            has_wildcard = true;

        if (arm->guard) {
            Type *guard_type = typecheck_node(tc, arm->guard);
            if (!type_is_error(guard_type) && guard_type->kind != TYPE_BOOL) {
                tc_error(tc, arm->guard->loc,
                         "match guard must be bool, got %s",
                         type_kind_name(guard_type->kind));
            }
        }

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

    /* Exhaustiveness (research/004 §9, ARCHITECTURE.md §11.3): an enum
     * match without a wildcard covers every variant; an optional match
     * must cover the payload tag (some/ok/err) and none; bool is proven
     * with its two literals; every other target needs a catch-all `_`
     * (audit §3.4 + §3.8). The run-time backstop for whatever still
     * slips through — Tier-2 optional aliasing — is OPCODE_MATCH_NONE:
     * a match that reaches the end without a hit aborts instead of
     * yielding a nil that lies under the promised type. */
    if (!has_wildcard && target->kind == TYPE_ENUM) {
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
    } else if (!has_wildcard && target->kind == TYPE_OPTIONAL) {
        if (!covered[0])
            tc_error(tc, node->loc,
                     "non-exhaustive match: missing payload arm (some/ok/err)");
        if (!covered[1])
            tc_error(tc, node->loc,
                     "non-exhaustive match: missing 'none' arm");
    } else if (!has_wildcard && target->kind == TYPE_BOOL) {
        if (!covered[0])
            tc_error(tc, node->loc,
                     "non-exhaustive match: missing 'false' arm");
        if (!covered[1])
            tc_error(tc, node->loc,
                     "non-exhaustive match: missing 'true' arm");
    } else if (!has_wildcard && !type_is_error(target)) {
        /* Every other target (int, float, string, struct, fn, …) has an
         * infinite or non-pattern-enumerable space and Astra-0 has no
         * range patterns, so a catch-all is mandatory — matching the
         * `compile error por defecto` of ARCHITECTURE.md §11.3 and the
         * strict model chosen by research/004 (audit §3.8). Without this
         * the match fell through at run time and yielded a nil that lied
         * under whatever type the context promised. */
        tc_error(tc, node->loc,
                 "non-exhaustive match: missing '_' arm");
    }

    return result_type ? result_type : type_new(tc->arena, TYPE_VOID);
}

static Type *typecheck_return(TypeChecker *tc, Node *node) {
    Type *value_type = type_new(tc->arena, TYPE_VOID);

    if (node->as.return_expr.value) {
        value_type = typecheck_node(tc, node->as.return_expr.value);
        if (type_is_error(value_type)) return value_type;
    }

    /* A module-scope `return` used to be silently accepted: both VMs
     * treated it as "end of module" (rc=0, main never ran) and the C
     * backend generated uncompilable C (`return frame[...]` from an int
     * function) (audit §4.5). fn_depth, not current_fn_return: an
     * unannotated fn also leaves the annotation NULL. */
    if (tc->fn_depth == 0) {
        return tc_error_type(tc, node->loc, "return outside of a function");
    }
    /* An unannotated fn leaves the annotation NULL (inference path): only
     * compare when there is one, like before. */
    if (tc->current_fn_return && !type_eq(value_type, tc->current_fn_return)) {
        return tc_error_type(tc, node->loc,
                             "return type %s does not match function return type %s",
                             type_kind_name(value_type->kind),
                             type_kind_name(tc->current_fn_return->kind));
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
 * research/001 §12.1 uses LValue without defining it). */
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

    /* DEC-013: indexing a string is read-only (`s[i]` reads one byte), so
     * `s[0] = "x"` keeps the compile-time rejection it had when string
     * indexing was rejected outright. The receiver is typechecked here, and
     * an errored receiver returns before typecheck_node(target) re-walks it —
     * no diagnostic is ever emitted twice for the same node. */
    if (target->kind == NODE_INDEX) {
        Type *obj = typecheck_node(tc, target->as.index.object);
        if (type_is_error(obj)) return obj;
        if (obj->kind == TYPE_STRING) {
            return tc_error_type(tc, target->loc, "cannot assign to string element");
        }
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

/* ------------------------------------------------------------
 * DEC-006/DEC-007 (research/027 §1, ratificada 2026-10-27)
 *
 * An integer literal that meets a concrete integer type must FIT it: a
 * compile-time range check at the point where the literal stops being
 * polymorphic. The runtime stays a single i64 with defined two's-complement
 * wrap on every route (research/027 §1 option 1E). The default type of an
 * unannotated binding stays i32 — unless the literal does not fit it, in
 * which case it falls to i64 (the Rust rule), so `let x = 9999999999`
 * keeps working.
 *
 * Messages here are mirrored byte-for-byte in zig/src/typechecker/
 * typechecker.zig (ui_message_parity.sh gates the first diagnostic line).
 * ------------------------------------------------------------ */

/* The value of an integer literal node, folding a leading `-` (`-1` is
 * UNOP_NEG over the literal). Returns false for any other shape. */
static bool int_lit_value(Node *n, int64_t *out) {
    if (!n) return false;
    if (n->kind == NODE_INT_LIT) { *out = n->as.int_lit.value; return true; }
    if (n->kind == NODE_UNARY_OP && n->as.unary.op == UNOP_NEG &&
        n->as.unary.operand && n->as.unary.operand->kind == NODE_INT_LIT) {
        *out = -n->as.unary.operand->as.int_lit.value;
        return true;
    }
    return false;
}

/* Does the value fit the concrete integer type? i64/u64 upper bounds cannot
 * be exceeded through an int64 literal (the lexer already rejects anything
 * past i64 max), so those reduce to the sign check. */
static bool int_lit_fits(int64_t v, TypeKind k) {
    switch (k) {
    case TYPE_INT:     return v >= INT32_MIN && v <= INT32_MAX;
    case TYPE_UINT32:  return v >= 0 && v <= (int64_t)UINT32_MAX;
    case TYPE_INT64:   return true;
    case TYPE_UINT64:  return v >= 0;
    default:           return true;
    }
}

/* The DEC-006 default for an unannotated binding: i32, or i64 when the
 * literal does not fit i32. */
static Type *default_int_type(Arena *a, Node *init) {
    int64_t v;
    if (int_lit_value(init, &v) && !int_lit_fits(v, TYPE_INT))
        return type_new(a, TYPE_INT64);
    return type_new(a, TYPE_INT);
}

/* DEC-015 (research/028 PR2): a builtin name is a reserved global. The VM
 * resolves builtins by *name* in GET_GLOBAL and the LLVM emitter by name in
 * emitCall (before consulting the fn/local tables), so a user binding called
 * `len`/`print`/... would run the builtin on one route and the binding on
 * another. Reject the redeclaration instead of letting the routes diverge.
 * Reports and returns true when `name` is builtin. */
static bool builtin_redeclare_error(TypeChecker *tc, SrcLoc loc,
                                    InternedString name) {
    static const char *kBuiltins[] = { "print", "len", "to_string", "read_file", "ord", "substr", "push", "str_to_int" };
    for (size_t i = 0; i < sizeof(kBuiltins) / sizeof(kBuiltins[0]); i++) {
        const char *b = kBuiltins[i];
        if (name.len == strlen(b) && memcmp(name.str, b, name.len) == 0) {
            tc_error(tc, loc, "'%.*s' is a builtin and cannot be redeclared",
                     (int)name.len, name.str);
            return true;
        }
    }
    return false;
}

static void typecheck_var_decl(TypeChecker *tc, Node *node) {
    InternedString name = node->as.var_decl.name;
    Type *decl_type = NULL;

    if (builtin_redeclare_error(tc, node->loc, name)) return;

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
        /* Audit §7.1: the old hint claimed the initializer was a block whose
         * last statement ended in `;` — untrue for `{ while … }`, `print(1)`
         * or any other void value. State the fact that is always true and
         * keep the block rule as a parenthetical. */
        tc_error(tc, node->loc,
                 "variable '%.*s' cannot be initialized with a void expression: "
                 "this expression has no value to bind (a block has one only "
                 "when it ends in an expression, not a statement)",
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
        } else if (type_is_integer(decl_type)) {
            /* DEC-006: the literal adopted a concrete integer type — it has
             * to fit it (`let big: i32 = 9999999999` is a compile error). */
            int64_t lit;
            if (int_lit_value(node->as.var_decl.value, &lit) &&
                !int_lit_fits(lit, decl_type->kind)) {
                tc_error(tc, node->loc,
                         "integer literal %lld out of range for %s",
                         (long long)lit, type_kind_name(decl_type->kind));
            }
        }
        final_type = decl_type;
    } else if (decl_type) {
        final_type = decl_type;
    } else if (val_type) {
        /* `let x = 5` with no annotation: the literal stops being polymorphic
         * here and becomes the default integer type (i32). Without this fallback
         * an unannotated binding would stay polymorphic forever and could later
         * be assigned to `u64` as if it had been a u64 all along — Rust resolves
         * the same ambiguity the same way. DEC-006: the default falls to i64
         * when the literal does not fit i32. */
        final_type = (val_type->kind == TYPE_INT_LITERAL)
                   ? default_int_type(tc->arena, node->as.var_decl.value)
                   : val_type;
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

    if (builtin_redeclare_error(tc, node->loc, name)) return;

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
        } else if (type_is_integer(decl_type)) {
            /* DEC-006, same rule as `let`. */
            int64_t lit;
            if (int_lit_value(node->as.const_decl.value, &lit) &&
                !int_lit_fits(lit, decl_type->kind)) {
                tc_error(tc, node->loc,
                         "integer literal %lld out of range for %s",
                         (long long)lit, type_kind_name(decl_type->kind));
            }
        }
        final_type = decl_type;
    } else if (decl_type) {
        final_type = decl_type;
    } else if (val_type) {
        /* Same default as `let`: a bare const initialised with a literal takes
         * the default integer type (DEC-006: i64 when it does not fit i32). */
        final_type = (val_type->kind == TYPE_INT_LITERAL)
                   ? default_int_type(tc->arena, node->as.const_decl.value)
                   : val_type;
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

    /* DEC-015 for nested fns: a top-level `fn len()` is reported once, in
     * typecheck_module_pass, because the duplicate-function check lives there
     * and must not overwrite the diagnostic (a nested fn has no pass-1 arm,
     * so its only entry point is here). */
    if (tc->fn_depth > 0 && builtin_redeclare_error(tc, fn_node->loc, name)) {
        return;
    }

    /* Phase 2.4 step 2a: `<T>` binds as TYPE_PARAM for the signature and
     * the body check — a symbolic check over every instantiation. The
     * enclosing-fn pointer (step 2b) is set even for a non-generic fn so
     * a nested generic body always knows its owner. */
    bool generic = fn_node->as.fn_decl.generics.len > 0;
    Node *saved_gfn = tc->current_generic_fn;
    size_t gmark = push_generic_scope(tc, fn_node);
    tc->current_generic_fn = fn_node;

    /* Resolve parameter types */
    size_t param_count = fn_node->as.fn_decl.params.len;
    Type **param_types = arena_new_array(tc->arena, Type *, param_count);
    for (size_t i = 0; i < param_count; i++) {
        param_types[i] = resolve_type_node(tc, fn_node->as.fn_decl.param_types.data[i]);
        if (type_is_error(param_types[i])) {
            tc->current_generic_fn = saved_gfn;
            pop_generic_scope(tc, gmark);
            return;
        }
        /* No annotation (e.g. `self` when the impl pass could not synthesize
         * it): the signature type must not carry NULL into call sites —
         * typecheck_call dereferenced it (audit §3.2). */
        if (!param_types[i]) param_types[i] = type_new(tc->arena, TYPE_UNKNOWN);
    }

    /* Resolve return type */
    Type *ret_type = NULL;
    if (fn_node->as.fn_decl.return_type) {
        ret_type = resolve_type_node(tc, fn_node->as.fn_decl.return_type);
        if (type_is_error(ret_type)) {
            tc->current_generic_fn = saved_gfn;
            pop_generic_scope(tc, gmark);
            return;
        }
    }

    Type *fn_type = type_new_fn(tc->arena, param_types, param_count, ret_type);

    /* Insert function symbol */
    Symbol sym = {
        .name    = name,
        .type    = fn_type,
        .is_mut  = false,
        .is_fn   = true,
        .is_generic = generic,
        .fn_ast  = fn_node,
        .def_loc = fn_node->loc,
    };

    /* Update existing symbol if forward-declared */
    Symbol *existing = symbol_table_lookup(tc->symbols, name);
    if (existing) {
        existing->type = fn_type;
        existing->fn_ast = fn_node;
    } else {
        symbol_table_insert(tc->symbols, sym);
    }

    /* Type-check body */
    if (fn_node->as.fn_decl.body) {
        typecheck_fn_body(tc, fn_node);
    }
    tc->current_generic_fn = saved_gfn;
    pop_generic_scope(tc, gmark);
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
    tc->fn_depth++;

    /* Insert parameters into scope */
    size_t param_count = fn_node->as.fn_decl.params.len;
    for (size_t i = 0; i < param_count; i++) {
        Type *pt = resolve_type_node(tc, fn_node->as.fn_decl.param_types.data[i]);
        /* Unannotated parameter (`self` on a failed impl, or any missing
         * annotation): bind unknown rather than NULL, so uses of the symbol
         * type-check as unknown instead of crashing (audit §3.2). */
        if (!pt) pt = type_new(tc->arena, TYPE_UNKNOWN);
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
        if (!body_type) body_type = type_new(tc->arena, TYPE_ERROR);

        /* The body's value must satisfy the declared return type, whether it
         * arrives through the tail expression (research/001 §4.2) or through an
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
    tc->fn_depth--;
    symbol_table_pop_scope(tc->symbols);
}

static void typecheck_struct_decl(TypeChecker *tc, Node *node) {
    InternedString name = node->as.struct_decl.name;
    bool generic = node->as.struct_decl.generics.len > 0;

    /* The module pass pre-registers top-level struct names (declare_type_decls)
     * so field types may reference structs declared later in the file. Fill
     * that type in place; a name not bound to a struct — a nested declaration
     * inside a function body, or a shadowing local — gets a fresh type.
     * A generic declaration fills its *template*: fields resolve with the
     * parameters in scope, so `value: T` lands as TYPE_PARAM(owner=decl) and
     * literal inference can unify against it (Phase 2.4 step 3b). */
    Type *st_type = NULL;
    Symbol *existing = symbol_table_lookup(tc->symbols, name);
    if (existing && existing->type && existing->type->kind == TYPE_STRUCT) {
        st_type = existing->type;
    } else {
        st_type = type_new(tc->arena, TYPE_STRUCT);
        st_type->as.struc.name = name;
        Symbol sym = {
            .name    = name,
            .type    = st_type,
            .is_mut  = false,
            .is_fn   = false,
            .is_generic = generic,
            .fn_ast  = NULL,
            .type_ast = node,
            .def_loc = node->loc,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    size_t gmark = push_generic_bindings(tc, &node->as.struct_decl.generics, node);

    /* Populate fields */
    size_t field_count = node->as.struct_decl.field_names.len;
    if (field_count > 0) {
        st_type->as.struc.fields = arena_new_array(tc->arena, StructField, field_count);
        st_type->as.struc.field_count = field_count;
        for (size_t i = 0; i < field_count; i++) {
            /* Duplicate field names silently overwrote each other — a
             * struct with two `a` fields type-checked and the last
             * declaration won (audit §3.5). Collect and keep going. */
            for (size_t j = 0; j < i; j++) {
                if (string_eq(node->as.struct_decl.field_names.data[j],
                              node->as.struct_decl.field_names.data[i])) {
                    tc_error(tc, node->loc,
                             "duplicate field '%.*s' in struct '%.*s'",
                             (int)node->as.struct_decl.field_names.data[i].len,
                             node->as.struct_decl.field_names.data[i].str,
                             (int)name.len, name.str);
                    break;
                }
            }
            Type *ft = resolve_type_node(tc, node->as.struct_decl.field_types.data[i]);
            if (type_is_error(ft)) {
                pop_generic_scope(tc, gmark);
                return;
            }
            st_type->as.struc.fields[i].name = node->as.struct_decl.field_names.data[i];
            st_type->as.struc.fields[i].type = ft;
        }
    } else {
        st_type->as.struc.fields = NULL;
        st_type->as.struc.field_count = 0;
    }
    pop_generic_scope(tc, gmark);
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

    /* Phase 2.4 step 1: same contract as structs (see typecheck_struct_decl). */
    if (node->as.enum_decl.generics.len > 0) return;

    /* Same forward-reference contract as structs: the module pass binds the
     * name, this fills variants and payload layouts into that type. */
    Type *en_type = NULL;
    Symbol *existing = symbol_table_lookup(tc->symbols, name);
    if (existing && existing->type && existing->type->kind == TYPE_ENUM) {
        en_type = existing->type;
    } else {
        en_type = type_new(tc->arena, TYPE_ENUM);
        en_type->as.enumeration.name = name;
        Symbol sym = {
            .name    = name,
            .type    = en_type,
            .is_mut  = false,
            .is_fn   = false,
            .def_loc = node->loc,
        };
        symbol_table_insert(tc->symbols, sym);
    }

    size_t nv = node->as.enum_decl.variants.len;
    en_type->as.enumeration.variant_count = nv;
    en_type->as.enumeration.variants =
        nv > 0 ? arena_new_array(tc->arena, InternedString, nv) : NULL;
    for (size_t i = 0; i < nv; i++) {
        /* Duplicate variant names made the enum ambiguous: covered[] has
         * one slot per spelling, so a correct match then reported an
         * impossible "non-exhaustive missing variant 'E.A'" (audit §3.7,
         * the enum analogue of the struct-field check). */
        for (size_t j = 0; j < i; j++) {
            if (string_eq(node->as.enum_decl.variants.data[j],
                          node->as.enum_decl.variants.data[i])) {
                tc_error(tc, node->loc,
                         "duplicate variant '%.*s' in enum '%.*s'",
                         (int)node->as.enum_decl.variants.data[i].len,
                         node->as.enum_decl.variants.data[i].str,
                         (int)name.len, name.str);
                break;
            }
        }
        en_type->as.enumeration.variants[i] = node->as.enum_decl.variants.data[i];
        checker_add_variant(tc, node->as.enum_decl.variants.data[i], en_type, false);
    }

    /* Payload layouts run parallel to the variants: index i describes
     * variants[i]. A unit variant carries zero fields. */
    en_type->as.enumeration.payloads =
        nv > 0 ? arena_new_array(tc->arena, VariantLayout, nv) : NULL;
    for (size_t i = 0; i < nv; i++) {
        VariantLayout *vl = &en_type->as.enumeration.payloads[i];
        vl->names = NULL;
        vl->types = NULL;
        vl->field_count = 0;
        Node *payload = node->as.enum_decl.variant_payloads.len > i
            ? node->as.enum_decl.variant_payloads.data[i] : NULL;
        if (!payload) continue;
        size_t nf = payload->as.payload.fields.len;
        vl->field_count = nf;
        vl->types = nf > 0 ? arena_new_array(tc->arena, Type *, nf) : NULL;
        vl->names = nf > 0 ? arena_new_array(tc->arena, InternedString, nf) : NULL;
        for (size_t j = 0; j < nf; j++) {
            PayloadField *pf = &payload->as.payload.fields.data[j];
            vl->names[j] = pf->name;
            vl->types[j] = resolve_type_node(tc, pf->type);
            if (type_is_error(vl->types[j])) return;
        }
    }
}

/* ============================================================
 * §7: Module Type Checking
 * ============================================================ */

/* Pass 0 of module type checking: bind every top-level struct/enum name to an
 * empty type before any signature or field type is resolved. Declarations may
 * then reference each other in any order (forward references, mutual
 * recursion); typecheck_{struct,enum}_decl fills the layouts in pass 1. */
static void declare_type_decls(TypeChecker *tc, Node *module) {
    for (size_t i = 0; i < module->as.module.items.len; i++) {
        Node *item = module->as.module.items.data[i];
        if (item->kind == NODE_STRUCT_DECL) {
            Type *st = type_new(tc->arena, TYPE_STRUCT);
            st->as.struc.name = item->as.struct_decl.name;
            st->as.struc.fields = NULL;
            st->as.struc.field_count = 0;
            Symbol sym = {
                .name    = item->as.struct_decl.name,
                .type    = st,
                .is_mut  = false,
                .is_fn   = false,
                /* Step 3b: a generic declaration binds its name too — as a
                 * template, so `Box<i32>` finds the base and a bare `Box`
                 * can complain about the missing arguments. Fields fill in
                 * typecheck_struct_decl. */
                .is_generic = item->as.struct_decl.generics.len > 0,
                .fn_ast  = NULL,
                .type_ast = item,
                .def_loc = item->loc,
            };
            symbol_table_insert(tc->symbols, sym);
        } else if (item->kind == NODE_ENUM_DECL) {
            if (item->as.enum_decl.generics.len > 0) continue;
            Type *en = type_new(tc->arena, TYPE_ENUM);
            en->as.enumeration.name = item->as.enum_decl.name;
            en->as.enumeration.variant_count = 0;
            en->as.enumeration.variants = NULL;
            en->as.enumeration.payloads = NULL;
            Symbol sym = {
                .name    = item->as.enum_decl.name,
                .type    = en,
                .is_mut  = false,
                .is_fn   = false,
                .def_loc = item->loc,
            };
            symbol_table_insert(tc->symbols, sym);
        }
    }
}

/* Phase 2.3 step 5: collect every trait's required method signatures. Runs
 * after declare_type_decls, so parameter and return types resolve in any
 * source order, and before the impl pass, so `impl T for X` can verify
 * conformance. A trait item with statements or a tail expression is a
 * default method — rejected until a later phase defines the lookup rules;
 * the empty block a signature-only item gets from the parser carries no
 * statements, so it passes untouched. */
static void collect_trait_decls(TypeChecker *tc, Node *module) {
    for (size_t i = 0; i < module->as.module.items.len; i++) {
        Node *item = module->as.module.items.data[i];
        if (item->kind != NODE_TRAIT) continue;
        if (item->as.trait_decl.generics.len > 0) continue; /* Phase 2.4 step 1 */
        Node *tr = item;
        TraitMethod *methods = NULL;
        size_t count = 0, cap = 0;
        for (size_t j = 0; j < tr->as.trait_decl.items.len; j++) {
            Node *fn = tr->as.trait_decl.items.data[j];
            if (fn->kind != NODE_FN_DECL) continue; /* the parser already reported it */
            if (fn->as.fn_decl.generics.len > 0) continue; /* Phase 2.4 step 1 */
            Node *body = fn->as.fn_decl.body;
            if (body && (body->as.block.stmts.len > 0 ||
                         body->as.block.last_expr)) {
                tc_error(tc, fn->loc, "default trait methods are not yet supported");
            }
            size_t pc = fn->as.fn_decl.params.len;
            if (pc == 0) continue; /* the parser already reported it */
            if (count >= cap) {
                size_t nc = cap == 0 ? 8 : cap * 2;
                TraitMethod *nd = arena_new_array(tc->arena, TraitMethod, nc);
                if (methods) {
                    memcpy(nd, methods, sizeof(TraitMethod) * count);
                }
                methods = nd;
                cap = nc;
            }
            TraitMethod *tm = &methods[count];
            tm->name = fn->as.fn_decl.name;
            tm->param_count = pc - 1; /* params[0] is the receiver */
            tm->param_types = arena_new_array(tc->arena, Type *, pc - 1);
            for (size_t k = 1; k < pc; k++) {
                tm->param_types[k - 1] =
                    resolve_type_node(tc, fn->as.fn_decl.param_types.data[k]);
            }
            tm->ret = NULL;
            if (fn->as.fn_decl.return_type) {
                tm->ret = resolve_type_node(tc, fn->as.fn_decl.return_type);
            }
            count++;
        }
        checker_add_trait(tc, tr->as.trait_decl.name, methods, count);
    }
}

static void typecheck_module_pass(TypeChecker *tc, Node *module) {
    declare_type_decls(tc, module);
    collect_trait_decls(tc, module);
    for (size_t i = 0; i < module->as.module.items.len; i++) {
        Node *item = module->as.module.items.data[i];
        switch (item->kind) {
        case NODE_FN_DECL:
            /* First pass: register function signature only. A generic
             * signature registers with TYPE_PARAM placeholders and is marked
             * `is_generic` (Phase 2.4 step 2a); the body is checked in pass 2
             * with the same placeholders in scope. */
            {
                /* DEC-015: a top-level `fn print()` reports here, before the
                 * duplicate-function check — that check would otherwise name
                 * the builtin symbol a duplicate and lose the rule. The body
                 * is still checked in pass 2 (with no registration), so only
                 * the name error fires for a trivial body. */
                if (builtin_redeclare_error(tc, item->loc, item->as.fn_decl.name))
                    break;
                bool generic = item->as.fn_decl.generics.len > 0;
                Node *saved_gfn = tc->current_generic_fn;
                size_t gmark = push_generic_scope(tc, item);
                tc->current_generic_fn = item;
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
                /* A duplicate top-level fn used to be accepted: the VM kept
                 * the LAST definition while the C backend emitted the FIRST
                 * (its fn_map is first-wins), so the same file printed
                 * different answers on the two backends (audit §3.10). */
                Symbol *prev = symbol_table_lookup(tc->symbols, item->as.fn_decl.name);
                if (prev && prev->is_fn) {
                    tc_error(tc, item->loc,
                             "duplicate function '%.*s'",
                             (int)item->as.fn_decl.name.len,
                             item->as.fn_decl.name.str);
                }
                Symbol sym = {
                    .name    = item->as.fn_decl.name,
                    .type    = fn_type,
                    .is_mut  = false,
                    .is_fn   = true,
                    .is_generic = generic,
                    .fn_ast  = item,
                    .def_loc = item->loc,
                };
                symbol_table_insert(tc->symbols, sym);
                tc->current_generic_fn = saved_gfn;
                pop_generic_scope(tc, gmark);
            }
            break;
        case NODE_STRUCT_DECL:
            typecheck_struct_decl(tc, item);
            break;
        case NODE_ENUM_DECL:
            typecheck_enum_decl(tc, item);
            break;
        case NODE_IMPL:
            /* Phase 2.4 step 1: a block with `<...>` stays inert. */
            if (item->as.impl_decl.generics.len > 0) break;
            /* Phase 2.3 step 3-4: register every method in the static-dispatch
             * table and rewrite the fn's name to the mangled global
             * `Type.method` it is emitted as (--dump-ast runs before checking,
             * so nothing user-visible changes). A typeless receiver gets a
             * synthesized type node so the body pass resolves `self` through
             * the normal path. Trait impls are then checked for conformance
             * (step 5, after the item loop). */
            {
                Node *impl = item;
                InternedString tname = impl->as.impl_decl.type_name;
                bool inherent = impl->as.impl_decl.trait_name.str == NULL;

                Node *tn = node_new(tc->arena, NODE_TYPE_IDENT, impl->loc);
                tn->as.type_ident.name = tname;
                Type *recv = resolve_type_node(tc, tn);
                if (type_is_error(recv)) break;
                if (recv->kind != TYPE_STRUCT && recv->kind != TYPE_ENUM) {
                    tc_error(tc, impl->loc,
                             "impl requires a struct or enum type, got %s",
                             type_kind_name(recv->kind));
                    break;
                }
                /* Phase 2.4 step 4: bound checking consults this record;
                 * the method table alone cannot (a method-less trait impl
                 * registers no method entry). */
                if (!inherent)
                    checker_add_impl(tc, tname, impl->as.impl_decl.trait_name);

                for (size_t j = 0; j < impl->as.impl_decl.items.len; j++) {
                    Node *fn = impl->as.impl_decl.items.data[j];
                    if (fn->kind != NODE_FN_DECL ||
                        fn->as.fn_decl.generics.len > 0 ||
                        fn->as.fn_decl.params.len == 0 ||
                        !fn->as.fn_decl.has_self) {
                        continue; /* the parser already reported it */
                    }

                    /* Receiver: typeless `self` borrows the impl's type; a
                     * typed receiver must name exactly that type. */
                    if (fn->as.fn_decl.param_types.data[0]) {
                        Type *ann = resolve_type_node(tc,
                            fn->as.fn_decl.param_types.data[0]);
                        if (!type_is_error(ann) && !type_eq(ann, recv)) {
                            tc_error(tc, fn->loc, "type of 'self' must be '%.*s'",
                                     (int)tname.len, tname.str);
                        }
                    } else {
                        Node *syn = node_new(tc->arena, NODE_TYPE_IDENT, fn->loc);
                        syn->as.type_ident.name = tname;
                        fn->as.fn_decl.param_types.data[0] = syn;
                    }

                    InternedString mname = fn->as.fn_decl.name;
                    /* The symbol table and the emitter both key the method by
                     * its mangled global; `mname` stays the lookup key. */
                    fn->as.fn_decl.name =
                        checker_method_global(tc, tname,
                                              impl->as.impl_decl.trait_name,
                                              mname);

                    size_t pc = fn->as.fn_decl.params.len;
                    Type **pts = arena_new_array(tc->arena, Type *, pc);
                    bool bad = false;
                    for (size_t k = 0; k < pc; k++) {
                        /* Receiver: resolve straight to the impl type — the
                         * annotation check above already reported any typo. */
                        pts[k] = k == 0
                            ? recv
                            : resolve_type_node(tc, fn->as.fn_decl.param_types.data[k]);
                        if (type_is_error(pts[k])) { bad = true; break; }
                    }
                    Type *ret = NULL;
                    if (!bad && fn->as.fn_decl.return_type) {
                        ret = resolve_type_node(tc, fn->as.fn_decl.return_type);
                        if (type_is_error(ret)) bad = true;
                    }
                    if (bad) continue;
                    checker_add_method(tc, tname, mname,
                                       impl->as.impl_decl.trait_name, inherent,
                                       type_new_fn(tc->arena, pts, pc, ret),
                                       fn->loc);
                }

                /* Phase 2.3 step 5: a trait impl must name a known trait and
                 * provide every required method with the required signature.
                 * Conformance is per-impl-block — an inherent method never
                 * satisfies a trait requirement (Rust's rule); it only
                 * shadows the trait's entry at dispatch. */
                if (!inherent) {
                    InternedString trname = impl->as.impl_decl.trait_name;
                    TraitInfo *ti = checker_find_trait(tc, trname);
                    if (!ti) {
                        tc_error(tc, impl->loc, "unknown trait '%.*s'",
                                 (int)trname.len, trname.str);
                    } else {
                        for (size_t k = 0; k < ti->method_count; k++) {
                            TraitMethod *tm = &ti->methods[k];
                            MethodEntry *m = checker_find_trait_method(
                                tc, tname, tm->name, trname);
                            if (!m) {
                                tc_error(tc, impl->loc,
                                         "type '%.*s' does not implement trait '%.*s': missing method '%.*s'",
                                         (int)tname.len, tname.str,
                                         (int)ti->name.len, ti->name.str,
                                         (int)tm->name.len, tm->name.str);
                                continue;
                            }
                            Type *fn = m->fn_type;
                            bool sig_ok =
                                fn->as.fn.param_count == tm->param_count + 1;
                            for (size_t q = 0;
                                 sig_ok && q < tm->param_count; q++) {
                                if (!type_eq(fn->as.fn.params[q + 1],
                                             tm->param_types[q])) {
                                    sig_ok = false;
                                }
                            }
                            Type *iret = fn->as.fn.ret
                                ? fn->as.fn.ret
                                : type_new(tc->arena, TYPE_VOID);
                            Type *tret = tm->ret
                                ? tm->ret
                                : type_new(tc->arena, TYPE_VOID);
                            if (!type_eq(iret, tret)) sig_ok = false;
                            if (!sig_ok) {
                                tc_error(tc, m->loc,
                                         "signature of method '%.*s' of '%.*s' does not match trait '%.*s'",
                                         (int)tm->name.len, tm->name.str,
                                         (int)tname.len, tname.str,
                                         (int)ti->name.len, ti->name.str);
                            }
                        }
                    }
                }
            }
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
            /* Skip pure declarations, only type-check bodies. A generic body
             * is checked symbolically with its `<T>` placeholders in scope
             * (Phase 2.4 step 2a). */
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
        case NODE_STRUCT_DECL:
        case NODE_ENUM_DECL:
            /* Bodies were fully checked in typecheck_module_pass; the
             * `default` path re-checked them and duplicated every
             * diagnostic (audit §3.5 surfaced it: "duplicate field"
             * printed twice). Nested declarations inside function bodies
             * still go through typecheck_node. */
            break;
        case NODE_IMPL:
            /* Bodies of the methods pass 1 registered. Their names are the
             * mangled `Type.method` globals by now, so typecheck_fn_decl
             * inserts/updates the right symbol and `self` resolves through
             * the type node pass 1 synthesized. A block (or method) with
             * `<...>` was skipped by pass 1 and stays inert (Phase 2.4). */
            if (item->as.impl_decl.generics.len > 0) break;
            {
                Node *impl = item;
                for (size_t j = 0; j < impl->as.impl_decl.items.len; j++) {
                    Node *fn = impl->as.impl_decl.items.data[j];
                    if (fn->kind == NODE_FN_DECL && fn->as.fn_decl.has_self &&
                        fn->as.fn_decl.generics.len == 0 &&
                        fn->as.fn_decl.body) {
                        typecheck_fn_decl(tc, fn);
                    }
                }
            }
            break;
        default:
            typecheck_node(tc, item);
            break;
        }
    }
}

/* `expr?` may unwind the enclosing frame with the absence/error, so that
 * frame's declared return must be able to carry it: a `?` inside a fn
 * declared `-> i32` (or with no return at all, or at module level) would
 * hand the caller a nil/err value under an i32 promise. Checked statically
 * instead of letting the VM unwind into a type lie. */
static void try_check_enclosing_return(TypeChecker *tc, SrcLoc loc) {
    Type *ret = tc->current_fn_return;
    /* No tracked return (module level, unannotated fn/lambda): reject.
     * An unresolvable annotation was already reported — don't pile on. */
    if (ret && (ret->kind == TYPE_ERROR || ret->kind == TYPE_UNKNOWN)) return;
    if (ret && ret->kind == TYPE_OPTIONAL) return;
    tc_error(tc, loc,
             "? operator requires the enclosing function to return an "
             "optional type");
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

    /* Expressions */
    case NODE_IDENT:      return typecheck_ident(tc, node);
    case NODE_BINARY_OP:  return typecheck_binary(tc, node);
    case NODE_UNARY_OP:   return typecheck_unary(tc, node);
    case NODE_CALL:       return typecheck_call(tc, node);
    case NODE_INDEX:      return typecheck_index(tc, node);
    case NODE_ARRAY_LIT:  return typecheck_array_lit(tc, node);
    case NODE_STRUCT_LIT: return typecheck_struct_lit(tc, node);
    /* Option/Result constructors produce *tagged* values, so their static type
     * is an optional wrapping the payload — not the bare payload. Returning the
     * payload type let a tagged value masquerade as a plain value (so
     * `let x: i32 = some(3)` type-checked) and left `x?` with nothing to unwrap,
     * which made the operator unusable. The VM agrees: OPCODE_TRY_UNWRAP errors
     * out with "? requires Result or Option" when the value carries no tag.
     * Static Result typing (a distinct TYPE_RESULT, so `err` cannot be confused
     * with a present value) is Tier 2 per research/002 §5.2; here both OK/ERR
     * carry the payload type and the distinction lives in the runtime tag. */
    case NODE_SOME_EXPR: {
        Type *inner = typecheck_node(tc, node->as.some_expr.value);
        if (type_is_error(inner)) return inner;
        return type_new_optional(tc->arena, inner);
    }
    case NODE_NONE_EXPR: {
        /* Absence: TYPE_NIL unifies with any TYPE_OPTIONAL (see type_eq). */
        return type_new(tc->arena, TYPE_NIL);
    }
    case NODE_OK_EXPR: {
        Type *inner = typecheck_node(tc, node->as.ok_expr.value);
        if (type_is_error(inner)) return inner;
        return type_new_optional(tc->arena, inner);
    }
    case NODE_ERR_EXPR: {
        Type *inner = typecheck_node(tc, node->as.err_expr.value);
        if (type_is_error(inner)) return inner;
        return type_new_optional(tc->arena, inner);
    }
    case NODE_TRY_EXPR: {
        Type *inner = typecheck_node(tc, node->as.try_expr.inner);
        if (type_is_error(inner)) return inner;
        /* `expr?` unwraps one optional layer: OPCODE_TRY_UNWRAP yields the
         * payload, or unwinds the frame when the value is absent/err.
         * Only a tagged value can do that: a type parameter is checked once
         * symbolically and left to its instantiations, everything else
         * fails at run time on both backends — so it fails here instead.
         * The bare `none` literal types as nil, not as `T?`, so `none?`
         * gets the same rejection; propagate absence through a typed
         * optional (`let v: i32? = none; v?`) or `return none`. The
         * enclosing return must be optional for the unwind path to
         * type-check. */
        if (inner->kind != TYPE_OPTIONAL && inner->kind != TYPE_PARAM) {
            tc_error(tc, node->loc,
                     "? operator requires Result or Option, got %s",
                     type_kind_name(inner->kind));
            return inner;
        }
        try_check_enclosing_return(tc, node->loc);
        if (inner->kind == TYPE_OPTIONAL) return inner->as.optional.inner;
        return inner;
    }
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
    case NODE_LAMBDA: {
        /* Resolve parameter types */
        size_t param_count = node->as.lambda.params.len;
        Type **param_types = arena_new_array(tc->arena, Type *, param_count);
        for (size_t i = 0; i < param_count; i++) {
            param_types[i] = resolve_type_node(tc, node->as.lambda.param_types.data[i]);
            if (type_is_error(param_types[i])) return type_new(tc->arena, TYPE_VOID);
            /* `|x|` with no annotation: the body scope and the fn type both
             * take this array — NULL made `x + 1` report "symbol has no
             * type" and crashed typecheck_call on `f(2)` (audit §3.1).
             * Unknown flows through type_eq and matches zig's behaviour. */
            if (!param_types[i]) param_types[i] = type_new(tc->arena, TYPE_UNKNOWN);
        }
        /* Resolve return type from annotation */
        Type *ret_type = NULL;
        if (node->as.lambda.return_type) {
            ret_type = resolve_type_node(tc, node->as.lambda.return_type);
            if (type_is_error(ret_type)) return type_new(tc->arena, TYPE_VOID);
        }
        /* Enter scope and bind parameters */
        symbol_table_push_scope(tc->symbols);
        for (size_t i = 0; i < param_count; i++) {
            Symbol sym = {
                .name    = node->as.lambda.params.data[i],
                .type    = param_types[i],
                .is_mut  = false,
                .is_fn   = false,
                .def_loc = node->loc,
            };
            symbol_table_insert(tc->symbols, sym);
        }
        /* Save and set current function return type for return statements.
         * If we don't have an explicit return type, leave it NULL for now;
         * we'll infer it after type-checking the body. */
        Type *saved_return = tc->current_fn_return;
        tc->current_fn_return = ret_type;
        tc->fn_depth++;
        /* Type-check body */
        Type *body_type = NULL;
        if (node->as.lambda.body) {
            body_type = typecheck_node(tc, node->as.lambda.body);
        }
        tc->current_fn_return = saved_return;
        tc->fn_depth--;
        symbol_table_pop_scope(tc->symbols);
        /* Infer return type: if not annotated, use body type. For blocks
         * ending in return statements the body_type is void, so walk the
         * body to find the return value type. */
        if (!ret_type) {
            /* No explicit return type: try to infer from body.
             * For blocks ending in tail expressions, body_type is the expr type.
             * For blocks ending in return, we need to check. */
            if (body_type && body_type->kind != TYPE_VOID) {
                ret_type = body_type;
            } else if (body_type && body_type->kind == TYPE_VOID) {
                /* Block is void — likely ends with return statements.
                 * For now, require explicit return type annotation. */
                return tc_error_type(tc, node->loc,
                    "lambda requires explicit return type annotation");
            } else {
                ret_type = type_new(tc->arena, TYPE_VOID);
            }
        }
        return type_new_fn(tc->arena, param_types, param_count, ret_type);
    }
    case NODE_STRUCT_DECL:  typecheck_struct_decl(tc, node); return type_new(tc->arena, TYPE_VOID);
    case NODE_ENUM_DECL:    typecheck_enum_decl(tc, node); return type_new(tc->arena, TYPE_VOID);
    case NODE_VAR_DECL:     typecheck_var_decl(tc, node); return type_new(tc->arena, TYPE_VOID);
    case NODE_CONST_DECL:   typecheck_const_decl(tc, node); return type_new(tc->arena, TYPE_VOID);

    /* Declaration-only payload of a data-carrying enum variant. Checked when
     * the enum itself is; appearing anywhere else is a grammar bug. */
    case NODE_PAYLOAD:      return tc_error_type(tc, node->loc,
                                "variant payload outside an enum declaration");

    /* `use` is parsed and then discarded: the driver compiles a single file, so
     * module resolution is deliberately not the seed's job (research/002 §5.2).
     * It is still an Astra-0 construct (constructs/use.c sets in_astra0), but
     * this dispatch had no case for it, so every `use` fell through to the
     * "unhandled node kind" error and the construct was unusable. */
    case NODE_USE:          return type_new(tc->arena, TYPE_VOID);

    /* `import` / `from` are parsed and then discarded for the same reason as
     * `use`: the seed compiles a single file, so module resolution is not its
     * job (research/002 §5.2, ARCHITECTURE.md §10). The item nodes exist only
     * to record the names a `from` statement would bring into scope. */
    case NODE_IMPORT:
    case NODE_FROM:
    case NODE_IMPORT_ITEM:  return type_new(tc->arena, TYPE_VOID);

    /* Phase 2.3: a top-level `impl` is handled by the module passes (method
     * table + bodies, step 3-4). Reaching this dispatch means the node is
     * somewhere else — a nested `impl`/`trait` inside a function body — and
     * stays inert there; `trait` declarations are walked for conformance in
     * step 5. */
    case NODE_TRAIT:
    case NODE_IMPL:        return type_new(tc->arena, TYPE_VOID);

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

GenericInstance *typechecker_instances(TypeChecker *tc, size_t *out_count) {
    if (out_count) *out_count = tc ? tc->inst_count : 0;
    return tc ? tc->instances : NULL;
}

void typechecker_append_instances(TypeChecker *tc, Node *module) {
    if (!tc || !module || tc->inst_count == 0) return;
    Node **old_items = module->as.module.items.data;
    size_t n_items = module->as.module.items.len;
    Node **fresh = arena_new_array(tc->arena, Node *, n_items + tc->inst_count);
    size_t w = 0;
    for (size_t i = 0; i < n_items; i++) {
        fresh[w++] = old_items[i];
        for (size_t j = 0; j < tc->inst_count; j++) {
            if (tc->instances[j].source == old_items[i])
                fresh[w++] = tc->instances[j].wrapper;
        }
    }
    module->as.module.items.data = fresh;
    module->as.module.items.len = w;
    module->as.module.items.cap = n_items + tc->inst_count;
}
