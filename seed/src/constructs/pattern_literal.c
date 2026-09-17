/* pattern_literal — LiteralPattern
 * ============================================================
 * `LiteralPattern ::= Literal | "-" Literal`
 *
 * Node-less: a literal pattern reuses the literal node kinds
 * owned by the `literal` construct (NODE_INT_LIT, NODE_STRING_LIT,
 * ...). The registry refuses to let two constructs own the same
 * node kind, so this file records the reuse instead of claiming
 * them again.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "literal", NULL };

const ConstructSpec construct_pattern_literal = {
    .name      = "pattern_literal",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_INT_LIT,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_PATTERN,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "LiteralPattern ::= Literal | \"-\" Literal",
    .research  = "research/010 §5.3 (Pattern grammar), §12.1; research/04 §9.4 (patterns)",
    .note      = "Reuses the literal node kinds; no node of its own. Negative literal "
                  "patterns (`-1 => ...`) parse through the unary-minus path. Range "
                  "patterns (`RangePattern ::= ... \"..\" ...`, research/04 §9.4) are "
                  "NOT implemented.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
