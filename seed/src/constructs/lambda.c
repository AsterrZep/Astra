/* lambda — LambdaExpr  [OUTSIDE ASTRA-0]
 * ============================================================
 * `LambdaExpr   ::= "|" LambdaParams? "|" ("->" Type)? Block`
 * `LambdaParams ::= LambdaParam ("," LambdaParam)* ","?`
 * `LambdaParam  ::= Identifier (":" Type)?`
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "block", "type_annotation", NULL };

const ConstructSpec construct_lambda = {
    .name       = "lambda",
    .role       = CONSTRUCT_LEAD,
    .keyword    = NULL,
    .token      = TOKEN_PIPE,
    .node_kind  = NODE_LAMBDA,
    .position   = CONSTRUCT_EXPR,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "LambdaExpr ::= \"|\" LambdaParams? \"|\" (\"->\" Type)? Block\n"
                  "LambdaParam ::= Identifier (\":\" Type)?",
    .research   = "research/010 §12.1 (lambda/closure); research/011 §5.2 (Tier 2 of the MVP)",
    .note       = "Lambdas compile to inner FnObj values, like regular functions. "
                  "Closures (captured variables) are not supported in Astra-0; "
                  "the lambda body may only reference its own parameters and globals. "
                  "`|` is disambiguated from bitwise-or by context: a `|` at expression "
                  "start is always a lambda, while `|` after an expression is bitwise-or.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
