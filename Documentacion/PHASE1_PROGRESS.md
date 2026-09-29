# Astra — Phase 1 Implementation Status

Estado del **compilador semilla** (`seed/`), la primera fase del plan de
bootstrap descrito en `COMPILER_STRATEGY.md`: un compilador en C que compila el
subconjunto **Astra-0**, suficiente para arrancar la Fase 2 (compilador en Zig).

---

## 1. Pipeline implementado

```
.astra ─▶ Lexer ─▶ Parser ─▶ Type Checker ─▶ Emitter ─▶ Bytecode ─▶ VM
          lexer.c  parser.c  typechecker.c    emitter.c               vm.c
                                                                          │
                                              ─── --emit-c ───────────────┘
                                                                          │
                                                          Bytecode ─▶ C Codegen ─▶ .c
                                                                   codegen.c
```

Todos los componentes están conectados y el binario `seed/astra-seed` ejecuta
programas Astra-0 de principio a fin. El pipeline `--emit-c` genera código C
ejecutable desde el bytecode, compilable con `gcc`/`clang`.

| Componente | Estado | Notas |
|:-----------|:-------|:------|
| Registro de constructos | ✅ | `src/constructs/`, un archivo por producción EBNF; `--check-constructs` valida 14 invariantes contra léxico y parser |
| Arena allocator | ✅ | `arena.c`, liberación en bloque |
| Interning de strings | ✅ | `string_table.c`, igualdad por puntero |
| Lexer | ✅ | `..`/`..=`, literales numéricos (hex/bin/oct), strings con escapes, comentarios |
| Parser | ✅ | descenso recursivo + Pratt; literales de array, rangos, bloques como expresión, `match` y patrones |
| Type checker | ✅ | tabla de símbolos con ámbitos; exhaustividad de `match`; errores con ubicación |
| Emitter | ✅ | bytecode de pila, parcheo de saltos, locales ocultos de bucle, `SWAP` para el temporal de `match` |
| VM | ✅ | ~30 opcodes, frames de llamada, globals, builtins |
| C Codegen | 🟡 | `--emit-c` genera .c compilable; aritmética, control, funciones, structs, enums, arrays. Ver §3c |
| Runner de tests | ✅ | `tests/run_tests.sh` (`EXPECT` / `EXPECT-ERROR`) |

## 2. Lenguaje soportado (Astra-0)

### Tipos
`i32`, `f64`, `bool`, `string`, arrays (`[T]`), structs (declaración, literal,
acceso a campo), enums unitarios (`Enum.Variant`), enums con datos (ADTs),
`void`, `nil`.

### Expresiones
- Aritmética y comparación: `+ - * / % == != < > <= >=`
- Lógicos con **cortocircuito**: `&&` / `||`
- Bit a bit: `& | ^ << >>`
- Unarios: `-`, `!`, `~`
- Literales: enteros, flotantes, strings, `true`/`false`, `null`
- Literales de array: `[1, 2, 3]`; indexado `xs[i]`
- Literales de struct: `Point { x: 1, y: 2 }` (el orden de campos es libre)
- Acceso a campo: `p.x`
- Rangos: `a..b` (exclusivo), `a..=b` (inclusivo)
- `Enum.Variant` como expresión
- `match` como expresión (con `or`-patterns `A | B | C`, wildcard `_`, guards)
- **Option/Result constructors**: `some(x)`, `none`, `ok(x)`, `err(x)`
- **`?` operator**: early return en funciones que retornan Result/Option
- Llamadas a función, paréntesis, bloques como expresión

### Sentencias y control de flujo
- `let` / `let mut` con anotación de tipo opcional
- `if` / `else` (también como expresión)
- `while` con `break` / `continue` reales
- `for x in start..end`, `for x in start..=end`, `for x in array`
- `match` como sentencia (el resultado se descarta)
- `return` con y sin valor
- `enum Nombre { A B C }` (variantes unitarias, sin datos aún)
- Declaraciones de módulo: `use a.b`, `import a.b as c`, `from a.b import X, y as z`
  (se parsean y se descartan; ver §6.7)
- Funciones de nivel superior con parámetros tipados y recursión

### Runtime
- Valores: `nil`, `bool`, `int`, `float`, `string`, `array`, `struct`, `enum`, `fn`
- **Option/Result tagged values**: `ok(x)`, `err(x)`, `some(x)` con igualdad estructural
- Igualdad estructural para arrays, structs, y Option/Result
- Builtin `print(...)` (variádico)
- Errores de runtime con número de línea
- **`?` operator**: early return en funciones con Result/Option

## 3. Estado de la suite de tests

`make test` ejecuta `seed/tests/run_tests.sh`, que descubre los archivos de
`seed/tests/conformance/` y valida su salida contra las anotaciones:

```astra
// EXPECT: <línea de salida>          (repetible)
// EXPECT-ERROR: <texto>              error de compilación que contiene <texto>
// EXPECT-RUNTIME-ERROR: <texto>      compila y luego falla al ejecutarse
```

La suite arranca con la puerta del registro (`--check-constructs`) y sigue con
los casos de conformidad. Cobertura actual (**93 casos**), en verde en las tres
variantes de build (`dev`, `debug` con ASan+UBSan+LSan, `release`).

`EXPECT-RUNTIME-ERROR` se añadió el 2026-09-21: hasta entonces **ningún** test
podía expresar "el programa compila y falla al ejecutarse", que es justo la clase
de caso que destapó la auditoría de esa fecha (índice fuera de rango, desborde de
pila, `?` sobre un valor sin etiquetar). En la VM se comprueba el texto del
error; en la ruta de C solo se exige salida 1 con una línea `runtime error`, a
propósito, porque los dos backends nombran sus límites de forma distinta (ver
§6, S8/S9) — una caída por señal también devuelve un código distinto de cero y
por eso el test exige la salida limpia.

Desde el 2026-09-21 la suite tiene **dos rutas**, no una: además de la VM,
`run_tests.sh` compila con `--emit-c` + `gcc` los casos de `tests/codegen/` y
compara su salida (ver §3c). El backend de C deja así de ser un camino sin
verificación automática. Los casos no-UI de conformidad se comprueban además a
mano por esa ruta en cada auditoría: reproducen la salida de la VM y **no fugan
memoria** bajo LSan.

