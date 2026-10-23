#!/usr/bin/env bash
# wasm32-wasi gate (LLVM_BACKEND_PLAN.md §6, §4.4): every parity fixture
# compiled for wasm32-wasi with `--target=wasm32-wasi`, linked with wasm-ld
# against wasi-libc, and run under Node's WASI; stdout, stderr and the exit
# code must match the native zig VM byte-for-byte.
#
#   ./zig/tests/llvm_wasm.sh                         # report (exit 1 on divergence)
#   ASTRA_LLVM_OPT=2 ./zig/tests/llvm_wasm.sh        # same gate through default<O2>+extras
#
# Toolchain knobs (each with a default):
#   ASTRA_WASM_LD       wasm-ld   (default: wasm-ld, wasm-ld-19, /usr/lib/llvm-19/bin/wasm-ld)
#   ASTRA_WASI_SYSROOT  sysroot   (default: /usr/lib/wasm32-wasi, /usr/share/wasi-sysroot)
#   ASTRA_WASM_NODE     node      (default: node; needs >= 22 for wasm Exception Handling)
#   ASTRA_WASM_CLANG    clang     (default: clang; compiles the runtime TU for wasm32)
#
# The runtime TU is compiled with `-mllvm -wasm-enable-sjlj`: wasi-libc's
# setjmp.h #errors without it, and Astra's error mechanism is
# setjmp/longjmp. That lowering needs an engine implementing the wasm
# Exception Handling proposal (Node >= 22 / V8 >= 12.4); an older engine
# traps on module load, which this gate surfaces as failures.
#
# Same skip discipline as llvm_parity.sh/llvm_cross.sh: a construct outside
# the backend's subset is *skipped* ("not supported by the LLVM backend"),
# never failed. ASTRA_LLVM_SAN is ignored here (no ASan runtime in this gate).
#
# The zig VM is the reference, exactly like llvm_parity.sh/llvm_cross.sh, so
# wasm == zig VM transitively implies wasm == seed semantics.
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
RUNTIME_SRC="$zigdir/src/llvm/runtime/astra_runtime_llvm.c"
WASI_RUNNER="$root/demo/wasi_run.mjs"

TRIPLE="wasm32-wasi"

die() { echo "llvm_wasm: $*" >&2; exit 2; }

[ -x "$ASTRA_ZIG" ] || die "missing $ASTRA_ZIG (build with 'zig build -Dllvm')"
[ -f "$WASI_RUNNER" ] || die "missing $WASI_RUNNER"

# --- toolchain probe ---------------------------------------------------------
# wasm-ld: env override, PATH, then the LLVM install dirs (same range
# build.zig probes for llvm-config).
WASM_LD="${ASTRA_WASM_LD:-}"
if [ -z "$WASM_LD" ]; then
    for c in wasm-ld wasm-ld-19 /usr/lib/llvm-19/bin/wasm-ld; do
        if command -v "$c" >/dev/null 2>&1; then WASM_LD=$c; break; fi
    done
fi
[ -n "$WASM_LD" ] || die "wasm-ld not found (install lld-19 or set ASTRA_WASM_LD)"

# wasi-libc sysroot: env override, then the common Debian/upstream layouts.
SYSROOT="${ASTRA_WASI_SYSROOT:-}"
if [ -z "$SYSROOT" ]; then
    for d in /usr/lib/wasm32-wasi /usr/share/wasi-sysroot /usr/wasm32-wasi; do
        if [ -f "$d/libc.a" ]; then SYSROOT=$d; break; fi
        # upstream wasi-sysroot keeps the archives under lib/wasm32-wasi.
        if [ -f "$d/lib/wasm32-wasi/libc.a" ]; then SYSROOT="$d/lib/wasm32-wasi"; break; fi
    done
fi
[ -n "$SYSROOT" ] && [ -f "$SYSROOT/libc.a" ] ||
    die "wasi-libc sysroot not found (install wasi-libc or set ASTRA_WASI_SYSROOT)"
[ -f "$SYSROOT/crt1.o" ] || die "$SYSROOT has no crt1.o (need the command crt for _start)"

# node with WASI: the runner needs wasm Exception Handling (Node >= 22).
NODE="${ASTRA_WASM_NODE:-node}"
command -v "$NODE" >/dev/null 2>&1 || die "$NODE not found (install node >= 22 or set ASTRA_WASM_NODE)"
NODE_MAJOR=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
case "$NODE_MAJOR" in (''|*[!0-9]*) NODE_MAJOR=0;; esac
[ "$NODE_MAJOR" -ge 22 ] || die "$NODE is v$NODE_MAJOR; WASI + wasm Exception Handling needs >= 22"

# clang compiles the runtime TU for wasm32 (the emitted object references the
# astra_llvm_* entry points).
CLANG="${ASTRA_WASM_CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || die "$CLANG not found (install clang or set ASTRA_WASM_CLANG)"

echo "llvm_wasm: wasm-ld=$WASM_LD sysroot=$SYSROOT node=$("$NODE" --version)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fail fast if the binary lacks the LLVM backend (same probe as llvm_parity).
"$ASTRA_ZIG" --emit-llvm-stdout "$zigdir/tests/llvm/fib.astra" >/dev/null 2>"$work/probe.err"
if [ $? = 2 ] && grep -q "requires the compiler to be built with" "$work/probe.err"; then
    cat "$work/probe.err" >&2
    die "build the compiler with 'zig build -Dllvm' first"
