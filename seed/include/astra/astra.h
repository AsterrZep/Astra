#ifndef ASTRA_H
#define ASTRA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ============================================================
 * Astra Seed Compiler — Public API
 * ============================================================
 * This header defines the interfaces between all compiler phases.
 * Each component (lexer, parser, typechecker, codegen, vm)
 * implements these interfaces.
 * ============================================================ */

/* -----------------------------------------------------------
 * §1: Source Location
 * ----------------------------------------------------------- */

typedef struct {
    const char *filename;
    uint32_t line;
    uint32_t column;
    uint32_t offset;
} SrcLoc;

SrcLoc srcloc_make(const char *filename, uint32_t line, uint32_t column, uint32_t offset);
void   srcloc_print(SrcLoc loc);

/* -----------------------------------------------------------
 * §2: Memory Arena
 * -----------------------------------------------------------
 * Arena allocator for compiler data structures.
 * All allocations are freed at once when arena_destroy() is called.
 * This is the recommended pattern for compiler internals.
 * ----------------------------------------------------------- */

typedef struct Arena Arena;

Arena  *arena_create(size_t initial_size);
void   *arena_alloc(Arena *a, size_t size, size_t align);
void   *arena_alloc_zero(Arena *a, size_t size, size_t align);
char   *arena_strdup(Arena *a, const char *s, size_t len);
void    arena_destroy(Arena *a);

#define arena_new(a, T) ((T *)arena_alloc_zero((a), sizeof(T), _Alignof(T)))
#define arena_new_array(a, T, n) ((T *)arena_alloc_zero((a), sizeof(T) * (n), _Alignof(T)))

/* -----------------------------------------------------------
 * §3: String Interning
 * -----------------------------------------------------------
 * All strings are interned for fast equality comparison.
 * Two interned strings can be compared with == (pointer comparison).
 * ----------------------------------------------------------- */

typedef struct {
    const char *str;
    size_t      len;
    uint32_t    hash;
} InternedString;

typedef struct StringTable StringTable;

StringTable  *string_table_create(Arena *a);
InternedString string_intern(StringTable *st, const char *str, size_t len);
InternedString string_intern_cstr(StringTable *st, const char *str);
bool           string_eq(InternedString a, InternedString b);

/* -----------------------------------------------------------
 * §4: Dynamic Arrays
 * ----------------------------------------------------------- */

#define DYNARRAY(T) \
    struct {        \
        T *data;    \
        size_t len; \
        size_t cap; \
    }

#define da_init(T) ((DYNARRAY(T)){0})

void da_grow_impl(void **data, size_t *len, size_t *cap, size_t elem_size, size_t new_cap);

#define da_push(T, arr, val, arena) do {                  \
    if ((arr).len >= (arr).cap) {                         \
        size_t new_cap = (arr).cap == 0 ? 16 : (arr).cap * 2; \
        da_grow_impl((void **)&(arr).data, &(arr).len,    \
                     &(arr).cap, sizeof(T), new_cap);     \
        if (arena) {                                      \
            (arr).data = arena_alloc(arena,               \
                sizeof(T) * new_cap, _Alignof(T));       \
            memset((arr).data, 0, sizeof(T) * new_cap);  \
        }                                                 \
    }                                                     \
    (arr).data[(arr).len++] = (val);                      \
} while(0)

/* -----------------------------------------------------------
 * §5: Lexer (Token Types)
 * ----------------------------------------------------------- */

