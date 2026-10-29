# 035 — Punteros: qué hacen los demás lenguajes, por qué, y cuáles son los más eficientes

> **Alcance**: dossier sobre los modelos de puntero/referencia de los
> principales lenguajes — C, C++, Rust, Zig, Go, Swift, Java, C#, Python,
> JavaScript, Ada, Erlang — más los modelos alternativos (handles, offsets,
> capabilities), la capa de hardware (MTE/PAC/CHERI) y una sección de
> **eficiencia medida**. Cierra con el encaje en Astra (§13).
> **Documento de investigación: no cambia ningún comportamiento.** Fecha:
> **2026-10-29**. `[verificado]` = ejecutado o leído en esta sesión (Debian,
> HEAD `eb7ff39`, worktree `Astra-wt/int-types`); `[citado]` = fuente externa
> con URL en §14.

---

## §0 — TL;DR

1. **Dos linajes históricos**: los *punteros-dirección* de B/C (aritmética
   sobre direcciones crudas) y las *referencias* de Simula 67 (objetos con
   identidad, checks y GC) — de ahí salen C/C++/Zig/Rust-unsafe de un lado, y
   Java/C#/Smalltalk/Python/JS del otro. Go, Swift y Rust safe son cruces.
2. **Todos los punteros «finos» miden 8 bytes** en 64 bits: `void*` en C/C++,
   `*T`, `[*]T`, `?*T` y `[*c]T` en Zig, `*const u8` y `&u8` en Rust —
   **medido** en §11. La diferencia entre modelos no está en el tamaño del
   puntero sino en: qué se puede hacer con él, quién es responsable de la
   memoria, y **a qué apunta** (el 90 % del coste real está en el patrón de
   acceso, no en el tipo).
3. **El patrón de acceso lo es todo**: un benchmark propio `[verificado]`
   recorre 4 M nodos: **794.7 ns/nodo** por lista enlazada aleatoria vs
   **6.71 ns/elem** en array contiguo = **~118× más lento** — cache misses
   serializados + TLB que el prefetcher no adivina.
4. **El puntero más eficiente a nivel primitivo** es el fino de una palabra
   con *provenance* conocida (permite alias analysis → vectorización). **El
   patrón más eficiente a nivel sistema** es lo contrario al pointer-chasing:
   arrays contiguos + índices/offsets (data-oriented), referencias
   comprimidas cuando el heap es enorme (JVM: 4 B bajo 32 GB), y dispatch
   monomorfizado (Zig/Rust) en vez de vtables indirectas.
5. **Overheads medidos**: `unique_ptr` = 8 B = puntero crudo (cero coste);
   `shared_ptr` = 16 B + átomos; `std::function` = 32 B; `Option<&u8>` de
   Rust = 8 B (nicho: el null gratis), `Option<*const u8>` = 16 B (los
   crudos sí admiten null, sin nicho); fat pointers (`&[u8]`, `&dyn T`) = 16 B.
6. **La industria del hardware ataca al puntero desde 2015**: ARM PAC/MTE
   (tags de 4 bits), CHERI (capabilities de 128 bits con bounds+permisos,
   Morello/FreeBSD/CHERIoT), Intel MPX (fracasó y se retiró: GCC 9.1, Linux
   5.6, glibc 2.35). Software: ASan/UBSan.
7. **Astra hoy**: el seed **no expone ningún tipo puntero** (`Ptr` →
   `unknown type 'Ptr'`, `[verificado]`); el plan (ARCHITECTURE §8.5) es
   `Ptr<T>` sólo dentro de bloques `unsafe`, con arenas/FFI — el bando
   Go/Rust-safe de partida. §13 lista qué decisiones convendría tomar antes
   de implementarlo.

---

## §1 — Qué es un puntero en la máquina

Un puntero es una **dirección con intención**: un entero que el hardware
traduce a una celda de memoria, más la promesa del lenguaje de qué se puede
hacer con él. Detalles físicos que condicionan todo lo demás:

- **Dirección de bytes vs de palabras**: los primeros (PDP-7/10, mainframes)
  direccionaban palabras de 32/36 bits; los punteros de B (Thompson, 1970)
  eran índices de palabras y `*p++` nació ahí. C heredó la sintaxis pero corrió
  sobre el PDP-11 **byte-addressable**, y por eso `char*` avanza de uno en
  uno: la aritmética de punteros es *dirección + sizeof(T)*.
