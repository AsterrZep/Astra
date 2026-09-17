/* pattern_or — OrPattern
 * ============================================================
 * `OrPattern ::= AndPattern ("|" AndPattern)*`
 *
 * `1 | 2 | 3 => ...`. Node-backed (NODE_PATTERN_OR), because an
 * or-pattern really is a list of alternatives rather than something
 * that maps onto an existing expression node.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = {
    "pattern_wildcard", "pattern_literal", "pattern_enum", NULL,
};

const ConstructSpec construct_pattern_or = {
    .name      = "pattern_or",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_PIPE,
    .node_kind = NODE_PATTERN_OR,
    .position  = CONSTRUCT_PATTERN,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "OrPattern ::= AndPattern (\"|\" AndPattern)*",
    .research  = "research/010 §5.3 (Pattern grammar); research/04 §9.4 (or-patterns)",
    .note      = "Alternatives are stored as sibling pattern nodes on NODE_PATTERN_OR. "
                  "The `&` conjunction form (AndPattern, research/04 §9.4) is not "
                  "implemented, and neither is `ref` (RefPattern). The checker requires "
                  "every alternative to match the target's type.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
