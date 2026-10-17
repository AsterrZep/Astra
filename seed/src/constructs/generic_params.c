/* generic_params — GenericParams / GenericParam / TraitBounds
 * ============================================================
 * `GenericParams ::= "<" GenericParam ("," GenericParam)* ">"`
 * `GenericParam  ::= Identifier (":" TraitBounds)?`
 * `TraitBounds   ::= TraitBound ("+" TraitBound)*`
 * `TraitBound    ::= TypePath`
 *
 * Phase 2.4 step 1: the list parses on fn/struct/enum/trait/impl
 * declarations into one NODE_TYPE_PARAM per parameter (the declaration
 * carries them in its `generics` array); steps 2-4 then landed
 * inference, monomorphization and bound checking, which is what makes
 * generics part of Astra-0 rather than deferred Phase 2 material
 * (conformance generics cases — audit §7.14).
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_generic_params = {
    .name      = "generic_params",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_LT,
    .node_kind = NODE_TYPE_PARAM,
    .position  = CONSTRUCT_ITEM,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "GenericParams ::= \"<\" GenericParam (\",\" GenericParam)* \">\"\n"
                 "GenericParam ::= Identifier (\":\" TraitBounds)?\n"
                 "TraitBounds ::= TraitBound (\"+\" TraitBound)*\n"
                 "TraitBound ::= TypePath",
    .research  = "research/001 §7.3, §12.1 (generic parameter lists); "
                 "research/002 §5.2 (generics were deferred to Phase 2)",
    .note      = "In Astra-0: conformance/generics/* passes on it (audit §7.14 — "
                 "research/002 §5.2 deferred generics, the implemented language "
                 "includes them). Phase 2.4 step 1: parses on fn/struct/enum/"
                 "trait/impl declarations into NODE_TYPE_PARAM nodes; inference and "
                 "monomorphization landed with steps 2-4. Bounds parse as bare "
                 "TypePath identifiers (traits are not namespaced yet), and "
                 "where-clauses are not parsed at all.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
