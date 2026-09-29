/* use — ExportStmt / ImportPath
 * ============================================================
 * `ExportStmt ::= "use" ImportPath`
 * `ImportPath ::= Identifier ("." Identifier)*`
 *
 * The seed lexes and parses `use` into NODE_USE but the driver is
 * single-file, so nothing is actually imported: the node is
 * recorded and ignored. Module resolution is the package manager's
 * job (research/package-manager-design.md), and the self-hosting
 * compiler is where it belongs.
 *
 * `ImportPath` is the dot-separated path rule shared by `use`, `import`
 * (constructs/import.c) and `from` (constructs/from.c); it is documented
 * here because `use` was its first consumer. The `import`/`from`
 * alternatives of `ImportStmt` (research/010 §12.1) own their own files.
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
                 "ImportPath ::= Identifier (\".\" Identifier)*",
    .research  = "research/010 §12.1 (import/export); research/package-manager-design.md; "
                 "research/011 §12.5",
    .note      = "Parsed and discarded: the seed compiles a single file (research/011 "
                  "§5.2 keeps the seed free of module resolution). The path separator is `.`, "
                  "not `::` — resolved in Phase 2.2 (PHASE2_GAP_ANALYSIS.md App. B #6); "
                  "`ui/use_colon_colon.astra` pins the rejection.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
