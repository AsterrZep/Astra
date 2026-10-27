#!/usr/bin/env bash
# Benchmark suite (LLVM_BACKEND_PLAN.md §6 M4): the same programs through the
# zig VM, the seed's C backend and the LLVM route. Correctness first (stdout
# must match the VM byte for byte) and then wall time; the table is
# informational, the exit status is the correctness gate.
#
#   ./zig/tests/llvm_bench.sh [-n REPEATS] [-O LEVEL]   # 3 repeticiones, O0
#
# Tiempos: `vm` es compilación + ejecución (lo que ve el usuario de la VM);
# `llvm build` es --emit-obj + enlace y `llvm run` la ejecución del binario;
# `c build`/`c run` lo mismo por el backend C del seed. Cada ejecución se
# repite REPEATS veces y se queda el mínimo (menos ruido de scheduler).
# `-O` pasa --opt-level=LEVEL al emisor LLVM (M4: 0 sin pipeline, 2 default<O2>
# + licm/simple-loop-unswitch/irce).
#
# research/030 (benchmarks vs Rust/Go/C/Zig, 2026-10-27): los casos
# fib30/alloc2m/str25k provienen de 030_benchmarks_suite/ y son los mismos
# programas medidos allí, para poder comparar de nuevo contra los lenguajes
# de referencia con `build_all.sh`. NOTA sobre umbrales: el techo de MEMORIA
# está gateado en CI por zig/tests/llvm_mem.sh (DEC-009, 64 MB); los tiempos
# se dejan informativos a propósito — en una máquina compartida un umbral de
# ms solo produce flakes, y la corrección (3 rutas byte-idénticas) sí es gate.
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
ASTRA_SEED="$root/seed/astra-seed"
BENCHDIR="$zigdir/tests/bench"

N=3
OPT=0
while getopts "n:O:" opt; do
    case "$opt" in
        n) N=$OPTARG ;;
        O) OPT=$OPTARG ;;
        *) echo "usage: $0 [-n REPEATS] [-O LEVEL]" >&2; exit 2 ;;
    esac
done

die() { echo "llvm_bench: $*" >&2; exit 2; }

[ -x "$ASTRA_ZIG" ] || die "missing $ASTRA_ZIG (build with 'zig build -Dllvm')"
command -v "${CC:-cc}" >/dev/null 2>&1 || die "${CC:-cc} not found"
[ -d "$BENCHDIR" ] || die "missing $BENCHDIR"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$BENCHDIR"/*.astra "$work/"

# Runtime de la ruta LLVM, una vez.
if ! "${CC:-cc}" -c -O2 -std=c11 -I"$root/seed/src" \
        "$zigdir/src/llvm/runtime/astra_runtime_llvm.c" -o "$work/runtime.o" 2>"$work/rt.err"; then
    echo "llvm_bench: cannot compile the LLVM runtime TU" >&2
    sed 's/^/    /' "$work/rt.err"
    exit 2
fi

c_routes=0
if [ -x "$ASTRA_SEED" ] && command -v gcc >/dev/null 2>&1; then
    c_routes=1
else
    echo "llvm_bench: C backend skipped (build seed/astra-seed with 'make -C seed debug')"
fi

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# min_run BIN OUT: ejecuta BIN N veces y deja el mínimo en ms en RUN_MS.
min_run() {
    local bin=$1 out=$2 best=999999999 t0 t1 dt i
    for ((i = 0; i < N; i++)); do
        t0=$(now_ms)
        "$bin" >"$out" 2>&1
        t1=$(now_ms)
        dt=$((t1 - t0))
        [ "$dt" -lt "$best" ] && best=$dt
    done
    RUN_MS=$best
}

printf '%-12s %9s %10s %9s' "bench" "vm" "llvm build" "llvm -O$OPT"
[ "$c_routes" = 1 ] && printf ' %8s %8s' "c build" "c run"
printf ' %9s\n' "llvm/vm"

fail=0
for f in "$work"/*.astra; do
    name=$(basename "$f" .astra)

    # Referencia: zig VM (compilación + ejecución).
    t0=$(now_ms)
    "$ASTRA_ZIG" "$f" >"$work/vm.out" 2>&1
    t1=$(now_ms)
    vm_ms=$((t1 - t0))

    # Ruta LLVM: construir una vez, ejecutar N veces.
    t0=$(now_ms)
    if ! "$ASTRA_ZIG" --emit-obj --opt-level="$OPT" "$f" >"$work/emit.log" 2>&1; then
        echo "FAIL $name: --emit-obj failed"
        sed 's/^/    /' "$work/emit.log"
        fail=$((fail + 1))
        continue
    fi
    if ! "${CC:-cc}" "${f%.astra}.o" "$work/runtime.o" -o "$work/bin" -lm 2>"$work/link.err"; then
        echo "FAIL $name: link failed"
        sed 's/^/    /' "$work/link.err"
        fail=$((fail + 1))
        continue
    fi
    t1=$(now_ms)
    llvm_build=$((t1 - t0))
    min_run "$work/bin" "$work/ll.out"
    llvm_run=$RUN_MS

    if ! cmp -s "$work/vm.out" "$work/ll.out"; then
        echo "FAIL $name: LLVM stdout differs from the VM"
        diff "$work/vm.out" "$work/ll.out" | sed 's/^/    /'
        fail=$((fail + 1))
        continue
    fi

    c_build="-"
    c_run="-"
    if [ "$c_routes" = 1 ]; then
        t0=$(now_ms)
        if ! "$ASTRA_SEED" --emit-c "$f" >"$work/emitc.log" 2>&1; then
            echo "FAIL $name: seed --emit-c failed"
            sed 's/^/    /' "$work/emitc.log"
            fail=$((fail + 1))
            continue
        fi
        if ! gcc -O2 -I"$root/seed/src" -o "$work/cbin" "${f%.astra}.c" -lm 2>"$work/gcc.err"; then
            echo "FAIL $name: gcc rejected the generated C"
            sed 's/^/    /' "$work/gcc.err"
            fail=$((fail + 1))
            continue
        fi
        t1=$(now_ms)
        c_build=$((t1 - t0))
        min_run "$work/cbin" "$work/c.out"
        c_run=$RUN_MS
        if ! cmp -s "$work/vm.out" "$work/c.out"; then
            echo "FAIL $name: C stdout differs from the VM"
            diff "$work/vm.out" "$work/c.out" | sed 's/^/    /'
            fail=$((fail + 1))
            continue
        fi
    fi

    ratio=$(awk -v v="$vm_ms" -v l="$llvm_run" 'BEGIN { if (l > 0) printf "%.2fx", v / l; else print "inf" }')
    printf '%-12s %9d %10d %9d' "$name" "$vm_ms" "$llvm_build" "$llvm_run"
    [ "$c_routes" = 1 ] && printf ' %8s %8s' "$c_build" "$c_run"
    printf ' %9s\n' "$ratio"
done

echo "----"
echo "llvm_bench: benches=$(ls "$work"/*.astra | wc -l) repeats=$N opt=$OPT c_routes=$c_routes fail=$fail"
[ "$fail" -eq 0 ]
