# Astra — Phase 2 Implementation Status (Zig compiler)

Estado del **compilador auto-hospedado en Zig** (`zig/`), la Fase 2 del plan de
bootstrap. Sustituye al compilador semilla en C (`seed/`, ver
`PHASE1_PROGRESS.md`) y apunta al lenguaje Astra completo.

> **Regla de paridad**: el compilador Zig debe aceptar **el mismo lenguaje** que
> el seed antes de crecer. `PHASE2_KICKOFF.md` lo fija como puerta: portar la
> suite existente (93 casos) antes de añadir genéricos, traits, etc.

---

## 1. Estado actual (2026-10-14)

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
| Módulos (`src/modules/` + driver) | 🟡 | Carga, gating `pub` y compilación multi-módulo en el CLI Zig (§7.3): `import`/`from` resuelven (reglas 1–2), imports tipados contra los exports del módulo exportador, globals manglados y ejecución en orden de dependencias. `use` (re-exports) y valores de structs/enums foráneos quedaron cubiertos (2026-10-12, §7.3); la raíz `@/` se resuelve desde `astra.toml` (App. B #10 cerrado) y `std/…` se rechaza con diagnóstico hasta que exista stdlib |

### Verificación medida

- **83/83** ficheros no-UI de `seed/tests/conformance/` se compilan **y se
  ejecutan** en la VM con una salida idéntica a la del seed (comparada fichero
  a fichero). Los casos `EXPECT-RUNTIME-ERROR` fallan con el mismo mensaje
  que el seed y sin volcar nada a stdout.
- **111/111** ficheros `ui/` son rechazados. El emitter cierra
  `break_outside_loop` y la asignación a una variable capturada
  (`capture_assign`), que el type checker deja pasar a propósito; ambos
  parsers cierran `break` con valor (`break_value`); los tres `ui/try_*`
  fijan los mensajes estáticos de `?` (§10).
- **73 pruebas** (lexer, AST, parser, type checker, types, emitter,
  bytecode, VM, módulos, depurador, link multi-módulo, diagnósticos y
  conformance) en `zig build test`.
- Gates de CI: suite seed **219/219** (194 conformance + 22 codegen +
  `--check-constructs`), paridad de dumps **111/111 ficheros, 0
  divergentes**.

---

## 2. Cómo construir y verificar

Requiere **Zig 0.16.x**. En este entorno el binario vive en `~/zig/zig`.

```bash
cd zig
zig build                 # -> zig-out/bin/astra-zig
zig build test            # 73 tests (unit + conformance: compila y ejecuta) sobre seed/tests/conformance
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
2. **El salto de línea es un token y termina una sentencia** (`research/001`
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
   `research/002` la sitúa en "phrase-level, no sobre-ingenierada" y eso es lo
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
| 6 | `--dump-tokens` / `--dump-ast` con paridad de formato | ✅ | byte-idénticos al seed: gate `zig/tests/dump_parity.sh` (job `parity` de CI) sobre conformance no-UI + codegen + `zig/tests/dump_probes/` (111 ficheros, 0 divergencias). `src/dump.zig` reimplementa el `%g` de C sin libc (tests contra gcc) y `Tag.seedName()` espeja `token_kind_name`. Mirrors lossy a propósito del seed, replicados: `Use` sin path, guard de match omitido, `CompoundAssign` sin hijos |
| 7 | **Depurador de bytecode** (`--debug`) | ✅ | breakpoints por línea Astra, `step`, pila/locales/frames; resuelve la decisión §12.5-2 de `PHASE2_GAP_ANALYSIS.md` (construirlo con la VM, sin esperar a LLVM) |
| 8 | **Módulos (Fase 2.2) — paso 1**: `use`/`import`/`from` en lexer y parser | ✅ | rutas punteadas (`.`, no `::`); nodos `use_decl`/`import_decl`/`from_decl`/`import_item`; el seed reconoce ya las mismas tres formas; sin resolución todavía. Ver §7 |
| 9 | **Módulos — paso 2**: resolución de rutas, tabla de módulos y cargador | ✅ | Carga, exports `pub`, gating y compilación multi-módulo en el CLI (§7.3). Los re-exports (`use`) y los valores struct/enum foráneos quedaron cubiertos (2026-10-12); la raíz `@/` se resuelve contra el `astra.toml` del proyecto (App. B #10 cerrado 2026-10-12) y `std/…` se rechaza con diagnóstico hasta que exista stdlib |
| 10 | **InternPool de tipos** (substrato de genéricos) | ✅ | `src/typechecker/types.zig`: pool hash-consed con identidad canónica (struct/enum por nombre); `typeEq` = fast-path de puntero + reglas de unificación del seed recursivas en compuestos (`array(int_literal)` ≡ `[]i32`); fn sin retorno anotado normalizado a `void` (paridad con `a.ret orelse voidType` del seed). 53/53 tests. Sustituye el diseño "un heap-node por ocurrencia" (`PHASE2_ARCHITECTURE.md` §3.3) |
| 11 | **Colección de declaraciones** (forward-refs de tipo) | ✅ | Pase 0 en ambos compiladores (`typecheck_module_pass`/`checkModule`): registra nombres de struct/enum con layout vacío antes de resolver firmas y fields, así las declaraciones se referencian en cualquier orden (incl. recursión mutua). Caso nuevo `types/forward_type_refs.astra`; suite 96/96 seed, 53/53 zig. Los structs anidados en cuerpos de función siguen sin funcionar (paridad — ya fallaban igual antes) |
| 12 | **Traits y métodos (Fase 2.3) — pasos 1–5** | ✅ | `trait`/`impl` parsean en nodos, el type checker registra la tabla de métodos por tipo nominal y baja los cuerpos, `x.m()` hace dispatch estático al global `Type.method`/`Type.Trait.method`, y un `impl T for X` se valida contra las firmas del trait (sin defaults). Semántica y límites en §8; suites 123/123 seed, 73/73 zig, paridad 83/83 |
| 13 | **Genéricos (Fase 2.4) — pasos 1–4** | ✅ | `GenericParams` con bounds parsea en fn/struct/enum/trait/impl; fns genéricas chequeadas simbólicamente con `TYPE_PARAM`; inferencia en call-site con instancias monomórficas (y pendientes por instancia); `Name<args...>` en tipos con fix del `>>`; structs genéricos end-to-end (plantilla, inferencia en literales, instancias internadas); bounds verificados contra registros `impl T for X`. Semántica y límites en §9; suites 148/148 seed, 73/73 zig, paridad 91/91 |
| 14 | **Propagación de errores (Fase 2.5)** | ✅ | El `?` ya existía de punta a punta (postfix Pratt, `OPCODE_TRY_UNWRAP`, unwind de frame, setjmp del C backend); la fase cerró los agujeros estáticos — `?` exige valor con tag y retorno `T?` del frame — y el bug del contexto try global en llamadas anidadas del C backend. Detalle en §10; suites 152/152 seed, 73/73 zig, paridad 92/92 |

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
  está en su §11 (fase 2.6) — **implementado**: la Fase LLVM (M0–M3) vive en
  `zig/src/llvm/` con su propio log (`PHASE_LLVM_PROGRESS.md`, opt-in
  `-Dllvm`, gate `zig/tests/llvm_parity.sh`, **131/131 casos ok** a
  2026-10-20).
- `research/001`, `research/002`, `research/003` — gramática, diseño del seed y
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
`sp=/base=/frame=` más la pila (hasta 20 valores) tras cada instrucción. Igual
que aquí, el seed manda ahora todo el volcado (constantes incluidas) a stderr
desde la tanda de deuda menor de 2026-10-12; la salida del programa queda en
stdout sin mezclarse.

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
`research/001` §12.1 (`use_decl`, `import_decl`, `from_decl` e `import_item`). El
type checker los trata como `void` y el emitter como declaraciones sin efecto,
igual que el seed: **la resolución de módulos no existe todavía**; esto sólo fija
la superficie sintáctica del lenguaje.

```
ExportStmt ::= "use" ImportPath
ImportStmt ::= "import" ImportPath ("as" Identifier)?
             | "from" ImportPath "import" ImportItem ("," ImportItem)*
ImportPath ::= ("@" "/")? Identifier (("." | "/") Identifier)*
ImportItem ::= Identifier ("as" Identifier)?
```

(La producción creció en 2026-10-12 con la raíz `@/` y el separador `/`
intercambiable con `.` — App. B #10; el rechazo de `::` no cambia.)

**Decisión: el separador de ruta es `.`, no `::`.** Los tres documentos de
diseño (`research/001` §12.1, `ARCHITECTURE.md` §10) y todos los ejemplos de
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
tres constructos nuevos en el registro (47 en total) y un único
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
en C**: el seed compila un fichero y no carga nada (`research/002` §5.2), así que
la paridad no dice nada de este terreno. Hace cuatro cosas y ninguna más.

**Ruta → fichero.** Las cuatro reglas de `ARCHITECTURE.md` §10.4, con `.` y
`/` como separadores intercambiables (gramática `ImportPath ::= ("@" "/")?
Identifier (("." | "/") Identifier)*`, App. B #10): las reglas 1 y 2 (relativa
y sub-ruta) resuelven contra el directorio del fichero que importa — `mesh` →
`mesh.astra`, `geometry.mesh` → `geometry/mesh.astra`; la regla 3 ancla `@/…`
al directorio con `astra.toml` más cercano por encima del fichero de entrada,
descubierto una vez por `Loader.load` (**sólo se comprueba la existencia**:
leer `[package]` y las dependencias es trabajo del package manager); la
regla 4 rechaza `std/…` con un diagnóstico explícito (aún no hay stdlib),
mientras `std.io` punteado sigue siendo una ruta relativa normal —
`use_paths.astra` depende de eso. El sufijo `.astra` se añade sólo
al último segmento (`a.b.c` → `a/b/c.astra`, no `a/b/c/.astra`).

**Segmentos revalidados.** `pathToFile` comprueba cada segmento contra la regla
del lexer (letra o `_`, luego alfanumérico) aunque el parser ya lo garantice:
aquí es donde una ruta de módulo se convierte en un nombre de fichero, y `..`
o un trozo que no sea identificador llegando de cualquier otro sitio serían una
travesía de rutas. Es la única frontera entre un identificador del fuente y el
sistema de ficheros.

**Tabla de módulos.** `collect` convierte el AST de un fichero en una
`ModuleTable`: cada declaración con la ruta escrita y el fichero al que apunta,
con `find` como índice. Sólo nivel de módulo (un `import` anidado en un cuerpo de
función se ignora; ver `PHASE1_PROGRESS.md` §6.7).

**Nombres explícitos.** `explicitBindings` lista los nombres que el fichero
introduce **cuando la gramática los dice**: el alias de `import … as x` y los
items de `from … import a, b as c`. Lo que ata un `import a.b` a secas no lo
declara la tabla: es el **último segmento**, decisión App. B #11 (confirmada
con el dueño del lenguaje, 2026-10-10) que derivan los drivers con
`lastSegment` — `import geometry.mesh` ata `mesh`,
`import @/utils/logger` ata `logger`.

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

- `pub` es cuantificable como en research/001 §12.1 (`FunctionQualifiers ::= ("pub" | ...)*`);
  `pub pub fn` se acepta y deduplica.
- `pub` seguido de cualquier otra cosa (`pub let`, `pub use`, `pub if`) es un
  error de parseo con el mismo mensaje en ambos: `'pub' can only precede fn,
  struct, enum or const`.
- `--dump-ast` lo muestra: ambos imprimen `PubFnDecl(nombre)` (desde la
  paridad de §4 #6 el Zig imprime el formato del seed, no el suyo propio).
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
   de compilación (`module 'x' does not export 'y'`); un `use` re-exporta
   los exports del módulo declarante (los nombres propios ganan, App. B #6).
   `alias.x` resuelve en los exports del módulo (un solo nivel —
   file-as-module, §10.1); un nombre re-exportado por `use` se lee a través
   de una tabla de alias por nombre que apunta al global del módulo dueño.
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
  (el pool es compartido) **y construir valores**: `collectForeign` entrega al
  emitter de cada módulo los `StructInfo`/`EnumInfo` de sus dependencias en
  orden post-order (los propios se registran antes que los foráneos, así un
  nombre local gana cualquier colisión) y resuelve `Vec2 { … }`, el valor
  `Enum.Variant` — forma plana y namespace `m.Enum.Variant`, que antes
  compilaba y moría en runtime con `undefined global` — y los patterns de
  match sobre un enum importado, incluidos los que `use` adelanta. La
  construcción de variantes con datos sigue siendo la forma plana `Circle(r)`
  dentro del módulo que declara el enum (App. B #14).
- `use` re-exporta los exports públicos del módulo dependencia (un nivel por
  sentencia; las cadenas componen en orden post-order): el nombre propio
  gana, el binding `from` apunta al global manglado del **dueño** del nombre
  y los lectores `m.x` consultan una tabla de alias por nombre. Los tipos
  re-exportados se resuelven por registro, no por global. Lo que §10.5 pinta
  como re-export del **nombre de un módulo** (`utils.Logger.info`) sigue
  abierto (App. B #13).
- La raíz `@/` (§7.1, regla 3) se resuelve desde el `astra.toml` que el
  loader descubre caminando hacia arriba desde el fichero de entrada, y
  `std/…` se rechaza con un diagnóstico explícito (App. B #10, resuelto
  2026-10-12); la stdlib en sí sigue sin existir.
- `let x = Shape` (tipo como valor) es un error de runtime
  (`undefined global`) **compartido con el seed**: ambos compiladores lo
  aceptan en compile time, así que no es una divergencia de módulos.
- `--debug` sobre un programa multi-módulo mapea las líneas contra el fuente
  de la raíz para todos los módulos (limitación conocida).

Fijado por `zig/src/link.zig` (test e2e sobre los fixtures `zig/tests/link/`:
`from`, alias, import desnudo con #11, gating de `pub` privado, aggregates
foráneos en `foreign/`, re-exports en `reexport/` y la raíz de proyecto en
`rootproj/`) y verificado a mano con `--dump-modules`/`--dump-bytecode`.

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

---

## 8. Traits y métodos (Fase 2.3) — pasos 1–5 completos

Commits `13b2f5c` (parseo inerte), `96ade27` (dispatch) y `288b5ea`
(conformidad). Spec: `research/001` §12 (`TraitDef`/`ImplBlock`) y
`PHASE2_GAP_ANALYSIS.md` §11 (fase 2.3). El *exit criteria* de la fase —
`impl Trait for Type` con dispatch de métodos — está cumplido en ambos
compiladores, con mensajes de error byte-idénticos.

### 8.1 Modelo de dispatch (estático, sin vtable)

- **Registro.** El type checker de cada módulo recoge `impl` en su pase 1 en
  una tabla de `MethodEntry`/`Method` con clave **(tipo nominal, nombre del
  método, trait)**. `fn_type` conserva el receptor en el parámetro 0, así
  que una llamada fuente de `k` argumentos chequea contra `params[1..]`.
- **Resolución.** `x.m(args)` (callee `field_access`) se resuelve en la
  tabla del receptor en compile time y **anota el callee** con el global
  manglado; el emitter baja el call a `get_global` + receptor + argumentos +
  `call` con `argc = args+1` — el layout que la VM ya esperaba. Sin vtable,
  sin `dyn`, sin UFCS: `Type::method(x)` o equivalentes no existen aún.
- **Mangle.** `Type.method` para un impl inherent, `Type.Trait.method` para
  un impl de trait. El segmento del trait **no es cosmético**: sin él, dos
  impls del mismo nombre comparten un global y el orden de emisión decide
  el ganador — el VM lo enmascaraba como *last-write-wins* y el backend C
  ata cada nombre a una sola función (regresso fijado por
  `tests/codegen/method_dispatch.astra`).
- **Precedencia.** Inherent gana sobre trait sin importar el orden; entre
  dos traits con el mismo método, gana el primero declarado (ambigüedad
  cross-trait: limitación documentada, resoluble con `impl Trait` explícito
  cuando exista).
- **Campo vs. método.** `x.m` (sin llamada) sigue siendo lectura de campo
  o variante; si `m` solo existe como método, el error es
  `method 'm' of 'T' must be called` — el split al estilo de Rust `x.m` /
  `x.m()`.
- **Receptores.** Solo struct y enum (`impl` sobre un primitivo es error);
  `self` obligatorio como primer parámetro (ya lo exigía el parser),
  typeless hereda el tipo del bloque y `self: T` debe nombrarlo exacto.

### 8.2 Conformidad (paso 5)

- Un pre-pase (`collect_trait_decls` / `collectTraitDecls`, tras la
  colección de nombres de tipo) guarda las firmas requeridas de cada
  `trait`, así un `impl T for X` puede aparecer antes que `trait T` en la
  fuente.
- Por cada `impl T for X`: `T` debe existir
  (`unknown trait 'T'`), el bloque debe declarar **todos** los métodos
  requeridos (`type 'X' does not implement trait 'T': missing method 'm'`)
  y cada uno debe calzar en aridad, tipos de parámetros y retorno
  (`signature of method 'm' of 'X' does not match trait 'T'`). La
  conformidad es **por bloque de impl**: un método inherent nunca satisface
  el requisito del trait (regla de Rust), solo sombrea su entrada en el
  dispatch.
- Un item de trait con cuerpo es rechazado:
  `default trait methods are not yet supported` (los métodos default
  llegan cuando existan sus reglas de lookup).

### 8.3 Diferido a fases futuras

| Qué | Dónde queda |
|:----|:------------|
| Objetos de trait / vtable (`dyn`) | GAP §11 paso 5 de la fase 2.3 (runtime) — el dispatch actual es 100 % estático |
| UFCS (`T::method(x)`, métodos como valores) | Con genéricos (fase 2.4) |
| `impl<T> Trait for T` | Fase 2.4 (los bounds de genéricos ya están: §9.3) |
| Métodos y traits cross-módulo (tabla `pub trait` exportable, `impl m.T for X`) | Con la semántica multi-módulo de traits: las tablas viven en cada `TypeChecker`, un módulo no ve los métodos del otro, y `from dep import T` no se exporta aún; el emitter tampoco sabe a qué módulo pertenece un `Type.Trait.method` |
| Métodos default en traits | Error explícito hoy (§8.2) |
| Desambiguar entre traits con el mismo método | Requiere calificación explícita (nueva sintaxis) |

### 8.4 Tests

`tests/conformance/traits/` (`trait_inert`, `method_dispatch`,
`trait_conformance`), `tests/codegen/method_dispatch.astra` (round-trip C:
override inherent vs trait) y trece casos `ui/` (`self_outside_impl`,
`impl_missing_self`, `trait_const_item`, `method_unknown`,
`method_bare_access`, `method_duplicate`, `impl_self_type_mismatch`,
`impl_primitive_receiver`, `method_arg_count`, `trait_unknown`,
`trait_missing_method`, `trait_signature_mismatch`,
`trait_default_method`).

---

## 9. Genéricos (Fase 2.4) — pasos 1–4 completos

Genéricos de Astra (`research/001` §7.3/§12.1) en ambos compiladores,
con el seed como referencia y paridad byte-a-byte de mensajes y dumps.
Los commits por paso están en la fila 13 de §4; aquí el detalle.

### 9.1 Sintaxis (paso 1, `daa0db4`)

`GenericParams ::= "<" GenericParam ("," GenericParam)* ">"` con
`GenericParam ::= Identifier (":" TraitBound ("+" TraitBound)*)?` parsea
inerte en fn/struct/enum/trait/impl → un `NODE_TYPE_PARAM` por parámetro,
con `bounds` como identificadores `NODE_TYPE_IDENT` (traits aún sin
namespace). Límite duro: 32 parámetros por lista, el mismo que retiene el
checker.

### 9.2 Fns genéricas (pasos 2a–2b, `e43520e` + `4f85d2b`)

- **2a**: la firma se registra con placeholders `TYPE_PARAM`
  (internados por nombre + nodo dueño, así dos `T` de fns distintas no
  colisionan) y el cuerpo se chequea **una vez simbólicamente** con ese
  stack en scope (marca/restore). El nombre de una fn genérica no es un
  valor (`ui/generic_as_value`).
- **2b**: inferencia en el call-site — `unify_bind` recorre
  firma↔argumentos (literal entero → `i32` por defecto, recursión en
  arrays/opcionales/fns) con el env pre-sembrado en orden de declaración
  (el mangle depende de ese orden). Conflicto →
  `cannot be both %s and %s`; incompleto →
  `cannot infer type parameter`. Binding concreto → instancia
  materializada (fn renombrada al mangle `f<i32>` + rewrites de los
  pendientes); binding abstracto (el call vive dentro de otro cuerpo
  genérico) → `pending`, resuelto cuando la instancia externa sea
  concreta. Los cuerpos **no** se re-chequean por instancia: son
  simbólicos.

### 9.3 Argumentos de tipo y structs genéricos (paso 3, `af0e692` + `0800660`)

- **3a**: `Name<args...>` en posición de tipo (recursivo con guard de
  profundidad, cap de 32 argumentos) y fix del `>>` en el lexer
  (`gt_depth` + `>` pendiente): el `>` que cierra argumentos se reparte
  antes del siguiente token, así `Vec<Vec<T>>` cierra dos veces y
  `a >> b` sigue siendo shift. `--dump-tokens`/`--dump-ast` con paridad
  (`TypeArgs`).
- **3b**: `resolve_type_with_args` valida base desconocida (mensaje
  `unknown type` de siempre — el test anidado depende de él), base que no
  es struct genérico (`does not take type arguments`) y aridad
  (`expected N, got M`); un nombre genérico sin argumentos en posición de
  tipo → `type 'Box' requires type arguments`. La instancia `Box<i32>`
  se materializa con mangle `Base<T1,T2>` **insertando el símbolo antes
  de resolver los campos** (recursión de tipos) y re-resolviéndolos del
  AST con los parámetros sustituidos: la plantilla conserva sus
  `TYPE_PARAM`, así que el orden de declaraciones no la contamina. Los
  literales `Box { v: ... }` **infieren** los argumentos desde los
  valores (unify + caché de tipos chequeados una sola vez) con los
  mismos mensajes de conflicto/inferencia que las llamadas y dueño =
  nombre del struct. El emitter deja de ignorar structs con `<...>`:
  todas las instancias comparten el `StructDef` del nombre fuente (los
  literales siempre escriben el nombre base).

### 9.4 Bounds (paso 4, `da08fa4`)

Una lista de registros `impl T for X` — no la tabla de métodos: un trait
sin métodos no registra ninguna entrada — responde si un tipo concreto
lleva un trait. El chequeo ocurre en los tres sitios donde un env se
vuelve concreto (llamada genérica, inferencia de literal, argumentos en
anotación):

```
type parameter 'T' of 'accept' requires bound 'Show': type 'i32' does not implement trait 'Show'
```

Solo struct/enum pueden satisfacer un bound (el pass de impl lo exige);
primitivas y compuestos, nunca. El **nombre** del bound se valida en
firme al vincular los parámetros (`unknown trait 'Missing'`), dentro de
`push_generic_bindings`/`pushGenericBindings`: el pre-pase de traits ya
corrió, y fn + struct cubren todas las declaraciones genéricas vivas. Los
bindings **abstractos** (parámetro de la fn envolvente) se saltan: el
cuerpo se chequea una vez simbólicamente y el chequeo perezoso no se
re-ejecuta por instancia.

### 9.5 Auditoría de límites (5 fixes)

`deb0964` (los pendientes de instancias perdían sus rewrites al crecer el
array), `cb2eb9f` (mangle que desbordaba su búfer de 512 → rechazo
explícito), `31a3fb0` (codificación C inyectiva para identificadores
manglados), `54fd94e` (techos duros: 32 parámetros, 256 instancias, guard
previo), `ae5ee81` (dos NULL-deref del typechecker hallados por fuzz +
regresión `ui/fuzz_field_access_null_type`).

### 9.6 Diferido y límites conocidos

| Qué | Estado |
|:----|:-------|
| **Enums genéricos** | Parsean y declaran inertes (checker/emitter los saltan); sin argumentos de tipo en construcción no hay forma de escribirlos |
| **`impl<T> Trait for T` e impls sobre instancias** (`impl Show for Box<i32>`) | El target del `impl` no parsea argumentos; `impl<T>` sigue inerte |
| **Bounds sobre bindings abstractos** | No se re-verifican al instanciar la fn envolvente (cuerpo simbólico, chequeo único) |
| **Bounds en enums/trait/impl genéricos** | Esas declaraciones siguen inertes: solo fn y struct vinculan parámetros |
| **Args sobre primitivas** (`i32<f32>`) | Se aceptan en silencio: las primitivas resuelven antes de mirar los argumentos |
| **Método sobre parámetro** (`x.show()` con `T: Show`) | El dispatch no consulta bounds (UFCS/`T::m`, §8.3) |
| **Genéricos cross-módulo (Zig)** | `collectExports` filtra `generics.len == 0` (herencia de la Fase 2.2): una plantilla `pub` no se exporta (`module 'x' does not export 'Box'`) y `Export` no arrastra `is_generic`/`type_ast`. El seed es de fichero único (sin capa de exports) |
| **where-clauses, turbofish (`f<i32>()`), blanket impls, `type_alias` genérico** | No parsean / fuera de alcance |
| **Techos** | 32 parámetros, 32 argumentos, 256 instancias, mangle ≤ 512 bytes — cada uno con su error dedicado |

### 9.7 Tests

- Positivos: `generics/{inert,instantiate,many_instances,generic_then_shift,generic_struct,bounds_ok}`;
  probe de dumps `zig/tests/dump_probes/generic_params.astra`.
- `ui/` (17): `generic_{as_value,cannot_infer,conflict,instance_limit,name_too_long,op_on_param,param_limit,param_vs_concrete}`,
  `generic_struct_{cannot_infer,conflict}`,
  `generic_type_{requires_args,wrong_arg_count}`,
  `type_args_{on_nongeneric,unknown_base}`,
  `bound_{not_satisfied,not_satisfied_struct,unknown_trait}`.
- Gates: suite seed **148/148**, `zig build test` **73/73**, paridad de
  dumps **91/91**, `--check-constructs` OK.

---

## 10. Propagación de errores (Fase 2.5) — completada 2026-10-14

El `?` ya funcionaba de punta a punta en ambos compiladores (postfix en
el bucle Pratt, `OPCODE_TRY_UNWRAP`, unwind de frame en las dos VMs,
setjmp/longjmp en el C backend): el criterio de salida del GAP —
"`?` propaga errores automáticamente a través de llamadas" — lo cumplía
`enums/try_operator.astra` antes de empezar. Los ítems 1/3/4 de
`GAP §11` describían trabajo sin empezar que en realidad estaba hecho;
lo que faltaba de verdad eran los agujeros estáticos y un bug del
backend C.

### 10.1 Chequeo estático del `?` (ambos compiladores, `1cc6ca4`)

`NODE_TRY_EXPR`/`.try_expr` rechaza dos cosas antes de que la VM pueda:

- **(a) valor sin tag**: `?` sobre un tipo conocido no-optional →
  `? operator requires Result or Option, got i32` (la misma redacción que
  la VM usa en runtime). El literal `none` se tipea como nil crudo, no
  como `T?`, así que `none?` también se rechaza: la ausencia se
  propaga por un optional tipado (`let v: i32? = none; v?`) o con
  `return none`. Los tipos parámetro pasan: los cuerpos genéricos se
  chequean una vez simbólicos y el guard runtime de ambas VMs cubre sus
  instanciaciones.
- **(b) retorno del frame no-optional**: el unwind entrega nil/err al
  caller, así que el retorno declarado de la función envolvente debe ser
  `T?`: un `?` en una fn `-> i32`, sin retorno declarado, dentro de una
  lambda sin anotar o a nivel de módulo →
  `? operator requires the enclosing function to return an optional type`.
  Se lee `current_fn_return` (guardado/restaurado alrededor de cuerpos
  de fn y lambda); los métodos de `impl` pasan por el camino normal.

Los mensajes son byte-idénticos seed↔zig (verificados fichero a fichero
con ambos binarios; seed solo añade su resumen `type check failed with
N error(s)`). Fijados por `ui/try_{non_optional,bad_return,toplevel}`.

### 10.2 C backend: contexto try por llamada (`da3ddb1`)

`astra_error_jmp`/`astra_error_active` son un par de globales único: un
callee con `?` instalaba su setjmp encima del del caller y, al volver
normalmente, lo dejaba apuntando a su frame ya desmontado — el
siguiente `?` del caller hacía longjmp a stack muerto (repro: un falso
`? operator requires Result or Option, got nil` mientras VM y zig
imprimían `nil`). `OPCODE_CALL` guarda y restaura `jmp_buf`, `active` y
`error_value` alrededor de cada llamada, así cada unwind aterriza en su
propio setjmp vivo, encadenado frame a frame como en la VM. Fijado por
`tests/codegen/try_nested_frames.astra` (VM, C y zig dan `nil`).

### 10.3 Registry al día (`82908b1`)

`operator_table.c` declaraba `?` con `binding_power=0`, que
`--check-constructs` interpreta como "sin implementar" y salta: la
comparación de precedencia de la invariante 6 nunca corría para él (ahora
`BP_POSTFIX`; `--dump-operators` lo saca de la lista de pendientes con
el parser en 14). Dos notas de constructs que mentían sobre `?`
(`type_annotation`: "`T?` nunca se consume, `T<U>` falta";
`field_access`: "no hay encadenado `?`") corregidas.

### 10.4 Diferido

`Result<T,E>` estático distinto y el tipo never `!` (Tier 2 de
research/002 §5.2; desviaciones de ARCHITECTURE §5.3/§7.2), `??`
coalescing, re-chequeo del `?` por instanciación genérica, y las fugas
del modelo de memoria del C backend (las celdas envueltas de `some(...)`
nunca se libera — preexistente; la suite no corre conformance con LSan).

### 10.5 Tests

`ui/try_{non_optional,bad_return,toplevel}` (3) y
`codegen/try_nested_frames` (1). Gates: suite seed **152/152**,
`zig build test` **73/73**, paridad **92/92**, `--check-constructs` OK;
casos positivos (fn, método, lambda anotada) verificados en VM seed,
C backend y zig.
