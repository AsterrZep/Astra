/* binary_op — the binary-expression chain
 * ============================================================
 * §12.1 spells the binary chain out as eleven productions
 * (LogicOr, LogicAnd, BitOr, BitXor, BitAnd, Equality,
 * Comparison, Shift, Additive, Multiplicative, Power), one per
 * precedence level.
 *
 * Those eleven are NOT split into eleven files. They are
 * mechanically derivable from a single precedence table, and
 * §2.4/§12.2 presents them as exactly that — a table. Splitting
 * them would mean eleven files that must be edited in lockstep
 * every time a level moves, which is the opposite of control.
 * The table is the single source of truth and lives in
 * operator_table.c; the parser reads the same numbers, and
 * `--check-constructs` fails if they ever diverge.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "operator_table", NULL };

const ConstructSpec construct_binary_op = {
    .name      = "binary_op",
    .role      = CONSTRUCT_LEAD,
    .keyword   = NULL,
    .token     = TOKEN_PLUS,
    .node_kind = NODE_BINARY_OP,
    .position  = CONSTRUCT_EXPR,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "LogicOr ::= LogicAnd (\"||\" LogicAnd)*\n"
                 "LogicAnd ::= BitOr (\"&&\" BitOr)*\n"
                 "BitOr ::= BitXor (\"|\" BitXor)*\n"
                 "BitXor ::= BitAnd (\"^\" BitAnd)*\n"
                 "BitAnd ::= Equality (\"&\" Equality)*\n"
                 "Equality ::= Comparison ((\"==\" | \"!=\") Comparison)*\n"
                 "Comparison ::= Shift ((\"<\" | \">\" | \"<=\" | \">=\") Shift)*\n"
                 "Shift ::= Additive ((\"<<\" | \">>\") Additive)*\n"
                 "Additive ::= Multiplicative ((\"+\" | \"-\") Multiplicative)*\n"
                 "Multiplicative ::= Power ((\"*\" | \"/\" | \"%\") Power)*\n"
                 "Power ::= Unary (\"**\" Unary)*",
    .research = "research/010 §2.2-2.4 (Pratt parsing, operator registration), §12.1, §12.2",
    .note     = "Eleven productions collapsed into one construct because they are one "
                "table; see operator_table.c for the deviations from §12.2 (`**` is "
                "specified but unimplemented, `%` binds with `*` as in the table, "
                "prefix/postfix rows are recorded there).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
