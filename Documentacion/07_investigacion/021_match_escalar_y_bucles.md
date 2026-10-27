# 021 — Decisión: match escalar (§3.8) y bucles como expresión (§7.15)

> **Estado: ADOPTADA el 2026-10-15.** §3.8 implementado en `3c2b81a`
> (chequeo estático + backstop `OPCODE_MATCH_NONE`), §7.15 en `d66370a`
> (bucles = sentencias en ambos compiladores); documentación
> contradictoria corregida en ARCH §11.3/§29.6 y research/001 §3.2.

Fecha: 2026-10-15. Origen: diferidos de `Documentacion/06_auditorias/PRE_LLVM_AUDIT.md` §9. Este
documento investiga qué es **mejor para el lenguaje**, apoyado en la
filosofía de Astra y en lo que hace la industria, y cierra cada uno
con una recomendación concreta.

---

## 1. Contexto de los dos problemas

### §3.8 — `match` sobre escalares sin exhaustividad

```astra
fn f(x: i32) -> i32 { return match x { 1 => 10 } }
fn main() { print(f(2)) }   // imprime `nil` bajo una promesa i32;
                            // con `f(2) + 1` revienta en runtime
```

Los tres backends (VM seed, `--emit-c`, zig) están de acuerdo: caen a
`nil`. Repro: `/tmp/opencode/sem/match_int_fall.astra`. El chequeo de
exhaustividad existe y funciona para **enums** (variantes) y
**optionals** (payload + `none`, cerrado en §3.4), pero
`covered_n = 0` para targets escalares y la rama final no corre.

### §7.15 — `while`/`for` como expresión

- El seed los **rechaza en el parser** (`let x = while …` →
  `unexpected token in expression`).
- Zig **los acepta** (siguiendo la spec) y luego:
  - `let x = while false { … }` → error limpio de void-in-let;
  - `print(while false { … })` → **error interno del emitter**
    (`internal: stack imbalance in expression call_expr`) — nunca
    aceptable;
  - `let x = for i in [1] { … }` → void-in-let.
