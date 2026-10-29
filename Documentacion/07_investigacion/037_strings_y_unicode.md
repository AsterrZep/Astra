# 037 — Strings y Unicode: UTF-8 vs UTF-16 vs graphemas, y qué le conviene a Astra

> **Alcance**: dossier sobre los modelos de string — codificación interna,
> qué mide `len()`, indexación, normalización, seguridad y orden — en Go,
> Rust, Python, Zig, Java, C#, JavaScript, Swift, Kotlin, PHP, C y SQL, con
> la tabla de divergencias real entre unidades de medida y el encaje con el
> modelo byte-oriented de Astra (DEC-013/018/020). **No cambia ningún
> comportamiento.** Fecha: **2026-10-29**. `[verificado]` = ejecutado o
> leído en esta sesión (Debian, HEAD `90e4e00`, worktree `Astra-wt/int-types`);
> `[citado]` = fuente externa con URL en §14.

---

## §0 — TL;DR

1. **Hay 4 unidades de «longitud» y ningún lenguaje coincide en todas**:
   bytes (Go/Rust/Zig/PHP/Astra), code points (Python), code units UTF-16
   (Java/C#/JS/Kotlin) y **grapheme clusters** (Swift). Una misma cadena
   `👩‍👩‍👧` mide **5 / 18 / 8 / 1** respectivamente (calculado con
   CPython en el brief de fuentes) — cualquier API que «cuente caracteres»
   está eligiendo una sin decirlo.
2. **Tres campamentos + uno raro**: **bytes** (Go, Rust, Zig, PHP y
   Astra — el bando sistemas), **UTF-16** (Java, C#, JS, Kotlin — el
   bando herencia Windows/JS), **graphemes** (Swift — el bando UI-correcto),
   y **Python** con representación flexible (PEP 393: 1/2/4 bytes por
   carácter) y longitud en code points.
3. **UTF-8 ganó en la práctica**: sin endianness, compatible con ASCII
   (1 byte, sin NUL → `strlen`, HTTP, JSON, HTML), orden lexicográfico =
   orden de code points (UTF-16 no), y en texto HTML real pesa **−55 %**
   que UTF-16 (767 KB vs 1186 KB; el texto denso asiático es el único
   donde UTF-16 gana ~21 %) `[citado: utf8everywhere.org]`. Java lo
   admitió a medias: JEP 254 hizo `String` = `byte[]` + flag (Latin-1/UTF-16)
   con «*not a goal to use UTF-8*», y JEP 400 puso UTF-8 en las APIs.
4. **El mito del O(1) de UTF-16**: también es variable-length (surrogate
   pairs) — su acceso aleatorio es O(1) sólo a *code units*, no a
   caracteres `[citado: utf8everywhere]`. El coste real de UTF-8 (escanear
   para encontrar límites) se amortiza con SIMD: `simdutf` transcodifica
   **≥1000 M caracteres/s**, 3-10× ICU en no-ASCII `[citado]`.
5. **Astra hoy es byte-oriented y ya está fijado por tests** `[verificado]`:
   `len(s)` = bytes, `s[i]` = string de 1 byte con bounds-check en runtime,
   `ord("á")` = **195** (primer byte), `for c in s` = byte a byte
   (DEC-013/018/020), escapes sólo `\n \t \r \\ \" \0` (**sin `\uXXXX`**),
   UTF-8 crudo pasa intacto (`len("á")` = 2) y `==` es por interning
   (`"ab" == "a" + "b"` → `true`). Recomendación: **mantener bytes como
   semántica primaria** (bando Go/Zig) y añadir capas Unicode
   complementarias sin romper DEC-013 (§13).

---

## §1 — Anatomía: las 4 unidades y los 2 ejes

```
bytes UTF-8:     61 62 63           ← Go/Rust/Zig/PHP/Astra miden aquí
code points:     'a' 'b' 'c'        ← Python; U+00E9, U+1F600…
code units U16:  D83D DC40          ← Java/C#/JS/Kotlin (surrogates)
graphemes:       "👩‍👩‍👧" (1 carácter visual) ← Swift; UAX #29
```

Los dos ejes de diseño: **(a) ¿qué unidad expone `len`/`[]`?** y
**(b) ¿qué pasa con bytes inválidos?** — de ahí salen todas las
diferencias de §10.

## §2 — UTF-8 vs UTF-16: la guerra ya ganada

| Criterio | UTF-8 | UTF-16 |
|:---------|:------|:-------|
| ASCII | 1 byte, idéntico | 2 bytes |
| HTML/texto occidental | **767 KB vs 1186 KB (+55 %)** | pierde |
| Texto denso asiático | 222 KB vs 176 KB | gana ~21 % |
| Tras gzip | la ventaja casi desaparece | — |
| Endianness | ninguna (BOM innecesario y desaconsejado) | sí (por eso el BOM) |
| Orden lexicográfico | byte-a-byte = orden Unicode | **no coincide** (surrogates) |
| Cadenas C (`strlen`, HTTP, JSON, HTML) | seguro byte-a-byte | rompe todo |
| Acceso a code point i-ésimo | O(n) (escaneo) | O(1) a units, O(n) a chars |
| Búsqueda de `<`, `'` o ASCII | seguro | no |

`[citado: utf8everywhere.org]` — y el dato incómodo para Java: JEP 254
(JDK 9) cambió `String` de `char[]` a **`byte[]` + flag de codificación**
ahorrando ~50 % de heap en cadenas Latin-1, pero con «*It is not a goal to
use alternate encodings such as UTF-8*» `[citado: openjdk.org/jeps/254]`;
JEP 400 (JDK 18) puso UTF-8 como charset **por defecto de las APIs**,
no de la representación `[citado: jeps/400]`.

## §3 — Por lenguaje

- **Go** `[citado: go.dev/blog/strings, spec]`: `string` = «secuencia de
  bytes de solo lectura»; `len` = bytes; fuente UTF-8; `for range`
  decodifica un **rune** por vuelta; bytes inválidos → `U+FFFD`
  (`RuneError`); `s[i]` es **el byte**.
- **Rust** `[citado: std/primitive.str]`: `&str` = ptr+len con
  **invariante UTF-8** («libraries may assume that string slices are
  always valid UTF-8»); `str::len()` = «in bytes, not chars or
  graphemes» (`"ƒoo".len() == 4`); `from_utf8` → `Result`; indexar/slicear
  fuera de límite de code point **pánica** (`split_at`).
- **Python 3** `[citado: stdtypes, PEP 393]`: «immutable sequences of
  Unicode code points»; representación **flexible 1/2/4 bytes** por
  carácter (ASCII = 1 byte); `len` = code points (NFC `ê` = 1, NFD = 2);
  `decode("utf-8","strict")` → `UnicodeDecodeError`.
- **Zig** `[citado: langref#Strings]`: literales = `*const [N:0]u8`;
  «indexing … returns individual bytes, whether valid UTF-8 or not»;
  `\xNN` permite bytes no-UTF-8 — el nivel más crudo, deliberadamente.
- **Java** `[citado: Oracle i18n, JEP 254/400, String.java]`: `char` = 16
  bits porque Unicode era de 16 bits en 1995; suplementarios = *surrogate
  pairs*; `length()` = nº de **code units**; `equals` = «identical char
  sequence of UTF-16 code units».
- **C#** `[citado: MS Learn String.Length]`: `Length` = nº de `Char`,
  «not the number of Unicode characters… use `StringInfo`».
- **JavaScript** `[citado: MDN String/length]`: `length` = units UTF-16
  (emoji = 2); `emoji.length` = 2 pero `[...emoji]` = 1; graphemas vía
  `Intl.Segmenter`; límite V8 ~1 GiB (2^29−24).
- **Swift** `[citado: String.swift]`: `String` = colección de **extended
  grapheme clusters**; índice = `String.Index` (**no `Int`**); `==`/`<`
  en representación canónica y *locale insensitive*; vistas
  `utf8`/`utf16`/`unicodeScalars` cuando toca.
- **Kotlin** `[citado: kotlinlang]`: `Char` = code unit UTF-16 (emoji = 2).
- **PHP** `[citado: php.net]`: «a character is the same as a byte… does
  not offer native Unicode support» — arrays de bytes, indexación no
  multibyte-safe.
- **C** `[citado: cppreference]`: bytes + NUL; orden según `LC_COLLATE`
  (arranque en locale `"C"`); `strcoll` para orden de locale.
- **SQL/PostgreSQL** `[citado: postgresql.org]`: `varchar(n)` = hasta **n
  caracteres**; collation *deterministic* = igualdad por bytes,
  *nondeterministic* (ICU) iguala formas normales/mayúsculas (UTS#10).

## §4 — Qué cuenta `len()` (divergencias reales)

Calculadas con CPython (code points) vs UTF-8/UTF-16/`graphemes`:

| Cadena | code points (Python) | bytes (Go/Rust/Zig/Astra) | units UTF-16 (Java/C#/JS) | graphemes (Swift) |
|:-------|---------------------:|--------------------------:|--------------------------:|------------------:|
| `é` (NFC, U+00E9) | 1 | 2 | 1 | 1 |
| `e`+U+0301 (NFD) | **2** | **3** | **2** | **1** |
| `👩‍👩‍👧` (2 ZWJ) | **5** | **18** | **8** | **1** |
| `🇵🇷` (bandera) | 2 | 8 | 4 | 1 |
| `日本語` | 3 | 9 | 3 | 1 |

Lección: **toda API de «caracteres» necesita decidir la columna**; Swift
eligió la última (UI correcta, índice no-int), Astra la segunda (bytes,
O(1)).

## §5 — Indexación

- **Bytes**: Go, Zig, PHP — `s[i]` puede caer a mitad de un code point
  (y no pasa nada: es un byte). Rust indexa por rangos de bytes **sólo**
  en límites de code point (si no, pánica). **Astra**: `s[i]` = 1 byte con
  bounds-check `[verificado §12]`.
- **Code points**: Python (`s[i]` «efficient» gracias a PEP 393).
- **Units UTF-16**: Java/C#/JS — `s[i]` puede devolver la mitad de un
  surrogate (el emoji partido por la mitad, el bug clásico).
- **Graphemes sin `Int`**: Swift recorre (`count` es O(n); `isEmpty` O(1)).
- **Por qué UTF-8 «indexa O(n)»**: los límites de code point no se
  conocen sin escanear (Rust: `is_char_boundary`); el manifiesto discute
  el trade-off: Python compró O(1) a code points con 1/2/4 bytes de
  memoria.

## §6 — Normalización

- **Formas**: NFC/NFD/NFKC/NFKD (`unicodedata.normalize`) `[citado]` —
  `ê` puede ser 1 o 2 code points (**len 1 vs 2**), `casefold` con
  `ß`→`ss`; comparar sin normalizar da falsos negativos.
- **Quién la hace**: Swift **automática** en `==` («Cafe\u{301}» ==
  «Café» → true, canónica y locale-insensitive); JS
  `String.prototype.normalize`; Rust vía crate `unicode-normalization`
  (**645 M descargas**, actualizado 2026-10 `[citado: crates.io]`);
  Python explícita; PHP no.
- **Ficheros**: HFS+/macOS guarda **NFD** (descompuesto y ordenado —
  TN1150); NTFS/APFS **[no verificado en primaria]** — pero la consecuencia
  práctica (un fichero con dos «nombres» distintos según SO) es el motivo
  clásico de normalizar al guardar.
- **Bases de datos**: PostgreSQL recomienda normalizar al guardar; la
  collation nondeterministic compara a cambio de coste.

## §7 — Seguridad

- **Homoglyph/IDN spoofing**: UTS#39 define detección por *skeleton*
  (`scope` vs `ѕсоре` cirílico), scripts mezclados, `confusables.txt`
  `[citado: unicode.org/reports/tr39]` — la capa de red/DNS es donde va,
  no el runtime.
- **Overlong UTF-8**: RFC 3629 — decodificar `C0 80` como U+0000 «may
  have security consequences» (bypass de filtros).
- **JSON**: RFC 8259 §8.1 — texto intercambiado **MUST be UTF-8**, sin
  BOM; §8.2 — surrogates huérfanos (`"\uDEAD"`) con comportamiento
  impredecible.
- **Políticas ante bytes inválidos** (el eje (b)): **Rust** rechaza en
  creación (`Err(Utf8Error)`) y sólo paniquea al slicear; **Go** acepta
  bytes arbitrarios y devuelve `U+FFFD` al decodificar; **Python**
  `strict` → excepción, `replace` → `U+FFFD`; **Zig** acepta y indexa sin
  error; **Java** (con JEP 400) convive con charset por defecto
  documentado como riesgo histórico.

## §8 — Comparación y orden

- **`==` byte-a-byte ≠ orden Unicode** sólo en UTF-16/UTF-32; **en UTF-8
  sí coinciden** `[citado: utf8everywhere]` — otra ventaja estructural.
- Orden de locale: C `strcoll(LC_COLLATE)`, ICU *tailoring* (ignorar
  acentos/mayúsculas/puntuación), PostgreSQL collation por columna.
- Case-insensitive: `casefold()` (Python) — no `lower()` (el `ß` no
  sobrevive a `lower`).

## §9 — Rendimiento

- **Conversión a UTF-16 en llamadas de Windows**: medida ~**1 ± 2 %**
  (`CreateFile` 184 µs vs 186 µs) — el coste de «UTF-8 everywhere» es
  ruido `[citado: utf8everywhere]`.
- **SIMD**: `simdutf` ≥1000 M caracteres/s, **3-10× ICU** en no-ASCII y
  ~20× en ASCII; integrado en Node: **+364 %** en decodificación
  `[citado: github.com/simdutf/simdutf]`. Validación: DFA de Hoehrmann y
  «ridiculously fast UTF-8 validation» de Lemire.
- **Memoria**: JEP 254 ahorra ~50 % en Latin-1; PEP 393 hace lo propio en
  Python — ambos confirmando que el tamaño del representation importa
  tanto como la codificación.

## §10 — Tabla comparativa transversal

| Lenguaje | Interno | `len` = | `s[i]` = | Inválidos | `==` |
|:---------|:--------|:--------|:---------|:----------|:-----|
| **Go** | bytes UTF-8 | bytes | byte | `U+FFFD` | bytes |
| **Rust** | bytes + invariante | bytes | byte (slices en boundary) | `Err` al crear | bytes |
| **Zig** | `*const [N:0]u8` | bytes | byte | acepta | bytes |
| **PHP** | bytes | bytes | byte | acepta | bytes |
| **Astra** | bytes internados | **bytes** `[v]` | **1 byte, bounds-checked** `[v]` | UTF-8 crudo pasa `[v]` | **por interning** `[v]` |
| **Python** | flexible 1/2/4 B | code points | code point | excepción/`replace` | code points |
| **Java** | `byte[]`+flag (JEP 254) | units UTF-16 | unit (¡surrogate!) | replacement | units UTF-16 |
| **C#** | UTF-16 | `Char`s | `Char` | replacement | units |
| **JS** | UTF-16 | units | unit | replacement | units |
| **Kotlin** | UTF-16 | units | unit | — | units |
| **Swift** | UTF-8 canónico | **graphemes** | `String.Index` (no `Int`) | — | canónica/locale-insens. |

## §11 — Síntesis: 3 campamentos y su precio

1. **Bytes (Go/Rust/Zig/PHP/Astra)**: precio = el programador pide
   `chars()`/`code_points()` cuando necesita caracteres; gana = sin
   surprises de rendimiento, FFI y binarios triviales, `len` es O(1) y
   = memoria.
2. **UTF-16 (Java/C#/JS/Kotlin)**: precio = surrogate pairs por
   todas partes (`length` engaña, `s[i]` parte emojis, BOM, orden raro);
   gana = compatibilidad histórica (Win32/ObjC/JS) y O(1) a units.
3. **Graphemes (Swift)**: precio = sin `Int`-indexing, `count` O(n),
   complejidad UAX#29 en el runtime; gana = UI siempre correcta (no
   partir emoticonos ni acentos combinantes).
4. **Python (flexible)**: el cuarto camino — representation adaptativa +
   code points + biblioteca Unicode completa en stdlib.

Ninguno es «el correcto»: **la unidad correcta depende de la capa**
(bytes en almacenamiento/protocolos, code points en procesamiento,
graphemes en UI) — los buenos lenguajes exponen las tres (Swift con
vistas, Rust con `bytes()/chars()`, JS con `Segmenter`).

## §12 — Astra hoy: retrato `[verificado — probes + lecturas]`

| Probe / fuente | Resultado |
|:---------------|:----------|
| `len(s)` / `s[0]` / `ord` / `chr` | `5`, `"h"`, `65`, `"B"` — **el PR1 de research/028 ya aterrizó** (la tabla de 028 que marcaba `s[i]` ❌ está desactualizada) |
| `s[5]` sobre `"abc"` | `runtime error: index 5 out of bounds (len 3)` — bounds-check en runtime, rc=1 |
| `ord("á")` | **195** (0xC3) — `ord` = primer byte, dominio 0..255 (DEC-018) |
| `len("á")` (UTF-8 crudo) | **2** — bytes, y el literal UTF-8 pasa intacto |
| escapes (`lexer.c:170-179`) | sólo `\n \t \r \\ \" \0` — **sin `\uXXXX` ni `\xNN`**; UTF-8 sólo «crudo desde el fichero» |
| `"ab" == "a" + "b"` | `true` — `==` por **interning** (astra.h: «compared by pointer comparison») |
| `to_string(42)` | `42` — existe (PR2 de 028) |
| `for c in s` | byte a byte, `c: string` de 1 byte (DEC-020, test `loops/for_string.astra`) |
| `let x: i32 = 0; x + len(s)` | `type mismatch: cannot apply '+' to i32 and i64` — sin promoción (informe `034` §13) |

Todo coherente con DEC-013 (`len`/`s[i]` → string de 1 byte, OOB = error),
DEC-018 (`ord` = primer byte, `substr` en bytes, «nunca recorta») y
DEC-020 (`chr` ∈ [0,255], `for c in s` byte a byte) — **el contrato de
bytes ya está test-pinned en las cuatro rutas**.

## §13 — Recomendación para Astra

1. **Mantener bytes como semántica primaria** (bando Go/Zig): `len`,
   `s[i]`, `ord`, `chr`, `substr` miden bytes — romperlo reabriría
   DEC-013/018/020 y arruinaría el coste O(1) de `s[i]` (§5).
2. **Capas complementarias en stdlib, no en el tipo** (todas condicionadas
   a sus `DEC-NNN`):
   - `code_points(s)` y `graphemes(s)` como iteradores (UAX#29 para
     graphemes; cross-ref informe `036` — el protocolo Iterator de la
     Fase 1/2 encaja aquí exactamente);
   - `normalize(s, form)` opcional (referencia: crate
     `unicode-normalization`);
   - comparación: `==` por bytes **documentado** + `compare_ci`/
     collation en librería (ICU detrás, como PostgreSQL);
   - validación UTF-8 explícita estilo Rust (`Result`, no pánico) en la
     frontera de decodificación/FFI (cross-ref `035` §5);
   - anti-spoofing UTS#39 en la capa de red/DNS, jamás en el runtime.
3. **Una entrada de DEC que fije «`len` = bytes» y el plan de capas
   Unicode por fases**, para que la futura discusión de graphemes no
   reabra DEC-013 — el mismo patrón «registrar sin re-litigar» de la
   regla 2 de AGENTS.md.
4. **Escapes Unicode (`\u{...}`)**: candidato a DEC cuando se necesite
   escribir code points sin fichero UTF-8 (hoy el hueco es real: no se
   puede escribir `"\u{1F600}"` ni un byte `\xFF` con escape — sólo
   crudo o `\0`).

## §14 — Fuentes

**Primarias / verificadas en esta sesión**:
- Probes del seed (§12): `seed/astra-seed` sobre `str1..str6.astra`,
  `mem_str*.astra` en `/tmp/opencode/intprobe` `[ejecutado]` ·
  `seed/src/lexer.c:141-184` (escapes) · `seed/include/astra/astra.h:53`
  (interning) · DEC-013/018/020 (`DECISIONES.md`) `[leído]`
- The Rust Book/`std`: https://doc.rust-lang.org/std/primitive.str.html
- Go strings: https://go.dev/blog/strings · spec: https://go.dev/ref/spec
- Python stdtypes/PEP 393/unicode howto:
  https://docs.python.org/3/library/stdtypes.html ·
  https://peps.python.org/pep-0393/ · https://docs.python.org/3/howto/unicode.html
- Zig langref (Strings): https://ziglang.org/documentation/master/#Strings
- Java: JEP 254 https://openjdk.org/jeps/254 · JEP 400
  https://openjdk.org/jeps/400 · tutorial i18n:
  https://docs.oracle.com/javase/tutorial/i18n/text/unicode.html
- Swift String.swift:
  https://raw.githubusercontent.com/apple/swift/main/stdlib/public/core/String.swift

**Secundarias / canónicas**:
- UTF-8 Everywhere (manifiesto, tablas de tamaño, mito O(1), costes de
  conversión): https://utf8everywhere.org/
- MDN String/length: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/length
- C# String.Length/StringInfo:
  https://learn.microsoft.com/en-us/dotnet/api/system.string.length
- Kotlin chars/strings: https://kotlinlang.org/docs/characters.html
- PHP strings (bytes): https://www.php.net/manual/en/language.types.string.php
- PostgreSQL varchar/collation:
  https://www.postgresql.org/docs/current/datatype-character.html ·
  https://www.postgresql.org/docs/current/collation.html
- UTS#39 (confusables): https://www.unicode.org/reports/tr39/ · RFC 3629:
  https://www.rfc-editor.org/rfc/rfc3629.txt · RFC 8259 §8.1/8.2:
  https://www.rfc-editor.org/rfc/rfc8259.txt
- Normalización: unicodedata https://docs.python.org/3/library/unicodedata.html
  · crate unicode-normalization: https://crates.io/crates/unicode-normalization
  · HFS+ NFD (TN1150):
  https://developer.apple.com/library/archive/technotes/tn/tn1150.html
- Rendimiento: simdutf https://github.com/simdutf/simdutf · DFA de
  Hoehrmann https://bjoern.hoehrmann.de/utf-8/decoder/dfa/ · Lemire
  https://lemire.me/blog/2020/10/20/ridiculously-fast-unicode-utf-8-validation/
- ICU collation: https://unicode-org.github.io/icu/userguide/collation/
