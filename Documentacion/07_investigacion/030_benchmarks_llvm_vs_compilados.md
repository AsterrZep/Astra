# 030 — Benchmarks de Astra (ruta LLVM) vs Rust, Go, C y Zig

> **Alcance**: medición empírica. Ningún código de producción se toca en este
> documento. Fecha: 2026-10-27. **Todo lo marcado [verificado] se ejecutó en
> esta máquina** durante la campaña; los programas y scripts están en
> `030_benchmarks_suite/` (mismo directorio) y los crudos en
> `results.json` / `results_extra.json`.

---

## 0. Resumen ejecutivo

1. **Estado de Astra medido («el momento»)**: commit `6e0954d` (2026-10-27),
   subconjunto **Astra-0**, backend **LLVM** (Fase LLVM M0–M6.c cerrados,
   paridad 159/159 contra el VM), suite seed 260 tests. **Estos números son
   de la ruta LLVM (`--emit-obj` + runtime), NO del VM.**
2. **Astra-LLVM compite en su liga**: arranque **0,8 ms** (= C, = Zig,
   < Rust), binarios de **23 KB**, pico de memoria de **1,2 MB** en el test de
   2 M allocaciones (**igual que C, mejor que Rust/Go**), y en CPU fib(30)
   queda a **8–9× de C -O2** — primera iteración de un backend sin escape
   analysis ni inlining agresivo.
3. **Los VMs (seed y zig) son otra historia — y es la que hay que arreglar**:
   no liberan **nada** (arena vitalicio): **400 MB y 712 MB** frente a
   **≤2 MB** de las rutas nativas en el mismo test, y 320–354 MB en el test de
   strings donde el nativo se mantiene en ~1,4 MB. Es la **deuda de la
   decisión #3** (`research/027` Rec3, ya cerrada como *divergencia
   documentada + gate de RSS*): **la liberación de memoria en los VMs queda
   como trabajo de Fase 2 (opción 3B)** — hoy no existe.
4. **Metodología honesta**: mínimos de N corridas (máquina compartida,
   loadavg 0,5→1,5), RSS por muestreo de `VmHWM` (el `ru_maxrss` de
   `wait4` hereda el piso del padre — descartado, §4.3), salidas verificadas
   en cada corrida, versiones y flags exactos listados.

---

## 1. Momento de Astra y versiones de los lenguajes

### 1.1 Astra [verificado]

| Campo | Valor |
|:------|:------|
| Commit | `6e0954d` (2026-10-27) — «Documentacion/ en carpetas numeradas (00–08) + auditoría» |
| Estado | Fase 1 (seed C) completa · Fase 2 (zig) en progreso · **Fase LLVM M0–M6.c cerrada** |
| Backend medido | **LLVM nativo**: `astra-zig --emit-obj [--opt-level=2]` + link del runtime TU (receta idéntica a `zig/tests/llvm_parity.sh`) |
| Subconjunto | Astra-0 (scalars, arrays, strings, funciones, closures, match, Option/Result, generics monomorfizados…; ver AGENTS.md) |
| Gates en verde ese día | `make test` 260/0 · `zig build test` 73/73 · `dump_parity` 147/0 · `llvm_parity` 159/159 |
| **NO medido aquí** | Los VMs (seed/zig) aparecen solo como filas de referencia: **son herramientas de desarrollo, aún sin liberación de memoria** (§5.3) |

### 1.2 Lenguajes de referencia [verificado]

| Lenguaje | Versión | Flags |
|:---------|:--------|:------|
| Rust | rustc 1.99.1 (58cf8f9c3, 2026-10-13) | `-O` (= opt-level 3) y `-C opt-level=0` (coste real sin elisión) |
| Go | go1.24.4 linux/amd64 | `go build` (flags por defecto) |
| C | gcc (Debian 14.2.0-19) 14.2.0 | `-O2 -std=c11` |
| Zig | 0.16.0 | `zig build-exe -OReleaseFast` |
| (build del seed) | Debian clang 19.1.7 | `-g -O0` (Makefile dev) |

### 1.3 Máquina [verificado]

Debian GNU/Linux 13 (trixie), kernel 6.6.147 · **AMD Ryzen 3 3250C** (4
CPUs, 15 W móvil) · **2,7 GB RAM** · loadavg registrado **0,53 → 1,46**
(había trabajo concurrente; por eso se reportan **mínimos**, no medias).