fi

# Snapshot the inputs (emitting writes a .o next to each .astra).
mkdir -p "$work/conf" "$work/llvm" "$work/cg"
cp -r "$root/seed/tests/conformance/." "$work/conf/"
cp -r "$zigdir/tests/llvm/." "$work/llvm/"
cp "$root"/seed/tests/codegen/*.astra "$work/cg/" 2>/dev/null || true

# Compile the runtime TU once for wasm32-wasi. `-mllvm -wasm-enable-sjlj` is
# mandatory: wasi-libc's setjmp.h refuses to compile without it, and Astra's
# error path is setjmp/longjmp (exercised by every runtime-error fixture).
if ! "$CLANG" --target=wasm32-wasi -c -O2 -std=c11 -mllvm -wasm-enable-sjlj \
        -I"$root/seed/src" "$RUNTIME_SRC" -o "$work/runtime.o" 2>"$work/rt.err"; then
    echo "llvm_wasm: cannot compile the LLVM runtime TU for $TRIPLE"
    sed 's/^/    /' "$work/rt.err"
    exit 2
fi

# Nivel de optimización del módulo antes de emitir el objeto (M4): 0 (default)
# o 1..3 para el pipeline del new PM. CI corre el gate sin y con ASTRA_LLVM_OPT=2.
OPT="${ASTRA_LLVM_OPT:-0}"
OPT_ARGS=""
if [ "$OPT" != 0 ]; then OPT_ARGS="--opt-level=$OPT"; fi

total=0
skip=0
fail=0

while IFS= read -r f; do
    case "$f" in
        "$work/conf"/*) rel=${f#"$work/conf/"} ;;
        "$work/cg"/*) rel="codegen/${f#"$work/cg/"}" ;;
        *) rel="llvm/${f#"$work/llvm/"}" ;;
    esac
    total=$((total + 1))

    # Module fixtures: the emitter is single-file, so run them --single-file
    # (the seed's semantics), exactly like llvm_parity.sh/llvm_cross.sh.
    extra=""
    if grep -qE '^(import|from|use) ' "$f"; then
        extra="--single-file"
    fi

    # Reference: native zig VM (the same reference the other gates use).
    "$ASTRA_ZIG" $extra "$f" >"$work/vm.out" 2>"$work/vm.err"
    vm_rc=$?

    # wasm route, step 1: emit a wasm32 object (TargetMachineEmitToFile).
    base=${f%.astra}
    if ! "$ASTRA_ZIG" --emit-obj --target="$TRIPLE" $extra $OPT_ARGS "$f" \
            >"$work/emit.out" 2>"$work/emit.err"; then
        if grep -q "not supported by the LLVM backend" "$work/emit.err"; then
            echo "skip $rel (not M0 scope)"
            skip=$((skip + 1))
            continue
        fi
        echo "FAIL $rel: --emit-obj --target=$TRIPLE failed"
        sed 's/^/    /' "$work/emit.err"
        fail=$((fail + 1))
        continue
    fi

    # Step 2: link with wasm-ld (crt1-command.o provides _start, wasi-libc
    # the libc the runtime TU calls).
    if ! "$WASM_LD" "$SYSROOT/crt1.o" "$base.o" "$work/runtime.o" \
            -L"$SYSROOT" -lc -o "$work/bin.wasm" 2>"$work/link.err"; then
        echo "FAIL $rel: wasm link failed"
        sed 's/^/    /' "$work/link.err"
        fail=$((fail + 1))
        continue
    fi

    # Step 3: run under Node WASI and compare stdout/stderr/exit vs the VM.
    # --no-warnings keeps Node's "WASI is an experimental feature" note off
    # stderr (the comparison is byte-for-byte).
    "$NODE" --no-warnings "$WASI_RUNNER" "$work/bin.wasm" \
        >"$work/wasm.out" 2>"$work/wasm.err"
    wasm_rc=$?

    bad=0
    [ "$vm_rc" != "$wasm_rc" ] && bad=1
    cmp -s "$work/vm.out" "$work/wasm.out" || bad=1
    cmp -s "$work/vm.err" "$work/wasm.err" || bad=1

    if [ "$bad" = 1 ]; then
        echo "FAIL $rel (rc vm=$vm_rc wasm=$wasm_rc)"
        diff "$work/vm.out" "$work/wasm.out" | sed 's/^/    out: /'
        diff "$work/vm.err" "$work/wasm.err" | sed 's/^/    err: /'
        fail=$((fail + 1))
    else
        echo "ok   $rel"
    fi
done < <(
    find "$work/conf" -name '*.astra' ! -path '*/ui/*' | sort
    find "$work/llvm" -name '*.astra' | sort
    find "$work/cg" -name '*.astra' | sort
)

echo "----"
echo "llvm_wasm: total=$total ok=$((total - skip - fail)) skip=$skip fail=$fail opt=$OPT"
[ "$fail" -eq 0 ]
