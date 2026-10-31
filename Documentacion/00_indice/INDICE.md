# Astra — Índice maestro de la documentación

> **Última revisión:** 2026-10-29 · **Rama:** reorganización en carpetas
> numeradas · **Estado del proyecto:** Fase 1 ✅ · Fase 2 (frontend + módulos) ✅ ·
> Fase LLVM (M0–M6.c) ✅

Este es el punto de entrada a toda la documentación. La estructura está
dividida en **carpetas numeradas** que siguen el orden en que se aborda el
proyecto: primero el lenguaje, luego el compilador, después cada fase de
implementación, al final las auditorías y el material de investigación.

---

## Estructura

| Carpeta | Contenido | Documentos |
|:--------|:----------|:-----------|
| [`00_indice/`](../00_indice/) | Este índice | 1 |
| [`01_lenguaje/`](../01_lenguaje/) | Qué es Astra: especificación, filosofía, comparativas, registro de constructos y decisiones | 5 |
| [`02_compilador/`](../02_compilador/) | Cómo se construye el compilador: estrategia, herramientas y trabajo por agentes | 3 |
| [`03_fase1_seed/`](../03_fase1_seed/) | Estado del compilador semilla en C | 1 |
| [`04_fase2_zig/`](../04_fase2_zig/) | Fase 2: compilador auto-hospedado en Zig | 6 |
| [`05_fase_llvm/`](../05_fase_llvm/) | Fase LLVM: backend nativo | 2 |
| [`06_auditorias/`](../06_auditorias/) | Auditorías ejecutadas contra el código y deuda pendiente | 3 |
| [`07_investigacion/`](../07_investigacion/) | Informes de investigación (001–040) | 40 |
| [`08_originales/`](../08_originales/) | PDFs originales de diseño | 2 |
| [`09_libro/`](../09_libro/) | Guía de usuario estilo libro (16 capítulos + 91 ejemplos ejecutados) | 17 |

---

## 1. `01_lenguaje/` — Lenguaje

| Documento | Qué contiene | Idioma |
|:----------|:-------------|:-------|
| [`ARCHITECTURE.md`](../01_lenguaje/ARCHITECTURE.md) | **Especificación completa** del lenguaje (40 secciones): tipos, memoria, concurrencia, gramática. El documento fuente. | ES |
| [`PHILOSOPHY.md`](../01_lenguaje/PHILOSOPHY.md) | Los principios de diseño y el axioma central que gobierna las decisiones. | ES |
| [`COMPARATIVE_ANALYSIS.md`](../01_lenguaje/COMPARATIVE_ANALYSIS.md) | Astra frente a Mojo, Nim, Zig, Julia, Vale y Swift. | EN |
| [`CONSTRUCT_REGISTRY.md`](../01_lenguaje/CONSTRUCT_REGISTRY.md) | Un fichero por producción EBNF: por qué existe el registro y sus invariantes. | ES |
| [`DECISIONES.md`](../01_lenguaje/DECISIONES.md) | Registro de decisiones de lenguaje (ADR-lite): qué se decidió, cuándo, por qué y qué test lo fija. Creado 2026-10-27. | ES |

## 2. `02_compilador/` — Compilador

| Documento | Qué contiene | Idioma |
|:----------|:-------------|:-------|
| [`COMPILER_STRATEGY.md`](../02_compilador/COMPILER_STRATEGY.md) | **Plan de bootstrap C → Zig → Astra**: por qué tres fases y no una. | EN |
| [`COMPILER_TOOLCHAIN.md`](../02_compilador/COMPILER_TOOLCHAIN.md) | Herramientas, librerías y flujos de trabajo (C, Zig, LLVM, CI). | EN |
| [`MULTI_AGENT_SETUP.md`](../02_compilador/MULTI_AGENT_SETUP.md) | Hallazgos verificados sobre cómo repartir trabajo entre agentes. | ES |

## 3. `03_fase1_seed/` — Fase 1: compilador semilla

