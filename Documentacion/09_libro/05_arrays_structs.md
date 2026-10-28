# Capítulo 5 — Arrays, structs y el contrato de aliasing

> Salidas = salida real de `seed/astra-seed` (la ruta zig VM,
> `zig/zig-out/bin/astra-zig`, produce la misma salida salvo el resumen
> final `error: type check failed…` en errores de compilación). Cada
> ejemplo vive en `ejemplos/cap05/` y se ejecutó antes de pegarlo aquí.

Hasta ahora has visto valores sueltos: enteros, strings, booleanos. Los
**arrays** y los **structs** son los dos agregados de Astra-0, y con ellos
aparece la pregunta que define al lenguaje: *cuando `let b = a`, ¿cuántas
copias hay?* Este capítulo responde esa pregunta con el contrato tal como
está hoy, fijado por tests, y termina con la sección más importante del
libro: **el contrato de aliasing**.

## Arrays

Un array literal es una lista entre corchetes; su tipo es `[T]` y todos los
elementos son del mismo tipo:

```astra
// ejemplos/cap05/array_basics.astra
fn main() {
    let xs = [10, 20, 30];
    print(xs[0]);
    print(xs[2]);

    let mut ys = [1, 2];
    ys[0] = 99;
    print(ys[0]);
    print(ys);
}
```

```text
10
30
99
[99, 2]
```

Tres detalles que ya aparecen en el ejemplo:

- El **índice empieza en 0** y el acceso es `xs[i]`.
- Escribir un elemento (`ys[0] = 99`) exige `let mut`, igual que una
  variable escalar.
- `print` de un array imprime su literal: `[99, 2]`.

`len(array)` devuelve el número de elementos **como `i64`** (DEC-013,
`Documentacion/01_lenguaje/DECISIONES.md`), un detalle que parece menor y
no lo es: en el Capítulo 8 verás por qué un contador de tipo `i32` no
compila junto a `len`.

### Fuera de rango: error de runtime, siempre

Un índice inválido es un error de runtime con este texto — nunca un valor
basura ni un silencioso `nil`:

```astra
// ejemplos/cap05/array_oob.astra
fn main() {
    let a = [1, 2, 3];
    print(a[5]);
}
```

```text
cap05/array_oob.astra:4: runtime error: index 5 out of bounds (len 3)
```

El programa termina con código de salida 1. Este mismo texto lo emiten las
cuatro rutas de ejecución (VM seed, backend C, VM zig, LLVM) — es un
contrato de paridad, no un detalle de implementación.

### Tipos de array

La anotación es `[T]`, y un array declarado sin inicializador empieza vacío
de contenido (nil) hasta que se le asigne valor:

```astra
let xs: [i32] = [1, 2, 3]
let vacio: [i32]          // array nil: leer su índice es un error de runtime
```

## Structs

Un struct declara sus campos **separados por newline, no por comas**:

```astra
struct Point {
    x: i32
    y: i32
}
```

Escribir comas es un error de parseo (`expected field name, got ,`); es una
diferencia con muchos lenguajes y conviene acostumbrarse desde el principio.
La construcción es la literal `Point { campo: valor, … }`, el orden de los
campos **no importa** (se guardan en orden de declaración), y los campos
pueden leerse, escribirse (con `let mut`) e imprimirse enteros:

```astra
// ejemplos/cap05/struct_basics.astra
struct Point {
    x: i32
    y: i32
}

fn sum(p: Point) -> i32 {
    return p.x + p.y;
}

fn main() {
    let q = Point { y: 1, x: 2 };
    print(q.x);
    print(q.y);
    print(q);
    print(sum(q));
}
```

```text
2
1
Point { x: 2, y: 1 }
3
```

Escribir campos también funciona, incluyendo la cadena
campo→índice cuando el campo es un array:

```astra
// ejemplos/cap05/struct_field_assign.astra
struct Punto {
    x: i32
    y: i32
}

struct Matriz {
    fila: [i32]
    alto: i32
}

fn main() {
    let mut p = Punto { x: 1, y: 2 };
    p.x = 5;
    print(p.x);

    let mut m = Matriz { fila: [7, 8], alto: 2 };
    m.fila[1] = 99;
    print(m.fila[1]);
    print(m.fila[0]);
}
```

```text
5
99
7
```

### Errores de campo

La literal debe declarar exactamente los campos del struct. Un campo que no
existe es error de compilación:

```astra
// ejemplos/cap05/unknown_field_error.astra
struct Point {
    x: i32
    y: i32
}

fn main() {
    let p = Point { x: 1, y: 2, z: 3 };
    print(p.x);
}
```

```text
cap05/unknown_field_error.astra:8:13: error: struct 'Point' has no field 'z'
cap05/unknown_field_error.astra:9:11: error: undefined variable 'p'
error: type check failed with 2 error(s)
```

> **Consejo de lectura de errores**: la primera diagnóstica es la real; la
> segunda (`undefined variable 'p'`) es efecto dominó — `p` nunca llegó a
> declararse. Busca siempre la primera línea.

Omitir un campo declarado falla igual (`missing field`), y no existe el
*shorthand* `P { x }`: cada campo necesita su `nombre: valor` — si lo
intentas, el parser se queja con `expected ':', got }`.

## El contrato de aliasing — `let` protege el binding, no el objeto

Este es el apartado más importante del capítulo, y probablemente del libro
entero. En Astra-0 **asignar un agregado no copia sus elementos: comparte
el handle** (DEC-001, ratificada como D2 el 2026-10-27;
`Documentacion/01_lenguaje/DECISIONES.md`; especificación en
`Documentacion/01_lenguaje/ARCHITECTURE.md` §2.5).

