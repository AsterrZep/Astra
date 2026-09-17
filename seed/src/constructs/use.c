/* use — ExportStmt / ImportStmt
 * ============================================================
 * `ExportStmt ::= "use" ImportPath`
 * `ImportStmt ::= "import" ImportPath ("as" Identifier)?
 *               | "from" ImportPath "import" ImportItem ("," ImportItem)*`
 *
 * The seed lexes and parses `use` into NODE_USE but the driver is
 * single-file, so nothing is actually imported: the node is
 * recorded and ignored. Module resolution is the package manager's
 * job (research/package-manager-design.md), and the self-hosting
 * compiler is where it belongs.
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_use = {
    .name      = "use",
    .role      = CONSTRUCT_LEAD,
    .keyword   = "use",
    .token     = TOKEN_USE,
    .node_kind = NODE_USE,
    .position  = CONSTRUCT_ITEM,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "ExportStmt ::= \"use\" ImportPath\n"
                 "ImportStmt ::= \"import\" ImportPath (\"as\" Identifier)?\n"
                 "             | \"from\" ImportPath \"import\" ImportItem (\",\" ImportItem)*\n"
                 "ImportPath ::= Identifier (\".\" Identifier)*",
    .research  = "research/010 §12.1 (import/export); research/package-manager-design.md; "
                 "research/011 §12.5",
    .note      = "Parsed and discarded: the seed compiles a single file (research/011 "
                  "§5.2 keeps the seed free of module resolution). `import`/`from` have "
                  "no lexer tokens yet, so only the `use` form is recognised.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
