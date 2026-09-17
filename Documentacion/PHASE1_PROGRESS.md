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

Cobertura actual (26 casos, todos en verde):

| Área | Casos |
|:-----|:------|
| expressions | `arithmetic` (precedencia, unarios, `%`) |
| control | `if_else`, `while_break`, `while_continue` |
| loops | `range_exclusive`, `range_inclusive`, `break_continue`, `for_array` |
| arrays | `literal_index` |
| structs | `literal_fields`, `field_order`, `struct_in_function` |
| enums | `match_variants`, `or_patterns`, `enum_print`, `match_statement` |
| functions | `recursion` (factorial + parámetros) |
| ui | `type_mismatch`, `break_outside_loop`, `struct_missing_field`, `struct_unknown_field`, `struct_field_type`, `match_non_exhaustive`, `enum_unknown_variant`, `match_pattern_type`, `match_guard_unsupported` |

Los tests se ejecutan también bajo `make debug` (ASan + UBSan) sin fallos.

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

### Tooling
- [ ] Subcomando `--emit-c` (ruta de bootstrap a C del diseño original).
- [ ] `--dump-bytecode` como flag estable (hoy vía `ASTRA_DUMP_VM`).
- [ ] Fuzzing del lexer/parser (`clang -fsanitize=fuzzer`).
- [ ] CI multiplataforma (Linux/macOS/Windows).

## 5. Cómo continuar

Ver `AGENTS.md` para comandos y **workstreams de sub-agentes** (frontend,
semantics, codegen, runtime, tests, docs), con la propiedad de archivos y el
protocolo de handoff.

Regla de oro al tocar el emisor: **cada camino debe dejar la pila de la VM a una
altura predecible**. La mayoría de los bugs encontrados en la Fase 1
(desbalance de pila, saltos con off-by-one, slots de frame) provienen de romper
esa invariante.
