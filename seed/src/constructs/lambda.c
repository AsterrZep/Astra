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
    .node_kind  = CONSTRUCT_NO_NODE,
    .position   = CONSTRUCT_EXPR,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = false,
    .deps       = deps,
    .grammar    = "LambdaExpr ::= \"|\" LambdaParams? \"|\" (\"->\" Type)? Block\n"
                  "LambdaParam ::= Identifier (\":\" Type)?",
    .research   = "research/010 §12.1 (lambda/closure); research/011 §5.2 (Tier 2 of the MVP)",
    .note       = "Excluded from Astra-0: closures need capture analysis and a heap "
                  "representation for the captured environment, and the seed has no ARC "
                  "or GC to own that memory (research/011 §5.4 - the seed uses arena "
                  "allocation only). `|` is currently parsed as bitwise-or, so there is "
                  "no ambiguity in practice yet; the parser will need lookahead when "
                  "this lands.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
