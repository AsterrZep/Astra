# 024 — Aplicar LLVM según la literatura: mejores prácticas para el backend de Astra

> **Alcance**: solo investigación. Complementa `023_LLVM_backend_investigacion.md`
> (opciones de integración, verificación empírica de herramientas) con la
> pregunta **"¿qué dicen las fuentes primarias y las investigaciones sobre la
> mejor manera de aplicar LLVM?"**. Fecha: 2026-10-16. Lo marcado **[verificado]**
> se leyó o ejecutó hoy (docs oficiales de LLVM descargados desde
> llvm.org/docs, código del repo); lo marcado **[citado]** se referencia sin
> verificación directa y se nombra por título/sitio, no por identificador.

---

## 0. Resumen ejecutivo — la "mejor manera" según las fuentes, en 9 reglas

1. **Emite IR "tipo Clang"**: el doc oficial dice textualmente que Clang es el
   frontend más maduro y "cuanto más se aleje tu IR del que emite Clang, menos
   optimizable será" [verificado: PerformanceTips]. Estudiar su CodeGen como
   plantilla.
2. **allocas en el entry block, antes de cualquier `call`**; deja que
   SROA/mem2reg construyan el SSA — "SSA es la forma canónica esperada por el
   optimizer" [verificado: PerformanceTips]. El backend de Astra **no** replica
   la máquina de pila del bytecode.
3. **Cero UB, cero `nsw`/`nuw`, cero `poison`**: la semántica de Astra ya es
   semántica fuerte verificada (wrap definido + guards explícitos, §4) — es el
   camino que el "LLVM IR UB Manual" recomienda a los lenguajes con semántica
   fuerte [verificado: UndefinedBehavior + vm.c/runtime].
4. **Passthrough de guardas**: div/mod/shift/bounds = guard condicional +
   `call @astra_runtime_error noreturn` + `unreachable` (nada de UB
   inmediato ni de intrinsics) [verificado: ambos manuales + semántica Astra].
5. **Atributos de memoria en los helpers del runtime** (`nounwind`, `noundef`,
   `readonly`…) — el optimizer no ve a través de llamadas sin ellos
   [verificado: PerformanceTips].
6. **`-O2` como base, no como dogma**: el doc dice que usar los pipelines
   `-O2`/`-O3` tal cual es "uno de los errores más comunes de los frontends
   nuevos"; para un lenguaje con guardas añadir LICM/LoopUnswitch extra e IRCE
   (range checks), y validar con el test de sanidad de re-ejecutar `-O2` sobre
   el IR ya optimizado [verificado: PerformanceTips §Pass Ordering].
7. **Debug info y verificación desde el día 1**: `LLVMVerifyModule` en cada
   módulo; DWARF con una alloca por variable (Kaleidoscope ch. 9) [verificado:
   tutorial + docs].
8. **Validar, no fiarse**: Alive2 (PLDI 2021) hace translation validation de
   transformaciones LLVM y corre a diario contra LLVM main detectando
   miscompiles [verificado: GitHub AliveToolkit/alive2]; úsalo para sospechas
   de pipeline, no en el camino crítico.
9. **Mantén LLVM opcional y versionado por rango** (Odin: 17..22 vía
   `LLVM_CONFIG`) [verificado: odin-lang.org/docs/install en 023] — coherente
   con que Zig mismo haya retirado LLVM de su propia compilación
   [citado: ziglang.org].

---

## 1. Fuentes primarias consultadas

