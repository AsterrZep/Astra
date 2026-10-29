# 034 — Sistemas de enteros de ancho fijo (`i8`…`i64` / `u8`…`u64`): cómo y por qué los diseñan Zig 0.17, C, C++, Java, Python, Rust, Swift, Go, C#, JavaScript y Kotlin

> **Alcance**: dossier autocontenido sobre los sistemas de tipos enteros
> «de familia `iN`/`uN`» — cómo funcionan en cada lenguaje, por qué sus
> diseñadores eligieron ese modelo, y qué ventajas/desventajas trae cada
> elección. Cierra con el encaje en Astra (§13). **Documento de
> investigación: no cambia ningún comportamiento, no toca código.** Fecha:
> **2026-10-29**. `[verificado]` = ejecutado o leído en esta sesión (Debian,
> HEAD `1a2eddb`, worktree `Astra-wt/int-types`, rama
> `docs/investigacion-int-types`); `[citado]` = fuente externa con URL en §14.

---

## §0 — TL;DR

1. **Los anchos fijos potencia de dos existen por el hardware, no por estética**:
   registros que se dividen en mitades (8/16/32/64), direccionamiento por bytes,
   lanes de SIMD, alineación natural y compatibilidad de ABI (§1).
2. **Hoy todos los lenguajes serios usan complemento a dos**; está mandado por
   norma en C23, C++20, Java (JLS), Rust y Zig. Fue ganando porque un solo cero,
   negación barata (`NOT+1`) y el mismo sumador sirve para firmado y sin signo
   (§2).
3. **Cinco ejes de diseño** explican todas las diferencias: (a) ancho fijo vs
   arbitrario, (b) firmado/unsigned, (c) promociones implícitas, (d) semántica
   de overflow — de UB (C) a imposible (Python) — y (e) tipo «palabra» por
   defecto (`int`/`Int`/`usize`) (§12).
4. **Zig 0.17.0** (2026-10-02) no cambia el modelo de enteros: `iN`/`uN`
   arbitrarios de 0…65535 bits, sin promociones, casts explícitos, overflow con
   *runtime safety* en `.debug`/`.safe` y sin checks en `.fast`/`.small`; lo nuevo
   de 0.17 alrededor de los enteros son `@divCeil`, `@backingInt`/
   `@fromBackingInt` y el renombrado de los modos de optimización (§3).
5. **C** paga el legado del PDP-11: promociones a `int`, signed overflow =
   UB, `stdint.h` (C99) como parche de anchos exactos y `_BitInt(N)` (C23) como
   remate (§4). **C++** hereda todo y añade dos complementos obligatorio desde
   C++20 (§5).
6. **Java** elimina unsigned (salvo `char`) y define wrap; **Python** elimina el
   ancho (entero arbitrario); **Rust** conserva familia completa pero elimina
   toda conversión implícita y el UB (wrap definido en release, panic en debug);
   **Swift** hace `Int` (palabra) el default y **trapea** el overflow; **Go**
   simplifica a `int/uint` palabra + familia y define wrap (§6–§10).
7. **Astra hoy**: el seed tiene exactamente `i32/i64/u32/u64` (no existen `i8`
   ni `u8`), sin promoción implícita (`i32 + i64` es error de tipos), runtime
   único `i64` con wrap definido, y literal fuera de rango = error compile-time
   (DEC-006/007) — verificado por ejecución en §13.1.

### Tabla rápida por lenguaje

| Lenguaje | Familia | Unsigned | Promoción implícita | Overflow (default) | Lit. fuera de rango |
|:---------|:--------|:---------|:--------------------|:-------------------|:--------------------|
| **C** | `short/int/long` + `intN_t` (C99) | sí | sí (a `int`) | firmado = **UB**; unsigned = wrap | truncación silenciosa (aviso opcional) |
| **C++** | ídem + `char8_t`, `__int128` (ext.) | sí | sí | ídem C | ídem C |
| **Java** | `byte/short/int/long` | no (`char` aparte) | sí (a `int`) | wrap definido | error de compilación |
| **Python** | `int` (arbitrario) | N/A | N/A | nunca desborda | N/A |
| **Rust** | `i8…i128`, `u8…u128`, `isize/usize` | sí | **no** | debug: panic · release: wrap | error de compilación |
| **Swift** | `Int8…Int64` (+`Int128`), `UInt…` | sí | **no** | **trap** (crash) · `&+` wrap | error de compilación |
| **Zig** | `iN`/`uN` arbitrarios | sí | **no** | safety: panic · fast: sin checks | error comptime |
| **Go** | `int8…int64`, `int` palabra, `uintptr` | sí | **no** | wrap definido | error de compilación |
| **C#** | `sbyte…ulong` (+`Int128`) | sí | a `int`/`long` | wrap (`unchecked` default) | error de compilación |
| **JS** | `Number` (f64) + `BigInt` | N/A (TypedArrays) | `→ Number` | imprecisión > 2⁵³−1 | N/A |
| **Kotlin** | `Byte…Long` (+`U*` desde 1.5) | opcional | parcial (a `Int`) | wrap definido | error de compilación |
| **Astra (hoy)** | `i32/i64/u32/u64` | sí | **no** | wrap definido (runtime i64) | error compile-time |

