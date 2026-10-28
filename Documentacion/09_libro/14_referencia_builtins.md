# Capítulo 14 — Referencia: builtins, keywords y errores de runtime

> **Estado de este capítulo** (2026-10-28, actualizado): los **8 builtins**
> están **todos en `main`** — `print`, `len`, `s[i]`, `to_string`,
> `read_file` (M1) y `ord`, `substr`, `push`, `str_to_int` (M2a/M2b,
> DEC-018/019) — documentados con sus textos de error **copiados de las
> ejecuciones reales** (seed VM y zig VM, byte-idénticos; las 4 rutas en los
> tests de paridad). Las filas de los cuatro nuevos llevan su firma y
> errores verificados en `main`.

Este capítulo no enseña nada nuevo: es la **hoja de referencia** que consultas
cuando dudas de una firma, de un texto de error o de si una palabra está
reservada. Todo lo que hay aquí está fijado por una decisión `DEC-NNN` en
[`Documentacion/01_lenguaje/DECISIONES.md`](../01_lenguaje/DECISIONES.md) y
por tests de conformance — la referencia cita, no inventa.

## Los builtins de hoy

Astra-0 no tiene estándar de librería; tiene **builtins** — funciones
resueltas por nombre en el runtime, sin importar nada. Los ejemplos de esta
sección viven en
[`ejemplos/cap14/`](ejemplos/cap14/).

### Tabla de referencia

| Builtin | Firma | Semántica | Decisión |
|:--------|:------|:----------|:---------|
| `print` | `print(x)` — cualquier valor | Imprime `x` + salto de línea. Floats con formato `%g`; bool como `true`/`false`; arrays como `[1, 2]` | DEC-010 |
| `len` | `len(x) -> i64` — array o string | Elementos del array; **bytes** del string. `len("")` → `0`. Receptor de otro tipo: error de runtime | DEC-013 |
| `s[i]` | `s[i] -> string` — string, `i` entero | **String de 1 byte** en la posición `i` (índices desde 0; byte, no codepoint). Solo lectura | DEC-013 |
| `to_string` | `to_string(x) -> string` — **solo enteros** | Entero a string, con la misma conversión que `print`, así que `print(to_string(n))` es byte-idéntico a `print(n)` | DEC-014 |
| `read_file` | `read_file(path: string) -> string` | Todo el fichero como string. Cualquier fallo de apertura/lectura colapsa en un único error de runtime | DEC-014 |

Las cinco entradas están fusionadas en `main` y verificadas por la suite. Un
programa que las usa junto,
[`ejemplos/cap14/builtins_basicos.astra`](ejemplos/cap14/builtins_basicos.astra):

```astra
fn main() {
    let nums = [10, 20, 30]
    print(len(nums))          // 3
    print(len("hola"))        // 4

    let s = "hola"
    print(s[0])               // h
    print(s[1] + s[3])        // oa

    let n = 42
    print("n=" + to_string(n))  // n=42

    print(read_file("saludo.txt"))  // Hola desde un fichero.
}
```

```text
3
4
h
oa
n=42
Hola desde un fichero.
```

(Ejecútalo así — `read_file` usa ruta relativa al **directorio de trabajo**,
así que hay que entrar en la carpeta del ejemplo; la lectura positiva vive
fuera de `conformance/` a propósito: DEC-014):

```bash
cd Documentacion/09_libro/ejemplos/cap14
../../../../zig/zig-out/bin/astra-zig builtins_basicos.astra
```

### Detalles que importan

- **`len` devuelve `i64`**, no un tipo tamaño nativo. Es `unknown` en el
  typechecker — igual que `print` —, así que cualquier receptor pasa el
  chequeo y el guard de runtime es la superficie de paridad entre rutas.
- **`s[i]` devuelve un string, no un `char`** — Astra-0 no tiene literales de
  carácter. `s[i]` se puede comparar por contenido (`==`) y usar en `match`
  con literales: `match s[i] { "(" => …, _ => … }` funciona hoy.
- **Los strings son inmutables**: `s[i] = …` es **error de compilación**,
  rechazado en el typechecker para que ninguna ruta lo ejecute:

  ```text
  x.astra:3:5: error: cannot assign to string element
  ```

