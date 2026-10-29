# 039 — Modelos de memoria y ownership: GC, RC, arenas y ownership en compile-time — qué usan y qué le conviene a Astra

> **Alcance**: dossier sobre los modelos de gestión de memoria — tracing
> GC, reference counting, ownership/borrowing, arenas/regiones y manejo
> manual — en Java, Go, CPython, PHP, Ruby, Swift, Lua, Rust y C, con
> costes medidos (pausas, CPU, bytes/objeto, herramientas) y el encaje con
> el rc de Astra (M4.e) y la decisión abierta **Rec3** de `research/027`.
> **No cambia ningún comportamiento.** Fecha: **2026-10-29**.
> `[verificado]` = ejecutado o leído en esta sesión (Debian, HEAD
> `fece1ab`, worktree `Astra-wt/int-types`); `[citado]` = fuente externa
> con URL en §12; **[no verificado]** = marcado donde no se alcanzó la
> fuente primaria.

---

## §0 — TL;DR

1. **Cinco familias**: tracing GC (Java/Go/.NET), RC con ciclo-colector
   (CPython/PHP), ARC sin ciclo-colector (Swift/Rust-`Rc`), ownership en
   compile-time (Rust) y arenas/manuel (Zig, C, el seed de Astra). La
   elección se reduce a 4 preguntas: **¿quién libera?, ¿cuándo?, ¿qué pasa
   con los ciclos?, ¿cuánto cuesta por objeto?**
2. **Tracing moderno es casi «sin pausas»**: ZGC generacional (JEP 439)
   promete pausas **<1 ms** con heaps de muchos TB y en Cassandra logró
   **¼ de heap y 4× throughput** `[citado]`; el coste se paga en CPU
   (el pacer de Go modeliza `CPU = fijo + coste/byte × live heap`, con
   techo del **50 % de CPU** para GC bajo `GOMEMLIMIT`) y en complejidad
   (tri-color + barreras + remembered sets = JEP «esfuerzo XL»).
3. **RC es determinista pero tiene dos deudas**: los **ciclos** (todos
   los rc los necesitan detectar o prohibir — CPython con umbral
   `(2000,10,10)` medido localmente, PHP con trial-deletion de
   Bacon–Rajan y buffer de 10k raíces) y el **coste por par**
   (retain/release ~1-5 ns **[no verificado en primaria]**; en la
   práctica Swift lo mitiga eliminando pares redundantes).
4. **Astra ya tiene la divergencia medida**: con 2 M de arrays, el seed
   VM llega a **404 MB** y el zig VM a **721 MB** (arena, sin free), el C
   backend a **489 MB** (malloc sin free, `refcount` nunca decrementado),
   y **el backend LLVM se mantiene acotado en ~77 MB** (ARC real con
   cabecera `{int32 rc; int32 kind}`) `[citado: research/027 §3.1]`.
   Mis propios probes lo confirman de forma independiente: RSS **lineal**
   con arrays (1 M → 135 MB, 2 M → 268 MB) y **plano** con strings
   (11.5 MB = baseline) `[verificado §10]`.
5. **Recomendación para Rec3**: gate de RSS **por backend** (la opción
   3A ya costeada como BAJO), rc puro como contrato (precedente Swift),
   ciclo-colector **opcional y presupuestado** como Fase 2 (precedente
   CPython/PHP — la cabecera `{rc,kind}` de Astra ya lleva el `kind` que
   un traverse necesitaría), arenas sólo en el compilador (invariante 5
   de AGENTS.md) y **no** tracing GC (desproporcionado frente al objetivo
   «sin pausas de tracing-GC»). Todo cambio = su `DEC-NNN`.

---

## §1 — El espacio de soluciones

| Familia | ¿Quién libera? | Ciclos | Pausas | Overhead/objeto | Ejemplos |
|:--------|:---------------|:-------|:-------|:----------------|:---------|
| **Tracing GC** | recolector (marca/evacúa) | los resuelve | STW o <1 ms (concurrente) | barreras + heap | Java, Go, .NET, Lua |
| **RC + ciclo-colector** | refcount + detector periódico | detecta | ninguna (o la del detector) | 8-16 B + 2 ops | CPython, PHP |
| **ARC sin detector** | refcount en scope | **no** — bug del programador (`weak`) | ninguna | 8 B + 2 ops | Swift, ObjC, Rust `Rc` |
| **Ownership compile-time** | el ámbito (stack/move) | imposible por tipos | ninguna | **0 en runtime** | Rust |
| **Arena/bump + manual** | reset masivo o `free` | N/A (tipos acíclicos) | ninguna (reset O(1)) | 0-8 B | Zig, C, game engines, **seed de Astra** |

