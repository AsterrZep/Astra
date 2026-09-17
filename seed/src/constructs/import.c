/* import — ImportStmt  [OUTSIDE ASTRA-0]
 * ============================================================
 * `ImportStmt ::= "import" ImportPath ("as" Identifier)?
 *               | "from" ImportPath "import" ImportItem ("," ImportItem)*`
 * `ImportItem ::= Identifier ("as" Identifier)?`
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_import = {
    .name      = "import",
    .role      = CONSTRUCT_LEAD,
    .keyword   = NULL,          /* no lexer token yet — see note */
    .token     = TOKEN_IDENT,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_ITEM,
    .phases    = 0,
    .in_astra0 = false,
    .deps      = NULL,
    .grammar   = "ImportStmt ::= \"import\" ImportPath (\"as\" Identifier)?\n"
                 "             | \"from\" ImportPath \"import\" ImportItem (\",\" ImportItem)*",
    .research  = "research/010 §12.1 (import/export); research/package-manager-design.md",
    .note      = "Excluded from Astra-0: the seed compiles exactly one file, so `use` is "
                  "parsed and ignored and nothing resolves modules (see use.c). "
                  "`keyword` is NULL because the lexer has no token for \"import\" or "
                  "\"from\" — adding the tokens is the first step when this lands.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
