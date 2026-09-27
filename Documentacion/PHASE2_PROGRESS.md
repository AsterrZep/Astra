# Astra — Phase 2 Implementation Status (Zig compiler)

Estado del **compilador auto-hospedado en Zig** (`zig/`), la Fase 2 del plan de
bootstrap. Sustituye al compilador semilla en C (`seed/`, ver
`PHASE1_PROGRESS.md`) y apunta al lenguaje Astra completo.

> **Regla de paridad**: el compilador Zig debe aceptar **el mismo lenguaje** que
> el seed antes de crecer. `PHASE2_KICKOFF.md` lo fija como puerta: portar la
> suite existente (89 casos) antes de añadir genéricos, traits, etc.

---

## 1. Estado actual (2026-09-27)

**Frontend (lexer + AST + parser) de Astra-0 portado y verificado.**

```
.astra ─▶ Lexer ─▶ Parser ─▶ AST          [implementado]
                              │
                              ├─▶ Type Checker   [pendiente]
                              ├─▶ Emitter        [pendiente]
                              └─▶ VM             [pendiente]
```

| Componente | Estado | Notas |
|:-----------|:-------|:------|
| Lexer (`src/lexer/lexer.zig`) | ✅ | Tokens de Astra-0 alineados con `seed/src/lexer.c`: keywords, `_`, `newline`, bases hex/bin/oct, `1_000`, escapes, comentarios `//` y `/* */`, rangos `..`/`..=` |
| AST (`src/ast/ast.zig`) | ✅ | Nodos **planos** `union(Tag)` con índices `u32`, buffer `extra` compartido para listas (`PHASE2_RESEARCH.md` §1.3/§1.5) |
| Parser (`src/parser/parser.zig`) | ✅ | Descenso recursivo + Pratt; sentencias terminadas por `;`/newline; bloques con tail-expr; `if`/`while`/`for`/`match`/patrones; structs; enums unitarios y con datos; lambdas; tipos (`T?`, `[T]`, `fn(P)->R`); `some`/`none`/`ok`/`err`; `?` |
| Driver (`src/main.zig`) | ✅ | Lee un fichero; `--dump-tokens`, `--dump-ast`; salida 1 en error de sintaxis |
| Type checker / Emitter / VM | ⬜ | Directorios creados, sin implementación |

### Verificación medida

- **52/52** ficheros no-UI de `seed/tests/conformance/` parsean sin error.
- **6/23** ficheros `ui/` son rechazados por el parser: exactamente los que la
  Fase 1 clasifica como errores **de parseo** (`struct_comma_body`,
  `enum_comma_body`, `nesting_too_deep`, `block_nesting_too_deep`,
  `integer_literal_out_of_range`, `unterminated_string`). El resto son errores
  de tipos y el parser debe aceptarlos (aún no hay type checker).
- **17 pruebas unitarias** (lexer, AST, parser, conformance) en `zig build test`.

---

## 2. Cómo construir y verificar

Requiere **Zig 0.16.x**. En este entorno el binario vive en `~/zig/zig`.

```bash
cd zig
zig build                 # -> zig-out/bin/astra-zig
zig build test            # 17 unit tests + conformance sobre seed/tests/conformance
zig build -Doptimize=ReleaseFast

# Introspección
./zig-out/bin/astra-zig file.astra            # parse check (salida 1 si falla)
./zig-out/bin/astra-zig --dump-tokens file.astra
./zig-out/bin/astra-zig --dump-ast file.astra
```

---

## 3. Decisiones de diseño (y por qué)

1. **AST plano con índices `u32` y buffer `extra`.** Lo recomienda
   `PHASE2_RESEARCH.md` §1.3/§1.5 (diseño del propio compilador de Zig:
   localidad de caché, serialización trivial, arena-friendly) y es lo que el
   esqueleto previo ya intentaba. El stub anterior guardaba `start = 0` en
   **todas** las listas, así que cada lista apuntaba al nodo 0 y el árbol no
   podía representar un programa; ahora cada lista es un tramo real del buffer
   `extra`.
