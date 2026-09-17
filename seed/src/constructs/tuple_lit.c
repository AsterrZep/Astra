/* tuple_lit — TupleLiteral / TuplePattern  [OUTSIDE ASTRA-0]
 * ============================================================
 * `TupleLiteral ::= "(" Expression ("," Expression)+ ")"`
 * `TuplePattern ::= "(" Pattern ("," Pattern)* ")"`
 * `SimpleType    ::= ... | "(" Type ("," Type)+ ")"`
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_tuple_lit = {
    .name      = "tuple_lit",
    .role      = CONSTRUCT_LEAD,
    .keyword   = NULL,
    .token     = TOKEN_LPAREN,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_EXPR | CONSTRUCT_PATTERN,
    .phases    = 0,
    .in_astra0 = false,
    .deps      = NULL,
    .grammar   = "TupleLiteral ::= \"(\" Expression (\",\" Expression)+ \")\"\n"
                 "TuplePattern ::= \"(\" Pattern (\",\" Pattern)* \")\"\n"
                 "SimpleType ::= ... | \"(\" Type (\",\" Type)+ \")\"",
    .research  = "research/010 §12.1 (compound literals, patterns, simple types); "
                  "research/04 §9.3 (positional product types)",
    .note      = "Excluded from Astra-0. A trailing comma inside parentheses currently "
                  "produces a parse error rather than a tuple, so nothing is silently "
                  "mistaken for a grouped expression. Adding tuples means a tuple type, "
                  "a tuple layout and destructuring patterns (research/04 §9.3), which "
                  "is why it is grouped with pattern_ident in the recommended order.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