- **Alineación**: un `u64` en dirección no múltiplo de 8 cuesta o es
  illegal (x86 tolera, ARM alineado exige); los punteros «alineados por
  tipo» existen para que el hardware no multipezee.
- **ASLR y reubicación**: la dirección concreta cambia en cada ejecución —
  por eso un puntero absoluto **no se puede serializar** (motivo de los
  offsets de §9.4) y por eso los binarios PIC usan GOT/PLT.
- **Los dos ejes de seguridad**: *espacial* (¿está dentro del objeto?
  bounds) y *temporal* (¿sigue vivo? use-after-free). Todo el §10 es la
  historia de intentar resolverlos en el puntero mismo.

## §2 — Taxonomía: seis familias de modelo

| Familia | Qué es el «puntero» | Responsable | Ejemplos |
|:--------|:---------------------|:------------|:---------|
| **A. Dirección cruda + aritmética** | dirección + permiso de hacer `+`/`-`/cast | el programador | C, C++, Zig (`[*]T`), Rust `unsafe`, Ada `Address` |
| **B. Puntero sin aritmética** | dirección, sólo dereferenciar | el lenguaje/GC | Go, Zig `*T` (aritmética sólo con trucos), Java `unsafe` |
| **C. Referencia administrada (GC)** | identidad de objeto vivo | GC + refcounts | Java, C#, Python, JS, Erlang (sin siquiera punteros) |
| **D. Referencia con ownership** | préstamo o propiedad verificada | compilador/ARC | Rust (`&T`, `Box`), Swift (ARC), C++ (`unique_ptr`) |
| **E. Handles / offsets** | índice o desplazamiento en un pool | la biblioteca | game dev (floooh), bases de datos, rkyv, JVM *compressed oops* |
| **F. Capabilities** | dirección + bounds + permisos en el registro | hardware | CHERI/Morello, seL4, KeyKOS |

Ningún lenguaje usa una sola familia: C++ combina A+D, Rust A+D+E, Zig A+B,
JVM C+E. La pregunta no es «¿punteros sí o no?» sino **cuáles exponer al
usuario y en qué contexto**.

## §3 — C y C++: la familia original

### 3.1 C — máxima potencia, mínimo andamiaje

- `T*`: dereferenciar (`*p`, `p->f`), aritmética (`p+1` avanza `sizeof(T)`),
  comparar, restar punteros del mismo objeto, convertir a `void*` y a
  enteros (`uintptr_t`) libremente.
- **Las tres trampas semánticas**: (1) *aliasing/strict aliasing* —
  reinterpretrar `int*` sobre un `float` es UB, el compilador lo optimiza
  asumiendo que no pasa; (2) *out-of-bounds* más allá de uno del final =
  UB (dos punteros a objetos distintos no pueden compararse con `<`); (3)
  *provenance* — un puntero «de» un objeto no puede reconvertirse en
  entero y volver a puntero para puntear a otro objeto y conservar
  optimizaciones (ralfj: «Pointers Are Complicated II/III»).
- **Por qué importa la provenance**: de ella depende el *alias analysis* —
  si el compilador sabe que dos punteros no pueden apuntar al mismo sitio,
  promueve cargas a registros, vectoriza y elimina bucles; esa es buena
  parte del rendimiento de C.
- **Aritmética es lo que hace posible** `memcpy`, arenas, bump allocators y
  todos los grafos de objetos manuales — y también los CVEs de
  use-after-free/overflow.
- **`malloc`/`free` a mano** + `restrict` (promesa de no-aliasing, C99) +
  VLA/`alloca`: C decide dar todas las herramientas y confiar.

### 3.2 C++ — capas sobre el modelo C

- **Referencias `T&`**: «puntero que no puede ser null ni reasignarse» — en
  ABI normalmente es un puntero de 8 B sin overhead (§11), pero sin
  aritmética ni casts.
- **Smart pointers** (RAII): `unique_ptr` = **8 B, cero overhead**
  `[verificado]` (es un puntero con destructor); `shared_ptr` = **16 B**
  (objeto + control block con refcount **atómico**) `[verificado]`;
  `weak_ptr` = 16 B para romper ciclos; `shared_ptr` duplica el tamaño y
  añade coste atómico por copia — el consejo canónico es «`unique_ptr` por
  defecto, `shared_ptr` sólo si hay sharing real».
