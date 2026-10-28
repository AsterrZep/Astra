# Capítulo 09 — Genéricos, `impl` y traits

Hasta aquí has escrito funciones y structs que trabajan con un tipo concreto:
`fn doble(x: i32)`, `struct Punto { x: i32 }`. El día que necesitas la misma
lógica para `i32`, para `string` y para tus propias structs, tienes dos
opciones malas: copiar y pegar el código, o meter `if` por todas partes con
valores convertidos a mano. **Astra-0 tiene genéricos de verdad**: escribes
la función una vez con `<T>` y cada tipo concreto obtiene su propia versión.

En este capítulo ves lo que existe **hoy**, verificado contra la suite de
conformidad (`seed/tests/conformance/generics/` y `traits/`):

- funciones y structs genéricos con inferencia en el punto de llamada;
- monomorfización (la abstracción no cuesta nada en runtime);
- bloques `impl` con métodos y su dispatch estático;
- traits: declararlos, implementarlos y lo que exige la conformidad;
- bounds (`T: Show`) y sus errores exactos;
- y —importante— la lista de límites conocidos, para que no pierdas una
  tarde descubriendo que algo aún no existe.

## Funciones genéricas

La sintaxis es un parámetro de tipo entre `<...>` delante del nombre:

```astra
fn identity<T>(x: T) -> T {
    x
}
```

`T` es un **parámetro de tipo**: un marcador de posición que se sustituye por
un tipo real en cada llamada. No hay que declarar de antemano por qué tipos
vale; el compilador **infiere `T` en el punto de llamada** a partir de los
argumentos que pasas.

El ejemplo completo está en
`Documentacion/09_libro/ejemplos/09/genericos_fn.astra`:

```astra
fn identity<T>(x: T) -> T {
    x
}

fn choose<T>(cond: bool, a: T, b: T) -> T {
    if cond { return a }
    b
}

// Una fn genérica puede llamar a otra: la instancia de `fwd` resuelve la
// de `identity` cuando su binding es concreto.
fn fwd<T>(x: T) -> T {
    identity(x)
}

print(identity(7))
print(identity("hola"))
print(choose(true, 1, 2))
print(choose(false, "a", "b"))
print(choose(true, true, false))
print(fwd(42))
```

Salida real (con `zig/zig-out/bin/astra-zig` y con `seed/astra-seed`, idéntica
en ambas rutas):

```text
7
hola
1
b
true
42
```

Tres reglas prácticas, todas fijadas por la suite:

1. **Cada argumento de tipo se deduce solo.** `identity(7)` liga `T = i32`
   (un literal entero sin anotar es `i32`, DEC-006) y `identity("hola")` liga
   `T = string`. Si un mismo parámetro recibe dos tipos distintos en una
   llamada es error:
   `type parameter 'T' of 'pair' cannot be both i32 and string`.
2. **Si `T` no aparece en ningún argumento, no hay nada que inferir** y el
   compilador lo dice: `cannot infer type parameter 'T' of 'make'`.
3. **El nombre de una función genérica no es un valor**: `let f = identity`
   produce `generic function 'identity' used as a value`. No existe «pasar la
   plantilla» como función — sólo sus instancias concretas.

> **Monomorphización (una frase).** Cada combinación concreta de argumentos
> (`identity<i32>`, `identity<string>`, `choose<i32>`…) se materializa como
> una instancia propia con el nombre manglado en el módulo: el programa
> final contiene versiones concretas por tipo, sin despacho dinámico ni
> indirección — la abstracción se paga en tamaño de binario, no en tiempo.

Hay techos duros con su error dedicado: **32 parámetros** por lista, 32
argumentos por uso, **256 instancias** por programa y un nombre manglado de
máximo 512 bytes.

No hay forma de escribir los argumentos a mano en la llamada (turbofish
`f<i32>()` no parsea): si la inferencia no puede resolver `T`, el error es la
única señal que necesitas.

## Structs genéricos

Un struct puede parametrizar sus campos. El ejemplo está en
`ejemplos/09/genericos_struct.astra`:

```astra
struct Box<T> {
    value: T
}

struct Pair<A, B> {
    first: A
    second: B
}

fn unbox(b: Box<i32>) -> i32 {
    b.value
}

let annotated: Box<i32> = Box { value: 42 }
print(annotated.value)
print(unbox(Box { value: 7 }))
print(Pair { first: 1, second: "hola" }.second)
print(Box { value: "deep" })
print(Box { value: "hola" })
print(Pair { first: 1, second: "x" })
```

```text
42
7
hola
Box { value: deep }
Box { value: hola }
Pair { first: 1, second: x }
```

Hay dos caminos para fijar los argumentos:

- **anotación explícita**: `let annotated: Box<i32> = ...` — el tipo de la
  anotación materializa `Box<i32>`;
- **inferencia desde el literal**: `Box { value: 7 }` mira el tipo del valor
  del campo y deduce `Box<i32>`; en `unbox(Box { value: 7 })` la firma del
  parámetro ayuda a la misma deducción.

