# 026 — Modelo de enforcement de «una fibra a la vez»: catálogo de opciones y recomendación

> **Alcance**: decisión de diseño — qué mecanismo hace cumplir la regla «una
> fibra a la vez» (ARCHITECTURE §2.4/§3.3) sin borrow checker completo y sin
> pausas de GC. Ningún código de producción se toca en este documento; solo se
> añade este `.md`. Fecha: **2026-10-27**. Convención: **[verificado]** =
> ejecutado o leído en este repo (Debian, seed `make` + `make test`, rustc y go
> locales) o leído en la fuente primaria oficial online durante esta sesión;
> **[citado]** = conocimiento de dominio no ejecutado/no verificado en línea
> aquí. La búsqueda web (`websearch`) devolvió HTTP 403 en esta sesión; las
> fuentes externas se verificaron por *fetch* directo de la documentación
> oficial de cada lenguaje (límites de búsqueda en §6).

---

## 0. Resumen ejecutivo

**Recomendación: la opción F — «regla de cruce con unicidad comprobada»
(híbrido C+D escalonado).** En una frase:

> **Compartir dentro de una fibra sigue siendo gratis (`let b = a` comparte el
> handle — `alias_write.astra` se queda verde); cruzar una frontera de fibra
> exige que el valor sea *único* en ese punto: el compilador lo rechaza en
> compile-time cuando puede probarlo, y un check en runtime basado en el
> refcount que ARC ya va a construir lo verifica cuando no puede; si no eres
> único, el cruce es `.copy()` explícito o `AtomicRef[T]`.**

Por qué esta y no otra:

1. **A (tracing GC) y B (RC atómico aceptando carreras) no *enforcing*ean la
   regla en absoluto** — lo demostré empíricamente: el programa con la forma
   exacta de la crítica corre en Go (tracing GC) y `go run -race` reporta
   *DATA RACE* **[verificado]**. GC ≠ seguridad de concurrencia; y B contradice
   «thread-safe» del README. Ambas descartadas con evidencia, no con opinión.
2. **El oráculo de unicidad ya está pagado**: la crítica dice «habría que
   rastrear aliases»; pero Phase 2 va a construir ARC/ORC de todos modos
   (ARCHITECTURE §2.1-§2.2), y **el refcount *es* el rastreo de aliases en
   runtime**: `rc == 1` en la raíz *y en cada nodo alcanzable* en el momento
   del cruce = grafo único. Closures que capturan, aliases vía campos,
   aliases vía contenedores — todos mantienen un `rc` extra y saltan el check.
   Ese check cuesta **O(tamaño del grafo) solo en los cruces** (raros, y ≤ el
   coste de la copia de respaldo), **cero en cada acceso**.
3. **Estático primero donde es gratis**: `let b = a; transfer(a)` es un alias
   *definido* a un binding local — dataflow intraprocedural, mismo coste de
   implementación que el chequeo `use-after-move` que ya hace Nim
   (`lastReadOf`). Ese check rechaza el programa de la crítica **en
   compilación** y se implanta en los 2 frontends → cubre las 7 rutas de
   ejecución con 2 implementaciones.
4. **Encaja el pitch**: sin GC (✓), sin borrow checker (no hay lifetimes ni
   préstamos: es un análisis de flujo sobre aliases locales + un oráculo de
   runtime), `ARC/ORC atómico` deja de ser una promesa vaga: la regla de
   promoción a atómico de §2.2 **es** la regla de cruce, y `ARCHITECTURE.md:31`
   («deep copy o `AtomicRef[T]`») queda normativa en vez de media nombrada.
5. **`alias_write.astra` NO se rompe ni se reescribe**: la regla nueva solo
   actúa en fronteras de fibra; el test no tiene ninguna. Lo que sí hay que
   cambiar es la *documentación* (§2.5 ganaba una pregunta abierta sin
   respuesta: «si un agregado puede cruzar una frontera de fibra» — aquí está
   la respuesta).

Las fases: **Fase 0** = escribir el enforcement en los docs (hoy, este
documento cierra 025-P0.1); **v1** = checks estáticos baratos (alias local +
use-after-transfer + efecto de globales en `spawn`) en ambos frontends, y
**el check runtime de grafo es requisito de entrada (*gate*) de la primera
feature que ejecute un cruce real** (scheduler/send); **v2** = el análisis
estático ampliado elide el walk en los casos probados y mejora mensajes;
**v3** = refinamiento regional (estilo SE-0414) + owner-assert opcional en
builds de debug (la opción D quedándose donde aporta: red de verificación).

Garantía resultante: **data-race freedom por construcción para agregados
mutables** (con la única excepción documentada de `unsafe`/FFI), coste escrito,
y honestidad: el README `124-125` se desmarca hasta que fibras/ARC existan
(mandato 025-P0.4).

---

## 1. Catálogo de opciones

### 1.0 El mapa de coste base: 7 rutas, 4 motores, 2 frontends

Cualquier modelo de enforcement se paga en uno de dos sitios: **frontend**
(checks estáticos) o **motor de ejecución** (checks runtime). El repo tiene
7 rutas de ejecución (AGENTS.md) pero no 7 motores independientes — y esa
asimetría es decisiva para la recomendación:

| Ruta de ejecución | Motor que hay que instrumentar | Frontend que la gobierna |
|:------------------|:-------------------------------|:-------------------------|
| 1. seed VM (`vm.c`) | **M1**: seed VM | **FC: frontend C** (`typechecker.c`) |
| 2. C backend (`--emit-c` + gcc) | **M2**: `codegen.c` + `codegen_runtime.h` | **FC: frontend C** |
| 3. Zig VM (`zig/src/vm/`) | **M3**: zig VM | **FZ: frontend zig** (`src/typechecker/`) |
| 4. LLVM AOT (`--emit-obj`) | **M4**: `src/llvm/emitter.zig` + `astra_runtime_llvm.c` | **FZ: frontend zig** |
| 5. LLVM JIT (`--jit`) | M4 (mismo emitter) | **FZ: frontend zig** |
| 6. wasm32-wasi | M4 (mismo emitter → wasm-ld) | **FZ: frontend zig** |
| 7. aarch64 cross | M4 (mismo emitter → cross-gcc) | **FZ: frontend zig** |

**[verificado]**: el backend LLVM compila desde el AST tipado y cubre AOT,
JIT, wasm y aarch64 con el mismo emitter (AGENTS.md; `zig/src/llvm/emitter.zig`
emite para todos ellos), y los tests de paridad y UI (`zig/tests/ui_message_parity.sh`)
exigen que **seed y zig rechacen cada caso UI con la primera línea de
diagnóstico byte-idéntica**. Por tanto:

- **Un check estático = 2 implementaciones** (FC, FZ) y gobierna las 7 rutas.
- **Un check runtime = hasta 4 implementaciones** (M1–M4): 4 si el check
  tiene que valer ya en Astra-0; **2 basta** (M3 y M4, rutas 3–7) cuando el
  check solo es necesario donde existan fibras+ARC — que es Phase 2 (el seed
  no tiene rc ni scheduler: §3.2/§3.4). Veredicto: mínimo real para RT1 =
  2 motores; el argumento general sigue en pie: **nunca 7, y nunca por
  acceso**.

Conclusión de diseño: **todo lo que se pueda resolver estáticamente se
resuelve estáticamente (2 sitios); lo que no, se resuelve una sola vez por
cruce en runtime (2 motores Phase 2, o 4 si Astra-0 lo exigiera), nunca por
acceso.**

Notación común de las fichas: *Garantía* = ¿cumple «una fibra a la vez»?;
*Coste estático* / *Coste runtime*; *7 rutas* = esfuerzo por motor;
*Pitch ARC/ORC*; *alias_write.astra*; *Closures*.