typedef enum {
    /* Literals */
    TOKEN_INT_LIT,
    TOKEN_FLOAT_LIT,
    TOKEN_STRING_LIT,
    TOKEN_IDENT,

    /* Keywords */
    TOKEN_FN,
    TOKEN_LET,
    TOKEN_VAR,
    TOKEN_IF,
    TOKEN_ELSE,
    TOKEN_WHILE,
    TOKEN_FOR,
    TOKEN_MATCH,
    TOKEN_RETURN,
    TOKEN_BREAK,
    TOKEN_CONTINUE,
    TOKEN_STRUCT,
    TOKEN_ENUM,
    TOKEN_TRAIT,
    TOKEN_IMPL,
    TOKEN_USE,
    TOKEN_MOD,
    TOKEN_PUB,
    TOKEN_MUT,
    TOKEN_TRUE,
    TOKEN_FALSE,
    TOKEN_NULL,
    TOKEN_OK,
    TOKEN_ERR,
    TOKEN_AND,
    TOKEN_OR,
    TOKEN_NOT,
    TOKEN_COMPTIME,
    TOKEN_CONST,
    TOKEN_IN,
    TOKEN_SOME,    // some
    TOKEN_NONE,    // none
    TOKEN_OPTION,  // option
    TOKEN_RESULT,  // result

    /* Operators */
    TOKEN_PLUS,        /* + */
    TOKEN_MINUS,       /* - */
    TOKEN_STAR,        /* * */
    TOKEN_SLASH,       /* / */
    TOKEN_PERCENT,     /* % */
    TOKEN_EQ,          /* = */
    TOKEN_EQ_EQ,       /* == */
    TOKEN_NEQ,         /* != */
    TOKEN_LT,          /* < */
    TOKEN_GT,          /* > */
    TOKEN_LE,          /* <= */
    TOKEN_GE,          /* >= */
    TOKEN_AND_AND,     /* && */
    TOKEN_OR_OR,       /* || */
    TOKEN_BANG,        /* ! (operator) */
    TOKEN_AMP,         /* & */
    TOKEN_PIPE,        /* | */
    TOKEN_CARET,       /* ^ */
    TOKEN_TILDE,       /* ~ */
    TOKEN_SHL,         /* << */
    TOKEN_SHR,         /* >> */
    TOKEN_ARROW,       /* -> */
    TOKEN_FAT_ARROW,   /* => */
    TOKEN_DOT,         /* . */
    TOKEN_COMMA,       /* , */
    TOKEN_SEMICOLON,   /* ; */
    TOKEN_COLON,       /* : */
    TOKEN_COLON_COLON, /* :: */
    TOKEN_LPAREN,      /* ( */
    TOKEN_RPAREN,      /* ) */
    TOKEN_LBRACKET,    /* [ */
    TOKEN_RBRACKET,    /* ] */
    TOKEN_DOTDOT,      /* ..  (exclusive range) */
    TOKEN_DOTDOT_EQ,   /* ..= (inclusive range) */
    TOKEN_LBRACE,      /* { */
    TOKEN_RBRACE,      /* } */
    TOKEN_QUESTION,    /* ? */
    TOKEN_UNDERSCORE,  /* _ */

    /* Special */
    TOKEN_NEWLINE,
    TOKEN_EOF,
    TOKEN_ERROR,
} TokenKind;

typedef struct {
    TokenKind      kind;
    InternedString text;
    SrcLoc         loc;
    union {
        int64_t   int_val;
        double    float_val;
        /* string_val is stored in text */
    } literal;
} Token;

/* -----------------------------------------------------------
 * §6: Lexer API
 * ----------------------------------------------------------- */

typedef struct Lexer Lexer;

Lexer  *lexer_create(const char *filename, const char *source, size_t source_len,
                     StringTable *strings, Arena *arena);
Token   lexer_next(Lexer *l);
Token   lexer_peek(Lexer *l);
void    lexer_destroy(Lexer *l);

/* Token a keyword lexes to, or TOKEN_IDENT when `text` is not a keyword.
 * Used by the construct registry self-check (src/constructs/construct.c). */
TokenKind lexer_keyword_token(const char *text, size_t len);

/* -----------------------------------------------------------
 * §7: AST Node Types
 * ----------------------------------------------------------- */

