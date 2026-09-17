/* return — ReturnStmt
 * ============================================================
 * `ReturnStmt ::= "return" Expression?`
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_return = {
    .name       = "return",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "return",
    .token      = TOKEN_RETURN,
    .node_kind  = NODE_RETURN,
    .position   = CONSTRUCT_STMT,
    .phases     = 0,
    .in_astra0  = true,
    .deps       = NULL,
    .grammar    = "ReturnStmt ::= \"return\" Expression?",
    .research   = "research/010 §12.1 (statements)",
    .note       = "`return` with no value is a distinct shape from `return expr`, so "
                  "the emitter must not leave a value on the stack for the bare form.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
