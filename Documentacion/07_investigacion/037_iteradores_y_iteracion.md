# 037 — Iteradores y protocolos de iteración: cómo los hacen y qué le conviene a Astra

> **Alcance**: dossier sobre los modelos de iteración — protocolos pull vs
> push, lazy vs eager, rangos, adapters, invalidación y sintaxis de bucles —
> en Rust, Python, C++, JavaScript, Java, C#, Swift, Kotlin, Go, Elixir, Ruby,
> Julia, Haskell y Zig. Incluye un **reality-check de `research/015` §4**
> (la propuesta previa de «lazy iterators estilo Rust» para Astra) contra el
> comportamiento medido del seed. **No cambia ningún comportamiento.** Fecha:
> **2026-10-29**. `[verificado]` = ejecutado o leído en esta sesión (Debian,
> HEAD `f86fb4c`, worktree `Astra-wt/int-types`); `[citado]` = fuente externa
> con URL en §14.

---

## §0 — TL;DR

1. **Toda iteración resuelve lo mismo** (recorrer una secuencia) con 5
   decisiones independientes: ¿protocolo de usuario? (interfaz dinámica /
   trait monomorfo / closure push / ninguno), ¿lazy o eager?, ¿rangos
   inclusivos o exclusivos?, ¿quién invalida a quién?, ¿qué sintaxis de
   bucle hay (`loop`, `break` con valor, labels)?
2. **La tendencia 2015-2025 es «protocolo lazy con adapters»**: C++20
   ranges/views, Java Streams, Kotlin Sequences, C# LINQ, Rust `Iterator`,
   y en 2023-2024 lo último en sumarse fue **Go** (range-over-func +
   paquete `iter`, Go 1.23 `[verificado: release notes]`) y **JS**
   (Iterator Helpers). El único gran disidente es **Zig** (sin iteradores:
   `for`+`while` y punto) — y su posición está documentada en
   `research/015` §4.1.
