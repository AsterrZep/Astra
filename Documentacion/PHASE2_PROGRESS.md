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
| Type checker (`src/typechecker/typechecker.zig`) | ✅ | Tabla de símbolos con ámbitos (borrado por secuencia de inserción), literales enteros polimórficos, exhaustividad de `match`, `?` sobre optional, mutabilidad de lvalues, `Option`/`Result` builtin. Los tipos viven en un **pool hash-consed** (`src/typechecker/types.zig`): identidad canónica por estructura (struct/enum por nombre), `typeEq` con fast-path de puntero y las reglas de unificación del seed (`unknown`/`nil`/`int_literal`) recursivas dentro de compuestos |
| Emitter (`src/emitter/emitter.zig`) | ✅ | Baja el AST a bytecode: modelo lineal de altura de pila con asertos por nodo, parcheo de saltos `offset = T - P`, frames con slot 0 para el retorno, `match`/`for`/`if`/lambdas, construcción de structs y enums, **closures** (análisis de variables libres sobre el árbol plano, captura por valor con `closure`/`get_capture`; asignar a una capturada es error de compilación) |
| VM (`src/vm/vm.zig`) | ✅ | ~50 opcodes, frames de llamada, globals, builtins (`print`), `Option`/`Result` y `?`; **closures** (`closure` clona el FnObj plantilla con el env capturado; `get_capture` lee `stack[base]`, que guarda el callee durante toda la llamada); mismos textos de error que el seed; salida de floats con `%g` de C |
| Driver (`src/main.zig`) | ✅ | Por defecto compila **y ejecuta**; `--dump-tokens`, `--dump-ast`, `--dump-modules`, `--dump-bytecode`; salida 1 ante error de compilación o de runtime. Diagnósticos por fase ruteados a un sink único (`src/diagnostics.zig`, §7.4) |
| Diagnósticos (`src/diagnostics.zig`) | ✅ | Registro `Diagnostic{file, span, msg}` con un único formato `file:line:col: error: msg` (degrada a `file:line:` / `file:` / `error:`); parser, type checker, emitter y loader emiten a través de él; las fases sin sink imprime directo con el mismo formato |
| Módulos (`src/modules/` + driver) | 🟡 | Carga, gating `pub` y compilación multi-módulo en el CLI Zig (§7.3): `import`/`from` resuelven (reglas 1–2), imports tipados contra los exports del módulo exportador, globals manglados y ejecución en orden de dependencias. Faltan re-exports (`use`), raíces `@/`/`std/` (§7.1) y valores de structs/enums foráneos |

### Verificación medida

- **57/57** ficheros no-UI de `seed/tests/conformance/` se compilan **y se
  ejecutan** en la VM con una salida idéntica a la del seed (comparada fichero
  a fichero). Los 4 casos `EXPECT-RUNTIME-ERROR` fallan con el mismo mensaje
  que el seed y sin volcar nada a stdout.
- **29/29** ficheros `ui/` son rechazados. El emitter cierra
  `break_outside_loop` y la asignación a una variable capturada
  (`capture_assign`), que el type checker deja pasar a propósito.
- **60 pruebas unitarias** (lexer, AST, parser, type checker, types, emitter,
  bytecode, VM, módulos, depurador, link multi-módulo, diagnósticos y
  conformance) en `zig build test`.

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
| 9 | **Módulos — paso 2**: resolución de rutas, tabla de módulos y cargador | ✅ | Carga, exports `pub`, gating y compilación multi-módulo en el CLI (§7.3). Faltan re-exports (`use`) y raíces `@/`/`std/` (§7.1) |
| 10 | **InternPool de tipos** (substrato de genéricos) | ✅ | `src/typechecker/types.zig`: pool hash-consed con identidad canónica (struct/enum por nombre); `typeEq` = fast-path de puntero + reglas de unificación del seed recursivas en compuestos (`array(int_literal)` ≡ `[]i32`); fn sin retorno anotado normalizado a `void` (paridad con `a.ret orelse voidType` del seed). 53/53 tests. Sustituye el diseño "un heap-node por ocurrencia" (`PHASE2_ARCHITECTURE.md` §3.3) |
| 11 | **Colección de declaraciones** (forward-refs de tipo) | ✅ | Pase 0 en ambos compiladores (`typecheck_module_pass`/`checkModule`): registra nombres de struct/enum con layout vacío antes de resolver firmas y fields, así las declaraciones se referencian en cualquier orden (incl. recursión mutua). Caso nuevo `types/forward_type_refs.astra`; suite 96/96 seed, 53/53 zig. Los structs anidados en cuerpos de función siguen sin funcionar (paridad — ya fallaban igual antes) |

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
medida sube a **54/54 no-UI y 26/26 UI**.

