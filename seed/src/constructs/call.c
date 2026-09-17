/* call — the postfix call form
 * ============================================================
 * `"(" ArgumentList? ")"` applied to a callee expression.
 *
 * Named arguments (`NamedArg ::= Identifier "=" Expression`) are
 * specified in §12.1 and not implemented: the seed takes positional
 * arguments only. UFCS / method-call syntax is likewise absent
 * (research/011 §5.2 keeps the seed's dispatch simple).
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_call = {
    .name      = "call",
    .role      = CONSTRUCT_LEAD,
    .keyword   = NULL,
    .token     = TOKEN_LPAREN,
    .node_kind = NODE_CALL,
    .position  = CONSTRUCT_EXPR,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "Postfix ::= Primary ( \".\" Identifier | \"[\" Expression (\".\" \".\" Expression)? \"]\" "
                 "| \"(\" ArgumentList? \")\" | \"?\" | \"++\" | \"--\" )*\n"
                 "ArgumentList ::= NamedArg (\",\" NamedArg)* | Expression (\",\" Expression)*\n"
                 "NamedArg ::= Identifier \"=\" Expression",
    .research  = "research/010 §12.1 (postfix operators, argument lists); research/011 §7.3",
    .note      = "Positional arguments only; named arguments are specified but not "
                 "implemented. Argument values are copied into the callee's frame.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
