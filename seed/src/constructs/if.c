/* if — IfExpr
 * ============================================================
 * `IfExpr ::= "if" Expression Block ("else" (IfExpr | Block))?`
 *
 * The `else` arm is a construct of its own (else.c): per the
 * granularity policy in construct.h a construct is one EBNF
 * production, and this production mixes two. Keeping them apart is
 * what lets the emitter give `else` its own jump-patching strategy
 * (and, later, `if let` / `while let` bind to it without touching
 * `if` at all — research/04 §9.5).
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "else", "block", NULL };

const ConstructSpec construct_if = {
    .name       = "if",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "if",
    .token      = TOKEN_IF,
    .node_kind  = NODE_IF,
    .position   = CONSTRUCT_STMT | CONSTRUCT_EXPR,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "IfExpr ::= \"if\" Expression Block (\"else\" (IfExpr | Block))?",
    .research   = "research/010 §3.2 (expression-oriented), §4 (block expressions), §12.1",
    .note       = "Both a statement and an expression. The condition is parsed with "
                  "no_struct_lit set so `if x {` is not read as a struct literal. "
                  "`if let` (research/04 §9.5) will attach to the `else` construct.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
