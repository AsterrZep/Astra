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
| 1.2 | 🟡 | `parser.c:57,123` + 6 sitios `aborting ... body`; `emitter.c` (capture, break/continue, 4 internos) | El seed imprimía `error:LOC: msg` (el `error:` antes de la posición), `break`/`continue` **sin posición** y `error:%s:%u:` en los invariantes internos, mientras zig ya emitía `LOC: error: msg`. Además `expect`/`parser_error` seguían hablando durante el unwind: `nesting_too_deep.astra` producía **257 líneas** (1 de breach + 256 `expected '}'`). | ✅ fix `a72d4a7` — todas las rutas con posición imprimen `file:line:col: error: msg` (el `SrcLoc` ya llevaba columna); `expect`/`parser_error` se callan bajo `p->aborted` y `parser_enter` sella **después** del único informe de breach. 257 → 1 + resumen. msg_diff 20 → 16. **Amend `f3751d9` (2026-10-15, verificación posterior):** la reclamación `file:line:col` no se cumplía para `break`/`continue` — imprimían `file:line:` y su nodo llevaba la loc del newline tras `optional_semi`, no la de la keyword (parser.zig siempre la había capturado antes: los dos parsers divergían en silencio, enmascarado porque solo se imprimía la línea). Ahora ambos imprimen `file:line:col` de la keyword, pineado con `EXPECT-ERROR-FIRST` en `ui/break_outside_loop` y el nuevo `ui/continue_outside_loop`. Excepciones documentadas: rutas `internal:` y la de asignación-a-capturada (A2) siguen en `file:line:`. |
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
Cerrados: 3.1–3.8, 3.10 y (absorbido) 3.13/§1.6. Diferidos con repro a
§9: 3.9/3.11/3.12/3.14/A1 (🔵/🟡, decisiones documentales o de feature).

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| 3.1 | 🟠 | `typechecker.c` (bucle de parámetros de lambda) | Un lambda sin anotar (`\|x\| { x + 1 }`) tipaba el parámetro como NULL y la comprobación de aritmética chocaba en `typecheck_call` con ASan (deref de NULL), en vez de degradar. | ✅ fix `ac987ca` — los tres bucles de parámetros (lambda, fn body, fn decl) pasan `TYPE_UNKNOWN`; test `ui/lambda_untyped_param.astra` |
| 3.2 | 🟠 | `typechecker.c` (`impl` + `typecheck_call`) | El `self` de un `impl` sin receptor anotado seguía con tipo NULL y el call-site no lo guardaba: crash en el checker. | ✅ fix `ac987ca` — rama `symbol '%s' has no type` → `return TYPE_UNKNOWN` + guard NULL en `typecheck_call`; test `ui/impl_unknown_self.astra` |
| 3.3 | 🟠 | `typechecker.c` `NODE_PATTERN_BUILTIN_VARIANT`, `typechecker.zig` | `some(v)`/`ok(a)`/`err(e)` tipaban el binding como el **optional completo**, no como el payload: `v + 1` era `arithmetic operator requires numeric type, got optional` y el literal `some(1)` se rechazaba en patrón. El VM siempre extrajo el valor; el chequeo iba atrás del runtime y de research/002 §5.2 (Result estático Tier 2: `ok`/`err` comparten `TYPE_OPTIONAL(payload)`, la distinción vive en el tag de runtime). | ✅ fix `213cc35` — ambos chequeadores bajan `optional.inner`; test `enums/payload_binding_types.astra` (43/84/43/111 en VM, C y zig) |
| 3.4 | 🟠 | `typechecker.c` `check_pattern`/`typecheck_match`, `typechecker.zig:1303+` | Dos huecos de exhaustividad: (a) una armada con guardia contaba como cobertura, así que `E.B if flag => 2` como única cobertura de `B` aceptaba un match que caía a `nil` bajo una promesa i32; (b) el chequeo solo corría contra enums, así que `match x { some(v) => v }` sobre `x = none` devolvía `nil` bajo `-> i32`. | ✅ fix `61b2e30` — las guardias no marcan cobertura ni eximen; target optional se verifica con dos slots (payload some/ok/err + none); un binding desnudo sin guardia, como `_`, exime; tests `ui/match_guarded_variant`, `ui/optional_match_missing_none`, `ui/optional_match_missing_payload`, `enums/bind_catch_all` |
| 3.5 | 🟡 | `typechecker.c` (decl y literal de struct), `typechecker.zig` | Un struct con dos campos `a` se pisaba en silencio (ganaba el último) y una clave repetida en el literal reutilizaba el primer valor; además struct/enum de módulo se chequeaban **dos veces** (pase 1 + `default` del pase de bodies), duplicando todo diagnóstico de su cuerpo. | ✅ fix `99759d5` — `duplicate field 'a' in struct 'S'` en la declaración (colecta) y `duplicate field 'a' in struct literal` en el literal; pase 2 de ambos omiten struct/enum ya chequeados; tests `ui/struct_duplicate_field`, `ui/struct_lit_duplicate_key` |
| 3.6 | 🟠 | `typechecker.c` `typecheck_call` | Un argumento con tipo `unknown` (por el grupo de 3.1/3.2) cruzaba el guard del call y producía crash en vez del diagnóstico degradado. | ✅ fix `ac987ca` — guard NULL, mismo texto que zig |
| 3.7 | 🟡 | `typechecker.c` `typecheck_enum_decl`, `typechecker.zig` `checkEnumDecl` | Variantes duplicadas (`enum E { A A }`) se aceptaban: `covered[]` tiene un slot por grafía, así que un match correcto reportaba un `non-exhaustive match: missing variant 'E.A'` **imposible de satisfacer**. | ✅ fix `74a90b4` — rechazo con el molde de los campos de struct, ambos lados; test `ui/enum_duplicate_variant.astra` |
| 3.8 | 🟠 | `typechecker.c:2251-2327`, `typechecker.zig:1399-1455` | El match sobre un target **escalar** (int/string/bool/float) nunca se verifica de exhaustividad: `let r = match x { 1 => 10 }` con `x = 9` devuelve `nil` bajo cualquier promesa, byte-idéntico en VM seed, VM zig y C backend (runtime deliberate: "No arm matched: yield nil"). ARCH §11.3 pide compile error por defecto. | ✅ fix `3c2b81a` (decisión en `research/021`, adoptada 2026-10-15) — espacio finito probado (bool con 2 slots como enums), catch-all obligatorio para el resto (`missing '_' arm`); backstop `OPCODE_MATCH_NONE` con `no match arm matched` para el aliasing Tier-2 (repro que antes imprimía `nil`: `expressions/match_fallthrough_trap.astra`); tests `ui/scalar_match_missing_wildcard`, `ui/bool_match_missing_arm` |
| 3.9 | 🔵 | ARCH §34.2/§34.3, `research/001`, `constructs/assign.c` | El operador compuesto `+= -= *= /=` está prometido por la precedencia del ARCH y la grammática del registry (`.in_astra0 = true`), pero **no es alcanzable en ningún compilador**: los tokens ni siquiera se lexean y el soporte existente es código muerto en tres capas (desugars del typechecker que no instalan los nodos reescritos, walkers del emitter sin caso de emit). | ⚠️ diferido a §9 — decisión: implementar (lexer+parser; los desugars medio-hechos existen) o borrar `+=` del ARCH/research/`assign.c` y eliminar los brazos muertos |
| 3.10 | 🟠 | `typechecker.c:3010` (y zig pass 1), `codegen.c:163-166,606-626` | Una `fn` de módulo duplicada se aceptaba: el VM conservaba la **última** definición (el symbol se prepende) y el C backend emitía la **primera** (`fn_map` first-wins + `emit_fn_bodies` corta en el primer par) — `fn main` dos veces imprimía `2` en el VM y `1` en el binario C. | ✅ fix `74a90b4` — `duplicate function 'name'` en ambos chequeadores; test `ui/duplicate_function.astra` |
| 3.11 | 🔵 | ARCH §30.2 vs §8.1, `parser.c:1093` | La matriz de mutabilidad está en paridad total seed↔zig (`let`/`const`/param/campo-through-immutable/capturada, con tests). El residual: los parámetros son inmutables por diseño de parser en ambos lados (`mut x: i32` se rechaza), pero ARCH §34.3 promete `param = ["mut"] IDENT`, y ARCH §30.2 aún muestra `var y = 5 // mutable`, contradiciendo §8.1. | ⚠️ diferido a §9 — decisión: ¿params `mut` en Astra-0?; y limpiar §30.2 |
| 3.12 | 🟡 | `typechecker.c:229-246`, `typechecker.zig:241`, ARCH §30.1 | ARCH §30.1 dice "redeclaración en mismo scope: COMPILE ERROR"; ambos compiladores la aceptan silenciosamente (`let x = 1; let x = 2` → `2`). El shadowing anidado/global sí es correcto y testeable. | ⚠️ diferido a §9 — decisión: hacer cumplir §30.1 (estilo Rust) o reescribir la sección para bendecir el shadowing (el comportamiento actual es coherente y simétrico) |
| 3.13 | 🔵 | — | El hallazgo numerado 3.13 del informe original no se pudo recuperar con certeza tras la pérdida de contexto; por su familia semántica quedó absorbido por §1.6 / 3.2 (acceso a campo sobre receptor `unknown`), cerrado en `ac987ca`. | ✅ absorbido |
| 3.14 | 🔵 | ARCH §11.2/§11.3 | `@non_exhaustive`, los bindings `n @ patrón` y los patrones de rango `0..=9` que el ARCH presenta como parte del lenguaje **no existen en ningún compilador** (el único `@` del seed es la ruta de módulo `@/`). Hoy el wildcard es la única forma de cubrir un target escalar. | ⚠️ diferido a §9 — decisión: marcarlos explícitamente out-of-Astra-0 en el ARCH o agendarlos |
| A1 | 🟡 | `typechecker.c:2485`, `typechecker.zig:1563` | `let x: i32` **sin inicializador** se acepta en ambos y `x` vale `nil` bajo la promesa del tipo (runtime `cannot add nil and int` en los tres backends), mientras research/001 (citado por `constructs/binding.c`) hace `=` obligatorio en la grammática. | ⚠️ diferido a §9 — decisión: exigir inicializador (como la grammática) o añadir definite-assignment |
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

