/* trait — TraitDef  [OUTSIDE ASTRA-0]
 * ============================================================
 * `TraitDef ::= "trait" Identifier GenericParams? WhereClause?
 *                 "{" TraitItem* "}"`
 * `TraitItem ::= FunctionDef | ConstDef`
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "fn", "const_decl", NULL };

const ConstructSpec construct_trait = {
    .name       = "trait",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "trait",
    .token      = TOKEN_TRAIT,
    .node_kind  = CONSTRUCT_NO_NODE,
    .position   = CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = false,
    .deps       = deps,
    .grammar    = "TraitDef ::= \"trait\" Identifier GenericParams? WhereClause? \"{\" TraitItem* \"}\"",
    .research   = "research/010 §12.1 (trait definition)",
    .note       = "Excluded from Astra-0 by research/011 §5.2 and §2.3 (\"don't implement "
                  "traits, generics or comptime in the seed\"): the self-hosting compiler "
                  "must fit in Astra-0 and is written without them. Lexes and is rejected "
                  "by the parser; no node, no checking. This is the file that will own "
                  "trait syntax when the full compiler reaches it.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
