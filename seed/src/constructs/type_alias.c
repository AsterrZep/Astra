/* type_alias — TypeAlias  [OUTSIDE ASTRA-0]
 * ============================================================
 * `TypeAlias ::= "type" Identifier ("=" | "<" GenericParams ">") Type`
 *
 * Note the report's own inconsistency: the alternative
 * `< GenericParams >` would also have to carry a target type, so
 * the production reads as if it were truncated. Recorded here.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "type_annotation", NULL };

const ConstructSpec construct_type_alias = {
    .name      = "type_alias",
    .role      = CONSTRUCT_LEAD,
    .keyword   = NULL,          /* no lexer token for "type" yet */
    .token     = TOKEN_IDENT,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_ITEM,
    .phases    = 0,
    .in_astra0 = false,
    .deps      = deps,
    .grammar   = "TypeAlias ::= \"type\" Identifier (\"=\" | \"<\" GenericParams \">\") Type",
    .research  = "research/010 §12.1 (type aliases)",
    .note      = "Excluded from Astra-0: aliases need the type system to resolve names "
                  "to types before checking, which the seed's flat name lookup does "
                  "(research/011 §8.4 keeps the seed's environment simple). The "
                  "production itself looks malformed — the `\"<\" GenericParams \">\"` "
                  "branch has no `=` and so no target type; the report should be fixed. "
                  "No lexer token for \"type\" exists.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