Lo que falta para un sistema de módulos de verdad (paso 2) está ya enumerado en
`PHASE2_GAP_ANALYSIS.md` §5.1: tabla de módulos, visibilidad `pub`, compilación
multifichero y resolución de referencias cruzadas.

### 7.1 Paso 2 (esbozo): resolución de rutas, tabla de módulos y cargador

`zig/src/modules/modules.zig` es lo primero del port que **no tiene contrapartida
en C**: el seed compila un fichero y no carga nada (`research/011` §5.2), así que
la paridad no dice nada de este terreno. Hace cuatro cosas y ninguna más.

**Ruta → fichero.** Sólo las reglas 1 y 2 de `ARCHITECTURE.md` §10.4 (relativa y
sub-ruta): `mesh` → `mesh.astra`, `geometry.mesh` → `geometry/mesh.astra`, ambas
relativas al directorio del fichero que importa. El sufijo `.astra` se añade sólo
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

**El cargador y los ciclos.** `Loader` lee el fichero al que apunta cada
declaración y sigue sus propios imports, recursivamente, construyendo un `Graph`
(**orden post-order: dependencias primero, la raíz la última**; cada fichero
aparece una sola vez aunque lo nombren diez declaraciones). El orden importa:
una futura compilación ejecuta el código de nivel de módulo módulo a módulo, y
cada uno debe correr después de todo lo que importa. Además el árbol parseado de
cada fichero **se conserva** en el `LoadedModule` (`tree` + `root`): la
compilación emitirá desde él, no sólo desde la tabla. Un ciclo es el único error
que **no se puede ver fichero a fichero** —todos los ficheros del ciclo están
bien y sólo la cadena está mal—, así que el cargador guarda la cadena de ficheros
por la que va entrando y reporta el ciclo cuando una resolución aterriza sobre
uno de ellos (`ARCHITECTURE.md` §10.6, que lo prohíbe). Los errores se cuentan en
`error_count` (mismo contrato que el type checker y el emitter): un módulo que no
existe, que no parsea o que participa en un ciclo no tira el grafo, lo deja
incompleto y lo señala. `Loader.deinit` destruye los árboles (las fuentes y rutas
son memoria de arena y las deja la arena).

`astra-zig --dump-modules fichero.astra` carga el grafo y lo imprime, con los
errores por stderr y salida 1 si los hubo. Sobre los propios fixtures del test
(`zig/tests/modules/tree/`, que también fijan la resolución relativa: desde
`geometry/mesh.astra` un hermano se importa como `vector`, no como
`geometry.vector`):

```
module graph: 3 module(s)
  tests/modules/tree/geometry/vector.astra
    exports: leaf
  tests/modules/tree/geometry/mesh.astra
    from vector -> tests/modules/tree/geometry/vector.astra [binds Vec2]
  tests/modules/tree/main.astra
    import geometry.mesh -> tests/modules/tree/geometry/mesh.astra
```

La tabla de cada módulo incluye además su conjunto de exports: los nombres
`pub` de nivel de módulo (`fn`/`struct`/`enum`/`const`), coleccionados por
`collect` para que el resolutor pueda rechazar un import de un nombre privado
(§7.2). Todavía no se aplica ninguna visibilidad; el dump los muestra porque ya
están recogidos.