2. **El salto de línea es un token y termina una sentencia** (`research/010`
   §4.2). Sin esto no compila `lambda_basic.astra`, que no tiene ni un `;`.
   `optionalSemi()` consume `;` y newlines y recuerda si hubo un `;` real: eso
   distingue el valor de bloque de `{ 7 }` del vacío de `{ 7; }`.
3. **El parser es la frontera de confianza.** `PARSER_MAX_DEPTH = 256` guarda
   tanto la entrada de expresión como la de bloque (los bloques anidados llegan
   por otro camino), igual que el seed tras el hallazgo S3.
4. **Paridad de tokens con el seed.** La tabla de keywords es copia literal de
   `seed/src/lexer.c`; el lexer emite `and`/`or`/`not`, `some`/`none`/`ok`/`err`,
   `option`/`result`, `use`/`mod`, `val`, etc. Un test de conformidad cruzada
   podrá comparar los dos lexers cuando exista el equivalente a
   `--check-constructs`.
5. **Fallo rápido por ahora.** El primer error de sintaxis aborta el parseo y se
   registra el mensaje. La recuperación a nivel de sentencia (como el seed) es
   una mejora posterior, no un requisito de paridad: `research/011` la sitúa en
   "phrase-level, no sobre-ingenierada".

### APIs de Zig 0.16 relevantes

Zig 0.16 cambió bastante la stdlib; el código usa:

- `main(init: std.process.Init)` con `init.gpa`, `init.io`,
  `init.minimal.args.toSlice(...)`.
- `std.Io.Dir.cwd()`, `dir.readFileAlloc(io, path, gpa, .limited(n))`,
  `dir.walk(gpa)` + `walker.next(io)`.
- `std.Io.Writer.fixed(buf)` y `w.buffered()` para ensamblar salida.
- `std.heap.DebugAllocator`, `std.ArrayListUnmanaged(T)` con `.empty` y
  `append(alloc, x)`.

---

## 4. Siguiente trabajo

Ordenado por dependencia y valor para el bootstrap.

| # | Tarea | Estado | Notas |
|:-:|:------|:-------|:------|
| 1 | **Type checker** portado (`typechecker.c` → Zig) | ⬜ | tabla de símbolos con ámbitos, igualdad estructural, literales enteros polimórficos (`TYPE_INT_LITERAL`), exhaustividad de `match`, `?` sobre optional |
| 2 | **Emitter + bytecode** (`emitter.c` → Zig) | ⬜ | modelo de altura de pila verificado (la causa raíz de los hallazgos A/C de Fase 1); parcheo de saltos `offset = T - P` |
| 3 | **VM** (`vm.c` → Zig) | ⬜ | ~30 opcodes, frames, globals, builtins; mismos textos de error que el seed |
| 4 | **Runner de conformance con ejecución** | ⬜ | replicar `EXPECT` / `EXPECT-ERROR` / `EXPECT-RUNTIME-ERROR` y comparar salida con la VM del seed |
| 5 | Errores con recuperación a nivel de sentencia | ⬜ | mejores diagnósticos; no bloquea |
| 6 | `--dump-tokens` / `--dump-ast` con paridad de formato | 🟡 | hoy el formato es propio; la comparación es por aceptación, no por texto |

---

## 5. Relación con la documentación de la Fase 2

- `PHASE2_KICKOFF.md` — plan y checklist originales (el lexer/parser/AST son los
  pasos 2–4; este documento los cierra para Astra-0).
- `PHASE2_IMPL_PLAN.md` — estructura de módulos; el esquema de carpetas
  `lexer/`, `ast/`, `parser/`, `typechecker/`, `emitter/`, `vm/` se respeta.
- `PHASE2_RESEARCH.md` — guía de arquitectura (IRs planas, InternPool,
  monomorfización, ARC/ORC, integración LLVM). Es la referencia para las fases
  siguientes.
- `PHASE2_GAP_ANALYSIS.md` — inventario de lo que falta para el lenguaje
  completo (genéricos, traits, comptime, módulos, FFI…).
- `research/010`, `research/011`, `research/012` — gramática, diseño del seed y
  backend C, que siguen siendo la especificación de comportamiento.
