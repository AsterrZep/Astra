/* pattern_wildcard — WildcardPattern
 * ============================================================
 * `WildcardPattern ::= "_"`
 *
 * The catch-all arm. Per research/04 §9.7 a wildcard discharges
 * the exhaustiveness check, which the seed's checker implements;
 * the report also warns that library enums should be forced to
 * wildcards so new variants cannot silently break callers, which
 * needs a `#[non_exhaustive]` equivalent and is not done yet.
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_pattern_wildcard = {
    .name      = "pattern_wildcard",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_UNDERSCORE,
    .node_kind = NODE_PATTERN_WILDCARD,
    .position  = CONSTRUCT_PATTERN,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "WildcardPattern ::= \"_\"",
    .research  = "research/010 §5.3 (pattern grammar); research/04 §9.7 (exhaustiveness)",
    .note      = "Types as the match target's type and makes the arm a fallback, so "
                  "it also silences the exhaustiveness check.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
