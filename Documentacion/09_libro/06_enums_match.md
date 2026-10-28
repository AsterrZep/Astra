# Capítulo 6 — Enums y `match`

> Salidas = salida real de `seed/astra-seed` (la ruta zig VM imprime lo
> mismo, salvo el resumen final en errores de compilación). Cada ejemplo
> vive en `ejemplos/cap06/`.

Los structs modelan «estos campos, siempre». Los **enums** modelan «estas
variantes, una de ellas»: colores, estados, formas de un resultado. Y el
`match` es la forma de recorrerlos comprobando que cubres todas las
variantes — el compilador te obliga a no olvidar ninguna.

## Declaración de un enum

Igual que los structs: variantes separadas por **newline**, sin comas (una
coma produce `expected variant name, got ,`). Una variante puede ser un
nombre simple (**unidad**) o llevar payload:

```astra
enum Color {
    Rojo
    Verde
    Azul
}

enum Figura {
    Punto                    // unidad
    Circulo(f64)             // un payload
    Rect(f64, f64)           // dos payloads
}
```

## Construcción calificada — la única ortografía legal (DEC-008)

Las variantes de un enum viven **en el namespace de su enum**: se
construyen como `Enum.Variant`, siempre (DEC-008,
`Documentacion/01_lenguaje/DECISIONES.md`):

```astra
let c = Color.Rojo
let f = Figura.Circulo(2.0)
```

La forma pelona `Circulo(2.0)` se rechaza **aunque no haya colisión con
otro enum**, con una diagnóstica que apunta a la ortografía correcta:

```astra
// ejemplos/cap06/bare_construction_error.astra
// The bare spelling is rejected for user variants — the compiler points at
// the qualified one (DEC-008).
enum A { Some2(i32) None2 }

fn main() {
    let x = Some2(1);
    print(x);
}
```

```text
cap06/bare_construction_error.astra:6:13: error: use Enum.Variant to construct 'Some2'
cap06/bare_construction_error.astra:7:11: error: undefined variable 'x'
error: type check failed with 1 error(s)
```

> **La excepción**: `some`/`none`/`ok`/`err` (Option y Result) se escriben
> pelones porque son builtins del lenguaje, no variantes de usuario —
> `some(42)` es correcto. Lo ves en el Capítulo 7.

La contraparte positiva del namespace por enum: **dos enums pueden declarar
la misma variante sin colisionar**:

```astra
// ejemplos/cap06/qualified_homonyms.astra
// Qualified construction gives every enum its own namespace: two enums may
// declare the same variant name without colliding (DEC-008).
enum A { Some2(i32) None2 }
enum B { Some2(i32) None2 }

fn main() {
    let a = A.Some2(1);
    let b = B.Some2(2);
    print(match a { A.Some2(n) => n, A.None2 => 0 });
    print(match b { B.Some2(n) => n, B.None2 => 0 });
    let c = A.None2;
    print(match c { A.Some2(n) => n + 2, A.None2 => 3 });
}
```

```text
1
2
3
```

Este ejemplo es, literalmente, el test de conformidad
`seed/tests/conformance/enums/qualified_construction.astra`.

## `match`: exhaustivo por construcción

`match` es una expresión (devuelve un valor) y también una sentencia. Sobre
un enum **sin `_` debe cubrir todas las variantes**, y cada brazo es
`patrón => expresión`:

```astra
// ejemplos/cap06/unit_enum.astra
// Unit variants and an exhaustive match (no wildcard needed over an enum).
enum Color {
    Rojo
    Verde
    Azul
}

fn name(c: Color) -> string {
    return match c {
        Color.Rojo => "rojo",
        Color.Verde => "verde",
        Color.Azul => "azul",
    };
}

fn main() {
    print(name(Color.Rojo));
    print(name(Color.Verde));
    print(name(Color.Azul));
}
```

```text
rojo
verde
azul
```

¿Qué pasa si olvidas una variante? Error de compilación — no un `nil`
silencioso a mitad de ejecución:

```astra
// ejemplos/cap06/non_exhaustive_error.astra
// A match over an enum without a wildcard must cover every variant.
enum Color {
    Rojo
    Verde
}

fn main() {
    let c = Color.Rojo;
    print(match c {
        Color.Rojo => 1,
    });
}
```

```text
cap06/non_exhaustive_error.astra:9:11: error: non-exhaustive match: missing variant 'Color.Verde'
error: type check failed with 1 error(s)
```

### Bindings: desestructurar el payload

Un patrón `Enum.Variant(x, y)` **enlaza** los payloads a nombres locales
visibles dentro del brazo — y solo dentro: al terminar el `match`, los
nombres se reclaman y no contaminan el ámbito exterior:

```astra
// ejemplos/cap06/payload_enum.astra
// Variants with payload, constructed ONLY as Enum.Variant(...) (DEC-008),
// and destructured by a binding pattern in each arm.
enum Color {
    Rgb(i32, i32, i32)
    Named(string)
}

fn main() {
    let c = Color.Rgb(10, 20, 30);
    match c {
        Color.Rgb(r, g, b) => {
            print(r);
            print(g);
            print(b);
        },
        Color.Named(name) => {
            print(name);
        },
    }
    let d = Color.Named("teal");
    match d {
        Color.Rgb(r, g, b) => {
            print(r + g + b);
        },
        Color.Named(name) => {
            print(name);
        },
    }
}
```

```text
10
20
30
teal
```

Fíjate en las llaves del brazo: cuando un brazo lleva varias sentencias se
escribe `{ … }` y se separa de los demás con coma.

### Guards con `if`

Un brazo puede llevar una condición `if` tras el patrón. Ojo a un detalle
que castiga al primero: **un brazo con guard no cuenta para la
exhaustividad** (la condición puede ser falsa en runtime), así que la
variante que solo cubre un guard necesita también un brazo sin guard o un
`_`:

```astra
// ejemplos/cap06/guards_or_patterns.astra
// Or-patterns, the `_` catch-all, and a guard over a payload binding.
enum E { A B(i32) C(i32, i32) }

fn band(n: i32) -> string {
    return match n {
        0 => "cero",
        1 | 2 | 3 => "bajo",
        _ => "alto",
    };
}

fn main() {
    print(band(0));
    print(band(2));
    print(band(7));

    let v1 = E.B(1);
    print(match v1 { E.B(n) if n > 1 => n, _ => 0 });
    let v2 = E.B(2);
    print(match v2 { E.B(n) if n > 1 => n, _ => 0 });

    let c = E.C(9, 2);
    print(match c { E.C(x, y) if x > y => 1, _ => 0 });
}
```

```text
cero
bajo
alto
0
2
1
```

El ejemplo junta tres herramientas:

- **Or-patterns**: `1 | 2 | 3 => …` — varios patrones en un mismo brazo.
- **`_`** (wildcard): el catch-all. Sobre escalares (`i32`, `f64`, `string`)
  es **obligatorio** si no cubres el espacio entero con literales: como
  Astra-0 no tiene patrones de rango, un `match` sobre un entero sin `_`
  es error de compilación
  (`non-exhaustive match: missing '_' arm`).
- **Guards sobre bindings**: `E.B(n) if n > 1` enlaza `n` y luego decide.

Errores de guard que conviene conocer (todos fijados en
`seed/tests/conformance/ui/`):

| Intento | Diagnóstica |
|:--------|:------------|
| Variante cubierta solo por un guard | `non-exhaustive match: missing variant 'E.B'` |
| Guard con condición no booleana | `match guard must be bool, got integer literal` |
| `match` sobre entero sin `_` | `non-exhaustive match: missing '_' arm` |

## `match` como expresión y como sentencia

Hasta aquí los dos usos: devolver el valor de un brazo (`return match c {
… }`) y ejecutar sentencias (`match c { … => print(…) }`). También puede
alimentar directamente a un `print` o a cualquier expresión — el Capítulo 7
lo usa con Option. Los patrones de escalares (literales de entero, string)
funcionan igual que los de variantes, incluido `_` y or-patterns.

## Resumen

- Un enum declara variantes separadas por newline; cada variante es un
  nombre o un constructor con payload.
- **La construcción de variantes de usuario es SOLO calificada**
  (`Color.Rojo`, `Figura.Circulo(2.0)`) — DEC-008; la forma pelona produce
  `use Enum.Variant to construct '…'`. `some`/`none`/`ok`/`err` son la
  excepción (Capítulo 7).
- El namespace por enum evita colisiones entre homónimos.
- `match` es expresión y sentencia; sobre enums es exhaustivo sin `_`, y
  un guard no cuenta para la exhaustividad.
- Los bindings de un brazo (`Color.Rgb(r, g, b)`) viven solo en ese brazo.
- Or-patterns (`1 | 2 | 3`), guards (`if`) y `_` completan el cuadro; los
  escalares exigen `_`.

## Ejercicios

1. Escribe un enum `Semana { Lun, Mar, Mie, Jue, Vie, Sab, Dom }` y una
   función `es_laborable(d: Semana) -> bool` con `match` exhaustivo. ¿Cuántos
   brazos necesita? ¿Funcionaría sin ninguno con `_`?
2. Un colega escribe:

   ```astra
   enum E { A B(i32) }
   fn f(e: E) -> i32 {
       return match e {
           E.A => 1,
           E.B(n) if n > 0 => 2
       };
   }
   ```

   Ejecútalo y pega la diagnóstica exacta. ¿Qué brazo(s) hay que añadir?
3. Usa el ejemplo `ejemplos/cap06/qualified_homonyms.astra` como base y
   añade un tercer enum `C` que también declare `Some2`; comprueba que los
   tres homónimos siguen sin pisarse.