---

## 2. Tests (equivalentes uno a uno en todos los lenguajes)

| ID | Test | Qué mide | Salida verificada |
|:---|:-----|:---------|:------------------|
| **B1** | `fib30` | Fibonacci naive recursivo — CPU/branch pura, sin heap | `832040` |
| **B2** | `alloc2m` | 2 M arreglos de 8 elems creados y descartados — throughput de alloc+free y pico de memoria | `2000000` |
| **B3** | `str25k` | 25 000 concatenaciones `s = s + "x"` (**O(n²) deliberado e idéntico en todos**) — memoria acumulativa vs reclamación | 25 000 `x` |
| **B4** | `startup` | Programa vacío — coste de arranque | (vacío, rc=0) |

Equivalencias y matizes de la suite [verificado]:

- **Rust `-O` elimina B2** (const-fold: 8 ms = 3 ns/alloc, imposible) y
  **transforma B3** (1,8 ms) → por eso se reportan también las filas
  **Rust -O0** con el trabajo real.
- **Go acelera B2 con escape analysis** (alloc en stack/tiny-alloc, 12 ms) —
  legítimo, pero no es «malloc+free»; anotado.
- El **C de B3** se reescribió para ser O(n²) como el resto (la primera
  versión con `realloc` amortizado daba ventaja injusta: 3,1 ms → 18,5 ms).
- Astra empaqueta cada elemento en un `Value` de **16 B** (boxed); Rust/Go/C
  usan `i64` crudo (8 B) — el pie por objeto de Astra es ~2× y está incluido
  en sus números, sin recortar.

---

## 3. Resultados

### 3.1 B1 — fib(30) naive: tiempo (mínimo de 5) [verificado]

| Ruta | Tiempo | vs C -O2 |
|:-----|-------:|---------:|
| **C gcc -O2** | **4,9 ms** | 1,0× |
| Rust rustc -O | 7,0 ms | 1,4× |
| Zig ReleaseFast | 7,2 ms | 1,5× |
| Go 1.24 | 10,7 ms | 2,2× |
| **Astra LLVM -O2** | **41,2 ms** | **8,4×** |
| **Astra LLVM -O0** | **44,6 ms** | **9,1×** |
| Astra zig-VM (referencia) | 3,79 s | ~770× |
| Astra seed-VM (referencia) | 5,34 s | ~1 090× |

*Nota*: el RSS de B1 no es significativo (todos por debajo del piso de
medición, §4.3); el valor de B1 es la CPU. La brecha Astra↔C (8–9×) es el
coste de un backend en primera iteración sobre Values boxed, sin escape
analysis ni inlining de la llamada recursiva; `-O2` ya mueve la aguja
(44,6→41,2 ms).

### 3.2 B2 — 2 M allocaciones: tiempo + pico real de memoria [verificado]

| Ruta | Tiempo | Pico RSS | Modelo de memoria |
|:-----|-------:|---------:|:------------------|
| C gcc -O2 (`malloc/free`) | 34–39 ms | **1,2 MB** | free inmediato |
| Zig smp_allocator | 74 ms | **0,5 MB** | free inmediato |
| Rust -O0 (trabajo real) | 175 ms | **1,9 MB** | drop inmediato |
| Rust -O (elidido por LLVM) | 8 ms | 1,9 MB | *el optimizer elimina el test* |
| Go (escape analysis) | 12 ms | 1,9 MB | stack/tiny alloc |
| **Astra LLVM -O0** | **181 ms** | **1,2 MB** | **ARC: rc→0 → free** |
| **Astra LLVM -O2** | **180 ms** | **1,2 MB** | ídem |
| Astra seed-VM | 10,3 s | **400 MB** | arena: **nunca libera** |
| Astra zig-VM | 8,4 s | **712 MB** | arena: **nunca libera** |

**Lectura**: el par **Astra -O0 181 ms / Rust -O0 175 ms** es la
comparación limpia de «allocator + reclamación en caliente»: **misma liga**
(el coste extra de Astra es el rc por objeto y el `Value` de 16 B). El pico
de **1,2 MB iguala al C** y gana a Rust/Go. Las filas de VM muestran el
problema real: **200–600× más memoria** que cualquier nativo por no tener
liberación.

