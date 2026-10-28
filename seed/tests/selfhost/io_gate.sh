#!/usr/bin/env bash
# Positive read_file gate (research/028 PR2 §3, modeled on §4.3's lexer_gate).
#
# read_file is the ONE builtin that needs a real file, so its positive case
# lives OUTSIDE tests/conformance/ on purpose: every gate runs with a
# different cwd (seed/, zig/, repo root — research/028 §2.4) and the wasm
# route has no preopens, so a conformance case reading a fixture would fail
# on the execution path, not on the language. This script fixes the directory
# itself (cd "$here", like §4.3) and compares each route byte-for-byte
# against the committed golden read.expected. Every route that can run here
# earns a line; missing tools are skipped, not failed.
#
#   ./seed/tests/selfhost/io_gate.sh        # from anywhere
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)     # seed/tests/selfhost
root=$(cd "$here/../../.." && pwd)
cd "$here"                              # ← cwd fijo: read_file usa path relativo

SEED="$root/seed/astra-seed"
ZIG="$root/zig/zig-out/bin/astra-zig"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$here/read_positive.c" "$here/read_line_positive.c"' EXIT

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
    if diff -u read.expected "$TMP/actual" >"$TMP/diff"; then
        echo "ok   $name"
    else
        echo "FAIL $name (output differs from read.expected)"
        sed 's/^/      /' "$TMP/diff"
        fail=1
    fi
}

if [ ! -x "$SEED" ]; then
    echo "io_gate: missing $SEED (build with 'make -C seed')" >&2
    exit 2
fi

# 1) seed VM.
route "seed VM" "$SEED" read_positive.astra

# 2) C backend round-trip (--emit-c → gcc → run): astra_builtin_read_file.
if command -v gcc >/dev/null 2>&1; then
    if "$SEED" --emit-c read_positive.astra >/dev/null 2>&1; then
        if gcc -Wall -Wextra -I"$root/seed/src" -o "$TMP/cbin" read_positive.c 2>"$TMP/gcc.err" \
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
    route "zig VM" "$ZIG" read_positive.astra

    "$ZIG" --jit read_positive.astra >"$TMP/actual" 2>"$TMP/err"
    jit_rc=$?
    if grep -q "require the compiler to be built with" "$TMP/err"; then
        echo "skip LLVM (compiler built without -Dllvm)"
    elif [ "$jit_rc" -ne 0 ]; then
        echo "FAIL LLVM (--jit) (non-zero exit)"
        sed 's/^/      /' "$TMP/err"
        fail=1
    elif diff -u read.expected "$TMP/actual" >"$TMP/diff"; then
        echo "ok   LLVM (--jit)"
    else
        echo "FAIL LLVM (--jit) (output differs from read.expected)"
        sed 's/^/      /' "$TMP/diff"
        fail=1
    fi
else
    echo "skip zig VM / LLVM (zig compiler not built)"
fi

# ---------------------------------------------------------------------------
# read_line stage (research/028 M3, DEC-020): the one builtin that reads stdin.
# Its positive case lives here beside read_file's, because it needs the same
# two things read_file does — a fixed cwd and a committed fixture — plus stdin
# redirected from stdin_lines.txt (conformance has no stdin to give: there the
# EOF-without-data case read_line_eof_error.astra is the deterministic pin).
# Every route that runs here earns a line; the EOF error itself is pinned in
# conformance, so this stage only checks the happy path byte-for-byte.
# ---------------------------------------------------------------------------
RL_GOLDEN="read_line.expected"
RL_PROG="read_line_positive.astra"
RL_FIXTURE="stdin_lines.txt"

# One route with stdin redirected: require exit 0, diff stdout against golden.
rl_route() {
    local name="$1"; shift
    if ! "$@" <"$RL_FIXTURE" >"$TMP/actual" 2>"$TMP/err"; then
        echo "FAIL read_line $name (non-zero exit)"
        sed 's/^/      /' "$TMP/err"
        fail=1
        return
    fi
    if diff -u "$RL_GOLDEN" "$TMP/actual" >"$TMP/diff"; then
        echo "ok   read_line $name"
    else
        echo "FAIL read_line $name (output differs from $RL_GOLDEN)"
        sed 's/^/      /' "$TMP/diff"
        fail=1
    fi
}

rl_route "seed VM" "$SEED" "$RL_PROG"

if command -v gcc >/dev/null 2>&1; then
    if "$SEED" --emit-c "$RL_PROG" >/dev/null 2>&1; then
        if gcc -Wall -Wextra -I"$root/seed/src" -o "$TMP/rlcbin" read_line_positive.c 2>"$TMP/gcc.err" \
           && [ ! -s "$TMP/gcc.err" ]; then
            rl_route "C backend (--emit-c + gcc)" "$TMP/rlcbin"
        else
            echo "FAIL read_line C backend: gcc rejected the generated C"
            sed 's/^/      /' "$TMP/gcc.err"
            fail=1
        fi
    else
        echo "FAIL read_line C backend: --emit-c failed"
        fail=1
    fi
else
    echo "skip read_line C backend (gcc not found)"
fi

if [ -x "$ZIG" ]; then
    rl_route "zig VM" "$ZIG" "$RL_PROG"

    if "$ZIG" --jit "$RL_PROG" <"$RL_FIXTURE" >"$TMP/actual" 2>"$TMP/err"; then
        if diff -u "$RL_GOLDEN" "$TMP/actual" >"$TMP/diff"; then
            echo "ok   read_line LLVM (--jit)"
        else
            echo "FAIL read_line LLVM (--jit) (output differs from $RL_GOLDEN)"
            sed 's/^/      /' "$TMP/diff"
            fail=1
        fi
    elif grep -q "require the compiler to be built with" "$TMP/err"; then
        echo "skip read_line LLVM (compiler built without -Dllvm)"
    else
        echo "FAIL read_line LLVM (--jit) (non-zero exit)"
        sed 's/^/      /' "$TMP/err"
        fail=1
    fi
else
    echo "skip read_line zig VM / LLVM (zig compiler not built)"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
    echo "io_gate: every route matches read.expected and read_line.expected"
else
    echo "io_gate: FAIL"
fi
[ "$fail" -eq 0 ]
