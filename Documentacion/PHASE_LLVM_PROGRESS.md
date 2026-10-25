# Astra — LLVM backend status (Fase LLVM)

Estado del **backend nativo LLVM** de Astra (`zig/src/llvm/`), la *Fase LLVM*
del plan (`LLVM_BACKEND_PLAN.md`). Emite LLVM IR desde el AST tipado del
compilador Zig (Fase 2) y compila a binario nativo, sin pasar por bytecode ni
por la VM.

> **Opt-in estricto** (plan §4.1): sin `-Dllvm` el build y el binario de Zig
> son byte-idénticos y **ningún gate existente cambia**. El backend se
> construye, prueba y despliega por su cuenta (job `llvm` de CI).

```
.astra ─▶ lexer/parser/typechecker (zig, ya portados) ─▶ AST tipado
                                                         │
           ┌─────────────────────────────────────────────┤
           ▼                    ▼                        ▼
   Ruta VM (zig)        Ruta C (--emit-c, seed)    Ruta LLVM (nueva)
   gate de referencia   referencia semántica        emitter.zig → LLVM C API
                                                           │ LLVMVerifyModule
                                                           ├── --emit-llvm      → .ll
                                                           ├── llc -filetype=obj → .o
                                                           └── link + runtime    → binario
```

---

## 1. Estado actual (2026-10-23, M0–M6.b cerrados)

**M0 (infraestructura), M1 (núcleo completo), M2 (valores y patrones), M3
(paridad total y robustez), M4 (calidad), M5 (targets), M6.a (LLJIT) y
M6.b (fast-math) están terminados: pipeline `-O2`, benchmarks, DWARF,
sanitizers ASan, cross aarch64, wasm32-wasi, ejecución in-process y flags
fast-math opt-in.** El emisor compila
Astra-0 —
escalares, floats, strings, Option/Result con `match`/`?`, closures,
arrays/structs/enums de usuario, `for..in`/`break`/`continue`, genéricos
monomorfizados, traits/impls, `let` sin inicializador y retornos sin anotar —
a LLVM IR verificado y lo baja a objeto con `--emit-obj`
(TargetMachineEmitToFile, M2.e — sin subproceso `llc`). En las cuatro
rutas — nativa, cross aarch64 (`--target=<triple>`, §13), wasm32-wasi
(§13.4) y `--jit` in-process (§14) — la salida (stdout, stderr y código
de salida) es **byte-idéntica a la VM** para **todos** los casos del gate
correspondiente: **155 — 155 ok, 0 skip, 0 excl, 0 fail** en cada ruta,
planas y con `ASTRA_LLVM_OPT=2` (la suite creció de 154 a 155 con el
fixture de fast-math de M6.b, §15).

| Hito | Contenido | Estado |
|:-----|:----------|:-------|
| **M0.1** | flag `-Dllvm` + descubrimiento de `llvm-config` (rango 19..23) | ✅ |
| **M0.2** | binding `llvm-c` (`src/llvm/c_api.zig`) + smoke test verify/print | ✅ |
| **M0.3** | emisor mínimo (`src/llvm/emitter.zig`) + CLI `--emit-llvm` | ✅ |
| **M0.4** | runner `zig/tests/llvm_parity.sh` + job CI `llvm` (apt.llvm.org 19) | ✅ |
| **M0.5** | `PHASE_LLVM_PROGRESS.md` + AGENTS.md (build `-Dllvm`, `-lc`) | ✅ |
| **M1** | floats, strings, Option/Result + `?` + `match`, closures | ✅ |
| **M2** | arrays/structs (GEP), enums de usuario + `match`, `for..in`, `--emit-obj` | ✅ |
| **M3** | paridad total, guard de profundidad, atributos/pesos, fuzz, FileCheck | ✅ |
| **M4** | calidad: pipeline `-O2` + benchmarks + DWARF + sanitizers ASan | ✅ |
| **M5** | `--target=<triple>` (cross aarch64) + `src/llvm/target.zig` + ruta wasm32-wasi formalizada (§13) | ✅ |
| **M6.a** | `--jit`: ejecución in-process vía ORC/LLJIT (§14) | ✅ |
| **M6.b** | `--fast-math`: flags fast-math opt-in en la aritmética FP (§15) | ✅ |

Queda, todo opcional y sin bloquear el cierre de la fase (plan §6): el
des-boxing de Option/Result y error-union para `?`.
La compatibilidad con LLVM 22 (churn que señaló el canario) quedó
corregida y verificada — §14.5.

---

## 2. Cómo construir y verificar

Requiere **Zig 0.16.x** (`~/zig/zig`) y **LLVM 19..23** descubierto vía
`llvm-config` (en este entorno, `llvm-config-19` = 19.1.7).

```bash
cd zig
export PATH="$HOME/zig:$PATH"
zig build -Dllvm                        # -> zig-out/bin/astra-zig (con emit-llvm)

# Ruta LLVM de un programa
./zig-out/bin/astra-zig --emit-llvm file.astra          # escribe file.ll
./zig-out/bin/astra-zig --emit-llvm-stdout file.astra   # imprime el IR (tests)

# Bajo nivel (fuera de proceso)
/usr/lib/llvm-19/bin/llc -relocation-model=pic -filetype=obj file.ll -o file.o
cc -c -O2 -std=c11 -I../seed/src src/llvm/runtime/astra_runtime_llvm.c -o runtime.o
cc file.o runtime.o -o program -lm && ./program

# Gate de paridad (VM <-> ruta LLVM) y forma del IR
./tests/llvm_parity.sh
./tests/llvm_filecheck.sh

# El mismo gate con el optimizador (M4): no puede cambiar la semántica.
ASTRA_LLVM_OPT=2 ./tests/llvm_parity.sh

# Ruta wasm32-wasi (§13.4): emitir -> wasm-ld + wasi-libc -> Node WASI.
# Requiere wasm-ld (lld), un sysroot wasi-libc con <setjmp.h> usable
# (el de Ubuntu no lo trae; ver §13.4) y Node >= 22.
./tests/llvm_wasm.sh
ASTRA_LLVM_OPT=2 ./tests/llvm_wasm.sh

# Fuzz diferencial de cuatro rutas (seed VM / --emit-c / zig VM / LLVM)
./tests/llvm_fuzz.sh -n 40 -s 1

# Benchmarks (VM / backend C / LLVM), con y sin pipeline
./tests/llvm_bench.sh -n 3 -O 0
./tests/llvm_bench.sh -n 3 -O 2
```

Sin `-Dllvm`, `--emit-llvm`/`--emit-llvm-stdout` terminan con un error
accionable (exit 2); la ejecución normal y los dumps no se ven afectados.

---

## 3. Decisiones de diseño (y por qué)

1. **Modelo de valores M0: escalares sin boxing** (plan §1.4/023 §4). Todos los
   tipos enteros de Astra se representan como `i64` y `bool` como `i8` 0/1. El
   *boxing* se difiere a M1: sin él el emisor es drásticamente más simple y los
   casos M0 (enteros, bool, control de flujo) ya logran paridad byte-a-byte.
2. **`+ - *` con wrap plano** (sin `nsw`/`nuw`). Es la semántica fijada por el
   backend C y la VM (audit §4.2): añadir banderas UB rompería la paridad y
   violaría la política de "cero flags UB en v1" (024 §3/§4). Los guards de
   `div`/`mod`/shift/`INT64_MIN÷-1` se emiten **inline** y delegan en
   `astra_llvm_fail`, que reimprime `file:line: runtime error: msg` vía el
   runtime compartido del seed (`codegen_runtime.h`) — no hay un tercer formato
   de error.
3. **Runtime = TU delgada sobre `codegen_runtime.h`**
   (`src/llvm/runtime/astra_runtime_llvm.c`). Ese header *define* sus globales,
   así que solo puede incluirlo **exactamente un** TU por programa enlazado. El
   emisor solo referencia los `astra_llvm_*` exportados (set_file, fail, print).
4. **El emisor camina el AST tipado directamente** (tras el type checker), sin
   bajar a bytecode ni tocar la VM. Es un emitter paralelo al de bytecode
   (`src/emitter/`), no una modificación de aquel.
5. **Triple y datalayout desde el host** (`LLVMGetDefaultTargetTriple` +
   `LLVMCreateTargetData("")`, plan 024 §2): el binario nativo se construye para
   la máquina que compila.
6. **Un solo sink de diagnósticos**: los rechazos " fuera de M0" del emisor
   pasan por `src/diagnostics.zig` con el mismo formato `file:line:col: error:`
   que el resto de fases. Un constructo no soportado sale limpio (exit 1) sin
   escribir IR.
7. **CLI**: `--emit-llvm` (`.ll` junto al input) y `--emit-llvm-stdout` (para
   tests). Ambos exigen `-Dllvm`; sobre un programa **multi-módulo** se rechazan
   limpio (exit 2) — el emisor es de fichero único. `--single-file` fuerza la
   semántica del seed (imports parseados y descartados), que es lo que usan
   los fixtures de `module/` y el runner de paridad.

---

## 4. Alcance del emisor M0

### Soportado (con paridad verificada por `llvm_parity.sh`)

- Literales **int** y **bool**; identificadores y variables (`let`/`const`,
  globales y locales), asignación a variable.
- Aritmética / bitwise / comparación sobre enteros (`+ - * % << >> & | ^`),
  con los guards de runtime; negación unaria `-`, `!` lógico.
- `&&` y `||` con *short-circuit* (bloques + `phi`).
- `if` (sentencia y expresión con valor), `while`.
- Funciones con parámetros/retorno escalares, llamada directa, recursión,
  retorno implícito (expresión final del cuerpo), expresiones-bloque.
- `print` de escalares (`i64`, `bool`).

### Rechazado (mensaje `not supported by the LLVM backend (M0): …`)

