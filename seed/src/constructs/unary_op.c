/* unary_op — Unary
 * ============================================================
 * `Unary ::= ("-" | "!" | "~" | "*" | "&") Unary | Postfix`
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_unary_op = {
    .name      = "unary_op",
    .role      = CONSTRUCT_LEAD,
    .keyword   = NULL,
    .token     = TOKEN_MINUS,
    .node_kind = NODE_UNARY_OP,
    .position  = CONSTRUCT_EXPR,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "Unary ::= (\"-\" | \"!\" | \"~\" | \"*\" | \"&\") Unary | Postfix",
    .research  = "research/010 §12.1 (unary operators), §12.2 row 11",
    .note      = "Binding power 13: unary binds tighter than any binary operator, so "
                 "`-5 + 8` is `(-5) + 8`. `*` (deref) and `&` (ref) parse into "
                 "UNOP_DEREF/UNOP_REF but Astra-0 has no pointer type yet.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
