/* variant_path — Enum.Variant
 * ============================================================
 * `EnumPattern ::= Path ("(" Pattern ("," Pattern)* ")")?` is how
 * §12.1 spells the *pattern* side; the expression side is just
 * `Path`, shared with field access.
 *
 * The seed lowers `Color.Rojo` to NODE_FIELD_ACCESS and lets the
 * type checker decide that the base is an enum type rather than a
 * value. That keeps the parser from needing to know which
 * identifiers name types, but it does mean there is no dedicated
 * node, which is why this construct owns no node kind.
 *
 * This is the file to change when enums gain payloads: the
 * `Enum.Variant(payload)` form needs a real node
 * (research/04 §9.3).
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "enum", "field_access", NULL };

const ConstructSpec construct_variant_path = {
    .name      = "variant_path",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_DOT,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_EXPR | CONSTRUCT_PATTERN,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "Path ::= Identifier (\".\" Identifier)*        (lowered to NODE_FIELD_ACCESS)",
    .research  = "research/04 §9.2 (enum declaration), §9.4 (patterns); research/010 §12.1",
    .note      = "Deliberately node-less: `Enum.Variant` is resolved by the type checker "
                  "out of NODE_FIELD_ACCESS. Payload variants (research/04 §9.3, "
                  "`Forma.Circulo(1.0)`) will need a dedicated node and will be the "
                  "point where this construct stops being transparent.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
