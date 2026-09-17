/* struct — StructDef
 * ============================================================
 * `StructDef    ::= StructQualifiers "struct" Identifier
 *                     GenericParams? WhereClause? "{" StructFields? "}"`
 * `StructFields ::= StructField ("," StructField)* ","?`
 * `StructField  ::= Identifier ":" Type`
 *
 * Product types: research/04 §9.3. The literal form is the separate
 * struct_lit construct. A struct declaration produces no bytecode of
 * its own — the emitter collects the layout up front so that
 * literals and field access can be resolved by name.
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "type_annotation", "struct_lit", NULL };

const ConstructSpec construct_struct = {
    .name       = "struct",
    .role       = CONSTRUCT_LEAD,
    .keyword    = "struct",
    .token      = TOKEN_STRUCT,
    .node_kind  = NODE_STRUCT_DECL,
    .position   = CONSTRUCT_ITEM,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "StructDef ::= StructQualifiers \"struct\" Identifier GenericParams? WhereClause? "
                  "\"{\" StructFields? \"}\"\n"
                  "StructFields ::= StructField (\",\" StructField)* \",\"?",
    .research  = "research/04 §9.3 (product types), §6.1-6.4 (layouts); research/010 §12.1",
    .note      = "Fields are layout-ordered by declaration; the emitter resolves field "
                  "access by name against the StructInfo table. Generics, qualifiers and "
                  "tuple structs (`struct Pair(i32, i32)`, research/04 §9.3) are not "
                  "implemented. Struct layouts are duplicated into each function's "
                  "constant pool, because every VM function owns its own pool.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
