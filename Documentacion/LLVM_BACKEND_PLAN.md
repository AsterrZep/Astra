# PLAN DE ACCIÓN — Backend LLVM para Astra

> Fase nueva del roadmap (`COMPILER_STRATEGY.md`: "VM + LLVM" desde el
> diseño). Este plan consolida las investigaciones
> **`research/023_LLVM_backend_investigacion.md`** (opciones, verificación
> empírica de la máquina) y
> **`research/024_llvm_mejores_practicas_segun_investigacion.md`** (qué dicen
> las fuentes primarias) en un plan ejecutable con el proceso de AGENTS.md
> (commits pequeños y probados, gates verdes, conventional commits en
> español, suite de conformidad como gate de paridad).
> Fecha: 2026-10-16. **Decisión pedida al final: §2 (versión LLVM).**

---

## 0. Resumen ejecutivo

| Pregunta | Respuesta |
|:---------|:----------|
| ¿Qué se construye? | Tercera ruta de codegen del compilador **zig**: `AST tipado → LLVM IR (C API llvm-c) → .o/.ll`, con el runtime C actual reutilizado |
| ¿Dónde vive? | `zig/src/llvm/` — **no** en el seed (bootstrap C→Zig→Astra: 023 §5) |
| ¿Cómo se activa? | Flag **`-Dllvm`** en `zig build` (default `false`: sin LLVM instalado, todo funciona como hoy) |
| ¿Qué versión de LLVM? | **LLVM 19 como mínimo pinado** (ya verificado en la máquina), **rango soportado 19..23** vía `llvm-config`, canario CI con latest (§2) |
| ¿Gate de calidad? | Misma suite de conformidad por una ruta más: VM ↔ C ↔ zig-VM ↔ **LLVM**, + fuzzing diferencial |
| ¿Qué NO es v1? | Des-boxing completo, JIT/REPL, MLIR, C++ API, tocar el seed |

**Definición de "hecho" de la fase**: el 100% de `tests/conformance/` (no-UI)
y `tests/codegen/` pasa por la ruta LLVM con salida byte-identica; fuzz
diferencial limpio; benchmarks documentados; DWARF funcional; CI verde con el
job LLVM; AGENTS.md y un `PHASE_LLVM_PROGRESS.md` actualizados.

---

## 1. Decisiones ya tomadas (investigación cerrada)

1. **Host zig** (023 §5): el compilador permanente; el seed se retira en la
   Fase 3 (auto-hosting) y no invierte en backends nuevos.
2. **C API (`llvm-c`), no C++ API** (023 §3 opción C/D): suficiente para todo
   lo necesario (Core/Analysis/TargetMachine/DebugInfo/Orc), estable entre
   majors, sin ABI C++. Precedentes: llvmlite, inkwell.
3. **Runtime C reutilizado** (`seed/src/codegen_runtime.h`): semántica ya
   verificada contra el VM por la suite + fuzzing; v1 lo incluye por módulo
   (idéntico al backend C), v2 puede pasarlo a TU separada.
4. **Semántica mapeada sin UB** (023 §6 + 023 §4): `+ - *` = wrap definido →
   `add` plano sin `nsw`/`nuw` ni `with.overflow`; `/ %`, shifts y bounds =
   guard + `call @astra_runtime_error noreturn` + `unreachable`; floats sin
   fast-math en `/`; `?` = longjmp v1 con helpers `noinline` y sin
   `willreturn`.
5. **Mejores prácticas de emisión** (024 §2): `triple`+`datalayout`
   obligatorios; allocas en entry block antes de cualquier `call`; AstraValue
   pasa fronteras de función como **2×i64 escalares**; atributos
   `nounwind`/`noundef`/etc. en helpers del runtime; pesos de rama fríos para
   los traps; encadenar comparaciones en `match` (sin hubs de alta
   in-grado); pipeline `-O2` como base con adiciones medidas
   (LICM/LoopUnswitch/IRCE) y test de sanidad re-`-O2`.
6. **Verificación obligatoria**: `LLVMVerifyModule` en cada módulo; la suite
   es el gate; `lli` para el dev-loop; FileCheck para shapes de IR.

---

## 2. Decisión: ¿qué versión de LLVM?

### 2.1 Veredicto

> **Se usa LLVM 19 (19.1.7) como versión mínima soportada y la de
> desarrollo/CI. Rango soportado: 19..23. Canario CI no bloqueante: latest
> (23.1.3) vía apt.llvm.org.**

### 2.2 Razones

