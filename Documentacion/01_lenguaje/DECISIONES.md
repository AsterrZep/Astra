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
| DEC-008 | Las variantes de enums viven en el namespace de su enum; la construcción **calificada es obligatoria** (`A.Some2(1)`) | Aceptada (ratificación 2026-10-27, D4) — test en PR de fase B | 2026-10-27 | `research/027` §4; `research/031` §0 (APPROVED) |
| DEC-009 | Los VMs (seed/zig) y el backend C no liberan memoria (arena/vitalicio); la ruta LLVM libera con ARC — divergencia **documentada y gateada** con techo de RSS | Aceptada (ratificación 2026-10-27, D3) — gate en PR de fase C | 2026-10-27 | `research/027` §3; `research/030` §3.2 (1,2 MB vs 400–712 MB) |
| DEC-010 | Los floats se imprimen con formato `%g` | Aceptada (test-pinned) | 2026-09 | conformance de expresiones |
| DEC-011 | Las sentencias se terminan con `;` o con newline | Aceptada (test-pinned) | 2026-09 | suite de conformidad (estilo mixto) |
| DEC-012 | Modelo de enforcement entre fibras = **Opción F** (`research/026`: regla de cruce con unicidad comprobada; `transfer(x)` será builtin, sin keyword; el walk de rc se difiere al primer cruce real — scheduler/send) | **Propuesta** (D7 pospuesto el 2026-10-27; solo Fase 0 documental) | 2026-10-27 | `research/026` §3–§4; `research/031` §0 (NEEDS WORK, bloqueos resueltos por posición) |

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
- **Estado**: Aceptada (ratificación 2026-10-27, D4) — el test llega en el PR de fase B
- **Fecha**: 2026-10-27
- **Decisión**: `Some2(1)` sin calificar deja de compilar si es ambiguo;
  solo `A.Some2(1)`. Las variantes unitarias calificadas ya funcionan; los
  patrones ya exigen calificación.
- **Alternativas consideradas**: «pelón si es inequívoco» (cuesta 0 tests
  pero deja dos ortografías para siempre y empeora con módulos).
- **Coste aceptado**: 2 typecheckers + 3 emisores; 12 conformance + 5
  codegen + 5 fixtures LLVM + 2 unit zig + `llvm_fuzz_gen.py` (lista exacta
  en `research/027` §4).
- **Evidencia actual**: hoy ambas construcciones sin calificar resuelven al
  primer enum y `match` contra el segundo falla (`research/025` §2.8).
- **Spec**: `research/027` §4.

### DEC-012 — Enforcement entre fibras: Opción F (pospuesto)
- **Estado**: Propuesta — D7 pospuesto el 2026-10-27; mientras sea `Propuesta`,
  la regla 5 de AGENTS bloquea backend work que tenga que codificarla.
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