| 4.7 | ✅ | `emitter.c` `NODE_MATCH`/`NODE_IF` + nuevo contador `Emitter.rt` (`priv.h`), `codegen.c` (`SET_LOCAL` con pad, `sp = local_count`), espejo `emitter.zig` (**dossier completo con evidencia, intentos y resolución: `Documentacion/research/022_TAREA_fix_47_match_inline_frame.md` §11 — nombre de delegación `TAREA-4.7-match-inline-frame`**) | **Descubierto al implementar §3.8:** un `match` **inline como argumento de llamada** (y, descubierto al arreglarlo, un `if` con `let` en rama) corrompía el frame en **los dos VMs**: `fn main() { let x = 5; print(match x { 1 => 10, _ => 20 }) }` → `runtime error: cannot call non-function value`. Causa raíz: los slots de locales y los valores de expresión comparten coordenadas del stack de la VM, `add_local` asigna por recuento de declaración, y la frontera real de runtime (los residuos de matches/bloques/bucles previos dejan celdas stale que el VM nunca recorta) no era computable en compile-time — por eso los dos intentos previos con objetivos estáticos fallaban de forma dependiente del camino. | ✅ fix `ed1792e` — dirección (i) del dossier con las piezas que faltaban: (a) contador `rt` de **altura runtime exacta** en paralelo al `sp` viejo (`SET_LOCAL` = `max(rt-1, slot+1)` como `vm.c`; resyncs exactos en `&&`/`||`, brazos, ramas de `if`, fn/lambda); (b) **pad de la tabla de locales hasta la frontera** en la entrada de `match`/`if`; (c) **cierre por camino** (`SET_LOCAL(target)` + `POP` de excedentes) tras cada brazo/rama — elimina además el residuo de los matches en sentencia, con lo que el bloqueador estructural del intento #2 desaparece; (d) stubs de bindings en `guard=false` (parchados más allá de la copia plain duplicada del brazo); (e) ensure de salida de bucle + stubs de reconciliación para `break`; (f) backend C fiel a `vm.c` (pad de nil + `sp = local_count`) para que los closes estáticos signifiquen lo mismo en ambos backends; (g) `NEW_ENUM` corrigiendo también `rt`. Tests: `expressions/match_inline_{call,if_let,after_statement}`, `loops/loop_residue_inline`, `codegen/match_inline_arg` |
| 4.8 | ✅ | `emitter.c` armada bind con guardia (`break` tras `NODE_PATTERN_BIND`), espejo confirmado en `emitter.zig` (candidato reportado en el dossier 022 §1.4, abierto al cerrar §4.7) | Tras un brazo binding **con guardia** hay un `break` incondicional (*"binding makes later arms unreachable"*) que solo es cierto sin guardia: los brazos posteriores **nunca se emiten** aunque el typechecker sí los procesa, así que el programa compila y en runtime cae al backstop de §3.8 — `fn main() { let x = 5; print(match x { n if n > 9 => 1, _ => 2 }) }` con x=5 debería imprimir 2 y hoy aborta `no match arm matched`. El wildcard con guardia tiene el mismo corte: `_ if c => 1, n => n + 100` con guardia falsa devolvía nil silencioso (`has_wildcard` se fijaba antes de mirar la guardia y suprimía el backstop). | ✅ fix `a29f1af` — un wildcard/binding **con** guardia ya no corta el bucle de brazos: la guardia fallida cae al brazo siguiente a la altura de entrada (POP de reconciliación cuando el binding dejó celda viva); solo el catch-all sin guardia suprime el backstop MATCH_NONE. El patrón reutilizado (stub de §4.7) resultó tener su propio bug, registrado como §4.11. Tests `conformance/enums/match_guard_fallthrough.astra` + gemelo `codegen/` |
| 4.9 | 🔴 | `parser.c` `parse_block_impl` (chequeo de cola ANTES de `skip_newlines`), `parser.zig` `parseBlock`; efectos en typechecker (`produces no value`, `void vs …`) y en runtime (nil silencioso) | El último ítem de un bloque solo se promovía a expresión de cola si el token siguiente a la sentencia era `}` **sin newlines de por medio**: `match`, `if` y bloque anidado no ejecutan `optional_semi`, el newline quedaba delante de `}` y se violaba `Block ::= "{" Statement* Expression? "}"` (research/001 §4.2/§4.3). Vectores: una **lambda/fn void terminada en compuesto multilinea devolvía nil EN SILENCIO**; una fn tipada recibía el error engañoso `produces no value` (aconsejaba no poner `;` final, que ya no había); una rama de `if` multilinea se tipeaba `void vs integer`. Descubierto el 2026-10-15 al verificar la lista de fixes de este audit; **preexistente en ambos compilers** (idéntico en `ddc97d2`, no regresión de §4.7); la suite no tenía ningún shape así. | ✅ fix `87aaaf1` — `skip_newlines` antes del chequeo de cola en ambos parsers (solo `;` descarta el valor: `ui/missing_return_value` sigue rechazando `let …;`); test `blocks/tail_compound_multiline.astra` (fn tipada, lambda, rama de `if`, inicializador de bloque) verificado también en el C backend |

