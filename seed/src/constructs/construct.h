#ifndef ASTRA_CONSTRUCT_H
#define ASTRA_CONSTRUCT_H

/* ============================================================
 * Astra Seed Compiler — Construct Registry
 * ============================================================
 * One file per grammar production, each owning everything there
 * is to know about that construct: its keyword, token, AST node,
 * grammar position, its dependencies on sub-constructs, the EBNF
 * production it implements and the research report that specifies
 * it — plus, as they are migrated, its parse / check / emit hooks.
 *
 * The registry is the single source of truth. Nothing about a
 * construct may live outside its own file; the self-check fails
 * the build if the registry and the rest of the compiler drift
 * apart (unknown deps, orphan sub-constructs, a keyword that the
 * lexer does not produce, a hook without its phase bit, ...).
 *
 * Granularity policy — a construct is *one EBNF production*.
 *   `IfExpr ::= "if" Expression Block ("else" (IfExpr | Block))?`
 * mixes two productions, so `if` and `else` are separate files.
 * The eleven binary-operator productions of research/010 §12.1 are
 * deliberately NOT split eleven ways: they are mechanically derived
 * from one precedence table, so the table is the single source of
 * truth (see binary_op.c and research/010 §2.4).
 *
 * Adding a construct:
 *   1. cp constructs/binary_op.c constructs/<name>.c and fill it in
 *   2. add the spec to registry.c
 *   3. `make && ./astra-seed --check-constructs` — fix what it reports
 *   4. if the construct has a keyword, add the token to lexer.c
 * ============================================================ */

#include "priv.h"

/* ------------------------------------------------------------
 * Spec vocabulary
 * ------------------------------------------------------------ */

/* A construct that is reachable on its own (a statement, an item or an
 * expression introducer) vs. one that only exists inside a parent:
 * `else` only ever follows an `if`, `in` only ever appears inside a
 * `for`, `match_arm` only inside a `match`. */
typedef enum {
    CONSTRUCT_LEAD = 0,
    CONSTRUCT_SUB,
} ConstructRole;

/* Where the construct is allowed to appear. A construct may occupy more
 * than one position (`if` is both a statement and an expression, per the
 * expression-oriented model of research/010 §3.2). */
typedef enum {
    CONSTRUCT_STMT    = 1u << 0,
    CONSTRUCT_EXPR    = 1u << 1,
    CONSTRUCT_ITEM    = 1u << 2,
    CONSTRUCT_PATTERN = 1u << 3,
    CONSTRUCT_TYPE    = 1u << 4,
} ConstructPosition;

/* Compiler phases. A bit is set only once the construct really owns that
 * phase's implementation; the hook pointer and the bit are cross-checked. */
typedef enum {
    CONSTRUCT_PARSE = 1u << 0,
    CONSTRUCT_CHECK = 1u << 1,
    CONSTRUCT_EMIT  = 1u << 2,
    CONSTRUCT_ALL_PHASES = CONSTRUCT_PARSE | CONSTRUCT_CHECK | CONSTRUCT_EMIT,
} ConstructPhase;

/* Constructs that build no AST node of their own (`else`, `in`, `=>`) */
#define CONSTRUCT_NO_NODE ((NodeKind)-1)

typedef struct ConstructSpec ConstructSpec;

/* The type checker's state is private to typechecker.c; construct modules
 * only ever pass the pointer through. */
struct TypeChecker;

typedef Node  *(*ConstructParseFn)(Parser *p, SrcLoc loc);
typedef Type  *(*ConstructCheckFn)(struct TypeChecker *tc, Node *node);
typedef void   (*ConstructEmitFn)(Emitter *em, Node *node);