- Funciones genéricas; parámetros/retorno no escalares (strings, floats,
  arrays, structs, enums).
- `for..in`, `match`, `break`/`continue`.
- Lambdas y valores-función.
- Cualquier valor no escalar: **strings, floats, arrays, structs, enums,
  Option/Result, `?`**.
- Programas **multi-módulo**.

### Gate de paridad (`zig/tests/llvm_parity.sh`)

Barrido diferencial sobre la suite de conformidad (no-UI) + `zig/tests/llvm/`.
Cada caso se compara contra la VM zig (referencia) en stdout, stderr y código
de salida, tras `--emit-llvm → llc -relocation-model=pic → link runtime →
ejecutar`. Los constructos fuera de M0 se **saltan** (el emisor los rechaza), de
modo que a medida que M1+ amplíen el subconjunto los casos pasan de *skip* a
*ok* automáticamente.

Cierre de M0: **93 casos — 14 ok, 78 skip, 1 excl, 0 fail**. El estado vigente
(al cierre de M1) es **41 ok, 51 skip, 1 excl, 0 fail** — ver §5.

---

## 5. M1 — núcleo completo (2026-10-17)

M1 añade los cuatro bloques que faltaban para que el subconjunto *sin* heap
de usuario (arrays/structs/enums) sea completo. Cada subhito fue un commit
con todos los gates verdes.

| Subhito | Commit | Contenido |
|:--------|:-------|:----------|
| **M1.a** | `7cb76fd` | floats `f64`: aritmética, `%` = `fmod`, guards (div/mod por cero = error, no IEEE) |
| **M1.b** | `b4ab832` | strings: literales con longitud explícita (NULs ok), print, `+` concat, `==` por contenido, ordenación = error |
| **M1.c** | `f8de722` | Option/Result: `some`/`none`/`ok`/`err`, `match` (variantes builtin + literales + guards + or-patterns), `?` |
| **M1.d** | `eb64a95` | closures: lambdas de primer orden, captura por valor, env que sobrevive al frame |

### Decisiones de diseño de M1

1. **`boxed_` (Option/Result)**: puntero a `{ i32 tag; i32 ptype; i64 payload }`
   con `none` = **NULL** (el VM tipa `none` como nil e imprime `nil`). El tag
   sigue la numeración de `TAG_IS` (0=ok 1=err 2=some) y el `ptype`
   (bool/i64/f64/str/boxed) dice al runtime cómo leer el payload **cuando el
   typechecker ya no distingue** ok/err de some/none (aliasing Tier-2). Sólo
   print/igualdad/ordenación pasan por el runtime (`astra_llvm_print_boxed`,
   `_boxed_eq`, `_boxed_order_fail`); tag checks y cargas de payload son IR
   inline. Los nombres dinámicos de `cannot compare some and some` salen de
   los tags en runtime, como `OPCODE_LT` del VM.
2. **`?` sin setjmp/longjmp**: el typechecker exige que la función devuelva un
   opcional, así que `err`/`none` propaga con un `ret` local de la propia
   caja — mismo efecto que el frame-pop del `TRY_UNWRAP` del VM (el caller ve
   la caja como resultado de la llamada). `ok`/`some` → payload con su tipo
   estático.
3. **`match`**: réplica de la bajada del seed — test de patrón (TAG_IS inline
   con guard anti-NULL; literales vía la misma máquina que `==`; or-patterns)
   → bindings en el scope del brazo (payload cargado con el tipo estático del
   objetivo) → guard con fallthrough (el binding se reclama al salir, audit
   §4.3) → phi de brazos como expresión; backstop `no match arm matched`
   (`OPCODE_MATCH_NONE`) cuando no hay brazo total. Los enums de usuario
   (`pattern_variant_bind`) quedan para M2.
4. **Closures con convención uniforme**: toda función Astra compila como
   `(ptr env, args...) -> ret`; las nombradas ignoran el env (llamados
   directos pasan NULL) y las lambdas leen sus capturas de ahí, así que un
   objeto heap `{ ptr code; ptr env }` sirve para lambdas **y** para
   funciones nombradas usadas como valor, y la llamada dinámica `f(x)` arma
   su firma en el sitio. El env es un array de slots i64 (`toBits`)
   malloc'd en el **sitio de creación**: snapshot por valor que sobrevive al
   frame (audit §7.11). El análisis de variables libres replica
   `collect_free_vars` del seed; las `fn` anidadas no capturan. **Gotcha**:
   el cuerpo de la lambda se compila con los scopes/captures del frame
   enclosing guardados aparte — resolver nombres libres contra allocas ajenos
   produce IR inválido (`Referring to an instruction in another function`).
5. **Anotaciones `T?` y `fn(T, ...) -> T`** en params/retorno/lets; `payload_ty`
   rastreado en `Val`/`Local`/`GlobalInfo`/`FnInfo` (para `boxed_` es el `T`
   del payload; para `fn_` el tipo de retorno).

### Alcance M1 (soportado con paridad)

Todo lo de M0, más: floats completos; strings completos; Option/Result con
constructores, `match` builtin/literal/or/guards, `?` en funciones; lambdas
`|x: i32| -> i32 { … }` como valores (args, locals/globales `let mut`,
asignación, anidadas, captura por valor); funciones nombradas como valores.

Sigue rechazado (M2): arrays, structs, enums de usuario, `for..in`,
traits/impls, genéricos, `break`/`continue`, multi-módulo, y `print`/`==` de
valores-función (el runtime no tiene representación).

Gate de paridad al cierre: **93 casos — 41 ok, 51 skip, 1 excl, 0 fail**.
Los flips de M1: floats (`float_*`), strings (`string_*`), Option/Result
(`option_*`, `result_*`, `try_operator`, `match_*`, `none_literal`,
`optional_syntax`, `or_patterns`, `nested_option_result`) y closures
(`lambda/basic`, `lambda/multi`, `lambda/closures` — el caso completo con env
que sobrevive al frame). Verificado además a mano contra el VM: `some(1) <
some(2)` → `cannot compare some and some` idéntico, `if some(0)` → true, y
los cinco patrones de `closures.astra` byte a byte.

---

## 6. M2 — valores y patrones (2026-10-17)

M2.a–M2.e cerrados: arrays homogéneos, structs con layout, enums de usuario
con `match` de variantes, `for..in` (rangos y arrays) + `break`/`continue`, y
`--emit-obj` vía TargetMachineEmitToFile. La ruta LLVM cubre ahora la suite
completa de `seed/tests/codegen/` además de la conformance (gate M2, plan
§6): **121 casos — 103 ok, 16 skip (M3), 2 excl, 0 fail** (los dos casos
nuevos de la contra-investigación post-M2 flipearon a ok).

### Decisiones de diseño de M2

| Qué | Decisión |
|:----|:---------|
| **Array** (M2.a) | objeto `{ i64 len; i32 elem_pty; i32 pad; <elems@16> }` (ARR_HDR=16, PTY_ARRAY=6); identidad compartida entre aliases; bounds check → `astra_llvm_index_fail`; literales ≥1025 elems → trap de stack overflow. `==` **estructural por elemento** con el ptype del objeto: la rama identidad del switch de `vm.c` es código muerto — `value_eq` compara elemento a elemento —, así que `astra_llvm_array_eq` recursa por ptype y lo comparten boxed/structs/enums/elems (fix latente descubierto por `aggregate_equality`, que antes ni compilaba). |
| **Struct** (M2.b) | objeto `{ ptr layout_def; f0@8; f1@16; … }` — todos los campos en slots de 8 bytes en orden de declaración; descriptor estático `AstraLLVMStructDef { name, nfields, ptypes, fields }` (PTY_STRUCT=7); `sname` propagado en `Val`/`Annot`/`Local`/`GlobalInfo`/`CapSlot`/`FnInfo` para resolver campos; print `astra_llvm_print_struct`, eq estructural `astra_llvm_struct_eq`. |
| **Enum** (M2.c) | objeto `{ const AstraLLVMEnumDef *def; i32 variant; i32 kind; <payload@16> }` con `AstraLLVMEnumDef { name, nvariants, variants[] }` y `AstraLLVMVariantDef { name, npayload, ptypes }`; el `kind` replica los dos kinds del VM — kind 0 (VAL_ENUM: acceso unit, acceso pelón de variante con payload y constantes de patrón; eq SÓLO por nombres, igual que el cross-kind de `value_eq`) y kind 1 (VAL_ENUM_DATA: construcción `Variant(x)`, eq estructural con payloads por ptype). Las constantes kind-0 se emiten con los slots de payload a cero del tamaño de la variante (un match con bindings sobre kind-0 lee 0, no OOB). Registro en pasada previa: nombres de struct → enums completos → layouts de struct. Payload literal de builtin (`some(1)`) testado en tag_bb (camino no-NULL). |
| **for..in** (M2.d) | réplica de NODE_FOR: almacen oculto de índice + límite/arr, condición al frente (`i < end`, `<=` en `..=`, `i < len(arr)` con el len del objeto en offset 0), la variable del loop se tipa con el **tipo de elemento** del array (`Val.payload_ty`), incremento como objetivo de `continue`; pila de contextos de loop (break→salida, continue→incremento en `for` y condición en `while`). |
| **Objeto** (M2.e) | `--emit-obj` escribe `<file>.o` con LLVMTargetMachineEmitToFile (CodeGenLevelDefault + **RelocPIC** — el PIC que el enlazador default-PIE exige); el init del target nativo sale del static inline de `llvm-c/Target.h` que translate-c sí traduce (`llvm-config.h` lo expande). `llvm_parity.sh` ya no subprocesa `llc` (sólo `${CC:-cc}` para enlazar el runtime). |

Límites conocidos (unsupported honestos): el elemento de un array pierde el
`sname` de struct (acceso a campo sobre `xs[0]` y `for p in structs`), y una
lambda con retorno struct pierde el `sname` del tipo — ambos documentados en
el emisor.