| 4.10 | 🔴 | `emitter.c` `emit_back_edge_reconcile` + stubs de `continue` en `loop_leave` (`LoopPatch.head_rt`/`continue_rt` en `priv.h`), espejo `emitter.zig` (`emitBackEdgeReconcile`) | El hueco de `continue` documentado en dossier 022 §11 era real **y más ancho**: la normalización de altura faltaba en dos sitios. (a) El **back-edge no reconciliaba** — las alturas del cuerpo se modelan en la entrada del bucle, pero el salto de vuelta lleva el runtime a la altura del fin del cuerpo, así que desde la iteración 2 el cuerpo corría N celdas alto y un constructo de valor cuyo slot oculto/close target caía entre las dos alturas sobrescribía celdas vivas; repro mínimo **sin `continue`**: `for i in 0..3 { let e = B(s); print(match e { E.B(n) => n }); let z = 0 }` → iteración 2 trap `cannot call non-function value` (el close del match pisaba la celda del receptor `print` y el `CALL` marcaba una celda stale). (b) `continue` saltaba al objetivo sin reconciliar (el stub que el dossier prescribía): sus celdas vivas llegaban de más, o de menos cuando se saltaba declaraciones. Descubierto el 2026-10-16 al implementar el hueco §11 con una batería diferencial `continue`-vs-guarda (150 pares → 2 divergencias; 72 de los "pases" iniciales eran enmascaramiento de mi generador); **preexistente en ambos compilers** (el bug no es de `continue` sino de cualquier iteración ≥2 con declaraciones + constructo de valor en args de call — la suite no tenía ningún shape así). | ✅ fix `4cc9ca2` — drenaje POP en el back-edge hasta `head_rt` y stubs por `continue` hasta `continue_rt` (POP si la ruta llega alta, `CONST nil` si llega baja: la siguiente iteración reescribe cada celda antes de leerla); espejo zig idéntico; el C backend traduce los stubs sin cambios. Tests `conformance/loops/iter_height_norm.astra` (repro sin continue, continue que salta decls, continue que llega baja) + gemelo `codegen/loop_iter_height.astra`; batería diferencial 750 pares a 5 semillas, 0 divergencias |
| 4.11 | 🔴 | `emitter.c` stub de guardia de brazos de variante/builtin con payload (mecanismo añadido en §4.7/`ed1792e`), espejo confirmado en `emitter.zig` | El stub POP era **código muerto**: el re-parcheo *"Re-target the guard-false stub"* volvía a apuntar `arm_gf_patch` (el JIF de la guardia) al final de la iteración, saltándose el POP — las celdas de los bindings extraídos quedaban vivas bajo el brazo siguiente y el `CALL` del resultado llegaba desalineado: `match v { E.B(n) if n > 1 => n, _ => 0 }` con v=B(1) trapeaba `cannot call non-function value` en los tres backends. Los tests de §4.7 solo cubrían variantes **unitarias** (`bind_count=0`, sin stub), así que el hueco nunca corrió. Además el count del POP era `bind_count` a ciegas: con `local_count` ya más allá del frontier (brazos previos siguen en la tabla), cada binding cae una celda más arriba y `SET_LOCAL` paddea una celda stale bajo él, así que el drop correcto es `bind_rt − rt_test` (§4.11 descubierto el 2026-10-16 al cerrar §4.8: el fix de §4.8 reutilizó el stub y el probe de interacción variante-guardia + bind-guardia lo delató). | ✅ fix `a29f1af` — el JIF apunta al stub y **solo el JUMP del stub** recibe el objetivo final; el POP lleva `drop = bind_rt − rt_test` en las tres rutas (variante, builtin, bind plain de §4.8). Tests `conformance/enums/match_guard_payload_stub.astra` (payload simple/doble, builtin Option, cadena con slots stale, cadena de guardias de variante) + gemelo `codegen/` |

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

## §5 — C backend (`codegen.c`, `codegen_runtime.h`)

Ocho hallazgos (5.1–5.8). Cerrados 5.1–5.6 y 5.8 en `6961005`; 5.7
diferido a §9 con repro. Correcciones verificadas contra los tres
caminos (VM seed, `--emit-c`+gcc con `-fsanitize=address` donde
aplica, y zig como referencia).

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| 5.1 | 🔴 | `codegen_runtime.h` `astra_unwrap` | El unwrap hacía `free()` de la celda envolvente sobre una **copia** del valor: dos `match` sobre el mismo `ok` producían double free (`free(): double free detected in tcache 2`, exit 134) e imprimir el scrutinee tras un match era heap-use-after-free (ASan). El VM libera nada (arena). | ✅ fix `6961005` — sin `free()`: el modelo de este runtime es vida de proceso (como el arena del VM); comentario en el sitio citando el hallazgo |
| 5.2 | 🟠 | `codegen_runtime.h` `astra_runtime_error`, `codegen.c` próloga de fn con try | Con un try-context armado, `astra_runtime_error` **longjmp-eaba para toda falla runtime** (div cero, OOB, …) y la próloga devolvía un `astra_error_value` viejo: el binario C imprimía el mensaje, luego `nil`, **exit 0**, mientras VM y zig abortaban con exit 1. `ASTRA_TRY_UNWRAP`'s rama por defecto ni siquiera seteaba el valor. | ✅ fix `6961005` — solo el unwrap de `?` longjmp-ea (`astra_try_unwind`, único punto de entrada, con guarda de `astra_error_active`); `astra_runtime_error` termina con `file:line: runtime error:` + exit(1) incondicional; los `try*` de `codegen/` (incluido `try_nested_frames`) verdes |
| 5.3 | 🔴 | `codegen.c` INDEX/SET_INDEX/LEN/GET_FIELD/SET_FIELD, `astra_array_bounds` | Los handlers dereferenciaban `_arr.as.array_val` / `_s->def` sin comprobar tag ni NULL: un receptor nil producía **SIGSEGV sin diagnóstico** (exit 139) donde el VM daba `cannot index nil` / `cannot access field on nil` / `cannot take length of nil`. | ✅ fix `6961005` — guards espejados con la redacción exacta de `vm.c`; LEN/GET_FIELD/SET_FIELD añadidos a `opcode_is_fallible` (si no, la línea reportada era vieja); test `codegen/nil_receiver.astra` (EXPECT-RUNTIME-ERROR, exit 1 — descarta el 139) |
| 5.4 | 🟡 | `codegen.c` `cg_set_line` | El dedup por función (`last_line`) comparaba contra un shadow local mientras el callee sobreescribía el global `astra_line`: una operación fallible tras una **call en la misma línea** reportaba la línea del callee (`:1:` en vez de `:4:`). | ✅ fix `6961005` — `OPCODE_CALL` invalida el dedup (`CG_NO_LINE`); repro `line_after_call` con la línea del caller en los tres backends |
| 5.5 | 🟠 | `codegen.c` `scan_struct_defs`/`scan_enum_defs` | Los scanners solo seguían `OPCODE_CONST`; un struct/enum usado **solo dentro de un cuerpo de lambda** se registraba tarde (tras los forward declarations) → gcc rechazaba `'g_structdef_0' undeclared` en el C generado, con `--emit-c` "exitoso". | ✅ fix `6961005` — siguen `OPCODE_CLOSURE` (`arg.index >> 8`) y recursan en las constantes de la fn (incluidos `VAL_FN` anidados); repros lambda-struct y lambda-enum limpios con `-Wall -Wextra` |
| 5.6 | 🟠 | `codegen.c` dispatch de `OPCODE_CALL` | `param_count == 255` bastaba para tomar el camino de builtin; el VM exige además `code == NULL` (`vm.c:1393`). Una **closure de exactamente 255 parámetros** usaba el frame equivocado e imprimía `nil` (VM/zig: `254`). Los fns nombrados lo esquivaban porque codegen los emite con aridad 0 hardcodeada. | ✅ fix `6961005` — conjunto `param_count == 255 && code == NULL`; `AstraFn` gana el campo `code` (NULL solo en builtins vía `astra_builtin_fn_new`) |
| 5.7 | 🟡 | `codegen.c` `GET_GLOBAL` de un global no inicializado | El C no tiene tracking de definidez: leer `compute()` antes de declararla da `cannot call non-function value` donde el VM da `undefined global variable 'compute'` (misma línea, mismo exit 1). | ⚠️ diferido a §9 — repro `sem5/e6_fwd.astra`; implica `static uint8_t g_defined_*` o aceptar la divergencia de texto en §6 |
| 5.8 | 🔵 | `codegen_runtime.h` `astra_ptr`, `sweep_emit_c.sh` | Toda literal de struct/enum generaba `-Wdiscarded-qualifiers` en el C (el sweep lo ocultaba con `gcc -w`). | ✅ fix `6961005` — `astra_ptr(const void*)` + el sweep pasa a `-Wall -Wextra` con **fallo explícito si gcc avisa** (el `-w` ya no puede esconder nada); 0 warnings en 74 conformance + 21 codegen |