typedef enum {
    /* Expressions */
    NODE_INT_LIT,
    NODE_FLOAT_LIT,
    NODE_STRING_LIT,
    NODE_BOOL_LIT,
    NODE_NULL_LIT,
    NODE_IDENT,
    NODE_BINARY_OP,
    NODE_UNARY_OP,
    NODE_CALL,
    NODE_INDEX,
    NODE_ARRAY_LIT,
    NODE_RANGE,
    NODE_STRUCT_LIT,
    NODE_FIELD_ACCESS,
    NODE_SOME_EXPR,   /* some(value) — Option constructor */
    NODE_NONE_EXPR,   /* none — None literal */
    NODE_OK_EXPR,     /* ok(value) — Result::Ok constructor */
    NODE_ERR_EXPR,    /* err(value) — Result::Err constructor */
    NODE_TRY_EXPR,    /* expr? — try-propagation operator */

    /* Enum variant payload declaration (only inside NODE_ENUM_DECL) */
    NODE_PAYLOAD,

    /* Patterns (only valid inside a match arm) */
    NODE_PATTERN_WILDCARD,
    NODE_PATTERN_BIND,   /* binding pattern: captures matched value */
    NODE_PATTERN_VARIANT_BIND, /* Enum.Variant(bind1, bind2, ...) */
    NODE_PATTERN_OR,
    NODE_OPTIONAL_CHAIN,
    NODE_BLOCK,
    NODE_IF,
    NODE_WHILE,
    NODE_FOR,
    NODE_MATCH,
    NODE_RETURN,
    NODE_BREAK,
    NODE_CONTINUE,
    NODE_ASSIGN,
    NODE_COMPOUND_ASSIGN,

    /* Declarations */
    NODE_FN_DECL,
    NODE_STRUCT_DECL,
    NODE_ENUM_DECL,
    NODE_CONST_DECL,
    NODE_VAR_DECL,

    /* Types */
    NODE_TYPE_IDENT,
    NODE_TYPE_OPTIONAL,
    NODE_TYPE_ARRAY,
    NODE_TYPE_FN,

    /* Top-level */
    NODE_MODULE,
    NODE_USE,
    NODE_IMPL,
} NodeKind;

/* Forward declaration */
typedef struct Node Node;

/* -----------------------------------------------------------
 * §8: AST Nodes
 * ----------------------------------------------------------- */

/* Expression nodes */
typedef struct {
    int64_t value;
} IntLitExpr;

typedef struct {
    double value;
} FloatLitExpr;

typedef struct {
    InternedString value;
} StringLitExpr;

typedef struct {
    bool value;
} BoolLitExpr;

typedef struct {
    InternedString name;
} IdentExpr;

typedef enum {
    OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD,
    OP_EQ, OP_NEQ, OP_LT, OP_GT, OP_LE, OP_GE,
    OP_AND, OP_OR,
    OP_BIT_AND, OP_BIT_OR, OP_BIT_XOR,
    OP_SHL, OP_SHR,
} BinaryOp;

typedef struct {
    BinaryOp op;
    Node    *left;
    Node    *right;
} BinaryExpr;

typedef enum {
    UNOP_NEG, UNOP_NOT, UNOP_BIT_NOT, UNOP_REF, UNOP_DEREF,
} UnaryOp;

typedef struct {
    UnaryOp op;
    Node   *operand;
} UnaryExpr;typedef struct {
    Node *callee;
    DYNARRAY(Node *) args;
} CallExpr;

/* Construction of a data-carrying enum variant: `Paso(x)` / `PasoDoble(x: 1, y: 2)`.
 * Construction syntax is CallExpr with an Ident callee when the name resolves
 * to a variant; the checker resolves it and the emitter lowers it. */

typedef struct {
    Node   *object;
    Node   *index;
} IndexExpr;

typedef struct {
    DYNARRAY(Node *) elems;
} ArrayLitExpr;

typedef struct {
    Node *start;     /* may be NULL for open-start ranges (future) */
    Node *end;       /* may be NULL for open-end ranges (future) */
    bool  inclusive; /* true for `..=`, false for `..` */
} RangeExpr;

typedef struct {
    InternedString       name; /* struct name */
    DYNARRAY(InternedString) field_names;
    DYNARRAY(Node *)     field_values;
} StructLitExpr;
/* Or-pattern: `A | B | C`. Each alternative is itself a pattern node. */
typedef struct {
    DYNARRAY(Node *) alts;
} PatternOrExpr;

typedef struct {
    InternedString name;  /* variable name to bind */
} PatternBindExpr;

typedef struct {
    Node   *variant; /* NODE_FIELD_ACCESS for Enum.Variant */
    DYNARRAY(InternedString) bindings; /* binding names for each payload field */
} PatternVariantBindExpr;

typedef struct {
    Node   *object;
    InternedString field;
} FieldAccessExpr;

typedef struct {
    Node *value;
} SomeExpr;

typedef struct {
    Node *value;
} OkExpr;

typedef struct {
    Node *value;
} ErrExpr;

typedef struct {
    DYNARRAY(Node *) stmts;
    Node *last_expr; /* may be NULL */
} BlockExpr;

