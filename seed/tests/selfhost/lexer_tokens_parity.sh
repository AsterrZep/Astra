#!/usr/bin/env bash
# Strong self-hosting lexer gate (research/028 §4.3 «Gate fuerte», cerrado en
# PR3b — DEC-016 lo pospuso, DEC-017 lo fija): the lexer WRITTEN IN ASTRA-0
# must reproduce the TOKEN STREAM of the lexer written in C
# (`astra-seed --dump-tokens`), not only its own committed golden.
# lexer_gate.sh proves it runs and emits the expected bytes; THIS gate proves
# the two lexer implementations tokenize identically — the real criterion of
# "the language compiles its own lexer".
#
#   ./seed/tests/selfhost/lexer_tokens_parity.sh     # from anywhere
#
# Design: each side is NORMALIZED to one `line KIND value` token per line
# (awk programs embedded below) and the normalized streams are diffed. The
# Astra-0 stream is compared against the SEED reference (the other routes
# already require byte-parity with lexer.expected in lexer_gate.sh, so their
# token stream is the same one compared here); when the zig compiler is
# built, its --dump-tokens must additionally be byte-identical to the seed's
# on this fixture (dump_parity.sh does not cover selfhost/), which ties the
# gate to both frontends.
#
# KINDs that map 1:1:
#   KEYWORD  the seed dump prints each keyword as its OWN kind name (`fn`,
#            `struct`, `true` …), which is exactly the lexer's KEYWORD lexeme
#   IDENT    1:1; the dump's lone `_` (TOKEN_UNDERSCORE) maps to IDENT `_`:
#            lexer.astra has no UNDERSCORE token, is_alpha accepts `_`, and a
#            wildcard arm lexes as an identifier there
#   INT      1:1 after value conversion: the dump prints the parsed VALUE
#            (`0x2A` → 42) while the lexer prints the raw lexeme, so the
#            normalizer converts decimal and 0x-hex to decimal
#   PUNCT    SYMBOL/OP of the lexer = the dump's per-operator kinds, which are
#            printed as the operator lexeme itself (`+ - * / = ; , . : | ! < >
#            ? ( ) { } [ ] == != <= >= && || -> :: => ..`)
#   ERROR    KIND and line only (the dump prints no message, the lexer prints
#            `unknown char '$'` — the message is golden-gated instead)
#   EOF      1:1
#
# Deliberately OUT of scope (a partial honest gate beats a broken complete
# one — DEC-017):
#   - NEWLINE: the seed emits a token per newline, lexer.astra skips them
#     (DEC-016), so the seed normalizer drops them.
#   - Columns: the seed tracks line:col, lexer.astra only lines. Only the
#     line is compared.
#   - STRING content: the dump prints the processed runtime VALUE (escapes
#     resolved, raw bytes — an embedded \n even spans physical dump lines),
#     the lexer the verbatim source lexeme (`\" \n` kept as written). Putting
#     both in the same space would test the normalizer's escape re-processing,
#     not the lexer; the content IS pinned byte-for-byte by lexer.expected in
#     lexer_gate.sh. The strong gate compares the string's KIND and line.
#   - FLOAT_LIT: lexer.astra lexes no floats (DEC-016). If a float ever
#     enters lexer_input.astra, the seed normalizer emits an unknown kind and
#     this gate FAILS loudly ("UNMAPPED") instead of silently passing.
#   - Tokens after the first ERROR: run_dump_tokens breaks on TOKEN_ERROR, so
#     the C stream ENDS at the first invalid char while lexer.astra recovers
#     and keeps going (INT:2@41, }@42, EOF@43 in the committed fixture). Both
#     normalizers stop at their first ERROR (inclusive): the gate compares the
#     common prefix, and the recovery tail is pinned by the golden gate.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)     # seed/tests/selfhost
root=$(cd "$here/../../.." && pwd)
cd "$here"                              # ← cwd fijo: read_file usa path relativo

SEED="$root/seed/astra-seed"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "lexer_tokens_parity: $*" >&2; exit 2; }