### Familias exploradas y limpias (§5)

Modelo de memoria (los únicos `free()`s eran el 5.1 y un buffer
temporal de `astra_add`; ASan+LSan en los 21 fixtures: solo fugas de
vida-de-proceso, sin UAF/double-free); cadenas setjmp/longjmp de `?`
(aneados, en match dentro de fn con try — byte-idénticos en los tres;
ningún puntero colgante tras el unwind); posiciones de línea (INDEX en
match en loop, ADD en inicializador de campo, INDEX en lambda —
`file:line:` byte-idénticos); orden de statements de módulo y pool de
constantes; layout de campos de struct (orden de declaración, aliasing,
struct-anidado, métodos); closures (captura por valor, mutación de la
capturada tras crear, recursión mutua y aridad — rechazos idénticos);
los 3 tests de módulos que el sweep salta **sí** generan C válido y
casan con la VM (el salto es precavido, no esconde nada); escapes y
modelo de string (§2.14 re-verificado, sin ruta de inyección).

---

## §6 — Zig (`parser/`, `typechecker/`, `emitter/`, `vm/`, `modules/`, `conformance.zig`, `diagnostics.zig`)

Seis hallazgos (6.1–6.6) más tres *cheap wins* de cascada. Cerrados
6.1–6.4 y 6.6 más los wins en `492f6e4`; 6.5 es higiene documentada.
La paridad de mensajes ya era gate (§1); esta parte ataca lo que el
gate **no veía**.

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| 6.1 | 🟡 | `parser.zig` `expect(tag)` + ~25 sitios | `expect(tag)` caía al nombre crudo del token (`expected )`, `expected :,`) donde el seed **siempre** pasa descripción (`expected ')'`, `expected ':'`, `function name`, `loop variable name`, `struct name`, `alias`, …). Unas 12 divergencias de **primera línea** latentes: el gate es por-fichero y ningún `ui/` existente activaba esos expects como primer error. | ✅ fix `492f6e4` — tabla `seedExpectName` (grafías entrecomilladas de la puntuación + `import`), ~25 sitios a `expectMsg` con la frase exacta del seed (leída call-site a call-site), `parseTypeImpl` deja de morir en `unreachable` y replica `expected type` no fatal; 8 pares repro byte-idénticos + 4 tests `ui/expect_*` que fijan la familia; 23 sitios bare quedan cubiertos por la tabla |
| 6.2 | 🟡 | `conformance.zig` | `expect(checked > 40)` / `> 15`: un fallo del walker que soltara 36/67 ficheros seguía verde (§0.3 prohíbe `checked > N` sueltos); y `EXPECT-RUNTIME-ERROR` con varias directivas tomaba la **última** mientras `run_tests.sh` toma la primera. | ✅ fix `492f6e4` — invariantes seen-vs-procesados (`expectEqual(seen - seen_ui, checked)` y su twin de ui; suelos derivados `> 0`, no mágicos) y primera directiva como el seed; verificado que el fallo sigue propagándose (robo intencional → rc≠0 nombrando el test) |
| 6.3 | 🟡 | `emitter.c` `add_local`/guard de bucles + `emitter.zig` | El seed imprimía `error: too many locals (max 256)` **sin archivo** y `error: loop nesting too deep (max 32)` **sin posición**; zig sí imprimía `file:` y `file:line:col`. Era el hermano no descubierto del KNOWN `too_many_locals` — el gate lo aceptaba. | ✅ fix `492f6e4` — `Emitter.filename` (derivado de `module->loc` en `emitter_emit`, sin tocar `driver/main/fuzz`) + `file:line:col` desde el loc del nodo, espejado en zig (`errLoc`); byte-idénticos ambos pares; **`KNOWN_FIRST_LINE` eliminado del gate → known=0**; tests `ui/loop_nesting_deep.astra` (33 bucles) y el existente `too_many_locals` ahora verificado en serio |
| 6.4 | 🟡 | `sweep_emit_c.sh` (saltos de módulo) | Los 3 tests de módulos que el sweep salta no tenían documentada la razón: el seed descarta `import`/`use` (driver de fichero único) mientras zig resuelve el grafo. | ✅ fix `492f6e4` — comentario en el punto de salto nombra los 3 ficheros y el porqué (comportamiento **por diseño**, no una brecha) |
| 6.5 | 🔵 | `diagnostics`/driver/CLI | (a) con `2>&1` fusionado, el seed imprime la línea de error antes que la salida del programa (stdout block-buffered) y zig al revés — bytes por stream idénticos; (b) `unknown option '--bogus'` vs `unknown flag --bogus`; (c) los resúmenes seed (`error: parse failed`…) no existen en zig (el gate ya los filtra); (d) ~70 `catch @panic("OOM")` de lado compilador y `unreachable`s revisados: todos defensivos. | 📋 documentado — sin acción; (c) es UX deliberada, (a)/(b) no tiene gate que compare streams fusionados |
| 6.6 | 🔵 | `conformance.zig` runner + `diagnostics.zig` | Todo `zig build test` —incluso verde— imprimía una línea engañosa `failed command: … --listen=-`: los runners no cableaban `diagnostics.Sink` y el build-runner zig formatea como fallo cualquier paso con stderr no vacío. Podía enterrar un fallo real en la arqueología de CI. | ✅ fix `492f6e4` — Sink con `echo=false` en el runner de conformance + `quiet_in_tests` en `diagnostics.zig` (solo `builtin.is_test`; el CLI no cambia); verificado que la propagación de fallo sigue viva (rc≠0 y noma el test); salida final 73/73 con **0** líneas `failed command` |
| 6.w1 | 🟡 | `parser.zig` `parseEnumDecl` | `ui/enum_comma_body`: la cascada de zig difería en línea ≥2 (sin el `aborting enum body after parse error` del seed). | ✅ fix `492f6e4` — `expectOr` + mismo `aborting` + salto a `}`: salidas **completas** byte-idénticas (2 líneas) |
| 6.w2 | 🟡 | `parser.zig` loop de campos de struct | `ui/struct_comma_body`: 4 líneas del seed no reproducidas (`expected ':', got ,` → `expected type` → `aborting struct body after parse error` + guarda de progreso). | ✅ fix `492f6e4` — secuencia espejada byte-idéntica, sin cuelgues (guarda de progreso al fondo del loop) |

### Familias exploradas y limpias (§6)

Cap de cadena del parser (idéntico en `a[0][0]…` y `1+1+…`, 256);
profundidad de llamada y stack de operandos (`countdown(300)` y
`stack_overflow_limit` byte-idénticos); impresión de valores VM (8
formas anidadas de ok/err/some/none, arrays, escapes, floats, strings
— idénticas); `--debug` arranca y sale limpio; sink único de
diagnósticos (ninguna fase escribe stderr directo); recurrencia sin
cota en typechecker/emitter (5000-arm match y 2000-campo literal
iterativos); formularios EXPECT del runner; deriva de buckets
(KNOWN=0, los 10 full-diffs restantes son recuperación §1.5).

### Estado de los gates al cierre de §6

