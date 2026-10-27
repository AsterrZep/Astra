#!/usr/bin/env bash
# Compila la suite de benchmarks (030) en las 6 rutas: Astra LLVM O0/O2,
# Rust, Go, C, Zig. Requiere: astra-zig (-Dllvm), rustc, go, gcc, zig.
set -e
cd "$(dirname "$0")"

REPO="$(cd ../../.. && pwd)"
ASTRA="$REPO/zig/zig-out/bin/astra-zig"

# Runtime TU de LLVM (misma receta que zig/tests/llvm_parity.sh)
cc -c -O2 -std=c11 -I"$REPO/seed/src" \
   "$REPO/zig/src/llvm/runtime/astra_runtime_llvm.c" -o runtime.o

for t in fib30 alloc2m str25k startup; do
  "$ASTRA" --emit-obj "$t.astra" >/dev/null
  cc "$t.o" runtime.o -o "${t}_astra_O0" -lm
  "$ASTRA" --emit-obj --opt-level=2 "$t.astra" >/dev/null
  cc "$t.o" runtime.o -o "${t}_astra_O2" -lm
  rm -f "$t.o"

  rustc -O "$t.rs" -o "${t}_rust"
  go build -o "${t}_go" "$t.go"
  gcc -O2 -std=c11 "$t.c" -o "${t}_c"
  zig build-exe "$t.zig" -OReleaseFast -femit-bin="${t}_zig"
done

# Filas de coste real de Rust (sin elisión del optimizer): B2 y B3
rustc -C opt-level=0 alloc2m.rs -o alloc2m_rust_O0
rustc -C opt-level=0 str25k.rs  -o str25k_rust_O0

echo "build ok: $(ls -d *_astra_O0 *_astra_O2 *_rust *_go *_c *_zig 2>/dev/null | wc -l) binarios"
