/* comptime — ComptimeBlock / ComptimeExpr  [OUTSIDE ASTRA-0]
 * ============================================================
 * `ComptimeBlock ::= "comptime" (Block | ":" Statement)`
 * `ComptimeExpr  ::= "comptime" Expression`
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "block", NULL };

const ConstructSpec construct_comptime = {
    .name       = "comptime",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "comptime",
    .token      = TOKEN_COMPTIME,
    .node_kind  = CONSTRUCT_NO_NODE,
    .position   = CONSTRUCT_STMT | CONSTRUCT_EXPR | CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = false,
    .deps       = deps,
    .grammar    = "ComptimeBlock ::= \"comptime\" (Block | \":\" Statement)\n"
                  "ComptimeExpr ::= \"comptime\" Expression",
    .research   = "research/010 §8 (comptime grammar); research/Comptime_Metaprogramming_Report.md; "
                  "research/011 §5.3 (explicitly not needed by the seed)",
    .note       = "Excluded from Astra-0 by explicit decision (research/011 §2.3 and §5.3: "
                  "the seed implements \"only what is needed to compile the self-hosting "
                  "compiler\", and the self-hosting compiler is written in Astra-0 without "
                  "comptime). Lexes to TOKEN_COMPTIME and is rejected by the parser.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