---

### Opción A — Tracing GC (estilo Go)

- **Garantía**: **No**. GC da seguridad de memoria, no libertad de carreras:
  ejecutado el análogo Go del programa de la crítica con `go run -race` →
  *WARNING: DATA RACE* (dos escrituras al mismo backing array de dos
  goroutines) **[verificado]**. Go lo «resuelve» con `-race` (detector
  opt-in) + `sync`, es decir, con otros mecanismos.
- **Coste estático**: 0. **Coste runtime**: barreras de escritura + fases de
  marcaje + pausas (sub-ms, pero existentes; figura «pausas <1 ms desde Go
  1.8» **[verificado: go.dev/doc/go1.8 — «pauses ... usually under 100
  microseconds and often as low as 10 microseconds»]**).
- **7 rutas**: XL en Phase 2 — sustituir el ARC que §6.4/§2.2 prometen
  inyectar por un GC (barreras de escritura y safepoints en M3/M4, raíces en
  el scheduler futuro), mientras que el seed M1/M2 se quedaría con la arena
  que hoy **ni siquiera libera** (**[verificado]** 025 §2.8: 408 MB de RSS
  en 2 M de arreglos) — es decir, dos modelos de memoria conviviendo en 7
  rutas. El coste real es doble: cambiar el modelo *y* que aun así no evita
  carreras.
- **Pitch ARC/ORC**: **lo contradice frontalmente** (README:21, ARCHITECTURE:12
  «sin GC stop-the-world»). Descartada por el propio pitch *y* por no
  resolver el problema de concurrencia.
- **alias_write.astra**: no se rompe (el sharing le es indiferente).
- **Closures**: sin problema (no hay unicidad que rastrear).
- **Veredicto**: ✗ — ni cumple la garantía, ni encaja en el pitch.

### Opción B — RC atómico aceptando carreras (Swift < 6)

- **Garantía**: **Parcial y solo del contador**: los refcounts no se
  corrompen; `b[0] = 99` desde dos fibras **sigue raceando**. Es la ausencia
  de enforcement disfrazada de elección.
- **Coste estático**: 0. **Coste runtime**: átomos en cada retain/release
  cross-fiber; el repo ya cita la cifra: *«40% performance penalty with
  `--threads:on` in Nim 2.0»* (`COMPARATIVE_ANALYSIS.md:131`, **[verificado
  cita]**; la medición original **[citado]**). La propia ARCHITECTURE §2.2 ya
  lo mitiga a medias: RC no-atómico local + promoción a atómico al compartir.
- **7 rutas**: M (operaciones atómicas donde hay rc — Phase 2: M3 y M4; de
  hecho es lo que
  Phase 2 va a hacer igualmente).
- **Pitch ARC/ORC**: encaja, pero **README:21 «thread-safe» queda falso** y
  §2.4 queda decorativa. Swift < 6 era exactamente esto y Swift 6 añadió
  verificación en compile-time (**[verificado: SE-0302 — «warnings for Swift 5
  and earlier», errores solo en modo Swift 6 — y SE-0414 *Status: Implemented
  (Swift 6.0)*, raw.githubusercontent.com/apple/swift-evolution]**; la propia
  existencia de SE-0414, §2, es la admisión).
- **alias_write.astra**: no se rompe. **Closures**: sin problema.
- **Veredicto**: ✗ como modelo de enforcement — es «no hacer nada». Queda
  como *componente*: el RC atómico es pieza de la opción F.

### Opción C — Unicidad / move condicional (estilo Nim `isolate`) + deep copy de respaldo

- **Garantía**: «Una fibra a la vez» **estática** para lo que el análisis
  prueba; para el resto, copia (o rechazo). La crítica lo llama «limited
  ownership check» y es justo lo que Nim hace: `isolate(x)` crea un
  subgrafo aislado y *«Isolation is checked at compile time»*
  (`std/isolation`, **[verificado]** fetch), `Isolated[T]` tiene `=copy`
  marcado `{.error.}` — solo move (**[verificado]**), y el análisis de move
  de Nim es *«limited and only concerned with local variables»*
  (`doc/destructors`, **[verificado]**) — más barato que el borrow checker
  porque no hay lifetimes ni préstamos.
- **Coste estático**: dataflow de aliases intraprocedural sobre bindings
  locales + capturas de closures + conservador en calls. FC y FZ.
- **Coste runtime**: deep copy en los cruces no probados (coste visible,
  proporcional al objeto — y solo en cruzar fibras).
- **7 rutas**: M — 2 frontends para el análisis; los backends solo necesitan
  la primitiva de copia profunda (un traversal por motor, que ya se necesita
  para `.copy()` igualmente).
- **Pitch ARC/ORC**: **es el modelo de Nim, que es exactamente el pitch de
  Astra** (ARC/ORC + move/isolate). `ARCHITECTURE.md:31` ya lo nombra
  («deep copy o `AtomicRef[T]`»).
- **alias_write.astra**: **no se rompe** — *si y solo si* la regla se aplica
  en la frontera de fibra y no en la asignación (ver C-espejo abajo).
- **Closures**: el caso duro, y lo es para Nim y Swift también. Un closure
  que captura `x` mantiene un handle → cuenta como alias vivo en `x` en el
  punto de cruce. La regla conservadora («capturado ⇒ no único ⇒ error o
  copia») es **[verificado]** necesaria en Astra: probé que la captura
  por valor copia el *handle*, no el agregado (programa
  `closure_alias.astra`: mutación dentro del closure → `print(a[0])` fuera
  imprime **42**) **[verificado]** — es decir, la captura *amplifica* el
  aliasing, no lo reduce.
- **Veredicto**: ✓ como base. Punto débil conocido: solo lo estático deja
  ventanas de sonido si el análisis se equivoca hacia «únicos» — de ahí el
  respaldo D de la opción F.

**C-espejo (sub-variante, listar por completitud): move por defecto en la
asignación (semántica Rust).** `let b = a` *mueve* → el alias nunca existe,
cero análisis. Pero **rompe `alias_write.astra`** (pasaría a imprimir `1`;
habría que reescribirlo como `let mut b = a.copy()`), rompe «fibras que
comparten datos» salvo con sintaxis de share explícito, y si además se
quiere compartir cómodamente hace falta borrow/lifetime = el borrow checker
que prometemos no tener. Descartada: es el encuadre binario de la crítica.

### Opción D — Owner-check por acceso en runtime

- **Garantía**: **Sí, completa** (módulo `unsafe`): cada objeto lleva un
  `owner` (id de fibra); leer/escribir agregados desde fibra ≠ owner →
  error en runtime. «Una fibra a la vez» literal, sin análisis estático
  alguno.
- **Coste estático**: 0. **Coste runtime**: **1 load + cmp por cada acceso a
  agregado** (`OPCODE_INDEX`, `OPCODE_SET_INDEX`, `OPCODE_GET_FIELD`,
  `OPCODE_SET_FIELD` — el mapa de accesos en el repo: `vm.c:1212/1240` y
  `codegen.c:1146/1202` **[verificado]**, más los equivalentes en zig VM y
  LLVM emitter), **permanente, en todos los caminos calientes** de los
  motores donde corran fibras (Phase 2: M3 y M4 — en M1/M2, sin fibras, el
  check sería inerte), además de un campo `owner` en los
  headers (el header `{rc, kind}` de `astra_runtime_llvm.c:43` crecería; el
  seed ni headers tiene — sus agregados son arena **[verificado]** por
  diseño, lo que además haría imposible D en Astra-0 sin rediseñar valores).
