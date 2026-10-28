# Astra — Índice maestro de la documentación

> **Última revisión:** 2026-10-28 · **Rama:** reorganización en carpetas
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
| [`06_auditorias/`](../06_auditorias/) | Auditorías ejecutadas contra el código | 2 |
| [`07_investigacion/`](../07_investigacion/) | Informes de investigación (001–030) | 30 |
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

## 7. `07_investigacion/` — Informes de investigación

30 informes numerados `001`–`030`, sin solapamientos: cada uno es un
dossier autocontenido sobre un tema (gramática, diseño del seed, backend C,
enums y pattern matching, arquitectura de rustc/cpython/go/julia, testing,
concurrency, comptime, stdlib, paquete, ABI, Android, Apple, LLVM, crítica
externa, enforcement de seguridad, semántica de runtime, stdlib y
benchmarks…).

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
| **Fase 1** — compilador semilla (`seed/`) | ✅ Completa | `make test` → **319 passed, 0 failed** (ASan/UBSan/LSan) + `sweep_emit_c` → **149 total, 3 skip, 0 fail** (2026-10-28) |
| Registro de constructos | ✅ (índice documental — DEC-002) | `--check-constructs` → **47 constructos, 27 operadores**; hooks = aspiración, no plan de migración |
| **Fase 2** — compilador Zig (`zig/`) | 🟡 Frontend completo | `zig build test` → **74/74** · `dump_parity.sh` → **193 ficheros, 0 divergentes** |
| Sistema de módulos | ✅ | `pub`, globales mangladas, orden de dependencias, `use`, raíz `@/` |
| **Fase LLVM** (opt-in `-Dllvm`) | ✅ M0–M6.c | `llvm_parity.sh` → **205/205** (también `ASTRA_LLVM_OPT=2`; skips = fallo desde #21) + `llvm_mem.sh` → techo 64 MB |
| **Decisiones de lenguaje** | ✅ 23 registradas (21 aceptadas) | `DECISIONES.md` — DEC-001..023 (única en `Propuesta`: DEC-021, la CLI `astraea`); DEC-012 ratificada 2026-10-28 con DEC-022/023 |
| **Stdlib Astra-0 (M1/M2b/M3 — MVP cerrado)** | ✅ 10 builtins + `for c in s` + lexer | `len`, `s[i]`, `to_string`, `read_file`, `ord`, `substr`, `push`, `str_to_int`, `chr`, `read_line` en 4 rutas (DEC-013..020) · `selfhost/lexer_gate.sh` → **7/7** rutas + gate fuerte `lexer_tokens_parity.sh` vs `--dump-tokens` (lexer escrito en Astra-0) · `selfhost/io_gate.sh` → **8/8** |
| **Enforcement entre fibras** | 🔵 Especificado, no implementado | `ARCHITECTURE.md` §2.6 (Opción F) · DEC-012/022/023 `Aceptada (doc)` 2026-10-28 · implementación = PR «fase E» (estimación 15–25 d/h en DEC-012) · RT1 solo M4 hasta scheduler/send |
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
