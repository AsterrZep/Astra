# 029 — Arreglos de proceso, bootstrap y registro de constructos

> **Alcance**: investigación y **propuestas de parche** derivadas de la crítica
> externa verificada en `research/025`. **No se aplica ningún parche en este
> documento**: los diffs son texto propuesto, no cambios en el repo. Fecha:
> 2026-10-27. Todo lo marcado **[verificado]** se ejecutó o se leyó en esta
> sesión (Debian, seed compilado con `make`, Zig 0.16.0 en `~/zig/zig`); lo
> marcado **[citado]** procede de otro documento del repo y no se ejecutó aquí.

**Comandos ejecutados en esta sesión** (todos en `/home/aster/Astra`):

| Comando | Salida |
|:--------|:-------|
| `./seed/astra-seed --check-constructs` **[verificado]** | `47 constructs` / `migrated (all three phases): 0 / 47` / `OK — registry, lexer, parser and operator table agree` |
| `cd seed && make test` **[verificado]** | `passed: 260   failed: 0` (incluye el gate del registro) |
| `cd zig && zig build test --summary all` **[verificado]** | `73/73 tests passed` |
| `./zig/tests/dump_parity.sh` **[verificado]** | `dump_parity: 147 files, 0 divergent` |
| `git log --oneline \| wc -l` / `grep -icE "llvm\|parity"` **[verificado]** | `234` / `73` (31 %); primer commit `2026-09-16` |
| `git log --format=%H -- seed/src zig/src \| sort -u \| wc -l` **[verificado]** | `135` commits tocan código de compilador |
| `git log --format=%H -- seed/tests/conformance \| sort -u \| wc -l` **[verificado]** | `66` |
| `find Documentacion -name "*.md" \| xargs wc -l \| tail -1` **[verificado]** | `41141` líneas; `ls Documentacion/07_investigacion/*.md \| wc -l` → `25` al ejecutarlo (con `026`–`029` ya escritos por otros subagentes hay **29**: recalcular en el momento del parche) |
| `grep -c 'free(' seed/src/vm.c` / `'malloc'` **[verificado]** | `0` / `0` |
| `grep -riE "fiber\|scheduler\|spawn\|channel\|Atomic\[" seed/src zig/src` **[verificado]** | `0` |
| `grep -rn 'transfer' seed/src` / `'"len"\|"push"\|"to_string"'` **[verificado]** | `0` / `0` |
| `grep -riE "query system" seed/src zig/src` **[verificado]** | `0` |
| `ls bootstrap` **[verificado]** | no existe el fichero ni el directorio |
| grep de consumidores de hooks fuera de `constructs/` **[verificado]** | solo `main.c` (`construct_dump`, `construct_self_check`); `parser.c` solo expone `parser_precedence_of`/`parser_binary_op_of` **para el self-check** |

---

## 0. Resumen ejecutivo — parches recomendados en orden

1. **`Documentacion/02_compilador/COMPILER_STRATEGY.md`** — §7.1 (paso 3
   imposible), §4.7 (`:303`) y el par «Why Three Phases?» (`:112`, `:116`), que
   repiten la misma falsedad. Diff completo en §1. Es el parche más barato y el
   que más contradicción interna cierra (`:64` vs `:588`).
2. **`README.md`** — (a) la línea de Status (`:19`, que dice que el backend LLVM
   «does not exist yet» mientras `:134` lo da por hecho con 159/159); (b) la
   sección `## Roadmap` (`:118-136`) reescrita con tres estados y evidencia por
   ítem (§2); (c) los conteos obsoletos `001–024 (24 files)` (`:91`, `:115`).
3. **Registro de constructs — opción B** (declararlo índice documental):
   parches de texto en `seed/src/constructs/construct.h` y `AGENTS.md`. **La
   decisión ya existe y está escrita** (`CONSTRUCT_REGISTRY.md` §8, 2026-09-21);
   lo que falta es que `AGENTS.md` y `construct.h` dejen de contradecirla (§3).
4. **Mecanismo de decisiones**: crear `Documentacion/01_lenguaje/DECISIONES.md`
   (ADR-lite) + dos reglas nuevas en `AGENTS.md` (decisión previa a feature;
   presupuesto de commits) + checkbox en la plantilla de PR (§4). Todo texto
   listo para pegar.
5. **Estado en un solo sitio**: la tabla «Estado del proyecto» de
   `Documentacion/00_indice/INDICE.md` pasa a ser la fuente de verdad; README y
   `ARCHITECTURE.md` §41 solo la reflejan (§2 y §4).
6. **`ARCHITECTURE.md` §41 «Puntos Pendientes»** — tercera fuente de `[x]`
   falsos (REPL, LSP, kernels GPU, ARC/ORC…, 31 `[x]`); parche de reetiquetado
   en §2.4.

Ninguno de estos parches toca código de compilador, así que **ninguno cambia el
comportamiento**; los gates actuales siguen en verde por construcción (§5).

---

## 1. Parche de texto exacto — `COMPILER_STRATEGY.md`

### 1.1 Contexto investigado (para no contradecir la doc existente)

- **`research/002` §6.2/§6.3** **[citado, leído en esta sesión]** describe el
  bootstrap con fuente **`.ast` en Astra-0**: «Seed compiles self-hosting
  compiler → `./astra-seed compile src/compiler/main.ast -o astra-v1.c`». Es
  decir: el plan original **nunca** dijo que el seed compilara Zig; el falso
  paso 3 es una adición posterior de `COMPILER_STRATEGY.md`.
- **`PHASE2_PROGRESS.md:3-17`** **[verificado]**: el compilador Zig «Sustituye
  al compilador semilla en C» y «está **portado** y verificado: compila y ejecuta
  la suite del seed con salida idéntica»; `PHASE2_KICKOFF.md:14` dibuja
  `C seed compiler (astra-seed) → Zig compiler (astra-zig)` (reemplazo, no
  compilación). **La cadena real es: C seed → port manual a Zig → verificación
  por suite.**
- **`COMPILER_STRATEGY.md:64`** **[verificado]**: «No language started
  self-hosted. The seed compiler is a **temporary tool**». Correcto; se conserva
  tal cual, y con el parche deja de contradecir al §7.1.
