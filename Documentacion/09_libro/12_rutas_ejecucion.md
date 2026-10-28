# Capítulo 12 — Las rutas de ejecución

> **Estado de este capítulo** (2026-10-28): describe las 7 rutas que existen
> hoy y se ejecutaron todas en esta máquina al escribirlo. Las cifras de
> rendimiento citan `Documentacion/07_investigacion/030_benchmarks_llvm_vs_compilados.md`
> (medición del 2026-10-27). Los gates citados se ejecutaron el 2026-10-28.

Hasta ahora has escrito programas Astra y los has corrido con un comando.
Este capítulo responde a otra pregunta: **¿por qué hay siete comandos
distintos para correr el mismo programa, y cuál te conviene?**

La respuesta corta: Astra-0 tiene dos intérpretes de bytecode (el *seed* en C
y el *zig*), un backend a C, y un backend LLVM nativo que puede compilar de
manera anticipada (AOT), ejecutar en proceso (JIT), o apuntar a otros
destinos (wasm32-wasi, aarch64). Todos compilan **el mismo lenguaje** y deben
producir **la misma salida byte a byte** — esa es la propiedad que exigen los
gates diferenciales que verás al final de cada ruta.

El mismo ejemplo corre por las siete rutas de este capítulo:
[`ejemplos/cap12/fib20.astra`](ejemplos/cap12/fib20.astra):

```astra
fn fib(n: i64) -> i64 {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

fn main() {
    print(fib(20))
}
```

Todas las rutas imprimen `6765`.

> **Convención de comandos**: los comandos se ejecutan desde la **raíz del
> repositorio**. Para acortar rutas, define una vez:
>
> ```bash
> EJ=Documentacion/09_libro/ejemplos
> ```

## Ruta 1 — VM seed: el ciclo de desarrollo

```bash
./seed/astra-seed $EJ/cap12/fib20.astra
# salida:
6765
```

`astra-seed` compila a bytecode y lo ejecuta en una VM de pila, en un solo
paso. Es el binario de desarrollo por defecto: arranca en ~1,4 ms, no necesita
nada instalado, y todo el flujo `guardar → correr` cabe en el redoble de una
tecla. **Úsalo mientras programas.**

Si algo falla, sus compañeros de introspección te sacan del apuro — verás
todos en el [capítulo 13](13_toolchain_cli.md):

```bash
./seed/astra-seed --dump-tokens $EJ/cap12/fib20.astra   # ¿qué vio el lexer?
./seed/astra-seed --dump-ast $EJ/cap12/fib20.astra      # ¿qué árbol parseó?
ASTRA_DUMP_VM=1 ./seed/astra-seed $EJ/cap12/fib20.astra # ¿qué bytecode corrió?
```

**La letra pequeña**: la VM seed no libera memoria — cada programa corre sobre
una arena lineal que crece y nunca devuelve nada (medido: 400 MB en el test de
2 M allocaciones de `research/030`). Para programas cortos de desarrollo no
importa; es la razón por la que la VM no es la ruta de producción.

## Ruta 2 — Backend C: compilar a C y enlazar con gcc

```bash
./seed/astra-seed --emit-c $EJ/cap12/fib20.astra   # escribe $EJ/cap12/fib20.c
gcc -Iseed/src -o fib20_c $EJ/cap12/fib20.c -lm
./fib20_c
# salida:
6765
```

El bytecode se traduce a C legible y el C lo compila tu toolchain. Hace dos
cosas útiles: produces un binario nativo sin necesitar LLVM, y puedes
depurar *el programa Astra* con las herramientas de C (`gcc -g` + gdb). El
C generado incluye `codegen_runtime.h` — de ahí el `-Iseed/src`.

**Cuándo usarlo**: cuando quieras un binario nativo en una máquina sin el
backend LLVM, o cuando el programa falle en una ruta LLVM y quieras mirar el C
que produjo el mismo bytecode.

**La letra pequeña**: el backend C compila bytecode, así que hereda el modelo
de memoria de la VM (arena, sin liberación). Es una ruta de portabilidad y
depuración, no de rendimiento.

## Ruta 3 — VM zig: compilar y correr, con el frontend de la Fase 2

```bash
./zig/zig-out/bin/astra-zig $EJ/cap12/fib20.astra
# salida:
6765
```

Mismo formato de comando que la VM seed, otro compilador detrás: `astra-zig`
es el compilador autoalojado en Zig (Fase 2), cuyo frontend Astra-0 ya está
portado y verificado contra la suite del seed. Compila y corre en un paso,
como el seed. Soporta además lo que el seed no: **módulos multifichero** de
verdad (`import`/`use` con resolución de ficheros, `--dump-modules`), y es la
**referencia** contra la que se miden todas las rutas LLVM.