- **7 rutas**: M de implementación en los motores con fibras, pero
  **coste continuo** en las rutas que los usan; y sin análisis estático
  **todos** los errores son de runtime (mala UX: el
  programa de la crítica compilaría y fallaría al correr).
- **Pitch ARC/ORC**: compatible pero no lo aporta; «thread-safe» se cumple,
  «sin coste» no.
- **alias_write.astra**: no se rompe (intra-fibra, owner == fibra
  actual siempre). **Closures**: sin problema para el check; el handle
  capturado simplemente falla al escribir si la otra fibra es owner.
- **Veredicto**: ✓ como **red de debug/assert** (cubre bugs del análisis y
  `unsafe`), ✗ como base (coste por acceso permanente en los motores con
  fibras + errores solo en runtime). En F queda como `ASTRA_DEBUG_OWNERSHIP=1`.

### Opción E — Sin mutable compartido: copia/canales (estilo Erlang)

- **Garantía**: **Sí, por construcción** — los cruces nunca comparten
  heap mutable: `send` copia, o se comunican por canales con copia.
- **Coste estático**: pequeño (regla de globales en spawn, igual que F).
  **Coste runtime**: deep copy en cada mensaje.
- **7 rutas**: S-M — solo la primitiva de copia (que F necesita igualmente).
- **Pitch ARC/ORC**: choca de frente con «fibras que comparten datos»
  (README:30, ARCHITECTURE §3.3 «para compartir: `transfer(var)` o
  `Atomic[T]`») y con el diferenciador cero-copia
  (`COMPARATIVE_ANALYSIS.md:30`). *Nota*: E necesita la misma regla de
  globales que F — un heap compartido con globales mutables no se vuelve
  seguro solo por copiar mensajes.
- **alias_write.astra**: no se rompe (intra-fibra). **Closures**: sin
  problema (todo se copia).
- **Veredicto**: ∼ es la garantía *barata* pero sacrifica el pitch. Es,
  además, **el subconjunto de F que ya existe como `.copy()`** — F añade el
  move cero-copia cuando eres único.

### Opción F — Híbrido escalonado C+D (recomendada)

Combina: **C en la semántica** (unicidad en el cruce, move cuando se prueba,
copia explícita cuando no, `AtomicRef` para compartir deliberado) + **D como
red de verificación** (owner-assert solo en builds de debug) + **oráculo
runtime de refcount** para lo que el estático no prueba. Escalonado:

| Fase | Mecanismo | Qué gana |
|:-----|:----------|:---------|
| **v1** | Checks **estáticos baratos** (alias definido, use-after-transfer, efecto de globales en `spawn`) + **check runtime de grafo único en el cruce** (`rc==1` en todos los nodos alcanzables) + invalidación de la variable emisora | **Correcto**: ninguna carrera posible, *antes* de tener un análisis potente. Errores: compile-time para lo evidente, runtime para lo invisible. |
| **v2** | El mismo pass crece: interprocedural conservador, liveness de closures, **elisión del walk runtime cuando el análisis prueba unicidad** | Los cruces probados no pagan O(grafo); mensajes mejores; menos falsos positivos. |
| **v3** | Refinamiento regional (estilo Swift SE-0414: transferir una región y rechazar *usos posteriores* de cualquier miembro) + owner-assert debug + benchmarks | Acepta programas con aliases muertos; red D para bugs de análisis. |

- **Garantía**: completa para agregados mutables (argumento de completitud en
  §3.1: todo handle que llega a una fibra M≠main entró por
  `transfer`/`spawn` args/`send` (→ check F) o es `Atomic` o es un global
  (→ regla estática de globales)).
- **Coste estático**: 1 pass lineal por frontend (FC, FZ) — 2
  implementaciones. **Coste runtime**: O(grafo) **por cruce** en los motores
  con fibras (2: M3 y M4 — rutas 3–7), **0 por acceso**; el walk es ≤ coste
  del `.copy()` de respaldo.
- **Pitch ARC/ORC**: es ARC/ORC *con su regla de uso escrita*; el refcount
  deja de ser solo memoria y pasa a ser también el oracle de unicidad; la
  promoción a atómico de §2.2 *es* la semántica de compartir.
- **alias_write.astra**: **se queda tal cual** (la regla no actúa sin
  frontera de fibra).
- **Closures**: captura = alias (runtime: el `rc` del env lo delata;
  estático: regla «capturado ⇒ no único»). Viabilidad: ✓ con la salvedad
  conservadora documentada.
- **Veredicto**: **✓ recomendada**.

---

## 2. Investigación de arte: cómo rechazan otros lenguajes el programa exacto de la crítica

El programa (025 §2.2):

```astra
let mut a = [1, 2, 3]
let mut b = a      # §2.5: b comparte el arreglo
transfer(a)        # §2.4: a queda inválida
b[0] = 99          # b sigue apuntando → dos fibras escribiendo
```

| Lenguaje | Qué hace con `let b = a` / `transfer` | **Check mínimo que lo rechaza** | Evidencia |
|:---------|:--------------------------------------|:--------------------------------|:----------|
| **Rust** | `let b = a` de un `Vec` **mueve** (no existe alias); `let b = &mut a` crea préstamo | **Use-after-move en `transfer(a)`**: `rustc` local sobre el análogo → `error[E0382]: use of moved value: a` apuntando a `transfer(a)`; y con doble préstamo → `error[E0499]: cannot borrow 'a' as mutable more than once at a time` | **[verificado]** (rustc 1.x local, en `/tmp/opencode/astra-critica/enforcement/`) |
| **Nim** | Asignación = **copia salvo** que el análisis `lastReadOf(x)` pruebe último uso (entonces move + `=wasMoved`); `isolate(x)`/`ensureMove` para cruces | **`ensureMove`/`isolate` con alias vivo → static error**: *«ensureMove annotation leads to a static error if the compiler cannot prove that a move would be safe»*; *«Isolation is checked at compile time»*; el análisis es *«limited … only concerned with local variables»* | **[verificado]** (`nim-lang.org/docs/destructors.html`, `docs/isolation.html`); el mensaje exacto del compilador **[citado]** (nim no está instalado) |
| **Pony** | `var b: Wombat iso = a` es **él mismo un error** — *«the `iso` reference capability denies other `iso` variables that point to the same object»*; mover exige `consume` | **El rechazo ocurre en la LÍNEA 2** (`let mut b = a`): «*Not allowed!*» si `a` es `iso`/`trn` (alias permitido solo como `tag`/`box`, sin escritura) | **[verificado]** (`tutorial.ponylang.io/reference-capabilities/aliasing/` y `/consume-and-destructive-read/`) |
| **Rust (historia)** | El chequeo de *move* (E0382) precede a los lifetimes no-lexicales (NLL) — es el check «del move inicial» | análogo a Rust arriba (E0382) | E0382 **[verificado]** reproducido; precedencia histórica NLL **[verificado
parcial: el RFC 2094 «non-lexical lifetimes» se aceptó el 2017-09-29
(api.github.com/repos/rust-lang/rfcs/pulls/2094) y redefine solo
lifetimes/préstamos, no el chequeo de move; no se ejecutó un rustc pre-NLL]** |
| **Swift 6 (SE-0414)** | `let y = x` → misma *isolation region*; transferir `x` transfiere **toda la región**; uso posterior de `y` → error | **Use-after-transfer regional**: la propuesta usa literalmente este programa: `let y = x` → `Regions: [(x, y)]`, `await transferToMainActor(x)` → `print(y)` → *«Error!»* — *«emits errors at use sites of non-`Sendable` values that have already been transferred»* | **[verificado]** (SE-0414, raw.githubusercontent; *Status: Implemented (Swift 6.0)*); salida real del compilador **[citado]** (swift no instalado) |
| **Clean** | Uniqueness types: un valor `unique` no puede tener dos nombres; la asignación transfiere unicidad | Rechazo en la asignación/uso que rompa unicidad | **[verificado parcial:
clean.cs.ru.nl (wiki oficial) confirma «uniqueness typing» como característica
distintiva de Clean; la semántica exacta de la asignación no se localizó en
línea]** |
| **Haskell (LinearTypes)** | `%1` — consumir *exactamente una vez*; GHC ≥ 9.0.1, experimental | Linealidad del consumidor; no resuelve por sí solo heap mutable compartido | **[verificado]** (`ghc.gitlab.haskell.org/.../linear_types.html`); implementación en Astra: n/a |
| **Go** | `b := a` copia el *slice header* (mismo backing array) | **Ninguno en compilación** — carrera detectada solo con `-race` en runtime | **[verificado]** (ejecutado: *Found 1 data race(s)*) |