- La spec (`research/001` §3.2 y su gramática, "Control Flow
  **Expressions**") lista `while`/`for` como expresiones: hay un
  conflicto real spec ↔ seed ↔ zig, no solo un bug de zig.

---

## 2. Qué dice la filosofía de Astra

De `Documentacion/01_lenguaje/PHILOSOPHY.md` y de las propuestas de investigación del repo:

1. **Axioma central**: "Todo está permitido siempre y cuando mejore el
   lenguaje Astra" — ni dogma pro-Rust ni dogma anti-Rust; la
   decisión se mide contra el beneficio.
2. **Predecibilidad**: "Si aprendes 10 reglas, debes poder predecir
   el comportamiento de las 100 combinaciones posibles."
3. **Seguridad sin tortura**: "**Sin `null`** — Option types que
   fuerzan el manejo explícito de la ausencia" y "sin excepciones que
   explotan — Result/Option que fuerzan el manejo explícito de
   errores". Un `nil` silencioso bajo una promesa `i32` es exactamente
   el anti-patrón que Astra existe para eliminar.
4. **Errores como documentación**: "Un buen error message enseña al
   programador a ser mejor" (enfoque Rust/Elm).
5. **Expression-oriented con límites honestos** (`research/001` §3.2):
   `if`, `match`, bloques y closures son expresiones *porque producen
   valores*; `let`/`return`/`break`/`continue` son sentencias.
6. **Exhaustividad estricta ya es la decisión de diseño del repo**:
   `research/004` (§13): "adoptar un modelo inspirado en Rust…
   con exhaustiveness checking **estricto por defecto**"; su comparativa
   elige `compile error` (E0004, "el más estricto") frente a warning
   (OCaml) o `#[non_exhaustive]` de escape. `Documentacion/01_lenguaje/ARCHITECTURE.md` §11.3:
   "Compile error por defecto (como Rust)".

---

## 3. Qué hace la industria

### 3.1 Exhaustividad de `match`/`switch`/`when`

| Lenguaje | Regla | Escalares (int/string) |
|:---------|:------|:-----------------------|
| **Rust** | `match` siempre exhaustivo (E0004), **también en posición de sentencia**; el espacio de `enum`/`bool` es comprobable | Necesitan `_` o un rango que cubra todo (p. ej. `i64::MIN..=i64::MAX`); `bool` se comprueba con `true`/`false` |
| **Swift** | `switch` siempre exhaustivo (sentencia o expresión); sin `default` no compila | **Exige `default`** para enteros (documentación oficial: "for integer, you need to include a default case") |
| **Kotlin** | `when` **como expresión** debe cubrir todo: `bool`/`enum`/`sealed` sin `else`; cualquier otro tipo exige `else`. **Como sentencia** no exige nada ("no error occurs") | Expresión ⇒ `else` obligatorio |
| **C** | `default` opcional; si nada coincide, simplemente no se ejecuta nada (y `switch` no produce valor) | Sin garantía, pero sin "valor del switch" que mentir |
| **Dart** | `switch` exige `default` salvo para enums/bool | Exige `default` |

Patrón común: **donde el `match` produce un valor, o el espacio es
finito y comprobable, o hay un catch-all obligatorio**. Nadie devuelve
"nulo silencioso" cuando nada casa.

### 3.2 Bucles como expresión

| Lenguaje | `if`/`match` como expresión | Bucles como expresión |
|:---------|:---------------------------|:----------------------|
| **Rust** | sí | `while`/`for` evalúan a `()` **solamente**; la referencia es explícita: *"Only loop and labeled block expressions support evaluation to non-trivial values"* — el valor de bucle, si se quiere, sale por `loop { break EXPR }` o bloque etiquetado |
| **Kotlin** | `if`, `when`, `try` | **No** — bucles son sentencias (documentación de control-flow: los bucles no aparecen como expresiones) |
| **Swift** | `if`/`switch` desde 5.9 | **No** — los bucles siguen siendo sentencias |
| **Zig** | bloques etiquetados con `break valor` | `while`/`for` son sentencias |
| **Go, Java, JS/TS, C#, Python, C** | (JS/TS: solo `if`, ternario) | **No** — sentencias |

Patrón común: la ola moderna de "expression-oriented" (Kotlin, Swift
5.9) añadió **expresiones de rama**, no de bucle. El único lenguaje con
bucles "como expresión" útil (Rust) les da un valor trivial `()` y
reserva el valor real para `loop`+`break`/bloques etiquetados.

---

## 4. Análisis para Astra

### 4.1 §3.8 — match escalar

- **El comportamiento actual viola tres decisiones ya tomadas**: el
  axioma de "sin null / manejo explícito de la ausencia" (§2.3), la
  regla de exhaustividad estricta de `research/004`/ARCH §11.3 (§2.6),
  y la predecibilidad: hoy un `match` puede o no producir `nil` según
  un dato que el lector no ve (el valor en runtime), cuando el resto
  de Astra decide estas cosas en compile-time.
- **Alternativa Kotlin** (sentencia libre, expresión obligada) —
  rechazada: exige que el typechecker distinga posición de sentencia
  para `match` (regla duala) y Astra descarta el valor de un `match`
  en sentencia igualmente; dos reglas para lo mismo rompe el principio
  "10 reglas → 100 combinaciones". Rust y Swift aplican una sola regla.
- **Alternativa "panic en runtime"** — rechazada como *solución
  principal*: deja el error para cuando el programa ya corre (peor
  para scripts, peor para el backend dual), cuando el 100 % de los
  casos es detectable en compile-time con la mecánica que ya existe
  (`covered[]`). Sí tiene valor como **backstop** (ver abajo).
- **`nil` actual** — no es candidato serio: es un valor que miente
  bajo el tipo prometido, invisible hasta que otro operador revienta.

### 4.2 §7.15 — bucles como expresión

- El conflicto spec↔impl es real, pero **la spec prometió algo sin
  valor**: en Astra-0 un bucle solo puede producir `void` porque
  `break` con valor está explícitamente rechazado
  (`ui/break_value.astra`: *"break with a value is not supported in
  Astra-0"*, y `constructs/break.c` documenta el hueco). Como toda
  expresión existente de Astra produce un valor (`if`, `match`,
  bloques-finales, closures), una "expresión" que nunca tiene valor
  no compone con nada: `let x = while…` es error de tipado, argumento
  de call también; su único efecto observable es habilitar código
  raro y, hoy, el crash interno de zig.
- La dirección de la industria (§3.2) y la propia evolución de Rust
  (que tuvo que inventar `loop`+`break EXPR` y bloques etiquetados
  para dar valor a los bucles) confirman: **expresiones de rama sí,
  expresiones de bucle no**.
- Arreglar por el lado de la spec es además lo barato: seed ya es
  correcto, hay que hacer que zig rechace en el parser (paridad) y
  enmendar `research/001` §3.2/gramática. Arreglar por el lado de
  aceptar exige además arreglar el emitter interno de zig y aceptar
  código sin valor — para ningún beneficio.

---

## 5. Recomendaciones

### §3.8 → **Error de compilación: todo `match` debe ser total**

**Regla única (para ARCH §11.3 y para ambos typecheckers):**

> Un `match` debe cubrir su target completo, o llevar `_` (o un
> binding irrefutable) en posición de armada. El espacio es comprobado
> cuando es **finito y enumerable** — variantes de enum, `payload +
> none` de optional, y `true/false` de bool — y exige catch-all cuando
> es **infinito** (int, float, string), porque sin patrones de rango
> (fuera de Astra-0, §3.14) no puede enumerarse.

Mensajes, con el estilo de los ya existentes
(`non-exhaustive match: missing variant 'E.B'`, `missing 'none' arm`):

| Caso | Mensaje |
|:-----|:--------|
| escalar (i32/f64/string) sin `_` | `non-exhaustive match: missing '_' arm` |
| bool sin uno de los dos brazos | `non-exhaustive match: missing 'true' arm` / `… 'false' arm` |

**Backstop:** el emitter actual —"no arm matched: yield nil so a match
always produces a value"— pasa a emitir un **error runtime posicionado**
(`no match arm matched`) en lugar de `nil`, en ambos emitters. Con la
regla estática es inalcanzable, pero convierte cualquier hueco futuro
en ruido inmediato en vez de un `nil` silencioso. (El C backend hereda
el bytecode, no necesita cambio propio.)

*Alternativa mínima si se quiere cerrar aún más rápido:* sin chequeo
de bool (bool exige `_` como cualquier escalar) — 10 líneas menos por
compilador, peor mensaje. Se recomienda incluir bool: es el mismo
mecanismo de 2 slots que ya usa §3.4 para optionals.

**Por qué esto es lo mejor para Astra:** es la única opción alineada
con las tres decisiones que Astra ya tomó (sin null, exhaustividad
estricta como Rust, predecibilidad), es la regla que comparten los
lenguajes modernos en posición de expresión, y su costo de uso es
mínimo: un `_` que el programador ya escribe en el 90 % de los casos.

### §7.15 → **Los bucles son sentencias en Astra-0**

1. **Zig**: `parseExpression` deja de aceptar `while`/`for` como
   prefijo → mismo primer error que el seed
   (`unexpected token in expression`), paridad byte-idéntica; añadir
   pins `ui/` en ambos lados. (Esto además elimina el crash interno
   del emitter: el nodo ya no llega.)
2. **Spec**: enmendar `research/001` §3.2 — `while`/`for` pasan de
   "expresiones" a sentencias, con la razón escrita: *no producen
   valor mientras `break` con valor no exista*. La sección de
   "Control Flow Expressions" de la gramática queda solo con `if` y
   `match`.
3. **Futuro (fuera de Astra-0, decisión separada):** si algún día se
   quiere valor de bucle, el camino que elige la industria es el de
   Rust: `loop { … break EXPR }` + bloques etiquetados, reutilizando
   la reserva de gramática `break Expression?` que ya existe — **no**
   convertir `while`/`for` en expresiones.

**Por qué no la alternativa B** (que el seed acepte bucles como
expresión-void para coincidir con la spec): coste de implementación
igual o mayor (emitter de zig incluido), y beneficio cero — una
expresión que siempre es `void` no es usable en ninguna posición que
acepte expresiones de Astra. La filosofía premia simplicidad con
justificación, no simetría por simetría.

---

## 6. Consecuencias operativas (si se adoptan)

| Paso | Alcance | Esfuerzo |
|:-----|:--------|:---------|
| §3.8 estático | `typecheck_match` seed + zig: `covered_n` para `TYPE_BOOL` (2 slots, marcas en literales bool) y `TYPE_INT/FLOAT/STRING` (1 slot "hay catch-all", marcado solo por `_`/bind de armada sin guardia); rama final con los dos mensajes nuevos | medio — análogo a S12/§3.4 |
| §3.8 backstop | emitters seed y zig: el fallback `yield nil` → `runtime error "no match arm matched"` | pequeño |
| §3.8 tests | `ui/scalar_match_missing_wildcard`, `ui/bool_match_missing_arm`, y ajustar `expressions/match_scalar.astra` (ya usa `_`, pasa sin cambios) | pequeño |
| §7.15 zig | rechazar `while`/`for` en `parsePrefix` + 2 pins `ui/` | pequeño |
| §7.15 spec | enmienda `research/001` §3.2/gramática | minúsculo |
| §9 del audit | mover 3.8 y 7.15 de "diferido" a "resuelto" | minúnculo |

Fallout esperado a comprobar con la suite: cualquier test existente
con `match` escalar sin `_` (hoy: solo `ui/match_pattern_type`, que
ya es rechazo) y con `while`/`for` en posición de expresión (hoy:
ninguno en los tests, ambos rechazan o rechazan ya en zig tras el
cambio).