- **`to_string` no acepta floats** — no por despiste, sino por decisión: el
  formato decimal de float es otra decisión que aún no existe (DEC-010 solo
  fija `print`), y el uso que motivó el builtin es numerar líneas y columnas
  (el lexer self-hosting). Un float llega a runtime y falla (ver abajo).
- **`read_file` anota `path: string`**, así que `read_file(42)` es error de
  compilación en ambos typecheckers:

  ```text
  x.astra:2:11: error: argument 1: expected string, got integer literal
  ```

### Errores de runtime — textos exactos

Los errores de runtime salen por stderr con el prefijo
`<fichero>:<línea>: runtime error: ` y **código de salida 1**, idéntico en
seed VM, backend C, zig VM y LLVM (la paridad de texto es parte del contrato
de cada decisión). Los cinco casos, ejecutados hoy:

| Caso | Texto del error | Fichero |
|:-----|:----------------|:--------|
| `len` de escalar | `cannot take length of int` | [`error_len_int.astra`](ejemplos/cap14/error_len_int.astra) |
| `s[i]` fuera de rango | `index 5 out of bounds (len 5)` | [`error_index_oob.astra`](ejemplos/cap14/error_index_oob.astra) |
| `s[i]` sobre nil | `cannot index nil` | (conformance `expressions/`) |
| `to_string` de float | `to_string expects an int, got float` | [`error_to_string_float.astra`](ejemplos/cap14/error_to_string_float.astra) |
| `read_file` inexistente | `cannot open file 'no_existe.txt'` | [`error_read_file.astra`](ejemplos/cap14/error_read_file.astra) |
| `read_file` de nil | `expected string path, got nil` | (conformance `expressions/`) |

Salida real de dos de ellos (zig VM y seed VM imprimen lo mismo, byte a byte):

```text
$ astra-zig ejemplos/cap14/error_index_oob.astra
error_index_oob.astra:6: runtime error: index 5 out of bounds (len 5)
$ echo $?
1

$ astra-zig ejemplos/cap14/error_to_string_float.astra
error_to_string_float.astra:6: runtime error: to_string expects an int, got float
```

Notas de contrato:

- El índice **fuera de rango usa el mismo texto que los arrays** — `s[i]` es
  una contracción del mismo trato, no un subsystema aparte.
- En `read_file`, **todo** fallo (no existe, permisos, es un directorio,
  errores WASI) es el mismo `cannot open file '<path>'`: distinguir causas
  divergiría entre runtimes sin aportarle nada al lexer self-hosting.
- El tipo nombrado en los guards (`got int`, `got float`) es el `type_name`
  del VM: si smuggleas otro tipo, el mensaje nombra el real.

## Los cuatro nuevos: `ord`, `substr`, `push`, `str_to_int`

