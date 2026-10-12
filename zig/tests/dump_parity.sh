#!/usr/bin/env bash
# Dump-parity gate (PHASE2 §4 #6): --dump-tokens and --dump-ast must be
# byte-for-byte identical between the seed reference and astra-zig.
#
#   ./zig/tests/dump_parity.sh            # from the repo root
#   SHOW_DIFF=1 ./zig/tests/dump_parity.sh
#
# Sources swept: every non-UI seed conformance file, every C-backend fixture,
# and the parse-only probes in zig/tests/dump_probes (named payload fields,
# %g float forms, match guards, module forms — cases the suite does not run).
# Both compilers must exit 0 on every file: the seed dumps a partial AST with
# rc=0 on parse errors while zig exits 1 (accepted difference, out of scope),
# so a parse failure on either side fails the gate instead of being skipped.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
SEED="$root/seed/astra-seed"
ZIG="$root/zig/zig-out/bin/astra-zig"

for bin in "$SEED" "$ZIG"; do
    if [ ! -x "$bin" ]; then
        echo "dump_parity: missing $bin (build seed with 'make -C seed debug'" \
             "and zig with 'zig build' first)" >&2
        exit 2
    fi
done

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

total=0
fail=0

check() {
    local f=$1
    total=$((total + 1))
    local ok=1
    "$SEED" --dump-tokens "$f" >"$tmpdir/s.tok" 2>"$tmpdir/s.tok.err" || ok=0
    "$ZIG"  --dump-tokens "$f" >"$tmpdir/z.tok" 2>"$tmpdir/z.tok.err" || ok=0
    cmp -s "$tmpdir/s.tok" "$tmpdir/z.tok" || ok=0
    "$SEED" --dump-ast "$f" >"$tmpdir/s.ast" 2>"$tmpdir/s.ast.err" || ok=0
    "$ZIG"  --dump-ast "$f" >"$tmpdir/z.ast" 2>"$tmpdir/z.ast.err" || ok=0
    cmp -s "$tmpdir/s.ast" "$tmpdir/z.ast" || ok=0
    if [ "$ok" -ne 1 ]; then
        fail=$((fail + 1))
        echo "DIVERGE: $f"
        if [ "${SHOW_DIFF:-0}" = 1 ]; then
            diff -u "$tmpdir/s.tok" "$tmpdir/z.tok" | head -20
            diff -u "$tmpdir/s.ast" "$tmpdir/z.ast" | head -40
        fi
    fi
    return 0
}

while IFS= read -r f; do
    check "$f"
done <<EOF
$(find "$root/seed/tests/conformance" -name '*.astra' ! -path '*/ui/*' | sort)
$(find "$root/seed/tests/codegen" -name '*.astra' | sort)
$(find "$here/dump_probes" -name '*.astra' | sort)
EOF

echo "dump_parity: $total files, $fail divergent"
[ "$fail" -eq 0 ]
