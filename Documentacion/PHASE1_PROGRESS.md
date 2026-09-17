# Astra — Phase 1 Implementation Status

Estado del **compilador semilla** (`seed/`), la primera fase del plan de
bootstrap descrito en `COMPILER_STRATEGY.md`: un compilador en C que compila el
subconjunto **Astra-0**, suficiente para arrancar la Fase 2 (compilador en Zig).

---

## 1. Pipeline implementado

```
.astra ─▶ Lexer ─▶ Parser ─▶ Type Checker ─▶ Emitter ─▶ Bytecode ─▶ VM
          lexer.c  parser.c  typechecker.c    emitter.c               vm.c
```

Todos los componentes están conectados y el binario `seed/astra-seed` ejecuta
programas Astra-0 de principio a fin.

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
| Runner de tests | ✅ | `tests/run_tests.sh` (`EXPECT` / `EXPECT-ERROR`) |

## 2. Lenguaje soportado (Astra-0)

### Tipos
`i32`, `f64`, `bool`, `string`, arrays (`[T]`), structs (declaración, literal,
acceso a campo), enums unitarios (`Enum.Variant`) y `void`.

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
- `match` como expresión (con `or`-patterns `A | B | C` y wildcard `_`)
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
- Igualdad estructural para arrays y structs (mismo tipo de struct + campos)
- Builtin `print(...)` (variádico)
- Errores de runtime con número de línea

## 3. Estado de la suite de tests

`make test` ejecuta `seed/tests/run_tests.sh`, que descubre los archivos de
`seed/tests/conformance/` y valida su salida contra las anotaciones:

```astra
// EXPECT: <línea de salida>          (repetible)
// EXPECT-ERROR: <texto de error>     (el programa debe fallar)
```

La suite arranca con la puerta del registro (`--check-constructs`) y sigue con
los casos de conformidad. Cobertura actual (33 casos, todos en verde):

| Área | Casos |
|:-----|:------|
| registro | invariantes de constructos, palabras clave y tabla de operadores |
| expressions | `arithmetic` (precedencia, unarios, `%`) |
| control | `if_else`, `while_break`, `while_continue` |
| loops | `range_exclusive`, `range_inclusive`, `break_continue`, `for_array` |
| arrays | `literal_index` |
| structs | `literal_fields`, `field_order`, `struct_in_function` |
| blocks | `tail_expression`, `if_value` |
| enums | `match_variants`, `or_patterns`, `enum_print`, `match_statement`, `match_block_arm` |
| functions | `recursion` (factorial + parámetros), `implicit_return` |
| ui | `type_mismatch`, `break_outside_loop`, `struct_missing_field`, `struct_unknown_field`, `struct_field_type`, `match_non_exhaustive`, `enum_unknown_variant`, `match_pattern_type`, `match_guard_unsupported`, `void_initializer`, `missing_return_value` |

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
| C | Retorno implícito de función | `fn f() -> i32 { 42 }` → `nil` | ✅ `42` |
| C | Tipo de retorno declarado sin valor | `fn f() -> i32 { }` → `nil` | ✅ error de compilación |
| B | `LValue` acotado a identificadores | `xs[0] = 9;` → error de parseo | ⛔ pendiente |
| B | Mismo caso en campos | `p.x = 5;` → error de parseo | ⛔ pendiente |

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

Hallazgo B en cambio tiene una causa localizada: `parse_assignment` rechaza
todo lo que no sea `NODE_IDENT`.

## 4. Pendiente para completar la Fase 1

Ordenado por valor para el objetivo de bootstrap.

### Agregados (bloquea el compilador auto-hospedado)
- [x] **Structs**: literal, valor `VAL_STRUCT`, acceso a campo por nombre en
      codegen, igualdad estructural e impresión.
- [x] **Enums unitarios**: `enum Color { Rojo Verde }`, `Enum.Variant` como
      expresión, `VAL_ENUM`, igualdad e impresión `Color.Rojo`.
- [x] **match**: `NODE_MATCH` en parser/AST, `or`-patterns, wildcard,
      exhaustividad y codegen por comparación de variante.
- [ ] **Enums con datos** (ADT): `Circulo(Float)`, bindings en patrones,
      patrones anidados. Ver `research/04` §9.3.
- [ ] **Guards** `patrón if cond` (hoy el parser los rechaza explícitamente).
- [ ] `Option<T>` / `Result<T, E>` y el operador `?`.

### Closures y módulos
- [ ] Lambdas `|x| ...` (Tier 2 del MVP).
- [ ] Cierre de variables capturadas.

### Sistema de tipos
- [ ] Genéricos básicos por monomorfización (Tier 3).
- [ ] Traits con despacho simple (Tier 3).
- [ ] Unidades de medida (fuera del alcance del seed).

### Arquitectura interna
- [x] **Registro de constructos**: un archivo por producción EBNF, con gramática
      y cita de investigación obligatorias, y 14 invariantes verificadas
      automáticamente. Ver `CONSTRUCT_REGISTRY.md` y `MULTI_AGENT_SETUP.md`.
- [ ] **Migrar los hooks** `parse` / `emit` / `check` a los archivos de
      constructo, fase por fase. Hoy el registro describe los 44 constructos
      pero no ejecuta ninguno (`migrated: 0 / 44`); la migración empieza por
      `if` + `else`, que es el par que motivó el diseño.

### Tooling
- [ ] Subcomando `--emit-c` (ruta de bootstrap a C del diseño original).
- [ ] `--dump-bytecode` como flag estable (hoy vía `ASTRA_DUMP_VM`).
- [ ] Fuzzing del lexer/parser (`clang -fsanitize=fuzzer`).
- [ ] CI multiplataforma (Linux/macOS/Windows).

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