| Fuente | Qué es | Estado |
|:-------|:-------|:-------|
| `llvm.org/docs/Frontend/PerformanceTips.html` | **"Performance Tips for Frontend Authors"** — qué espera LLVM de un frontend: la guía canónica de emisión de IR | [verificado] descargado hoy |
| `llvm.org/docs/UndefinedBehavior.html` | **"LLVM IR Undefined Behavior (UB) Manual"** — UB inmediato vs diferido (poison/undef), `freeze`, guías para frontends de semántica fuerte | [verificado] descargado hoy |
| `llvm.org/docs/tutorial/` | **Kaleidoscope** — tutorial oficial: cap. 3 (IR), 7 (variables mutables = alloca), 8 (object code), 9 (debug info) + serie "Building a JIT" (ORC por capas) | [verificado] índice hoy; capítulos [citado] |
| `llvm.org/docs/GettingStarted.html` | Integración como librería, `llvm-config`, builds stand-alone | [verificado] hoy (§4) |
| `llvm.org/docs/ExceptionHandling.html`, `GetElementPtr.html`, `SourceLevelDebugging.html`, `NewPassManager.html`, `OpaquePointers.html`, `Remarks.html` | EH (landingpad/invoke), "the often misunderstood GEP", DWARF, NPM (`LLVMRunPasses`), punteros opacos, optimization remarks | [citado] (índice verificado; contenido de dominio público bien establecido) |
| **Alive2** (github.com/AliveToolkit/alive2) | Translation validation de optimizaciones LLVM; paper **PLDI 2021**; tools: `alive-tv` (+web alive2.llvm.org/ce), plugin de `opt`, `alivecc`; corre a diario contra LLVM main; BugList.md con bugs de LLVM encontrados | [verificado] hoy |
| **LLVM CGO'04** — Lattner & Adve, *"LLVM: A Compilation Framework for Lifelong Program Analysis & Transformation"* | El paper de diseño: IR estable como contrato de por vida entre frontend y optimizer | [citado] |
| **MLIR** — Lattner, Amini, Bondhugula, Cohen et al. (2020), mlir.llvm.org | Rationale del IR multinivel: si necesitas optimizaciones de alto nivel, hazlas ANTES de bajar a LLVM IR | [citado] (arXiv no verificado) |
| **CompilerGym** — Cummins et al., NeurIPS 2020 Datasets & Benchmarks, facebookresearch/CompilerGym | Benchmark suite de pipelines de optimización (cBench/PolyBench) para estudiar phase-ordering empíricamente | [citado] (arXiv no verificado) |
| **Cranelift** — cranelift.dev (Bytecode Alliance) | Backend JIT alternativo: codegen ~10× más rápido, código ~2-14% más lento, API solo-Rust | [verificado] sitio en sesión 023 |
| **Odin** — odin-lang.org/docs/install | Precedente de rango de versiones LLVM (17..22), descubrimiento por `LLVM_CONFIG`, usuarios finales sin LLVM | [verificado] en 023 |
| **llvmlite** — llvmlite.readthedocs.io | Diseño de referencia de un binding C-API: secuencia canónica initialize→triple→TargetMachine→MCJIT→verify | [verificado] en 023 |

> **Nota de honestidad**: tres identificadores arXiv que recordaba de memoria
> para MLIR/CompilerGym/Cranelift resultaron pertenecer a papers sin relación
> (combinatoria, materiales, astrofísica) al verificarlos hoy — por eso este
> documento los cita **por título y sitio**, sin ID. No propagar IDs no
> verificados.

---

## 2. "Performance Tips for Frontend Authors" — la biblia de la emisión [verificado]

Síntesis regla a regla con la aplicación concreta a Astra (el backend viviría
en `zig/src/emitter/` o en un `src/llvm/`, consumiendo el AST ya tipado):

### 2.1 Lo básico del módulo y las funciones
- **`datalayout` + `target triple` son obligatorios**: sin ellos "ninguna
  optimización específica de target estará habilitada" — efecto mayor que
  casi cualquier otro. Obtenerlos del `TargetMachine` (`LLVMCreateTargetDataLayout`).
- **Linkage lo más privado posible** (`internal`/`private`/`linkonce_odr`):
  potencia el IPO.
- **Evitar bloques con alta in-grado** (decenas de predecesores): el
  register allocator rinde mal. **Excepción explícita**: un bloque de `ret`
  unificado con alta in-grado está bien → nuestro `match` con muchas armas
  debe encadenar comparaciones (if/else-if), no crear un hub gigante.
- Funciones del runtime: `nounwind`, `noreturn` donde aplique, `noundef` en
  parámetros, `readonly`/`readnone`/`argmemonly` cuando se conozca — "el
  optimizer intentará inferirlos pero no siempre puede; es especialmente
  importante para funciones externas" → **`astra_add`, `astra_eq`,
  `astra_enum_val`, `astra_truthy`… deben declararse con atributos** o el
  backend pierde la mitad del pipeline.

