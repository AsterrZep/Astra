/* literal — Literal
 * ============================================================
 * `Literal ::= IntegerLiteral | FloatLiteral | StringLiteral
 *            | CharLiteral | BoolLiteral | "null" | "none"
 *            | ArrayLiteral | TupleLiteral | StructLiteral`
 *
 * One production, five node kinds (also_nodes). Integer literals
 * accept the hex/octal/binary forms and `_` digit separators, all
 * specified in §12.1 and implemented in the lexer.
 *
 * Char literals (`'a'`) are specified but NOT implemented: the
 * lexer has no TOKEN_CHAR and the type system has no char type.
 * Recorded here so the gap is visible.
 * ============================================================ */

#include "constructs/construct.h"

static const NodeKind also_nodes[] = {
    NODE_FLOAT_LIT, NODE_STRING_LIT, NODE_BOOL_LIT, NODE_NULL_LIT,
    CONSTRUCT_NO_NODE,
};

const ConstructSpec construct_literal = {
    .name       = "literal",
    .role       = CONSTRUCT_LEAD,
    .keyword    = NULL,
    .token      = TOKEN_INT_LIT,
    .node_kind  = NODE_INT_LIT,
    .also_nodes = also_nodes,
    .position   = CONSTRUCT_EXPR,
    .phases     = 0,
    .in_astra0  = true,
    .deps       = NULL,
    .grammar    = "Literal ::= IntegerLiteral | FloatLiteral | StringLiteral | CharLiteral "
                  "| BoolLiteral | \"null\" | \"none\" | ArrayLiteral | TupleLiteral | StructLiteral",
    .research   = "research/010 §12.1 (literals and lexical conventions)",
    .note       = "Integer bases (hex/octal/binary) and `_` separators are implemented. "
                  "`none` is lexed as TOKEN_IDENT: Option/Result are not in Astra-0 yet. "
                  "CharLiteral is specified but has no lexer token.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
