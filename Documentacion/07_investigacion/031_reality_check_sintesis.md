# 031 — Reality check de las recomendaciones 026–030 antes de su ratificación

> **Alcance**: revisión crítica (sin ratificar) de los informes de investigación
> `026`–`030` y de la sección **Benchmarks** nueva del `README.md`, contra el
> código y los gates reales del repo. **No se modifica ningún informe 026–030,
> ningún código de producción ni ningún test; no se hace ningún commit.** Único
> fichero nuevo: este `.md`. Fecha: **2026-10-27**. **[verificado]** = ejecutado
> o leído en esta sesión (Debian, HEAD `6e0954d`, árbol sin commitear: solo
> `README.md` y `INDICE.md` modificados + `025`–`030` y `030_benchmarks_suite/`
> sin trackear — `git status --porcelain` **[verificado]**, ningún `seed/src`
> ni `zig/src` tocado).

## Reality-check ejecutado (todo **[verificado]**)

| Comando | Salida |
|:--------|:-------|
| `cd seed && make test` | `passed: 260  failed: 0` |
| `./seed/astra-seed --check-constructs` | `47 constructs / migrated: 0 / 47 / 27 operators / OK` |
| `./zig/tests/dump_parity.sh` | `147 files, 0 divergent` |
| `cd zig && zig build test --summary all` | `73/73 tests passed` |
| `./zig/tests/llvm_parity.sh` | `total=159 ok=159 skip=0 excl=0 fail=0 opt=0` |
| `./seed/tests/sweep_emit_c.sh` | `total=113 skip=3 fail=0` |
| `git log --oneline \| wc -l` / `grep -icE "llvm\|parity"` | `234` / `73` |
| `git log -- seed/src zig/src` / `-- seed/tests/conformance` (únicos) | `135` / `66` |
| `git log --format=%s \| grep -cE "^(docs\|test)(\(|:)"` (baseline 029 §4.3) | `85` |
| `find Documentacion -name "*.md" \| xargs wc -l \| tail -1` | `44.261` (029 citaba 41.141) |
| `ls Documentacion/07_investigacion/*.md \| wc -l` | `30` |
| Repro: `int_width.astra` / `alias_struct.astra` / `alias_write.astra` | `9999999999 · -1 · 2147483648 · -9223372036854775808` / `5` / `99 99` |
| Repro: `enum_use.astra` (seed) · `enum_qualified.astra` | `6 errores, rc=1` · `cannot call non-function type enum` |
| Repro: seed `loop_alloc.astra` (VmHWM muestreado) | **407.828 KB** (~400 MB, coincide con 025/027/030) |
| Repro: `len`/`s[0]`/`print(1,2)` | `undefined variable 'len'` · `cannot index non-array type string` · `expected 1 arguments, got 2` |
| Repro: `go run -race go_race.go` · `rustc rust_move.rs` / `rust_borrow.rs` | `WARNING: DATA RACE` · `E0382` · `E0499` (026 §1/§2) |
| Repro: `results.json` + `results_extra.json` vs tablas README/030 | ver §2 |
| Rebuild `030_benchmarks_suite/build_all.sh` → tamaños | ver §2.9 |
| Anclas al azar de 026/027/028/029 (`vm.c:1212`, `codegen.c:1146`, `typechecker.c:611/1336/1617/1900`, `emitter.zig:4339/2906/3069`, `astra_runtime_llvm.c:23/43/224`, `vm.c:1402-1409/1717`, `construct.c:303`, `construct.h:78`, `parser.c:411/2169-2182`, `run_tests.sh:65`, `COMPILER_STRATEGY:599-600/303/616/626/64`) | todos correctos (path de `astra.h` mal en 026, ver §1-P14) |

---

## §0 Veredicto global

**Veredicto: NEEDS WORK — los cinco informes son sólidos y en su mayoría
reproducibles, pero ninguno debe ratificarse «en bloque»: `026-F` tiene dos
bloqueos de coherencia con `027` y dos huecos de especificación, `029-README`
tiene referencias caducadas por la sección Benchmarks, y `030-gates` tiene una
celda numérica irreproducible, una autocontradicción con `027-Rec3` y una
propuesta que ya existe en el repo; el resto se aprueba con las correcciones de
§2 y la secuencia de §3.**

