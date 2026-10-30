#!/usr/bin/env bash
# DEC-009 + DEC-039 gate: the native LLVM route keeps a FLAT memory ceiling
# under sustained allocation. The VMs' arena growth (404/721/489 MB measured
# in research/040 §12) must never appear on the production route.
#
# Two phases:
#   loop_reuse (DEC-009, techo 64 MB): measured ~1.2 MB, ~50x headroom.
#   string_alloc (DEC-039, techo 128 MB): 300 k string allocs — research/040
#       measured a 77 MB suite peak today, so 128 MB keeps headroom while
#       catching any regression to arena-style growth.
#
#   ./zig/tests/llvm_mem.sh                    # gate (64/128 MB)
#   ASTRA_MEM_CEILING_KB=131072 ./zig/tests/llvm_mem.sh
#   ASTRA_MEM_STR_CEILING_KB=131072 ./zig/tests/llvm_mem.sh
#
# Runs the fixtures through `--emit-obj` + link (same recipe as
# llvm_parity.sh), checks the output byte-for-byte, and asserts peak RSS
# (VmHWM sampled at 5 ms) under the ceiling. Needs a `-Dllvm` build of
# astra-zig. The string probe only gates the LLVM route: seed/zig/C arenas
# are a documented divergence (DEC-039), never a false-red gate.
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
RUNTIME_SRC="$zigdir/src/llvm/runtime/astra_runtime_llvm.c"
CEILING_KB=${ASTRA_MEM_CEILING_KB:-65536}
STR_CEILING_KB=${ASTRA_MEM_STR_CEILING_KB:-131072}
LOOP_SRC="$root/seed/tests/conformance/memory/loop_reuse.astra"
STR_SRC="$here/probes/string_alloc.astra"

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

# Compile a fixture to a native binary in $work and assert output + peak
# RSS (VmHWM sampled at 5 ms — the kernel high-water mark survives exec,
# unlike a forked child's inherited ru_maxrss).
measure() {
    local src="$1" label="$2" ceiling="$3" expected="$4"
    local name
    name=$(basename "$src" .astra)
    cp "$src" "$work/$name.astra"
    (cd "$work" && "$ASTRA_ZIG" --emit-obj "$name.astra" >/dev/null) \
        || { echo "llvm_mem: --emit-obj failed ($label)" >&2; return 2; }
    "${CC:-cc}" "$work/$name.o" "$work/runtime.o" -o "$work/$name.bin" -lm \
        || { echo "llvm_mem: link failed ($label)" >&2; return 2; }
    "$work/$name.bin" > "$work/$name.out" 2>"$work/$name.err" &
    local pid=$!
    local peak=0
    while kill -0 "$pid" 2>/dev/null; do
        local h
        h=$(awk '/VmHWM:/{print $2}' "/proc/$pid/status" 2>/dev/null)
        [ -n "${h:-}" ] && [ "$h" -gt "$peak" ] && peak=$h
        sleep 0.005
    done
    wait "$pid"
    local rc=$?
    local actual
    actual=$(cat "$work/$name.out")
    if [ "$rc" -ne 0 ] || [ "$actual" != "$expected" ]; then
        echo "llvm_mem: FAIL — output mismatch ($label, rc=$rc)" >&2
        sed 's/^/    /' "$work/$name.out" "$work/$name.err" >&2
        return 1
    fi
    if [ "$peak" -gt "$ceiling" ]; then
        echo "llvm_mem: FAIL — peak RSS ${peak} KB exceeds ceiling ${ceiling} KB ($label)" >&2
        echo "  (the native route must stay flat under sustained allocation; see DEC-009/DEC-039)" >&2
        return 1
    fi
    echo "llvm_mem: ok — peak RSS ${peak} KB <= ceiling ${ceiling} KB ($label, native route)"
    return 0
}

fail=0
measure "$LOOP_SRC" "loop_reuse" "$CEILING_KB" "$(printf '2000000\n8')" || fail=1
measure "$STR_SRC" "string_alloc" "$STR_CEILING_KB" "300000" || fail=1
exit "$fail"