### 2.2 allocas y SSA
- allocas de variables de función **al inicio del entry block, ANTES de
  cualquier `call`** (un `call` puede inlinearse y añadir bloques, sacando a
  un alloca posterior del entry block). **SROA/mem2reg solo eliminan allocas
  del entry block**; si no se eliminan, "el optimizer probablemente será meno
  efectivo de lo que podría".
- Traducción directa para Astra: cada `let`/parámetro local → alloca + stores;
  cada uso → load; mem2reg hace el resto. **Nada de replicar `frame[sp]`** —
  esa disciplina (las familias de bugs §4.7/§4.10/§4.11 del emitter de
  bytecode) simplemente no existe en este nivel.
- `lifetime.start`/`lifetime.end` sobre las allocas: DSE + tamaños de pila
  menores (recomendado explícitamente).

### 2.3 Tipos y memoria
- **No crear valores de tipo agregado** (structs/arrays) salvo: inicializadores
  globales, devolver múltiples valores en registros, resultados de
  intrinsics `with.overflow`, y agregados como *tipo* en GEP/`sret`.
  → **Refinamiento del v1 boxed de 023**: `AstraValue` (struct de 16 B) no
  debe viajar como *valor agregado*; representarlo como **dos escalares i64**
  (tag/payload) en fronteras de llamada — el patrón "return de múltiples
  valores en registros" está bendecido por el doc, y clang ya pasa structs de
  16 B en dos registros de todos modos.
- **No load/store de `i1`** (extender a i8); **byte types** (no `iN`) para
  memoria cruda/union punteros (preservan provenance).
- **`zext` > `sext` cuando el rango lo permita**; `!range` metadata para
  comunicar rangos (ayuda a sext→zext y a eliminar checks).
- **`inbounds` en los GEP**; `ptrtoint`/`inttoptr` con parsimonia (GEP mejor);
  alignment explícito donde se sepa (contrato de UB que el backend explota).

### 2.4 Aritmética, flags e intrinsics
- `nsw`/`nuw` "van muy bien para el optimizer" — **pero nunca para Astra** (§4):
  la semántica de Astra hace que estos flags sean ilegales siempre.
- **Intrinsics aritméticas (incluidas las `with.overflow`): "muy raramente
  rentables… el optimizer las formará él mismo al final del pipeline"** —
  salvo que "tu spec de lenguaje requiera emitir una secuencia concreta".
  Astra: `+`/`-`/`*` son wrap definido → **`add`/`sub`/`mul` planos, sin
  intrinsics y sin flags**; div/shift → guards de control flujo, no
  intrinsics. Ni siquiera invocamos la excepción "requerido por la spec".
- **fast-math** solo si la semántica lo permite — Astra: no en `/` (§4), y
  futuro opt-in del estilo `-ffast-math` como feature del lenguaje.
- `llvm.assume`: evitar; para unreachable no-terminador usar la forma canónica
  `store i1 true, ptr poison, align 1`.

### 2.5 Control de flujo y bucles
- Para funciones que siempre lanzan: `invoke` con destino normal
  `unreachable` (o `noreturn`).
- **Profile metadata para caminos fríos** incluso sin perfilado dinámico:
  "puede marcar una gran diferencia en la colocación de código en bucles
  apretados" → los bloques de trap (`integer overflow`, `division by zero`,
  `index out of bounds`) deben llevar pesos de rama fríos.
- **No terminar el header del bucle antes de tiempo** (limita LICM si el
  terminator es un branch condicional de salida) — relevante para cómo
  emitimos `while`/`for`.
- Comparar contra constantes con **tipo de comparación consistente** (GVN
  corre tarde en el pipeline).
- Anidamiento profundo de bucles: evitar (complejidad cúbica en algunos passes).

### 2.6 Pass ordering — la corrección importante a 023
 textual: *"One of the most common mistakes made by new language frontend
 projects is to use the existing -O2 or -O3 pass pipelines as is. These pass
 pipelines… have been carefully tuned for C and C++, not your target language.
 **You will almost certainly need to use a custom pass order** to achieve
 optimal performance."* Recomendaciones concretas del doc:
 1. Lenguajes con muchas **guardas rara vez ejecutadas** (null/type/range
    checks — Astra: bounds, división, tags de enums): añadir ejecuciones extra
    de **LoopUnswitch + LICM**.
 2. **Range checks → IRCE** (Index Check Elimination), no está en el pipeline
    estándar.
 3. **Test de sanidad**: pasar el IR ya optimizado otra vez por `-O2`; si
    mejora, tu orden de passes necesita ajuste.