### 3.3 B3 — 25 000 concatenaciones O(n²): tiempo + pico [verificado]

| Ruta | Tiempo | Pico RSS | Comportamiento |
|:-----|-------:|---------:|:---------------|
| Rust -O0 | 5,6 ms | 2,1 MB | free inmediato |
| Zig | 15,2 ms | **0,6 MB** | free inmediato |
| C gcc -O2 | 18,5 ms | 1,3 MB | free inmediato |
| **Astra LLVM -O0** | **29,7 ms** | **1,4 MB** | **ARC libera el string viejo → plano** |
| Rust -O (transformado) | 1,8 ms | ~2 MB | *el optimizer comprime el patrón* |
| Go | 237 ms | 20 MB | GC: lento y con techo creciente |
| Astra seed-VM | 332 ms | **320 MB** | arena: **acumula los 25 000 intermedios** |
| Astra zig-VM | 396 ms | **354 MB** | arena: ídem |

**Lectura**: es el test que mejor separa los modelos. Astra-LLVM se mantiene
en **1,4 MB constantes** (igual que los nativos con free inmediato) mientras
los VMs **acumulan cada string intermedio** (320–354 MB para un resultado de
25 KB). Go muestra el coste del GC (0,24 s y 20 MB para el mismo trabajo).

### 3.4 B4 — arranque: mínimo/mediana de 20 corridas [verificado]

| Ruta | Mín | Mediana |
|:-----|----:|--------:|
| Zig | 0,7 ms | 1,1 ms |
| **Astra LLVM** | **0,8 ms** | **1,1 ms** |
| C | 0,8 ms | 1,2 ms |
| Rust | 1,2 ms | 1,6 ms |
| Go | 1,7 ms | 2,8 ms |
| Astra seed-VM (compila+corre) | 1,4 ms | 2,0 ms |
| Astra zig-VM (compila+corre) | 64,8 ms | 69,0 ms |

**Lectura**: el binario nativo de Astra arranca **al nivel de C/Zig** (≤1 ms)
— muy por debajo del objetivo de «arranque < 10 ms» del pitch. El zig-VM
cobra ~65 ms de compilación en frío (esperado: compila en cada arranque).

### 3.5 Tamaño de binario (programa `startup`) [verificado]

| C | **Astra LLVM** | Go | Zig | Rust |
|--:|---------------:|---:|----:|-----:|
| 15,8 KB | **23,3 KB** | 1,56 MB | 0,95 MB | 4,53 MB |

Los binarios de Astra son pequeños porque linkan solo el runtime TU contra
libc (sin stdlib propia embebida). *Rango total de Astra: 23,2–23,3 KB en
los 4 tests.*

---

## 4. Metodología

### 4.1 Qué se midió y cómo [verificado]

- **Tiempo de pared**: `time.perf_counter()` alrededor de `os.wait4()` del
  hijo; **N corridas por celda** (B1: 5, B2/B3: 3, B4: 20; VMs reducidos) y
  se reporta el **mínimo** (menos sensible al ruido de una máquina
  compartida; las medianas y máximos están en `results.json`).
- **Memoria pico**: muestreo de **`VmHWM`** en `/proc/<pid>/status` cada
  2 ms durante la corrida (máximo observado).
- **Corrección**: la salida de **cada** corrida se compara contra el valor
  esperado (`832040`, `2000000`, 25 000 `x`, vacío) — una celda con salida
  mala se marca `error`, no se promedia.
- **Build**: Astra = `--emit-obj` (+ `--opt-level=2`) y link
  `cc prog.o runtime.o -lm` con `runtime.o = cc -c -O2 -std=c11 -I seed/src
  zig/src/llvm/runtime/astra_runtime_llvm.c` (la receta de `llvm_parity.sh`);
  resto de flags en §1.2.

### 4.2 Reproducibilidad

```bash
cd Documentacion/07_investigacion/030_benchmarks_suite
# 1) compilar (ver build_all.sh)  2) python3 run_bench.py  3) python3 measure_extra.py
```

La suite fuente está íntegra en `030_benchmarks_suite/` (20 fuentes + 2
scripts + `results*.json` crudos).

### 4.3 Corrección de metodología (lecciones de esta campaña)

