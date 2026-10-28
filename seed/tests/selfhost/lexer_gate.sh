#!/usr/bin/env bash
# Self-hosting lexer gate (research/028 PR3a §4.3, DEC-016; rutas LLVM/cross/
# wasm y gate fuerte añadidos en PR3b, DEC-017): lexer.astra is a mini lexer
# WRITTEN IN ASTRA-0 that reads the sibling fixture lexer_input.astra
# (read_file uses a RELATIVE path, so this script fixes the cwd itself — every
# gate runs with a different one: seed/, zig/, repo root, research/028 §2.4).
# Each route that can run here must reproduce the committed golden
# lexer.expected byte-for-byte; missing tools are skipped, not failed.
#
#   ./seed/tests/selfhost/lexer_gate.sh        # from anywhere
#
# Routes: seed VM · C backend (--emit-c+gcc) · zig VM · LLVM --jit ·
# LLVM --emit-obj+link (native production route) · LLVM cross aarch64 under
# qemu · LLVM wasm32-wasi under Node WASI. The last three need a zig built
# with -Dllvm; cross/wasm additionally need their toolchains and skip cleanly
# without them.
#
# The strong gate — compare the Astra-0 token stream against
# `astra-seed --dump-tokens` — is lexer_tokens_parity.sh (PR3b, DEC-017); it
# runs at the END of this script, so one invocation covers golden + routes +
# stream parity.
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

    # 5) LLVM native production route: --emit-obj -> link the runtime TU ->
    #    run (the llvm_parity.sh recipe; since M2.e the object comes straight
    #    from TargetMachineEmitToFile, no llc). The .o lands NEXT TO the
    #    .astra, so the source is compiled from a copy in $TMP — harmless:
    #    read_file resolves against the CWD (fixed to $here), not against the
    #    source location.
    CC_BIN="${CC:-cc}"
    if ! command -v "$CC_BIN" >/dev/null 2>&1; then
        echo "skip LLVM (--emit-obj + link) ($CC_BIN not found)"
    elif ! cp lexer.astra "$TMP/obj_src.astra" \
       || ! "$ZIG" --emit-obj "$TMP/obj_src.astra" >/dev/null 2>"$TMP/emit.err"; then
        if grep -q "require the compiler to be built with" "$TMP/emit.err"; then
            echo "skip LLVM (--emit-obj + link) (compiler built without -Dllvm)"
        else
            echo "FAIL LLVM (--emit-obj): --emit-obj failed"
            sed 's/^/      /' "$TMP/emit.err"
            fail=1
        fi
    elif ! "$CC_BIN" -c -O2 -std=c11 -I"$root/seed/src" \
            "$root/zig/src/llvm/runtime/astra_runtime_llvm.c" -o "$TMP/runtime.o" 2>"$TMP/rt.err"; then
        echo "FAIL LLVM (--emit-obj): cannot compile the runtime TU"
        sed 's/^/      /' "$TMP/rt.err"
        fail=1
    elif ! "$CC_BIN" "$TMP/obj_src.o" "$TMP/runtime.o" -o "$TMP/objbin" -lm 2>"$TMP/link.err"; then
        echo "FAIL LLVM (--emit-obj): link failed"
        sed 's/^/      /' "$TMP/link.err"
        fail=1
    else
        route "LLVM (--emit-obj + link)" "$TMP/objbin"
    fi

    # 6) LLVM cross route (the llvm_cross.sh recipe): a foreign object linked
    #    with the cross toolchain and cross-run under qemu-user. A real
    #    foreign-ABI check of the production route; skips without the
    #    toolchain (CI's llvm-cross job has it, the llvm job does not).
    TRIPLE="${ASTRA_CROSS_TRIPLE:-aarch64-linux-gnu}"
    CROSS_CC="${ASTRA_CROSS_CC:-${TRIPLE}-gcc}"
    QEMU="${ASTRA_QEMU:-qemu-${TRIPLE%%-*}-static}"
    QEMU_SYSROOT="${ASTRA_QEMU_SYSROOT:-/usr/${TRIPLE}}"
    if ! command -v "$CROSS_CC" >/dev/null 2>&1 || ! command -v "$QEMU" >/dev/null 2>&1; then
        echo "skip LLVM cross $TRIPLE ($CROSS_CC / $QEMU not found)"
    elif ! cp lexer.astra "$TMP/x_src.astra" \
       || ! "$ZIG" --emit-obj --target="$TRIPLE" "$TMP/x_src.astra" >/dev/null 2>"$TMP/xemit.err"; then
        if grep -q "require the compiler to be built with" "$TMP/xemit.err"; then
            echo "skip LLVM cross $TRIPLE (compiler built without -Dllvm)"
        else
            echo "FAIL LLVM cross $TRIPLE: --emit-obj --target failed"
            sed 's/^/      /' "$TMP/xemit.err"
            fail=1
        fi
    elif ! "$CROSS_CC" -c -O2 -std=c11 -I"$root/seed/src" \
            "$root/zig/src/llvm/runtime/astra_runtime_llvm.c" -o "$TMP/runtime_x.o" 2>"$TMP/xrt.err"; then
        echo "FAIL LLVM cross $TRIPLE: cannot cross-compile the runtime TU"
        sed 's/^/      /' "$TMP/xrt.err"
        fail=1
    elif ! "$CROSS_CC" "$TMP/x_src.o" "$TMP/runtime_x.o" -o "$TMP/xbin" -lm 2>"$TMP/xlink.err"; then
        echo "FAIL LLVM cross $TRIPLE: cross link failed"
        sed 's/^/      /' "$TMP/xlink.err"
        fail=1
    else
        route "LLVM cross $TRIPLE (--emit-obj --target + qemu)" \
              "$QEMU" -L "$QEMU_SYSROOT" "$TMP/xbin"
    fi

    # 7) LLVM wasm route (the llvm_wasm.sh recipe): wasm32-wasi object +
    #    wasm-ld/wasi-libc + Node WASI (demo/wasi_run.mjs — PR2 already gave
    #    it preopens {"/": cwd}, so read_file works; the toolchain is the
    #    only extra requirement). Skips without it.
    WASM_LD="${ASTRA_WASM_LD:-}"
    if [ -z "$WASM_LD" ]; then
        for c in wasm-ld wasm-ld-19 /usr/lib/llvm-19/bin/wasm-ld; do
            if command -v "$c" >/dev/null 2>&1; then WASM_LD=$c; break; fi
        done
    fi
    SYSROOT="${ASTRA_WASI_SYSROOT:-}"
    if [ -z "$SYSROOT" ]; then
        for d in /usr/lib/wasm32-wasi /usr/share/wasi-sysroot /usr/wasm32-wasi; do
            if [ -f "$d/libc.a" ]; then SYSROOT=$d; break; fi
            if [ -f "$d/lib/wasm32-wasi/libc.a" ]; then SYSROOT="$d/lib/wasm32-wasi"; break; fi
        done
    fi
    # wasi headers, derived from the sysroot (…/lib/<triple> -> …/include/<triple>,
    # the layout llvm_wasm.sh uses).
    WASI_INCLUDE=""
    if [ -n "$SYSROOT" ]; then
        WASI_INCLUDE="$(cd "$SYSROOT/../.." 2>/dev/null && pwd)/include/$(basename "$SYSROOT")"
    fi
    NODE="${ASTRA_WASM_NODE:-node}"
    WASM_CLANG="${ASTRA_WASM_CLANG:-clang}"
    NODE_MAJOR=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
    case "$NODE_MAJOR" in (''|*[!0-9]*) NODE_MAJOR=0;; esac
    if [ -z "$WASM_LD" ] || [ -z "$SYSROOT" ] || [ ! -f "$SYSROOT/crt1.o" ] \
       || [ ! -d "$WASI_INCLUDE" ] \
       || ! command -v "$WASM_CLANG" >/dev/null 2>&1 \
       || ! command -v "$NODE" >/dev/null 2>&1 || [ "$NODE_MAJOR" -lt 22 ]; then
        echo "skip LLVM wasm32-wasi (wasm-ld / wasi sysroot / $WASM_CLANG / node>=22 not all found)"
    elif ! cp lexer.astra "$TMP/w_src.astra" \
       || ! "$ZIG" --emit-obj --target=wasm32-wasi "$TMP/w_src.astra" >/dev/null 2>"$TMP/wemit.err"; then
        if grep -q "require the compiler to be built with" "$TMP/wemit.err"; then
            echo "skip LLVM wasm32-wasi (compiler built without -Dllvm)"
        else
            echo "FAIL LLVM wasm32-wasi: --emit-obj --target failed"
            sed 's/^/      /' "$TMP/wemit.err"
            fail=1
        fi
    elif ! "$WASM_CLANG" --target=wasm32-wasi -c -O2 -std=c11 -mllvm -wasm-enable-sjlj \
            -I"$WASI_INCLUDE" -I"$root/seed/src" \
            "$root/zig/src/llvm/runtime/astra_runtime_llvm.c" -o "$TMP/runtime_w.o" 2>"$TMP/wrt.err"; then
        echo "FAIL LLVM wasm32-wasi: cannot compile the runtime TU for wasm32"
        sed 's/^/      /' "$TMP/wrt.err"
        echo "      hint: this sysroot's <setjmp.h> may be unusable — see llvm_wasm.sh"
        fail=1
    elif ! "$WASM_LD" "$SYSROOT/crt1.o" "$TMP/w_src.o" "$TMP/runtime_w.o" \
            -L"$SYSROOT" -lc -o "$TMP/wbin.wasm" 2>"$TMP/wlink.err"; then
        echo "FAIL LLVM wasm32-wasi: wasm link failed"
        sed 's/^/      /' "$TMP/wlink.err"
        fail=1
    else
        route "LLVM wasm32-wasi (--emit-obj --target + Node WASI)" \
              "$NODE" --no-warnings "$root/demo/wasi_run.mjs" "$TMP/wbin.wasm"
    fi
else
    echo "skip zig VM / LLVM routes (zig compiler not built)"
fi

# Strong gate (PR3b, DEC-017): the Astra-0 token stream vs the C lexer's
# --dump-tokens, both normalized to one common kind space. Seed-only
# dependency, so it can never skip; it prints its own ok/FAIL lines.
if ! "$here/lexer_tokens_parity.sh"; then
    fail=1
fi

echo "----"
if [ "$fail" -eq 0 ]; then
    echo "lexer_gate: every route matches lexer.expected; token-stream parity holds"
else
    echo "lexer_gate: FAIL"
fi
[ "$fail" -eq 0 ]
