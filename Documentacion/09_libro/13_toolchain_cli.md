# Capítulo 13 — Toolchain: los comandos del día a día

> **Estado de este capítulo** (2026-10-28): los comandos de uso se ejecutaron
> en esta máquina contra los binarios existentes de `seed/astra-seed` (0.1.0)
> y `zig/zig-out/bin/astra-zig`, y las salidas pegadas son reales. Las órdenes
> de *build* (`make -C seed`, `zig build`) están tomadas de AGENTS.md y no se
> re-ejecutaron al escribir el capítulo (los binarios ya existían).

El [capítulo 12](12_rutas_ejecucion.md) cubrió *correr* programas por las siete
rutas. Este capítulo es el manual de tu caja de herramientas: cómo se
construyen los dos compiladores, qué banderas tienen, y qué te cuentan los
dumps cuando algo no hace lo esperado.

## Los dos compiladores

Astra tiene hoy **dos** compiladores de Astra-0:

- **`seed/astra-seed`** — el compilador semilla en C (Fase 1). Un solo binario
  que hace todo: lex, parse, typecheck, emisor de bytecode, VM, y backend C.
- **`zig/zig-out/bin/astra-zig`** — el compilador autoalojado en Zig (Fase 2).
  Frontend portado y verificado contra la suite del seed, VM propia, sistema de
  módulos real, y — si se construye con `-Dllvm` — el backend LLVM nativo.

No hay (todavía) un único ejecutable `astra`. Ver «Aún no existe», al final.

> **Convención de comandos**: los comandos se ejecutan desde la **raíz del
> repositorio**. Para acortar rutas, define una vez:
>
> ```bash
> EJ=Documentacion/09_libro/ejemplos
> ```

### Cómo se construyen

```bash
# Compilador seed (desarrollo, con -g -O0)
make -C seed
# → seed/astra-seed

# Variantes del seed
make -C seed debug     # ASan + UBSan + LSan (el recomendado mientras desarrollas)
make -C seed release   # gcc -O2
make -C seed test      # la suite completa (conformance + codegen)

# Compilador zig (requiere Zig 0.16.x)
cd zig
zig build              # → zig-out/bin/astra-zig (sin LLVM)
zig build -Dllvm       # lo mismo + backend LLVM (requiere llvm-config 19..23)
zig build test         # unit tests + conformance sobre seed/tests/conformance
```

Cada variante del seed compila en su propio árbol de objetos
(`build/debug`, `build/release`) — nunca compartas `build/` entre variantes:
los flags no forman parte del timestamp del objeto y mezclarlos enlaza objetos
incompatibles.

**`-Dllvm` es estrictamente opt-in**: sin él, el binario zig es byte-idéntico
al de antes y ninguna puerta existente cambia. Con él se habilitan
`--emit-llvm`, `--emit-obj`, `--jit` y las banderas relacionadas.

## `astra-seed` — referencia de banderas

```
Usage: astra-seed [options] <file.astra>

Options:
  --help           Show this help message
  --version        Show version
  --dump-tokens    Lex and dump all tokens
  --dump-ast       Parse and dump the AST
  --dump-bytecode  Compile and dump the bytecode (does not run it)
  --dump-constructs  Dump the construct registry (grammar, research, deps)
  --dump-operators   Dump the operator precedence table
  --check-constructs Check registry invariants; exit 1 on failure
  --emit-c         Generate C code to <file>.c
```

Sin bandera, compila y corre en su VM. Los dumps más usados, con el programa
mínimo [`ejemplos/cap13/hola_dump.astra`](ejemplos/cap13/hola_dump.astra):

```astra
fn sum(a: i64, b: i64) -> i64 {
    return a + b
}

fn main() {
    let total = sum(2, 3)
    print(total)
}
```

### `--dump-tokens`: ¿qué vio el lexer?

```bash
./seed/astra-seed --dump-tokens $EJ/cap13/hola_dump.astra | head -6
# salida:
1:63  NEWLINE
2:1  fn
2:4  IDENT           "sum"
2:7  (
2:8  IDENT           "a"
2:9  :
```

Cada línea es `línea:columna  tipo  léxico`. Cuando un programa no parsea y
no ves por qué, la primera pregunta es si el lexer partió el código donde
creías — sobre todo con strings, comentarios anidados o caracteres raros.

### `--dump-ast`: ¿qué árbol construyó el parser?

