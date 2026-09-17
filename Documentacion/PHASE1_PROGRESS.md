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
| Parser | ✅ | descenso recursivo + Pratt; literales de array, rangos, bloques como expresión |
| Type checker | ✅ | tabla de símbolos con ámbitos; errores con ubicación |
| Emitter | ✅ | bytecode de pila, parcheo de saltos, locales ocultos de bucle |
| VM | ✅ | ~30 opcodes, frames de llamada, globals, builtins |
| Runner de tests | ✅ | `tests/run_tests.sh` (`EXPECT` / `EXPECT-ERROR`) |

## 2. Lenguaje soportado (Astra-0)

### Tipos
`i32`, `f64`, `bool`, `string`, arrays (`[T]`), `void`, tipos nombrados
(structs/enums se registran pero su codegen está pendiente).

### Expresiones
- Aritmética y comparación: `+ - * / % == != < > <= >=`
- Lógicos con **cortocircuito**: `&&` / `||`
- Bit a bit: `& | ^ << >>`
- Unarios: `-`, `!`, `~`
- Literales: enteros, flotantes, strings, `true`/`false`, `null`
- Literales de array: `[1, 2, 3]`; indexado `xs[i]`
- Rangos: `a..b` (exclusivo), `a..=b` (inclusivo)
- Llamadas a función, paréntesis, bloques como expresión

### Sentencias y control de flujo
- `let` / `let mut` con anotación de tipo opcional
- `if` / `else` (también como expresión)
- `while` con `break` / `continue` reales
- `for x in start..end`, `for x in start..=end`, `for x in array`
- `return` con y sin valor
- Funciones de nivel superior con parámetros tipados y recursión

### Runtime
- Valores: `nil`, `bool`, `int`, `float`, `string`, `array`, `fn`
- Igualdad estructural para arrays
- Builtin `print(...)` (variádico)
- Errores de runtime con número de línea

## 3. Estado de la suite de tests

`make test` ejecuta `seed/tests/run_tests.sh`, que descubre los archivos de
`seed/tests/conformance/` y valida su salida contra las anotaciones:

```astra
// EXPECT: <línea de salida>          (repetible)
// EXPECT-ERROR: <texto de error>     (el programa debe fallar)
```

Cobertura actual (12 casos, todos en verde):

| Área | Casos |
|:-----|:------|
| expressions | `arithmetic` (precedencia, unarios, `%`) |
| control | `if_else`, `while_break`, `while_continue` |
| loops | `range_exclusive`, `range_inclusive`, `break_continue`, `for_array` |
| arrays | `literal_index` |
| functions | `recursion` (factorial + parámetros) |
| ui | `type_mismatch`, `break_outside_loop` |

## 4. Pendiente para completar la Fase 1

Ordenado por valor para el objetivo de bootstrap.

### Agregados (bloquea el compilador auto-hospedado)
- [ ] **Structs**: literal `Point { x: 1, y: 2 }`, valor `VAL_STRUCT`, acceso a
      campo en codegen (el type checker ya resuelve campos).
- [ ] **Enums**: variantes con y sin datos, `Enum.Variant`, `VAL_ENUM`.
- [ ] **match**: no se parsea todavía; falta `NODE_MATCH` en el parser y
      codegen de decisión por variante.
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
