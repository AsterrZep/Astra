/* ============================================================
 * Operator table — research/010 §2.4 (pratt parsing / operator
 * registration) and §12.2 (the precedence table).
 *
 * This is the single source of truth for binding powers. The Pratt
 * parser in parser.c uses the same numeric scale, and
 * `astra-seed --check-constructs` fails if the two ever disagree.
 *
 * `doc_precedence` records the row research/010 §12.2 gives the
 * operator so the dump can show where the report and the
 * implementation differ. `note` explains each such difference.
 * ============================================================ */

#include "constructs/construct.h"

/* Binding-power scale, mirroring the Precedence enum in parser.c.
 * Higher binds tighter. */
#define BP_ASSIGN  1
#define BP_RANGE   2
#define BP_OR      3
#define BP_AND     4
#define BP_BIT_OR  5
#define BP_BIT_XOR 6
#define BP_BIT_AND 7
#define BP_EQ      8
#define BP_COMP    9
#define BP_SHIFT  10
#define BP_ADD    11
#define BP_MUL    12
#define BP_UNARY  13
#define BP_POSTFIX 14

#define NO_DOC 0

static const OperatorSpec astra_operators[] = {
    /* --- logic ------------------------------------------------- */
    { "||", TOKEN_OR_OR,     OPERATOR_BINARY, OPERATOR_LEFT, BP_OR,      1, OP_OR,      OPERATOR_NO_UN_OP, NULL },
    { "&&", TOKEN_AND_AND,   OPERATOR_BINARY, OPERATOR_LEFT, BP_AND,     2, OP_AND,     OPERATOR_NO_UN_OP, NULL },
    /* --- bitwise ----------------------------------------------- */
    { "|",  TOKEN_PIPE,      OPERATOR_BINARY, OPERATOR_LEFT, BP_BIT_OR,  3, OP_BIT_OR,  OPERATOR_NO_UN_OP, NULL },
    { "^",  TOKEN_CARET,     OPERATOR_BINARY, OPERATOR_LEFT, BP_BIT_XOR, 4, OP_BIT_XOR, OPERATOR_NO_UN_OP, NULL },
    { "&",  TOKEN_AMP,       OPERATOR_BINARY, OPERATOR_LEFT, BP_BIT_AND, 5, OP_BIT_AND, OPERATOR_NO_UN_OP, NULL },
    /* --- equality ----------------------------------------------
     * §12.2 groups == != < > <= >= on one row (6). The seed splits them
     * the way Rust and C do: equality binds looser than comparison, so
     * `a < b == c < d` reads as `(a < b) == (c < d)`. */
    { "==", TOKEN_EQ_EQ,     OPERATOR_BINARY, OPERATOR_LEFT, BP_EQ,      6, OP_EQ,      OPERATOR_NO_UN_OP, "split from the comparison row of §12.2" },
    { "!=", TOKEN_NEQ,       OPERATOR_BINARY, OPERATOR_LEFT, BP_EQ,      6, OP_NEQ,     OPERATOR_NO_UN_OP, "split from the comparison row of §12.2" },
    /* --- comparison ------------------------------------------- */
    { "<",  TOKEN_LT,        OPERATOR_BINARY, OPERATOR_LEFT, BP_COMP,    6, OP_LT,      OPERATOR_NO_UN_OP, NULL },
    { ">",  TOKEN_GT,        OPERATOR_BINARY, OPERATOR_LEFT, BP_COMP,    6, OP_GT,      OPERATOR_NO_UN_OP, NULL },
    { "<=", TOKEN_LE,        OPERATOR_BINARY, OPERATOR_LEFT, BP_COMP,    6, OP_LE,      OPERATOR_NO_UN_OP, NULL },
    { ">=", TOKEN_GE,        OPERATOR_BINARY, OPERATOR_LEFT, BP_COMP,    6, OP_GE,      OPERATOR_NO_UN_OP, NULL },
    /* --- shift ------------------------------------------------ */
    { "<<", TOKEN_SHL,       OPERATOR_BINARY, OPERATOR_LEFT, BP_SHIFT,   7, OP_SHL,     OPERATOR_NO_UN_OP, NULL },
    { ">>", TOKEN_SHR,       OPERATOR_BINARY, OPERATOR_LEFT, BP_SHIFT,   7, OP_SHR,     OPERATOR_NO_UN_OP, NULL },
    /* --- additive --------------------------------------------- */
    { "+",  TOKEN_PLUS,      OPERATOR_BINARY, OPERATOR_LEFT, BP_ADD,     8, OP_ADD,     OPERATOR_NO_UN_OP, NULL },
    { "-",  TOKEN_MINUS,     OPERATOR_BINARY, OPERATOR_LEFT, BP_ADD,     8, OP_SUB,     OPERATOR_NO_UN_OP, NULL },
    /* --- multiplicative --------------------------------------- */
    { "*",  TOKEN_STAR,      OPERATOR_BINARY, OPERATOR_LEFT, BP_MUL,     9, OP_MUL,     OPERATOR_NO_UN_OP, NULL },
    { "/",  TOKEN_SLASH,     OPERATOR_BINARY, OPERATOR_LEFT, BP_MUL,     9, OP_DIV,     OPERATOR_NO_UN_OP, NULL },
    { "%",  TOKEN_PERCENT,   OPERATOR_BINARY, OPERATOR_LEFT, BP_MUL,     9, OP_MOD,     OPERATOR_NO_UN_OP, NULL },
    /* --- range -------------------------------------------------
     * §12.2 has no row for expression ranges: §12.1 only uses `..` in
     * patterns and in slice syntax `[a..b]`. The seed lets `a..b` be an
     * expression so `for i in 0..n` reads naturally (see for.c). */
    { "..", TOKEN_DOTDOT,    OPERATOR_BINARY, OPERATOR_NONASSOC, BP_RANGE, NO_DOC, OPERATOR_NO_BIN_OP, OPERATOR_NO_UN_OP, "absent from the §12.2 table; see for.c" },
    { "..=", TOKEN_DOTDOT_EQ,OPERATOR_BINARY, OPERATOR_NONASSOC, BP_RANGE, NO_DOC, OPERATOR_NO_BIN_OP, OPERATOR_NO_UN_OP, "absent from the §12.2 table; see for.c" },
    /* --- prefix ------------------------------------------------
     * The prefix forms are not modelled in the Pratt table (they are
     * parsed by unary_op.c); they are listed so the binding power of
     * §12.2 row 11 is on record. */
    { "-",  TOKEN_MINUS,     OPERATOR_PREFIX,   OPERATOR_RIGHT, BP_UNARY, 11, OPERATOR_NO_BIN_OP, UNOP_NEG,     NULL },
    { "!",  TOKEN_BANG,      OPERATOR_PREFIX,   OPERATOR_RIGHT, BP_UNARY, 11, OPERATOR_NO_BIN_OP, UNOP_NOT,     NULL },
    { "~",  TOKEN_TILDE,     OPERATOR_PREFIX,   OPERATOR_RIGHT, BP_UNARY, 11, OPERATOR_NO_BIN_OP, UNOP_BIT_NOT, NULL },
    /* --- postfix ------------------------------------------------ */
    { ".",  TOKEN_DOT,       OPERATOR_POSTFIX,  OPERATOR_LEFT,  BP_POSTFIX, 12, OPERATOR_NO_BIN_OP, OPERATOR_NO_UN_OP, NULL },
    { "[",  TOKEN_LBRACKET,  OPERATOR_POSTFIX,  OPERATOR_LEFT,  BP_POSTFIX, 12, OPERATOR_NO_BIN_OP, OPERATOR_NO_UN_OP, NULL },
    { "(",  TOKEN_LPAREN,    OPERATOR_POSTFIX,  OPERATOR_LEFT,  BP_POSTFIX, 12, OPERATOR_NO_BIN_OP, OPERATOR_NO_UN_OP, NULL },
    { "?",  TOKEN_QUESTION,  OPERATOR_POSTFIX,  OPERATOR_LEFT,  0,          12, OPERATOR_NO_BIN_OP, OPERATOR_NO_UN_OP, "specified (§12.2 row 12) but not implemented: needs Option/Result, so there is no Pratt entry" },
};

