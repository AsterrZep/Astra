# 023 — Backend LLVM para Astra: investigación de integración

> **Alcance**: solo investigación (cómo, por qué, con qué herramientas). Ningún
> código de producción se toca en este documento. Fecha: 2026-10-16. Todo lo
> marcado **[verificado]** se ejecutó en esta máquina (Debian, clang-19,
> Zig 0.16.0 en `~/zig`, LLVM 19 en `/usr/lib/llvm-19`) durante la investigación;
> lo demás es revisado de fuentes externas citadas.

---

## 0. Resumen ejecutivo

1. **El plan oficial del repo** (`COMPILER_STRATEGY.md`: backend LLVM linkado
   desde Zig vía `@cImport(llvm-c/*.h)` + `linkSystemLibrary("llvm")`) **sigue
   siendo el correcto en 2026 y lo verifiqué funcionando de punta a punta** en
   esta máquina **[verificado]** — con una corrección práctica: hay que
   **linkar `-lc` explícitamente**; sin libc, el binario zig segfaultea dentro
   de LLVM (ver §4.3).
2. **LLVM actual es 23.1.3** (upstream, 2026-10-06; majors cada ~6 meses); la
   máquina y la mayoría de distros van con retardo — aquí LLVM 19. La
   estrategia de versionado debe ser **soportar un rango (19..N)** como hace
   Odin (17..22), no fijar un major **[verificado: Odin]**.
3. **Medí el techo del camino corto** (backend C actual compilado con clang/LLVM
   en vez de gcc): `fib(32)` → gcc -O2 **0.30s**, clang -O2 **0.41s**,
   clang -O0 **1.30s** **[verificado]**. Cambiar gcc→clang sobre la salida C
   actual **no gana**: el techo no es el optimizador, es el ABI de valores
   (tagged union de 16 B, convención `AstraValue (*)(AstraValue *frame, u8)`,
   todo el tráfico intermedio por `frame[sp]` en memoria). **El valor real de
   un backend LLVM está en el frontend del codegen (SSA + des-boxing), no en
   "ser LLVM"**.
4. **Recomendación**: backend dedicado vía **C API (`llvm-c`) desde el
   compilador zig**, con **runtime C reutilizado** (`codegen_runtime.h`,
   semántica idéntica al VM), **v1 con boxing** (paridad por la suite de
   conformidad como gate) y **v2 con des-boxing progresivo** (enteros/flotantes
   en SSA). Puente táctico: emitir **IR textual `.ll`** primero — `llc`, `lli`
   y `opt` ya están en la máquina — y parsearlo con `IRReader.h` cuando se
   quieran pasos propios (híbrido texto→API validado por llvmlite).

---

## 1. Por qué LLVM (y qué NO resuelve)

### 1.1 Lo que aporta

| Aporte | Detalle para Astra |
|:-------|:-------------------|
| Optimización | SSA, GVN, inlining, LICM, vectorización — pero ver §1.2: solo rinden si el IR generado tiene tipos precisos y no cajas en cada operación |
| Targets | x86-64, aarch64, riscv64, s390x, wasm (llc -mattr), sin escribir backend nuevo — desbloquea "Astra → binario nativo/EMSCRIPTEN-like" |
| Ecosistema | lldb (DWARF vía `DebugInfo.h`), perf, sanitizers (ASan/MSan/TSan sobre artefactos Astra), profilers, coverage — gratis sobre los binarios |
| JIT | `Orc.h`/`LLJIT.h` en C API: REPL, eval, comptime futuro, pruebas rápidas sin `llc`+link |
| Madurez | 20+ años, el backend de Rust/Swift/Clang; bugs conocidos y mitigaciones |

### 1.2 Lo que NO resuelve (y la medición que lo prueba)

`fib(32)` con el backend C actual **[verificado, §4.6]**:

| Compilador | Tiempo | Nota |
|:-----------|-------:|:-----|
| gcc -O2    | 0.30s  | hoy (Makefile) |
| clang -O2  | 0.41s  | "LLVM sobre la salida C" — **no gana** |
| clang -O0  | 1.30s  | el -O2 vale ~4×, pero el techo lo marca el ABI |

El techo está en el **modelo de ejecución**, no en el optimizer:

