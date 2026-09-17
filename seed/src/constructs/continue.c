/* continue — ContinueStmt
 * ============================================================
 * `ContinueStmt ::= "continue"`
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_continue = {
    .name       = "continue",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "continue",
    .token      = TOKEN_CONTINUE,
    .node_kind  = NODE_CONTINUE,
    .position   = CONSTRUCT_STMT,
    .phases     = 0,
    .in_astra0  = true,
    .deps       = NULL,
    .grammar    = "ContinueStmt ::= \"continue\"",
    .research   = "research/010 §12.1 (statements)",
    .note       = "Jumps to the loop's update/test point, which differs between "
                  "`while` (re-test the condition) and `for` (advance the index).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
