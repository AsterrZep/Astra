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

**M0 (infraestructura + smoke de punta a punta) está completo.** El emisor
mínimo compila el subconjunto escalar de Astra-0 a LLVM IR verificado, lo
baja a objeto con `llc`, lo enlaza contra el runtime compartido del seed y
produce binarios cuya salida (stdout, stderr y código de salida) es
**byte-idéntica a la VM** para todos los casos en alcance.

| Hito | Contenido | Estado |
|:-----|:----------|:-------|
| **M0.1** | flag `-Dllvm` + descubrimiento de `llvm-config` (rango 19..23) | ✅ |
| **M0.2** | binding `llvm-c` (`src/llvm/c_api.zig`) + smoke test verify/print | ✅ |
| **M0.3** | emisor mínimo (`src/llvm/emitter.zig`) + CLI `--emit-llvm` | ✅ |
| **M0.4** | runner `zig/tests/llvm_parity.sh` + job CI `llvm` (apt.llvm.org 19) | ✅ |
| **M0.5** | `PHASE_LLVM_PROGRESS.md` + AGENTS.md (build `-Dllvm`, `-lc`) | ✅ |
| **M1** | closures, floats, Option/Result + `?`, strings | ⬜ |
| **M2** | arrays/structs (GEP), enums + `match`, `for..in` | ⬜ |
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

Estado actual: **93 casos — 14 ok, 78 skip, 1 excl, 0 fail**.

---

## 5. Diferido a M1+

| Qué | Hito |
|:----|:-----|
| Boxing de escalares, floats (guards no-IEEE), closures (env structs) | M1 |
| Option/Result y `?` (longjmp v1), strings | M1 |
| Arrays/structs (GEP estáticos por layout del typechecker) | M2 |
| Enums + `match` (tag tests → `icmp`/`br` + phi), `for..in` | M2 |
| `TargetMachineEmitToFile` reemplaza al `llc` subproceso | M2 |
| Atributos de helpers, pesos de rama fría en traps, fuzz diferencial, FileCheck | M3 |
| DWARF (`DebugInfo.h`), pipeline `-O2` + remarks, benchmarks | M4 |

Exclusiones del runner de paridad (con commentario en el propio script):

- **`expressions/recursion_depth_limit.astra`** — fija el guard de profundidad
  de llamada de la VM (`VM_CALL_DEPTH`); el código nativo no lo reproduce y
  completa legítimamente, así que no es comparable hasta que la ruta LLVM
  crece su propio guard (M1+).
- Los casos con `import`/`from`/`use` se saltan (emisor de fichero único).

---

## 6. Bug pre-existente conocido (no de esta fase)

El operador **`||` (`or_or`)** falla en runtime con
`cannot call non-function value` en **ambas** VMs (seed y zig) — `&&` funciona.
No es una regresión del backend LLVM: el `||` de la ruta LLVM calcula bien
(short-circuit + phi). Se excluye de la paridad por ahora; su arreglo pertenece
al seed/espejo zig (fix(seed) + fix(zig)) y queda fuera del alcance de M0.

---

## 7. Commits de M0

| # | Commit | Mensaje |
|:-:|:-------|:--------|
| M0.1 | `c2c62d1` | `build(llvm): flag -Dllvm y descubrimiento de LLVM vía llvm-config` |
| M0.2 | `52a4710` | `feat(llvm): binding llvm-c y módulo verify/print (M0.2)` |
| M0.3 | `96f66c4` | `feat(llvm): emisor mínimo y CLI --emit-llvm` |
| M0.4 | `2ee1e47` | `test(llvm): runner llvm_parity + job CI llvm (apt.llvm.org 19)` |
| M0.5 | _(este commit)_ | `docs(llvm): PHASE_LLVM_PROGRESS.md + AGENTS.md (build -Dllvm, -lc)` |

Gates verdes en cada commit de M0: suite seed **237/237** + `--check-constructs`
OK, `zig build test` **73/73** (sin flag) / **76/76** (con `-Dllvm`), paridad de
dumps **124/0**, `sweep_emit_c` **0 fail**, `ui_message_parity`
`accept_fail=0 first_fail=0`, y `llvm_parity.sh` **0 fail**.
