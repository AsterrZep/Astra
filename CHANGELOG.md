# Changelog

All notable changes to the Astra programming language will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Backend nativo LLVM (Fase LLVM, M0–M2, opt-in `-Dllvm`)**: tercera ruta
  de codegen del compilador zig — AST tipado → LLVM IR (C API `llvm-c`,
  LLVM 19..23 vía `llvm-config`) → `.o` nativo con TargetMachineEmitToFile
  (`--emit-obj`), enlazado contra el runtime compartido del seed. Cubre el
  subconjunto Astra-0 sin heap de usuario: escalars, floats, strings,
  Option/Result con `match`/`?`, closures, arrays/structs/enums,
  `for..in`/`break`/`continue`. Gate de paridad `zig/tests/llvm_parity.sh`
  (salida de la VM ↔ ruta LLVM byte a byte): **121 casos — 103 ok, 0 fail**;
  job CI `llvm` con LLVM 19. La contra-investigación post-M2 (2026-10-20)
  verificó docs contra código, localizó y cerró un bug pre-existente de
  `&&`/`||` en call-args (doble push del short-circuit en ambos emitters
  VM, heredado por el C) y alineó el dump AST (`BinaryOp(&&/||)`). Detalle:
  `Documentacion/PHASE_LLVM_PROGRESS.md`.
- **Propagación de errores estáticamente chequeada (seed + Zig, Fase 2.5)**:
  el `?` ya existía de punta a punta (postfix Pratt, `OPCODE_TRY_UNWRAP`,
  unwind de frame, setjmp del C backend); ahora el typechecker de ambos
  compiladores cierra los agujeros que dejaba: (a) `?` sobre un valor sin
  tag → `? operator requires Result or Option, got i32` (mismo texto que
  el runtime; `none` se tipea como nil crudo, así que `none?` también se
  rechaza y la ausencia va por un optional tipado o `return none`, y los
  tipos parámetro quedan a cargo del guard runtime de sus
  instanciaciones), y (b) el retorno declarado del frame debe ser `T?` —
  el unwind entrega nil/err al caller, así que `?` en una fn `-> i32`, sin
  retorno declarado, en lambda sin anotar o a nivel de módulo →
  `? operator requires the enclosing function to return an optional type`.
  Mensajes byte-idénticos verificados fichero a fichero; fijados por
  `ui/try_{non_optional,bad_return,toplevel}`. La registry de operadores
  declara `?` con `BP_POSTFIX` (el check de precedencia de la invariante 6
  lo saltaba con `binding_power=0`) y dos notas de constructs que mentían
  sobre `?` se corrigieron. Diferido: `Result<T,E>` estático y `!` (Tier
  2), `??`, re-chequeo por instanciación genérica — `PHASE2_PROGRESS.md`
  §10.4. Gates: suite seed 152/152, zig 73/73, paridad 92/92, CI verde.
- **Genéricos (seed + Zig, Fase 2.4, pasos 1–4)**: `GenericParams` con
  bounds (`T: Show + Debug`) parsea en fn/struct/enum/trait/impl y el `>>`
  de `Vec<Vec<T>>` se reparte en dos `>` (`af0e692`); las fns genéricas
  se chequean simbólicamente con placeholders `TYPE_PARAM` (`e43520e`) y
  la inferencia en call-site materializa instancias monomórficas con
  pendientes por instancia (`4f85d2b`, parseo inerte en `daa0db4`);
  `Box<i32>` en posición de tipo y los literales `Box { v: ... }`
  rellenan la plantilla con los argumentos concretos — símbolo insertado
  antes que los campos (recursión de tipos), tipos internados por nombre
  (una instancia = un `*Type`) e inferencia con caché de los valores
  chequeados una sola vez (`0800660`); los bounds se verifican en los
  tres sitios de instanciación contra registros `impl T for X` — no la
  tabla de métodos, un trait sin métodos no registra entradas — con
  `unknown trait` en firme al vincular los parámetros (`da08fa4`).
  Auditoría de límites: cinco fixes (los pendientes de instancias
  perdían sus rewrites al crecer el array, mangle >512 bytes, C
  inyectivo para nombres manglados, techos 32 params/256 instancias,
  dos NULL-deref de fuzz con regresión). Diferidos: enums genéricos,
  `impl<T>` e impls sobre instancias, bounds sobre bindings abstractos,
  args sobre primitivas (`i32<f32>` silencioso), método sobre parámetro
  (UFCS), genéricos cross-módulo (el exportador zig filtra
  `generics.len == 0`), where-clauses, turbofish, blanket impls:
  `PHASE2_PROGRESS.md` §9.6. Fijado por 6 casos `generics/` y 17 casos
  `ui/` — suite seed 148/148, zig 73/73, paridad de dumps 91/91, CI
  verde en ambos compiladores.