### Alcance M2 (soportado con paridad)

Todo lo de M0/M1, más: arrays (literal, lectura/escritura con bounds check,
`==` estructural, iteración, anidados, campos-array de struct/enum); structs
(literal, campo lectura/escritura, eq estructural, print, structs en payloads
de match); enums de usuario (acceso, construcción, `match` con
bindings/guards/or-patterns/brazos-bloque, eq cross-kind, print de ambos
kinds, anotaciones `x: Color`, enums dentro de boxes/arrays/structs);
`for..in` sobre rangos y arrays de cualquier tipo soportado; `break`/`continue`
en `for` y `while`. El límite de 256 globales de la VM se espeja en runtime
(`too many global variables` en la línea del declarante, como el SET_GLOBAL
del VM en orden de fuente).

Gate de paridad al cierre: **121 casos — 103 ok, 16 skip, 2 excl, 0 fail**.
Los flips de M2: `arrays/*`, `structs/*`, `enums/*` (12; `mixed_patterns`
esperó a `for..in`), `loops/*` + `control/while_*` (8, incluidos
`iter_height_norm` y `loop_residue_inline`), `aggregate_equality`,
`match_inline_call`, `pub_decls`, `toplevel_aggregates`, `forward_type_refs`,
`integer_widths`, `deep_recursion`, `element_assign`, y la suite
`codegen/*` (20 ok, 1 auto-skip). Verificado a mano contra el VM además de
por el runner: eq cross-kind de enums (`Shape.Circle == Circle(2.5)` → true),
constructores y prints de ambos kinds, y los 13 ficheros de loops/enums
pendientes.

---

## 7. M3 — paridad total y robustez (2026-10-20)

Los 16 skips y los 2 `excl` de M2 se cerraron en nueve pasos, cada uno con
su commit y los gates verdes (detalle de commits en §9):

| # | Contenido |
|:-:|:----------|
| M3.a | Retornos sin anotar (inferidos de los `return` + cola, como la VM) y `let` sin inicializador para tipos respaldados por puntero (`nil`). |
| M3.b | Traits e `impl`: los métodos se declaran y emiten como globales manglados y `trait_decl` es inerte. |
| M3.c | Genéricos: monomorfización en el typechecker (instancias con tipos concretos, AST anotado) y un descriptor por instancia en LLVM con el nombre fuente para que `print` coincida. |
| M3.d | Guard de profundidad: `astra_llvm_depth` global, comprobación `>= 256` antes de cada llamada de usuario (nombrada/método/dinámica) con el mismo mensaje y línea que la VM; los 2 `excl` pasan a ok. |
| M3.e | `nounwind` en los helpers del runtime, `cold noreturn` en los de fallo y pesos de rama fría (`1 : 1048576`) en el edge de error de todos los traps. |
| M3.f | FileCheck: 4 fixtures `zig/tests/llvm/check_*.astra` (guards, match, profundidad, `?`) fijan la FORMA del IR; `llvm_filecheck.sh` localiza `FileCheck` o `FileCheck-19..23`. |
| M3.g | Fuzz diferencial de cuatro rutas (`llvm_fuzz_gen.py` + `llvm_fuzz.sh`): 480 programas (12 semillas × 40) con stdout/stderr/exit idénticos. Encontró y motivó dos fixes reales del seed (strings vacíos en concat/eq y la línea del error en `--emit-c`). |
| M3.h | `--single-file` (semántica del seed: `import`/`from`/`use` inertes) y los 3 fixtures de `module/` en el gate; el emisor LLVM deja de rechazar declaraciones de módulo. |
| M3.i | Canario CI no bloqueante con el LLVM stable más reciente (`llvm-canario`, `continue-on-error`). |

**Gate final de M3: `llvm_parity.sh` 131 casos — 131 ok, 0 skip, 0 excl, 0 fail
(132 desde el fixture `check_debug` de M4.c).**
El resto de gates: `zig build test` 73/73 (84/84 con `-Dllvm`), dump_parity
132/0, suite seed 245/245, `sweep_emit_c` 0 fail, `ui_message_parity`
`accept_fail=0 first_fail=0`, `llvm_filecheck` 4/4 y fuzz 480/480.

### Fuera del alcance del backend LLVM v1 (se rechaza limpio, exit 2)

- **Programas multi-módulo reales** (loader, mangling entre módulos, orden de
  dependencias): el emisor es de fichero único. `--single-file` reproduce la
  semántica del seed para los fixtures que declaran imports inertes.
- `@cImport`/translate-c: no implementado en v1.

### Diferido a M4 / M5

| Qué | Hito |
|:----|:-----|
| UBSan (`ubsan` no existe como pasada del new PM en LLVM 19..23) | cuando lo publique LLVM |
| Remarks del pipeline (medir las adiciones de `-O2`) | M4 (opcional) |
| Multi-target / cross-compilation (`-mtriple`) | M5 |

El runner de paridad **no excluye ningún caso**: el guard de profundidad se
reproduce con el contador interno y los fixtures de módulo corren con
`--single-file` en ambas rutas.

---

## 8. M4 — calidad (cerrado 2026-10-21)

### M4.a — Benchmarks (cerrado)

`zig/tests/bench/` (recursión, bucle entero con guards div/módulo, `match`
de enum con payload, arrays + structs) y `zig/tests/llvm_bench.sh`, que pasa
cada programa por la VM zig, el backend C del seed y la ruta LLVM, compara
stdout byte a byte (gate de correctitud) y publica el mínimo de N
repeticiones. En esta máquina (AMD Ryzen 3 3250C, 4 hilos, 3 repeticiones,
ms):

| bench | vm | llvm build | llvm -O0 | c build | c run | llvm/vm |
|:------|---:|-----------:|---------:|--------:|------:|--------:|
| arrays | 12374 | 163 | 20 | 651 | 301 | 619x |
| fib | 1022 | 149 | 11 | 427 | 33 | 93x |
| loop | 7506 | 165 | 18 | 407 | 194 | 417x |
| match | 11695 | 166 | 172 | 920 | 700 | 68x |

El backend C también interpreta (bytecode traducido a un switch en C), así
que el nativo le gana por 10–17x; la VM paga el intérprete y la arena.

### M4.b — Pipeline de optimización (cerrado)

`--opt-level=N` (0..3, default 0) corre el pipeline del new PM con
`LLVMRunPasses` antes de verificar y emitir: 1 = `default<O1>`, 2 =
`default<O2>` + LICM (adaptador `loop-mssa`), `simple-loop-unswitch` (el
nombre del unswitch en LLVM 19) e IRCE — las adiciones que pide el plan —,
3 = `default<O3>`. El nivel 0 deja el módulo intacto: el IR que fijan los
FileCheck y el binario por defecto no cambian.

El optimizador **no puede cambiar la semántica observable**: `llvm_parity.sh`
acepta `ASTRA_LLVM_OPT` y CI corre el gate dos veces, sin pipeline y con
`-O2`; **154/154 en ambos**. Números O0 → O2 (mismos fixtures, mínimos):

| bench | llvm -O0 | llvm -O2 |
|:------|---------:|---------:|
| arrays | 20 | 10 |
| loop | 18 | 16 |
| match | 172 | 121 |
| fib | 11 | 13 |

`match` y `arrays` mejoran porque el pipeline quita los checks redundantes
y hoistea; `fib` está dominado por llamadas (el boxeo de `AstraValue` es el
techo conocido, 023 §1.2) y la diferencia es ruido.

### M4.c — DWARF (cerrado 2026-10-21)

Metadatos DWARF (`llvm-c/DebugInfo.h`, `src/llvm/debug.zig`, Kaleidoscope ch. 9)
opt-in con `--debug-info`:

- `DICompileUnit` + `DIFile` por módulo.
- `DISubprogram` por función (`emitFn`), método de `impl`, lambda (`emitLambda`) y
  el `astra_module_main`.
- `DILocation` por cada nodo/sentencia/expresión emitida (`setLoc`), fijada en el
  IRBuilder con `LLVMSetCurrentDebugLocation2`. `@main` sintético se emite sin location.
- **Verificación**:
  - Test unitario: `test "emite DWARF con enableDebugInfo..."` en `src/llvm/emitter.zig` (85/85 tests ok).
  - FileCheck: `zig/tests/llvm/check_debug.astra` (`llvm_filecheck.sh`, 5/5 ok).
  - Depuración con `lldb-19` (`zig/tests/llvm_dwarf_test.sh`): breakpoints en líneas
    exactas de Astra (funciones, métodos y lambdas), preview de código fuente con
    cursor de columna y backtrace limpio a través de marcos.
  - Paridad: `llvm_parity.sh` total **132 ok / 0 fail** tanto a `-O0` como a `-O2`.

### M4.d — Sanitizers sobre los artefactos (cerrado 2026-10-21)

`--sanitize=address` instrumenta el módulo con la pasada `asan` del new PM
(`instrumentSanitizer` en `src/llvm.zig`) **antes** del pipeline de
optimización, como hace clang: el emisor sólo marca las funciones
(`sanitize_address` en nombradas, métodos de `impl`, lambdas,
`astra_module_main` y `main`) y la pasada inserta los checks de shadow memory
más el `asan.module_ctor`.

- El flag exige un modo de salida LLVM (con la VM no hay artefacto que
  instrumentar: exit 2). **`--sanitize=undefined` no se acepta**: LLVM 19..23
  no registra `ubsan` en el new PM (`opt-19 --print-passes` no la lista), así
  que prometerlo daría un error de pasada en todo build del rango soportado;
  el atributo `sanitize_undefined` queda para cuando LLVM la publique.
- El objeto referencia `__asan_*`: enlazarlo sin `-fsanitize=address` falla, y
  el gate lo exige (un flag ignorado en silencio no pasaría).
