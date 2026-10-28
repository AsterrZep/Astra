# Capítulo 2 — Variables y tipos

Aquí es donde Astra empieza a tomar decisiones delante de ti: cómo se declara
una variable, qué tipos hay, qué pasa cuando un número no cabe y qué puedes (y
no puedes) hacer con un binding.

## `let` y `let mut`

La inmutabilidad es el defecto. En
[`ejemplos/02/inmutabilidad.astra`](ejemplos/02/inmutabilidad.astra):

```astra
// `let` es inmutable; `let mut` permite reasignar (ARCHITECTURE §8.1 / §30.2).
fn main() {
    let mut contador = 0;
    contador = contador + 1;
    contador = contador + 1;
    let nombre = "Astra";
    print(contador);
    print(nombre);
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig inmutabilidad.astra
2
Astra
```

Si reasignas un binding creado con `let`, el compilador lo para —
[`error_inmutable.astra`](ejemplos/02/error_inmutable.astra):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_inmutable.astra
error_inmutable.astra:3:5: error: cannot assign to immutable variable 'x'
```

### `const` para lo que no cambia

Además de `let`, existe `const`: declara una constante **inmutable** (reasignarla
da el mismo `cannot assign to immutable variable` que un `let`), en nivel de
módulo y dentro de funciones. En
[`constante.astra`](ejemplos/02/constante.astra):

```astra
// `const` también existe: constante de nivel de módulo o local.
const VERSION = 1

