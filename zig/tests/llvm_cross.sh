#!/usr/bin/env bash
# M5 cross-compilation gate (LLVM_BACKEND_PLAN.md §6 M5, §4.4): every parity
# fixture compiled for a foreign target with `--target=<triple>`, linked with
# the cross toolchain, and cross-run under qemu; stdout, stderr and the exit
# code must match the native zig VM byte-for-byte.
#
#   ./zig/tests/llvm_cross.sh                         # aarch64-linux-gnu (default)
#   ASTRA_CROSS_TRIPLE=... ASTRA_CROSS_CC=... ASTRA_QEMU=... ./zig/tests/llvm_cross.sh
#
# Defaults target aarch64: `gcc-aarch64-linux-gnu` for the cross toolchain and
# `qemu-aarch64-static -L /usr/aarch64-linux-gnu` to run the resulting binaries
# on the x86-64 host/CI runner. The reference is the native zig VM (which the
# seed jobs already tie to the seed VM), so a cross binary that diverges from
# the VM is a real codegen/ABI bug on that target, not a semantics question.
#
# Same skip discipline as llvm_parity.sh: a construct outside the backend's
# subset is *skipped* ("not supported by the LLVM backend"), never failed. The
# set of supported cases is target-independent, so a case that runs natively
# must also cross-run identically; a cross-only FAIL is the M5 gate tripping.
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
RUNTIME_SRC="$zigdir/src/llvm/runtime/astra_runtime_llvm.c"

# M5: the foreign target. aarch64 by default; the toolchain, emulator and
# sysroot derive from it but each is overridable.
TRIPLE="${ASTRA_CROSS_TRIPLE:-aarch64-linux-gnu}"
CROSS_CC="${ASTRA_CROSS_CC:-${TRIPLE}-gcc}"
QEMU="${ASTRA_QEMU:-qemu-${TRIPLE%%-*}-static}"
QEMU_SYSROOT="${ASTRA_QEMU_SYSROOT:-/usr/${TRIPLE}}"

die() { echo "llvm_cross: $*" >&2; exit 2; }

[ -x "$ASTRA_ZIG" ] || die "missing $ASTRA_ZIG (build with 'zig build -Dllvm')"
command -v "$CROSS_CC" >/dev/null 2>&1 || die "$CROSS_CC not found (install gcc-${TRIPLE%%-*}-linux-gnu)"
command -v "$QEMU" >/dev/null 2>&1 || die "$QEMU not found (install qemu-user-static)"

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

# Cross-compile the runtime TU once (thin TU over seed/src/codegen_runtime.h).
if ! "$CROSS_CC" -c -O2 -std=c11 -I"$root/seed/src" "$RUNTIME_SRC" -o "$work/runtime.o" 2>"$work/rt.err"; then
    echo "llvm_cross: cannot cross-compile the LLVM runtime TU for $TRIPLE"
    sed 's/^/    /' "$work/rt.err"
    exit 2
fi

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
    # (the seed's semantics), exactly like llvm_parity.sh.
    extra=""
    if grep -qE '^(import|from|use) ' "$f"; then
        extra="--single-file"
    fi

    # Reference: native zig VM (this is the same reference llvm_parity uses).
    "$ASTRA_ZIG" $extra "$f" >"$work/vm.out" 2>"$work/vm.err"
    vm_rc=$?

    # Cross route, step 1: emit an object for the foreign target.
    base=${f%.astra}
    if ! "$ASTRA_ZIG" --emit-obj --target="$TRIPLE" $extra "$f" >"$work/emit.out" 2>"$work/emit.err"; then
        if grep -q "not supported by the LLVM backend" "$work/emit.err"; then
            echo "skip $rel (not M0 scope)"
            skip=$((skip + 1))
            continue
        fi
        echo "FAIL $rel: --emit-obj --target failed"
        sed 's/^/    /' "$work/emit.err"
        fail=$((fail + 1))
        continue
    fi

    # Step 2: link the foreign object with the cross toolchain.
    if ! "$CROSS_CC" "$base.o" "$work/runtime.o" -o "$work/bin" -lm 2>"$work/link.err"; then
        echo "FAIL $rel: cross link failed"
        sed 's/^/    /' "$work/link.err"
        fail=$((fail + 1))
        continue
    fi

    # Step 3: cross-run under qemu and compare stdout/stderr/exit vs the VM.
    "$QEMU" -L "$QEMU_SYSROOT" "$work/bin" >"$work/cross.out" 2>"$work/cross.err"
    cross_rc=$?

    bad=0
    [ "$vm_rc" != "$cross_rc" ] && bad=1
    cmp -s "$work/vm.out" "$work/cross.out" || bad=1
    cmp -s "$work/vm.err" "$work/cross.err" || bad=1

    if [ "$bad" = 1 ]; then
        echo "FAIL $rel (rc vm=$vm_rc cross=$cross_rc)"
        diff "$work/vm.out" "$work/cross.out" | sed 's/^/    out: /'
        diff "$work/vm.err" "$work/cross.err" | sed 's/^/    err: /'
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
echo "llvm_cross($TRIPLE): total=$total ok=$((total - skip - fail)) skip=$skip fail=$fail"
[ "$fail" -eq 0 ]