| Documento | Qué contiene | Idioma |
|:----------|:-------------|:-------|
| [`PHASE1_PROGRESS.md`](../03_fase1_seed/PHASE1_PROGRESS.md) | **Estado del compilador en C** (`seed/`): pipeline, lenguaje soportado, cobertura, límites conocidos y hallazgos de la Fase 1. | ES |

## 4. `04_fase2_zig/` — Fase 2: compilador en Zig

| Documento | Qué contiene | Idioma |
|:----------|:-------------|:-------|
| [`PHASE2_PROGRESS.md`](../04_fase2_zig/PHASE2_PROGRESS.md) | **Estado vivo de la Fase 2** — el documento que hay que leer para saber qué hay hecho hoy (frontend, módulos, traits, genéricos, `?`). | ES |
| [`PHASE2_KICKOFF.md`](../04_fase2_zig/PHASE2_KICKOFF.md) | Arranque de la fase: alcance y regla de paridad con el seed. | EN |
| [`PHASE2_ARCHITECTURE.md`](../04_fase2_zig/PHASE2_ARCHITECTURE.md) | Arquitectura diseñada para el compilador Zig (diseño, 2026-09). | EN |
| [`PHASE2_IMPL_PLAN.md`](../04_fase2_zig/PHASE2_IMPL_PLAN.md) | Plan de implementación práctico por pasos (plan, 2026-09). | EN |
| [`PHASE2_GAP_ANALYSIS.md`](../04_fase2_zig/PHASE2_GAP_ANALYSIS.md) | Inventario de lo que falta para el lenguaje completo y orden recomendado. | EN |
| [`PHASE2_RESEARCH.md`](../04_fase2_zig/PHASE2_RESEARCH.md) | Síntesis de investigación específica de la fase (arquitectura Zig, LLVM en Zig). | EN |

## 5. `05_fase_llvm/` — Fase LLVM

| Documento | Qué contiene | Idioma |
|:----------|:-------------|:-------|
| [`LLVM_BACKEND_PLAN.md`](../05_fase_llvm/LLVM_BACKEND_PLAN.md) | **Plan accionable** del backend: decisiones, workstreams, hitos M0–M6, CI y riesgos. | ES |
| [`PHASE_LLVM_PROGRESS.md`](../05_fase_llvm/PHASE_LLVM_PROGRESS.md) | **Estado vivo de la Fase LLVM**: qué hito está cerrado, gates y trazabilidad de commits. | ES |

## 6. `06_auditorias/` — Auditorías

| Documento | Qué contiene | Idioma |
|:----------|:-------------|:-------|
| [`COHERENCE_AUDIT.md`](../06_auditorias/COHERENCE_AUDIT.md) | Auditoría de coherencia documento↔código (2026-09-16/21). Registro histórico. | ES |
| [`PRE_LLVM_AUDIT.md`](../06_auditorias/PRE_LLVM_AUDIT.md) | Auditoría previa a la Fase 2.6 sobre todo el código, con repros y tests por hallazgo (2026-10-14). Registro histórico. | ES |
| [`DEUDA_PENDIENTE_2026-10-29.md`](../06_auditorias/DEUDA_PENDIENTE_2026-10-29.md) | **Inventario de deuda**: 32 issues abiertos de `research/034`, huecos de funcionalidad (GAP/PHASE1/PHASE2/LLVM), ~24 decisiones sin abrir y 10 desincronizaciones doc↔código. Registro datado. | ES |

## 7. `07_investigacion/` — Informes de investigación

40 informes numerados `001`–`040`, sin solapamientos: cada uno es un
dossier autocontenido sobre un tema (gramática, diseño del seed, backend C,
enums y pattern matching, arquitectura de rustc/cpython/go/julia, testing,
concurrency, comptime, stdlib, paquete, ABI, Android, Apple, LLVM, crítica
externa, enforcement de seguridad, semántica de runtime, stdlib, benchmarks,
taxonomía de vulnerabilidades y auditoría, sistemas de enteros, punteros,
iteradores, strings/Unicode, concurrencia, memoria…).