**Lectura cruzada del arte**:

1. **Ninguno de los cuatro modelos (move, refcaps, regiones, unicidad) necesita
   un borrow checker completo** para rechazar este programa. El check mínimo
   es siempre una de: *(i)* move-on-assignment (Rust), *(ii)* unicidad en el
   punto de cruce (Nim), *(iii)* unicidad del alias al crearlo (Pony), *(iv)*
   no-uso-posterior-de-la-región (Swift). Todos son más baratos que lifetimes.
2. **Swift es la coincidencia más fuerte con la crítica**: SE-0414 rechaza el
   programa *no* al `transfer` sino en el uso posterior de `b` — y lo hace
   con un análisis de regiones *control-flow sensitive*, no con borrow
   checker. También es la más parecida a la semántica Astra: en Astra,
   §2.4 ya dice «transfer invalida la variable emisora»; la generalización
   es «invalida la *región*» (v3 de F).
3. **Pony muestra el extremo más estricto** (ni siquiera el alias se crea) y
   Nim el más laxo (copia por defecto, move solo cuando prueba). Astra en F
   queda en la zona Nim/Swift: **compartir intra-fibra barato, cruce
   verificado**.
4. **Lo mínimo que rechazaría el programa en Astra** (dos puntos posibles):
   - **Compile-time (v2)**: al `transfer(a)`, el pass ve `b` en el conjunto
     de aliases de `a` → error (equivale a Pony-línea-2/Nim-isolate).
   - **Runtime (v1)**: el walk rc ve `rc(a) == 2` → error en el `transfer`
     (equivale a Swift use-after-transfer, pero detectado en el cruce).
   Ninguno de los dos necesita lifetimes ni inferencia de regiones.

---

## 3. Especificación concreta de la recomendación (opción F)

### 3.1 Conceptos y reglas normativas (texto a entrar en ARCHITECTURE §2.6)

**Conceptos.**
- *Fibra*: unidad de ejecución programable (§3.1). La principal es `main`.
- *Frontera de fibra (cruce)*: todo punto donde un handle de agregado pasa a
  una fibra distinta. En Astra hay exactamente cinco vías:
  **(1)** `transfer(x)`, **(2)** argumentos de `spawn` (futuro), **(3)**
  `ch.send(v)` (futuro), **(4)** `Atomic[T]`/`AtomicRef[T]` (sanctionado),
  **(5)** globales mutables alcanzables por código de otra fibra.
- *Agregado mutable*: valor heap cuya escritura pasa por `SET_INDEX` o
  `SET_FIELD` — arrays y structs (los strings no son indexables
  **[verificado]**: `s[0]` → *cannot index non-array type string*; la
  asignación a campo de enum está rechazada **[verificado]** por
  `ui/enum_variant_assign.astra`). Enums con payload: mutables solo como
  campos de struct que los contengan; se les aplica la misma regla.
- *Handle*: el `Value`/`AstraValue` apuntando al objeto — `let b = a` copia
  el handle **[verificado]** (`alias_write` imprime `99 99`), las capturas de
  closures copian el handle **[verificado]** (§1-Opción C).

**Reglas.**

- **R1 — Compartir intra-fibra es libre.** `let b = a` dentro de una misma
  fibra comparte el handle (ARC lo contabiliza). **`alias_write.astra` es la
  spec de R1 y no cambia.** *(Esta regla NO hace `let` inmutable: que `let
  p/q` permita mutar vía alias —025 §2.8, imprime `5`— es una decisión
  adyacente, separada, NO resuelta por este informe.)*
- **R2 — Toda frontera es un evento de cruce** (las 5 vías). No hay otra
  forma de que una fibra 2 toque un agregado.
- **R3 — Regla de cruce (la garantía).** En cada cruce de las vías 1–3, el
  valor debe ser **único en su grafo**: *ningún nodo alcanzable desde la
  raíz tiene otro handle vivo*. Se comprueba:
  - **(a) estáticamente** cuando el análisis lo prueba (v2); si el análisis
    ve un alias **definido** → **error de compilación** (v1 ya, §3.3 S2);
  - **(b) en runtime** si el análisis no prueba nada (v1): walk del grafo
    con `rc == 1` en cada nodo (§3.4 RT1);
  - **(c) escape explícito** si no eres único: **`x.copy()`** (deep copy —
    la opción ya nombrada en `ARCHITECTURE.md:31`) o **`AtomicRef[T]`**
    (vía 4, la única forma compartida-mutable legal).
  `transfer` es azúcar sobre R3 + R4 (025 §4, confirmado y refinado).
- **R4 — Invalidación de la emisora.** Tras `transfer(x)`, el binding `x`
  queda inválido (§2.4): estáticamente «use of transferred variable»; en v1
  runtime, el binding se pone a `nil` (red de mensajes nil existentes).
- **R5 — Globales mutables.** Una global mutable cuyo objeto pueda ser
  escrito por más de una fibra **debe ser `Atomic[T]`** o pasar como
  parámetro. Se verifica con un **check de efectos en `spawn`** (S3): el
  destino de `spawn` (y sus transitivas dentro del módulo, y el cuerpo de
  closures) no puede acceder a globales mutables no-`Atomic`. *Por qué hace
  falta*: es el único agujero del oráculo rc — `spawn(f)` sin argumentos no
  dispara ningún cruce verificable, pero `f` escribe la global compartida.
- **R6 — `unsafe`/FFI** queda fuera de R1–R5 con contrato documentado
  (equivalente al `unsafe` de Rust): el código crudo puede aliasar sin
  retener `rc`; se anota en la sección `unsafe` de §2.1.
- **R7 — Promoción atómica = semántica de compartir.** Un objeto cuyo rc
  cruza fibras usa rc atómico (§2.2 literal). La cifra del 40% de Nim con
  threads aplica solo a lo que *de verdad* se comparte; R3+C la acota.

*Nota de despliegue*: `transfer` entra en Astra-0 (v1, junto a S1/S2), así que
el escape `.copy()` debe existir en los **4 motores** — es copia estructural y
**no necesita rc** (el seed puede implementarla sin ARC). El walk RT1, en
cambio, solo donde hay rc: M3/M4 (§3.2).

**Argumento de completitud (por qué R3+R5 cubren todo)**: un handle en la
fibra M (M ≠ la que lo creó) solo puede haber llegado por una de las 5 vías;
1–3 pasan por R3, 4 es el mecanismo sancionado, 5 por R5. `unsafe` es R6.
∎ — *completitud relativa a que no existan otras vías de cruce (cualquier
feature futura que mueva handles entre fibras DEBE declararse frontera; esto
va escrito como invariant, §4)*.

### 3.2 Dónde vive cada check (para que un implementador no adivine)