- **Punteros a miembro**: pueden medir 8/16/32 B según la herencia (se
  resuelven vía offset o vtable) — el caso «no tan delgado» de C++.
- **`std::span`/gsl::span**: el fat pointer moderno (ptr+len, 16 B) para
  arrays — aceptado en el estándar porque los crudos «puntero+largo»
  sueltos son la fuente nº1 de bugs de tamaño.
- **`std::function` = 32 B** `[verificado]` (SBO inline): la «closure» de
  C++ es cara; las lambdas sin captura degradan a fn ptr de 8 B.

## §4 — Rust: dos mundos (safe vs `unsafe`) y provenance explícita

- **`&T` / `&mut T`**: no-null, no-reasignables, con lifetimes; sin
  aritmética. **`*const T`/`*mut T`** (crudos): dereferenciar sólo es
  legal en `unsafe`, admiten null, unaligned y dangling. **`Box<T>`** =
  ownership heap = 8 B `[verificado]`.
- **Provenance como feature**: Rust la discutió explícitamente (RFC 3559,
  «Rust has provenance») y expone APIs estrictas (`with_exposed_provenance`,
  `addr` vs `expose_addr`) para que el truco de *bit packing* de punteros
  (p. ej. guardar flags en alineación baja) sea **decidido, no accidental** —
  a diferencia de C, donde es UB silencioso. La regla: los crudos pueden
  guardarse en enteros, pero «redondear» enteros a punteros invalida las
  optimizaciones salvo por la API expuesta.
- **Fat pointers = 16 B** `[verificado]`: `&[u8]` = ptr+len (el largo viaja
  con la referencia; `str`/`Vec` lo usan), `&dyn T` = ptr+vtable (dispatch
  dinámico). Cuestión de diseño: Rust **no** rellena los arrays de longitudes
  — la longitud vive en la referencia.
- **Nichos (la optimización más elegante)** `[verificado]`:
  `Option<&u8>` = **8 B** — como `&` jamás es null, el «sin valor» codifica
  en la dirección 0 **gratis**; `Option<*const u8>` = **16 B** — los crudos
  sí pueden ser null, no hay bits libres. Igual para `NonZeroU8`, etc.:
  el sistema de tipos fabrica representaciones más pequeñas sin coste.
- **`Pin`**: la respuesta a self-referential structs — mover el objeto
  invalidaría sus punteros internos, así que se «clava» en su sitio (relacionado
  con los offsets de §9.4).
- **Sin UB en safe code**: dangling, aliasing mutante y overflow están
  prohibidos por el borrow checker; `unsafe` acota los 5 casos (raw pointers,
  FFI, inline asm, etc.).

## §5 — Zig: punteros con la semántica escrita en el tipo

Zig descompone el puntero C en tipos explícitos (referencia verificada
contra la referencia 0.17 y medidas de tamaño en 0.16 local `[verificado]`):

| Tipo | Significado | Tamaño medido |
|:-----|:------------|:--------------|
| `*T` | **single-item**: exactamente un `T`, no-null, alineado al tipo | 8 B |
| `[*]T` | **many-item**: secuencia de longitud desconocida (como C pero tipada; sin `+1` implícito — se usa `ptr + 1` sólo con comptime bounds) | 8 B |
| `?*T` | opcional: **null in-band** — la dirección 0 es el `null` | **8 B** (gratis) |
| `[*c]T` | **C pointer**: el «compromiso» para FFI — admite null y aritmética C | 8 B |
| `*align(1) u8` | alineación **en el tipo** (para leer struct de red sin UB) | 8 B |

Puntos de diseño:
- **Sin fat pointers escondidos**: Zig no mete longitudes en el puntero; un
  slice es un `struct { ptr, len }` de 16 B que el programador pasa como
  valor — el puntero puro nunca engorda.
- **`?*T` gratis = el mismo truco de nicho de Rust**, pero hecho por el
  lenguaje para todo optional-pointer (strings `?[*:0]u8`, `FILE*`, etc.).
- **La aritmética de punteros existe pero es cara de escribir** (hay que
  pasar por `[*]T` + aritmética explícita, con safety checks en modos
  seguros): Zig no la oculta, la hace ruidosa.