[ -x "$SEED" ] || die "missing $SEED (build with 'make -C seed')"

# --- side 1: the C lexer (reference) ----------------------------------------
# rc=1 is EXPECTED, not an error: lexer_input.astra carries an invalid `$` on
# purpose and run_dump_tokens returns false when it stops on TOKEN_ERROR.
"$SEED" --dump-tokens lexer_input.astra >"$TMP/dump" 2>"$TMP/dump.err"
dump_rc=$?
if [ "$dump_rc" -gt 1 ] || [ ! -s "$TMP/dump" ]; then
    echo "FAIL --dump-tokens exited rc=$dump_rc with no usable output"
    sed 's/^/      /' "$TMP/dump.err"
    exit 1
fi

# --- side 1b: the zig frontend must agree with the seed on this fixture ----
# dump_parity.sh byte-gates --dump-tokens seed<->zig on conformance/codegen
# but NOT on selfhost/ fixtures; without this line the strong gate would tie
# lexer.astra to the SEED reference only. Same rc expected (both stop on the
# fixture's intentional ERROR token).
ZIG="$root/zig/zig-out/bin/astra-zig"
if [ -x "$ZIG" ]; then
    "$ZIG" --dump-tokens lexer_input.astra >"$TMP/zdump" 2>/dev/null
    zrc=$?
    if [ "$zrc" != "$dump_rc" ] || ! cmp -s "$TMP/dump" "$TMP/zdump"; then
        echo "FAIL zig --dump-tokens diverges from the seed on lexer_input.astra"
        diff "$TMP/dump" "$TMP/zdump" | sed 's/^/      /' | head -20
        exit 1
    fi
else
    echo "note: zig not built — the gate compares against the seed reference only"
fi

# --- side 2: the Astra-0 lexer (canonical route: seed VM) -------------------
if ! "$SEED" lexer.astra >"$TMP/lex" 2>"$TMP/lex.err"; then
    echo "FAIL lexer.astra (non-zero exit on the seed VM)"
    sed 's/^/      /' "$TMP/lex.err"
    exit 1
fi

