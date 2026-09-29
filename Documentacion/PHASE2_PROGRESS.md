# Astra — Phase 2 Implementation Status (Zig compiler)

Estado del **compilador auto-hospedado en Zig** (`zig/`), la Fase 2 del plan de
bootstrap. Sustituye al compilador semilla en C (`seed/`, ver
`PHASE1_PROGRESS.md`) y apunta al lenguaje Astra completo.

> **Regla de paridad**: el compilador Zig debe aceptar **el mismo lenguaje** que
> el seed antes de crecer. `PHASE2_KICKOFF.md` lo fija como puerta: portar la
> suite existente (93 casos) antes de añadir genéricos, traits, etc.

---

## 1. Estado actual (2026-09-29)

**El compilador Astra-0 completo (frontend + emitter + VM) está portado y
verificado: compila y ejecuta la suite del seed con salida idéntica.**

```
.astra ─▶ Lexer ─▶ Parser ─▶ AST ─▶ Type Checker ─▶ Emitter ─▶ Bytecode ─▶ VM
                                      [implementado]        [implementado]
```

| Componente | Estado | Notas |
|:-----------|:-------|:------|
| Lexer (`src/lexer/lexer.zig`) | ✅ | Tokens de Astra-0 alineados con `seed/src/lexer.c`: keywords, `_`, `newline`, bases hex/bin/oct, `1_000`, escapes, comentarios `//` y `/* */`, rangos `..`/`..=` |
| AST (`src/ast/ast.zig`) | ✅ | Nodos **planos** `union(Tag)` con índices `u32`, buffer `extra` compartido para listas (`PHASE2_RESEARCH.md` §1.3/§1.5) |
| Parser (`src/parser/parser.zig`) | ✅ | Descenso recursivo + Pratt; sentencias terminadas por `;`/newline; bloques con tail-expr; `if`/`while`/`for`/`match`/patrones; structs; enums unitarios y con datos; lambdas; tipos (`T?`, `[T]`, `fn(P)->R`); `some`/`none`/`ok`/`err`; `?`; declaraciones de módulo `use`/`import`/`from` con rutas punteadas (ver §7) |
| Type checker (`src/typechecker/typechecker.zig`) | ✅ | Tabla de símbolos con ámbitos (borrado por secuencia de inserción), literales enteros polimórficos, igualdad estructural, exhaustividad de `match`, `?` sobre optional, mutabilidad de lvalues, `Option`/`Result` builtin |
| Emitter (`src/emitter/emitter.zig`) | ✅ | Baja el AST a bytecode: modelo lineal de altura de pila con asertos por nodo, parcheo de saltos `offset = T - P`, frames con slot 0 para el retorno, `match`/`for`/`if`/lambdas, construcción de structs y enums |
| VM (`src/vm/vm.zig`) | ✅ | ~48 opcodes, frames de llamada, globals, builtins (`print`), `Option`/`Result` y `?`; mismos textos de error que el seed; salida de floats con `%g` de C |
| Driver (`src/main.zig`) | ✅ | Por defecto compila **y ejecuta**; `--dump-tokens`, `--dump-ast`, `--dump-modules`, `--dump-bytecode`; salida 1 ante error de compilación o de runtime |
| Módulos (`src/modules/modules.zig`) | 🟡 | Esbozo del paso 2: `ImportPath` → fichero (reglas 1–2 de `ARCHITECTURE.md` §10.4), `ModuleTable` y nombres explícitos. Sin cargador de ficheros (ver §7.1) |

### Verificación medida

- **54/54** ficheros no-UI de `seed/tests/conformance/` se compilan **y se
  ejecutan** en la VM con una salida idéntica a la del seed (comparada fichero
  a fichero). Los 4 casos `EXPECT-RUNTIME-ERROR` fallan con el mismo mensaje
  que el seed y sin volcar nada a stdout.
- **26/26** ficheros `ui/` son rechazados. El emitter cierra
  `break_outside_loop`, que el type checker deja pasar a propósito.
