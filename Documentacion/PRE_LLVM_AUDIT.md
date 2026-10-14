# Astra — Auditoría previa a la Fase 2.6 (LLVM)

Fecha de inicio: 2026-10-14. Motivo: la Fase 2.6 introduce un backend
nativo (LLVM o codegen Zig) sobre **toda** la semántica ya construida;
antes de apilar una capa más se revisa desde el principio todo lo hecho
(Fase 1 `seed/` + Fase 2 `zig/`), se documenta por partes, y se fija cada
bug encontrado con su repro y su test.

> Relación con lo anterior: `COHERENCE_AUDIT.md` (2026-09-16/21) auditó
> coherencia doc↔código y memoria del seed *de la Fase 1*, con PoCs en
> `PHASE1_PROGRESS.md` §6. Esta auditoría cubre **todo lo posterior y
> rehecha la verificación activa** con herramientas que entonces no
> había (barridos diferenciales a los tres backends, campañas de fuzz
> con ASan sobre la suite, verificación de mensajes byte-a-byte).

---

## §0 — Plan, método y criterios

### Alcance y partes

| § | Parte | Qué cubre |
|:-:|:------|:----------|
| 1 | **Barridos activos** | Bugs encontrados *ejecutando*: conformance↔C (`--emit-c`+gcc vs VM), mensajes `ui/` seed↔zig, campaña de fuzz con ASan |
| 2 | **Frontend seed** | `lexer.c`, `parser.c` (Pratt, profundidad, recuperación), `ast.c`, `constructs/` + registry |
| 3 | **Semántica seed** | `typechecker.c`: ámbitos, literales polimorficos, `match`, structs/enums, traits/genéricos, `?`, mutabilidad |
| 4 | **Emitter + VM seed** | `emitter.c` (balance de pila, parcheo de saltos), `vm.c` (frames, opcodes, valores) |
| 5 | **C backend** | `codegen.c`, `codegen_runtime.h`: modelo de memoria, setjmp, límites de registro, posiciones de línea |
| 6 | **Zig** | Paridad real de mensajes (hoy sin gate), diagnósticos por fase, módulos, huecos de los `checked > N` |
| 7 | **Suite de tests** | Qué feature no tiene test, aserciones débiles, `EXPECT:` vs comportamiento real |
| 8 | **Docs** | AGENTS/PROGRESS/CHANGELOG/GAP/ARCHITECTURE vs código |
| 9 | **Síntesis** | Bugs fijados/diferidos, criterios de entrada a la Fase 2.6 |

### Método (igual para cada parte)

1. **Pruebas activas primero**: barridos/fuzz que ejercitan los tres
   caminos (VM seed, `--emit-c`+gcc, `astra-zig`) y comparan salida y
   mensajes; todo hallazgo empieza por una repro mínima en
   `/tmp/opencode/`.
