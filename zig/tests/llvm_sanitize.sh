#!/usr/bin/env bash
# LLVM backend sanitizers (LLVM_BACKEND_PLAN.md §6 M4.d):
#
#   1. `--sanitize=address` instruments the module (checks in the IR, ASan
#      constructor) and the object (undefined `__asan_*` symbols).
#   2. The object cannot be linked without `-fsanitize=address`: instrumenta-
#      tion is real, not a silently ignored flag.
#   3. The ASan binary reproduces the VM's stdout byte-for-byte.
#   4. Negative control: a heap-buffer-overflow compiled with the same flags
#      aborts with an AddressSanitizer report — so a green suite means the
#      sanitizer is actually able to catch a violation.
#   5. The whole LLVM parity suite (conformance + codegen + llvm fixtures) runs
#      under ASan via ASTRA_LLVM_SAN, runtime TU included, both without and with
#      the -O2 pipeline (instrumentation runs before optimization, as in clang).
#
#   ./zig/tests/llvm_sanitize.sh     # exit 1 on any failure
#
# Requires the compiler built with -Dllvm and ${CC:-cc} with libasan (default
# toolchain on Linux). Leak detection stays off: v1 values are not freed by
# design (like the VM's arena), so LSan reports are out of scope here and would
# only mask the memory-safety gate.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
RUNTIME_SRC="$zigdir/src/llvm/runtime/astra_runtime_llvm.c"
CC_BIN="${CC:-cc}"

die() { echo "llvm_sanitize: $*" >&2; exit 2; }
fail() { echo "llvm_sanitize: FAIL: $*" >&2; exit 1; }

[ -x "$ASTRA_ZIG" ] || die "missing $ASTRA_ZIG (build with 'zig build -Dllvm')"
command -v "$CC_BIN" >/dev/null 2>&1 || die "$CC_BIN not found"
command -v nm >/dev/null 2>&1 || die "nm not found (binutils)"

# Same probe as llvm_parity.sh: a binary built without -Dllvm answers exit 2
# with an actionable message, and every check below would look like a failure.
probe=$(mktemp)
"$ASTRA_ZIG" --emit-llvm-stdout "$zigdir/tests/llvm/fib.astra" >/dev/null 2>"$probe"
probe_rc=$?
if [ "$probe_rc" = 2 ] && grep -q "requires the compiler to be built with" "$probe"; then
    cat "$probe" >&2
    rm -f "$probe"
    die "build the compiler with 'zig build -Dllvm' first"
fi
rm -f "$probe"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The fixture is copied because --emit-obj writes <file>.o next to its input.
cp "$zigdir/tests/llvm/fib.astra" "$work/fib.astra"
fixture="$work/fib.astra"

# ---- 1. Instrumentación en IR e objeto --------------------------------
"$ASTRA_ZIG" --emit-llvm-stdout --sanitize=address "$fixture" >"$work/asan.ll" 2>"$work/asan.err" \
    || { sed 's/^/    /' "$work/asan.err"; fail "--emit-llvm-stdout --sanitize=address failed"; }
grep -q "__asan_report" "$work/asan.ll" || fail "IR has no ASan shadow checks (__asan_report_*)"
grep -q "asan.module_ctor" "$work/asan.ll" || fail "IR has no asan.module_ctor"

# Control: without the flag the module must stay clean.
"$ASTRA_ZIG" --emit-llvm-stdout "$fixture" >"$work/plain.ll" 2>"$work/plain.err" \
    || { sed 's/^/    /' "$work/plain.err"; fail "--emit-llvm-stdout failed"; }
if grep -q "__asan" "$work/plain.ll"; then
    fail "unsanitized IR already contains __asan references"
fi
echo "ok   IR instrumentado sólo con --sanitize=address"

"$ASTRA_ZIG" --emit-obj --sanitize=address "$fixture" >"$work/obj.out" 2>"$work/obj.err" \
    || { sed 's/^/    /' "$work/obj.err"; fail "--emit-obj --sanitize=address failed"; }