Aterrizaron en `main` con la stdlib M2 (PRs #23 y #26). Estado real hoy:

| Builtin | Firma | Semántica | Estado (2026-10-28) |
|:--------|:------|:----------|:--------------------|
| `ord` | `ord(s) -> i64` | **Primer byte** de `s`; `""` = error de runtime | ✅ **En `main`** (DEC-018, fijada en `expressions/ord_*.astra`) |
| `substr` | `substr(s, start, len) -> string` | `len` bytes desde `start`; **error, nunca recorte**, fuera de `[0, len(s)]` | ✅ **En `main`** (DEC-018, `expressions/substr_*.astra`) |
| `push` | `push(arr, v) -> array` | **Nuevo** array con `v` al final (el original no cambia — DEC-019) | ✅ **En `main`** (DEC-019, `push_alias.astra` fija la copia) |
| `str_to_int` | `str_to_int(s) -> i64` | Decimal de `s` a entero; inválidos = error de runtime | ✅ **En `main`** (DEC-019, `str_to_int_*.astra`) |

Los textos de error ya están fijados por los tests del PR de `ord`/`substr`:
`ord() of empty string`, `ord expects a string, got int`,
`substr length 99 out of bounds (len 5)`,
`substr start 6 out of bounds (len 5)` — mismos patrones que `len`/`s[i]`:
guard de runtime con el receptor y los límites nombrados, paridad de texto en
las 4 rutas. `ord` y `substr` se suman a la lista reservada de DEC-015.

**«Llegan a main en los próximos PRs; esta tabla se actualizará.»** Cuando lo
hagan, sus filas dejan de llevar estado y se completan con la evidencia de
sus gates (conformance + codegen + paridad 4 rutas, el mismo circuito que M1).

## Keywords reservadas

El lexer del seed reconoce **36 keywords** (`seed/src/lexer.c`, tabla
`keywords[]`). No puedes usarlas como identificador en ningún sitio:

| | | | |
|:--|:--|:--|:--|
| `and` | `as` | `break` | `comptime` |
| `const` | `continue` | `else` | `enum` |
| `err` | `false` | `fn` | `for` |
| `from` | `if` | `impl` | `import` |
| `in` | `let` | `match` | `mod` |
| `mut` | `none` | `not` | `ok` |
| `option` | `or` | `pub` | `return` |
| `result` | `some` | `struct` | `trait` |
| `true` | `use` | `var` | `while` |

Observa que `ok`/`err`/`some`/`none` y `option`/`result` **son keywords** —
los constructos de los capítulos 6 y 7 no se declaran con `enum` aparte, el
lexer ya los conoce. `var` y `comptime` están reservadas desde la gramática
completa aunque Astra-0 aún no las use como constructos.

## Recordatorio DEC-015 — los nombres de builtin están reservados

Además de las keywords, **los nombres de los builtins no se pueden
redeclarar**: ni `let len`, ni `fn print`, ni `const to_string`, ni nada — en
**ningún ámbito**, módulo incluido. Ejecutado hoy en ambas rutas:

```text
$ astra-seed x.astra            # x.astra contiene `fn print() { }`
x.astra:1:1: error: 'print' is a builtin and cannot be redeclared
error: type check failed with 1 error(s)

$ astra-zig x.astra
x.astra:1:1: error: 'print' is a builtin and cannot be redeclared
```

y el mismo para `let len = 5` (probado hoy en los dos typecheckers, texto
byte-idéntico; los tests `ui/builtin_shadow_*.astra` lo tienen fijado). El
porqué está en [DEC-015](../01_lenguaje/DECISIONES.md): el VM resuelve
builtins por nombre en `GET_GLOBAL` y el emisor LLVM decide la llamada por
nombre en `emitCall` *antes* de mirar tablas — un binding llamado `len` se
ejecutaría como slot en unas rutas y como builtin en otras. El bug observable
ya existía: `let len = 5` imprimía `<fn>` en el VM seed y `5` en el backend C.

Cuando `ord`/`substr` aterricen, sus nombres se suman a esta lista; lo mismo
`push`/`str_to_int`. La lista reservada crece con cada builtin, nunca se
achica.

## Resumen

- Cinco builtins en `main` hoy: `print`, `len`, `s[i]`, `to_string`,
  `read_file` — firmas en la tabla de arriba, contratos fijados por
  DEC-010/013/014 y tests.
- `s[i]` da strings de 1 byte, solo lectura (`s[i] = …` no compila);
  `to_string` solo enteros; `read_file` colapsa todo fallo en un error.
- Los errores de runtime llevan `fichero:línea: runtime error:` y salen con
  código 1 — texto idéntico en las 4 rutas, y esa identidad es gate.
- `ord`/`substr` (DEC-018) y `push`/`str_to_int` (DEC-019) ya están en
  `main` — esta referencia cubre los 8.
- 36 keywords + nombres de builtin reservados (DEC-015): no se pueden
  redeclarar, en ningún ámbito.

## Ejercicios

1. Escribe un programa que lea `saludo.txt` (o cualquier fichero tuyo),
   imprima su `len`, y muestre el primer y último byte con `s[i]`. ¿Qué pasa
   si el fichero está vacío — y cómo lo averiguas sin que el programa tronque?
2. Implementa `reverse(s)` **sin** `substr`/`ord` (aún no están en main):
   con `s[i]`, `len` y concatenación, en un `while`. Mide cuánto tarda con un
   string de 1 000 bytes — y explica por qué crece cuadrático.
3. Prueba los límites de la tabla: `len` de un struct, `to_string` de un
   bool, `read_file` de un path absoluto que no existe. Cada error, ¿te dice
   lo que necesitas para arreglarlo? ¿Cuál sobra y cuál falta?
