/* index — the postfix index form
 * ============================================================
 * `"[" Expression ("" .. "" Expression)? "]"` applied to a sequence.
 *
 * Slice syntax (`xs[1..3]`) is specified in §12.1 and not
 * implemented in Astra-0; recorded here with the reason.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "range", NULL };

const ConstructSpec construct_index = {
    .name      = "index",
    .role      = CONSTRUCT_LEAD,
    .keyword   = NULL,
    .token     = TOKEN_LBRACKET,
    .node_kind = NODE_INDEX,
    .position  = CONSTRUCT_EXPR,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "Postfix ::= Primary ... \"[\" Expression (\"..\" Expression)? \"]\" ...",
    .research  = "research/010 §12.1 (postfix operators)",
    .note      = "Scalar indexing only. Slices `xs[a..b]` and `xs[a..=b]` are specified "
                  "but not implemented: they need a view type, and Astra-0 has no "
                  "borrowing model in the seed (research/011 §5.3). Out-of-bounds "
                  "indexing is a runtime error carrying the source line.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
