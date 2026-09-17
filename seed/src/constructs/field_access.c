/* field_access — the postfix `.` form
 * ============================================================
 * `"." Identifier` applied to a value: struct field reads and
 * `Enum.Variant` paths, which share the syntax.
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_field_access = {
    .name      = "field_access",
    .role      = CONSTRUCT_LEAD,
    .keyword   = NULL,
    .token     = TOKEN_DOT,
    .node_kind = NODE_FIELD_ACCESS,
    .position  = CONSTRUCT_EXPR,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "Postfix ::= Primary ... \".\" Identifier",
    .research  = "research/010 §12.1 (postfix operators); research/04 §9.2 (Enum.Variant paths)",
    .note      = "One syntax, two meanings, decided by the type checker: if the base "
                  "expression is a struct the name must be a field, if it is an enum "
                  "type name the name must be a variant (see variant_path.c). "
                  "`?`-chaining on a field access is not implemented.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