- `001`–`003` son los que fijan el **comportamiento de referencia**: gramática,
  diseño del seed y patrones del backend C.
- `021`–`022` son dossiers de tareas concretas del compilador.
- `023`–`024` son la investigación que sostiene la Fase LLVM.
- `025` contrasta una crítica externa con el código: promesas de seguridad sin
  mecanismo de enforcement, decisiones de runtime abiertas y proceso.
- `026`–`030` son la respuesta a esa crítica: modelo de enforcement (026),
  decisiones de semántica de runtime (027), stdlib mínimo para self-hosting
  (028), arreglos de proceso/bootstrap (029) y benchmarks vs Rust/Go/C/Zig
  (030, con suite reproducible en `030_benchmarks_suite/`).
- `031` reality-check de 026–030 antes de ratificarlos (§3 cerró la
  secuencia A–F que se ejecutó).
- `032` alcance del **typechecker en Astra-0** (paso 5 de PHASE1 §7):
  inventario de ~55 checks, corpus medido (189/304 parsean con el parser
  self-hosted), estructuras de datos viables en la ruta LLVM y el shape
  del gate diferencial; abre DEC-032.
- `033` **taxonomía de auditoría**: 90 casos (30 críticos / 30
  intermedios / 30 básicos) por niveles CVSS, extrapolados a Astra.
- `034` **informe de auditoría**: 42 hallazgos verificados de seguridad
  y robustez del compilador.
- `035` **sistemas de enteros de ancho fijo** (`i8`…`i64`/`u8`…`u64`):
  cómo y por qué los diseña Zig 0.17, C, C++, Java, Python, Rust, Swift,
  Go, C#, JS y Kotlin; el espectro de semánticas de overflow (UB → wrap →
  trap → imposible) y el encaje con DEC-006/007 (incluye probes
  empíricos del seed: sólo `i32/i64/u32/u64` existen hoy).
- `036` **punteros: modelos y eficiencia**: las seis familias de modelo
  (dirección cruda, sin aritmética, GC, ownership, handles/offsets,
  capabilities CHERI), C/C++/Rust/Zig/Go/Swift/Java/C#/Python/JS/Ada/Erlang
  comparados, la capa hardware (PAC/MTE/MPX-fracasó), y eficiencia
  **medida** (chase 794.7 ns/nodo vs array 6.71 ns/elem ≈ 118×;
  `unique_ptr`=8 B, `shared_ptr`=16 B, `?*T`=8 B, `Option<&T>`=8 B por
  nicho) con el encaje de `Ptr<T>`/unsafe de ARCHITECTURE §8.5.
- `037` **iteradores y protocolos de iteración**: los 5 ejes de diseño
  (protocolo pull/push, lazy/eager, rangos inclusivo/exclusivo,
  invalidación, sintaxis de bucle) en Rust/Python/C++/JS/Java/C#/Swift/
  Kotlin/Go/Elixir/Ruby/Julia/Haskell/Zig; verificado Go 1.23 range-over-func
  y el Rust Book; reality-check de `research/015` §4 con 8 probes del seed
  (rango sólo-en-`for`, sin `loop`, `break`-con-valor rechazado con mensaje
  propio) y plan en 3 fases para Astra.
- `038` **strings y Unicode**: UTF-8 vs UTF-16 vs graphemas con la tabla
  de divergencias real (`👩‍👩‍👧` = 5/18/8/1), los 3 campamentos + Python,
  JEP 254/400, normalización, UTS#39/overlong/JSON UTF-8, rendimiento
  (simdutf ≥1000 M chars/s) y el retrato medido de Astra (`len`=bytes,
  `ord("á")`=195, escapes sin `\uXXXX`, `==` por interning) con
  recomendación de capas Unicode por fases sin romper DEC-013.
