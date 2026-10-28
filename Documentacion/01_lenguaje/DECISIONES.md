# DECISIONES — registro de decisiones de lenguaje

> **Alcance**: única fuente de verdad de *qué* está decidido sobre el lenguaje
> (semántica, layout, diagnósticos, alcance, memoria). La especificación
> normativa sigue en `ARCHITECTURE.md`; aquí se registra qué se decidió, cuándo,
> por qué, con qué coste y **qué test lo fija**. Creado: 2026-10-27.
> Mantenimiento: reglas 1–5 de `AGENTS.md` §«Language decisions».

| ID | Decisión (una frase) | Estado | Fecha | Evidencia |
|:---|:---------------------|:-------|:------|:----------|
| DEC-001 | `let b = a` comparte el handle; no copia los elementos | Aceptada (test-pinned); ratificada 2026-10-27 (D2) | 2026-09-21 | `seed/tests/conformance/arrays/alias_write.astra` (`EXPECT: 99`) |
| DEC-002 | El seed no migra los hooks `parse/check/emit`; el registro es declarativo + validado | Aceptada (doc) | 2026-09-21 | `CONSTRUCT_REGISTRY.md` §8; `--check-constructs` → `migrated: 0 / 47` |
| DEC-003 | El separador de rutas de módulo es `.` (no `::`) | Aceptada (test-pinned) | 2026-09 | `seed/tests/conformance/ui/use_colon_colon.astra` |
| DEC-004 | Los closures capturan **por valor** (copian el handle; asignar a una capturada es error de compilación) | Aceptada (test-pinned) | 2026-09 | suite `functions/`+`lambda/`; `AGENTS.md` §C Codegen |
| DEC-005 | El slot 0 de un frame es el callee/return; los parámetros empiezan en el slot 1 | Aceptada (test-pinned) | 2026-09 | `AGENTS.md` invariant 3; conformance de funciones |
| DEC-006 | Un literal fuera de rango de su tipo anotado es **error en compile-time** (con fallback a `i64` si el literal no cabe en el default `i32`) | Aceptada (test-pinned) | 2026-10-27 | `ui/int_literal_range.astra`, `ui/int_literal_range_unsigned.astra`, `types/int_width_semantics.astra` (PR fase B1) |
| DEC-007 | El overflow de enteros en runtime es **wrap definido** (two's complement, documentado); checked-overflow = flag futuro | Aceptada (test-pinned) | 2026-10-27 | `types/int_width_semantics.astra` (`s + s` → wrap) |
| DEC-008 | Las variantes de enums viven en el namespace de su enum; la construcción **calificada es obligatoria** (`A.Some2(1)`) | Aceptada (test-pinned) | 2026-10-27 | `research/027` §4; `enums/qualified_construction.astra` (EXPECT 1/2/3), `ui/enum_bare_construction_rejected.astra` (PR fase B2) |
| DEC-009 | Los VMs (seed/zig) y el backend C no liberan memoria (arena/vitalicio); la ruta LLVM libera con ARC — divergencia **documentada y gateada** con techo de RSS | Aceptada (test-pinned + gate) | 2026-10-27 | `memory/loop_reuse.astra` + gate `zig/tests/llvm_mem.sh` (techo 64 MB, CI job `llvm`) |
| DEC-010 | Los floats se imprimen con formato `%g` | Aceptada (test-pinned) | 2026-09 | conformance de expresiones |
| DEC-011 | Las sentencias se terminan con `;` o con newline | Aceptada (test-pinned) | 2026-09 | suite de conformidad (estilo mixto) |
| DEC-012 | Modelo de enforcement entre fibras = **Opción F** (`research/026`: regla de cruce con unicidad comprobada; `transfer(x)` será builtin, sin keyword; el walk de rc se difiere al primer cruce real — scheduler/send) | **Propuesta** (D7 pospuesto; Fase 0 completada: `ARCHITECTURE.md` §2.6 escrita) | 2026-10-27 | `research/026` §3–§4; `ARCHITECTURE.md` §2.6; `research/031` §0 |
| DEC-013 | Stdlib M1: `len(x) -> i64` para arrays y strings; `s[i]` → **string de 1 byte** (OOB = error de runtime con el texto de los arrays); los strings son inmutables (`s[i] = …` es error de compilación) | Aceptada (test-pinned) | 2026-10-27 | `arrays/len_array.astra`, `expressions/len_string.astra`, `expressions/str_index.astra`, `expressions/str_index_oob.astra`, `expressions/len_int_runtime_error.astra`, `ui/str_index_assign_rejected.astra`, `codegen/str_index.astra`, `codegen/len_builtin.astra` (PR D-PR1) |
| DEC-014 | Stdlib M1: `to_string(x) -> string` **solo enteros** (otros tipos = error de runtime con el texto de las 4 rutas) y `read_file(path: string) -> string` (todo fallo de apertura/lectura colapsa en `cannot open file '<path>'`); la lectura positiva vive fuera de `conformance/` | Aceptada (test-pinned) | 2026-10-27 | `expressions/to_string_roundtrip.astra`, `expressions/to_string_float_rejected.astra`, `expressions/read_file_missing.astra`, `expressions/read_file_nil_path.astra`, `codegen/to_string.astra`, `codegen/read_file_missing.astra`, `seed/tests/selfhost/io_gate.sh` (4 rutas) (PR D-PR2) |
| DEC-015 | Los nombres de builtin (`print`, `len`, `to_string`, `read_file`) están **reservados**: redeclararlos con `let`/`const`/`fn` en cualquier ámbito es error de compilación, idéntico en los dos typecheckers | Aceptada (test-pinned) | 2026-10-27 | `ui/builtin_shadow_print.astra`, `ui/builtin_shadow_len.astra`, `ui/builtin_shadow_to_string.astra`, `ui/builtin_shadow_read_file.astra` (primera línea byte-idéntica seed↔zig) (PR D-PR2) |
| DEC-016 | El lexer de Astra-0 (`seed/tests/selfhost/lexer.astra`) es el primer componente self-hosting: lexea `lexer_input.astra` con solo los builtins M1 y emite un token por línea `<KIND>:<lexeme>@<line>`; el stream se gatea byte a byte contra `lexer.expected` en las 4 rutas, fuera de `conformance/` (cwd) | Aceptada (test-pinned) | 2026-10-27 | `seed/tests/selfhost/lexer_gate.sh` → 4/4 rutas (seed VM, `--emit-c`+gcc, zig VM, LLVM `--jit`) contra `lexer.expected` (PR D-PR3a; rutas y gate fuerte cerrados en DEC-017) |
| DEC-017 | Cierre del gate del lexer self-hosting (PR3b): `lexer_gate.sh` crece a **7 rutas** ( + `--emit-obj`+link nativo, cross aarch64 bajo qemu, wasm32-wasi bajo Node WASI con preopens — cada una con skip limpio sin su toolchain) y añade el **gate fuerte** `lexer_tokens_parity.sh` (el stream de `lexer.astra` normalizado contra `astra-seed --dump-tokens`: 1:1 en KEYWORD/IDENT(`_`)/INT(hex→valor)/PUNCT/ERROR/EOF; fuera NEWLINE, columnas, contenido de STRING, FLOAT_LIT y la cola tras el primer ERROR); CI lo cablea en los jobs `seed` y `llvm` con los mismos guards, sin renombrar checks | Aceptada (test-pinned) | 2026-10-27 | `seed/tests/selfhost/lexer_gate.sh` → **7/7 rutas** + `lexer_tokens_parity.sh` → **176 tokens** (PR D-PR3b) |
| DEC-018 | Stdlib M2a: `ord(s) -> i64` = **primer byte** de `s` (`""` = error de runtime) y `substr(s, start, len) -> string` = `len` bytes desde `start` (**error, nunca recorte**, fuera de `[0, len(s)]`); los tres parámetros de `substr` y el de `ord` son `unknown` con guards de runtime (sin coerción en la llamada), y los dos nombres se suman a la lista reservada de DEC-015 | Aceptada (test-pinned) | 2026-10-28 | `expressions/ord_basic.astra`, `expressions/ord_empty_error.astra`, `expressions/ord_int_arg.astra`, `expressions/substr_basic.astra`, `expressions/substr_bounds_error.astra`, `expressions/substr_start_error.astra`, `codegen/ord_substr.astra`, `codegen/substr_oob.astra`, `ui/builtin_shadow_ord.astra`, `ui/builtin_shadow_substr.astra` (PR D-PR4a) |

### DEC-006 — Ancho de enteros: rango en compile-time, wrap en runtime
- **Estado**: Aceptada (test-pinned) — fijada en el PR de fase B1 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: `let big: i32 = 9999999999` pasa a ser error de compilación
  (hoy imprime `9999999999`); sin anotación, un literal que no cabe en el
  default `i32` cae a `i64`. El overflow en runtime queda **wrap definido y
  documentado**; checked-overflow puede llegar como flag.
- **Alternativas consideradas**: truncar/saturar en runtime (rompe la
  intuición de C y cuesta en 4 runtimes); ancho real en el bytecode (requiere
  bytecode con tipos — el backend C lee bytecode sin tipos, `research/027` §1).
- **Coste aceptado**: 2 typecheckers (seed + zig); 0 runtimes; mensajes
  seed↔zig byte-idénticos.
- **Evidencia**: fijado por `ui/int_literal_range.astra`,
  `ui/int_literal_range_unsigned.astra` y `types/int_width_semantics.astra`
  (el cuarto EXPECT prueba el fallback `let big = 9999999999` → i64).
- **Spec**: `research/027` §1 — «pendiente de escribir en ARCHITECTURE §8/§9».

### DEC-008 — Variantes de enums: namespace por enum, construcción calificada
- **Estado**: Aceptada (test-pinned) — fijada en el PR de fase B2 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: la construcción **calificada `Enum.Variant(...)` es la única
  legal** para variantes de usuario: `Some2(1)` se rechaza siempre con
  «use Enum.Variant to construct 'Some2'» (no solo cuando hay colisión), y
  el registro plano deja de resolver la forma pelona. Los builtins
  `some/ok/err/none` (Option/Result) siguen pelones: el usuario escribe
  `some(x)`. Las variantes unitarias calificadas ya funcionaban; los
  patrones ya exigen calificación.
- **Alternativas consideradas**: «pelón si es inequívoco» (cuesta 0 tests
  pero deja dos ortografías para siempre y empeora con módulos);
  status quo (primer enum en ganar) — el bug sigue vivo.
- **Coste aceptado**: 2 typecheckers + 3 emisores; 12 conformance + 5
  codegen + 5 fixtures LLVM + 2 unit zig + `llvm_fuzz_gen.py` (lista exacta
  en `research/027` §4).
- **Evidencia**: `enums/qualified_construction.astra` (EXPECT 1/2/3 —
  homónimos `A.Some2`/`B.Some2` sin colisión) y
  `ui/enum_bare_construction_rejected.astra` (EXPECT-ERROR: use
  Enum.Variant to construct 'Some2'); calificados los 12 conformance +
  5 codegen + 5 fixtures LLVM + 2 unit zig + el generador. Gates:
  `make test` 265/0, `sweep_emit_c` fail=0, `zig build test` verde,
  `ui_message_parity` first_fail=0, `dump_parity` 0 divergent,
  `llvm_parity` fail=0, `llvm_fuzz` fail=0.
- **Spec**: `research/027` §4.

### DEC-012 — Enforcement entre fibras: Opción F (pospuesto)
- **Estado**: Propuesta — D7 pospuesto el 2026-10-27; Fase 0 completada
  (la regla vive en `ARCHITECTURE.md` §2.6); mientras sea `Propuesta`, la
  regla 5 de AGENTS bloquea backend work que tenga que codificarla.
- **Fecha**: 2026-10-27
- **Decisión (dirección)**: compartir intra-fibra es gratis (DEC-001);
  **cruzar frontera de fibra exige valor único en ese punto** — estático si
  se prueba, walk de `rc` en runtime si no; si no es único → `.copy()` o
  `AtomicRef[T]`. `transfer(x)` será un **builtin** (estilo `print`), no
  keyword. El walk RT1 se difiere al primer feature con cruce real
  (scheduler/send) — sin rc en los VMs antes de tiempo.
- **Alternativas consideradas**: A tracing GC (contradice «sin pausas»);
  B RC atómico aceptando carreras (contradice «thread-safe»); D owner-check
  por acceso (queda como red de v2, no como base); E sin mutable compartido
  (pierde el pitch).
- **Coste aceptado**: Fase 0 = docs (ARCHITECTURE §2.6 «pendiente»);
  implementación futura = S1/S2/S3 en 2 frontends + `.copy()` en 4 runtimes.
- **Evidencia**: `research/026` §3–§4 (spec operativa R1–R7); `research/031`
  §0 (NEEDS WORK: estimación de esfuerzo pendiente antes del PR grande).
- **Spec**: «pendiente de escribir en ARCHITECTURE §2.6».

### DEC-013 — Stdlib M1: `len(x)` y `s[i]` (índice de string)

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR1 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**:
  - `len(x) -> i64` para **arrays** (número de elementos) y **strings**
    (número de bytes). Registrado como builtin con parámetro `unknown` — igual
    que `print` —, así que cualquier receptor pasa el typechecker y el guard
    de runtime (`cannot take length of <tipo>`, el texto que ya usaba
    `OPCODE_LEN`) es la superficie de paridad entre las 4 rutas.
  - `s[i]` sobre un string devuelve un **string de 1 byte** (byte, no
    codepoint: el lexer del seed es byte-oriented). El typechecker lo acepta
    como lectura; el índice sigue teniendo que ser entero. **Fuera de rango =
    error de runtime con el mismo texto que los arrays**
    (`index N out of bounds (len M)`); receptor nil → `cannot index nil`.
  - Los strings son **inmutables**: `s[i] = …` es error de compilación
    (`cannot assign to string element`) — se rechaza en el typechecker, no en
    runtime, para que ninguna ruta lo ejecute.
  - `i32` y floats siguen rechazados con el mensaje actual
    (`cannot index non-array type …`, `ui/index_non_array.astra` intacto).
- **Alternativas consideradas**: código numérico (Go) en vez de 1-byte-string
  (habría roto `match c { "(" => …, _ => … }` y `==` por contenido, que ya
  funcionan en 4 rutas, y no existe char literal); `char_at(s, i)` como builtin
  (gastaba el plumbing completo de un builtin sin reutilizar `OPCODE_INDEX`);
  restringir `len` a `string|array` en compile-time (`research/028` §1.3 lo
  recomienda) — pospuesto: exige un caso `ui/` con primera línea byte-idéntica
  y el guard de runtime ya existe en las 4 rutas; discriminador `builtin_id` en
  `FnObj` — descartado por ahora: identidad de puntero por marcador (un FnObj
  por builtin) deja `astra.h` intacta.
- **Coste aceptado**: 4 implementaciones (seed VM, backend C, zig VM,
  LLVM+runtime) en 7 ficheros de código; 8 tests; los JIT/wasm/aarch64 heredan
  el runtime LLVM sin código propio.
- **Evidencia**: fijado por `arrays/len_array.astra` (3/1),
  `expressions/len_string.astra` (5/0 — incluye `len("")` → 0),
  `expressions/str_index.astra` (lectura + concat + `==`),
  `expressions/str_index_oob.astra` (`index 5 out of bounds (len 5)`),
  `expressions/len_int_runtime_error.astra` (`cannot take length of int`),
  `ui/str_index_assign_rejected.astra` (primera línea byte-idéntica seed↔zig),
  `codegen/str_index.astra` y `codegen/len_builtin.astra` (redondeo C). Gates
  del PR: `make test` 276/0, `sweep_emit_c` total=122 fail=0, `make debug`
  (ASan/UBSan/LSan) 276/0, `make release` 276/0, `zig build test` verde,
  `ui_message_parity` first_fail=0, `dump_parity` 0 divergent,
  `llvm_parity` 170/170 (opt=0 y opt=2), `llvm_jit` 170/170,
  `llvm_fuzz -n 20 -s 1` fail=0, `--check-constructs` OK.
- **Spec**: `research/028` §1.2 (firmas M1) y §3 (PR1) — «pendiente de
  escribir en ARCHITECTURE».

### DEC-014 — Stdlib M1: `to_string(x)` y `read_file(path)`

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR2 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**:
  - `to_string(x) -> string` convierte **solo enteros**. El parámetro se
    registra como `unknown` — igual que `print`/`len` — porque el checker no
    puede expresar «cualquier entero» sin romper el default `i32` de DEC-006;
    el rechazo es de **runtime** y con texto idéntico en las 4 rutas
    (`to_string expects an int, got <tipo>`, con el `type_name` del VM). Los
    floats quedan **fuera del MVP** a propósito: el formato decimal de float
    es otra decisión (DEC-010 solo fija cómo imprime `print`), y lo que el
    lexer necesita es numerar líneas/columnas (`research/028` §1 MVP #4).
  - La conversión usa **la misma conversión que `print`** en cada ruta —
    `%ld`/`(long)` en seed y backend C, `{d}` en zig, `%lld`/`(long long)` en
    LLVM (ésta además es correcta en wasm32/ILP32, donde `long` mide 32
    bits), de modo que `print(to_string(n))` es byte-idéntico a `print(n)`.
  - `read_file(path: string) -> string`: parámetro **anotado string**, así
    que `read_file(42)` es error de compilación en ambos checkers; un valor
    nil bajo anotación string (`let s: string` sin inicializar) se rechaza en
    runtime con `expected string path, got nil`.
  - **Todo fallo de apertura/lectura colapsa en un único runtime error**
    `cannot open file '<path>'` (la frase del driver del seed sin el prefijo
    `error:`, porque los errores de runtime ya llevan `file:line: runtime
    error:`), para que las 4 rutas sean byte-idénticas — incluye leer un
    directorio en Linux (`fopen` abre y `fread` falla) y los errores de WASI.
  - **Colocación de la lectura positiva**: no vive en `conformance/`
    (`research/028` §2.4: los gates corren con cwd distinto — `seed/`,
    `zig/`, raíz del repo — y la ruta wasm no tiene `preopens`); vive en
    `seed/tests/selfhost/` (fixture `fixture_read.txt` + golden
    `read.expected` + `io_gate.sh` con `cd` fijo, §4.3). `conformance/` solo
    lleva los casos negativos, con un path inventado que no existe en
    ningún cwd.
- **Alternativas consideradas**: `to_string` polimórfico (i64|f64|str|bool)
  — pospuesto junto al formato de float; parámetro `i64` anotado para
  rechazar floats en compile-time — rompe DEC-006 (un literal sin anotar es
  i32 y ya no calzaría con el parámetro); `read_file` con `Option`/`Result`
  (`ARCHITECTURE.md:1617` especula `read_file(path)?`) — Astra-0 no tiene
  `FileError` y el `?` puede añadirse después sin tocar este texto; errores
  distintos por causa (not-found/permission/is-a-directory) — añade
  divergencia entre runtimes (WASI no distingue igual) sin aportarle al
  lexer; leer el tamaño con `fseek`/`ftell` — descartado: el tamaño no es
  fiable en todos los destinos (procfs, wasm), se lee por bloques en las 4
  rutas.
- **Coste aceptado**: 4 implementaciones (seed VM, backend C, zig VM,
  LLVM+runtime) en 8 ficheros de código; 6 tests + un gate propio de cwd
  fijo; JIT/wasm/aarch64 heredan el runtime LLVM (la ruta wasm necesita
  `preopens` en `demo/wasi_run.mjs`, añadido en este PR).
- **Evidencia**: fijado por `expressions/to_string_roundtrip.astra`
  (42/-7/0/`true`/9007199254740993/`n=42`),
  `expressions/to_string_float_rejected.astra`
  (`to_string expects an int, got float`),
  `expressions/read_file_missing.astra` (`cannot open file '…'`),
  `expressions/read_file_nil_path.astra` (`expected string path, got nil`),
  `codegen/to_string.astra` y `codegen/read_file_missing.astra` (redondeo C),
  y `seed/tests/selfhost/io_gate.sh` → 4 rutas ok (seed VM, `--emit-c`+gcc,
  zig VM, LLVM `--jit`) contra `read.expected`. Gates del PR: `make test`
  286/0, `sweep_emit_c` total=126 skip=3 fail=0, `make debug`
  (ASan/UBSan/LSan) 286/0, `make release` 286/0, `zig build test` verde,
  `ui_message_parity` first_fail=0 (total=125), `dump_parity` 0 divergent
  (164 files), `llvm_parity` 176/176 (opt=0 y opt=2), `llvm_jit` 176/176,
  `llvm_sanitize` 176/176 + LSan limpio, `llvm_cross` 176/176 (aarch64),
  `llvm_filecheck` 8/8, `llvm_fuzz -n 20 -s 1` fail=0, `--check-constructs`
  OK, `io_gate` 4/4; la ruta wasm no corrió localmente (sin `wasm-ld`: la
  hace CI, `preopens` ya en `demo/wasi_run.mjs`).
- **Spec**: `research/028` §1 (firmas M1) y §3 (PR2) — «pendiente de
  escribir en ARCHITECTURE».

### DEC-015 — Nombres de builtin reservados (anti-shadowing)

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR2 (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: `print`, `len`, `to_string` y `read_file` **no pueden
  redeclararse** — ni como `let`, ni como `const`, ni como `fn` — **en
  ningún ámbito** (módulo incluido). El error es
  `'<nombre>' is a builtin and cannot be redeclared`, byte-idéntico en los
  dos typecheckers.
  - Motivo: el VM resuelve los builtins por **nombre** en `GET_GLOBAL` y el
    emisor LLVM decide la llamada por **nombre** en `emitCall` *antes* de
    mirar tablas de fns/locales; un binding llamado `len` se ejecutaría como
    slot en unas rutas y como builtin en otras. El bug observable ya
    existía a nivel de módulo: `let len = 5` imprimía `<fn>` en el VM semilla
    y `5` en el backend C.
  - Un `fn print()` de nivel superior se reporta en la **primera pasada y
    antes** del chequeo de `duplicate function` (que habría nombrado la
    regla equivocada: el símbolo builtin parecía un segundo `print`), y
    exactamente una vez — el cuerpo se sigue comprobando en la pasada 2 sin
    registrar el símbolo.
- **Alternativas consideradas**: rechazar solo en nivel de módulo — dejaba
  el hueco local abierto para LLVM; permitir el shadowing y resolver
  identidades en el emisor LLVM — coste alto (tablas de bindings en
  `emitCall`) y rompe «los builtins son globales»; reutilizar el mensaje
  «duplicate function» — menciona la regla equivocada.
- **Coste aceptado**: 2 typecheckers × 3 puntos de anclaje (var, const, fn),
  ningún runtime. **Fuera de alcance y conocido**: los *enlaces* de `for` y
  los patrones de `match` no se chequean (`for len in … { print(len) }` hoy
  funciona y es inocuo en las 4 rutas); sombrear un binder **invocable**
  divergiría entre slot (VM/C/zig) y nombre (LLVM) — se cubrirá si algún
  binder futuro lo permite declarar.
- **Evidencia**: `ui/builtin_shadow_print.astra` (fn, pasada 1),
  `ui/builtin_shadow_len.astra` (let de módulo),
  `ui/builtin_shadow_to_string.astra` (const) y
  `ui/builtin_shadow_read_file.astra` (let local: el ámbito cualquiera) —
  los 4 con **una sola** diagnóstica y la primera línea byte-idéntica
  seed↔zig.
- **Spec**: «pendiente de escribir en ARCHITECTURE».

### DEC-016 — Lexer de Astra-0 como gate de self-hosting

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR3a (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: `seed/tests/selfhost/lexer.astra` — un lexer mini **escrito
  en Astra-0** — es el primer componente self-hosting de la cadena de
  bootstrap (`research/028` §4.2/§5: el lexer es E/S + cómputo puro sobre
  bytes, no toca ABI). Usa solo los builtins M1 de DEC-013/DEC-014 (`len`,
  `s[i]` → 1 byte, `to_string` solo enteros, `read_file`) más lo que
  Astra-0 ya tenía (`==`/`+` de string, `match` con literales + or-patterns
  + `_`, `while`/`continue`, structs). Su salida es **un token por línea**
  con el formato fijado en el propio fichero (comentario de cabecera):
  - `<KIND>:<lexeme>@<line>` con `KIND ∈ KEYWORD | IDENT | INT | STRING |
    SYMBOL | OP | ERROR`; la última línea de toda ejecución es
    `EOF@<line>`; en `ERROR` el hueco del lexeme es un mensaje
    (`ERROR:unknown char '$'@41`, `ERROR:unterminated string@<n>`).
  - Cobertura de tokens: los **36 keywords** de `seed/src/lexer.c`
    (tabla `keyword_kind`), identificadores con `_` y dígitos, enteros
    decimal y hex (`0x…`), strings con escapes copiados verbatim
    (`\\ \" \n` y bytes UTF-8 alto pasan tal cual), comentarios `//` (sin
    emitir), operadores de 1 y 2 chars (`== != <= >= && || -> :: => ..`) y
    puntuación `( ) { } [ ] + - * / = ; , . : | ! < > ?`.
  - **Ubicación**: `seed/tests/selfhost/`, junto a `io_gate.sh` y **nunca**
    en `conformance/` (DEC-014, `research/028` §2.4: los gates corren con
    cwd distinto — `seed/`, `zig/`, raíz — y la ruta wasm no tiene
    `preopens`; un caso con `read_file` ahí fallaría por el camino de
    ejecución, no por el lenguaje). El gate `lexer_gate.sh` fija el cwd con
    `cd "$here"` y compara **byte a byte** contra el golden commiteado
    `lexer.expected` en las **4 rutas** (seed VM, `--emit-c`+gcc, zig VM,
    LLVM `--jit`); el fixture `lexer_input.astra` es un Astra-0 no trivial
    (struct, enum, match, closures, `for..in` con rango, escapes, hex) con
    **un carácter inválido `$` a propósito** para que el golden fije también
    el camino de error — solo se lexea, nunca se compila.
- **Alternativas consideradas**: (1) usar `lexer.astra` como su propio
  fixture — descartado: cada edición del lexer regenera un golden gigante
  (los 52 or-patterns de `is_alpha` ocupan solos decenas de tokens) y se
  pierde el valor de regresión; (2) gate «fuerte» contra
  `astra-seed --dump-tokens` en el mismo PR (`research/028` §4.3) —
  **pospuesto a PR3b**: los formatos difieren (el C imprime
  `<línea>:<col>  <KIND>  <lexeme>`, **incluye tokens NEWLINE** que este
  lexer se salta, y da a cada operador su propio KIND mientras aquí se
  agrupan en `SYMBOL:`/`OP:`), así que la normalización necesita su propio
  diseño (resuelto en PR3b: DEC-017); (3) el formato `"<KIND> <lexeme> @<line>"` de `research/028`
  §4.2 — se eligió `<KIND>:<lexeme>@<line>` (separador `:` como en la
  propia lista de ejemplos del informe, con `@line` conservado).
- **Coste aceptado**: 0 cambios de código de compilador (ni seed ni zig);
  4 ficheros nuevos en `seed/tests/selfhost/`. Lexemas por concat `+`
  (O(n²)) y `is_alpha` con 52 or-patterns literales en una sola línea (el
  parser no continúa un patrón de match a través de NEWLINE): sin `substr`
  ni `ord` (M2, PR4) — con esos builtins el lexer se acorta sin tocar el
  gate. `let mut i: i64` es obligatorio: `len` devuelve `i64` y comparar
  anchos distintos en `i < n` es error de compilación (DEC-006).
- **Evidencia**: `seed/tests/selfhost/lexer_gate.sh` → **4/4 rutas ok**
  (seed VM, C backend `--emit-c`+gcc, zig VM, LLVM `--jit`) contra
  `lexer.expected` (179 líneas; sha256
  `f3e66f929e8084d6ea2a74562030e0b0836728fd4310b51b1118f919dbe71498`);
  `io_gate.sh` sigue 4/4 y `make test` 286/0 (este PR no añade casos de
  conformance — el lexer vive fuera por decisión propia).
- **Spec**: «pendiente de escribir en ARCHITECTURE» (`research/028` §4.2/§4.3
  es la spec de facto: formato de salida, cobertura y ubicación del gate).

### DEC-017 — Cierre del gate del lexer self-hosting (PR3b de DEC-016)

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR3b (2026-10-27)
- **Fecha**: 2026-10-27
- **Decisión**: tres piezas, todas en `tests/` y CI — **0 cambios de
  compilador** (ni seed ni zig):
  1. **Rutas nuevas de `lexer_gate.sh`** (4 → 7): además de seed VM,
     `--emit-c`+gcc, zig VM y LLVM `--jit`, la ruta nativa de producción
     `--emit-obj` + enlace del runtime TU (receta `llvm_parity.sh`), la ruta
     cross aarch64 (`--emit-obj --target` + `aarch64-linux-gnu-gcc` + qemu)
     y la ruta wasm32-wasi (`--emit-obj --target` + `wasm-ld` + wasi-libc +
     Node WASI vía `demo/wasi_run.mjs`, que desde PR2 lleva
     `preopens {"/": cwd}` — `read_file` funciona en wasm). Cada ruta nueva
     tiene **skip limpio** (no fallo) si falta su toolchain o si el zig no
     está construido con `-Dllvm`.
  2. **Gate fuerte** `lexer_tokens_parity.sh`: la salida de `lexer.astra` y
     la de `astra-seed --dump-tokens lexer_input.astra` se **normalizan**
     (awk embebido) a `line KIND value` y se comparan con diff — 176 tokens
     en el fixture commiteado. KINDs que mapean 1:1: KEYWORD (el dump
     imprime el keyword como su propio kind), IDENT (`_` del dump ≡
     `IDENT _`: `lexer.astra` no tiene token UNDERSCORE), INT (el dump
     imprime el valor parseado — `0x2A` ≡ `42`; el normalizador convierte
     hex→decimal), PUNCT (`SYMBOL:`/`OP:` ≡ los kinds por-operador del
     dump), ERROR (KIND+línea; el dump no imprime el mensaje) y EOF.
     **Fuera del gate** (parcial honesto, con la razón en la cabecera del
     script): NEWLINE (el lexer los salta, DEC-016), columnas (lexer.astra
     solo trackea línea), contenido de STRING (el dump imprime el valor
     procesado con escapes resueltos — crudo y multi-línea si contiene
     `\n` —, el lexer el lexema verbatim: re-producir los escapes testaría
     el normalizador, no el lexer; el contenido queda pinneado byte a byte
     por `lexer.expected`), FLOAT_LIT (lexer.astra no lexea floats: si
     aparece uno en el fixture el normalizador **falla ruidosamente** con
     UNMAPPED, no lo esconde) y los tokens tras el primer ERROR
     (`run_dump_tokens` para en `TOKEN_ERROR` mientras `lexer.astra`
     recupera y sigue: el gate compara el prefijo común hasta e incluyendo
     el primer ERROR; la cola de recuperación la pinnea el golden).
     `lexer_gate.sh` lo invoca al final, así que una sola ejecución cubre
     golden + rutas + paridad de stream.
  3. **CI** (`.github/workflows/ci.yml`): paso «Self-hosting gates (seed VM
     + C backend)» en el job `seed` — corre `io_gate.sh` y `lexer_gate.sh`
     con el mismo guard `if: needs.changes.outputs.code == 'true'` que el
     resto de pasos del job (sin zig ahí, las rutas zig/LLVM skipean y el
     gate fuerte corre contra el seed) — y paso «Self-hosting gates (zig VM
     + LLVM routes)» en el job `llvm` (único job con `-Dllvm`; construye el
     seed con `make -C seed` porque las rutas canónicas y el gate fuerte
     necesitan `astra-seed`): ahí corren zig VM, `--jit` y
     `--emit-obj`+link; cross/wasm skipean por toolchain (cablearlos en los
     jobs `llvm-cross`/`llvm-wasm` es un paso cada uno, dejado pendiente).
     **Ningún job renombrado**: los checks requeridos por los rulesets no
     cambian.
- **Alternativas consideradas**: (1) meter el gate fuerte como paso extra
  dentro de `lexer_gate.sh` en vez de script propio — se hizo lo mejor de
  los dos: script propio (invocable y testeable independiente) **invocado**
  por `lexer_gate.sh` al final; (2) cablear las rutas cross/wasm en CI ya —
  el mínimo viable acordado era `seed` + `llvm`; ambas rutas quedan
  verificadas localmente (7/7) y anotadas en el script y en el paso de CI
  para los jobs `llvm-cross`/`llvm-wasm`; (3) comparar también el contenido
  de STRING re-procesando escapes en el normalizador — descartado por
  frágil (el parseo multi-línea del dump es ambiguo en general) y porque
  testaría el normalizador, no el lexer.
- **Coste aceptado**: 0 cambios de compilador; 1 fichero nuevo
  (`seed/tests/selfhost/lexer_tokens_parity.sh`), ~150 líneas añadidas a
  `lexer_gate.sh` y ~30 a `ci.yml`. El gate fuerte compara el stream de
  `lexer.astra` contra el seed; si el zig está construido exige además que
  su `--dump-tokens` sea byte-idéntico al del seed en este fixture
  (`dump_parity.sh` no cubre `selfhost/`), y las demás rutas ya exigen
  byte-parity con `lexer.expected` — así el gate cubre ambos frontends.
- **Evidencia**: `seed/tests/selfhost/lexer_gate.sh` → **7/7 rutas ok**
  (seed VM, C backend `--emit-c`+gcc, zig VM, LLVM `--jit`,
  LLVM `--emit-obj`+link, LLVM cross aarch64+qemu, LLVM wasm32-wasi+Node
  WASI) + `lexer_tokens_parity.sh` → `ok (176 tokens …)`; `io_gate.sh` →
  4/4; `make test` 286/0; `llvm_parity.sh` 176/176 skip=0.

### DEC-018 — Stdlib M2a: `ord(s)` y `substr(s, start, len)`

- **Estado**: Aceptada (test-pinned) — fijada en el PR D-PR4a (2026-10-28)
- **Fecha**: 2026-10-28
- **Decisión**:
  - `ord(s) -> i64` devuelve el valor del **primer byte** de `s` (0..255) —
    **byte, no codepoint**: `s[i]` ya devuelve un string de 1 byte (DEC-013) y
    el lexer del seed recorre `char` sin UTF-8 (`research/028` §1.1), así que
    las cuatro rutas y un `lexer.astra` futuro leen el mismo número. Un string
    vacío **no tiene primer byte**: `ord("")` es error de runtime
    `ord() of empty string` — nunca lee pasando el buffer, porque `""` es
    `{NULL, 0}` en el VM y decide la longitud, no el puntero. Receptor
    no-string → `ord expects a string, got <tipo>` con el `type_name` del VM.
  - `substr(s, start, len) -> string` devuelve `len` bytes desde `start`.
    **Fuera de rango es error, nunca recorte**: `start < 0 || start > len(s)`
    → `substr start N out of bounds (len M)`; `len < 0 || start + len > len(s)`
    → `substr length N out of bounds (len M)` (con prefijo `substr`, no el
    `index … out of bounds` de los arrays: ese texto no dice de dónde sale).
    `len == 0` con `start == len(s)` devuelve `""` — el llamante no pidió
    nada —, mientras `start > len(s)` falla incluso con `len == 0`. El chequeo
    compara contra `len(s) - start`, así que un `len` enorme (p. ej.
    `9223372036854775807`) falla en vez de desbordar `start + len`.
  - **Tipos: los tres parámetros de `substr` (y el de `ord`) son `unknown`
    con guards de runtime** — el patrón de `print`/`len`/`to_string`
    (DEC-013/DEC-014). Motivo: la llamada compara argumentos con `type_eq`
    **exacto** y Astra-0 no tiene coerción, así que un parámetro anotado `i64`
    rechazaría `substr(s, 1, 3)` (literal `i32` por DEC-006) y uno anotado
    `i32` rechazaría `substr(s, 0, len(s))` (`len` devuelve `i64`); con
    `unknown` ambos calzan sin coerción. Cada runtime rechaza con el mismo
    texto: `substr expects a string, got <tipo>` y `substr expects an int, got
    <tipo>` — los dos argumentos enteros comparten la frase, igual que los dos
    guards del emisor LLVM.
  - **Los 4 sitios a la vez** (`research/028` §2.2): seed (`typechecker.c`
    símbolos, `vm.c` cuerpo + `GET_GLOBAL` + dispatch + marcadores `FnObj`,
    `priv.h`, `codegen.c` `cg_builtins[]`, `codegen_runtime.h`), zig
    (`typechecker.zig`, `vm.zig`) y LLVM (`emitter.zig` `emitOrd`/`emitSubstr`
    + `astra_runtime_llvm.c`); JIT, wasm y aarch64 heredan el runtime LLVM sin
    código propio.
  - **`ord` y `substr` se suman a la lista reservada de DEC-015** (`kBuiltins`
    en los dos typecheckers): el VM resuelve builtins por **nombre** en
    `GET_GLOBAL` y el emisor LLVM decide la llamada por **nombre** en
    `emitCall`, así que un binding homónimo divergiría entre rutas. Mensaje
    idéntico: `'ord' is a builtin and cannot be redeclared` /
    `'substr' is a builtin and cannot be redeclared`.
- **Alternativas consideradas**: (1) anotar el receptor `s: string` (como
  `read_file`, DEC-014) para rechazar `substr(42, …)` en compile-time —
  descartado: dejaría `ord` y `substr` con reglas distintas (`ord` seguiría
  siendo runtime por DEC-006) y añadiría un mensaje de compilación que mantener
  byte-idéntico en dos checkers, sin una seguridad que el runtime no dé;
  (2) **recortar** (clipping) cuando `start + len > len(s)` en vez de fallar —
  descartado: el error es *más barato* de verificar en las 4 rutas (una
  comparación contra el hueco restante, sin segunda rama) y es el mismo
  contrato que `s[i]` (DEC-013), que ya falla en vez de devolver menos;
  (3) tercer parámetro llamado `end` (la firma de `research/028` §1.2) — se
  eligió `len`, porque el valor es una **longitud**, no un índice final:
  `substr(s, 0, n)` toma `n` bytes; (4) parámetros anotados `string, i64, i64`
  — imposible sin coerción (arriba); (5) codepoint UTF-8 en `ord` — descartado:
  `s[i]` ya es byte y el lexer C es byte-oriented, un codepoint rompería la
  equivalencia con `lexer.astra`; (6) reutilizar el texto de bounds de los
  arrays (`index N out of bounds (len M)`) — descartado: no nombra el builtin
  que falla.
- **Coste aceptado**: 4 implementaciones en 9 ficheros de código (seed:
  `typechecker.c`, `vm.c`, `priv.h`, `codegen.c`, `codegen_runtime.h`; zig:
  `typechecker.zig`, `vm.zig`, `llvm/emitter.zig`,
  `llvm/runtime/astra_runtime_llvm.c`); 10 tests (6 conformance, 2 codegen,
  2 ui); 0 cambios de bytecode ni de AST, así que los dumps siguen
  byte-idénticos (172 ficheros = los 164 previos + los 8 nuevos que ya
  gatean).
- **Evidencia**: fijado por `expressions/ord_basic.astra` (65/97/48/10/
  `true`), `expressions/ord_empty_error.astra` (`ord() of empty string`),
  `expressions/ord_int_arg.astra` (`ord expects a string, got int`),
  `expressions/substr_basic.astra` (`ell`, tres `true` — entre ellos
  `substr(s, 0, len(s)) == s` y `substr(s, 5, 0) == ""` — y `e`),
  `expressions/substr_bounds_error.astra`
  (`substr length 99 out of bounds (len 5)`),
  `expressions/substr_start_error.astra`
  (`substr start 6 out of bounds (len 5)`), `codegen/ord_substr.astra` y
  `codegen/substr_oob.astra` (redondeo C; este último `substr start -1 out of
  bounds (len 5)`), `ui/builtin_shadow_ord.astra` y
  `ui/builtin_shadow_substr.astra` (primera línea byte-idéntica seed↔zig).
  Gates del PR: `make test` **296/0**, `sweep_emit_c` total=**132** skip=3
  fail=0, `make debug` (ASan/UBSan/LSan) **296/0**, `zig build test` verde,
  `ui_message_parity` first_fail=0 (total=127), `dump_parity` 0 divergent
  (172 files), `llvm_parity` **184/184** skip=0 fail=0 (opt=0 y opt=2),
  `llvm_fuzz -n 20 -s 1` fail=0, `lexer_gate.sh` **7/7 rutas** + paridad de
  tokens (176), `--check-constructs` OK.
- **Spec**: `research/028` §1.2 (firmas M2) — «pendiente de escribir en
  ARCHITECTURE».
