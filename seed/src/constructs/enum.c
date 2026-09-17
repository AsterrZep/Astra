/* enum — EnumDef
 * ============================================================
 * `EnumDef      ::= "enum" Identifier GenericParams? WhereClause?
 *                     "{" EnumVariants? "}"`
 * `EnumVariants ::= EnumVariant ("," EnumVariant)* ","?`
 *
 * Sum types: research/04 §9.2. Astra-0 implements the unit form
 * (`enum Color { Rojo Verde }`); payload variants are specified and
 * not implemented, and the discriminator/tag layout questions in
 * research/04 §6 are deferred with them.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "enum_variant", "variant_path", NULL };

const ConstructSpec construct_enum = {
    .name       = "enum",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "enum",
    .token      = TOKEN_ENUM,
    .node_kind  = NODE_ENUM_DECL,
    .position   = CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "EnumDef ::= \"enum\" Identifier GenericParams? WhereClause? \"{\" EnumVariants? \"}\"\n"
                  "EnumVariants ::= EnumVariant (\",\" EnumVariant)* \",\"?",
    .research  = "research/04 §9.2 (enum declaration), §6 (memory and layout), §9.7 "
                  "(exhaustiveness); research/010 §12.1",
    .note      = "Unit variants only. A variant is a (enum name, variant index) pair; "
                  "the runtime value prints as `Enum.Variant` and compares structurally. "
                  "No layout is allocated yet, so the tag-width/niche questions of "
                  "research/04 §6.2-6.4 are still open. Empty enums (research/04 §8.4) "
                  "parse but are not meaningfully handled.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