Un aviso para quien lo pruebe con la suite de conformidad: los casos no-UI son
programas de una sola pieza y sus rutas (`std.io`, `geometry.mesh`) no existen en
disco, así que `--dump-modules` sobre `module/import_from.astra` reporta los
cuatro ficheros que faltan y sale con 1. Es correcto: ese caso fija la *sintaxis*,
no un proyecto. La ruta normal (sin `--dump-modules`) no carga nada y no cambia.

Sin cargador de enlaces todavía: no hay tabla de símbolos por módulo, ni
resolución de referencias cruzadas (`ARCHITECTURE.md` §10.5). La visibilidad
`pub` ya se parsea en ambos compiladores (§7.2), pero todavía no se aplica.
Eso es el resto de `PHASE2_GAP_ANALYSIS.md` §8.3.

### 7.2 `pub`: sintaxis real en ambos compiladores

`ARCHITECTURE.md` §10.2: los items son privados por defecto y `pub` exporta
`fn`, `struct`, `enum` y `const` (no `let`/`var`, ni `use`/`import`). Antes de
este paso el lexer del seed tenía `TOKEN_PUB` pero el parser lo rechazaba
(`unexpected token in expression`) mientras el Zig lo aceptaba y lo descartaba
— una divergencia que habría congelado dos parsers distintos para siempre.

Ahora ambos registran el modificador en el AST (`is_pub` en `FnDecl`,
`StructDecl`, `EnumDecl` y `ConstDecl`):

- `pub` es cuantificable como en research/010 §12.1 (`FunctionQualifiers ::= ("pub" | ...)*`);
  `pub pub fn` se acepta y deduplica.
- `pub` seguido de cualquier otra cosa (`pub let`, `pub use`, `pub if`) es un
  error de parseo con el mismo mensaje en ambos: `'pub' can only precede fn,
  struct, enum or const`.
- `--dump-ast` lo muestra: el Zig imprime `pub fn_decl nombre`, el seed
  `PubFnDecl(nombre)`.
- Casos nuevos: `module/pub_decls.astra` (acepta y ejecuta) y
  `ui/pub_let.astra` (rechaza).

La *semántica* (dos niveles de visibilidad, gating en imports) queda para la
compilación multi-módulo: con un solo fichero `pub` y privado se comportan
igual. Se aplicó en §7.3.

### 7.3 Compilación multi-módulo (CLI Zig)

`astra-zig fichero.astra` ya compila y ejecuta programas de varios ficheros.
Cuando el fichero de entrada declara `import`/`from`, `main.zig` cambia al
paso multi-módulo (`compileAndRunMulti`):

1. **Grafo.** El `Loader` de §7.1 carga el fichero y sus imports en orden
   post-order (dependencias primero, raíz al final) con los árboles retenidos.
   Un módulo ilegible/no-parseable/cíclico falla la compilación entera —
   divergencia consciente con el seed, que ignora los imports y compila un
   fichero (la suite de conformidad no se ve afectada: `conformance.zig` usa su
   propio pipeline de un fichero).
2. **Tipos compartidos.** Un `TypePool` por compilación; cada módulo tiene su
   `TypeChecker` (`initWithPool`), de modo que un tipo exportado es el mismo
   tipo interning en todas partes (`typeEq` por puntero).
3. **Imports y gating.** El driver resuelve cada declaración de import contra
   los exports del módulo exportador: `from x import a, B as c` ata `a` y `c`
   a los tipos de los exports; `import a.b` (sin `as`) ata el **último
   segmento** como espacio de nombres de módulo (decisión #11 de
   `PHASE2_GAP_ANALYSIS.md` App. B, confirmada con el dueño del lenguaje),
   `import a.b as m` ata `m`. Un nombre que no está en los exports es un error
   de compilación (`module 'x' does not export 'y'`); un `use` (re-export) se
   rechaza con un mensaje claro por ahora. `alias.x` resuelve en los exports
   del módulo (un solo nivel — file-as-module, §10.1).