| # | Razón | Evidencia |
|:-:|:------|:----------|
| 1 | **Ya está verificado de punta a punta en esta máquina**: headers `llvm-c` completos (Core/Analysis/TargetMachine/DebugInfo/Orc/LLJIT…), `libLLVM-19.so`, `llc/lli/opt/FileCheck/llvm-config` en `/usr/lib/llvm-19/bin`, y el smoke zig 0.16 + `@cImport` + `-lc` funcionando | [verificado] 023 §4 |
| 2 | **Es el que shippea la distro estable** (Debian/Ubuntu): con `llvm-19-dev` basta; sin PPA ni builds desde fuente | [verificado] máquina |
| 3 | **Punteros opacos desde LLVM 15** estabilizan la superficie del IR-builder: la C API que usamos (los `LLVMBuild*`) cambia despacio entre majors | 023 §8 |
| 4 | **Precedente de rango**: Odin soporta 17..22 con descubrimiento por env — un rango amplio es sostenible | [verificado] 023 §8 |
| 5 | **Probar el suelo, no el techo**: si el backend funciona en 19 (el mayor "viejo" soportado), funciona en cualquier mayor del rango; añadir 20..23 al rango es activar el canario, no rediseñar | práctica de soporte |
| 6 | **No 23 de entrada**: upstream va 6 meses por delante de las distros; anclarse a latest duplicaría el trabajo de packaging (apt.llvm.org en cada máquina de contributor) sin ganar funcionalidad para Astra | 023 §8 |

### 2.3 Mecánica de versión en el build (`zig/build.zig`)

```text
-Dllvm                    → activa el backend (default false)
ASTRA_LLVM_CONFIG        → env con la ruta a llvm-config (fallback: "llvm-config" del PATH)
llvm-config --version    → 19 <= v <= 23 ?  compile : error claro y accionable
llvm-config --includedir --libdir --libs --link-shared
```

- Enlace dinámico: `-lLLVM-19` (una sola lib, [verificado] 023 §4.5).
  Estático (216 archives) queda descartado para desarrollo.
- `@cImport` de `llvm-c/*.h` **en un único módulo** (`zig/src/llvm/c_api.zig`)
  para que el coste frío (~2:17 la primera vez con `Core.h`, cacheado
  después) se pague una sola vez y quede encapsulado (023 §4.3).
- **Gotcha verificado a documentar en AGENTS.md**: al linkar `libLLVM` desde
  zig es **obligatorio `-lc`**; sin libc, segfault dentro de LLVM (023 §4.3).

---

## 3. Arquitectura

### 3.1 Archivos nuevos (propietarios de workstream)

| Ruta | Contenido |
|:-----|:----------|
| `zig/build.zig` (edición) | `b.option(bool, "llvm", …)`, descubrimiento `llvm-config`, módulo condicional, link `-lLLVM-19 -lc` |
| `zig/src/llvm/c_api.zig` | **Único** `@cImport` de `llvm-c/Core.h, Analysis.h, TargetMachine.h, DebugInfo.h`; wrappers zig idiomáticos |
| `zig/src/llvm/emitter.zig` | AST tipado → LLVM IR (el emisor; sigue el patrón del emitter de bytecode pero en este nivel: allocas+SSA, §1.5) |
| `zig/src/llvm/runtime/astra_runtime_llvm.c` | TU delgada: `#include "codegen_runtime.h"` (copia sincronizada o include por ruta relativa al seed — decisión en M0) + `astra_runtime_error` `noreturn` exportado |
| `zig/src/llvm.zig` | Fachada: `emitModule(ast) → *LLVMModuleRef`, verify, write `.ll`/`.o` |
| `zig/src/main.zig` (edición) | Flags CLI: `--emit-llvm` (texto `.ll` junto al input), `--emit-obj` (M2+), `--emit-llvm-stdout` para tests |
| `zig/tests/llvm/` | Casos `.astra` + expectativas de la ruta LLVM (paralelo a `tests/codegen/` del seed) |
| `zig/tests/llvm_parity.sh` | Runner: conformance no-UI → `--emit-llvm` → `llc`/`lli` → salida idéntica a la VM |
| `Documentacion/PHASE_LLVM_PROGRESS.md` | Progress log estilo PHASE2_PROGRESS.md (se crea al aterrizar M0) |

### 3.2 Flujo

```
.astra ──► lexer/parser/typechecker (zig, ya portados) ──► AST tipado
   │
   ├─► Ruta VM (zig)          ── ya existe, gate de referencia
   ├─► Ruta C (--emit-c)      ── seed, referencia semántica
   └─► Ruta LLVM (nueva):     emitter.zig → LLVM C API
          │  LLVMVerifyModule  (siempre)
          ├── --emit-llvm      → archivo .ll (inspección, FileCheck)
          ├── llc -filetype=obj → .o  (M0-M1, subproceso)
          ├── TargetMachineEmitToFile (M2+, en proceso)
          └── link con astra_runtime_llvm.o + libc → binario Astra
```

