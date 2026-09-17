/* type_annotation — Type
 * ============================================================
 * `Type        ::= FunctionType`
 * `FunctionType ::= "(" TypeList? ")" "->" Type | AtomicType`
 * `AtomicType  ::= OptionalType`
 * `OptionalType ::= PrimaryType "?"`
 * `PrimaryType ::= SimpleType ("." "<" TypeArgs ">")?`
 * `SimpleType  ::= Identifier | "(" Type ("," Type)+ ")"
 *                | "[" Type (";" Expression)? "]"
 *                | "*" "const"? Type | "&" "mut"? Type`
 *
 * One construct covering the whole type syntax, because the parser
 * has exactly one `parse_type` entry point and the Astra-0 type
 * system is a closed set of builtins plus struct/enum names
 * (research/011 §5.2: no generics, no inference variables).
 *
 * Which spellings are implemented is recorded in `note` rather than
 * as separate files: they are alternatives inside one production,
 * not productions of their own.
 * ============================================================ */

#include "constructs/construct.h"

static const NodeKind also_nodes[] = {
    NODE_TYPE_ARRAY, NODE_TYPE_OPTIONAL, NODE_TYPE_FN, CONSTRUCT_NO_NODE,
};

const ConstructSpec construct_type_annotation = {
    .name       = "type_annotation",
    .role       = CONSTRUCT_SUB,
    .keyword    = NULL,
    .token      = TOKEN_IDENT,
    .node_kind  = NODE_TYPE_IDENT,
    .also_nodes = also_nodes,
    .position   = CONSTRUCT_TYPE,
    .phases     = 0,
    .in_astra0  = true,
    .deps       = NULL,
    .grammar    = "Type ::= FunctionType\n"
                  "FunctionType ::= \"(\" TypeList? \")\" \"->\" Type | AtomicType\n"
                  "AtomicType ::= OptionalType\n"
                  "OptionalType ::= PrimaryType \"?\"\n"
                  "PrimaryType ::= SimpleType (\".\" \"<\" TypeArgs \">\")?\n"
                  "SimpleType ::= Identifier | \"(\" Type (\",\" Type)+\")\" "
                  "| \"[\" Type (\";\" Expression)? \"]\" | \"*\" \"const\"? Type | \"&\" \"mut\"? Type",
    .research  = "research/010 §6 (type annotation grammar), §12.1; research/011 §5.2",
    .note      = "Implemented: builtin names, struct names, enum names, `[T]` arrays, "
                  "`T?` optionals (parsed, TYPE_OPTIONAL exists) and `(T, T) -> T` "
                  "function types. NOT implemented: generic arguments `T<U>`, "
                  "fixed-size arrays `[T; N]`, tuples, raw pointers and references. "
                  "Types are resolved by name at check time; there is no unification "
                  "(research/011 §8.1 calls for simplified HM, which the seed does "
                  "not yet need).",
    .parse = NULL, .check = NULL, .emit = NULL,
};