- Gate `zig/tests/llvm_sanitize.sh`: IR y `.o` instrumentados; enlace plano
  fallido por símbolos `__asan_*`; control negativo (heap-buffer-overflow
  aborta con reporte de ASan); la suite completa vía
  `ASTRA_LLVM_SAN=address` — **154/154 a -O0 y a -O2**, con el runtime
  compilado también con ASan; y un paso final de LSan (§12, M4.e) sobre
  `tests/llvm/leaks.astra`. `llvm_parity.sh` acepta `ASTRA_LLVM_SAN=<tipo>`
  (flag + runtime + enlace) para no duplicar el runner.
- LSan (`detect_leaks`) va apagado **en el barrido de paridad**: ese gate
  incluye programas que terminan por un error fatal, cuyo camino de salida no
  es un test de ownership. Las fugas se miden en el paso dedicado de
  `llvm_sanitize.sh` (M4.e): `detect_leaks=1` sobre `tests/llvm/leaks.astra`
  debe terminar con cero fugas.

Tests: `src/llvm.zig` («instrumentSanitizer inserta checks de ASan») y
`src/llvm/emitter.zig` («emite atributos de sanitize_address»); `zig build test
-Dllvm` **88/88**.

---

## 9. Bug pre-existente conocido (cerrado en la contra-investigación)

El operador **`||` (`or_or`)** fallaba en runtime con
`cannot call non-function value` en **ambas** VMs (seed y zig) cuando su
resultado alimentaba un call (`print(a || b)`) — `&&` funcionaba, y en
condición de `if` ambos pasaban por residuo que nadie leía. La
contra-investigación post-M2 (2026-10-20) lo localizó con exactitud: en
**ambos emitters** el primer `CONST` objetivo de rama de un short-circuit
caía al segundo sin `JUMP` intermedio (doble push → el `CALL` leía el slot
equivocado), y **`&&` con izquierda falsa fallaba igual** — la afirmación
original de que `&&` funcionaba estaba enmascarada. La ruta LLVM lo
computaba bien (phi) y sirvió de referencia.

✅ fix `395c588` — `JUMP` al final tras el primer CONST de rama en
`OP_AND`/`OP_OR` de ambos emitters; el C backend hereda el bytecode
corregido. Tests gemelos `expressions/short_circuit_call_arg.astra` +
`codegen/` cubren las formas (call-args con ambas polaridades, let-init,
if-condición) y flipearon los dos casos nuevos del gate de paridad a ok.
Complemento `5e61b48`: el dump AST del seed imprimía `BinaryOp(and/or)`
(los keywords muertos, audit §A3) donde zig imprime `&&`/`||`; corregido
en el seed, dump_parity 126/0.

---

## 10. Commits

### M0

| # | Commit | Mensaje |
|:-:|:-------|:--------|
| M0.1 | `c2c62d1` | `build(llvm): flag -Dllvm y descubrimiento de LLVM vía llvm-config` |
| M0.2 | `52a4710` | `feat(llvm): binding llvm-c y módulo smoke verify/print (M0.2)` |
| M0.3 | `96f66c4` | `feat(llvm): emisor mínimo y CLI --emit-llvm` |
| M0.4 | `2ee1e47` | `test(llvm): runner llvm_parity + job CI llvm (apt.llvm.org 19)` |
| M0.5 | `8538b75` | `docs(llvm): PHASE_LLVM_PROGRESS.md + AGENTS.md (build -Dllvm, -lc)` |

Gates verdes en cada commit de M0: suite seed **237/237** + `--check-constructs`
OK, `zig build test` **73/73** (sin flag) / **76/76** (con `-Dllvm`), paridad de
dumps **124/0**, `sweep_emit_c` **0 fail**, `ui_message_parity`
`accept_fail=0 first_fail=0`, y `llvm_parity.sh` **0 fail**.

### M1

| # | Commit | Mensaje |
|:-:|:-------|:--------|
| M1.a | `7cb76fd` | `feat(llvm): floats f64 en el emisor (M1.a)` |
| M1.b | `b4ab832` | `feat(llvm): strings — literales, print, concat e igualdad (M1.b)` |
| M1.c | `f8de722` | `feat(llvm): Option/Result, match y ? en el emisor (M1.c)` |
| M1.d | `eb64a95` | `feat(llvm): closures — lambdas de primer orden con captura por valor (M1.d)` |
| M1.doc | _(este commit)_ | `docs(llvm): PHASE_LLVM_PROGRESS.md — cierre de M1` |

Los mismos gates, verdes en cada commit de M1, con `zig build test -Dllvm`
creciendo de 76 a **79** (tests de emisión de match/`?`/closures) y
`llvm_parity.sh` de 14 a **41 ok, 0 fail**.

### M2

| # | Commit | Mensaje |
|:-:|:-------|:--------|
| M2.a | `a79c495` | `feat(llvm): arrays homogéneos con bounds check (M2.a)` |
| M2.b | `74f086b` | `feat(llvm): structs con layout, print y igualdad estructural (M2.b)` |
| M2.c | `8b79b26` | `feat(llvm): enums de usuario + match con payloads (M2.c)` |
| M2.d | `1914658` | `feat(llvm): for..in con rangos y arrays + break/continue (M2.d)` |
| M2.e | `6f54cd9` | `feat(llvm): --emit-obj vía TargetMachine y paridad con la suite codegen (M2.e)` |
| M2.doc | _(este commit)_ | `docs(llvm): PHASE_LLVM_PROGRESS.md — cierre de M2` |

Los mismos gates, verdes en cada commit de M2, con `zig build test -Dllvm`
creciendo de 79 a **84** (tests de arrays/structs/enums/loops/emit-obj) y
`llvm_parity.sh` de 41 a **101 ok, 0 fail** (119 casos: conformance + suite
`seed/tests/codegen/`).

### Contra-investigación post-M2 (2026-10-20)

| # | Commit | Mensaje |
|:-:|:-------|:--------|
| C1 | `5e61b48` | `fix(seed): dump AST de \`&&\`/\`\|\|\` usa los símbolos, no las keywords muertas` |
| C2 | `395c588` | `fix(compiler): \`&&\`/\`\|\|\` en call-args empujaban dos veces su resultado` |

Hallazgos de la contra-investigación (verificación de docs contra código,
repros en `/tmp/opencode/`, cifras del gate re-ejecutado):

- El gate estaba exactamente donde la doc decía (119 — 101/16/2/0) y los 14
  hashes de commits citados existen con su mensaje.
- El bug de §8 era real **y más ancho de lo documentado**: `&&` con izquierda
  falsa fallaba igual (doble push del short-circuit en ambos emitters, C
  incluido) — cerrado en C2, con el dump-name fix de C1 que el test nuevo
  desenmascaró (`BinaryOp(and/or)` vs `BinaryOp(&&/||)`).
- Gate al cierre: **121 casos — 103 ok, 16 skip, 2 excl, 0 fail**; dump_parity
  126/0; suite seed 239/239; `zig build test` 73/73; `sweep_emit_c` 0 fail;
  `ui_message_parity` 0 fail.
- Documentación corregida en el mismo pase: erratas del plan (§9
  "traits/traits"), el canario CI descrito pero aún no implementado, AGENTS.md
  en estado post-M2, CHANGELOG con la fase, PHASE2_PROGRESS con el puntero.

### M3

| # | Commit | Mensaje |
|:-:|:-------|:--------|
| M3.a | `2fd85d1` | `feat(llvm): retornos sin anotar y \`let\` sin inicializador nil (M3.a)` |
| M3.b | `8c070db` | `feat(llvm): dispatch de métodos y bloques impl (M3.b)` |
| M3.c | `bc4b3cb` | `feat(llvm): monomorfización de genéricos (M3.c)` |
| M3.d | `c4913be` | `feat(llvm): guard de profundidad de llamada (M3.d)` |
| M3.e | `4283487` | `feat(llvm): atributos de helpers y pesos de rama fría (M3.e)` |
| M3.f | `b35f601` | `test(llvm): FileCheck de shapes críticos del IR (M3.f)` |
| fix | `bf2d2af` | `fix(seed): strings vacíos en concat y eq (UB + divergencia con zig)` |
| fix | `7a49169` | `fix(seed): línea del error de runtime dentro de una rama (--emit-c)` |
| M3.g | `18558da` | `test(llvm): fuzz diferencial de cuatro rutas (M3.g)` |
| M3.h | `661b7cd` | `feat(llvm): fichero único explícito y fixtures de módulo en paridad (M3.h)` |
| M3.i | `a6a9672` | `ci(llvm): canario no bloqueante con LLVM latest (M3.i)` |
| M3.doc | _(este commit)_ | `docs(llvm): cierre de M3 — paridad total, fuzz y FileCheck` |

### M4

| # | Commit | Mensaje |
|:-:|:-------|:--------|
| M4.a | `cd0ad33` | `test(llvm): suite de benchmarks VM/C/LLVM (M4.a)` |
| M4.b | `8a0aad9` | `feat(llvm): pipeline de optimización --opt-level y gate a -O2 (M4.b)` |
| M4.doc | `3f9e704` | `docs(llvm): M4.a/M4.b — benchmarks y pipeline -O2` |
| M4.c | `43b0837` | `feat(llvm): emisión de DWARF con --debug-info y verificación lldb (M4.c)` |
| M4.cdoc | `d004711` | `docs(llvm): M4.c — soporte DWARF y depuración por línea Astra` |
| M4.d | `50ec20b` | `feat(llvm): instrumentación ASan con --sanitize=address (M4.d)` |
| M4.d test | `7cd6f6a` | `test(llvm): gate de sanitizers sobre los artefactos (M4.d)` |
| M4.d doc | _(este commit)_ | `docs(llvm): M4.d — sanitizers sobre los artefactos` |

