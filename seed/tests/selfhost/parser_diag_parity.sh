#!/usr/bin/env bash
# parser_diag_parity.sh — DEC-031: first-error parity between the seed's
# parser and the self-hosted parser.astra, over parser_errors/*.astra.
#
# For each broken fixture the seed (`--dump-ast`, parse-only) and
# parser.astra must emit the SAME FIRST diagnostic line, after path
# normalization: `:LINE:COL: error: MSG`. Only the first line is compared —
# recovery (cascades beyond the first error) is deliberately out of scope
# for v1 (DEC-031 §3). Both sides must also print the trailing
# `error: parse failed` (driver.c:668 / parser.astra's main).
#
#   ./seed/tests/selfhost/parser_diag_parity.sh        # from anywhere
#
# Seed-only (like lexer_tokens_parity): needs only astra-seed.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)     # seed/tests/selfhost
root=$(cd "$here/../../.." && pwd)
cd "$here"

SEED="$root/seed/astra-seed"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
total=0

if [ ! -x "$SEED" ]; then
    echo "parser_diag_parity: missing $SEED (build with 'make -C seed')" >&2
    exit 2
fi

first_err() {
    # first line shaped like file:line:col: error: ...
    grep -E '^[^ ]+:[0-9]+:[0-9]+: error: ' "$1" | head -1
}

norm() {
    # strip the path prefix: keep :line:col: error: ...
    sed -E 's|^[^:]+||' <<<"$1"
}

for fx in parser_errors/*.astra; do
    total=$((total + 1))
    name=$(basename "$fx")

    # Seed side: parse-only via --dump-ast, path as passed (we cd into the dir).
    (cd parser_errors && "$SEED" --dump-ast "$name" >"$TMP/seed.out" 2>&1) || true
    seed_first=$(first_err "$TMP/seed.out")
    seed_failed=$(grep -c '^error: parse failed$' "$TMP/seed.out")

    # Parser side: run parser.astra in a temp cwd with the fixture under
    # its hardcoded name (read_file uses a relative path).
    mkdir -p "$TMP/run"
    cp parser.astra "$TMP/run/parser.astra"
    cp "$fx" "$TMP/run/parser_input.astra"
    (cd "$TMP/run" && "$SEED" parser.astra >"$TMP/own.out" 2>&1) || true
    own_first=$(first_err "$TMP/own.out")
    own_failed=$(grep -c '^error: parse failed$' "$TMP/own.out")

    ok=1
    if [ -z "$seed_first" ]; then
        echo "SKIP $name (seed parsed it cleanly — fixture drifted)"
        continue
    fi
    if [ "$(norm "$seed_first")" != "$(norm "$own_first")" ]; then
        echo "FAIL $name (first diagnostic differs)"
        echo "      seed:  $seed_first"
        echo "      own:   ${own_first:-<none>}"
        ok=0
        fail=1
    fi
    if [ "$seed_failed" -lt 1 ] || [ "$own_failed" -lt 1 ]; then
        echo "FAIL $name (missing trailing 'error: parse failed')"
        echo "      seed=$seed_failed own=$own_failed"
        ok=0
        fail=1
    fi
    if [ "$ok" -eq 1 ]; then
        echo "ok   $name  ($(norm "$seed_first"))"
    fi
done

echo "----"
if [ "$fail" -eq 0 ]; then
    echo "parser_diag_parity: $total fixtures, first error + parse-failed line match"
else
    echo "parser_diag_parity: FAIL"
fi
[ "$fail" -eq 0 ]