fn main() {
    const local = 3
    print(VERSION)
    print(local)
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig constante.astra
1
3
```

### No hay `val` ni `var`

Son palabras de otras versiones del diseño que **no existen en Astra-0**: la
forma canónica es `let` / `let mut` (decisión del 2026-09-16,
[`ARCHITECTURE.md` §8.1](../01_lenguaje/ARCHITECTURE.md)). `val x = 1` hoy
deja `val` como un identificador cualquiera y el compilador no lo encuentra
([`error_val.astra`](ejemplos/02/error_val.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_val.astra
error_val.astra:3:1: error: undefined variable 'val'
error_val.astra:3:5: error: undefined variable 'x'
```

`var` ni siquiera llega a parsear: `var x = 1` produce
`error: unexpected token in expression` en los dos compiladores.

### La inmutabilidad protege el binding, no el objeto

`let` impide reasignar el nombre, pero **no convierte en inmutables los
arrays o structs que guarda**: `let a = [1,2,3]` es un handle, y si mutas el
objeto por otro binding lo verás por ambos (DEC-001/DEC-002). Ese contrato de
aliasing tiene capítulo propio: [capítulo 5](05_arrays_structs.md).

## Los tipos de Astra-0

| Tipo | Ejemplo | Notas |
|:-----|:--------|:------|
| `i32` | `let a: i32 = 42` | entero con signo, **default** de los literales (DEC-006) |
| `i64` | `let b: i64 = 9007199254740993` | entero con signo de 64 bits; es lo que devuelve `len` (DEC-013) |
| `u32` | `let c: u32 = 4294967295` | sin signo |
| `u64` | `let d: u64 = 9223372036854775807` | sin signo de 64 bits |
| `f64` | `let e: f64 = 3.5` | doble precisión; `print` lo imprime con `%g` (DEC-010) |
| `bool` | `let f: bool = true` | `true` / `false` |
| `string` | `let g: string = "texto"` | inmutable; `s[i]` devuelve un string de 1 byte (DEC-013) |

El ejemplo completo está en
[`tipos_anotados.astra`](ejemplos/02/tipos_anotados.astra):

```text
$ ../../../../zig/zig-out/bin/astra-zig tipos_anotados.astra
42
9007199254740993
4294967295
9223372036854775807
3.5
true
texto
```

La anotación es opcional: sin ella el compilador infiere. Los literales
enteros son **polimórficos** — toman el tipo que exige el contexto (`let x:
i64 = 5`, o el parámetro de una función) — y sin contexto caen al default
`i32` ([`ARCHITECTURE.md` §5.1](../01_lenguaje/ARCHITECTURE.md)). No hay
coerciones silenciosas: `let b: f64 = a` con `a: i32` es
`type mismatch: variable 'b' declared as f64 but initialized with i32`, y hoy
**no existen casts** (`x as i32` muere en el parser: `unexpected token in
expression`) **ni sufijos** (`5i64` se lee como `5` seguido de la variable
`i64`: `undefined variable 'i64'`).

## Rangos, default y wrap: DEC-006 y DEC-007

Estas dos decisiones explican casi todos los errores de enteros que verás.

### DEC-006 — rango en compile-time, default `i32` con caída a `i64`

Un literal que **no cabe en el tipo anotado es error de compilación**; sin
anotación, el default es `i32` y si el literal no cabe **cae a `i64`**
([`default_i32.astra`](ejemplos/02/default_i32.astra)):

```astra
// DEC-006: por defecto un literal entero es i32; si no cabe, cae a i64.
fn main() {
    let a = 42;            // sin anotación: i32
    let b = 9999999999;    // no cabe en i32: el default cae a i64
    print(a);
    print(b);
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig default_i32.astra
42
9999999999
```

Pero anotado el tipo, el mismo número fuera de rango **no compila**
([`error_rango_i32.astra`](ejemplos/02/error_rango_i32.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_rango_i32.astra
error_rango_i32.astra:3:5: error: integer literal 9999999999 out of range for i32
```

(Límite honesto: un literal mayor que `INT64_MAX`, p. ej. el máximo de `u64`,
tampoco es representable — el lexer lo rechaza, `integer literal is out of
range for i64`. `ARCHITECTURE.md` §5.1 lo documenta.)

### DEC-007 — el overflow en runtime es wrap definido

Los anchos se comprueban en compilación; en runtime la aritmética es de 64
bits con **wrap definido en complemento a dos**, documentado y igual en las
cuatro rutas ([`wrap_i64.astra`](ejemplos/02/wrap_i64.astra)):

```astra
// DEC-007: el overflow de enteros en runtime es wrap definido (two's complement).
fn main() {
    let s: i64 = 4611686018427387904;
    print(s + s);
    let a: i32 = 2147483647;
    print(a + 1);
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig wrap_i64.astra
-9223372036854775808
2147483648
```

Fíjate en la segunda línea: `2147483647 + 1` en un `i32` **no** vuelve a
`-2147483648`, porque la aritmética corre en 64 bits — el envoltorio de 32
bits aún no está. Un checked-overflow puede llegar como flag (DEC-007).

## Tres trampas típicas

### 1. Contadores junto a `len`

`len` devuelve `i64` (DEC-013) y tu contador sin anotar es `i32`, así que la
comparación no compila
([`error_contador_len.astra`](ejemplos/02/error_contador_len.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_contador_len.astra
error_contador_len.astra:6:13: error: type mismatch: cannot compare i32 and i64
```

La solución es anotar el contador: `let mut i: i64 = 0`. (En el ejemplo del
[capítulo 0](00_introduccion.md) ya lo ves hecho.)

### 2. Nombres de builtin reservados

`print`, `len`, `to_string` y `read_file` **no pueden redeclararse** ni con
`let`, ni con `const`, ni con `fn`, en ningún ámbito (DEC-015) — el VM y el
emisor LLVM resuelven los builtins por nombre y un binding homónimo
divergiría entre rutas
([`error_nombre_builtin.astra`](ejemplos/02/error_nombre_builtin.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_nombre_builtin.astra
error_nombre_builtin.astra:3:5: error: 'len' is a builtin and cannot be redeclared
```

### 3. `ok` (y `some`, `none`, `err`) son keywords

Son las variantes de Option/Result (capítulo 7), así que no sirven como
nombres ([`error_ok_keyword.astra`](ejemplos/02/error_ok_keyword.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_ok_keyword.astra
error_ok_keyword.astra:3:9: error: expected variable name, got ok
error_ok_keyword.astra:5:1: error: unexpected token in expression
```

## Aún no existe

- **Casts y sufijos** (`x as f64`, `5i64`): no están en la gramática.
- **Coerciones numéricas**: `i32` nunca se convierte solo a `f64` ni a `i64`.
- **Checked overflow**: solo wrap definido (DEC-007), salvo que aparezca un
  flag.
- **`val` / `var`**: descartados; quedan `let` y `let mut`.

---

## Resumen

- `let` crea un binding inmutable, `let mut` uno reasignable, `const` una
  constante; `val` y `var` no existen.
- Tipos: `i32` (default), `i64`, `u32`, `u64`, `f64`, `bool`, `string`; los
  literales enteros se anclan al contexto y sin él caen a `i32` (DEC-006).
- Un literal fuera del rango anotado **no compila**; en runtime los enteros
  envuelven definidamente (DEC-007).
- `len` devuelve `i64`: anota tus contadores con `i64`.
- Los nombres de builtin están reservados (DEC-015) y `ok`/`some`/`none`/`err`
  son keywords.
- `let` protege el binding, no el objeto: el detalle está en el capítulo 5.

## Ejercicios

1. Escribe un contador que sume los elementos de `[10, 20, 30]` con `while` y
   `len`. Si te sale el error `cannot compare i32 and i64`, arréglalo anotando
   el contador.
2. Comprueba el rango: `let x: u32 = -1` y `let y: u32 = 4294967296`. Lee el
   diagnóstico de DEC-006 en ambos casos.
3. Declara `let mut s = "hola"` y prueba `s = "adiós"`. ¿Funciona? Ahora
   prueba `s[0] = "H"`: anota el error y busca en el capítulo 8 por qué el
   string es inmutable.
