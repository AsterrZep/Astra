#!/usr/bin/env bash
# Fuzz diferencial (LLVM_BACKEND_PLAN.md §4.5/§6 M3): programas generados
# determinísticamente (llvm_fuzz_gen.py) por las cuatro rutas — seed VM,
# seed --emit-c + gcc, zig VM y zig --emit-obj -> link runtime — con stdout,
# stderr y exit code byte a byte idénticos.
#
#   ./zig/tests/llvm_fuzz.sh [-n N] [-s SEED]     # N=25, SEED=1 por defecto
#
# Cada programa es reproducible: `python3 zig/tests/llvm_fuzz_gen.py --seed S
# --index I` imprime el mismo fichero. Un fallo imprime el programa y el diff.
# Las rutas del seed son opcionales: sin seed/astra-seed (o sin gcc) se saltan
# y queda el diferencial zig VM <-> LLVM, que es el que cubre el backend nuevo.
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
ASTRA_SEED="$root/seed/astra-seed"
GEN="$here/llvm_fuzz_gen.py"

N=25
SEED=1
while getopts "n:s:" opt; do
    case "$opt" in
        n) N=$OPTARG ;;
        s) SEED=$OPTARG ;;
        *) echo "usage: $0 [-n N] [-s SEED]" >&2; exit 2 ;;
    esac
done

die() { echo "llvm_fuzz: $*" >&2; exit 2; }

[ -x "$ASTRA_ZIG" ] || die "missing $ASTRA_ZIG (build with 'zig build -Dllvm')"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v "${CC:-cc}" >/dev/null 2>&1 || die "${CC:-cc} not found"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Sin -Dllvm el binario sale con 2 y un mensaje accionable.
if ! "$ASTRA_ZIG" --emit-llvm-stdout "$zigdir/tests/llvm/fib.astra" >/dev/null 2>"$work/probe.err"; then
    if grep -q "requires the compiler to be built with" "$work/probe.err"; then
        cat "$work/probe.err" >&2
        die "build the compiler with 'zig build -Dllvm' first"
    fi
    cat "$work/probe.err" >&2
    die "cannot emit IR for tests/llvm/fib.astra"
fi

# Runtime de la ruta LLVM, compilado una vez.
if ! "${CC:-cc}" -c -O2 -std=c11 -I"$root/seed/src" \
        "$zigdir/src/llvm/runtime/astra_runtime_llvm.c" -o "$work/runtime.o" 2>"$work/rt.err"; then
    echo "llvm_fuzz: cannot compile the LLVM runtime TU" >&2
    sed 's/^/    /' "$work/rt.err"
    exit 2
fi

seed_routes=0
if [ -x "$ASTRA_SEED" ] && command -v gcc >/dev/null 2>&1; then
    seed_routes=1
else
    echo "llvm_fuzz: seed routes skipped (build seed/astra-seed with 'make -C seed debug' to include them)"
fi

total=0
fail=0
for i in $(seq 0 $((N - 1))); do
    total=$((total + 1))
    prog="$work/p.astra"
    python3 "$GEN" --seed "$SEED" --index "$i" >"$prog"

    # zig VM = referencia.
    "$ASTRA_ZIG" "$prog" >"$work/vm.out" 2>"$work/vm.err"
    vm_rc=$?

    # Un programa generado debe compilar: si la referencia falla sin un
    # `runtime error`, el bug es del generador (corpus inválido), no de una ruta.
    if [ "$vm_rc" != 0 ] && ! grep -q "runtime error" "$work/vm.err"; then
        echo "FAIL index=$i: generator produced an invalid program"
        sed 's/^/    /' "$work/vm.err"
        sed 's/^/    | /' "$prog"
        fail=$((fail + 1))
        continue
    fi

    bad=0

    # Ruta LLVM.
    if ! "$ASTRA_ZIG" --emit-obj "$prog" >"$work/emit.log" 2>&1; then
        echo "FAIL index=$i: --emit-obj failed"
        sed 's/^/    /' "$work/emit.log"
        bad=1
    elif ! "${CC:-cc}" "${prog%.astra}.o" "$work/runtime.o" -o "$work/bin" -lm 2>"$work/link.err"; then
        echo "FAIL index=$i: link failed"
        sed 's/^/    /' "$work/link.err"
        bad=1
    else
        "$work/bin" >"$work/ll.out" 2>"$work/ll.err"
        ll_rc=$?
        [ "$vm_rc" != "$ll_rc" ] && bad=1
        cmp -s "$work/vm.out" "$work/ll.out" || bad=1
        cmp -s "$work/vm.err" "$work/ll.err" || bad=1
        if [ "$bad" = 1 ]; then
            echo "FAIL index=$i (rc vm=$vm_rc llvm=$ll_rc)"
            diff "$work/vm.out" "$work/ll.out" | sed 's/^/    out: /'
            diff "$work/vm.err" "$work/ll.err" | sed 's/^/    err: /'
        fi
    fi

    # Rutas del seed (VM y --emit-c + gcc), si están disponibles.
    if [ "$seed_routes" = 1 ] && [ "$bad" = 0 ]; then
        "$ASTRA_SEED" "$prog" >"$work/svm.out" 2>"$work/svm.err"
        svm_rc=$?
        [ "$vm_rc" != "$svm_rc" ] && bad=1
        cmp -s "$work/vm.out" "$work/svm.out" || bad=1
        cmp -s "$work/vm.err" "$work/svm.err" || bad=1
        if [ "$bad" = 1 ]; then
            echo "FAIL index=$i (rc zig=$vm_rc seed=$svm_rc)"
            diff "$work/vm.out" "$work/svm.out" | sed 's/^/    out: /'
            diff "$work/vm.err" "$work/svm.err" | sed 's/^/    err: /'
        fi
    fi
    if [ "$seed_routes" = 1 ] && [ "$bad" = 0 ]; then
        if ! "$ASTRA_SEED" --emit-c "$prog" >"$work/emitc.log" 2>&1; then
            echo "FAIL index=$i: seed --emit-c failed"
            sed 's/^/    /' "$work/emitc.log"
            bad=1
        elif ! gcc -Wall -Wextra -I"$root/seed/src" -o "$work/sbin" "${prog%.astra}.c" -lm 2>"$work/gcc.err"; then
            echo "FAIL index=$i: gcc rejected the generated C"
            sed 's/^/    /' "$work/gcc.err"
            bad=1
        elif [ -s "$work/gcc.err" ]; then
            echo "FAIL index=$i: gcc warned about the generated C"
            sed 's/^/    /' "$work/gcc.err"
            bad=1
        else
            "$work/sbin" >"$work/c.out" 2>"$work/c.err"
            c_rc=$?
            [ "$vm_rc" != "$c_rc" ] && bad=1
            cmp -s "$work/vm.out" "$work/c.out" || bad=1
            cmp -s "$work/vm.err" "$work/c.err" || bad=1
            if [ "$bad" = 1 ]; then
                echo "FAIL index=$i (rc vm=$vm_rc c=$c_rc)"
                diff "$work/vm.out" "$work/c.out" | sed 's/^/    out: /'
                diff "$work/vm.err" "$work/c.err" | sed 's/^/    err: /'
            fi
        fi
    fi

    if [ "$bad" = 1 ]; then
        echo "    repro: python3 $GEN --seed $SEED --index $i > p.astra"
        sed 's/^/    | /' "$prog"
        fail=$((fail + 1))
    fi
done

echo "----"
echo "llvm_fuzz: seed=$SEED programs=$total seed_routes=$seed_routes fail=$fail"
[ "$fail" -eq 0 ]