| Recomendación | Veredicto | Evidencia en una línea |
|:--------------|:----------|:-----------------------|
| **026-F** (regla de cruce con unicidad) | **NEEDS WORK** | Modelo verificado en anclas y en ejecución (Go `-race`, rustc E0382/E0499, `alias_write` intacto), pero: RT1 asignado a M3 sin rc (026:423) chocando con 027-Rec3 (027:400), sintaxis de `transfer` sin decidir (026:554) y Fase 0 descrita incompleta (026:553 vs 026:616/647) |
| **026-v1** (constructo `transfer` + S1/S2/S3 + `.copy()` ×4 motores) | **NEEDS WORK** | Plan de gates correcto (026:554-555) pero **cero estimación de esfuerzo**, sin decisión keyword-vs-builtin (invariante 6 de AGENTS.md) y sin entrada en el registro de constructs |
| **027-Rec1** (enteros: error compile-time + wrap) | **APPROVED** | Salidas reproducidas en las 5 rutas ejecutables; `integer_widths.astra` solo usa literales en rango (leído) ⇒ «rompe 0 tests» sostenible; baseline 260/0 y 159/159 re-ejecutados |
| **027-Rec2** (aliasing: mantener handle compartido) | **APPROVED** | 0 líneas de runtime; `alias_write` → `99/99` re-ejecutado y coherente con 026-R1; los 3 fixtures citados existen y fijan el contrato |
| **027-Rec3** (memoria: divergencia + gate RSS) | **APPROVED** (con corrección de redacción obligatoria) | Divergencia re-meditida (seed 407.828 KB; LLVM acotado; `free(`/`malloc` en `vm.c` = 0); `zig/tests/llvm_mem.sh` **no existe** aún; **030 §0.3/§5.2.2 lo contradice** (§1-P5) |
| **027-Rec4** (enums: construcción calificada) | **APPROVED** | Lista de rotura reproducida al detalle: 12 conformance + 5 codegen + 5 fixtures LLVM + 2 unit + 1 generador (grep propio idéntico); la forma calificada falla hoy (`cannot call non-function type enum`, ejecutado) |
| **028-MVP** (len, `s[i]`, `read_file`, `to_string`) | **APPROVED** | `OPCODE_LEN` acepta string en los 3 handlers (leído `vm.c:1164`/`codegen.c:1129`/`vm.zig:1083`); `print` único builtin (leído `typechecker.c:611`, despacho único a `builtin_print`); `preopens` ausente en `demo/wasi_run.mjs` (grep → 0) |
| **028-PRs** (plan de 4 PRs + gates) | **APPROVED** (condicionado) | Tabla de gates correcta (sweep 113/3/0 re-ejecutado; `conformance.zig:1-15` lo dice literal); condiciones: `DEC-NNN` por PR (029), recomputar el total `159` que subirá, `preopens` en PR2 |
| **029-B** (registro → índice documental) | **APPROVED** | La decisión ya está escrita (`CONSTRUCT_REGISTRY.md:268-270`, §8, 2026-09-21); diffs solo de comentario; acoplamiento `construct.c:303 ↔ run_tests.sh:65` verificado y ya mitigado en el diff conservador |
| **029-DECISIONES.md** (ADR-lite + reglas) | **APPROVED** | No existe ningún `DECISIONES*`/`ADR*` (ls → no existe); baseline `CODE=135`, `DEC=0`, `docs+test=85/234` verificada; el backfill coincide con tests pinned |
| **029-README** (Status + Roadmap tres estados + conteos) | **NEEDS WORK** | Referencias caducadas por la sección Benchmarks: `:118-136`→**171-189**, `:124/:125`→**177/178**, `:134`→**187**; `README:91` sigue diciendo `001–024 (24 files)` mientras `README:115` ya dice 30; y `README:19` sigue negando el backend LLVM que la propia sección Benchmarks usa |
| **029-CS** (patch de `COMPILER_STRATEGY` §7.1/§4.7) | **APPROVED** | Paso imposible verificado en `COMPILER_STRATEGY.md:599-600` (`./astra-v0 bootstrap/zig-compiler.zig`) más `:303`, `:616`, `:626`; parche solo-texto, gates intactos |
| **030-gates** (campaña → gate con umbrales) | **NEEDS WORK** | Tablas del README coinciden con `results*.json` salvo celdas de §2; `results.json` arrastra una celda obsoleta de C; §5.2.2 contradice 027-Rec3; §5.2.4 propone crear `zig/tests/llvm_bench.sh` **que ya existe** (`AGENTS.md:153,230`) |

