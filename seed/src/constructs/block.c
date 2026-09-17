/* block — Block
 * ============================================================
 * `Block ::= "{" Statement* Expression? "}"`
 *
 * Astra is expression-oriented (research/010 §3.2): a block's value
 * is its trailing expression, so a block is a real expression and
 * not just a statement container. Everything with a brace body
 * (`if`, `while`, `for`, `fn`, `match` arms) depends on this file.
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_block = {
    .name       = "block",
    .role       = CONSTRUCT_LEAD,
    .keyword    = NULL,
    .token      = TOKEN_LBRACE,
    .node_kind  = NODE_BLOCK,
    .position   = CONSTRUCT_STMT | CONSTRUCT_EXPR,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = NULL,
    .grammar    = "Block ::= \"{\" Statement* Expression? \"}\"",
    .research   = "research/010 §3.2 (expression-oriented), §4 (block expressions), §12.1",
    .note       = "Tail-expression semantics are Rust-style: the last expression, "
                  "without a trailing semicolon, is the block's value (research/010 §4.2).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
