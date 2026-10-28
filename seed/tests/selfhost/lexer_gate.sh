#!/usr/bin/env bash
# Self-hosting lexer gate (research/028 PR3a §4.3, DEC-016): lexer.astra is a
# mini lexer WRITTEN IN ASTRA-0 that reads the sibling fixture lexer_input.astra
# (read_file uses a RELATIVE path, so this script fixes the cwd itself — every
# gate runs with a different one: seed/, zig/, repo root, research/028 §2.4).
# Each route that can run here must reproduce the committed golden
# lexer.expected byte-for-byte; missing tools are skipped, not failed.
#
#   ./seed/tests/selfhost/lexer_gate.sh        # from anywhere
#
# The strong gate — compare the Astra-0 token stream against
# `astra-seed --dump-tokens` — is PR3b: the formats differ (research/028 §4.3).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)     # seed/tests/selfhost
root=$(cd "$here/../../.." && pwd)
cd "$here"                              # ← cwd fijo: read_file usa path relativo

SEED="$root/seed/astra-seed"
ZIG="$root/zig/zig-out/bin/astra-zig"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$here/lexer.c"' EXIT

fail=0

# One route: run it, require exit 0, diff stdout against the golden.
route() {
    local name="$1"; shift
    if ! "$@" >"$TMP/actual" 2>"$TMP/err"; then
        echo "FAIL $name (non-zero exit)"
        sed 's/^/      /' "$TMP/err"
        fail=1
        return
    fi
    if diff -u lexer.expected "$TMP/actual" >"$TMP/diff"; then
        echo "ok   $name"
    else
        echo "FAIL $name (output differs from lexer.expected)"
        sed 's/^/      /' "$TMP/diff"
        fail=1
    fi
}

if [ ! -x "$SEED" ]; then
    echo "lexer_gate: missing $SEED (build with 'make -C seed')" >&2
    exit 2
fi

# 1) seed VM.
route "seed VM" "$SEED" lexer.astra

# 2) C backend round-trip (--emit-c → gcc → run): same token stream out of C.
if command -v gcc >/dev/null 2>&1; then
    if "$SEED" --emit-c lexer.astra >/dev/null 2>&1; then
        if gcc -Wall -Wextra -I"$root/seed/src" -o "$TMP/cbin" lexer.c 2>"$TMP/gcc.err" \
           && [ ! -s "$TMP/gcc.err" ]; then
            route "C backend (--emit-c + gcc)" "$TMP/cbin"
        else
            echo "FAIL C backend: gcc rejected the generated C"
            sed 's/^/      /' "$TMP/gcc.err"
            fail=1
        fi
    else
        echo "FAIL C backend: --emit-c failed"
        fail=1
    fi
else
    echo "skip C backend (gcc not found)"
fi

# 3) zig VM and 4) LLVM, when the zig compiler is built.
if [ -x "$ZIG" ]; then
    route "zig VM" "$ZIG" lexer.astra

    "$ZIG" --jit lexer.astra >"$TMP/actual" 2>"$TMP/err"
    jit_rc=$?
    if grep -q "require the compiler to be built with" "$TMP/err"; then
        echo "skip LLVM (compiler built without -Dllvm)"
    elif [ "$jit_rc" -ne 0 ]; then
        echo "FAIL LLVM (--jit) (non-zero exit)"
        sed 's/^/      /' "$TMP/err"
        fail=1
    elif diff -u lexer.expected "$TMP/actual" >"$TMP/diff"; then
        echo "ok   LLVM (--jit)"
    else
        echo "FAIL LLVM (--jit) (output differs from lexer.expected)"
        sed 's/^/      /' "$TMP/diff"
        fail=1
    fi
else
    echo "skip zig VM / LLVM (zig compiler not built)"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
    echo "lexer_gate: every route matches lexer.expected"
else
    echo "lexer_gate: FAIL"
fi
[ "$fail" -eq 0 ]