---

## §1 Problemas concretos, por severidad (los que bloquean la ratificación, primero)

### Bloqueantes

1. **RT1 necesita rc en el VM Zig, que 027-Rec3 decide no construir.**
   `026:423` (fila RT1) y `026:103` asignan el walk `rc==1` a **M3 y M4**, y
   `026:555` lo declara gate de la primera frontera real; pero M3
   (`zig/src/vm/`) es arena sin liberar hoy (027 §3.1: 712 MB medidos; yo
   reproduce ~400 MB en seed), y `027:400` (opción 3A, la recomendada) dice
   documentar la divergencia **en vez de** portar ARC a los VMs (3B = ALTA, no
   recomendada). Ninguno de los dos informes reconcilia esto: **RT1@M3 depende
   de una decisión (ARC en `vm.zig`) que 027 declina tomar ahora.**
   → Resolver con una entrada `DEC-NNN` explícita: RT1 vive en M4 (que ya
   tiene rc) hasta que una decisión posterior añada rc al VM Zig; o 027-Rec3 se
   declara temporal para M3. *Sin esto, 026-F no se ratifica.*

2. **`026` no decide la sintaxis de `transfer` (keyword vs builtin).**
   `026:554` habla de «el constructo `transfer`» y de «nuevo opcode», pero en
   778 líneas no fija si es palabra clave (⇒ fichero
   `constructs/transfer.c` + fila en el registro, invariante 6 de AGENTS.md:
   *«a construct's keyword must lex to the token it declares»*) ni si es un
   builtin (⇒ sin registro, pero entonces cambia el dispatch de builtins que
   028 acaba de mapear). Sus gates (`026:554`) no nombran `--check-constructs`
   (lo cubre `make test` de forma implícita, `run_tests.sh:64-66`), pero la
   decisión de sintaxis es previa a cualquier planificación de S1/S2.
   → Exige `DEC-NNN` de sintaxis + fila de registro antes de estimar v1.

3. **El README está incoherente consigo mismo y `029-README` apunta a líneas
   que ya no existen.**
   - `README.md:19` (Status) dice que el backend LLVM *«does not exist yet»*
     mientras `README.md:187` lo marca `[x] 159/159` y la sección
     `README.md:118-169` (Benchmarks, sin commitear) presenta sus números.
   - `README.md:91` (Project Structure) dice `001–024 (24 files)`; hay **30**
     ficheros (`ls … | wc -l`); `README.md:115` ya fue actualizada a `001–030`
     en el mismo árbol de trabajo ⇒ **el propio README se contradice entre dos
     líneas**.
   - `029:38-40`, `029:232`, `029:250`, `029:252`, `029:706` citan
     `:118-136` / `:124` / `:125` / `:134` / `:115`; hoy son
     **`:171-189` / `:177` / `:178` / `:187` / ya corregida**. Aplicar el diff
     de `029` literalmente fallaría o dejaría los `[x]` falsos.
   → `029-README` se aprueba solo tras re-mapear referencias y fusionar con el
   Paso 2 de 026 (punto 4) en **un único PR de README**.

4. **`026` Paso 2 (README) es más débil que `029` y dejaría un `[x]` falso.**
   `026:604-609` solo desmarca `fiber-aware` y pone `:125` en `[ ]`, dejando
   `[x] Memory model (ARC/ORC, cycle detection)` (`README.md:177`) — y **no
   existe ningún colector de ciclos ARC/ORC en `seed/src` ni `zig/src`** (los
   `cycle` encontrados son detección de ciclos de imports de módulos
   `zig/src/modules/modules.zig:356-427` y un comentario del parser
   `parser.c:875`; `grep -riE "cycle detect|collectCycles"` → 0 reales
   **[verificado]**); el rc solo existe en la ruta LLVM (M4.e). `029:298`
   (fila tres estados «Specified — not implemented») es la versión correcta.
   → **Rechazar el Paso 2 de 026 tal cual**; adoptar la fila de 029 y añadirle
   la fila de Design Goals que 026 sí aporta («Fiber Ownership Enforcement —
   §2.6»).

5. **`030` y el README tratan la liberación de memoria de los VMs como
   «trabajo pendiente», citando 027-Rec3 — que decide lo contrario.**
   `030:26` («*falta crear la liberación de memoria en los VMs* (decisión #3
   de research/027)»), `030:241` y `030:251` («priorizarla» = opción 3B) chocan
   con `027:400`/§0-Rec3 (divergencia **documentada y aceptada** + gate RSS;
   3B explícitamente «ALTA, no recomendada hoy»). El README repite el error:
   `README.md:125` («open "decision #3"») y `README.md:162`
   («that work is pending»). 027-Rec3 ya está *decidida*; lo que queda abierto
   es solo si algún día se porta ARC a los VMs (eso sí es `DEC` pendiente).
   → Redactar 030 §0.3/§5.1/§5.2.2 y README:125/162 como «divergencia
   documentada (027-Rec3A); portar ARC a los VMs = decisión futura `DEC-NNN`».

### Altos

6. **`030:257` propone crear algo que ya existe**: «volverla
   `zig/tests/llvm_bench.sh` con umbrales (como ya existe `llvm_parity.sh`)» —
   `zig/tests/llvm_bench.sh` existe desde 2026-10-20 y está documentado como
   gate en `AGENTS.md:153` y `:230` (hoy: solo Astra VM/C/LLVM, sin
   lenguajes externos y **sin umbrales**: «the table is informational, the exit
   status is the correctness gate»). La campaña cruzada debe **extender** ese
   script, no recrearlo; si se crea otro paralelo, habrá dos fuentes de
   benchmarks (exactamente el bug de proceso que 029 denuncia).

7. **`029` regla 5 («open decisions block backends») bloquea a 028 si se
   ratifica sin ajuste.** `029:583-587` prohíbe fusionar trabajo de backend
   mientras `DEC-006..008` estén en `Propuesta`; los PR1–PR4 de 028 tocan
   `emitter.zig`/`astra_runtime_llvm.c` (backend LLVM) y `to_string(i: i64)`
   codifica «runtime = i64» (DEC-006/007). O se ratifican Rec1 y Rec4 **antes**
   de 028 (secuencia §3), o la regla 5 se acota a «decisiones que la feature
   codifica *de verdad*». Sin matizar, la regla es inaplicable tal como está
   escrita.

8. **La Fase 0 de 026 no es toda la Fase 0.** `026:553` (fila «0 — hoy»)
   lista ARCHITECTURE + fixes §2.4/§2.5/:31/:875 + README + invariant AGENTS,
   pero el §4 de 026 añade `026:616-624` (Paso 3: registro en `INDICE.md`) y
   `026:647` (Paso 5: `PHASE2_PROGRESS`, `LLVM_BACKEND_PLAN`,
   `COMPARATIVE_ANALYSIS:131`) — todo documental, todo pendiente. Y **ninguno
   está ejecutado**: `grep -n "^### 2.6\|Enforcement" ARCHITECTURE.md` → 0
   **[verificado]** (§2.6 no existe todavía).

### Medios

9. **Afirmaciones caducadas entre informes** (se escribieron en paralelo):
   `027:262` y `027:589` dicen que «026 no existe» (ya existe);
   `026:623` pide cambiar INDICE «001–025 / 25 → 001–026 / 26» (el árbol ya
   dice **001–030 / 30**, `INDICE.md:25,80`); `029:705` dice «el INDICE dice
   001–025 / 25 y hoy hay 29 ficheros» (hoy: 30, y 31 con este informe);
   `029:706` afirma que `README:91` **y** `:115` citan `001–024` (solo `:91`).
   → Recalcular todos los conteos en el PR integrador (029 ya lo pide
   explícitamente para el suyo: «recalcular en el momento del parche»).

10. **`027:460` «mismos 6 errores, byte idénticos» está sobre-dicho.**
    Diff ejecutado seed↔zig sobre `enum_use.astra`: los **6 diagnósticos son
    idénticos byte a byte**, pero el seed añade la línea resumen
    `error: type check failed with 6 error(s)` que el zig **no** emite ⇒ el
    stderr completo **no** es idéntico. Corregir la frase (la sustancia de la
    decisión no cambia).

11. **Cifras estáticas que 028 hará caducar.** El total `159/159` =
    113 conformance no-UI + 28 `codegen` + 18 fixtures `zig/tests/llvm/*.astra`
    **[verificado contando]**. Cada caso nuevo de 028 sube el total; hoy están
    citadas como constantes en `AGENTS.md` (v. g. «159 cases — 159 ok»),
    `README.md:187` y `README.md:121`, `030:45`, `029` (filas de roadmap) e
    `INDICE.md:119`. El gate es dinámico (bien), la documentación es estática
    (mal) → regla de «contadores se verifican, no se recuerdan» (ya escrita en
    `INDICE.md:138`) debe aplicarse también a README/AGENTS en cada PR.

12. **`026` no estima esfuerzo de v1.** Fase 0 sí es «docs» (barata), pero
    `transfer` + S1/S2/S3 × 2 frontends + `.copy()` × 4 motores + tests UI de
    paridad es el trabajo más grande de todo el lote y **no tiene estimación
    en ninguna parte** (026 habla de costes S/M, no de días). Con 028
    estimando 4-6 d/builtin, un estimador de v1 es requisito para planificar.

13. **Umbrales de tiempo no fiables como gate.** `030:4.4` admite máquina
    compartida (loadavg 0,53→1,46) y CPU móvil 15 W; convertir `min de 5` en
    umbral de CI produciría flakes. Los umbrales **de memoria** sí son
    estables (1,2 MB medido vs techo 128 MB propuesto = 100× de margen);
    los de tiempo deben quedar informativos o usarse razones (×C), no
    absolutos.

### Bajos

14. `026:429` cita `include/astra/astra.h:847`; la ruta real desde la raíz es
    `seed/include/astra/astra.h` (enum de opcodes en `:845`) **[verificado]**.
15. `030:170`/`README.md:159` (tamaños de binario) no están en
    `results*.json` (los binarios están `.gitignore`-ados) — son correctos
    (§2.10) pero «crudos» no los incluye: la reproducibilidad exige
    `build_all.sh` (está documentado en `030:198-204`).
16. `029:451-454` ya reconoce el acoplamiento `construct.c:303` ↔
    `run_tests.sh:65` y su diff conservador lo mitiga — solo exige ejecutar
    `make test` tras aplicarlo (recomendación: mantener la palabra
    `migrated`, como ya dice el diff).

---

## §2 Correcciones numéricas encontradas (valor correcto verificado)

1. **`030:120-121` / `030:125` — «Astra LLVM -O0 184 ms» no existe en los
   datos.** Correcto: `results.json` → `alloc2m/astra_O0` **min 0,1809 s =
   181 ms**, `alloc2m/astra_O2` **0,1803 s = 180 ms**; `results_extra.json` →
   `rss/alloc2m_astra_O0` **0,1904 s = 190 ms**, `…_O2` **0,1841 s = 184 ms**.
   El par «184/184» del informe mezcla: el 184 ms es el **-O2** de
   `results_extra`; para -O0 la cifra correcta es **181 ms** (results) o
   **190 ms** (extra). (La comparación «Astra -O0 vs Rust -O0» sigue siendo
   válida: Rust -O0 = 174,9 ms ✓.)
2. **`030:119` / `README.md:146` — Go «2,0 MB»** → `rss/alloc2m_go` =
   **1.964 KB = 1,92 MB** (redondeo al alza del 4 %; leer 1,9 MB).
3. **`results.json` arrastra una celda obsoleta**: `str25k/c` = **3,1 ms** es
   la versión vieja O(n) de C (realloc amortizado) que `030:82-83` dice haber
   reescrito a O(n²); la cifra final 18,5 ms solo está en
   `results_extra.json` (`time/str25k_c_O2`). Un lector que compare README vs
   `results.json` «encuentra» una discrepancia de 6×. → Regenerar
   `results.json` tras `build_all.sh` o anotar la celda como pre-reescritura.
4. **`029:21` — «41.141 líneas de documentación»** → hoy **44.261**
   **[verificado]** (los informes 026–030 lo superan; recalcular en el PR).
5. **`029:706` / `README.md:91` — «001–024 (24 files)»** → hay **30** ficheros
   hoy (**31** con este `031`); `README.md:115` ya dice 30 ⇒ corregir solo
   `:91` (y `:85-92` del árbol de proyecto).
6. **`026:623` y `029:705` — conteos de `INDICE.md`** → el árbol de trabajo ya
   dice **001–030 / 30** (`INDICE.md:25,80`); «25→26» (026) y «29 ficheros»
   (029) están caducados; con este informe toca **31**.
7. **`029:38-40` — referencias de línea del README** → Status `:19` (sigue
   vigente y sigue falsa), Roadmap `:118-136` → **`:171-189`**, `:124/:125` →
   **`:177/:178`**, `:134` → **`:187`**, `:115` → ya corregida (no necesita
   parche; solo `:91`).
8. **`027:460` — «byte idénticos»** → idénticos los **6** diagnósticos; el
   stderr completo difiere en la línea resumen del seed (diff ejecutado).
9. **Tamaños de binario (030 §3.5 / README:159) — sin datos crudos, pero
   correctos**: reconstruidos con `build_all.sh` **[verificado]**:
   `startup_c` **15.832 B (15,8 KB)** ✓ · `startup_zig` **945.736 B (0,95 MB)**
   ✓ · `startup_rust` **4.529.760 B (4,53 MB)** ✓ · `startup_go`
   **1.563.090 B (1,56 MB)** ✓ · Astra `startup` **23.248–23.328 B
   (23,2–23,3 KB)** ✓ y `23 KB`/`16 KB` del README ✓.
10. **Resto de tablas del README y de 030: sin alteraciones.** Comparadas celda
    a celda con `results.json`/`results_extra.json` **[verificado]**: fib30
    (4,9/7,0/7,2/10,7/41,2/44,6 ms/5,34 s/3,79 s) ✓; B2 RSS (1,2/0,5/1,9/1,2
    MB; 400 MB = 409.588 KB ✓; 712 MB = 729.472 KB ✓) ✓; B3 RSS
    (0,6/1,3/2,1/1,4/20/320/354 MB) ✓; arranque (0,8/0,8/0,7/1,2/1,7 ms y
    medianas 1,1/1,2/1,1/1,6/2,8) ✓; VMs (5,34/3,79 s; 10,3/8,4 s; 332/396 ms;
    64,8 ms) ✓; loadavg 0,53→1,46 ✓; commit `6e0954d` existe ✓; rangos N=5/3/3/20
    ✓; metodología `VmHWM` y descarte de `ru_maxrss` coherente con los
    `rss_kb=12800` planos de `results.json` ✓.
11. **Cifras de 026/027/028/029 sin corrección** (todas reproducidas):
    260/0 · 0/47 · 27 operadores · 73/73 · 147/0 · 159/159 · sweep 113/3/0 ·
    234 commits · 73 `llvm|parity` (31 %) · 135 código · 66 conformance ·
    85 `docs|test` · `free(`/`malloc` en `vm.c` = 0 · `transfer`/`fiber`/
    `spawn`/`"len"` → 0 · `ls bootstrap` no existe · 31 `[x]` en
    `ARCHITECTURE.md` §41 · `query system` → 0 · `CONSTRUCT_REGISTRY.md:268`
    §8 · `run_tests.sh:65` · `construct.h:78` · `parser.c:411` ·
    `COMPILER_STRATEGY.md:599-600` · `astra_runtime_llvm.c:23/43` ·
    `typechecker.c:611/1336` (default `i32`) · `vm.c:1402-1409/1717` ·
    `emitter.zig:4339/2906/3069` · `llvm_parity` 113+28+18 = 159.

---

## §3 Secuencia mínima de implementación recomendada (propuesta propia)

Criterio: **(i) decisiones antes que código** (029 regla (a)), **(ii) un solo
cambio por fichero para no rehacer**, **(iii) barato antes que caro**,
**(iv) nada que dependa de rc hasta que exista rc**.

| Fase | Qué (PRs) | Por qué en este punto |
|:-----|:----------|:----------------------|
| **A — Proceso (docs, 1 PR)** | 029 completo con correcciones: `DECISIONES.md` (backfill DEC-001..011) + reglas (a)/(c) + checkbox de plantilla + **opción B de registry** + patch de `COMPILER_STRATEGY` + **README único** (Status `:19`, Roadmap tres estados de 029, `:91`, fusionando el Paso 2 de 026 con las correcciones §1-P4) + fila `INDICE` | Es el único PR que todos los demás necesitan (028 exige `DEC-NNN`, 026 exige invariant #8, 029-README ya está preparado). Barato, sin comportamiento, gates intactos por construcción (029 §5.1). **Primero** porque cualquier otro orden haría rehacer el README dos veces. |
| **B — Decisiones de frontend (2 PRs)** | 027-**Rec1** (enteros, DEC-006/007 + 2 tests) → 027-**Rec4** (enums calificados, DEC-008 + 17+5+2+1 ficheros) | Rec1 es lo más barato de todo el lote (2 typecheckers, 0 runtimes, 0 tests rotos). Rec4 segundo **antes** de tocar fixtures por memoria (027 §5 lo dice y es correcto: `leaks.astra`/`ownership_*` son gates de Rec3) y **antes** de 028, para que la regla 5 de 029 no bloquee los PRs de backend. |
| **C — Spec de seguridad + contrato (1 PR docs + tests)** | 026 **Fase 0 completo** (ARCHITECTURE §2.6 + §2.4/§2.5/:31/:118/:875 + invariant #8 en AGENTS + `INDICE` + Paso 5 de 026) **+** 027-**Rec2** (DEC-001 ampliado + `alias_let_visibility` + `immutable_field_assign`) **+** 027-**Rec3** (texto de divergencia + `zig/tests/llvm_mem.sh`) **+** las dos resoluciones de §1-P1/P5 (`DEC` de alcance de RT1 y redacción de 030/README) | 027 §5 exige 026 *escrito* antes de Rec2 — aquí se cumple. Rec2/Rec3 cero-runtime. El `DEC` de RT1 desbloquea 026 sin inventar rc donde no lo hay. |
| **D — Stdlib MVP (4 PRs, 028 tal cual)** | PR1 `len`+`s[i]` → PR2 `to_string`+`read_file`+`preopens` → PR3 `lexer.astra`+gate → PR4 M2 (`push`,`ord`,`substr`,`str_to_int`) | Independiente de la semántica, pero llega **después** de A+B para que (i) cada PR lleve su `DEC-NNN`, (ii) no haya conflicto de merge en `typechecker.c`/`emitter.zig` con Rec1/Rec4, (iii) la regla 5 de 029 no se dispare. Recomputar `159→N` en cada PR. |
| **E — Enforcement v1 (1-2 PRs)** | `DEC` de sintaxis de `transfer` (+ `constructs/transfer.c` si es keyword) → constructo + S1+S2+S3 en FC y FZ en el mismo PR + `.copy()` en 4 motores + `ui/transfer_*` y `conformance/transfer/*` | Es el PR más grande: hacerlo **después** de A-D significa que la spec (§2.6), el registro de decisiones, los tests UI y los builtins ya están listos y el PR solo aporta comportamiento. |
| **F — Diferido (no bloquea nada)** | RT1 (solo M4, como gate del primer scheduler/send real; M3 cuando una `DEC` añada rc al VM Zig) · v2/v3 de 026 · gate de benchmarks: **extender** `zig/tests/llvm_bench.sh` existente con techo de RSS (estable) y umbrales de tiempo informativos/razones ×C | Todo lo que depende de rc/fibras o de umbrales frágiles se pospone explícitamente con su `DEC`, en vez de quedar «a medias» como denuncia 025. |

**Rechazos/posposiciones explícitos:**

- **RECHAZAR** el Paso 2 de `026:604-609` literal (dejaría `[x]` falso en
  `README:177`) → usar la fila tres estados de `029:276` + la fila nueva de
  Design Goals de 026.
- **RECHAZAR** `030:251` como *acción* («priorizar 3B») → convertirla en
  candidata a `DEC-NNN`; 027-Rec3A sigue siendo la recomendación vigente.
- **POSponer** RT1@M3 (§1-P1) y `read_file` en wasm hasta los `preopens` de
  028-PR2 (ya previsto en `028:302`).
- **NO** proponer el presupuesto de commits como *required status check*
  (`029:617-621` ya lo descarta — mantenerlo como checkbox de revisión).

---

## §4 Lo que NO se puede ratificar aún y qué evidencia falta

| Pieza | Qué falta (evidencia concreta) |
|:------|:-------------------------------|
| **026-F / 026-v1** | (1) `DEC` de **sintaxis** de `transfer` (keyword vs builtin) + fila de registro si es keyword; (2) `DEC` que resuelva el conflicto **RT1@M3 vs 027-Rec3** (§1-P1); (3) **estimación de esfuerzo** de v1 (no existe en 027/028/029 para este PR); (4) los diffs de Fase 0 **ejecutados** — hoy `ARCHITECTURE.md` no tiene §2.6 (`grep` → 0) y los gates de v1 deben incluir `--check-constructs` de forma explícita si hay keyword. |
| **027-Rec1/Rec2/Rec4** | Los tests propuestos **no existen todavía** (`int_literal_range`, `int_width_semantics`, `alias_let_visibility`, `immutable_field_assign`, `qualified_construction` — `ls` → no existen **[verificado]**): hasta que un PR los añada y pase `make test` + `zig build test` + `ui_message_parity.sh` + `dump_parity.sh`, la decisión está ratificable como *diseño*, no como *hecho*. Rec4 exige además verificación post-cambio de `llvm_sanitize.sh` (LSan sobre los fixtures reescritos). |
| **027-Rec3** | `zig/tests/llvm_mem.sh` **no existe** (`ls` → no existe); falta ejecutar el techo 128 MB en la ruta LLVM y fijar qué pasa con el seed en ese gate («arena sin límite» documentado, no medible). Y falta la redacción de §1-P5 en 030/README para que «decisión #3» deje de llamarse abierta. |
| **028-MVP/PRs** | Ningún PR ejecutado aún; falta la **primera** evidencia real de que un builtin nuevo sobrevive los 9 gates a la vez (`sweep_emit_c` + `zig build test` + `dump_parity` + `ui parity` + `llvm_parity` subiendo el total con `skip=0` + `jit`/`cross`/`wasm`/`sanitize`), y los `preopens` de WASI probados en PR2. Las estimaciones 4-6 d/builtin son **opinión calibrada** (028 lo admite en su cabecera): no hay velocidad histórica por feature en el repo con la que contrastarlas (135 commits de código en 6 semanas, sin desglose por feature). |
| **029-B/DECISIONES/README** | Parches **sin aplicar** (todo sigue sin commitear); tras aplicarlos haría falta: `make test` (acoplamiento `construct.c:303↔run_tests.sh:65`), `--check-constructs` (si se toca la cabecera), `gh pr checks --watch` (los 3 checks requeridos corren también en PRs de docs), y el **recálculo de todos los conteos** en el momento del parche (§2.4-6 ya los dejó caducados). |
| **030-gates** | (1) Corregir la celda 184 ms y regenerar `results.json` (celda obsoleta de C); (2) decidir el **mecanismo** de gate: extender `zig/tests/llvm_bench.sh` existente, con techo de RSS (estable) y tiempos informativos o por razón ×C — un umbral absoluto de tiempo en esta máquina (loadavg 0,53→1,46, 15 W) **flakearía**; (3) incluir los tamaños de binario en los crudos o documentar que solo salen de `build_all.sh`; (4) arreglar la redacción §1-P5 antes de que el autor ratifique «falta crear la liberación en los VMs» como plan. |

**Ninguna recomendación se rechaza en su total**: el diseño de 026-F, las
cuatro decisiones de 027, el MVP/PRs de 028, la opción B y `DECISIONES.md` de
029 y la campaña de 030 están **sustancialmente bien construidos y sus cifras
claves se reproducen**. Lo que falta no es ideas: es cerrar los cinco huecos
de §1 antes de que el autor escriba «ratificado», y ejecutar la secuencia de
§3 para que los informes dejen de ser propuestas.

**RealityIntegration** · 2026-10-27 · evidencia: este documento + gates
re-ejecutados en el árbol sin commitear · re-evaluar tras la Fase A.
