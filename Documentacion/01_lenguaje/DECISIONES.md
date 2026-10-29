# DECISIONES — registro de decisiones de lenguaje

> **Alcance**: única fuente de verdad de *qué* está decidido sobre el lenguaje
> (semántica, layout, diagnósticos, alcance, memoria). La especificación
> normativa sigue en `ARCHITECTURE.md`; aquí se registra qué se decidió, cuándo,
> por qué, con qué coste y **qué test lo fija**. Creado: 2026-10-27.
> Mantenimiento: reglas 1–5 de `AGENTS.md` §«Language decisions».

| ID | Decisión (una frase) | Estado | Fecha | Evidencia |
|:---|:---------------------|:-------|:------|:----------|
| DEC-001 | `let b = a` comparte el handle; no copia los elementos | Aceptada (test-pinned); ratificada 2026-10-27 (D2) | 2026-09-21 | `seed/tests/conformance/arrays/alias_write.astra` (`EXPECT: 99`) |
| DEC-002 | El seed no migra los hooks `parse/check/emit`; el registro es declarativo + validado | Aceptada (doc) | 2026-09-21 | `CONSTRUCT_REGISTRY.md` §8; `--check-constructs` → `migrated: 0 / 47` |
| DEC-003 | El separador de rutas de módulo es `.` (no `::`) | Aceptada (test-pinned) | 2026-09 | `seed/tests/conformance/ui/use_colon_colon.astra` |
| DEC-004 | Los closures capturan **por valor** (copian el handle; asignar a una capturada es error de compilación) | Aceptada (test-pinned) | 2026-09 | suite `functions/`+`lambda/`; `AGENTS.md` §C Codegen |
| DEC-005 | El slot 0 de un frame es el callee/return; los parámetros empiezan en el slot 1 | Aceptada (test-pinned) | 2026-09 | `AGENTS.md` invariant 3; conformance de funciones |
| DEC-006 | Un literal fuera de rango de su tipo anotado es **error en compile-time** (con fallback a `i64` si el literal no cabe en el default `i32`) | Aceptada (test-pinned) | 2026-10-27 | `ui/int_literal_range.astra`, `ui/int_literal_range_unsigned.astra`, `types/int_width_semantics.astra` (PR fase B1) |
| DEC-007 | El overflow de enteros en runtime es **wrap definido** (two's complement, documentado); checked-overflow = flag futuro | Aceptada (test-pinned) | 2026-10-27 | `types/int_width_semantics.astra` (`s + s` → wrap) |
| DEC-008 | Las variantes de enums viven en el namespace de su enum; la construcción **calificada es obligatoria** (`A.Some2(1)`) | Aceptada (test-pinned) | 2026-10-27 | `research/027` §4; `enums/qualified_construction.astra` (EXPECT 1/2/3), `ui/enum_bare_construction_rejected.astra` (PR fase B2) |
| DEC-009 | Los VMs (seed/zig) y el backend C no liberan memoria (arena/vitalicio); la ruta LLVM libera con ARC — divergencia **documentada y gateada** con techo de RSS | Aceptada (test-pinned + gate) | 2026-10-27 | `memory/loop_reuse.astra` + gate `zig/tests/llvm_mem.sh` (techo 64 MB, CI job `llvm`) |
| DEC-010 | Los floats se imprimen con formato `%g` | Aceptada (test-pinned) | 2026-09 | conformance de expresiones |
| DEC-011 | Las sentencias se terminan con `;` o con newline | Aceptada (test-pinned) | 2026-09 | suite de conformidad (estilo mixto) |
| DEC-012 | Modelo de enforcement entre fibras = **Opción F** (`research/026`: compartir intra-fibra gratis — DEC-001 —; toda frontera exige valor único: estático si se prueba, walk `rc==1` en runtime si no; escapes = `.copy()` o `Atomic[T]`; walk = gate del primer cruce real) | **Aceptada (test-pinned)** — ratificada 2026-10-28 y fijada por el PR fase-E1 (S1/S2 + nil-red en 4 rutas); S3/`spawn` y `.copy()` siguen fuera (DEC-026 §5) | 2026-10-27 | `research/026` §3–§5; `ARCHITECTURE.md` §2.6; `ui/transfer_{aliased,used_after,captured,escaped}.astra`, `conformance/transfer/transfer_{unique,global_nil}.astra` (PR fase-E1) |
| DEC-013 | Stdlib M1: `len(x) -> i64` para arrays y strings; `s[i]` → **string de 1 byte** (OOB = error de runtime con el texto de los arrays); los strings son inmutables (`s[i] = …` es error de compilación) | Aceptada (test-pinned) | 2026-10-27 | `arrays/len_array.astra`, `expressions/len_string.astra`, `expressions/str_index.astra`, `expressions/str_index_oob.astra`, `expressions/len_int_runtime_error.astra`, `ui/str_index_assign_rejected.astra`, `codegen/str_index.astra`, `codegen/len_builtin.astra` (PR D-PR1) |
| DEC-014 | Stdlib M1: `to_string(x) -> string` **solo enteros** (otros tipos = error de runtime con el texto de las 4 rutas) y `read_file(path: string) -> string` (todo fallo de apertura/lectura colapsa en `cannot open file '<path>'`); la lectura positiva vive fuera de `conformance/` | Aceptada (test-pinned) | 2026-10-27 | `expressions/to_string_roundtrip.astra`, `expressions/to_string_float_rejected.astra`, `expressions/read_file_missing.astra`, `expressions/read_file_nil_path.astra`, `codegen/to_string.astra`, `codegen/read_file_missing.astra`, `seed/tests/selfhost/io_gate.sh` (4 rutas) (PR D-PR2) |
| DEC-015 | Los nombres de builtin (`print`, `len`, `to_string`, `read_file`) están **reservados**: redeclararlos con `let`/`const`/`fn` en cualquier ámbito es error de compilación, idéntico en los dos typecheckers | Aceptada (test-pinned) | 2026-10-27 | `ui/builtin_shadow_print.astra`, `ui/builtin_shadow_len.astra`, `ui/builtin_shadow_to_string.astra`, `ui/builtin_shadow_read_file.astra` (primera línea byte-idéntica seed↔zig) (PR D-PR2) |
| DEC-016 | El lexer de Astra-0 (`seed/tests/selfhost/lexer.astra`) es el primer componente self-hosting: lexea `lexer_input.astra` con solo los builtins M1 y emite un token por línea `<KIND>:<lexeme>@<line>`; el stream se gatea byte a byte contra `lexer.expected` en las 4 rutas, fuera de `conformance/` (cwd) | Aceptada (test-pinned) | 2026-10-27 | `seed/tests/selfhost/lexer_gate.sh` → 4/4 rutas (seed VM, `--emit-c`+gcc, zig VM, LLVM `--jit`) contra `lexer.expected` (PR D-PR3a; rutas y gate fuerte cerrados en DEC-017) |
| DEC-017 | Cierre del gate del lexer self-hosting (PR3b): `lexer_gate.sh` crece a **7 rutas** ( + `--emit-obj`+link nativo, cross aarch64 bajo qemu, wasm32-wasi bajo Node WASI con preopens — cada una con skip limpio sin su toolchain) y añade el **gate fuerte** `lexer_tokens_parity.sh` (el stream de `lexer.astra` normalizado contra `astra-seed --dump-tokens`: 1:1 en KEYWORD/IDENT(`_`)/INT(hex→valor)/PUNCT/ERROR/EOF; fuera NEWLINE, columnas, contenido de STRING, FLOAT_LIT y la cola tras el primer ERROR); CI lo cablea en los jobs `seed` y `llvm` con los mismos guards, sin renombrar checks | Aceptada (test-pinned) | 2026-10-27 | `seed/tests/selfhost/lexer_gate.sh` → **7/7 rutas** + `lexer_tokens_parity.sh` → **176 tokens** (PR D-PR3b) |
| DEC-018 | Stdlib M2a: `ord(s) -> i64` = **primer byte** de `s` (`""` = error de runtime) y `substr(s, start, len) -> string` = `len` bytes desde `start` (**error, nunca recorte**, fuera de `[0, len(s)]`); los tres parámetros de `substr` y el de `ord` son `unknown` con guards de runtime (sin coerción en la llamada), y los dos nombres se suman a la lista reservada de DEC-015 | Aceptada (test-pinned) | 2026-10-28 | `expressions/ord_basic.astra`, `expressions/ord_empty_error.astra`, `expressions/ord_int_arg.astra`, `expressions/substr_basic.astra`, `expressions/substr_bounds_error.astra`, `expressions/substr_start_error.astra`, `codegen/ord_substr.astra`, `codegen/substr_oob.astra`, `ui/builtin_shadow_ord.astra`, `ui/builtin_shadow_substr.astra` (PR D-PR4a) |
| DEC-019 | Stdlib M2b: `push(arr, v) -> array` devuelve un array **NUEVO** (copia manual; el llamante re-bindea `a = push(a, v)` y el viejo queda intacto — crecer in-place es imposible en la ruta LLVM, cuyo objeto guarda los elementos **en línea** y es compartido por todos los bindings) con **guard de homogeneidad en runtime** (`push element has type X, expected Y`), y `str_to_int(s) -> i64` = el decimal de `to_string` con **error de runtime** para entradas inválidas, vacías o fuera de rango (acepta `-`, no `+` ni espacios ni `0x`); ambos parámetros `unknown` con guards (patrón `ord`, DEC-018), retorno de `push` `array<unknown>`, y los dos nombres se suman a la lista reservada de DEC-015 | Aceptada (test-pinned) | 2026-10-28 | `expressions/push_basic.astra`, `expressions/push_alias.astra`, `expressions/push_int_arg.astra`, `expressions/push_elem_error.astra`, `expressions/push_nil.astra`, `expressions/str_to_int_basic.astra`, `expressions/str_to_int_invalid.astra`, `expressions/str_to_int_empty.astra`, `expressions/str_to_int_range.astra`, `expressions/str_to_int_int_arg.astra`, `expressions/str_to_int_nul.astra`, `codegen/push_roundtrip.astra`, `codegen/push_elem_error.astra`, `ui/builtin_shadow_push.astra`, `ui/builtin_shadow_str_to_int.astra` (PR D-PR4b) |
| DEC-020 | Stdlib M3 (cierre del MVP): `chr(i: i64) -> string` = string de **1 byte** cuyo primer byte es `i` (rango `[0, 255]` en runtime, fuera = error `chr value N out of bounds (0..255)` — la inversa de `ord`, DEC-018), `read_line() -> string` = una línea de **stdin** sin el `\n` final (EOF sin datos = error de runtime `end of input`; la ruta wasm sin stdin da el mismo EOF, comportamiento documentado), y `for c in s { … }` sobre un string itera **byte a byte** con `c: string` de 1 byte (abierto en los dos typecheckers y emitido vía el LEN+INDEX que las cuatro rutas ya tenían); `chr` y `read_line` se suman a la lista reservada de DEC-015 | Aceptada (test-pinned) | 2026-10-28 | `expressions/chr_basic.astra`, `expressions/chr_oob_error.astra`, `expressions/chr_int_arg_error.astra`, `expressions/read_line_eof_error.astra`, `loops/for_string.astra`, `codegen/chr_oob.astra`, `codegen/for_string.astra`, `seed/tests/selfhost/io_gate.sh` (lectura positiva de `read_line` con stdin desde `stdin_lines.txt`, 4 rutas) (PR D-PR5) |
| DEC-021 | El manifest del proyecto y la CLI unificada se llaman **`astraea`** — `astraea.toml` + `astraea.lock` + comando `astraea` (estilo Cargo: nombre propio del *tool*, no del lenguaje); el `astra.toml` actual se queda como marcador de raíz **hasta** que la CLI exista, y el rename llega de una vez en ese PR (nota: la DEC-020 la crea el PR de M3) | **Propuesta** (dirección decidida 2026-10-28; implementación bloqueada hasta la CLI unificada) | 2026-10-28 | Mediciones de registros 2026-10-28 (sección abajo) · Spec: `ARCHITECTURE.md` §33.2 |
| DEC-022 | `transfer(x)` es un **builtin** con sintaxis de llamada `transfer(x)` — no keyword: sin `constructs/transfer.c` ni fila de registro (`--check-constructs` sigue 47/27); el nombre se suma a las listas reservadas de DEC-015 en los dos typecheckers; la semántica (S1/S2 + invalidación R4) entra en el mismo PR que el constructo (fase E de DEC-012) | **Aceptada (test-pinned)** — PR fase-E1 | 2026-10-28 | `ui/builtin_shadow_transfer.astra` (reserva), `ui/transfer_{value_use,nested,scalar,nonvar,arity}.astra` (forma), `conformance/transfer/*` (nil-red) |
| DEC-023 | RT1 (walk `rc==1` en el cruce) vive en **M4** (ruta LLVM, que ya tiene rc desde M4.e) hasta que una decisión futura añada rc al VM Zig; M3 queda sin RT1 mientras DEC-009 mantenga la divergencia arena — el walk es gate de la primera feature con cruce real (scheduler/send), no antes | **Aceptada (doc)** — sin código hoy; el pin (`EXPECT-RUNTIME-ERROR: cannot transfer: value graph is shared`) llega con el scheduler, suite Phase 2 | 2026-10-28 | `research/031` §1-P1 («RT1 vive en M4…») y §3-F; `research/027` §3.2 op. 3A; `research/026` §3.2 fila RT1 (enmendada por cita) |
| DEC-024 | Stdlib post-M3 en **Astra puro** (no builtins, plan de `research/028` §1.2): funciones `contains(s, sub) -> bool` (aguja vacía = `true`), `index_of(s, sub) -> i64?` (ocurrencia más a la izquierda; ausente = `none`; aguja vacía = `some(0)`), y `split(s, sep) -> [string]` (campos se preservan, sep al inicio/final da campo vacío, sin sep = `[s]`, **`sep` vacío = array de bytes de `s`** — caso especial tipo JS; nunca error, porque el código de usuario no puede lanzar errores de runtime) — cada test define sus helpers en línea (no existe stdlib compartida: el seed compila un fichero y `std/…` está rechazado) y los nombres **no** se reservan (libres para el usuario y para un futuro `Array.contains` de `research/015`) | Aceptada (test-pinned) | 2026-10-28 | `conformance/stdlib/{contains_basic,index_of_basic,split_basic,split_fields,split_chars_empty_sep}.astra`, `codegen/{contains,split}_roundtrip.astra`, `codegen/split_fields.astra` (4 rutas verificadas) (PR stdlib-postM3) |
| DEC-025 | **`parser.astra` es el segundo componente self-hosting**: parser de Astra-0 (v1) en Astra-0 que lee `parser_input.astra` (subconjunto: items `const`/`fn` con params y retorno, statements con `;` obligatorio, `let`(+mut, tipo opcional), assign, if/else/else-if, while, return, break; exprs con literales int decimal/string plano/bool, unary -/!, precedencia de la tabla de operadores, calls, index, paréntesis, array literals); emite el AST como **s-expresión prefijo de una línea** y se gatea contra `parser.expected`, golden generado por `--dump-ast | normalize_ast.awk` (implementaciones independientes: parser C vs Astra-0) en **7 rutas** + **freshness check** del golden en cada corrida; fuerza `;` en todo statement y no modela NEWLINE-terminador, escapes de string ni literales hex — límites declarados, no accidental | Aceptada (test-pinned) | 2026-10-28 | `seed/tests/selfhost/parser_gate.sh` → 5/5 rutas locales (seed VM, `--emit-c`+gcc, zig VM, `--jit`, `--emit-obj`+link; cross/wasm skip limpio sin toolchain) + freshness `--dump-ast` == golden · CI jobs `seed` y `llvm` · fixture `parser_input.astra` (corre: 31/true) (PR parser-selfhost) |
| DEC-026 | **Fase E v1 de enforcement — detalles de `transfer` sin fibras**: solo la forma-directa-sentencia `transfer(x);` (1 argumento, variable desnuda); tipos escalar rechazados en compile-time (`transfer expects an aggregate, got i32`); S1/S2 como pasada post-typecheck en los 2 frontends con las semánticas de `research/026` §3.3 (Único/Aliased/Escapado + movidos, alcance por bloques, joins conservadores en if/loops, alias por `let y = x` **sonoro** (ambos → Aliased), escapes por call no-builtin/contenedor/captura, globales usados desde fn = Escapado al transferir); nil-red de R4 en los emisores (`CONST nil; SET` del binding, observable solo en globales entre funciones — S1 es intraprocedural); mensajes nuevos: M1 `transfer must be called directly as transfer(variable)`, M2 `transfer must be its own statement`, S2-escaped `cannot transfer 'x': value has escaped`; S3/`spawn` y `.copy()` quedan fuera (siguiente PR / Phase 2) | Aceptada (test-pinned) | 2026-10-28 | `ui/transfer_{aliased,used_after,captured,escaped,nested,value_use,scalar,bad_form}.astra`, `ui/builtin_shadow_transfer.astra`, `conformance/transfer/transfer_unique.astra`, `conformance/transfer/transfer_global_nil.astra` (EXPECT-RUNTIME-ERROR), `codegen/transfer_unique.astra` (PR fase-E1) |
| DEC-027 | **`.copy()` — fase E2**: deep copy estructural **solo en forma de método** `x.copy()` (la forma directa `copy(x)` no existe: el nombre no se registra como símbolo → `copy must be called as x.copy()`); nombre **reservado** en kBuiltins/k_builtins (`ui/builtin_shadow_copy`); receptor con el mismo conjunto de tipos que `transfer` (agregados+string+optional+unknown, escalares → `copy expects an aggregate, got i32`); devuelve el **tipo estático del receptor**; `x.copy(args)` → `copy takes no arguments`; semántica: recursivo sobre arrays/structs/enum/optional-caja (parejas: bits+retain), strings **compartidos** (inmutables, retain en LLVM), closures = shell nuevo con env profundo y **markers compartidos** (despacho por identidad de puntero), **depth cap 64** → `copy depth limit exceeded` (ciclos construibles: `n.kid = some(n)`); walker: el receiver de un **método de usuario** pasa a escaparse (S2) pero el de `.copy()` no; el receiver de `.copy()` NO escapa (la fuente queda transferible) | Aceptada (test-pinned) | 2026-10-28 | `ui/builtin_shadow_copy.astra`, `ui/copy_{scalar,extra_args,value_use}.astra`, `ui/transfer_method_escaped.astra`, `conformance/transfer/{transfer_copy,copy_independent,copy_cycle}.astra` (ciclo = EXPECT-RUNTIME-ERROR), `codegen/{transfer_copy,copy_independent}.astra` (PR fase-E2) |
| DEC-028 | **parser.astra v2 — NEWLINE como terminador + `match` + items `enum`** (paso 1–2 del plan de `PHASE1_PROGRESS` §7): fin de sentencia = `;` **o** cambio de línea **o** `}` **o** EOF (espejo del `optional_semi` del seed, verificado: `fn f() -> i32 { return 5 }` y `let a = 1`\n`let b = 2` sin `;` son válidos); `else` exige **misma línea** que el `}` que cierra el then (el seed rechaza `}\nelse`); expresiones **no** continúan tras NEWLINE en el seed (`let x = 1 +`\n`2` → error) → el fixture evita operadores a fin de línea (límite declarado); `match`: comas **obligatorias** entre brazos (sin coma el seed falla, verificado), trailing opcional, guardas parseadas pero **no emitidas** (el dump del seed omite el guard — mirror lossy de PHASE2 §7); patrones = literal(+`-`)/string/bool/`PatternOr(n)`/`PatternWildcard`/ruta calificada `FieldAccess`/binding `PatternBind`/`PatternVariantBind`+`Bind(name)`; items `enum` con `Variant(name)`+`Field(TypeIdent)`; fixture v2 mezcla sentencias con y sin `;` para cubrir ambos caminos; sin lambdas aún (siguiente paso) | Aceptada (test-pinned) | 2026-10-29 | `seed/tests/selfhost/parser_gate.sh` (fixture `parser_input.astra` v2 + `parser.expected` regenerado de `--dump-ast` + freshness en las 7 rutas) (PR parser-v2) |
| DEC-029 | **parser.astra v2.1 — lambdas** (paso 2 de `PHASE1_PROGRESS` §7, cerrado): `|params| [-> type] { block }` — el cuerpo **exige bloque** (el seed rechaza `|y| y * 2`, verificado); sin parámetros: `||` es el token OR_OR y el seed lo rechaza, `| |` (espaciado) sí parsea y typecheckea con `-> T` — el parser acepta ambas grafías vía el mismo loop; **tipos de parámetro y `-> ret` se parsean y se descartan del dump**: el dump del seed imprime `Lambda [Param(name)]* [TypeIdent(ret)] Block` — el TypeIdent es SOLO la anotación de retorno (verificado: `|x: i32| -> i32` imprime TypeIdent, `|a: i32, b: i32|` sin `->` no imprime ninguno); sin tipos fn en anotaciones (parse_type v2 sigue con ident simple); fixture con 4 lambdas (tipada+ret, identidad sin tipar, multi-tipada, `| | -> i32`) + llamadas, todas terminadas por NEWLINE | Aceptada (test-pinned) | 2026-10-29 | `seed/tests/selfhost/parser_gate.sh` (fixture v2.1 + golden regenerado + freshness, 7 rutas) (PR parser-lambdas) |
| DEC-030 | **parser.astra v2.2 — capa de items** (paso 3 de `PHASE1_PROGRESS` §7): `struct` (fields `nombre: Tipo` → `Field(name)+TypeIdent`), `trait` (solo firmas `fn` sin cuerpo → `Block` vacío — el seed sintetiza el bloque; métodos-default = rechazo del typecheck, no del parser), `impl [Trait for] Type` (`Impl(Area for Punto)` / `Impl(Punto)`, payload = texto crudo) y `pub` delante de fn/struct/const/enum/trait (`Pub*Decl`, nombres verificados: PubFnDecl/PubStructDecl/PubConstDecl/PubEnumDecl/PubTrait); `use`/`import`/`import … as`/`from … import …` con rutas punteadas — el dump de `use` va **sin payload** (mirror lossy) y `Import(path as alias)`/`ImportItem(n as a)` llevan el texto crudo; **struct literals** con la misma regla del flag `no_struct_lit` del seed (parser.c:1894): `IDENT {` = literal salvo en condiciones de `if`/`while` y target de `match` (el flag se pone en esas 4 contextos y se restablece dentro de paréntesis — verificado en parser.c:649/704/730/910); `Punto {}` vacío aceptado; parámetros con `:` opcional (`self` tipado-less solo en trait/impl en el seed — el parser v2.2 lo admite en cualquier fn, límite declarado); sin genéricos en items; sin `pub` antes de impl/use/import; sin literales float en el fixture (el dump usa %g y `to_string` es solo-enteros) | Aceptada (test-pinned) | 2026-10-29 | `seed/tests/selfhost/parser_gate.sh` (fixture v2.2 + golden regenerado + freshness, 7 rutas) (PR parser-items) |
| DEC-031 | **parser.astra v2.3 — diagnósticos de error con paridad de primer error** (paso 4 de `PHASE1_PROGRESS` §7): formato del seed `file:line:col: error: msg` (parser.c:78/133) con las dos formas — expect `expected <msg>, got <kind>` (got = token_kind_name: keywords en minúscula, IDENT/INT_LIT/STRING_LIT/EOF en mayúscula, `_` es token propio) y parser_error `<msg>` sin got; síntesis de NEWLINE donde el seed la vería (call `)` sin skip_newlines: `print(1\n}` → `expected *')', got NEWLINE` en fin-de-línea); `error: parse failed` final + supresión del AST con errores (driver.c:668); **correcciones de comportamiento verificadas contra el seed**: el separador NUNCA es obligatorio (`print(1) print(2)` parsea — corrige el modelo de DEC-028 §1), `=` opcional en `let` (`let x 5;` = VarDecl+sentencia), sentencias a nivel de módulo (`foo bar` = dos idents), la coma faltante de `match` NO se reporta (rompe y el `}` esperado choca: `expected *'}', got <kind>`), `else` en línea aparte cae como sentencia (`unexpected token in expression`), `invalid assignment target` para no-LValue; gate `parser_diag_parity.sh` = paridad del PRIMER error + línea final sobre 16 fixtures rotos (la cascada posterior DIFEREE y queda fuera de alcance — recuperación completa = paso siguiente) | Aceptada (test-pinned) | 2026-10-29 | `seed/tests/selfhost/parser_diag_parity.sh` → 16/16 (primer error + parse-failed byte-idénticos, rutas dentro de `parser_gate.sh`) (PR parser-diag) |
| DEC-032 | **Typechecker en Astra-0 — alcance v1** (paso 5 de PHASE1 §7; criterio: filosofía §«Todo está permitido siempre que mejore Astra» + «simplicidad como estrategia»): **7 rutas** (patrón lexer/parser, sin regalar rigor); **AST = tablas SoA** en `parser.astra` — `struct { kind: [i64], a: [i64], b: [i64], s: [string] }` — con la s-expresión pasando a *rendering* de esas tablas (los gates existentes quedan byte-idénticos) y **concatenación en el gate** (`parser.astra` sin su `main` + `typechecker.astra`, colisiones de nombre delatadas ruidosamente por el typecheck del seed); corpus ≈176 ficheros medidos con **lista de exclusión explícita** (5 `ui/` emitter-owned + 12 `transfer_*` de §8b — capas ajenas al typechecker, como `llvm_parity` EXCLUDE con comentario, nunca silencio); **espejo byte a byte de `typechecker.c`** como verdad (doctrina dump-parity: los 102 mensajes son la referencia; divergir exige DEC primero — sin forks silenciosos de semántica); `some/none/ok/err` pasan a emitirse en las formas del seed (prerequisito del port; la sintaxis `T?`/`[T]` queda en el backlog medido del parser); **single-file** `selfhost/typechecker.astra` (LLVM no compila multi-fichero; el árbol `src/compiler/` viene en Step 4 con la CLI — DEC-021 intacta); presupuesto: **sin techo nuevo** — los 256 globales del VM son la guarda automática (fallo ruidoso) y el combinado parser+typechecker se diseña ≤200; orden: typechecker → emitter (028 §5 «codegen va el último»); milestones M-T1 (SoA) → M-T2 (núcleo ~35 checks + gate diferencial) → M-T3 (methods/trait/match/exhaustividad) → M-T4 (corpus completo), ~10–15 d/h en 4–5 PRs | Aceptada (doc) | 2026-10-29 | `research/032` (inventario de ~55 checks, corpus 189/304 medido, restricciones LLVM con citas, shape del gate) + DEC-033 (los dos pines previos) |
| DEC-033 | **Dos formas de control-flow que AMBOS compiladores rechazan (pines previos al typechecker)**: (a) `if/else if/else` como **última expresión de un `fn`** → `if branches have different types: <T> vs void` (el if-cadena anidado tipea void en la cola; un `if/else` simple SÍ funciona — verificado en seed y zig con salida idéntica, 2 errores); (b) `}` NEWLINE `else` → `unexpected token in expression` en el `else` (el NEWLINE rompe el binding del else — verificado; primeras líneas byte-idénticas seed↔zig, el zig cascade extra es informativo); ambos se **pinnean como están** (test-pinned = registrar, no re-litigar — regla 2); el parser.astra ya impone (b) por su regla de misma línea y (a) es de fase de tipos; corregirlos en el futuro = PR propio con DEC que superscriba, nunca fork silencioso | Aceptada (test-pinned) | 2026-10-29 | `ui/elseif_tail_rejected.astra` (EXPECTED-ERROR `if branches have different types` + FIRST `2:5`), `ui/else_newline_rejected.astra` (EXPECTED-ERROR `unexpected token in expression` + FIRST en el `else`) — primera línea idéntica en seed y zig (`ui_message_parity.sh`) (PR DEC-032/033) |

### DEC-006 — Ancho de enteros: rango en compile-time, wrap en runtime
- **Estado**: Aceptada (test-pinned) — fijada en el PR de fase B1 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: `let big: i32 = 9999999999` pasa a ser error de compilación
  (hoy imprime `9999999999`); sin anotación, un literal que no cabe en el
  default `i32` cae a `i64`. El overflow en runtime queda **wrap definido y
  documentado**; checked-overflow puede llegar como flag.
- **Alternativas consideradas**: truncar/saturar en runtime (rompe la
  intuición de C y cuesta en 4 runtimes); ancho real en el bytecode (requiere
  bytecode con tipos — el backend C lee bytecode sin tipos, `research/027` §1).
- **Coste aceptado**: 2 typecheckers (seed + zig); 0 runtimes; mensajes
  seed↔zig byte-idénticos.
- **Evidencia**: fijado por `ui/int_literal_range.astra`,
  `ui/int_literal_range_unsigned.astra` y `types/int_width_semantics.astra`
  (el cuarto EXPECT prueba el fallback `let big = 9999999999` → i64).
- **Spec**: `research/027` §1 — «pendiente de escribir en ARCHITECTURE §8/§9».

### DEC-008 — Variantes de enums: namespace por enum, construcción calificada
- **Estado**: Aceptada (test-pinned) — fijada en el PR de fase B2 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: la construcción **calificada `Enum.Variant(...)` es la única
  legal** para variantes de usuario: `Some2(1)` se rechaza siempre con
  «use Enum.Variant to construct 'Some2'» (no solo cuando hay colisión), y
  el registro plano deja de resolver la forma pelona. Los builtins
  `some/ok/err/none` (Option/Result) siguen pelones: el usuario escribe
  `some(x)`. Las variantes unitarias calificadas ya funcionaban; los
  patrones ya exigen calificación.
- **Alternativas consideradas**: «pelón si es inequívoco» (cuesta 0 tests
  pero deja dos ortografías para siempre y empeora con módulos);
  status quo (primer enum en ganar) — el bug sigue vivo.
- **Coste aceptado**: 2 typecheckers + 3 emisores; 12 conformance + 5
  codegen + 5 fixtures LLVM + 2 unit zig + `llvm_fuzz_gen.py` (lista exacta
  en `research/027` §4).
- **Evidencia**: `enums/qualified_construction.astra` (EXPECT 1/2/3 —
  homónimos `A.Some2`/`B.Some2` sin colisión) y
  `ui/enum_bare_construction_rejected.astra` (EXPECT-ERROR: use
  Enum.Variant to construct 'Some2'); calificados los 12 conformance +
  5 codegen + 5 fixtures LLVM + 2 unit zig + el generador. Gates:
  `make test` 265/0, `sweep_emit_c` fail=0, `zig build test` verde,
  `ui_message_parity` first_fail=0, `dump_parity` 0 divergent,
  `llvm_parity` fail=0, `llvm_fuzz` fail=0.
- **Spec**: `research/027` §4.

### DEC-012 — Enforcement entre fibras: Opción F (ratificada)
- **Estado**: **Aceptada (doc)** — ratificada el 2026-10-28. La Fase 0 está
  completa: `ARCHITECTURE.md` §2.6 escrita (PR #15), invariant 8 en
  `AGENTS.md` y las notas de `§35.5`/`COMPARATIVE_ANALYSIS` añadidas en el
  PR de ratificación. La **implementación queda pospuesta** al PR «fase E»
  (constructo + S1/S2/S3 en los 2 frontends + `.copy()` en 4 motores); no
  existe código hoy (`transfer` no lexea, `grep` → 0 en ambos árboles).
- **Fecha**: 2026-10-27 (dirección); 2026-10-28 (ratificación).
- **Decisión**: compartir intra-fibra es gratis (DEC-001); **cruzar frontera
  de fibra exige valor único en ese punto** — estático si se prueba, walk de
  `rc` en runtime si no; si no es único → `.copy()` o `Atomic[T]`.
  `transfer(x)` será un **builtin** con sintaxis de llamada (fijado en
  DEC-022). El walk RT1 vive en **M4** y llega con el primer feature con
  cruce real — scheduler/send (fijado en DEC-023) — sin rc en los VMs antes
  de tiempo.
- **Alternativas consideradas**: A tracing GC (contradice «sin pausas»);
  B RC atómico aceptando carreras (contradice «thread-safe»); D owner-check
  por acceso (queda como red de v2, no como base); E sin mutable compartido
  (pierde el pitch).
- **Coste aceptado (estimación calibrada 2026-10-28**, opinión calibrada —
  no hay velocidad histórica por feature en el repo, `research/031` §4):
  el PR fase E completo se estima en **~15–25 días-hombre**: plumbing de
  `transfer` en 4 motores (8–9 ficheros, patrón DEC-013..020, ~4–6 d por
  builtin) + análisis de flujo S1/S2 intraprocedural × 2 frontends (misma
  clase que el `lastReadOf` de Nim, `research/026` §3.3) + S3 (cierre de
  efectos sobre globales en el grafo de llamadas del módulo) + `.copy()`
  (copia estructural profunda × 4 motores, sin rc — el seed puede llevarlo)
  + la batería UI/conformance/paridad (FC/FZ byte-idénticos).
- **Evidencia**: `research/026` §3–§5 (spec operativa R1–R7);
  `research/031` §1-P1/P2/P8 — los cuatro huecos que abrió (sintaxis de
  `transfer`, alcance del RT1, estimación, Fase 0) quedan cerrados por
  DEC-022, DEC-023, la estimación de arriba y este PR. Evidencia ejecutable
  pendiente hasta el PR fase E: `ui/transfer_{aliased,used_after,captured}.astra`,
  `ui/spawn_global_atomic.astra`, `conformance/transfer/transfer_{unique,copy}.astra`.
- **Spec**: `ARCHITECTURE.md` §2.6.

### DEC-013 — Stdlib M1: `len(x)` y `s[i]` (índice de string)

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR1 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**:
  - `len(x) -> i64` para **arrays** (número de elementos) y **strings**
    (número de bytes). Registrado como builtin con parámetro `unknown` — igual
    que `print` —, así que cualquier receptor pasa el typechecker y el guard
    de runtime (`cannot take length of <tipo>`, el texto que ya usaba
    `OPCODE_LEN`) es la superficie de paridad entre las 4 rutas.
  - `s[i]` sobre un string devuelve un **string de 1 byte** (byte, no
    codepoint: el lexer del seed es byte-oriented). El typechecker lo acepta
    como lectura; el índice sigue teniendo que ser entero. **Fuera de rango =
    error de runtime con el mismo texto que los arrays**
    (`index N out of bounds (len M)`); receptor nil → `cannot index nil`.
  - Los strings son **inmutables**: `s[i] = …` es error de compilación
    (`cannot assign to string element`) — se rechaza en el typechecker, no en
    runtime, para que ninguna ruta lo ejecute.
  - `i32` y floats siguen rechazados con el mensaje actual
    (`cannot index non-array type …`, `ui/index_non_array.astra` intacto).
- **Alternativas consideradas**: código numérico (Go) en vez de 1-byte-string
  (habría roto `match c { "(" => …, _ => … }` y `==` por contenido, que ya
  funcionan en 4 rutas, y no existe char literal); `char_at(s, i)` como builtin
  (gastaba el plumbing completo de un builtin sin reutilizar `OPCODE_INDEX`);
  restringir `len` a `string|array` en compile-time (`research/028` §1.3 lo
  recomienda) — pospuesto: exige un caso `ui/` con primera línea byte-idéntica
  y el guard de runtime ya existe en las 4 rutas; discriminador `builtin_id` en
  `FnObj` — descartado por ahora: identidad de puntero por marcador (un FnObj
  por builtin) deja `astra.h` intacta.
- **Coste aceptado**: 4 implementaciones (seed VM, backend C, zig VM,
  LLVM+runtime) en 7 ficheros de código; 8 tests; los JIT/wasm/aarch64 heredan
  el runtime LLVM sin código propio.
- **Evidencia**: fijado por `arrays/len_array.astra` (3/1),
  `expressions/len_string.astra` (5/0 — incluye `len("")` → 0),
  `expressions/str_index.astra` (lectura + concat + `==`),
  `expressions/str_index_oob.astra` (`index 5 out of bounds (len 5)`),
  `expressions/len_int_runtime_error.astra` (`cannot take length of int`),
  `ui/str_index_assign_rejected.astra` (primera línea byte-idéntica seed↔zig),
  `codegen/str_index.astra` y `codegen/len_builtin.astra` (redondeo C). Gates
  del PR: `make test` 276/0, `sweep_emit_c` total=122 fail=0, `make debug`
  (ASan/UBSan/LSan) 276/0, `make release` 276/0, `zig build test` verde,
  `ui_message_parity` first_fail=0, `dump_parity` 0 divergent,
  `llvm_parity` 170/170 (opt=0 y opt=2), `llvm_jit` 170/170,
  `llvm_fuzz -n 20 -s 1` fail=0, `--check-constructs` OK.
- **Spec**: `research/028` §1.2 (firmas M1) y §3 (PR1) — «pendiente de
  escribir en ARCHITECTURE».

### DEC-014 — Stdlib M1: `to_string(x)` y `read_file(path)`

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR2 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**:
  - `to_string(x) -> string` convierte **solo enteros**. El parámetro se
    registra como `unknown` — igual que `print`/`len` — porque el checker no
    puede expresar «cualquier entero» sin romper el default `i32` de DEC-006;
    el rechazo es de **runtime** y con texto idéntico en las 4 rutas
    (`to_string expects an int, got <tipo>`, con el `type_name` del VM). Los
    floats quedan **fuera del MVP** a propósito: el formato decimal de float
    es otra decisión (DEC-010 solo fija cómo imprime `print`), y lo que el
    lexer necesita es numerar líneas/columnas (`research/028` §1 MVP #4).
  - La conversión usa **la misma conversión que `print`** en cada ruta —
    `%ld`/`(long)` en seed y backend C, `{d}` en zig, `%lld`/`(long long)` en
    LLVM (ésta además es correcta en wasm32/ILP32, donde `long` mide 32
    bits), de modo que `print(to_string(n))` es byte-idéntico a `print(n)`.
  - `read_file(path: string) -> string`: parámetro **anotado string**, así
    que `read_file(42)` es error de compilación en ambos checkers; un valor
    nil bajo anotación string (`let s: string` sin inicializar) se rechaza en
    runtime con `expected string path, got nil`.
  - **Todo fallo de apertura/lectura colapsa en un único runtime error**
    `cannot open file '<path>'` (la frase del driver del seed sin el prefijo
    `error:`, porque los errores de runtime ya llevan `file:line: runtime
    error:`), para que las 4 rutas sean byte-idénticas — incluye leer un
    directorio en Linux (`fopen` abre y `fread` falla) y los errores de WASI.
  - **Colocación de la lectura positiva**: no vive en `conformance/`
    (`research/028` §2.4: los gates corren con cwd distinto — `seed/`,
    `zig/`, raíz del repo — y la ruta wasm no tiene `preopens`); vive en
    `seed/tests/selfhost/` (fixture `fixture_read.txt` + golden
    `read.expected` + `io_gate.sh` con `cd` fijo, §4.3). `conformance/` solo
    lleva los casos negativos, con un path inventado que no existe en
    ningún cwd.
- **Alternativas consideradas**: `to_string` polimórfico (i64|f64|str|bool)
  — pospuesto junto al formato de float; parámetro `i64` anotado para
  rechazar floats en compile-time — rompe DEC-006 (un literal sin anotar es
  i32 y ya no calzaría con el parámetro); `read_file` con `Option`/`Result`
  (`ARCHITECTURE.md:1617` especula `read_file(path)?`) — Astra-0 no tiene
  `FileError` y el `?` puede añadirse después sin tocar este texto; errores
  distintos por causa (not-found/permission/is-a-directory) — añade
  divergencia entre runtimes (WASI no distingue igual) sin aportarle al
  lexer; leer el tamaño con `fseek`/`ftell` — descartado: el tamaño no es
  fiable en todos los destinos (procfs, wasm), se lee por bloques en las 4
  rutas.
- **Coste aceptado**: 4 implementaciones (seed VM, backend C, zig VM,
  LLVM+runtime) en 8 ficheros de código; 6 tests + un gate propio de cwd
  fijo; JIT/wasm/aarch64 heredan el runtime LLVM (la ruta wasm necesita
  `preopens` en `demo/wasi_run.mjs`, añadido en este PR).
- **Evidencia**: fijado por `expressions/to_string_roundtrip.astra`
  (42/-7/0/`true`/9007199254740993/`n=42`),
  `expressions/to_string_float_rejected.astra`
  (`to_string expects an int, got float`),
  `expressions/read_file_missing.astra` (`cannot open file '…'`),
  `expressions/read_file_nil_path.astra` (`expected string path, got nil`),
  `codegen/to_string.astra` y `codegen/read_file_missing.astra` (redondeo C),
  y `seed/tests/selfhost/io_gate.sh` → 4 rutas ok (seed VM, `--emit-c`+gcc,
  zig VM, LLVM `--jit`) contra `read.expected`. Gates del PR: `make test`
  286/0, `sweep_emit_c` total=126 skip=3 fail=0, `make debug`
  (ASan/UBSan/LSan) 286/0, `make release` 286/0, `zig build test` verde,
  `ui_message_parity` first_fail=0 (total=125), `dump_parity` 0 divergent
  (164 files), `llvm_parity` 176/176 (opt=0 y opt=2), `llvm_jit` 176/176,
  `llvm_sanitize` 176/176 + LSan limpio, `llvm_cross` 176/176 (aarch64),
  `llvm_filecheck` 8/8, `llvm_fuzz -n 20 -s 1` fail=0, `--check-constructs`
  OK, `io_gate` 4/4; la ruta wasm no corrió localmente (sin `wasm-ld`: la
  hace CI, `preopens` ya en `demo/wasi_run.mjs`).
- **Spec**: `research/028` §1 (firmas M1) y §3 (PR2) — «pendiente de
  escribir en ARCHITECTURE».

### DEC-015 — Nombres de builtin reservados (anti-shadowing)

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR2 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: `print`, `len`, `to_string` y `read_file` **no pueden
  redeclararse** — ni como `let`, ni como `const`, ni como `fn` — **en
  ningún ámbito** (módulo incluido). El error es
  `'<nombre>' is a builtin and cannot be redeclared`, byte-idéntico en los
  dos typecheckers.
  - Motivo: el VM resuelve los builtins por **nombre** en `GET_GLOBAL` y el
    emisor LLVM decide la llamada por **nombre** en `emitCall` *antes* de
    mirar tablas de fns/locales; un binding llamado `len` se ejecutaría como
    slot en unas rutas y como builtin en otras. El bug observable ya
    existía a nivel de módulo: `let len = 5` imprimía `<fn>` en el VM semilla
    y `5` en el backend C.
  - Un `fn print()` de nivel superior se reporta en la **primera pasada y
    antes** del chequeo de `duplicate function` (que habría nombrado la
    regla equivocada: el símbolo builtin parecía un segundo `print`), y
    exactamente una vez — el cuerpo se sigue comprobando en la pasada 2 sin
    registrar el símbolo.
- **Alternativas consideradas**: rechazar solo en nivel de módulo — dejaba
  el hueco local abierto para LLVM; permitir el shadowing y resolver
  identidades en el emisor LLVM — coste alto (tablas de bindings en
  `emitCall`) y rompe «los builtins son globales»; reutilizar el mensaje
  «duplicate function» — menciona la regla equivocada.
- **Coste aceptado**: 2 typecheckers × 3 puntos de anclaje (var, const, fn),
  ningún runtime. **Fuera de alcance y conocido**: los *enlaces* de `for` y
  los patrones de `match` no se chequean (`for len in … { print(len) }` hoy
  funciona y es inocuo en las 4 rutas); sombrear un binder **invocable**
  divergiría entre slot (VM/C/zig) y nombre (LLVM) — se cubrirá si algún
  binder futuro lo permite declarar.
- **Evidencia**: `ui/builtin_shadow_print.astra` (fn, pasada 1),
  `ui/builtin_shadow_len.astra` (let de módulo),
  `ui/builtin_shadow_to_string.astra` (const) y
  `ui/builtin_shadow_read_file.astra` (let local: el ámbito cualquiera) —
  los 4 con **una sola** diagnóstica y la primera línea byte-idéntica
  seed↔zig.
- **Spec**: «pendiente de escribir en ARCHITECTURE».

### DEC-016 — Lexer de Astra-0 como gate de self-hosting

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR3a (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: `seed/tests/selfhost/lexer.astra` — un lexer mini **escrito
  en Astra-0** — es el primer componente self-hosting de la cadena de
  bootstrap (`research/028` §4.2/§5: el lexer es E/S + cómputo puro sobre
  bytes, no toca ABI). Usa solo los builtins M1 de DEC-013/DEC-014 (`len`,
  `s[i]` → 1 byte, `to_string` solo enteros, `read_file`) más lo que
  Astra-0 ya tenía (`==`/`+` de string, `match` con literales + or-patterns
  + `_`, `while`/`continue`, structs). Su salida es **un token por línea**
  con el formato fijado en el propio fichero (comentario de cabecera):
  - `<KIND>:<lexeme>@<line>` con `KIND ∈ KEYWORD | IDENT | INT | STRING |
    SYMBOL | OP | ERROR`; la última línea de toda ejecución es
    `EOF@<line>`; en `ERROR` el hueco del lexeme es un mensaje
    (`ERROR:unknown char '$'@41`, `ERROR:unterminated string@<n>`).
  - Cobertura de tokens: los **36 keywords** de `seed/src/lexer.c`
    (tabla `keyword_kind`), identificadores con `_` y dígitos, enteros
    decimal y hex (`0x…`), strings con escapes copiados verbatim
    (`\\ \" \n` y bytes UTF-8 alto pasan tal cual), comentarios `//` (sin
    emitir), operadores de 1 y 2 chars (`== != <= >= && || -> :: => ..`) y
    puntuación `( ) { } [ ] + - * / = ; , . : | ! < > ?`.
  - **Ubicación**: `seed/tests/selfhost/`, junto a `io_gate.sh` y **nunca**
    en `conformance/` (DEC-014, `research/028` §2.4: los gates corren con
    cwd distinto — `seed/`, `zig/`, raíz — y la ruta wasm no tiene
    `preopens`; un caso con `read_file` ahí fallaría por el camino de
    ejecución, no por el lenguaje). El gate `lexer_gate.sh` fija el cwd con
    `cd "$here"` y compara **byte a byte** contra el golden commiteado
    `lexer.expected` en las **4 rutas** (seed VM, `--emit-c`+gcc, zig VM,
    LLVM `--jit`); el fixture `lexer_input.astra` es un Astra-0 no trivial
    (struct, enum, match, closures, `for..in` con rango, escapes, hex) con
    **un carácter inválido `$` a propósito** para que el golden fije también
    el camino de error — solo se lexea, nunca se compila.
- **Alternativas consideradas**: (1) usar `lexer.astra` como su propio
  fixture — descartado: cada edición del lexer regenera un golden gigante
  (los 52 or-patterns de `is_alpha` ocupan solos decenas de tokens) y se
  pierde el valor de regresión; (2) gate «fuerte» contra
  `astra-seed --dump-tokens` en el mismo PR (`research/028` §4.3) —
  **pospuesto a PR3b**: los formatos difieren (el C imprime
  `<línea>:<col>  <KIND>  <lexeme>`, **incluye tokens NEWLINE** que este
  lexer se salta, y da a cada operador su propio KIND mientras aquí se
  agrupan en `SYMBOL:`/`OP:`), así que la normalización necesita su propio
  diseño (resuelto en PR3b: DEC-017); (3) el formato `"<KIND> <lexeme> @<line>"` de `research/028`
  §4.2 — se eligió `<KIND>:<lexeme>@<line>` (separador `:` como en la
  propia lista de ejemplos del informe, con `@line` conservado).
- **Coste aceptado**: 0 cambios de código de compilador (ni seed ni zig);
  4 ficheros nuevos en `seed/tests/selfhost/`. Lexemas por concat `+`
  (O(n²)) y `is_alpha` con 52 or-patterns literales en una sola línea (el
  parser no continúa un patrón de match a través de NEWLINE): sin `substr`
  ni `ord` (M2, PR4) — con esos builtins el lexer se acorta sin tocar el
  gate. `let mut i: i64` es obligatorio: `len` devuelve `i64` y comparar
  anchos distintos en `i < n` es error de compilación (DEC-006).
- **Evidencia**: `seed/tests/selfhost/lexer_gate.sh` → **4/4 rutas ok**
  (seed VM, C backend `--emit-c`+gcc, zig VM, LLVM `--jit`) contra
  `lexer.expected` (179 líneas; sha256
  `f3e66f929e8084d6ea2a74562030e0b0836728fd4310b51b1118f919dbe71498`);
  `io_gate.sh` sigue 4/4 y `make test` 286/0 (este PR no añade casos de
  conformance — el lexer vive fuera por decisión propia).
- **Spec**: «pendiente de escribir en ARCHITECTURE» (`research/028` §4.2/§4.3
  es la spec de facto: formato de salida, cobertura y ubicación del gate).

### DEC-017 — Cierre del gate del lexer self-hosting (PR3b de DEC-016)

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR3b (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: tres piezas, todas en `tests/` y CI — **0 cambios de
  compilador** (ni seed ni zig):
  1. **Rutas nuevas de `lexer_gate.sh`** (4 → 7): además de seed VM,
     `--emit-c`+gcc, zig VM y LLVM `--jit`, la ruta nativa de producción
     `--emit-obj` + enlace del runtime TU (receta `llvm_parity.sh`), la ruta
     cross aarch64 (`--emit-obj --target` + `aarch64-linux-gnu-gcc` + qemu)
     y la ruta wasm32-wasi (`--emit-obj --target` + `wasm-ld` + wasi-libc +
     Node WASI vía `demo/wasi_run.mjs`, que desde PR2 lleva
     `preopens {"/": cwd}` — `read_file` funciona en wasm). Cada ruta nueva
     tiene **skip limpio** (no fallo) si falta su toolchain o si el zig no
     está construido con `-Dllvm`.
  2. **Gate fuerte** `lexer_tokens_parity.sh`: la salida de `lexer.astra` y
     la de `astra-seed --dump-tokens lexer_input.astra` se **normalizan**
     (awk embebido) a `line KIND value` y se comparan con diff — 176 tokens
     en el fixture commiteado. KINDs que mapean 1:1: KEYWORD (el dump
     imprime el keyword como su propio kind), IDENT (`_` del dump ≡
     `IDENT _`: `lexer.astra` no tiene token UNDERSCORE), INT (el dump
     imprime el valor parseado — `0x2A` ≡ `42`; el normalizador convierte
     hex→decimal), PUNCT (`SYMBOL:`/`OP:` ≡ los kinds por-operador del
     dump), ERROR (KIND+línea; el dump no imprime el mensaje) y EOF.
     **Fuera del gate** (parcial honesto, con la razón en la cabecera del
     script): NEWLINE (el lexer los salta, DEC-016), columnas (lexer.astra
     solo trackea línea), contenido de STRING (el dump imprime el valor
     procesado con escapes resueltos — crudo y multi-línea si contiene
     `\n` —, el lexer el lexema verbatim: re-producir los escapes testaría
     el normalizador, no el lexer; el contenido queda pinneado byte a byte
     por `lexer.expected`), FLOAT_LIT (lexer.astra no lexea floats: si
     aparece uno en el fixture el normalizador **falla ruidosamente** con
     UNMAPPED, no lo esconde) y los tokens tras el primer ERROR
     (`run_dump_tokens` para en `TOKEN_ERROR` mientras `lexer.astra`
     recupera y sigue: el gate compara el prefijo común hasta e incluyendo
     el primer ERROR; la cola de recuperación la pinnea el golden).
     `lexer_gate.sh` lo invoca al final, así que una sola ejecución cubre
     golden + rutas + paridad de stream.
  3. **CI** (`.github/workflows/ci.yml`): paso «Self-hosting gates (seed VM
     + C backend)» en el job `seed` — corre `io_gate.sh` y `lexer_gate.sh`
     con el mismo guard `if: needs.changes.outputs.code == 'true'` que el
     resto de pasos del job (sin zig ahí, las rutas zig/LLVM skipean y el
     gate fuerte corre contra el seed) — y paso «Self-hosting gates (zig VM
     + LLVM routes)» en el job `llvm` (único job con `-Dllvm`; construye el
     seed con `make -C seed` porque las rutas canónicas y el gate fuerte
     necesitan `astra-seed`): ahí corren zig VM, `--jit` y
     `--emit-obj`+link; cross/wasm skipean por toolchain (cablearlos en los
     jobs `llvm-cross`/`llvm-wasm` es un paso cada uno, dejado pendiente).
     **Ningún job renombrado**: los checks requeridos por los rulesets no
     cambian.
- **Alternativas consideradas**: (1) meter el gate fuerte como paso extra
  dentro de `lexer_gate.sh` en vez de script propio — se hizo lo mejor de
  los dos: script propio (invocable y testeable independiente) **invocado**
  por `lexer_gate.sh` al final; (2) cablear las rutas cross/wasm en CI ya —
  el mínimo viable acordado era `seed` + `llvm`; ambas rutas quedan
  verificadas localmente (7/7) y anotadas en el script y en el paso de CI
  para los jobs `llvm-cross`/`llvm-wasm`; (3) comparar también el contenido
  de STRING re-procesando escapes en el normalizador — descartado por
  frágil (el parseo multi-línea del dump es ambiguo en general) y porque
  testaría el normalizador, no el lexer.
- **Coste aceptado**: 0 cambios de compilador; 1 fichero nuevo
  (`seed/tests/selfhost/lexer_tokens_parity.sh`), ~150 líneas añadidas a
  `lexer_gate.sh` y ~30 a `ci.yml`. El gate fuerte compara el stream de
  `lexer.astra` contra el seed; si el zig está construido exige además que
  su `--dump-tokens` sea byte-idéntico al del seed en este fixture
  (`dump_parity.sh` no cubre `selfhost/`), y las demás rutas ya exigen
  byte-parity con `lexer.expected` — así el gate cubre ambos frontends.
- **Evidencia**: `seed/tests/selfhost/lexer_gate.sh` → **7/7 rutas ok**
  (seed VM, C backend `--emit-c`+gcc, zig VM, LLVM `--jit`,
  LLVM `--emit-obj`+link, LLVM cross aarch64+qemu, LLVM wasm32-wasi+Node
  WASI) + `lexer_tokens_parity.sh` → `ok (176 tokens …)`; `io_gate.sh` →
  4/4; `make test` 286/0; `llvm_parity.sh` 176/176 skip=0.

### DEC-018 — Stdlib M2a: `ord(s)` y `substr(s, start, len)`

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR4a (2026-10-28)
- **Fecha**: 2026-10-28
- **Decisión**:
  - `ord(s) -> i64` devuelve el valor del **primer byte** de `s` (0..255) —
    **byte, no codepoint**: `s[i]` ya devuelve un string de 1 byte (DEC-013) y
    el lexer del seed recorre `char` sin UTF-8 (`research/028` §1.1), así que
    las cuatro rutas y un `lexer.astra` futuro leen el mismo número. Un string
    vacío **no tiene primer byte**: `ord("")` es error de runtime
    `ord() of empty string` — nunca lee pasando el buffer, porque `""` es
    `{NULL, 0}` en el VM y decide la longitud, no el puntero. Receptor
    no-string → `ord expects a string, got <tipo>` con el `type_name` del VM.
  - `substr(s, start, len) -> string` devuelve `len` bytes desde `start`.
    **Fuera de rango es error, nunca recorte**: `start < 0 || start > len(s)`
    → `substr start N out of bounds (len M)`; `len < 0 || start + len > len(s)`
    → `substr length N out of bounds (len M)` (con prefijo `substr`, no el
    `index … out of bounds` de los arrays: ese texto no dice de dónde sale).
    `len == 0` con `start == len(s)` devuelve `""` — el llamante no pidió
    nada —, mientras `start > len(s)` falla incluso con `len == 0`. El chequeo
    compara contra `len(s) - start`, así que un `len` enorme (p. ej.
    `9223372036854775807`) falla en vez de desbordar `start + len`.
  - **Tipos: los tres parámetros de `substr` (y el de `ord`) son `unknown`
    con guards de runtime** — el patrón de `print`/`len`/`to_string`
    (DEC-013/DEC-014). Motivo: la llamada compara argumentos con `type_eq`
    **exacto** y Astra-0 no tiene coerción, así que un parámetro anotado `i64`
    rechazaría `substr(s, 1, 3)` (literal `i32` por DEC-006) y uno anotado
    `i32` rechazaría `substr(s, 0, len(s))` (`len` devuelve `i64`); con
    `unknown` ambos calzan sin coerción. Cada runtime rechaza con el mismo
    texto: `substr expects a string, got <tipo>` y `substr expects an int, got
    <tipo>` — los dos argumentos enteros comparten la frase, igual que los dos
    guards del emisor LLVM.
  - **Los 4 sitios a la vez** (`research/028` §2.2): seed (`typechecker.c`
    símbolos, `vm.c` cuerpo + `GET_GLOBAL` + dispatch + marcadores `FnObj`,
    `priv.h`, `codegen.c` `cg_builtins[]`, `codegen_runtime.h`), zig
    (`typechecker.zig`, `vm.zig`) y LLVM (`emitter.zig` `emitOrd`/`emitSubstr`
    + `astra_runtime_llvm.c`); JIT, wasm y aarch64 heredan el runtime LLVM sin
    código propio.
  - **`ord` y `substr` se suman a la lista reservada de DEC-015** (`kBuiltins`
    en los dos typecheckers): el VM resuelve builtins por **nombre** en
    `GET_GLOBAL` y el emisor LLVM decide la llamada por **nombre** en
    `emitCall`, así que un binding homónimo divergiría entre rutas. Mensaje
    idéntico: `'ord' is a builtin and cannot be redeclared` /
    `'substr' is a builtin and cannot be redeclared`.
- **Alternativas consideradas**: (1) anotar el receptor `s: string` (como
  `read_file`, DEC-014) para rechazar `substr(42, …)` en compile-time —
  descartado: dejaría `ord` y `substr` con reglas distintas (`ord` seguiría
  siendo runtime por DEC-006) y añadiría un mensaje de compilación que mantener
  byte-idéntico en dos checkers, sin una seguridad que el runtime no dé;
  (2) **recortar** (clipping) cuando `start + len > len(s)` en vez de fallar —
  descartado: el error es *más barato* de verificar en las 4 rutas (una
  comparación contra el hueco restante, sin segunda rama) y es el mismo
  contrato que `s[i]` (DEC-013), que ya falla en vez de devolver menos;
  (3) tercer parámetro llamado `end` (la firma de `research/028` §1.2) — se
  eligió `len`, porque el valor es una **longitud**, no un índice final:
  `substr(s, 0, n)` toma `n` bytes; (4) parámetros anotados `string, i64, i64`
  — imposible sin coerción (arriba); (5) codepoint UTF-8 en `ord` — descartado:
  `s[i]` ya es byte y el lexer C es byte-oriented, un codepoint rompería la
  equivalencia con `lexer.astra`; (6) reutilizar el texto de bounds de los
  arrays (`index N out of bounds (len M)`) — descartado: no nombra el builtin
  que falla.
- **Coste aceptado**: 4 implementaciones en 9 ficheros de código (seed:
  `typechecker.c`, `vm.c`, `priv.h`, `codegen.c`, `codegen_runtime.h`; zig:
  `typechecker.zig`, `vm.zig`, `llvm/emitter.zig`,
  `llvm/runtime/astra_runtime_llvm.c`); 10 tests (6 conformance, 2 codegen,
  2 ui); 0 cambios de bytecode ni de AST, así que los dumps siguen
  byte-idénticos (172 ficheros = los 164 previos + los 8 nuevos que ya
  gatean).
- **Evidencia**: fijado por `expressions/ord_basic.astra` (65/97/48/10/
  `true`), `expressions/ord_empty_error.astra` (`ord() of empty string`),
  `expressions/ord_int_arg.astra` (`ord expects a string, got int`),
  `expressions/substr_basic.astra` (`ell`, tres `true` — entre ellos
  `substr(s, 0, len(s)) == s` y `substr(s, 5, 0) == ""` — y `e`),
  `expressions/substr_bounds_error.astra`
  (`substr length 99 out of bounds (len 5)`),
  `expressions/substr_start_error.astra`
  (`substr start 6 out of bounds (len 5)`), `codegen/ord_substr.astra` y
  `codegen/substr_oob.astra` (redondeo C; este último `substr start -1 out of
  bounds (len 5)`), `ui/builtin_shadow_ord.astra` y
  `ui/builtin_shadow_substr.astra` (primera línea byte-idéntica seed↔zig).
  Gates del PR: `make test` **296/0**, `sweep_emit_c` total=**132** skip=3
  fail=0, `make debug` (ASan/UBSan/LSan) **296/0**, `zig build test` verde,
  `ui_message_parity` first_fail=0 (total=127), `dump_parity` 0 divergent
  (172 files), `llvm_parity` **184/184** skip=0 fail=0 (opt=0 y opt=2),
  `llvm_fuzz -n 20 -s 1` fail=0, `lexer_gate.sh` **7/7 rutas** + paridad de
  tokens (176), `--check-constructs` OK.
- **Spec**: `research/028` §1.2 (firmas M2) — «pendiente de escribir en
  ARCHITECTURE».

### DEC-019 — Stdlib M2b: `push(arr, v)` (array nuevo) y `str_to_int(s)` (error de runtime)

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR4b (2026-10-28)
- **Fecha**: 2026-10-28
- **Decisión**:
  - `push(arr, value) -> array` devuelve un **array NUEVO** con `value`
    añadido al final — **copia manual, no crecimiento in-place**: el llamante
    re-bindea (`a = push(a, x)`) y el array del que venía queda **intacto**
    para cada binding que aún lo retenga. La razón técnica no es de estilo,
    es de layout: en la ruta LLVM el objeto array es
    `{rc, kind, i64 len, i32 elem_pty, <elementos en línea>}` y **todos los
    bindings comparten el puntero** (la semántica de `arrays/alias_write`,
    DEC-001) — hacer crecer el objeto exige reubicarlo y dejaría a cada alias
    apuntando al objeto viejo con la `len` vieja. Sólo el copy es correcto
    en las cuatro rutas sin rehacer el layout LLVM (que print, eq y el rc
    de M2.a dan por supuesto). Nota deliberada: `a[i] = v` sí escribe
    **a través del handle** (la sobrescritura no mueve la memoria); el
    **crecimiento** sí la mueve, y ahí el handle LLVM no puede seguirla.
  - **Coste**: la copia es O(n) por llamada (arena sin realloc en el seed y
    zig, `malloc`+`memcpy` en C y LLVM), así que `n` pushes son **O(n²)**.
    Aceptado: el uso previsto es el buffer de tokens de un lexer (miles de
    elementos, no millones) y la alternativa (capacidad amortizada) añade un
    campo `capacity` a tres rutas y una política de reserva que la cuarta no
    puede compartir. **Sin `realloc` in-place**: la arena del seed no
    redimensiona y el objeto LLVM no puede moverse (arriba).
  - **Homogeneidad del elemento en runtime**: `push element has type <X>,
    expected <Y>` cuando el tipo de `value` no es el del elemento del array
    — la frase abreviada del checker (`array element N has type X, expected
    Y`, sin `N` porque el runtime no conoce el índice). Hace falta porque el
    checker **no puede** comparar el elemento contra el tipo del array: los
    parámetros de `push` son `unknown` (arriba) y `type_eq` sobre
    `array<int_literal>` vs `array<f64>` pasaría por el unknown. Los VMs y el
    backend C comparan el tipo dinámico del valor contra el del **primer
    elemento** (todo array de Astra-0 tiene ≥1: el literal exige elementos y
    `push` sólo añade); LLVM compara el ptype estático en el emisor y sólo
    recurre al helper dinámico cuando hay una caja de por medio (un lado
    `some/ok/err` sólo se nombra con su tag real). Mismo texto en los 4.
  - `push` con receptor que no es array (incluido `nil`) →
    `push expects an array, got <tipo>` con el `type_name` del VM; parámetros
    `unknown` con guards de runtime, patrón `ord` (DEC-018), y el retorno es
    **`array<unknown>`**: `let b = push(a, 1)` hereda un array cuyo elemento
    se sigue chequeando por uso, y `type_eq(array<T>, array<unknown>)` acepta
    la reasignación `a = push(a, …)` sin reglas nuevas.
  - `str_to_int(s) -> i64` parsea **el decimal que `to_string` produce**:
    opcional `-` inicial + uno o más dígitos `0-9`, nada más. Redondea
    `str_to_int(to_string(n))` para todo entero que el lenguaje pueda nombrar.
    **Error de runtime** (nunca un optional) para tres casos con textos
    fijos: entrada inválida (incluido `""`, `+`, espacios, `_`, `0x`, letras)
    → `str_to_int: invalid integer literal '<s>'`; magnitud pasada de i64 →
    `str_to_int: integer literal is out of range for i64` (la frase del
    lexer del seed con el prefijo del builtin); receptor no-string →
    `str_to_int expects a string, got <tipo>`. El desbordamiento se capa en
    **magnitud ≤ INT64_MAX** con el mismo criterio que `accumulate_digit` del
    lexer, así `-9223372036854775808` falla **igual que el literal en origen**
    (el lexer también lo rechaza: el signo no forma parte de la magnitud que
    acumula) — sin wrap silencioso. La literal que el mensaje **muestra** se
    recorta a **64 bytes** (y, como todo `%.*s`, al primer NUL): los tres
    runtimes C capan su buffer de error a tamaños distintos (seed 512, backend
    C 192, LLVM 128) y el zig no capa, así que sin un tope común un input
    largo o con `\0` escribiría cuatro mensajes distintos. Los prefijos
    `+`/`0x`/`0b`/`0o` y `_` no
    se aceptan: son ortografías del lexer (`str_to_int` es el par decimal de
    `to_string`, y `+5` ni siquiera lexea como literal en origen).
  - **Los 4 sitios a la vez** (`research/028` §2.2): seed (`typechecker.c`
    símbolos + `kBuiltins`, `vm.c` cuerpo + `GET_GLOBAL` + dispatch +
    marcadores `FnObj`, `priv.h`, `codegen.c` `cg_builtins[]`,
    `codegen_runtime.h`), zig (`typechecker.zig` + `k_builtins`, `vm.zig`) y
    LLVM (`emitter.zig` `emitPush`/`emitStrToInt`/guards + `astra_runtime_llvm.c`
    `astra_llvm_array_push`/`astra_llvm_str_to_int` + fallos); JIT, wasm y
    aarch64 heredan el runtime LLVM sin código propio. Los dos nombres se
    suman a la lista reservada de DEC-015 en los dos typecheckers.
- **Alternativas consideradas**:
  (1) **`push` in-place a través del handle** (`arr->elems`/`arr->len`
  reescritos, visible para todas las copias como `a[i] = v`) — era trivial en
  **3 de las 4** rutas (seed y zig: la arena bump; C: `{elems, len}` con
  `malloc`), pero **imposible en LLVM**: los elementos viven en línea dentro
  del objeto compartido, así que crecer obliga a reubicarlo y los alias
  quedan con el puntero viejo (arriba). Mantenerla habría exigido rediseñar
  el layout LLVM (buffer separado con rc propio: print, eq, array_eq y el
  retain/release de M2.a dan el inline por supuesto) o divergir el VM/seed/C
  de LLVM; (2) **in-place condicional** (sólo si nadie más retiene, p. ej.
  `rc == 1`) — descartado: el comportamiento observable pasaría a depender de
  si hay alias, y una misma sentencia `push(a, x)` daría o no resultados
  distintos en `b = a` según el momento; (3) **`i64?` (some/none)** —
  descartado: el estilo del repo es el error de runtime consistente (mismo
  contrato que `substr` bounds, DEC-018), un optional exige construir
  `some`/`none` desde un builtin en las cuatro rutas (el par M6.c sólo se
  desempaqueta en la ABI de funciones nombradas) y obliga a `match`/`?` en
  **cada** llamante para usar el valor — `print(str_to_int(s))` dejaría de
  existir; (4) `Result[i64, string]` (la firma de `research/028` §1.2) —
  misma objeción más construir strings de error en 4 rutas; (5) **anotar el
  receptor** (`str_to_int(s: string)` como `read_file`, o
  `push(arr: [T], v: T)`) — para `push` imposible sin coerción (DEC-006: un
  `[i32]` anotado rechazaría `push(a, len(s))` y un `v: i32`
  `push(a, 3.5)` sólo en compile-time mientras `b[0] = 3.5` seguiría
  cayendo en runtime vía otro camino); para `str_to_int` técnicamente
  viable pero descartado para no partir la pareja de lectores de string en
  dos reglas (`ord` es `unknown`+guard desde DEC-018); (6) **que el checker
  rechace el desajuste de elemento en compile-time** (comparar arg2 contra
  el elem de arg1 en la llamada a `push`) — descartado: introduce una regla
  de chequeo especial para un solo builtin en dos checkers (otro mensaje que
  mantener byte-idéntico) y no sustituye al guard de runtime, que las rutas
  dinámicas (cajas) necesitan de todas formas; (7) `+` explícito y
  hex/bin/oct con `_` dentro de `str_to_int` — descartado: `to_string` no
  los emite (rompería el redondeo como definición) y esas ortografías son
  del lexer; añadirlas aquí duplicaría la lógica de `lexer.astra` en 4
  runtimes.
- **Coste aceptado**: 4 implementaciones en 9 ficheros de código (seed:
  `typechecker.c`, `vm.c`, `priv.h`, `codegen.c`, `codegen_runtime.h`; zig:
  `typechecker.zig`, `vm.zig`, `llvm/emitter.zig`,
  `llvm/runtime/astra_runtime_llvm.c`); 15 tests (11 conformance, 2 codegen,
  2 ui); 0 cambios de bytecode ni de AST, así que los dumps siguen
  byte-idénticos (185 ficheros = los 172 previos + los 13 nuevos que ya
  gatean); O(n²) de `push` documentado arriba.
- **Evidencia**: fijado por `expressions/push_basic.astra` (crece, lee por
  índice, `len`, imprime `[1, 2, 3]` y añade un elemento calculado),
  `expressions/push_alias.astra` (**el array viejo no crece**: `len(a)==2`,
  `len(b)==3` — el pin de la semántica de array nuevo),
  `expressions/push_int_arg.astra` (`push expects an array, got int`),
  `expressions/push_elem_error.astra`
  (`push element has type float, expected int`),
  `expressions/push_nil.astra` (`push expects an array, got nil`),
  `expressions/str_to_int_basic.astra` (`42`, `-7`, `0`, `123`, i64 min via
  `to_string`), `expressions/str_to_int_invalid.astra`
  (`str_to_int: invalid integer literal '12a'`),
  `expressions/str_to_int_empty.astra`
  (`str_to_int: invalid integer literal ''`),
  `expressions/str_to_int_range.astra`
  (`str_to_int: integer literal is out of range for i64`),
  `expressions/str_to_int_int_arg.astra`
  (`str_to_int expects a string, got int`), `expressions/str_to_int_nul.astra`
  (literal con `\0` mostrado truncado en el NUL — `invalid integer literal
  '1'` —, idéntico en las 4 rutas), `codegen/push_roundtrip.astra`
  y `codegen/push_elem_error.astra` (redondeo C, incluida la composición
  `push`+`substr`+`str_to_int`), `ui/builtin_shadow_push.astra` y
  `ui/builtin_shadow_str_to_int.astra` (primera línea byte-idéntica seed↔zig).
  Gates del PR: `make test` **311/0**, `sweep_emit_c` total=**143** skip=3
  fail=0, `make debug` (ASan/UBSan/LSan) **311/0**, `zig build test`
  **73/73**, `ui_message_parity` first_fail=0 (total=129), `dump_parity` 0
  divergent (185 files), `llvm_parity` **197/197** skip=0 fail=0 (opt=0 y
  opt=2), `llvm_jit` **197/197** (opt=0 y opt=2), `llvm_sanitize`
  **197/197** bajo ASan + LSan limpio, `llvm_cross` **197/197** (aarch64),
  `llvm_wasm` **197/197**, `llvm_fuzz -n 20 -s 1` fail=0, `lexer_gate.sh`
  **7/7 rutas** + paridad de tokens (176), `--check-constructs` OK.
- **Spec**: `research/028` §1.2 (firmas M2) — «pendiente de escribir en
  ARCHITECTURE».

### DEC-020 — Stdlib M3: `chr(i)`, `read_line()` y `for c in s` (cierre del MVP)

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR5 (2026-10-28)
- **Fecha**: 2026-10-28
- **Decisión**:
  - `chr(i: i64) -> string` devuelve el string de **1 byte** cuyo primer byte
    es `i` — la inversa exacta de `ord(s)` (DEC-018): `chr(ord(s))` round-tripea
    cualquier `s` de 1 byte, y el lexer del futuro self-hosting la necesita
    para reconstruir strings a partir de códigos clasificados. Es **byte**, no
    codepoint, coherente con `s[i]` (DEC-013) y `ord` (DEC-018). El rango
    `[0, 255]` se comprueba en runtime: fuera de él es **error de runtime**
    `chr value N out of bounds (0..255)` (texto fijo, idéntico en las cuatro
    rutas) — **nunca** el byte bajo enmascarado, que ocultaría un error del
    llamante (mismo contrato «error, nunca recorte» que `substr` bounds,
    DEC-018). El parámetro es `unknown` con guard de runtime, patrón `ord`
    (DEC-018): `chr(65)` (literal i32, DEC-006) y `chr(len(s))` (i64) calzan
    igual, y un receptor no-int (`chr("a")`) cae en `chr expects an int, got
    <tipo>` en las cuatro rutas.
  - `read_line() -> string` lee **una línea de stdin** hasta (sin incluir) el
    `\n` final y la devuelve **sin el `\n`**; una última línea sin `\n` devuelve
    lo que hay (convención estándar de lector) y una línea vacía devuelve `""`.
    **EOF sin datos** (la stdin está vacía, cerrada o es `/dev/null`) es **error
    de runtime** `end of input`, texto fijo en las cuatro rutas. La stdin se lee
    **byte a byte** (`fgetc` en las tres rutas C, `takeByte` en el zig VM), no
    por bloques: un `fread` comería los bytes de la **siguiente** línea en un
    buffer desechado y la segunda llamada perdería datos — el lexer lee el
    fuente línea a línea y esa es la razón de ser del builtin. El búfer de
    lectura es único y se reutiliza entre llamadas (arena en seed/zig, `static`
    en C y LLVM). Sin parámetros: el chequeo de arity reporta `expected 0
    arguments but got N`, igual que el resto de builtins.
    **wasm sin stdin**: WASI expone stdin como `/dev/null` implícito (el runner
    `demo/wasi_run.mjs` no la cablea), así que la primera `read_line()` da el
    **mismo** `end of input` determinista — comportamiento razonable y
    documentado aquí; el caso positivo (leer una línea de verdad) vive fuera de
    `conformance/`, en `io_gate.sh`, que redirige stdin desde un fixture.
  - `for c in s { … }` sobre un string itera **byte a byte**, con `c` como
    **string de 1 byte** — el mismo modelo que `s[i]` (DEC-013) y `ord`
    (DEC-018), para que un lexer pueda comparar `c` contra un literal de string
    sin `ord`. El typechecker acepta `TYPE_STRING` como iterable en los **dos**
    typecheckers (el mensaje de rechazo pasa a nombrar `array, string or range`);
    la emisión no necesita opcode nuevo: las cuatro rutas ya tenían el camino
    LEN+INDEX que recorre un array por índice, y `OPCODE_INDEX`/`astra_string_get`
    sobre un string ya devuelven el byte correcto (DEC-013). Un string vacío itera
    cero veces; `break`/`continue` se comportan como en arrays.
  - **Los 4 sitios a la vez** (`research/028` §2.2): seed (`typechecker.c`
    símbolos + `kBuiltins` + chequeo `for`, `vm.c` cuerpo + `GET_GLOBAL` +
    dispatch + marcadores `FnObj`, `priv.h`, `codegen_runtime.h`), zig
    (`typechecker.zig` + `k_builtins` + chequeo `for`, `vm.zig`) y LLVM
    (`emitter.zig` `emitChr`/`emitReadLine`/chequeo `for` + `astra_runtime_llvm.c`
    `astra_llvm_chr`/`astra_llvm_read_line`); JIT, wasm y aarch64 heredan el
    runtime LLVM sin código propio. Los dos nombres nuevos (`chr`, `read_line`)
    se suman a la lista reservada de DEC-015 en los dos typecheckers.
- **Alternativas consideradas**:
  (1) **`chr` enmascarando el byte bajo** (`i & 0xFF`, sin error) — descartado:
    `chr(256)` daría `"0"` y `chr(-1)` daría `"\xFF"` en silencio, ocultando un
    bug del llamante; el contrato del repo para rangos es el error de runtime
    (substr bounds, DEC-018); (2) **`read_line() -> string?`** (la firma de
    `research/028` §1.2, con `none` en EOF) — descartado: obligaría a construir
    `some`/`none` desde un builtin en las cuatro rutas (el par M6.c sólo se
    desempaqueta en la ABI de funciones nombradas) y a `match`/`?` en **cada**
    llamante para usar la línea; el estilo del repo es el error de runtime
    consistente (DEC-018/019), y `read_line()` en un bucle `while` es la forma
    natural de leer hasta EOF sin optional; (3) **`read_line` leyendo por
    bloques** (`fread` de 4 KB, como `read_file`) — descartado: el búfer se
    descartaría al volver y la **segunda** llamada perdería el resto de la
    línea anterior; el byte a byte es la única implementación correcta con un
    búfer de línea reutilizable, y el coste (una syscall por byte en el peor
    caso) es irrelevante para el uso previsto (lexer leyendo su fuente);
  (4) **`for c in s` con `c: i64`** (el código numérico, estilo Go) —
    descartado: `match c { "(" => … }` ya funciona en cuatro rutas con strings
    (p8 de research/028) y con `i64` habría que escribir `ord(c)` en cada
    comparación; el string de 1 byte es coherente con `s[i]` (DEC-013);
  (5) **`char_at(s, i)` builtin en vez de `s[i]`/iteración** — descartado:
    `s[i]` ya existe (DEC-013) y `for c in s` reutiliza el LEN+INDEX, sin
    consumir presupuesto de builtin.
- **Coste aceptado**: 4 implementaciones en 9 ficheros de código (seed:
  `typechecker.c`, `vm.c`, `priv.h`, `codegen_runtime.h`; zig:
  `typechecker.zig`, `vm.zig`; LLVM: `emitter.zig`,
  `llvm/runtime/astra_runtime_llvm.c`) + los dos typecheckers para el chequeo
  `for`; 7 tests (5 conformance, 2 codegen) + el stage de `io_gate.sh` para la
  lectura positiva de `read_line`; 0 cambios de bytecode ni de AST, así que los
  dumps siguen byte-idénticos. `for c in s` emite **exactamente** el mismo
  LEN+INDEX que `for x en arr` — sin opcode nuevo — y el C backend no necesitó
  cambio: su `OPCODE_INDEX` ya trataba `AST_STRING` desde DEC-013.
- **Evidencia**: fijado por `expressions/chr_basic.astra` (`chr(65)=="A"`,
  `chr(ord("Z"))=="Z"`, byte 0, `chr(i64)`), `expressions/chr_oob_error.astra`
  (`chr value 256 out of bounds (0..255)`), `expressions/chr_int_arg_error.astra`
  (`chr expects an int, got string`), `expressions/read_line_eof_error.astra`
  (`end of input` con stdin=`/dev/null`, determinista en las 4 rutas),
  `loops/for_string.astra` (itera `"hola"` imprime `h o l a`, concatena,
  string vacío = 0 iteraciones, `continue`/`break`), `codegen/chr_oob.astra`
  y `codegen/for_string.astra` (redondeo C), `seed/tests/selfhost/io_gate.sh`
  (stage `read_line`: 4 rutas leen `stdin_lines.txt` y coinciden byte a byte
  con `read_line.expected`). `ui/for_iter_type.astra` se actualizó al nuevo
  texto del rechazo (`array, string or range`).
  Gates del PR: `make test` **319/0**, `sweep_emit_c` total=**149** skip=3
  fail=0, `make debug` (ASan/UBSan/LSan) **319/0**, `zig build test` en verde,
  `ui_message_parity` first_fail=0 (total=129), `dump_parity` sin divergencia,
  `llvm_parity` **205/205** skip=0 fail=0, `llvm_jit` **205/205**,
  `llvm_fuzz -n 20 -s 1` fail=0, `lexer_gate.sh` **7/7 rutas** + paridad de
  tokens, `io_gate.sh` **8/8** (4 read_file + 4 read_line), `--check-constructs`
  OK.
- **Spec**: `research/028` §1.2 (firmas M3: `chr`, `read_line`, `for c in s`)
  — «pendiente de escribir en ARCHITECTURE».
### DEC-021 — Nombre del manifest y de la CLI futura: `astraea`
- **Estado**: **Propuesta** — dirección decidida el 2026-10-28; la
  implementación (rename `astra.toml` → `astraea.toml` + bautizo del CLI)
  queda **bloqueada hasta que exista la CLI unificada** («Aún no existe»,
  `09_libro/13_toolchain_cli.md`). Al implementarse pasa a
  `Aceptada (test-pinned)` con el test de raíz del módulo.
  *(La DEC-020 la crea el PR de M3 — por eso la numeración salta.)*
- **Fecha**: 2026-10-28.
- **Decisión**: el manifest del proyecto se llama **`astraea.toml`** (con
  `astraea.lock` al estilo `Cargo.lock`) y la CLI unificada se llama
  **`astraea`** — patrón «nombre propio de la herramienta» (`Cargo.toml`,
  `pubspec.yaml`), no «nombre del lenguaje» (`go.mod`, `pyproject.toml`).
  Mientras tanto sigue vigente `astra.toml` como marcador de raíz (es lo que
  hoy busca `zig/src/modules/modules.zig`).
- **Investigación de nombres (MEDIDA el 2026-10-28**, npm/crates.io/PyPI/GitHub,
  200=ocupado / 404=libre):

  | Nombre | npm | crates | PyPI | GH org | Veredicto |
  |:-------|:---:|:------:|:----:|:------:|:----------|
  | **`astraea`** | 200 | ✅ 404 | ✅ 404 | ✅ 404 | **elegido**: libre donde importa; ortografía canónica de la diosa |
  | `astrea` | 200 | 200 | 200 | 200 | descartada: ocupada en los 4 que cuentan |
  | `astro` | — | — | — | — | descartada: marca enorme **astro.build** + una-letra de `astra` |
  | `rigel`/`deneb`/`oort`/… | 200 casi todos | parcial | — | — | descartados: sin parentesco ni filosofía (datos en el informe de la sesión) |

- **Por qué `astraea`**: (a) **filosofía** — la doncella de las estrellas,
  diosa de la **justicia**: «las reglas hechas de estrellas que se cumplen»,
  que es exactamente lo que hace el ecosistema de decisiones/gates de este
  repo; (b) **familia con Astra sin la trampa de Astro** — contiene `astra`
  (más la `e`), la relación se explica sola (hermana mitológica), mientras
  `astro` la sustituía por una letra y colisionaba con astro.build;
  (c) precedente: el ecosistema Rust convive con nombres de familia
  (`rust`/`rustup`/`rustfmt`) porque los roles son distintos — aquí
  lenguaje=`astra`, administrador=`astraea`.
- **Alternativas consideradas y descartadas**: `astra.toml` (status quo — se
  mantiene hasta que la CLI exista; es la escuela `go.mod`), `astro.toml`
  (marca ajena + una-letra), `Astrea` corta (ocupada en crates/PyPI/GH org),
  `rigel`/`oort`/`spica` (breves y casi libres, pero sin significado
  filosófico ni relación con Astra), mantener `Cargo.toml`-style con otro
  vocabulario no astronómico (fuera del brief).
- **Coste aceptado**: el rename es **barato hoy** (~1 literal en
  `modules.zig` + ~15 referencias en docs + 1 test unitario) y **caro tras
  el package manager** (proyectos/registros de usuarios) — por eso se
  decide YA y se deja bloqueada la ejecución hasta la CLI, no al revés.
  Riesgo residual aceptado: `astra`/`astraea` comparten raíz — mitigado por
  roles claros y por la diferencia de sílaba (a-la-astro, que era
  sustitución de una letra final + marca tomada).
- **Evidencia**: las mediciones de la tabla de arriba (curl a
  `registry.npmjs.org`, `crates.io/api/v1/crates`, `pypi.org/pypi`,
  `api.github.com` el 2026-10-28).
- **Spec**: `ARCHITECTURE.md` §33.2 (puntero añado en este PR).

### DEC-022 — Sintaxis de `transfer`: builtin en forma de llamada
- **Estado**: **Aceptada (doc)** — dirección ya assertada por DEC-012 y
  `ARCHITECTURE.md` §2.4/§2.6/§21.3; formalizada como decisión propia
  (requisito de `research/031` §3-E antes de planificar la fase E). El
  comportamiento se pinnea en el PR fase E.
- **Fecha**: 2026-10-28.
- **Decisión**: `transfer(x)` es un **builtin** en posición de llamada —
  **no keyword**. Consecuencias: sin `constructs/transfer.c`, sin fila en el
  registro de constructos (`--check-constructs` se queda en 47/27, invariante
  6 intacta), y el nombre `transfer` se suma a las listas reservadas de
  DEC-015 en los dos typecheckers (pin: `ui/builtin_shadow_transfer.astra`).
  La semántica (S1 use-after-transfer, S2 alias en el cruce, invalidación
  R4 del binding emisor) **no** vive en esta decisión: entra en el mismo PR
  que el constructo (`research/026` §3.2/§3.5).
- **Alternativas consideradas**: (1) keyword `transfer a` — descartada: cuesta
  token de lexer + fichero de registro + fila (invariante 6), hace que
  `transfer` deje de lexear como identificador en todo el lenguaje, y
  todos los ejemplos de 025/026/ARCHITECTURE usan forma de llamada;
  (2) método `a.transfer()` — descartada: el cruce se define sobre el grafo
  de valores, no sobre un receiver, y se enredaría con la sintaxis de
  `.copy()` que aún no existe; (3) keyword `move a` — descartada: renombra
  el concepto respecto de ARCHITECTURE §2.4/§3.3, que dicen `transfer(var)`
  desde el diseño original.
- **Coste aceptado**: el patrón DEC-013..020 (builtin en 4 motores, ~8–9
  ficheros, 1 opcode o camino de builtin-call nuevo) + el chequeo S1/S2 en
  2 typecheckers; ver la estimación calibrada de DEC-012.
- **Evidencia**: hoy ninguna ejecutable (no hay `transfer` en el léxico);
  pins pre-declarados `ui/builtin_shadow_transfer.astra` y la batería
  `026` §3.5 en el PR fase E.
- **Spec**: `ARCHITECTURE.md` §2.6.

### DEC-023 — Alcance del motor del walk RT1: M4, no M3
- **Estado**: **Aceptada (doc)** — resuelve el conflicto `research/026`
  fila RT1 («M3 y M4») vs `research/027`-Rec3 / DEC-009 («los VMs no
  portan ARC») según la recomendación literal de `research/031` §1-P1.
- **Fecha**: 2026-10-28.
- **Decisión**: el walk de unicidad en runtime RT1 (`rc == 1` en todo el
  grafo alcanzable en el punto de cruce) vive en **M4** — la ruta LLVM,
  que ya tiene refcounting desde M4.e — hasta que una decisión futura añada
  rc al VM Zig. M3 (VM seed/zig, arena) queda **sin RT1** mientras DEC-009
  mantenga la divergencia documentada. RT1 sigue siendo el **gate de
  entrada de la primera feature que ejecute un cruce real**
  (scheduler/`spawn`/`send`), nunca «después» (`research/026` §3.2 fila
  RT1, enmendada por cita — 026 no se edita). M1/M2 siguen siendo solo
  estáticos (move + nil invalidation, S1/S2), como 026 ya especificaba.
- **Alternativas consideradas**: portar ARC al VM Zig ahora para cumplir la
  fila M3 de 026 — descartada: `research/027` §3.2 op. 3B la declara
  «ALTA, no recomendada hoy» y DEC-009 ya fija la divergencia; declarar
  027-Rec3 solo temporal para M3 sin fijar alcance — descartada: deja el
  conflicto abierto para el siguiente planificador.
- **Coste aceptado**: cero hoy; el pin eventual
  (`EXPECT-RUNTIME-ERROR: cannot transfer: value graph is shared (rc=2 …)`)
  llega con el scheduler en la suite Phase 2 (el seed no puede ejecutarlo:
  no tiene fibras — logistics ya señaladas en `research/026` §4 Paso 4.3).
- **Evidencia**: `research/031` §1-P1 y §3-F; `research/027` §3.2 op. 3A;
  DEC-009 (hermana de esta decisión).
- **Spec**: `ARCHITECTURE.md` §2.6 (párrafo 5, «el walk llega con el
  primer cruce real»).

### DEC-024 — Stdlib post-M3: `contains`, `index_of`, `split` en Astra puro
- **Estado**: **Aceptada (test-pinned)** — fijada en el PR stdlib-postM3
  (2026-10-28).
- **Fecha**: 2026-10-28.
- **Decisión**: las tres funciones que `research/028` §1.2 dejó para M3
  «en Astra puro sobre M1+M2» se implementan como **helpers de usuario, no
  builtins** (0 bytes de compilador): cada programa/test define sus
  funciones inline — hoy no existe vehículo para código Astra compartido
  (el seed compila exactamente un fichero; `std/…` está rechazado por la
  regla 4 de `modules.zig`; los gates son single-file por construcción).
  Semántica fijada:
  - `contains(s, sub) -> bool`: búsqueda byte a la izquierda; **sub vacío =
    `true`** (está en toda posición, como en las bibliotecas maduras).
  - `index_of(s, sub) -> i64?`: primera (más a la izquierda) ocurrencia;
    ausente = `none`; **sub vacío = `some(0)`** (imprime `nil`/`some(N)`).
  - `split(s, sep) -> [string]`: campos se **preservan** (`"a,,b"` →
    `a`,``,`b`), sep al inicio/final produce campo vacío, sin sep = `[s]`,
    `s` vacío = `[""]`, byte a byte; **`sep` vacío = array de bytes de `s`**
    (caso especial tipo JS: `split("ab", "")` → `a`,`b`) — elegido en lugar
    de un «error» porque el código de usuario **no puede** lanzar errores de
    runtime (solo los builtins), y devolver `[s]` silenciaría bugs de sep
    variable. Nunca recorta ni inventa campos.
  - Contadores de índice tipados `i64` (`let mut i: i64 = 0`) porque `len`
    devuelve `i64` (DEC-013/DEC-006).
- **Alternativas consideradas**: builtins en los 4 motores (~8–9 ficheros,
  4–6 d cada uno + nombres reservados DEC-015) — descartados: no hay
  consumidor con necesidad de rendimiento aún (el lexer usa sondeos) y
  reservar `contains`/`split` chocaría con el futuro `Array.contains` de
  `research/015`; módulo `std/` compartido — imposible hoy (regla 4 +
  single-file); `split` con `[]` literal como seed — descartado: el
  emisor LLVM rechaza literales de array vacío (`emitter.zig:1415`) y
  `llvm_parity` cuenta cualquier skip como fallo.
- **Coste aceptado**: 0 líneas de compilador; duplicación de helpers en
  cada programa (se elimina sola cuando exista resolución de módulos en el
  seed — flip de la regla 4, PR futuro).
- **Evidencia**: `conformance/stdlib/` (5 ficheros), `codegen/` (3
  round-trips); verificados en VM seed, `--emit-c`+gcc, VM zig y
  `--jit` LLVM con salida byte-idéntica.
- **Spec**: `ARCHITECTURE.md` §32.2 (la tabla de builtins no crece; estas
  funciones viven en el libro `09_libro/08_strings_texto.md`).

### DEC-025 — `parser.astra`: segundo componente self-hosting (parser en Astra-0)
- **Estado**: **Aceptada (test-pinned)** — fijada en el PR parser-selfhost
  (2026-10-28).
- **Fecha**: 2026-10-28.
- **Decisión**: después del lexer (DEC-016/017), el **parser** se escribe en
  Astra-0 como `seed/tests/selfhost/parser.astra` (~450 líneas): parser
  recursivo con Pratt sobre la tabla de precedencia de `--dump-operators`,
  con estado global (pos, token actual, un peek de un token) — los módulos
  son globales mutables y las funciones los escriben (patrón verificado en
  las 4 rutas).
  - **Formato de salida**: s-expresión prefijo de **una línea**
    (`FnDecl(add Param(a TypeIdent(i32)) … Block(…))`), construido con un
    `attach(text, kids)` que inserta los hijos antes del último `)` del
    texto con payload.
  - **Golden independiente**: `parser.expected` sale de
    `astra-seed --dump-ast parser_input.astra | awk -f normalize_ast.awk`
    — el parser en C contra el parser en Astra-0, con el awk como simple
    adaptador de formato (indentación → prefijo), sin conocimiento de
    nombres de nodo. El gate **regenera y re-compara** el golden en cada
    corrida (freshness), así el fixture no puede divergir de `--dump-ast`
    en silencio.
  - **Gate**: `parser_gate.sh`, clon del de lexer → **7 rutas** (seed VM,
    `--emit-c`+gcc, zig VM, LLVM `--jit`, `--emit-obj`+link, cross aarch64
    bajo qemu, wasm32-wasi bajo Node), skips limpios sin toolchain, cableado
    en CI (jobs `seed` y `llvm`).
- **Límites declarados (v1, no accidentales)**: (1) todo statement termina
  en `;` — NEWLINE como terminador queda fuera (el seed lo acepta; la
  fixture lo evita); (2) literales int solo decimales (el dump imprime el
  valor de hex, no el lexema); (3) strings **planos** sin escapes (el dump
  los imprime decodificados, con saltos de línea reales); (4) subconjunto
  de constructos: sin match, lambdas, genéricos, campos, traits ni
  anotaciones complejas; (5) `else` en la misma línea del `}` que cierra el
  `if` (limitación conocida del parser de los 2 compiladores, sin decidir
  aún).
- **Alternativas consideradas**: s-expr multilinea con indentación
  (descartada: requeriría shift de indentación al componer subárboles —
  O(n²) peor y código de más); construir el AST como structs/arrays
  (descartada: arrays heterogéneos no existen y `a[i].field` está rechazado
  en la ruta LLVM); golden generado por el propio `parser.astra`
  (descartada: dejaría de ser un gate — el golden debe venir del compilador
  real).
- **Coste aceptado**: 0 líneas de compilador; el fixture es single-file y
  los helpers de DEC-024 no hacen falta (el parser no busca substrings).
  Hallazgos de lenguaje que el PR NO pinnea (comportamiento existente
  compartido por ambos compiladores, candidatos a DEC futura): `else` en
  línea aparte se rechaza; `if/else if/else` multilinea como **cola** de fn
  no tipa («if branches have different types: string vs void») — se esquiva
  con early-returns.
- **Evidencia**: `parser_gate.sh` (rutas + freshness), `parser_input.astra`
  (corre en el VM: `31` / `true`), CI jobs `seed` y `llvm`.
- **Spec**: alcance y límites en la cabecera de `parser.astra`; plan de
  crecimiento (patrones, `fn` completo con NEWLINE, `--dump-ast` como gate
  fuerte vivo) en `PHASE1_PROGRESS` §selfhosting.

### DEC-026 — Fase E v1: `transfer` sin fibras (S1/S2 + nil-red)
- **Estado**: **Aceptada (test-pinned)** — fijada en el PR fase-E1
  (2026-10-28).
- **Fecha**: 2026-10-28.
- **Decisión**: los detalles que DEC-012/022 dejaron abiertos para el PR
  fase E, sin fibras («check sin cruce», `research/026` §3.4):
  1. **Forma**: solo `transfer(x);` como sentencia, 1 argumento, **variable
     desnuda**. `transfer()`/`transfer(a, b)` → `expected 1 arguments, got N`
     (formato genérico); `transfer(a + 1)` / `transfer(a[0])` →
     `transfer expects a variable`; valor-fuente (`let f = transfer`) → M1
     `transfer must be called directly as transfer(variable)` (typecheck);
     anidado (`print(transfer(a))`, `let y = transfer(a)`, tail-expr) → M2
     `transfer must be its own statement` (pasada de ownership). Retorna
     void.
  2. **Tipos**: solo agregados — `array`, `struct`, `enum`, `fn`, `string`,
     `optional` y `unknown`; escalares (`i32`/`i64`/`u32`/`u64`/`f64`/`bool`)
     → `transfer expects an aggregate, got <tipo>` en compile-time. Razones:
     un escalar no tiene nil en el modelo LLVM (`emitter.zig` rechaza `let`
     escalar sin inicializador) y `val` cruza siempre gratis (§2.6 regla 2).
  3. **S1/S2**: pasada post-typecheck (`enforce_ownership` en seed y zig),
     solo si el typecheck limpió; intraprocedural, sensible al flujo, sin
     CFG: σ por nombre con `Único | Aliased | Escapado` + conjunto
     `movidos`, alcance por bloques con pila de marks (shadowing restaura),
     joins punto a punto (`Escapado` absorbente) en `if`/`match` y
     `join(entrada, cuerpo)` una vez en bucles. Transiciones de
     `research/026` §3.3 con dos precisiones: **`let y = x` / `y = x` con
     valor Ident dejan ambos `Aliased`** (la fila literal de 026 copiaba
     `σ(x)` y sería falsa negativa si `σ(x)==Único`), y `f(x)`/contenedor/
     captura de closure marcan escape/alias **sin comprobar tipos** — solo
     un agregado puede transferirse, así que el sobre-marcaje de escalares
     es inobservable. Parámetros arrancan `Único`; un nombre **no presente
     en σ** (global usado desde una fn) se trata como `Escapado` al
     transferirlo: los globales son compartidos por definición.
     Mensajes: S2-alias `cannot transfer 'a': value is aliased by 'b'`,
     S2-captura `… aliased by closure 'f'`, S2-escape (nuevo, no specado
     por 026) `cannot transfer 'a': value has escaped`, S1
     `use of transferred variable 'a'` (incluye re-transfer). Loc: el nodo
     call para S2/tipos/forma, el Ident de uso para S1, el Ident argumento
     para M2-anidado… (fijados por `EXPECT-ERROR-FIRST` en cada test).
  4. **R4 nil-red**: la sentencia `transfer(x)` se emite como
     `CONST nil; SET_LOCAL/GLOBAL x; CONST nil` (neto +1, el POP de
     sentencia lo descarta) — **sin CALL**: el nombre nunca llega a
     `GET_GLOBAL`, así que `vm.c`/`codegen.c`/runtime LLVM no necesitan
     cuerpo para `transfer` (un camino que se escape falla ruidoso:
     «undefined variable» en VM/C, «not found» en LLVM). En LLVM: `store`
     de `zeroInit(tipo)` en el alloca del binding (mismo nil que un `let`
     sin inicializador). observable solo en **globales** entre funciones
     (S1 es intraprocedural): `transfer_global_nil.astra`.
  5. **Fuera de v1**: S3/`spawn` (`ui/spawn_global_atomic` se pospone con el
     spawn — `research/026` §3.6 «y spawn cuando entre»), `.copy()`
     (PR fase-E2), RT1 (DEC-023, M4), `AtomicRef`, v2/v3.
- **Alternativas consideradas**: builtin con FnObj + CALL en los 4 motores
  (~8–9 ficheros de plumbing) — descartado: el emitter ya es el sitio que
  026 §3.2 designa para la invalidación, y sin CALL no hay riesgo de
  divergencia por nombre; checks-only sin nil-red — descartado: R4 exige la
  red runtime para el caso global; rechazar transfer de globals —
  descartado: es el caso que la nil-red existe para observar.
- **Coste aceptado**: 2 typecheckers (registro + early-path + M1 + pasada),
  2 emisores (seed + zig) + el LLVM (store nil), sin cambios de VM/C.
- **Evidencia**: los 11 `ui/` + `conformance/transfer/` + `codegen/` del PR
  fase-E1 en las 4 rutas; `ui_message_parity.sh` con primera línea
  byte-idéntica; `--check-constructs` sigue 47/27 (DEC-022: sin keyword).
- **Spec**: `ARCHITECTURE.md` §2.6 (regla) + este apéndice (detalles v1).

### DEC-027 — Fase E2: `.copy()` (deep copy estructural)
- **Estado**: **Aceptada (test-pinned)** — fijada en el PR fase-E2
  (2026-10-28).
- **Fecha**: 2026-10-28.
- **Decisión**: el escape legal de S2 (`research/026` R3(c),
  `ARCHITECTURE.md` §2.6 §4):
  1. **Forma**: solo método `x.copy()`. El fallback vive en el path
     `FIELD_ACCESS` de `typecheck_call`/`checkCall`, **después** de la
     tabla de métodos (un método de usuario llamado `copy` gana) y antes
     del fall-through a field-read: chequea el receiver (mismo conjunto de
     tipos que `transfer`: array/struct/enum/fn/string/optional/unknown;
     escalares → `copy expects an aggregate, got <tipo>`, loc = nodo del
     receptor como los errores de field actuales), exige 0 argumentos
     explícitos (`copy takes no arguments`) y **devuelve el tipo del
     receptor** — no `unknown`: así `let c = a.copy(); c[0]` tipa sin
     anotación (el pitfall del registro genérico que hizo furor en el
     research). La forma directa `copy(x)` **no existe**: `copy` no se
     registra como símbolo, así que `typecheck_ident` la rechaza con
     `copy must be called as x.copy()` (M1 de transfer, traducido).
     El nombre **sí** se reserva en `kBuiltins`/`k_builtins` (DEC-015):
     el emisor del form método emite `GET_GLOBAL "copy"` y la
     resolución por nombre debe ser inequívoca en las 4 rutas.
  2. **Semántica — deep copy estructural** recursivo (prof. cap 64):
     arrays (shell + elementos recursivos), structs (campos recursivos),
     enums con datos (payload recursivo), optional **caja** (contenido
     recursivo) y **pareja** (bits + retain del payload puntero),
     strings **compartidos** (inmutables — en LLVM `retain` del mismo
     puntero), closures = shell nuevo que comparte `code`/`constants`
     (plantilla de `OPCODE_CLOSURE`) con **env copiado en profundidad**;
     los **markers de builtin se comparten** (nunca se clonan: el
     despacho de `OPCODE_CALL` es por identidad de puntero —
     `param_count == 255 && code == NULL`). Escalares no llegan
     (rechazo en compile-time). **Depth cap 64** → error de runtime
     `copy depth limit exceeded`: los ciclos son construibles hoy
     (`struct N { kid: N? }; n.kid = some(n)` — verificado en las 4
     rutas) y un copy sin tapa divergiría (la fuga de ciclo de rc que
     `astra_runtime_llvm.c:41` documenta como «la única que este modelo
     no puede colectar»).
  3. **Walker (S1/S2)**: el receiver de una llamada a **método de
     usuario** ahora **escapa** (el callee no-builtin recibe `self` como
     argumento 0 — hueco de sonido de la fase E1, pinneado por
     `ui/transfer_method_escaped.astra`); el receiver de `.copy()` **no**
     escapa (copy sólo lee la fuente — `let c = a.copy(); transfer(a)`
     sigue legal si `a` era único) y sus (vacíos) argumentos tampoco.
- **Alternativas consideradas**: forma directa `copy(x)` como
  primitives — descartada de v1 (026 sólo especifica `.copy()`; añade un
  early-path y tests por mensaje); registro como `fn(unknown) -> unknown`
  — descartado: `let b = copy(a); b[0]` muere con «cannot index
  non-array type unknown» (research §5.5) y el form método ya devuelve el
  tipo real; `copy` sin reservar — descartado: `GET_GLOBAL "copy"` por
  nombre ambiguo con un binding de usuario (divergencia de rutas, la
  misma razón de DEC-015); deep copy de strings — descartado (inmutables,
  DEC-013: compartir es la semántica); share-shallow de env de closures —
  descartado: el env es el estado que el copy debe independizar.
- **Coste aceptado**: 8–9 ficheros por el patrón builtin (seed vm +
  codegen + runtime; zig vm; LLVM emitter + runtime) + los 3 typecheckers
  de fallback/forma + los 2 walkers, sin opcode nuevo.
- **Evidencia**: los tests de la fila; gates del PR fase-E2 (seed, sweep,
  zig, ui parity, dump, llvm parity ×2, jit, sanitize).
- **Spec**: `ARCHITECTURE.md` §2.6 §4 (el escape) + este apéndice.

### DEC-028 — parser.astra v2: NEWLINE, `match` e items `enum`
- **Estado**: **Aceptada (test-pinned)** — fijada en el PR parser-v2
  (2026-10-29).
- **Fecha**: 2026-10-29.
- **Decisión**: segundo incremento de `seed/tests/selfhost/parser.astra`
  (plan de crecimiento de `PHASE1_PROGRESS` §7, pasos 1–2 sin lambdas):
  1. **Terminador de sentencia** (espejo del `optional_semi` del seed):
     `;` **o** cambio de línea (token actual en otra línea que el último
     consumido) **o** `}` **o** EOF. Verificado empíricamente: el seed
     acepta `fn f() -> i32 { return 5 }` y sentencias separadas por
     NEWLINE sin `;`, y **rechaza** expresiones que continúan tras NEWLINE
     (`let x = 1 +` \n `2` falla en el NEWLINE) — por eso el fixture v2
     no pone operadores a fin de línea (límite declarado, igual que el de
     DEC-025 sobre strings/hex). **`else` en línea aparte** del `}` del
     then: rechazado también por parser.astra (el seed lo rechaza, E1
     verificado); el v1 era más permisivo — se cierra.
  2. **`match`** como expresión y como sentencia: coma **obligatoria**
     entre brazos (sin ella el seed falla — verificado `0 => 1` \n
     `_ => 2` → `expected '}'`), trailing opcional; **guardas se parsean
     pero no se emiten** (el dump del seed omite el guard: mirror lossy
     documentado en PHASE2 §7 — el golden no puede distinguirlas);
     patrones: literal entero (con `-` → `UnaryOp(-) IntLit`), string,
     bool, or-patterns (`PatternOr(n)` con aridad), `_` →
     `PatternWildcard`, ruta calificada `FieldAccess(field) Ident(root)`
     (la misma forma que la expresión), `Point.Pt(a, b)` →
     `PatternVariantBind(path Bind(a) Bind(b))` (payload **sin** paréns
     en el nombre del nodo; sin wildcard por campo — el seed lo rechaza)
     y binding simple `PatternBind(name)` (un ident suelto siempre es
     binding: DEC-008 prohíbe la forma pelona de variantes).
  3. **Items `enum`**: `EnumDecl(name)` + `Variant(v)` con `Field(TypeIdent)`
     por payload (tipos de payload de un solo ident en v2 — `i32`; límite
     declarado).
  4. **Fixture v2** (`parser_input.astra`): reescrito con sentencias en su
     mayoría **sin `;`** (y unas pocas con `;` — ambos caminos del
     terminador quedan cubiertos), enum + match (literales, negativos,
     or-patterns, guarda, variantes calificadas, bindings, brazos-block y
     match en sentencia) + el resto del subconjunto v1. `parser.expected`
     se regenera desde `--dump-ast | normalize_ast.awk` (el freshness
     check del gate los mantiene sincronizados).
- **Alternativas consideradas**: token NEWLINE explícito en el lexer del
  parser (descartado: el control de línea por token actual/logrado da la
  misma semántica sin tocar el lexer ni el flujo de skips); mantener `;`
  obligatorio (descartado: el objetivo del plan es parsear código real
  del repo, que es mayoritariamente sin `;`); emitir guardas (imposible:
  el golden sale del dump del seed, que las omite).
- **Coste aceptado**: ~120 líneas en `parser.astra` (línea de tokens,
  `stmt_end`, regla del `else`, `parse_pattern`/`parse_match`, item
  `enum`) + fixture/golden nuevos; 0 líneas de compilador.
- **Evidencia**: `parser_gate.sh` (7 rutas + freshness) con el fixture v2
  — el golden es el AST del parser en C, implementación independiente.
- **Spec**: alcance y límites en la cabecera de `parser.astra`.

### DEC-029 — parser.astra v2.1: lambdas
- **Estado**: **Aceptada (test-pinned)** — fijada en el PR
  parser-lambdas (2026-10-29).
- **Fecha**: 2026-10-29.
- **Decisión**: tercer incremento de `seed/tests/selfhost/parser.astra`
  (paso 2 de `PHASE1_PROGRESS` §7 — «match + lambdas», ahora completo):
  1. **Forma**: `|params| [-> type] { block }`. El cuerpo **debe ser
     bloque — el seed rechaza el cuerpo sin llaves (`|y| y * 2` →
     `expected '{' for lambda body`, verificado); el parser reporta lo
     mismo. Cada parámetro: `IDENT [":" type]`; la anotación `-> type`
     es opcional en el parser (el seed la exige solo en algunos casos —
     `| | {}` sin anotación falla con `lambda requires explicit return
     type annotation` — y la inferencia cubre los demás: `|a: i32, b: i32|`
     sin `->` typecheckea, verificado) y se **descarta** (el dump no la
     imprime).
  2. **Sin parámetros**: `||` lexea como token OR_OR y el seed lo
     rechaza en posición de expresión (verificado); la grafía espaciada
     `| |` sí parsea (dos PUNCT `|`) y con `-> T` typecheckea y corre
     (verificado) — el loop de parámetros del parser cubre ambos casos
     sin código especial (`||` tratado como cierre inmediato).
  3. **Dump**: `Lambda` + `[Param(name)]*` + `[TypeIdent(ret)]` +
     `Block` — **los tipos de parámetro no se imprimen** (comment de
     `ast.zig` + verificado empíricamente: `|x: i32| -> i32` imprime un
     TypeIdent que es el de retorno, `|a: i32, b: i32|` sin `->` no
     imprime ninguno). El golden sale de `--dump-ast`, así que la forma
     anterior es ley.
  4. **Fixture**: cuatro lambdas en `main` (tipada con ret, identidad sin
     tipar, multi-tipada, `| | -> i32`) + llamadas, todas con NEWLINE
     (los dos caminos del terminador siguen cubiertos); sin tipos fn
     (`fn(i32) -> i32`) en anotaciones — `parse_type` v2 sigue con
     ident simple (límite declarado desde DEC-025).
- **Alternativas consideradas**: emitir tipos de parámetro en el dump
  (descartado: el golden es el dump del seed, que no los imprime — el
  parser debe reproducirlo, no «mejorarlo»); soportar cuerpo sin bloque
  (descartado: el seed lo rechaza); soportar `||` como lista vacía
  (imposible sin cambiar el lexer: es un único token OR_OR — y el seed
  tampoco lo acepta).
- **Coste aceptado**: ~45 líneas en `parser.astra` (`parse_lambda` en
  `parse_primary` + entrada por `|`/`||`), 0 líneas de compilador.
- **Evidencia**: `parser_gate.sh` (7 rutas + freshness) con el fixture
  v2.1; las cuatro formas fueron ejecutadas en el seed antes de
  escribirse (42/41/42/7).
- **Spec**: cabecera de `parser.astra`.

### DEC-030 — parser.astra v2.2: capa de items (struct/trait/impl/use/import)
- **Estado**: **Aceptada (test-pinned)** — fijada en el PR parser-items
  (2026-10-29).
- **Fecha**: 2026-10-29.
- **Decisión**: paso 3 del plan de `PHASE1_PROGRESS` §7 — con esto el
  parser cubre **todos los items de módulo** del subconjunto Astra-0:
  1. **Items**: `struct` (campos `name: Type` → `Field(name)` +
     `TypeIdent` hijo), `trait` (sólo firmas: una firma sin cuerpo produce
     `Block` vacío — el seed lo sintetiza, verificado; los métodos
     default son rechazo del *typecheck*, no del parser: `--dump-ast` es
     parse-only y el gate no typechequea), `impl [Trait for] Type` con
     payload de texto crudo (`Impl(Area for Punto)` / `Impl(Punto)`),
     `pub` delante de `fn`/`struct`/`const`/`enum`/`trait` con los
     prefijos verificados (`PubFnDecl`, `PubStructDecl`, `PubConstDecl`,
     `PubEnumDecl`, `PubTrait` — `pub` antes de `impl`/`use`/`import` no
     se soporta, el seed tiene campos is_pub solo en esas declaraciones).
  2. **Módulo**: `use ruta.dotted` → nodo `Use` **sin payload** (mirror
     lossy del dump, PHASE2 §7), `import ruta [as alias]` →
     `Import(ruta as alias)` con texto crudo, `from ruta import a, b as c`
     → `From(ruta)` + `ImportItem(a)`/`ImportItem(b as c)` con texto
     crudo; segmentos de ruta sólo IDENT (una palabra clave tras un `.`
     es error — espejo de `ui/import_keyword_segment`).
  3. **Struct literals** con la regla literal del seed: flag
     `no_struct_lit` (`parser.c:1894`) activo en las **cuatro**
     condiciones (if/while/for/match — `parser.c:649/704/730/910`) y
     restablecido dentro de paréntesis (`parser.c:289`); `IDENT {` en
     cualquier otro sitio es literal (los argumentos de llamada heredan
     el flag, igual que el seed). `Punto {}` vacío → `StructLit(Punto)`
     (verificado).
  4. **Parámetros**: `:` opcional en cualquier `fn` — el seed restringe
     `self` sin anotación a trait/impl (`allow_self`, `parser.c:1097`);
     **cerrado 2026-10-29 (M-T3, paridad, sin nuevo comportamiento)**:
     parser.astra implementa las tres reglas del seed — `'self' parameter
     outside a trait or impl`, `'self' must be the first parameter`,
     `'self' is required as the first parameter of a method` — así que el
     superconjunto del parser v2.2 sobre `self` ya no existe
     (test-pinned: `ui/self_outside_impl.astra`, gate `parser_diag_parity`
     19/19). Igual para la coma entre campos/variantes de struct/enum
     (`ui/{struct,enum}_comma_body.astra`): antes se aceptaban en
     silencio, ahora se rechazan como el seed.
- **Límites declarados**: sin genéricos en items (`struct Box<T>`,…),
  sin `pub` antes de impl/use/import, rutas de impl sólo con ident
  simple, **sin literales float en el fixture** (el dump los formatea con
  `%g` y `to_string` es sólo-enteros — imprimir `FloatLit` igual que el
  seed requeriría un builtin de float; los campos del fixture son i32).
- **Alternativas consideradas**: lookahead `IDENT { IDENT :` para
  distinguir literal de bloque (descartado: el seed usa flag de contexto
  y el lookahead rompería `Punto {}` y divergiría); ignorar el flag y
  tratar `IDENT {` siempre como literal (descartado: rompe `if x {`),
  sin estructura de items (era el paso — sin ella el parser no parsea el
  corpus real del repo).
- **Coste aceptado**: ~130 líneas en `parser.astra` (parse_fn compartido
  con trait/impl, items, struct-lit con flag, rutas de módulo), 0
  líneas de compilador.
- **Evidencia**: `parser_gate.sh` (7 rutas + freshness) con el fixture
  v2.2; todas las formas dump-first con `--dump-ast` del seed y el
  fixture ejecutándose en el VM (incluye `p.area()` sobre
  `struct+trait+impl`).
- **Spec**: cabecera de `parser.astra`.

### DEC-031 — parser.astra v2.3: diagnósticos de error (paridad de primer error)
- **Estado**: **Aceptada (test-pinned)** — fijada en el PR parser-diag
  (2026-10-29).
- **Fecha**: 2026-10-29.
- **Decisión**: cuarto incremento de `parser.astra` (paso 4 de
  `PHASE1_PROGRESS` §7 — «diagnósticos comparados con los del seed»):
  1. **Formato**: `file:line:col: error: <msg>` en cada diagnóstico, con
     las dos formas del seed: *expect* `expected <msg>, got <kind>`
     (`parser.c:133`; got = `token_kind_name`: keywords en su grafía,
     punctuación su grafía, `IDENT`/`INT_LIT`/`STRING_LIT`/`EOF`
     mayúscula, y **`_` es un token propio** — verificado con
     `match_no_comma`: `got _`) y *parser_error* `<msg>` sin got
     (`parser.c:78`). Síntesis de NEWLINE para los expect que el seed ve
     sin `skip_newlines` (verificado: cierre de llamada — `print(1\n}`
     → `expected ')', got NEWLINE` en la columna fin-de-línea); el resto
     reporta en el token actual (`ef_now`). Al final: `error: parse failed`
     y **sin dump del AST** cuando hubo errores (`driver.c:668`).
  2. **Correcciones de comportamiento** (cada una verificada ejecutando
     el seed antes de escribir — DEC-028 §1 se corrige): el separador
     **nunca** es obligatorio (`print(1) print(2)`, `let x = 1 let y = 2`
     y `let x 5 print(x)` parsean y corren — `stmt_end` sólo consume el
     `;` opcional); `=` opcional en `let` (VarDecl sin inicializador +
     la siguiente expresión como sentencia); **sentencias a nivel de
     módulo** (`foo bar` = dos idents — `parse_module` rama a
     `parse_stmt`, espejo de `toplevel_stmts`); la coma faltante de
     `match` **no se reporta**: el bucle de brazos rompe y el `}`
     esperado choca con el primer token del siguiente brazo
     (`expected '}', got <kind>`); `else` en línea aparte cae como
     sentencia (`unexpected token in expression` en el `else`); y
     `invalid assignment target` para no-LValue, reportado en el token
     después del `=`.
  3. **Gate**: `parser_diag_parity.sh` — 16 fixtures rotos en
     `selfhost/parser_errors/`, comparación del **primer** error + la
     línea final, con rutas normalizadas; cableado dentro de
     `parser_gate.sh` (seed-only, como `lexer_tokens_parity`).
     **Fuera de alcance v1**: la cascada posterior al primer error (la
     recuperación completa del seed — sync por declaración, aborting
     guards, dummy `<?>` — es el paso siguiente cuando se necesite).
- **Alternativas consideradas**: replicar la recuperación completa ya
  (descartada de v1: el parser usa avance-eager y no el modelo
  current/sin-consumir del seed; coste alto y la paridad de primer error
  ya fija formato+posición+palabra); comparar todos los errores
  (descartado: cascadas divergentes harían rojo un gate útil);NEWLINE
  como token explícito (descartado: la síntesis por línea-lograda cubre
  los casos verificados sin reescribir el lexer).
- **Coste aceptado**: ~90 líneas (columnas, helpers de diagnóstico,
  alineación de mensajes) + 16 fixtures + el gate; 0 líneas de
  compilador.
- **Evidencia**: `parser_diag_parity.sh` → 16/16; el gate de rutas y el
  freshness siguen en verde con el fixture v2.2 sin cambios de salida.
- **Spec**: cabecera de `parser.astra` + esta sección.

### DEC-032 — Typechecker en Astra-0: alcance y forma de v1
- **Estado**: **Aceptada (doc)** — el comportamiento que fija (los dos
  pines de control-flow) llega con DEC-033 + sus tests; esta entrada
  gobierna los PRs de implementación que abren el milestone M-T1.
- **Fecha**: 2026-10-29.
- **Decisión** (las 10 preguntas de `research/032` §6, resueltas con el
  criterio de `PHILOSOPHY.md` — *«todo está permitido siempre que mejore
  Astra»* y *simplicidad como estrategia*; nada de adorno ni de prisa
  que baje el listón):
  1. **Rutas: 7** (patrón lexer/parser con skip limpio). El typechecker
     es componente self-host de la misma clase: cómputo puro sobre un
     fixture; aceptar 4 sería regalar rigor sin ganar nada.
  2. **Entrada: tablas SoA construidas por `parser.astra`** —
     `struct Ast { kind: [i64], a: [i64], b: [i64], s: [string] }`
     (hijos = índices en la misma arena; nombres en `s`). Es la única
     disciplina 100 % soportada en lectura y escritura en la ruta LLVM
     (campo→índice; `a[i][j]` está muerto salvo copia-anotada). La
     s-expresión actual pasa a ser un **rendering** de esas tablas: los
     gates de rutas/freshness/diagnósticos siguen byte-idénticos y no
     hay segundo IR ni re-parseo (una sola verdad — el axioma de
     simplicidad). La símbolos = tablas planas + pila de marcas de
     scope (mismo argumento LLVM; lookup por escaneo lineal con `==`,
     probado). **Concatenación en el gate**: el programa combinado es
     `parser.astra` (sin su `main`, que es su última función) +
     `typechecker.astra` (su `main` llama a `parse_module()` y chequea
     las tablas); disciplina de nombres sin colisión — si colisionan,
     el typecheck del seed las delata con `duplicate function` (fallo
     ruidoso, no silencioso). Se descarta el re-parseo del string
     s-expresión (parserar un parse) y el formato máquina aparte (otro
     IR que mantener).
  3. **Corpus v1 ≈176 ficheros** (medido: 189/304 parsean hoy) con
     **lista de exclusión explícita y comentada** en el gate (patrón
     `llvm_parity` EXCLUDE): los 5 `ui/` de mensajes *emitter-owned*
     (`break/continue outside loop`, `loop_nesting_deep`,
     `capture_assign`, `too_many_locals` — el seed los rechaza en una
     capa POSTERIOR: implementarlos en el typechecker sería capa
     equivocada) y los 12 `transfer_*` (§8b ownership = fase posterior).
     Ningún fichero se excluye en silencio.
  4. **Verdad semántica: espejo byte a byte de `typechecker.c`**
     (doctrina dump-parity; los 102 mensajes ya son la referencia de
     facto y las DEC 006/008/015/022/026 están ya implementadas allí).
     Los dos quirks (retorno de `fn` sin anotar no se chequea; la
     anotación de retorno de una lambda no se compara con el tail) se
     **clonan** y se registran como candidatos a corrección — corregir
     exige su propio PR con DEC (nada de forks silenciosos: la
     semántica vive en un solo sitio).
  5. **`some/none/ok/err`**: el parser pasa a emitir las formas del
     seed (nodos propios, no `Call(Ident)`) en expresiones y patrones —
     prerequisito de que el typechecker pueda tipear opcionales; la
     sintaxis de tipo `T?`/`[T]` queda en el backlog *medido* de
     extensiones del parser (research/032 §2), no en este ciclo.
  6. **Single-file `seed/tests/selfhost/typechecker.astra`** — el LLVM
     no compila multi-fichero y el patrón de 7 rutas exige un fichero;
     el árbol `src/compiler/` de Step 4 llega con la CLI (DEC-021 sigue
     `Propuesta` y no se adelanta).
  7. **Presupuesto: sin techo nuevo** — los 256 globales del VM (cada
     `fn` de módulo cuenta) y los 256 de profundidad son la guarda
     automática que ya falla ruidoso; diseño: combinado ≤ 200 globales
     (parser: 38 fns; typechecker: objetivo ≤ 80 fns con helpers `tc_`
     compactos). RSS sin techo extra: el gate corre fichero a fichero
     como el resto de selfhost.
  8. **Orden**: typechecker → **emitter** (028 §5: «el codegen va el
     último»); migración al árbol + CLI en Step 4.
  9. **Hallazgos sin pinnear**: se cierran ANTES del primer código de
     este plan, con DEC-033 + tests (regla: decisiones antes que
     código) — el typechecker tocaría esos comportamientos el día uno.
  10. **Milestones**: M-T1 refactor SoA (gates existentes verdes) →
      M-T2 núcleo (~35 checks + gate diferencial) → M-T3
      methods/trait/match/exhaustividad → M-T4 corpus completo.
      Estimación ~10–15 d/h en 4–5 PRs con la forma DEC-gated de la
      serie DEC-025..031.
- **Alternativas consideradas**: rutas 4 (regala rigor, sin beneficio);
  re-parseo del s-expresión (parserar un parse, dos formas de verdad);
  formato máquina nuevo (segundo IR que mantener); corpus completo sin
  exclusiones (haría rojo por capas ajenas — la misma lección de
  `llvm_parity` que convirtió los skips en fallos **documentados**);
  corregir los quirks dentro del port (fork de semántica sin DEC);
  árbol multi-fichero desde ya (el LLVM no puede y la CLI aún no existe).
- **Coste aceptado**: refactor de `parser.astra` a tablas (los gates
  existentes son la red de seguridad) + ~55 checks + gate diferencial.
- **Evidencia**: `research/032` (todo medido: 189/304, 20 experimentos de
  ruta, inventario de mensajes) — los PRs de M-T1..M-T4 la convierten en
  `test-pinned` progresivamente.
- **Spec**: `research/032` §4–§5 + esta sección.

### DEC-033 — Pines: if/else-if como cola de fn y else en línea aparte
- **Estado**: **Aceptada (test-pinned)** — fijada en el PR DEC-032/033
  (2026-10-29).
- **Fecha**: 2026-10-29.
- **Decisión**: registrar (no re-litigar — regla 2) los dos
  comportamientos que los hallazgos de la fase E1/`PHASE1` §7 dejaron sin
  pinnear, **antes** de que el typechecker en Astra (DEC-032) los
  reproduzca:
  1. **`if/else if/else` como última expresión de un `fn`** es error en
     ambos compiladores con la misma primera línea:
     `file:2:5: error: if branches have different types: <T> vs void`
     (y la segunda `function 'j' returns <T> but its body has type
     <error>`); un `if/else` simple como cola **sí** typechea
     (verificado) — la asimetría es el bug latente; se pinnea la
     superficie de HOY.
  2. **`}` \n `else`**: el `else` no se une al `if` y cae como
     sentencia → `unexpected token in expression` en el `else`
     (primeras líneas idénticas seed↔zig; el zig reporta además una
     cascada — `ui_message_parity` sólo compara la primera). `} else`
     en la MISMA línea sí funciona, y el cuerpo del else puede empezar
     en la línea siguiente (`} else\n{` — verificado).
- **Por qué ahora**: DEC-032 obliga a decisiones «antes que código» y
  ambos son semanticamente de dominio del typechecker/validación que el
  port va a tocar el día uno; dejarlos sin pin = comportamiento
  contractual nadie vigilaba.
- **Corrección futura**: si se arreglan (p. ej. tipar la cola if-cadena),
  el PR trae un DEC que superscriba esta entrada y reescribe los tests
  — el pin existe para que el cambio sea explícito, no para congelar
  bugs para siempre.
- **Evidencia**: los dos `ui/` con primera línea byte-idéntica
  seed↔zig (`ui_message_parity.sh`) + salida conjunta verificada en los
  dos binarios (2 errores idénticos en (a); 1 vs 2 líneas en (b) con la
  primera igual).
- **Spec**: esta sección; el parser de `parser.astra` ya implementa (b)
  (DEC-031 §2).