Y un detalle amable al imprimir: las instancias comparten el nombre del
struct de origen, así que `print` muestra `Box { value: 42 }`, no el nombre
manglado `Box<i32>`.

Errores que puedes encontrarte aquí (los fija la suite `ui/`):

- `Box` sin argumentos en posición de tipo → `type 'Box' requires type arguments`;
- argumentos de más → `expected N, got M`;
- `i32<f32>` (argumentos sobre primitivas) → se aceptan en silencio hoy: las
  primitivas resuelven antes de mirar los argumentos (límite conocido);
- inferencia imposible o en conflicto → los mismos mensajes
  `cannot infer type parameter` / `cannot be both ...` de las funciones.

## `impl`: métodos sobre tus tipos

Un bloque `impl` añade métodos a un struct o enum concreto. El ejemplo está
en `ejemplos/09/impl_metodos.astra`:

```astra
struct Point {
    x: i32
    y: i32
}

enum Color {
    Red
    Green
}

impl Point {
    fn get_x(self) -> i32 {
        self.x
    }
    fn add(self, n: i32) -> i32 {
        self.x + n
    }
    // Los métodos pueden devolver el propio tipo y encadenarse.
    fn moved(self, dx: i32) -> Point {
        Point { x: self.x + dx, y: self.y }
    }
}

impl Color {
    fn name(self) -> string {
        return match self {
            Color.Red => "red",
            Color.Green => "green",
        };
    }
}

let p = Point { x: 40, y: 2 }
print(p.get_x())
print(p.add(2))
print(p.moved(2).get_x())
print(Color.Red.name())
```

```text
40
42
42
red
```

Cómo se declaran **hoy**, sin sorpresas:

- `self` es obligatorio como **primer parámetro** de cada método; si no está,
  el parser lo rechaza (`impl_missing_self.astra`).
- Sólo **structs y enums** pueden llevar `impl` — un `impl` sobre `i32` es
  error de compilación (`impl_primitive_receiver.astra`).
- El receptor se hereda del tipo del bloque: escribes `self`, no `self: Point`.
- La resolución es **estática, en compile time**: `p.add(2)` se resuelve en la
  tabla de métodos del receptor y se convierte en una llamada a la función
  global `Point.add`. No hay vtables ni despacho dinámico.
- Los métodos se encadenan porque el tipo de retorno alimenta la siguiente
  búsqueda (`p.moved(2).get_x()`).
- **Un método no es un valor**: `let f = p.get_x` responde
  `method 'get_x' of 'Point' must be called`. No existen referencias a
  métodos de primer nivel.

## Traits: contratos que otros tipos cumplen

Un trait declara un conjunto de métodos; `impl T for X` es la promesa de que
`X` los cumple. El ejemplo completo está en `ejemplos/09/traits.astra`:

```astra
trait Math {
    fn add(self, n: i32) -> i32
    fn label(self) -> string
}

trait Marker {
}

struct Point {
    x: i32
}

struct Other {
    y: i32
}

impl Math for Point {
    fn add(self, n: i32) -> i32 {
        self.x + n
    }
    fn label(self) -> string {
        return "point"
    }
}

impl Marker for Other {
}

impl Point {
    // También declarada en el trait: la versión inherent gana en TODOS los
    // call sites (7, no 3) — el trait conserva la suya para quien la pida
    // por su ruta.
    fn add(self, n: i32) -> i32 {
        self.x + n + 4
    }
}

let p = Point { x: 1 }
let o = Other { y: 5 }
print(p.add(2))
print(p.label())
print(o.y)
print("marker")
```

```text
7
point
5
marker
```

Reglas de la conformidad (paso 5 de la Fase 2.3, idéntica en los dos
compiladores):

1. **`impl T for X` debe nombrar un trait que exista** —
   si no: `unknown trait 'T'`.
2. **Debe declarar todos los métodos requeridos** con aridad y tipos
   coincidentes. Un método inherent *no* sustituye al del trait:
   `type 'X' does not implement trait 'T': missing method 'm'` y
   `signature of method 'm' of 'X' does not match trait 'T'`.
3. **Los traits vacíos (`trait Marker {}`) son legales** — sirven como
   marcadores, y también satisfacen bounds (más abajo).
4. **`impl` propio gana a `impl` de trait** sin importar el orden de
   declaración: en el ejemplo, `p.add(2)` imprime `7` (versión inherent) y no
   `3`. Entre dos traits con el mismo método gana el primero declarado —
   desempatar entre traits requiere sintaxis que aún no existe.
5. **`self` es una palabra contextual**: fuera de `impl`, `let self = 41` es
   un identificador normal (así lo fija `traits/trait_inert.astra`).

Un trait con **métodos por defecto** (con cuerpo) se rechaza hoy con el error
dedicado `default trait methods are not yet supported` — ver
`ejemplos/09/no_compilan/trait_default.astra`.

## Bounds: exigir un trait a un tipo genérico

Un parámetro de tipo puede llevar una lista de traits obligatorios:

```astra
trait Show {
}

struct Point {
    x: i32
}

impl Show for Point {
}

struct Box<T: Show> {
    v: T
}

fn accept<T: Show>(x: T) -> i32 {
    1
}

let p = Point { x: 1 }
let b = Box { v: p }
print(accept(p))
print(b.v.x)
print("point")
```

