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
| `zig/src/llvm.zig` | Fachada: `emitModule(ast) → *LLVMModuleRef`, verify, write `.ll`, `emitObjectFile` (TargetMachineEmitToFile, M2.e) |
| `zig/src/main.zig` (edición) | Flags CLI: `--emit-llvm` (texto `.ll` junto al input), `--emit-llvm-stdout` (tests), `--emit-obj` (objeto nativo vía TargetMachine, M2.e) |
| `zig/tests/llvm/` | Casos `.astra` + expectativas de la ruta LLVM (paralelo a `tests/codegen/` del seed) |
| `zig/tests/llvm_parity.sh` | Runner: conformance no-UI + suite `seed/tests/codegen/` → `--emit-obj` → link runtime → salida idéntica a la VM |
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
          ├── --emit-obj       → .o vía TargetMachineEmitToFile (RelocPIC)
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
6. **Fuzzing diferencial**: `zig/tests/llvm_fuzz_gen.py` genera programas
   deterministas por (semilla, índice) y `zig/tests/llvm_fuzz.sh` los pasa
   por VM↔C↔zig↔LLVM comparando stdout, stderr y exit code byte a byte
   (`LLVMVerifyModule` fallando = crash de fuzz). CI corre una campaña corta
   con semilla fija en el job `llvm`.
7. **Handoff por workstream** con sus tres obligaciones: `zig build -Dllvm`
   sin warnings, gates verdes, tests/pin añadidos.

---

## 5. Workstreams (paralelizables tras M0)

| Workstream | Owns | Verifies with |
|:-----------|:-----|:--------------|
| **llvm-infra** | `build.zig` (flag/descubrimiento/link), `c_api.zig`, runtime TU | unit test de módulo verify; `zig build` sin flag intacto |
| **llvm-core** | `emitter.zig`: literales, aritmética con guards (§1.4), `let`, `if`/`while`, funciones, `print` | `--emit-obj` + salida VM |
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

### M2 — Valores y patrones ✅ (cerrado, `74557cb`)
Arrays/structs (GEP estáticos por layout del typechecker), enums+`match`
(tag tests → `icmp`/`br`/phi; sin hubs), `for..in` (rangos + arrays),
`--emit-obj` vía TargetMachineEmitToFile. **Gate alcanzado**: la suite
`seed/tests/codegen/` + la conformance completa pasan por la ruta LLVM;
paridad 119 casos = 101 ok / 16 skip (M3) / 2 excl / 0 fail. Ver
`PHASE_LLVM_PROGRESS.md` §6 para las decisiones de layout y lowering.

### M3 — Paridad total y robustez (✅ cerrado 2026-10-20)
Cierra los 16 skip restantes (genéricos, traits/impls, módulos con
import), la guarda de profundidad de llamada que hoy se excluye (los 2
`excl`), más atributos de helpers, pesos de rama fríos en traps, fuzz
diferencial cuádruple y FileCheck para shapes críticos (guards, match).
**Gate alcanzado**: `llvm_parity.sh` **131 casos — 131 ok, 0 skip, 0 excl,
0 fail**, `llvm_filecheck.sh` 4/4, fuzz de cuatro rutas 480/480 y canario CI
no bloqueante. Detalle por paso en `PHASE_LLVM_PROGRESS.md` §7/§9.

### M4 — Calidad (benchmark + debug) — ✅ cerrado (2026-10-21)
DWARF (`DebugInfo.h`, Kaleidoscope ch. 9), pipeline `-O2` + adiciones
(LICM/LoopUnswitch extra, IRCE) **midiendo** con remarks; suite de
benchmarks (fib, bucles, match) vs VM y backend C; sanitizers sobre
artefactos. **Gate**: números publicados en el progress log; lldb depura por
línea Astra.