- **Traits y métodos con dispatch estático (seed + Zig, Fase 2.3)**: los
  bloques `trait`/`impl` pasan de inertes a funcionales en tres pasos
  (`13b2f5c` parseo, `96ade27` dispatch, `288b5ea` conformidad). El type
  checker registra los métodos por **(tipo nominal, método, trait)** con el
  receptor en el parámetro 0; `x.m(args)` anota el callee con el global
  manglado y el emitter lo baja a `get_global` + receptor + argumentos +
  `call` (`argc = args+1`), igual en la VM y en el backend C. Sin vtable:
  la precedencia es inherent > trait (entre traits, el primero declarado),
  `x.m` sin llamada sigue siendo campo/variante con error `must be called`,
  y los receptores se limitan a struct/enum con `self` obligatorio. La
  conformidad (paso 5) recoge las firmas de cada trait en un pre-pase y
  exige por bloque de impl: trait existente, todos los métodos requeridos y
  firmas calzadas (aridad, parámetros, retorno); un método inherent nunca
  satisface al trait, solo sombrea su entrada. Item de trait con cuerpo →
  `default trait methods are not yet supported`. El mangle incluye el trait
  (`Type.Trait.method`): sin el segmento, inherent y trait del mismo nombre
  compartían un global y el backend C — que ata cada nombre a una sola
  función — enlazaba siempre el primero registrado mientras el VM lo
  enmascaraba como last-write-wins (regresso en
  `tests/codegen/method_dispatch.astra`). Quedan diferidos los objetos de
  trait/vtable, UFCS, `impl<T>`, métodos default, la desambigüación
  cross-trait y todo lo cross-módulo (tablas por checker, `pub trait` sin
  exportar): `PHASE2_PROGRESS.md` §8.3. Fijado por
  `tests/conformance/traits/{method_dispatch,trait_conformance}.astra`,
  `tests/codegen/method_dispatch.astra` y 13 casos `ui/` — suite seed
  123/123, zig 73/73, paridad de dumps 83/83, CI verde en ambos
  compiladores.
- **Fuzzing del lexer/parser del seed (libFuzzer)**: harness
  `seed/fuzz/fuzz_compile.c` que recorre lexer→parser→typechecker→emitter
  (sin VM), diccionario `seed/fuzz/astra.dict` con las keywords y
  puntuación del lexer, y targets `make fuzz` / `make fuzz-run` (corpus
  sembrado desde `tests/`, 1 worker con `-rss_limit_mb=512` para cajas
  pequeñas). El job seed de CI construye el harness y hace replay
  `-runs=0` de todo el corpus. Primera campaña: ~180k ejecuciones sin
  hallazgos, cobertura 7853→8638.