```bash
./seed/astra-seed --dump-ast $EJ/cap13/hola_dump.astra | head -10
# salida:
Module
  FnDecl(sum)
    Param(a)
      TypeIdent(i64)
    Param(b)
      TypeIdent(i64)
    ReturnType
      TypeIdent(i64)
    Block
      Return
```

El árbol con sangría, un nodo por línea. Útil para confirmar precedencias y
qué rama de un `if`/`match` quedó colgando de qué.

### `--dump-bytecode`: ¿qué va a ejecutar la VM?

```bash
./seed/astra-seed --dump-bytecode $EJ/cap13/hola_dump.astra
# salida:
=== Bytecode (7 instructions, 5 constants) ===
  [  0] CONST            0 (<fn>)
  [  1] SET_GLOBAL       1
  [  2] CONST            2 (<fn>)
  [  3] SET_GLOBAL       3
  [  4] GET_GLOBAL       4
  [  5] CALL             argc=0
  [  6] HALT
=== End bytecode ===
```

(Sin `--dump-bytecode`, `ASTRA_DUMP_VM=1 astra-seed f.astra` imprime lo mismo
**y** corre el programa; `ASTRA_TRACE=1` traza la pila instrucción a
instrucción — el depurador de nivel bajo de la VM seed.)

### `--emit-c`: el programa en C

```bash
./seed/astra-seed --emit-c $EJ/cap13/hola_dump.astra
# escribe $EJ/cap13/hola_dump.c junto al .astra; enlázalo con:
gcc -Iseed/src -o hola $EJ/cap13/hola_dump.c -lm
```

Recuerda el `-Isrc`: el C generado incluye `codegen_runtime.h`.

### `--check-constructs` y `--dump-constructs`: el registro

```bash
./seed/astra-seed --check-constructs
# salida:
construct registry: 47 constructs
sub-constructs: 14
migrated (all three phases): 0 / 47 (hooks aspirational — see CONSTRUCT_REGISTRY.md §8)
operator table: 27 entries
OK — registry, lexer, parser and operator table agree
```

El registro de constructos es la tabla documental que amarra cada producción
de la gramática a su investigación y a sus dependencias; `--check-constructs`
demuestra que el lexer, el parser y la tabla de operadores siguen de acuerdo.
Sale con 0 o falla. `--dump-constructs` imprime el registro entero (gramática
EBNF, informe de investigación, deps, fases por constructo) y
`--dump-operators` la tabla de precedencias — `||` en 3, `&&` en 4, `==`/`!=`
en 8, …, 27 filas en total.

## `astra-zig` — referencia de banderas

`astra-zig` no tiene `--help`; sin argumentos (o con una bandera desconocida)
imprime su uso:

```
usage: astra-zig [--single-file] [--dump-tokens | --dump-ast | --dump-modules | --dump-bytecode | --emit-llvm | --emit-llvm-stdout | --emit-obj | --jit | --debug] <file.astra>

  (no flag)              compile and run, exit 1 on a compile or runtime error
  --single-file          ignore `import`/`from`/`use` and compile only the entry
                         file (seed semantics; needed for module-decl fixtures)
  --dump-tokens          print the token stream
  --dump-ast             print the parsed AST
  --dump-modules         load and print the module graph (files reached, cycles reported)
  --dump-bytecode        print the emitted bytecode
  --emit-llvm            write LLVM IR to <file>.ll (requires -Dllvm)
  --emit-llvm-stdout     print LLVM IR to stdout (requires -Dllvm)
  --emit-obj             compile to a native object <file>.o via TargetMachine (requires -Dllvm)
  --jit                  compile and run in-process via ORC/LLJIT (requires -Dllvm; host-only)
  --opt-level=N          optimize the LLVM module before emitting (N = 0..3; 0 default)
  --debug-info           emit DWARF line tables (lldb/gdb stop on Astra lines)
  --sanitize=address     instrument the module with AddressSanitizer
                         (needs an LLVM output mode; link with -fsanitize=address)
  --target=<triple>      cross-compile for <triple>, e.g. aarch64-linux-gnu
                         (needs an LLVM output mode; default = host triple)
  --fast-math            mark FP arithmetic with fast-math flags (NaN/Inf/
                         reassociation allowed; needs an LLVM output mode)
  --debug                run under the interactive bytecode debugger (stdin)
```

Los dumps de tokens/AST/bytecode son byte-idénticos a los del seed — eso lo
exige el gate de paridad de dumps (`zig/tests/dump_parity.sh`), que hoy corre
sobre 184 ficheros con 0 divergente. Lo que el seed **no** tiene:

### `--dump-modules`: el grafo de módulos