| Área | Casos |
|:-----|:------|
| registro | invariantes de constructos, palabras clave y tabla de operadores |
| expressions | `arithmetic` (precedencia, unarios, `%`), `string_concat` (`+` con strings), `integer_types`, `none_literal` (`none` como ausencia), `aggregate_equality` (igualdad estructural de arrays/structs/enums con datos), `float_remainder` (`fmod`), `deep_recursion` (200 frames: el límite que truncaba el `base` del frame), `recursion_depth_limit` (el tope de profundidad se reporta limpio), `float_divide_by_zero`, `string_order_rejected` |
| control | `if_else`, `while_break`, `while_continue` |
| loops | `range_exclusive`, `range_inclusive`, `break_continue`, `for_array` |
| arrays | `literal_index`, `element_assign`, `alias_write` (compartición de handles), `out_of_bounds` (índice fuera de rango: error limpio, no memoria corrupta), `returned_literal` (un literal de array sobrevive al retorno de su función) |
| structs | `literal_fields`, `field_order`, `struct_in_function`, `field_assign` (cadenas anidadas) |
| blocks | `tail_expression`, `if_value` |
| types | `optional_syntax` (`T?` parseado correctamente), `integer_widths` (`i64`/`u32`/`u64` con valores reales, Hallazgo E) |
| enums | `match_variants`, `or_patterns`, `enum_print`, `match_statement`, `match_block_arm`, `pattern_bind`, `nested_pattern_bind`, `mixed_patterns`, `match_guard`, `guard_with_binding`, `option_basic`, `option_equality`, `result_basic`, `result_match`, `nested_option_result`, `try_operator` |
| module | `toplevel_stmts` (sentencias de nivel de módulo: la clase de código que ningún otro test cubría, y por eso el break de §6 pasó inadvertido), `toplevel_aggregates` (structs, enums y variantes con datos declarados en el nivel superior), `use_paths` (`use` con rutas punteadas: el constructo `use` no tenía **ningún** test, y por eso no se notó que era código muerto (S18) ni que el parser separaba con `::` (S19)), `import_from` (`import ... as`, `from ... import ... as`, las tres formas de §6.7) |
| functions | `recursion` (factorial + parámetros), `implicit_return` |
| lambda | `lambda_basic`, `lambda_multi` |
| ui | `from_without_items` (`from a.b import` sin ningún item), `type_mismatch`, `break_outside_loop`, `struct_missing_field`, `struct_unknown_field`, `struct_field_type`, `match_non_exhaustive`, `enum_unknown_variant`, `match_pattern_type`, `void_initializer`, `missing_return_value`, `immutable_element_assign`, `enum_variant_assign`, `pattern_bind_wrong_type`, `option_type_error`, `option_type_mismatch`, `lambda_type_mismatch`, `null_rejected`, `struct_comma_body`, `enum_comma_body`, `nesting_too_deep`, `block_nesting_too_deep`, `integer_literal_out_of_range`, `unterminated_string`, `use_colon_colon` |
| codegen | `string_escape`, `global_limit`, `bitwise`, `deep_recursion`, `frame_overflow`, `out_of_bounds`, `returned_literal`, `aggregate_equality`, `float_remainder`, `string_order_rejected`, `float_divide_by_zero`, `integer_widths`, `toplevel_aggregates` |

Los tests se ejecutan también bajo `make debug` (ASan + UBSan + LSan) sin
fallos ni fugas.

> **Cómo se construye cada variante** (arreglado el 2026-09-21): `make debug` y
> `make release` compilan en `build/debug/` y `build/release/`, y su receta borra
> el binario antes de enlazar. Antes compartían `build/` con el build normal y
> las flags no forman parte del timestamp del objeto, así que `make && make debug`
> respondía `Nothing to be done for 'debug'` dejando el binario **sin
> instrumentar** —la afirmación "verde bajo ASan" no era reproducible desde los
> comandos documentados— y mezclar objetos de dos variantes fallaba al enlazar
> (`creating DT_TEXTREL in a PIE`). Ver §6.

## 3bis. Fallos de corrección conocidos (NO usar el seed como especificación)

La auditoría de coherencia (`COHERENCE_AUDIT.md`) encontró fallos que producen
**respuestas incorrectas silenciosas**. Están documentados aquí para que nadie
los herede al escribir el compilador en Zig:

| # | Qué | Antes | Ahora |
|:-:|:----|:------|:------|
| A | Valor de bloque en posición de valor | `{ let t = 100; 7 }` → `100` | ✅ `7` |
| A | Regla del `;` (§4.2 de `research/010`) | `{ 7; }` → `7` | ✅ error de tipos |
| A | `if` como expresión con sentencias en la rama | `if c { let t = 5; t + 1 }` → `5` | ✅ `6` |
| B | Retorno implícito de función | `fn f() -> i32 { 42 }` → `nil` | ✅ `42` |
| B | Tipo de retorno declarado sin valor | `fn f() -> i32 { }` → `nil` | ✅ error de compilación |
| C | `LValue` acotado a identificadores | `xs[0] = 9;` → error de parseo | ✅ asigna el elemento |
| C | Mismo caso en campos | `p.x = 5;` → error de parseo | ✅ asigna el campo |
| D | Keyword `null` violaba PHILOSOPHY.md | `null` existía como keyword | ✅ eliminado, `none` es canónico |
| F | Operador `?` documentado como implementado | No era usable: `some(x)` devolvía el tipo del payload, así que `?` no tenía capa que quitar | ✅ constructores y `?` con tipo de optional; verificado en ambos backends (§6) |
| G | Semántica de agregados sin especificar | Compartir handle (ARC) *de facto* | ✅ escrito en `ARCHITECTURE.md` §2 (decisión del 2026-09-21) y fijado por `arrays/alias_write.astra` |
| E | Tipos enteros `i64`/`u32`/`u64` faltantes | Solo `i32` y `f64` | ✅ usables desde el 2026-09-21: **literales enteros polimórficos** (`ARCHITECTURE.md` §5.1). Antes el typechecker *nombraba* los tipos pero ningún valor podía tenerlos, porque todo literal era `i32`; ahora el literal adopta el tipo que el contexto exige. Ancho no verificado en runtime, ver §6.3 |
| F | Sintaxis `T?` no parseable | `let x: i32? = none` → error de parseo | ✅ parser consume `?` como postfix |
| — | Literal entero fuera de rango | `9223372036854775808` se envolvía en silencio a un número distinto (y era UB por *shift* con signo) | ✅ el lexer rechaza el literal y el mensaje llega al usuario (§6, S15) |

### Causa raíz de A y C (arreglada)

El invariante de *stack balance* que `AGENTS.md` documentaba **no se verificaba
en ninguna parte**. El emisor ahora lleva un modelo de altura de pila: cada
instrucción lo actualiza según su efecto real (contrastado con `vm.c`), y
`emit_expr` / `emit_stmt` comprueban el efecto que su nodo debe tener. Los
constructos con ramas (`if`, `match`, `&&`, `||`) resincronizan el modelo donde
sus caminos se reencuentran. Un desbalance es ahora un **error de compilación,
no una respuesta incorrecta silenciosa**; verificado por inyección de fallo.

Ese modelo destapó de paso tres bugs que nadie había visto: `pop_scope` emitía
un `POP n` que borraba el valor del bloque en lugar de sus ranuras locales;
`const` dentro de una función no se almacenaba nunca, dejando su valor en la
pila; y el `match` terminaba con un `SWAP; POP` que consumía una ranura local
viva.

Hallazgo B en cambio tenía la causa localizada que decía la auditoría:
`parse_assignment` rechazaba todo lo que no fuera `NODE_IDENT`. Cerrado en dos
mitades:

- **Frontend**: `parse_assignment` acepta la forma `LValue ::= Identifier |
  LValue "." Identifier | LValue "[" Expression "]"` (el reporte usa `LValue`
  sin definirlo; esa es la lectura que el AST puede representar) y
  `AssignExpr` guarda el `target` completo, no solo el nombre.
- **Codegen**: la VM gana `SET_INDEX` (pop valor/índice/array, escribe, devuelve
  el valor) y `SET_FIELD` (pop valor/struct, escribe, devuelve el valor). El
  emisor recorre la cadena hasta el penúltimo enlace con `emit_expr` —una sola
  ruta de lectura, reutilizada— y almacena con el último enlace desmontado;
  ambos stores consumen el handle del agregado y devuelven el valor, así que el
  efecto neto del nodo sigue siendo "un valor" y no hay resincronización del
  modelo de pila.

