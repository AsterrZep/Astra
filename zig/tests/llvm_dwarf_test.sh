#!/usr/bin/env bash
# Verificación de DWARF (LLVM_BACKEND_PLAN.md §6 M4.c):
# 1. Compila un programa con `--emit-obj --debug-info`.
# 2. Comprueba que el `.o` contenga secciones de depuración (.debug_line, .debug_info).
# 3. Si lldb está instalado, corre el binario con un breakpoint por línea y
#    comprueba que pare en la línea fuente exacta de Astra.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
RUNTIME_SRC="$zigdir/src/llvm/runtime/astra_runtime_llvm.c"

[ -x "$ASTRA_ZIG" ] || { echo "error: $ASTRA_ZIG missing" >&2; exit 2; }
command -v "${CC:-cc}" >/dev/null 2>&1 || { echo "error: ${CC:-cc} not found" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat << 'EOF' > "$work/prog.astra"
fn compute(x: i32) -> i32 {
    let y = x * 2
    return y + 10
}

fn main() {
    print(compute(5))
    let add = make_adder(7)
    print(add(3))
}

// Regresión M4.c: una función que devuelve un closure. Sin reaplicar la
// location del builder al restaurar el scope del frame exterior en `emitLambda`,
// el `ret` de `make_adder` heredaba la location de la lambda y el verificador
// rechazaba el módulo ("!dbg attachment points at wrong subprogram").
fn make_adder(base: i32) -> fn(i32) -> i32 {
    return |x: i32| -> i32 { return base + x }
}
EOF

# 1. Compilación a objeto nativo con DWARF
"$ASTRA_ZIG" --emit-obj --debug-info "$work/prog.astra"
[ -f "$work/prog.o" ] || { echo "error: prog.o not generated" >&2; exit 1; }

# 2. Verificación de secciones DWARF en el objeto
if command -v readelf >/dev/null 2>&1; then
    readelf -S "$work/prog.o" | grep -q "\.debug_line" || {
        echo "error: .debug_line section missing in prog.o" >&2
        exit 1
    }
    readelf -S "$work/prog.o" | grep -q "\.debug_info" || {
        echo "error: .debug_info section missing in prog.o" >&2
        exit 1
    }
fi

# 3. Enlace
"${CC:-cc}" -c -O2 -std=c11 -I"$root/seed/src" "$RUNTIME_SRC" -o "$work/runtime.o"
"${CC:-cc}" "$work/prog.o" "$work/runtime.o" -o "$work/prog" -lm

# Comprobación de ejecución normal
out=$("$work/prog")
[ "$out" = $'20\n10' ] || { echo "error: expected '20\\n10', got '$out'" >&2; exit 1; }

# 4. Inspección con lldb si está disponible
LLDB=""
for cand in lldb lldb-19 lldb-20 lldb-21 lldb-22 lldb-23; do
    if command -v "$cand" >/dev/null 2>&1; then LLDB=$(command -v "$cand"); break; fi
done

if [ -n "$LLDB" ]; then
    lldb_out=$("$LLDB" --batch \
        -o "b prog.astra:3" \
        -o "run" \
        -o "thread backtrace" \
        "$work/prog" 2>&1)

    echo "$lldb_out" | grep -q "stop reason = breakpoint" || {
        echo "error: lldb did not hit breakpoint" >&2
        echo "$lldb_out" >&2
        exit 1
    }
    echo "$lldb_out" | grep -q "prog.astra:3" || {
        echo "error: lldb backtrace does not mention prog.astra:3" >&2
        echo "$lldb_out" >&2
        exit 1
    }
    echo "ok   lldb stopped at prog.astra:3:16"
fi

echo "llvm_dwarf: ok"
