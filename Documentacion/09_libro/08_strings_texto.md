# Capítulo 8 — Strings y texto

> Salidas = salida real de `seed/astra-seed` (la ruta zig VM imprime lo
> mismo, salvo el resumen final en errores de compilación). Cada ejemplo
> vive en `ejemplos/cap08/`.

En Astra-0 un string es **una secuencia de bytes inmutable**. De esa frase
salen tres consecuencias que este capítulo convierte en práctica diaria: se
leen por índice como bytes (no como letras Unicode), no se pueden modificar
in situ, y hay un puñado pequeño de builtins que lo hacen todo — con el
resto del mundo esperando en la cola, listado al final con su estado real.

## Literales y escapes

Los strings se escriben entre comillas dobles; las sentencias terminan con
`;` o con newline (DEC-011):

```astra
let saludo = "hola"
let vacio = ""
```

El lexer acepta **cuatro escapes**: `\"` (comilla doble), `\\` (barra
inversa), `\n` (salto de línea) y `\t` (tabulador). Cualquier otra cosa
tras una barra es error de compilación (`invalid escape sequence`) — nunca
un backslash silenciosamente conservado:

```astra
// ejemplos/cap08/string_basics.astra
// String literals, escapes, concatenation and content equality.
fn main() {
    let a = "hello ";
    let b = "world";
    print(a + b);
    print("quote: \"  backslash: \\");
    print("tab:\tend");
    print("line1\nline2");

    let e = "";
    print(len(e));
    print(e == (e + e));
    print("abc" == "abc");
}
```

```text
hello world
quote: "  backslash: \
tab:	end
line1
line2
0
true
true
```

(`print` escribe el string tal cual: el `\t` se imprime como la tabulación
real, el `\n` parte la línea.)

## Concatenación, igualdad… y nada más

- `a + b` concatena.
- `==` compara **por contenido**, también con el string vacío.
- **No hay ordenación**: `"a" < "b"` llega a runtime y muere con
  `runtime error: cannot compare string and string` (el typechecker todavía
  lo deja pasar; la ruta C de antes lo respondía `false` — un error
  convertido en respuesta plausible, y por eso está fijado como test).
- **No hay conversión implícita de números**: `"n=" + n` es error de
  compilación (`arithmetic operator requires numeric type, got string`);
  para meter un número en un string usa `to_string`, más abajo.

## Strings inmutables (DEC-013)

No existe `s[i] = …`: los strings no se modifican, y el rechazo es de
**compilación**, no de runtime — ninguna ruta llega a ejecutarlo:

```astra
// ejemplos/cap08/string_assign_error.astra
// Strings are immutable: a write through an index is a compile error.
fn main() {
    let mut s = "abc"
    s[0] = "x"
}
```

```text
cap08/string_assign_error.astra:4:5: error: cannot assign to string element
error: type check failed with 1 error(s)
```

> Fíjate en el `let mut s`: el `mut` hace falta para *reasignar* `s` a otro
> string (`s = s + "!"` sí funciona); no habilita escrituras por índice.

## `len(s)`: bytes, y en `i64`

`len(s)` devuelve el número de **bytes** como `i64` (DEC-013,
`Documentacion/01_lenguaje/DECISIONES.md`). Un string UTF-8 con acentos
tiene más bytes que caracteres: `s[i]` devuelve **un string de 1 byte**, no
una letra. Para texto ASCII esto es invisible; para texto con acentos o
emoji, recuérdalo antes de iterar.

Fuera de rango, el error es el mismo que el de los arrays (Capítulo 5):

```astra
// ejemplos/cap08/string_oob.astra
// Indexing past the end fails with the very wording arrays use.
fn main() {
    let s = "hello"
    print(s[5])
}
```

```text
cap08/string_oob.astra:4: runtime error: index 5 out of bounds (len 5)
```

Y como `print`, `len` acepta cualquier receptor en compilación y cada
runtime lo rechaza si no es colección:

```astra
// ejemplos/cap08/len_int_error.astra
fn main() {
    let n = len(1)
    print(n)
}
```

```text
cap08/len_int_error.astra:4: runtime error: cannot take length of int
```

## El bucle idiomático

Recorrer un string se hace con un contador `i64` — y aquí es donde la
anotación importa de verdad: `len` devuelve `i64`, y comparar un `i32` con
un `i64` (`let mut i = 0` sin anotar es `i32`, DEC-006) es **error de
compilación**. La forma correcta, que verás en cada programa serio (por
ejemplo en el lexer self-hosting de DEC-016), es ésta:

```astra
// ejemplos/cap08/string_index_walk.astra
// Walking a string byte by byte: len(s) is i64, so the counter must be
// `let mut i: i64` or the comparison is a compile error.
fn main() {
    let s = "hello"
    print(s[0])
    let mut w = ""
    let mut i: i64 = 1
    while i < len(s) {
        w = w + s[i]
        i = i + 1
    }
    print(w)
    print(s[4] == "o")
}
```

```text
h
ello
true
```

Reserva mental: **`while i < len(s)` ⇒ `let mut i: i64`**. Es el error de
compilación más común al empezar.

## `to_string(x)`: enteros y nada más (DEC-014)