El checker exige que el binding raíz de la cadena sea `let mut` y rechaza
asignar a una variante de enum (`Color.Rojo = x`), que el parser ve como acceso
de campo sobre un nombre de tipo.

**Semántica de agregados (de facto, Hallazgo G)**: `let b = a` copia el
*handle*, no los elementos. `arrays/alias_write.astra` fija el comportamiento:
escribir a través de un binding es visible por el otro. Es la semántica que la
filosofía espera de ARC/ORC (compartir con contabilidad); queda escrito aquí
para que el compilador en Zig no la herede por accidente.

Bug aparte descubierto al sondear (preexistente, de recuperación de errores):
el parser de `struct` declarations espera campos separados por saltos de línea y,
ante una coma, reportaba errores en bucle en vez de abortar el cuerpo. **Cerrado**:
un `struct` con comas es un error (los campos van por líneas, `ARCHITECTURE.md`
§10.1), y ahora se reporta y se aborta el cuerpo en tiempo acotado —
`ui/struct_comma_body.astra` fija las dos mitades, el diagnóstico *y* la
terminación.

## 3c. Estado del C Codegen (`--emit-c`)

Pipeline: `.astra → Lexer → Parser → Typecheck → Emitter → Bytecode → C Codegen → .c → gcc`

Enfoque: **Bytecode→C** (estilo Haxe/HashLink), reutiliza el backend de bytecode
existente. El C codegen lee las instrucciones del bytecode y genera código C
equivalente que se compila con el compilador del sistema.

### Archivos

| Archivo | Responsabilidad |
|:--------|:----------------|
| `seed/src/codegen_runtime.h` | Runtime C incluido por los .c generados: tipos (AstraValue, AstraStruct, AstraEnumObj), constructores, operaciones aritméticas/comparación/lógica, print, manejo de errores con setjmp/longjmp |
| `seed/src/codegen.h` | API pública: `codegen_create()`, `codegen_emit_to_file()`, `codegen_destroy()` |
| `seed/src/codegen.c` | Driver de codegen: detección de globals, declaración de tipos, forward declarations de funciones, emisión de cuerpos de función, código de módulo, emisión de main() |

### Lo que funciona (verificado contra VM)

| Feature | Estado | Notas |
|:--------|:-------|:------|
| Aritmética (`+`, `-`, `*`, `/`, `%`, unario `-`) | ✅ | Salida idéntica a VM |
| Comparaciones (`==`, `!=`, `<`, `>`, `<=`, `>=`) | ✅ | |
| Lógicos (`&&`, `\|\|`, `!`) | ✅ | Cortocircuito generado |
| Literales (int, float, string, bool, nil) | ✅ | |
| `let` variables (locales y globales) | ✅ | |
| `if` / `else` | ✅ | Como statement y expresión |
| `for..in` (rangos exclusivos) | ✅ | Requiere cómputo correcto de max_slot para separar stack de locals |
| Builtins (`print`) | ✅ | Detectado por `param_count==255 && code==NULL` |
| Llamadas a función | ✅ | Frame offset correcto para builtins vs usuario |
| Recursión | ✅ | `OPCODE_RET` manejado en codegen de función |
| Arrays (literal + indexado) | ✅ | `astra_array_new` **copia** los elementos; el indexado pasa por `astra_array_get`/`astra_array_set`, que acotan (ver §6, S10/S11) |
| Structs (literal + acceso a campo) | ✅ | `AstraStructDef`/`AstraStruct` estáticos, lookup por nombre en runtime |
| Enums unitarios | ✅ | `Color.Red` como `{enum_name, variant_name}` |

### Invariantes de memoria del C generado (2026-09-21)

Tres reglas que el código generado no puede romper, y que costaron un SEGV, un
desbordamiento de pila y una corrupción de heap respectivamente (§6, S9–S11):

1. **Todo push pasa por `ASTRA_PUSH(frame, sp, valor)`.** `frame` es una ventana
   al array global `astra_frame[ASTRA_FRAME_SIZE]` y el guard comprueba la ranura
   *absoluta*, no `sp`: dentro de una función `frame` apunta al medio del array
   (el llamante pasó `astra_frame + _fn_slot`), así que mirar solo `sp` dejaría
   crecer `frame_base + sp` fuera del array. Es el espejo del `vm_push()` del VM.
2. **El indexado de arrays usa `astra_array_get`/`astra_array_set`**, nunca
   `elems[i]` directo: con acceso directo un índice malo era un valor erróneo
   silencioso al leer y una escritura fuera del buffer al asignar.
3. **`astra_array_new` copia** los elementos que le pasa el código generado,
   porque el buffer de origen es un array local de la función C que construye el
   literal; adoptarlo dejaba al array apuntando a una pila muerta.

Estas tres viven en `codegen_runtime.h` y están cubiertas por
`tests/codegen/{frame_overflow,out_of_bounds,returned_literal}.astra`.

### Bugs corregidos durante el desarrollo

1. **Stack-local overlap**: `sp` iniciaba en 0, sobreponiéndose con slots de variables locales. Fix: calcular `max_slot` del bytecode.
2. **Jump offset off-by-one**: El target del salto en C debe ser `ip + offset` (no `ip + 1 + offset`). Corregido en 6 ubicaciones.
3. **`OPCODE_RET` faltante**: El switch de codegen de función no manejaba RET, causando crash en recursión.
4. **Struct codegen**: Reescrito para usar `AstraStructDef`/`AstraStruct` matching VM, con lookup por nombre en runtime.
5. **GET_FIELD/SET_FIELD**: Ahora hacen lookup por nombre (strcmp) en lugar de índice hardcodeado.
6. **Struct def constants**: `VAL_STRUCT_DEF` no era emitido; agregado `register_struct_def()` + `emit_struct_def_globals()`.
7. **Enum variant constants**: `VAL_ENUM` no era emitido; agregado handler.
8. **Runtime header**: `astra_struct_new()` movido después de definición de `AstraValue` (tipo incompleto).

### Lo que falta (bloqueado o pendiente)

| Feature | Problema | Esfuerzo estimado |
|:--------|:---------|:-------------------|
Los cinco ítems que esta tabla daba por pendientes **ya funcionan** y desde el
2026-09-21 están verificados automáticamente: el runner compila los 42 casos no-UI
de conformidad con `--emit-c` + `gcc` y compara su salida con la de la VM
(coincidencia exacta, sin fugas bajo LSan):

| Feature | Estado real (medido) |
|:--------|:---------------------|
| **Lambdas** | ✅ `lambda_basic`, `lambda_multi` reproducen la VM |
| **Match** | ✅ `match_variants`, `or_patterns`, `match_guard`, `match_statement`, `nested_pattern_bind`… idénticos |
| **Option/Result** | ✅ `option_basic`, `option_equality`, `result_basic`, `result_match`, `nested_option_result`, `try_operator` |
| **Enums con datos** | ✅ `pattern_bind`, `nested_pattern_bind`, `mixed_patterns` |
| **`?` operator** | ✅ `try_operator` (era el único feature documentado **sin ningún test**) |

Dos ítems que sí eran reales y quedaron cerrados en la misma pasada:

