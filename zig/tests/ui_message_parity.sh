#!/usr/bin/env bash
# UI message parity (PRE_LLVM_AUDIT §1): every seed ui/ case must be
# rejected by BOTH compilers, and their FIRST diagnostic line must be
# byte-identical after dropping the seed's trailing summary lines.
#
#   ./zig/tests/ui_message_parity.sh            # gate (STRICT=1 default)
#   STRICT=0 ./zig/tests/ui_message_parity.sh   # report mode (exit 0)
#
# Why first line: the compilers recover differently after the first error
# (seed aborts the body and prints "aborting ... body", zig unwinds with
# "unexpected token in expression"), so line 2+ is a documented design
# divergence (PRE_LLVM_AUDIT §1.5). The first line is the diagnostic the
# user actually sees first, and since audit §1.2/§1.3 both sides emit
# `file:line:col: error: msg` there — byte-identical in 64/65 cases.
#
# Full-output differences are still counted and printed (msg_diff_full)
# so recovery drift stays visible in the report.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
SEED="$root/seed/astra-seed"
ZIG="$root/zig/zig-out/bin/astra-zig"

# No first-line divergence is accepted on purpose: audit §6.3 closed the last
# one (too_many_locals.astra — the seed's Emitter had no filename at all and
# zig's own loc carried no line; the seed now names the file from the module
# node's SrcLoc, so both sides print `file: error: too many locals (max 256)`).
KNOWN_FIRST_LINE=""

for bin in "$SEED" "$ZIG"; do
    if [ ! -x "$bin" ]; then
        echo "ui_message_parity: missing $bin (build seed with 'make -C seed debug'" \
             "and zig with 'zig build' first)" >&2
        exit 2
    fi
done

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

total=0
accept_fail=0
first_fail=0
known_hit=0
msg_full=0

for f in "$root"/seed/tests/conformance/ui/*.astra; do
    [ -f "$f" ] || continue
    total=$((total + 1))
    rel=$(basename "$f")

    "$SEED" "$f" >"$tmpdir/s.out" 2>"$tmpdir/s.err"
    src=$?
    "$ZIG" "$f" >"$tmpdir/z.out" 2>"$tmpdir/z.err"
    zrc=$?

    if [ "$src" -eq 0 ] || [ "$zrc" -eq 0 ]; then
        echo "ACCEPT $rel (seed rc=$src zig rc=$zrc)"
        accept_fail=$((accept_fail + 1))
        continue
    fi

    # Seed-only trailing summaries; everything else must match.
    cat "$tmpdir/s.err" "$tmpdir/s.out" 2>/dev/null \
        | grep -v -e '^error: type check failed with' \
                  -e '^error: parse failed$' \
                  -e '^error: code generation failed with' \
        >"$tmpdir/s.norm"
    cat "$tmpdir/z.err" "$tmpdir/z.out" 2>/dev/null >"$tmpdir/z.norm"

    sfirst=$(head -n 1 "$tmpdir/s.norm")
    zfirst=$(head -n 1 "$tmpdir/z.norm")
    if [ "$sfirst" != "$zfirst" ]; then
        case "$KNOWN_FIRST_LINE" in
            *" $rel "*)
                echo "KNOWN $rel (first line)"
                known_hit=$((known_hit + 1))
                ;;
            *)
                echo "MSG $rel (first line)"
                printf '    seed: %s\n    zig : %s\n' "$sfirst" "$zfirst"
                first_fail=$((first_fail + 1))
                ;;
        esac
    fi

    if ! cmp -s "$tmpdir/s.norm" "$tmpdir/z.norm"; then
        echo "FULL $rel (line 2+ differs; informational)"
        diff "$tmpdir/s.norm" "$tmpdir/z.norm" | sed 's/^/    /'
        msg_full=$((msg_full + 1))
    fi
done

echo "----"
echo "ui_message_parity: total=$total accept_fail=$accept_fail" \
     "first_fail=$first_fail known=$known_hit msg_diff_full=$msg_full"
if [ "${STRICT:-1}" = 1 ] && { [ "$accept_fail" -gt 0 ] || [ "$first_fail" -gt 0 ]; }; then
    exit 1
fi
exit 0
