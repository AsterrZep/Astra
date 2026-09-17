/* else — the else arm of IfExpr
 * ============================================================
 * `"else" (IfExpr | Block)`
 *
 * Split out of IfExpr so the else arm has its own file, its own
 * grammar record and its own codegen. It is a SUB construct: `else`
 * is never a statement on its own, only reachable from `if`.
 *
 * Two shapes share this production: `else { ... }` and
 * `else if c { ... }`, which chains back into the `if` construct.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "if", "block", NULL };

const ConstructSpec construct_else = {
    .name      = "else",
    .role      = CONSTRUCT_SUB,
    .keyword   = "else",
    .token     = TOKEN_ELSE,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_STMT | CONSTRUCT_EXPR,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "\"else\" (IfExpr | Block)",
    .research  = "research/010 §3.2, §12.1",
    .note      = "Builds no node of its own: `else { }` is the else-branch Block and "
                 "`else if` is a nested NODE_IF. Owned by `if`.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
