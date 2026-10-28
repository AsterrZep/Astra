# Capítulo 7 — Option, Result y el operador `?`

> Salidas = salida real de `seed/astra-seed` (la ruta zig VM imprime lo
> mismo, salvo el resumen final en errores de compilación). Cada ejemplo
> vive en `ejemplos/cap07/`.

Un programa real tiene valores que pueden no estar: el resultado de buscar
en una lista vacía, el contenido de un fichero que quizá no existe. Astra-0
no tiene `nil` como valor general — tiene **Option** y **Result**, dos
constructores builtins que convierten «quizá» y «o bien… o bien» en cosas
que el tipo del sistema puede describir.

Este capítulo es también una lección de honestidad: Option está completo y
bien gateado; Result existe pero hoy es más pobre de lo que su nombre
promete. Lo contamos tal cual, con las ejecuciones delante.

## `some(x)` y `none`: Option

`some(v)` envuelve un valor; `none` lo ausenta. Se escriben **pelones**, sin
calificar — es la excepción explícita de DEC-008 a la regla de variantes
calificadas del Capítulo 6 (los enums de usuario exigen `Enum.Variant`;
éstos son builtins):

```astra
// ejemplos/cap07/some_none.astra
// some(x) / none: the Option constructors (bare spelling, by design).
fn main() {
    let x = some(42);
    let y = none;
    print(x);
    print(y);

    let a: i32? = some(1);
    let b: i32? = none;
    print(a == some(1));
    print(b == none);
}
```

```text
some(42)
nil
true
true
```

Vale la pena mirar los dos primeros resultados: `print` de un Option escribe
`some(<payload>)`, y un `none` se imprime **`nil`** — `nil` no es un literal
del lenguaje (el viejo `null` fue retirado y hoy produce
`undefined variable 'null'`), es sólo la forma en que el runtime dibuja la
ausencia. La igualdad es **estructural**: dos `some(42)` construidos por
separado son iguales, y con strings compara por contenido.

El tipo de un Option se anota con `?` detrás del payload: `i32?`,
`string?`, `bool?`. Un `let x: i32? = none` es el idioma normal de «puede
no haber valor».

### `match` sobre Option

El desempaquetado idiomático es un `match` con los dos brazos `some(v)` y
`none` — y aquí el compilador es estricto: **falta `none` es error de
compilación** (`non-exhaustive match: missing 'none' arm`), no un runtime
sorpresa:

```astra
// ejemplos/cap07/match_option.astra
fn main() {
    let x = some(10)
    match x {
        some(v) => print(v),
        none => print("nothing"),
    }
}
```

```text
10
```

(Este patrón es, literalmente, el test de conformidad
`seed/tests/conformance/enums/nested_option_result.astra`.)

El binding `some(v)` trae el payload como variable local del brazo, y
funciona igual para payloads de string (`string?`) y dentro de arrays
(`[i32?]`).

## `ok(x)` y `err(e)`: Result

`ok(v)` y `err(e)` son los constructores de Result, con la misma ortografía
pelona. Construirlos, imprimirlos y compararlos funciona hoy:

```astra
// ejemplos/cap07/ok_err.astra
// ok(x) / err(e): the Result constructors (bare spelling, like some/none).
// Construction, printing and equality work; see result_match_quirk.astra
// for what match on a Result does today.
fn main() {
    let good = ok("hello");
    let bad = err("failed");
    print(good);
    print(bad);
    print(good == ok("hello"));
    print(err("x") == err("x"));
}
```

```text
ok(hello)
err(failed)
true
true
```

### La peculiaridad actual de `match` sobre Result

Atención: **el chequeo de exhaustividad trata hoy todo valor etiquetado como
un Option**, así que un `match` sobre un Result exige un brazo `none` que
un Result nunca tomará. Con el brazo fantasma puesto, los brazos
`ok`/`err` sí se disparan correctamente en runtime:

```astra
// ejemplos/cap07/result_match_quirk.astra
// CURRENT QUIRK: the exhaustiveness checker treats every tagged value as an
// Option, so a `match` over a Result demands a `none` arm. With the dummy
// arm in place the ok/err arms fire correctly at run time.
fn main() {
    let good = ok("hello");
    match good {
        ok(msg) => print(msg),
        err(e) => print(e),
        none => print("impossible for a Result"),
    }
}
```

```text
hello
```

Es un comportamiento que el propio registro de decisiones dará por cerrado
cuando Result obtenga su tratamiento propio; mientras tanto, es el
comportamiento real y está escrito aquí para que no te lo encuentres a
ciegas. Relacionado: **hoy no se puede escribir el tipo `Result[T, E]`** en
Astra-0 (no hay anotación para él), así que un Result solo existe como
valor inferido de un `ok`/`err`. Y `err` **no propaga** por `?` (más
abajo).

## `?`: desempaquetar o volver atrás

