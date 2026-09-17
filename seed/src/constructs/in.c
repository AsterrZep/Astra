/* in — the `in` separator of ForExpr
 * ============================================================
 * `"in" Expression`
 *
 * A punctuation-level production with a keyword token, split from
 * ForExpr for the same reason `else` is split from `if`: it is a
 * distinct production and it changes independently (a future
 * `if x in y { }` membership form would reuse it — stdlib-design
 * report, iterators section).
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_in = {
    .name      = "in",
    .role      = CONSTRUCT_SUB,
    .keyword   = "in",
    .token     = TOKEN_IN,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_STMT,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "\"in\" Expression",
    .research  = "research/010 §12.1 (ForExpr), §5 (pattern grammar)",
    .note      = "Builds no node: the iterable expression is stored on NODE_FOR.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