**Hecho (2026-10-21)**: M4.a (suite `zig/tests/bench/` + `llvm_bench.sh`,
números en `PHASE_LLVM_PROGRESS.md` §8), M4.b (`--opt-level=N` con
`LLVMRunPasses`; `-O2` = `default<O2>` + `loop-mssa(licm)` +
`simple-loop-unswitch` + `irce`; el gate de paridad corre también con
`ASTRA_LLVM_OPT=2`: **154/154**), y M4.c (`--debug-info` con `DebugInfo.h`,
subprograms y locations por instrucción, verificado con `llvm_dwarf_test.sh` y
`lldb-19` en líneas Astra), y M4.d (`--sanitize=address`: el emisor marca las
funciones y la pasada `asan` del new PM instrumenta antes del pipeline;
`llvm_sanitize.sh` exige instrumentación en IR y objeto, el enlace con
`-fsanitize=address`, corre la suite completa bajo ASan: **154/154 a -O0 y
-O2**, y cierra con un gate de fugas LSan sobre `tests/llvm/leaks.astra`).
La auditoría post-M4 (2026-10-21) cerró los SEGV con nil, la igualdad
de arrays de bool y los valores-función (`PHASE_LLVM_PROGRESS.md` §11), y
M4.e añadió el modelo de ownership por refcount que elimina las fugas del
código generado (`PHASE_LLVM_PROGRESS.md` §12).
**M4 cerrado**; UBSan queda para cuando el new PM exponga `ubsan`
(LLVM 19..23 no la registra).

### M5 — Targets y release (cerrado 2026-10-22)
Cruzado `-mtriple=aarch64-linux-gnu` vía el flag `--target=<triple>`, gate
cross-run en CI (job `llvm-cross`: emitir para aarch64, enlazar con el
toolchain cruzado y correr bajo qemu — **154/154** idénticos a la VM). wasm,
opcional en el plan, se formalizó tras M5 como `wasm32-wasi` de punta a
punta: gate `zig/tests/llvm_wasm.sh` (emitir → `wasm-ld`+wasi-libc → Node
WASI, **154/154** sin y con `-O2`) + job CI `llvm-wasm` (§13.4 del progress
log). El plumbing de `--target` acepta cualquier triple registrado en la lib
LLVM. Detalle en `PHASE_LLVM_PROGRESS.md` §13.

### M6 — Opcional / futuro
**M6.a (LLJIT) está implementado** (`--jit`, `PHASE_LLVM_PROGRESS.md` §14):
ejecución in-process vía ORC/LLJIT, cimiento del REPL/eval, con paridad
**154/154** contra la VM (`zig/tests/llvm_jit.sh`). **M6.b (fast-math) está
implementado** (`--fast-math`, `PHASE_LLVM_PROGRESS.md` §15): los siete flags
fast-math sobre toda la aritmética FP, opt-in puro — sin el flag el IR es
byte-idéntico — y el guard de división cero queda sin marcar; suite de
paridad 155/155 con el fixture `check_fast_math.astra` (creció de 154).
El des-boxing de escalares
que 023 §1.2 apunta ya está entregado dentro de v1 — el emisor camina el AST
tipado y emite `i64`/`f64`/`i8` nativos en SSA, y `llvm_bench.sh` mide la ruta
LLVM 2-8× más rápida que el backend C boxed. Quedan opcionales el des-boxing de
Option/Result — diseño cerrado en `PHASE_LLVM_PROGRESS.md` §16: par
`{i8 tag, i64 payload}` en SSA con boxing en fronteras de contenedor; la
opción sentinel i64 quedó **descartada** (el dominio de i64 es completo,
cualquier sentinel colisiona) — y error-union
para `?` si el JIT lo pide. Cada uno se planifica al
llegar; M6 no bloquea el cierre de la fase.

---

## 7. CI (extensión de `.github/workflows/ci.yml`)

