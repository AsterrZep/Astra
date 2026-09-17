/* ident — Identifier
 * ============================================================
 * `Identifier ::= [a-zA-Z_] [a-zA-Z0-9_]*`
 *
 * The seed's lexer also accepts `$` in identifiers so codegen
 * temporaries cannot collide with user names; that extension is
 * recorded here rather than hidden in lexer.c.
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_ident = {
    .name       = "ident",
    .role       = CONSTRUCT_LEAD,
    .keyword    = NULL,
    .token      = TOKEN_IDENT,
    .node_kind  = NODE_IDENT,
    .position   = CONSTRUCT_EXPR,
    .phases     = 0,
    .in_astra0  = true,
    .deps       = NULL,
    .grammar    = "Identifier ::= [a-zA-Z_] [a-zA-Z0-9_]*",
    .research   = "research/010 §12.1 (lexical conventions)",
    .note       = "Identifiers are interned (research/011 Appendix C), so equality is "
                  "pointer equality. `$` is allowed as an extra character for "
                  "compiler-generated names.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