---

## §1 — Por qué existen los anchos fijos (la respuesta del hardware)

Antes de cualquier lenguaje, la memoria es bytes direccionables y los
registros son bloques de tamaño fijo. La familia 8/16/32/64 no es arbitraria:
es la serie de mitades del registro de 64 bits que toda la industria convergió
en usar (un byte = 8 bits por el estándar ASCII extendido/EBDIC y su
consagración en los mainframes de los 60). Un ancho fijo compra:

- **Layout determinista.** Un `struct` con dos `u32` ocupa 8 bytes en
  cualquier plataforma con `sizeof` conocido: eso es lo que hacen posible un
  formato de fichero, un paquete de red, un registro de BBDD o un GUID. Sin
  anchos fijos no hay serialización binaria estable (basta mirar cómo `long`
  de C mide 4 bytes en Windows/LLP64 y 8 en Linux/LP64 para ver el dolor).
- **Densidad y caché.** Un array de un millón de `u8` son 1 MB; de `i64`, 8 MB.
  Elegir el ancho es elegir el coste de memoria y el número de fallos de
  caché — Python lo demuestra al revés: su `int` arbitrario cuesta ~28 bytes
  como mínimo (§7).
- **Instrucciones concretas.** x86-64 tiene `add r8/r16/r32/r64`, SIMD con
  lanes de 8/16/32/64 bits (`i8x16`, `i32x4`…), saturating arithmetic por
  ancho; ARM NEON igual. Un lenguaje sin `u8` no puede expresar un kernel de
  imagen sin representar cada píxel en un `i64`.
- **Protocolos y campos bit.** Cabeceras DNS/HTTP/binarias definen campos de
  4, 8, 12, 16 bits. Zig lleva esto al extremo: `i7`, `u12` o `u256` (cripto)
  sin esperar a que el estándar añada el tipo (§3).
- **Rangos como contratos de tipo.** `u8` = «este campo nunca negativo y nunca
  mayor que 255» lo comprueba el compilador en los lenguajes buenos (Rust,
  Swift, Zig, Java, Go, Astra-DEC-006) — el ancho no es sólo rendimiento, es
  una aserción de diseño verificable.

**Coste** (por qué no todos lo usan): propaga la complejidad a todo el
ecosistema (¿`size_t` o `int`? ¿`long` o `int64_t`? — el «Egyptian hieroglyphs»
de Steve Yegge sobre C), abre la puerta a bugs de promoción (§4.3) y hace
frágil la evolución de APIs (cambiar `int32_t` a `int64_t` rompe ABI).

## §2 — Por qué todos convergen en complemento a dos

Históricamente convivieron tres representaciones de firmados:

| Representación | Máquina emblemática | Pecado original |
|:----------------|:--------------------|:----------------|
| Signo-magnitud | IBM 704 | dos ceros (+0 y −0); el signo necesita lógica de suma aparte |
| Complemento a uno | PDP-1, CDC 6600 | dos ceros; la suma necesita acarreo de final de vuelta (corrección) |
| **Complemento a dos** | series System/360 → x86, ARM | ninguno fatal |

Complemento a dos gana porque: **un solo cero** (desperdicia un slot menos),
**negación = `NOT` + 1** (se hace en el mismo camino de datos), **el mismo
sumador suma firmado y unsigned** (el hardware no distingue: sólo los flags de
estado difieren en la interpretación), la **extensión de signo** es replicar el bit de
signo, y la detección de overflow es XOR de dos acarreos. Los lenguajes
«herederos del hardware» lo adoptaron tarde o temprano y hoy está **mandado
por norma**: C23 (resolución N2218 de WG14), C++20 (P0907), Rust (referencia),
Zig (única representación) y el JLS de Java siempre lo describió así. La
paradoja: el modelo de C++20 dice «dos complementos obligatorio» pero sigue
definiendo el overflow firmado como UB (§4.4) — representación fija no implica
aritmética definida.

