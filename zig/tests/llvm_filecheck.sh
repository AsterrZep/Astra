#!/usr/bin/env bash
# FileCheck sobre shapes críticos del IR (LLVM_BACKEND_PLAN.md §6 M3).
#
# Cada fixture `zig/tests/llvm/check_*.astra` lleva sus directivas `// CHECK:`
# y se emite con `--emit-llvm-stdout`; FileCheck exige los patrones EN ORDEN,
# así que un cambio de lowering (bloques de guard, metadata de pesos, GEPs de
# payload, contador de profundidad, `?`) rompe el test aunque el programa siga
# funcionando. La suite diferencial (llvm_parity.sh) cubre la semántica; esto
# fija la FORMA del IR.
#
#   ./zig/tests/llvm_filecheck.sh
#
# Requiere el compilador con -Dllvm y FileCheck de LLVM 19..23 (viene con
# llvm-NN-tools; Debian/Ubuntu lo instala como FileCheck-NN fuera del PATH).
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"

die() { echo "llvm_filecheck: $*" >&2; exit 2; }

[ -x "$ASTRA_ZIG" ] || die "missing $ASTRA_ZIG (build with 'zig build -Dllvm')"

# FileCheck no siempre está en el PATH: prueba el nombre pelado (paquetes
# upstream) y los versionados (Debian/Ubuntu, en /usr/lib/llvm-NN/bin).
FC=""
for cand in FileCheck FileCheck-19 FileCheck-20 FileCheck-21 FileCheck-22 FileCheck-23; do
    if command -v "$cand" >/dev/null 2>&1; then FC=$(command -v "$cand"); break; fi
done
if [ -z "$FC" ]; then
    for v in 19 20 21 22 23; do
        if [ -x "/usr/lib/llvm-$v/bin/FileCheck" ]; then
            FC="/usr/lib/llvm-$v/bin/FileCheck"
            break
        fi
    done
fi
[ -n "$FC" ] || die "FileCheck not found (instala llvm-NN-tools, LLVM 19..23)"

# Sin -Dllvm el binario sale con 2 y un mensaje accionable: fallar rápido en
# vez de reportar cada fixture como divergencia.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if ! "$ASTRA_ZIG" --emit-llvm-stdout "$zigdir/tests/llvm/fib.astra" >/dev/null 2>"$work/probe.err"; then
    if grep -q "requires the compiler to be built with" "$work/probe.err"; then
        cat "$work/probe.err" >&2
        die "build the compiler with 'zig build -Dllvm' first"
    fi
    cat "$work/probe.err" >&2
    die "cannot emit IR for tests/llvm/fib.astra"
fi

total=0
fail=0
for f in "$zigdir"/tests/llvm/check_*.astra; do
    [ -e "$f" ] || continue
    total=$((total + 1))
    rel=${f#"$zigdir/"}
    if ! "$ASTRA_ZIG" --emit-llvm-stdout "$f" >"$work/ir.ll" 2>"$work/emit.err"; then
        echo "FAIL $rel: emit"
        sed 's/^/    /' "$work/emit.err"
        fail=$((fail + 1))
        continue
    fi
    if "$FC" "$f" <"$work/ir.ll" >"$work/fc.out" 2>&1; then
        echo "ok   $rel"
    else
        echo "FAIL $rel: FileCheck"
        sed 's/^/    /' "$work/fc.out"
        fail=$((fail + 1))
    fi
done

echo "----"
echo "llvm_filecheck: total=$total fail=$fail"
[ "$fail" -eq 0 ]