- `AstraValue` = tagged union de 16 B (`AstraTag` + union de i64/double/punteros)
  — cada entero viaja con tag;
- convención de llamada `AstraValue (*)(AstraValue *frame, uint8_t argc)` —
  frame por llamada, args en memoria, nada en registros SSA;
- el C generado (muestreado, §4.7) ya tipa enums como structs C con union —
  clang lo optimiza razonablemente, pero **todo intermediario pasa por
  `frame[sp]`**: `ASTRA_PUSH`, stores/loads en el frame, `astra_eq` sobre
  valores boxed.

Conclusión: **"usar LLVM" ≠ "ser rápido"**. El backend LLVM solo justifica su
coste si ataca el ABI: v1 boxed (paridad) → v2 des-boxing (`i64`/`f64` en SSA,
enum por tag entero, strings/arrays como punteros). Ese es el trabajo de
frontend de codegen; LLVM paga la parte backend (registro, peephole, targets).

### 1.3 Por qué ahora y no antes

- La suite de conformidad (237 checks seed + 219+ zig) y el backend C son la
  **referencia semántica**: el gate de un backend nuevo es pasar la misma
  suite. Eso ya existe.
- El bootstrap (`COMPILER_STRATEGY.md` §6): Fase 3 = Astra se auto-compila. El
  compilador zig es el permanente; el seed C se retira. **Un backend nuevo
  solo se justifica en zig** (ver §5).

---

## 2. El plan oficial del repo y qué delata la práctica

`COMPILER_STRATEGY.md` (§8.2, §10.4, fases 15-16) planea:

```zig
const c = @cImport({ @cInclude("llvm-c/Core.h"); @cInclude("llvm-c/Analysis.h"); });
compiler.linkSystemLibrary("llvm");
```

**Verificado hoy [verificado]:** funciona en Zig 0.16.0, con matices que el
plan no menciona:

1. `@cImport` **sigue existiendo** en 0.16 aunque el langref ya no lo
   documenta (traducción vía translate-c interna; la caché de build lo
   compila en ~2 min en frío con `Core.h` y segundos después).
2. `-lc` **es obligatorio** al linkar `libLLVM-19.so` desde zig (§4.3).
3. `linkSystemLibrary("llvm")` no basta como nombre: en Debian la lib se llama
   `libLLVM-19.so` en `/usr/lib/llvm-19/lib` — hay que descubrir ruta/versión
   con `llvm-config` (hacerlo como Odin: env `ASTRA_LLVM_CONFIG` con
   fallback a `llvm-config` del PATH).
4. El ejemplo del repo usa `linkSystemLibrary("clang")` además de llvm: **no
   hace falta** — `libLLVM` solo (la C API no necesita clang para codegen; el
   linker de los artefactos es el ld del sistema o lld).

---

## 3. Opciones de integración (comparativa)

| # | Opción | Esfuerzo | Techo | Dependencia en runtime | Veredicto |
|:-:|:-------|:---------|:------|:-----------------------|:----------|
| A | Backend C actual + `clang -O2` (hoy, sin código) | cero | bajo (medido: no gana vs gcc) | ninguna (clang solo en build) | mantener como baseline; no es el camino LLVM |
| B | Emitir **IR textual `.ll`** + subproceso `llc`/`clang` | medio | medio-alto | herramientas LLVM en PATH | **puente M0-M1 ideal**: sin linkar libLLVM, `lli` da dev-loop, FileCheck testeable; mismo patrón que `--emit-c`→gcc |
| C | **C API `llvm-c` linkada** (desde zig) | medio-alto | alto | libLLVM-XX.so en build del compilador (no de los binarios Astra) | **objetivo final** (plan oficial verificado) |
| D | Híbrido B→C: texto `.ll` + `LLVMParseIRInContext` (IRReader) + pasos propios + TargetMachine | medio | alto | como C | camino incremental recomendado: se empieza en B y el frontend de emisión no cambia |
| E | **JIT** MCJIT/LLJIT (C API) | alto | dev-loop instantáneo, REPL | como C | futuro (M4); MCJIT = legacy (llvmlite aún lo usa), LLJIT = moderno (`LLJIT.h` en LLVM 19) |
| F | Alternativas: **Cranelift** | alto | medio (~2-14% más lento que LLVM, codegen ~10× más rápido) | — | API solo-Rust (requiere shim Rust embebido); x86-64/aarch64/s390x/riscv64. Interesante para JIT rápido, no primer paso |
| G | **QBE** (librería C ~10k LOC) | bajo | bajo (opts/pocos targets) | libqbe | solo si el objetivo fuera minimalismo, no performance |
| H | **MLIR** | muy alto | — | — | descartado: Astra no necesita un framework de dominios; el CIR no aplica |

