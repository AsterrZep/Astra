/* impl — ImplBlock  [OUTSIDE ASTRA-0]
 * ============================================================
 * `ImplBlock ::= "impl" GenericParams? Type ("for" Type)? WhereClause?
 *                  "{" ImplItem* "}"`
 * `ImplItem  ::= FunctionDef | ConstDef`
 * ============================================================
 * Phase 2.3 lands the subset: no GenericParams/WhereClause yet (Phase 2.4),
 * items are `fn` methods that must take a typeless `self` as first parameter,
 * and ConstDef in an impl is rejected by the parser with a dedicated message.
 */

#include "constructs/construct.h"

static const char *const deps[] = { "fn", "const_decl", "type_annotation", NULL };

const ConstructSpec construct_impl = {
    .name       = "impl",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "impl",
    .token      = TOKEN_IMPL,
    .node_kind  = NODE_IMPL,
    .position   = CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = false,
    .deps       = deps,
    .grammar    = "ImplBlock ::= \"impl\" GenericParams? Type (\"for\" Type)? WhereClause? \"{\" ImplItem* \"}\"",
    .research   = "research/010 §12.1 (impl blocks); research/011 §5.2 (simple dispatch only)",
    .note       = "Excluded from Astra-0. Phase 2.3 step 1-2: parses into NODE_IMPL "
                  "(inherent `impl T` and `impl Tr for T`); the type checker keeps the "
                  "block inert (static method dispatch lands with step 3-4) and the "
                  "emitter skips it. Static dispatch only for now — vtables and UFCS "
                  "stay deferred (research/011 §5.2). Note research/010 §12.1 spells "
                  "the type parameter list of `impl` as a bare GenericParams, which is "
                  "inconsistent with the other declarations (it would need an `<...>`); "
                  "worth fixing in the report.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
