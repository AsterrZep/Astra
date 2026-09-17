/* pattern_ident — IdentifierPattern  [OUTSIDE ASTRA-0]
 * ============================================================
 * `IdentifierPattern ::= Identifier ("@" Identifier)?
 * `AtPattern         ::= Identifier "@" Pattern`
 *
 * Not implemented. This is the construct that blocks payload
 * variants and destructuring: without a binding pattern you cannot
 * get at the data inside an enum variant, so `Color.Rgb(r, g, b)`,
 * `let (a, b) = pair` and `let else` all wait on it.
 *
 * `@` bindings and `ref`/`ref mut` are deliberately out of scope
 * too — they exist for a borrowing model the seed does not have
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
    .in_astra0 = false,
    .deps      = NULL,
    .grammar   = "IdentifierPattern ::= Identifier (\"@\" Identifier)?\n"
                 "AtPattern ::= Identifier \"@\" Pattern\n"
                 "RefPattern ::= (\"ref\" | \"ref\" \"mut\") IdentifierPattern",
    .research  = "research/010 §5.3 (Pattern grammar), §12.1; research/04 §9.4 (bindings), "
                  "§8.2 (patterns in let), §9.5 (patterns in other positions)",
    .note      = "Excluded from Astra-0: a bare identifier in a pattern is currently "
                  "rejected rather than silently turned into a binding that captures "
                  "the whole value, so nothing is silently misparsed. Implementing this "
                  "is the prerequisite for payload variants, nested patterns and "
                  "destructuring let. `ref`/`@` stay out: research/011 §5.4 keeps "
                  "borrowing semantics out of the seed.",
    .parse = NULL, .check = NULL, .emit = NULL,
};