Con el ejemplo de dos ficheros
[`ejemplos/cap13/mods/`](ejemplos/cap13/mods/) (`main.astra` hace
`import util`; `util.astra` exporta `doble` con `pub`):

```bash
./zig/zig-out/bin/astra-zig --dump-modules $EJ/cap13/mods/main.astra
# salida:
module graph: 2 module(s)
  mods/util.astra
    exports: doble
  mods/main.astra
    import util -> mods/util.astra
```

Ves qué ficheros se alcanzan, qué exporta cada uno y hacia dónde apunta cada
`import`. Un ciclo se reporta aquí; un fichero que no se encuentra, también.
Y sin bandera, el mismo programa corre:

```bash
./zig/zig-out/bin/astra-zig $EJ/cap13/mods/main.astra
# salida:
42
```

### `--emit-llvm-stdout`: mirar el IR

```bash
./zig/zig-out/bin/astra-zig --emit-llvm-stdout $EJ/cap13/hola_dump.astra | head -5
# salida:
; ModuleID = 'astra_llvm'
source_filename = "astra_llvm"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-linux-gnu"

@astra_llvm_depth = internal global i64 0
```

`--emit-llvm` hace lo mismo escribiendo `<fichero>.ll`. Es el puente entre
Astra y todo lo que entiende LLVM IR; los tests de forma (`llvm_filecheck.sh`)
fijan estas siluetas con FileCheck.

### `--debug`: el depurador interactivo de bytecode

```bash
./zig/zig-out/bin/astra-zig --debug $EJ/cap13/debug_ejemplo.astra
```

Sesión real sobre [`ejemplos/cap13/debug_ejemplo.astra`](ejemplos/cap13/debug_ejemplo.astra)
(`let c = a * b` es la línea 7; el depurador re-imprime la ubicación antes de
cada prompt — aquí se comprime por brevedad, las salidas son reales):

```
-- line 4: fn main() {
[pc=0] CONST
b 7
breakpoint set on line 7
c
-- line 7:     let c = a * b
[pc=4] GET_LOCAL
p
stack (3): [<fn>] [6] [7]
l
locals (base=0, sp=3):
  [0] <fn>
  [1] 6
  [2] 7
bt
call stack (1 frame(s)):
  #0  base=0 pc=4 (current)
  #1  base=0 ret_pc=4
q
```

Comandos: `c` (continue), `s` (step, una instrucción), `b <línea>` (punto de
ruptura por línea Astra), `d <línea>` (quitar), `p`/`stack` (pila de
operandos), `l`/`locals` (slots del frame actual), `bt` (frames), `q` (salir).
Empieza siempre con `h` si lo olvidas.

### Las banderas LLVM en un solo bloc de notas

| Bandera | Efecto |
|:--------|:-------|
| `--opt-level=N` (0..3) | pipeline new-PM: `default<O2>` + LICM / loop-unswitch / IRCE para N=2 |
| `--debug-info` | DWARF line tables — lldb/gdb paran en líneas Astra |
| `--sanitize=address` | instrumenta el módulo; enlaza con `-fsanitize=address` (sin eso, el enlace falla a propósito) |
| `--target=<triple>` | objeto para otro target (aarch64, wasm32-wasi, …) |
| `--fast-math` | marca TODO el aritmético FP con fast-math flags; sin la bandera el IR es byte-idéntico |
| `--jit` | compila y corre en proceso vía ORC/LLJIT, sin `cc` ni enlace |

## Los gates de self-hosting: 7 rutas para un mismo fichero

`seed/tests/selfhost/` guarda los primeros componentes escritos **en Astra-0**
— un lexer (`lexer.astra`) y una lectura de fichero (`read_positive.astra`) —
y sus gates los corren por todas las rutas exigibles, comparando contra un
golden cometido.

### `io_gate.sh` — read_file por 4 rutas

```bash
./seed/tests/selfhost/io_gate.sh
# salida:
ok   seed VM
ok   C backend (--emit-c + gcc)
ok   zig VM
ok   LLVM (--jit)

io_gate: every route matches read.expected
```

El mismo `read_positive.astra`, el mismo golden `read.expected`, cuatro rutas
distintas. El script fija el `cwd` él mismo — cada gate corre desde un
directorio distinto (`seed/`, `zig/`, raíz) y `read_file` usa ruta relativa
(`research/028` §2.4).

### `lexer_gate.sh` — el lexer self-hosteado por 7 rutas

