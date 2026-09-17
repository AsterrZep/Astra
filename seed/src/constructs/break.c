/* break — BreakStmt
 * ============================================================
 * `BreakStmt ::= "break" Expression?`
 *
 * The optional value is Rust's loop-result form; Astra-0 has no
 * `loop` construct to receive it yet, so the seed parses and emits
 * the bare form and records the gap here.
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_break = {
    .name       = "break",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "break",
    .token      = TOKEN_BREAK,
    .node_kind  = NODE_BREAK,
    .position   = CONSTRUCT_STMT,
    .phases     = 0,
    .in_astra0  = true,
    .deps       = NULL,
    .grammar    = "BreakStmt ::= \"break\" Expression?",
    .research   = "research/010 §12.1 (statements)",
    .note       = "Only valid inside a loop; the type checker rejects it elsewhere. "
                  "Jump targets are owned by the enclosing loop (while.c / for.c).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
