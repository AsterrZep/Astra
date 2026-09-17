/* binding — Declaration
 * ============================================================
 * `Declaration ::= ("val" | "mut" | "let") Pattern (":" Type)? "=" Expression`
 *
 * Covers `let`, `let mut` and `val`. The grammar also allows `mut`
 * as a bare introducer; the seed's lexer has TOKEN_VAR for that and
 * the parser routes all three through one production, which is why
 * NODE_VAR_DECL owns the lot.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "type_annotation", NULL };

const ConstructSpec construct_binding = {
    .name      = "binding",
    .role      = CONSTRUCT_LEAD,
    .keyword   = "let",
    .token     = TOKEN_LET,
    .node_kind = NODE_VAR_DECL,
    .position  = CONSTRUCT_STMT,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "Declaration ::= (\"val\" | \"mut\" | \"let\") Pattern (\":\" Type)? \"=\" Expression",
    .research  = "research/010 §3.1-3.2, §6.3 (type annotation), §12.1",
    .note       = "`val` and `mut` also lex as keywords (TOKEN_VAR, TOKEN_MUT); they "
                  "map onto this same production. Destructuring patterns (research/04 "
                  "§8.2, `let (a, b) = ...`) are specified but not part of Astra-0.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
