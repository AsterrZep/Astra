/* trait — TraitDef  [OUTSIDE ASTRA-0]
 * ============================================================
 * `TraitDef ::= "trait" Identifier GenericParams? WhereClause?
 *                 "{" TraitItem* "}"`
 * `TraitItem ::= FunctionDef | ConstDef`
 * ============================================================
 * Phase 2.3 lands the subset: no GenericParams/WhereClause yet (Phase 2.4),
 * items are `fn` only, and ConstDef in a trait is rejected by the parser
 * with a dedicated message. A trait method may be signature-only.
 */

#include "constructs/construct.h"

static const char *const deps[] = { "fn", "const_decl", NULL };

const ConstructSpec construct_trait = {
    .name       = "trait",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "trait",
    .token      = TOKEN_TRAIT,
    .node_kind  = NODE_TRAIT,
    .position   = CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = false,
    .deps       = deps,
    .grammar    = "TraitDef ::= \"trait\" Identifier GenericParams? WhereClause? \"{\" TraitItem* \"}\"",
    .research   = "research/010 §12.1 (trait definition)",
    .note       = "Excluded from Astra-0 by research/011 §5.2 and §2.3 (\"don't implement "
                  "traits, generics or comptime in the seed\"). Phase 2.3 step 1-2: parses "
                  "into NODE_TRAIT; the type checker keeps the block inert (no method "
                  "table or conformance checks yet) and the emitter skips it. Still "
                  "outside Astra-0 — it is Phase 2 language, not bootstrap material.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
