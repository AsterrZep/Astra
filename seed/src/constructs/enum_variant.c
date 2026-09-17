/* enum_variant — EnumVariant
 * ============================================================
 * `EnumVariant      ::= Identifier ("(" EnumPayload ")")?`
 * `EnumPayload      ::= EnumPayloadField ("," EnumPayloadField)*`
 * `EnumPayloadField ::= Identifier ":" Type | Type`
 *
 * Split from EnumDef because it is a production of its own and
 * because it is the piece that grows: payloads, mixed named/unnamed
 * variants and recursive variants all land here
 * (research/04 §9.2, §9.9).
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "type_annotation", NULL };

const ConstructSpec construct_enum_variant = {
    .name      = "enum_variant",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_IDENT,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_ITEM,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "EnumVariant ::= Identifier (\"(\" EnumPayload \")\")?\n"
                 "EnumPayload ::= EnumPayloadField (\",\" EnumPayloadField)*\n"
                 "EnumPayloadField ::= Identifier \":\" Type | Type",
    .research  = "research/04 §9.2 (variants with and without data), §6.5-6.6 (tag encoding)",
    .note      = "Data-carrying variants are implemented: the payload form "
                  "`Paso(i32)` / `PasoDoble(x: i32, y: i32)` parses to NODE_PAYLOAD "
                  "(this file's node), the checker stores VariantLayout parallel to "
                  "the variants, and construction is positional through the shared "
                  "CallExpr grammar — a bare-identifier callee that resolves to a "
                  "variant packs NEW_ENUM instead of CALL. Pattern bindings over "
                  "payloads are research/04 §9.4 and still need pattern_ident.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
