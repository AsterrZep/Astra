/* array_lit — ArrayLiteral
 * ============================================================
 * `ArrayLiteral ::= "[" Expression ("," Expression)* ","? "]"`
 *
 * Elements must share one type; the seed infers the array's element
 * type from the first element and rejects the rest on mismatch
 * (Astra-0 has no inference variables yet — research/011 §8.1).
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_array_lit = {
    .name       = "array_lit",
    .role       = CONSTRUCT_LEAD,
    .keyword    = NULL,
    .token      = TOKEN_LBRACKET,
    .node_kind  = NODE_ARRAY_LIT,
    .position   = CONSTRUCT_EXPR,
    .phases     = 0,
    .has_braces = false,
    .in_astra0  = true,
    .deps       = NULL,
    .grammar    = "ArrayLiteral ::= \"[\" Expression (\",\" Expression)* \",\"? \"]\"",
    .research   = "research/010 §12.1 (compound literals); research/serialization-and-allocators.md",
    .note       = "The fixed-size form `[T; N]` of §12.1 is not implemented; arrays "
                  "grow at runtime (VAL_ARRAY). The trailing comma is allowed.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