typedef struct {
    Node *cond;
    Node *then_block;
    Node *else_block; /* may be NULL (if-let, or if without else) */
} IfExpr;

typedef struct {
    Node *cond;
    Node *body;
} WhileExpr;

typedef struct {
    InternedString var;
    Node          *iter;
    Node          *body;
} ForExpr;

typedef struct {
    Node *pattern;
    Node *guard;    /* optional guard expression (NULL if no guard) */
    Node *body;
} MatchArm;

typedef struct {
    Node *target; /* expression to match */
    DYNARRAY(MatchArm) arms;
} MatchExpr;

typedef struct {
    Node *value; /* may be NULL for bare return */
} ReturnExpr;

typedef struct {
    /* The assignment target. `Assignment ::= LValue "=" Assignment`
     * (research/010 §12.1) where
     * `LValue ::= Identifier | LValue "." Identifier | LValue "[" Expression "]"`.
     * The report names LValue but never defines it; see constructs/assign.c,
     * which owns the Assignment production. */
    Node          *target;  /* NODE_IDENT | NODE_FIELD_ACCESS | NODE_INDEX */
    InternedString name;    /* mirror of target->as.ident.name when target is an ident */
    Node          *value;
    BinaryOp       op;  /* used by NODE_COMPOUND_ASSIGN */
} AssignExpr;

/* Declaration nodes */
typedef struct {
    InternedString        name;
    DYNARRAY(InternedString) params; /* param names */
    DYNARRAY(Node *)      param_types;
    Node                 *return_type; /* may be NULL */
    Node                 *body;        /* BlockExpr */
} FnDecl;

typedef struct {
    InternedString        name;
    DYNARRAY(InternedString) field_names;
    DYNARRAY(Node *)      field_types;
} StructDecl;

typedef struct {
    InternedString        name;
    DYNARRAY(InternedString) variants;       /* unit variant names */
    DYNARRAY(Node *)      variant_payloads;  /* NODE_PAYLOAD, parallel to variants */
} EnumDecl;

/* Payload of a data-carrying enum variant:
 * `enum Mover { Paso(i32) PasoDoble(x: i32, y: i32) }`.
 * Unnamed fields (`Paso(i32)`) keep name == NULL. Cites research/04 §9.2;
 * owned by constructs/enum_variant.c. */
typedef struct {
    InternedString name;                     /* may be NULL for unnamed fields */
    Node          *type;                     /* NODE_TYPE_* */
} PayloadField;

typedef struct {
    DYNARRAY(PayloadField) fields;
} PayloadExpr;

typedef struct {
    InternedString name;
    Node          *type;
    Node          *value; /* may be NULL */
} ConstDecl;

typedef struct {
    InternedString name;
    Node          *type;
    Node          *value; /* may be NULL */
    bool           is_mut;
} VarDecl;

/* Type nodes */
typedef struct {
    InternedString name;
} TypeIdent;

typedef struct {
    Node *inner;
} TypeOptional;

typedef struct {
    Node *elem_type;
    Node *size; /* may be NULL for dynamic arrays */
} TypeArray;

typedef struct {
    DYNARRAY(Node *) param_types;
    Node            *return_type;
} TypeFn;

/* Module */
typedef struct {
    DYNARRAY(Node *) items;
} ModuleNode;

/* -----------------------------------------------------------
 * §9: AST Node (union)
 * ----------------------------------------------------------- */

struct Node {
    NodeKind kind;
    SrcLoc   loc;
    union {
        IntLitExpr      int_lit;
        FloatLitExpr    float_lit;
        StringLitExpr   string_lit;
        BoolLitExpr     bool_lit;
        IdentExpr       ident;
        BinaryExpr      binary;
        UnaryExpr       unary;
        CallExpr        call;
        IndexExpr       index;
        ArrayLitExpr    array_lit;
        RangeExpr       range;
        StructLitExpr   struct_lit;
        PayloadExpr     payload;
        FieldAccessExpr field_access;
        SomeExpr        some_expr;
        OkExpr          ok_expr;
        ErrExpr         err_expr;
        struct { Node *inner; } try_expr;
        PatternOrExpr   pattern_or;
        PatternBindExpr pattern_bind;
        PatternVariantBindExpr pattern_variant_bind;
        BlockExpr       block;
        IfExpr          if_expr;
        WhileExpr       while_expr;
        ForExpr         for_expr;
        MatchExpr       match_expr;
        ReturnExpr      return_expr;
        AssignExpr      assign;
        FnDecl          fn_decl;
        StructDecl      struct_decl;
        EnumDecl        enum_decl;
        ConstDecl       const_decl;
        VarDecl         var_decl;
        TypeIdent       type_ident;
        TypeOptional    type_optional;
        TypeArray       type_array;
        TypeFn          type_fn;
        ModuleNode      module;
    } as;
};