| Ítem | Estado |
|:-----|:-------|
| **Errores de runtime en código de módulo** | ✅ verificado: el runtime reporta y termina con salida 1 (`astra_runtime_error` imprime y sale, no depende de `setjmp`). `tests/codegen/frame_overflow.astra` y `out_of_bounds.astra` lo ejercitan en el nivel superior |
| **Agregados en código de módulo** | ✅ el dispatcher de módulo no conocía `NEW_STRUCT`, `GET_FIELD`, `SET_FIELD`, `NEW_ENUM*` ni `GET_ENUM_FIELD`, y además su `CONST` no emitía el `VAL_STRUCT_DEF` (caía en `default:` y empujaba `nil`, así que un `let p = P { … }` de nivel superior construía el struct desde un puntero NULL: SEGV, no diagnóstico). Cubierto por `module/toplevel_aggregates.astra` (§6, S16) |

**Lo que queda en esta sección es deuda estructural, no un fallo funcional:** el
backend de C tiene **dos dispatchers de opcodes** (cuerpo de función y código de
módulo) que hay que mantener en paralelo. Esa duplicación ha causado ya cuatro
bugs (S4 y su gemelo, el `POP` de módulo, los operadores bit a bit de módulo y
el `VAL_STRUCT_DEF` de arriba). El error duro de "opcode sin handler" los vuelve
*ruidosos* en vez de silenciosos, que es lo que permitió cerrarlos; la
unificación en un solo `emit_instructions` parametrizado está en §4bis#32.

### Cómo usar

```bash
cd seed
make debug                        # compila astra-seed con ASan+UBSan
./astra-seed --emit-c input.astra # genera input.c
gcc -Wall -Wextra -Isrc -o output input.c -lm  # compila el C generado
./output                          # ejecuta
```

`-Isrc` **no es opcional**: el `.c` generado hace
`#include "codegen_runtime.h"` y ese header vive en `seed/src/`, no junto al
archivo de salida. El comando documentado sin `-Isrc` fallaba con
`fatal error: codegen_runtime.h: No such file or directory`.

Flags de debug del codegen:
```bash
ASAN_OPTIONS=detect_leaks=0 ./astra-seed --emit-c input.astra  # sin leak detection
./astra-seed --emit-c input.astra 2>err.txt                    # errores en stderr
```

### Dos backends, un programa

La regla que se aplicó a fondo el 2026-09-21: **si el programa compila en ambos
backends, su comportamiento observable debe ser el mismo** — misma salida, mismo
código de salida y, cuando ambos fallan, el mismo texto de error (al VM se le
añade su prefijo `fichero:línea:`, que el runtime de C no tiene). Esa regla
destapó las divergencias S12–S14 de §6 (igualdad estructural, `%` con flotantes,
orden de comparaciones, división por cero en `0.0`). Asimetrías que quedan a
propósito:

| Asimetría | Por qué |
|:----------|:--------|
| El VM corta por **profundidad de llamada** (256 frames, `VM_CALL_DEPTH`) y el C por **ranuras de pila** (`ASTRA_FRAME_SIZE`) | El VM necesita un array fijo de metadatos por frame; el backend de C usa la pila de C como metadatos y solo tiene el presupuesto de operandos. Los dos topes son distintos en *tipo*, no en intención: ambos terminan con diagnóstico |
| El runtime de C no imprime `fichero:línea:` en sus errores | El código generado no lleva posiciones de origen; añadirlas es trabajo de Fase 2 (el emisor tendría que anotar cada instrucción que puede fallar) |
| `--dump-bytecode` imprime los valores de las constantes por stdout y el resto por stderr | `value_print()` escribe a stdout y lo comparte con el builtin `print`; darle un `FILE*` es una refactorización aparte. Consecuencia práctica: `--dump-bytecode > f 2>&1` es la forma de capturarlo entero |

## 4. Pendiente para completar la Fase 1

Ordenado por valor para el objetivo de bootstrap.

### Agregados (bloquea el compilador auto-hospedado)
- [x] **Structs**: literal, valor `VAL_STRUCT`, acceso a campo por nombre en
      codegen, igualdad estructural e impresión.
- [x] **Enums unitarios**: `enum Color { Rojo Verde }`, `Enum.Variant` como
      expresión, `VAL_ENUM`, igualdad e impresión `Color.Rojo`.
- [x] **match**: `NODE_MATCH` en parser/AST, `or`-patterns, wildcard,
      exhaustividad y codegen por comparación de variante.
- [x] **Enums con datos** (ADT): `Circulo(Float)`, bindings en patrones,
      patrones anidados. Ver `research/04` §9.3.
- [x] **Guards** `patrón if cond` (parser soporta, emitter genera código).
- [x] **Option/Result**: constructores `some(x)`, `none`, `ok(x)`, `err(x)`
      implementados como enums builtin. Operador `?` implementado.

### Closures y módulos
- [x] **Lambdas** `|params| { body }`: parse, typecheck (con inferencia de retorno),
      emit como FnObj interno. Soporta parámetros tipados, return type annotations
      y return statements. Sin captura de variables (closures) aún.
- [ ] Cierre de variables capturadas (Tier 2 del MVP).

### Sistema de tipos
- [ ] Genéricos básicos por monomorfización (Tier 3).
- [ ] Traits con despacho simple (Tier 3).
- [ ] Unidades de medida (fuera del alcance del seed).

### C Codegen (`--emit-c`)
- [x] **Fundamentos**: `codegen_runtime.h`, `codegen.h`, `codegen.c`, integración CLI.
- [x] **Literales y operaciones**: aritmética, comparación, lógicos, strings.
- [x] **Variables y control flow**: locales, globales, if/else, for..in.
- [x] **Funciones**: forward declarations, llamadas, return, recursión.
- [x] **Agregados básicos**: arrays, structs con acceso a campo, enums unitarios.
- [x] **Lambdas**: `astra_fn_new` con cuerpo C estático por FnObj (`astra_lambda_N`).
- [x] **Match**: funciona (el fallo de "cannot call non-function" era un efecto de los opcodes sin handler).
- [x] **Option/Result**: `TRY_UNWRAP`, `TAG_IS`, `UNWRAP` verificados por `try_operator` y los 4 tests de Option/Result.
- [x] **Enums con datos**: `pattern_bind`, `nested_pattern_bind`, `mixed_patterns` idénticos a la VM.
- [x] **Suite vía C codegen**: `run_tests.sh` compila los 42 casos no-UI con `--emit-c` + `gcc` y compara salida (ver §6).
- [x] **Escapado de literales de string**: el contenido se escribe escapado; antes un `"` en un string de Astra producía C inválido e inyectable (ver §6, S2).
- [x] **Límites de los registros de nombres**: un programa con más de 256 globales corrompía memoria; ahora falla con diagnóstico (ver §6, S1).
- [x] **Errores de runtime en código de módulo**: verificado (§3c); el runtime no depende de `setjmp` para reportar.
- [x] **Agregados en código de módulo**: structs, enums y variantes con datos en el nivel superior (§6, S16).
- [x] **Seguridad de memoria del código generado**: push acotado, indexado acotado y copia de literales de array (§3c, §6 S9–S11).