Gates en cada commit de M4: `zig build test` 73/73 (88/88 con `-Dllvm`),
dump_parity 144/0, suite seed 257/257, `sweep_emit_c` 0 fail,
`ui_message_parity` 0 fail, `llvm_filecheck` 5/5, `llvm_dwarf_test.sh` OK,
`llvm_sanitize.sh` OK y `llvm_parity.sh` **145 casos — 145 ok, 0 skip, 0 excl,
0 fail** tanto a `-O0` como a `-O2`, también bajo ASan (`ASTRA_LLVM_SAN=address`).
Fuzz diferencial de 4 rutas `llvm_fuzz.sh` limpio (0 fail).

---

## 11. Auditoría post-M4 y correcciones (2026-10-21)

Revisión completa de `zig/src/llvm/` (emisor, runtime C, DWARF, fachada y
CLI) y de los scripts del gate, con repros ejecutados contra la VM zig, la VM
del seed y `--emit-c`. **Todos los fallos confirmados eran exclusivos de la
ruta LLVM**: la VM y el backend C ya daban la salida o el diagnóstico
correctos.

### 11.1 Fallos corregidos

| # | Tipo | Síntoma (antes) | Causa | Fix |
|:-:|:-----|:----------------|:------|:----|
| A1 | Memoria | `==` de arrays de `bool` leía fuera del heap (ASan: `heap-buffer-overflow`, 5 bytes tras una región de 19) y podía dar un resultado arbitrario | `astra_llvm_array_eq` avanzaba con stride 8 fijo, pero los bool ocupan 1 byte (`arr_slot`/`elemSlotSize`) | `f356e18`: mismo stride que print |
| A2 | Memoria | SEGV con `let s: string` / `let p: P` / `let a: [i32]` / `let f: fn(...)`: print, `==`, `match` con literal, `+`, `for..in`, lectura/escritura de campo, método con nil, llamada dinámica, y nil dentro de Option/array/payload | runtime desreferenciaba NULL; el emisor no comprobaba nil en field access, `for` ni llamada indirecta | `f356e18` + `2ecdcc3`: print/eq/concat nil-safe y guards en el emisor con los mensajes exactos del VM |
| A3 | Correctitud | `print(f())` con `f` imprimiendo daba `1\n 2` (espacio de más) | `print_begin` se emitía antes de evaluar el argumento; el print interno dejaba el separador armado | `2ecdcc3`: evaluar el argumento primero |
| A4 | Correctitud | Campo/payload de tipo `fn` se imprimía como `true` y se comparaba como bool (`PTY_BOOL` de fallback) | `boxPTy(.fn_)` era `null` y el layout caía a `PTY_BOOL` | `f356e18`/`2ecdcc3`: `PTY_FN` (9), print `<fn>` e igualdad por identidad; `print(f)` y `f == g` también soportados |
| B1 | Correctitud | `print` de array/enum nil daba `[]`/`?`; struct nil y payload string nil daban SEGV | el runtime no contemplaba nil en esos cuerpos | `f356e18`: `nil` en string/array/struct/enum y en elementos/payloads |
| B2 | Diagnóstico | `s < "x"` con `s` nil decía `cannot compare string and string` | mensaje constante por tipo | `f356e18`/`2ecdcc3`: `astra_llvm_str_order_fail` nombra los operandos (`nil and string`) |

Commits: `f356e18` (runtime), `2ecdcc3` (emisor), `b9fa176` (tests).

### 11.2 Cobertura nueva

Doce casos de conformidad (se ejecutan en la VM seed, la VM zig y la ruta
LLVM) más `zig/tests/llvm/fn_values.astra` (sólo LLVM: el C del seed imprime
`fn`): `arrays/bool_equality`, `types/nil_string`, `types/nil_aggregates`,
`types/nil_string_concat{,_right,_both}`, `types/nil_fn_call`,
`types/string_order_nil`, `structs/nil_field{,_assign}`, `loops/for_nil`,
`expressions/nested_print` y `llvm/fn_values`. El gate pasó de 132 a **145
casos** (145/145 a `-O0`, `-O2` y bajo ASan); suite seed **257/257** y
dump_parity **144/0**.### 11.3 Limitaciones que siguen (documentadas, no silenciosas)

- ~~**Sin ownership (fugas)**~~: **cerrado en M4.e (§12)** — el runtime ya
  libera todo lo que el programa no conserva; el repro de 100 concatenaciones
  que dejaba 51.400 bytes termina ahora con LSan limpio.
- **Metadatos derivados de un elemento**: `a[0][1]` y llamar `a[0](x)` sobre
un array de funciones se rechazan con diagnóstico limpio porque `Val` no
conserva el tipo interno del elemento. Caps que la VM no tiene: >64 campos
de struct, >64 variantes, >32 brazos de match y >15 params (la VM acepta un
struct de 65 campos; LLVM lo rechaza).
- **UBSan** no se ofrece: LLVM 19..23 no registra la pasada `ubsan` en el new
PM. La verificación de UB se limita a ASan y a la seguridad del build Zig debug.
- El generador del fuzz diferencial no produce nil ni arrays de `bool`, así
que estas regresiones viven en la suite de conformidad (que el gate barre) y
no en el fuzz.

## 12. M4.e — Ownership y fugas (cerrado 2026-10-21)

M4.d cerró la seguridad de memoria con `detect_leaks=0`; el modelo de
**liberación** llega aquí, como **refcount v1** en `astra_runtime_llvm.c` +
`emitter.zig`. El objetivo era eliminar la fuga medida en §11.3 (100
concatenaciones de 10 bytes → 51.400 bytes retenidos) sin tocar el modelo de
valores de la VM (arrays/structs con identidad compartida) y sin cambiar ni
un byte de la salida observable — el gate de paridad es la prueba.

### 12.1 Cabecera de refcount

Todo objeto con heap lleva **8 bytes antes del puntero** que el IR manipula:

```c
typedef struct { int32_t rc; int32_t kind; } AstraLLVMHdr;  // kind: 1=str 2=box
                                                             // 3=arr 4=struct 5=enum
                                                             // 6=fn 7=env
```

Como el header vive *delante* del payload, **los layouts no se mueven**: `len`
sigue en el offset 0 del array, `def` en el 0 del struct/enum, tag/ptype en la
caja. Todos los GEP en línea del emisor y todas las lecturas del runtime
(imprimir/igualdad) siguen igual; sólo cambia `astra_llvm_alloc` (calloc +
header) y los dos helpers `retain`/`release`.

Los objetos **estáticos** (literales de string, constantes kind-0 de enum)
llevan el mismo header con `rc = -1` (**inmortal**), emitido en
`emitStringLit` y en el bloque de `unit_const`. Así `release` de cualquier
puntero de valor es uniforme sin rastrear procedencia: `rc < 0` es no-op. El
valor de un literal de string pasa a ser un `GEP` constante al campo `len`
(y no al global entero), lo que además obligó a fijar la inferencia de tipo
de un global `let g = "a" + "b"` (se infería `i64` e imprimía el puntero).

### 12.2 Reglas de ownership (lo que emite el emisor)

| Sitio | Regla |
|:------|:------|
| asignación heap (`emitAlloc`, `wrap`, concat, resultado de llamada puntero) | `rc = 1` y **registro como temporal** |
| store en local/global/campo/elemento/box/env (`emitStoreOwned`) | **libera** el valor anterior y **retiene** el nuevo |
| parámetros | el callee **retiene** al entrar y libera al salir (asignar a un parámetro es seguro) |
| `return` / propagación de `?` | **retiene** el valor, libera los locales del frame y sus temporales (`emitFrameCleanup`) |
| `break` / `continue` | limpia los temporales al mark del frame antes del salto |
| fin de sentencia (`emitStmt`) | `tmp_clear(mark)`: se libera lo que no acabó almacenado |
| fin de función (cuerpo de cola) | `emitFrameRelease` + `ret` |
| `@main` | libera todos los globales y `astra_llvm_runtime_cleanup` libera el buffer |

El **destructor recursivo** (`astra_llvm_destroy`) recorre cada objeto por su
`kind` usando los mismos ptypes de print/eq: elementos de array (stride real,
bool = 1 byte), campos de struct por descriptor, payloads de enum kind-1,
payload de caja y **capturas de closure** — el objeto `{code, env}` crece a
`{code, env, cap_ptypes, ncaps}` (32 bytes) para que el destructor sepa qué
slots del env son punteros. El env no es un temporal: su dueño es el closure.

### 12.3 Verificación

| Check | Resultado |
|:------|:----------|
| `llvm_parity.sh` (154 casos, VM ↔ LLVM byte a byte) | **154/154** a `-O0` y `-O2` |
| `llvm_sanitize.sh` (suite bajo ASan + paso LSan nuevo) | OK, **sin fugas** |
| `llvm_fuzz.sh -n 40` (VM↔C↔zig↔LLVM) | 0 fail |
| Repros de mano (concat en bucle, structs con array de strings, enums con payload, closures que capturan strings, `?`, `match`, `for..in`, `break`/`continue`, globales) | idénticos a la VM y **LSan limpio** |
| `zig build test -Dllvm` | 88/88 |
| Suite seed | 258/258 |
| Presión de memoria (medida) | 10 000 vs 1 000 000 concatenaciones en un bucle: RSS pico **11,1 / 11,2 MB** — plano. Antes, por la medición de §11.3 (51.400 B por 100), ese mismo programa habría crecido ~5 MB por cada 10 000 iteraciones. |

El **gate de fugas** es `zig/tests/llvm/leaks.astra`, recogido además por el
barrido de paridad (145 → 154 casos: `leaks.astra`, los siete fixtures `ownership_*` y `types/global_string_concat.astra`): 40 iteraciones de un bucle que asigna
strings, cajas, arrays, structs, enums, closures y globales, corrido con
`--sanitize=address` + runtime con ASan y `ASAN_OPTIONS=detect_leaks=1`;
`llvm_sanitize.sh` exige exit 0, stdout idéntico a la VM y stderr sin
`LeakSanitizer`. Un store sin `retain`, un `return` sin `retain` o un
destructor que olvide un hijo hacen fallar ese paso.

