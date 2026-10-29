# Deuda acumulada de Astra — inventario, decisiones faltantes y estado de la documentación

> **Fecha:** 2026-10-29 · **Base:** `main` @ `c49ce28` (tras `git pull` de 6
> commits sobre `10ceefe`) · **Tipo:** registro datado (como `COHERENCE_AUDIT`
> y `PRE_LLVM_AUDIT`): no cambia comportamiento y no se reescribe; los estados
> de roadmap siguen viviendo en `Documentacion/00_indice/INDICE.md` §«Estado
> del proyecto».
>
> **Método.** Inventario de deuda en seis fuentes, todas leídas en la fecha:
> `DECISIONES.md` (33 entradas), `PHASE1_PROGRESS.md` §4/§4bis/§7,
> `PHASE2_PROGRESS.md` §8.3/§9.6/§10.4/§11, `PHASE_LLVM_PROGRESS.md` §7
> («Fuera del alcance»/«Diferido»), `PHASE2_GAP_ANALYSIS.md` §5/§11/§12/App. B
> y `research/034` + los issues de GitHub abiertos. Gates ejecutados hoy, no
> recordados (§6).
>
> **Qué NO es:** no es un plan de features (eso es `GAP_ANALYSIS.md` §11) ni
> un registro de decisiones (eso es `DECISIONES.md`); es el pasillo entre los
> dos: lo que se debe, lo que falta decidir y lo que la documentación dice
> distinto de lo que el código hace.

---

## 0. Resumen ejecutivo

