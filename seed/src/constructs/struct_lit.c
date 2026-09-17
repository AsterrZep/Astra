/* struct_lit — StructLiteral
 * ============================================================
 * `StructLiteral    ::= Identifier "{" StructFieldInit ("," StructFieldInit)* ","? "}"`
 * `StructFieldInit  ::= Identifier ("=" Expression)?`
 *
 * The seed accepts `:` as well as `=` between a field name and its
 * value, because struct *declarations* use `:`. The grammar says
 * `=`; that deviation is recorded here.
 *
 * Parsing `Ident { ... }` is ambiguous with a block that follows an
 * identifier, so the parser sets a no-struct-literal flag while
 * parsing `if` / `while` / `for` headers (see if.c).
 * ============================================================ */

#include "constructs/construct.h"

static const char *const deps[] = { "struct", NULL };

const ConstructSpec construct_struct_lit = {
    .name       = "struct_lit",
    .role       = CONSTRUCT_LEAD,
    .keyword    = NULL,
    .token      = TOKEN_LBRACE,
    .node_kind  = NODE_STRUCT_LIT,
    .position   = CONSTRUCT_EXPR,
    .phases     = 0,
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "StructLiteral ::= Identifier \"{\" StructFieldInit (\",\" StructFieldInit)* \",\"? \"}\"\n"
                  "StructFieldInit ::= Identifier (\"=\" Expression)?",
    .research   = "research/010 §12.1 (compound literals); research/04 §9.3 (product types)",
    .note       = "Field order in the literal is free: the emitter lays values out in "
                  "declaration order. Both `=` (§12.1) and `:` (struct declarations) "
                  "are accepted as the separator. Shorthand `Point { x }` (the "
                  "optional-expression form of §12.1) is not implemented; the "
                  "field-initializer list must name a value.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