- **Casts con intención**: `@ptrCast`, `@alignCast`, `@addrSpaceCast` —
  cada asunción es una palabra visible en el diff (vs el cast `(T*)p` de C
  que mezcla todo en un símbolo).

## §6 — Go: el «no» más productivo

- **Punteros sí, aritmética no**: `*p` funciona, `p+1` no compila (sólo con
  `unsafe.Pointer` + reglas estrictas de cgo). Esto elimina de golpe la
  clase entera de bugs de C sin eliminar la capacidad de pasar referencias
  baratas (sin copiar structs grandes).
- **GC de tri-color concurrente con write barriers** + *interior pointers*
  permitidos: apuntar al medio de un objeto es legal (las slices lo hacen);
  el GC debe rastrear rangos, no sólo cabezas — costo real en el GC, no en
  el programa.
- **Sin promociones ni punteros a miembros**: `&x.field` es un puntero
  interior normal; no hay punteros a función con `this` implícito (los
  métodos son funciones con receiver explícito — un disfraz de puntero).
- **Slices = fat pointer de 3 palabras** (ptr+len+cap = 24 B): el único
  «puntero gordo» está en el valor slice, no en `*T`.
- **Por qué lo hizo así**: Go nació (2009) para servidores con GC — el
  objetivo era «referencias baratas sin la locura de C»; no compite en
  arenas crudas (ahí está `unsafe` y los FFI).

## §7 — Swift: ARC — el refcount en el propio puntero

- **Referencias fuertes = ARC**: cada assign retiene (`swift_retain`),
  cada fin de scope libera — el «puntero» lleva implicitamente la vida del
  objeto (vía side table en el header del objeto, no en la palabra del
  puntero). **Coste medido por la comunidad**: retain/release ≈ unos pocos
  ns por operación + el consiguiente tráfico de memoria; Swift lo mitiga
  con *immutability* y el optimizador eliminando retains redundantes.
- **`UnsafePointer<T>`/`UnsafeMutableRawPointer`/`withUnsafeBytes`**: la
  escapatoria explícita (buffers, FFI, SIMD) — el mismo contrato «fuera de
  aquí no hay garantías» que Rust `unsafe`/bloque `unsafe` de Astra.
- **`Unmanaged<T>`**: punteros sin ARC para FFI, con `retain`/`release`
  manuales.
- **Sin punteros a miembro ni aritmética en safe code**; los índices de
  colección son `Int` (firmado, §034) y las referencias no-null se codifican
  como `Optional` con nicho igual que Rust.

## §8 — Los administrados: todo es un puntero, pero no lo ves

- **Java**: los objetos viven en el heap y las variables de objeto son
  *oop* (ordinary object pointers) de 8 B — o **4 B comprimidos**
  (*compressed oops*, por defecto con heap ≤ 32 GB): el JVM los
  reescala ×8 al cargar. Dato de diseño clave: **comprimir referencias
  ahorra ~50 % del heap en heaps medianos** y es transparente. Los
  arrays de objetos son arrays de oops — «el puntero existe, el lenguaje
  lo esconde» (y los primitives `int` no son punteros: un `int[]` es
  primitivo denso — el mejor de ambos mundos para datos numéricos).
- **C#**: igual que Java (managed heap, interior pointers ilegales salvo
  `unsafe`+`stackalloc`), con `Span<T>`/`Memory<T>` como fat pointers
  modernos (ptr+len+flags) y `ref`/`in` como referencias «por valor de
  dirección» de bajo nivel.
- **Python**: **todo** es `PyObject*` (variables, argumentos, campos de
  `list` — que es un array de punteros con refcount en el header). `id(x)`
  expone la dirección. Coste: cada acceso de objeto pasa por el puntero +
  refcount (2 memory-hits por acceso típico) — por eso `int` pequeño tiene
  caché y `list` de números sueltos es puntero-chasing de libro.
- **JavaScript**: los motores **no** exponen punteros y aun así viven de
  ellos: V8 usa *pointer tagging* (bits bajos = tipo, alineación deja bits
  libres) + **compressed pointers** de 4 B; SpiderMonkey usa **NaN boxing**
  (escondedizo de 64 bits en el NaN de un double). Los TypedArrays
  (`Int8Array`…) son la única ventana a direcciones — de nuevo: anchos y
  punteros sólo en la capa de datos.
