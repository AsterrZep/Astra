# Capítulo 10 — Módulos y programas multi-fichero

Un script cabe en un fichero; un programa no. Astra-0 usa el diseño
**file-as-module** (`ARCHITECTURE.md` §10.1): **cada fichero `.astra` es un
módulo**, sin declaraciones `mod` ni ficheros especiales de registro. Abres un
fichero nuevo, escribes `pub` en lo que quieras exportar, y otro fichero lo
importa.

Este capítulo describe el sistema **real**, no el plan de diseño: `use`,
`pub`, rutas con punto (`DEC-003`), la raíz `@/` anclada en `astraea.toml`, el
orden de ejecución entre ficheros y —con la misma importancia— **quién puede
compilar multi-fichero hoy y quién no**.

Advertencia honesta antes de empezar: la **ruta multi-módulo existe en
`astra-zig`** (compilador Zig, Fase 2.2). El seed compila **un fichero**:
parsea `import`/`from`/`use` y los descarta deliberadamente
(`research/002` §5.2), para que los dos compiladores compartan la misma
gramática. Si ejecutas un programa multi-fichero con `astra-seed`, verás
`undefined variable` en cada nombre importado — no es un bug tuyo.

## Un primer programa de tres ficheros

El ejemplo vive en `Documentacion/09_libro/ejemplos/10_multifichero/`:

```text
10_multifichero/
├── astraea.toml            # marcador de raíz de proyecto (para `@/`)
├── main.astra            # la raíz: declara imports y tiene `main`
├── lib/util.astra        # dependencia de nivel de proyecto
└── geometry/shape.astra  # submódulo relativo a main.astra
```

`geometry/shape.astra`:

```astra
// Submódulo relativo: main.astra lo importa como geometry.shape.
pub const SIDES = 4

pub fn area(x: i32) -> i32 {
    x * x
}

fn private_diag(x: i32) -> i32 {
    x + x
}
```

`lib/util.astra`:

```astra
// Dependencia de nivel raíz, alcanzable desde cualquier directorio con @/.
pub fn twice(x: i32) -> i32 {
    x * 2
}

// Sin `pub`: no puede importarse desde otro módulo.
fn helper() -> i32 {
    99
}
```

`main.astra`:

```astra
// Ejemplo del capítulo 10 — programa multi-fichero de verdad:
//   astraea.toml          raíz del proyecto (marca `@/`)
//   lib/util.astra      dependencia de nivel raíz
//   geometry/shape.astra submódulo relativo a este fichero
from @/lib.util import twice
from geometry.shape import area, SIDES
import geometry.shape as geo

fn main() {
    print(twice(21))     // 42
    print(area(5))       // 25
    print(SIDES)         // 4
    print(geo.area(3))   // 9
}
```

Ejecutarlo (funciona desde cualquier directorio; las rutas de import se
resuelven contra el fichero, no contra tu cwd):

```console
$ zig/zig-out/bin/astra-zig Documentacion/09_libro/ejemplos/10_multifichero/main.astra
42
25
4
9
```

## Las tres formas de importar

La gramática (`ImportPath ::= ("@" "/")? Identifier (("." | "/") Identifier)*`)
admite tres sentencias, y cada una ata un nombre distinto:

| Sentencia | Qué ata | Ejemplo del programa |
|:----------|:--------|:---------------------|
| `from ruta import a, b as c` | los nombres citados (con alias opcional) | `from geometry.shape import area, SIDES` → `area`, `SIDES` |
| `import ruta` | el **último segmento** como espacio de nombres | `import geometry.shape` → `shape.area(3)` |
| `import ruta as m` | el alias `m` como espacio de nombres | `import geometry.shape as geo` → `geo.area(3)` |