[ -f "$work/fib.o" ] || fail "missing $work/fib.o"
nm -u "$work/fib.o" | grep -q "__asan_init" || fail "object has no undefined __asan_* symbols"

# ---- 2. El enlace exige -fsanitize=address ---------------------------
"$CC_BIN" -c -O2 -std=c11 -I"$root/seed/src" "$RUNTIME_SRC" -o "$work/runtime.o" \
    || fail "cannot compile the LLVM runtime TU"

if "$CC_BIN" "$work/fib.o" "$work/runtime.o" -o "$work/plain_link" -lm 2>"$work/nolink.err"; then
    fail "object linked without -fsanitize=address: instrumentation was dropped"
fi
grep -q "__asan" "$work/nolink.err" || {
    sed 's/^/    /' "$work/nolink.err"
    fail "link failed but not on missing __asan_* symbols"
}
echo "ok   el objeto exige -fsanitize=address (enlace plano falla)"

"$CC_BIN" -c -O2 -std=c11 -fsanitize=address -I"$root/seed/src" "$RUNTIME_SRC" -o "$work/runtime_asan.o" \
    || fail "cannot compile the runtime TU with ASan"
"$CC_BIN" -fsanitize=address "$work/fib.o" "$work/runtime_asan.o" -o "$work/fib_asan" -lm \
    || fail "ASan link failed"

export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
"$ASTRA_ZIG" "$fixture" >"$work/vm.out" 2>"$work/vm.err"
vm_rc=$?
"$work/fib_asan" >"$work/asan.out" 2>"$work/asan_run.err"
asan_rc=$?
[ "$vm_rc" = "$asan_rc" ] || fail "exit code differs (vm=$vm_rc asan=$asan_rc)"
cmp -s "$work/vm.out" "$work/asan.out" || {
    diff "$work/vm.out" "$work/asan.out" | sed 's/^/    out: /'
    fail "ASan binary stdout differs from the VM"
}
cmp -s "$work/vm.err" "$work/asan_run.err" || {
    diff "$work/vm.err" "$work/asan_run.err" | sed 's/^/    err: /'
    fail "ASan binary stderr differs from the VM"
}
echo "ok   binario ASan reproduce stdout/stderr/exit de la VM"

# ---- 3. Control negativo: ASan detecta una violación ------------------
cat >"$work/overflow.c" <<'EOF'
#include <stdlib.h>
int main(void) {
    char *p = malloc(8);
    p[8] = 1; /* heap-buffer-overflow */
    free(p);
    return 0;
}
EOF
"$CC_BIN" -fsanitize=address -O0 "$work/overflow.c" -o "$work/overflow" \
    || fail "cannot build the negative control"
"$work/overflow" >"$work/ctl.out" 2>"$work/ctl.err"
ctl_rc=$?
[ "$ctl_rc" -ne 0 ] || fail "ASan did not abort the negative control"
grep -q "AddressSanitizer" "$work/ctl.err" || fail "negative control aborted without an ASan report"
echo "ok   control negativo: ASan aborta y reporta la violación"

# ---- 4. Suite de paridad completa bajo ASan ---------------------------
echo "---- paridad LLVM bajo ASan ----"
if ! ASTRA_LLVM_SAN=address "$here/llvm_parity.sh"; then
    fail "llvm_parity.sh diverged under ASan"
fi

# The same suite through the -O2 pipeline: the sanitizer pass runs first, so
# the optimizer must not remove a check that is observable (it may drop
# provably redundant ones).
echo "---- paridad LLVM bajo ASan y -O2 ----"
if ! ASTRA_LLVM_SAN=address ASTRA_LLVM_OPT=2 "$here/llvm_parity.sh"; then
    fail "llvm_parity.sh diverged under ASan at -O2"
fi

echo "llvm_sanitize: ok"