(`ejemplos/09/bounds.astra`)

```text
1
1
point
```

Cómo funciona el chequeo **hoy**:

- El bound se comprueba en cada punto donde el parámetro se vuelve concreto.
  Si falla, el mensaje es este (sólo structs y enums pueden llevar `impl`,
  así que `i32` nunca satisface un bound):

  ```text
  type parameter 'T' of 'accept' requires bound 'Show': type 'i32' does not implement trait 'Show'
  ```
- El **nombre** del bound se valida en firme al declarar, aunque nadie
  llame a la función: `unknown trait 'Missing'`.
- Sólo **fn y struct** vinculan parámetros hoy; bounds en enums, traits o
  `impl` genéricos se parsean y se ignoran (siguen «inertes»).

Y la limitación más importante de todas: **el dispatch de métodos no mira
los bounds**. No puedes llamar `x.show()` dentro de una genérica con
`T: Show` — lo intentas y obtienes
`cannot access field on non-struct type type parameter`
(`ejemplos/09/no_compilan/metodo_sobre_parametro.astra`). El bound hoy sólo
sirve para *validar instanciación*, no para *seleccionar métodos*.

## Límites conocidos

Todo lo de esta sección está verificado hoy con los dos compiladores; los
ficheros `ejemplos/09/no_compilan/` producen exactamente estos mensajes:

| Qué no puedes hacer | Mensaje real que verás |
|:--------------------|:-----------------------|
| Llamar métodos sobre `T` (`x.show()` con `T: Show`) | `cannot access field on non-struct type type parameter` |
| Construir un enum genérico (`Wrap<i32>.Some(1)`) | `unexpected token in expression` — los enums genéricos **parsean y se declaran inertes** |
| Trait con método por defecto | `default trait methods are not yet supported` |
| `impl<T> Holder { ... }` | parsea, pero el bloque es inerte: el método no existe (`struct 'Holder' has no field 'ping'`) |
| `impl Show for Box<i32>` | el objetivo del `impl` no acepta argumentos de tipo |
| Aritmética sobre `T` | `operator '+' cannot be applied to type parameter 'T'` (los bounds no dan operadores) |
| Pasar una genérica como valor | `generic function '<nombre>' used as a value` |
| `where`, turbofish `f<i32>()`, impls blanket (`impl<T> Trait for T`) | no parsean / fuera de alcance |
| Exportar una plantilla genérica a otro módulo | `module 'x' does not export 'Box'` (los exports filtran las genéricas — cap. 10) |
| Traits y métodos cross-módulo | las tablas viven en cada módulo; `from dep import T` no exporta traits aún |

Una nota sobre `generics/inert.astra`: el nombre es histórico. Ese fichero
nació en el paso 1, cuando *toda* declaración genérica se parseaba y se
ignoraba. Hoy **fn y struct son de verdad**; siguen inertes los enums
genéricos, los `impl<T>` y los bounds fuera de fn/struct — y el propio test
lo sigue fijando.

## Aún no existe

- **Objetos de trait / `dyn`**: no hay vtables; todo el despacho es estático.
- **UFCS** (`T::m(x)`, métodos como valores) — se resolverá junto con los
  genéricos avanzados.
- **`impl<T> Trait for T`** (blanket impls) y `impl Show for Box<i32>`.
- **Métodos genéricos cross-módulo** (ver cap. 10).
- El estado detallado vive en
  `Documentacion/04_fase2_zig/PHASE2_PROGRESS.md` §8.3/§9.6 — este capítulo
  sólo traduce lo que la suite verifica.

## Resumen

- `fn f<T>(...)` y `struct S<T> { ... }` con **inferencia en el punto de
  llamada**; cada combinación concreta se **monomorfoza** en su propia
  instancia (32 parámetros, 256 instancias como techo).
- `impl Tipo { fn m(self, ...) ... }` añade métodos con `self` obligatorio,
  sólo sobre structs/enums, con **despacho estático** y encadenamiento.
- `impl Trait for Tipo` exige todos los métodos con su firma; el `impl`
  propio sombra al del trait en cada call site; traits vacíos = marcadores.
- `T: Trait` **valida** la instancia pero **no da métodos ni operadores**.
- La lista «Límites conocidos» es tu mapa: lo que no está ahí está en
  «Aún no existe», y nada de este capítulo existe «a medias» sin decirlo.

## Ejercicios

1. Añade a `impl_metodos.astra` un método `sub(self, n: i32) -> Point` y una
   llamada encadenada que lo use. Comprueba la salida con las dos rutas.
2. Declara un trait `Area` con `fn area(self) -> i32` e implántalo para dos
   structs distintos; después añade un método `area` propio a uno de ellos y
   verifica con la salida que el `impl` propio gana.
3. Escribe `fn double<T>(x: T) -> T { x + x }` y llámalo con `2`. Localiza en
   la tabla de límites el mensaje exacto que produce y explica por qué el
   compilador no puede aceptarlo hoy.
