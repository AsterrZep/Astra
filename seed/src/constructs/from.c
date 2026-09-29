/* from — ImportStmt (the `from path import item, ...` alternative)
 * ============================================================
 * `ImportStmt ::= "from" ImportPath "import" ImportItem ("," ImportItem)*`
 *
 * `ImportStmt` is one production with two alternatives (research/010
 * §12.1); the seed keeps `from` and `import` as two constructs — one per
 * keyword — so each keyword can be registered with its own token. This file
 * owns the `from` alternative; `ImportPath` is documented in use.c and
 * `ImportItem` is owned by constructs/import_item.c.
 *
 * The seed parses `from` into NODE_FROM but the driver is single-file, so
 * nothing is imported: the node is recorded and ignored, and module
 * resolution stays the package manager's job (research/011 §5.2).
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "import_item", NULL };

const ConstructSpec construct_from = {
    .name      = "from",
    .role      = CONSTRUCT_LEAD,
    .keyword   = "from",
    .token     = TOKEN_FROM,
    .node_kind = NODE_FROM,
    .position  = CONSTRUCT_ITEM,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = deps,
    .grammar   = "ImportStmt ::= \"from\" ImportPath \"import\" ImportItem (\",\" ImportItem)*",
    .research  = "research/010 §12.1 (import/export); research/package-manager-design.md; "
                 "research/011 §12.5",
    .note      = "Parsed and discarded: the seed compiles a single file (research/011 §5.2 "
                  "keeps the seed free of module resolution). The `from` keyword and token "
                  "were added in Phase 2.2 alongside `import` and `as`.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