### 12.4 Limitaciones del modelo v1

- **Ciclos**: un closure cuyo env alcanza al propio closure (o structs que se
  contienen mutuamente) no se colecciona — como en ARC/ORC de Rust/Swift. La
  Astra-0 no tiene punteros mutables ni referencias, así que el único camino
  conocido es un closure almacenado en un campo/elemento de un objeto que el
  closure capture.
- **Salidas por error fatal**: `astra_llvm_fail` termina el proceso con
  `exit(1)` sin recorrer el cleanup de frames; los valores vivos en ese
  instante no se liberan. Es el camino del trap (no del programa correcto), y
  por eso el barrido de paridad corre con `detect_leaks=0` y el gate de fugas
  usa un programa que termina limpio.
- La **presión de memoria** por iteración de bucle depende de que cada
  sentencia limpie sus temporales; los locales de un bucle se reutilizan (el
  store libera el anterior) y sólo conservan el último valor hasta el `return`
  del frame.

---

## 13. M5 — Targets y cross-compilation (cerrado 2026-10-22)

M5 cierra el plan (`LLVM_BACKEND_PLAN.md` §6): el backend emite para un
target **extranjero**, no sólo el host. El gate que pedía el plan —
*cross-run en CI* — está alcanzado: las **154** fixtures de paridad
compilan para `aarch64-linux-gnu`, se enlazan con el toolchain cruzado y
corren bajo `qemu-aarch64` produciendo salida idéntica, byte a byte, a la VM
nativa.

### 13.1 `--target=<triple>`

- Flag CLI `--target=<triple>` (p. ej. `aarch64-linux-gnu`), coherente con
  `--sanitize=`/`--opt-level=`. Exige un modo de salida LLVM (`--emit-llvm`,
  `--emit-llvm-stdout`, `--emit-obj`); con la VM o los dumps se rechaza
  (exit 2) en vez de aparentar que cambia el target. Sin `--target`, el
  comportamiento es exactamente el del host (los gates nativos no cambian).
- El triple se hila por toda la ruta LLVM: el emisor (`setTargetTriple`)
  fija el triple **y el datalayout del destino** en el módulo, y la fachada
  (`emitObjectFile`/`instrumentSanitizer`/`runPasses`) recibe el mismo triple
  para crear el TargetMachine. Con un datalayout del host, un objeto aarch64
  saldría malformado (tamaños/alignments de `i64`, GEPs), de ahí que el
  módulo lleve el layout del objetivo.

### 13.2 `src/llvm/target.zig` — TargetMachine compartido

Nuevo módulo `src/llvm/target.zig` con `create(diag, file, triple?)`: registra
**todos** los targets de la lib LLVM (`LLVMInitializeAllTargets` y hermanos,
`static inline` de `llvm-c/Target.h`) y resuelve el triple pedido (o el host).
Antes de M5 sólo se inicializaba el target nativo, así que
`LLVMGetTargetFromTriple` rechazaba cualquier triple no-nativo. Lo comparten
el emisor (datalayout) y la fachada (emitir/correr pasadas) para no duplicar
la lógica; no importa al emisor, así que no hay ciclo de imports.

### 13.3 Gate y verificación

- **`zig/tests/llvm_cross.sh`** (nuevo): el mismo barrido de fixtures que
  `llvm_parity.sh` pero con `--emit-obj --target=<triple>`, enlace con
  `<triple>-gcc` y corrida bajo `qemu-<arch>-static -L /usr/<triple>`,
  comparando stdout/stderr/exit contra la VM nativa. Por defecto
  `aarch64-linux-gnu`; triple/toolchain/emulador/sysroot sobreribles por env
  (`ASTRA_CROSS_TRIPLE`, `ASTRA_CROSS_CC`, `ASTRA_QEMU`, `ASTRA_QEMU_SYSROOT`).
  **154/154 ok, 0 skip, 0 fail.**
- CI: job **`llvm-cross`** (verbloqueante) instala LLVM 19 +
  `gcc-aarch64-linux-gnu` + `qemu-user-static` y corre `llvm_cross.sh` — el
  «cross-run en CI» que exige el plan.
- Tests unitarios: `target.zig` (host + aarch64 + triple inventado → null) y
  `llvm.zig` («produce un ELF aarch64 cuando `--target` lo fija», verifica
  `e_machine` = EM_AARCH64 = 183). `zig build test -Dllvm` en verde.
- Sin regresión nativa: paridad 154/154 (host), FileCheck 5/5, dump_parity
  145/0, sanitizers sin regresión — el camino host de `setTarget` es
  byte-idéntico al de antes de M5.

### 13.4 wasm32-wasi (gate formalizado 2026-10-23)

El plan lista wasm como opcional («+ wasm si se quiere»); en vez de quedar
diferido, se formaliza como ruta completa con gate y job de CI, apoyado en el
plumbing de `--target` de M5 (cualquier triple registrado en la lib LLVM):

```
.astra → --emit-obj --target=wasm32-wasi → wasm-ld (crt1.o + wasi-libc) → node WASI
```

- **Gate `zig/tests/llvm_wasm.sh`** (nuevo): espejo de `llvm_parity.sh` —
  referencia = zig VM, comparación byte a byte de stdout/stderr/exit, mismo
  criterio de skip («not supported by the LLVM backend») y honra
  `ASTRA_LLVM_OPT`. Sustituye el enlace nativo por `wasm-ld $SYSROOT/crt1.o
  <base>.o runtime.o -L$SYSROOT -lc` y la corrida por `node --no-warnings
  demo/wasi_run.mjs` (`--no-warnings` para que la nota experimental de Node
  no ensucie stderr). **154/154 ok, 0 skip, 0 fail**, sin y con
  `ASTRA_LLVM_OPT=2`.
- **Prerrequisitos**: `wasm-ld` (paquete `lld`), un sysroot WASI con
  `crt1.o`+`libc.a` **y** un `<setjmp.h>` usable (con `jmp_buf`), y **Node
  >= 22** (V8 con Exception Handling). El TU del runtime se compila con
  `clang --target=wasm32-wasi -mllvm -wasm-enable-sjlj -I<sysroot>/include/<triple>`
  — el `-I` es explícito, así que sirve cualquier clang sin depender de
  parches del driver: los wasi-libc modernos `#error`-an en `setjmp.h` sin
  EH (el flag lo satisface) porque `codegen_runtime.h` lo incluye. Ojo con
  el sysroot del SO: el paquete `wasi-libc` de Ubuntu noble **no contiene
  `setjmp.h`** (y los pre-EH no definen `jmp_buf` para wasm), así que en
  Ubuntu/CI se usa el tarball oficial `wasi-sysroot-*.tar.gz`. Knobs del
  gate: `ASTRA_WASM_LD`, `ASTRA_WASI_SYSROOT`, `ASTRA_WASM_NODE`,
  `ASTRA_WASM_CLANG`; `ASTRA_LLVM_SAN` se ignora (no hay ASan en esta
  ruta).
- **Dos bugs que el gate encontró y cerró**:
  1. *Padding del literal de enum* (`92ba823`): `match` sobre enum con
     payload leía basura — wasm32 alinea `i64` a 4 y el host a 8, y el
     literal empaquetado no respetaba el layout del value-struct. Fix:
     value-struct acolchado + `target_td`/`targetPointerBytes` con
     `setTarget()` al inicio de `emit()`, y `main` `.hidden` con alias
     `__main_void` (lo que el crt1 de wasi-libc invoca).
  2. *Impresión de i64 truncada* (`3c7f1e4`): `printf("%ld", (long)v)` es
     64-bit en LP64 pero **32-bit en wasm32** (ILP32), así que `i64` máx
     salía `-1` y `i64` min `0`. Fix: `%lld` + `(long long)` — 64 bits en
     LP64/ILP32/LLP64, salida nativa idéntica.
- **CI: job `llvm-wasm`** (tras `llvm-cross`): LLVM 19 + `clang-19` +
  `lld-19` (wasm-ld) + `wasi-sysroot-23.0.tar.gz` de la release oficial
  `wasi-sdk-23` (31 MB, pinado — el paquete de Ubuntu no sirve) + Node 24
  (setup-node), gate plano y con `ASTRA_LLVM_OPT=2`.
- **El primer run de CI encontró lo que la verificación local no podía
  ver** (`ac91a9e`): en local el `clang` de Debian añade
  `/usr/include/wasm32-wasi` por sí solo, mientras que `clang-19` de
  apt.llvm.org (vanilla) cae a los headers glibc del host y moría en
  `bits/setjmp.h` no encontrado; y el `.deb` de Ubuntu noble, examinado a
  fondo, **no contiene `setjmp.h`** — la verificación noble previa sólo
  cubría enlace y corrida, porque los headers en local los aportaba Debian,
  no noble. Corregido con `-I` explícito en el gate (cualquier clang vale)
  + sysroot wasi-sysroot en CI: **154/154** contra sdk-23 (y en -O2), y el
  sysroot de noble queda validado para enlace+corrida (`crt1` con
  `__main_void`, salida idéntica).
- Alcance: como el resto, emisor single-file (los fixtures de `module/`
  corren con `--single-file`); wasm multi-module real sigue fuera de alcance.

## 14. M6.a — LLJIT, ejecución in-process (implementado 2026-10-22)