- **Fase 3 sí tiene interpretación legítima**: el §6 del propio documento
  (`:531-561`) describe «The Zig compiler compiles the Astra compiler (written
  in Astra)» + *diverse double-compilation*. **Esa fase se conserva** (paso 4-5
  del nuevo §7.1), reescrita con su prerequisito real (stdlib mínimo de
  Astra-0, `research/025` §2.6).

### 1.2 Diff — bloque §7.1 (`:588-609`)

````diff
 ### 7.1 Complete Bootstrap Sequence
 
-```
-Step 1: Build C seed
-    cc *.c -o astra-seed
-
-Step 2: Seed compiles minimal Astra
-    ./astra-seed src/stdlib/stdlib.astra -o stdlib.o
-    ./astra-seed src/compiler/compiler.astra -o compiler.o
-    cc stdlib.o compiler.o -o astra-v0
-
-Step 3: astra-v0 compiles Zig compiler source
-    ./astra-v0 bootstrap/zig-compiler.zig -o astra-zig
-
-Step 4: astra-zig compiles full Astra compiler
-    ./astra-zig build src/compiler/ -o astra
-
-Step 5: astra compiles itself
-    ./astra build src/compiler/ -o astra-self
-    ./astra-self build src/compiler/ -o astra-verified
-    diff astra-self astra-verified  # Must be identical
-```
+### 7.1 Bootstrap Sequence (as built)
+
+The chain executed so far is a **manual port**, not a compilation step: the
+seed has never compiled the Zig compiler, Astra-0 cannot read `.zig` sources,
+and `bootstrap/zig-compiler.zig` does not exist. Steps marked *future* are
+what remains; steps marked *gate* are re-run on every PR.
+
+```
+Step 1: Build C seed                                        [done]
+    cc *.c -o astra-seed
+
+Step 2: Port the Astra-0 frontend to Zig BY HAND            [done]
+    cd zig && zig build                 # Zig 0.16, port of seed/src
+    zig build test                      # unit + seed conformance
+    ./tests/dump_parity.sh              # --dump-tokens/--dump-ast vs seed
+
+Step 3: The seed stays the behavioural reference            [gate, every PR]
+    cd seed && make test                # registry gate + VM + C-backend round-trip
+    every new behaviour lands in seed/tests/ first, then in zig/src
+
+Step 4 (future): astra-zig compiles the Astra compiler
+    # prereq: minimal Astra-0 stdlib (len, push, string indexing/iteration,
+    # int->string, file I/O) — research/025 §2.6; then an Astra-0 source tree
+    ./astra-zig build src/compiler/ -o astra
+
+Step 5 (future): astra compiles itself
+    ./astra build src/compiler/ -o astra-self
+    ./astra-self build src/compiler/ -o astra-verified
+    diff astra-self astra-verified  # Must be identical
+```
+
+> **Note (2026-10-27, `research/029` §1).** An earlier revision listed a
+> `Step 3: astra-v0 compiles Zig compiler source`. That step was impossible
+> (Astra-0 compiles `.astra`, not `.zig`) and no `astra-v0` binary was ever
+> produced. The Zig compiler is a *port* verified by the seed's suite; the
+> seed compiles an **Astra-0** compiler only from Step 4 on, which is exactly
+> what `research/002` §6.3 prescribes.
 ````

### 1.3 Diff — §7.2 Cadena de confianza (`:611-620`)

```diff
 ### 7.2 Trust Chain
 
 ```
 C compiler (gcc/clang) — trusted (system compiler)
   → astra-seed — auditable (simple C code)
-    → astra-v0 — compiled by seed (verify conformance tests)
-      → astra-zig — compiled by v0 (verify it compiles correctly)
-        → astra — compiled by zig (verify conformance tests)
-          → astra-self — compiled by astra (verify binary reproducibility)
+    → astra-zig — written by hand from the seed, verified against its suite
+      (zig build test + dump_parity.sh byte-for-byte)
+        → astra (future) — compiled by astra-zig from Astra-0 source
+          (conformance tests)
+          → astra-self — compiled by astra (verify binary reproducibility)
 ```
```

### 1.4 Diff — §7.3 (`:622-628`)

```diff
 1. **C compiler is trusted**: It's the system compiler, used by billions of lines of code
 2. **C seed is auditable**: ~5000 lines of C, no dependencies, easy to review
-3. **astra-v0 is verified**: Must pass all conformance tests
-4. **astra-zig is verified**: Must compile correctly and pass tests
-5. **astra is verified**: Must produce identical output to itself
+3. **astra-seed is verified**: `make test` — registry gate + VM + C-backend round-trip (260 checks)
+4. **astra-zig is verified**: `zig build test` (73 tests) + `dump_parity.sh` byte-identical to the seed
+5. **astra is verified** (future): Must produce identical output to itself
```

### 1.5 Diff — §4.7 «Testing the Seed» (`:300-305`, la línea `:303`)

```diff
 ### 4.7 Testing the Seed
 
 The seed compiler is tested against:
-1. **Self-hosting compiler source**: The seed must compile the Zig-based compiler
-2. **Astra-0 conformance tests**: 228 test cases covering the minimal subset
-3. **Cross-platform**: Must build and run on Linux, macOS, Windows
+1. **Behavioural reference for the Zig port**: the seed defines Astra-0
+   behaviour; `zig build test` and `zig/tests/dump_parity.sh` must agree with
+   it. The seed does **not** compile the Zig compiler — that is Step 4 of §7.1
+2. **Astra-0 conformance tests**: 260 checks covering the minimal subset
+   (229 conformance + 28 codegen + 3 auxiliary — `make test`, 2026-10-27)
+3. **Cross-platform**: verified on Linux (CI). macOS/Windows builds are not
+   exercised by any gate today
```

### 1.6 Diff — §3 «Why Three Phases?» (`:112` y `:116`, misma falsedad)

```diff
-**Phase 1 (C) → Phase 2 (Zig):** The C seed compiles a minimal Astra that's powerful enough to compile the Zig-based compiler. The Zig compiler is the "real" compiler — it handles all the complex features (generics, traits, comptime, ARC/ORC).
+**Phase 1 (C) → Phase 2 (Zig):** The C seed is the behavioural reference for Astra-0: it fixes the grammar, diagnostics and VM behaviour that the Zig compiler must reproduce. The Zig compiler was **ported from it by hand** and is verified against the seed's suite; it is the "real" compiler — it handles all the complex features (generics, traits, comptime, ARC/ORC).
 
-**Why not skip Phase 1?** Because you need *something* to compile the Zig compiler. Zig requires `zig` to build Zig programs. The C seed provides the initial `astra` command that can compile the minimal subset needed.
+**Why not skip Phase 1?** Because you need *something* to define Astra-0: the seed fixes the reference semantics the port must match, and it is the compiler that will later build the Astra-written compiler of Phase 3 (`research/002` §6.3). Zig requires `zig` to build Zig programs — the seed never builds them.
```