```bash
./seed/tests/selfhost/lexer_gate.sh
# salida (últimas líneas):
ok   seed VM
ok   C backend (--emit-c + gcc)
ok   zig VM
ok   LLVM (--jit)
ok   LLVM (--emit-obj + link)
ok   LLVM cross aarch64-linux-gnu (--emit-obj --target + qemu)
ok   LLVM wasm32-wasi (--emit-obj --target + Node WASI)
ok   lexer_tokens_parity (176 tokens: KEYWORD/IDENT/INT/PUNCT/STR/ERROR vs --dump-tokens)

lexer_gate: every route matches lexer.expected; token-stream parity holds
```

Un lexer escrito en Astra-0 que lee un fichero Astra y emite un token por
línea. Las siete rutas del [capítulo 12](12_rutas_ejecucion.md) reproduciendo
el golden byte a byte — y encima, `lexer_tokens_parity.sh` compara el flujo de
tokens del lexer-Astra contra `astra-seed --dump-tokens`: el compilador
escrito en su propio lenguaje debe ver los mismos tokens que el compilador C.
Ese es el corazón del plan de autoalojamiento: cada paso de la cadena bootstrap
se gana su gate antes de que el siguiente se apoye en él.

## Variables de entorno que vale la pena conocer

| Variable | Efecto |
|:---------|:-------|
| `ASTRA_DUMP_VM=1` | imprime el bytecode de la VM seed y corre |
| `ASTRA_TRACE=1` | traza la pila por instrucción (VM seed) |

Y para los gates LLVM: `ASTRA_LLVM_OPT`, `ASTRA_LLVM_SAN`, `ASTRA_LLVM_CONFIG`,
`ASTRA_MEM_CEILING_KB`, `ASTRA_CROSS_TRIPLE`/`ASTRA_CROSS_CC`/`ASTRA_QEMU`,
`ASTRA_WASM_LD`/`ASTRA_WASI_SYSROOT`/`ASTRA_WASM_NODE`/`ASTRA_WASM_CLANG` —
todos documentados en la cabecera de su script.

## Aún no existe

- **No hay CLI unificada `astra build` / `astra run`** — «Aún no existe». Hoy
  cada ruta tiene su receta (capítulo 12) y cada compilador sus banderas. Un
  driver que las envuelva está previsto para la Fase 3; mientras tanto, este
  capítulo es el mapa de comandos.
- **No hay `astra fmt`, `astra test`, `astra doc`**. El formateador y el
  gestor de tests de proyecto no existen; la verificación se hace con los
  scripts de gate tal cual.
- **`astra-zig` no tiene `--help` ni `--version`** (el seed sí los tiene
  ambos). Sin argumentos imprime el uso — la bandera `-h` da error, no ayuda.

## Resumen

- Dos compiladores: `astra-seed` (C, Fase 1, incluye VM + backend C) y
  `astra-zig` (Zig, Fase 2, módulos + backend LLVM con `-Dllvm`).
- Los dumps (`--dump-tokens`, `--dump-ast`, `--dump-bytecode`) son idénticos
  en ambos — el gate de paridad de dumps lo garantiza sobre 184 ficheros.
- `--check-constructs` es la brújula cuando tocas la gramática: registro,
  lexer, parser y tabla de operadores, o rojo.
- `--debug` depura bytecode de Astra con puntos de ruptura por línea fuente.
- Los gates de selfhost (`io_gate.sh`, `lexer_gate.sh`) son el patrón del
  proyecto: un comportamiento, muchas rutas, un golden, cero divergencias.
- No hay `astra build`: las recetas de este capítulo y del 12 *son* la
  toolchain de hoy.

## Ejercicios

1. Toma un programa que falle y recorre la cadena `--dump-tokens` →
   `--dump-ast` → `--dump-bytecode` con el seed, y `--dump-modules` con el
   zig. ¿En qué fase se rompe por primera vez?
2. Añade un `pub fn triple(n: i64) -> i64` a `util.astra`, úsalo desde
   `main.astra` y vuelve a mirar `--dump-modules`: el grafo crece pero el
   formato no cambia. ¿Qué verías si hicieras un ciclo `import` entre los dos?
3. Corre `lexer_gate.sh` con `ASTRA_WASI_SYSROOT=/no_existe` (verificado:
   `skip LLVM wasm32-wasi (wasm-ld / wasi sysroot / clang / node>=22 not all
   found)` y el gate sigue en verde). ¿Por qué un skip aquí no es un fallo,
   mientras que un skip en `llvm_parity.sh` sí lo es?