Node *node_new(Arena *a, NodeKind kind, SrcLoc loc);

/* -----------------------------------------------------------
 * §10: Parser API
 * ----------------------------------------------------------- */

typedef struct Parser Parser;

Parser *parser_create(Lexer *lexer, Arena *arena, StringTable *strings);
Node   *parser_parse_module(Parser *p);
void    parser_destroy(Parser *p);

/* True if any syntax error was reported (0 = clean parse) */
bool    parser_had_error(Parser *p);

/* -----------------------------------------------------------
 * §11: Type System
 * ----------------------------------------------------------- */

typedef enum {
    TYPE_VOID,
    TYPE_BOOL,
    TYPE_INT,
    TYPE_FLOAT,
    TYPE_STRING,
    TYPE_OPTIONAL,
    TYPE_ARRAY,
    TYPE_FN,
    TYPE_STRUCT,
    TYPE_ENUM,
    TYPE_NIL,       /* nil literal type — unifies with any optional */
    TYPE_UNKNOWN,
    TYPE_ERROR,
} TypeKind;

typedef struct Type Type;

/* Compile-time payload layout of one data-carrying enum variant, parallel to
 * the variant list in `Type::enumeration`. Unnamed fields keep name NULL.
 * Cites research/04 §6.2/§9.2; owned by the checker's enum declaration pass. */
typedef struct {
    InternedString *names;   /* may be NULL when all fields are unnamed */
    Type          **types;
    size_t          field_count;
} VariantLayout;
typedef struct {
    InternedString name;
    Type          *type;
} StructField;

struct Type {
    TypeKind kind;
    union {
        struct { Type *inner; } optional;
        struct { Type *elem; Node *size; } array;
        struct { Type **params; size_t param_count; Type *ret; } fn;
        struct {
            InternedString  name;
            InternedString *variants;
            /* Payload layouts, parallel to `variants`. NULL when the enum has
             * no data-carrying variant; unit variants carry field_count == 0. */
            VariantLayout  *payloads;
            size_t          variant_count;
        } enumeration;
        struct {
            InternedString  name;
            StructField    *fields;
            size_t          field_count;
        } struc;
    } as;
};

Type *type_new(Arena *a, TypeKind kind);
bool  type_eq(Type *a, Type *b);
void  type_print(Type *t);

/* -----------------------------------------------------------
 * §12: Symbol Table
 * ----------------------------------------------------------- */

typedef struct Symbol Symbol;

struct Symbol {
    InternedString name;
    Type          *type;
    bool           is_mut;
    bool           is_fn;
    SrcLoc         def_loc;
    uint32_t       seq;  /* monotonic insertion order (for scoped removal) */
    Symbol        *next; /* for hash chain */
};

typedef struct SymbolTable SymbolTable;

SymbolTable *symbol_table_create(Arena *a, size_t size);
void         symbol_table_insert(SymbolTable *st, Symbol sym);
Symbol      *symbol_table_lookup(SymbolTable *st, InternedString name);
void         symbol_table_push_scope(SymbolTable *st);
void         symbol_table_pop_scope(SymbolTable *st);

/* -----------------------------------------------------------
 * §13: Type Checker API
 * ----------------------------------------------------------- */

typedef struct TypeChecker TypeChecker;

TypeChecker *typechecker_create(Arena *arena, StringTable *strings);
Type        *typecheck(TypeChecker *tc, Node *node);
void         typechecker_destroy(TypeChecker *tc);

/* Number of type errors recorded (0 = success) */
int          typechecker_error_count(TypeChecker *tc);

/* -----------------------------------------------------------
 * §14: Bytecode
 * ----------------------------------------------------------- */