**Opcional (recomendado)**: en el diagrama ASCII del §3, `:84`
(`Purpose: Bootstrap the self-hosting compiler`) →
`Purpose: reference implementation of Astra-0 + future bootstrap of the Astra compiler`.

**Respuesta a las dos preguntas**: el paso «`astra-v0` compiles Zig source» se
**elimina** (no hay interpretación legítima: es imposible por diseño); la línea
`:303` se **reescrita** como relación de referencia/port; y **sí se conserva**
una fase futura claramente marcada — el paso 4/5 del nuevo §7.1, que es el
`zig-compiler.astra` análogo (compilar un compilador escrito en Astra con
`astra-zig`), coherente con §6.2/§6.3 de este mismo documento y con
`research/002` §6.

---

## 2. Roadmap de README reescrito (estado real verificado)

### 2.1 Fuente de verdad (respuesta a «¿dónde vive?»)

**Hoy hay tres fuentes paralelas** — es el bug de proceso:

| Fuente | Qué afirma | Estado |
|:-------|:-----------|:-------|
| `README.md:118-136` (Roadmap) | `[x]` binarios, 2 falsos | desincronizada |
| `ARCHITECTURE.md:2490-2525` (§41 «Puntos Pendientes») | `[x]` en «REPL interactivo», «LSP», «kernels GPU», «Runtime systems (ARC/ORC, fibers)», «Concurrencia profunda», «Arquitectura del compilador (multi-IR, query system)»… | desincronizada (tercera fuente de falsos `[x]`) |
| `INDICE.md:105-116` («Estado del proyecto de un vistazo») | tabla con gate + cifra por área, con la política «los contadores se verifican, no se recuerdan» (`:133-135`) | **la más fiable; ya existe y ya se mantiene** |

**Propuesta**: `Documentacion/00_indice/INDICE.md` §«Estado del proyecto» es la
**única** fuente de verdad del estado; los documentos *vivos*
(`PHASE1_PROGRESS`, `PHASE2_PROGRESS`, `PHASE_LLVM_PROGRESS`) guardan el detalle
(esa regla ya está escrita en `INDICE.md:127-132`); README y `ARCHITECTURE` §41
**solo reflejan** esa tabla y citan el gate. Regla exacta para `AGENTS.md` en §4.2.

### 2.2 Línea de Status — `README.md:19`

```diff
-> **Status: Phase 1 complete, Phase 2 in progress** — the seed compiler (`seed/`, C) compiles and runs Astra-0 (suite in green on the VM, the C backend and Zig); the self-hosting Zig compiler (`zig/`) implements the Astra-0 frontend plus the module system. The standard library and the LLVM backend (Phase 2.6) do not exist yet.
+> **Status (2026-10-27)**: Phase 1 (`seed/`, C) complete — `cd seed && make test` → **260 passed, 0 failed**. Phase 2 (`zig/`) has the Astra-0 frontend, module system, traits, generics and `?`, verified against the seed suite — `zig build test` → **73/73**, `dump_parity.sh` → **147 files, 0 divergent**. The LLVM backend is **opt-in** (`-Dllvm`) and green: `llvm_parity.sh` → **159/159** (native, `-O2`, aarch64 under qemu, wasm32-wasi under Node). **Not built yet**: standard library, ARC/ORC + fibers, comptime, package manager, Phase 3 self-compilation. Single source of truth for status: [`Documentacion/00_indice/INDICE.md`](Documentacion/00_indice/INDICE.md).
```

> Corrige dos falsedades internas: el LLVM backend **sí** existe (contradice a
> `README.md:134`) y «suite en green … and Zig» es correcto.

### 2.3 Sección `## Roadmap` — reemplazo ítem por ítem (`:118-136`)

Sustituir las dos subsecciones por:

````markdown
## Roadmap

**Single source of truth: [`Documentacion/00_indice/INDICE.md`](Documentacion/00_indice/INDICE.md) → «Estado del proyecto».**
This table mirrors it. A row may only change in the same PR that changes that
table, and only with the gate command + figure pasted under «Evidencia de
verificación».

States — never a bare `[x]`:
**Specified** = written in a document, no code ·
**Implemented** = code exists, not gated ·
**Verified** = gate executed, command + number.

### Design & Research

| Item | State | Evidence |
|:-----|:------|:---------|
| Language design and architecture specification | **Specified** | `Documentacion/01_lenguaje/ARCHITECTURE.md` (§1–§41) |
| Cross-platform research (Linux, macOS, Windows, Android, iOS, visionOS) | **Specified** | `research/018`, `research/019`, ARCHITECTURE §24–27. *Cross-verified* only for `aarch64-linux-gnu` and `wasm32-wasi`: `zig/tests/llvm_cross.sh`, `llvm_wasm.sh` → 159/159 |
| Compiler architecture (multi-IR, query system) | **Specified (partial)** | multi-IR: ARCHITECTURE §20.1 · query system: **0 hits** in `seed/src`+`zig/src` · dual backend **Verified**: `make test` 260/260 + `llvm_parity.sh` 159/159 |
| Memory model (ARC/ORC, cycle detection, fiber-aware) | **Specified — not implemented** | ARCHITECTURE §2; `vm.c` never frees (`grep -c 'free(' seed/src/vm.c` → 0, arena-only), no cycle detection, no fiber-awareness. Ref-counting exists only on the LLVM route (M4.e, no cycles) |
| Concurrency model (green threads, channels, atomics) | **Specified — not implemented** | ARCHITECTURE §3/§35; `grep -riE "fiber\|scheduler\|spawn\|channel\|Atomic\[" seed/src zig/src` → **0**; `transfer` → 0 |
| Standard library design (~64 modules) | **Specified** | `research/015`, ARCHITECTURE §32; `std/…` is rejected by the Zig CLI |
| Package manager design | **Specified** | `research/016`, ARCHITECTURE §33; only `@/` root resolution from `astra.toml` |
| Formal grammar (EBNF) | **Specified + gated** | `research/001` §12.1; `./astra-seed --check-constructs` → 47 constructs / 27 operators, registry⇔lexer⇔parser agree |
| Compiler strategy (C → Zig → Astra bootstrapping) | **Specified — §7.1 correction pending** | `Documentacion/02_compilador/COMPILER_STRATEGY.md` §7.1 still states an impossible step (patch proposed in `research/029` §1) |