/* Not implemented in Astra-0: `**` (specified as §12.2 row 10, right
 * associative). Recorded here so the gap is visible in the dump rather
 * than silently missing. */
static const OperatorSpec astra_pending_operators[] = {
    { "**", TOKEN_STAR,      OPERATOR_BINARY, OPERATOR_RIGHT, 0, 10, OPERATOR_NO_BIN_OP, OPERATOR_NO_UN_OP, "specified by §12.2 row 10, not implemented in Astra-0" },
};

/* ------------------------------------------------------------
 * Registry entry — the precedence table is configuration data, so it
 * is registered like every other construct. `binary_op` depends on it,
 * and the self-check proves the parser reads the same numbers.
 * ------------------------------------------------------------ */

const ConstructSpec construct_operator_table = {
    .name      = "operator_table",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_IDENT,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_EXPR,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "§12.2 precedence table: || && | ^ & == != < > <= >= << >> + - * / % "
                 ".. ..= (prefix) - ! ~ (postfix) . [ ( ?",
    .research  = "research/010 §2.2-2.4 (Pratt parsing and operator registration), §12.2",
    .note      = "Four documented deviations from §12.2: (1) assignment sits at the "
                 "loosest level per §12.1, not the tightest as §12.2 row 13 claims; "
                 "(2) ==/!= were split from < > <= >= so equality binds looser, as in "
                 "Rust and C; (3) `**` is specified (row 10) but not implemented; "
                 "(4) expression ranges have no §12.2 row at all — §12.1 only uses "
                 "`..` in patterns and slices.",
    .parse = NULL, .check = NULL, .emit = NULL,
};

const OperatorSpec *operator_table(size_t *out_count) {
    if (out_count) *out_count = sizeof(astra_operators) / sizeof(astra_operators[0]);
    return astra_operators;
}

/* Exposed for the dump so the unimplemented rows are visible too. */
const OperatorSpec *operator_pending_table(size_t *out_count) {
    if (out_count) *out_count = sizeof(astra_pending_operators) / sizeof(astra_pending_operators[0]);
    return astra_pending_operators;
}