**Recomendación: D → C** (emitir `.ll` textual primero, parsear con IRReader
para pasos/emisión de objetos vía TargetMachine, terminar linkando libLLVM para
JIT y DWARF). La distinción B/C es de *link*, no de *diseño del emisor*: el
código que construye el módulo crece igual.

---

## 4. Verificación empírica en esta máquina (2026-10-16)

### 4.1 Inventario disponible

| Componente | Estado |
|:-----------|:-------|
| LLVM upstream | 23.1.3 (2026-10-06); majors ~cada 6 meses |
| LLVM en la máquina | **19.1.7** en `/usr/lib/llvm-19` |
| `llvm-c` headers | ✅ completos: `Core Analysis Target TargetMachine DebugInfo Orc LLJIT OrcEE ExecutionEngine IRReader BitWriter Linker Error Transforms` |
| `libLLVM-19.so` | ✅ (link dinámico = `-lLLVM-19`; estático = 216 archives de componentes) |
| Tools | ✅ `llc lli opt FileCheck llvm-config` en `/usr/lib/llvm-19/bin` (no en PATH) |
| clang | ✅ 19 (`/usr/bin/clang`) |
| Zig | ✅ 0.16.0 en `~/zig` |

### 4.2 Smoke C (clang + llvm-c) **[verificado]**

Crear módulo, función `i64 add(i64,i64)`, `LLVMVerifyModule`, imprimir IR —
funciona a la primera contra `libLLVM-19.so`.

### 4.3 Smoke Zig (zig 0.16 + llvm-c) **[verificado]**

Mismo programa en zig con `@cImport`:

- **Sin `-lc` → segfault dentro de LLVM** (地址 en libLLVM; el binario zig sin
  libc no expone el runtime glibc que libLLVM espera).
- **Con `-lc` → funciona** e imprime el mismo IR que la versión C.
- Frío de compilación: ~2:17 (translate-c de `Core.h`); cacheado: ~2s.

### 4.4 Camino M0 completo `.ll → llc → .o → link → run` **[verificado]**

```bash
llc -filetype=obj m0.ll -o m0.o && clang m0.o -o m0.bin && ./m0.bin  # exit=42
```

### 4.5 Descubrimiento de versión

`llvm-config --libs --link-shared` → `-lLLVM-19` (una lib); `--version` → 19.1.7.
Ruta de descubrimiento recomendada (patrón Odin): env `ASTRA_LLVM_CONFIG`
con fallback `llvm-config`.

### 4.6 Benchmark del techo (backend C actual)

Ver §1.2 — fib(32): gcc-O2 0.30s / clang-O2 0.41s / clang-O0 1.30s. Nota: la
diferencia gcc↔clang es ruido a esta escala; el saltador de 4× es -O0→-O2.

### 4.7 Muestreo del C generado

`--emit-c` de un match con guarda: enums → structs C con union tipada (bien);
funciones → `AstraValue f(AstraValue *frame, uint8_t argc)` con `uint16_t sp`;
intermediarios → `ASTRA_PUSH`/stores sobre `frame[sp]`; igualdad de enums →
`astra_eq` boxed. Confirma §1.2.

---

## 5. Dónde vive el backend: zig, no seed

- `COMPILER_STRATEGY.md` §6: la Fase 3 es Astra auto-compilándose; el
  compilador zig es el permanente, el seed C se retira tras validar features.
- El port zig ya tiene la paridad de frontend (lexer/parser/typechecker/
  emitter/VM) y la suite conformance corre sobre él — **el gate de un backend
  nuevo es la misma suite**, disponible en el host zig.
- Invertir el backend LLVM en el seed obligaría a reimplementarlo en zig
  (doble trabajo, violando el esquema de bootstrap).
