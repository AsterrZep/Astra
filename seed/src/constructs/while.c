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
                  "`while let` (research/04 §9.5) will attach here later. "
                  "`position` records the *grammar* position — §12.1 lists WhileExpr "
                  "under Primary, so a while loop is an expression there. Only the "
                  "statement form is implemented: the Pratt nud table has entries for "
                  "`if` and `match` but not for `while`/`for`, so "
                  "`let x = while c { };` is a parse error. The value of a while "
                  "expression would be void anyway (research/010 §4.1).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
