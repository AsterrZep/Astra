# Capítulo 3 — Control de flujo

Todo programa necesita decidir y repetir. En Astra-0 tienes `if`/`else`
(sentencia y expresión), `while` y `for..in` sobre arrays y rangos, con
`break` y `continue`. No hay más bucles: lo que ves es lo que hay.

## `if` / `else`

Como **sentencia** (para ejecutar cosas) y como **expresión** (para producir
un valor), con `else if` en cadena. En
[`if_sentencia_expresion.astra`](ejemplos/03/if_sentencia_expresion.astra):

```astra
// if/else como sentencia, `else if` en cadena y `if` como expresión.
fn main() {
    let x = 7;

    if x > 10 {
        print("grande");
    } else if x > 5 {
        print("medio");
    } else {
        print("pequeño");
    }

    let categoria = if x > 5 { "mayor" } else { "menor" };
    print(categoria);
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig if_sentencia_expresion.astra
medio
mayor
```

Como expresión, **los dos brazos deben producir el mismo tipo**: si no, el
compilador lo dice antes de ejecutar nada
([`error_if_brazos.astra`](ejemplos/03/error_if_brazos.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_if_brazos.astra
error_if_brazos.astra:3:13: error: if branches have different types: integer literal vs string
error_if_brazos.astra:4:11: error: undefined variable 'y'
```

(La segunda línea es efecto dominó: al rechazar la inicialización, `y` queda
sin declarar.)

### Los bloques también son expresiones

El valor de un bloque es su **última expresión, la que no lleva `;`**
([`bloque_expresion.astra`](ejemplos/03/bloque_expresion.astra)):

```astra
// Un bloque es una expresión: su valor es la última expresión sin `;`.
fn main() {
    let a = { 1 + 2 }
    let b = {
        let t = 3
        t * 4
    }
    print(a)
    print(b)
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig bloque_expresion.astra
3
12
```

Si la última sentencia lleva `;`, el bloque no tiene valor y no puede
inicializar un `let` — el compilador responde
`cannot be initialized with a void expression: this expression has no value to
bind`. Esta misma regla es la que hace
posible el *return* implícito de las funciones, en el
[capítulo 4](04_funciones_closures.md).

## `while`

[`while_break_continue.astra`](ejemplos/03/while_break_continue.astra) suma
los números del 1 al 6 saltando el 3 y parando en el 5:

```astra
// while con break y continue.
fn main() {
    let mut i = 0;
    let mut suma = 0;
    while i < 6 {
        i = i + 1;
        if i == 3 { continue; }
        if i == 5 { break; }
        suma = suma + i;
    }
    print(i);
    print(suma);
}
```

```text
$ ../../../../zig/zig-out/bin/astra-zig while_break_continue.astra
5
7
```

`continue` vuelve a la condición; `break` sale del bucle. Fuera de un bucle,
ambos son error de compilación: `'break' used outside of a loop` y
`'continue' used outside of a loop`.

## `for..in`

`for` itera **arrays y rangos**. Nada más.

### Arrays

De [`for_arrays_rangos.astra`](ejemplos/03/for_arrays_rangos.astra)
(fragmento, con la sangría recortada):

```astra
let xs = [10, 20, 30];
let mut total = 0;
for x in xs {
    total = total + x;
}
```

### Rangos

- `0..3` es **exclusivo**: 0, 1, 2.
- `1..=3` es **inclusivo**: 1, 2, 3.
- El límite puede ser una expresión (`1..=n`), no solo un literal.

El ejemplo completo, con las tres formas, está en
[`for_arrays_rangos.astra`](ejemplos/03/for_arrays_rangos.astra):

```text
$ ../../../../zig/zig-out/bin/astra-zig for_arrays_rangos.astra
60
0
1
2
1
2
3
```

### Qué no itera `for`

- **Enteros sueltos**: `for i in 5` no es una secuencia
  ([`error_for_entero.astra`](ejemplos/03/error_for_entero.astra)):

  ```text
  $ ../../../../zig/zig-out/bin/astra-zig error_for_entero.astra
  error_for_entero.astra:3:14: error: for loop must iterate over an array or range, got integer literal
  ```

- **Strings**: `for c in "hola"` da el mismo rechazo con `got string`. Hoy no
  se puede iterar un string carácter a carácter con `for` (se recorre con un
  `while` y `s[i]`, que devuelve un string de 1 byte — DEC-013, capítulo 8).

- **Paso personalizado** (`by 2`): no existe. Para dar pasos, usa `while` con
  tu propio contador.

El enlace de `for` es **un binding nuevo en cada iteración**, así que no toca
una variable homónima de fuera: si `i` vale `0` antes del bucle, tras
`for i in 0..5 { … }` sigue valiendo `0`.

### `break` y `continue` en `for`

[`for_break_continue.astra`](ejemplos/03/for_break_continue.astra):

```text
$ ../../../../zig/zig-out/bin/astra-zig for_break_continue.astra
1
3
4
```

## Dos asignadores que no existen

### `+=` y compañía

No están en la gramática: `x += 1` muere en el parser de expresiones
([`error_asignador_compuesto.astra`](ejemplos/03/error_asignador_compuesto.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_asignador_compuesto.astra
error_asignador_compuesto.astra:4:8: error: unexpected token in expression
error_asignador_compuesto.astra:6:1: error: unexpected token in expression
```

Escribe `x = x + 1`.

### `break` con valor

La gramática de investigación contempla `break Expression`, pero Astra-0 no
tiene un `loop` que reciba ese valor, así que es error de compilación
([`error_break_valor.astra`](ejemplos/03/error_break_valor.astra)):

```text
$ ../../../../zig/zig-out/bin/astra-zig error_break_valor.astra
error_break_valor.astra:4:15: error: break with a value is not supported in Astra-0
error_break_valor.astra:5:5: error: unexpected token in expression
error_break_valor.astra:6:1: error: unexpected token in expression
```

## Aún no existe

- `loop` infinito sin condición (ni su `break` con valor).
- `for` con paso (`by`) o sobre strings.
- `do/while`, etiquetas y `goto`.
- Asignadores compuestos (`+=`, `-=`, `*=`…).

---

## Resumen

- `if`/`else` funciona como sentencia y como expresión; los brazos de la forma
  expresión deben tener el mismo tipo.
- Un bloque vale lo que vale su última expresión sin `;`.
- `while` con `break`/`continue`; `for..in` solo sobre **arrays y rangos**
  (`..` exclusivo, `..=` inclusivo).
- El enlace de `for` es nuevo en cada iteración y no pisa variables de fuera.
- No existen `+=`, `break` con valor ni `loop` sin condición.

## Ejercicios

1. Imprime los números pares del 0 al 10 con `for..in` y un `if`. Después,
   haz lo mismo con `while` y comprueba que ambas salidas coinciden.
2. Escribe un `if` como expresión que asigne a `let mensaje` una de dos
   cadenas según el valor de una variable, y provoca el error de brazos
   distintos cambiando un brazo a `1`. Lee el diagnóstico.
3. Usa `for x in [1, 2, 3]` para sumar los elementos y luego intenta lo mismo
   con `for x in "abc"`. ¿Qué mensaje te da y por qué?
