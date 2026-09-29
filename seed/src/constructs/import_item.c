/* import_item — ImportItem (sub-production of ImportStmt)
 * ============================================================
 * `ImportItem ::= Identifier ("as" Identifier)?`
 *
 * A sub-construct: it owns the `ImportItem` node kind but is only reachable
 * through `from`, which lists it in its `deps`. The node carries the imported
 * name plus the optional `as` alias (alias == NULL when there is none).
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_import_item = {
    .name      = "import_item",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_IDENT,
    .node_kind = NODE_IMPORT_ITEM,
    .position  = CONSTRUCT_ITEM,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "ImportItem ::= Identifier (\"as\" Identifier)?",
    .research  = "research/010 §12.1 (import/export)",
    .note      = "Carried by the `from` alternative of ImportStmt; the parser builds one node "
                  "per item, with alias == NULL when the item has no `as`.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