**Cuándo usarlo**: para todo lo que sea módulos (`use`, `pub` — capítulo 10),
y como referencia de semántica cuando dudes qué comportamiento es el correcto:
si el seed y el zig discrepan, es un bug, y el gate de paridad lo caza.

**La letra pequeña**: cuesta ~65 ms de compilación en frío por arranque (mide
`research/030`), y tampoco libera memoria en su VM — misma arena, misma deuda.

## Ruta 4 — LLVM nativo: `--emit-obj` + enlace del runtime

Esta es la ruta de producción. El compilador emite un objeto nativo vía
TargetMachine y tú enlazas contra el *runtime TU* — un fichero C fino sobre
`codegen_runtime.h`. La receta exacta, tal como la corre el gate
`zig/tests/llvm_parity.sh`:

```bash
# 1) emitir el objeto nativo (escribe fib20.o junto al .astra)
./zig/zig-out/bin/astra-zig --emit-obj $EJ/cap12/fib20.astra

# 2) compilar el runtime una vez
cc -c -O2 -std=c11 -Iseed/src \
   zig/src/llvm/runtime/astra_runtime_llvm.c -o runtime.o

# 3) enlazar y correr
cc $EJ/cap12/fib20.o runtime.o -o fib20 -lm
./fib20
# salida:
6765
```

Y la versión optimizada, un solo flag más:

```bash
./zig/zig-out/bin/astra-zig --emit-obj --opt-level=2 $EJ/cap12/fib20.astra
```

**Cuándo usarlo**: siempre que la salida vaya a alguien más que a ti. Arranque
0,8 ms (= C), binario de 23 KB, y — la diferencia grande — **ARC**: cada valor
de heap lleva contador de referencias y se libera al llegar a cero. Donde las
VMs acumulan 400–712 MB, esta ruta se mantiene en 1,2 MB
(`research/030`, medido el 2026-10-27):

| Test (`research/030`) | Astra LLVM | VMs (seed / zig) |
|:----------------------|-----------:|:-----------------|
| 2 M allocaciones, pico RSS | **1,2 MB** | 400 MB / 712 MB |
| 25 000 concatenaciones, pico RSS | **1,4 MB** | 320 MB / 354 MB |

**La letra pequeña**: el emisor LLVM es *single-file* — los programas con
`import` de varios ficheros no compilan por esta ruta (el driver los rechaza
limpiamente con exit 2). Para multifichero, la ruta sigue siendo la VM zig.

> **Nota de PIC**: `--emit-obj` crea el TargetMachine con `LLVMRelocPIC`, así
> que el objeto enlaza con el `cc` default-PIE de la distro sin flags extra.
> Si enlazas un `.ll` a mano vía `llc`, pasa `-relocation-model=pic`.

### Rendimiento frente a lenguajes compilados

La medición completa está en
[`research/030`](../07_investigacion/030_benchmarks_llvm_vs_compilados.md)
(2026-10-27, misma máquina, mínimos de N corridas). El extracto de fib(30)
naive, CPU pura:

| Ruta | Tiempo | vs C -O2 |
|:-----|-------:|---------:|
| C gcc -O2 | **4,9 ms** | 1,0× |
| Rust rustc -O | 7,0 ms | 1,4× |
| Zig ReleaseFast | 7,2 ms | 1,5× |
| Go 1.24 | 10,7 ms | 2,2× |
| **Astra LLVM -O2** | **41,2 ms** | **8,4×** |
| Astra zig-VM (referencia) | 3,79 s | ~770× |
| Astra seed-VM (referencia) | 5,34 s | ~1 090× |

Dos lecturas honestas: la ruta LLVM compite en la liga de los nativos (arranque,
memoria, tamaño de binario), y a CPU pesada aún queda a 8–9× de C — el coste de
un backend en primera iteración, sin escape analysis ni inlining de la llamada
recursiva. Los VMs están dos órdenes de magnitud por debajo: son herramientas de
desarrollo, y el libro no los usa para medir.

## Ruta 5 — `--jit`: compilar y ejecutar en proceso

```bash
./zig/zig-out/bin/astra-zig --jit $EJ/cap12/fib20.astra
# salida:
6765
```

El mismo módulo LLVM de la ruta 4, pero compilado **dentro del propio proceso
del compilador** vía ORC/LLJIT: sin paso de `cc`, sin enlace, sin fichero
intermedio. Comparte el emisor con la ruta AOT, así que acepta exactamente el
mismo subconjunto y produce la misma semántica. Es el cimiento de un futuro
REPL/eval.

