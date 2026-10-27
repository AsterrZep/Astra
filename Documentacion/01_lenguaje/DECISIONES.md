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
| DEC-012 | Modelo de enforcement entre fibras = **Opción F** (`research/026`: regla de cruce con unicidad comprobada; `transfer(x)` será builtin, sin keyword; el walk de rc se difiere al primer cruce real — scheduler/send) | **Propuesta** (D7 pospuesto; Fase 0 completada: `ARCHITECTURE.md` §2.6 escrita) | 2026-10-27 | `research/026` §3–§4; `ARCHITECTURE.md` §2.6; `research/031` §0 |
| DEC-013 | Stdlib M1: `len(x) -> i64` para arrays y strings; `s[i]` → **string de 1 byte** (OOB = error de runtime con el texto de los arrays); los strings son inmutables (`s[i] = …` es error de compilación) | Aceptada (test-pinned) | 2026-10-27 | `arrays/len_array.astra`, `expressions/len_string.astra`, `expressions/str_index.astra`, `expressions/str_index_oob.astra`, `expressions/len_int_runtime_error.astra`, `ui/str_index_assign_rejected.astra`, `codegen/str_index.astra`, `codegen/len_builtin.astra` (PR D-PR1) |

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

### DEC-012 — Enforcement entre fibras: Opción F (pospuesto)
- **Estado**: Propuesta — D7 pospuesto el 2026-10-27; Fase 0 completada
  (la regla vive en `ARCHITECTURE.md` §2.6); mientras sea `Propuesta`, la
  regla 5 de AGENTS bloquea backend work que tenga que codificarla.
- **Fecha**: 2026-10-27
- **Decisión (dirección)**: compartir intra-fibra es gratis (DEC-001);
  **cruzar frontera de fibra exige valor único en ese punto** — estático si
  se prueba, walk de `rc` en runtime si no; si no es único → `.copy()` o
  `AtomicRef[T]`. `transfer(x)` será un **builtin** (estilo `print`), no
  keyword. El walk RT1 se difiere al primer feature con cruce real
  (scheduler/send) — sin rc en los VMs antes de tiempo.
- **Alternativas consideradas**: A tracing GC (contradice «sin pausas»);
  B RC atómico aceptando carreras (contradice «thread-safe»); D owner-check
  por acceso (queda como red de v2, no como base); E sin mutable compartido
  (pierde el pitch).
- **Coste aceptado**: Fase 0 = docs (ARCHITECTURE §2.6 «pendiente»);
  implementación futura = S1/S2/S3 en 2 frontends + `.copy()` en 4 runtimes.
- **Evidencia**: `research/026` §3–§4 (spec operativa R1–R7); `research/031`
  §0 (NEEDS WORK: estimación de esfuerzo pendiente antes del PR grande).
- **Spec**: «pendiente de escribir en ARCHITECTURE §2.6».

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