→ vía C API: `LLVMRunPasses` (New Pass Manager) con pipelines por texto
(`"default<O2>"`, o listas explícitas) — el NPM hace esto práctico
[verificado: `llvm-c/Transforms/PassBuilder.h` presente en LLVM 19 de la
máquina; doc `NewPassManager.html` [citado]].

---

## 3. El "LLVM IR UB Manual" — semántica fuerte, poison y freeze [verificado]

- **UB inmediato**: reservarlo a lo que trampa el CPU (división por cero,
  null-deref). El doc muestra por qué: un `udiv` con UB inmediato bloquea el
  hoisting/speculación (ejemplo `f(c,v)` del manual). Astra ya no emite
  ninguno: todos esos casos son **guard + error de runtime** (§4).
- **Time-travel**: con `willreturn`, el UB puede borrar I/O *anterior* al
  UB. Regla del doc: `willreturn` solo en funciones sin comportamiento
  observable. → `astra_runtime_error` (imprime y sale) **jamás**
  `willreturn`; es observable y `noreturn`.
- **Deferred UB** (poison/undef): el caso de estudio del manual son los
  **shifts** — x86 y ARM difieren; los lenguajes "con semántica fuerte deben
  usar el valor condicionalmente" (enmascar). **Astra ya lo hace mejor**: guard
  0..63 → error (§4.1); el shift va sobre `uint64_t`.
- **`undef` deprecado** (solo cargas de memoria sin inicializar); **`poison`**
  es el deferred UB; **`freeze`** para cortar la propagación; ramificar sobre
  poison = UB inmediato (ejemplo del loop-unswitching).
- **Tests sin UB inmediato**: usar argumentos dummy, no `poison`, para que
  Alive2 pueda validar — regla aplicable a nuestros futuros tests de IR.
- **Consecuencia Astra**: al emitir cero flags UB y cero poison, la clase
  entera de miscompiles "poison propagation" queda fuera de nuestra superficie.
  El coste son los guards explícitos; la mitigación es la sección 2.6
  (LICM/LoopUnswitch/IRCE) + `!range`.

---

## 4. La semántica de Astra ya está mapeada a IR — tabla verificada en el código

Cada fila: semántica verificada hoy en el VM y el runtime C (espejo zig) →
mapeo IR recomendado por las fuentes.

| Op | Semántica actual [verificado] | Mapeo LLVM IR (mejor manera) |
|:---|:-----------------------------|:-----------------------------|
| `+ - *` int | **wrap definido** vía uint64 (`vm.c:746-748`, `astra_add` runtime `:462-466`, audit §4.2; espejo zig `+%`) | `add`/`sub`/`mul` **sin flags** (wrapping es el comportamiento *definido* de LLVM) — **nunca `nsw`/`nuw`**, nunca intrinsics `with.overflow` |
| `/ %` int | error runtime en divisor 0 y en `INT64_MIN / -1` (`vm.c:817-833, 862-866`; `astra_div`/`astra_mod`) | guard `icmp` + bloque de trap (`call void @astra_runtime_error(...) noreturn` + `unreachable`); `sdiv`/`srem` solo tras el guard |
| `/ %` float | **no IEEE**: divisor 0.0 → error runtime (decidido para paridad VM/C) | igual que int; **sin fast-math** en `/`; el resto de floats candidatos a fast-math opt-in futuro |
| `<< >>` | guard 0..63 → error; shift sobre uint64 (`vm.c:1073-1081`, `astra_shl`) | guard + `shl`/`lshr` sobre i64 — coincide con lo que el UB manual pide a "lenguajes de semántica fuerte" |
| indexación | bounds check → error (`vm.c:1148, 1221`) | guard + trap; añadir `!range` y más tarde IRCE para eliminar checks redundantes en bucles |
| `?` (Option/Result) | longjmp a try-context pareado (`codegen_runtime.h:793-802`, invariante 9) | v1: mantener longjmp (helpers `noinline` en TU del runtime); sin landingpad; v2 (si el JIT lo pide): error-union explícita |
| enums/match | tag tests + ramas (con exhaustividad ya probada en el typechecker) | cadena `icmp`+`br`+phi; no construir un hub de alta in-grado (§2.1) |