El «último segmento» es una decisión de diseño (GAP App. B #11):
`import geometry.shape` no ata `geometry`, ata `shape`. El alias `as` es el
camino explícito cuando el nombre no te conviene.

`from X import a as b` renombra en la importación: la forma
`from geometry.shape import area as superficie, SIDES as caras` también está
verificada.

### `use` = re-export

`use` no ata nada para ti: **re-exporta los exports públicos del módulo que
nombra** (un nivel por sentencia). El ejemplo está en
`ejemplos/10_reexport/`:

```astra
// middle.astra
use base

pub fn extra() -> i32 { 6 }
```

```astra
// main.astra
from middle import twice, K, extra
import middle

fn main() {
    print(twice(K))     // 10
    print(extra())      // 6
    print(middle.twice(3)) // 6
    print(middle.K)     // 5
}
```

```text
10
6
6
5
```

`twice` y `K` viven en `base.astra`; `middle` los adelanta porque hace `use
base`. Los nombres propios ganan sobre los re-exportados, y las cadenas de
`use` componen en orden de dependencias.

## Privacidad: `pub` es lo único que exporta

- **Todo es privado por defecto**: `helper()` y `private_diag()` de los
  ejemplos anteriores no se pueden importar.
- **`pub` precede a `fn`, `struct`, `enum` y `const`** a nivel de módulo.
  No a `let` (`'pub' can only precede...`, fijado por `ui/pub_let.astra`) ni
  a campos de struct: `pub x: i32` dentro de un struct **no parsea hoy**
  (`expected field name, got pub`) — el ejemplo con campos `pub` de
  `ARCHITECTURE.md` §10.2 es diseño, no comportamiento actual.
- La comprobación es **real en la ruta multi-módulo**: intenta importar un
  nombre privado con `ejemplos/10_multifichero/importa_privado.astra`:

```text
importa_privado.astra: error: module 'geometry.shape' does not export 'private_diag'
importa_privado.astra:8:11: error: undefined variable 'private_diag'
```

## Rutas: punto, barra y la raíz `@/`

- **El separador es `.`** — decisión **DEC-003**, fijada por
  `ui/use_colon_colon.astra`: `use a::b` muere con
  `unexpected token in expression`. La barra `/` es intercambiable en la
  gramática (`geometry/shape` ≡ `geometry.shape`); el cargador siempre
  normaliza a `/` en el sistema de ficheros.
- **Relativo al fichero que importa**: desde `main.astra`,
  `geometry.shape` busca `geometry/shape.astra` al lado suyo. Un hermano se
  importa por su nombre suelto (`vector`), no por la ruta completa.
- **`@/` se ancla en el `astraea.toml`**: el cargador camina hacia arriba desde
  el fichero de entrada hasta encontrar el primer directorio con `astraea.toml`
  y resuelve `@/lib.util` como `<raíz>/lib/util.astra` — por eso funciona
  igual desde `main.astra` que desde `nested/inner.astra`. **Sólo se comprueba
  la existencia** del manifest; leer `[package]` o `[dependencies]` es hoy
  trabajo del (futuro) package manager. Sin manifest:

```text
sin_manifest.astra: error: cannot resolve '@/base': no astraea.toml found (project root)
```

- **`std/...` (con barra) se rechaza**: no hay stdlib.
  `use std/io` → `cannot resolve 'std/io': no standard library exists yet`.
  Ojo: la forma **punteada** `std.io` *no* tiene caso especial — es una ruta
  relativa normal, así que en modo multi-módulo busca `std/io.astra` al lado
  del fichero y acaba en `std/io.astra: error: cannot read module:
  FileNotFound`.

## Orden de ejecución entre ficheros

El cargador construye el grafo en **orden post-order: dependencias primero,
raíz la última** (`PHASE2_PROGRESS.md` §7.1). El código de nivel de módulo de
cada fichero se ejecuta en ese orden, y `main` sólo se llama en la raíz.
Ejemplo en `ejemplos/10_orden/`:

```astra
// deps.astra
print("1. modulo deps corriendo")

pub fn value() -> i32 {
    7
}
```

```astra
// main.astra
from deps import value

print("2. raiz main corriendo")
print(value())
```

```text
1. modulo deps corriendo
2. raiz main corriendo
7
```

**Los ciclos están prohibidos** (`ARCHITECTURE.md` §10.6) y es el único error
que no se ve fichero a fichero — cada fichero del ciclo es válido, sólo la
cadena está mal. El cargador lo detecta (`ejemplos/10_ciclo/`):

```text
a.astra: error: circular import: a.astra -> b.astra -> a.astra
```

## Cómo se compila y se inspecciona hoy

Los comandos de esta sección se ejecutan **dentro del directorio del
ejemplo** (`ejemplos/10_multifichero/`), porque los dumps imprimen rutas
relativas:

```console
$ zig/zig-out/bin/astra-zig main.astra              # compila y ejecuta el programa completo
$ zig/zig-out/bin/astra-zig --dump-modules main.astra   # sólo el grafo de módulos
$ zig/zig-out/bin/astra-zig --single-file main.astra    # semántica seed: ignora los imports
```

`--dump-modules` sobre el ejemplo del capítulo:

```text
module graph: 3 module(s)
  lib/util.astra
    exports: twice
  geometry/shape.astra
    exports: SIDES, area
  main.astra
    from @/lib.util -> lib/util.astra [binds twice]
    from geometry.shape -> geometry/shape.astra [binds area, SIDES]
    import geometry.shape -> geometry/shape.astra as geo
```

Muestra cada fichero alcanzado, sus exports `pub` y a qué fichero apunta cada
declaración. Con `--dump-bytecode` cada módulo aparece en su propia sección
(sus globals van manglados con un prefijo `m<i>.` para que la tabla plana de
la VM no los mezcle).

Y lo que **no** es esta ruta — el mismo `main.astra` en el seed:

```console
$ seed/astra-seed Documentacion/09_libro/ejemplos/10_multifichero/main.astra
main.astra:10:11: error: undefined variable 'twice'
main.astra:11:11: error: undefined variable 'area'
main.astra:12:11: error: undefined variable 'SIDES'
main.astra:13:11: error: undefined variable 'geo'
error: type check failed with 4 error(s)
```

## Límites conocidos

Todo esto está verificado hoy (fuentes: `PHASE2_PROGRESS.md` §7, tests
`zig/tests/link/` y la suite de conformidad):

| Límite | Qué verás |
|:-------|:----------|
| El seed no resuelve módulos | `undefined variable` por cada nombre importado (parsea y descarta) |
| No hay stdlib | `cannot resolve 'std/io': no standard library exists yet` |
| `astraea.toml` sólo es marcador | `[dependencies]` no se lee; no hay registry ni versiones |
| Los **structs/traits genéricos no se exportan** | `module 'x' does not export 'Box'` — los exports filtran las plantillas genéricas (cap. 9) |
| Traits y `impl` **no cruzan módulos** | cada módulo tiene su tabla de métodos; `from dep import T` no trae traits |
| `pub` no va en campos ni en `let` | `expected field name, got pub` / `'pub' can only precede...` |
| Sólo items de nivel módulo | un `import` dentro de una función se ignora |
| `--debug` multi-módulo | mapea todas las líneas contra el fuente de la raíz (limitación conocida) |
| El tipo enum como valor | `let x = Shape` es error de runtime compartido por ambos compiladores |

## Aún no existe

- **Package manager**: `astraea.toml` con `[dependencies]` y registry —
  `research/016` y `ARCHITECTURE.md` §10.7 son diseño, no código.
- **stdlib** (`std/io`, `std/fs`, …): la gramática la admite, ningún módulo
  la trae.
- Re-exportar el **nombre de un módulo** como namespace (`utils.Logger.info`)
  — GAP App. B #13, sigue abierto.
- Compilación de paquetes con múltiples raíces, `pub(crate)`, visibilidad en
  campos — sólo existen `pub` y privado, a nivel de item.

## Resumen

- **File-as-module**: un `.astra` = un módulo; privado por defecto, `pub` en
  `fn`/`struct`/`enum`/`const`.
- **Tres sentencias**: `from X import a` (nombres), `import X` (último
  segmento como namespace), `import X as m` (alias); `use X` re-exporta un
  nivel.
- **Rutas** con `.` (DEC-003, `::` rechazado), `/` intercambiable, relativas
  al fichero importador, `@/` anclado en el `astraea.toml` más cercano hacia
  arriba (sólo su existencia), `std/` rechazado por no existir stdlib.
- **Ejecución post-order**: dependencias primero (su código de nivel módulo
  incluido), raíz la última; ciclos → `circular import: ...`.
- **Hoy esto lo compila `astra-zig`**; el seed es de un solo fichero — usa
  `--single-file` para reproducir su semántica sobre el mismo programa.

## Ejercicios

1. Crea `geometry/perim.astra` con `pub fn perim(x: i32) -> i32` y llámalo
   desde `main.astra` de las tres formas (`from`, `import` desnudo y `as`).
2. Amplía `importa_privado.astra` para que intente importar `SIDES` (que sí
   es `pub`) y `private_diag` (que no): captura los dos mensajes distintos.
3. Convierte `10_orden/` en un ciclo (`deps.astra` importa de `main.astra`)
   y captura el `circular import`; después rompe el ciclo con un tercer
   módulo neutro y vuelve a dejarlo verde.