M6 es opcional (`LLVM_BACKEND_PLAN.md` §6) y su ancla es **LLJIT (REPL/eval)**.
M6.a lo implementa: `--jit` compila el módulo emitido en el **propio proceso**
vía ORC/LLJIT y ejecuta su `main`, sin el paso `cc`+enlace de la ruta AOT. Es
el cimiento del REPL/eval futuro — misma semántica que AOT (mismo runtime C
resolviendo `astra_llvm_*`), y la paridad con la VM se reproduce byte a byte
corriendo en el compilador.

Nota sobre el «des-boxing de escalares» que 023 §1.2 lista como el premio de
M6: **ya está entregado dentro de v1**. Este backend camina el AST tipado (no
el `AstraValue` del VM), así que emite `i64`/`f64`/`i8` nativos en SSA — `+` de
enteros es `LLVMBuildAdd` con guard de overflow, no una llamada al runtime. Lo
confirma `llvm_bench.sh`: la ruta LLVM va 2-8× más rápida que el backend C
boxed y 58-338× más que la VM. El des-boxing que aún queda es el de
Option/Result (tag entero), arriesgado para la semántica y con visibilidad
mínima en los benchmarks actuales, así que no entra en M6.a.

### 14.1 Cómo funciona (`src/llvm/jit.zig`)

- `run(mod, diag, file)`: crea un LLJIT para el host (tras registrar todos los
  targets — ver §14.3), adjunta el **generador de símbolos de proceso**
  (`LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess`, `dlsym(RTLD_DEFAULT)`),
  añade el módulo al JITDylib principal, hace `LLVMOrcLLJITLookup` de `main` y
  lo llama. `main` es el C entry autocontenido que emite el backend
  (`astra_set_file` → `astra_init` → `astra_module_main` → release de globales
  → `astra_llvm_runtime_cleanup` → return 0).
- **Resolución de símbolos**: el código JITeado referencia `astra_llvm_*` (y
  las globales del runtime) + libc. El runtime se linkea al binario `astra-zig`
  bajo `-Dllvm` (`build.zig`) y se exporta con `-rdynamic`, de modo que el
  generador de proceso los encuentra. libc (malloc/printf) vive en el proceso.
- **Propiedad del módulo**: LLJIT exige que el contexto del módulo y el
  ThreadSafeContext coincidan, y el emisor usa el suyo propio. `run`
  serializa el IR y lo **re-analiza** en un contexto fresco propiedad del JIT
  (`LLVMParseIRInContext`, que consume el buffer), desacoplando el ciclo de
  vida del emisor del del JIT (sin use-after-free de contexto). El emisor
  sigue disposal su módulo con normalidad.
- **Errores de runtime**: un `?` que propague o un fallo (índice fuera de
  rango, overflow) llaman `exit(1)`/longjmp dentro del runtime — igual que la
  ruta AOT (proceso sale con 1). `--jit` es one-shot por proceso, así que no
  hay estado que reiniciar. Un `fflush(NULL)` vierte el buffer stdio antes de
  salir (el `main` JITeado devuelve 0).

### 14.2 `--jit` en el CLI (`main.zig`)

Modo `--jit` ruteado por `emitLlvm` como los demás modos LLVM, tras el
typecheck y el pipeline de optimización. Exige `-Dllvm` (sin él, mensaje
accionable). Rechaza `--sanitize` (el runtime ASan no está enlazado al
proceso) y `--target` (sólo host). Con `--opt-level=N` corre el pipeline del
new PM antes de JITear.

### 14.3 Registro de targets (`target.zig`)

`registerAll()` (extraído de `create`) llama los `LLVMInitializeAll*`
idempotentes. El camino del host por defecto del emisor **no** llama
`target.create`, así que sin esta llamada en `jit.run` el `detectHost` de
LLJIT fallaría con «no targets are registered» — bug encontrado y corregido
en M6.a.

### 14.4 Gate y verificación

- **`zig/tests/llvm_jit.sh`** (nuevo): espejo de `llvm_parity.sh` pero con
  `--jit` (sin objeto que enlazar ni `${CC}`). **154/154 ok, 0 skip, 0 fail**,
  sin y con `ASTRA_LLVM_OPT=2` — el mismo recuento que la paridad AOT, lo que
  confirma que la ruta JIT acepta el mismo subconjunto y reproduce la VM.
- Tests unitarios: `jit.zig` JITea un módulo `i64 add(i64,i64)` (create → add
  → lookup → call). `zig build test -Dllvm` en verde (91/91).
- Sin regresión: paridad AOT 154/154, FileCheck 5/5, dump_parity 145/0,
  sanitizers (ASan `-O2` + LSan) sin regresión — la ruta AOT no cambia.
- CI: el job `llvm` corre `llvm_jit.sh` sin y con `ASTRA_LLVM_OPT=2`.

### 14.5 Churn de LLVM 22 y su shim (cerrado 2026-10-23)

El canario `llvm-canario` (LLVM latest) empezó a fallar al salir LLVM 22:
**`LLVMOrcThreadSafeContextGetContext` fue eliminada de la C API de ORC**
(el contexto de un ThreadSafeContext ya no se extrae) e invirtió la
operación con `LLVMOrcCreateNewThreadSafeContextFromLLVMContext`, que
crea el TSC a partir de un contexto propio **del que toma propiedad** (no
se dispala). Era el churn exacto para el que el canario existe.

- **Alcance real del churn, auditado en seco**: contra los headers
  `llvm-c/` de la rama `release/22.x`, los 190 identificadores LLVM que
  usa el backend (`grep -o 'c\.LLVM…'` sobre `src/llvm/`) tienen **una
  sola** ausencia en 22 — ésta. No hubo que tocar emisor, targets ni
  runtime.
- **Fix** (`jit.zig`, `ba70878`): `parseIntoFreshContext()` centraliza
  «crear contexto JITeado + parsear el IR dentro» y elige la rama en
  **comptime con `@hasDecl`**: 19..21 usan `CreateNewThreadSafeContext` +
  `GetContext`; 22+ crean el contexto con `LLVMContextCreate` y lo
  envuelven con `FromLLVMContext`. Ownership idéntico en ambos lados: el
  caller dispone su ref del TSC (`defer`) y el `ThreadSafeModule` mantiene
  la suya compartida; en el camino de fallo del parse se dispala el TSC
  (rama 19) o el contexto (rama 22).
- **Verificación**: en LLVM 19 (pinado) `zig build -Dllvm`, `build test
  -Dllvm` y `llvm_jit.sh` 154/154 plano y `-O2`; en CI el canario pasó a
  **verde** (run 39954279053) — la rama 22+ compiló y corrió la suite
  completa bajo LLVM latest, no sólo el shim aislado.

## 15. M6.b — `--fast-math` opt-in (implementado 2026-10-23)

Primer item opcional de M6 (`LLVM_BACKEND_PLAN.md` §6). El flag nuevo
`--fast-math` (exige un modo de salida LLVM: `--emit-llvm`,
`--emit-llvm-stdout`, `--emit-obj` o `--jit`; con la VM o los dumps se
rechaza con mensaje accionable) marca toda la aritmética FP del módulo
con los **siete flags fast-math** — `reassoc|nnan|ninf|nsz|arcp|contract|
afn`, lo que el IR textual imprime como `fast`.

### Diseño

- **Portabilidad del C API**: en LLVM 19 `LLVMFastMathFlags` es
  `typedef unsigned` sin nombres de bit; LLVM 22+ añade el enum
  `LLVMFastMathFlags` con `LLVMFastMathAllowReassoc = 1 << 0` … — **el
  mapa de bits es el mismo** (orden LangRef: reassoc, nnan, ninf, nsz,
  arcp, contract, afn), así que la constante `0x7F` se fija en el emisor
  y compila igual en todo el rango 19..23. La función se llama
  `LLVMSetFastMathFlags` en ambos.
- **Opt-in estricto**: sin el flag el emisor no emite ni una marca
  distinta — el IR de siempre queda **byte-idéntico** (verificado con
  grep sobre `--emit-llvm-stdout`: 0 ocurrencias de `… fast`), así que
  ningún gate existente se mueve. El campo `fast_math` vive en el
  emisor con `enableFastMath()` al estilo de `enableSanitizer()`.
- **Los cinco puntos de construcción FP** pasan por `setFastMath()`:
  `fadd`/`fsub`/`fmul` de los binarios, `fneg` del unario y
  `fdiv`/`frem` de `emitDivRem`.
- **El guard no se marca**: el `fcmp oeq` del guard de división cero se
  queda sin FMF — dividir entre cero sigue siendo el error del VM con su
  texto («division by zero»), no `inf`. Consecuencia de diseño: el fast
  de `ninf` no convierte en UB el único camino que llega a `fdiv` con
  divisor cero, porque ese camino ni llega.

### Fixture y crecimiento de la suite

`zig/tests/llvm/check_fast_math.astra` (`// FLAGS: --fast-math`) fija la
forma del IR con FileCheck: seis ops con `fast` en orden y ambos guards
sin marcar (`fcmp oeq double` plano). Como `llvm_filecheck.sh` ya
admitía `// FLAGS:` por fixture, no hubo que tocar el harness.

Al vivir en `tests/llvm/`, el fixture entra también en **todos** los
gates de paridad (la carpeta se copia entera): la suite crece de **154 a
155**. Es un crecimiento honesto — el caso añade paridad real de `%`
sobre floats (`frem` VM↔LLVM) y de `print` de floats, y los registros
históricos de los hitos anteriores conservan su 154 fechado.

### Verificación

- `llvm_filecheck.sh`: **6/6** (nuevo fixture en verde).
- `llvm_parity.sh`: **155/155** plano y con `ASTRA_LLVM_OPT=2`.
- `llvm_jit.sh` / `llvm_cross.sh` / `llvm_wasm.sh`: **155/155** cada uno.
- Corrida real `--jit --fast-math` sobre el fixture: salida correcta
  (`3.75 / -0.75 / 3.375 / 0.666667 / 1.5 / -3.75` — valores exactos en
  binario, indistinguibles con o sin la marca, como corresponde a un flag
  que sólo habilita *optimizaciones* permitidas).
