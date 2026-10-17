/* impl — ImplBlock  [IN ASTRA-0]
 * ============================================================
 * `ImplBlock ::= "impl" GenericParams? Type ("for" Type)? WhereClause?
 *                  "{" ImplItem* "}"`
 * `ImplItem  ::= FunctionDef | ConstDef`
 * ============================================================
 * Phase 2.3 lands the subset: items are `fn` methods that must take a
 * typeless `self` as first parameter, and ConstDef in an impl is
 * rejected by the parser with a dedicated message. Generic parameters
 * parse inert since Phase 2.4 step 1 (the checker skips the block);
 * WhereClause is still unparsed.
 */

#include "constructs/construct.h"

static const char *const deps[] = { "fn", "const_decl", "type_annotation", "generic_params", NULL };

const ConstructSpec construct_impl = {
    .name       = "impl",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "impl",
    .token      = TOKEN_IMPL,
    .node_kind  = NODE_IMPL,
    .position   = CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "ImplBlock ::= \"impl\" GenericParams? Type (\"for\" Type)? WhereClause? \"{\" ImplItem* \"}\"",
    .research   = "research/001 §12.1 (impl blocks); research/002 §5.2 (simple dispatch only)",
    .note       = "In Astra-0: conformance/traits/* and conformance/generics/* pass on "
                  "it (audit §7.14 — research/002 §5.2 deferred it, the implemented "
                  "language did not). Phase 2.3: parses into NODE_IMPL "
                  "(inherent `impl T` and `impl Tr for T`), the checker registers the "
                  "methods for static dispatch and verifies trait conformance, and the "
                  "emitter compiles them as mangled `Type.method` globals. Static "
                  "dispatch only for now — vtables and UFCS stay deferred (research/002 "
                  "§5.2). Generic parameters parse inert since Phase 2.4 step 1 (the "
                  "checker skips a block that carries one). Note research/001 §12.1 "
                  "spells the type parameter list of `impl` as a bare GenericParams, "
                  "which is inconsistent with the other declarations (it would need an "
                  "`<...>`); worth fixing in the report.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