# --- normalizer: `--dump-tokens` -> `line KIND value` -----------------------
# `line:col  KIND14  [value]` (driver.c token_print); STRING_LIT values are
# printed raw, so a value with a \n spans physical lines — the token ends at
# the first following line ending with the closing quote (a value whose
# INTERIOR line ends with `"` would confuse that scan; the fixture is
# committed and doesn't, and any leftover fails the parse below loudly).
awk '
{
    if (in_str) {
        if ($0 ~ /"$/) { printf "%s STR\n", str_line; in_str = 0 }
        next
    }
    if ($0 !~ /^[0-9]+:[0-9]+  /) {
        printf "UNPARSABLE dump line: %s\n", $0 > "/dev/stderr"; exit 3
    }
    loc = $0; sub(/ .*/, "", loc); sub(/:/, " ", loc); split(loc, lc, " ")
    line = lc[1]
    rest = $0; sub(/^[0-9]+:[0-9]+  /, "", rest)
    kind = rest; sub(/ .*/, "", kind)
    val  = rest; sub(/^[^ ]+ */, "", val)
    if (kind == "NEWLINE") next                   # the lexer skips them (DEC-016)
    if (kind == "IDENT")   { sub(/^"/, "", val); sub(/"$/, "", val)
                             printf "%s IDENT %s\n", line, val; next }
    if (kind == "INT_LIT") { printf "%s INT %s\n", line, val; next }
    if (kind == "STRING_LIT") {
        # printf writes `  "` + value + `"` with no trailing padding: a line
        # ending with `"` holds a complete single-line value, otherwise the
        # value continues on the next physical lines.
        if (val ~ /"$/) { printf "%s STR\n", line; next }
        in_str = 1; str_line = line; next
    }
    if (kind == "ERROR") { printf "%s ERROR\n", line; exit 0 }  # C lexer STOPS
    if (kind == "EOF")   { printf "%s EOF\n",   line; exit 0 }
    if (kind == "_")     { printf "%s IDENT _\n", line; next }  # no UNDERSCORE in lexer.astra
    if (kind ~ /^[a-z]+$/) { printf "%s KEYWORD %s\n", line, kind; next }
    if (kind ~ /[A-Z]/)  { printf "UNMAPPED seed kind: %s\n", kind > "/dev/stderr"; exit 3 }
    printf "%s PUNCT %s\n", line, kind            # punctuation = its own kind
}
' "$TMP/dump" >"$TMP/dump.norm" 2>"$TMP/dump.norm.err"
dump_norm_rc=$?
if [ "$dump_norm_rc" -ne 0 ] || grep -q UNMAPPED "$TMP/dump.norm.err" 2>/dev/null; then
    echo "FAIL normalizer (seed side) — a new token kind needs a mapping"
    sed 's/^/      /' "$TMP/dump.norm.err"
    exit 1
fi

# --- normalizer: lexer.astra output -> `line KIND value` --------------------
# `<KIND>:<lexeme>@<line>` (lexer.astra header); the lexeme may contain `:`
# or `@` (SYMBOL::, strings), so kind and line are anchored and the middle is
# greedy. INT converts decimal/0x-hex to the value the dump prints.
awk '
{
    if ($0 !~ /^[A-Z]+:.*@[0-9]+$/) {
        printf "UNPARSABLE lexer line: %s\n", $0 > "/dev/stderr"; exit 3
    }
    kind = $0; sub(/:.*/, "", kind)
    line = $0; sub(/.*@/, "", line)
    lex  = $0; sub(/^[A-Z]+:/, "", lex); sub(/@[0-9]+$/, "", lex)
    if (kind == "KEYWORD") { printf "%s KEYWORD %s\n", line, lex; next }
    if (kind == "IDENT")   { printf "%s IDENT %s\n",   line, lex; next }
    if (kind == "STRING")  { printf "%s STR\n",        line; next }  # content golden-gated
    if (kind == "ERROR")   { printf "%s ERROR\n",      line; exit 0 } # recovery tail golden-gated
    if (kind == "EOF")     { printf "%s EOF\n",        line; next }
    if (kind == "INT")     { printf "%s INT %s\n", line, todec(lex); next }
    if (kind == "SYMBOL" || kind == "OP") { printf "%s PUNCT %s\n", line, lex; next }
    printf "UNMAPPED lexer KIND: %s\n", kind > "/dev/stderr"; exit 3
}
function todec(s,   i, c, n, d) {
    n = 0
    if (s ~ /^0[xX]/) {
        s = substr(s, 3)
        for (i = 1; i <= length(s); i++) {
            c = tolower(substr(s, i, 1)); d = index("0123456789abcdef", c) - 1
            if (d < 0) { printf "bad hex lexeme: %s\n", s > "/dev/stderr"; exit 3 }
            n = n * 16 + d
        }
    } else {
        for (i = 1; i <= length(s); i++) {
            d = index("0123456789", substr(s, i, 1)) - 1
            if (d < 0) { printf "bad int lexeme: %s\n", s > "/dev/stderr"; exit 3 }
            n = n * 10 + d
        }
    }
    return n
}
' "$TMP/lex" >"$TMP/lex.norm" 2>"$TMP/lex.norm.err"
lex_norm_rc=$?
if [ "$lex_norm_rc" -ne 0 ]; then
    echo "FAIL normalizer (lexer side) — a new token kind needs a mapping"
    sed 's/^/      /' "$TMP/lex.norm.err"
    exit 1
fi

# --- compare ----------------------------------------------------------------
if diff -u "$TMP/dump.norm" "$TMP/lex.norm" >"$TMP/diff"; then
    n=$(wc -l < "$TMP/dump.norm")
    echo "ok   lexer_tokens_parity ($n tokens: KEYWORD/IDENT/INT/PUNCT/STR/ERROR vs --dump-tokens)"
    exit 0
fi
echo "FAIL lexer_tokens_parity: the Astra-0 lexer diverges from the C lexer's token stream"
sed 's/^/      /' "$TMP/diff"
exit 1
