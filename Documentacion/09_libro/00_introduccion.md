# Capítulo 0 — Qué es Astra hoy

Bienvenido al libro de usuario de Astra. Este libro describe el lenguaje **tal
como es hoy**, no como estará algún día: cada ejemplo se ejecutó de verdad y
cada límite se dice con su nombre. Cuando algo existe solo en la especificación,
lo verás marcado como *Aún no existe*.

## Por qué este libro

Astra es un lenguaje compilado, **multi-paradigma**, que apunta a la ergonomía
de Python/TypeScript y al rendimiento de C/Rust, sin borrow checker y sin
pausas de GC (los pilares están en
[`ARCHITECTURE.md` §1](../01_lenguaje/ARCHITECTURE.md)). La promesa de diseño
es ambiciosa; este libro se ocupa de lo que hoy puedes escribir, compilar y
ejecutar.

## Astra-0: el subconjunto que existe

Lo que se ejecuta hoy se llama **Astra-0**: el subconjunto mínimo definido por
el compilador semilla (`seed/`) y portado por el compilador de la Fase 2
(`zig/`). Astra-0 incluye:

- tipos `i32`/`i64`/`u32`/`u64`/`f64`/`bool`/`string` y arrays;
- `let`/`let mut`, `if`/`else`, `while`, `for..in` con `break`/`continue`;
- funciones con parámetros anotados, `return` explícito e implícito,
  recursión y closures (captura por valor);
- structs, enums, `match` (con guards y or-patterns), Option/Result con el
  operador `?`;
- genéricos monomorfizados y traits con `impl`;
- cinco primitivas de E/S: `print`, `len`, `to_string`, `read_file` y el
  índice de string `s[i]`.

El **sistema de módulos multi-fichero** (`use`, `pub`, rutas `@/`) solo
existe en el compilador Zig de la Fase 2: el seed trata las declaraciones de
módulo como inertes, a propósito (los fixtures `module/` fijan ese
comportamiento).

La lista completa, con el estado de cada pieza, está en
[`Documentacion/00_indice/INDICE.md`](../00_indice/INDICE.md) — allí vive la
única fuente de verdad del estado del proyecto; este libro la refleja, no la
sustituye.

## Qué puedes hacer ya

Este programa usa funciones, closures, arrays, strings y los bucles; está en
[`ejemplos/00/presentacion.astra`](ejemplos/00/presentacion.astra):

```astra
// Lo que Astra-0 hace hoy: funciones, closures, arrays, strings y control de flujo.
fn saludar(nombre: string) -> string {
    "Hola, " + nombre
}

fn main() {
    print(saludar("Astra"));

    let nums = [3, 1, 4, 1, 5];
    let mut total = 0;
    for n in nums {
        total = total + n;
    }
    print(total);

    let mut i: i64 = 0;
    while i < len(nums) {
        print(nums[i]);
        i = i + 1;
    }

    let doble = |x: i32| -> i32 { x * 2 };
    print(doble(21));
}
```

Ejecutado con la VM del compilador Zig (la receta completa está en el
[capítulo 1](01_primer_programa.md)):

```text
$ cd Documentacion/09_libro/ejemplos/00
$ ../../../../zig/zig-out/bin/astra-zig presentacion.astra
Hola, Astra
14
3
1
4
1
5
42
```

Fíjate en dos cosas del ejemplo: `i` se anota `i64` porque `len` devuelve `i64`
(DEC-013, y el detalle está en el [capítulo 2](02_variables_tipos.md)), y el
closure `doble` no captura nada: solo usa su parámetro.

### La prueba de que el lenguaje se sostiene: el lexer self-hosteado

`seed/tests/selfhost/lexer.astra` es un **lexer completo escrito en Astra-0**:
lee `lexer_input.astra` con `read_file` y emite un token por línea
(`KEYWORD:fn@1`, `IDENT:fib@1`, …). Es el primer componente self-hosting de la
cadena de bootstrap (DEC-016, cerrado en DEC-017 con 7 rutas de ejecución):

```text
$ cd seed/tests/selfhost
$ ../../astra-seed lexer.astra | head -8
KEYWORD:struct@9
IDENT:Point@9
SYMBOL:{@9
IDENT:x@10
SYMBOL::@10
IDENT:i32@10
IDENT:y@11
SYMBOL::@11
```

Su salida completa (179 líneas) es byte-idéntica al golden commiteado
`lexer.expected`, y el gate `seed/tests/selfhost/lexer_gate.sh` lo comprueba en
las 7 rutas (VM semilla, `--emit-c` + gcc, VM zig, `--jit`, `--emit-obj` +
enlace, cross aarch64 bajo qemu y wasm32-wasi bajo Node). Si el lenguaje no
pudiera expresar un lexer, ese gate no existiría.

## Qué no existe aún

Sé honesto contigo desde el principio:

- **Fibras (hilos verdes) y ARC/ORC**: **especificados, no implementados**. La
  regla de frontera entre fibras vive en
  [`ARCHITECTURE.md` §2.6](../01_lenguaje/ARCHITECTURE.md) y su decisión,
  DEC-012, sigue en estado `Propuesta`. Hoy no hay `spawn`, no hay `transfer`
  y los VMs no liberan memoria (DEC-009: la ruta LLVM libera con ARC; los VMs
  son arena). Detalles en el capítulo 11.
- **`comptime`**: especificado en `ARCHITECTURE.md` §12, no implementado.
- **stdlib amplia**: el diseño prevé ~64 módulos (red, JSON, HTTP, crypto…);
  hoy hay cinco primitivas. Las siguientes — `ord`, `substr`, `push`,
  `str_to_int` — están en ramas de trabajo **sin fusionar a `main`** (DEC-018
  las cubre en su rama; `push`/`str_to_int` siguen en preparación): no las
  uses hasta que aparezcan en tu binario.
- **`val` / `var`**: no son palabras clave. La forma canónica es
  `let` / `let mut` (decisión del 2026-09-16,
  [`ARCHITECTURE.md` §8.1](../01_lenguaje/ARCHITECTURE.md)); `val x = 1` hoy
  produce `undefined variable 'val'` — lo ves en el capítulo 2.
- **Gestor de paquetes, LSP, REPL, FFI con Python**: especificados, pendientes.

Cada capítulo termina con su sección *Aún no existe* cuando el tema la tiene.

## Instalación y construcción

Requisitos:

- **Zig 0.16.x** para el compilador de la Fase 2 (el que usarás en este libro);
- **gcc** (o `cc`) para el compilador semilla y para enlazar los binarios
  nativos;
- para la ruta LLVM, **LLVM 19..23** con su `llvm-config` (opcional).

```bash
# Compilador semilla (C) -> seed/astra-seed
cd seed && make            # desarrollo (-g -O0); make debug = ASan/UBSan/LSan; make test = suite
cd ..

# Compilador Zig (el de este libro) -> zig/zig-out/bin/astra-zig
zig build                  # sin LLVM: VM, dumps, módulos, debugger
zig build -Dllvm           # además: --emit-llvm / --emit-obj / --jit
```

Sin `-Dllvm`, el binario conserva el frontend y la VM; solo cambian los modos
de salida nativos, que se rechazan con el mensaje de `zig/src/main.zig`:

```text
error: the LLVM backend output modes (--emit-llvm / --emit-llvm-stdout / --emit-obj / --jit) require the compiler to be built with `-Dllvm` (LLVM 19..23 via llvm-config)
```

`zig build -Dllvm` descubre el compilador LLVM con
`ASTRA_LLVM_CONFIG` (variable de entorno) → `llvm-config` del PATH →
`llvm-config-19` … `llvm-config-23`. En Debian/Ubuntu,
`apt install llvm-19-dev` deja `llvm-config-19` en el sitio exacto que
`build.zig` prueba.

## Cómo ejecutar los ejemplos de este libro

Todos los ejemplos viven en [`ejemplos/`](ejemplos/) y se ejecutan desde la
carpeta de su capítulo, con el binario relativo a la raíz del repositorio:

```text
$ cd Documentacion/09_libro/ejemplos/02
$ ../../../../zig/zig-out/bin/astra-zig tipos_anotados.astra
```

(En este libro el prompt `$` muestra el comando tal cual se ejecutó; la salida
que ves debajo es la salida real, sin editar.) Cuando el ejemplo es un error de
compilación, la salida es el diagnóstico y el código de salida es 1.

---

## Resumen

- **Astra hoy = Astra-0**: el subconjunto que los dos compiladores aceptan y
  que la suite de conformidad fija.
- Hay **dos compiladores**: `seed/` (C, la referencia de comportamiento) y
  `zig/` (el auto-hospedado, el que usarás); además de la VM hay rutas de
  ejecución nativa (C, LLVM, JIT, cross, wasm) — capítulo 12.
- El **lexer escrito en Astra-0** es la prueba de que el lenguaje ya se
  sostiene solo (DEC-016/DEC-017).
- **No existen** fibras/ARC (especificado, no implementado — DEC-012),
  `comptime` ni una stdlib amplia.
- Se construye con `zig build` (Zig 0.16) y, opcionalmente,
  `zig build -Dllvm` con LLVM 19..23.

## Ejercicios

1. Escribe un fichero `saludo.astra` con un `fn main()` que imprima tu nombre
   y ejecútalo con la VM. Después, sin cambiar el programa, pásalo por
   `--emit-obj` y enlázalo como se explica en el capítulo 1.
2. En `seed/tests/selfhost/lexer.astra`, busca un `match` con or-patterns
   (la función `is_alpha`) y ejecuta el lexer para ver qué token produce una
   letra. ¿Y qué produce `$`?
3. Comprueba en tu binario que `val` no existe: escribe `val x = 1` en un
   fichero y lee el diagnóstico. ¿Y `var x = 1`?