### Arquitectura interna
- [x] **Registro de constructos**: un archivo por producción EBNF, con gramática
      y cita de investigación obligatorias, y 14 invariantes verificadas
      automáticamente. Ver `CONSTRUCT_REGISTRY.md` y `MULTI_AGENT_SETUP.md`.
- [x] **Migrar los hooks** `parse` / `emit` / `check` a los archivos de
      constructo — **decisión del 2026-09-21: no se migran**. El registro se
      queda declarativo y validado. Motivo y condiciones para revisarlo en
      `CONSTRUCT_REGISTRY.md` §8; resumen: `research/011` §2.3.1 lista la
      sobre-ingeniería del seed como su primer anti-patrón y §3.3 no incluye
      siquiera un directorio `constructs/`.
- [ ] **Unificar los dos dispatchers del backend de C** (deuda estructural, ver
      §3c y §4bis#32).

### Tooling
- [x] **`--emit-c`** (ruta de bootstrap a C del diseño original).
- [x] **`--dump-bytecode`** como flag estable (comparte implementación con
      `ASTRA_DUMP_VM` vía `vm_dump_bytecode()`).
- [ ] Fuzzing del lexer/parser (`clang -fsanitize=fuzzer`).
- [ ] CI multiplataforma (Linux/macOS/Windows).

## 4bis. Inventario de tareas para completar la Fase 1

### Categoría A: Tareas CORTAS (< 1 día)

| # | Tarea | Impacto | Estado | Archivos |
|:-:|:------|:--------|:-------|:---------|
| 1 | Agregar `i64`, `u32`, `u64` al typechecker | Alto | ✅ | `astra.h`, `typechecker.c` — tipos resueltos en `resolve_type_node`, aceptados en bitwise/index/ranges |
| 2 | Permitir concatenación de strings con `+` | Alto | ✅ | `typechecker.c:519-522` — guard `string + string → string` antes del bloque aritmético |
| 3 | Sintaxis `T?` para optional types | Alto | ✅ | `parser.c` — `parse_type()` consume `TOKEN_QUESTION` como postfix, envuelve en `NODE_TYPE_OPTIONAL` |
| 4 | Eliminar `null`, mantener `none` canónico | Alto | ✅ | `TOKEN_NULL`/`NODE_NULL_LIT` eliminados de lexer, parser, typechecker, emitter, driver, constructs |
| 5 | `--dump-bytecode` como flag CLI | Medio | ✅ | `main.c`, `driver.c`, `vm.c` — `vm_dump_bytecode()` compartido con `ASTRA_DUMP_VM` |
| 6 | Bug de coma en struct declarations | Medio | ✅ | El bucle de errores terminaba (la guarda de profundidad de §6 lo acota) y `ui/struct_comma_body.astra` fija diagnóstico + terminación |
| 7 | Documentar semántica de agregados | Medio | ✅ | `ARCHITECTURE.md` §2 (compartición de handle, decisión del usuario) |
| 8 | Resolver contradicciones entre documentos | Bajo | ✅ | `let`/`let mut` canónico en los tres documentos; notas de alcance por tiers (§4bis, `ARCHITECTURE.md` §5.1) |
| 9 | Decidir keyword canónico (`let`/`mut` vs `val`/`mut`) | Bajo | ✅ | `let` / `let mut`; hallazgo D |

### Categoría B: Tareas MEDIANAS (1-3 días)

| # | Tarea | Impacto | Estado | Archivos |
|:-:|:------|:--------|:-------|:---------|
| 10 | C codegen: Match expressions | Alto | ✅ | Verificado por `match_*`, `or_patterns`, `match_guard` |
| 11 | C codegen: Lambdas | Alto | ✅ | `lambda_basic`, `lambda_multi` |
| 12 | C codegen: Enums con datos | Alto | ✅ | En el cuerpo de función *y* en módulo (§6, S16) |
| 13 | C codegen: Option/Result | Alto | ✅ | `option_*`, `result_*`, `nested_option_result` |
| 14 | C codegen: `?` operator | Alto | ✅ | `conformance/enums/try_operator.astra`; mensaje de error idéntico al VM |
| 15 | Suite de tests vía C codegen | Alto | ✅ | `tests/run_tests.sh` (segunda ruta) + `tests/codegen/` |
| 16 | Closures (captura de variables) | Medio | [ ] **Tier 2** | `emitter.c`, `vm.c` — fuera del alcance de la Fase 1 (`research/011` §5.2 la lista en Tier 1 el *lambda*, no la captura) |
| 17 | Migrar hooks de constructos | Medio | ✖ decidido no hacer | `CONSTRUCT_REGISTRY.md` §8 |
| 18 | C codegen: module-level errors sin setjmp | Medio | ✅ | Verificado: salida 1 con diagnóstico en ambos backends |
| 19 | Bitwise operators en el emisor | Medio | ✅ | VM + runtime de C + `tests/codegen/bitwise.astra` |
| 20 | `while`/`for` como expresión | Medio | ✖ fuera de alcance | Un `while` como expresión exige `break valor` con tipo unificado; `research/010` §9 no lo incluye en el seed (su forma es `for` como *statement* + `if` como expresión). Documentado como no-soporteado |
| 21 | Frame dinámico en C codegen | Bajo | ✅ | `ASTRA_FRAME_SIZE` + `ASTRA_PUSH` acotado (§6, S9) |
| 22 | Manejo de opcodes desconocidos en C codegen | Bajo | ✅ | Es un **error duro**, no un comentario |
| 23 | Fuzzing del lexer/parser | Bajo | [ ] | Nuevo target — pendiente |

### Categoría C: Tareas LARGAS (4+ días)

| # | Tarea | Impacto | Estado | Archivos |
|:-:|:------|:--------|:-------|:---------|
| 24 | Module system (File-as-Module) | Alto | [ ] **Fase 2** | `research/011` §5.3 lo da por no-bloqueante para el bootstrap: el seed compila **un** fichero, que es lo que necesita para auto-hospedarse en un solo módulo |
| 25 | Full C codegen test suite | Alto | ✅ | La suite completa corre por ambas rutas (registro + VM + C) |
| 26 | CI multiplataforma | Alto | [ ] | `.github/workflows/` — pendiente |
| 27 | Genéricos básicos por monomorfización | Medio | [ ] | **Fase 2** |
| 28 | Traits con despacho simple | Medio | [ ] | **Fase 2** |
| 29 | Migración completa de constructos (44 hooks) | Medio | ✖ decidido no hacer | `CONSTRUCT_REGISTRY.md` §8 |
| 30 | Standard library mínima | Bajo | [ ] | **Fase 2** |
| 31 | LSP básico | Bajo | [ ] | **Fase 2** |
| 32 | Unificar los dispatchers del backend de C | Medio | [ ] | `codegen.c` — origen de cuatro bugs (§3c); el error duro de opcode sin handler los vuelve ruidosos mientras siga duplicado |

### Estado de hallazgos de auditoría (COHERENCE_AUDIT.md)

| Hallazgo | Descripción | Estado |
|:---------|:------------|:-------|
| A | Valor de bloque roto | ✅ Resuelto (stack model en emisor) |
| B | LValue restringido a identificadores | ✅ Resuelto (`SET_INDEX`, `SET_FIELD`) |
| C | Retorno implícito `nil` | ✅ Resuelto (tail return) |
| D | `val` keyword no existe, 3 docs discrepantes | ✅ Resuelto (`let`/`let mut` canónico) |
| E | Tipos enteros `i64`/`u32`/`u64` faltantes | ✅ Resuelto (agregados al typechecker) |
| F | `T?` optional type no parseable | ✅ Resuelto (parser consume `?`) |
| G | Semántica de agregados sin especificar | [ ] Pendiente |

## 5. Cómo continuar

Ver `AGENTS.md` para comandos y **workstreams de sub-agentes** (registry, un
constructo, frontend, types, codegen, runtime, tests, docs), con la propiedad de
archivos y el protocolo de handoff. Ver `CONSTRUCT_REGISTRY.md` para el diseño
por constructo y `MULTI_AGENT_SETUP.md` para activar los multi-agentes
(verificado: en Freebuff están forzados a `LITE` y no hay forma de activarlos;
con Codebuff en `mode: "MAX"` sí).

Regla de oro al tocar el emisor: **cada camino debe dejar la pila de la VM a una
altura predecible**. La mayoría de los bugs encontrados en la Fase 1
(desbalance de pila, saltos con off-by-one, slots de frame) provienen de romper
esa invariante.

---

## 6. Auditoría de corrección — 2026-09-21

Segunda pasada de auditoría, esta vez **ejecutando** el binario (la primera,
`COHERENCE_AUDIT.md`, fue de coherencia documento↔código). Todo hallazgo de abajo
tiene un PoC reproducible y una prueba de regresión en `seed/tests/`.

### 6.1 Hallazgos y estado

| # | Severidad | Hallazgo | Evidencia (antes) | Estado |
|:-:|:----------|:---------|:------------------|:-------|
| S1 | 🔴 Alta | Corrupción de memoria en `--emit-c`: los registros de nombres (`global_map[256]`) se indexaban sin comprobar límites | 260+ globales de nivel superior → `UBSan: index 256 out of bounds` + `ASan SEGV` en `make_global_cname` | ✅ guards + `Codegen.error_count`; falla con diagnóstico y no escribe el `.c` |
| S2 | 🔴 Alta | El generador de C escribía los literales de string **sin escapar**: `"`/`\`/salto de línea rompían el literal y permitían inyectar C arbitrario | `print("say \"hi\" now")` → `astra_string_new("say "hi" now", 12)` (C inválido) | ✅ `cg_write_c_escaped()`; salida bit a bit idéntica a la VM |
| S3 | 🔴 Alta | Recursión sin límite: 7 formas de anidamiento desbordaban la pila del proceso | 20 000 `(`, `{`, llamadas, arrays o `if` → **SIGSEGV** | ✅ `PARSER_MAX_DEPTH = 256` en expresión y bloque, con aborto no recuperable; 7/7 vectores dan un diagnóstico en ~10 ms |
| S4 | 🔴 Alta | **Todo** el código de nivel de módulo estaba roto: `print(...)`, expresiones sueltas, `if` y asignaciones daban un error *interno* falso | `print("hi");` → `error: internal: stack imbalance in statement Module` | ✅ eliminado el dispatcher duplicado `emit_node`; los items de módulo pasan por `emit_stmt` |
| S5 | 🟠 Media | `make debug` no recompilaba: las variantes compartían `build/` y las flags no entran en el timestamp | `make && make debug` → `Nothing to be done for 'debug'` (binario sin instrumentar); mezclar variantes → `ld: creating DT_TEXTREL in a PIE` | ✅ objetos y binario por variante (`build/debug`, `build/release`) con relink forzado |
| S6 | 🟠 Media | El build **no** estaba libre de warnings, contra lo que exige `AGENTS.md`; incluía una lectura fuera de límites real | 13 warnings con gcc; `memcpy(out_path + fn_len, ".c", 4)` lee 4 bytes de un literal de 3 (`-Wstringop-overread`, CWE-125) | ✅ 0 warnings; `memcpy` de 3 bytes; 8 casos `-Wswitch` de `--dump-ast` completados |
| S7 | 🟡 Baja | `codegen_destroy()` no liberaba los nombres de `struct_defs`/`enum_defs` | LSan abortaba en cada `--emit-c` con struct/enum (64 bytes), lo que ocultaba el fallo con `detect_leaks=0` | ✅ liberados; el round-trip completo pasa con LSan activo |
| — | 🔴 Alta | Operadores bit a bit en **código de módulo** se descartaban en silencio | `let x = 5 & 3;` → el C generado imprimía `3` (VM: `1`) | ✅ casos añadidos a `emit_module_code` |
| — | 🟠 Media | `emit_module_code` emitía `/* TODO: opcode N */` para cualquier opcode sin handler: una instrucción descartada = respuesta incorrecta silenciosa | el mismo caso del bitwise; y `OPCODE_POP` tampoco estaba cubierto | ✅ es un **error duro** (`error: C codegen has no handler for opcode N`); al activarlo destapó al instante el `POP` de módulo que faltaba |
| — | 🟠 Media | `?` documentado como implementado y **sin ningún test**; en la práctica inusable | `fn f(x: i32?) -> i32? { let v = x?; return some(v + 1) }` → cascada de errores de tipo | ✅ constructores con tipo de optional y `?` que quita la capa; `try_operator` cubre ambos backends |

**Segunda tanda — 2026-09-21 (misma sesión, tras cerrar la primera).** Al buscar
el mismo tipo de fallo *en el otro backend* y al comprobar la paridad
VM↔C operación por operación aparecieron estos. Los tres primeros son de
memoria y los dos últimos producían **respuestas incorrectas silenciosas**
(la peor clase para un compilador que se va a usar para auto-hospedarse):

| # | Severidad | Hallazgo | Evidencia (antes) | Estado |
|:-:|:----------|:---------|:------------------|:-------|
| S8 | 🔴 Alta | **El VM corrompía valores en recursión**: `CallFrame.base` es una ranura de 16 bits, pero `GET_LOCAL`/`SET_LOCAL` la leían a través de un `uint8_t` y se envolvía en 256 | `fn f(n: i32) -> i32 { … }` con `f(127)` → `runtime error: cannot compare function and int` (leía el slot de *otro* frame) | ✅ `uint16_t` en los tres sitios; valores exactos hasta 254 y luego `call depth exceeded` **con la línea del call site** (antes reportaba `:0:`) |
| S9 | 🔴 Alta | **Desbordamiento de pila en el C generado**: `frame[sp] = …; sp++` sin comprobar nada, y `frame` es una ventana al medio del array, así que `sp` por sí solo no dice nada | recursión de profundidad 600 → `ASan: stack-buffer-overflow` (READ de 24 bytes) en `astra_fn_f` | ✅ `ASTRA_PUSH` acota la ranura **absoluta** contra `ASTRA_FRAME_SIZE`, con el array en global (`astra_frame`); profundidad 5000 → `runtime error: frame stack overflow` |
| S10 | 🔴 Alta | **Los literales de array quedaban colgando**: `astra_array_new` *adoptaba* el `AstraValue _elems[n]` local de la función C que lo construía | `fn mk() -> [i32] { return [1, 2, 3] }` + usar el array → `ASan: stack-use-after-scope` | ✅ el constructor **copia** (como hace NEW_ARRAY en el VM); `tests/codegen/returned_literal.astra` |
| S11 | 🔴 Alta | **Indexado de array sin comprobar en el C generado**: `elems[i]` directo | `print(a[5])` → valor basura con salida 0 (la VM reporta `index 5 out of bounds (len 3)`); `a[5] = 99` → corrupción de heap | ✅ `astra_array_get`/`astra_array_set` con el **mismo texto** que el VM |
| S12 | 🔴 Alta | **Igualdad de agregados**: `astra_eq` no tenía casos para array/struct/variante con datos y caía en `default: false` | `print([1,2] == [1,2])` → VM `true`, C `false`; igual con structs y `C.A(1) == C.A(1)` | ✅ casos estructurales (por nombre de tipo y campo a campo), como `value_eq` del VM; requiere guardar `field_count` en el objeto de enum |
| S13 | 🟠 Media | **`%` con flotantes**: el runtime de C solo tenía la rama entera y *erraba* donde el VM da un valor | `print(7.5 % 2.0)` → VM `1.5`, C `runtime error: unsupported % operands` | ✅ `fmod`, como `OPCODE_MOD` |
| S14 | 🟠 Media | **Comparaciones**: `<`/`>`/`<=`/`>=` devolvían `false` para pares no numéricos donde el VM da error, y `1.0 / 0.0` imprimía `inf` donde el VM aborta | `print("a" < "b")` → VM error, C `false`; `1.0 / 0.0` → VM `division by zero`, C `inf` | ✅ error con el texto del VM en ambos casos; `string_order_rejected` y `float_divide_by_zero` en los dos backends |
| S15 | 🟠 Media | **Literales enteros fuera de rango**: el lexer acumulaba en `int64_t` sin comprobar (y las variantes con `<<` eran UB por desbordamiento con signo) | `print(9223372036854775808)` → `-9223372036854775808`; `print(99999999999999999999999999)` → basura | ✅ el lexer rechaza el literal; y el mensaje **llega al usuario** (antes el parser lo sustituía por su genérico "unexpected token") |
| S16 | 🟠 Media | **Agregados en código de módulo**: el dispatcher de módulo no conocía `NEW_STRUCT`/`NEW_ENUM*`/campos, y su `CONST` no emitía `VAL_STRUCT_DEF` (caía en `default:` → `nil`) | `let origin = P { x: 0, y: 0 }` + `origin.x` → el C generado hacía SEGV (definición NULL); la VM imprimía `0` | ✅ handlers añadidos a los dos dispatchers; `module/toplevel_aggregates.astra` + gemelo de C |
| S17 | 🟠 Media | **`i64`/`u32`/`u64` eran inhabitables** (hallazgo E de `COHERENCE_AUDIT.md`): el checker resolvía los nombres pero todo literal era `i32`, y no hay sufijo ni cast | `let a: i64 = 5` → `type mismatch: declared as i64 but initialized with i32`; `f(5)` con `f(x: i64)` → igual | ✅ literales enteros **polimórficos** (`TYPE_INT_LITERAL`): adoptan el tipo del contexto, y sin contexto un binding toma el tipo por defecto (`i32`), como en Rust. Ver §6.3 para lo que *no* se verifica |

### 6.2 Decisiones tomadas (y por qué)

1. **Opcode sin handler en el backend de C = error, no comentario.** Una
   instrucción descartada produce un programa que calcula mal sin avisar; es la
   peor clase de fallo que puede tener un compilador que se usa para
   auto-hospedarse. Coste: cero en la ruta feliz, y ya detectó un opcode real
   sin cubrir (`POP` de módulo).
2. **Límite de profundidad de 256 en el parser, no en cada fase.** El parser es
   la frontera de confianza (el input viene de disco) y el árbol que produce acota
   la profundidad que después recorren el checker y el emisor. 256 está muy por
   encima de lo legible por humanos y muy por debajo de la pila por defecto.
3. **La brecha de profundidad aborta el parseo.** Con recuperación de errores, el
   parser volvía a descender sobre los 20 000 caracteres restantes: pasaba de
   segfault a *timeout*. Un límite de profundidad es fatal por naturaleza (así lo
   tratan gcc y clang).
4. **Los constructores de Option/Result tienen tipo de optional.** Devolver el
   tipo del payload dejaba que un valor etiquetado se hiciera pasar por valor
   plano (`let x: i32 = some(3)` compilaba) y dejaba a `?` sin capa que quitar. El
   VM ya da error de runtime ("? requires Result or Option") cuando no hay tag,
   así que el checker estaba contradiciendo al runtime. El tipado estático de
   `Result` (un `TYPE_RESULT` propio) es Tier 2 (`research/011` §5.2) y queda
   fuera: hoy `ok`/`err` llevan el tipo del payload y el tag vive en runtime.
5. **No migrar los hooks del registro de constructos** (ver `CONSTRUCT_REGISTRY.md` §8).
6. **Semántica de agregados: compartir handle** (decisión del usuario; ver
   `ARCHITECTURE.md` §2).
7. **Un array literal se copia al construirse, no se adopta la pila.** El VM ya
   copiaba desde su pila de operandos; que el runtime de C adoptara el buffer del
   llamante era una optimización de una línea que convertía cada literal devuelto
   por una función en un puntero a una pila muerta (S10). La copia cuesta una
   asignación y cierra la clase entera.
8. **Toda escritura de pila del código generado está acotada o no existe.**
   Después de S9/S11 la regla es mecánica: los push pasan por `ASTRA_PUSH` y el
   indexado por `astra_array_get/set`. Es la misma decisión que el VM ya había
   tomado (`vm_push` comprueba), aplicada al backend que la incumplía.
9. **Los dos backends comparten el texto de sus errores de runtime.** El runtime
   de C decía `unsupported + operands` donde el VM dice `cannot add int and bool`,
   y nombra los tipos de otra forma. Un lenguaje con dos implementaciones necesita
   que el error sea reconociblemente el mismo, y es la condición para poder
   comparar la salida de error en los tests (hoy `EXPECT-RUNTIME-ERROR` compara el
   texto en la VM y exige salida limpia en C).
10. **Un literal entero no tiene tipo hasta que un contexto se lo da** (S17). La
    alternativa —sufijos (`5i64`) o conversiones implícitas— choca con
    `ARCHITECTURE.md` §5.1 ("sin coerción silenciosa"): no se convierte un valor
    de un tipo a otro, sino que el literal todavía no tenía ninguno. El fallback a
    `i32` en un binding sin anotación evita que una variable quede polimórfica y
    se pueda colar después en un `u64` como si siempre lo hubiera sido.
11. **El límite de profundidad del parser aborta el parseo**, no se recupera
    (S3): con recuperación el parser volvía a descender sobre los 20 000
    caracteres restantes, cambiando un segfault por un *timeout*. gcc y clang
    tratan este límite como fatal y el seed hace lo mismo.

### 6.3 Lo que esta pasada deja explícitamente fuera

Documentado para que no se lea como resuelto:

| Tema | Estado |
|:-----|:-------|
| **Ancho de los enteros no verificado en runtime** | `u32`/`u64`/`i64` existen en el checker y los valores son `int64_t` en los dos backends. No se comprueba rango al sumar ni al asignar: `let a: u32 = -1` compila y `a` vale `-1`. Un `u64` por encima de `INT64_MAX` tampoco es representable (el lexer lo rechaza). Es consecuencia de que el seed modela **un** entero de 64 bits y le pone nombres; darle semántica real de anchuras es trabajo de Fase 2 (`research/011` §9.2 es lo que lo exige) |
| **`while`/`for` como expresión** | No soportado a propósito (ver §4bis#20) |
| **Closures** | Tier 2; los `lambda` existen pero no capturan (ver §4bis#16) |
| **Módulos** | Un fichero; el module system es Fase 2 |
| **Fuzzing y CI** | Pendientes (§4bis#23 y #26). El fuzzing es la forma natural de buscar la *próxima* clase de fallo del lexer/parser, ahora que los siete vectores conocidos se cierran por el límite de profundidad |
| **Posiciones de origen en los errores del C generado** | No las lleva; añadirlas exigiría anotar cada instrucción que puede fallar |

### 6.5 Hallazgos de la Fase 2.2 (2026-09-28)

Al portar el sistema de módulos al compilador Zig (`PHASE2_PROGRESS.md` §7) se
auditó por primera vez el constructo `use` del seed, que **no tenía ningún
test**. Aparecieron dos fallos, corregidos aquí:

| # | Severidad | Hallazgo | Evidencia (antes) | Estado |
|:-:|:----------|:---------|:------------------|:-------|
| S18 | 🟠 Media | **`use` era código muerto**: el constructo es Astra-0 (`constructs/use.c` pone `in_astra0`, y el parser lo acepta y el emitter lo ignora), pero el type checker no tenía caso para `NODE_USE` y caía en `default:` | `use std.io` → `error: unhandled node kind 46`. Ninguna declaración `use` podía compilar: el constructo estaba en el registro y no en la práctica | ✅ caso `NODE_USE` en `typecheck_node` (devuelve `void`); `module/use_paths.astra` lo cubre |
| S19 | 🟡 Baja | **El separador de ruta había derivado de su propia gramática**: `parse_use` casaba `TOKEN_COLON_COLON`, pero la gramática declarada (`constructs/use.c`, `research/010` §12.1) dice `ImportPath ::= Identifier ("." Identifier)*`, y `::` no es separador de ruta en ningún otro sitio del lenguaje (los caminos de variante son `Color.Rojo`, el acceso a campo `s.field`) | `use a::b` se aceptaba aquí y en ninguna otra parte | ✅ `parse_use` casa `TOKEN_DOT`; `ui/use_colon_colon.astra` fija el rechazo. Decisión y contexto en `PHASE2_GAP_ANALYSIS.md` App. B #6 |

Ninguno de los dos lo podía ver la suite: no había ni un caso de conformidad que
nombrara `use`. La causa raíz es la misma que la del resto de este apartado — una
construcción marcada como soportada sin ninguna prueba que la ejercite.

### 6.6 Cómo se reproduce

```bash
cd seed
make clean && make debug && make test        # 93 casos, ASan+UBSan+LSan, 0 fugas
./astra-seed --check-constructs              # 46 constructos, 27 operadores, sin drift

# S1: 300 globales por la ruta de C (antes: SEGV)
python3 -c "open('/tmp/g.astra','w').write(''.join('let g%d = %d;\n'%(i,i) for i in range(300))+'fn main() { print(g0) }\n')"
./astra-seed --emit-c /tmp/g.astra          # error: C codegen registry overflow, exit 1

# S3: anidamiento profundo (antes: SIGSEGV)
./astra-seed tests/conformance/ui/nesting_too_deep.astra   # error: nesting too deep (max 256)

# S8: recursión (antes: valor corrupto a partir de 127 frames)
./astra-seed tests/conformance/expressions/deep_recursion.astra      # 200
./astra-seed tests/conformance/expressions/recursion_depth_limit.astra  # call depth exceeded

# S9/S10/S11: memoria del C generado (antes: ASan en los tres)
for t in frame_overflow out_of_bounds returned_literal; do
  ./astra-seed --emit-c tests/codegen/$t.astra
  gcc -Isrc -o /tmp/t tests/codegen/$t.c -lm && /tmp/t
done

# S2 y el round-trip completo del backend de C
./tests/run_tests.sh                        # incluye los casos de tests/codegen/
```

Al verificar esta pasada se compiló además **cada** caso no-UI de conformidad con
`--emit-c` + `gcc` (y con ASan) comparando salida, código de salida y texto de
error contra la VM. Cualquier divergencia nueva se ve así antes de escribirla en
la documentación, que es lo que faltaba para que las afirmaciones de esta
documentación sean reproducibles en lugar de declaradas.

### 6.7 Superficie de módulos completa en el seed (2026-09-29)

El paso 1 de módulos dejó al compilador Zig por delante en el *frontend*: aceptaba
`import`/`from`/`as` mientras el seed sólo tenía `use`, y registraba `import` como
un constructo fuera de Astra-0 (`keyword = NULL`). Eso es un superconjunto —la
regla de paridad lo tolera— pero es la dirección que conviene no mantener: la
gramática de `research/010` §12.1 es una sola, y el seed es donde se decide qué es
Astra-0.

El seed reconoce ahora las tres formas, sin añadir resolución de módulos (sigue
sin ser su trabajo: `research/011` §5.2):

```
ExportStmt ::= "use" ImportPath
ImportStmt ::= "import" ImportPath ("as" Identifier)?
             | "from" ImportPath "import" ImportItem ("," ImportItem)*
ImportPath ::= Identifier ("." Identifier)*
ImportItem ::= Identifier ("as" Identifier)?
```

Lo que se añadió, y por qué en cada sitio:

| Pieza | Sitio | Nota |
|:------|:------|:-----|
| `TOKEN_IMPORT` / `TOKEN_FROM` / `TOKEN_AS` | `lexer.c` (`keywords[]`) | tres entradas más en la tabla de palabras clave; `lexer_keyword_token` las expone al self-check |
| `NODE_IMPORT` / `NODE_FROM` / `NODE_IMPORT_ITEM` | `astra.h` | `ImportDecl{path, alias}`, `FromDecl{path, items}`, `ImportItem{name, alias}`; `alias.str == NULL` cuando no hay `as` |
| `constructs/{import,from,import_item}.c` | registro | `import` y `from` son dos archivos para una producción con dos alternativas (cada palabra clave necesita su token); `import_item` es el SUB que posee `NODE_IMPORT_ITEM`. **46 constructos** |
| `parse_module_path` | `parser.c` | un solo constructor de la ruta punteada, compartido por `import` y `from` |
| casos `NODE_*` | `typechecker.c`, `emitter.c`, `driver.c` | `void` y sin efecto, como `use`; `--dump-ast` imprime `Import(...)`/`From(...)`/`ImportItem(...)` |

Dos decisiones que la implementación dejó al descubierto y que conviene tener por
escrito:

- **Un `from` sin items es un error de sintaxis.** La producción exige
  `ImportItem ("," ImportItem)*`, y el parser lo aceptaba como una lista vacía: un
  `from a.b import` que no importaba nada y no decía nada. Ahora reporta
  `expected at least one import item` (`ui/from_without_items.astra`).
- **La ruta se construye sin `realloc`.** La arena no tiene `realloc`, así que
  `parse_module_path` acumula los segmentos internados y los une en un solo
  buffer al final: el número de reservas depende de los segmentos, no de los
  caracteres. `da_push` existía pero **sin ningún uso** en el compilador y con el
  patrón "asignar memoria nueva y ponerla a cero", que pierde el contenido
  anterior; no se adoptó.
