/* match_arm — MatchArm
 * ============================================================
 * `MatchArm ::= Pattern ("if" Expression)? "=>" (Expression | Block) ","?`
 *
 * Guards are now supported: the parser stores the guard expression
 * in MatchArm.guard (NULL if absent), the typechecker verifies it
 * is bool, and the emitter emits a JUMP_IF_FALSE past the arm body.
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
    .note      = "Arms are stored as (pattern, guard, body) triples on NODE_MATCH, "
                  "so this production owns no node. The guard is an optional expression "
                  "node (NULL when absent). The trailing comma is optional.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