- **Erlang/Elixir: cero punteros** — valores inmutables copiados entre
  procesos (message passing), aislamiento por diseño; los punteros existen
  dentro del BEAM, jamás en el lenguaje. Es la frontera opuesta a C.

## §9 — Modelos alternativos que resuelven lo que los punteros no

### 9.1 Handles (índices con generación) — «handles are the better pointers»
Identificar objetos por **índice en un array** (+contador de generación
contra dangling): serializable, reubicable, cache-friendly (pool contiguo),
y el dangling se detecta (índice viejo → generación no coincide). Lo usan
game engines (floooh), motores de juego AAA, DBs y el propio modelo de
*handles compartidos* que Astra ya discute en `research/026`/`027`.

### 9.2 Punteros relativos (offsets)
En vez de dirección absoluta, **desplazamiento desde la propia celda**
(`rkyv`, gingerBill): sobreviven a `memcpy`, serialización y ASLR; resuelven
los self-referential structs sin `Pin`. Coste: cada acceso requiere la
base + offset (un LEA más) y el lenguaje debe prohibir guardarlos en
variables sueltas.

### 9.3 Compressed references (JVM/V8)
4 B en vez de 8 con escala fija: la mitad de memoria en heap y mejor
localidad. Límite duro: 32 GB de heap (V8: sandbox de 1 TB con offsets de
32 bits). Conclusión: cuando el heap es enorme, **el ancho del puntero es
una decisión de producto**.

### 9.4 Capabilities (CHERI y familia)
El intento de arreglar el puntero **en el hardware**: un capability = 128
bits (dirección + base + límite + permisos + tag) que el procesador valida
en cada acceso (bounds y permisos de lectura/escritura/ejecución). Morello
(ARM), FreeBSD en CHERI, CHERIoT para IoT; PAC y MTE de ARM son versiones
baratas (tags de 4 bits, probabilísticas). **Intel MPX fue el intento
competidor y fracasó** (overhead tan alto que GCC lo retiró en 9.1, el
kernel en 5.6 y glibc en 2.35) — lección: una capability cara de usar
muere; una barata (MTE) se adopta.

## §10 — Eficiencia: qué es rápido y por qué (medido)

### 10.1 El overhead del puntero en sí es ~0; el problema es **dónde** apunta

Primitivas `[verificado en esta sesión, -O2]`:

| Operación | Tamaño/overhead |
|:----------|:----------------|
| C load/store vía `T*` | 1 instrucción (`mov`), mismo coste que cualquier dirección |
| `unique_ptr<T>` vs `T*` | 8 B vs 8 B — **idéntico código máquina** (sólo el destructor al final) |
| `shared_ptr<T>` | 16 B + `atomic` por copia/destrucción (control block aparte) |
| `std::function<int()>` | 32 B (SBO) — una «closure» C++ pesa 4 palabras |
| Zig `*T`/`?*T`/`[*c]T` | 8 B cada uno — el opcional **no** cuesta palabra extra |
| Rust `&T`/`Box<T>` | 8 B; `Option<&T>` = 8 B (nicho null); `&[T]`/`&dyn T` = 16 B |

### 10.2 El coste real: pointer chasing (benchmark propio)

```
$ gcc -O2 chase.c && ./chase
pointer-chase (lista enlazada aleatoria, 4194304 nodos): 3.333 s = 794.7 ns/nodo
array contiguo (mismos datos):                           0.028 s =   6.71 ns/elem
sizeof(Node)=16  sizeof(void*)=8
```
`[verificado]` — mismos 4 M de nodos, mismo trabajo semántico: **~118×**.
Por qué:
1. **Cada salto es un cache miss serializado**: la dirección del siguiente
   sólo se conoce tras leer el actual → la CPU no puede paralelizar
   (memory-level parallelism = 0).
2. **El prefetcher es ciego** a orden aleatorio (solo predice secuencial/strides).
3. **TLB**: 64 MB dispersos = muchos misses de página.
4. El array se recorre a ~6.7 ns/elem ≈ banda de memoria saturada con
   prefetch — el mejor caso.

Conclusión de diseño: **el puntero es barato, la indirección aleatoria es
cara**. Por eso los «más eficientes» en la práctica son los modelos que
minimizan indirecciones aleatorias: arrays/SoA + índices (data-oriented),
handles a pools contiguos, y structs inlineados (Zig `anytype`/Rust
monomorphization) en vez de grafos de objetos.

