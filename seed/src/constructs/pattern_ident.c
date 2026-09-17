/* pattern_ident — IdentifierPattern
 * ============================================================
 * `IdentifierPattern ::= Identifier ("@" Identifier)?`
 * `AtPattern         ::= Identifier "@" Pattern`
 *
 * A bare identifier in a pattern captures (binds) the whole matched
 * value. The `@` binding form and `ref`/`ref mut` are out of scope
 * — they exist for a borrowing model the seed does not have
 * (research/011 §5.4).
 * ============================================================ */

#include "constructs/construct.h"

const ConstructSpec construct_pattern_ident = {
    .name      = "pattern_ident",
    .role      = CONSTRUCT_SUB,
    .keyword   = NULL,
    .token     = TOKEN_IDENT,
    .node_kind = CONSTRUCT_NO_NODE,
    .position  = CONSTRUCT_PATTERN,
    .phases    = 0,
    .in_astra0 = true,
    .deps      = NULL,
    .grammar   = "IdentifierPattern ::= Identifier (\"@\" Identifier)?\n"
                 "AtPattern ::= Identifier \"@\" Pattern\n"
                 "RefPattern ::= (\"ref\" | \"ref\" \"mut\") IdentifierPattern",
    .research  = "research/010 §5.3 (Pattern grammar), §12.1; research/04 §9.4 (bindings), "
                  "§8.2 (patterns in let), §9.5 (patterns in other positions)",
    .note      = "Bare identifier binding is implemented (NODE_PATTERN_BIND). "
                  "`@` bindings and `ref`/`ref mut` stay out: research/011 §5.4 "
                  "keeps borrowing semantics out of the seed.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
