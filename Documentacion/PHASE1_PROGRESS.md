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
// EXPECT-ERROR: <texto de error>     (el programa debe fallar)
```

La suite arranca con la puerta del registro (`--check-constructs`) y sigue con
los casos de conformidad. Cobertura actual (60 casos, todos en verde, también
bajo ASan/UBSan):

| Área | Casos |
|:-----|:------|
| registro | invariantes de constructos, palabras clave y tabla de operadores |
| expressions | `arithmetic` (precedencia, unarios, `%`), `string_concat` (`+` con strings), `integer_types` (`i64`/`u32`/`u64`), `none_literal` (`none` como ausencia) |
| control | `if_else`, `while_break`, `while_continue` |
| loops | `range_exclusive`, `range_inclusive`, `break_continue`, `for_array` |
| arrays | `literal_index`, `element_assign`, `alias_write` (compartición de handles) |
| structs | `literal_fields`, `field_order`, `struct_in_function`, `field_assign` (cadenas anidadas) |
| blocks | `tail_expression`, `if_value` |
| types | `optional_syntax` (`T?` parseado correctamente) |
| enums | `match_variants`, `or_patterns`, `enum_print`, `match_statement`, `match_block_arm`, `pattern_bind`, `nested_pattern_bind`, `mixed_patterns`, `match_guard`, `guard_with_binding`, `option_basic`, `option_equality`, `result_basic`, `result_match`, `nested_option_result` |
| functions | `recursion` (factorial + parámetros), `implicit_return` |
| lambda | `lambda_basic`, `lambda_multi` |
| ui | `type_mismatch`, `break_outside_loop`, `struct_missing_field`, `struct_unknown_field`, `struct_field_type`, `match_non_exhaustive`, `enum_unknown_variant`, `match_pattern_type`, `void_initializer`, `missing_return_value`, `immutable_element_assign`, `enum_variant_assign`, `pattern_bind_wrong_type`, `option_type_error`, `option_type_mismatch`, `lambda_type_mismatch`, `null_rejected` |

Los tests se ejecutan también bajo `make debug` (ASan + UBSan) sin fallos.

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
| E | Tipos enteros `i64`/`u32`/`u64` faltantes | Solo `i32` y `f64` | ✅ agregados al typechecker |
| F | Sintaxis `T?` no parseable | `let x: i32? = none` → error de parseo | ✅ parser consume `?` como postfix |

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
ante una coma, entra en un bucle de errores infinito en vez de abortar. No lo
toca este hito; es frontend puro.

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
| Arrays (literal + indexado) | ✅ | `astra_array_new` + `astra_array_get` |
| Structs (literal + acceso a campo) | ✅ | `AstraStructDef`/`AstraStruct` estáticos, lookup por nombre en runtime |
| Enums unitarios | ✅ | `Color.Red` como `{enum_name, variant_name}` |

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
| **Lambdas** | Emite `astra_fn_new(NULL, 0)` — no genera cuerpo C para el FnObj del lambda | Medio: necesita generar funciones C estáticas para cada lambda FnObj |
| **Match** | Falla con "cannot call non-function" — probablemente porque el desugaramiento genera CALL sobre valor no-función | Medio: investigar bytecode generado para match |
| **Option/Result** | TRY_UNWRAP, TAG_IS, UNWRAP no testeados | Bajo: son opcodes simples |
| **Enums con datos** | NEW_ENUM emite pero `enum_obj` no se maneja correctamente | Medio: necesita AstraEnumObj con campos |
| **`?` operator** | No testado en codegen | Bajo: setjmp/longjmp ya está en runtime |
| **`astra_runtime_error` en module code** | Se usa fuera de contexto setjmp | Bajo: cambiar a fprintf+exit en module code |

### Cómo usar

```bash
cd seed
make debug                        # compila astra-seed con ASan+UBSan
./astra-seed --emit-c input.astra # genera input.c
gcc -Wall -Wextra -o output input.c -lm  # compila el C generado
./output                          # ejecuta
```

Flags de debug del codegen:
```bash
ASAN_OPTIONS=detect_leaks=0 ./astra-seed --emit-c input.astra  # sin leak detection
./astra-seed --emit-c input.astra 2>err.txt                    # errores en stderr
```

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
- [ ] **Lambdas**: generar funciones C estáticas para cada lambda FnObj.
- [ ] **Match**: investigar por qué falla el desugaramiento en C codegen.
- [ ] **Option/Result**: probar TRY_UNWRAP, TAG_IS, UNWRAP.
- [ ] **Enums con datos**: AstraEnumObj con campos.
- [ ] **55 tests vía C codegen**: ejecutar la suite completa y corregir diferencias.

### Arquitectura interna
- [x] **Registro de constructos**: un archivo por producción EBNF, con gramática
      y cita de investigación obligatorias, y 14 invariantes verificadas
      automáticamente. Ver `CONSTRUCT_REGISTRY.md` y `MULTI_AGENT_SETUP.md`.
- [ ] **Migrar los hooks** `parse` / `emit` / `check` a los archivos de
      constructo, fase por fase. Hoy el registro describe los 44 constructos
      pero no ejecuta ninguno (`migrated: 0 / 44`); la migración empieza por
      `if` + `else`, que es el par que motivó el diseño.

### Tooling
- [x] **`--emit-c`** (ruta de bootstrap a C del diseño original).
- [ ] `--dump-bytecode` como flag estable (hoy vía `ASTRA_DUMP_VM`).
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
| 5 | `--dump-bytecode` como flag CLI | Medio | [ ] | `main.c` |
| 6 | Bug de coma en struct declarations | Medio | [ ] | `parser.c` |
| 7 | Documentar semántica de agregados | Medio | [ ] | `ARCHITECTURE.md` |
| 8 | Resolver contradicciones entre documentos | Bajo | [ ] | Varios `.md` |
| 9 | Decidir keyword canónico (`let`/`mut` vs `val`/`mut`) | Bajo | [ ] | Varios `.md` |

### Categoría B: Tareas MEDIANAS (1-3 días)

| # | Tarea | Impacto | Estado | Archivos |
|:-:|:------|:--------|:-------|:---------|
| 10 | C codegen: Match expressions | Alto | [ ] | `codegen.c` |
| 11 | C codegen: Lambdas | Alto | [ ] | `codegen.c` |
| 12 | C codegen: Enums con datos | Alto | [ ] | `codegen.c`, `codegen_runtime.h` |
| 13 | C codegen: Option/Result | Alto | [ ] | `codegen.c` |
| 14 | C codegen: `?` operator | Alto | [ ] | `codegen.c` |
| 15 | Suite de tests vía C codegen | Alto | [ ] | `tests/run_tests.sh` |
| 16 | Closures (captura de variables) | Medio | [ ] | `emitter.c`, `vm.c` |
| 17 | Migrar hooks de constructos (iniciar con `if`+`else`) | Medio | [ ] | `constructs/`, `parser.c`, `emitter.c`, `typechecker.c` |
| 18 | C codegen: module-level errors sin setjmp | Medio | [ ] | `codegen.c` |
| 19 | Bitwise operators en el emisor | Medio | [ ] | `emitter.c` |
| 20 | `while`/`for` como expresión | Medio | [ ] | `parser.c`, `emitter.c` |
| 21 | Frame dinámico en C codegen | Bajo | [ ] | `codegen.c` |
| 22 | Manejo de opcodes desconocidos en C codegen | Bajo | [ ] | `codegen.c` |
| 23 | Fuzzing del lexer/parser | Bajo | [ ] | Nuevo target |

### Categoría C: Tareas LARGAS (4+ días)

| # | Tarea | Impacto | Estado | Archivos |
|:-:|:------|:--------|:-------|:---------|
| 24 | Module system (File-as-Module) | Alto | [ ] | `parser.c`, `typechecker.c`, `emitter.c`, driver |
| 25 | Full C codegen test suite | Alto | [ ] | `tests/run_tests.sh`, `codegen.c` |
| 26 | CI multiplataforma | Alto | [ ] | `.github/workflows/` |
| 27 | Genéricos básicos por monomorfización | Medio | [ ] | Phase 2 |
| 28 | Traits con despacho simple | Medio | [ ] | Phase 2 |
| 29 | Migración completa de constructos (44 hooks) | Medio | [ ] | `constructs/` |
| 30 | Standard library mínima | Bajo | [ ] | Phase 2 |
| 31 | LSP básico | Bajo | [ ] | Phase 2 |

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