### Implementation

| Item | State | Evidence |
|:-----|:------|:---------|
| **Phase 1**: seed compiler in C (Astra-0) — VM, C backend, fuzzing | **Verified** | `cd seed && make test` → **260 passed, 0 failed** (2026-10-27, ASan/UBSan/LSan) |
| **Phase 2 core**: Zig compiler — Astra-0 frontend, modules, traits, generics, `?` | **Verified** | `cd zig && zig build test` → **73/73**; `zig/tests/dump_parity.sh` → **147 files, 0 divergent** (2026-10-27) |
| **LLVM backend** (`-Dllvm`, opt-in): `--emit-obj`/`--jit`, cross aarch64, wasm32-wasi, `--fast-math`, unboxed Option/Result | **Verified (CI)** | `zig/tests/llvm_parity.sh` → **159/159**, plain and `ASTRA_LLVM_OPT=2`; jobs `llvm`, `llvm-cross`, `llvm-wasm` **[citado de CI/INDICE, no ejecutado en esta sesión]** |
| **Phase 2 full language**: comptime, ARC/ORC, fibers, FFI, stdlib | **Not started** | `Documentacion/04_fase2_zig/PHASE2_GAP_ANALYSIS.md` §11 |
| **Phase 3**: Astra compiles itself | **Not started** | needs Phase 2 + the minimal Astra-0 stdlib of `research/025` §2.6 |
````

### 2.4 Ítems hoy marcados `[x]` que no lo están (auditoría ejecutada)

| Ítem | Hoy | Estado real | Comando/evidencia **[verificado]** |
|:-----|:----|:------------|:-----------------------------------|
| `:124` Memory model (ARC/ORC, cycle detection, fiber-aware) | `[x]` | **Specified — not implemented** | `grep -c 'free(' seed/src/vm.c` → 0; sin cycle detection ni fibras; rc solo en la ruta LLVM |
| `:125` Concurrency model (green threads, channels, atomics) | `[x]` | **Specified — not implemented** | grep combinado → 0 coincidencias en ambos árboles |
| `:123` Compiler architecture (multi-IR, query system) | `[x]` | **Specified (partial)** | query system → 0 en código; dual backend sí **Verified** |
| `:122` Cross-platform research | `[x]` | **Specified** (+ cross verificado solo aarch64 y wasm) | `llvm_cross.sh` / `llvm_wasm.sh` 159/159 **[citado]** |
| `:121,126,127,128,129` (spec, stdlib, pkg manager, grammar, strategy) | `[x]` | **Specified** (grammar: **Specified + gated**) | ficheros existen; `--check-constructs` OK |
| `:132` Phase 1, `:133` Phase 2 core, `:134` LLVM | `[x]` | **Verified** | `make test` 260/0 · `zig build test` 73/73 · `dump_parity` 147/0 (ejecutados) |
| `:135`, `:136` (full language, Phase 3) | `[ ]` | correcto: **Not started** | — |
| `ARCHITECTURE.md:2492-2525` §41 | `[x]` ×31 (y 2 `[ ]`) | mezcla de *investigado* y *implementado* (REPL, LSP, kernels GPU, ARC/ORC fibers, concurrencia profunda: **no implementados**) | greps de §2.4 arriba; `grep -c '^\- \[x\]'` sobre §41 → **31** **[verificado]** |

Parche recomendado para `ARCHITECTURE.md` §41 (texto exacto para pegar):

```diff
-## 41. Puntos Pendientes
-
-- [x] Todos los items investigados.
+## 41. Puntos de investigación — estado en INDICE.md
+
+> **Estado (2026-10-27)**: esta lista registra qué se ha **investigado**, no
+> qué está implementado. El estado de cada área (Especificado / Implementado /
+> Verificado, con el gate) vive en `Documentacion/00_indice/INDICE.md` §«Estado
+> del proyecto» y en `README.md` §Roadmap; no se marca nada aquí con `[x]`.
+> Los `[x]` de abajo significan «investigado/diseñado».
+
+- [x] Todos los items investigados.
```

---

## 3. Registro de constructs: opción A (wirear hooks) vs B (índice documental)

### 3.1 Hechos verificados

- `--check-constructs` → **`migrated (all three phases): 0 / 47`** **[verificado]**.
- Los 47 `constructs/*.c` asignan `.parse = NULL, .check = NULL, .emit = NULL`
  (leído `binding.c`, `literal.c`, `binary_op.c`, `call.c`) **[verificado]**.
- **Nadie consulta los hooks fuera del self-check**: grep de
  `construct_lookup|construct_by_token|construct_by_node|construct_table|construct_by_keyword|ConstructSpec`
  en `seed/src` → solo `constructs/*` y `construct.h`; en `parser.c` solo un
  comentario y `parser_precedence_of`/`parser_binary_op_of`, exportados
  **expresamente para el self-check** (`parser.c:2169-2182`) **[verificado]**.
  El único consumidor en `main.c` es `--check-constructs` / `--dump-constructs`.
- **`Documentacion/01_lenguaje/CONSTRUCT_REGISTRY.md` §8 (2026-09-21) ya decidió
  esto**: «**El seed no migra los hooks `parse`/`check`/`emit`. El registro se
  queda declarativo + validado (`migrated: 0 / 47`).**» con cuatro
  justificaciones citando `research/002` §2.3.1/§3.3/§2.3.3 **[verificado, leído
  íntegro]**. §7 además prescribe el coste real de la opción A: «Requiere una
  API de servicios del parser (`parser_internal.h`) porque hoy `advance`,
  `check`, `expect`, `parse_block`… son `static` dentro de `parser.c`».

### 3.2 Opción A — wirear los hooks de verdad (de punta a punta)

**Hallazgo técnico decisivo: la firma del hook no alcanza para 47 constructos.**

```c
typedef Node *(*ConstructParseFn)(Parser *p, SrcLoc loc);   /* construct.h:78 */
```

Es una forma *nud* (posición de palabra clave, sin operandos). Pero:

