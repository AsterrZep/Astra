/* generic_params — GenericParams / GenericParam / TraitBounds
 * ============================================================
 * `GenericParams ::= "<" GenericParam ("," GenericParam)* ">"`
 * `GenericParam  ::= Identifier (":" TraitBounds)?`
 * `TraitBounds   ::= TraitBound ("+" TraitBound)*`
 * `TraitBound    ::= TypePath`
 *
 * Phase 2.4 step 1: the list parses on fn/struct/enum/trait/impl
 * declarations into one NODE_TYPE_PARAM per parameter (the declaration
 * carries them in its `generics` array). The type checker and the
 * emitter skip any declaration that carries one — inference,
 * monomorphization and bounds checking land with the later steps.
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
    .in_astra0 = false,
    .deps      = NULL,
    .grammar   = "GenericParams ::= \"<\" GenericParam (\",\" GenericParam)* \">\"\n"
                 "GenericParam ::= Identifier (\":\" TraitBounds)?\n"
                 "TraitBounds ::= TraitBound (\"+\" TraitBound)*\n"
                 "TraitBound ::= TypePath",
    .research  = "research/010 §7.3, §12.1 (generic parameter lists); "
                 "research/011 §5.2 (generics are outside Astra-0)",
    .note      = "Out of Astra-0. Phase 2.4 step 1: parses inert on fn/struct/"
                 "enum/trait/impl declarations into NODE_TYPE_PARAM nodes; the "
                 "checker and the emitter skip declarations that carry one until "
                 "steps 2-4 land inference, monomorphization and bounds checking. "
                 "Bounds parse as bare TypePath identifiers (traits are not "
                 "namespaced yet), and where-clauses are not parsed at all.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
