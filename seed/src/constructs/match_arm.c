/* match_arm — MatchArm
 * ============================================================
 * `MatchArm ::= Pattern ("if" Expression)? "=>" (Expression | Block) ","?`
 *
 * The guard form is specified (research/04 §9.4) but not part of
 * Astra-0; the parser rejects it explicitly rather than silently
 * dropping the condition, and this file records the gap.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "pattern_or", "block", NULL };

const ConstructSpec construct_match_arm = {
    .name      = "match_arm",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_FAT_ARROW,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_EXPR,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "MatchArm ::= Pattern (\"if\" Expression)? \"=>\" (Expression | Block) \",\"?",
    .research  = "research/010 §5.2-5.3, §12.1; research/04 §9.4 (guards, or-patterns, nesting)",
    .note      = "Arms are stored as (pattern, body) pairs on NODE_MATCH, so this "
                  "production owns no node. Guards are NOT implemented: the parser "
                  "reports \"match guards are not supported in Astra-0\" instead of "
                  "accepting and ignoring them. The trailing comma is optional.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