| Bloque | Deuda | Dónde vive | Estado |
|:-------|:------|:-----------|:-------|
| **Corrección / seguridad** | **32 issues abiertos** (#49–#80): 10 ALTA · 15 MEDIA · 7 BAJA | `research/034` + `gh issue list` | 🟡 Abiertos (0 cerrados) |
| **Decisiones de lenguaje** | 1 en `Propuesta` (DEC-021) + **24 puntos sin DEC** (§3: D1–D24) que hoy se están resolviendo «de facto» en código o en informes | §3 de este informe | 🔴 El bloqueo real: sin DEC no hay backend ni feature nueva (regla 5 `AGENTS.md`) |
| **Funcionalidad** | Self-hosting a ~2/3 (corpus 196/304); Tier 1/2/3 del GAP casi entero (comptime, fibers, ARC/ORC, FFI, macros, paquetes) | §2 | 🟡 |
| **Documentación** | 13 desincronizaciones objetivas verificadas hoy (10 corregidas en este mismo cambio, 3 pendientes) + 6 DEC sin escribir en `ARCHITECTURE.md` | §4 | 🟡 |
| **Presupuesto de decisiones** | Ciclo desde 2026-09-16: `CODE = 146`, `DEC = 22` → **15 %** (la regla pide ≥ 20 %) | `AGENTS.md` §Commit budget | 🔴 Bajo |

**El hallazgo de fondo:** el proyecto no tiene deuda de *calidad de ejecución*
(la suite está verde en las cuatro rutas y los gates son serios) — tiene
deuda de **decisión**. Casi todo lo pendiente de la §2 y §3 está así porque
nadie escribió la `DEC-NNN` que lo autorice, no porque falte capacidad.

---

## 1. Deuda de corrección — 32 issues abiertos (`research/034`, 2026-10-29)

Todos con repro verificado (✓ = reproducido con binario ASan; `[sub]` = con
salida capturada). Cifras del propio informe: gate base `make test` → 352/0
en el commit auditado.

### 1.1 Nivel ALTO (CVSS 7.0–8.9) — issues #49–#58

| # | Issue | Hallazgo (una línea) | Impacto |
|:-:|:------|:---------------------|:--------|
| A1 | #49 | `FnObj.local_count` (`uint8_t`) trunca con 255 params → el C generado arranca `sp=0` sobre los parámetros | Respuesta incorrecta silenciosa solo en `--emit-c` |
| A2 | #50 | `fn_obj_reg[512]` **falla abierta** (sin `error_count++`): >512 lambdas → puntero `NULL` | `--emit-c` dice éxito y el binario muere (SIGSEGV) |
| A3 | #51 | Sentinela `0xFF` de `add_local` colisiona con el slot 255 válido | VM: `local variable at slot 255 not initialized`; C: `nil`, exit 0 |
| A4 | #52 | Anidación 240–255 aceptada por el parser → **stack-overflow en `emit_expr`** | DoS determinista del compilador con entrada que él mismo valida |
| A5 | #53 | `print(n)` / `a == b` sobre structs cíclicas recursan sin límite (el límite 64 solo existe en `value_copy`) | SIGSEGV con 8 líneas de Astra legal (los ciclos son legales: DEC-027) |
| A6 | #54 | `NEW_ENUM`: `break` muerto en el escaneo hacia atrás en `codegen.c` | Enums anidados → igualdad y print **falsos** en C |
| A7 | #55 | Constantes float escritas con `%g` (6 dígitos) en el C generado | Redondeo irreversible: `1.0000000000000002 == 1.0` → VM `false`, C `true` |
| A8 | #56 | Familia de `malloc`/`realloc`/grow sin check de NULL (typechecker, parser, lexer, emitter, codegen, string_table) | OOM = SEGV en vez de `error: out of memory` (repro con `ulimit -v`) |
| A9 | #57 | `--emit-c` escribe a través de symlinks preexistentes (sin `O_NOFOLLOW`/`lstat`) | Poisoning de artefactos al correr la suite en CI |
| A10 | #58 | Un **método de usuario llamado `copy`** elude el walker `is_copy` → `transfer` aceptado con doble propiedad | Bypass de la fase E de enforcement (DEC-026/027) en **ambos** frontends |

### 1.2 Nivel MEDIO (CVSS 4.0–6.9) — issues #59–#73

| # | Issue | Hallazgo (una línea) |
|:-:|:------|:---------------------|
| M1 | #59 | `read_line()` devuelve el búfer stdin reutilizado: la 2ª línea corrompe la 1ª (`secondline here`) |
| M2 | #60 | Global leído antes de definirse: VM aborta, la ruta C sigue con `nil` y exit 0 |
| M3 | #61 | S2 (fase E): derivados de contenedor (`arr[0]`, `b.x`) no se enlazan con su contenedor → doble propiedad aceptado |
| M4 | #62 | S1 sin back-edge: `transfer` dentro de `while`/`for` aceptado y muere en la 2ª iteración |
| M5 | #63 | Nil-red incompleta: `transfer(param)` deja el handle vivo en el caller; `transfer(const)` acepta y revienta en runtime |
| M6 | #64 | El pase de ownership se **desactiva en silencio** pasados 256 marks / 512 entries (sin diagnóstico) |
| M7 | #65 | Hash-DoS: FNV-1a 32 sin semilla en interning + tabla de símbolos (compile 44–88 s con 30k idents en un bucket) |
| M8 | #66 | `add_constant` O(n²) sin dedup de strings: 100k refs globales tardan 50–60 s en emitir |
| M9 | #67 | Directorio como entrada → exit 0 en todos los modos (única celda roja de la matriz de exit codes) |
| M10 | #68 | `fwrite`/`fclose` sin comprobar: disco lleno → `.c` truncado con exit 0 |
| M11 | #69 | `cg_writef` (`tmp[2048]`, retorno ignorado): identificadores >2 KB → `.c` malformado con exit 0 |
| M12 | #70 | **Paridad**: la ruta zig pierde capturas en posición de escritura (`a[0]=9`) → programa legal falla **solo en zig** |
| M13 | #71 | **Paridad**: LLVM rechaza arrays de opcionales legales (`some([1,2])`) y `.copy()` de pareja es *shallow* solo ahí (DEC-027) |
| M14 | #72 | Keywords de C (`union`, `char`, `int`…) como campos/variantes → C no compila y `--emit-c` dice éxito |
| M15 | #73 | >255 parámetros: `param_count` truncado a `uint8` → error interno opaco `stack imbalance` |

### 1.3 Nivel BAJO — issues #74–#80

`B1` #74 `opcode_is_fallible` omite 24 opcodes (diagnósticos C con línea 0) ·
`B2` #75 `<fn>` vs `fn` al imprimir funciones · `B3` #76 `gt_depth` filtrado
tras `fn f<T` truncado · `B4` #77 `generic_stack` cap 32 con truncado
silencioso · `B5` #78 posiciones `uint32_t` >4 GiB + sin techo de tamaño de
entrada · `B6` #79 DEC-026 cita un diagnóstico que el compilador no emite ·
`B7` #80 higiene de mensajes (arity, `ferror` como `cannot open`).

### 1.4 Priorización real (qué bloquea qué)

1. **M12 y M13 rompen la regla de paridad** («el Zig debe aceptar todo lo que
   el seed acepta») — son los únicos que empeoran *hoy* un invariante de
   proceso, no solo un caso límite.
2. **A4 y A5 son DoS deterministas con entrada legal** — cortan cualquier
   host que ejecute Astra no confiable (juez, REPL futuro, CI).
3. **A10, M3, M4, M5, M6** dejan la fase E de enforcement con huecos: la
   seguridad entre fibras está «implementada y gateada» pero los gates no
   cubren estas rutas. **RT1 (DEC-023) es el backstop diseñado para varios de
   ellos y aún no existe.**
4. **A1–A3, A6, A7, A9, M2, M9–M11, M14** son divergencias `--emit-c` vs VM:
   dañan la credibilidad del backend C, que sigue siendo la ruta de
   bootstrap documentada.
5. **A8, M7, M8, M15, B4, B5** son robustez/rendimiento del compilador
   (B4/B5 y M15 tienen mitigación barata: caps y chequeos ruidosos).

> Riesgos de diseño abiertos en `research/034` §«Riesgos»: **R1**
> `read_file(path)` = lectura arbitraria si la CLI futura ejecuta Astra no
> confiable · **R2** `--jit` ejecuta código dentro del proceso del
> compilador con `-rdynamic`. Ambos pertenecen a la decisión **DEC-021**.

---

## 2. Deuda de funcionalidad

### 2.1 Self-hosting (paso 5 de PHASE1 §7) y Fase 3

| Qué falta | Estado medido | Fuente |
|:----------|:-------------|:-------|
| Corpus del typechecker auto-hospedado completo | **196/304** (M-T4a/b/c cerrados: `for`, lambdas/`fn(T)->R`, opcionales/`?`); fuera: genéricos, ownership/transfer, `if` como expresión en posición de expresión, tipos `[T]`, y ~11 gaps de parser/lexer + 4 mensajes del emitter | `typechecker_corpus.list` |
| Límites de profundidad del seed en `parser.astra` | 3 casos siguen excluidos (`deep_elseif`, `expr_chain_deep`, `nesting_too_deep`) | PHASE1 §7 |
| **Emitter en Astra-0** (codegen el último) | No empezado — prerequisito explícito del orden de `research/028` §5 | `research/028` §5 |
| Árbol de compilador `src/compiler/` (multi-fichero en Astra) | No empezado — **acoplado a DEC-021** (la CLI es la que compila el árbol; `DEC-032` lo deja explícito) | DEC-032 |
| Fase 3 (doble compilación: Astra compila Astra) | No empezada — prerequisitos: stdlib MVP ✅ + árbol en Astra ⏳ | `INDICE.md`, `COMPILER_STRATEGY.md` §6 |

### 2.2 Lenguaje — GAP §5 (Tier 1/2/3)

| Tier | Pendiente | Nota |
|:-----|:----------|:-----|
| T1 | **Type aliases** — la fila existe en el registro (`type_alias`) pero **no hay token `type`** en ningún lexer | `GAP §8.2` |
| T1 | **Package manager** (dependencias, registry, semver) | bloqueado por DEC-021 |
| T2 | **Comptime** (`comptime` parsea y se rechaza) | `GAP §5.2` |
| T2 | **Operator overloading** (trait-based) | `GAP §5.2` |
| T2 | **Macros** | `GAP §5.2` |
| T2 | **Async / fibers**: S3 (`spawn`), scheduler, `await`/`yield` | fase E §2.5 |
| T2 | **ARC/ORC en los VMs** — hoy divergencia aceptada (DEC-009); medidas en `research/040`: seed 404 MB · zig 721 MB · C 489 MB · LLVM 77 MB acotado | `research/040` |
| T2 | **Zero-copy FFI** (`@cImport` ni `translate-c` en LLVM) | `GAP §5.2`, LLVM M3 |
| T3 | rest/spread en `match`, destructuring, interpolación de strings, parámetros por defecto, variádicos, atributos | `GAP §5.3` |

### 2.3 Traits y genéricos (`PHASE2` §8.3/§9.6)

- Objetos de trait / vtables (`dyn`) — el dispatch es **100 % estático**.
- UFCS (`T::method(x)`, métodos como valores) → bloquea también
  **método sobre parámetro genérico** (`x.show()` con `T: Show`).
- `impl<T> Trait for T`, impls sobre instancias (`impl Show for Box<i32>`,
  `impl m.T for X`), blanket impls.
- Métodos/traits **cross-módulo** (las tablas viven en cada `TypeChecker`).
- Métodos default en traits (hoy: error explícito) y desambigüación entre
  traits con el mismo método (requiere sintaxis nueva).
- **Enums genéricos inertes** (parsean, checker/emitter los saltan), bounds
  en declaraciones enum/trait/impl, bounds sobre bindings abstractos,
  `i32<f32>` aceptado en silencio, where-clauses, turbofish, `type_alias`
  genérico.
- **Genéricos cross-módulo**: `collectExports` filtra `generics.len == 0`
  → una plantilla `pub` no se exporta.

### 2.4 Errores `?` (`PHASE2` §10.4)

`Result<T, E>` estático distinto · tipo never `!` · `??` coalescing ·
re-chequeo del `?` por instanciación genérica · **fugas del backend C**
(las celdas envueltas de `some(...)` nunca se libera; la suite no corre
conformance con LSan).

### 2.5 Enforcement entre fibras (fase E, `PHASE2` §11)

| Pieza | Estado |
|:------|:-------|
| S1/S2 + nil-red R4 + `.copy()` (E1/E2) | ✅ gateado |
| **S3** (`spawn`, cierre de efectos sobre globales) | ⏳ pospuesto con `spawn` — `ui/spawn_global_atomic.astra` sin crear |
| **RT1** (walk `rc==1` en el cruce) | ⏳ fijado a M4/scheduler (DEC-023); **sin código y sin pin** |
| Correcciones de A10/M3/M4/M5/M6 | ⏳ issues abiertos (§1) |

### 2.6 Backend LLVM — restos conocidos

- **`--emit-asm`** es el único flag de `GAP §12.2` sin implementar.
- **UBSan** no se ofrece: LLVM 19..23 no registra la pasada `ubsan` del new-PM
  (`opt-19 --print-passes`) — bloqueo externo, reevaluar con LLVM nuevo.
- Remarks del pipeline (`-O2` adicional medido solo con benchmarks) — M4 lo
  dejó «en pie».
- **Programas multi-módulo reales**: el emisor es de fichero único
  (`--single-file` reproduce el seed); `@cImport` fuera de v1.
- Metadatos de elemento derivados: `a[0][1]`, `a[0](x)` → rechazo limpio
  (documentado en `AGENTS.md`, sin plan de soporte).
- Ciclo-colector opcional para el ARC de M4.e (recomendación `research/040`).

### 2.7 Stdlib y runtime

- **Stdlib compartida no existe**: `std/…` se rechaza con diagnóstico hasta
  que exista; `DEC-024` obliga a definir cada helper *dentro* de cada test.
- `to_string` **solo enteros** (floats pospuestos con DEC-010/014) ·
  `len` devuelve `i64` · strings = bytes (DEC-013).
- **Unicode/strings**: `research/038` recomienda capas Unicode por fases
  (UTF-8 con `len`=bytes se mantiene) — falta la DEC que lo fije.
- **Iteradores**: `research/037` propone plan en 3 fases — sin DEC.
- **Enteros**: solo existen `i32/i64/u32/u64` (probes de `research/035`);
  `i8/i16/u8/u16` no existen aunque la spec los nombra en varias partes.
- **Punteros**: `Ptr<T>`/unsafe de `ARCHITECTURE §8.5` sin modelo elegido
  (`research/036`).
- **Lectura de memoria en los VMs**: gate RSS por backend recomendado
  (`research/040` Rec3) — solo existe techo para la ruta LLVM.

### 2.8 Tooling

| Pieza | Estado | Fuente |
|:------|:-------|:-------|
| CLI unificada `astraea` (manifest `astraea.toml`, `astraea.lock`) | **DEC-021 `Propuesta`** — bloquea rename, paquetes y el árbol `src/compiler/` | DEC-021 |
| REPL | Fundamento existente (`--jit`, M6.a) sin explotar | `GAP §12.4` |
| LSP básico | `[ ]` sin empezar | PHASE1 §4bis #31 |
| Build HTML del libro (mdBook) | Pendiente (decisión 2026-10-28: primero contenido) | `09_libro/README.md` |
| Gate de ejemplos del libro (re-ejecutar los 91 y comparar salidas) | Anotado, **no implementado** | `09_libro/README.md` |
| CI: rutas cross/wasm de `lexer_gate`/`parser_gate` cableadas en `llvm-cross`/`llvm-wasm` | Pendiente (DEC-017 lo dejó «un paso cada uno») | DEC-017 |
| CI multiplataforma (macOS/Windows) | Pendiente (solo Linux) | PHASE1 §4bis #26 |
| `sweep_emit_c` / suites con LSan en el C backend | La conformance no corre con LSan | PHASE2 §10.4 |

---

## 3. Decisiones que faltan

Regla 1 de `AGENTS.md`: *nada aterriza sin una decisión*. La lista siguiente
es el **trabajo de `DECISIONES.md`** que hay que abrir antes (o junto con)
el código que las necesita. Estado actual verificado hoy: **33 DEC
registradas — 32 aceptadas, 1 en `Propuesta` (DEC-021)**.

### 3.1 Bloqueantes (sin estas DEC no se puede avanzar la Fase 3 ni Tier 1)

| # | Decisión a abrir | Qué hay hoy | Qué bloquea | Fuente |
|:-:|:-----------------|:------------|:------------|:-------|
| D1 | **CLI y manifest `astraea`** — implementación de DEC-021 (rename `astra.toml` → `astraea.toml` + bautizo del CLI) | DEC-021 en `Propuesta` (dirección decidida) | Árbol `src/compiler/` en Astra, package manager, `std/…` real | DEC-021 |
| D2 | **Alcance de la Fase 3**: qué se auto-hospeda primero (¿parser+typechecker+emitter single-file?, ¿cuándo multi-módulo?) | `DEC-032` dice «Step 4 con la CLI» sin fijar alcance | Orden del resto del paso 5 | DEC-032, `research/028` §5 |
| D3 | **Formato de bytecode** (rediseño temprano vs parchear el plano) | `GAP §6.3` lo recomendó «temprano en Fase 2»; App. B #1 **abierta** | Debugger persistente (§12.5-3), serialización, versionado | `GAP §6.3`, App. B #1 |
| D4 | **Estructural vs nominal** — cuándo un tipo pasa a ser nominal (traits/genéricos ya lo exigen) | App. B #2 abierta; hoy estructural para structs | Completar genéricos/traits, `type_alias` | `GAP §7.3`, App. B #2 |

### 3.2 Decisión de modelo (semántica y runtime)

| # | Decisión a abrir | Estado actual | Recomendación ya escrita en investigación | Fuente |
|:-:|:-----------------|:-------------|:------------------------------------------|:-------|
| D5 | **Memoria de los VMs**: ¿portar ARC (opción 3B) o mantener divergencia + gate RSS por backend (3A) y añadir ciclo-colector opcional? | DEC-009 fija la divergencia *hoy*; sin plan siguiente | `research/040`: gate RSS por backend + colector opcional, **sin tracing GC** | DEC-009, `research/040` Rec3 |
| D6 | **Modelo de fibers/async**: stackful vs stackless + dónde vive RT1 | DEC-023 deja RT1 en M4; `spawn` no existe | `research/039`: spawn scoped, canales por defecto, **RT1 en send/recv**, cancelación por scope | App. B #4, `research/039` |
| D7 | **S3**: qué cierra `spawn` sobre globales y cuándo se gatea | Pospuesto (DEC-026 §5); `ui/spawn_global_atomic.astra` sin crear | — | `PHASE2` §11 |
| D8 | **Strings/Unicode**: capas Unicode por fases sin romper DEC-013 | DEC-013 fija `len`=bytes | `research/038`: fases + escapes `\uXXXX` + normalización al final | `research/038` |
| D9 | **Iteradores**: protocolo pull, lazy/eager, sintaxis de bucle | `research/015` §4 reality-checked por `037` | `research/037`: plan en 3 fases | `research/037` |
| D10 | **Anchos de enteros**: ¿se añaden `i8/i16/u8/u16`? y si se añaden, ¿literal out-of-range = error (DEC-006)? | Solo `i32/i64/u32/u64` medidos | `research/035` (espectro UB→wrap→trap) | `research/035`, DEC-006 |
| D11 | **Punteros**: modelo de `Ptr<T>`/unsafe de `ARCHITECTURE §8.5` | Sin modelo | `research/036` (6 familias; `?*T` = 8 B) | `ARCHITECTURE` §8.5, `research/036` |
| D12 | **Operator overloading**: ¿solo traits (opAdd/opEq…) o también ad-hoc? | App. B #7 abierta; no implementado | — | `GAP` App. B #7 |
| D13 | **Retención del backend C**: ¿se conserva como verificación de bootstrap indefinidamente? | App. B #5 abierta; hoy se usa en cada gate | — | `GAP` App. B #5 |
| D14 | **Salida de ensamblado y modo debug**: ¿`--emit-asm`? ¿bytecode serializado como formato de debug? ¿garantía de «debug build» sin reordenar? | §12.5-3 y §12.5-4 **abiertas**; `--emit-asm` sin implementar | — | `GAP` §12.5 |
| D15 | **Scope de FFI** (`@cImport`, punteros C) y su orden respecto a Fase 3 | Tier 2 sin decidir | — | `GAP` §5.2, LLVM M3 |

### 3.3 Preguntas abiertas de módulos (`GAP` App. B)

| # | Pregunta | Estado |
|:-:|:---------|:-------|
| D16 | ¿Se rechazan `import`/`from` anidados dentro de funciones (App. B #12)? | Abierta — ambos compiladores los aceptan |
| D17 | ¿`use path` re-enlaza también el *nombre de módulo* de la dependencia (App. B #13)? | Abierta — «deferred, not guessed» (2026-10-12) |
| D18 | ¿Las variantes de un `pub enum` forman parte de su superficie de export (App. B #14)? | Abierta — hoy se construye cross-módulo con `pub fn` wrapper |

### 3.4 Decisiones menores ya detectadas (sin DEC propia)

| # | Decisión | Nota |
|:-:|:---------|:-----|
| D19 | **`type_alias`**: token `type`, sintaxis y alcance (T1 del GAP) | El registro lo declara sin token; `--check-constructs` no lo reclama |
| D20 | **`to_string` polimórfico / formato de float** | Pospuesto con DEC-010/014 explícitamente |
| D21 | **Shadowing de binders de `for`/`match`** con nombres builtin | DEC-015 lo deja «fuera de alcance y conocido»: `for len in …` hoy funciona |
| D22 | **QoL Tier 3** (interpolación, parámetros por defecto, atributos…): orden y alcance | `GAP §5.3` sin priorizar |
| D23 | **LSP/REPL**: si entran en alcance de Fase 3 o después | PHASE1 §4bis #31 `[ ]` |
| D24 | **macOS/Windows CI** y `ubsan` cuando LLVM lo publique | PHASE1 §4bis #26; LLVM §7 «Diferido» |

### 3.5 Deuda del propio proceso de decisiones

- **Presupuesto de commits incumplido en este ciclo** (`INI=2026-09-16`):
  `CODE = 146`, `DEC = 22` → `DEC * 5 = 110 < 146` (**15 %**, la regla pide
  ≥ 20 %). Cierra solo con ≥ 30 commits a `DECISIONES.md` — es decir, las
  DEC de §3.1/§3.2 **son** la salida del déficit, no un trámite aparte.
- **6 entradas con `Spec: pendiente de escribir en ARCHITECTURE`**:
  DEC-006 (enteros), DEC-013/014 (builtins M1), DEC-015 (nombres
  reservados), DEC-016 (lexer selfhost), DEC-020 (builtins M3). Todas
  quedaron como «spec de facto» en `research/027`/`028` sin subir a la
  especificación normativa.

---

## 4. Deuda de documentación (verificada hoy contra el código)

### 4.1 Desincronizaciones objetivas

| # | Qué decía la doc | Qué hace el código | Estado |
|:-:|:-----------------|:-------------------|:-------|
| DD1 | `PHASE1` §7: «Sigue: M-T4 (corpus completo…)» | M-T4a/b/c **cerrados** (corpus 172 → 196, PRs #84–#86) | ✅ **Corregido en este cambio** |
| DD2 | `PHASE1` §7 final: dos hallazgos «sin pinneear… candidatos a DEC futura» (`else` en línea aparte, `if/else if` como cola) | Fijados por **DEC-033** con `ui/elseif_tail_rejected.astra` + `ui/else_newline_rejected.astra` | ✅ **Corregido en este cambio** |
| DD3 | `INDICE.md` fila Fase 1: `typechecker_gate 141/141 ×4 rutas, M-T3` | Gate en verde a **196/196** (§6) | ✅ **Corregido en este cambio** |
| DD4 | `README.md` línea Status: `typechecker_gate → 141/141 … M-T3` | Ídem 196/196, M-T4c | ✅ **Corregido en este cambio** |
| DD5 | `CHANGELOG.md` `[Unreleased]`: termina en M-T3 | Faltan M-T4a/b/c y los informes `035`–`040` | ✅ **Corregido en este cambio** |
| DD6 | `09_libro/README.md`: capítulos 05–15 con la columna Estado **vacía** | Los 16 capítulos existen (155–430 líneas c/u) y los 91 ejemplos están en `ejemplos/` (verificados por muestreo) | ✅ **Corregido en este cambio** |
| DD7 | `INDICE.md` §9: «8 divergencias halladas quedaron en el backlog» del libro | **No están itemizadas en ningún fichero** del repo ni en issue abierto | ⏳ Pendiente: extraerlas de la sesión de escritura/PR del libro o retirar la afirmación |
| DD8 | `09_libro/README.md`: «Gate futuro: script que re-ejecute todos los ejemplos» | No existe (`ejemplos/**/*.astra` no se ejecuta en CI) | ⏳ Pendiente |
| DD9 | 6 DEC con `Spec: pendiente de escribir en ARCHITECTURE` (§3.5) | La spec normativa no las recoge | ⏳ Pendiente |
| DD10 | `research/034` → 32 issues abiertos sin fila en `INDICE.md` | Este informe es el puente (fila añadida) | ✅ **Corregido en este cambio** |
| DD11 | `09_libro/14_referencia_builtins.md`: «los **8** builtins», texto futuro caducado («llegan a main en los próximos PRs»), «cuando `ord`/`substr` aterricen» y ejercicio con «aún no están en main» — omitiendo `chr`/`read_line` (M3, DEC-020), que el propio capítulo 8 ya documentaba | Los 10 builtins están en `main` desde M3 | ✅ **Corregido en este cambio** (tablas, errores exactos de conformance y resumen) |
| DD12 | `README.md` §Roadmap, fila *Concurrency model*: «`grep … spawn/channel/Atomic[` → **0**; **`transfer` → 0**» | `transfer` existe en **6 ficheros** de `seed/src`+`zig/src` (fase E1/E2) y el grep de concurrencia da 1 (un comentario) | ✅ **Corregido en este cambio** (evidencia actualizada con DEC-012/022/026/027 y el estado real de S3/RT1) |
| DD13 | `DECISIONES.md` §DEC-012: «La implementación queda pospuesta… **no existe código hoy** (`transfer` no lexea, `grep` → 0)» | E1 (PR #36) y E2 (PR #38) cerraron el 2026-10-28; pendientes solo S3 y RT1 | ✅ **Corregido en este cambio** (hecho objetivamente falso, actualizado sin tocar la decisión) |

### 4.2 Tareas de escritura pendientes (no son bugs, son texto)

1. Escribir en `ARCHITECTURE.md` las 6 DEC de §3.5 (enteros, builtins M1/M3,
   nombres reservados, lexer selfhost).
2. Itemizar o retirar las «8 divergencias» del libro (DD7).
3. Gate de los 91 ejemplos del libro en CI (DD8).
4. `research/029` §1/§2 — parches de texto de `COMPILER_STRATEGY.md` y del
   roadmap de `README.md`: **ya aplicados** en su mayor parte (verificados
   hoy: `ARCHITECTURE` §41 lleva cabecera «estado en INDICE.md» y `README`
   §Roadmap tiene estados con gate); solo queda el conteo histórico si
   alguna cita obsoleta reaparece.

---

## 5. Orden recomendado para el siguiente ciclo

Orden por dependencia y por «cuánto desbloquea»; cada paso nombra su gate.

1. **Cerrado de los 32 issues** en tres tandas: (a) M12/M13 (paridad) —
   primero, porque violan una regla de proceso; (b) A4/A5/A8 (DoS con
   entrada legal + OOM); (c) A1–A3/A6/A7/A9 + M2/M9–M11/M14 (backend C).
   Los de fase E (A10, M3–M6) van con la tanda de S3/RT1. *Gate: `make test`
   352/0 + `sweep_emit_c` + `llvm_parity` 221/221 sin regresiones.*
2. **Ciclo de DEC antes que ciclo de código** (regla «no dos ciclos
   backend seguidos» + presupuesto): abrir D1 (DEC-021 a `Aceptada`
   implementando la CLI mínima) y D3/D4 (bytecode + nominalidad). Además
   de desbloquear, es lo que mueve el ratio `DEC*5 ≥ CODE` del ciclo.
3. **Cerrar el paso 5**: genéricos y ownership en el corpus del typechecker
   (196 → ~304 excluyendo solo lo documentado) + `parser.astra` con los 3
   límites de profundidad. *Gate: `typechecker_gate.sh` + exclusiones con
   motivo.*
4. **Emitter en Astra-0** (`research/028` §5 dice «codegen va el último»).
   *Gate: salida diferencial contra `--dump-bytecode` del seed, patrón
   `typechecker_gate`.*
5. **Stdlib compartida + `std/…`** (hoy rechazado): sin esto no hay árbol
   `src/compiler/` ni Fase 3. *DEC propia + `conformance/stdlib/` crecido.*
6. **Fase 3** (doble compilación) con el alcance que fije D2.
7. **Deuda Tier 2** en el orden que salga de 2: fibers (D6/D7) → memoria
   (D5) → comptime/macros/FFI.
8. En paralelo, **docs**: DD7/DD8/DD9 (§4.2) — son de bajo coste y cierran
   la contradicción doc↔código que la auditoría del libro ya detectó.

---

## 6. Evidencia de verificación (2026-10-29)

```bash
git rev-parse --short HEAD                      # c49ce28 (tras pull de 6)
cd seed && make test                            # passed: 352   failed: 0
./astra-seed --check-constructs                 # 47 constructos, 27 operadores — OK
./tests/selfhost/typechecker_gate.sh            # corpus 196: rutas en verde (§6.1)
grep -v -E '^\s*(#|$)' tests/selfhost/typechecker_corpus.list | wc -l   # 196
gh issue list --state open --limit 100          # 32 issues (#49–#80: 10 A · 15 M · 7 B)
git log --format=%H --since=2026-09-16 -- seed/src zig/src | sort -u | wc -l   # 146 (CODE)
git log --format=%H --since=2026-09-16 -- Documentacion/01_lenguaje/DECISIONES.md | sort -u | wc -l   # 22 (DEC)
find Documentacion/09_libro/ejemplos -name '*.astra' | wc -l   # 91
# muestreo de ejemplos del libro (cap05/cap12) con astra-zig: salidas correctas
```

### 6.1 Salida del gate del typechecker self-hosted

`seed/tests/selfhost/typechecker_gate.sh` → **rc=0**, con las **4 rutas**
sobre los 196 ficheros del corpus:

```text
ok   route C backend: 196/196 corpus
ok   route zig VM: 196/196 corpus
ok   route LLVM --jit: 196/196 corpus
typechecker_gate: 196/196 corpus (verdict + first-error) + routes
```

(la 1ª ruta, seed VM, es la referencia contra la que comparan las otras
tres: sus 196 líneas `ok <fichero> (P|R|E)` encabezan la salida; la ruta
`--jit` exige zig construido con `-Dllvm`, presente en este entorno — corrió
completa, sin skip). Verificado dos veces hoy.

---

*Registro datado — actualizar con un informe nuevo, no reescribir este.
La fuente de verdad del estado del proyecto sigue siendo
`Documentacion/00_indice/INDICE.md`.*
