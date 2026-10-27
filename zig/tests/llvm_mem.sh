#!/usr/bin/env bash
# DEC-009 gate (research/027 §3.3, ratificada como D3): the native LLVM
# route keeps a FLAT memory ceiling under sustained allocation. The VMs'
# arena growth (400–729 MB measured in research/030) must never appear on
# the production route — measured today: ~1.2 MB, so the 64 MB default is
# ~50x headroom while still catching any regression to arena-style growth.
#
#   ./zig/tests/llvm_mem.sh                    # gate (techo 64 MB)
#   ASTRA_MEM_CEILING_KB=131072 ./zig/tests/llvm_mem.sh   # techo alternativo
#
# Runs seed/tests/conformance/memory/loop_reuse.astra through
# `--emit-obj` + link (same recipe as llvm_parity.sh), checks the output
# byte-for-byte, and asserts peak RSS (VmHWM sampled at 5 ms) under the
# ceiling. Needs a `-Dllvm` build of astra-zig.
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
RUNTIME_SRC="$zigdir/src/llvm/runtime/astra_runtime_llvm.c"
CEILING_KB=${ASTRA_MEM_CEILING_KB:-65536}
SRC="$root/seed/tests/conformance/memory/loop_reuse.astra"

if [ ! -x "$ASTRA_ZIG" ]; then
    echo "llvm_mem: missing $ASTRA_ZIG (build with 'zig build -Dllvm')" >&2
    exit 2
fi
if ! "$ASTRA_ZIG" --help 2>&1 | grep -q -- '--emit-obj'; then
    echo "llvm_mem: astra-zig was built without -Dllvm; rebuild and retry" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Runtime object, compiled once (thin TU over seed/src/codegen_runtime.h).
"${CC:-cc}" -c -O2 -std=c11 -I"$root/seed/src" "$RUNTIME_SRC" -o "$work/runtime.o" \
    || { echo "llvm_mem: cannot compile the LLVM runtime TU" >&2; exit 2; }

# Copy the fixture into the work dir so the .o does not land in the suite.
cp "$SRC" "$work/loop_reuse.astra"
(cd "$work" && "$ASTRA_ZIG" --emit-obj loop_reuse.astra >/dev/null) \
    || { echo "llvm_mem: --emit-obj failed" >&2; exit 2; }
"${CC:-cc}" "$work/loop_reuse.o" "$work/runtime.o" -o "$work/bin" -lm \
    || { echo "llvm_mem: link failed" >&2; exit 2; }

# Run once while sampling VmHWM (the kernel's high-water mark survives
# exec, unlike a forked child's inherited ru_maxrss).
"$work/bin" > "$work/out" 2>"$work/err" &
pid=$!
peak=0
while kill -0 "$pid" 2>/dev/null; do
    h=$(awk '/VmHWM:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    [ -n "${h:-}" ] && [ "$h" -gt "$peak" ] && peak=$h
    sleep 0.005
done
wait "$pid"
rc=$?

expected=$(printf '2000000\n8')
actual=$(cat "$work/out")
if [ "$rc" -ne 0 ] || [ "$actual" != "$expected" ]; then
    echo "llvm_mem: FAIL — output mismatch (rc=$rc)" >&2
    sed 's/^/    /' "$work/out" "$work/err" >&2
    exit 1
fi

if [ "$peak" -gt "$CEILING_KB" ]; then
    echo "llvm_mem: FAIL — peak RSS ${peak} KB exceeds ceiling ${CEILING_KB} KB" >&2
    echo "  (the native route must stay flat under sustained allocation; see DEC-009)" >&2
    exit 1
fi

echo "llvm_mem: ok — peak RSS ${peak} KB <= ceiling ${CEILING_KB} KB (loop_reuse, native route)"