### 10.3 Dispatch: el otro punto donde se gana o se pierde

| Mecanismo | Coste |
|:----------|:------|
| Llamada directa (nombre conocido en comptime) | 0 — se inlina, predicha por el BTB |
| Monomorfización (Zig `anytype`, Rust generics) | 0 en runtime; paga en tamaño de binario |
| Fn ptr (`fn(*void)`) | +1 load implícito + indirect call (se predice bien si es monomorfico) |
| vtable C++/Java call site | load del vptr + load del slot + indirect call; **y rompe la frontera de inlining** (el verdadero coste, según mediciones de johnnysswlab/nimrod) |
| intérprete / megamorphic IC (JS) | dispatch en tabla + switch; los engines inventan inline caches justo por esto |

### 10.4 ¿Cuál es «el más eficientes»? Respuesta directa

- **Como primitiva**: el puntero fino de 1 palabra con alineación y
  provenance conocidas — todos los lenguajes miden 8 B y el código
  generado es idéntico; la «inteligencia» está en lo que el compilador
  puede inferir (alias analysis, nullability, bounds).
- **Como patrón de datos**: índices/offsets sobre arrays contiguos le
  ganan al puntero crudo en casi todos los benchmarks de heaps reales
  (localidad + serialización + sin dangling + prefetch funcional).
- **Como compromiso**: referencias comprimidas (JVM/V8) si el heap manda;
  handles con generación si hay ciclos de vida complejas; capabilities si
  el presupuesto de seguridad es alto (aunque MPX enseñó que el hardware
  caro no se adopta).
- **Para dispatch**: comptime/monomorfización (Zig, Rust, C++ templates)
  > indirect call fino > vtable con frontera de inlining rota.

## §11 — Tabla comparativa transversal

| Lenguaje | Qué expone | Aritmética | Quién libera | Null | Nota de eficiencia |
|:---------|:-----------|:-----------|:-------------|:-----|:-------------------|
| **C** | `T*` crudo | sí | manual (`free`) | sí (0) | mínimo overhead, máximo UB |
| **C++** | `T*`, `T&`, smart ptrs | sí (crudos) | RAII/`delete` | `T&` no | `unique_ptr`=8 B; `shared_ptr`=16 B+átomos |
| **Rust** | `&T` + crudos `unsafe` | sólo `unsafe` | borrow checker | `&` no (nicho gratis) | fat ptrs 16 B; provenance explícita |
| **Zig** | `*T`, `[*]T`, `?*T`, `[*c]T` | sólo `[*]` explícito | `defer`/allocator | opcional gratis | sin fat escondidos; alignment en el tipo |
| **Go** | `*T` | **no** | GC | sí | interior pointers OK; slice = 3 palabras |
| **Swift** | refs ARC + `Unsafe*` | sólo unsafe | ARC (retain/release) | `Optional` | ~ns por retain; overhead del optimizador |
| **Java** | oops (ocultos) | no | GC | null | compressed oops = 4 B ≤32 GB heap |
| **C#** | managed + `ref`/`Span` | `unsafe` | GC | null | `Span<T>` fat moderno |
| **Python** | todo `PyObject*` | no | refcount+GC | null | 2 hits de memoria por acceso |
| **JS** | ninguno (tagging interno) | no | GC | null | tagged ptr 4 B / NaN boxing |
| **Erlang** | ninguno | no | GC (por proceso) | `undefined` | copias, cero indirección compartida |
| **Ada** | `access` + `Address` | annex | storage pools | `null` + checks | accesos con checks de dominio/accesibilidad |

## §12 — Por qué cada lenguaje lo hace así (síntesis)

- **C** necesitaba escribir SO y drivers en 1972: dirección cruda = la
  abstracción mínima sobre el PDP-11; todo lo demás (checks, RAII) vino 40
  años tarde y ya convive con legado.
- **C++** añadió RAII/referencias **encima** sin romper C: por eso conviven
  4 estilos de puntero y las guías de estilo son necesarias.
- **Java/C#/Python/JS** eligieron la referencia-GC porque su prioridad era
  productividad y portabilidad; el precio (latencia de GC, overhead por
  objeto, sin control de layout) lo pagan los sistemas, no las apps.
