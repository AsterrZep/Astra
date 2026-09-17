/* impl — ImplBlock  [OUTSIDE ASTRA-0]
 * ============================================================
 * `ImplBlock ::= "impl" GenericParams? Type ("for" Type)? WhereClause?
 *                  "{" ImplItem* "}"`
 * `ImplItem  ::= FunctionDef | ConstDef`
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "fn", "const_decl", "type_annotation", NULL };

const ConstructSpec construct_impl = {
    .name       = "impl",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "impl",
    .token      = TOKEN_IMPL,
    .node_kind  = CONSTRUCT_NO_NODE,
    .position   = CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = false,
    .deps       = deps,
    .grammar    = "ImplBlock ::= \"impl\" GenericParams? Type (\"for\" Type)? WhereClause? \"{\" ImplItem* \"}\"",
    .research   = "research/010 §12.1 (impl blocks); research/011 §5.2 (simple dispatch only)",
    .note       = "Excluded from Astra-0. Methods need a receiver (`self`), a vtable or "
                  "static-dispatch decision and UFCS resolution — all of which research/011 "
                  "§5.2 pushes past the seed. NODE_IMPL exists in the AST but nothing "
                  "produces it. Note research/010 §12.1 spells the type parameter list of "
                  "`impl` as a bare GenericParams, which is inconsistent with the other "
                  "declarations (it would need an `<...>`); worth fixing in the report.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