4. **Emisión.** Cada módulo lleva un prefijo `m{i}.` que mangla sus globals de
   nivel módulo (la tabla de globals de la VM es plana y por nombre), y un mapa
   de imports que traduce cada nombre importado al global real (`m0.add`, o
   `m0.` + campo para un espacio de nombres). Los builtins (`print`) no se
   manglan: sólo se manglan los nombres que el módulo declara.
5. **Ejecución.** Un `VM` por programa; cada módulo se emite (los deps sin la
   llamada a `main`, la raíz con ella) y se ejecuta en orden de dependencias —
   `vm.run` preserva la tabla de globals entre llamadas, así que los bindings
   de un módulo siguen vivos cuando corre el importador. `--dump-bytecode`
   imprime la sección de cada módulo.

Alcance y límites conocidos, todos documentados en el código:

- `fn` y `const` cruzan módulos completos (firmas, llamadas, valores).
- Structs/enums **exportados** se pueden importar para anotaciones y firmas
  (el pool es compartido), pero **construir** un valor struct/enum foráneo
  (`Vec2 { … }`, `Shape.Circle`, match sobre un enum importado) todavía no:
  el emitter lo rechaza en compile time (los `StructDef`/registros de enums
  son por módulo; extenderlos es el siguiente paso natural).
- `use`/re-exports y las raíces `@/`/`std/` (§7.1) siguen fuera.
- `--debug` sobre un programa multi-módulo mapea las líneas contra el fuente
  de la raíz para todos los módulos (limitación conocida).

Fijado por `zig/src/link.zig` (test e2e sobre los fixtures `zig/tests/link/`:
`from`, alias, import desnudo con #11, gating de `pub` privado) y verificado a
mano con `--dump-modules`/`--dump-bytecode`.

### 7.4 Diagnósticos: un sink, un formato (Zig)

Antes de este paso cada fase imprimía por su cuenta y con su propio formato:
el parser `error:{line}:{col}: {msg}` **sin el nombre del fichero** (un bug
real: en compilación multi-módulo un error de parseo no decía de qué módulo
era), el type checker `{file}:{line}:{col}: error: {msg}`, y el emitter
mezclaba `error: {msg}` sin ubicación con variantes internas. Ahora existe un
único registro y un único formato:

- `zig/src/diagnostics.zig` define `Diagnostic{file, span, msg}` y `Sink`
  (arena-backed). `emit(sink, file, span, fmt, args)` añade al sink si hay uno
  y, por ahora, lo ecoa a stderr (`echo = true` — salida idéntica a la de
  antes en la CLI); si el sink es `null`, formatea a un buffer de pila e
  imprime directo **con el mismo formato**, de modo que las fases sin cablear
  (p. ej. `conformance.zig`, que sólo mira `error_count`) no divergen.
- Formato único: `file:line:col: error: msg`, degradando a `file:line:`,
  `file:` y `error:` cuando no hay ubicación (span en ceros = "sin span").
- El parser gana `filename` (lo fija el driver o el `Loader`) y `diag`; el
  type checker, emitter y `Loader` ganan `diag: ?*Sink`. Todos los call
  sites del emitter pasan la línea real cuando existe (`self.err(ln, …)`);
  los límites globales (constantes, locals, funciones…) usan la línea del
  item declarado o 0 si no hay.
- Los errores de *driver* multi-módulo (`does not export`, `use` no
  soportado) y los del `Loader` (módulo ilegible, ciclo) también pasan por
  `emit`. Los errores de runtime y los del CLI (flags, fichero) quedan
  fuera a propósito: no son diagnósticos de compilación.
- La semántica del programa y la suite no cambian: `conformance.zig` sigue
  sin comparar texto, y el seed no se toca (el sink es solo Zig por ahora;
  portarlo al seed queda para cuando el formato se estabilice contra un
  emisor de verdad — p. ej. JSON o SARIF — y no solo a stderr).

Fijado por los tests de `diagnostics.zig` (formato degradado y
truncamiento) y verificado a mano: error de parseo con fichero
(`/tmp/err.astra:1:14: error: …`), export inexistente en multi-módulo, ciclo
(`circular import: a -> b -> a`) y `break` fuera de bucle (`file:1: error: …`).
