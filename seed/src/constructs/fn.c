/* fn — FunctionDef
 * ============================================================
 * `FunctionDef ::= FunctionQualifiers "fn" Identifier
 *                    GenericParams? "(" FunctionParams? ")"
 *                    ReturnType? WhereClause? (Block | "=" Expression)`
 *
 * Astra-0 takes the plain form only. The qualifiers, generic
 * parameters and where-clauses are specified and deliberately out
 * of scope: research/011 §5.2 keeps generics and traits out of the
 * seed, and §5.4 defines the Astra-0 subset the self-hosting
 * compiler must fit into.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "block", "type_annotation", NULL };

const ConstructSpec construct_fn = {
    .name       = "fn",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "fn",
    .token      = TOKEN_FN,
    .node_kind  = NODE_FN_DECL,
    .position   = CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "FunctionDef ::= FunctionQualifiers \"fn\" Identifier GenericParams? \"(\" FunctionParams? \")\" "
                  "ReturnType? WhereClause? (Block | \"=\" Expression)\n"
                  "FunctionQualifiers ::= (\"pub\" | \"extern\" StringLiteral? | \"unsafe\" | \"comptime\")*\n"
                  "FunctionParams ::= FunctionParam (\",\" FunctionParam)* \",\"?\n"
                  "FunctionParam ::= (\"comptime\"? Identifier \":\" Type) | (\"&\" | \"&&\")? \"mut\"? \"self\"\n"
                  "ReturnType ::= \"->\" Type",
    .research  = "research/010 §7 (function signature grammar), §12.1; research/011 §5.2, §5.4",
    .note      = "TOP-LEVEL ONLY, and top-level functions are emitted as VM globals — a "
                  "function calling another function needs that, and storing them as "
                  "module locals made cross-function calls impossible. Methods (`self`), "
                  "generic parameters, where-clauses, qualifiers and the `= Expression` "
                  "shorthand are specified but not implemented. Parameters live in "
                  "frame slots 1..n (slot 0 is the callee).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
