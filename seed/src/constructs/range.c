/* range — range expressions (an Astra extension)
 * ============================================================
 * `a..b` (exclusive) and `a..=b` (inclusive).
 *
 * §12.1 has no range production in the expression chain: `..` only
 * appears in RangePattern and in the slice form `[a..b]`. The seed
 * needed iterable ranges for `for i in 0..n`, so it added them as
 * expressions with binding power 2 (tighter than assignment,
 * looser than every logical operator). See range in §12.2: absent.
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_range = {
    .name      = "range",
    .role      = CONSTRUCT_LEAD,
    .keyword   = NULL,
    .token     = TOKEN_DOTDOT,
    .node_kind = NODE_RANGE,
    .position  = CONSTRUCT_EXPR,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "a \"..\" b | a \"..=\" b        (Astra extension; §12.1 has ranges only "
                 "in RangePattern and slices)",
    .research  = "research/010 §12.1 (Postfix slice form), §12.2 (no range row); "
                 "research/04 §9.4 (range patterns)",
    .note      = "Non-associative and only meaningful as a `for` iterable in Astra-0; "
                 "the type checker rejects a range that is used as a value. Range "
                 "patterns (research/04 §9.4) are not implemented.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