## §3 — Zig 0.17.0 (2026-10-02): anchos arbitrarios y seguridad explícita

### 3.1 El modelo

- **Familia arbitraria**: `i`/`u` seguido de cualquier número de bits, de
  `u0` a `u65535` (referencia del lenguaje). `i7`, `u13`, `i256` para cripto o
  `u4` para nibbles son tipos reales. `@sizeOf(i3) == 1` porque se guardan
  rellenados a byte dentro de arrays/structs, pero el compilador razona con el
  rango real (`-4..3`) en comptime.
- **Sin promociones ni conversiones implícitas**: `a + b` con anchos distintos
  no compila; hay que escribir `@as(u32, a) + b` (coerción, sólo si el valor
  cabe) o `@intCast` (trunca/chequea). Los literales se adaptan al tipo
  esperado y **se comprueban su rango en comptime**: `const x: u8 = 300;` es
  error de compilación.
- **Overflow**: con *runtime safety* activa (modos `.debug` y `.safe`) es un
  **panic**; en `.fast`/`.small` los checks se eliminan y el comportamiento
  queda sin definir por el lenguaje (el issue #7967 lo describe como «trapped
  in debug, undefined in release»). Para wrap a propósito existen `+%`, `-%`,
  `*%` y las formas `@addWithOverflow`/`@mulWithOverflow`/`@shlWithOverflow`
  que devuelven `{resultado, bit}` [verificado en la referencia 0.17: lista de
  builtins leída por curl].
- **Intrínsecos por ancho**: `@clz`, `@ctz`, `@popCount`, `@byteSwap`,
  `@bitReverse`, `@divCeil` (nuevo en 0.17), `@shlExact`, `@reduce` — los
  enteros pequeños son moneda corriente en el std (bytes, flags, códigos de
  error, tags de enums).

### 3.2 Qué cambió (y no) en 0.17.0

El modelo de enteros **no cambió**; 0.17.0 (206 contribuidores, 925 commits,
según la nota de lanzamiento) remató su ecosistema:

- **Enums con backing int de primer nivel**: `@backingInt` y
  `@fromBackingInt` (nuevos) hacen lo que `@intFromEnum`/`@enumFromInt` +
  `@bitCast` para `enum(u8)`; `@bitCast` ya puede fabricar enums.
- **`std.meta.Int` eliminado → builtin `@Int`** (y `@Tuple`): los tipos
  enteros parametrizados (`@Int(false, 64)`) pasan a ser lenguaje, no std.
- **Modos de optimización renombrados** (`.debug`, `.safe`, `.fast`,
  `.small`; tipo `std.lang.Optimize`, leídos con `builtin.optimize`): el
  contrato de overflow queda explícito en el nombre — `.safe` = optimizado
  **con** checks, `.fast` = sin ellos.
- `std.mem.writePackedIntNative` → `writePackedInt(…, .native)` (serialización
  de enteros de cualquier ancho, nativa o bytes-swapped).

### 3.3 Ventajas y desventajas