### `let mut` ↔ `let mut`: la escritura se ve por todos lados

```astra
// ejemplos/cap05/alias_mut_mut.astra
// DEC-001: `let b = a` comparte el handle. A write through one binding is
// visible through the other (let mut <-> let mut).
fn main() {
    let mut a = [1, 2, 3];
    let mut b = a;
    b[0] = 99;
    print(a[0]);
    print(b[0]);
}
```

```text
99
99
```

`b[0] = 99` escribe **el mismo array** que `a`: no hay dos arrays, hay dos
nombres de uno. (`b = push(b, x)` no crece en sitio — devuelve un array
nuevo; eso llegará con el builtin `push`, aún no publicado, y no cambia
nada de lo anterior.)

### `let` ↔ `let mut`: `let` protege el binding, no el objeto

El binding `let` no puede escribirse… pero eso no impide que **otro**
binding mutable escriba el objeto al que apunta:

```astra
// ejemplos/cap05/alias_let_binding.astra
// `let` protects the BINDING, not the object: q is a mutable alias of the
// same struct p points at, so q.x = 5 is visible through p.
struct P { x: i32 }

fn main() {
    let p = P { x: 1 };        // immutable binding
    let mut q = p;             // mutable alias to the SAME object
    q.x = 5;
    print(p.x);
    print(q.x);
}
```

```text
5
5
```

`p` es inmutable, pero su *objeto* muta por obra de `q`. Ése es el contrato
completo: **`let` protege el binding, no el objeto**. (Este test está
también en la suite de conformidad como
`seed/tests/conformance/arrays/alias_let_visibility.astra`.)

### La otra mitad: ninguna escritura a través de un `let`

Si intentas escribir directamente a través de un binding `let`, ni siquiera
a un campo, es error de compilación:

```astra
// ejemplos/cap05/immutable_field_error.astra
// The other half of the contract: a `let` binding never accepts a write,
// not even to a field.
struct P { x: i32 }

fn main() {
    let p = P { x: 1 };
    p.x = 5;
    print(p.x);
}
```

```text
cap05/immutable_field_error.astra:7:5: error: cannot assign through immutable variable 'p' (declare it with 'let mut')
error: type check failed with 1 error(s)
```

### El contrato en una tabla

| Situación | Resultado |
|:----------|:----------|
| `let mut b = a` (arrays o structs) | comparten handle; `b[0] = 99` se ve en `a` |
| `let q = p` + `let mut` en otro alias | el alias mutable escribe el objeto; `p` sigue siendo binding inmutable |
| `p.x = 5` con `p` declarado `let` | error de compilación: `cannot assign through immutable variable 'p'` |
| `s[i] = …` sobre un string | error de compilación (los strings son inmutables, Capítulo 8) |

### ¿Por qué compartir y no copiar?

Porque el modelo de memoria de Astra lo pide así: ARC/ORC cuenta
referencias, y contar significa *compartir con contabilidad*, no duplicar
(los motivos completos, en `ARCHITECTURE.md` §2.5). Dos consecuencias
honestas para hoy:

- **No hay copia explícita todavía.** `.copy()` no existe en Astra-0; si
  necesitas independencia hoy, reconstruye el agregado campo a campo.
- **Los VMs no liberan memoria** (DEC-009): compartir es gratis pero nada
  se recicla en la ruta VM; la ruta LLVM libera con ARC. El capítulo 11
  cuenta el modelo completo.

### ¿Y entre fibras?

Hoy no hay fibras, así que *dentro de un programa todo lo anterior vale sin
excepciones*. La regla de **cruce de frontera de fibra** ya está escrita
pero **no implementada** (`ARCHITECTURE.md` §2.6; DEC-012, en estado
`Propuesta`): compartir intra-fibra será gratis (como aquí), y cruzar una
frontera exigirá valor único en ese punto — `.copy()` o `Atomic[T]` si no.
Mientras tanto, ésta es una especificación, no algo que puedas programar.

## Resumen

- Un array literal es `[v1, v2, …]`, su tipo es `[T]`, se indexa con `xs[i]`
  y `len(xs)` devuelve `i64`.
- Fuera de rango, arrays: `runtime error: index N out of bounds (len M)` —
  error de runtime en las cuatro rutas, nunca un valor incorrecto.
- Un struct declara campos separados por newline; su literal es
  `P { campo: valor }`, el orden no importa, y un campo desconocido o
  ausente es error de compilación.
- **Asignar un agregado comparte el handle (DEC-001)**: `let b = a` son dos
  nombres del mismo objeto, y una escritura a través de uno se ve en el
  otro.
- **`let` protege el binding, no el objeto**: `p.x = 5` sobre un `let` es
  error de compilación, pero un alias `let mut` puede escribir el mismo
  objeto.
- Entre fibras, la regla llegará con `ARCHITECTURE.md` §2.6 — hoy está
  especificada, no implementada.

## Ejercicios

1. Escribe un struct `Vec2 { x: f64, y: f64 }` y una función que reciba un
   `Vec2` y lo imprima. Después añade un alias `let mut` en `main` y
   responde: ¿qué imprime `p.x` tras modificar a través del alias?
2. Predice la salida — y después compruébala con `seed/astra-seed` — de:

   ```astra
   struct P { x: i32 }
   fn main() {
       let mut a = [1, 2];
       let b = a;
       let mut c = b;
       c[1] = 50;
       print(a[1]);
       print(b[1]);
   }
   ```

3. Un colega escribe `struct Nota { titulo: string, nota: i32 }` (con coma)
   y `Nota { titulo: "examen" }`. Ejecuta el programa y anota los dos
   mensajes de error exactos que produce.