- `call`, `index`, `field_access`, `range`, `assign` y los 11 niveles de
  `binary_op` son **led de Pratt**: su implementación real es
  `parse_call(Parser *p, Node *left, Precedence prec)` (`parser.c:411`,
  `:359`, `:522`, `:533`, `:395`) — `left` y `prec` **no caben en la firma**.
  `binary_op.c` lo admite en su propia cabecera: «The table is the single source
  of truth».
- Los constructos de posición `type` (`type_annotation`) y `pattern`
  (5 × `pattern_*`, `match_arm`) se despachan desde `parse_type_impl`
  (`parser.c:1679`) y `parse_pattern_primary` (`parser.c:749`), no desde
  `parse_statement`/`parse_expression_impl`: harían falta **dos despachos más**.
- `literal` e `ident` —los sugeridos como piloto— arrastran en **check** la
  lógica más delicada del typechecker (literales polimórficos; resolución de
  símbolos con ámbitos), y en **emit** `GET_LOCAL/GET_GLOBAL` con capturas.

**Coste concreto de un piloto punta a punta** (verificado leyendo el código):

| Fase | Qué habría que tocar | Coste |
|:-----|:---------------------|:------|
| parse | Exportar de `parser.c` (hoy `static`): `parser_error` (`:63`), `advance` (`:106`), `check` (`:111`), `match` (`:115`), `expect`, `optional_semi` (`:168`) — es decir, crear `parser_internal.h` (mismo nombre que ya prescribe CONSTRUCT_REGISTRY §7) o mover `struct Parser` a `priv.h`; **+1 despacho** en `parse_statement` (`parser.c:1772`) con fallback `spec->parse ? … : switch` | shared-contract change; toca el fichero más caliente |
| check | Exponer `struct TypeChecker` (hoy privado en `typechecker.c:350`) y `tc_error` (`:686`, `static`) en `priv.h`; `type_new` ya es externo (`:10`) | 2 exportaciones + despacho en el `switch` de `typechecker.c:3316` |
| emit | Exportar `emit_inst` (`:166`), `emit_inst_offset`, `add_constant` (`:240`), `patch_push` (`:711`) — todos `static`. `struct Emitter` y `LoopPatch` **ya** están en `priv.h:121-164` (buen dato: la mitad del contrato ya existe) | 4 exportaciones + despacho en `emitter.c:1226` |
| registry | Poner `.phases = CONSTRUCT_ALL_PHASES` y los tres punteros; el self-check ya valida bit⇔hook (invariante 7) | 1 línea |
| gate | `make debug` (ASan/UBSan/LSan) + 260 tests + `dump_parity` (sin cambios de dump) | rojo si un despacho se desequilibra |

Estimación honesta: **~150–250 líneas en 5–6 ficheros, cero cambio de
comportamiento observable**, y deja `migrated: 1 / 47` con 46 `NULL` (dos
caminos de código por despacho hasta el fin de la migración). Coste marginal
bajo para constructos de sentencia; **imposible sin rediseñar `construct.h`**
para los ~20 led/tipo/patrón.

### 3.3 Opción B — declararlo índice documental (parches de texto)

**Diff `seed/src/constructs/construct.h` (cabecera, `:9-17`):**

```diff
  * grammar position, its dependencies on sub-constructs, the EBNF
- * production it implements and the research report that specifies
- * it — plus, as they are migrated, its parse / check / emit hooks.
+ * production it implements and the research report that specifies
+ * it. The `parse / check / emit` hooks and the `phases` bits are
+ * **aspirational, not wired** (decision of 2026-09-21, recorded in
+ * Documentacion/01_lenguaje/CONSTRUCT_REGISTRY.md §8): no phase
+ * dispatches through this table — parser.c, typechecker.c and
+ * emitter.c keep their own switches. The only consumer of the
+ * hooks today is the self-check itself.
  *
- * The registry is the single source of truth. Nothing about a
- * construct may live outside its own file; the self-check fails
- * the build if the registry and the rest of the compiler drift
- * apart (unknown deps, orphan sub-constructs, a keyword that the
- * lexer does not produce, a hook without its phase bit, ...).
+ * The registry IS the single source of truth for construct *metadata*
+ * (keyword, token, node kind, positions, deps, EBNF, research pointer).
+ * Nothing about a construct may live outside its own file; the self-check
+ * fails the build if the registry and the rest of the compiler drift
+ * apart (unknown deps, orphan sub-constructs, a keyword that the lexer
+ * does not produce, a hook without its phase bit, an operator row whose
+ * binding power differs from the parser's table, ...).
```

**Diff `AGENTS.md` (fila de la tabla `:395` y párrafo `:404-408`):**

```diff
-| **one construct** | a single `constructs/<name>.c` | `--check-constructs` + conformance |
+| **one construct** | a single `constructs/<name>.c` — **metadata only** (keyword/token/node/EBNF/research/note); the `parse/check/emit` hooks are aspirational, see §3 below | `--check-constructs` + conformance |
 
 The construct workstreams are the finest-grained split: 47 constructs (one
 file per grammar production), so several can run at once. They have exactly
 one shared contract — `constructs/construct.h` — and the self-check is the
 arbiter: if two of them claim the same node kind, token or keyword,
 `--check-constructs` fails the suite before anything is compiled.
+
+**Scope of a construct workstream (decision 2026-09-21, `CONSTRUCT_REGISTRY.md` §8).**
+The registry is **documental + validated**, not a migration plan:
+`parser.c`, `typechecker.c` and `emitter.c` dispatch on their own `switch`es
+and never consult the table, so a construct PR edits *metadata* only and must
+not claim to "migrate" a phase. `--check-constructs` reporting
+`migrated (all three phases): 0 / 47` is a **documented aspiration**, not a
+progress bar; wiring the hooks is a separate project that would first need a
+`ConstructParseFn` redesign (Pratt led forms do not fit the current signature)
+plus a `parser_internal.h` — costed in `Documentacion/07_investigacion/029_process_bootstrap_fixes.md` §3.2.
```

*(Si se prefiere no citar el informe desde `AGENTS.md`, basta con la primera
frase del párrafo; la referencia es opcional.)*

**Diff menor `constructs/construct.c` (`:303`)** — opcional, **con acoplamiento**:

```diff
-    report(&r, "migrated (all three phases): %zu / %zu\n", migrated, astra_construct_count);
+    report(&r, "migrated (all three phases): %zu / %zu (hooks aspirational — see CONSTRUCT_REGISTRY.md §8)\n",
+           migrated, astra_construct_count);
```

