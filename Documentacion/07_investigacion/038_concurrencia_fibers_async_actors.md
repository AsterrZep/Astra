# 038 — Concurrencia: fibers, async/await, goroutines y actors — qué eligen los lenguajes y qué le conviene a Astra

> **Alcance**: dossier sobre los modelos de concurrencia de lenguaje y
> runtime — hilos 1:1, green threads M:N, event loops async, actores,
> corutinas y concurrencia estructurada — en Go, Java, Erlang, Rust, Swift,
> C#/C++ y Zig, con el coste real de locks/átomos/cambios de fibra y el
> encaje en el plan de fibras de Astra (DEC-012/022/023/026). **No cambia
> ningún comportamiento.** Fecha: **2026-10-29**. `[verificado]` = ejecutado
> o leído en esta sesión (Debian, HEAD `90e4e00`, worktree `Astra-wt/int-types`);
> `[citado]` = fuente externa con URL en §15; **[no verificado]** = marcado
> explícitamente donde la fuente primaria no se alcanzó.

---

## §0 — TL;DR

1. **Seis modelos conviven**: hilos 1:1 (C#, Rust `std::thread`, Java
   clásico), green threads M:N (Go, Java Loom, BEAM), event loop
   async/await (JS, Python, Rust-tokio, C#, Swift), actores/mailboxes
   (Erlang), corutinas C++20 y — el recién llegado — **effect handlers**
   (Koka, Unison). Cada uno resuelve el mismo triángulo: **coste por
   tarea, coste por conmutación, y quién posee los datos**.
2. **2024-2026 consolidó dos tendencias**: (a) *fibras baratas para
   cualquier E/S* — Loom maduro (JDK 21-25), Zig rehaciendo `std.Io` tras
   **eliminar `async` del lenguaje** (issue #18873), Go 1.25 con GC
   *greentea* (−10..−40 % de overhead) y `GOMAXPROCS` por cgroups; y
   (b) *concurrencia estructurada* como respuesta a los «tasks sueltos» —
   `StructuredTaskScope` de Java sigue en preview (JEP 505 en JDK 25), el
   patrón `nursery` de Trio y los scopes de Kotlin ya son canónicos.
3. **Costes medidos** (Skylake, Travis Downs `[citado]`): mutex sin
   contención ~21 ns, `atomic add` ~7 ns, CAS ~12 ns; **con contención el
   mutex arranca en ~125 ns con 2 hilos** y con oversubscription el
   ticket-spin se desploma ~500× (cientos de µs). TSan para detectar
   carreras cuesta **5-15× de CPU y 5-10× de memoria** `[citado: Clang]`.
4. **La lección de ownership entre tareas**: Rust **mueve** (`Send` +
   closures `move`), Go **comparte referencias** (basura compartida),
   Erlang **copia** el mensaje (términos inmutables), Astra eligió un
   punto medio documentado: **move sin copia** para `var` único + walk
   `rc==1` de respaldo (DEC-012/023) + `.copy()`/`Atomic[T]` como escape.
5. **Astra hoy** `[verificado]`: `spawn` **no existe** (`undefined variable
   'spawn'`) y `transfer` **ya invalida en compile-time**
   (`use of transferred variable 'a'`) — la semántica de move de la fase E1
   (DEC-026) está viva; S3/`spawn` es el siguiente PR. El plan
   (ARCHITECTURE §3) es M:N con pilas ~2 KB, **sin `async/await`** (sin
   funciones de dos colores) y targets explícitos (spawn <150 ns, switch
   <100 ns).

---

## §1 — Los seis modelos estelares

| Modelo | Representante | Coste por tarea | Conmutación | Posesión de datos |
|:-------|:--------------|:----------------|:------------|:-------------------|
| **Hilos 1:1 (SO)** | C#, Rust `std::thread`, Java pre-Loom | ~1 MB de pila + kernel (µs de creación) | syscall ~1-3 µs | `Send`/locks a mano |
| **Green threads M:N** | Go, Java Loom, Erlang BEAM | pila dinámica (KB o cientos de B) | ~ns-µs (swap de pila) | modelo del lenguaje (canales/move/copy) |
| **Event loop async/await** | JS, Python asyncio, tokio, Swift | task ≈ heap future | sin swap (vuelta al loop) | `await` encadena |
| **Actores/mailboxes** | Erlang/BEAM | proceso ≈ cientos de B | reductions | **copia** del mensaje |
| **Corutinas C++20** | `co_await` | frame en heap | suspend/resume (stackless) | a mano |
| **Effect handlers** | Koka, Unison | — | — | tipos de efecto |

La frontera importante es **stackful vs stackless**: las fibras de Go/Loom/
BEAM llevan pila propia (pueden conmutar en cualquier punto, incluidas
llamadas bloqueantes); `async/await` es *stackless* (la función se parte en
máquina de estados — de ahí el «colores de función» que Zig y Astra rechazan).

## §2 — Go: goroutines + CSP

- **Diseño**: «los primitivos de concurrencia de Go derivan de *channels*
  como objetos de primera clase» (FAQ) — CSP/Occam como filosofía, no
  mutex bajos. Las goroutines tienen pila **redimensionable y acotada**
  («a few kilobytes», FAQ `[citado]`; el «2-8 KB» es aproximado
  **[no verificado en primaria]**), ~3 instrucciones baratas de sobrecoste
  por llamada, «cientos de miles» de goroutines es práctico.
- **Scheduler**: work-stealing desde Go 1.1 (diseño de Dmitry Vyukov,
  2012) `[citado]`; `entersyscall/exitsyscall` para no bloquear el M:N
  cuando se entra al SO — **el patrón que Astra adopta explícitamente**
  (ARCHITECTURE §3).
- **Memory model** (2022): *happens-before* = cierre transitivo de
  `sequenced-before` + `synchronized-before`; programas **DRF-SC** (sin
  carreras ⇒ secuencialmente consistentes); `go build -race` (TSan) mata
  el programa al detectar carrera `[citado: go.dev/ref/mem]`.
- **1.22-1.25**: `for range` sobre enteros + corrección de variables de
  bucle; **1.23** paquete `iter` + range-over-func (informe `036` §10);
  **1.25**: `GOMAXPROCS` consciente de cgroups, `testing/synctest`
  (tiempo virtual para testear concurrencia), GC experimental *greentea*
  (−10..−40 % de overhead) y `WaitGroup.Go` `[citado: go.dev/doc/go1.25]`.

## §3 — Java: Loom y la estructuración

- **Virtual threads (JEP 444, JDK 21)** `[citado]`: M:N — el planificador
  es un `ForkJoinPool` **work-stealing FIFO** sin afinidad ni time-sharing;
  la pila vive como *stack chunks* en el heap que crecen/encogen. Cifras
  del propio JEP: pool de 200 hilos de plataforma → ~200 tareas/s;
  virtual threads → ~10.000 tareas/s; **1.000.000 de virtual threads →
  ~1.000.000 tareas/s** (sólo E/S).
- **Pinning**: los hilos virtuales se desmontaban en `synchronized`/nativo;
  **JEP 491 (JDK 24)** elimina casi todo el pinning de `synchronized`.
- **StructuredTaskScope** (JEP 428→437→453→462→480→**505 en JDK 25**,
  5ª preview; JDK 26: JEP 525) `[citado]`: *short-circuit* de errores (un
  fallo cancela a los hermanos), cancelación al salir del ámbito,
  `StructureViolationException` si se rompe el orden. Motivo: los
  `ExecutorService`/`Future` sueltos producían *thread leaks* y cancelación
  olvidada.
- **Threads de plataforma siguen existiendo**: Loom no retiró nada —
  añadió la fila de arriba de la tabla §1.

## §4 — Erlang/BEAM: actores con presupuesto

- **Procesos ligeros** (crecen/encogen, huella pequeña, rápidos de
  crear) `[citado: erlang.org ref man]`; **preemptivo por *reductions***:
  el scheduler ejecuta hasta agotar el presupuesto (históricamente
  **1000 reductions/turno** en 2001 `[citado: lista erlang-questions]`,
  ≈una llamada a función/BIF por reducción) y reencola — el historial es
  consultable con `process_info(Pid, reductions)`. La cifra «~300
  procesos/núcleo» **[no verificado]**: los docs hablan de «millones».
- **Copia de mensajes**: `!` copia el término al buzón del receptor
  (términos inmutables) — sin data races por construcción; el precio es
  el copy (mitigado por pequeñez de mensajes y heap por proceso).
- **Flujo de control integrado**: en distribución, el envío puede
  suspender al emisor en el *distribution buffer busy limit* — backpressure
  en el propio primitivo.
- **Lo que Astra toma prestado**: la semántica «copiar si no eres dueño»
  es el precedente de `.copy()`/`Atomic[T]` de DEC-012.

## §5 — Rust: sin runtime, con ownership

- **`std` no trae executor**: «executors, tasks, reactors y low-level I/O
  futures **no** están en la stdlib» `[citado: async-book]` — tokio/async-std
  son ecosistema. El estado de `async/await` sigue en discusión en el
  foro oficial (2025) `[citado]`; el cierre de `async-std` (RUSTSEC-2025-0052)
  **[no verificado directamente]**.
- **Ownership entre hilos**: `thread::spawn` exige `Send`, los closures
  `move` llevan el valor **[docs estándar, no re-verificados en primaria
  aquí]** — la frontera de tipos es el «no hay data races en safe code».
- **`Send`/`Sync`**: los traits que marcan «puede vivir en otro hilo» /
  «puede compartirse por referencia» — el equivalente tipo-sistema de los
  locks.
- **Coste real de lo seguro**: sin locks en lo local (borrow checker), y
  `Arc<Mutex<T>>` sólo donde hay sharing real — el modelo que hace
  razonable el «contendido ~125 ns» de §9.

## §6 — Swift, C# y C++: tres respuestas al async

- **Swift**: `async/await` + **actors** (aislamiento por tipo — el
  «object-level lock» automático) + `TaskGroup` para scopes
  **[URL oficial sin confirmar en esta pasada: no verificado]**. ARC en
  el runtime: retain/release insertados por el compilador con pares
  redundantes eliminados `[citado: Clang ARC]`.
- **C#**: pionero de `async/await` mainstream (2012, C# 5) sobre `Task` +
  thread pool; `IAsyncEnumerable`+`await foreach` = pull lazy async
  (informe `036` §7). **`Span<T>`/`Memory<T>`** para no allocar en E/S.
- **C++26: Execution control library** (P2300R10 senders/receivers) +
  *async scopes* (P3149R11 `counting_scope`) + tipos de tarea de coroutine
  (P3552R3) `[citado: cppreference C++26]` — C++ persigue 12 años la
  unificación de `std::thread`, `std::async` y las corutinas; y la
  propuesta P1364R0 documenta que **el cambio de contexto de un *fiber*
  sigue costando significativamente** frente a una llamada normal
  `[citado: open-std.org]`.

## §7 — Zig: quitó `async` y lo está rehaciendo con I/O

- **`async`/`await` fueron eliminados del lenguaje** tras el stage2
  (seguimiento: issue #18873, feb-2024) `[citado]`; la frase «async is a
  house of cards» atribuida a Andy Kelley **[no verificado — búsqueda sin
  resultados]**. El *Zig Roadmap 2024* reconoció los obstáculos (backends,
  debuggers) antes de rehacerlo `[citado: ziggit]`.
- **Estado actual (0.15/0.16)** `[citado: kristoff.it/blog/zig-new-async-io]`:
  `std.Io` entra como interfaz tipo `Allocator` (inyectada por el llamante,
  vtable de-virtualizable); `io.async()` + `Future.await()` separados de
  la ejecución; implementaciones previstas: *blocking*, *thread pool*,
  **green threads** (io_uring + pool de pila, x86_64 Linux primero) y
  *stackless coroutines* (pendiente de la convención de llamada, issue
  #23446); cancelación vía `Future.cancel()` **idempotente**.
- **Lección para Astra**: un lenguaje systems puede *deshacer* un async
  mal encajado y reemplazarlo por I/O inyectado — y Zig y Astra comparten
  la filosofía «sin funciones de dos colores» (Astra: yield cooperativo en
  cada I/O, ARCHITECTURE §3).

## §8 — Canales vs memoria compartida

- **CSP (Go)**: sincronización implícita — el *send* en un canal es
  *synchronized-before* la recepción correspondiente; canal sin búfer ⇒
  recepción *before* la finalización del *send*; capacidad C ⇒ regla
  k-ésima recepción → k+C-ésimo envío `[citado: go.dev/ref/mem]`. El
  propio FAQ explica por qué CSP y no mutex de bajo nivel.
- **Actores (Erlang)**: sin memoria compartida entre procesos — el canal
  es el buzón, la copia es la sincronización.
- **Canales en Rust**: `std::sync::mpsc` **[no verificado en primaria
  aquí]**; en la práctica tokio añade *bounded* con backpressure.
- **¿Y Astra?**: un canal además **transporta ownership de forma
  explícita** — justo donde el walk `rc==1` de DEC-023 es barato (sólo en
  `send`/`recv`, no en cada acceso), a diferencia de la memoria compartida
  donde habría que chequear en cada cruce.

## §9 — Costes reales (medidos)

Tabla de Travis Downs (Skylake) `[citado: travisdowns.github.io]`:

| Operación | Sin contención | Nota |
|:----------|:---------------|:-----|
| mutex lock/unlock | ~21 ns | |
| `atomic add` | ~7 ns | |
| CAS | ~12 ns | |
| ticket lock | ~10 ns | |
| **mutex con contención** | **~125 ns ya con 2 hilos** | escala con hilos |
| `sched_yield` (nivel syscalls) | ~1 orden de magnitud peor | |
| spin con oversubscription | cientos de µs (≈500× peor) | el desastre clásico |

Y el coste de **detectar** carreras: TSan **5-15× CPU, 5-10× memoria**
(5× + 1 MB/hilo por defecto) `[citado: Clang ThreadSanitizer]`, ASan ~2×
+ hasta 3× de stack. Correr la suite con sanitizers es barato; correr la
producción con ellos no.

## §10 — Concurrencia estructurada: la idea que unió a todos

- **Origen**: Martin Sústrik, popularizado por Nathaniel J. Smith — «si
  una tarea se divide en subtareas concurrentes, **todas regresan al
  mismo sitio**: el bloque de la tarea» `[citado: JEP 505]`.
- **Garantías** (JEP 505): *short-circuit* de errores, cancelación
  propagada al salir del ámbito, observabilidad jerárquica del árbol
  tarea→subtareas, y excepción si se rompe el orden. Da el **único punto
  donde aplicar deadlines, cancelación y ownership**.
- **Ya en producción**: `nursery` de Trio (espera a todos, errores como
  `ExceptionGroup`, violar el scope rompe la semántica — PEP 789);
  `CoroutineScope` de Kotlin (scope cancelado ⇒ hijos cancelados, scope
  no completa hasta los hijos); `asyncio.TaskGroup` (3.11) **[evidencia
  secundaria]**.
- **Por qué importa para Astra**: el scope de spawn es donde encajan
  naturalmente S1/S2/RT1 (unicidad/transfer) y los timeouts — sin scope,
  `transfer` no tendría dónde verificar.

## §11 — Memoria compartida: los modelos formales

- **Java JMM (JLS §17)** y **C++20 atomics**: *happens-before* explícito,
  `volatile`/`memory_order` como herramientas **[no re-verificados en
  primaria aquí]**.
- **C++26**: defanga `memory_order::consume` (P3475R1) y añade `constexpr`
  para `std::atomic` (P3309R3) `[citado: cppreference C++26]`.
- **Regla de oro transversal** (Go la escribe, todas la cumplen): si no
  hay carreras, el programa es secuencialmente consistente; si las hay,
  «sigue ejecutándose» pero las estructuras multi-palabra se corrompen —
  por eso los race detectors son parte del flujo (TSan 5-15×, `go
  build -race` en CI).

## §12 — Pilas, work-stealing y conmutación

- **Pilas**: Go «resizables y acotadas» (crece y se encoge) `[FAQ]`; Loom
  «stack chunks» en el heap con el mismo comportamiento `[JEP 444]` —
  nadie usa pilas fijas grandes: el M:N moderno es pila dinámica.
- **Work-stealing**: Vyukov 2012 para Go, `ForkJoinPool` FIFO para Loom,
  colas por scheduler con reparto en BEAM `[citado: theBeamBook]`.
- **Coste de cambio de fibra**: la P1364R0 reconoce coste significativo
  con tabla por plataforma `[citado: open-std]`; la cifra «10-50 ns vs
  1-3 µs del SO» procede de fuentes secundarias — **aproximada** `[citado:
  pistack.xyz]`, útil sólo como orden de magnitud (decenas de ns vs µs).
- **Pinning y bloqueos**: en Java los hilos virtuales se desmontaban en
  `synchronized`/nativo hasta JEP 491 (JDK 24) — el M:N necesita que
  *cualquier* bloqueo del SO sea «yield al scheduler» (el
  `entersyscall/exitsyscall` de Go, §2).

## §13 — Tendencias 2024-2026 (síntesis)

1. **Loom maduro**: virtual threads estables (21), pinning resuelto (24),
   structured concurrency en preview larga (505/525) — el mainstream
   adoptó fibras *con* scopes.
2. **Go itera rápido post-1.22**: sintaxis de ranges, `iter`, timers sin
   búfer, GOMAXPROCS por cgroups, GC *greentea* — concurrencia como
   superficie de mejora continua.
3. **Zig rehace I/O** (std.Io, green threads con io_uring) tras borrar
   async — «I/O inyectada» como alternativa al event loop del lenguaje.
4. **Rust**: ecosistema async sin runtime oficial, debate abierto —
   «async no es cooperativo» (foro 2025).
5. **C++26**: senders/receivers + async scopes — la llegada tardía de la
   biblioteca de ejecución.
6. **Effect systems** (Koka v3 con handlers, Unison *abilities*, OCaml
   multicore): el siguiente eje posible, aún fuera del mainstream.

## §14 — Astra: estado medido y recomendación

### 14.1 Estado `[verificado — probes del seed]`

| Probe | Entrada | Resultado |
|:------|:--------|:----------|
| `spawn` | `spawn foo();` | `error: undefined variable 'spawn'` — **no existe aún** (S3 fuera de alcance por DEC-026) |
| `transfer` + uso | `transfer(a); print(a);` | `error: use of transferred variable 'a'` — **la invalidación de move está viva** (fase E1, DEC-026) |
| memoria del probe de arrays | 1 M / 2 M arrays locales en bucle | RSS **lineal**: 135 MB / 268 MB (ver informe `039`) — sin free en el VM |

Y en el repo (leído): DEC-012 (opción F ratificada: `val` cruza siempre,
`var` sólo con unicidad probada, walk `rc==1` como gate), DEC-022
(`transfer` builtin), DEC-023 (RT1 en M4 hasta que el VM Zig tenga rc),
DEC-026 (fase E1: forma directa, S1/S2 post-typecheck, S3/`spawn`
fuera), y el plan ARCHITECTURE §3: **M:N con pilas dinámicas ~2 KB, sin
`async/await`**, yield cooperativo en cada I/O, patrón
`entersyscall/exitsyscall` estilo Go, primitivas *fiber-aware* con
targets: **spawn <150 ns, ctx switch <100 ns, mutex 25-40 ns, canal
40-100 ns, atomic load 1-5 ns**.

### 14.2 Recomendaciones (condicionadas a `DEC-NNN`, AGENTS §1)

1. **`spawn` scoped, no `go` libre**: `spawn` como sentencia con scope
   (bloque con join implícito al salir) — encaja con S3/DEC-026 pendiente
   y es el único punto donde aplicar unicidad/transfer y timeouts
   (§10). El patrón «Future suelto» que Java está arreglando con JEP 505
   desde 2022 es el anti-modelo a no repetir.
2. **Canales por defecto para cruzar fibras**; memoria compartida sólo vía
   `Atomic[T]`/locks intra-fibra (gratuitos dentro de una fibra). Un canal
   transporta ownership explícito → el walk RT1 de DEC-023 se ejecuta en
   `send`/`recv`, no en cada acceso — barato y localizable.
3. **Cancelación por scope**: al fallar una tarea, cancelar hermanos y
   esperar a todos antes de salir del bloque; timeouts por scope (modelo
   nursery/JEP 505, §10).
4. **`transfer` entre «mover» y «copiar»**: Astra ya está entre Rust
   (move sin copia, invalidando al emisor — **medido: `use of
   transferred variable`**) y Erlang (copiar como escape = `.copy()`/
   `Atomic[T]`). El precedente de Zig (`Future.cancel()` idempotente)
   sugiere que la cancelación de Astra debe ser idempotente por diseño.
5. **El target de costes de ARCHITECTURE §3 es coherente con la
   literatura** (§9/§12): switch <100 ns está entre el «decenas de ns»
   medido por fuentes secundarias y el µs del SO; el gate real será
   medirlo cuando exista el scheduler — candidato a benchmark en la suite
   de `research/030`.

### 14.3 Qué NO hace este informe

Ningún cambio de comportamiento: los probes sólo ejecutaron el compilador
y las recomendaciones son propuestas que, si se aceptan, entran como
`DEC-NNN` con tests en el mismo PR (la fase E con `spawn` ya está
presupuestada como «siguiente PR» en DEC-026).

## §15 — Fuentes

**Primarias / oficiales**:
- JEP 444 (virtual threads): https://openjdk.org/jeps/444 · JEP 491
  (pinning): https://openjdk.org/jeps/491 · JEP 505 (structured
  concurrency, 5ª preview): https://openjdk.org/jeps/505
- Go FAQ (goroutines, CSP): https://go.dev/doc/faq · Go memory model:
  https://go.dev/ref/mem · Go 1.23: https://tip.golang.org/doc/go1.23 ·
  Go 1.25: https://go.dev/doc/go1.25 · Scheduler de Vyukov (2012):
  https://rakyll.org/scheduler/
- Erlang — procesos: https://www.erlang.org/doc/system/ref_man_processes.html
  · The Beam Book (scheduling/reductions):
  https://github.com/happi/theBeamBook/blob/master/chapters/scheduling.asciidoc
  · turnos de 1000 reductions (2001):
  https://erlang.org/pipermail/erlang-questions/2001-April/003132.html
- Rust async-book (ecosistema sin stdlib):
  https://rust-lang.github.io/async-book/08_ecosystem/00_chapter.html
- Zig: eliminación de async (issue #18873):
  https://github.com/ziglang/zig/issues/18873 · nuevo modelo std.Io:
  https://kristoff.it/blog/zig-new-async-io/ · Roadmap 2024:
  https://ziggit.dev/t/36-zig-roadmap-2024-andrew-kelley/3024
- C++: P1364R0 (costes de fiber/coroutine):
  https://open-std.org/jtc1/sc22/wg21/docs/papers/2018/p1364r0.pdf ·
  C++26 (P2300/P3149): https://en.cppreference.com/w/cpp/26
- Clang: ThreadSanitizer (5-15×):
  https://clang.llvm.org/docs/ThreadSanitizer.html · AddressSanitizer:
  https://clang.llvm.org/docs/AddressSanitizer.html · ARC:
  https://clang.llvm.org/docs/AutomaticReferenceCounting.html

**Mediciones y análisis secundarios**:
- Travis Downs — concurrency costs (Skylake: 21/7/12/10 ns, contención
  ~125 ns): https://travisdowns.github.io/blog/2020/07/06/concurrency-costs.html
- Coste de fiber switch (~10-50 ns, **aproximado**):
  https://www.pistack.xyz/posts/2026-06-21-coroutine-libraries-libaco-greenlet-libco-boost-context/
- Trio (nursery/PEP 789): https://trio.readthedocs.io/en/stable/reference-core.html
  · Kotlin CoroutineScope:
  https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-coroutine-scope/
- Effect systems: Koka https://github.com/koka-lang/koka · Unison
  https://www.unison-lang.org/docs/language-reference/abilities-and-ability-handlers/

**Del repo**:
- DEC-012/022/023/026 (`Documentacion/01_lenguaje/DECISIONES.md`) ·
  ARCHITECTURE §2.6/§3 (plan M:N, targets) · `research/026` (enforcement
  S1/S2/RT1) · probes `spawn`/`transfer` en `/tmp/opencode/intprobe`
  `[ejecutado]` · comparativa RSS en informe `039` §14.