- El backend C (`codegen.c`) queda como referencia semántica y como camino
  sin dependencias — el emisor LLVM debe reproducir su comportamiento observable.

---

## 6. Modelo de valores, runtime y decisiones de lowering

### 6.1 Runtime: reutilizar `codegen_runtime.h`

- 892 líneas, header-only, `static inline`, semántica **ya verificada contra el
  VM** por la suite + fuzzing. Es la especificación ejecutable del lenguaje.
- Estrategia: compilarlo **una vez como TU** (`astra_runtime.o` con enlace
  externo) o mantener el include por módulo como hace `codegen.c`. Para v1:
  include por módulo (idéntico al backend C → cero divergencias nuevas); para
  v2: TU separada + funciones `noinline` en los caminos de error (ver §6.4).
- AstraValue queda boxed en v1 (paridad bit a bit con VM/C).

### 6.2 Des-boxing (v2, el verdadero premio)

| Constructo | v1 (boxed) | v2 (SSA) |
|:-----------|:-----------|:---------|
| `i64`/`f64`/`bool` | AstraValue en stack/frames | `i64`/`double` en SSA; tags solo en fronteras (prints, arrays heterogéneos) |
| enums | `AstraEnumObj*` malloc por valor (hoy en C) | `{ i32 tag, [N x payload] }` por valor en SSA cuando el tipo es conocido |
| structs | puntero + strcmp de campos (VM) | GEP por índice estático (el typechecker ya conoce el layout) |
| closures | `AstraClosure*` heap | env como struct anónima pasada como puntero; capturas por valor ya lo son |
| Option/Result | wrapper boxed | `{ i1 is_ok, T inner }` when T known |

### 6.3 Errores y `?`

- Hoy: par global `astra_error_jmp` + `astra_error_active` (setjmp/longjmp),
  con save/restore en cada `OPCODE_CALL` (invariante 9 del codegen).
- **v1: mantener longjmp** — funciona dentro de código compilado por LLVM (es
  una llamada C; no requiere landingpad ni EH). La semántica ya está probada en
  tres backends.
- Alternativa futura (v2+): modelo error-union estilo Zig (resultado explícito
  `{ok, err}` propagado con `?`) — elimina longjmp pero cambia el ABI y
  exige reescribir builtins; solo con un caso de uso que lo pida (JIT/REPL).

### 6.4 Riesgo de UB/opt con longjmp

`setjmp/longjmp` sobre frames con valores en registros SSA puede confundir al
optimizador si el longjmp cruza funciones inlineadas. El backend C ya sobrevive
esto con gcc/clang porque los caminos de error son llamadas a helpers. Regla
para el backend LLVM: **los helpers de error (`astra_runtime_error`,
`astra_try_unwind`) viven en la TU del runtime con `noinline`**, nunca se
inlinean en el IR del usuario. También: los allocas de recover se limitan al
entry block (regla estándar de LLVM para que mem2reg funcione).

### 6.5 Match, bucles, `?`

- Match: los tests de tag del emitter actual (GET_ENUM_FIELD/EQ/JIF) se traducen
  1:1 a `icmp`+`br`+phi; sin cambio de diseño — el decision-tree ya vive en el
  frontend (typechecker de exhaustividad).
- Bucles: el modelo de altura de pila del emitter **desaparece** en un backend
  SSA (no hay `frame[sp]`) — se emiten `br` + phi directamente. Es una
  simplificación grande: las familias de bugs §4.7/§4.10/§4.11 (alturas,
  stubs de `continue`) no tienen análogo en IR.
- `continue`/`break`/`return` → bloques básicos; sin patching de offsets.

---

## 7. Caja de herramientas LLVM (las que importan para Astra)