El operador `?` hace en una línea lo que haría un `match` con early-return:
si el valor está presente (`some`), lo desempaqueta; si no, **desenrolla la
función actual devolviendo `none`** al llamador. Es el motor de las
«pipelines» de Option:

```astra
// ejemplos/cap07/try_propagate.astra
// The `?` operator over Option: unwrap when present, early-return `none`
// from the enclosing function otherwise.
fn increment(x: i32?) -> i32? {
    let v = x?            // unwraps when present, propagates none otherwise
    return some(v + 1)
}

fn halve(x: i32) -> i32? {
    if x < 0 {
        return none
    }
    return some(x / 2)
}

fn pipeline(x: i32) -> i32? {
    let a = halve(x)?                 // early return propagates through here
    let b = increment(some(a))?
    return some(b * 2)
}

fn main() {
    print(increment(some(3)))
    print(increment(none))
    print(pipeline(16))
    print(pipeline(-1))               // absence comes back out of two frames
    print(pipeline(1))
}
```

```text
some(4)
nil
some(18)
nil
some(2)
```

`pipeline(-1)` es la línea que merece una segunda mirada: la ausencia nace
en `halve`, cruza dos frames por dos `?` distintos y sale por el retorno de
`pipeline` sin que nadie escriba un manejo explícito de errores. (Este
ejemplo es el test de conformidad `seed/tests/conformance/enums/try_operator.astra`.)

### Tres reglas del `?`, con sus errores reales

1. Solo sobre Option/Result etiquetado — a un entero pelón no hay nada que
   desempaquetar:

   ```astra
   // ejemplos/cap07/try_non_optional_error.astra
   fn main() {
       let x: i32 = 42;
       print(x?);
   }
   ```

   ```text
   cap07/try_non_optional_error.astra:4:12: error: ? operator requires Result or Option, got i32
   error: type check failed with 1 error(s)
   ```

2. La función envolvente **debe devolver un tipo optional** (`-> i32?`), o
   el `?` no tendría adónde devolver la ausencia: con `-> i32` el error es
   `? operator requires the enclosing function to return an optional type`.
3. No existe a nivel de módulo (fuera de función no hay frame que
   desenrollar) — mismo mensaje que la regla 2.

## `none` como valor

`none` puede fluir como cualquier otro valor: guardarlo en un `let` con
anotación `T?`, meterlo en un array de opcionales, compararlo, devolverlo.
Un `let x: i32?` sin inicializar es distinto de `none` explícito — inicialízalo
siempre que puedas. Ejemplos con arrays de `[i32?]`, igualdad por contenido
y unificaciones `if`/`match` de brazos `some`/`none` viven en
`seed/tests/conformance/enums/option_branch_unify.astra` y
`enums/option_str_payload.astra`.

## Aún no existe

- **Anotar un Result**: no hay sintaxis `Result[T, E]`; un Result solo
  nace de `ok`/`err` con inferencia.
- **Propagar `err` con `?`**: el `?` desenrolla con `none` sobre valores
  etiquetados; hacer que `err` cruce por firmas `?` hoy se rechaza en el
  typechecker (con un mensaje todavía poco claro —
  `return type optional does not match function return type optional`).
  Está en la agenda junto al punto anterior; no lo intentes todavía.
- `read_file` devuelve `string` y falla con error de runtime, no un
  `Option`/`Result` (Capítulo 8).

## Resumen

- `some(v)` / `none` construyen Option; el tipo se anota `T?`; `none` se
  imprime como `nil`.
- La construcción de Option/Result es **pelona** (`some(42)`, `ok(v)`),
  la excepción de DEC-008 a la regla `Enum.Variant` del Capítulo 6.
- `match` sobre Option exige `some(v)` y `none`; la igualdad es
  estructural.
- `ok(v)` / `err(e)` construyen Result: imprimirlos y compararlos funciona;
  `match` sobre un Result exige hoy un brazo `none` fantasma (peculiaridad
  documentada), y no existe la anotación `Result[T, E]`.
- `?` desempaqueta o devuelve `none` de la función actual; exige valor
  etiquetado y retorno opcional, y no funciona a nivel de módulo.

## Ejercicios

1. Escribe `fn primero(xs: [i32]) -> i32?` que devuelva `some(xs[0])` si el
   array tiene elementos y `none` si está vacío. Comprueba ambos caminos
   con `print`.
2. Escribe `fn tercera_raiz(x: i32) -> i32?` que encadene tres `halve` del
   ejemplo (`let a = halve(x)?; let b = halve(a)?; let c = halve(b)?` y
   devuelva `some(c)`). ¿Qué imprime para `x = 16`, `x = 8` y `x = -1`?
   Compruébalo con `seed/astra-seed`.
3. Un colega escribe `let r = ok(1); match r { ok(v) => print(v), err(e) => print(e) }`.
   Ejecútalo, pega la diagnóstica y reescribe el `match` con el brazo que
   hoy hace falta.