2. **Lectura de código enfocada**, no línea a línea: los invariantes de
   `AGENTS.md` ("Invariantes que hay que preservar", "Key codegen
   invariants"), las rutas de error, los límites de tamaño, y las
   funciones que la repro toca. Se usa `explore` en paralelo cuando una
   parte supera dos lecturas.
3. **Fix-forward**: cada bug confirmado → repro verde tras el fix →
   test que lo fija → gates (`make debug` + `run_tests` +
   `--check-constructs`; `zig build test`; `dump_parity.sh`) → commit
   propio en convención (`fix(seed):`, `fix(zig):`, `test(lang):`…) con
   el número de hallazgo en el mensaje (`audit §N.M`).
4. **Documentación por parte**: cada § se escribe aquí con su tabla de
   hallazgos y se cierra con su propio commit `docs(audit): …`.

### Registro de hallazgos

Cada parte cierra con una tabla:

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| N.1 | 🔴/🟠/🟡/🔵 | `emitter.c:123` | descripción | ✅ fix `<hash>` / ⚠️ diferido (razón) / 📋 abierto |

- 🔴 crash/UB/corrupción de memoria · 🟠 respuesta incorrecta o
  divergencia entre backends · 🟡 mensaje/edge-case · 🔵 higiene
  (docs, tests, aserciones).
- ⚠️ *diferido* exige razón explícita; 📋 *abierto* no puede pasar a §9.

### Criterios de salida hacia la Fase 2.6 (detalle en §9)

1. Cero hallazgos 🔴 abiertos; 🟠 cerrados o diferidos con repro
   documentada.
2. Los tres barridos de §1 en verde y **puestos como gate** (script en
   `seed/tests/`, hilo en CI o `make`).
3. Cobertura mínima: cada feature con `EXPECT:` o `EXPECT-ERROR` en al
   menos un caso; sin `checked > N` sueltos en `conformance.zig`.
4. §4 (emitter/VM) cerrado: la semántica que LLVM deberá replicar está
   verificada y fijada con tests — es la base que el backend nuevo
   copia.
5. Mensajes seed↔zig: o byte-idénticos o divergencia de formato
   aceptada y documentada en §6.

---

## §1 — Barridos activos (VM↔C, mensajes ui, fuzz)

### Qué se ejecutó

| Barrido | Herramienta | Qué compara |
|:--------|:------------|:------------|
| conformance↔C | `seed/tests/sweep_emit_c.sh` (nuevo) | los 68 casos no-UI de `conformance/` por VM y por `--emit-c` + gcc: stdout, stderr y código de salida byte a byte (salta los 3 de módulos: `import_from`, `root_import`, `use_paths`) |
| mensajes ui | `zig/tests/ui_message_parity.sh` (nuevo) | los 65 casos de `conformance/ui/`: rechazo por ambos compiladores + **primera línea** de diagnóstico idéntica |
| fuzz | `make fuzz` + campaña 300 s; replay `-runs=0` en CI | harness libFuzzer (lexer→parser→typechecker→emitter) con ASan sobre todo `tests/` |

Evolución del barrido de mensajes: **20** divergencias iniciales → **16**
tras §1.2 → **10** tras §1.3, de las cuales solo **1** afecta a la primera
línea (KNOWN); las otras 9 son cascadas de recuperación en línea ≥2 o
textos del typechecker.

### Tabla de hallazgos

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| 1.1 | 🟠 | `codegen.c` (`OPCODE_CALL`), `codegen_runtime.h` (`ASTRA_PUSH`) | El C backend **no tenía guarda de profundidad de llamada**: `countdown(300)` imprimía `300` con exit 0 mientras el VM abortaba con `call depth exceeded` (divergencia conductual, no solo de texto — la nota de `run_tests.sh` que decía que los backends ponían sus límites "con texto distinto a propósito" era falsa). Cuando el backend C sí paraba, mensaje y línea diferían (`frame stack overflow` en la 10 vs `call depth exceeded` en la 11), y el desbordamiento de operandos imprimía `stack overflow` con un formato de posición distinto. | ✅ fix `b3136d1` — guardas `astra_depth`/`ASTRA_CALL_DEPTH 256` (sincronizadas con `VM_CALL_DEPTH` por comentario), mensajes idénticos en los tres caminos; tests `codegen/frame_overflow.astra` (reescrito) y `stack_overflow_limit.astra` ×2 (literal de 1100 elems); gate nuevo `sweep_emit_c.sh` |
| 1.2 | 🟡 | `parser.c:57,123` + 6 sitios `aborting ... body`; `emitter.c` (capture, break/continue, 4 internos) | El seed imprimía `error:LOC: msg` (el `error:` antes de la posición), `break`/`continue` **sin posición** y `error:%s:%u:` en los invariantes internos, mientras zig ya emitía `LOC: error: msg`. Además `expect`/`parser_error` seguían hablando durante el unwind: `nesting_too_deep.astra` producía **257 líneas** (1 de breach + 256 `expected '}'`). | ✅ fix `a72d4a7` — todas las rutas con posición imprimen `file:line:col: error: msg` (el `SrcLoc` ya llevaba columna); `expect`/`parser_error` se callan bajo `p->aborted` y `parser_enter` sella **después** del único informe de breach. 257 → 1 + resumen. msg_diff 20 → 16. |
| 1.3 | 🟡 | `parser.zig` `report`/`expect`/`parseFrom` | Tres espejos rotos del `parser.c` del seed: (a) `report()` colgaba un sufijo `(found <token>)` a **cada** diagnóstico y un `lex_err` perdía el mensaje del lexer (`unexpected token in expression (found ERROR)` en vez de `integer literal is out of range for i64` / `unterminated string literal`); (b) `expect` imprimía `expected <kind.name()>` con el vocabulario zig (`comma`, `rbrace`, `kw_let`), sin el `got` del seed ni sus mensajes propios (`field name`, `variant name`, `module path`, `/ after @`); (c) `parseFrom` entraba en su bucle hasta en EOF, de modo que `from x import` sin items fallaba por `expect` en vez de aplicar la regla "al menos un item". | ✅ fix `6437aa0` — `reportExact()` con rama `lex_err` → `current.text` (espejo de la rama `TOKEN_ERROR`), sufijo eliminado; `expectMsg(tag, msg)` con el formato seed `expected %s, got %s` y `Tag.seedName()` (la tabla ya portada del dump-parity = `token_kind_name`); bucle de `from` con condición `!eof/!aborted` + informe con la misma redacción. msg_diff 16 → 10; primera línea 64/65. |
| 1.4 | 🔵 | `seed/build/fuzz/artifacts/` (2026-10-13) | Los dos artefactos de la campaña previa (NULL-deref en `typechecker.c:1569` `field_access` y `:2343` `fn_body`) corresponden a bugs **ya corregidos** por `ae5ee81`; la campaña nueva de 300 s fue limpia (164 649 ejecuciones). No existe `seed/fuzz/regressions/` porque la repro ya está en la suite, y el replay `-runs=0` de todo `tests/` ya corre en CI. | ✅ documentado — sin acción (los artefactos son obsoletos) |
| 1.5 | ⚠️ | recuperación de errores seed↔zig | Tras el primer error las cascadas difieren **por diseño**: seed aborta el cuerpo (`aborting ... body`; 12 líneas en `generic_param_limit`) y zig desenvuelve (`unexpected token in expression`; 2-3 líneas). 8 archivos difieren solo en línea ≥2 (break_value, enum/struct_comma, generic_param, impl_missing, integer_literal, self_outside, unterminated). | ⚠️ diferido: es forma de recuperación, no bug — el gate de §1 compara la primera línea. Si se unifica, va en §6. |
| 1.6 | 🟡 | `typechecker.c` (seed) vs zig, `fuzz_field_access_null_type.astra:32,46` | Mismo rechazo, texto distinto: seed `symbol 'self' has no type` vs zig `cannot access field on non-struct type unknown`. La primera línea del archivo casa; difieren las líneas 5 y 7 del volcado. | ✅ fix `ac987ca` (§3.2/§3.6) — los receptores `unknown` degradan igual en ambos: `arithmetic operator requires numeric type, got unknown` y `cannot access field on non-struct type unknown` byte-idénticos; el rama `symbol '%s' has no type` ya no existe |
| 1.7 | 🔵 | `emitter.c:254` (`add_local`) | `too many locals (max 256)` sin posición en el seed (el Emitter no tiene filename en el punto de choke) y con `file:` pero **sin línea** en zig: única primera línea divergente, aceptada como `KNOWN_FIRST_LINE` del gate. | ⚠️ diferido: exige hilar un `SrcLoc` por `add_local` (~8 call sites); el comportamiento es correcto en ambos, solo degrada la posición |

### Gates (criterio de salida 2 de §0 — ✅ cumplido)

| Gate | Dónde | Estado actual |
|:-----|:------|:--------------|
| `sweep_emit_c.sh` | step del job `seed` en CI + ejecución local | 🟢 68/68, 0 divergencias (1 fallo antes del fix 1.1) |
| `ui_message_parity.sh` | step del job `parity` en CI, `STRICT=1` por defecto | 🟢 total=65, accept_fail=0, first_fail=0, known=1 |
| replay de fuzz `-runs=0` | step del job `seed` en CI | 🟢 corpus íntegro, sin hits de sanitizer |

---

## §2 — Frontend seed (`lexer.c`, `parser.c`, `ast.c`, `constructs/`)

Catorce hallazgos (2.1–2.14) más dos accesorios. Doce cerrados con fix
propio y test; 2.9/2.10 se rederivaron después (su contenido original
se perdió con el contexto) y se cerraron en `74a90b4`.

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| 2.1 | 🟠 | `lexer.c` (tabla de keywords) | El lexer emitía `TOKEN_NOT` para el operador `!` (el mismo token de la keyword muerta `not`), pero el nud de Pratt solo tenía caso `TOKEN_BANG`: `print(!true)` era error de parseo en el seed mientras zig lo imprimía. `operator_table.c:75` ya declaraba `!`/`TOKEN_BANG`. | ✅ fix `8832fc9` — el lexer emite `TOKEN_BANG`; test `expressions/not_op.astra` |
| 2.2 | 🟠 | `parser.c` `parse_if`, `parser.zig` `parseIf` | La cadena `else if` recursaba sin guard de profundidad: 30k eslabones reventaban ASan en C y el stack en zig. | ✅ fix `8832fc9` — ambas entradas pasan por `PARSER_MAX_DEPTH` (breach byte-idéntico, 260:15); test `ui/deep_elseif.astra` |
| 2.3 | 🟠 | `parser.c` `parse_pattern`, `parser.zig` `parsePattern` | `some(some(...))` ×300 ciclaba `parse_pattern`↔`parse_pattern_primary` sin que el guard de expresión/bloque lo viera. | ✅ fix `8832fc9` — guard en ambas entradas (breach 8:1284 idéntico); test `ui/deep_pattern.astra` |
| 2.4 | 🟠 | `lexer.c` `read_number` | El buffer fijo `char buf[64]` truncaba cualquier float de más de 63 caracteres significativos y `strtod`'eaba el número equivocado — `0.5e-61` con padding leía distinto que zig. | ✅ fix `b3c798b` — buffer en el arena de tamaño `len+1`; test `expressions/float_long_literal.astra` (EXPECT `1.23457e+72`) |
| 2.5 | 🟡 | `parser.zig:342` (entrada `kw_var`) | Zig parseaba `var x = 5` como un `let` **inmutable** por una entrada suelta: la declaración compilaba y solo la asignación posterior fallaba (`cannot assign to immutable variable 'x'`), mientras seed rechazaba el token. ARCH §8.1: la forma canónica es `let`/`let mut`; `var` es token residual sin uso. | ✅ fix `97f8909` — entrada eliminada; ambos rechazan el token con primera línea idéntica; test `ui/var_keyword_rejected.astra` |
| 2.6 | 🟡 | `parser.zig` (13 sitios de llave de cuerpo) | `expect(.lbrace)` imprimía el nombre crudo del token (`expected {, got let`) donde el seed imprime la descripción del contexto (`expected '{' for function body, got let`): la primera línea divergía en todo error de cuerpo. | ✅ fix `e5376a4` — los 13 sitios (if/else/while/for/match/`=>`/fn/struct/enum/trait/impl/lambda/struct-lit) pasan `expectMsg` con la descripción del seed; habilita el test de §2.13 |
| 2.7 | 🟡 | `driver.c` `run_dump_ast` | `--dump-ast` salía con rc=0 aunque el parser hubiera fallado: el volcado salía roto y con éxito. | ✅ fix `2364a2c` — consulta `parser_had_error()`; sección en `run_tests.sh` que fija rc 0/1 del flag |
| 2.8 | 🟠 | `lexer.c` `read_number` | Prefijos sin dígitos (`0x`, `0b`, `0o`) se lexaban como enteros vacíos en vez de error. | ✅ fix `b3c798b` — ≥1 dígito real exigido, `integer literal is out of range for i64` en la posición inicial (7 variantes byte-idénticas a zig); test `ui/int_prefix_no_digits.astra` |
| 2.9 | 🟠 | `lexer.zig:358-369` `skipWhitespace` | Los comentarios de bloque **anidan** en el seed (contador de profundidad desde el commit inicial) y zig se detenía en el primer `*/` (su comentario citaba mal al seed): `/* /* */ código */` borraba en silencio todo el resto del archivo en zig, rc=0 y sin diagnóstico, mientras seed imprimía `2`. | ✅ fix `74a90b4` — zig porta el contador; test `expressions/nested_comment.astra` |
| 2.10 | 🟠 | `lexer.c`/`lexer.zig` `read_number` | Un marcador de exponente sin dígitos (`print(1e)`) se plegaba a **1.0** vía `strtod` en el seed y a **0.0** vía `parseFloat`'s `catch` en zig: dos respuestas del mismo fuente, ambas rc=0. | ✅ fix `74a90b4` — ≥1 dígito tras `e`/`E` en ambos lexers, `exponent has no digits`; test `ui/exponent_no_digits.astra` |
| 2.11 | 🟡 | `parser.c:2036-2046` `parse_declaration` | `had_error` es un bit pegajoso de todo el archivo, así que el guard `!err_before` sincronizaba **a lo sumo una vez por archivo**: cada declaración rota posterior devolvía su nodo parcial a `module->items` y la recuperación degradaba a un error por token basura (seed 5 líneas donde zig imprimía 2). El nodo parcial no llegaba a las fases posteriores solo porque todos los consumidores chequean `parser_had_error()`. | ✅ fix `179d138` — contador de errores por declaración (`error_count`); siempre sync+drop ante uno nuevo, como el catch por-declaración de zig; test `ui/parse_sticky_recovery.astra` |
| 2.12 | 🔴 | `arena.c` `st_grow` | La ventana de redimensionado no incluía la cabecera de datos: un crecimiento en el límite producía un WRITE OOB de 196608 bytes (ASan), alcanzable desde el harness de fuzz. | ✅ fix `5435722` — `min_size = data_offset() + align_up(size,align) + align` + revalidación tras `arena_grow`; repro byte-exacta en `seed/fuzz/regressions/arena_stgrow_window.astra` (192520 bytes), el replay de CI la copia al corpus |
| 2.13 | 🟠 | `parser.c` (6 sitios `expect(TOKEN_LBRACE)` + `parse_match`) | `expect` no era fatal y a continuación se llamaba `parse_block` incondicionalmente: un `fn`/`if`/`while`/`for`/`lambda` sin `{` fabricaba un bloque sin llave de origen y **se tragaba las declaraciones siguientes** (validas, sin diagnóstico propio) y el error final señalaba EOF; un brazo de match sin `=>` construía el brazo de todos modos. | ✅ fix `179d138` — los seis sitios cortan en la falla (`body = NULL`, return del nodo) y el caller los descarta con sync; igual para `=>`; test `ui/parse_missing_body.astra` (habilitado por §2.6) |
| 2.14 | 🟠 | `astra.h` `Value.as.string_val`, `vm.c` | El Value del VM guardaba strings como `char *` **sin longitud**: un literal con `\0` se imprimía, concatenaba, comparaba y medía truncado en el primer NUL (`print("a\0b")` → `a`; el truthiness también mentía para `"\0abc"`). El C backend ya era correcto (`AstraString{data,len}`) y zig también (slices). | ✅ fix `97f8909` — `struct { str, len }` en el Value; print con `fwrite` (no `%.*s`, que también para en NUL), concat/len/equality length-bounded, `cg_write_c_escaped(s,len)`, dumps con `fwrite`; test `types/string_nul.astra` (concat+equality contra literales `\0`, sin bytes NUL en EXPECT) |
| 2.x | 🟡 | `parser.c:968` `parse_return` | `return` como últimos 6 bytes del archivo (sin newline final) hacía parse-expression sobre EOF: el seed rechazaba y zig aceptaba. El guard miraba `;`/newline/`}` pero no EOF (el de `break` sí). | ✅ fix `74a90b4` — EOF añadido al guard; ambos aceptan |

### Leads explorados y refutados (§2)

Descartados con evidencia: desbordes de lectura del lexer en cadena sin
terminar / comentario sin terminar (todos los accesos tienen guarda de
`source_len`; ambos compilan idénticos); contabilidad de columnas
CRLF/tab/UTF-8 (los dos `advance` son byte-a-byte idénticos); bucles de
EOF en el parser (todos con guarda); `--check-constructs` vs la tabla de
operadores (47 constructs, OK); `no_struct_lit` save/restore (los
mismos seis contextos en ambos compiladores); `synchronize` que se traga
una sentencia válida tras un `;` huérfano (solo observable en archivos
ya rechazados; no promovido).

---

## §3 — Semántica seed (`typechecker.c`) y espejo zig

Catorce hallazgos numerados (3.1–3.14) más tres accesorios (A1–A3).
Cerrados: 3.1–3.7, 3.10 y (absorbido) 3.13/§1.6. Diferidos con repro a
§9: 3.8 (🟠, decisión de lenguaje) y 3.9/3.11/3.12/3.14/A1 (🔵/🟡,
decisiones documentales o de feature).

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| 3.1 | 🟠 | `typechecker.c` (bucle de parámetros de lambda) | Un lambda sin anotar (`\|x\| { x + 1 }`) tipaba el parámetro como NULL y la comprobación de aritmética chocaba en `typecheck_call` con ASan (deref de NULL), en vez de degradar. | ✅ fix `ac987ca` — los tres bucles de parámetros (lambda, fn body, fn decl) pasan `TYPE_UNKNOWN`; test `ui/lambda_untyped_param.astra` |
| 3.2 | 🟠 | `typechecker.c` (`impl` + `typecheck_call`) | El `self` de un `impl` sin receptor anotado seguía con tipo NULL y el call-site no lo guardaba: crash en el checker. | ✅ fix `ac987ca` — rama `symbol '%s' has no type` → `return TYPE_UNKNOWN` + guard NULL en `typecheck_call`; test `ui/impl_unknown_self.astra` |
| 3.3 | 🟠 | `typechecker.c` `NODE_PATTERN_BUILTIN_VARIANT`, `typechecker.zig` | `some(v)`/`ok(a)`/`err(e)` tipaban el binding como el **optional completo**, no como el payload: `v + 1` era `arithmetic operator requires numeric type, got optional` y el literal `some(1)` se rechazaba en patrón. El VM siempre extrajo el valor; el chequeo iba atrás del runtime y de research/011 §5.2 (Result estático Tier 2: `ok`/`err` comparten `TYPE_OPTIONAL(payload)`, la distinción vive en el tag de runtime). | ✅ fix `213cc35` — ambos chequeadores bajan `optional.inner`; test `enums/payload_binding_types.astra` (43/84/43/111 en VM, C y zig) |
| 3.4 | 🟠 | `typechecker.c` `check_pattern`/`typecheck_match`, `typechecker.zig:1303+` | Dos huecos de exhaustividad: (a) una armada con guardia contaba como cobertura, así que `E.B if flag => 2` como única cobertura de `B` aceptaba un match que caía a `nil` bajo una promesa i32; (b) el chequeo solo corría contra enums, así que `match x { some(v) => v }` sobre `x = none` devolvía `nil` bajo `-> i32`. | ✅ fix `61b2e30` — las guardias no marcan cobertura ni eximen; target optional se verifica con dos slots (payload some/ok/err + none); un binding desnudo sin guardia, como `_`, exime; tests `ui/match_guarded_variant`, `ui/optional_match_missing_none`, `ui/optional_match_missing_payload`, `enums/bind_catch_all` |
| 3.5 | 🟡 | `typechecker.c` (decl y literal de struct), `typechecker.zig` | Un struct con dos campos `a` se pisaba en silencio (ganaba el último) y una clave repetida en el literal reutilizaba el primer valor; además struct/enum de módulo se chequeaban **dos veces** (pase 1 + `default` del pase de bodies), duplicando todo diagnóstico de su cuerpo. | ✅ fix `99759d5` — `duplicate field 'a' in struct 'S'` en la declaración (colecta) y `duplicate field 'a' in struct literal` en el literal; pase 2 de ambos omiten struct/enum ya chequeados; tests `ui/struct_duplicate_field`, `ui/struct_lit_duplicate_key` |
| 3.6 | 🟠 | `typechecker.c` `typecheck_call` | Un argumento con tipo `unknown` (por el grupo de 3.1/3.2) cruzaba el guard del call y producía crash en vez del diagnóstico degradado. | ✅ fix `ac987ca` — guard NULL, mismo texto que zig |
| 3.7 | 🟡 | `typechecker.c` `typecheck_enum_decl`, `typechecker.zig` `checkEnumDecl` | Variantes duplicadas (`enum E { A A }`) se aceptaban: `covered[]` tiene un slot por grafía, así que un match correcto reportaba un `non-exhaustive match: missing variant 'E.A'` **imposible de satisfacer**. | ✅ fix `74a90b4` — rechazo con el molde de los campos de struct, ambos lados; test `ui/enum_duplicate_variant.astra` |
| 3.8 | 🟠 | `typechecker.c:2251-2327`, `typechecker.zig:1399-1455` | El match sobre un target **escalar** (int/string/bool/float) nunca se verifica de exhaustividad: `let r = match x { 1 => 10 }` con `x = 9` devuelve `nil` bajo cualquier promesa, byte-idéntico en VM seed, VM zig y C backend (runtime deliberate: "No arm matched: yield nil"). ARCH §11.3 pide compile error por defecto. | ⚠️ diferido a §9 — repro `/tmp/opencode/sem/match_int_fall.astra` (los tres backends imprimen `nil`; con `-> i32` el `+` revienta en runtime `cannot add nil and int`); decisión pendiente: exigir `_` en targets escalares (estilo Rust) o panic en runtime en vez de `nil` |
| 3.9 | 🔵 | ARCH §34.2/§34.3, `research/010`, `constructs/assign.c` | El operador compuesto `+= -= *= /=` está prometido por la precedencia del ARCH y la grammática del registry (`.in_astra0 = true`), pero **no es alcanzable en ningún compilador**: los tokens ni siquiera se lexean y el soporte existente es código muerto en tres capas (desugars del typechecker que no instalan los nodos reescritos, walkers del emitter sin caso de emit). | ⚠️ diferido a §9 — decisión: implementar (lexer+parser; los desugars medio-hechos existen) o borrar `+=` del ARCH/research/`assign.c` y eliminar los brazos muertos |
| 3.10 | 🟠 | `typechecker.c:3010` (y zig pass 1), `codegen.c:163-166,606-626` | Una `fn` de módulo duplicada se aceptaba: el VM conservaba la **última** definición (el symbol se prepende) y el C backend emitía la **primera** (`fn_map` first-wins + `emit_fn_bodies` corta en el primer par) — `fn main` dos veces imprimía `2` en el VM y `1` en el binario C. | ✅ fix `74a90b4` — `duplicate function 'name'` en ambos chequeadores; test `ui/duplicate_function.astra` |
| 3.11 | 🔵 | ARCH §30.2 vs §8.1, `parser.c:1093` | La matriz de mutabilidad está en paridad total seed↔zig (`let`/`const`/param/campo-through-immutable/capturada, con tests). El residual: los parámetros son inmutables por diseño de parser en ambos lados (`mut x: i32` se rechaza), pero ARCH §34.3 promete `param = ["mut"] IDENT`, y ARCH §30.2 aún muestra `var y = 5 // mutable`, contradiciendo §8.1. | ⚠️ diferido a §9 — decisión: ¿params `mut` en Astra-0?; y limpiar §30.2 |
| 3.12 | 🟡 | `typechecker.c:229-246`, `typechecker.zig:241`, ARCH §30.1 | ARCH §30.1 dice "redeclaración en mismo scope: COMPILE ERROR"; ambos compiladores la aceptan silenciosamente (`let x = 1; let x = 2` → `2`). El shadowing anidado/global sí es correcto y testeable. | ⚠️ diferido a §9 — decisión: hacer cumplir §30.1 (estilo Rust) o reescribir la sección para bendecir el shadowing (el comportamiento actual es coherente y simétrico) |
| 3.13 | 🔵 | — | El hallazgo numerado 3.13 del informe original no se pudo recuperar con certeza tras la pérdida de contexto; por su familia semántica quedó absorbido por §1.6 / 3.2 (acceso a campo sobre receptor `unknown`), cerrado en `ac987ca`. | ✅ absorbido |
| 3.14 | 🔵 | ARCH §11.2/§11.3 | `@non_exhaustive`, los bindings `n @ patrón` y los patrones de rango `0..=9` que el ARCH presenta como parte del lenguaje **no existen en ningún compilador** (el único `@` del seed es la ruta de módulo `@/`). Hoy el wildcard es la única forma de cubrir un target escalar. | ⚠️ diferido a §9 — decisión: marcarlos explícitamente out-of-Astra-0 en el ARCH o agendarlos |
| A1 | 🟡 | `typechecker.c:2485`, `typechecker.zig:1563` | `let x: i32` **sin inicializador** se acepta en ambos y `x` vale `nil` bajo la promesa del tipo (runtime `cannot add nil and int` en los tres backends), mientras research/010 (citado por `constructs/binding.c`) hace `=` obligatorio en la grammática. | ⚠️ diferido a §9 — decisión: exigir inicializador (como la grammática) o añadir definite-assignment |
| A2 | 🔵 | `emitter.c:1735`, `emitter/emitter.zig:1816` | El chequeo "no se puede asignar a una capturada" vive en los **emitters**, no en los typecheckers, y su posición carece de columna (`file:3:`), unlike todo lo armonizado en §1.2. Cubierto por `ui/capture_assign.astra`. | ⚠️ diferido a §9 — higiene: subir el chequeo al checker o al menos hilar el `SrcLoc` |
| A3 | 🔵 | `lexer.c:9,28,31,43` | `and`, `or`, `not`, `in`, `as`, `comptime` se lexean como keywords pero ningún parser los usa (`true and true` es error de parseo; `&&` funciona, que es lo que ARCH §34.2 promete). La vocabulario de diagnósticos del typechecker sí dice "and"/"or". | ⚠️ documentado — sin acción inmediata; candidato a limpieza con §3.9 |

### Leads explorados y refutados (§3)

`while`/`if` con condición no-bool (idéntico en ambos; `if` acepta
optional como prueba de presencia y `while` lo rechaza — asimetría
interna, cero divergencia); `!`/`-`/`&&`/`||` sobre no-bool (rechazo
idéntico); división entera y comparaciones mixtas int/float (truncan y
rechazan igual en VM seed, VM zig **y** C backend); lambda
auto-recursivo por `let` (`undefined variable 'f'` idéntico); `var`
(cerrado en §2.5).

### Cómo se contó

Los números 2.9/2.10 y 3.7–3.14/A1–A3 se **rederivaron** con sondas
mínimas tras perderse el informe original de los agentes explore
(`/tmp/opencode/astra29/` y `/tmp/opencode/sem/`); los rows 2.1–2.8 y
2.11–2.14 / 3.1–3.6 provienen de los fixes ya commiteados
(`8832fc9`…`74a90b4`).

### Estado de los gates al cierre de §3

| Gate | Valor |
|:-----|:------|
| seed `run_tests.sh` | 🟢 178/178 |
| `--check-constructs` | 🟢 OK (47 constructs) |
| `sweep_emit_c.sh` | 🟢 74/74, skip=3 (módulos), fail=0 |
| `dump_parity.sh` | 🟢 100/100 |
| `zig build test` | 🟢 73/73 |
| `ui_message_parity.sh` | 🟢 total=81, accept_fail=0, first_fail=0, known=1; msg_diff_full=12 (bucket informativo de cascadas) |

---

## §4 — Emitter + VM seed (`emitter.c`, `vm.c`)

Seis hallazgos (4.1–4.6) más dos notas de higiene, de una auditoría con
sondas sobre los invariantes de `AGENTS.md` (balance de pila, offsets
`T-P`, frames slot 0/1, scopes por secuencia, recurrencia acotada).
Cerrados los seis en `e88d925`.

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| 4.1 | 🔴 | `vm.c:825` (DIV), `codegen_runtime.h` `astra_div`/`astra_mod`, `vm.zig:896` | `INT64_MIN / -1` (y `% -1`) trampaba el hardware en **los tres backends**: ASan FPE + abort en el debug del seed, SIGFPE en release, `Excepción de coma flotante` en el binario C, panic `integer overflow` en zig — ninguno producía un diagnóstico posicionado. | ✅ fix `e88d925` — guard con `integer overflow` idéntico en vm.c, codegen_runtime y vm.zig; test `expressions/int_min_div_neg1.astra` (EXPECT-RUNTIME-ERROR) |
| 4.2 | 🔴 | `vm.c` ADD/SUB/MUL/NEG, `codegen_runtime.h` `astra_add/sub/mul/neg` | La aritmética entera con overflow era **UB** en el VM seed y en el C backend (UBSan la reportaba en un programa legal: `max + 1`), mientras zig la definía con `+%`/`-%`/`*%` (wrap). Las salidas coincidían en la práctica, pero dos de los tres caminos eran indefinidos. | ✅ fix `e88d925` — wrap vía casts `uint64_t` en los dos lados C; test `expressions/integer_wrap.astra` (4 EXPECTs con los valores envueltos) |
| 4.3 | 🟠 | `emitter.c:1546`, `emitter/emitter.zig:1709` | El epílogo del `NODE_MATCH` reclaimaba **solo el último slot** (`local_count--`), no el bloque de bindings del arm: con un patrón de ≥2 campos, los nombres anteriores quedaban vivos en la tabla local del emitter y una referencia posterior al mismo nombre resolvía al slot muerto con el payload viejo — `print(a)` tras `Pair.Two(a, b) => a+b` imprimía el payload en los **tres** backends (respuesta incorrecta silenciosa). | ✅ fix `e88d925` — snapshot de `local_count` antes del local oculto y restauración entera en ambos emitters; test `enums/match_binding_reclaim.astra` (3/7/3) |
| 4.4 | 🟠 | `codegen_runtime.h` `astra_print_value` `AST_ENUM_DATA` | El C backend imprimía un variant con payload como `E.B` (sin los campos) donde el VM seed y zig imprimen la forma constructora `E.B(7)`; `enum_print.astra` solo cubre unit variants, por eso el sweep no lo pillar. | ✅ fix `e88d925` — espejo del print del VM (paréntesis, campos `", "`-separados); test `codegen/enum_payload_print.astra` |
| 4.5 | 🟠 | `vm.c:1447` (`OPCODE_RET` con `frame_count == 0`), `typechecker.c` `typecheck_return` | Un `return` a scope de módulo se aceptaba en silencio: ambos VMs lo trataban como "fin del módulo" (rc=0, `main` no corría) y el C backend generaba `return frame[sp-1]` dentro de una función `int` → C que no compila. | ✅ fix `e88d925` — ambos chequeadores rechazan `return outside of a function`; el alcance se mide con `fn_depth` (contador de cuerpos fn/lambda), **no** con `current_fn_return`, que también es NULL en una fn sin anotar (el primer intento rechazaba returns legítimos y lo pilló `result_match`); test `ui/toplevel_return.astra` |
| 4.6 | 🔴 | `parser.c` loop Pratt (`led`), `parser.zig` `parseExprImpl`, `typechecker.c:913`, `emitter.c:994` | El guard de profundidad del parser cubre su descenso recursivo, pero el loop Pratt es **iterativo**: una cadena plana (`1+1+1+…`, `a[0][0]…`) construye árboles tan profundos como quiera el usuario y `typecheck_binary`/`emit_expr` recursan una vez por nodo sin cota — ASan stack-overflow a **300** términos en el debug del seed, SIGSEGV a ≥8000 en release, zig segfault a 20k. | ✅ fix `e88d925` — contador de cadena en el loop Pratt de ambos parsers, cap = `PARSER_MAX_DEPTH` (256), `expression chain too deep (max 256)`; test `ui/expr_chain_deep.astra` |

### Notas de higiene (§4, sin acción)

- 33+ bucles anidados: ambos compilan rechazan con `loop nesting too
  deep (max 32)` (sin posición) seguido de ~40 `internal: stack
  imbalance` en cascada — consistente entre compilers, ruidoso.
- `field 'f' expects fn, got fn` (mismatch de tipos fn en campos) es
  byte-idéntico en los tres pero no dice *qué* tipos fn difieren.

### Invariantes verificados OK (§4)

1. **Balance de pila** — modelo de efectos en compile-time
   (`opcode_stack_effect`) + neutralidad de sentencia; cero errores de
   desbalance interno en probes legales; `while`/`for`/`return`/`break`/
   `continue` sin POP final; la asignación produce su valor.
2. **Offsets de salto** — todos los sitios de patch usan `T-P`; VM
   `ip += offset; ip--`; C `i + offset`; loops, break/continue, if como
   expresión, match dentro de loops: byte-idénticos en los tres.
3. **Frames** — slot 0 oculto `$ret`/callee, params desde 1; top-level
   como globales; GET_CAPTURE lee `stack[base]`.
4. **Scopes** — `symbol_table_pop_scope` elimina por `seq >= cutoff`
   (nunca por hash). La tabla de *locales del emitter* tenía el bug
   4.3, pero no es la symbol table.
5. **Recurrencia acotada** — ahora completa: parser (§2.2/2.3) **y**
   cadenas planas (§4.6).

### Familias exploradas y limpias (§4)

Cobertura de opcodes (los 53 con case en vm.c **y** codegen.c; el
`default:` de codegen es error duro — sin drops silenciosos); patching
de bucles; `return` en todas las posiciones (menos módulo = 4.5);
arity en runtime (guard en `vm.c:1386`); edges del modelo de valores
(aliasing de arrays/structs, OOB y índice negativo con mensaje
byte-idéntico en los tres, división float por cero, `%` negativo,
comparación de strings uniformemente diferida a runtime); builtins (solo
`print`, alcanzable solo vía GET_GLOBAL); `?` fuera de loops y por
frames anidados; switches de depuración `ASTRA_DUMP_VM`/`ASTRA_TRACE`.

---

*(Las secciones siguientes se van añadiendo conforme avanza la
auditoría; cada una cierra con su commit.)*