```yaml
llvm:
  name: llvm (LLVM 19) — ruta --emit-obj sobre la suite
  runs-on: ubuntu-latest
  steps:
    - checkout + setup-zig 0.16.0
    - Instalar LLVM 19 (apt.llvm.org, verificado en CI): wget llvm.sh 19 \
        && sudo apt-get install -y llvm-19-dev
    - zig build -Dllvm                                # con ASTRA_LLVM_CONFIG si hace falta
    - ./zig/tests/llvm_parity.sh                      # --emit-obj -> link runtime
llvm-cross:                                          # gate cross-run de M5 (aarch64)
  name: llvm-cross (aarch64) — cross-run bajo qemu
  runs-on: ubuntu-latest
  steps:
    - LLVM 19 (igual que el job llvm)
    - sudo apt-get install -y gcc-aarch64-linux-gnu qemu-user-static
    - zig build -Dllvm
    - ./zig/tests/llvm_cross.sh                       # --emit-obj --target -> qemu
llvm-wasm:                                           # gate wasm32-wasi (§13.4)
  name: llvm-wasm (wasm32-wasi) — suite bajo Node WASI
  runs-on: ubuntu-latest
  env: { ASTRA_WASM_CLANG: clang-19 }
  steps:
    - LLVM 19 (igual que el job llvm)
    - sudo apt-get install -y clang-19 lld-19
    - curl wasi-sysroot-23.0.tar.gz (release wasi-sdk-23) -> ASTRA_WASI_SYSROOT
    - actions/setup-node node 24                      # >= 22 (V8 con EH)
    - zig build -Dllvm
    - ./zig/tests/llvm_wasm.sh                        # y con ASTRA_LLVM_OPT=2
llvm-canario:                                        # no bloqueante (continue-on-error)
  … misma instalación con latest (23) …              # churn de API detectado antes
```

- El job principal **fija LLVM 19** (reproducible; `apt.llvm.org/llvm.sh 19`
  quedó verificado en CI — era la única pieza "[a verificar]" en M0); el
  canario usa el stable más reciente (`llvm.sh` sin argumentos) para
  adelantar el churn de la C API hacia el rango 19..23. **Cuatro jobs existen
  en `ci.yml`**: `llvm` (gate x86-64, pinado a 19 — corre la paridad AOT, la
  paridad JIT de M6.a, FileCheck, DWARF, sanitizers y fuzz), `llvm-cross`
  (gate cross-run aarch64 de M5, `gcc-aarch64-linux-gnu` + `qemu-user-static`),
  `llvm-wasm` (gate wasm32-wasi, `clang-19` + `lld-19` + el tarball
  `wasi-sysroot` de la release `wasi-sdk-23` — el `wasi-libc` de Ubuntu
  noble no trae `<setjmp.h>`, §13.4 del progress — + Node 24) y
  `llvm-canario` (`continue-on-error`, M3).
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

Estado: **M0–M6.b completados** (ver `PHASE_LLVM_PROGRESS.md`). El backend
compila el subconjunto de Astra-0 (escalares, floats, strings,
Option/Result+`match`/`?`, closures, arrays/structs/enums, `for..in`,
`break`/`continue`, genéricos, traits/impls) a `.o` nativo vía
TargetMachineEmitToFile y reproduce la salida de la VM byte a byte en
**155/155 casos** (0 skip, 0 excl). Las cuatro rutas están gateadas en CI
y en verde: nativa (`llvm`), cross aarch64 bajo qemu (`llvm-cross`, M5),
wasm32-wasi bajo Node WASI (`llvm-wasm`, §13.4) y `--jit` in-process
(`llvm`, M6.a); el job `llvm` añade FileCheck, DWARF, sanitizers y el
fuzz diferencial de cuatro rutas. M4 cerró con benchmarks y pipeline
`-O2` (155/155 también en `-O2`). La compatibilidad con LLVM 22 (churn de ORC que señaló el
canario) quedó corregida y verificada con el canario en verde
(`PHASE_LLVM_PROGRESS.md` §14.5); M6.b entregó `--fast-math` (§15 del
mismo log), opt-in puro sin mover la semántica por defecto.

Lo que queda es **opcional** (§6, «M6 — Opcional / futuro»), y cada
entrada se planifica al entrar: des-boxing de Option/Result (diseño
cerrado en `PHASE_LLVM_PROGRESS.md` §16, pendiente de implementar) y
error-union para `?`. Los hitos siguen el patrón
workstream → commit probado → gate verde.

Pendiente confirmado y cerrado: la instalación de `llvm-19-dev` en CI vía
`apt.llvm.org/llvm.sh 19` quedó verificada con el job `llvm` en verde desde
M0.4 (ya no es un riesgo "[a verificar]").