- `039` **concurrencia: fibers, async/await, goroutines y actors**: los
  6 modelos estelares con costes medidos (mutex 21 ns sin contención /
  ~125 ns con 2 hilos, TSan 5-15×), Loom (JEP 444/491/505), BEAM por
  reductions, Go CSP+DRF-SC, Zig tras borrar async (std.Io), concurrencia
  estructurada (nursery/scope), y el encaje en DEC-012/022/023/026 con
  probes (`spawn` no existe aún; `transfer` ya invalida) — recomendación:
  spawn scoped, canales por defecto con RT1 en send/recv, cancelación por
  scope.
- `040` **memoria y ownership**: las 5 familias (tracing GC, RC+ciclo
  colector, ARC, ownership compile-time, arenas/manual) con precedentes
  verificados — ZGC JEP 439 (pausas <1 ms, Cassandra ¼ heap/4×), pacer
  de Go, CPython umbral `(2000,10,10)` medido, PHP Bacon–Rajan,
  mimalloc 0,2 % — y los gates de Astra: tabla de las 4 rutas
  (seed 404 MB / zig 721 MB / C 489 MB / LLVM 77 MB acotado) + probes
  propios (RSS lineal con arrays, plano con strings ⇒ el hueco está en
  el handler de arrays) con recomendación para Rec3: gate RSS por
  backend + ciclo-colector opcional en Fase 2, sin tracing GC.

**Convención de citación:** los documentos (y el código) citan estos informes
por su corto `` `research/001` `` + sección, p. ej. `` `research/001` §12.1 ``.
Esa abreviatura sigue siendo válida: designa al informe **001** de esta
carpeta, no una ruta literal.

## 8. `08_originales/` — Material original

Los dos PDFs de los que arrancó todo: *Arquitectura Lenguaje Astra* y
*Diseño de un Lenguaje Híbrido*.

---

## 9. `09_libro/` — Guía de usuario (libro)

*The Astra Programming Language* — libro de usuario estilo *The Rust
Programming Language*, **16 capítulos** (00 introducción → 15 glosario) +
`README.md` con la guía de estilo + **91 ficheros de ejemplo `.astra`** en
`ejemplos/`, todos ejecutados con el toolchain real y con la salida pegada
de las corridas. Escrito en 4 bloques paralelos (2026-10-28) contra el
compilador real: documenta **solo lo implementado** y remite a
`DECISIONES.md`/`ARCHITECTURE.md` para el porqué. Su escritura actuó como
auditoría de docs: 8 divergencias halladas quedaron en el backlog. El build
HTML (mdBook o equivalente) es el siguiente paso — el contenido, no.

---

## Estado del proyecto de un vistazo (2026-10-28)

