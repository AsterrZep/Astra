/* import — ImportStmt (the `import path ("as" alias)?` alternative)
 * ============================================================
 * `ImportStmt ::= "import" ImportPath ("as" Identifier)?`
 *
 * `ImportStmt` is one production with two alternatives (research/010
 * §12.1); the seed keeps `import` and `from` as two constructs — one per
 * keyword — so each keyword can be registered with its own token. This file
 * owns the `import` alternative; `ImportPath` is documented in use.c and the
 * `from` alternative in constructs/from.c.
 *
 * The seed parses `import` into NODE_IMPORT but the driver is single-file,
 * so nothing is imported: the node is recorded and ignored, and module
 * resolution stays the package manager's job (research/011 §5.2).
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_import = {
    .name      = "import",
    .role      = CONSTRUCT_LEAD,
    .keyword   = "import",
    .token     = TOKEN_IMPORT,
    .node_kind = NODE_IMPORT,
    .position  = CONSTRUCT_ITEM,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "ImportStmt ::= \"import\" ImportPath (\"as\" Identifier)?",
    .research  = "research/010 §12.1 (import/export); research/package-manager-design.md; "
                 "research/011 §12.5",
    .note      = "Parsed and discarded: the seed compiles a single file (research/011 §5.2 "
                  "keeps the seed free of module resolution). The `import` keyword and token "
                  "were added in Phase 2.2 alongside `from` and `as`, so the seed recognises "
                  "the same module surface the Zig frontend already parses.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
