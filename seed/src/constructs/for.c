/* for — ForExpr
 * ============================================================
 * `ForExpr ::= "for" (Pattern | Identifier) "in" Expression Block`
 *
 * Iterates ranges (`0..n`, `0..=n`) and arrays. The range forms come
 * from the `range` construct; the `in` separator is its own
 * construct (in.c). Binding a pattern here (not just an identifier)
 * is what research/04 §9.5 wants for destructuring loops.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "in", "range", "block", "break", "continue", NULL };

const ConstructSpec construct_for = {
    .name       = "for",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "for",
    .token      = TOKEN_FOR,
    .node_kind  = NODE_FOR,
    .position   = CONSTRUCT_STMT,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "ForExpr ::= \"for\" (Pattern | Identifier) \"in\" Expression Block",
    .research   = "research/010 §12.1; research/04 §9.5 (patterns in loop bindings)",
    .note       = "The iterable is evaluated once, before the loop header, so "
                  "iterating an array does not re-evaluate it per iteration.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