> ⚠️ `seed/tests/run_tests.sh:65` hace `grep -E 'constructs:|migrated'` sobre
> esa salida. Mantener la palabra `migrated` (como arriba) o actualizar el grep
> **en el mismo commit**; si desaparece, el gate sigue en verde por la rama
> `constructs:` pero se pierde la cifra del resumen.

### 3.4 Recomendación: **opción B** (una sola)

Justificación (coste de mantener la ficción vs coste del wire):

1. **La decisión ya está tomada y documentada con investigación delante**
   (`CONSTRUCT_REGISTRY.md` §8, 2026-09-21, con `research/002` §2.3.1
   anti-over-engineering). Elegir A hoy **revertiría una decisión escrita** sin
   aportar un solo comportamiento nuevo — exactamente el problema de proceso
   que denuncia `research/025` §5.1.
2. **A no puede llegar a 47/47**: la firma `Node *(*)(Parser*, SrcLoc)` no
   expresa los led de Pratt (`call`, `binary_op`, `index`, `field_access`,
   `assign`, `range`) ni los despachos de `type`/`pattern`. Llegar ahí exige
   rediseñar `construct.h` (un segundo typedef led + dos despachos nuevos),
   no «wirear».
3. **El wire cuesta tocar los tres ficheros más calientes** del compilador
   (`parser.c`, `typechecker.c`, `emitter.c`) con exportación de helpers
   `static` y **cero cambio observable** — mientras el P0 de `research/025` §5
   (cuatro decisiones de runtime sin congelar) sigue abierto. El coste de
   mantener la ficción es un párrafo en `construct.h` y `AGENTS.md`; el coste
   del wire es riesgo sobre el invariante de pila del emisor con recompensa 0.
4. **B ya es casi verdad**: el registro aporta 14 invariantes verificados en
   cada `make test`, trazabilidad gramática→reporte y 7 desviaciones
   investigación↔código (§4-§5 de `CONSTRUCT_REGISTRY.md`) — es un gate real,
   solo que de *coherencia de metadatos*, no de migración.

**Si en el futuro se elige A** (requiere una entrada `DEC-NNN` que revoque la
§8), el diseño del piloto, por ser el más barato de punta a punta:

- **Constructo piloto: `continue`** (no `literal` ni `ident`): es `LEAD`,
  `CONSTRUCT_STMT`, sin `deps`, nodo único `NODE_CONTINUE`, parse de 6 líneas
  (`parser.c:1837-1843`), check trivial (`typecheck_continue` → `TYPE_VOID`,
  `typechecker.c:2400`) y emit autocontenido (15 líneas, `emitter.c:2199-2214`,
  parcheo de `LoopPatch`). *Contra-indicación de `literal`/`ident`*: su fase
  `check` arrastra literales polimórficos y resolución de símbolos.
- Ficheros: `constructs/continue.c` (3 hooks + `.phases = CONSTRUCT_ALL_PHASES`),
  `parser_internal.h` nuevo (exporta `advance/check/match/expect/optional_semi/
  parser_error`), `priv.h` (+`struct TypeChecker`, `tc_error`), `emitter.c`
  (+`emit_inst/emit_inst_offset/add_constant/patch_push`), 3 despachos con
  fallback `spec->X ? spec->X(...) : <switch actual>` (los 46 restantes siguen
  por `switch`), `driver.c:345` **no** cambia (los node kinds no cambian).
- Gate: `make debug && ./tests/run_tests.sh` (260/0), `--check-constructs`
  → `migrated: 1 / 47`, `dump_parity.sh` → 147/0, y **ningún** test nuevo
  (cambio comportamentalmente neutro — si hace falta un test nuevo, el wire
  cambió comportamiento y hay que parar).
- Siguiente paso si el piloto verde: `if`/`else`, el par que ya recomienda
  `CONSTRUCT_REGISTRY.md` §7 (donde el parcheo de `JUMP_IF_FALSE` ya se
  equivocó una vez).

---

## 4. Mecanismo de decisiones + reglas de proceso (textos exactos)

### 4.1 Registro de decisiones: archivo y formato

- **Archivo nuevo**: `Documentacion/01_lenguaje/DECISIONES.md` (ES, como
  `ARCHITECTURE.md` y `PHILOSOPHY.md` de esa carpeta). No existe hoy ningún
  `DECISIONS*`/`ADR*` en el repo **[verificado con glob]**; el precedente más
  cercano ya en uso son los títulos «decisión del 2026-09-21» de
  `ARCHITECTURE.md` §2.5 y `CONSTRUCT_REGISTRY.md` §8 — **el registro nuevo es
  el índice, `ARCHITECTURE.md` sigue siendo el texto normativo.**
- **Formato**: ADR-lite de una tabla + entradas (no un ADR por fichero: con
  40k líneas de doc el coste por decisión debe ser ~10 líneas).

```markdown
# DECISIONES — registro de decisiones de lenguaje

> **Alcance**: única fuente de verdad de *qué* está decidido sobre el lenguaje
> (semántica, layout, diagnósticos, alcance, memoria). La especificación
> normativa sigue en `ARCHITECTURE.md`; aquí se registra qué se decidió, cuándo,
> por qué, con qué coste y **qué test lo fija**. Creado: 2026-10-27.
> Mantenimiento: §4.2 de `Documentacion/07_investigacion/029_process_bootstrap_fixes.md`.

| ID | Decisión (una frase) | Estado | Fecha | Evidencia |
|:---|:---------------------|:-------|:------|:----------|
| DEC-001 | `let b = a` comparte el handle; no copia | Aceptada (test-pinned) | 2026-09-21 | `seed/tests/conformance/arrays/alias_write.astra` |
| DEC-002 | El seed no migra los hooks `parse/check/emit`; registro declarativo | Aceptada (doc) | 2026-09-21 | `CONSTRUCT_REGISTRY.md` §8 |
| … | … | … | … | … |

### DEC-NNN — <título>
- **Estado**: Propuesta · Aceptada (test-pinned) · Aceptada (doc) · Rechazada · Superseded por DEC-MMM
- **Fecha**: YYYY-MM-DD
- **Decisión**: una frase normativa.
- **Alternativas consideradas**: (y por qué no)
- **Coste aceptado**: qué se pierde o se paga con ella
- **Evidencia**: comando + cifra, o `seed/tests/conformance/...`
- **Spec**: `ARCHITECTURE.md §Y` | «pendiente de escribir en ARCHITECTURE»
```

