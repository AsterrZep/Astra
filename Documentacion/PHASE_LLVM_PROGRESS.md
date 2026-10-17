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

## 1. Estado actual (2026-10-17)

**M0 (infraestructura) y M1 (núcleo completo) están terminados.** El emisor
compila el núcleo de Astra-0 — escalars, floats, strings, Option/Result con
`match`/`?` y closures — a LLVM IR verificado, lo baja a objeto con `llc`,
lo enlaza contra el runtime compartido del seed y produce binarios cuya
salida (stdout, stderr y código de salida) es **byte-idéntica a la VM** para
todos los casos en alcance (41 de los 93 casos del gate de paridad; el resto
son arrays/structs/enums de usuario/`for`, que llegan con M2).

| Hito | Contenido | Estado |
|:-----|:----------|:-------|
| **M0.1** | flag `-Dllvm` + descubrimiento de `llvm-config` (rango 19..23) | ✅ |
| **M0.2** | binding `llvm-c` (`src/llvm/c_api.zig`) + smoke test verify/print | ✅ |
| **M0.3** | emisor mínimo (`src/llvm/emitter.zig`) + CLI `--emit-llvm` | ✅ |
| **M0.4** | runner `zig/tests/llvm_parity.sh` + job CI `llvm` (apt.llvm.org 19) | ✅ |
| **M0.5** | `PHASE_LLVM_PROGRESS.md` + AGENTS.md (build `-Dllvm`, `-lc`) | ✅ |
| **M1** | floats, strings, Option/Result + `?` + `match`, closures | ✅ |
| **M2** | arrays/structs (GEP), enums de usuario + `match`, `for..in` | ⬜ |
| **M3** | paridad total, fuzz diferencial, FileCheck | ⬜ |
| **M4** | calidad: DWARF, pipeline `-O2` + remarks, benchmarks | ⬜ |

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

# Gate de paridad (VM <-> ruta LLVM)
./tests/llvm_parity.sh
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
   limpio (exit 2) — el emisor M0 es de fichero único.

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

## 6. Diferido a M2+

| Qué | Hito |
|:----|:-----|
| Arrays/structs (GEP estáticos por layout del typechecker) | M2 |
| Enums de usuario + `match` de variantes (tag tests → `icmp`/`br` + phi), `for..in` | M2 |
| `TargetMachineEmitToFile` reemplaza al `llc` subproceso | M2 |
| Atributos de helpers, pesos de rama fría en traps, fuzz diferencial, FileCheck | M3 |
| DWARF (`DebugInfo.h`), pipeline `-O2` + remarks, benchmarks | M4 |

Exclusiones del runner de paridad (con commentario en el propio script):

- **`expressions/recursion_depth_limit.astra`** — fija el guard de profundidad
  de llamada de la VM (`VM_CALL_DEPTH`); el código nativo no lo reproduce y
  completa legítimamente, así que no es comparable hasta que la ruta LLVM
  crece su propio guard.
- Los casos con `import`/`from`/`use` se saltan (emisor de fichero único).

---

## 7. Bug pre-existente conocido (no de esta fase)

El operador **`||` (`or_or`)** falla en runtime con
`cannot call non-function value` en **ambas** VMs (seed y zig) — `&&` funciona.
No es una regresión del backend LLVM: el `||` de la ruta LLVM calcula bien
(short-circuit + phi). Se excluye de la paridad por ahora; su arreglo pertenece
al seed/espejo zig (fix(seed) + fix(zig)) y queda fuera del alcance de M0.

---

## 8. Commits

### M0

| # | Commit | Mensaje |
|:-:|:-------|:--------|
| M0.1 | `c2c62d1` | `build(llvm): flag -Dllvm y descubrimiento de LLVM vía llvm-config` |
| M0.2 | `52a4710` | `feat(llvm): binding llvm-c y módulo verify/print (M0.2)` |
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
