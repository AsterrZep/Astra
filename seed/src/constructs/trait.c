/* trait — TraitDef  [IN ASTRA-0]
 * ============================================================
 * `TraitDef ::= "trait" Identifier GenericParams? WhereClause?
 *                 "{" TraitItem* "}"`
 * `TraitItem ::= FunctionDef | ConstDef`
 * ============================================================
 * Phase 2.3 lands the subset: items are `fn` only, and ConstDef in a
 * trait is rejected by the parser with a dedicated message. A trait
 * method may be signature-only. Generic parameters parse inert since
 * Phase 2.4 step 1 (the checker skips the trait); WhereClause is
 * still unparsed.
 */

#include "constructs/construct.h"

static const char *const deps[] = { "fn", "const_decl", "generic_params", NULL };

const ConstructSpec construct_trait = {
    .name       = "trait",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "trait",
    .token      = TOKEN_TRAIT,
    .node_kind  = NODE_TRAIT,
    .position   = CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "TraitDef ::= \"trait\" Identifier GenericParams? WhereClause? \"{\" TraitItem* \"}\"",
    .research   = "research/001 §12.1 (trait definition)",
    .note       = "In Astra-0: conformance/traits/* passes on it (audit §7.14 — "
                  "research/002 §5.2 and §2.3 said \"don't implement traits, generics "
                  "or comptime in the seed\", and Phase 2.3 implemented them anyway). "
                  "Parses into NODE_TRAIT, the checker collects the required method "
                  "signatures for conformance and the emitter skips the block (traits "
                  "have no runtime form).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