- **Backfill inicial** (registra lo que ya está decidido *de facto*, sin cambiar
  comportamiento): DEC-001 aliasing (`ARCHITECTURE` §2.5), DEC-002 hooks
  (`CONSTRUCT_REGISTRY` §8), DEC-003 separador `.` de rutas de módulo
  (`ui/use_colon_colon.astra`), DEC-004 closures capturan por valor
  (`AGENTS.md` codegen), DEC-005 slot 0 = callee/return, DEC-006 todo es `i64`
  en runtime y la anotación no trunca (**Propuesta**, `research/025` §2.8),
  DEC-007 overflow = wrap silencioso (**Propuesta**), DEC-008 scope de variantes
  de enums (**Propuesta**), DEC-009 el seed no libera memoria (arena,
  `research/002` §5.3), DEC-010 impresión de floats `%g`, DEC-011 sentencias
  terminadas por `;`/newline.
- **Registro en `INDICE.md`**: añadir fila en §1 (y a la tabla de estructura
  `01_lenguaje/` → 5 documentos).

### 4.2 Regla (a) — «toda feature nueva viene con su decisión» → pegar en `AGENTS.md`

Insertar como sección propia tras `## Invariants to preserve`:

```markdown
## Language decisions — `Documentacion/01_lenguaje/DECISIONES.md`

1. **Nothing lands without a decision.** Any PR that adds, changes or rejects a
   language behaviour (new construct, semantics, diagnostic, layout, memory
   rule, accepted rejection) must add an entry `DEC-NNN` to
   `Documentacion/01_lenguaje/DECISIONES.md` **in the same PR**, with the
   conformance test that pins it. A `feat` PR with no `DEC-NNN` is rejected in
   review — this is a review rule, not a CI rule (CI cannot judge intent).
2. **Decisions that already exist as tests are recorded, not re-litigated.**
   If behaviour is pinned by a test (e.g. `arrays/alias_write.astra`), the entry
   is `Estado: Aceptada (test-pinned)` and cites the test. Registering a
   decision never changes behaviour, so it never needs a feature gate.
3. **Status lives in exactly one place.** The only file where a roadmap item may
   be marked done is the table «Estado del proyecto» in
   `Documentacion/00_indice/INDICE.md`. `README.md` §Roadmap and
   `ARCHITECTURE.md` §41 mirror that table and cite the gate command + figure;
   they are never edited to flip a state on their own.
4. **Three states, never a bare `[x]`.** Every roadmap row is one of
   `Specified` (doc only) · `Implemented` (code exists, not gated) ·
   `Verified` (gate executed; command + number pasted in the PR's
   «Evidencia de verificación»).
5. **Open decisions block backends.** While a `DEC-NNN` needed by a feature is
   in state `Propuesta`, no new backend work may be merged that would have to
   encode it (today: DEC-006..DEC-008, `research/025` §2.8 — integer width,
   `let`/alias semantics, enum-variant scoping; they reach 7 routes: VM seed,
   C backend, VM Zig, LLVM ×`--opt-level`, JIT, wasm, aarch64).
```

### 4.3 Regla (c) — presupuesto de commits → pegar en `AGENTS.md`

````markdown
## Commit budget — decisions vs. backends

Measured **per work cycle** (a cycle = one milestone / PR series), by path, not
by commit prefix:

```bash
INI=2026-10-27                                   # cycle start
CODE=$(git log --format=%H --since=$INI -- seed/src zig/src | sort -u | wc -l)
DEC=$(git log --format=%H --since=$INI -- Documentacion/01_lenguaje/DECISIONES.md | sort -u | wc -l)
# rule: DEC * 5 >= CODE   (>= 20 % of code commits are paid for by a decision commit)
```

- A cycle with `CODE > 0` and `DEC == 0` **cannot close**: paste both numbers in
  the closing PR's «Evidencia de verificación».
- **No two consecutive backend cycles** (LLVM / parity / wasm / cross). The
  cycle after a backend cycle starts in `DECISIONES.md`, not in `src/`.
- Baseline 2026-09-16 → 2026-10-27 **[verificado]**: `CODE = 135`,
  `DEC = 0` (el archivo no existe), `llvm|parity = 73/234` (31 %),
  `docs+test = 85/234` (36 %). La regla existe para romper ese 135:0; el
  backfill de §4.1 (≈11 entradas) se cuenta como **un solo** commit de
  arranque, no como ciclo.
````

**Por qué es cumplible**: (i) es **medible por path** con un comando de una
línea, sin interpretar mensajes; (ii) se pega en la evidencia del PR que cierra
el ciclo (la plantilla ya lo pide); (iii) **no** se propone como *required
status check* — añadir un contexto a los rulesets exige editar los rulesets y
bloquearía todos los merges si el job está mal (riesgo §5); se empieza como
checkbox + regla de revisión y se reevalúa tras dos ciclos.

### 4.4 Regla (b) — ajustes en flujos existentes

**`.github/PULL_REQUEST_TEMPLATE.md`, checkbox nuevo en «Checklist»:**

```markdown
- [ ] **Decisión registrada**: si el cambio toca comportamiento del lenguaje,
      este PR añade su `DEC-NNN` en `Documentacion/01_lenguaje/DECISIONES.md`
      (o amplía uno existente) con el test que lo fija.
- [ ] **Estado en un solo sitio**: si el PR cambia el estado de un ítem del
      roadmap, cambia la tabla «Estado del proyecto» de
      `Documentacion/00_indice/INDICE.md` **en el mismo PR** y pega comando +
      cifra en «Evidencia de verificación».
```

**`INDICE.md` §«Cómo mantener este índice»** — precisar el checklist (hoy
pide actualizar `index.html`, `CHANGELOG.md` y `.agents/skills/*/SKILL.md`, pero
**ninguno enumera informes** **[verificado: `grep -c "025"` → 0 en `index.html`
y en `.agents/skills/*/SKILL.md`; en `CHANGELOG.md` solo aparece el recuento
fechado `001–024` de la entrada del reordenamiento, `:366`]**):

