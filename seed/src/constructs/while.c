/* while — WhileExpr
 * ============================================================
 * `WhileExpr ::= "while" Expression Block`
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "block", "break", "continue", NULL };

const ConstructSpec construct_while = {
    .name       = "while",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "while",
    .token      = TOKEN_WHILE,
    .node_kind  = NODE_WHILE,
    .position   = CONSTRUCT_STMT | CONSTRUCT_EXPR,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "WhileExpr ::= \"while\" Expression Block",
    .research   = "research/010 §3.3 (grammar fragment), §12.1",
    .note       = "Gives `break` and `continue` a target, so it declares them as "
                  "dependencies: they are meaningless outside a loop. "
                  "`while let` (research/04 §9.5) will attach here later.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