`to_string` convierte **solo enteros** a decimal, usando exactamente la
misma conversión que `print`, así que `print(to_string(n))` escribe lo
mismo que `print(n)`. Es **la única** forma de meter un número dentro de un
string. Con un float u otro tipo, muere en runtime con texto idéntico en
las cuatro rutas: `to_string expects an int, got float`.

```astra
// ejemplos/cap08/to_string_roundtrip.astra
// to_string converts integers only, and it is THE way to put a number
// inside a string (`"n=" + n` is a compile error).
fn main() {
    print(to_string(42))
    print(to_string(-7))
    let n = 42
    print(to_string(n) == "42")
    print("n=" + to_string(n))
}
```

```text
42
-7
true
n=42
```

## `read_file(path)`: un solo error para todo (DEC-014)

`read_file` recibe **un string** (un entero es error de compilación:
`argument 1: expected string, got integer literal`) y devuelve el contenido
del fichero. **Todo fallo** — no existe, sin permisos, es un directorio,
cualquier cosa de WASI — colapsa en un único error de runtime:

```astra
// ejemplos/cap08/read_file_missing.astra
// Every open/read failure collapses into one run-time error.
fn main() {
    print(read_file("astra_libro_missing.txt"))
}
```

```text
cap08/read_file_missing.astra:3: runtime error: cannot open file 'astra_libro_missing.txt'
```

Sin `Option`, sin `Result`: el fallo detiene el programa con código 1
(habrá lecturas con `Option`/`Result` cuando el lenguaje tenga anotación de
Result — Capítulo 7).

## Nombres de builtins reservados (DEC-015)

`print`, `len`, `to_string`, `read_file` (y los que se sumen) **no pueden
redeclararse** con `let`, `const` ni `fn`, en ningún ámbito — ni siquiera
dentro de una función. El error es de compilación y byte-idéntico en los
dos checkers:

```astra
// ejemplos/cap08/builtin_reserved_error.astra
// Builtin names are reserved globals: redeclaring one is a compile error.
let len = 5
```

```text
cap08/builtin_reserved_error.astra:2:1: error: 'len' is a builtin and cannot be redeclared
error: type check failed with 1 error(s)
```

## Estado de los builtins de texto — tabla honesta

La stdlib de texto crece por PRs; éste es el estado real **a fecha de
2026-10-28**, y mientras una fila no diga «disponible» no la uses en tus
programas (el libro tampoco la usa en ejemplos):

| Builtin | Firma planeada | Estado |
|:--------|:---------------|:-------|
| `print(x)` | cualquier valor | **Disponible** (DEC-010) |
| `len(x)` | `string`/`array` → `i64` | **Disponible** (DEC-013) |
| `s[i]` | byte `i` → string de 1 byte | **Disponible** (DEC-013) |
| `to_string(x)` | entero → `string` | **Disponible** (DEC-014) |
| `read_file(path)` | `string` → `string` | **Disponible** (DEC-014) |
| `ord(s)` | `string` → primer byte `i64` | **Disponible** (DEC-018) |
| `substr(s, start, len)` | `string` → `string` | **Disponible** (DEC-018) |
| `push(arr, v)` | array → array nuevo con `v` al final | **Disponible** (DEC-019 — el original no cambia) |
| `str_to_int(s)` | `string` → `i64` | **Disponible** (DEC-019 — inválidos = error de runtime) |

Los cuatro últimos aterrizaron con la stdlib M2 (2026-10-28): firmas,
textos de error y ejemplos de uso están en el
[capítulo 14 (referencia)](14_referencia_builtins.md). Truco que sigue
siendo útil: para un byte concreto, `s[i]` ya te lo da directamente.

## Resumen

- Un string es bytes inmutable; escapes limitados a `\" \\ \n \t`.
- `+` concatena, `==` compara por contenido; **no hay ordenación ni
  conversión implícita** de números.
- `s[i] = …` es error de **compilación** (DEC-013); `mut` sólo permite
  reasignar el binding.
- `len(s)` → `i64` (bytes); `s[i]` → string de 1 byte (no codepoint);
  fuera de rango: `index N out of bounds (len M)`.
- El bucle idiomático necesita `let mut i: i64 = 0` junto a
  `while i < len(s)`.
- `to_string` sólo convierte enteros; `read_file` colapsa todo fallo en
  `cannot open file '<path>'`; los nombres de builtins están reservados
  (DEC-015).
- `ord`, `substr`, `push` y `str_to_int` están llegando: míralos en la
  tabla de estado, no en tu código todavía.

## Ejercicios

1. Escribe un programa que recorra `"astra"` con el bucle idiomático y
   imprima cada byte. Cambia después el contador a `let mut i = 0` y pega
   el error de compilación exacto.
2. Escribe `fn repetir(s: string, n: i32) -> string` que devuelva `s`
   concatenado `n` veces. Prueba con `repetir("ab", 3)`.
   (Pista: `n` es `i32`, pero para comparar con `len` necesitas `i64` —
   anota `let mut i: i64` y cuenta con `i < n` ¿funciona? Si no, ¿por qué?
   Usa `to_string` para imprimir el resultado dentro de un mensaje.)
3. Ejecuta `ejemplos/cap08/read_file_missing.astra` con un path inventado
   tuyo y compara el texto del error con el del ejemplo. Después escribe la
   misma llamada `read_file` con un número en vez de un string y pega el
   error de compilación.