```diff
-- **Al añadir o mover un documento**: añadir su fila aquí y corregir las
-  referencias en los puntos de entrada: `README.md`, `AGENTS.md`,
-  `CHANGELOG.md`, `index.html`, `.github/PULL_REQUEST_TEMPLATE.md`,
-  `.agents/skills/*/SKILL.md` y los comentarios en
-  `seed/src/constructs/{assign,type_annotation}.c`.
+- **Al añadir o mover un documento**: añadir su fila aquí; corregir los
+  contadores *actuales* que citan el número de informes (`README.md:91` y
+  `:115`) y las referencias en `AGENTS.md` si el documento cambia una regla de
+  flujo. No hace falta tocar `index.html` ni `.agents/skills/*` para un
+  informe nuevo: ninguno enumera informes (verificado 2026-10-27). `CHANGELOG.md`
+  solo cita el recuento en la entrada fechada del reordenamiento (`:366`,
+  «informes 001–024»): es registro histórico y no se reescribe.
```

---

## 5. Checklist de verificación y riesgos

### 5.1 Comandos que confirman que los parches no rompen nada

```bash
cd /home/aster/Astra

# --- A. parches de texto de constructs (§3.3) ---
./seed/astra-seed --check-constructs        # exit 0; "OK — registry, lexer, parser and operator table agree"
                                            # (si se reescribe construct.c: mantener la palabra "migrated")
cd seed && make test                        # 260 passed, 0 failed  [ejecutado hoy: verde]
cd seed && make debug && ./tests/run_tests.sh   # ASan+UBSan+LSan, mismo gate

# --- B. parches de COMPILER_STRATEGY (§1) y README (§2): solo texto ---
grep -n "astra-v0\|zig-compiler.zig" Documentacion/02_compilador/COMPILER_STRATEGY.md   # debe quedar vacío
grep -n "must compile the Zig" Documentacion/02_compilador/COMPILER_STRATEGY.md         # debe quedar vacío
grep -n "\[x\] Memory model\|\[x\] Concurrency model" README.md                         # debe quedar vacío
grep -n "001–024\|24 files\|24 deep-dive" README.md                                     # debe quedar vacío
ls Documentacion/07_investigacion/*.md | wc -l    # número real a escribir en README:91/:115

# --- C. gates que siguen en verde por construcción (sin cambios de código) ---
cd zig && zig build test                    # 73/73  [ejecutado hoy: verde]
./zig/tests/dump_parity.sh                  # 147 files, 0 divergent  [ejecutado hoy: verde]
./zig/tests/llvm_parity.sh                  # 159/159  [citado de CI; correrlo si el PR toca zig/]
./seed/astra-seed --dump-tokens <f> | ./zig-out/bin/astra-zig --dump-tokens <f> | diff -  # ya cubierto por dump_parity

# --- D. proceso (§4) ---
grep -c "^| DEC-" Documentacion/01_lenguaje/DECISIONES.md   # >= 1 tras el backfill
git log --show-signature -1                                # commit firmado (SSH, reglas de main)
gh pr checks --watch                                       # seed / zig / parity + CodeQL en verde
```

**Ninguno de los parches propuestos toca `seed/src` ni `zig/src`** (salvo, opcional,
el `report()` de `construct.c`), así que A/B/C deben quedar **idénticos** a hoy.

### 5.2 Riesgos

| Riesgo | Impacto | Mitigación |
|:-------|:--------|:-----------|
| Un PR de docs **sigue ejecutando** los 3 checks requeridos (`seed (C)…`, `zig (Phase 2)…`, `dump parity…`) | bajo: están en verde hoy | no hace falta nada; esperar `gh pr checks --watch` |
| Cambiar el texto de `construct.c:303` | **acoplamiento real**: `run_tests.sh:65` hace `grep -E 'constructs:\|migrated'` | mantener la palabra `migrated` (diff de §3.3) o tocar el grep **en el mismo commit** |
| Cambiar comentarios de `construct.h` | ninguno: el self-check no valida comentarios | reejecutar `--check-constructs` por si un `#define` se toca |
| Editar `parser.c`/`typechecker.c`/`emitter.c` (opción A) | gates: ASan, 260 tests, dump parity, y riesgo sobre el invariante de pila del emisor | no aplica — se recomienda B; si se hace A, rama aparte y `make debug` primero |
| Añadir un **nuevo required status check** para el registro de decisiones | rompería todos los merges si el job no corre en algún PR (rulesets exigen el contexto) | **no proponerlo**; checkbox + regla de revisión (§4.3) |
| Reglas de repo: commits firmados, PR con 1 review, admin bypass | ninguno: los cambios son docs/tests, entran por PR normal | `git commit` firma solo; nunca `--no-verify`; `gh pr merge --admin --squash` |
| `INDICE.md` desactualizado tras añadir este informe | el propio `INDICE.md:122-126` exige actualizarlo al añadir documentos | añadir la fila de `029` y subir el contador: el `INDICE.md` del árbol de trabajo (sin commitear) dice `001–025 / 25`, pero hoy hay **29** ficheros (`026`–`029` escritos en paralelo) → en el PR integrador, `001–029 / 29` + las cuatro filas |
| README `:91/:115` citan `001–024 (24 files)` (hoy hay **25**) | cifra falsa | calcular con `ls … \| wc -l` en el mismo PR (§5.1) |
| `ARCHITECTURE.md` §41 se edita en el mismo PR | es spec; cualquier cambio requiere evidencia | parche de reetiquetado de §2.4 (no borra contenido) |

**Conclusión de riesgo**: los cinco parches son de documentación y proceso;
el único punto con acoplamiento a código es la cadena
`construct.c ↔ run_tests.sh`, resuelta con la opción conservadora del diff de
§3.3.

---

## Verificación externa (2026-10-27)

Este informe no tiene afirmaciones web: sus marcadores proceden de otros
documentos del repo. `websearch` seguía con HTTP 403; no hizo falta.

- Único **[citado]** externo: la fila `:122` («`llvm_cross.sh` /
  `llvm_wasm.sh` 159/159») **sigue [citado]** — es lo que afirman `AGENTS.md`
  (sección LLVM, M5) y `ci.yml` (jobs `llvm-cross`, `llvm-wasm`), pero **no se
  re-ejecutaron en esta sesión**: exigen `gcc-aarch64-linux-gnu` +
  `qemu-user-static`, sysroot wasi-libc con `<setjmp.h>` y Node ≥ 22.
- El resto de marcadores [verificado] de este informe son salidas de comandos
  ejecutados en la propia sesión (§ «Comandos ejecutados») y no cambian.
- Ningún otro texto de este documento se modificó.