## §2 — Tracing GC: el modelo caro de hacer bien

- **ZGC generacional (JEP 439, JDK 21)** `[citado]`: pausas **≤1 ms**,
  heaps de cientos de MB a **muchos TB**, sin configuración; usa
  *colored pointers* + *load/store barriers* + remembered sets con
  bitmaps dobles (en vez de card table) + SATB. Cassandra: **¼ del heap
  y 4× el throughput** vs no-generacional. ZGC es **O(1) en pausas desde
  JDK 16** (no crecen con heap/live-set/root-set; rara vez >250 µs entre
  8 MB y 16 TB) `[citado: malloc.se, inside.java]`.
- **Shenandoah (JEP 189)** `[citado]`: pausas independientes del tamaño
  («200 MB o 200 GB») — a cambio **añade un puntero de indirección a
  cada objeto** (el coste estructural de mover concurrente).
- **Go** `[citado: gc-guide]`: mark-sweep **concurrente y no-moving**;
  el pacer modeliza `CPU = coste_fijo + coste/byte × live_heap`; el
  **25 %** de CPU va a *assist* (mark) y `GOMEMLIMIT` pone techo al
  **~50 % de CPU para GC** en la ventana `2×GOMAXPROCS` s; `GOGC`
  duplicar heap ≈ **mitad de CPU** de GC. El pacer fue rediseñado en
  2019 por problemas de estabilidad `[citado: proposal/44167]`.
- **G1**: sus pausas «van de milisegundos a segundos» (JEP 439);
  objetivo por defecto 200 ms **[no verificado en primaria]**.
- **Fragmentación**: los no-moving (CMS) «gestionan peor el espacio
  libre»; los moving la eliminan a cambio de prohibir punteros crudos
  `[citado: JEP 189, Wikipedia]`.
- **El resumen**: tracing = sin ciclos, sin leaks del programador, con
  un proyecto de backend completo detrás (tri-color incremental,
  barreras, pacer) — **«esfuerzo XL»**, dicho en el propio JEP 439.

## §3 — Reference counting: determinista con dos deudas

- **CPython** `[citado: docs gc + medición local]`: rc en todo objeto +
  **colector generacional cíclico**. Umbral **medido en esta máquina**
  (Python 3.13.5): `gc.get_threshold() == (2000, 10, 10)` — el clásico
  `(700,10,10)` de la documentación histórica sigue citado en terceros.
  Recolecta gen 0 cuando `allocs − deallocs > threshold0`; gen 1 cada 10
  exámenes; gen 2 por ratio. **3.14** añadió recolección incremental de
  gen 1; **3.15** expondrá `duration`/`candidates` en stats (plantilla
  para gatear el coste). Free-threading (3.13+) introduce rc
  *biased/deferido* `[citado: vstinner]`.
- **PHP** `[citado: php.net gc]`: rc (zval) + desde 5.3 **trial deletion
  de Bacon–Rajan** (paper *Concurrent Cycle Collection in RC Systems*):
  root buffer «púrpura» de **10 000 raíces**; al llenarse, DFS de
  decrecimiento (gris) → DFS de re-conteo (blanco si rc=0) → libera
  blancos; desactivable por latencia (`zend.enable_gc`).
- **Ruby**: **no es rc** — es mark&sweep: **RGenGC** generacional (2.1,
  2013), **incremental** (2.2, 2014) y opción `--with-jemalloc`
  `[citado: ruby-lang news]` («deferred sweeping» **[no verificado]**).
- **Swift/ObjC ARC** `[citado: Clang ARC]`: el compilador inserta
  retain/release; **no** hace retain/release sólo por *usar* un puntero
  como operando dentro de una expresión y elimina pares redundantes; el
  ARC puro de Swift **no usa autorelease pools** (sólo compatibilidad
  ObjC) `[citado: forums.swift.org]`. Coste ~1-5 ns/par **[no
  verificado en primaria — orden de magnitud]**.
- **Los ciclos — la deuda de todo rc**:
  - **Detectan**: CPython (§3 arriba), PHP (trial deletion).
  - **Dejan al usuario**: Swift (`weak`/`unowned`) y Rust (`Weak`/`Rc` —
    los ciclos se fuga y la doc lo dice); Astra hoy es de este bando
    (§10).
  - **Híbrido confirmado**: CPython y PHP = **rc + tracing del ciclo**;
    Swift = ARC + `weak` manual; .NET = tracing generacional puro
    **[no verificado en primaria aquí]**; **Lua = tracing incremental
    puro** (manual §2.10, sin rc) `[citado: lua.org]`.