- **Go** quiso «referencias de Java con control de sistemas»: GC + punteros
  sin aritmética = el punto medio que eliminó el uso-after-free sin
  obligar a ownership annotations.
- **Rust** demostró que se puede tener el modelo C **sin UB en safe code**:
  ownership+ lifetimes en compile-time, coste runtime cero (los `&T` son
  punteros de 8 B), y `unsafe` para el resto. Es el estado del arte del
  linaje C.
- **Zig** toma las lecciones de Rust y C++ y **las escribe en la sintaxis**:
  puntero single/many/optional/C son 4 tipos distintos porque son 4
  semánticas distintas; sin inheritanza ni vtables ocultas (dispatch =
  `anytype`/vtable structs explícitas).
- **Swift** apostó por ARC porque su público (apps Apple) necesita
  predictabilidad sin la curva de Rust: retain/release con coste acotado y
  escapatorias `Unsafe*` explícitas.
- **Astra** (según su ARCHITECTURE) se sitúa en el bando «GC/ARC +
  handles + unsafe opcional»: rc propio (M4.e), sin tracing GC, punteros
  crudos sólo en bloques `unsafe` — el diseño que §13 discute.

## §13 — Astra: estado actual y aprendizajes

### 13.1 Estado `[verificado]`

- **El seed no expone punteros**: `fn f(p: Ptr<Float>)` →
  `error: unknown type 'Ptr'` (probe en este worktree, HEAD `eb7ff39`).
  Tampoco hay `TYPE_PTR` en el typechecker (`seed/src/typechecker.c`).
- **El plan está escrito** (`Documentacion/01_lenguaje/ARCHITECTURE.md`):
  - §8.5 «Bloque unsafe»: `fn acceso_directo(ptr: Ptr<Float>) { unsafe {
    ptr.write(3.14159) } }` — `Ptr<T>` con método `write`, acotado a `unsafe`;
  - fila «Bajo Nivel»: «Manual / Arenas: Punteros crudos (`Ptr<T>`,
    `alloc`/`free`)» y §9 casos de uso: «Bloques unsafe, punteros, FFI
    directo con C»;
  - §856 `BumpAllocator` (incremento de puntero) como allocator de frame;
  - §2351: el **«pointer model»** sigue listado como trabajo futuro del
    Memory Model (junto a ARC/ORC y happens-before), y DEC-012/RT1 ya
    obligan a checks cuando un handle cruza fibras.
- **Ownership**: el heap es por **reference counting** con cabecera
  `{rc, kind}` (LLVM M4.e); el aliasing de handles está decidido
  (research/027 Rec2: handle compartido, `alias_write` fija `99/99`).

### 13.2 Decisiones que conviene tomar ANTES de implementar `Ptr<T>`
(Esta sección es lectura de diseño; **cualquier cambio de comportamiento
exige su `DEC-NNN` + test, según AGENTS.md §decisiones**.)

1. **Sin aritmética fuera de `unsafe`** (bando Go/Zig): `Ptr<T>` en modo
   seguro sólo dereferencia (`read`/`write`); la aritmética requiere
   explícitamente `[*]T`-like o bloque `unsafe`. Evita heredar el UB nº1
   de C.
2. **Nullibilidad como `Ptr?` gratis** — la medida de Zig y Rust
   (`?*T` = 8 B, `Option<&T>` = 8 B `[verificado §10.1]`) demuestra que
   «puntero opcional» no cuesta palabra: Astra ya tiene `Option`, así que
   `T?`-sobre-punteros sale natural y gratis (el pair `{tag,payload}` de
   M6.c ya existe en el backend LLVM).
3. **Handles vs punteros para el heap rc**: con rc, un `Ptr<T>` crudo a un
   objeto rc es dangling en cuanto el último owner suelta; el modelo de
   handles con generación (§9.1) —que ya discuten research/026/027— es
   más robusto y serializable que punteros absolutos; `Ptr<T>` debería
   reservarse para **FFI/arenas** (memoria no-rc: `alloc`/`free`, bump
   allocators), no para objetos rc.
4. **Serialización**: si Astra persiste structs self-referential, mirar
   offsets relativos (§9.2) antes que «arreglar» punteros al cargar.
