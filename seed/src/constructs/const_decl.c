/* const_decl — ConstDef
 * ============================================================
 * `ConstDef ::= ("pub"? "const" | "val") Identifier (":" Type)? "=" Expression`
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "type_annotation", NULL };

const ConstructSpec construct_const_decl = {
    .name      = "const_decl",
    .role      = CONSTRUCT_LEAD,
    .keyword   = "const",
    .token     = TOKEN_CONST,
    .node_kind = NODE_CONST_DECL,
    .position  = CONSTRUCT_ITEM,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "ConstDef ::= (\"pub\"? \"const\" | \"val\") Identifier (\":\" Type)? \"=\" Expression",
    .research  = "research/010 §12.1 (constants)",
    .note      = "Constant folding is not implemented: the initialiser is evaluated "
                  "where the constant is used. The `val` spelling has no lexer token "
                  "(the seed's `let` covers immutable bindings).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