- **45 pruebas unitarias** (lexer, AST, parser, type checker, emitter, bytecode,
  VM, módulos, depurador y conformance) en `zig build test`.

---

## 2. Cómo construir y verificar

Requiere **Zig 0.16.x**. En este entorno el binario vive en `~/zig/zig`.

```bash
cd zig
zig build                 # -> zig-out/bin/astra-zig
zig build test            # 39 unit tests + conformance (compila y ejecuta) sobre seed/tests/conformance
zig build -Doptimize=ReleaseFast

# Introspección
./zig-out/bin/astra-zig file.astra            # compila y ejecuta (salida 1 si falla)
./zig-out/bin/astra-zig --dump-tokens file.astra
./zig-out/bin/astra-zig --dump-ast file.astra
./zig-out/bin/astra-zig --dump-bytecode file.astra
./zig-out/bin/astra-zig --debug file.astra    # depurador de bytecode (breakpoints/step)

# Depuración de bajo nivel (mismos nombres que el seed)
ASTRA_DUMP_VM=1 ./zig-out/bin/astra-zig file.astra   # bytecode + cuerpo de cada llamada
ASTRA_TRACE=1   ./zig-out/bin/astra-zig file.astra   # traza de pila por instrucción
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
5. **Recuperación a nivel de sentencia.** El bucle del módulo captura el error
   de una declaración, sincroniza (el mismo conjunto de tokens que el seed:
   `;`, `}`, `fn`, `let`, `if`…) y sigue parseando, de modo que un fichero con
   dos declaraciones malas reporta las dos, como el seed. El árbol solo se
   entrega si el parseo queda limpio; cualquier error sigue siendo un fallo duro
   (`exit 1`). Un detalle del seed que hay que copiar con cuidado: en C
   `parse_statement` consume el `;` con `optional_semi` incluso tras error; en
   Zig el error se propaga antes, así que la recuperación avanza un token si
   `synchronize` se detuvo donde ya estaba (si no, el bucle giraría sin fin).
   `research/011` la sitúa en "phrase-level, no sobre-ingenierada" y eso es lo
   que hay: sincronización por sentencia, sin recuperación intra-expresión.

### APIs de Zig 0.16 relevantes

Zig 0.16 cambió bastante la stdlib; el código usa:

- `main(init: std.process.Init)` con `init.gpa`, `init.io`,
  `init.minimal.args.toSlice(...)`.
- `std.Io.Dir.cwd()`, `dir.readFileAlloc(io, path, gpa, .limited(n))`,
  `dir.walk(gpa)` + `walker.next(io)`.
- `std.Io.Writer.fixed(buf)` y `w.buffered()` para ensamblar salida.
- `std.Io.File.stdout()` y `file.writer(io, buf)` → se pasa `&file_writer.interface`
  (campo `std.Io.Writer`) a la VM y se hace `flush()` al terminar.
- `std.heap.DebugAllocator`, `std.ArrayListUnmanaged(T)` con `.empty` y
  `append(alloc, x)`.

---

## 4. Siguiente trabajo

Ordenado por dependencia y valor para el bootstrap.

| # | Tarea | Estado | Notas |
|:-:|:------|:-------|:------|
| 1 | **Type checker** portado (`typechecker.c` → Zig) | ✅ | Verificado: 53/53 no-UI limpios, 23/24 UI rechazados (el 24, `break`, lo cierra el emitter) |
| 2 | **Emitter + bytecode** (`emitter.c` → Zig) | ✅ | modelo de altura de pila verificado (la causa raíz de los hallazgos A/C de Fase 1); parcheo de saltos `offset = T - P`; incluye el chequeo de `break`/`continue` fuera de bucle |
| 3 | **VM** (`vm.c` → Zig) | ✅ | 48 opcodes, frames, globals, builtins; mismos textos de error que el seed. La salida de floats replica `printf("%g")` (ver §6) |
| 4 | **Runner de conformance con ejecución** | ✅ | `zig build test` ejecuta cada caso no-UI y compara `EXPECT:` / `EXPECT-RUNTIME-ERROR:`; los `ui/` deben fallar al compilar |
| 5 | Errores con recuperación a nivel de sentencia | ✅ | el módulo reporta varios errores por pase; verificado contra el seed (2 declaraciones malas → 2 errores) |
| 6 | `--dump-tokens` / `--dump-ast` con paridad de formato | 🟡 | hoy el formato es propio; la comparación es por aceptación, no por texto |
| 7 | **Depurador de bytecode** (`--debug`) | ✅ | breakpoints por línea Astra, `step`, pila/locales/frames; resuelve la decisión §12.5-2 de `PHASE2_GAP_ANALYSIS.md` (construirlo con la VM, sin esperar a LLVM) |
| 8 | **Módulos (Fase 2.2) — paso 1**: `use`/`import`/`from` en lexer y parser | ✅ | rutas punteadas (`.`, no `::`); nodos `use_decl`/`import_decl`/`from_decl`/`import_item`; el seed reconoce ya las mismas tres formas; sin resolución todavía. Ver §7 |
| 9 | **Módulos — paso 2**: tabla de módulos y resolución de rutas | 🟡 | esbozo en `src/modules/modules.zig`: ruta relativa → fichero, `ModuleTable` y nombres explícitos, con `--dump-modules`. Sin cargador de ficheros ni resolución de referencias. Ver §7.1 |

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
  completo (genéricos, traits, comptime, módulos, FFI…). Su **§12** fija el plan
  de *debugging e inspección de bajo nivel* (flags `--emit-llvm`/`--emit-asm`,
  DWARF, depurador de bytecode) y las decisiones abiertas; el backend nativo
  está en su §11 (fase 2.6).
- `research/010`, `research/011`, `research/012` — gramática, diseño del seed y
  backend C, que siguen siendo la especificación de comportamiento.

---

## 6. Notas del port de la VM (`vm.c` → `zig/src/vm/vm.zig`)

La VM se comporta como la del seed; tres detalles merecen quedar por escrito
porque son fáciles de romper sin que la suite lo note a simple vista:

1. **El objetivo de un salto es `ip + offset`.** El seed hace `ip += offset;
   ip--` y el bucle luego `ip++`, lo que da `P + offset`. El port paso de
   índice calcula el destino con una suma **con signo** (`jumpTarget`) para no
   envolver los offsets negativos de `continue`.
2. **La pila por debajo de `sp` es el frame.** `base` es un índice de slot, no
   un contador de 8 bits: recortarlo a `u8` fue el bug S8 de la Fase 1 (más de
   ~127 llamadas anidadas leían el slot equivocado). El port usa `usize`.
3. **Los textos de error son contrato.** `run_tests.sh` compara subcadenas de
   `EXPECT-RUNTIME-ERROR`, así que los mensajes se copian literalmente.

El modo de depuración del seed también está portado: `ASTRA_DUMP_VM=1` vuelca el
bytecode del módulo y de cada función llamada, y `ASTRA_TRACE=1` imprime
`sp=/base=/frame=` más la pila (hasta 20 valores) tras cada instrucción. A
diferencia del seed — que deja los valores en stdout y los corchetes en stderr,
partiendo cada línea — aquí todo va a stderr.

### Depurador de bytecode (`--debug`)

`./zig-out/bin/astra-zig --debug file.astra` da un depurador interactivo sobre
la VM (sin LLVM): se detiene en la entrada y acepta comandos por stdin.

```
c | continue     corre hasta el siguiente breakpoint (o el final)
s | step         ejecuta una instrucción
b | break        lista los breakpoints
b <line>         pone un breakpoint en una línea Astra
d <line>         quita un breakpoint
stack | p        pila de operandos
locals | l       slots del frame actual
bt               frames de llamada
h | help / q | quit
```

La salida del depurador va a stderr (la del programa, a stdout). No necesita
información adicional del emitter: usa el `line` que ya lleva cada instrucción.
Al reanudar con `continue` se suprime el resto de la misma línea para no parar
una vez por instrucción de una sentencia.

Además, la salida no va por `printf` sino por un `std.Io.Writer`: el CLI escribe
a stdout (`std.Io.File.stdout()` con su campo `.interface`) y la suite captura
la salida en un buffer fijo, de modo que nada se cuela por la salida del proceso
de test.

### Formato de floats: `%g`, no el de Zig

El seed imprime todo float con `printf("%g", …)` (`value_print`). El formato
por defecto de Zig (`{}`/`{d}`) es *shortest round-trip*, no `%g`: para
`3.14159265358979` imprime todos los dígitos donde C imprime `3.14159`, y nunca
pasa a notación científica. Para que VM, volcado de bytecode y backend C den el
mismo texto, `bytecode.writeFloatG` implementa la regla de C99 §7.21.6.1
(formatear con estilo `e` para hallar el exponente redondeado `X`; si
`-4 <= X < P` usar estilo `f` con `P-1-X` decimales, si no estilo `e` con `P-1`;
quitar ceros finales).

---

## 7. Módulos (Fase 2.2) — paso 1: lexer y parser

Primer paso del sistema de módulos, todavía **sólo en el frontend**: el lexer
reconoce `import`/`from`/`as` y el parser construye los nodos de la gramática de
`research/010` §12.1 (`use_decl`, `import_decl`, `from_decl` e `import_item`). El
type checker los trata como `void` y el emitter como declaraciones sin efecto,
igual que el seed: **la resolución de módulos no existe todavía**; esto sólo fija
la superficie sintáctica del lenguaje.

```
ExportStmt ::= "use" ImportPath
ImportStmt ::= "import" ImportPath ("as" Identifier)?
             | "from" ImportPath "import" ImportItem ("," ImportItem)*
