/* assign — Assignment
 * ============================================================
 * `Assignment ::= LValue ("=" | "+=" | "-=" | "*=" | "/=" | "%="
 *                         | "&=" | "|=" | "^=" | "<<=" | ">>=" | "**=")
 *                 Assignment
 *              | LogicOr`
 *
 * Right associative and the loosest level in §12.1 (the grammar
 * entry point is `Expression ::= Assignment`), which contradicts
 * the §12.2 table row that puts assignment *highest*. See
 * Documentacion/CONSTRUCT_REGISTRY.md — the seed follows §12.1,
 * like every language in the comparison set.
 *
 * One production, two node kinds: NODE_ASSIGN and
 * NODE_COMPOUND_ASSIGN (hence also_nodes). An assignment yields the
 * assigned value so a block can end in one, as it does in C.
 * ============================================================ */

#include "constructs/construct.h"

static const NodeKind also_nodes[] = { NODE_COMPOUND_ASSIGN, CONSTRUCT_NO_NODE };

const ConstructSpec construct_assign = {
    .name       = "assign",
    .role       = CONSTRUCT_LEAD,
    .keyword    = NULL,
    .token      = TOKEN_EQ,
    .node_kind  = NODE_ASSIGN,
    .also_nodes = also_nodes,
    .position   = CONSTRUCT_EXPR,
    .phases     = 0,
    .in_astra0  = true,
    .deps       = NULL,
    .grammar    = "Assignment ::= LValue (\"=\" | \"+=\" | \"-=\" | \"*=\" | \"/=\" | \"%=\" "
                  "| \"&=\" | \"|=\" | \"^=\" | \"<<=\" | \">>=\" | \"**=\") Assignment | LogicOr",
    .research   = "research/010 §12.1 (Assignment), §2.4 (operator registration), §12.2",
    .note       = "Binding power 1 = loosest, following §12.1 rather than the §12.2 "
                  "row. The report never defines LValue; the seed reads it as "
                  "`Identifier | LValue \".\" Identifier | LValue \"[\" Expression \"]\"` "
                  "(parser checks the shape, the checker enforces mutability of the "
                  "root binding). The compound-assignment tokens are lexed but the "
                  "parser does not build NODE_COMPOUND_ASSIGN yet.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