3. **Pull (`next()`) vs push (`yield`)**: pull (Rust/Python/C#/Java) es
   sincrónico y compone con `break`; push (Go 1.23, corutinas) evita la
   interfaz y compone con closures pero el `break` lo maneja el iterador
   (`yield` devuelve `false`). Go eligió push expresamente tras rechazar la
   interfaz de iteradores `[citado: Go 1.23 notes]`.
4. **Rangos: el primer split histórico** — exclusivos `0..n` (Rust, Python,
   JS, Swift, Astra `[verificado]`) vs inclusivos `1..=n`/`1:n` (Julia,
   Kotlin, Ruby, Elixir) vs con step (`1..10//2` de Elixir, `range(1,10,2)`
   de Python). Astra ya es exclusivo pero **el rango aún no es un valor**
   (§13.1).
5. **Invalidación de iteradores**: C++ la deja en UB, Java lanza
   `ConcurrentModificationException`, .NET estampa versión, Python lanza
   `RuntimeError`, y **Rust la elimina del sistema** (el préstamo impide
   mutar mientras se itera) — el mejor ejemplo de «seguridad por diseño de
   tipos».
6. **Astra hoy** `[verificado, 8 probes]`: `for..in` sobre arrays, strings
   (byte a byte, DEC-020) y rangos `0..5` (exclusivo) funciona; `while`,
   `break`, `continue` existen; pero **el rango rechaza ser valor**
   (`range expression is only valid as a for-loop iterator`), **no hay
   `loop`** y **`break` con valor está rechazado con mensaje propio**
   (`break with a value is not supported in Astra-0`). No hay protocolo de
   iterador para tipos de usuario — que es exactamente lo que `research/015`
   §4 propone.

---

## §1 — Anatomía de una iteración

Toda solución de iteración se puede describir con 5 ejes:

| Eje | Opciones | Quién lo usa |
|:----|:---------|:-------------|
| **Protocolo** | interfaz dinámica (`next()`), trait monomorfo, closure push (`func(yield)`), ninguno (sintaxis builtin) | Java/C#/JS vs Rust/Zig vs Go vs Zig/SQL |
| **Evaluación** | lazy (cada `next` produce uno) vs eager (construye la lista completa) | Rust/Python-genexp vs listcomp/Python-2 |
| **Rango** | exclusivo `a..b`, inclusivo `a..=b`/`a:b`, con step | Rust/Python/JS/Swift vs Julia/Kotlin/Ruby/Elixir |
| **Invalidación** | UB, excepción, versión, imposible por tipos | C++ vs Java/.NET vs Python vs Rust |
| **Sintaxis de bucle** | `for..in`, `while`, C-style `for`, `loop`-expr, `break` con valor, labels, `do..while` | todos mezclan distinto |

Un lenguaje puede ser moderno en un eje y conservador en otro: C++20 es
state-of-the-art en ranges pero mantiene el `for(;;)` de 1985 y la
invalidación en UB.

## §2 — Rust: el «gold standard» (y por qué)

`research/015` §4.1 lo llama «the gold standard»; el Rust Book ch. 13
`[citado]` documenta el contrato completo:

```rust
pub trait Iterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
    // + 70+ métodos con implementación por defecto (adapters)
}
```

- **`for` es azúcar**: desugara a `loop { match iter.next() { Some(x) => …, None => break } }` — el `for` toma propiedad del iterador y lo vuelve mutable detrás.
- **Lazy total**: `v.iter().map(f)` no hace nada hasta un consumidor
  (`sum`, `collect`, `for`) — el compilador avisa `unused Map that must be used`.
- **Tres verbos de acceso**: `iter()` (por `&T`), `iter_mut()` (por `&mut T`),
  `into_iter()` (consume, devuelve `T` dueños) — la distinción de ownership
  es parte del protocolo.
- **Adapters monomorfizados**: `map`/`filter`/`take`/`zip`/`enumerate`/
  `chain`/`peekable`… son structs genéricos; tras inlining, el código es
  idéntico al bucle manual (la promesa «zero-cost»). Consumidores:
  `sum`, `collect`, `any`, `fold`, `count`.
- **Sin invalidación posible**: no puedes mutar la colección mientras
  tienes el iterador (el préstamo lo impide en compile-time) — sin CME, sin
  version stamps, sin UB.
- **Sintaxis asociada**: `loop` **como expresión** (devuelve valor),
  `break 'label valor`, rangos `0..10` (exclusivo) y `0..=10` (inclusivo);
  **no hay C-style `for`** ni `do..while` (el `while true { … }` + `break`
  o `loop` los sustituyen).

## §3 — Python: generadores como lenguaje de primera clase

- **Generadores** (`yield`): funciones perezosas — PEP 380 añadió
  `yield from` (delegación, la base de las corutinas `async/await` de
  3.5+). `[citado: peps.python.org/pep-0380]`
- **Comprensiones**: `[…]` es **eager**, `(…)` es **lazy** — la misma
  sintaxis, dos semánticas; el bug clásico de «el genexp se consumió una
  vez».
- **Protocolo**: `__iter__`/`__next__` dinámico (cada paso = lookups de
  métodos → ~10× más lento que un `for` C, pero cómodísimo). `itertools`
  (chain, islice, groupby, batched desde 3.12) + `functools.reduce`.
- **Exhaustión**: un generador se consume una vez (`StopIteration`); los
  bucles de Python son también el protocolo `for..in` genérico (listas,
  dicts, rangos, ficheros).

## §4 — C++: de los iteradores crudos a los ranges (2020)

- **Clásico (1998-)**: pares `begin/end`, conceptos implícitos
  (Input/Forward/Bidirectional/RandomAccess), y **la mancha**: invalidar
  iterators al reasignar un `vector` = UB si sigues usándolo.
- **C++20 ranges/views** `[citado: cppreference]`: `std::ranges::filter_view`,
  `take`, `transform`, pipelines **lazy** de una expresión
  (`v | views::filter(…) | views::transform(…)`), algoritmos con proyecciones
  (`ranges::sort(v, {}, &Persona::edad)`), **sentinels** (fin de tipo
  distinto → permite ranges finitos-infinitos como `views::iota(0)`).
  Heredero directo de **range-v3** (Eric Niebler, 2013-2018).
- **Coste**: templates puro = cero en runtime; el precio es **tiempo de
  compilación** (instanciaciones) y tamaño de binario — el mismo trade-off
  de los genéricos monomorfizados (§13 de `035` no aplica: aquí es el bando
  Zig/Rust).
- **C++23/26**: `ranges::to<T>()` para materializar; `views::zip` etc.
  siguen creciendo. El C-style `for(;;)` convive — nadie lo toca.

## §5 — JavaScript: el protocolo de objetos iterable (ES2015)

- **`Symbol.iterator`**: cualquier objeto con `[Symbol.iterator]()`
  devuelve un iterador con `next() -> {value, done}`. `for..of`, spread
  `[...]`, destructuring, `await for` consumen ese protocolo.
- **Generadores** (`function*`/`yield`): lazy, además permiten `next(v)` /
  `throw(e)` (los dos lados de la corutina — el protocolo que luego
  `async/await` estandarizó).
- **Trampa conocida**: `for..of` sobre un Map/Set itera en orden de
  inserción, pero `for..in` itera claves (prototipo incluido) — dos
  sintaxis, semánticas distintas.
- **Iterator Helpers (TC39, ES2025)** `[citado: tc39.es/proposal-iterator-helpers]`:
  `.map()/.filter()/.take()` sobre los propios iteradores de JS — el ecosistema
  se sumó al modelo lazy diez años tarde.

## §6 — Java: interfaces dinámicas + Streams con fusión

- **`Iterable<T>`/`Iterator<T>`** (1998): `hasNext/next` — el protocolo
  pull original, con **`ConcurrentModificationException`** como castigo por
  mutar durante la iteración (fail-fast por modCount).
- **`for..of` → `for..in`** (1995): `for (Type x : collection)` reemplazó
  al C-style.
- **Streams (8)**: pipelines **lazy** con fusión de operaciones
  (stateless: map/filter/flatMap se fusionan en un solo pipeline; la
  terminal ejecuta todo de golpe), `collect` como consumidor, y el coste
  de las primitivas: `IntStream/LongStream/DoubleStream` existen porque
  `Stream<Integer>` autoboxea (el lambdas-vs-generics de 2014, resuelto a
  medias). `[citado: Oracle Java Tutorials]`
- **`parallelStream`**: el «gratis» que no lo es (ForkJoinPool, splitting,
  y sorpresas de orden/estado compartido).
- **Java 21**: `SequencedCollection` (`getFirst/getLast/reversed`) — la
  colección-secuencia explícita que faltaba.

## §7 — C#: `yield return` (2005) y LINQ — el pionero del lazy mainstream

- **`yield return`/`yield break`** (C# 2.0, 2005): el compilador fabrica
  la máquina de estados — el primer generador mainstream moderno (anterior
  a Python 3 generators como estándar de lenguaje ampliamente adoptado).
- **`IEnumerable<T>`/`IEnumerator<T>`**: pull; **`foreach`** usa el
  *pattern-based* `GetEnumerator()` — cuando el enumerator es **struct**
  (como `List<T>.Enumerator`) el JIT lo desvirtualiza y no hay allocación.
- **LINQ**: lazy por diseño (`Select/Where` no ejecutan hasta `ToList`/
  `foreach`) — y la trampa educada «multiple enumeration» (recorrer dos
  veces un `IEnumerable` re-ejecuta la consulta; con `IQueryable` hasta va
  a la BD otra vez).
- **`IAsyncEnumerable` + `await foreach`** (C# 8): el pull lazy con
  `await` por ítem — el modelo que adoptó también Rust *post-1.0* para async.

## §8 — Swift: `Sequence`/`Collection` y el coste del type erasure

- **Tres niveles**: `Sequence` (una vez, sólo-forward), `Collection`
  (índices O(1), múltiples pasadas), `BidirectionalCollection`/
`RandomAccessCollection` — la jerarquía de capacidades es el protocolo.
- `for x in seq` usa `makeIterator()`; **`AnyIterator`/`AnySequence`**
  (type erasure) cuestan una llamada indirecta por paso — Swift prefiere
  generics (`some Sequence`) para no pagarla.
- **`LazySequence`/`.lazy`**: como Ruby, el lazy es **opt-in por adapter**
  (`a.map(f).filter(g)` es eager; `a.lazy.map(f).filter(g)` es lazy) —
  la filosofía opuesta a Rust (lazy por defecto en el iterador).
- Rangos: `0..<10` exclusivo, `1...10` inclusivo — dos operadores
  distintos en la sintaxis (ni Rust `..=` ni el signo único).

## §9 — Kotlin: Iterable (eager) vs Sequence (lazy) — dos mundos explícitos

- `List.map{}` devuelve **lista nueva** (eager); `list.asSequence().map{}`
  es **lazy** hasta `toList()` — la dualidad está en el tipo, no en la
  comprensión (a diferencia de Python, donde está en los paréntesis).
- Rangos inclusivos `0..9` por defecto, `0 until 9` exclusivo (¡al revés
  que Rust/Python!), `1..10 step 2` con step. `forEach` existe pero
  `for..in` sigue siendo el idiomático (Klingon: «`forEach` es un anti-patrón
  en Kotlin» — JetBrains lo desaconseja por estilo).
- **`Flow`**: el Sequence async (cold, lazy, cancellable) — el mismo modelo
  pull para streams reactivos.

## §10 — Go: del «no hay iteradores» a push-based (1.23)

- **2009-2021**: sólo `for i, v := range slice/map/string` — sin
  iteradores de usuario, sin `while` (hay `for` único con tres formas),
  sin `do..while`.
- **Go 1.22**: `for i := range 10` (range sobre enteros).
- **Go 1.23** `[verificado: release notes de tip.golang.org/doc/go1.23]`:
  `for` acepta **funciones iterator** `func(func(K) bool)` como expresión
  de rango — **push-based**: el iterador llama a `yield` y `yield` devuelve
  `false` cuando el cuerpo hace `break`; más el paquete `iter`
  (`Seq`/`Seq2`) y helpers perezosos en `slices` (`All`, `Values`,
  `Backward`, `Collect`, `Sorted`, `Chunk`) y `maps` (`Keys`, `Values`,
  `Collect`).
- **Por qué push**: la discusión de 2022 rechazó la interfaz de
  iteradores (¿`nil`? ¿estado? ¿interfaces de 1 método de vuelta?) y
  eligió closures — composición trivial con `defer`, sin métodos nuevos en
  cada tipo, y el control de flujo (`break`/`return` del cuerpo) vuelve al
  iterador como `false`. **La contra** conocida: no se puede «reanudar» un
  push-iterator sin estado extra (un pull se guarda solo; un push necesita
  que el iterador guarde el punto de suspensión — en Go, el `yield` vive
  dentro del `for`, así que el estado queda en las variables del closure).
- **Go sigue sin adapters** en std: `slices.All` itera, pero no hay
  `.map().filter()` encadenable — la composición es con funciones
  (`func f(seq iter.Seq[int]) iter.Seq[int]` que envuelven).

## §11 — Otros modelos (breve)

- **Elixir/Erlang**: `for` es **eager** (comprehension), pero `Stream`
  (perezoso, `Stream.iterate |> Stream.map |> Enum.take`) + `Enum` (30+
  funciones) son el stdlib; la iteración «real» idiomática sigue siendo la
  **recursión con TCO** (Erlang no tiene bucles `while` en absoluto).
- **Ruby**: `each` + `Enumerable` (mixins), `Enumerator` (lazy, puede
  reanudarse), `.lazy` desde 2.0; rangos **inclusivos** `(1..10)` con
  `(1...10)` exclusivo (¡al revés que Kotlin!).
- **Julia**: protocolo `Base.iterate(state)` (stateful, sin `next` de
  instancia), rangos `1:10` **inclusivos y 1-based** (con `1:2:9` y
  `range(a, b, length=n)`), `eachindex` para no asumir 1-based.
- **Haskell**: listas **infinitas por defecto** (`[1..]`, `take 10
  (map f [1..])`) — el lazy puro total; `unfoldr` como constructor.
- **Zig**: sin protocolo: `for (items) |item|`, `while` con índice manual,
  `std.mem` con callbacks; la postura (simpleza, sin magic) está
  documentada en `research/015` §4.1 con las libs de comunidad
  (ziter/Zigerator).
- **SQL/SQL-adjacent**: `generate_series`, `UNNEST`, window functions —
  la iteración declarativa sin bucles (referencia de contraste: el
  lenguaje «itera» por ti).

## §12 — Tablas comparativas

### 12.1 Rangos: inclusivo vs exclusivo

| Exclusivo `a..b` | Inclusivo `a..b` | Doble |
|:-----------------|:-----------------|:------|
| Rust `0..10` · Python `range(10)` · Swift `0..<10` · **Astra `0..5` = 0..4 `[verificado]`** · C# `Enumerable.Range(0,10)` (por conteo: da 0..9) · JS no tiene rango nativo (`Array.from({length:n})`, lodash `range`) | Julia `1:10` · Kotlin `0..9` · Ruby `(1..10)` · Elixir `1..10` · Lua `for i=1,10` | Kotlin `0 until 9` = exclusivo; Ruby `(1...10)` = exclusivo — **cada uno eligió el símbolo opuesto** |

### 12.2 Invalidación de iteradores

| Lenguaje | Mecanismo | Precio |
|:---------|:----------|:-------|
| C++ | UB si usas un iterator tras invalidarlo | bugs silenciosos, el clásico |
| Java | `ConcurrentModificationException` (fail-fast) | excepción en runtime |
| .NET | estampa de versión → `InvalidOperationException` | excepción, a veces sorpresiva |
| Python | `RuntimeError: dictionary changed size` | excepción |
| **Rust** | **imposible por tipos** (préstamo) | 0 (compile-time) |
| Go | sin iteradores de puntero: `range` copia clave/valor | copy por iteración |

### 12.3 Pull vs push

| Pull (`next()`) | Push (`yield`/callback) |
|:----------------|:------------------------|
| Rust `Iterator`, Python generadores, Java `Iterator`, C# `IEnumerable`, Swift `Sequence` | Go 1.23 `iter.Seq`, JS generators (híbrido: son push con reanudación), Kotlin `Flow` (pull sobre channel) |
| compone con `break` natural; reanudación gratis | compone con closures; sin interfaz por tipo; `break` = `yield→false` |
| estado = el objeto iterador | estado = cierres/variables del cuerpo |

### 12.4 Formas de bucle presentes

| Forma | Dónde vive |
|:------|:-----------|
| `for x in seq` | Rust, Python, JS, Swift, Kotlin, Go, **Astra** `[verificado]` |
| C-style `for(init;cond;step)` | C, C++, Java, C#, JS, **Go** (una de las 3 formas de su `for` único) — **eliminado** en Rust/Swift/Zig |
| `while` | casi todos (no en Smalltalk: solo `whileTrue:`) |
| `do..while` | C/C++/Java/C#/Swift(`repeat`)/JS — **no** en Rust/Go/Zig/Python |
| `loop` como expresión | **Rust** (`loop { … break value }`); **Zig** (`while`/bloque etiquetado como expresión con `break valor`) |
| `break` con valor | Rust (`break 'l valor`), Zig — **Astra lo rechaza explícitamente** `[verificado]`; no lo tienen Go, Java, C#, Python |
| labels (`break outer`) | Rust, Kotlin (`break@l`), Java, Go, JS, Swift — C# sólo vía `goto` |
| recursión como bucle | Erlang, Haskell, Scheme (TCO) |

*(Precisión: en Go, `break` no lleva valor; el valor del range-over-func
sale por el cierre, no por `break` — verificado en las release notes de
§10.)*

## §13 — Síntesis: las cinco decisiones y su precio

1. **Protocolo monomorfo (Rust/C++/Zig) vs dinámico (Java/C#/JS/Python)**:
   monomorfo = cero coste + inlining total, paga en binario/tiempo de
   compilación y en «no puedes guardar una cadena heterogénea sin `dyn`»;
   dinámico = flexible (colecciones mixtas, plugins), paga una llamada
   indirecta por paso y a menudo allocaciones.
2. **Lazy por defecto (Rust/C#/Java-Streams) vs eager por defecto (Python
   listas, Kotlin Iterable, Swift)**: lazy evita temporales y permite
   pipelines infinitos (`take` de un generador infinito); eager es
   predecible y simple pero construye la lista intermedia — Python lo
   resolvió con dos grafías, Kotlin con dos tipos, Swift con `.lazy`,
   C# con `ToList()` explícito. **Nadie se arrepiente de lazy en
   intermediarios; todos se arrepienten de lazy silencioso.**
3. **Push vs pull**: pull gana en composeción sincrónica simple; push gana
   en «sin interfaz por tipo» (Go) y en corutinas. La convergencia actual
   es pull + `async` (C# `IAsyncEnumerable`, Rust async-iter, Kotlin Flow).
4. **Rangos**: elijo el símbolo y una convención y los usuarios la
   recuerdan para siempre — no hay razones técnicas, es pura
   convención/estética (y Astra ya está en el bando exclusivo).
5. **Invalidación**: la lección de Rust es que el problema **no es del
   iterador, es de la mutación compartida** — cualquier lenguaje sin
   aliasing mutante hereda la solución gratis.

## §14 — Astra: estado medido y recomendación

### 14.1 Superficie actual `[verificado — 8 probes con seed/astra-seed]`

| Probe | Entrada | Resultado |
|:------|:--------|:----------|
| rango en `for` | `for i in 0..5 { print(i); }` | imprime `0 1 2 3 4` (exclusivo), rc=0 |
| rango como valor | `let r = 0..5;` | `error: range expression is only valid as a for-loop iterator` |
| `for` sobre array | `for x in a { print(x); }` | imprime los elementos, rc=0 |
| `for` + `break` | `break` dentro de `for` | para en el elemento correcto, rc=0 |
| `while` + contador | `let mut i = 0; while i < 3 …` | funciona (rc=0) — `let mut` obligatorio |
| `loop` | `loop { print(1); }` | **parse error** (no existe) |
| `break` con valor | `if … { break i; }` | `error: break with a value is not supported in Astra-0` |
| `for` sobre string | (DEC-020, test `loops/for_string.astra`) | byte a byte, `c: string` de 1 byte |

Es decir: **la base de control de flujo está completa** (for/while/break/
continue/rango-exclusivo/strings) y **el hueco es exactamente el protocolo
de valor**: el rango no se puede pasar, no hay `loop`-expresión, no hay
`break`-con-valor (aunque el error ya existe como contrato previsto), y no
hay iteradores de usuario.

### 14.2 Reality-check de `research/015` §4 (recomendación «lazy iterators
estilo Rust»)

La recomendación **sigue en pie y se refuerza con los datos nuevos**:

- Go se sumó al lazy iterator en 1.23 (2024) — el lenguaje «anti-patrones»
  aceptó el modelo; JS con Iterator Helpers (ES2025) también; C++20
  consolidó ranges. El campo se mueve **hacia** lo que 015 proponía, no
  en contra. El único disidente relevante es Zig (015 ya lo registra).
- El «gold standard» citado (Rust `Iterator` con `next() -> Option[T]`)
  es el que Astra puede copiar casi literal: **ya tiene traits/impls,
  genéricos monomorfizados en el backend LLVM (M1.c) y `Option`** — el
  `trait Iterator[T] { fn next(mut self) -> Option[T] }` de 015 §4.2 no
  necesita nada que Astra no tenga (las closures de `map`/`filter` ya
  existen: DEC-029).

### 14.3 Recomendación por fases (cada fase = su `DEC-NNN` + tests, AGENTS §1)

1. **Fase 0 — cerrar lo barato ya decidible hoy** (no toca semántica
   existente):
   - **`loop` como expresión + `break` con valor** (el mensaje de error
     actual ya marca la intención): es el 80 % del valor de Rust sin
     protocolo nuevo; el seed ya parsea `break` y sólo falta aceptar el
     valor (o rechazarlo con la DEC correspondiente si se decide no).
   - **Rango como valor**: hoy rechazado explícitamente — convertirlo en
     valor de tipo rango (exclusivo, `[verificado]`) es el prerrequisito
     de cualquier `.filter` posterior.
2. **Fase 1 — `trait Iterator[T]` mínimo**: `next() -> Option[T]` +
   consumidores (`for` ya consume; añadir `collect`/`sum`/`count`).
   Monomorfo por diseño (los traits de Astra ya monomorfizan en LLVM →
   coste cero tras inlining, como Rust).
3. **Fase 2 — adapters lazy**: `map`/`filter`/`take`/`enumerate` como
   métodos default del trait (estructuras genéricas, como Rust) —
   **advertencia de coste**: si los adapters se implementan como closures
   heap con rc (forma actual de las lambdas de Astra), el coste por ítem
   puede impedir el inlining; el backend LLVM ya monomorfiza genéricos,
   así que los adapters deben bajar a structs concretos, no a `fn*`
   boxed — condición técnica a verificar en el PR de la Fase 2.
4. **Coherencias a fijar en la misma DEC**: rango exclusivo (ya medido),
   iterador de string = bytes (DEC-020 — **no** prometer graphemas;
   cross-ref informe `038`), sin C-style `for`, `for` sin forma
   índice+valor (hoy) o con (`enumerate` en Fase 2).

### 14.4 Qué NO hace este informe

Ningún cambio de comportamiento: los probes sólo ejecutaron el compilador
en modo lectura, y las fases de §14.3 son propuestas que, si se aceptan,
cada una exige su entrada en `DECISIONES.md` con tests de conformidad en
el mismo PR.

## §15 — Fuentes

**Primarias / verificadas en esta sesión**:
- The Rust Book, ch. 13 «Processing a Series of Items with Iterators»
  (trait `Iterator`, `next`, lazy, adapters, desugaring de `for`):
  https://doc.rust-lang.org/book/ch13-02-iterators.html `[leído]`
- Go 1.23 Release Notes (range sobre `func(func(K) bool)`, paquete `iter`,
  `slices`/`maps` con iteradores): https://tip.golang.org/doc/go1.23 `[leído]`
- `research/015` §4 «Iterator Patterns» (propuesta previa de Astra:
  Rust-style lazy, `impl Iterator[T]`, Fibonacci, rangos `0..10`):
  `Documentacion/07_investigacion/015_stdlib-design-patterns.md` `[leído]`
- Probes del seed (§14.1): `seed/astra-seed` compilando `it1..it6.astra`
  en `/tmp/opencode/intprobe` `[ejecutado]`
- `seed/src/constructs/range.c` (`NODE_RANGE`, sólo for-loop/slice;
  rechazo como valor) y DEC-020 (`for c in s` byte a byte) `[leído]`

**Secundarias / canónicas**:
- PEP 380 — `yield from`: https://peps.python.org/pep-0380/
- C++20 ranges (cppreference): https://en.cppreference.com/w/cpp/ranges
  · range-v3 (Niebler): https://ericniebler.github.io/range-v3/
- MDN — Iteradores y protocolos de JavaScript:
  https://developer.mozilla.org/es/docs/Web/JavaScript/Reference/Iteration_protocols
  · TC39 Iterator Helpers: https://tc39.es/proposal-iterator-helpers/
- Oracle — The Java™ Tutorials «Working with Collections» / Streams:
  https://docs.oracle.com/javase/8/docs/api/java/util/stream/Stream.html
- Microsoft Learn — C# iterators (`yield`) y LINQ:
  https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/concepts/iterators/
- Swift — Sequences, Collections, Lazy:
  https://developer.apple.com/documentation/swift/sequence
- Kotlin — Sequences vs Collections:
  https://kotlinlang.org/docs/sequences.html
- Go — propuesta range-over-func (2022, motivación citada en Go 1.23 notes):
  https://github.com/golang/go/issues/61405
- Elixir `Stream` (lazy): https://hexdocs.pm/elixir/Stream.html
- Ruby `Enumerator`/`lazy`: https://docs.ruby-lang.org/en/master/Enumerator.html
- Julia iteración (`Base.iterate`, rangos 1-based):
  https://docs.julialang.org/en/v1/manual/iteration/