| Check | Fase | Dónde (FC: frontend C) | Dónde (FZ: frontend zig) | Dónde (runtime, por motor) |
|:------|:-----|:------------------------|:--------------------------|:---------------------------|
| **S1** use-after-transfer | v1 | `seed/src/typechecker.c`, fase tras `typecheck_node` (invocada desde `driver.c:689`); errores con `tc_error` (`typechecker.c:686`) | `zig/src/typechecker/typechecker.zig`, fase final de `TypeChecker.check` (llamada en `src/main.zig:278` y por módulo en `:567`); errores por el sink `src/diagnostics.zig` | red: binding → `nil` en el emitter (`seed/src/emitter.c`, `zig/src/emitter/emitter.zig`) |
| **S2** alias definido en el cruce | v1 | ídem S1 | ídem S1 | — (S2 no necesita runtime) |
| **S3** efecto de globales en `spawn` | v1 | ídem S1 (sets de globales por función + clausura de llamadas dentro del módulo) | ídem S1 | — |
| **RT1** walk `rc==1` del grafo | **gate de la primera frontera real** | n/a — *el seed no puede*: no tiene rc (arena, `research/002 §5.3`) ni fibras; su semántica de `transfer` es solo move+estáticos | la lógica vive en los motores **M3 y M4** | **M3**: `zig/src/vm/` (opcode de cruce + walk); **M4**: `src/llvm/runtime/astra_runtime_llvm.c` (helper `astra_llvm_check_unique`, siguiendo el patrón de `astra_llvm_index_fail`, `emitter.zig:676`); **M1/M2**: n/a — cubiertos por S1/S2 + «sin cruce en Astra-0» |
| **D** owner-assert | v3 (debug) | — | — | accesos de `SET_INDEX`/`SET_FIELD`/`INDEX`/`GET_FIELD` bajo `#ifdef ASTRA_DEBUG_OWNERSHIP`, en M3 y M4 (inerte en M1/M2 sin fibras) |

**Inserción exacta por motor para el opcode de cruce** (puntos de cruce, no
de acceso): `OPCODE_TRANSFER`/`OPCODE_SPAWN`/send en **M1** (`seed/src/vm.c`,
nuevo opcode al estilo de los existentes; lista de opcodes en
`include/astra/astra.h:847+`) y **M2** (`seed/src/codegen.c` — todo opcode
tiene handler obligatorio, invariant 8 de AGENTS.md): en M1/M2 ese opcode hace
**move + invalidación (nil) y S1/S2 ya garantizaron la corrección — sin walk**,
porque Astra-0 no tiene rc ni cruce real. En **M3** (`zig/src/vm/` + opcode en
`zig/src/emitter/bytecode.zig:62`, emitter `emitter.zig:1189`) y **M4** (LLVM
emitter + helper de runtime) el mismo opcode añade **RT1**. **Nota de
paridad**: cada mensaje nuevo de UI debe ser
byte-idéntico en FC y FZ (`zig/tests/ui_message_parity.sh` gatea la primera
línea) **[verificado]**.

### 3.3 Algoritmo del check estático S2 (especificación operativa)

Intraprocedural, flow-sensitive, sin CFG explícito: recorrido recursivo del
AST que **hila estado** (firma: `visit_block(stmts, σ) -> σ`).

```
σ : Map<Binding, Estado>       Estado = Único | Aliased{conjunto de nombres} | Escapado
σ_también: Set<Binding>  (movidos por transfer)
join(if/else)  = punto a punto: Único ⊔ Aliased(S) = Aliased(S)
                            Escapado ⊔ cualquiera = Escapado   (absorbente)
bucles         = conservador: join(entrada, cuerpo) una vez (v1)
```

Reglas de transición (v1 — cubren el programa de la crítica y los casos del
repo):

| Operación | Efecto en σ |
|:----------|:------------|
| `let y = x` (agregado) | `σ(x)=σ(y)=Aliased{x,y}` si `σ(x)≠Único`, si no ambos `Aliased{x,y}` |
| `y = x` (reasignación) | `σ(y) := σ(x)`; si `y` era alias de `z`, `z` queda `Escapado` (v1: conservador `Escapado`) |
| `x = <literal/nuevo>` | `σ(x) := Único` (objeto fresco) |
| `s.f = x` / `[e1, x, ...]` | `σ(x) := Escapado` (alcanzable desde contenedor; v1 no rastrea dentro de contenedores → conservador) |
| `f(x)` (call no-builtin) | `σ(x) := Escapado` (callee desconocido puede retener; v2: efecto por firma) |
| `let c = \|..\| x ..` (captura) | `σ(x) := Aliased{c}` mientras `c` viva (v1: hasta fin de scope); `c` queda registrado como portador de alias |
| `transfer(e)` con raíz `x` | exige `σ(x)==Único ∧ x ∉ movidos` — **si no → S2 error**; añade `x` a `movidos` |
| uso de binding en `movidos` | **S1 error** |
| `spawn f(args)` | por cada arg: igual que `transfer`; además S3 (efecto de `f`) |

Programa de la crítica bajo S2: línea 2 `let mut b = a` → `σ(a)=σ(b)=
Aliased{a,b}`; línea 3 `transfer(a)` → **rechazado en compile-time**. ✓

**S3 (globales)**: `globals_mut(fn)` = globales con `SET_GLOBAL`/lectura
mutante en `fn` o en su clausura; `spawn` exige
`globals_mut(closure(fn)* ) ⊆ Atomic`. Fijo por iteración (worklist) sobre el
grafo de llamadas del módulo; callee sin cuerpo (FFI) ⇒ conservador «toca
todo» → error con salida `Atomic` o parámetro.

**Por qué el estático nunca puede estar «equivocado hacia compartir»**: si S2
tiene falsos positivos → rechazas un programa válido (ergonomía, se arregla en
v2); si tuviera falsos negativos → RT1 lo coge en el cruce. La corrección no
descansa en el análisis; descansa en RT1. Este es el reparto de confianza de
la opción F.

### 3.4 Algoritmo del check runtime RT1 (la red de corrección)

```
check_grafico_unico(raiz):            # en el punto de cruce, ANTES del handoff
    epoch += 1                        # campo i32 en el header (hoy {rc, kind})
    stack = [raiz]
    while stack:                      # DFS iterative — sin recursión (bordes de pila)
        o = stack.pop()
        if o.epoch == epoch: continue
        o.epoch = epoch               # marca => ciclos manejados (ORC ya recorre grafo)
        if o.rc != 1: FAIL("compartido", o.rc)
        stack.push_all(hijos(o))      # elems de array, fields de struct, env de closure,
                                      # payload de enum — el mismo recorrido que =trace
    OK
```

- **Coste**: O(nodos del grafo transferido) — ≤ coste de `x.copy()`, y solo
  en cruzar. **Cero** en accesos.
- **Lectura de `rc` no-objetómica**: en el momento del cruce el objeto es
  propiedad de la fibra emisora (ella ejecuta el cruce) → lectura
  single-thread con *release* en el push de la cola del scheduler (fences del
  handoff, §35).
- **`rc == 1` en la raíz no basta** (raíz única con subnodo compartido →
  carrera por el subnodo): por eso el walk es *del grafo completo*, no de la
  raíz. Este punto es la diferencia entre F y un «owner-check ingenuo».
- **Semántica del fallo** (v1): error, no autocopia — el coste debe ser
  visible; el mensaje empuja a `.copy()` o `AtomicRef`.
- **Seed**: RT1 no aplica (no hay rc ni fibras) y es **innecesario**: con un
  solo scheduler no hay carrera posible. La semántica de `transfer` en seed
  es move + S1/S2 (v1), documentado como *check sin cruce*.

### 3.5 Mensajes de error (texto exacto para los tests UI)