## §4 — RC vs tracing: el trade-off exacto

| Eje | RC | Tracing |
|:----|:---|:--------|
| **Latencia** | libera **determinista** al llegar a 0 — pero «pausas arbitrarias en momentos fijos» (dealloc en cascada) `[citado: Wikipedia]` | no determinista; con concurrente, <1 ms |
| **Coste CPU** | par inc/dec por copia | barreras de escritura + mark |
| **Memoria** | retiene lo que el programador olvida (ciclos) | trade-off cuantificado: `GOGC` dobla heap ≈ mitad CPU |
| **Implementación** | sencilla + ciclo-colector incremental si no se aceptan fugas (buffer de raíces + DFS doble) | tri-colour + invariantes + barreras (SATB, remembered sets) |
| **Leaks** | el programador los ve (rc nunca baja) | el recolector los cobra en heap |

## §5 — Ownership en compile-time: Rust y los clásicos

- **Rust Book ch. 4** `[citado]`: el ownership «permite las garantías de
  seguridad de memoria **sin garbage collector**»; borrowing + lifetimes
  la disciplina; `Rc`/`Arc` el escape para sharing (con su rc y sus
  ciclos). **Coste runtime: 0** en lo local — el único modelo de la tabla
  §1 que no paga ni un byte por objeto.
- **Clásicos académicos** (Clean *uniqueness types*, Linear Haskell,
  Plaid/ownership types, regiones de Tofte–Talpin) **[no verificados
  online en esta pasada — citar como literatura]**: la línea de
  investigación que demostró que la seguridad de memoria puede estar en
  el tipo antes que en el runtime.

## §6 — Arenas y allocadores: el bando de C/Zig/Astra-compilador

- **Arena bump** (el seed de Astra: invariante 5 de AGENTS.md — «arena
  only allocation, cero `free`», `vm_destroy` no-op; el zig VM usa
  `std.heap.ArenaAllocator` con `defer arena.deinit()`): alloc **O(1)**,
  liberación masiva O(1), pero **si no hay reset, crece linealmente**
  (medido en §10: 268 MB con 2 M de arrays). El reset *global* está
  descartado para datos de usuario: **3C INSEGURA** sin análisis de
  escape (`research/027` §3.2).
- **Zig** `[citado: langref]`: `ArenaAllocator` sobre un backing GPA con
  reset O(1); la distinción GPA (libre granular + detección de fugas) vs
  arena (liberación masiva) es estándar en game engines (*frame
  allocators*).
- **mimalloc** `[citado: README oficial]`: **~0,2 % de overhead de
  metadatos**, listas libres *sharded* por página de 64 KiB con free
  cross-thread vía un solo CAS, purga eager al OS, modo seguro con
  **~10 %** de penalización; en benchmarks públicos gana a
  jemalloc/tcmalloc (+13 % sobre tcmalloc en *leanN*, >2,5× más rápido
  que jemalloc en *sh8bench*). Su modo **first-class heaps** (heap
  destruible de una vez) es el precedente industrial de «arena moderna».
- jemalloc/tcmalloc y fragmentación: cifras **[no verificadas]**; papers
  Mesh/Hoard como referencias fragmentation-aware.

## §7 — Herramientas: el coste de vigilar a C

| Herramienta | Coste | Fuente |
|:------------|:------|:-------|
| **ASan** | ~**2×** CPU, hasta **3×** stack, +memoria (más cuanto más pequeñas las allocs), 16+ TB de VA | `[citado: Clang]` |
| **TSan** | **5-15× CPU, 5-10× memoria** (5× + 1 MB/hilo) | `[citado: Clang]` |
| **Valgrind** | Callgrind ~5× según FAQ; Memcheck **10-50×** (clásico, **[no verificado en la FAQ alcanzada]**) | `[citado: valgrind.org]` |
| Electric Fence (guard-page por alloc) | caro en memoria **[no verificado]** | — |

Por qué C sobrevive: coste cero en runtime + un ecosistema de
herramientas que, corridas en CI (como hace ya `llvm_sanitize.sh` con
ASan/LSan), convierten los bugs de memoria en rojos de pipeline.

## §8 — Cifras de bytes/objeto (medidas y de referencia)

- **CPython 3.13.5, `sys.getsizeof` medido localmente** `[verificado]`:
  `int(0)` = **28 B** (cabecera `PyObject` = 16 B: `ob_refcnt`+`ob_type`),
  `float` = 24 B, `str(1)` = 42 B, `list()` = 56 B, `tuple()` = 40 B,
  `dict()` = 64 B, instancia vacía = 48 B.