struct ConstructSpec {
    const char        *name;      /* stable id; also the file stem          */
    ConstructRole      role;
    const char        *keyword;   /* NULL for punctuation-led constructs    */
    TokenKind          token;     /* keyword's token, else TOKEN_IDENT      */
    NodeKind           node_kind; /* CONSTRUCT_NO_NODE if it builds none    */
    /* Extra node kinds the same production can build, NULL-terminated.
     * One production may lower to more than one node: `Literal` builds
     * every literal kind, `Assignment` builds NODE_ASSIGN and
     * NODE_COMPOUND_ASSIGN. The registry still refuses two constructs
     * claiming the same node kind. */
    const NodeKind    *also_nodes;
    uint32_t           position;  /* ConstructPosition mask                 */
    uint32_t           phases;    /* ConstructPhase mask actually migrated  */
    bool               has_braces;/* production contains a `{ ... }` body   */
    bool               in_astra0; /* false: specified but out of seed scope */
    const char *const *deps;      /* NULL-terminated sub-construct names    */
    const char        *grammar;   /* the EBNF production (research/010)     */
    const char        *research;  /* where this construct is specified      */
    const char        *note;      /* decisions, deviations, known gaps      */
    ConstructParseFn   parse;
    ConstructCheckFn   check;
    ConstructEmitFn    emit;
};

/* ------------------------------------------------------------
 * Operator table (research/010 §2.4 + §12.2)
 * ------------------------------------------------------------ */

typedef enum {
    OPERATOR_BINARY = 0,
    OPERATOR_PREFIX,
    OPERATOR_POSTFIX,
} OperatorArity;

/* Sentinels for operators that do not produce a binary/unary AST operator
 * (ranges, postfix forms). The self-check skips those comparisons. */
#define OPERATOR_NO_BIN_OP ((BinaryOp)-1)
#define OPERATOR_NO_UN_OP  ((UnaryOp)-1)

typedef enum {
    OPERATOR_LEFT = 0,
    OPERATOR_RIGHT,
    OPERATOR_NONASSOC,
} OperatorAssoc;

typedef struct {
    const char   *spelling;
    TokenKind     token;
    OperatorArity arity;
    OperatorAssoc assoc;
    /* The Pratt binding power the parser actually uses. 0 means the parser
     * has no Pratt entry for the operator: either it is unimplemented, or
     * it is handled outside the Pratt led-loop (prefix forms live in
     * unary_op.c). The self-check compares this against the parser's own
     * table whenever it is non-zero and the operator is not a prefix. */
    uint8_t       binding_power;
    /* The row research/010 §12.2 assigns this operator, or 0 when the
     * specification has no entry for it. Kept only so the dump can show
     * where the report and the implementation disagree. */
    uint8_t       doc_precedence;
    BinaryOp      bin_op;      /* valid when arity == OPERATOR_BINARY */
    UnaryOp       un_op;       /* valid when arity != OPERATOR_BINARY */
    const char   *note;   /* non-NULL when doc and implementation differ */
} OperatorSpec;

const OperatorSpec *operator_table(size_t *out_count);

/* Rows research/010 §12.2 specifies that Astra-0 does not implement
 * (`**`). Kept out of the main table so the self-check never compares an
 * unimplemented operator against the parser. */
const OperatorSpec *operator_pending_table(size_t *out_count);

/* ------------------------------------------------------------
 * Provided by parser.c and lexer.c so the self-check can prove that
 * the tables in this registry and the real implementation agree.
 * ------------------------------------------------------------ */

uint8_t  parser_precedence_of(TokenKind kind);
BinaryOp parser_binary_op_of(TokenKind kind);
TokenKind lexer_keyword_token(const char *text, size_t len);

/* ------------------------------------------------------------
 * Registry queries
 * ------------------------------------------------------------ */

const ConstructSpec *construct_table(size_t *out_count);
const ConstructSpec *construct_lookup(const char *name);
const ConstructSpec *construct_by_token(TokenKind kind);
const ConstructSpec *construct_by_node(NodeKind kind);
const ConstructSpec *construct_by_keyword(const char *text, size_t len);

/* Constructs whose `phases` covers every phase the construct needs
 * (LEAD constructs need PARSE + CHECK + EMIT; SUB constructs inherit
 * their parent's phases). Used by --check-constructs as a progress
 * metric for the migration. */
size_t construct_fully_migrated_count(void);

/* ------------------------------------------------------------
 * Self-check and diagnostics
 * ------------------------------------------------------------ */

/* Validates the registry's invariants and writes a human-readable report
 * into `buf`. Returns the number of failures (0 = registry is consistent). */
int construct_self_check(char *buf, size_t cap);

/* Human-readable dump of every construct and its metadata. */
size_t construct_dump(char *buf, size_t cap);

/* Human-readable dump of the operator table. */
size_t operator_table_dump(char *buf, size_t cap);

#endif /* ASTRA_CONSTRUCT_H */