Formato del repo: `file:line:col: error: <primera línea>` — la primera línea
debe ser **byte-idéntica** en seed y zig **[verificado]** por
`ui_message_parity.sh`; tests con `// EXPECT-ERROR: <subcadena>` (máx. 1 por
fichero) **[verificado]** en `tests/run_tests.sh`.

```text
# ui/transfer_aliased.astra (S2) — rechaza el programa de la crítica
// EXPECT-ERROR: cannot transfer 'a': value is aliased by 'b'

# ui/transfer_used_after.astra (S1)
// EXPECT-ERROR: use of transferred variable 'a'

# ui/transfer_captured.astra (S2, captura de closure)
// EXPECT-ERROR: cannot transfer 'a': value is aliased by closure 'f'

# ui/spawn_global_atomic.astra (S3)
// EXPECT-ERROR: 'worker' reads mutable global 'counter'; declare it Atomic[i64] or pass it as a parameter

# v1 runtime (Phase 2; EXPECT-RUNTIME-ERROR existe ya en run_tests.sh [verificado])
// EXPECT-RUNTIME-ERROR: cannot transfer: value graph is shared (rc=2 at node 1)

# red de v1 (binding nil tras transfer) — mensaje existente de nil, documentado como secundario
# (los errores nil actuales tipan receiver; ver vm.c OPCODE_INDEX)
```

Y los positivos (los dos primeros deben pasar en las 7 rutas; el tercero,
donde exista `AtomicRef` — Phase 2):

```text
# conformance/transfer/transfer_unique.astra    # move legal, EXPECT de salida
# conformance/transfer/transfer_copy.astra      # escape .copy() con alias vivo
# conformance/transfer/transfer_atomic.astra    # AtomicRef compartido (Phase 2)
```

### 3.6 Plan de fases (con gates)

| Fase | Qué | Dónde se ejecuta | Gate de salida |
|:-----|:----|:-----------------|:---------------|
| **0 — hoy** | Este informe → ARCHITECTURE §2.6; fixes de §2.4/§2.5/:31/:875; README 124-125; invariant en AGENTS.md | solo docs | 025-P0.1 cerrado; revisión humana |
| **v1-estático** | S1+S2+S3 en FC y FZ **en el mismo PR que traiga el constructo `transfer`** (y `spawn` cuando entre) | 2 frontends → 7 rutas | `make test` + `zig build test` + `ui_message_parity.sh` + casos nuevos `ui/transfer_*` |
| **v1-runtime** | RT1 walk + invalidación por nil + regla «RT1 es *parte de la definición de hecho* de cualquier feature que ejecute un cruce real» (scheduler/send) | motores M3 y M4 (rutas 3–7); M1/M2 se quedan en estático (move+nil) | conformance con `EXPECT-RUNTIME-ERROR`; en LLVM: paridad 159/159 + `llvm_fuzz.sh` 4 rutas |
| **v2** | S2 ampliado (interproc conservador, liveness de closures) que **elide RT1** cuando prueba unicidad; mensajes con sugerencia | 2 frontends | menos rechazos: tests que pasaban por `.copy()` ahora directos; FileCheck opcional sin `check_unique` |
| **v3** | Regiones (SE-0414: transfer + uso-posterior de la región completa, acepta aliases muertos); `ASTRA_DEBUG_OWNERSHIP=1` (D); benchmark de coste de cruce (`llvm_bench.sh`) | frontends + motores con fibras (D solo en debug) | presupuesto de overhead de cruce escrito y medido |

**Por qué este orden y no «estático primero, siempre»**: lo estático barato
(S1/S2/S3) es *necesario* antes de que existan cruces (si no, la crítica
tiene razón: sería un deseo); lo runtime (RT1) es *necesario* en el momento
en que un cruce sea real porque es el que garantiza ante alias invisibles.
Ninguna fase deja una ventana: `transfer` sin S2 sería insound (por eso S2
entra *con* el constructo), y un scheduler sin RT1 sería insound (por eso
RT1 es gate de la feature de scheduling, no «después»).

---

## 4. Plan de migración (docs y tests, en orden)

Orden por dependencia: **la spec antes que los tests, los tests antes que el
código** (la crítica 025 §3.2: «las decisiones se toman en tests, no en la
especificación» — esto lo invierte).

**Paso 1 — `Documentacion/01_lenguaje/ARCHITECTURE.md` (spec):**

1. **Nuevo `### 2.6 Enforcement de «una fibra a la vez» (decisión del
   2026-10-27)`** — texto de §3.1–§3.5 de este informe (reglas R1–R7, las 5
   vías, costes). Responde explícitamente a la pregunta abierta de §2.5
   («…y si un agregado puede cruzar una frontera de fibra», `:86-90`).
2. **§2.4** (`:50-57`): la fila *Move Semantics* pasa de «Invalida la
   variable emisora» a «Invalida la variable emisora **y exige unicidad del
   grafo (§2.6); si no, error → `x.copy()` o `Atomic[T]`**». La fila
   *Inmutabilidad por Defecto* ganará una nota: `let` ≠ inmutable profundo
   mientras §2.5 comparta handles (enlazar a la decisión adyacente de
   `let`/alias, 025 §2.8 — **no se resuelve aquí**).
3. **§2.5** (`:60-90`): añadir alcance — «compartir es **intra-fibra**;
   el cruce se rige por §2.6». El test que lo fija (`alias_write.astra`)
   **se mantiene idéntico**. La lista «Lo que NO especifica todavía»
   (`:86-90`) se marca: *cruce de frontera → resuelto en §2.6*; quedan
   `cuándo se libera un handle compartido` y `qué hace .copy()` → anotar
   `.copy()` = deep copy §2.6.
4. **`:31`** — dejar de ser «medio nombrada»: referenciar §2.6 como
   normativa (deep copy / AtomicRef = escapes oficiales).
5. **`:118` (§3.3)** — alinear con §2.6 (mismo texto de regla).
6. **`:875`** — «**ARC/ORC atómico + regla de unicidad §2.6** — Thread-safe
   sin borrow checker» (hoy *«ARC/ORC atómico — Thread-safe sin borrow
   checker»* sugiere que el rc atómico *por sí solo* da thread-safety; §2.3
   de 025 ya demostró que no).
7. **§30.5** (`:1762-1773`) — nota: captura por valor copia el **handle**;
   un capture es un alias raíz para §2.6 (evidencia empírica §1-C).
8. **§35.5** (`Send`/`Sync`) — `Send` para agregados = cumplir §2.6.

**Paso 2 — `README.md` (honestidad, mandato 025-P0.4):**

- `:124` `[x] Memory model (ARC/ORC, cycle detection, fiber-aware)` →
  desmarcar el sub-claim `fiber-aware` (hoy `grep fiber|scheduler|spawn` →
  **0 [verificado]** en ambos árboles); `:125` `[x] Concurrency model (green
  threads, channels, atomics)` → `[ ]` hasta que exista código.
- `:21` — se mantiene *literalmente* verdadero con F (sin borrow checker, sin
  pausas de GC); añadir al Design Goals una fila
  **«Fiber Ownership Enforcement — §2.6: shared within a fiber, verified
  unique on every fiber crossing»** para que la promesa de concurrencia
  tenga mecanismo nombrado, no solo adjetivos.

**Paso 3 — `AGENTS.md` + índice:**

- Invariant **#8** (junto a los 7 existentes): *«Cualquier feature que mueva
  handles entre fibras es una frontera y DEBE llevar su check (S2/RT1) en el
  mismo PR; el enforcement vive en ARCHITECTURE §2.6 — un backend no puede
  implementar semántica de cruce propia»*.