**Cuándo usarlo**: cuando quieras la semántica nativa sin tocar el disco de
objetos, o cuando estés en una máquina donde no puedas enlazar (el runtime C
ya viene linclado en `astra-zig`, resuelto por `-rdynamic`).

## Ruta 6 — wasm32-wasi: el navegador y los edge runtimes

```bash
# 1) emitir el objeto para wasm32-wasi
./zig/zig-out/bin/astra-zig --emit-obj --target=wasm32-wasi $EJ/cap12/fib20.astra

# 2) compilar el runtime para wasm (wasi-libc no compila sin esto:
#    Astra usa setjmp/longjmp y wasm lo baja vía Exception Handling)
clang --target=wasm32-wasi -c -O2 -std=c11 -mllvm -wasm-enable-sjlj \
      -I/usr/include/wasm32-wasi -Iseed/src \
      zig/src/llvm/runtime/astra_runtime_llvm.c -o runtime_wasm.o

# 3) enlazar con wasm-ld (crt1.o da el _start; wasi-libc, la libc)
wasm-ld-19 /usr/lib/wasm32-wasi/crt1.o $EJ/cap12/fib20.o runtime_wasm.o \
      -L/usr/lib/wasm32-wasi -lc -o fib20.wasm

# 4) correr bajo el WASI de Node (>= 22)
node --no-warnings demo/wasi_run.mjs fib20.wasm
# salida:
6765
```

**Cuándo usarlo**: para correr Astra donde no hay libc nativa — el WASI de
Node, edge runtimes, sandboxes. `read_file` funciona si el runner declara
`preopens` (el de `demo/wasi_run.mjs` los declara).