| Gate | Valor |
|:-----|:------|
| seed `run_tests.sh` | 🟢 190/190 |
| `--check-constructs` | 🟢 OK (47 constructs, 27 operadores) |
| `sweep_emit_c.sh` | 🟢 77/77, skip=3 (módulos), fail=0, gcc `-Wall -Wextra` sin warnings |
| `dump_parity.sh` | 🟢 105/105 |
| `zig build test` | 🟢 73/73, 0 líneas `failed command` |
| `ui_message_parity.sh` | 🟢 total=88, accept_fail=0, first_fail=0, **known=0**; msg_diff_full=13 (10 recuperación §1.5 + 3 informativos de los nuevos pins) |

---

## §7 — Suite de tests (`seed/tests/`, `run_tests.sh`, `conformance.zig`)

Catorce hallazgos del análisis previo (7.1–7.14) más dos nuevos
detectados al fixear (7.15, 7.16). Cerrados todos: 7.1–7.14 en
`6e2a4e1`, y 7.15/7.16 con sus decisiones (`d66370a` / diferido UX).

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| 7.1 | 🔴 | `parser.c` `parse_block_impl` (~:606), `parser.zig` `isTailCandidate` | La promoción del último statement a expresión de cola excluía FN/STRUCT/ENUM/CONST/VAR/RETURN/BREAK/CONTINUE pero **no WHILE/FOR** (y el guard de peek era un `if` vacío): con las dos llaves en la misma línea, un bucle legal se volvía la cola del bloque y **ambos** emitters reventaban con `internal: stack imbalance in expression Block: expected height 1, emitter computed 0`. Toda la suite estaba formateada con `}` en su propia línea, así que el gate era ciego por construcción. | ✅ fix `6e2a4e1` — WHILE/FOR excluidos en ambos parsers + guard muerto eliminado; tests `loops/while_brace_same_line` y `for_brace_same_line`; caída: el mensaje de void-in-let mentía ("…ends in `;`…" sin `;` ni expresión final) para **todos** los void initializers → texto nuevo idéntico en ambos typecheckers + `ui/void_initializer_loop` |
| 7.2 | 🟠 | `typechecker.c` `cannot assign to immutable variable` | La regla central de mutabilidad no estaba en ningún fichero de la suite: `let x = 1; x = 2` rechazaba y ningún test lo sabía (solo existía el camino por índice). | ✅ fix `6e2a4e1` — `ui/assign_immutable` + `ui/reassign_function` |
| 7.3 | 🟠 | `typechecker.c` (familia de guards) | **Cero** asserts sobre la familia de guards: condición if/while no-bool, iterador de for no-array, guard de match no-bool, tipos de brazos/if divergentes, return type, call/index no-fn/no-array, índice no-entero, rango fuera de for, operadores unarios/bitwise/lógicos — doce rechazos alcanzables sin test. | ✅ fix `6e2a4e1` — 11 ficheros `ui/` nuevos con la primera línea sondeada en ambos compilan |
| 7.4 | 🟠 | `expressions/match_scalar.astra` (nuevo) | El match sobre targets escalares solo tenía un caso negativo: ni el funcional positivo (con `_`) ni el hueco §3.8 tenían repro en la suite. | ✅ fix `6e2a4e1` — test positivo int/string/bool con `_`; el hueco §3.8 se cerró después en `3c2b81a` (con su repro `ui/scalar_match_missing_wildcard` y el caso bool total dentro de este mismo test) |
| 7.5 | 🟡 | escapes de string | `\n \t \" \\` solo se afirmaban por la ruta del C (`codegen/string_escape`); la VM, el sweep y zig nunca los imprimían. | ✅ fix `6e2a4e1` — `types/string_escapes.astra` (copia verificada, VM = C = zig) |
| 7.6 | 🟡 | mensajes runtime/lexer sin test | `modulo by zero`, `shift amount out of range`, `invalid escape sequence` — alcanzables, sin ningún assert. | ✅ fix `6e2a4e1` — `expressions/modulo_zero`, `expressions/shift_range`, `ui/invalid_escape` |
| 7.7 | 🟡 | `;` tras bloque con `}` | `while {…};` es error de parseo en ambos sin que ningún test lo sepa; decisión pendiente (¿sentencia vacía aceptada?). | ✅ comportamiento actual fijado en `ui/trailing_semi_after_loop` (decisión queda para §9) |
| 7.8 | 🟡 | `run_tests.sh` | Ningún `EXPECT-ERROR` de la suite afirmaba la **posición** (`file:line:col`): el substr match vivía en cualquier parte de la salida, y la paridad solo prueba que seed y zig fallen igual — no que el sitio sea correcto. | ✅ fix `6e2a4e1` — directiva aditiva `EXPECT-ERROR-FIRST` (substring en la primera línea) + pins de posición en 6 ui + guarda que falla con >1 directiva por fichero (`head -1` las ignoraba en silencio) |
| 7.9 | 🟡 | 11 `EXPECT-ERROR` débiles | Substrings de 7 caracteres (`expects`, `does not match`, `type mismatch`) que casarían con cualquier otro diagnóstico. | ✅ fix `6e2a4e1` — reemplazados por el texto completo de la primera línea (sondado) |
| 7.10 | 🟡 | `run_tests.sh` `cg_compile` | Los 22 fixtures codegen se compilaban con `gcc -w … 2>/dev/null`: ningún warning del C generado podía fallar ni siquiera mostrarse, contra la disciplina `-Wall -Wextra` del AGENTS y del sweep. | ✅ fix `6e2a4e1` — política espejada al sweep: `-Wall -Wextra`, stderr surfaced, fallo si gcc avisa (verificado con un warning inyectado) |
| 7.11 | 🟡 | 4 aserciones más débiles que su comentario | `many_instances` imprimía `done` incondicionalmente; `integer_types` no llamaba sus funciones; `fuzz_field_access_null_type` llevaba 4 `EXPECT:` muertos; `closures` no distinguía captura por valor de referencia. | ✅ fix `6e2a4e1` — valores reales por instancia (7..13), u32/u64 llamados (43/7/9), muertos retirados, y el caso `n=5 → captura → n=10 → f(1)=6` |
| 7.12 | 🔵 | `run_tests.sh` / ficheros raíz | Los 5 `tests/{hello,simple,…}.astra` no los ejecuta nada; `--dump-bytecode`/`--dump-operators` sin gate. | ✅ parcial `6e2a4e1` — EXPECT honestos en los 3 que compilan (anotados como seeds de fuzz); `--dump-bytecode`/`--dump-operators` quedan como 🔵 sin gate (bajo valor: el primero ya tiene paridad por conformance, el segundo es la tabla del registry que `--check-constructs` vigila) |
| 7.13 | 🔵 | constructos sin pin de rechazo | `comptime`, `type_alias`, tuple, shorthand de struct, rango fuera de for, `+=`, `as` — declarados rechazados en sus `.note` pero nada lo fijaba (§0.3). | ✅ fix `6e2a4e1` — 7 ficheros `ui/*_rejected` con primera línea idéntica en ambos |
| 7.14 | 🔵 | `constructs/{impl,trait,generic_params}.c` | `.in_astra0 = false` con nota "Excluded from Astra-0" mientras `conformance/traits/*` y `generics/*` (9 ficheros) lo prueban implementado. | ✅ fix `6e2a4e1` — flags a `true` + notas y cabeceras corregidas; `--check-constructs` verde (el único check sobre el flag solo relaja) |
| 7.15 | 🟠 | `parser.zig` expression vs `parser.c` | **Nuevo, al fixear 7.13:** zig aceptaba `while`/`for` en posición de expresión (el seed los rechaza en el parser) y el emitter zig moría con `internal: stack imbalance in expression call_expr` en `print(while …)` — un error interno en vez de un rechazo limpio; `let x = while …` pasaba al typechecker zig. | ✅ fix `d66370a` (decisión en `research/021`) — los bucles son sentencias en Astra-0: parsePrefix de zig deja de tener los casos; tests `ui/while_as_expression` y `ui/for_as_expression` con primera línea idéntica; `research/001` §3.2 y su gramática enmendados |
| 7.16 | 🔵 | `tests/hello.astra`, `tests/simple_test.astra` | No compilan en ningún compilador: usan `result` como nombre de variable y `result` es keyword desde Option/Result. Hoy son seeds de fuzz que solo aportan inputs de parse-error. | ⚠️ diferido a §9 — decidir: renombrar y plegar a conformance, o dropearlos |