- Rechazo: `astra-zig --fast-math file.astra` (modo VM) →
  `error: --fast-math requires an LLVM output mode …`, exit 2.

## 16. M6.c — des-boxing de Option/Result (etapa c.1 implementada)

**Estado (2026-10-24): c.1 implementado** — el par `{i8 tag, i64 payload}`
vive en SSA dentro de funciones nombradas (params, retornos, `let` y
temporales) con boxing en las fronteras, sin flag opt-in; todos los gates en
§16.1 están verdes y el contrato de diseño de este §16 quedó cerrado con las
desviaciones anotadas. Sigue abierto y opcional el paso c.2 (payloads `str_`).

Segundo item opcional de M6 (plan §6). Este §16 es el **contrato de diseño**
que precedió a la implementación — la convención «cada item se planifica al
entrar» aplica con fuerza aquí: es el cambio con más riesgo semántico de la
fase (touchpoints: ~40 sitios sustantivos de `emitter.zig` + el contrato de
runtime), y el benchmark actual le da «visibilidad mínima» (§14). Se escribió
primero para que la implementación tuviera la decisión de representación
cerrada y no se improvisaran conversiones a mitad de ruta.

### Qué cuesta hoy

Todo `Option/Result` es una **caja heap** `{ i32 tag; i32 ptype; i64 payload }`
asignada por `astra_llvm_wrap` en cada `some(x)`/`ok(x)`/`err(x)`, con `none`
como puntero NULL (§4, M1). `?`, `match`, print e igualdad la leen con
`loadBoxTag`/`loadBoxPayload`. En código escalar caliente (`f()?` en bucle),
cada construcción paga malloc + header rc + dos loads, y M4.e añade el
release correspondiente.

### Decisión de representación: par `{i8 tag, i64 payload}` en SSA

- **NO sentinel i64** (la opción que los docs previos llamaban «tag entero,
  arriesgado: colisiones de sentinel»): el dominio de payload de `i64` es
  completo — cualquier valor que se reserve como «none» colisiona con un
  programa legal. El análisis cierra esa opción: sentinel es incorrecto,
  no arriesgado.
- Sí **par des-boxado** en valores SSA: `{ i8 tag; i64 payload }` (el payload
  sigue el mismo transporte de bits de `toBits`/`fromBits` de hoy; `f64` por
  bitcast, `bool` 0/1, payloads de puntero — `str_`/`fn_`/`arr_`/`struct_`/
  `enum_` — caben en el i64). `none` = `{ 3, 0 }` (tag 3, el «nil» del VM),
  sin puntero NULL que testear. Sin heap, sin rc, sin loads: el `?` sobre
  par es `icmp tag == err` + rama; el payload es `extractvalue`.
- **Tag en i8** (no i32): el par vive en registros/stack; el layout de caja
  heap NO se toca.

### Frontera de conversión (lo que acota el riesgo)

El par sólo vive en **SSA: temporales, `let` locales, parámetros y retornos**
con tipo estático conocido de optional escalar (`i64`/`f64`/`bool`). En
cualquier frontera que hoy exige 8 bytes crudos — elementos de array, campos
de struct, payloads de enum, slots de captura de lambda — se **caja en el
sitio** (llamada a `astra_llvm_wrap`, exactamente hoy) y las cargas desde
esos contenedores devuelven caja como ahora. Invariant: **la semántica no
cambia ni un byte**; el des-boxing es pura representación. Consecuencias
delimitadas documentadas:

- `print`/`igualdad` de un par se **inlinean en el emisor** con ramas de tag
  (hoy van a `astra_llvm_print_boxed`/`astra_llvm_boxed_eq` con puntero): el
  emisor ya conoce el payload estático, así que cada rama usa el print/eq
  existente de ese Ty. La caja cargada desde contenedor conserva el camino
  runtime actual.
- Las **llamadas a fn conocidas** firman con el par (ambos lados son emisor,
  el `FnInfo` cachea el LLVM type); las **llamadas dinámicas** (`fn_` con
  parámetro optional) y los retornos a través de `fn_` caen al camino cajado
  (firma runtime genérica de hoy).
- `some(some(x))` ya es rechazo limpio hoy (`boxPTy(boxed_)` = null); se
  conserva.

### Etapas y gates

| Etapa | Contenido | Gate |
|:------|:----------|:-----|
| **c.1** | par en SSA para construcción + `?` + `match` + print/igualdad inline, con boxing en fronteras | paridad **157/157** (la paridad ES el gate: si la representación cambia la salida, hay bug), filecheck nuevo de formas del par, fuzz 4 rutas |
| **c.2** (opcional) | ampliar a payloads `str_` (par con puntero) sin boxing en fronteras de string | igual |

Sin flag opt-in: a diferencia de fast-math, aquí no hay cambio semántico que
proteger — la corrección se demuestra con las rutas gateadas existentes
(parity/jit/cross/wasm + ASan/LSan: el par no asigna, así que las fugas sólo
pueden bajar). Los tests unitarios existentes de `emitter.zig` (§4157:
«match de Option: TAG_IS inline…») se ajustan a las formas nuevas y fijan
los shapes viejos que dejen de aplicar.

**Estado: c.1 implementado (2026-10-24).** Riesgo residual conocido: el
peaje de conversiones en frontera (caja↔par) debe ser exhaustivo — un sitio
que olvide una de las dos direcciones es un use-after-free de rc o un tag
ilegible; la auditoría se hizo por `grep boxed_` (los ~40 sitios) y por una
batería manual de fronteras (struct/array/capturas/llamadas) VM↔LLVM.

### §16.1 — Registro de implementación de c.1

Lo que entró en `zig/src/llvm/emitter.zig`:

- **Reglas de forma**: el par vive sólo en params/rets/`let`/temporales de
  **funciones nombradas**; lambdas y valores `fn(...)` conservan la caja (ABI
  dinámica); contenedores (elems de array, campos de struct/enum, slots de
  captura) se cajan en el sitio. Una función cuya firma usa par **no puede
  usarse como valor** — rechazo honesto en `emitIdent` (la ABI dinámica no
  representa un par).
- **Conversiones**: `coerceToBox` (par→caja en frontera; `none` → caja NULL,
  nunca tag 3 — el runtime imprimiría `some(`), `coerceToPair` (caja→par en
  entrada de firma con par; la caja NULL es `{3, 0}` sin memoria),
  `coerceVal`/`coerceRet`/`unifyWithFixed` (la caja sin payload estático —
  p. ej. `none` o un elemento de array — **toma prestado el payload del
  destino**, sound porque el typechecker garantiza la compatibilidad).
- **Hot path inline**: construcción (`insertvalue`), `?` (`extractvalue` +
  `icmp` de tag), `match` y la unificación de brazos no tocan heap ni rc.
- **`emitIf`/`emitMatch` reestructurados**: los `br merge` se posponen y la
  coerción de un brazo se emite **en el bloque-unión de su propio brazo**
  (aún sin terminador); si se emitiera ya en merge, el bloque-unión no sería
  predecesor del phi («PHI node entries do not match predecessors»).

Desviaciones respecto al contrato de diseño de arriba (todas decisiones, no
accidentes):

1. **print/igualdad/orden del par**: no se inlinearon el emisor — el par se
   **convierte a caja en el sitio** y corre el runtime actual
   (`astra_llvm_print_boxed`/`boxed_eq`). Sí está inline la igualdad
   par-vs-par (tag `icmp` + payload: `f64` por `fcmp OEQ`, resto por bits —
   casa con `boxed_eq`). El hot path (?/match/construcción) no paga nada de
   esto.
2. **`br i1 true` del `none`**: `none` es una constante NULL, así que
   `coerceToPair` pliega la condición a `br i1 true, label %box_none, label
   %box_load` con un bloque muerto `box_load` (`load i32, ptr null`) — seguro
   porque es inalcanzable y O2 lo elimina. Fijado en `check_opt_pair.astra`.
3. **Bugs encontrados y cerrados en la auditoría de fronteras**: el phi de
   `emitIf` y el de `emitMatch` **descartaban `payload_ty`/`sname`**, así que
   `let c = if … { some(1) } else { none }` seguido de `print(c)` llegaba a
   `coerceToBox` con un par sin payload y revienta (panic de unwrap). Arreglado
   en ambos phis + defensa en `coerceToBox` (diagnóstico limpio en vez de
   unwrap nulo); el caso quedó pinzado por el conformance nuevo
   `seed/tests/conformance/enums/option_branch_unify.astra` (15 EXPECT).

Gates de c.1 (2026-10-24, todos verdes):

| Gate | Resultado |
|:-----|:----------|
| `seed make test` (VM + C codegen, con el conformance nuevo) | **259/259** |
| `zig build test -Dllvm` (unit, emisor) | **rc=0** |
| `llvm_parity.sh` plano y `ASTRA_LLVM_OPT=2` | **157/157** y **157/157** |
| `llvm_jit.sh` plano y O2 | **157/157** ×2 |
| `llvm_cross.sh` (aarch64→qemu) plano y O2 | **157/157** ×2 |
| `llvm_wasm.sh` (wasm32-wasi→Node) plano y O2 | **157/157** ×2 |
| `llvm_filecheck.sh` (`check_try` reescrito + `check_opt_pair` nuevo) | **7/7** |
| `llvm_sanitize.sh` (ASan + LSan) | **157/157**, sin fugas |
| `dump_parity.sh` (seed ↔ zig) | **146 archivos, 0 divergent** |

La suite LLVM crece de 156 a **157** (el conformance nuevo entra al glob de
paridad). Queda abierto y opcional **c.2** (payloads `str_` con puntero) y,
posterior, el **error-union para `?`** (plan §6).
