# Capítulo 4 — Funciones y closures

Las funciones de Astra-0 son simples: parámetros anotados, un tipo de retorno
opcional, y la última expresión del cuerpo como valor de salida. Los closures
son funciones anónimas que **capturan por valor** — una decisión (DEC-004) que
conviene entender bien, porque cambia lo que el closure ve.

## Declarar funciones

```astra
fn suma(a: i32, b: i32) -> i32 {
    a + b
}
```

- **Todos los parámetros van anotados**: `fn f(x)` es error
  (`expected ':', got )`). No hay inferencia de parámetros.
- El tipo de retorno `-> T` es opcional: sin él, la función no devuelve valor
  (si el cuerpo produce uno, se descarta — estilo procedimiento).
- **Return implícito**: si la última sentencia del cuerpo es una expresión
  **sin `;`**, ese es el valor de la función. `return expr;` también existe y
  sirve para salir antes de tiempo.
- Los parámetros son inmutables dentro de la función; para cambiarlos usa un
  local.

El ejemplo completo está en
[`ejemplos/04/funciones.astra`](ejemplos/04/funciones.astra):

```astra
// Funciones: parámetros anotados, return explícito e implícito (el valor de la
// última expresión del cuerpo) y funciones sin valor de retorno.
fn suma(a: i32, b: i32) -> i32 {
    a + b
}

fn restar(a: i32, b: i32) -> i32 {
    return a - b;
}

fn saludar(nombre: string) {
    print("Hola, " + nombre)
}

fn main() {
    print(suma(2, 3));
    print(restar(10, 4));
    saludar("Astra");
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig funciones.astra
5
6
Hola, Astra
```

Dos detalles de la regla del return implícito, fijados en la suite
(`seed/tests/conformance/functions/implicit_return.astra` y
`blocks/tail_expression.astra`):

- un cuerpo puede tener sentencias antes de la expresión final
  (`let t = 100; t + 1` devuelve `101`);
- si la última sentencia lleva `;`, la función **no** devuelve ese valor: la
  expresión se descarta.

## Recursión

El orden de declaración no importa: las funciones pueden llamarse entre sí —
y a sí mismas — sin prototipo. En
[`recursion.astra`](ejemplos/04/recursion.astra):

```astra
// Recursión: factorial y Fibonacci.
fn fact(n: i32) -> i32 {
    if n <= 1 { return 1; }
    return n * fact(n - 1)
}

fn fib(n: i32) -> i32 {
    if n <= 1 { return n; }
    return fib(n - 1) + fib(n - 2)
}

fn main() {
    print(fact(5));
    print(fib(10));
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig recursion.astra
120
55
```

La recursión está acotada: si la cadena de llamadas se dispara, el runtime
para con `runtime error: call depth exceeded` (el mismo texto en las cuatro
rutas) en vez de desbordar la pila del proceso.

## Funciones como valores

Una función puede guardarse en un binding y pasarse como argumento. Su tipo
se escribe `fn(i32) -> i32` — paréntesis con los tipos de los parámetros y el
retorno:

```astra
fn aplicar(f: fn(i32) -> i32, x: i32) -> i32 {
    f(x)
}
```

Ese `aplicar` aparece en el ejemplo de closures de más abajo.

## Closures

Un closure es una función anónima entre barras: `|x: i32| -> i32 { x + 1 }`.
Los parámetros **se anotan igual que en `fn`**; sin anotar, su tipo es
`unknown` y el cuerpo no compila
([`error_param_sin_anotar.astra`](ejemplos/04/error_param_sin_anotar.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_param_sin_anotar.astra
error_param_sin_anotar.astra:3:19: error: arithmetic operator requires numeric type, got unknown
```

El `-> R` puede omitirse cuando el cuerpo lo determina
(`|x: i32| { x + 1 }` funciona); si no se puede inferir, el compilador pide
`lambda requires explicit return type annotation`.

**Trampa con los closures sin parámetros**: `||` se lexea como el operador
lógico `or`, así que una función sin argumentos se escribe **con una barra
vacía entre espacios**, `| | -> i32 { 7 }`. Con `||` directamente obtienes
`unexpected token in expression`.

### Capturan por valor (DEC-004)

Cuando construyes el closure, este **copia el valor de las variables libres
que usa** — un snapshot. Reasignar la variable después **no le llega**. En
[`closures.astra`](ejemplos/04/closures.astra):

```astra
// DEC-004: los closures capturan por valor — copian el handle en el momento
// de construir el closure; reasignar la variable después no les llega.
fn aplicar(f: fn(i32) -> i32, x: i32) -> i32 {
    f(x)
}

fn main() {
    let mut n = 5;
    let f = |x: i32| -> i32 { x + n };
    n = 10;
    print(f(1));

    let factor = 3;
    let escalar = |x: i32| -> i32 { x * factor };
    print(escalar(4));
    print(aplicar(escalar, 5));
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig closures.astra
6
12
15
```

La primera línea es la prueba: `n` vale `10` cuando se llama `f(1)`, pero el
closure se construyó con `n = 5`, así que imprime `1 + 5 = 6`, no `11`.

### Asignar a una capturada es error de compilación

Como no hay celda a la que escribir, el compilador lo prohíbe en lugar de
simplemente no hacer nada ([`error_capture.astra`](ejemplos/04/error_capture.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_capture.astra
error_capture.astra:4: error: cannot assign to captured variable 'n' (closures capture by value)
```

(El compilador semilla emite la misma línea — con el mismo texto — y cierra
con `error: code generation failed with 1 error(s)`; el Zig la reporta antes,
en el chequeo de tipos.)

Los closures pueden vivir en el nivel de módulo, guardarse en otros bindings
y anidarse: el ejemplo `seed/tests/conformance/lambda/closures.astra` cubre
los tres casos.

## Aún no existe

- **Captura por referencia** (`&x`) o captura débil: `ARCHITECTURE.md` §30.5
  las describe, pero hoy solo existe la captura por valor (DEC-004).
- **Parámetros por defecto, variádicos o con nombre**: todos los argumentos
  son posicionales y la cuenta es fija (`expected 1 arguments, got 2` para
  `print`).
- **`fn` con parámetros sin anotar** (inferencia de firmas): no.
- **Sobrecarga de funciones**: cada nombre declara una sola función; los
  métodos con `self` existen vía `impl`/traits y están en el capítulo 9.

---

## Resumen

- `fn nombre(p: T, …) -> R { … }`: parámetros siempre anotados, retorno
  opcional, **última expresión sin `;` = valor de retorno**.
- `return` explícito para salir antes; la recursión funciona y está acotada
  con `call depth exceeded`.
- Las funciones son valores: su tipo es `fn(T, …) -> R`.
- Los closures `|x: T| -> R { … }` capturan **por valor** (DEC-004): el
  snapshot es el de la construcción, y **asignar a una capturada no compila**.

## Ejercicios

1. Escribe `fn max(a: i32, b: i32) -> i32` usando un `if` como expresión, sin
   `return`. Después reescríbela con `return` explícito y compara.
2. Intenta un contador con closure: `let mut n = 0` seguido de
   `let incr = |x: i32| -> i32 { n = n + x; n }`. El compilador lo rechaza;
   explica con tus palabras por qué (DEC-004) y sustitúyelo por una función
   que reciba el valor y devuelva el nuevo total.
3. Usa `aplicar` (o tu propio `fn aplicar(f: fn(i32) -> i32, x: i32) -> i32`)
   para pasarle tres closures distintos y comprueba que el resultado cambia
   con cada uno.