typedef enum {
    /* Stack operations */
    OPCODE_CONST,         /* push constant */
    OPCODE_POP,           /* pop top */
    OPCODE_DUP,           /* duplicate top */
    OPCODE_SWAP,          /* swap top two values */

    /* Local variables */
    OPCODE_GET_LOCAL,     /* get local variable */
    OPCODE_SET_LOCAL,     /* set local variable */

    /* Global variables */
    OPCODE_GET_GLOBAL,
    OPCODE_SET_GLOBAL,

    /* Arithmetic */
    OPCODE_ADD,
    OPCODE_SUB,
    OPCODE_MUL,
    OPCODE_DIV,
    OPCODE_MOD,
    OPCODE_NEG,

    /* Comparison */
    OPCODE_EQ,
    OPCODE_NEQ,
    OPCODE_LT,
    OPCODE_GT,
    OPCODE_LE,
    OPCODE_GE,

    /* Logical */
    OPCODE_AND,
    OPCODE_OR,
    OPCODE_NOT,

    /* Control flow */
    OPCODE_JUMP,          /* unconditional jump */
    OPCODE_JUMP_IF_FALSE, /* conditional jump */
    OPCODE_JUMP_IF_TRUE,

    /* Aggregates */
    OPCODE_NEW_ARRAY,     /* pop N values, push array */
    OPCODE_INDEX,         /* pop index, array; push element */
    OPCODE_LEN,           /* pop array; push length */
    OPCODE_NEW_STRUCT,    /* pop layout + N field values, push struct */
    OPCODE_GET_FIELD,     /* pop field name, struct; push field value */
    OPCODE_SET_INDEX,     /* pop value, index, array; store, push value */
    OPCODE_SET_FIELD,     /* operand: field-name constant; pop value, struct; store, push value */
    OPCODE_NEW_ENUM,      /* operand: (variant << 16) | count; pop N payload values, push enum */
    OPCODE_GET_ENUM_FIELD, /* operand: field index; pop enum data value, push field value */

    /* Functions */
    OPCODE_CALL,          /* call function */
    OPCODE_RET,           /* return from function */

    /* I/O */
    OPCODE_PRINT,         /* print value */

    /* Option/Result wrapping */
    OPCODE_WRAP_OK,       /* pop inner, push ok(inner) */
    OPCODE_WRAP_ERR,      /* pop inner, push err(inner) */
    OPCODE_WRAP_SOME,     /* pop inner, push some(inner) */

    /* Special */
    OPCODE_HALT,          /* stop execution */
    OPCODE_TRY_UNWRAP,    /* expr? — unwrap Result/Option or early return */
} OpCode;

typedef struct {
    OpCode  op;
    uint32_t line;
    union {
        uint32_t index;    /* constant/local index */
        int32_t  offset;   /* jump offset */
        uint8_t  arg_count; /* call argument count */
    } arg;
} Instruction;

/* Forward declarations for §15/§16 */
typedef struct Value Value;

/* -----------------------------------------------------------
 * §15: Bytecode Emitter API
 * ----------------------------------------------------------- */

typedef struct Emitter Emitter;

Emitter *emitter_create(Arena *arena, StringTable *strings);
void     emitter_emit(Emitter *e, Node *module);
void     emitter_destroy(Emitter *e);

/* Access emitted bytecode */
const Instruction *emitter_get_code(Emitter *e, size_t *out_len);
const Value       *emitter_get_constants(Emitter *e, size_t *out_len);

/* Number of code-generation errors recorded (0 = success) */
int emitter_error_count(Emitter *e);

/* -----------------------------------------------------------
 * §16: Value (VM runtime)
 * ----------------------------------------------------------- */

typedef enum {
    VAL_NIL,
    VAL_BOOL,
    VAL_INT,
    VAL_FLOAT,
    VAL_STRING,
    VAL_ARRAY,
    VAL_STRUCT,
    VAL_STRUCT_DEF,
    VAL_ENUM,      /* unit variant: enum_val (name pair, no payload) */
    VAL_ENUM_DATA, /* data-carrying variant: enum_obj (tag + payload fields) */
    VAL_ENUM_DEF,
    VAL_FN,
    VAL_OK,      /* Result::Ok(value) */
    VAL_ERR,     /* Result::Err(value) */
    VAL_SOME,    /* Option::Some(value) */
} ValueKind;