**Lectura global**: Astra es un lenguaje de **semántica fuerte** (todo
definido o error de runtime) — exactamente el perfil para el cual el UB manual
recomienda el camino sin UB. El backend LLVM de Astra no necesita *ningún*
flag de poison/UB para rendir bien; necesita guards baratos + buen pass
ordering.

---

## 5. Precedentes de industria — qué hicieron y qué enseñan

| Proyecto | Qué hizo | Lección para Astra |
|:---------|:---------|:-------------------|
| **Swift** [citado] | Creado un IR de nivel medio propio (**SIL**) antes de LLVM IR porque el IR de LLVM era demasiado bajo para las optimizaciones del lenguaje (devirtualización, ownership) | Astra ya tiene su "SIL": el AST tipado + el decision-tree de match + la resolución de closures del emitter. Las optimizaciones de lenguaje se hacen ahí; LLVM solo recibe la forma baja |
| **Rust** [citado] | MIR propio; backend LLVM vía wrapper C++; añadió Cranelift para builds de dev más rápidas | Dos backends conviven: LLVM = release, rápido = dev. Astra ya tiene VM (dev) + C (referencia); LLVM entra como tercera ruta de release |
| **Odin** [verificado 023] | Soporta **rango LLVM 17..22**, descubrimiento por env `LLVM_CONFIG`, usuarios de releases sin LLVM | Rango de versiones + flag opcional: exactamente el diseño propuesto en 023 §8, ahora con precedente citable |
| **Zig** [citado] | Empezó sobre LLVM y luego construyó backends self-hosted (x86_64/aarch64/wasm) para eliminar la dependencia de su propia compilación | Coste real de depender de LLVM (build times, peso) → mantener `-Dllvm` opcional en `zig build` de Astra |
| **llvmlite (Numba)** [verificado 023] | Binding C-API mínimo sobre MCJIT; secuencia canónica initialize→triple→TM→verify→JIT | Un subset curado de la C API basta; no hace falta cubrir LLVM entero |
| **Cranelift/Wasmtime** [verificado 023] | Backend propio Rust: ~10× más rápido de compilar, ~2-14% más lento | Si algún día se quiere un JIT de arranque instantáneo, Cranelift es la vía — pero su API es Rust; para Astra (zig) no es el primer paso |
| **Alive2 vs LLVM main** [verificado] | Validación de traducciones a diario; encontró bugs documentados en BugList.md | La sabiduría de la comunidad: ni el optimizer de LLVM está libre de miscompiles; los frontends que emiten UB-lean lo sufren menos |

---

## 6. El pipeline de trabajo recomendado (lo que la literatura ensambla)

```
AST tipado (typechecker)            ← optimizaciones de lenguaje aquí (lección SIL/MIR)
   │  exhaustividad de match, closure env, tipos de tags
   ▼
Emisión IR (C API llvm-c)           ← reglas §2: triple+datalayout, allocas entry,
   │                                   atributos en helpers, guards de §4, pesos fríos
   ▼
LLVMVerifyModule                    ← gate automático, siempre [§ Kaleidoscope ch3]
   │
   ├── dev loop:   lli (ejecutar sin link) [tools verificadas en máquina]
   ├── AOT:        LLVMRunPasses("default<O2>") [+ LICM/LoopUnswitch/IRCE cuando
   │               los perfiles de §2.6 lo justifiquen; sanidad: re-O2]
   ├── objetos:    TargetMachineEmitToFile → link con astra_runtime.o
   └── tests:      FileCheck (shapes de IR) + suite de conformidad (salida) +
                   fuzzing diferencial VM↔C↔zig↔LLVM (ya existe infra de fuzz)
```

Hitos: idénticos a 023 §10 (M0..M4), pero M0 ya emite con triple/datalayout,
allocas-entry y los guards de §4 — no una versión "naive" que haya que
reescribir.

---

## 7. Enmiendas y precisiones a 023 (tabla de correcciones)