### 3.3 Debugging (espejo de los switches del repo)

```bash
zig build -Dllvm
./zig-out/bin/astra-zig --emit-llvm file.astra     # escribe file.ll
ASTRA_LLVM_DUMP=1 ./zig-out/bin/astra-zig …        # volcar IR por paso (futuro)
/usr/lib/llvm-19/bin/lli file.ll                   # dev-loop sin linkar
opt -passes=verify file.ll                         # sanity fuera de proceso
```

---

## 4. Proceso (AGENTS.md aplicado a la fase)

1. **Opt-in estricto**: sin `-Dllvm`, ningún artefacto, gate ni binario
   cambia. Los gates actuales (seed, zig, parity) corren igual y deben
   seguir verdes en cada commit de la fase.
2. **Un commit = una feature enfocada = gates verdes**. Nunca dejar la suite
   roja; si un intento falla, revertir y documentar en el progress log.
3. **Conventional commits en español**: `feat(llvm): …`, `fix(llvm): …`,
   `test(llvm): …`, `docs(llvm): …`, `build(llvm): …`.
4. **La suite de conformidad es el gate de paridad**: una compilación de
   lenguaje no aterriza en LLVM hasta que su caso de conformance pasa por
   las cuatro rutas con salida idéntica (patrón del sweep VM↔C, ampliado).
5. **El seed no se toca** en esta fase; si la ruta LLVM descubre un bug real
   del seed, se arregla con el espejo zig como siempre (fix(seed)+fix(zig)).
6. **Fuzzing diferencial**: ampliar el harness mental (patrón
   `sweep_emit_c.sh`) a VM↔C↔zig↔LLVM; `LLVMVerifyModule` fallando = crash
   de fuzz.
7. **Handoff por workstream** con sus tres obligaciones: `zig build -Dllvm`
   sin warnings, gates verdes, tests/pin añadidos.

---

## 5. Workstreams (paralelizables tras M0)

| Workstream | Owns | Verifies with |
|:-----------|:-----|:--------------|
| **llvm-infra** | `build.zig` (flag/descubrimiento/link), `c_api.zig`, runtime TU | unit test de módulo verify; `zig build` sin flag intacto |
| **llvm-core** | `emitter.zig`: literales, aritmética con guards (§1.4), `let`, `if`/`while`, funciones, `print` | `lli`/`llc` + salida VM |
| **llvm-values** | arrays, structs, enums, `match`, closures, strings | suite `tests/codegen/` + conformance |
| **llvm-errors** | guards de div/shift/bounds, Option/Result, `?` (longjmp v1), atributos de helpers | conformance `ui/` + sweeps |
| **llvm-testing** | `llvm_parity.sh`, ruta en CI, FileCheck, fuzz diferencial | job `llvm` CI verde |
| **llvm-quality** (M4) | pipeline `-O2`+adiciones, DWARF, benchmarks, remarks | benchmarks documentados; lldb por línea Astra |
| **docs** | `PHASE_LLVM_PROGRESS.md`, AGENTS.md (build instrs + fila de workstream), este plan | review |

Contrato único entre workstreams: `zig/src/llvm/c_api.zig` + la tabla de
semántica §1.4/023 §4 — si dos workstreams necesitan cambiarla, lo hace
uno primero y el otro rebasa.

---

## 6. Hitos, gates y secuencia de commits

### M0 — Infraestructura (smoke de punta a punta)
**Contenido**: flag `-Dllvm`, descubrimiento `llvm-config` (rango 19..23),
`c_api.zig`, TU del runtime, `--emit-llvm`, emisor mínimo (i64 aritmética
con guards de wrap/div/shift, `if`/`while`, funciones, `print`).
**Commits** (secuencia planeada):
1. `build(llvm): flag -Dllvm y descubrimiento de LLVM vía llvm-config`
   — gate: `zig build` sin flag ≡ actual; `zig build -Dllvm` detecta 19.1.7
2. `feat(llvm): binding llvm-c y módulo verify/print (smoke)`
   — gate: unit test crea `i64 add(i64,i64)`, verifica e imprime IR
3. `feat(llvm): emisor mínimo y CLI --emit-llvm`
   — gate: `fib(20)` → `.ll` → `llc` → link runtime → salida = VM (196418→el
   valor de fib(20)=6765; el punto es salida idéntica, no el número)
4. `test(llvm): runner llvm_parity + job CI llvm (apt.llvm.org 19)`
   — gate: CI verde con 4 jobs; primeros casos en `zig/tests/llvm/`
