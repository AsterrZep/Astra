/* pattern_enum — EnumPattern
 * ============================================================
 * `EnumPattern ::= Path ("(" Pattern ("," Pattern)* ")")?`
 *
 * Node-less in Astra-0: a unit variant pattern is a
 * `Path` parsed into NODE_FIELD_ACCESS and recognised by the type
 * checker. Payload patterns are where this stops being transparent
 * — they need bindings, which need the `pattern_ident` construct.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "variant_path", "pattern_ident", NULL };

const ConstructSpec construct_pattern_enum = {
    .name      = "pattern_enum",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_IDENT,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_PATTERN,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "EnumPattern ::= Path (\"(\" Pattern (\",\" Pattern)* \")\")?",
    .research  = "research/010 §5.3 (Pattern grammar); research/04 §9.4 (nested patterns), "
                  "§9.2 (variants with data)",
    .note      = "Unit variants only, lowered to NODE_FIELD_ACCESS + the enum type in the "
                  "checker. Payload patterns (`Color.Rgb(r, g, b) =>`), nested patterns "
                  "and `Bindings con @` (research/04 §9.4) are specified and not "
                  "implemented; they need pattern_ident to bind values first.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