**La letra pequeña**: el sysroot de wasi-libc debe traer un `<setjmp.h>`
moderno. **El paquete apt de Ubuntu no lo trae** — usa el tarball oficial de
[wasi-sdk](https://github.com/WebAssembly/wasi-sdk/releases) y apunta
`ASTRA_WASI_SYSROOT` a su `lib/wasm32-wasi`. Y el motor de wasm necesita la
propuesta Exception Handling (Node ≥ 22 / V8 ≥ 12.4); uno viejo trapa al cargar
el módulo. `zig/tests/llvm_wasm.sh` tiene todos los knobs por variable de
entorno.

## Ruta 7 — aarch64 + qemu: compilación cruzada

```bash
# 1) emitir el objeto para aarch64
./zig/zig-out/bin/astra-zig --emit-obj --target=aarch64-linux-gnu $EJ/cap12/fib20.astra

# 2) compilar el runtime con el toolchain cruzado
aarch64-linux-gnu-gcc -c -O2 -std=c11 -Iseed/src \
      zig/src/llvm/runtime/astra_runtime_llvm.c -o runtime_a64.o

# 3) enlazar en cruzado y correr bajo qemu
aarch64-linux-gnu-gcc $EJ/cap12/fib20.o runtime_a64.o -o fib20_a64 -lm
qemu-aarch64-static -L /usr/aarch64-linux-gnu ./fib20_a64
# salida:
6765
```

El módulo LLVM lleva el triple y el datalayout del destino, así que el mismo
`--emit-obj` con otro `--target` sirve para cualquier arquitectura que el
backend conozca (`src/llvm/target.zig` registra todas). **Cuándo usarlo**:
cuando el programa vaya a correr en un dispositivo ARM y quieras probarlo en
tu x86 antes. Requiere `gcc-aarch64-linux-gnu` y `qemu-user-static`; el gate
`zig/tests/llvm_cross.sh` acepta `ASTRA_CROSS_TRIPLE`/`ASTRA_CROSS_CC`/
`ASTRA_QEMU` para otros destinos.

## Qué gate protege cada ruta

Cada ruta tiene un gate diferencial que exige **stdout, stderr y código de
salida byte a byte idénticos a los del VM de referencia**. Todos se ejecutaron
el 2026-10-28 con el compilador `-Dllvm` de esta máquina:

| Ruta | Gate | Resultado (2026-10-28) |
|:-----|:-----|:-----------------------|
| VM seed ↔ VM zig | `zig/tests/dump_parity.sh` + suite de conformance | 184 ficheros, 0 divergente |
| Backend C | `seed/tests/codegen/` vía `make test` | no ejecutado en esta sesión (requiere rebuild del checkout compartido); el circuito está documentado en DEC-014 |
| LLVM nativo | `zig/tests/llvm_parity.sh` | **196/196, 0 skip, 0 fail** |
| LLVM nativo (optimizado) | `ASTRA_LLVM_OPT=2 ./zig/tests/llvm_parity.sh` | 196/196 |
| `--jit` | `zig/tests/llvm_jit.sh` | 196/196 |
| aarch64 + qemu | `zig/tests/llvm_cross.sh` | 196/196 |
| wasm32-wasi | `zig/tests/llvm_wasm.sh` | 196/196 |
| LLVM + ASan | `zig/tests/llvm_sanitize.sh` | 196/196 + LSan sin fugas |
| Fuzz diferencial (4 rutas) | `zig/tests/llvm_fuzz.sh -n 10 -s 1` | fail=0 |
| Memoria (techo 64 MB) | `zig/tests/llvm_mem.sh` | pico 1 244 KB ≤ 65 536 KB |

(AGENTS.md cita estas cifras desde su última actualización; la suite crece con
cada PR — medir tú mismo con los comandos de la tabla es la forma de
actualizarlas.)

Tres matices que importan:

- **Un skip ahora es fallo**. Cada fixture que el emisor LLVM no acepta se
  contaba antes como `skip` y la cobertura podía encoger en silencio — así se
  escondió una regresión DEC-008 durante un merge. Desde ese hallazgo, un skip
  hace fallar el gate; lo que está deliberadamente fuera del subconjunto se
  lista en `EXCLUDE`, con comentario.
- **La referencia es el VM zig**. El seed garantiza por su parte (dump parity +
  conformance) que el VM zig coincide con el seed, así que
  LLVM == VM zig implica LLVM == semántica del seed, por transitividad.
- **`llvm_mem` es el gate de la deuda de memoria** (DEC-009): mide el pico RSS
  de la ruta nativa bajo asignación sostenida y exige un techo plano de 64 MB
  — hoy se queda en 1,2 MB, con ~50× de margen. Es lo que impide que la
  arena de los VMs se cuela en la ruta de producción.

## Flujo recomendado, resumido

| Situación | Ruta |
|:----------|:-----|
| Iterar en el editor | VM seed (ruta 1) |
| Módulos multifichero | VM zig (ruta 3) |
| Depurar lo que el emisor produce | `--emit-c` + gcc -g (ruta 2) |
| Entregar un binario | `--emit-obj` + enlace (ruta 4), con `--opt-level=2` |
| Eval en proceso / REPL futuro | `--jit` (ruta 5) |
| Navegador / edge | wasm32-wasi (ruta 6) |
| Dispositivo ARM | `--target=aarch64-linux-gnu` + qemu (ruta 7) |

## Aún no existe

- **No hay un `astra build --release` unificado**: cada ruta tiene su receta
  (las de arriba) y ninguna las envuelve en un comando. Eso llegará con el
  driver de la Fase 3; hoy se hacen a mano o vía los scripts de gate.
- **No hay distribución de paquetes ni registro**: multifichero funciona
  (capítulo 10), pero no hay dónde publicar módulos.
- **La ruta LLVM no compila multifichero**: el emisor es single-file; los
  programas con `import` se rechazan con exit 2. La semántica de módulos vive
  en las VMs.

## Resumen

- Siete rutas, un lenguaje: seed VM, backend C, zig VM, LLVM AOT, JIT, wasm,
  aarch64 — todas producen la misma salida, y gates diferenciales lo exigen.
- Desarrolla con las VMs (rápidas, introspectables); entrega con la ruta
  LLVM (nativa, ARC, 23 KB).
- La ruta LLVM es la de producción: `--emit-obj` + runtime + `-lm`, con
  `--opt-level=2` cuando importe la CPU.
- Los VMs no liberan memoria (arena); la ruta LLVM sí (ARC, techo de 64 MB
  gateado). Si tu programa corre minutos o usa cientos de MB, no uses VM.
- Si una ruta se porta distinto, es un bug — el gate diferencial lo convierte
  en rojo antes que tú.

## Ejercicios

1. Corre `fib20.astra` por las rutas 1, 3, 4 y 5 y comprueba con `cmp` que
   las cuatro salidas son idénticas byte a byte (haz lo mismo con la salida
   de error: redirige stderr y compáralo).
2. Añade un `print(fib(25))` al final de `main` y vuelve a enlazar la ruta 4
   sin recompilar `runtime.o` — ¿por qué funciona? ¿Cuándo tendrías que
   recompilarlo?
3. Escribe una versión iterativa de `fib` (con `while`), mándala por
   `--jit` y por `--emit-obj --opt-level=2`, y cronometra las dos con
   `time`. ¿Se acerca a los 41 ms de `research/030`?