- **Agregados foráneos y re-exports (`use`) en el compilador Zig**: el
  emitter de cada módulo recibe los `StructInfo`/`EnumInfo` de sus
  dependencias en orden post-order (los propios se registran antes que los
  foráneos, así un nombre local gana cualquier colisión), de modo que
  `Vec2 { … }`, el valor `Enum.Variant` y los patterns de match sobre un
  enum importado emiten igual que en un archivo único. La forma namespace
  `m.Enum.Variant` se resuelve en compile time contra los registros del
  módulo exportador — antes compilaba y moría en runtime con
  `undefined global 'm0.Shape'`, porque los defs de struct/enum nunca son
  globals. `use` pasa a ser re-export: el driver fusiona los exports del
  módulo dependencia (el nombre propio gana), registra el módulo dueño de
  cada nombre para que los bindings `from` apunten a su global manglado,
  entrega a los importadores una tabla de alias por nombre para las
  lecturas `m.x`, y adelanta también los registros de tipos. Lo que §10.5
  pinta como re-export del nombre de un módulo (`utils.Logger`) queda como
  pregunta abierta (App. B #13), igual que la importación de variantes de
  enums (#14); la raíz `@/` se resuelve desde `astra.toml` (App. B #10,
  cerrado más abajo) y `std/` sigue rechazado hasta que exista stdlib.
  Fijado por los fixtures `zig/tests/link/foreign/` y
  `zig/tests/link/reexport/` (62 pruebas Zig, 104 seed).
- **`break` con valor es error de compilación (seed + Zig)**: la gramática de
  `research/001` permite `break Expression?`, pero Astra-0 no tiene `loop` para
  recibir el valor y ambos parsers se lo tragaban en silencio — `break 5`
  compilaba como `break` más una expresión muerta que imprimía `0`. Ahora
  `break` exige límite de sentencia (`;`, newline, `}` o EOF) tras él, y cualquier
  otro token produce `break with a value is not supported in Astra-0`. Los
  newlines son tokens en ambos lexers, así que la sentencia siguiente en su
  propia línea no se confunde con un valor. Fijado por
  `tests/conformance/ui/break_value.astra` (104 casos seed, 60 Zig)
- **Closures (seed + C backend + Zig)**: lambdas now capture free variables
  from the enclosing frame **by value** (ARCHITECTURE.md §30.5). The emitter
  analyzes the lambda body for free names against the enclosing scopes, pushes
  each captured value at the creation site, and emits `OPCODE_CLOSURE`
  (`(fn_const << 8) | n_captures`), which clones the template `FnObj` and
  attaches the stack values as its `env`. Inside the body a free name resolves
  local → `GET_CAPTURE` → global; `GET_CAPTURE` reads the callee's env through
  frame slot 0, which holds the callee for the whole call. Assigning to a
  captured variable is rejected at compile time — there is no cell to write, and
  a write to only the local copy would diverge from the enclosing frame. Named
  nested functions do not capture. Implemented end-to-end in all three paths:
  the seed VM (`vm.c`), the C backend (`--emit-c`: `AstraFn.env`,
  `astra_closure_new`, both opcode switches), and the Zig compiler
  (`bytecode.zig`/`vm.zig`/`emitter.zig` with the free-variable walker over the
  flat AST). Conformance: `lambda/closures.astra`, `ui/capture_assign.astra`,
  `tests/codegen/closures.astra`; verified by instruction-level `ASTRA_DUMP_VM`
  trace parity between the seed and the Zig VM.
- **Unified diagnostics sink (Zig)**: parser, type checker, emitter and
  module loader now report through one `Diagnostic{file, span, msg}` sink
  (`zig/src/diagnostics.zig`) with a single `file:line:col: error: msg`
  format that degrades to `file:line:`, `file:` or `error:` when location
  information is missing. Parse errors now carry the module's file name
  (previously they printed `error:{line}:{col}:` with no file, which was
  ambiguous in multi-module builds). The loader's read/parse/cycle errors
  and the driver's `does not export` / `use not supported` errors use the
  same sink; runtime and CLI-flag errors are intentionally outside it.
  Phases with no sink wired (e.g. the conformance runner) print directly
  through the same formatter, so behaviour is identical either way. The
  seed compiler is untouched
- **Multi-module compilation (Zig CLI)**: `astra-zig` now compiles and runs
  programs whose entry file declares imports. The loader builds the graph
  (dependencies first), every module typechecks against one shared type pool,
  imports resolve to the exporting module's `pub` declarations (`pub` gating:
  a private name is a compile error), module globals are mangled (`m0.add`)
  into the VM's flat namespace, and modules execute in dependency order on
  one VM — the root's `main` runs last. A bare `import a.b` binds the last
  segment (decision App. B #11); at the time of this entry `use`
  re-exports and cross-module struct/enum *values* were unsupported — both
  were delivered later in [Unreleased] (see above). E2E fixtures in
  `zig/tests/link/`, tests in `zig/src/link.zig`. The seed CLI still
  compiles one file and ignores imports (the conformance suite is unaffected:
  it uses its own single-file pipeline)
- **Module loader keeps trees and orders dependencies first (Zig)**:
  `Loader.loadFile` now appends each module *after* its imports (post-order, so
  a future compiler can execute module code dep-before-user), retains each
  file's parsed tree in `LoadedModule` (`tree` + `root`) for emission, and
  `collect` gathers each file's `pub` top-level names into
  `ModuleTable.exports`. `--dump-modules` prints the new order and the export
  sets; `Loader.deinit` tears the trees down
- **`pub` declarations (seed + Zig)**: `pub` before `fn`, `struct`, `enum` or
  `const` is accepted by both compilers and recorded on the AST (`is_pub`);
  before anything else (`pub let`, `pub use`) it is a parse error with the
  same message in both. Foundation for the module system's visibility rules
  (`ARCHITECTURE.md` §10.2); no cross-module semantics yet. New cases
  `module/pub_decls.astra` and `ui/pub_let.astra`
- **CI (GitHub Actions)**: `.github/workflows/ci.yml` builds the seed under
  ASan/UBSan/LSan and runs the full suite against that binary, checks the
  release build, and runs `zig build test` (unit tests + seed conformance)
  with Zig 0.16.0 on every push and PR (Linux; macOS/Windows are a follow-up)
- Complete architecture specification (40 sections, numbered 1-41)
- Design philosophy documentation
- Comparative analysis with Mojo, Nim, Zig, Julia, Vale, Swift
- Cross-platform research (Linux, macOS, Windows, Android, iOS, visionOS)
- Compiler architecture design (multi-IR, query system, dual backend)
- Memory model specification (ARC/ORC, cycle detection)
- Concurrency model (green threads, channels, atomics)
- Standard library design (~64 modules)
- Package manager design
- Formal grammar (EBNF)
- Error handling design (Result/Option, panic/recover)
- Type coercion rules
- Variable scoping and shadowing rules
- Seed compiler design
- Compiler testing methodologies
- Governance and RFC process
- Evolution demo scripts (01_basics through 07_lowlevel_phase2) in `scripts/evolution/`
- Terminal status dashboard (`scripts/status.sh`)
- Phase 2 kickoff document (`Documentacion/PHASE2_KICKOFF.md`)
- **Module declarations in the Zig compiler (Phase 2.2, step 1)**: `use`/`import`/`from` are lexed and parsed into `use_decl`/`import_decl`/`from_decl`/`import_item` nodes, with dot-separated `ImportPath` (`zig/src/`). No module resolution yet
- **Module declarations in the seed (Phase 2.2, step 1)**: `import`/`from`/`as` are lexed and parsed into `NODE_IMPORT`/`NODE_FROM`/`NODE_IMPORT_ITEM`, sharing one dot-separated `ImportPath` builder with `use`. The registry grows to 46 constructs (`seed/src/`). Parsed and discarded, as before: no module resolution in the seed
- **Module resolution groundwork (Phase 2.2, step 2)**: `zig/src/modules/modules.zig` resolves an `ImportPath` to a file (relative and sub-route, `ARCHITECTURE.md` §10.4 rules 1–2, rejected if a segment could escape the module directory), collects a file's declarations into a `ModuleTable`, and lists the names each declaration states explicitly
- **Module loader with cycle detection**: the same module reads each resolved file, follows its imports transitively and reports circular imports (`ARCHITECTURE.md` §10.6) instead of looping; `--dump-modules` prints the resulting graph, with fixtures under `zig/tests/modules/`
- **Prefijo raíz `@/` y separador `/` en `ImportPath` (gramática + resolución)**:
  la producción pasa a `ImportPath ::= ("@" "/")? Identifier (("." | "/") Identifier)*`
  en ambos parsers — token `@` nuevo (`TOKEN_AT`/`.at`), `.` y `/` como
  separadores intercambiables y el path guardado tal cual está escrito (el
  seed comparte un único `parse_module_path` entre `use`/`import`/`from`, así
  `--dump-ast` imprime el mismo slice en ambos lados). En el Zig, la regla 3
  de `ARCHITECTURE.md` §10.4 resuelve `@/…` contra el directorio con
  `astra.toml` más cercano por encima del fichero de entrada (walk-up en
  `Loader.load`; sólo existencia — leer `[package]` queda para el package
  manager), y la regla 4 rechaza `std/…` con «no standard library exists
  yet», dejando `std.io` punteado como ruta relativa normal. `lastSegment`
  de `main.zig`/`link.zig` acepta ambos separadores (`@/utils/logger` ata
  `logger`). Fijado por `seed/tests/conformance/module/root_import.astra`,
  `ui/import_at_noslash.astra` y los fixtures `zig/tests/link/rootproj/`
  (end-to-end) y `zig/tests/modules/{rootproj,noroot,stdlib}` (seed 106,
  zig 73, paridad 79/79; cierra App. B #10).

### Changed
- **`--dump-tokens` y `--dump-ast` del Zig byte-idénticos al seed (PHASE2
  §4 #6)**: los dos introspection flags dejaron de imprimir el formato
  propio del Zig a stderr y ahora replican el del seed a stdout. Nuevo
  `zig/src/dump.zig`: `printToken` (mismo `%u:%u  %-14s` + valor que
  `token_print`), `Tag.seedName()` completo (81 kinds en espejo de
  `token_kind_name`) y `writeG`, un `%g` de C sin libc (6 dígitos
  significativos, estilo e si el exponente < -4 o >= 6, exponente con
  signo y >= 2 dígitos) testeado contra la salida real de gcc. `dumpNode`
  reescrito al formato de `driver.c dump_node` (`Module`, `FnDecl(name)`,
  `Param(x)`, `ReturnType`, `VarDecl(x[, mut])`, `Field(x:)` inline en
  payloads, `Arm` sin guard, `Bind(name)`, `NoneExpr`, `Use` bare);
  `dumpInline` eliminado. Gate en CI: job `parity` +
  `zig/tests/dump_parity.sh` diffea ambos dumps sobre conformance no-UI,
  codegen y los probes parse-only de `zig/tests/dump_probes/` (payloads
  con nombre, formas `%g`, guards, `pub`+lambda, `use`/`import`) — 78
  ficheros. Divergencia aceptada fuera del alcance: ante un error de
  parseo el seed vuelca el AST parcial con rc=0 y el Zig sale con rc=1
- **Dispatchers del backend de C unificados** (`--emit-c`): los dos
  switches de opcodes paralelos de `seed/src/codegen.c` (cuerpo de
  función y código de módulo) pasan a un único
  `emit_instructions(cg, code, code_len, constants, const_len, last_line)`.
  La duplicación había producido cuatro bugs (POP de módulo, operadores
  bit a bit de módulo, el gemelo de S4 y `VAL_STRUCT_DEF` → SEGV en
  struct literals de nivel superior); los 72 `.c` generados sobre la
  suite son byte-idénticos antes y después del refactor.
- **`--dump-bytecode` y los volcados de depuración van enteros a stderr
  (seed)**: `value_print()` escribía las constantes por stdout mientras el
  resto del volcado iba a stderr, partiendo cada línea entre los dos streams e
  intercalando diagnóstico con la salida del programa. Nuevo
  `value_print_stream(FILE*, Value)` alimenta los tres sitios de volcado
  (`--dump-bytecode`, `ASTRA_DUMP_VM`, `ASTRA_TRACE`) con stderr;
  `value_print()` queda como envoltorio a stdout para el builtin `print` y
  `OPCODE_PRINT`, sin cambios en la salida de programa. Paridad con el
  compilador Zig, que ya volcaba todo a stderr; los dumps seed vs Zig ahora
  son byte a byte idénticos
- **Errores runtime del C generado con `fichero:línea:` (seed `--emit-c`)**:
  `astra_runtime_error` imprimía solo `runtime error: msg`. El código
  generado ahora escribe `astra_line = N;` antes de cada instrucción que
  puede fallar (deduplicando cuando la línea no cambia) y el runtime imprime
  `file:line: runtime error: msg`, el mismo formato que el driver del VM
  (anteriormente asimetría documentada en PHASE1 §3). El CALL de nivel
  módulo pasó de imprimir a mano `cannot call non-function` (sin longjmp) a
  `astra_runtime_error("cannot call non-function value")`, con la misma
  palabra que `vm.c`. `run_tests.sh` compara ahora también el texto esperado
  en la rama del C backend; `error_line_in_fn.astra` fija la línea del fallo
  dentro de una función

### Fixed
- **C backend: el contexto `?` ya no sobrevive a las llamadas**:
  `astra_error_jmp`/`astra_error_active` son un par de globales y cada
  callee con `?` instalaba su setjmp encima del del caller dejándolo
  apuntando a su frame desmontado — el siguiente `?` del caller hacía
  longjmp a stack muerto (repro: falso `? operator requires Result or
  Option, got nil` con salida que divergía de las dos VMs). `OPCODE_CALL`
  guarda y restaura `jmp_buf`, `active` y `error_value` alrededor de cada
  llamada. Fijado por `tests/codegen/try_nested_frames.astra` (VM seed,
  C y zig dan `nil`).
- **Payload fields con nombre de enum se perdían en el dump del seed**:
  `match(p, TOKEN_COLON)` movía `previous` al `:` y `--dump-ast` imprimía
  `Field(::)` para todo campo `x: i32` de una variante con payload (el
  parser Zig ya almacenaba el nombre bien; la paridad lo hizo visible).
  Ahora `Field(x:)`. Los nombres solo alimentan el dump y
  `field_names` cosmético (la igualdad de payloads es posicional), así
  que la suite no se mueve. Pinned by
  `zig/tests/dump_probes/enum_named_payload.astra`
- **INDEX/SET_INDEX de nivel módulo en el C backend sin bounds checks**:
  `emit_module_code` emitía acceso crudo a `elems[idx]`, así que
  `print(a[5])` a nivel superior leía fuera del buffer del heap, imprimía
  basura y salía con 0 (clase de fallo S11: el twin dentro de funciones ya
  estaba arreglado pero el camino de módulo no). Ambos casos pasan ahora por
  `astra_array_get`/`astra_array_set`, con el mismo error de límites que la
  VM. Pinned by `tests/codegen/toplevel_oob.astra`
- **Type references may point forward (seed + Zig)**: signatures, struct
  fields, variable annotations and enum payloads referring to a struct or enum
  declared later in the file used to fail with `unknown type '...'`. Both
  typecheckers now run a declaration-collection pass that binds every
  top-level struct/enum name to an empty type before resolving any type node,
  so declarations work in any order — including mutual recursion. Pinned by
  `tests/conformance/types/forward_type_refs.astra` (seed suite now 96 cases)
- **Emitter limits no longer fail silently (seed + Zig)**: past `MAX_CODE` the
  instruction was dropped (wrong answers with exit 0), past `MAX_CONSTS`
  `add_constant` returned index 0 (aliasing every further constant), and past
  256 locals `add_local` returned `0xFF`, which `let` silently promoted to a
  *global* — changing scoping without a word. Both emitters now report each
  limit once at the choke point and fail the compilation; pinned by
  `ui/too_many_locals.astra` (95 seed cases)
- **Zig conformance gate**: `zig build test` used to skip (green) when
  `seed/tests/conformance` was missing; it now hard-fails, as
  `PHASE2_KICKOFF.md` defines the suite as the parity gate
- **`status.sh` false red**: the dashboard parsed `failed:` with `awk '{print $2}'`
  on the shared summary line and reported "94 passed, 94 FAILED" for a green suite
- **`import` path segments are re-validated at the filesystem boundary**: `zig/src/modules/modules.zig` refuses a segment that is not an identifier (`a/b`, `..`), so a module path can never escape the importing file's directory
- **`from` with no import items was silently accepted**: `from a.b import` built a `From` that imported nothing and reported nothing; the production requires at least one item, so it now reports `expected at least one import item` (`ui/from_without_items.astra`)
- **`use` was dead code in the seed**: the type checker had no `NODE_USE` case, so every `use` declaration — an Astra-0 construct — failed with `unhandled node kind 46` (S18)
- **Module path separator drift**: the seed's `parse_use` matched `::` while its own declared grammar (`constructs/use.c`, `research/001` §12.1) says `.`; the parser now accepts the dot-separated `ImportPath` and rejects `::` (S19)
- **SHL/SHR undefined behavior**: Added range validation (`< 0 || >= 64`) and `uint64_t` cast in VM and C codegen runtime
- **String concatenation memory leak**: Added `free(buf)` after `astra_string_new` in C codegen runtime
- **Runtime errors in module code**: Modified `astra_runtime_error` to use `longjmp` when `astra_error_active` is set; updated `ASTRA_TRY_CONTEXT` macro and module-level error handlers

## [0.1.0] - 2025-XX-XX

### Added
- Initial language design and architecture
- Project repository and community infrastructure

[Unreleased]: https://github.com/AsterrZep/Astra/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/AsterrZep/Astra/releases/tag/v0.1.0
