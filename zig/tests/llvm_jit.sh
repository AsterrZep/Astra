#!/usr/bin/env bash
# LLVM-route JIT parity (LLVM_BACKEND_PLAN.md §6 M6.a): every case through the
# zig VM (reference) and through the LLJIT in-process path (--jit); stdout,
# stderr and the exit code must match byte-for-byte.
#
#   ./zig/tests/llvm_jit.sh                 # report (exit 1 on divergence)
#   ASTRA_LLVM_OPT=2 ./zig/tests/llvm_jit.sh  # same gate with the opt pipeline
#
# `--jit` compila el módulo emitido en el propio proceso vía ORC/LLJIT y ejecuta
# su `main` — sin `cc`+enlace intermedio. Comparte el emisor con la ruta AOT
# (--emit-obj), así que acepta el mismo subconjunto y la misma semántica; el
# gate comprueba que correr en proceso reproduce la VM byte a byte. Es el
# cimiento del REPL/eval.
#
# Requiere el compilador construido con -Dllvm (zig build -Dllvm): el runtime C
# se linkea al binario y se exporta con -rdynamic, de modo que el generador de
# símbolos de proceso de LLJIT resuelve `astra_llvm_*`+libc desde el código
# JITeado. A diferencia de llvm_parity.sh no hay objeto que enlazar ni ${CC}.
#
# La zig VM es la referencia (igual que en llvm_parity.sh). El emitter es
# single-file: los fixtures de módulos corren con --single-file. Un caso fuera
# del subconjunto del emisor se *salta* (rechazado con "not supported by the
# LLVM backend"), igual que llvm_parity.sh, no se cuenta como fallo.
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"

die() { echo "llvm_jit: $*" >&2; exit 2; }

[ -x "$ASTRA_ZIG" ] || die "missing $ASTRA_ZIG (build with 'zig build -Dllvm')"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fail fast if the binary lacks the LLVM backend: without -Dllvm every case
# would exit 2 with an actionable message and look like a wall of divergences.
"$ASTRA_ZIG" --jit "$zigdir/tests/llvm/fib.astra" >/dev/null 2>"$work/probe.err"
probe_rc=$?
if [ "$probe_rc" = 2 ] && grep -q "requires the compiler to be built with" "$work/probe.err"; then
    cat "$work/probe.err" >&2
    die "build the compiler with 'zig build -Dllvm' first"
fi

# Snapshot the inputs: `--jit` no escribe artefactos (todo es in-process), pero
# se trabaja en un temp dir por consistencia con llvm_parity.sh.
mkdir -p "$work/conf" "$work/llvm" "$work/cg"
cp -r "$root/seed/tests/conformance/." "$work/conf/"
cp -r "$zigdir/tests/llvm/." "$work/llvm/"
cp "$root"/seed/tests/codegen/*.astra "$work/cg/" 2>/dev/null || true

# Nivel de optimización del módulo antes de JITearlo (M4/M6.a): 0 (default) o
# 1..3 para el pipeline del new PM. CI puede correr con ASTRA_LLVM_OPT=2.
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

    # El emisor LLVM es single-file; los fixtures de módulos declaran imports
    # que no deben resolverse, igual que en llvm_parity.sh.
    extra=""
    if grep -qE '^(import|from|use) ' "$f"; then
        extra="--single-file"
    fi

    # Reference: zig VM.
    "$ASTRA_ZIG" $extra "$f" </dev/null >"$work/vm.out" 2>"$work/vm.err"
    vm_rc=$?

    # LLJIT route: compile-and-run in-process. Constructs outside the backend's
    # scope are a clean skip (the emitter rejects them before the JIT runs).
    "$ASTRA_ZIG" --jit $extra $OPT_ARGS "$f" </dev/null >"$work/jit.out" 2>"$work/jit.err"
    jit_rc=$?
    if [ "$jit_rc" != 0 ] && grep -q "not supported by the LLVM backend" "$work/jit.err"; then
        echo "skip $rel (not LLVM scope)"
        skip=$((skip + 1))
        continue
    fi

    bad=0
    [ "$vm_rc" != "$jit_rc" ] && bad=1
    cmp -s "$work/vm.out" "$work/jit.out" || bad=1
    cmp -s "$work/vm.err" "$work/jit.err" || bad=1

    if [ "$bad" = 1 ]; then
        echo "FAIL $rel (rc vm=$vm_rc jit=$jit_rc)"
        diff "$work/vm.out" "$work/jit.out" | sed 's/^/    out: /'
        diff "$work/vm.err" "$work/jit.err" | sed 's/^/    err: /'
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
echo "llvm_jit: total=$total ok=$((total - skip - fail)) skip=$skip fail=$fail opt=$OPT"
[ "$fail" -eq 0 ]