1. **`ru_maxrss` de `wait4` NO sirve aquí**: el hijo hereda el piso de RSS
   del proceso padre en el fork → todas las celdas nativas aparecían iguales
   (12 800 KB). Descartado a favor de `VmHWM` muestreado (que tras `exec`
   refleja el binario real: 1 200 KB vs 409 588 KB, coherente con las
   mediciones previas de `research/027` §3.1).
2. **Optimizadores que se comen el benchmark**: Rust -O const-foldó B2 y
   transformó B3 → filas -O0 añadidas. Un benchmark que el compilador puede
   eliminar no mide el runtime.
3. **Equivalencia semántica estricta**: la primera versión de B3 en C era
   O(n) (realloc amortizado) y daba 6× de ventaja injusta → reescrita O(n²).

### 4.4 Limitaciones

- **Una máquina, sin aislamiento de carga** (loadavg 0,5→1,5) y CPU móvil de
  15 W: los **rangos** son más fiables que los absolutos; las **razones**
  (×C) son lo comparable.
- Astra-0 es un subconjunto: sin escape analysis, sin inlining agresivo,
  `Value` boxed de 16 B. Las brechas de CPU (8–9× en B1) son el techo del
  backend **actual**, no del diseño (el des-boxing progresivo está en el
  plan M4/M6 — ver `PHASE_LLVM_PROGRESS.md`).
- Los tests son micro-benchmarks sintéticos; no representan carga de
  aplicación real (sin I/O, sin concurrencia — Astra-0 aún no tiene fibras).

---

## 5. Veredicto y pendientes

### 5.1 Lo que estos números dicen del lenguaje hoy

| Afirmación | Veredicto con datos |
|:-----------|:--------------------|
| «Ruta LLVM con rendimiento nativo» | **Sí**: arranque 0,8 ms, binarios 23 KB, memoria 1,2 MB, fib 8× de C (brecha cerrable con optimizador) |
| «Sin pausas de GC» (en la ruta LLVM) | **Sí**: no hay GC — ARC con free inmediato, pico plano en B2/B3 |
| «Los VMs son de desarrollo» | **Sí, pero con deuda explícita**: 400–712 MB donde el nativo usa ≤2 MB — **la liberación de memoria en los VMs está por crear** (divergencia aceptada y gateada en `research/027` Rec3; ARC en los VMs = opción 3B, Fase 2) |
| «Arranque < 10 ms» | **Sí** (0,8 ms nativo; 1,4 ms seed-VM; el zig-VM cuesta 65 ms de compilación en frío) |

### 5.2 Acciones que surgen de la medición

1. **Gate de techo de RSS** (ya propuesto en `research/027` Rec3A): fijar
   `maxRSS < 128 MB` para B2 en la ruta LLVM (medido: 1,2 MB — techo muy
   holgado) y documentar «arena lineal, sin límite» para los VMs hasta que
   exista la liberación.
2. **Opción 3B (memoria en los VMs)**: la decisión de corto plazo ya está
   tomada (divergencia documentada + gate de RSS, `research/027` Rec3); estos
   números son el argumento medido para **programar la 3B** (ARC en `vm.c`/
   `vm.zig`/`codegen_runtime.h`) como Fase 2 — su coste está en
   `research/027` §3.2.
3. **Cerrar la brecha de CPU** (8–9× → más cerca de 2–3×): des-boxing de
   enteros en SSA (plan M6/M4), inlining de llamadas — hitos ya
   esbozados en `PHASE_LLVM_PROGRESS.md`, no decisiones nuevas.
4. **Esta campaña es una foto, no un gate**: para que no se degrade, el
   paso natural es **extender `zig/tests/llvm_bench.sh`** (ya existe —
   publica timings VM/C/LLVM) con estos 4 tests y umbrales, del mismo modo
   que `llvm_parity.sh` gatea la corrección.

---

## 6. Reproducción exacta

```bash
# Suite y resultados crudos
ls Documentacion/07_investigacion/030_benchmarks_suite/
cd Documentacion/07_investigacion/030_benchmarks_suite
bash build_all.sh          # compila los 20 binarios (Astra/Rust/Go/C/Zig)
python3 run_bench.py       # tiempo + ru_maxrss (results.json)
python3 measure_extra.py   # tiempo + VmHWM real (results_extra.json)
```

Versiones, flags y máquina: §1 de este informe (todo [verificado] por
ejecución el 2026-10-27).