ImportPath ::= Identifier ("." Identifier)*
ImportItem ::= Identifier ("as" Identifier)?
```

**Decisión: el separador de ruta es `.`, no `::`.** Los tres documentos de
diseño (`research/010` §12.1, `ARCHITECTURE.md` §10) y todos los ejemplos de
módulos del repositorio usan la forma punteada (`import geometry.mesh`,
`from geometry.vector import Vec2, add`, `std.os.linux`); `::` sólo aparece en
fragmentos de *comparación con Rust*, nunca en código Astra. Además `.` ya es el
separador de caminos del resto del lenguaje (`Color.Rojo`, `s.field`). El seed
había derivado a `::` en `parse_use` mientras su propia gramática decía `.`, así
que se corrigió el seed y los dos compiladores coinciden ahora. La decisión queda
fijada por `seed/tests/conformance/ui/use_colon_colon.astra` y por un test unitario
del parser Zig, y cierra la pregunta App. B #6 de `PHASE2_GAP_ANALYSIS.md`.

El port destapó de paso que **`use` nunca había funcionado** en el seed: el type
checker no tenía caso para `NODE_USE`, así que toda declaración moría con
`unhandled node kind 46` (S18 en `PHASE1_PROGRESS.md` §6.5). Corregido allí, junto
con el separador (S19).

**El seed ya tiene la misma superficie (2026-09-29).** Este paso dejó al parser
Zig por delante: `import` y `from` no existían como tokens en el seed, que los
registraba como constructos fuera de Astra-0 (`keyword = NULL`). Eso convertía al
Zig en un superconjunto —permitido por la regla de paridad, pero en la dirección
que no interesa mantener—, así que el seed reconoce ahora `import`/`from`/`as`:
tres constructos nuevos en el registro (46 en total) y un único
`parse_module_path` compartido por `import` y `from`, para que las dos formas no
puedan divergir del `use` que ya existía. Sigue sin haber resolución de módulos,
igual que en el Zig: en ambos compiladores la declaración se parsea y se
descarta.

Dos casos nuevos cubren la superficie en el seed: `module/import_from.astra` (las
tres formas, con `as`) y `ui/from_without_items.astra` (`from a.b import` sin
ningún item, que antes se aceptaba como una lista vacía silenciosa). La paridad
medida sube a **54/54 no-UI y 25/25 UI**.

Lo que falta para un sistema de módulos de verdad (paso 2) está ya enumerado en
`PHASE2_GAP_ANALYSIS.md` §5.1: tabla de módulos, visibilidad `pub`, compilación
multifichero y resolución de referencias cruzadas.

### 7.1 Paso 2 (esbozo): resolución de rutas y tabla de módulos

`zig/src/modules/modules.zig` es lo primero del port que **no tiene contrapartida
en C**: el seed compila un fichero y no carga nada (`research/011` §5.2), así que
la paridad no dice nada de este terreno. Hace cuatro cosas y ninguna más.

**Ruta → fichero.** Sólo las reglas 1 y 2 de `ARCHITECTURE.md` §10.4 (relativa y
sub-ruta): `mesh` → `mesh.astra`, `geometry.mesh` → `geometry/mesh.astra`,
relativo al directorio del fichero que importa. El sufijo `.astra` se añade sólo
al último segmento (`a.b.c` → `a/b/c.astra`, no `a/b/c/.astra`). Las reglas 3 y 4
(`@/utils/logger` desde la raíz de `astra.toml`, `std/io` de la stdlib) quedan
aplazadas a propósito: no existe ni `astra.toml` ni stdlib, y las dos escriben sus
raíces con `/`, un separador que el lenguaje ya no usa. Inventar una grafía
punteada para una raíz que nadie ha definido sería inventar lenguaje, no
implementarlo.

**Segmentos revalidados.** `pathToFile` comprueba cada segmento contra la regla
del lexer (letra o `_`, luego alfanumérico) aunque el parser ya lo garantice:
aquí es donde una ruta de módulo se convierte en un nombre de fichero, y `a/b` o
`..` que llegasen de cualquier otro sitio serían una travesía de rutas. Es la
única frontera entre un identificador del fuente y el sistema de ficheros.

**Tabla de módulos.** `collect` convierte el AST de un fichero en una
`ModuleTable`: cada declaración con la ruta escrita y el fichero al que apunta,
con `find` como índice. Sólo nivel de módulo (un `import` anidado en un cuerpo de
función se ignora; ver `PHASE1_PROGRESS.md` §6.7).

**Nombres explícitos.** `explicitBindings` lista los nombres que el fichero
introduce **cuando la gramática los dice**: el alias de `import … as x` y los
items de `from … import a, b as c`. Lo que ata un `import a.b` a secas no está
especificado en ningún sitio —`ARCHITECTURE.md` §10.5 escribe `import utils` y
luego `utils.Logger.info(…)`, lo que sugiere el primer segmento, pero para
`import geometry.mesh` ni eso— así que el módulo no lo adivina: es una pregunta
abierta en `PHASE2_GAP_ANALYSIS.md` App. B.

`astra-zig --dump-modules fichero.astra` imprime la tabla para comprobarlo a mano
(el fichero se resuelve relativo a su propio directorio, como referencia):

```
modules (src/main.astra): 4 declaration(s)
  import std.io -> src/std/io.astra
  import geometry.mesh -> src/geometry/mesh.astra as mesh
  from geometry.vector -> src/geometry/vector.astra [binds Vec2, add as sum]
  use a.b.c -> src/a/b/c.astra
```

Sin cargador: no se abre ningún fichero, no hay tabla de símbolos por módulo, ni
resolución de referencias cruzadas, ni `pub`, ni detección de ciclos
(`ARCHITECTURE.md` §10.5–§10.6). Eso es el resto de `PHASE2_GAP_ANALYSIS.md` §8.3.
