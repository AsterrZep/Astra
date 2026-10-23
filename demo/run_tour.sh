#!/usr/bin/env bash
# run_tour.sh — ejecuta demo/tour.astra por las cinco rutas del toolchain y
# exige la misma salida en todas:
#
#   1. VM seed     seed/astra-seed
#   2. Backend C   --emit-c -> gcc
#   3. VM zig      zig/zig-out/bin/astra-zig
#   4. LLVM AOT    --emit-obj -> enlace con el runtime -> ejecutar
#   5. LLVM JIT    --jit (LLJIT, en proceso)
#
# La referencia es la VM seed. Las rutas 2-5 se diffean contra ella. La ruta
# LLVM (4 y 5) necesita `zig build -Dllvm` y llvm-config-19..23; si falta,
# se omite con aviso en lugar de fallar (M0-M5 sin LLVM siguen siendo
# válidos). Uso: demo/run_tour.sh [--opt N]  (N en 0..3, default 0)
set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
TOUR="$root/demo/tour.astra"
SEED="$root/seed/astra-seed"
ASTRA_ZIG="$root/zig/zig-out/bin/astra-zig"
RUNTIME_SRC="$root/zig/src/llvm/runtime/astra_runtime_llvm.c"

OPT_LEVEL=0
if [ "${1:-}" = "--opt" ]; then OPT_LEVEL="${2:-0}"; fi

work="$(mktemp -d /tmp/opencode/tour.XXXXXX)" || exit 1
trap 'rm -rf "$work"; rm -f "${TOUR%.astra}.c" "${TOUR%.astra}.o"' EXIT

die()  { echo "run_tour: $*" >&2; exit 1; }
[ -x "$SEED" ]       || die "$SEED not found (run `make -C seed`)"
[ -x "$ASTRA_ZIG" ]  || die "$ASTRA_ZIG not found (run zig build)"
[ -f "$TOUR" ]       || die "$TOUR not found"

# ── 1. Referencia: VM seed ────────────────────────────────────────────
if ! "$SEED" "$TOUR" >"$work/ref.out" 2>"$work/ref.err"; then
    echo "FAIL seed-vm: la VM seed no ejecuta el tour"
    sed 's/^/    /' "$work/ref.err"
    exit 1
fi
echo "ok   seed-vm      ($(wc -l <"$work/ref.out") líneas)"

fails=0

# compare <nombre> <archivo-salida> <archivo-stderr> <código>
compare() {
    local name="$1" out="$2" err="$3" rc="$4"
    if [ "$rc" != "0" ]; then
        echo "FAIL $name: exit $rc"
        sed 's/^/    /' "$err" | head -10
        fails=$((fails+1)); return
    fi
    if ! diff -u "$work/ref.out" "$out" >"$work/diff.$name" 2>&1; then
        echo "FAIL $name: la salida difiere de la VM seed"
        head -20 "$work/diff.$name" | sed 's/^/    /'
        fails=$((fails+1)); return
    fi
    echo "ok   $name"
}

# ── 2. Backend C ──────────────────────────────────────────────────────
# `--emit-c file.astra` escribe el código en file.c (no en stdout). Igual que
# la suite de codegen, se compila con -Wall -Wextra: un warning en C generado
# es un defecto del codegen y debe romper este gate como cualquier otra
# divergencia. El .c generado se limpia al final.
CG_C="${TOUR%.astra}.c"
if "$SEED" --emit-c "$TOUR" >/dev/null 2>"$work/emitc.err"; then
    if cc -O2 -Wall -Wextra -I"$root/seed/src" -o "$work/tour_c" "$CG_C" -lm 2>"$work/cc.err"; then
        "$work/tour_c" >"$work/c.out" 2>"$work/c.err"; rc=$?
        compare "backend-c" "$work/c.out" "$work/c.err" "$rc"
    else
        echo "FAIL backend-c: el gcc falló"; sed 's/^/    /' "$work/cc.err" | head -10
        fails=$((fails+1))
    fi
else
    echo "FAIL backend-c: --emit-c falló"; sed 's/^/    /' "$work/emitc.err" | head -10
    fails=$((fails+1))
fi

# ── 3. VM zig ─────────────────────────────────────────────────────────
"$ASTRA_ZIG" "$TOUR" >"$work/zig.out" 2>"$work/zig.err"; rc=$?
compare "zig-vm" "$work/zig.out" "$work/zig.err" "$rc"

# ── 4 y 5. Rutas LLVM (AOT y JIT) — omitidas si no hay build -Dllvm ───
# La detección usa --emit-obj (lo que la ruta AOT llama realmente); --jit
# devuelve exit 0 incluso con errores de compilación en stderr, así que no
# sirve como sonda de "¿este binario tiene LLVM?".
have_llvm=""
if "$ASTRA_ZIG" --emit-obj "$TOUR" >/dev/null 2>&1; then
    have_llvm=1
fi
rm -f "${TOUR%.astra}.o"

if [ -n "$have_llvm" ]; then
    # 4. AOT: --emit-obj -> enlace con el runtime -> ejecutar.
    opt_args=""
    [ "$OPT_LEVEL" != "0" ] && opt_args="--opt-level=$OPT_LEVEL"
    if "$ASTRA_ZIG" --emit-obj $opt_args "$TOUR" >"$work/emit.out" 2>"$work/emit.err"; then
        if ! cc -O2 -c -I"$root/seed/src" "$RUNTIME_SRC" -o "$work/runtime.o" 2>"$work/rt.err"; then
            echo "FAIL llvm-aot: no compila el runtime TU"; sed 's/^/    /' "$work/rt.err" | head -10
            fails=$((fails+1))
        elif ! cc "${TOUR%.astra}.o" "$work/runtime.o" -o "$work/tour_llvm" -lm 2>"$work/link.err"; then
            echo "FAIL llvm-aot: falló el enlace"; sed 's/^/    /' "$work/link.err" | head -10
            fails=$((fails+1))
        else
            "$work/tour_llvm" >"$work/aot.out" 2>"$work/aot.err"; rc=$?
            compare "llvm-aot" "$work/aot.out" "$work/aot.err" "$rc"
        fi
        rm -f "${TOUR%.astra}.o"
    else
        echo "FAIL llvm-aot: --emit-obj falló"; sed 's/^/    /' "$work/emit.err" | head -10
        fails=$((fails+1))
    fi

    # 5. JIT: en proceso, sin cc ni enlace. Ojo al medir exit codes con pipes:
    # `cmd | head; echo $?` reporta el exit de head (siempre 0), no el de cmd.
    # `--jit` sí propaga bien sus fallos (compilación y runtime -> 1).
    "$ASTRA_ZIG" --jit $opt_args "$TOUR" >"$work/jit.out" 2>"$work/jit.err"; rc=$?
    compare "llvm-jit" "$work/jit.out" "$work/jit.err" "$rc"
else
    echo "skip llvm-aot, llvm-jit (el binario zig no tiene -Dllvm; zig build -Dllvm)"
fi

echo
if [ "$fails" = "0" ]; then
    echo "run_tour: todas las rutas producen la misma salida ($(wc -l <"$work/ref.out") líneas)"
else
    echo "run_tour: $fails ruta(s) fallan"
    exit 1
fi