| Área | Estado | Gate / cifra |
|:-----|:-------|:-------------|
| **Fase 1** — compilador semilla (`seed/`) | ✅ Completa | `make test` → **360 passed, 0 failed** (ASan/UBSan/LSan) + `sweep_emit_c` → **164 total, 3 skip, 0 fail** + selfhost `io`/`lexer`/`parser_gate` OK (diag 19/19) — con `typechecker_gate` diferencial (**260/260** ×4 rutas, DEC-042) (2026-10-30) |
| Registro de constructos | ✅ (índice documental — DEC-002) | `--check-constructs` → **47 constructos, 27 operadores**; hooks = aspiración, no plan de migración |
| **Fase 2** — compilador Zig (`zig/`) | 🟡 Frontend completo | `zig build test` → **74/74** · `dump_parity.sh` → **209 ficheros, 0 divergentes** + `ui_message_parity` first_fail=0 (146) |
| Sistema de módulos | ✅ | `pub`, globales mangladas, orden de dependencias, `use`, raíz `@/` |
| **Fase LLVM** (opt-in `-Dllvm`) | ✅ M0–M6.c | `llvm_parity.sh` → **221/221** (también `ASTRA_LLVM_OPT=2`; skips = fallo desde #21) + `llvm_mem.sh` → techo 64 MB |
| **Decisiones de lenguaje** | ✅ 33 registradas (32 aceptadas) | `DECISIONES.md` — DEC-001..033 (única en `Propuesta`: DEC-021, la CLI `astraea`); del ciclo 2026-10-28/29: DEC-012/022 ratificadas + DEC-023 (RT1@M4) + DEC-024..031 (stdlib + parser v2..v2.3) + DEC-032/033 (typechecker en Astra + pines de control-flow) |
| **Deuda abierta** | 📋 Inventariada (2026-10-29) | `06_auditorias/DEUDA_PENDIENTE_2026-10-29.md` — **32 issues** de `research/034` (#49–#80: 3 cerrados por #93/#94 + issue #91 por DEC-042) + **15 puntos de decisión** sin `DEC-NNN` (D7, D9, D11–D12, D14–D24; D1–D6, D8, D10 y D13 cerrados por DEC-021 y DEC-035..043 el 2026-10-30) + presupuesto de DEC del ciclo al **20,5 %** (DEC 31 sobre CODE 151; **regla ≥ 20 % cumplida — ciclo cerrado** por DEC-043) |
| **Stdlib Astra-0 (M1/M2b/M3 — MVP cerrado)** | ✅ 10 builtins + `for c in s` + lexer + helpers puros | `len`, `s[i]`, `to_string`, `read_file`, `ord`, `substr`, `push`, `str_to_int`, `chr`, `read_line` en 4 rutas (DEC-013..020) + helpers en Astra puro `contains`/`index_of`/`split` (DEC-024, `conformance/stdlib/`) · `selfhost/lexer_gate.sh` → **7/7** rutas + gate fuerte `lexer_tokens_parity.sh` vs `--dump-tokens` (lexer escrito en Astra-0) · `selfhost/io_gate.sh` → **8/8** |
| **Enforcement entre fibras** | 🟡 v1+E2 implementado y gateado | S1/S2 + nil-red + `.copy()` (deep copy con depth cap) en 4 rutas (DEC-012/022/026/027 `test-pinned`) · S3/`spawn` = fase E3 · RT1 solo M4 (DEC-023) hasta scheduler/send |
| Lenguaje completo (comptime, ARC/ORC, fibers, FFI, stdlib) | ⏳ Pendiente | ver `04_fase2_zig/PHASE2_GAP_ANALYSIS.md` §11 |
| **Fase 3** — Astra se compila a sí misma | ⏳ Pendiente | prerequisitos: stdlib M1/M2/M3 ✅ (MVP cerrado 2026-10-28) + árbol de compilador en Astra |

---

## Cómo mantener este índice

- **Al añadir o mover un documento**: añadir su fila aquí; corregir los
  contadores *actuales* que citan el número de informes (`README.md` árbol y
  sección Documentation) y las referencias en `AGENTS.md` si el documento
  cambia una regla de flujo. No hace falta tocar `index.html` ni
  `.agents/skills/*` para un informe nuevo: ninguno enumera informes
  (verificado 2026-10-27). `CHANGELOG.md` solo cita el recuento en la entrada
  fechada del reordenamiento («informes 001–024»): es registro histórico y no
  se reescribe.
- **Al actualizar el estado**: los documentos *vivos* son
  `03_fase1_seed/PHASE1_PROGRESS.md`, `04_fase2_zig/PHASE2_PROGRESS.md` y
  `05_fase_llvm/PHASE_LLVM_PROGRESS.md`. Los demás (`*_AUDIT`,
  `PHASE2_{ARCHITECTURE,IMPL_PLAN,RESEARCH}`) son registros de diseño o
  auditorías **fechados**: no se reescriben, se corrigen solo los hechos
  objetivamente falsos.
- **Los contadores se verifican, no se recuerdan.** Antes de citar un número
  de tests, ejecútalo: `cd seed && make test`, `cd zig && zig build test`,
  `zig/tests/dump_parity.sh`, `zig/tests/llvm_parity.sh`.
- **Idioma**: la documentación no está unificada. Se respeta el idioma de cada
  documento (ES o EN); ver cabecera de tabla en cada sección.