5. `docs(llvm): PHASE_LLVM_PROGRESS.md + AGENTS.md (build -Dllvm, -lc)`
   — gate: review

### M1 — Núcleo completo
Closures (env structs), floats (guards no-IEEE), Option/Result y `?`
(longjmp v1), strings. **Gate**: subset de conformance (~60%) por ruta LLVM,
`llvm_parity.sh` en CI ampliado.

### M2 — Valores y patrones
Arrays/structs (GEP estáticos por layout del typechecker), enums+`match`
(tag tests → `icmp`/`br`/phi; sin hubs), `for..in`. **Gate**: los 22 casos de
`seed/tests/codegen/` + conformance completa por la ruta LLVM;
`TargetMachineEmitToFile` reemplaza al `llc` subproceso.

### M3 — Paridad total y robustez
Atributos de helpers, pesos de rama fríos en traps, fuzz diferencial
cuádruple, FileCheck para shapes críticos (guards, match). **Gate**:
**definición de "hecho"** de §0 alcanzada; la fase es usable.

### M4 — Calidad (benchmark + debug)
DWARF (`DebugInfo.h`, Kaleidoscope ch. 9), pipeline `-O2` + adiciones
(LICM/LoopUnswitch extra, IRCE) **midiendo** con remarks; suite de
benchmarks (fib, bucles, match) vs VM y backend C; sanitizers sobre
artefactos. **Gate**: números publicados en el progress log; lldb depura por
línea Astra.

### M5 — Targets y release
Cruzado `-mtriple=aarch64-linux-gnu` (+ wasm si se quiere), artefactos,
matriz CI (x86-64 gate + aarch64 canario). **Gate**: cross-run en CI.

### M6 — Opcional / futuro
LLJIT (REPL/eval), des-boxing de escalares (el premio real de rendimiento,
023 §1.2), fast-math opt-in, error-union para `?` si el JIT lo pide.
Cada uno se planifica al llegar; M6 no bloquea el cierre de la fase.

---

## 7. CI (extensión de `.github/workflows/ci.yml`)

```yaml
llvm:
  name: llvm (LLVM 19) — ruta --emit-llvm sobre la suite
  runs-on: ubuntu-latest
  steps:
    - checkout + setup-zig 0.16.0
    - Instalar LLVM 19: wget https://apt.llvm.org/llvm.sh && sudo ./llvm.sh 19 \
        && sudo apt-get install -y llvm-19-dev        # [a verificar en M0]
    - zig build -Dllvm                                # con ASTRA_LLVM_CONFIG si hace falta
    - ./zig/tests/llvm_parity.sh
llvm-canario:                                        # no bloqueante (continue-on-error)
  … misma instalación con latest (23) …              # churn de API detectado antes
```

- El job principal **fija LLVM 19** (reproducible); el canario usa latest
  para adelantar el churn de la C API hacia el rango 19..23.
- Los jobs actuales (seed, zig, parity) **no cambian**: `-Dllvm` es opt-in.

---

## 8. Riesgos top (023 §9 + 024 §8, condensados)

| Riesgo | Mitigation en el plan |
|:-------|:----------------------|
| Semántica divergente vs VM/C | Suite por 4 rutas + fuzz diferencial (M3 gate) |
| UB introducido por flags | Política: **cero flags UB** en v1 (024 §3/§4); revisión explícita si alguno se propone |
| Churn entre majors LLVM | Rango 19..23 + canario CI + encapsulamiento en `c_api.zig` |
| Coste frío de translate-c | Un solo módulo `c_api.zig` + caché zig |
| Expectativa de rendimiento sin des-boxing | Comunicado 023 §1.2: v1 = paridad + targets + DWARF; v2 (M6) = des-boxing |
| `-lc` olvidado → segfault | Gotcha documentado en AGENTS.md (M0) y testeado en CI |
| Regresión de los gates existentes | §4.1: ópt-in estricto; gates actuales en verde cada commit |

---

## 9. Próximo paso

M0 es pequeño y autocontenido (~4 commits, una tarde de trabajo enfocado):
infra + smoke de fib end-to-end. Al aterrizarlo se crea
`PHASE_LLVM_PROGRESS.md` y se actualiza AGENTS.md. Los hitos M1+ siguen el
mismo patrón workstream → commit probado → gate verde.

Pendiente de confirmación del usuario antes de M0.1:
- Instalación de `llvm-19-dev` en CI vía `apt.llvm.org/llvm.sh 19`
  (la única pieza marcada "[a verificar]" — si falla, alternativa:
  `llvm-19` de universe o contenedor con LLVM preinstalado).