| Herramienta | Uso en el proyecto |
|:------------|:-------------------|
| `llvm-c/Core.h` | construir módulo: tipos, funciones, builder (IRBuilder no está en C API — se usa `LLVMBuild*` directo) |
| `llvm-c/Analysis.h` | `LLVMVerifyModule` — **gate automático en cada compilación** (barato, catching) |
| `llvm-c/TargetMachine.h` | `LLVMTargetMachineEmitToFile` → .o nativo (o textual .s) |
| `llvm-c/DebugInfo.h` | DWARF: breakpoints por línea Astra en lldb (v2) |
| `llvm-c/IRReader.h` | `LLVMParseIRInContext` — híbrido texto→API (opción D) |
| `llvm-c/Orc.h` + `LLJIT.h` | JIT moderno (M4: REPL/eval); `ExecutionEngine.h` = MCJIT legacy |
| `llvm-c/BitWriter.h` | emitir `.bc` (para inspect/debug) |
| `lli` | **dev-loop**: ejecutar el .ll sin compilar/linkar (rápido para tests) |
| `llc` | .ll → .o/.s con target/mattrs (cruzado: `-mtriple=aarch64-linux-gnu`) |
| `opt` | aplicar pipeline de pasos; `opt -passes=verify` sanity |
| `FileCheck` + `lit` | tests de IR assertion-based (patrones en el .ll emitido) — el runner propio (run_tests.sh) ya cubre salida; FileCheck para shapes de IR concretos |
| `llvm-dis`, `llvm-bcanalyzer` | inspección de bitcode |
| **Alive2** | validador de equivalencia para pasos/opts si se tocan (futuro) |
| sanitizers/lldb/perf | sobre artefactos Astra vía clang (ASan ya se usa en el seed para el compilador; esto lo extiende al código emitido) |
| **libFuzzer** (ya en repo) | ampliar el harness existente: todo programa fuzz → `LLVMVerifyModule` + comparar salida vs VM/C — **el fuzzing diferencial que ya existe se extiende al backend LLVM casi gratis** |

---

## 8. Versionado, distribución y CI

### 8.1 Versiones

- Upstream: 23.1.3 actual; majors cada ~6 meses (marzo/septiembre). La C API
  cambia despacio pero cambia (ports por major: removals en transforms,
  cambios en ORC). Punteros opacos desde LLVM 15 → el grueso del IR-builder
  no depende de major.
- **Soportar rango**, patrón Odin (`brew install llvm`, versions 17..22,
  `LLVM_CONFIG` override): Astra → `ASTRA_LLVM_CONFIG`, rango propuesto
  **19..23** (19 = mínimo probado en la máquina + CI de distro; 23 = latest).
- Descubrimiento en `build.zig`: `b.addSystemCommand("$(ASTRA_LLVM_CONFIG||llvm-config) --includedir --libdir --version")`; la versión decidirá
  comptime qué variantes de la C API usar (pocos `if` esperados).

### 8.2 Peso y distribución

| Modo | Coste | Nota |
|:-----|:------|:-----|
| Dinámico (`-lLLVM-19`) | +~50-70 MB enlazados al binario del **compilador** (no a los binarios Astra) | simplest; es lo que hace el smoke verificado |
| Estático | cientos de MB, link lento (216 archives) | solo si se quiere compilador sin dependencias de sistema |
| Subproceso (opción B/D) | cero link | requiere tools en PATH/ASTRA_LLVM_HOME |

**Clave**: LLVM es dependencia de **build del compilador**, igual que Odin —
los binarios finales de Astra no dependen de LLVM (son .o+runtime C). Las
releases precompiladas del compilador pueden llevar LLVM estático dentro o
asumir libLLVM del sistema.

### 8.3 CI

- Job nuevo `llvm` (opt-in, no bloqueante al inicio): instala `llvm-19-dev`
  (ya disponible en esta máquina; en GitHub Actions: `apt install llvm-19-dev clang-19`) o apt.llvm.org para latest.
- Gates espejo del job seed: conformance через `--emit-llvm` + llc + run, con
  los mismos EXPECTs; paridad seed↔zig↔llvm.
- Tiempos: translate-c de Core.h ~2 min en frío → cachear `zig-cache` entre
  runs, o **evitarlo** con bindings escritos a mano (§9).

---

## 9. Riesgos y mitigaciones