typedef struct Value Value;
typedef struct VM VM;

/* Array object (heap-managed by the VM arena) */
typedef struct {
    Value *elems;
    size_t len;
} ArrayObj;

/* Compile-time struct layout. Strings are interned, so the pointers are
 * stable for the whole compilation and can be shared with the VM. */
typedef struct {
    const char  *name;
    const char **field_names;
    size_t       field_count;
} StructDef;

/* Compile-time layout of one enum variant's payload. Strings are interned.
 * Unnamed fields keep name == NULL; position in the array is their identity. */
typedef struct {
    const char  *name;        /* may be NULL */
    const char **field_names; /* parallel to field_count when named */
    size_t       field_count;
} VariantDef;

/* Compile-time enum layout: the tag is the index into variants. */
typedef struct {
    const char  *name;
    VariantDef  *variants;
    size_t       variant_count;
} EnumDef;

/* Runtime enum value: a variant tag plus its payload fields, stored flat. */
typedef struct {
    const EnumDef *def;
    size_t         variant;
    Value         *fields;
} EnumObj;

/* Runtime struct instance: a layout plus its field values. */
typedef struct {
    const StructDef *def;
    Value           *fields;
} StructObj;

/* Function object */
typedef struct {
    const Instruction *code;
    size_t             code_len;
    Value             *constants;
    size_t             const_len;
    uint8_t            param_count;
    uint8_t            local_count;
} FnObj;

struct Value {
    ValueKind kind;
    union {
        bool        bool_val;
        int64_t     int_val;
        double      float_val;
        const char *string_val; /* interned */
        ArrayObj   *array_val;
        StructObj  *struct_val;
        StructDef  *struct_def;
        struct { const char *enum_name; const char *variant_name; } enum_val;
        EnumObj     *enum_obj;
        EnumDef     *enum_def;
        FnObj      *fn_val;
        struct { Value *inner; } ok_val;    /* only valid for VAL_OK */
        struct { Value *inner; } err_val;   /* only valid for VAL_ERR */
        struct { Value *inner; } some_val;  /* only valid for VAL_SOME */
    } as;
};

Value value_nil(void);
Value value_bool(bool v);
Value value_int(int64_t v);
Value value_float(double v);
Value value_string(const char *s);
Value value_array(ArrayObj *a);
Value value_struct(StructObj *s);
Value value_struct_def(StructDef *d);
Value value_enum(const char *enum_name, const char *variant_name);

/* A data-carrying enum value: `def` carries the layout, `variant` is the tag
 * (index into def->variants) and `fields` holds the payload values in order. */
Value value_enum_with_payload(EnumObj *obj);

/* Compile-time constant: an enum layout the emitter packs once per
 * construction site; the VM clones it when materialising an EnumObj. */
Value value_enum_def(EnumDef *d);
Value value_fn(FnObj *f);
Value value_ok(Arena *a, Value inner);
Value value_err(Arena *a, Value inner);
Value value_some(Arena *a, Value inner);

/* Allocate an array object in the given arena (len may be 0) */
ArrayObj *array_obj_new(Arena *a, size_t len);

/* Allocate a struct instance for the given layout */
StructObj *struct_obj_new(Arena *a, const StructDef *def);
void  value_print(Value v);
bool  value_is_truthy(Value v);

/* -----------------------------------------------------------
 * §17: Virtual Machine API
 * ----------------------------------------------------------- */

typedef enum {
    VM_OK,
    VM_RUNTIME_ERROR,
} VMResult;

VM      *vm_create(Arena *arena);
VMResult vm_run(VM *vm, const Instruction *code, size_t code_len,
                Value *constants, size_t const_len);
VMResult vm_exec(VM *vm);
void     vm_destroy(VM *vm);

/* -----------------------------------------------------------
 * §18: Compiler Driver
 * ----------------------------------------------------------- */

typedef struct {
    Arena        *arena;
    StringTable  *strings;
    Lexer        *lexer;
    Parser       *parser;
    TypeChecker  *checker;
    Emitter      *emitter;
    VM           *vm;
} Compiler;

Compiler *compiler_create(const char *filename, const char *source, size_t source_len);
VMResult  compiler_run(Compiler *c);
void      compiler_destroy(Compiler *c);

#endif /* ASTRA_H */
