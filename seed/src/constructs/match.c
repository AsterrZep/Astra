/* match — MatchExpr
 * ============================================================
 * `MatchExpr ::= "match" Expression "{" MatchArm+ "}"`
 *
 * Arms are a construct of their own (match_arm.c), so guards,
 * bindings and arm-level lowering (jump table vs. test chain —
 * research/04 §7.1-7.3) can change without touching the match
 * header.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "match_arm", NULL };

const ConstructSpec construct_match = {
    .name       = "match",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "match",
    .token      = TOKEN_MATCH,
    .node_kind  = NODE_MATCH,
    .position   = CONSTRUCT_STMT | CONSTRUCT_EXPR,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "MatchExpr ::= \"match\" Expression \"{\" MatchArm+ \"}\"",
    .research   = "research/04 §7 (compilation strategies), §9.4 (pattern matching), "
                  "§9.7 (exhaustiveness); research/010 §5.2-5.3",
    .note       = "The scrutinee is evaluated exactly once into a hidden local. "
                  "Exhaustiveness is checked over unit enums; a wildcard arm "
                  "discharges the check (research/04 §9.7).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