| Riesgo | Impacto | Mitigación |
|:-------|:--------|:-----------|
| Churn de la C API entre majors | medio | rango 19..23 + CI en dos extremes; los `LLVMBuild*` son estables desde hace años |
| Frío de compilación (2:17 translate-c Core.h) | bajo | caché zig; o bindings manuales curados (~40-80 funciones para M0-M2 — la C API es plana y estable; precedente: llvmlite/inkwell exponen subsets) |
| Semántica divergente vs VM/C | **alto** | la suite de conformidad es el gate (ya corre en ambos hosts); fuzzing diferencial existente ampliado con la ruta LLVM; `LLVMVerifyModule` en cada build |
| UB nuevo (longjmp, aliasing, alignment) | medio | §6.4: helpers noinline; el runtime C ya es la semántica — no se reimplementa en IR |
| Doble mantenimiento (zig + eventual Astra) | medio | el backend nace en zig; la auto-compilación (Fase 3) lo heredará |
| Expectativa "LLVM = rápido" sin des-boxing | alto | §1.2 medido: comunicar que v1 = paridad + targets/DWARF; v2 (des-boxing) = la ganancia |
| ORC C API menos documentada | bajo | empezar con llc (subproceso) — el JIT es M4 opcional |

---

## 10. Hitos sugeridos (para cuando se decida implementar)

| Hito | Contenido | Gate |
|:-----|:----------|:-----|
| **M0** | Infra: flag `-Dllvm` en `zig build`, descubrimiento `llvm-config`, emisor mínimo (arith i64, if/while, funciones, `print` via runtime) en `.ll` textual + `llc`+link con `astra_runtime.o` | un programa corre y da el mismo output en VM/C/LLVM; `LLVMVerifyModule` limpio |
| **M1** | Cobertura = suite codegen (22 casos) + conformance: arrays, structs, enums, match, closures, Option/Result, `?`, strings | runner con los mismos EXPECTs en la tercera ruta; 0 divergencias en fuzz diferencial |
| **M2** | `-O2`, DWARF (DebugInfo.h), sanitizers sobre artefactos, benchmark suite vs C backend/VM | benchmarks documentados; lldb debuggable por línea Astra |
| **M3** | Targets cruzados (`-mtriple` aarch64/wasm), artefactos de release | cross-run en CI |
| **M4** (opcional) | LLJIT (REPL/eval), des-boxing de escalares (el premio de rendimiento), perfilado guiado | benchmarks vs C backend con números publicados |

---

## 11. Referencias

- LLVM releases: <https://releases.llvm.org/> — actual 23.1.3 (2026-10-06) **[verificado vía API GitHub]**
- C API (llvm-c): <https://llvm.org/doxygen/group__LLVMCInfrastructure.html> — headers locales en `/usr/lib/llvm-19/include/llvm-c/`
- Kaleidoscope (tutorial oficial, C++ — el diseño aplica): <https://llvm.org/docs/tutorial/>
- Kaleidoscope en C con C API (referencia de emisor): <https://github.com/saleyn/llvm-tutorial>
- llvmlite (diseño de referencia: C API + MCJIT + parse_assembly): <https://llvmlite.readthedocs.io/en/latest/user-guide/binding/examples.html>
- Cranelift (alternativa): <https://cranelift.dev/> — API Rust, codegen ~10× más rápido, código ~2-14% más lento
- Odin (precedente de rango de versiones + `LLVM_CONFIG` + usuarios sin LLVM): <https://odin-lang.org/docs/install/> **[verificado]**
- ORC/LLJIT C API: `llvm-c/Orc.h`, `llvm-c/LLJIT.h` (presentes desde LLVM ~13; verificados en 19)
- Repo: `COMPILER_STRATEGY.md` (plan oficial, fases 15-16), `codegen_runtime.h` (runtime candidato), `codegen.c` (referencia semántica del codegen)

---

## 12. Preguntas abiertas (decisión antes de M0)

1. **Objetivo declarado**: ¿paridad + targets/DWARF primero (v1) o ir directo
   al des-boxing (más lento en llegar, más ganancia)? (Recomendación: v1
   paridad — la suite lo hace barato.)
2. **Host**: ¿confirmar zig (recomendado, §5) o sembrar en el seed para
   prototipar rápido y portar?
3. **Puente textual**: ¿aceptar M0 en `.ll` textual (sin linkar LLVM, con
   llc) como paso intermedio? (Recomendación: sí — desacopla la decisión de
   dependencia.)
4. **Dependencia**: ¿el compilador zig acepta `libLLVM-XX.so` del sistema
   como requisito de build opcional (flag `-Dllvm`), con el camino C como
   default mientras tanto?
5. **Rango de versiones mínimo**: ¿19 (lo probado/CI de distro) o subir a 21+?
