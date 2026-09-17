# Astra — Auditoría de coherencia

Fecha: 2026-09-16. Alcance: el compilador semilla (`seed/`) contrastado con
`PHILOSOPHY.md`, `ARCHITECTURE.md`, `COMPILER_STRATEGY.md` y los 19 reportes de
`Documentacion/research/`.

Método: 14 programas de sondeo ejecutados contra `astra-seed` (con volcado de
AST y de bytecode para aislar la causa), más lectura dirigida de `research/010`
§3-§12, `research/011` §2, §5, §7, §8, §11-§15 y `research/04` §6-§9.

---

## 1. Veredicto

**La arquitectura es coherente; la semántica de las expresiones no.**

Las decisiones estructurales del seed coinciden con lo investigado casi punto
por punto (§7). Pero falta por completo una de las dos decisiones centrales del
lenguaje: **Astra es orientado a expresiones** (`research/010` §3.2, "Rust
model"; §4.2, "Rust-Style Implicit Tail Expression") y **el valor de un bloque
no funciona**. No falla con un error: devuelve silenciosamente un valor
equivocado.

Estado por severidad:

| Severidad | Nº | Resumen |
|:----------|:--:|:--------|
| 🔴 Bloqueante | 2 | Valor de bloque roto (respuestas incorrectas silenciosas); `LValue` restringido a identificadores |
| 🟠 Importante | 5 | Retorno implícito `nil`; `val`; tipos enteros de Tier 1; `T?`; semántica de agregados sin especificar |
| 🟡 Menor | 5 | `while`/`for` como expresión; concatenación de strings; división entera sin documentar; notas inexactas en el registro; contradicciones entre reportes |

Lo que **no** es un problema: el pipeline, el modelo de memoria del compilador,
el parser, el VM de pila y la aplicación de la estrategia de bootstrap. Todo
eso es coherente y está bien elegido.

---

## 2. 🔴 Hallazgo A — El valor de un bloque está roto (respuesta incorrecta silenciosa)

`research/010` §4.2 recomienda para Astra la expresión de cola estilo Rust:

> `Block ::= "{" Statement* Expression? "}"` — el último *expresión*, sin punto y
> coma, es el valor del bloque.

Sondeos ejecutados (`p1`, `pA`, `pB`, `p10`):

| Programa | Salida real | Esperada |
|:---------|:------------|:---------|
| `let a = { 1 + 2 }; print(a);` | `3` ✅ | 3 |
| `let b = { let t = 3; t * 4 }; print(b);` | `3` ❌ | 12 |
| `let b = { let t = 100; 7 }; print(b);` | `100` ❌ | 7 |
| `let b = { 7; }; print(b);` | `7` ❌ | error, o ausencia de valor |
| `let a = if true { let t = 5; t + 1 } else { 0 };` | `5` ❌ | 6 |
| `let a = if true { 10 } else { 20 };` | `10` ✅ | 10 |

El bytecode de `{ let t = 100; 7 }` muestra el mecanismo exacto:

```
[  0] CONST 100
[  1] SET_LOCAL   slot=1      <- let t = 100
[  2] CONST 7                 <- expresión de cola, correctamente parseada
[  3] POP                     <- ...y descartada
[  4] SET_LOCAL   slot=1      <- b = <lee una ranura de pila obsoleta>
```

La expresión de cola **sí se parsea** (`Block.last_expr` se rellena) pero el
emisor la descarta con un `POP`, como si el bloque estuviera en posición de
sentencia. El binding que lo consume lee entonces una ranura de pila que ya no
contiene nada: eso es lo que produce el `3` y el `100` de la tabla.

**Por qué importa más que un bug normal:** no hay diagnóstico. Un programa
Astra-0 que calcula mal se compila y se ejecuta "bien". Y el `{ 7; }` demuestra
que la regla del punto y coma (§4.2: el `;` descarta el valor) tampoco se
aplica.

Consecuencia directa: `let x = if c { ... } else { ... };` con algún `let`
dentro de las ramas —que es como está escrito cualquier compilador— devuelve
basura.

## 3. 🔴 Hallazgo B — `LValue` restringido a identificadores

`research/010` §12.1 especifica:

```
Assignment ::= LValue ("=" | "+=" | ...) Assignment | LogicOr
```

`LValue` no está definido en la producción, pero la misma §12.1 incluye el
acceso a campo (`.Identifier`) y el indexado (`[Expression]`) entre los
operadores postfijos. El parser, en cambio, exige un identificador:

```c
static Node *parse_assignment(Parser *p, Node *left, Precedence prec) {
    if (left->kind != NODE_IDENT) {
        parser_error(p, "invalid assignment target");
        return left;
    }
    ...
```

Sondeos:

| Programa | Resultado |
|:---------|:----------|
| `let mut xs = [1, 2, 3]; xs[0] = 9;` | `error: invalid assignment target` |
| `let mut p = P { x: 1 }; p.x = 5;` | `error: invalid assignment target` |

Efecto neto: **los arrays y los structs son de solo lectura**. Se pueden
construir y leer, pero no modificar. Un compilador que no puede actualizar un
elemento de un array no puede escribir un compilador auto-hospedado — que es el
criterio con el que `research/011` §5.1 define el alcance del seed ("el seed
debe soportar la intersección de características que usa el código del
compilador auto-hospedado").

Conviene precisar que la comprobación de mutabilidad **sí existe** y funciona:

```astra
let x = 1;
x = 2;      // error: cannot assign to immutable variable 'x'
```

Lo que eso agrava el hallazgo en vez de atenuarlo: el programador escribe
`let mut xs = [1, 2, 3];` —una promesa explícita de que va a mutar el array— el
chequeo la acepta, y después `xs[0] = 9;` es imposible. `mut` es obligatorio y
no sirve para nada en un agregado, así que la única forma de "actualizar" un
elemento hoy es reconstruir el array entero y reasignar el binding.

## 4. 🟠 Hallazgo C — El retorno implícito de función devuelve `nil`

`research/010` §7.3 y §4.2 hacen que el cuerpo de una función sea una expresión:

| Programa | Salida real | Esperada |
|:---------|:------------|:---------|
| `fn f() -> i32 { 42 } fn main() { print(f()); }` | `nil` ❌ | 42 |
| `fn f() -> i32 { let t = 100; 7 }` | `nil` ❌ | 7 |
| `fn f() -> i32 { return 7; }` | `7` ✅ | 7 |

Causa localizada en `emit_stmt`, caso `NODE_FN_DECL`: emite el cuerpo con
`emit_expr` (que deja el valor de cola en la pila) y a continuación comprueba si
la última instrucción es `RET`; como no lo es, **añade `CONST nil; RET`**, que
descarta el valor que acaba de dejar el bloque.

Tampoco se comprueba que una función con tipo de retorno declarado devuelva algo:

| Programa | Salida real | Esperada |
|:---------|:------------|:---------|
| `fn f() -> i32 { } fn main() { print(f()); }` | `nil` | error de compilación |

Un `i32` declarado que se materializa como `nil` en tiempo de ejecución es la
misma clase de fallo que el Hallazgo A: el tipo miente y nadie avisa.

## 5. 🟠 Hallazgo D — `val` no existe, y los tres documentos no coinciden

| Fuente | Introduce variables con |
|:-------|:------------------------|
| `ARCHITECTURE.md` §8.1 | `let x = 10` (inmutable), `mut y = 10`, `val z = "constante"` |
| `research/010` §12.1 | `("val" \| "mut" \| "let")` |
| `research/011` §5.2 (Tier 1) | **`val`, `mut`** |
| El seed | `let`, `let mut` |

`val x = 1;` hoy produce `error: undefined variable 'val'`. El lexer tiene
`TOKEN_VAR` para `var` (que no usa nadie) y ningún token para `val`.

Hay que decidir una forma canónica y corregir las otras dos fuentes. Nótese que
`ARCHITECTURE` §8.1 usa `mut y = 10` (el `mut` como introductor suelto), que
tampoco existe, y que el seed introdujo `let` (de Rust) que solo aparece en uno
de los tres documentos.

## 6. 🟠 Hallazgo E — Faltan tipos enteros de Tier 1

`research/011` §5.2, Tier 1, primera viñeta:

> Integer types (`i32`, `i64`, `u32`, `u64`)

El seed tiene **solo `i32`** (más `f64`). `let x: i64 = 5;` →
`error: unknown type 'i64'`.

Y hay una tercera nomenclatura en juego: `ARCHITECTURE` §8.2 escribe sus
ejemplos con `Int` y `String`, `research/011` Tier 1 usa `i32`/`String`. El seed
usa `i32`, `f64`, `bool`, `string`. Son tres convenciones para lo mismo.

Un compilador auto-hospedado necesita al menos un entero con signo y otro sin
signo, y distinguir anchuras, porque el emisor de C de `research/011` §9.2
depende de ello.

## 7. 🟠 Hallazgo F — `T?` está especificado, declarado en el registro, y no se parsea

`research/010` §12.1 define `OptionalType ::= PrimaryType "?"`, y
`research/011` Tier 2 lista `Optional type (T?)`. Sondeo:

```astra
let x: i32? = null;
```
```
error: unexpected token in expression      (en el `?`)
error: parse failed
```

`parse_type` no consume el `?`. **Y la nota de mi propio `type_annotation.c`
afirma que sí lo hace** ("`T?` optionals (parsed, TYPE_OPTIONAL exists)"). Es un
fallo de la auditoría del artefacto que construí en el hito anterior: el campo
`note` del registro es documentación escrita a mano y no está verificado por el
self-check. Corregido en este commit.

Relacionado, y más de fondo: **existe `null` pero no existe `Option`**.
`PHILOSOPHY.md` principio 2 es explícito:

> Sin `null` — Option types que fuerzan el manejo explícito de la ausencia.

y `ARCHITECTURE.md` §5.3 también:

> Sin `null`/`None` tradicional. Uso de opcionales explícitos.

`research/010` §12.1, en cambio, incluye `"null" | "none"` en `Literal`. El seed
implementó `null` y nada más. Eso es exactamente lo peor de los dos mundos: el
lenguaje tiene el agujero que la filosofía quería evitar, sin la construcción
que lo compensa.

## 8. 🟠 Hallazgo G — La semántica de los agregados no está especificada (y no se puede sondear)

La pregunta que decide casi todo lo demás: al hacer `let b = a;` con `a` un
array o un struct, ¿se copia o se comparte? La filosofía dice ARC/ORC
(conteo de referencias ⇒ compartir con contabilidad), y `research/04` §9.8
describe los incrementos sobre el *payload* de un enum en cada creación.

**Ninguno de los 19 reportes especifica el punto**, y hoy no se puede sondear
porque el Hallazgo B impide mutar un agregado:

```astra
let mut a = [1, 2, 3];
let mut b = a;
b[0] = 99;
print(a[0]);      // ¿99 (compartido, ARC) o 1 (copia, valor)?
```

Esto es una **decisión abierta que el seed está tomando por omisión**, y su
elección acabará siendo la especificación de facto para el compilador
auto-hospedado. Debe decidirse y escribirse en `ARCHITECTURE.md` §2 antes de que
el compilador en Zig la herede.

## 9. 🟡 Hallazgos menores

| # | Hallazgo | Evidencia |
|:-:|:---------|:----------|
| 1 | `while` y `for` como expresión: §12.1 los lista como `Primary`; no implementados (solo nud de `if` y `match`) | `let x = while … ;` → parse error |
| 2 | Concatenación de strings con `+` no existe | `"ab" + "c"` → *arithmetic operator requires numeric type, got string*. Tier 3 (`io`, `string`), pero bloquea el auto-hosting |
| 3 | División/módulo de enteros trunca hacia cero, sin documentarlo | `7/2=3`, `-7/2=-3`, `7%3=1`, `-7%3=-1` (semántica C/Rust, no Python) |
| 4 | El registro declara `position = STMT\|EXPR` para `while`/`for`, lo que es fiel a la gramática pero no a la implementación; el límite solo estaba en `note` | `while.c`, `for.c` |
| 5 | §7.2 del reporte dice "~60 tokens"; el enum tiene **75** | `TokenKind` en `astra.h` |

---

## 10. Contracciones entre los propios reportes (no del código)

Estas importan porque el compilador en Zig (Fase 2) se escribirá contra los
reportes, no contra el seed.

| # | Reportes en conflicto | Detalle |
|:-:|:----------------------|:--------|
| 1 | `010` §12.2 ↔ `010` §12.1 | La tabla pone la asignación en la precedencia **más alta**; la gramática la pone como el nivel **más flojo** (`Expression ::= Assignment`). Ya documentado en `CONSTRUCT_REGISTRY.md` |
| 2 | `010` §12.1 ↔ `011` §5.2 | Sintaxis de array: `010` escribe `"[" Type (";" Expression)? "]"` → `[T]` / `[T; N]` (Rust); `011` Tier 2 escribe **`[N]T` y `[T]`** (Zig). Son sintaxis distintas para el mismo tipo |
| 3 | `010` §12.1 ↔ `ARCHITECTURE` §8.1 ↔ `011` §5.2 | Keyword de variable: tres conjuntos distintos (`let/mut/val` vs `let/mut/val` vs `val/mut`) — ver Hallazgo D |
| 4 | `ARCHITECTURE` §5.3 + `PHILOSOPHY` ↔ `010` §12.1 | `null`: prohibido por filosofía y arquitectura, presente en la gramática y en el lexer |
| 5 | `ARCHITECTURE` §8.2 ↔ `011` §5.2 | Nombres de tipo: `Int`/`String` vs `i32`/`String` |
| 6 | `010` §12.1 | `TypeAlias ::= "type" Identifier ("=" \| "<" GenericParams ">") Type`: la rama de genéricos no lleva `=` ni, por tanto, tipo destino. La producción parece truncada |
| 7 | `010` §12.1 | `ImplBlock ::= "impl" GenericParams? Type …`: `GenericParams?` sin ángulos, a diferencia de `FunctionDef`/`StructDef`/`EnumDef`, que lo envuelven en `< >` |
| 8 | `010` §7.2 ↔ realidad | "~60 tokens" vs 75 |
| 9 | `ARCHITECTURE` §8.4 ↔ `PHILOSOPHY` §3 | `ARCHITECTURE` usa `spawn fn` para fibras; `PHILOSOPHY` promete "sin colores" y sin `async`. Compatible, pero `spawn` como keyword no aparece en la lista de keywords de `010` §12.1, que sí incluye `"spawn"` y `"async"` — es decir, `010` lista `async` como keyword en un lenguaje que promete no tenerlo |

---

## 11. Lo que sí es coherente

Conviene dejarlo escrito, porque no es poco:

| Decisión | Coincide con |
|:---------|:-------------|
| Seed en C, sin dependencias, `cc *.c -o astra-seed` | `research/011` §4.2 y Appendix C ("Implementation language: C — minimal deps, auditable, ubiquitous") |
| Descenso recursivo + Pratt, escrito a mano | `research/010` §10.2 y `research/011` §7.1 ("Recursive descent + Pratt, full control, no generator dep") |
| VM de pila, bytecode, un solo backend por ahora | `research/011` Appendix C ("Stack-based — simpler than register-based, correctness only") y §3.2 (el backend de C llega en la Fase 4) |
| Arena allocator, sin `free()` individual | `research/011` Appendix C ("Arena allocator — simple, no individual free, fast") y §15.2 (mitigación del riesgo de memoria) |
| Interning de strings | `research/011` §7.2 ("all identifiers and strings are interned") y Appendix C |
| Ubicaciones `archivo:línea:columna` en cada token y en cada error | `research/011` §10.3 |
| Suite de conformidad con anotaciones `// EXPECT:` dentro del propio `.astra` | `research/011` §11.3, que muestra literalmente `tests/conformance/expressions/arithmetic.astra` con `// EXPECT: 42`. La estructura del repo reproduce el ejemplo del reporte |
| Estructura de fases y los 5 milestones | `research/011` §6.1, §13, §14 |
| Fuera del seed: `comptime`, traits, genéricos, hilos verdes, ARC/ORC, unidades de medida, LSP, LLVM | `research/011` §2.3 (anti-patrones) y §5.3, §5.4, literalmente |
| Structs como tipos producto, enums unitarios, `match` exhaustivo con wildcard | `research/04` §9.2, §9.3, §9.7 |
| Variantes con datos, guards y patrones anidados **rechazados explícitamente** en vez de aceptados a medias | `research/011` §2.3 ("premature optimization") y §5.4. Los guards se rechazan con mensaje, no se ignoran |
| Enums/structs comparados estructuralmente y listados como huérfanos en el registro | Coherente con `research/04` §9.7 y con la política de `CONSTRUCT_REGISTRY.md` |

También es coherente el **registro de constructos** en sí: declara los 44
constructos y valida 14 invariantes sin añadir ni una característica al lenguaje.
Pero hay que decir lo incómodo: mientras `migrated` siga en `0 / 44`, el
registro es documentación ejecutable, no arquitectura. Vale por la puerta de
validación (invariantes 6 y 14 cruzan de verdad con `lexer.c` y `parser.c`) y
por las 7 desviaciones que ya dejó a la vista; su valor estructural llega con la
migración.

---

## 12. Causa raíz común: el invariante #1 no se verifica

`AGENTS.md` documenta:

> **Stack balance.** Every emitter path must leave the VM stack at a predictable
> height.

Los Hallazgos A y C son dos formas del mismo incumplimiento, y ninguno produce
un diagnóstico porque **no existe ninguna comprobación de altura de pila**. El
emisor no lleva la cuenta de `sp` en tiempo de compilación, así que un desbalance
no se detecta: se convierte en una lectura de una ranura obsoleta.

Añadir un modelo de altura de pila al emisor (incrementar/decrementar por
opcode, afirmar `sp == esperado` al cerrar cada sentencia y cada bloque, activo
en `make debug`) habría convertido los tres hallazgos en errores de compilación
en vez de respuestas incorrectas silenciosas. Es la inversión de mayor
rendimiento disponible ahora mismo, y es un cambio local a `emitter.c`:
**ninguna de las correcciones de §2 y §4 es fiable sin ella.**

---

## 13. Prioridad recomendada

1. **Modelo de altura de pila en el emisor** (§12). Sin esto, cualquier arreglo
   de lo de abajo es fe.
2. **Hallazgo A**: valor del bloque y expresión de cola, incluida la regla del
   `;` que descarta. Es una decisión central del lenguaje (`PHILOSOPHY` +
   `010` §3.2) y hoy está mal.
3. **Hallazgo C**: retorno implícito de función, y comprobación de que una
   función con tipo de retorno devuelve algo. Depende de (2).
4. **Hallazgo B**: `LValue` completo (identificador, acceso a campo, indexado) y
   comprobación real de mutabilidad de `let mut`. Sin esto el seed no puede
   apuntar al auto-hosting.
5. **Hallazgos D/E**: decidir la keyword de variable y los tipos enteros de
   Tier 1, y **corregir `ARCHITECTURE.md` §8.1 y `research/011` §5.2** para que
   coincidan con la decisión.
6. **Contradicción 2 de §10** (sintaxis de array `[T; N]` vs `[N]T`): decidirla
   antes de escribir el compilador en Zig.
7. **Hallazgo F**: o se implementa `Option`/`Result` con `?`, o se retira `null`
   del lexer. Tener los dos a medias es peor que cualquiera de las dos opciones.
8. **Hallazgo G**: especificar la semántica de asignación de agregados en
   `ARCHITECTURE.md` §2 antes de que se herede.

## 14. Lo que **no** hay que hacer

`research/011` §2.3 lista cuatro anti-patrones. Al revisar lo construido, el
riesgo real no está en el registro de constructos (que es declarativo y valida,
sin añadir conceptos) sino en arreglar los hallazgos por acumulación:

- **No** implementar `Option`/`Result`/genes/closures "ya que estamos" mientras
  se arregla el valor de bloque. §5.2 los sitúa en Tier 2 y el seed no los
  necesita para compilar el compilador auto-hospedado.
- **No** optimizar el emisor (§2.3: "el seed no necesita generar código rápido,
  solo correcto").
- **No** ampliar el registro con constructos que el lenguaje no tiene. Los 8
  constructos con `in_astra0 = false` existen para documentar exclusiones, no
  para justificar trabajo futuro.
- El criterio de corte sigue siendo el de §5.1: **el seed implementa la
  intersección de características que usa el compilador auto-hospedado**. Los
  Hallazgos A, B y C están dentro de esa intersección. `Option`, closures y
  traits no necesariamente.