- **Astra (LLVM)**: cabecera = **8 B** (`int32 rc` + `int32 kind`,
  `astra_runtime_llvm.c:43`) — la misma ordén de CPython pero con `kind`
  explícito `[citado: research/027 §3.1]`.
- Cabecera Java 12-16 B **[no verificado — usar JOL]**; overhead de
  tracing 5-20 % CPU **[rango de literatura, no verificado en primaria]**
  (la guía de Go ilustra escenarios 5-10 % con su propio modelo, §2).

## §9 — El espectro de opciones realistas (con precedentes)

| Opción | Precedente verificado | Pros | Contras |
|:-------|:----------------------|:-----|:--------|
| **1. RC puro** (status quo LLVM) | Swift/ObjC ARC | determinista, sin pausas, **ya implementado y acotado (77 MB)** | 8 B/objeto; ciclos se fugan (closure↔env) |
| **2. RC + ciclo-colector opcional** | CPython (root buffer + gen, umbral medido) · PHP (Bacon–Rajan, buffer 10k, desactivable) | resuelve ciclos con presupuesto; `kind` de la cabecera ya sirve de traverse | complejidad en el runtime; pausa del detector |
| **3. Arenas por ciclo de vida** | el propio seed · mimalloc *first-class heaps* | O(1), liberación masiva | sólo acíclicos + escape acotado (3C descartado) |
| **4. GC tracing opcional** | ZGC/Shenandoah/Go | sin leaks de usuario | «esfuerzo XL»; **contradice** «sin tracing-GC pauses» de AGENTS.md |
| **5. Ownership en tipos** | Rust | 0 en runtime | exige el checker que Astra no tiene (y no quiere) |

## §10 — Astra: estado medido

### 10.1 La tabla de `research/027` §3.1 (loop_alloc, 2 M arrays de 8 elems)

| Ruta | maxRSS 2 M | Mecanismo |
|:-----|-----------:|:---------|
| seed VM | **404 764 KB** (lineal: 1 M → 201 MB) | arena bump en `vm.c`, 0 `free`, `vm_destroy` no-op |
| zig VM | **721 916 KB** | arena de programa |
| C backend | **489 220 KB** | `malloc` sin `free`; `refcount` nunca decrementado |
| **LLVM `--jit`** | **76 896 KB** (acotado; 4 M → 76,9 MB) | **ARC real**, cabecera `{int32 rc; int32 kind}`; libera todo salvo ciclos |

### 10.2 Probes independientes `[verificado — esta sesión]`

| Probe | maxRSS | Lectura |
|:------|-------:|:--------|
| bucle vacío 1 M (baseline) | **11,5 MB** | referencia |
| 1 M arrays de 5 elems en scope | **135 MB** | crece |
| 2 M arrays de 5 elems | **268 MB** | **lineal ⇒ no se liberan** |
| 300 k concats ` "hola"+"mundo "` | **11,5 MB** (= baseline) | plano |
| 300 k strings **únicos** (`"item-"+to_string(i)`) | **11,5 MB** (= baseline) | **los strings sí se liberan/reusan** — el hueco es el camino de los arrays |
| `to_string(42)` | `42` | existe (028 PR2) |

Coherencia: mis 135/268 MB (arrays de 5 elems) escalan con los 404 MB
(arrays de 8) de `research/027` — mismo patrón lineal, tamaños distintos.
**El contraste arrays-vs-strings es nuevo**: el VM no libera arrays por
scope pero el camino de strings (internados) se mantiene plano — localiza
el hueco en el handler de arrays, no en «el VM no libera nada».

### 10.3 Gates existentes

- **LSan** en `llvm_sanitize.sh` paso 5 (`detect_leaks=1` sobre
  `leaks.astra`) — ya gatea fugas del backend LLVM.
- **Rec3** (`research/027` §3): opción **3A** (gate RSS + documentar
  divergencia) costeada **BAJO**; **3B** (portar ARC a las 3 rutas
  restantes) **ALTO**; **3C** (arena con reset) **INSEGURA**. La opción
  1D (checked-overflow) y ésta son las dos abiertas del informe.

## §11 — Recomendación para Rec3 (condicionada a `DEC-NNN`)