| Ventaja | Desventaja |
|:--------|:-----------|
| Modelar binarios/protocolos/cripto sin librerías (`u256`, `u4`) | Coste de comptime: templates de tipos arbitrarios ensanchan compilación |
| El rango del tipo es una precondición verificable (p. ej. `fn f(x: u8)`) | Doble vida del ancho: en memoria se rellena a byte (padded bits: issue #11263, bits «fantasma» en coerciones) |
| Saturating/wrapping/bit-ops disponibles para cualquier ancho | Curva: hay que entender safety modes y casts explícitos antes de escribir `+` |
| Sin ambigüedad de ABI: `i32` es 32 bits en todo target | El poder arbitrario invita a tipos exóticos difíciles de diagnosticar |

## §4 — C: el modelo original y sus deudas

### 4.1 Tipos y historia

K&R/ANSI C definió `char`, `short`, `int`, `long` (+ `long long` en C99) con
**tamaños dependientes de la plataforma** («≥ 16 bits», «`long` ≥ `int`», la
única garantía real). El nombre «int» es la abreviatura de «integer» del
PDP-11, donde `int` medía la palabra de 16 bits. En 1999, **C99 trajo
`<stdint.h>`**: `int8_t/uint8_t/…/int64_t` de **ancho exacto** (sólo existen si
el hardware los tiene, sin padding, complemento a dos), más los «tibios»
`int_leastN_t` (mínimo N bits) e `int_fastN_t` (el más rápido para la
plataforma) y los macros `PRIu64` para imprimir. **C23** remata con
`_BitInt(N)` / `unsigned _BitInt(N)` — enteros de ancho arbitrario «a la Zig»
dentro de C — y con dos complementos obligatorio.

### 4.2 Reglas de conversión (el laberinto)

1. **Integer promotions**: `char`, `short` y bit-fields se promueven a `int`
   (o `unsigned int` si `int` no los contiene) **antes de cualquier operación**.
2. **Usual arithmetic conversions**: si los operandos difieren, ambos suben al
   tipo de mayor «rank» que contenga al otro; si no existe (p. ej.
   `long` + `unsigned int` en LP64), ambos pasan a `unsigned long`. El signed
   se vuelve unsigned y el programador ni lo ve.

### 4.3 La trampa clásica de los anchos fijos en C

```c
uint16_t i = 65535;
i += 1;                       // NO envuelve a 0: i se promueve a int,
                              // 65535 + 1 = 65536 cabe en int,
                              // y al reasignar a uint16_t trunca a 0…
                              // pero con valores > 2^31 el camino es otro
```

El punto real (documentado por Jeff Hurchalla y otros): confiar en que
`uintN_t` «envuelve como unsigned de N bits» en C es frágil porque la
promoción a `int` firmado cambia el rango de overflow detectable. Los
compiladores advierten con `-Wconversion`, pero nada lo exige.

### 4.4 Overflow

- **Unsigned**: wrap definido módulo 2^n (es el «módulo» que permite la
  aritmética de punteros y la cripto en C).
- **Signed**: **undefined behavior** — no «envuelve en la práctica»: el
  compilador puede (y hace) optimizar asumiendo que no ocurre (paper de Dietz
  et al., *Understanding Integer Overflow in C/C++*, CACM 2012, citado 293
  veces). `-fwrapv` lo cambia a wrap definido, pero es extensión no estándar.
  Aun así, en la práctica los compiladores envuelven en `-O0` y `-O2` salvo
  casos construidos — medido también en nuestro propio C codegen
  (`research/027` §1).

### 4.5 Balance

Ventaja: mapeo 1:1 con el hardware y máxima portabilidad de *código que ya
sabe lo que hace*; desventaja: **cada regla es una mina** (promociones,
signedness mismatches, UB) — es el lenguaje que más CVEs de numeración ha
producido y por el que nacieron `stdint.h`, `_Bool`, MISRA y los linters.

## §5 — C++: hereda C y añade parches

C++ usa el mismo modelo de tipos y conversiones que C (con los mismos
peligros) y va añadiendo circuitos de escape:

- **Dos complementos obligatorio desde C++20** (P0907): `-2^31..2^31-1`
  garantizado y `INT_MIN` sin trampa de rango.
- **`char8_t`** (C++20) para UTF-8; `char` sigue siendo «byte con sabor
  local» (signedness de `char` = implementation-defined, otro clásico).
- **Narrowing explícito en llaves**: `int x{some_uint};` no compila si puede
  truncar — el «lit. fuera de rango» lo recupera el programador a mano.
- **`__int128`** existe en GCC/Clang pero no es estándar; no hay `_BitInt`
  equivalente aún en el comité.
- **Strong typedefs de facto**: `std::chrono::seconds`, `std::byte`,
  `std::size_t` y bibliotecas como Abseil (`absl::int128`) son la forma
  idiomática de «crear tipos enteros nuevos sin heredar las trampas».
- **Estilo**: Google C++ Style Guide recomienda **no usar unsigned para
  cantidades** (sólo para bits/módulo) — la lección de C escrita en política.

Ventaja: rendimiento C con tipos de dominio. Desventaja: dos modelos
conviviendo (C crudo + envoltorios de tipo fuerte) y el UB de signed overflow
intacto.

## §6 — Java: firmado, promovido a `int`, wrap definido

- **Cuatro primitivos**: `byte` (8), `short` (16), `int` (32), `long` (64),
  todos firmados de complemento a dos; **sin unsigned** (salvo `char`, 16 bits
  sin signo, existente sólo para UTF-16). La decisión de diseño fue
  deliberada: eliminar el doble modelo firmado/unsigned de C era uno de los
  motivos explícitos del lenguaje; para lo binario, desde Java 8 existen
  helpers (`Integer.compareUnsigned`, `divideUnsigned`, `toUnsignedLong`,
  `rotateRight`).
- **Promoción universal a `int`**: `byte + byte` se calcula en `int`; el
  programador reasigna y ya. Simplifica el JLS y el JVM (stack slots de 32
  bits; `long` ocupa dos).
- **Overflow = wrap definido** en todos los operadores (JLS §15.18.2): nunca
  UB, nunca trap — el mismo carácter del lenguaje (GC, bounds checks).
- **Literales fuera de rango = error** (`byte b = 300;` no compila).
- **Escala vía librería**: `BigInteger` cuando el rango importa más que el
  rendimiento.

Ventaja: un modelo mental pequeño y determinista; desventaja: sin `u8` la
programación binaria es incómoda (bytes con signo por todas partes) y `long`
contagia las APIs de índice (arrays de más de 2³¹ elementos, paths de
archivos…). Android lo sufrió tanto que añadió `@IntDef`/anotaciones de rango.

## §7 — Python: el lenguaje que borró el ancho

- **Un solo tipo `int`, de precisión arbitraria**. No hay `i32`: la
  aritmética nunca desborda y se «promueve sola» al crecer.
- **Implementación CPython** [verificado en esta máquina: Python 3.13.5,
  `sys.int_info` → `bits_per_digit=30, sizeof_digit=4`]:
  el entero es un array de **dígitos de 30 bits** (base 2³⁰) en unidades de
  32 bits; los pequeños (−5…256) se cachean como singletons. Un `int` vacío
  cuesta ~28 bytes — el precio de la comodidad (un millón de contadores ~28 MB
  donde C gastaría 4 MB con `i32`).
- **Protección DoS**: convertir un `int` gigante a decimal es O(n²); tras el
  CVE-2020-10735 (`10**1000000` bloqueaba el intérprete), CPython limita la
  conversión a 4300 dígitos por defecto [verificado:
  `default_max_str_digits=4300` en `sys.int_info`] con `sys.set_int_max_str_digits`.
- **Cuando importa el ancho, se baja a librería**: `struct`/`array`/`int.to_bytes`
  (con byteorder explícito), `int.from_bytes`. Los anchos viven en el **datos**,
  no en el **tipo**.
- **`bool` es subclase de `int`** — herencia del modelo «un entero».

Ventaja: cero bugs de overflow, ideal para educación, cripto, scripting y
matemáticas; desventaja: rendimiento y memoria en hot loops y colecciones, y
un salto de coste no lineal al salir del rango small-int. Por eso **JavaScript
y Python convergen en BigInt como tipo aparte** en vez de cambiar el
primitivo (§10.3).

## §8 — Rust: familia completa, cero implicitness, overflow sin UB

- **Tipos**: `i8/i16/i32/i64/i128`, `u8…u128`, más `isize/usize` (tamaño del
  puntero; `usize` es el tipo de índices y longitudes — comprueba
  out-of-bounds en ejecución, así que firma y sin signo no importan allí).
  Literal por defecto: `i32`.
- **Cero conversiones implícitas**: `let x: u8 = 1; let y: u16 = 2; x + y;`
  no compila; `as` trunca de forma **definida** (documentado, no UB) y hay
  `try_from` para fallar limpio. La «promoción» no existe: Rust eligió el
  bando de Zig/Go/Swift.
- **Overflow**: el diseño de RFC 560 — en **debug** panic (check explícito),
  en **release** wrap de dos complementos **definido** (mismo contrato
  determinista que Go y Astra, no UB como C). Para decisión explícita:
  `wrapping_*`, `checked_*` (Option), `saturating_*`, `overflowing_*` y, más
  recientes, `strict_*` — o `a as u8` para truncar.
- **Layout como API**: `NonZeroU8`, `u4`-like vía crates, `#[repr(transparent)]`
  — los anchos se usan para optimizar nichos (`Vec<Option<NonZeroU8>>` ocupa
  lo mismo que `Vec<u8>`).

Ventaja: rendimiento C con semántica sin UB ni sorpresas de conversión;
desventaja: verbosidad (`as`, `try_from`, `wrapping_add`) y la dualidad
debug/release (un bug de overflow puede dormir hasta que alguien compila en
release).

## §9 — Swift: `Int` palabra por defecto, trap en overflow

- **Default `Int`/`UInt`** = palabra de la plataforma (32 en watchOS, 64 en
  desktop): la guía oficial recomienda `UInt` sólo si se necesita
  expresamente unsigned — así el código no se rompe al cambiar de arquitectura
  (el bug clásico de `int` de 32 bits en iOS 64-bit).
- Familia `Int8…Int64`/`UInt8…UInt64` y **`Int128`/`UInt128` desde Swift 6.0**
  (SE-0425).
- **Los operadores normales trapean** en overflow (runtime error, sin UB y sin
  wrap silencioso); el wrap explícito es `&+`, `&-`, `&*`. Literal fuera de
  rango = error de compilación (`let x: UInt8 = 300`).
- **Sin conversiones implícitas**; comparar `Int` con `UInt8` exige convertir.
- Las APIs de colecciones devuelven `Int` firmado para índices (decidido y
  defendido en los foros de Swift: evitar el clásico bug de `i - 1` con
  unsigned en índice 0 → 2^n−1).

Ventaja: cero wraps accidentales (el fallo es ruidoso, no silencioso);
desventaja: el trap es un crash sin recuperación posible en la operación
(hay que auditar `&+` y `overflowing`), y conviven dos familias firmadas/
unsigned que rara vez se mezclan bien.

## §10 — Otros modelos

### 10.1 Go — simplicidad con wrap definido

`int8…int64`, `uint8(=byte)…uint64`, `int`/`uint` (palabra) y `uintptr`
(para punteros). Sin promociones: `var a int8 = 1; var b int16 = 2; a+b` no
compila. **Overflow definido** (wrap módulo 2^n) también para signed — el spec
lo dice literalmente («deterministically defined by the signed two's-complement
representation»). Constantes sin tipo con precisión arbitraria en comptime (a
la Zig/Python). Recomendación oficial: usa `int` salvo motivo concreto — Go
confía en que el programador elija poco.

### 10.2 C# — wrap por defecto, `checked` opcional

Primitivos `sbyte…ulong` (+ `System.Int128/UInt128` desde .NET 7; C# 14 les
da palabras clave). Conversiones implícitas en anchos crecientes; **overflow
por defecto = wrap (`unchecked`)**, y el contexto `checked`/`unchecked`
(operator y statement, o `/checked+` de proyecto) convierte el overflow en
`OverflowException`. Es el «tercer camino» entre UB y panic: decidir por
bloque de código, con coste de rendimiento medible.

### 10.3 JavaScript — el anti-ejemplo instructivo

No hay enteros: `Number` es **IEEE 754 binary64** (entero exacto hasta
±(2⁵³−1)) y los anchos viven sólo en las **TypedArrays** (`Int8Array` …
`BigUint64Array`) para datos binarios. `BigInt` (2020) añade precisión
arbitraria pero no se mezcla con `Number` sin conversión explícita. Lección
para Astra: los anchos «sólo en la capa de datos» son un callejón cuando el
dominio es numérico (contadores de longitud > 2⁵³, índices de buffers).

### 10.4 Kotlin — firmado primero, unsigned después

`Byte/Short/Int/Long` firmados como modelo principal; `UByte/UShort/UInt/ULong`
estables desde Kotlin 1.5 (beta desde 1.3) — y con soporte de API limitado
(p. ej. la stdlib sigue tragándose `Int` en colecciones/índices). Muestra el
precio de llegar tarde con unsigned: convives con dos modelos y el ecosistema
elige el viejo.

## §11 — Tablas comparativas

### 11.1 Semántica de overflow (el espectro completo)

| Escala | Lenguajes | Contrato |
|:-------|:----------|:---------|
| **UB** (puede hacer cualquier cosa) | C, C++ (signed) | el compilador asume que no desborda |
| **Wrap definido** | Go (ambos), C# (unchecked), Rust (release), Zig (`.fast`), Java (ambos), Astra (runtime i64) | módulo 2^n, determinista |
| **Panic/trap** | Rust (debug), Swift, Zig (`.safe`), C# (checked) | el programa falla ruidosamente |
| **Imposible** | Python, JS `BigInt`, constantes sin tipo de Go/Zig | precisión arbitraria |

### 11.2 Manejo de un literal fuera de rango del tipo anotado

| Lenguaje | `x: u8 = 300` | Resultado |
|:---------|:--------------|:----------|
| C | `uint8_t x = 300;` | compila; trunca a 44 (aviso sólo con `-Wconversion`) |
| Java | `byte b = 300;` | error de compilación |
| C# | `byte b = 300;` | error de compilación |
| Go | `var x uint8 = 300` | error de compilación |
| Rust | `let x: u8 = 300;` | error «literal out of range» |
| Swift | `let x: UInt8 = 300;` | error de compilación |
| Zig | `const x: u8 = 300;` | error comptime |
| Python | `x = 300` | no aplica (sin ancho) |
| **Astra** | `let x: i32 = 2147483648;` | **error compile-time** (DEC-006) `[verificado, §13.1]` |

### 11.3 ¿Promociones implícitas?

| Con promociones (legado C) | Sin promociones (seguridad explícita) |
|:---------------------------|:--------------------------------------|
| C, C++, Java, C# | Rust, Go, Swift, Zig, **Astra** |

La tabla no es aleatoria: los tres primeros nacieron antes de que los bugs de
promoción fueran famosos (o los toleran por compatibilidad ABI); los cinco
segundos son de 2009+ y diseñaron el tipo enteros desde cero.

## §12 — Síntesis: las cinco decisiones de diseño y su precio

1. **Ancho: fijo vs arbitrario.** Fijo (todos salvo Zig/Python/JS) = layout
   predecible, mapeo a ISA, pero API frágiles al crecer. Arbitrario (Zig) =
   modelado exacto de binarios y precondiciones de rango, a costa de comptime
   y tipos «raros». Python/JS esconden el ancho en la librería/datos.
2. **Signed/unsigned: dos familias vs una.** C/C++/Rust/Zig/Go/C#/Swift
   mantienen las dos (el unsigned sirve para bits, módulo, binarios, rangos
   dobles); Java demostró que se puede vivir sin (con helpers), y Swift/Go
   demuestran que el default firmado + unsigned opcional es sostenible. La
   regla emergente (Google style, guía Swift): **unsigned para bits/módulo,
   firmado para cantidades**.
3. **Implicitness: promociones vs cast explícito.** Las promociones ahorran
   ruido pero ocultan cambios de rango y signedness (§4.3); el cast explícito
   (Rust/Zig/Swift/Go/Astra) convierte cada cambio de ancho en una decisión
   revisable en el diff.
4. **Overflow: UB → wrap → trap → imposible** (§11.1). El eje es *quién paga*
   el bug: UB lo paga el usuario final en producción; wrap lo paga el
   programador que audita; trap lo paga el tester ruidosamente; big-int lo paga
   el caché. Zig añade el giro de 2020+: elegir por modo de compilación
   (`.safe` vs `.fast`) en vez de por lenguaje.
5. **Default word type.** C (`int`), Go (`int`), Swift (`Int`), Rust (`usize`
   para índices), Astra (i32→i64) — todos convergen en «que el caso normal no
   requiera elegir», y el ancho pequeño queda para arrays/protocolos.

Ninguna de las diez familias es «mejor» en abstracto: son puntos de un mismo
espacio de compromiso entre **determinismo**, **rendimiento** y **cuánto ruido
está el programador dispuesto a escribir**.

## §13 — Astra hoy y aprendizajes (todo `[verificado]` en este worktree)

### 13.1 Estado empírico del seed (2026-10-29, HEAD `1a2eddb`)

Ejecutado con `seed/astra-seed` (build de desarrollo, clang):

| Probe | Entrada | Salida |
|:------|:--------|:-------|
| Inventario de tipos | `let x: T = 1` con `T ∈ {i8,i16,i32,i64,u8,u16,u32,u64,i128,u128,isize,usize}` | **sólo `i32`, `i64`, `u32`, `u64` compilan**; el resto: `unknown type 'u8'` etc. |
| Promoción mixta | `let a: i32 = 1; let b: i64 = 2; print(a + b);` | `error: type mismatch: cannot apply '+' to i32 and i64` |
| Signedness mixta | `let a: u32 = 1; let b: i32 = 2; print(a + b);` | `error: type mismatch: cannot apply '+' to u32 and i32` |
| Literal fuera de rango | `let x: i32 = 2147483648;` | `error: integer literal 2147483648 out of range for i32` (rc=1, DEC-006) |
| Wrap en u32 | `let x: u32 = 4294967295; print(x + 1);` | `4294967296` — **no envuelve a 32 bits**: la aritmética corre en el i64 del runtime |
| Límite de literales u64 | `let x: u64 = 18446744073709551615;` | `error: integer literal is out of range for i64` (**en el parser**, rc=1) — `u64` no admite literales por encima de `i64::MAX` hoy |

Coherente con `seed/tests/conformance/types/int_width_semantics.astra`
[leído] y con `research/027` §1: los anchos son **contrato de chequeo de
tipos**; el runtime es **un i64 con wrap de dos complementos definido** en
las cuatro rutas (VM C, VM Zig, C codegen, LLVM — `LLVMBuildAdd` sin
`nsw`/`nuw`). DEC-006/007 lo registran; el checked-overflow (1D) quedó
pospuesto a Fase 2 tras un `--overflow=check`.

### 13.2 Dónde queda Astra en el mapa

- **Familia y promociones**: bando Rust/Zig/Go/Swift (sin promoción, tipos
  explícitos) — la opción moderna, verificada arriba.
- **Overflow**: wrap definido = Go, Rust-release, Java, C# unchecked. Es el
  contrato más barato de implementar en 4 runtimes y ya está fijado por test.
- **Anchos**: el hueco más notable frente a todos los lenguajes de la tabla
  es la **ausencia de `i8`/`u8`/`i16`/`u16`** — justo el tipo que más se usa
  en binarios, texto y protocolos. Astra-0 los difiere (el runtime es i64),
  pero el *surface* los podría tener ya como contrato de tipo (igual que
  `i32` hoy, que tampoco envuelve a 32 bits): el coste de añadirlos al
  typechecker es el mismo que tuvieron `i32`/`u32`, y lo confirma la
  asimetría de que `u64` existe pero sus literales están techoados a
  `i64::MAX` en el parser.
- **Límite heredado**: el techo de literales en el parser (`u64` > `i64::MAX`
  rechazado) es un artefacto de representar literales en `i64` del host, no
  una decisión de diseño registrada — candidato a discusión cuando se toque
  el typechecker (`research/032` es el inventario de checks).

### 13.3 Qué NO hacer (y por qué)

Ninguna acción de este informe cambia comportamiento: añadir `i8`/`u8`,
mover el techo de literales o introducir checked-overflow son **cambios de
lenguaje** y, por la regla 1 de AGENTS.md, cada uno exige su `DEC-NNN` +
test de conformidad en el mismo PR. Este dossier existe para que esa
discusión se lleve los datos de §3–§12 puestos sobre la mesa.

## §14 — Fuentes

**Primarias / oficiales** (consultadas 2026-10-29):
- Zig 0.17.0 release notes y nota de lanzamiento (2026-10-02):
  https://ziglang.org/download/0.17.0/release-notes.html ·
  https://ziglang.org/news/0.17.0-released/
- Referencia del lenguaje Zig 0.17 (enteros arbitrarios, builtins, safety):
  https://ziglang.org/documentation/0.17.0/ `[verificado por lectura directa]`
- Guía comunitaria «What Changed in Zig 0.17» (snippets CI-verificados):
  https://www.ziglang.in/learn/getting-started/zig-0-17/ `[verificado]`
- Referencia de Rust (enteros, overflow):
  https://doc.rust-lang.org/book/ch03-02-data-types.html · RFC 560
  https://rust-lang.github.io/rfcs/0560-integer-overflow.html
- Guía de tipos de Java: https://docs.oracle.com/javase/tutorial/java/nutsandbolts/datatypes.html
- `sys.int_info` local (Python 3.13.5) `[verificado por ejecución]` ·
  docs C API de PyLong: https://docs.python.org/3/c-api/long.html
- Guía de Swift «The Basics»: https://docs.swift.org/latest/documentation/the-swift-programming-language/thebasics · SE-0425 (Int128):
  https://github.com/swiftlang/swift-evolution/blob/main/proposals/0425-int128.md
- Tour de Go: https://go.dev/tour/basics/11
- Tipos sin signo en Kotlin: https://kotlinlang.org/docs/unsigned-integer-types.html
- BigInt en JS (V8): https://v8.dev/features/bigint

**Secundarias / análisis**:
- N2218 «Signed Integers are Two's Complement» (WG14, → C23):
  https://www.open-std.org/jtc1/sc22/wg14/www/docs/n2218.htm
- Resumen de reglas C/C++ (Nayuki): https://www.nayuki.io/page/summary-of-c-cpp-integer-rules
- Dietz et al., *Understanding Integer Overflow in C/C++* (CACM 2012):
  https://users.cs.utah.edu/~regehr/papers/overflow12.pdf
- Sorpresas de promoción en unsigned (Hurchalla):
  https://jeffhurchalla.com/2019/01/16/c-c-surprises-and-undefined-behavior-due-to-unsigned-integer-promotion/
- C++20 y dos complementos: https://stackoverflow.com/questions/57363324/ramifications-of-c20-requiring-twos-complement
- Zig: reglas de promoción/cast y overflow en release (issue #7967):
  https://github.com/ziglang/zig/issues/7967 · padded bits (issue #11263):
  https://github.com/ziglang/zig/issues/11263
- Por qué ganó el complemento a dos:
  https://retrocomputing.stackexchange.com/questions/7095/why-did-ones-complement-decline-in-popularity
- Int128 en .NET: https://learn.microsoft.com/en-us/dotnet/api/system.int128
- Swift e índices firmados: https://forums.swift.org/t/why-does-swift-use-signed-integers-for-unsigned-indices/69812