- `Documentacion/00_indice/INDICE.md`: registrar `026` («001–025» →
  «001–026», conteo 25 → 26; estado actual **[verificado]** en `:25,:80,:90`).

**Paso 4 — Tests (en este orden):**

1. **`seed/tests/conformance/arrays/alias_write.astra` — NO se modifica**
   (decisión explícita; su comentario puede ganar «intra-fiber scope
   (ARCHITECTURE §2.6)» cuando el paso 1 aterrice).
2. **Al entrar `transfer` (v1 estático)**: `ui/transfer_aliased.astra`,
   `ui/transfer_used_after.astra`, `ui/transfer_captured.astra`,
   `ui/spawn_global_atomic.astra` (textos de §3.5) + positivos
   `conformance/transfer/transfer_unique.astra` y `transfer_copy.astra`.
   Gate: `ui_message_parity.sh` (exige FC y FZ con el mismo texto).
3. **Al entrar la primera frontera real (v1 runtime)**:
   `EXPECT-RUNTIME-ERROR` para RT1 (ya soportado por `run_tests.sh`
   **[verificado]**) — en los motores M3/M4. *Decisión pendiente a resolver
   en ese momento*: `run_tests.sh` ejecuta hoy **toda** `tests/conformance/`
   en el seed; un caso con fallo RT1 solo puede existir en la suite Phase 2
   (el seed no tiene rc), así que o los tests de cruce viven en una suite
   Phase 2 o el seed crece hasta ellos — anotarlo en la Fase 2 de
   `PHASE2_PROGRESS.md`. En LLVM: paridad 159/159 y `llvm_fuzz.sh`.
4. **v2**: los tests que hoy exigirían `.copy()` pasan a directos — mover,
   no duplicar; añadir un FileCheck opcional en `zig/tests/llvm/` que pille
   la ausencia del helper cuando S2 prueba unicidad.

**Paso 5 — docs de estado**: `PHASE2_PROGRESS.md` y
`LLVM_BACKEND_PLAN.md` ganan el gate «isolation check» en su lista de
puertas; `COMPARATIVE_ANALYSIS.md:131` (40 % Nim) gana la frase «Astra solo
paga átomos en lo que cruza (R3/R7)»; roadmap de README pasa de binario
`[x]` a hecho/implementado/especificado (025-P2.7).

---

## 5. Matriz de decisión final

Costes: **S/M/L/XL** = pequeños/medios/…; «sitios» = dónde hay que
implementar (2 frontends para estático; hasta 4 motores para un check
runtime de Astra-0 — en la práctica RT1/D solo donde hay fibras: 2 motores;
7 rutas cubiertas en ambos casos).

| Opción | Garantía «una fibra a la vez» | Coste estático (sitios) | Coste runtime (sitios) | Esfuerzo total 7 rutas | Encaje pitch (README/ARCHITECTURE) | `alias_write.astra` | Closures que capturan | Veredicto |
|:-------|:------------------------------|:------------------------|:-----------------------|:-----------------------|:-----------------------------------|:--------------------|:----------------------|:----------|
| **A. Tracing GC** | **No** (carreras siguen — Go `-race` demo **[verificado]**) | S (0) | L–XL (GC en AIR + M3/M4; el seed arena no cambia) | **XL** | **✗ Rompe** «sin pausas de GC» | intacto | trivial | ✗ |
| **B. RC atómico, carreras aceptadas** | **No** (solo el contador) | S (0) | M (átomos donde hay rc: Phase 2 — Astra-0 no tiene rc) | M | **✗ Rompe** «thread-safe»; 40 % Nim citado | intacto | trivial | ✗ como modelo (✓ como componente) |
| **C. Unicidad/move condicional + deep copy** | **Sí**, si el análisis es sonido (riesgo: falsos negativos = carreras silenciosas) | **M–L (2 frontends)** | S (copia en 4 motores — necesaria de todos modos) | M–L | ✓ es el modelo de Nim, el pitch de Astra | **intacto** si el check es solo en frontera (roto si move-por-defecto: reescribir con `.copy()`) | **caso duro** — captura = alias; regla conservadora | ✓ como base |
| **C'. Copy automático en el cruce** (sin check) | **Sí** (para vías 1–3) — pero ¿globales? → necesita R5 igual | S (S3) | M (copia silenciosa = cliffe de perf invisible) | S–M | ∼ (pérdida de cero-copia no *explicitada* al programador) | intacto | trivial (copia) | ∼ «barata pero opaca» |
| **D. Owner-check por acceso (runtime)** | **Sí** (módulo unsafe) | S (0) | **L-permanente (M3+M4: 1 check por cada acceso a agregado, camino caliente)** + campo `owner` en headers (el seed ni headers tiene **[verificado]** → D imposible en Astra-0 sin rediseñar valores) | M | ∼ cumple «thread-safe», falla «sin coste» | intacto | sin problema | ✗ base ( ✓ red de debug ) |
| **E. Sin mutable compartido (copia/canales)** | **Sí** por construcción (vías 1–3 + R5) | S (S3) | M (copia por mensaje) | S–M | **✗ Rompe** «fibras que comparten datos» / cero-copia | intacto | trivial | ∼ garantía barata, pitch caro |
| **F. Híbrido C+D escalonado (recomendada)** | **Sí** — estático donde se prueba, RT1 de grafo donde no, D en debug | **M (2 frontends)** | **S: O(grafo) solo por cruce (M3+M4), 0 por acceso** | **M** | **✓** ARC/ORC + el deep copy de `:31` + promoción atómica quedan *normativos* | **intacto (se re-documenta, no se reescribe)** | ✓ (rc del env + regla de captura) | **✓ ELEGIDA** |

**Justificación final de F sobre sus competidoras más cercanas:**

1. **F vs C**: C solo es *sonoro* si el análisis nunca falla hacia «únicos»;
   un bug ahí sería una carrera **silenciosa**. F descansa la corrección en
   RT1 (oracle runtime, no análisis) y usa lo estático para UX y para elisión
   — misma potencia, riesgo de sonoridad acotado.
2. **F vs D**: D cobra peaje en *cada acceso* de las 7 rutas para siempre y
   solo erra en runtime; F cobra en *cada cruce* (O(grafo) ≤ copia) y erra en
   compile-time en los casos definidos. D queda como assert de debug donde su
   coste no importa.
3. **F vs E**: F contiene a E (`.copy()` *es* E como escape explícito) y
   añade el move cero-copia cuando eres único — no pierde ninguna garantía
   de E y sí su coste de ergonomía.
4. **F vs A/B**: descartadas con ejecución, no con argumento (§1).
5. **Presupuesto honesto**: el único coste *nuevo* no existente ya en el
   roadmap es (i) 1 pass estático × 2 frontends, (ii) 1 walk por cruce × 2
   motores Phase 2 (junto a la feature de cruce, no antes), (iii) `.copy()` deep
   (que `ARCHITECTURE.md:31` ya lista). Ninguno toca el camino caliente por acceso; ninguno
   introduce pausas; ninguno exige lifetimes.

**Confianza de esta recomendación: media-alta**, calibrada así: la
completitud del argumento R3+R5 y los costs por ruta están anclados a código
verificado del repo; la parte que **no** está probada es el comportamiento en
producción del walk rc (todavía no hay ARC ni fibras — la crítica apunta
exactamente ahí, y por eso RT1 es *gate* de la feature de fibras, no un
«después»). La evidencia de que el check mínimo rechaza el programa está
verificada para Rust/Go locales y para Nim/Pony/Swift/GHC en sus documentos
oficiales; **no** ejecuté los compiladores de Nim/Pony/Swift (no instalados).

---

## 6. Metodología y límites de la búsqueda