5. **FFI C**: hará falta algo tipo `[*c]T` (Zig lo llama literalmente
   «compromise»): null + aritmética de C sólo en la frontera.
6. **El benchmark de §10.2 es el argumento para las colecciones**: donde
   Astra diseñe graphos/árbol de objetos, preferir arrays de structs +
   índices (handles) a punteros entre nodos — es la diferencia de 118×.

### 13.3 Qué NO hace este informe
Ninguna acción cambia comportamiento ni código: `Ptr<T>` todavía no existe
en el seed y su implementación futura es un feature con DEC propio. Este
dossier aporta el mapa de decisiones (§13.2) con los datos de §3–§11.

## §14 — Fuentes

**Primarias / oficiales** (consultadas 2026-10-29):
- Referencia del lenguaje Zig 0.17 (punteros: single/many/optional/C,
  alignment): https://ziglang.org/documentation/0.17.0/ `[leído]`
- Guía Zig de punteros: https://zig.guide/language-basics/many-item-pointers/
- The Rust Book (references, slices, fat pointers):
  https://doc.rust-lang.org/book/ch04-03-slices.html · RFC 3559 provenance:
  https://rust-lang.github.io/rfcs/0359-rust-has-provenance.html
- Ralf Jung, *Pointers Are Complicated II/III* (provenance):
  https://www.ralfj.de/blog/2020/12/14/provenance.html ·
  https://www.ralfj.de/blog/2022/04/11/provenance-exposed.html
- Go FAQ/especificación (sin aritmética, slices):
  https://go.dev/doc/effective_go#pointers_vs_values ·
  reglas cgo: https://pkg.go.dev/cmd/cgo
- Swift: `UnsafePointer` docs (developer.apple.com) · «The Basics»:
  https://docs.swift.org/latest/documentation/the-swift-programming-language/thebasics
- Java compressed oops (JVM manual):
  https://docs.oracle.com/en/java/javase/21/gctuning/available-collectors.html
  (artículo de referencia: shipilev, JVM Anatomy Quark #23)
- C++ Core Guidelines (smart pointers): https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#Rr-smartptrparam

**Mediciones propias** `[verificado en esta sesión]`:
- `chase.c` (gcc 14.2 `-O2`): 794.7 ns/nodo vs 6.71 ns/elem, 4 M nodos,
  `sizeof(Node)=16` — código en §10.2.
- `sizes.cpp` (g++ 14.2 `-O2`): unique=8, shared=16, weak=16, function=32.
- `zsizes.zig` (Zig 0.16.0 instalado): `*u8`/`[*]u8`/`?*u8`/`[*c]u8`/`?[*:0]u8`
  = 8 B todos.
- `rsizes.rs` (rustc `-O`): `&u8`=8, `Option<&u8>`=8, `Option<*const u8>`=16,
  `&[u8]`=16, `&dyn T`=16, `Box<u8>`=8.
- Probe seed: `Ptr` → `unknown type 'Ptr'` (rc=1).

**Secundarias / análisis**:
- Handles vs pointers (floooh, game dev):
  https://floooh.github.io/2018/06/17/handles-vs-pointers.html
- Relative pointers (gingerBill): https://www.gingerbill.org/article/2020/05/17/relative-pointers/ · rkyv: https://rkyv.org/architecture/relative-pointers.html
- Intel MPX retirado (GCC wiki): https://gcc.gnu.org/wiki/Intel%20MPX%20support%20in%20the%20GCC%20compiler · Wikipedia: https://en.wikipedia.org/wiki/Intel_MPX
- CHERI: https://www.cl.cam.ac.uk/recuritylab/cheri/ · CHERIoT:
  https://cheriot.org/cheri/philosophy/isa/2025/11/19/cheri-or-cheriot.html
- ARM MTE (p.ej. blog de LWN/ARM docs) y PAC — familia de tags de 4 bits.
- Virtual functions cost (mediciones): https://johnnysswlab.com/the-true-price-of-virtual-functions-in-c/ · https://nimrod.blog/posts/virtual-function-costs/
- NaN boxing vs pointer tagging: https://wingolog.org/archives/2011/05/18/value-representation-in-javascript-implementations
- Pointer chasing y latencia de memoria: https://en.algorithmica.org/hpc/cpu-cache/pointers/ · paper ICCM'16 «Accelerating Pointer Chasing in 3D-Stacked Memory»
