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
| 1.6 | 🟡 | `typechecker.c` (seed) vs zig, `fuzz_field_access_null_type.astra:32,46` | Mismo rechazo, texto distinto: seed `symbol 'self' has no type` vs zig `cannot access field on non-struct type unknown`. La primera línea del archivo casa; difieren las líneas 5 y 7 del volcado. | 📋 abierto — §3 decide cuál es canónico y lo unifica |
| 1.7 | 🔵 | `emitter.c:254` (`add_local`) | `too many locals (max 256)` sin posición en el seed (el Emitter no tiene filename en el punto de choke) y con `file:` pero **sin línea** en zig: única primera línea divergente, aceptada como `KNOWN_FIRST_LINE` del gate. | ⚠️ diferido: exige hilar un `SrcLoc` por `add_local` (~8 call sites); el comportamiento es correcto en ambos, solo degrada la posición |

### Gates (criterio de salida 2 de §0 — ✅ cumplido)

| Gate | Dónde | Estado actual |
|:-----|:------|:--------------|
| `sweep_emit_c.sh` | step del job `seed` en CI + ejecución local | 🟢 68/68, 0 divergencias (1 fallo antes del fix 1.1) |
| `ui_message_parity.sh` | step del job `parity` en CI, `STRICT=1` por defecto | 🟢 total=65, accept_fail=0, first_fail=0, known=1 |
| replay de fuzz `-runs=0` | step del job `seed` en CI | 🟢 corpus íntegro, sin hits de sanitizer |

*(Las secciones siguientes se van añadiendo conforme avanza la
auditoría; cada una cierra con su commit.)*