```text
PREGUNTA: qué modelo de enforcement aplica «una fibra a la vez» en Astra
          sin borrow checker ni GC — y qué check mínimo rechaza el
          programa a/b/transfer de la crítica 025.
========================================
Fuentes buscadas:
  - Repo: ARCHITECTURE.md, README.md, AGENTS.md, 025, seed/src (+ tests),
    zig/src, run_tests.sh, ui_message_parity.sh, construct registry.
  - Online (fetch directo; websearch → HTTP 403): nim-lang.org/docs
    (manual, destructors.html, isolation.html), tutorial.ponylang.io
    (aliasing, consume-and-destructive-read), Swift SE-0414 (github raw),
    GHC user guide (linear_types).
  - Ejecutables locales: rustc, go, seed (make + make test).
Rango de fechas: docs externas leídas el 2026-10-27 (versiones mostradas:
  Nim 2.2.12, GHC 9.15 dev, SE-0414 Implemented/Swift 6.0); repo = HEAD
  2026-10-27 (234 commits).
Criterios de inclusión: fuente primaria (doc oficial o código del repo);
  enfoque en el caso EXACTO a/b/transfer. Excluidos: blogs, rankings,
  segundas manos (no aportan verificabilidad con websearch caído).
Resultados: 4 lenguajes verificados en su doc oficial (Nim, Pony, Swift,
  Haskell) + 2 ejecuciones empíricas (rustc, go); Clean queda [verificado
  parcial: clean.cs.ru.nl solo confirma «uniqueness typing»];
  Nim/Pony/Swift no ejecutados (no instalados) → mensajes exactos [citado].
```

**Lo que NO se encontró** (hallazgos de vacío, no ausencias de la revisión):

- **No existe ningún mecanismo de enforcement en el código** — repetido y
  confirmado en esta sesión: `transfer` 0 apariciones reales en `seed/src` y
  `zig/src`; `fiber|scheduler|spawn|channel` → 0 en ambos **[verificado]**;
  registry `0/47` **[verificado con `--check-constructs`]**.
- **No hay coste escrito del overhead de cruce** en ninguna parte de la doc
  (§3.4–§3.6 de este informe son el primer presupuesto).
- **No hay test que ejercite un cruce de fibra** — imposible hoy: no hay
  fibras. El plan de §4 los ata a la feature, no al revés.

---

## 7. Reproducción (todos los `[verificado]` de este informe)

```bash
# Estado base del seed: 260/260
cd /home/aster/Astra/seed && make && make test        # -> passed: 260  failed: 0

# Registry
./seed/astra-seed --check-constructs                   # -> migrated (all three phases): 0 / 47

# Ausencias (repo root)
grep -rn '"transfer"' seed/src zig/src                 # -> 0
grep -rn  'fiber\|scheduler\|spawn' seed/src zig/src   # -> 0 (ni siquiera en comentarios)

# Semántica de handles (ejecutados en /tmp/opencode/astra-critica/enforcement/)
S=/home/aster/Astra/seed/astra-seed
$S alias_write.astra        # -> 99 99   (§2.5 intacta)
$S closure_alias.astra      # -> 1 / 42  (la captura copia el HANDLE: el alias atraviesa)

# Opción A descartada empíricamente (Go + tracing GC)
go run -race go_race.go     # -> WARNING: DATA RACE ... Found 1 data race(s)

# Opción C: el check mínimo de Rust rechaza el programa
rustc --edition 2021 rust_move.rs    # -> error[E0382]: use of moved value: `a` (en transfer(a))
rustc --edition 2021 rust_borrow.rs  # -> error[E0499]: cannot borrow `a` as mutable more than once

# Anclas de implementación citadas
grep -n "OPCODE_SET_INDEX" seed/src/vm.c seed/src/codegen.c    # vm.c:1212, codegen.c:1146
grep -n "AstraLLVMHdr" zig/src/llvm/runtime/astra_runtime_llvm.c  # :43 {int32 rc; int32 kind}
grep -n "tc.check" zig/src/main.zig                            # :278 (single), :567 (modules)
head -40 zig/tests/ui_message_parity.sh                        # primera línea byte-idéntica
```

Programas de reproducción (íntegros en
`/tmp/opencode/astra-critica/enforcement/`): `alias_write.astra`,
`closure_alias.astra`, `rust_move.rs`, `rust_borrow.rs`, `go_race.go`.

---

## 8. Referencias internas

- `Documentacion/07_investigacion/025_critica_externa_seguridad_y_proceso.md`
  §2.1–§2.5, §3.1, §4 (el espacio A–E que este informe cierra con F)
- `Documentacion/01_lenguaje/ARCHITECTURE.md` §2.1–§2.5, `:31`, `:118`,
  `:875`, §30.5, §35.3–§35.5
- `Documentacion/01_lenguaje/COMPARATIVE_ANALYSIS.md:30,131`
- `seed/tests/conformance/arrays/alias_write.astra` (test-pinning de §2.5)
- `seed/tests/run_tests.sh` (EXPECT-ERROR / EXPECT-RUNTIME-ERROR)
- `zig/tests/ui_message_parity.sh` (paridad de mensajes seed↔zig)
- `AGENTS.md` (7 rutas, invariantes, gates de backend)
- Fuentes externas primarias (fetch 2026-10-27): Nim `destructors.html`,
  Nim `std/isolation`; Pony tutorial `aliasing`, `consume-and-destructive-read`;
  Swift SE-0414 (region-based isolation, Implemented 6.0); GHC 9.15
  `linear_types`

---

## Verificación externa (2026-10-27)

`websearch` volvió a fallar (HTTP 403) en esta sesión; la verificación se hizo
con `webfetch` a URLs directas.

**Cambió esta sesión:**

- **[verificado]** «pausas <1 ms desde Go 1.8» (§1 Opción A) → go.dev/doc/go1.8:
  la nota oficial dice *«usually under 100 microseconds and often as low as 10»*,
  o sea más fuerte que la cifra citada (nada la contradice).
- **[verificado]** «Swift 6 añadió verificación en compile-time» (§1 Opción B) →
  SE-0302 (las restricciones son *warnings* en Swift 5 y errores en Swift 6) +
  SE-0414 *Status: Implemented (Swift 6.0)*.
- **[verificado]** Nim (§2 fila Nim) → `nim-lang.org/docs/isolation.html`
  («Isolation is checked at compile time», `Isolated[T] =copy` `{.error.}`,
  RFC nim-lang/RFCs#244) y `docs/destructors.html` («limited … only concerned
  with local variables»); reproducido también en la sesión previa.
- **[verificado]** Pony (§2 fila Pony) → `tutorial.ponylang.io/reference-
  capabilities/aliasing/` («the `iso` reference capability denies other `iso`
  variables that point to the same object»; `var b: Wombat iso = a // Not
  allowed!`) y `/guarantees/` («By ensuring this situation can never occur,
  Pony eliminates the need for locks»).
- **[verificado]** Rust E0382/E0499 → `doc.rust-lang.org/error_codes/` +
  rustc 1.99.1 local; **[verificado parcial]** precedencia NLL (RFC 2094
  aceptado 2017-09-29, `api.github.com/repos/rust-lang/rfcs/pulls/2094`).
- **[verificado parcial]** Clean → `clean.cs.ru.nl` (wiki oficial) confirma
  «uniqueness typing» como característica; la semántica de la asignación no.

**Sigue [citado]:** los mensajes exactos de `nim` y `swiftc` (no instalados),
la medición original del «40 % de Nim con `--threads:on`» (la cifra está en
`COMPARATIVE_ANALYSIS.md:131`, su fuente no se localizó) y «RC atómico protege
solo el contador» (§2.3).