| # | 023 decía | Según la investigación (hoy) |
|:-:|:----------|:-----------------------------|
| 1 | Pipeline `-O2` fijo | **Enmienda**: `-O2` como *base* + adiciones para IR con guardas (LICM/LoopUnswitch extra, IRCE) — el doc oficial llama "error muy común" a no personalizar. Medir antes de personalizar (§2.6) |
| 2 | v2 con des-boxing de escalares | Se mantiene, pero el v1 boxed debe **pasar AstraValue como 2×i64 escalares**, no como valor agregado de16 B (§2.3) |
| 3 | "`nsw`/`nuw` solo con prueba" | **Enmienda fuerte**: para la aritmética de Astra (wrap definido) son **ilegales siempre** — no es una cuestión de prudencia, es semántica |
| 4 | (no mencionado) | **Añadido**: intrinsics `with.overflow` innecesarias — PerformanceTips las desaconseja salvo que la spec lo exija; Astra no lo hace |
| 5 | fast-math como optimización futura | **Precisión**: opt-in del lenguaje, y **nunca** en `/` (Astra no es IEEE: divisor 0.0 es error) |
| 6 | longjmp de `?` aceptable en v1 | Se mantierte + reglas del UB manual: helpers `noinline`, jamás `willreturn`, sin landingpad |
| 7 | (no mencionado) | **Añadido**: atributos `nounwind`/`noundef`/etc. en los helpers del runtime — sin ellos el optimizer es ciego a través de las llamadas |

---

## 8. Riesgos que la literatura advierte (recopilación para Astra)

1. **Alta in-grado en el match** (muchas armas) → encadenar comparaciones;
   return unificado OK (§2.1).
2. **allocas fuera del entry block** por emissions condicionales → regla
   dura: todas las allocas al prologue, antes de cualquier call (§2.2).
3. **Helpers sin atributos** = pipeline a medias (§2.1).
4. **UB introducido por flags entusiastas** (`nsw`, `inbounds` sin serlo,
   `fast-math`): con la semántica de Astra ninguno es legal hoy — política:
   flags = revisión explícita, no por defecto (§3, §4).
5. **Divergencia VM/C/LLVM**: la suite de conformidad + fuzz diferencial ya
   son el gate (patrón del repo); añadir `LLVMVerifyModule` y tests sin UB
   inmediato para Alive2 (§3).
6. **Churn de la C API** entre majors: rango 19..23 + CI en dos extremos
   (023 §8, precedente Odin).
7. **Over-fitting de passes**: el test de sanidad "re-ejecutar -O2" y
   optimization remarks (`Remarks.html`, `llvm-opt-report`) diagnostican
   pipelines que dejan dinero en la mesa (§2.6).

---

## 9. Referencias

**Verificadas hoy (descargadas)**:
- <https://llvm.org/docs/Frontend/PerformanceTips.html>
- <https://llvm.org/docs/UndefinedBehavior.html>
- <https://llvm.org/docs/tutorial/> (Kaleidoscope + Building a JIT)
- <https://llvm.org/docs/GettingStarted.html>
- <https://github.com/AliveToolkit/alive2> (Alive2; paper PLDI 2021:
  <https://web.ist.utl.pt/nuno.lopes/pubs/alive2-pldi21.pdf>)

**Citadas (sin verificación directa hoy; nombradas por título/sitio)**:
- Lattner & Adve, CGO 2004 — *LLVM: A Compilation Framework for Lifelong
  Program Analysis & Transformation*
- Lattner et al., 2020 — *MLIR: A Compiler Infrastructure for the End of
  Moore's Law* (<https://mlir.llvm.org>)
- Cummins et al., NeurIPS 2020 D&B — *CompilerGym*
  (<https://github.com/facebookresearch/CompilerGym>)
- Docs LLVM: ExceptionHandling, GetElementPtr ("The Often Misunderstood GEP"),
  SourceLevelDebugging, NewPassManager, OpaquePointers, Remarks, LangRef
- <https://cranelift.dev/>, <https://odin-lang.org/docs/install/> (verificados
  en la sesión 023), llvmlite binding examples (verificado en 023)

**Repo**:
- `Documentacion/07_investigacion/023_LLVM_backend_investigacion.md` — opciones de
  integración y verificación empírica de la máquina (enmiendas en §7)
- `seed/src/vm.c`, `seed/src/codegen_runtime.h` — semántica verificada de §4
- `seed/src/codegen.c` — referencia semántica del codegen (patrón a preservar)
