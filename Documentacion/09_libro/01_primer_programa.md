# Capítulo 1 — Tu primer programa

En este capítulo escribes el clásico «hola mundo», lo ejecutas en la VM, lo
compilas a un binario nativo y aprendes a leer los errores del compilador.

## El fichero

Crea `hola_mundo.astra` (también está en
[`ejemplos/01/hola_mundo.astra`](ejemplos/01/hola_mundo.astra)):

```astra
fn main() {
    print("Hola, Astra!")
}
```

Eso es todo: una función `main` sin parámetros, sin tipo de retorno y con una
llamada a `print`.

## Anatomía de un fichero

Un fichero de Astra-0 se compone de:

- **comentarios** de línea con `//` y de bloque con `/* … */`;
- **declaraciones**: `fn`, `let`, `let mut`, `struct`, `enum`, …
- **sentencias de nivel de módulo**: se ejecutan **antes** que `main`, en
  orden. En
  [`ejemplos/01/nivel_modulo.astra`](ejemplos/01/nivel_modulo.astra):

  ```astra
  print("module level")

  fn main() {
      print("main")
  }
  ```

  ```text
  $ ../../../../zig/zig-out/bin/astra-zig nivel_modulo.astra
  module level
  main
  ```

- **`main` es el punto de entrada convencional, no obligatorio**: un fichero
  sin `main` termina con código 0 tras ejecutar sus sentencias de nivel de
  módulo (si no tiene ninguna, no imprime nada).

Las sentencias se terminan con **`;` o con salto de línea** — las dos formas
son legales y conviven en el mismo fichero (DEC-011; en este libro usamos `;`
al final de las sentencias y lo dejamos de hacer cuando el código se lee mejor
sin él).

## Ejecutarlo en la VM

```text
$ cd Documentacion/09_libro/ejemplos/01
$ ../../../../zig/zig-out/bin/astra-zig hola_mundo.astra
Hola, Astra!
```

Código de salida 0. Si algo falla (error de compilación o de runtime) el
código de salida es 1, y el diagnóstico va a stderr.

La VM es la ruta de desarrollo: arranca en milisegundos y es la referencia con
la que se comparan todas las demás.

## Compilarlo a un binario nativo

La ruta de producción usa el backend LLVM, así que tu `astra-zig` debe estar
construido con `zig build -Dllvm`. La receta es la que usa el gate
`zig/tests/llvm_parity.sh`: emitir el objeto, compilar el runtime una vez y
enlazar.

```text
$ cd Documentacion/09_libro/ejemplos/01
$ ../../../../zig/zig-out/bin/astra-zig --emit-obj hola_mundo.astra
$ cc -c -O2 -std=c11 -I../../../../seed/src ../../../../zig/src/llvm/runtime/astra_runtime_llvm.c -o runtime.o
$ cc hola_mundo.o runtime.o -o hola_mundo -lm
$ ./hola_mundo
Hola, Astra!
```

Tres pasos, tres notas:

1. `--emit-obj` deja `hola_mundo.o` **junto al fichero fuente** (el
   compilador no usa `llc` externo: el objeto sale del `TargetMachine`).
2. El runtime (`astra_runtime_llvm.c`) es una sola traducción que incluye
   `codegen_runtime.h` del seed; se compila **una vez** y vale para todos tus
   programas.
3. El enlace necesita `-lm`.

### Otras dos rutas, para que sepas que existen

- **JIT en proceso** (mismo compilador, sin paso de enlace):

  ```text
  $ ../../../../zig/zig-out/bin/astra-zig --jit hola_mundo.astra
  Hola, Astra!
  ```

- **Backend C del compilador semilla** (bytecode → C → `cc`):

  ```text
  $ ../../../../seed/astra-seed --emit-c hola_mundo.astra
  $ cc -Wall -Wextra -I../../../../seed/src -o hola_mundo_c hola_mundo.c -lm
  $ ./hola_mundo_c
  Hola, Astra!
  ```

Las siete rutas en detalle (VM semilla, VM zig, C, LLVM `--emit-obj`, JIT,
cross, wasm) están en el capítulo 12.

## Errores de compilación: `fichero:línea:columna`

Los diagnósticos llevan **fichero, línea y columna**. Este fichero, en
[`ejemplos/01/error_sintaxis.astra`](ejemplos/01/error_sintaxis.astra), olvida
un paréntesis:

```astra
fn main() {
    print("hola"
}
```

Con el compilador Zig:

```text
$ ../../../../zig/zig-out/bin/astra-zig error_sintaxis.astra
error_sintaxis.astra:2:17: error: expected ')', got NEWLINE
error_sintaxis.astra:3:1: error: unexpected token in expression
```

Con el compilador semilla la **primera línea es idéntica** (esa paridad es una
puerta del proyecto) y además resume el resultado:

```text
$ ../../../../seed/astra-seed error_sintaxis.astra
error_sintaxis.astra:2:17: error: expected ')', got NEWLINE
error: parse failed
```

Ambos salen con código 1. La columna apunta al token que causó el problema:
`2:17` es la posición justo después de `"hola"`, donde faltaba `)`.

Cuando el error sea más difícil de entender, dos switches de diagnóstico te
muestran lo que el compilador ve: `--dump-tokens` (la salida del lexer) y
`--dump-ast` (el árbol parseado):

```bash
../../../../zig/zig-out/bin/astra-zig --dump-tokens hola_mundo.astra
../../../../zig/zig-out/bin/astra-zig --dump-ast hola_mundo.astra
```

(Se ejecutan desde la carpeta del capítulo; no los pegamos aquí porque su
salida es larga y no aporta al flujo normal de trabajo.)

---

## Resumen

- Un fichero de Astra-0 tiene sentencias de nivel de módulo (que se ejecutan
  primero) y declaraciones; `fn main()` es el punto de entrada convencional.
- Las sentencias terminan en `;` o en salto de línea (DEC-011).
- `zig/zig-out/bin/astra-zig f.astra` ejecuta en la VM; `--emit-obj` + dos
  `cc` producen un binario nativo (receta de `zig/tests/llvm_parity.sh`);
  `--jit` ejecuta en proceso.
- Los errores son `fichero:línea:columna: error: mensaje` y salen con código 1;
  la primera línea coincide entre seed y Zig.

## Ejercicios

1. Cambia el texto de `hola_mundo.astra` y vuelve a ejecutarlo en la VM. Después
   compílalo a objeto y enlázalo: ¿el binario nativo imprime lo mismo?
2. Escribe a propósito un error de tipo (por ejemplo, `let x: i32 = "texto"`)
   y localiza línea y columna en el diagnóstico. Compara el mensaje con el del
   otro compilador: ¿es idéntico?
3. Añade una sentencia de nivel de módulo `print("primero")` delante de
   `main` y observa el orden de la salida. ¿Qué pasa si pones esa misma
   sentencia **después** de la definición de `main`?