### Estado de los gates al cierre de §7

| Gate | Valor |
|:-----|:------|
| seed `run_tests.sh` | 🟢 219/219 (83 no-UI + 111 ui + 22 codegen) |
| `--check-constructs` | 🟢 OK (47 constructs / 14 sub / 27 operadores) |
| `sweep_emit_c.sh` | 🟢 83/83, skip=3, fail=0, gcc `-Wall -Wextra` limpio |
| `dump_parity.sh` | 🟢 111/111 |
| `zig build test` | 🟢 73/73 |
| `ui_message_parity.sh` | 🟢 total=111, accept_fail=0, first_fail=0, **known=0**; msg_diff_full=20 (cascadas §1.5, informativo) |

---

## §8 — Docs ↔ código

Treinta y un hallazgos (8.1–8.31) sobre `ARCHITECTURE.md`, `AGENTS.md`,
los dos `PHASE*_PROGRESS`, `PHASE2_GAP_ANALYSIS`, `CHANGELOG.md`,
`README.md`, `CONSTRUCT_REGISTRY.md`, `COMPILER_STRATEGY.md`,
`COMPILER_TOOLCHAIN.md` y `research/001`. Cerrados en `bf37069`
(contenido, sin conteos) y `dd54c86` (conteos y tablas).

| # | Sev | Archivo | Qué pasa | Estado |
|:-:|:---:|:---------|:---------|:-------|
| 8.1–8.6 | 🟠 | `ARCHITECTURE.md` | Seis promesas incumplidas: §30.2 presenta `var` como sintaxis mutable (rechazada por ambos); §30.1 dice que redeclarar en mismo scope es error (ambos la aceptan); §34.3 gramática de params con `mut` (ningún parser); §11.2/@-bindings y rangos + `@non_exhaustive` (no implementados); §34.2/research `+=` (no se lexea); §29.6 `must_use`/`_ = expr`/ejemplo Ok-Err sin `none` (no existen / ya no). | ✅ fix `bf37069` — escrito a lo que existe hoy, con las decisiones 3.9/3.12/3.14/§3.8 apuntando a `PRE_LLVM_AUDIT` |
| 8.7–8.9 | 🟡/✅ | `AGENTS.md` | 19→22 casos codegen, 46→47 constructs; invariantes y comandos **verificados** (todos ejecutados, todos funcionan; invariante 9 del codegen real y testeado). La tabla "What remains" tenía una sola fila Done. | ✅ fixes `bf37069` + `dd54c86` |
| 8.10–8.11 | 🟡 | `PHASE1_PROGRESS.md` | 94→219 casos; "42 no-UI del runner" → sweep con 83; genéricos/traits marcados `[ ] Fase 2` con Fase 2.3/2.4 entregada; fila C Codegen 🟡 con todo funcionando. | ✅ fix `dd54c86` |
| 8.12–8.14 | 🟡 | `PHASE2_PROGRESS.md` | Conteos de §1 (67/65/152/92/78) con tres tests más; dos filas "faltan raíces `@/`/`std/`" que contradicen §7.3 del mismo fichero (`@/` resuelto vía `astra.toml`, App. B #10 cerrado); 46→47 constructs. | ✅ fix `dd54c86` |
| 8.15–8.18 | 🟠/🟡 | `PHASE2_GAP_ANALYSIS.md` | Baseline 44→47/89→219; 32→36 keywords; builtins `len/push/pop` inexistentes; `and/or/not` y spread no usados; "not implemented in Phase 1" con Traits/Generics/Methods ya entregados; tabla de excluidos desactualizada. | ✅ fix `dd54c86` |
| 8.19–8.22 | 🟠/🟡 | `COMPILER_STRATEGY.md` | El ejemplo Astra-0 **no compilaba** (comas en structs/enums, `Result<T,E>`/`Ok`/`Err` Tier 2); tabla 4.3 con "not needed" de una era ya superada; comandos muertos `--test` y `bootstrap/compiler.zig`; §5.4 en presente sobre lenguaje completo. | ✅ fix `bf37069` |
| 8.23–8.24 | 🟡/🔵 | `CHANGELOG.md` | Dos entradas contradichas por la misma sección (`@/`/`std/` y `use` re-exports); conteos 41→40 secciones y 06→07 scripts. | ✅ fix `bf37069` |
| 8.25–8.27 | 🟠/🟡 | `README.md` | "Pre-implementation, no working compiler" con dos compiladores funcionando; Phase 1 sin marcar; árbol sin `seed/`/`zig/`; conteos 41→40 y 19→20. | ✅ fix `bf37069` |
| 8.28–8.29 | 🟡 | `CONSTRUCT_REGISTRY.md` | 46→47 y sub 13→14 en seis sitios; §9 presentaba como pendientes los ítems 1-4 (bindings, payload, guards, `?`) que están implementados. | ✅ fix `dd54c86` |
| 8.30 | 🟡 | `research/001` | Tres líneas de spec no implementadas: `("val"/"mut")` como introductor, literal `null`, operadores `++/--` y asignadores compuestos. | ✅ fix `bf37069` |
| 8.31 | 🔵 | `COMPILER_TOOLCHAIN.md` | La muestra etiquetada `# ci.yml` no es el CI real (3 jobs Linux); el Summary recomienda CMake/Unity/AFL++ no adoptados. | ✅ fix `dd54c86` — etiquetas de ejemplo + nota de adopción real (Makefile + build.zig + libFuzzer) |

Comandos ejecutados por el agente §8: los diez gates/verificaciones
de `AGENTS.md` (todos en verde; `make fuzz` no ejecutado — escribe
artefactos, pero los targets existen y CI los corre).

---

## §9 — Síntesis: cerrado, diferido y criterios de entrada a la Fase 2.6

**31 commits** (`c1ee107`…`d66370a` + el cierre documental, todos con
CI verde) entre el plan y este cierre. Nueve partes, **122 hallazgos**
analizados (7 + 16 +
17 + 8 + 8 + 8 + 16 + 31 + los accesorios), de los cuales se fixearon
en código/docs **todo lo que era bug o fraude documental** y el resto
quedó diferido con repro más abajo.

### Criterios de salida (§0) — estado final

| # | Criterio | Estado |
|:-:|:---------|:-------|
| 1 | Cero hallazgos 🔴 abiertos; 🟠 cerrados o diferidos con repro | ✅ Los 9 🔴 (arena OOB, NUL, INT64_MIN/−1, overflow UB, cadenas planas, unwrap UAF, receiver-nil, stack-imbalance de bucles) están cerrados con test. 3.8 y 7.15 se resolvieron el 2026-10-15 (`3c2b81a`, `d66370a`, decisión en `research/021`). El único 🟠 post-cierre, **4.7** (match inline corrompe el frame en los VMs), se cerró el 2026-10-15 (`ed1792e`); al cerrarlo apareció **4.8** (binding con guardia no emite los brazos posteriores), **diferido con repro**, y de la verificación posterior de la lista de fixes salió **4.9** (cola multilinea → nil silencioso), cerrada el mismo día (`87aaaf1`), más el amend de §1.2 (`f3751d9`) — ver filas §4 y dossier 022 §11. Al implementar
después el hueco de `continue` del dossier §11 apareció **4.10** (alturas de
iteración de bucle: back-edge sin reconciliar + `continue` sin stub), **más ancho
que el hueco documentado** — el repro mínimo no llevaba `continue` — y cerrada el
mismo día (`4cc9ca2`). Al cerrar §4.8 el 2026-10-16 (`a29f1af`, catch-alls con
guardia refutables + backstop solo sin guardia) apareció **4.11** — el stub POP
que §4.8 reutilizó era código muerto en variantes/builtins con payload (el
re-parcheo saltaba el POP) y su count era `bind_count` a ciegas — y se cerró en
el mismo commit. **Sin 🔴 ni 🟠 abiertos.** |
| 2 | Los tres barridos de §1 como gate en CI | ✅ `sweep_emit_c.sh` (job seed), `ui_message_parity.sh` (job parity, `STRICT=1`), replay de fuzz `-runs=0` (job seed) — todos en `.github/workflows/ci.yml` y verdes en los 29 commits. |
| 3 | Cada feature con `EXPECT`/`EXPECT-ERROR`; sin `checked > N` sueltos | ✅ §7 añadió los pines que faltaban (guards, inmutable, escapes, runtime errors, constructos rechazados) y §6.2 sustituyó `checked > 40/15` por invariantes seen-vs-procesados en `conformance.zig`. Residuales documentados: `--dump-bytecode`/`--dump-operators` sin gate propio (🔴-bajo valor, el segundo lo vigila `--check-constructs`). |
| 4 | §4 (emitter/VM) cerrado: semántica verificada y fijada con tests | ✅ Invariantes 1-5 de `AGENTS.md` verificados con probes; 6 hallazgos cerrados; tests `integer_wrap`, `int_min_div_neg1`, `match_binding_reclaim`, `toplevel_return`, `expr_chain_deep`, `enum_payload_print`. |
| 5 | Mensajes seed↔zig: byte-idénticos o divergencia aceptada y documentada | ✅ `known=0` (se eliminó el único KNOWN); `msg_diff_full=20` documentado como recuperación §1.5 (informativo; el gate compara la primera línea). |

### Lo que se fixeó (mapa por parte)

| Parte | Cerrados | Commits |
|:------|:---------|:--------|
| §1 barridos | 1.1-1.4, 1.6 (+gates) | `b3136d1`, `a72d4a7`, `6437aa0`, `123809d`, `ac987ca`, `2d2722f` |
| §2 frontend | 2.1-2.14 + return-EOF | `8832fc9`, `5435722`, `b3c798b`, `2364a2c`, `179d138`, `97f8909`, `e5376a4`, `74a90b4` |
| §3 semántica | 3.1-3.7, 3.10, 3.13(=1.6) | `ac987ca`, `213cc35`, `61b2e30`, `99759d5`, `74a90b4` |
| §4 emitter/VM | 4.1-4.11 | `e88d925`, `ed1792e`, `87aaaf1`, `4cc9ca2`, `a29f1af` |
| §5 backend C | 5.1-5.6, 5.8 | `6961005` |
| §6 zig | 6.1-6.4, 6.6, 2 wins | `492f6e4` |
| §7 suite | 7.1-7.14 | `6e2a4e1` |
| §8 docs | 8.1-8.31 | `bf37069`, `dd54c86`, `5a6b358` |
| docs por parte | tablas §0-§8 | `c1ee107`, `2d2722f`, `66fb38e`, `ecee3a7`, `f9a1f27`, `5a6b358`, este commit |

### Diferidos con razón (inventario definitivo)

**Decisiones de lenguaje — bloquean réplica en LLVM si se ignoran:**

| # | Diferido | Razón / opciones | Repro |
|:-:|:---------|:-----------------|:------|
| 3.9 | `+=` y asignadores compuestos | Dos opciones: implementar (lexer+parser; los desugars a medias existen en ambos typecheckers) o borrar de `research/001`/`ARCH §34.2`/`assign.c` y eliminar los brazos muertos. Docs ya anotados como no implementados. | `sem/compound.astra` |
| 3.11 | Parámetros `mut` | Implementar (ARCH §34.3 ya lo retiró de la gramática) o fijar que los params son inmutables. Hoy la matriz de mutabilidad restante está en paridad total. | `sem/mut_param.astra` |
| 3.12 | Redeclaración en mismo scope | Imponer la regla Rust (ARCH §30.1 original) o bendecir el shadowing actual (ya documentado en §30.1). | `sem/shadow_same.astra` |
| 3.14 | `@non_exhaustive`, bindings `@`, rangos en patrones | Agendar o excluir formalmente de Astra-0 (ARCH §11.2-11.3 ya marcados fuera). | `sem/nonexh_attr/at_bind/range_pat` |
| A1 | `let x: T` sin inicializador aceptado (da `nil` bajo la promesa) | Exigir `=` (la grammática de `research/001` ya lo dice) o añadir definite-assignment. | `sem/uninit_arg/uninit_local` |
| 7.7 | `;` tras bloque con `}` es error | Aceptar sentencia vacía o mantener el rechazo (hoy fijado por `ui/trailing_semi_after_loop`). | el propio test |

**Divergencias de texto/UX aceptadas (sin semántica en juego):**

| # | Diferido | Razón |
|:-:|:---------|:------|
| 1.5 | Cascadas de recuperación en línea ≥2 (bucket `msg_diff_full=20`) | Diferencia de *recuperación*, no de diagnóstico: el gate compara la primera línea. Unificar exigiría hacer los `expect` de zig no-fatales en masa (§6.1 lo dejó anotado). |
| 1.7 | `too_many_locals` sin línea/columna | §6.3 cerró la paridad (ambos imprimen `file:`); hilar `SrcLoc` por `add_local` queda como UX, idéntico en ambos lados. |
| 5.7 | Global leído antes de definido: `cannot call non-function value` (C) vs `undefined global variable` (VM/zig) | Misma línea, mismo exit. Implica `g_defined_*` en el C backend; repro `sem5/e6_fwd.astra`. |
| 6.5 | Higiene: interleaving con `2>&1`, `unknown option` vs `unknown flag`, resúmenes seed-only | Ningún gate compara streams fusionados; los resúmenes ya están filtrados por el gate de paridad. |
| 7.16 | `tests/{hello,simple_test}.astra` no compilan (variable `result` = keyword) | Solo aportan parse-errors al corpus de fuzz; decisión: renombrar+plegar a conformance o dropear. |
| A2 | Chequeo de asignación-a-capturada en los emitters (sin columna) | Coberto por `ui/capture_assign`; subirlo al typechecker es higiene. |
| A3 | Keywords muertas `and/or/not/in/as/comptime` | Limpiar junto con §3.9; `&&`/`\|\|` son los operadores reales. |

### Veredicto

La auditoría **cierra sus criterios de salida**: cero 🔴 abiertos, gates
diferenciales en CI, cobertura mínima cumplida, §4 verificado y paridad
de mensajes `known=0`. Las dos salvedades que exigían decisión antes de
que la Fase 2.6 (backend LLVM) replique semántica — **§3.8** (match
escalar → `nil` bajo promesa) y **§7.15** (`while`/`for` como expresión)
— quedaron resueltas el 2026-10-15 con su investigación y regla
definitiva en `research/021` (`3c2b81a`, `d66370a`), y la documentación
que decía lo contrario (ARCH §11.3/§29.6, research/001 §3.2) fue
corregida. **La Fase 2.6 puede empezar** sobre esta base. El último
🟠 post-cierre, **§4.7** (match inline como argumento corrompe el frame
en los dos VMs), se cerró el 2026-10-15 con `ed1792e` — dirección (i)
del dossier 022 con altura runtime exacta, pad hasta la frontera y
cierre por camino, espejo en zig y backend C unificado (resolución
completa en dossier §11); al cerrarlo apareció **§4.8** (binding con
guardia no emite los brazos posteriores), que se cerró el 2026-10-16
(`a29f1af`, catch-alls con guardia refutables) junto con **§4.11**,
el bug que su fix destapó en el stub de payloads de §4.7. El
resto de diferidos (3.9, 3.11, 3.12, 3.14, A1–A3, 5.7, 6.5, 7.7, 7.16)
son decisiones de lenguaje documentadas o deuda de UX, no bloqueos.

### Resueltos tras el cierre (2026-10-15)

Los dos 🟠 que el cierre original dejó pendientes se investigaron
(con filosofía del proyecto + práctica de la industria en
`research/021`) y se resolvieron con decisión documentada:

| # | Decisión | Implementación |
|:-:|:---------|:---------------|
| 3.8 | **Todo `match` debe ser total**: espacio finito probado (enum/optional/bool), catch-all `_` obligatorio para el resto; backstop `no match arm matched` en runtime para el aliasing Tier-2 | `3c2b81a` + `research/021` + ARCH §11.3/§29.6 actualizados |
| 7.15 | **Los bucles son sentencias** en Astra-0 (no producen valor); enmienda a `research/001` §3.2/gramática; el valor de bucle futuro, si quiere, será `loop { break expr }` | `d66370a` + tests `ui/while_as_expression`, `ui/for_as_expression` |

### Gates finales (2026-10-15, tras 3.8 y 7.15)

| Gate | Valor |
|:-----|:------|
| seed `run_tests.sh` | 🟢 224/224 (conformance no-UI + ui + codegen) |
| `--check-constructs` | 🟢 OK (47 constructs, 14 sub-constructs, 27 operadores) |
| `sweep_emit_c.sh` | 🟢 84/84, skip=3, gcc `-Wall -Wextra` limpio |
| `dump_parity.sh` | 🟢 112/112 |
| `zig build test` | 🟢 73/73 (sin ruido `failed command`) |
| `ui_message_parity.sh` | 🟢 total=115, accept_fail=0, first_fail=0, known=0, msg_diff_full=22 (informativo) |
| CI (31 commits + docs) | 🟢 todos los runs `success` |

### Cierre de §4.7 (2026-10-15, `ed1792e`)

Fix del `match`/`if` inline en los dos emitters + backend C (dirección (i)
del dossier 022; qué funcionó, adyacentes resueltos y el hueco de
`continue` documentado en dossier §11). Gates tras el cierre:

| Gate | Valor |
|:-----|:------|
| seed `run_tests.sh` | 🟢 229/229 (224 previos + 5 tests nuevos) |
| `sweep_emit_c.sh` | 🟢 88/88, skip=3 |
| `--check-constructs` | 🟢 OK |
| `zig build test` | 🟢 73/73 |
| `dump_parity.sh` | 🟢 117/117, 0 divergent |
| `ui_message_parity.sh` | 🟢 total=115, first_fail=0, known=0 |
| Cross-VM probes | 🟢 40/40 byte-idénticos seed↔zig; backend C = VM en los 26 probados |

### Verificación de la lista de fixes + §4.9/§1.2 (2026-10-15)

Muestreo de ~20 reclamaciones `✅ fix` con repros propios (todas ciertas; los 44 tests
citados en filas ✅ existen) → dos hallazgos: **§4.9** (cola multilinea, cerrada en
`87aaaf1`) y el amend de **§1.2** (`f3751d9`). Gates tras ambos: seed 231/231,
sweep 89/89 skip=3, `--check-constructs` OK, `zig build test` 73/73,
`dump_parity` 118/118, `ui_message_parity` total=116 first_fail=0 known=0,
cross-VM 51 probes sin divergencias reales (las2 del resumen seed-only, §6.5).

### Hueco de `continue` → §4.10, alturas de iteración (2026-10-16, `4cc9ca2`)

El "hueco conocido" del dossier 022 §11 (la altura de iteración vía `continue`
que salta declaraciones queda fuera del modelo) se implementó con la metodología
§4.7: repros primero. La batería diferencial `continue`-vs-guarda (`if COND {
continue }` ≡ `if !(COND) { … }`, mismos ítems renderizados de la misma lista) lo
rompió en 2 de 150 pares — y la reducción mostró que **el repro mínimo no llevaba
`continue`**: `for i in 0..3 { let e = B(s); print(match e { E.B(n) => n }); let z
= 0 }` ya trapeaba `cannot call non-function value` en la iteración 2 (el close
del match escribía el resultado encima de la celda del receptor `print`; `CALL`
leía `sp-1-argc` y encontraba una celda stale). O sea: (a) el back-edge no
reconciliaba la altura del cuerpo, y (b) `continue` saltaba al objetivo sin el
stub que el dossier prescribía. Fix: `emit_back_edge_reconcile` (POP hasta
`head_rt`) + stubs por `continue` hasta `continue_rt` (POP / `CONST nil`), en
ambos compilers. Gates: seed 233/233, sweep 90/90 skip=3, `--check-constructs`
OK, `zig build test` 73/73, `dump_parity` 120/120, `ui_message_parity`
total=116 first_fail=0; la batería diferencial pasó a 750 pares (5 semillas) con
0 divergencias. Nota de proceso: la primera tanda del fuzzer daba 49
"divergencias" — eran bug del generador (listas desincronizadas → brazos if
vacíos no-equivalentes) y 72/150 pares ni compilaban (ids indefinidos) dando
"falso pase": sin el paso de verificar que los pares realmente compilan, la
evidencia no vale.

### §4.8 + §4.11 — catch-alls con guardia y el stub de payloads (2026-10-16, `a29f1af`)

Al atacar la fila §4.8 (el `break` tras un brazo binding con guardia) el probe
ampliado mostró que **el wildcard con guardia tenía el mismo corte**:
`match x { _ if x > 9 => 1, n => n + 100 }` con x=5 devolvía `nil` silencioso —
`has_wildcard` se fijaba antes de mirar la guardia, así que el guardado
suprimía el backstop MATCH_NONE y los brazos posteriores ni se emiten. Fix en
ambos compilers: un catch-all **con** guardia es refutable — la guardia fallida
cae al brazo siguiente a la altura de entrada del brazo (POP de reconciliación
cuando el binding dejó celda viva; sin stub para el wildcard, que no extrae) y
solo el catch-all **sin** guardia corta el bucle y suprime el backstop. El
typechecker ya trataba los guards como no totales (exige `_`), así que el
runtime ahora coincide con él.

Reutilizar el stub de §4.7 como patrón (era el fix prescrito por el dossier
022 §11) destapó **§4.11**, un bug preexistente en la misma maquinaria: el
re-parcheo *"Re-target the guard-false stub"* volvía a apuntar `arm_gf_patch`
— el JIF de la guardia — al final de la iteración, **saltándose el POP**, de
modo que el stub era código muerto y las celdas de los bindings extraídos
quedaban vivas bajo el brazo siguiente (`match v { E.B(n) if n > 1 => n, _ => 0 }`
con v=B(1) → trap `cannot call non-function value` en los tres backends, desde
antes de §4.7: los tests de esa fila solo cubrían variantes unitarias, sin
stub). Y al arreglar el enlace apareció el segundo defecto: el count del POP
era `bind_count` a ciegas, pero cuando un brazo previo dejó `local_count` más
allá del frontier cada binding cae una celda más arriba y `SET_LOCAL` paddea
una celda stale bajo él — el drop exacto es `bind_rt − rt_test` (1 + pad, o
`bind_count` + pads), emitido como POP con operand-count en las tres rutas
(variante, builtin, bind plain). El probe que lo delató cruzó patrones:
variante con guardia → bind con guardia → variante → wildcard, dentro de un
loop (`s48_mix`), la misma familia de desalineación que §4.10 pero por slots
de la tabla de locales en vez de back-edges.

Gates tras el fix: seed 237/237 (ASan), sweep 92/92 skip=3, `--check-constructs`
OK, `zig build test` 73/73, `dump_parity` 124/124, `ui_message_parity`
total=116 first_fail=0. Tests nuevos: `enums/match_guard_fallthrough.astra`
(catch-alls con guardia: bind, wildcard, cadena de guards, guard verdadera) y
`enums/match_guard_payload_stub.astra` (§4.11: payload simple y doble, builtin
Option, cadena con slots stale, cadena de guardias de variante), cada uno con
su gemelo `tests/codegen/` — los 21 shapes de repro (VM, C y zig) quedan
pinned entre ambos.