1. **Gate RSS por backend, no global** (opción 3A, ya costeada BAJO):
   - LLVM: `maxRSS < 128 MB` (medido 77 MB) — el único que puede
     prometerlo hoy;
   - seed/zig/C: **cifra medida + documentada** como divergencia
     (404/721/489 MB), no gate falsamente rojo — mismo criterio de
     «divergencia medida, no garantizada» que ya usa Rec3 para la
     aritmética C.
   - Mi probe de strings (plano) sugiere un **segundo gate barato**:
     «300 k allocs de string ⇒ RSS ≤ 2× baseline» — pasa hoy y captura
     regresiones del camino de strings.
2. **RC puro como contrato, ciclos documentados como límite** (bando
   Swift): el ciclo closure→env→closure ya está documentado; la doc de
   Astra debe decir «los ciclos son bug del programador — `weak`
   explícito cuando exista» **[si se elige esta vía]**.
3. **Fase 2: ciclo-colector opcional y presupuestado** (si los ciclos
   duelen): precedente CPython/PHP — buffer de raíces + trial deletion
   incremental, ejecutado sólo al llenarse o por llamada explícita
   (`gc_collect()` estilo PHP). La cabecera `{rc,kind}` **ya lleva el
   `kind`** que un traverse necesitaría para enumerar referencias por
   tipo — el diseño lo anticipa. Coste: recorrer campos por tipo (los
   tipos de Astra son conocidos en compile-time: se puede generar el
   traverse).
4. **No GC tracing** (opción 4): el esfuerzo (ZGC: JEP «XL») y el
   propósito del lenguaje («no tracing-GC pauses») lo descartan; la
   literatura no conoce ningún lenguaje pequeño moderno que lo haya
   añadido tarde barato.
5. **Arenas donde ya están**: el compilador (invariante 5) y — si se
   quiere — allocators de frame para hot paths tipo game engine
   (mimalloc *first-class heaps* como precedente), nunca para el grafo
   de datos de usuario con aliasing (3C).
6. **Medir como CPython**: publicar stats del rc/detector
   (`duration`/`candidates` al estilo 3.15) si llega el colector — el
   gate necesita visibilidad, no sólo un número de RSS.

## §12 — Fuentes

**Primarias / oficiales**:
- OpenJDK: JEP 439 (ZGC generacional) https://openjdk.org/jeps/439 ·
  JEP 376 https://openjdk.org/jeps/376 · JEP 189 (Shenandoah)
  https://openjdk.org/jeps/189 · malloc.se (ZGC O(1))
  https://malloc.se/blog/zgc-jdk16
- Go GC guide https://tip.golang.org/doc/gc-guide · pacer redesign
  https://go.googlesource.com/proposal/+/master/design/44167-gc-pacer-redesign.md
- Python gc https://docs.python.org/3/library/gc.html (**umbral
  (2000,10,10) medido localmente en 3.13.5**) · free-threading rc
  https://vstinner.github.io/free-threading-reference-counting.html
- PHP cycle collection
  https://www.php.net/manual/en/features.gc.collecting-cycles.php
- Ruby 2.1/2.2 https://www.ruby-lang.org/en/news/2013/12/25/ruby-2-1-0-is-released/
  · https://www.ruby-lang.org/en/news/2014/12/25/ruby-2-2-0-released/
- Clang ARC https://clang.llvm.org/docs/AutomaticReferenceCounting.html ·
  ASan https://clang.llvm.org/docs/AddressSanitizer.html · TSan
  https://clang.llvm.org/docs/ThreadSanitizer.html · Valgrind FAQ
  https://valgrind.org/docs/manual/faq.html
- Rust Book ch. 4 https://doc.rust-lang.org/book/ch04-00-understanding-ownership.html
- Lua GC manual https://www.lua.org/manual/5.1/manual.html §2.10
- mimalloc README https://github.com/microsoft/mimalloc
- Swift ARC sin autorelease
  https://forums.swift.org/t/is-autorelease-no-longer-in-pure-swift-arc/33712

**Del repo y medición local**:
- `research/027` §3.1 (tabla loop_alloc de las 4 rutas) · AGENTS.md
  invariante 5 · `astra_runtime_llvm.c:43` (cabecera rc+kind) ·
  Rec3/3A/3B/3C (`research/027` §3.2) `[leído]`
- Probes RSS de §10.2 (`mem_empty/mem_alloc/mem_alloc2m/mem_str*` en
  `/tmp/opencode/intprobe`, `resource.getrusage`) `[ejecutado]`
- `sys.getsizeof` de CPython 3.13.5 (§8) `[ejecutado]`
- Wikipedia (determinism/performance de RC vs tracing):
  https://en.wikipedia.org/wiki/Reference_counting
