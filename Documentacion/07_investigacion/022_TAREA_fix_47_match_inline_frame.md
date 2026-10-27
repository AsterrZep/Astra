# 022 — TAREA: Fix §4.7 — Corrupción de frame de `match` inline (emitter VM)

> **Nombre para delegar:** `TAREA-4.7-match-inline-frame`
> **Estado:** ✅ **RESUELTA el 2026-10-15 por `ed1792e`** (fix en seed +
> zig + codegen C; gates al cierre en §11, suite 229/229). Qué funcionó
> de verdad: §11 al final de este documento. Lo que sigue es la memoria
> histórica de los dos intentos previos y del bloqueador que condicionó
> el diseño.
> **Estado a la entrada (histórico):** 🟠 ABIERTO — bug sin fix, dos
> intentos revertidos, bloqueador estructural identificado y tres
> direcciones de fix diseñadas; el árbol estaba **verde** (suite 224/224,
> CI verde, commit `67ffe75`).
> **Dónde vive el registro corto:** `Documentacion/06_auditorias/PRE_LLVM_AUDIT.md`
> §4.7 (fila de la tabla §4).

---

## 0. Brief de arranque (pegar en la conversación nueva)

> Arregla el bug §4.7 ("corrupción de frame de match inline") siguiendo
> el dossier `Documentacion/07_investigacion/022_TAREA_fix_47_match_inline_frame.md`
> de este repo. Lee el dossier COMPLETO antes de tocar código: contiene
> el repro mínimo, la evidencia (bytecode y traces), los dos intentos
> previos y POR QUÉ fracasaron, el bloqueador estructural (residuos de
> runtime invisibles al compile-time) y las tres direcciones de fix con
> el detalle de diseño de la dirección (i), que es la recomendada.
> Reglas: gates antes de cada commit (`cd seed && make debug &&
> ./tests/run_tests.sh && ./astra-seed --check-constructs`, desde la
> raíz `./zig/tests/dump_parity.sh`, `./zig/tests/ui_message_parity.sh`,
> `cd zig && zig build test --summary all`), commit convencional en
> español, push + CI verde, y espejo seed↔zig (un bug fix en uno se
> hace en ambos). Si un intento falla, REVIERTE y actualiza este
> dossier con el porqué — no dejes la suite roja.

---

## 1. El bug

### 1.1 Síntoma

Un `match` usado **como argumento de llamada** corrompe el frame en
**los dos VMs** (seed y zig). El C backend es **correcto** (es inmune:
su layout deriva de escaneo de `max_slot`, no del `sp` de la VM).

```astra
// repro mínimo (funciona mal en seed y zig; el C imprime 20)
fn main() { let x = 5; print(match x { 1 => 10, _ => 20 }) }
```

| Camino | Resultado |
|:-------|:----------|
| seed VM | `:1: runtime error: cannot call non-function value` (rc=1) |
| zig VM | idéntico byte a byte |
| C (`--emit-c` + gcc) | `20` ✓ correcto |
| misma cosa en **sentencia** (`let r = match …; print(r)`) | funciona ✓ |

### 1.2 Alcance

- **Roto:** `print(match …)` y cualquier `f(…, match …)` — con
  wildcard, con brazos literales, con bindings de payload, anidado
  (`print(match x { _ => match y { _ => 40 } })`), en arrays
  (`print([match x { _ => 1 }])`). Las formas SIN `_` en escalares ya
  ni llegan al runtime: el chequeo de §3.8 (`missing '_' arm`) las
  rechaza antes — el hueco vive tras cualquier match legal.
- **Correcto (no tocar):** posición de sentencia (`let r = match…`,
  match como statement), `print(if …)` (los `if` no allocan locals
  ocultos), el C backend en cualquier posición.
- **De suerte de layout (funciona hoy, NO por diseño):**
  `seed/tests/conformance/enums/match_binding_reclaim.astra` (inline
  en la línea 18) pasa 3/7/3 en la suite porque sus conteos de locales
  y residuos desplazan el receptor — CUALQUIER fix debe seguir
  pasándolo con `3 / 7 / 3`.

### 1.3 Causa raíz (nivel 1, ya demostrado con bytecode)

`NODE_MATCH` guarda el scrutinee en un **local oculto `$match_val`**
asignado por **recuento de declaración** (`add_local` → `local_count++`).
Los locales y los valores de expresión **comparten las coordenadas del
stack de la VM**. En posición de expresión, el receptor (`print`) ya
fue empujado en el índice que luego reclama el local oculto, y
`SET_LOCAL` **escribe por encima del valor vivo**:

```
; bytecode de `fn main() { let x = 5; print(match x { 1 => 10, _ => 20 }) }`
[ 0] CONST 0 (5)
[ 1] SET_LOCAL slot=1        ; let x
[ 2] GET_GLOBAL 1            ; print  -> vive en el índice 2
[ 3] GET_LOCAL slot=1        ; target del match, empujado en 3
[ 4] SET_LOCAL slot=2        ; <<< ESCRIBE EN 2: ¡DESTRUYE `print`!
…
; ASTRA_TRACE de la ejecución:
sp=3 | [<fn>][5][<fn>]        ; print en idx2
sp=4 | [<fn>][5][<fn>][5]
sp=3 | [<fn>][5][5]           ; idx2 = 5  ← print ya no existe
…
; CALL: fn_idx = sp-1-argc apunta a 5 (un int) -> "cannot call non-function value"
```

### 1.4 Bug adyacente DESCUBIERTO y registrado como fila §4.8 del audit (cerrado como §4.8+§4.11, `a29f1af`)

`seed/src/emitter.c`, armada **bind con guardia**: tras el bloque de
`NODE_PATTERN_BIND` hay un `break` incondicional (*"binding makes later
arms unreachable"*) que solo es cierto **sin guardia**. Con guardia,
los brazos posteriores **nunca se emiten** aunque el typechecker sí los
procesa (él no tiene el `break`), así que el programa compila y en
runtime cae al fallback:

```astra
fn main() { let x = 5; print(match x { n if n > 9 => 1, _ => 2 }) }
// x=5: debería imprimir 2 (el brazo `_`); hoy: "no match arm matched"
// (antes de §3.8 imprimía nil — también mal)
```

Zig probablemente espeja el mismo `break` (revisar `emitter.zig`
`pattern_bind`). Fix probable: con guardia la armada es *refutable* →
no romper el bucle y parchear el `guard_false` al inicio del siguiente
brazo. Puede arreglarse en la misma tarea o en una aparte.

---

## 2. Modelo del terreno (lo que hay que saber ANTES de tocar nada)

### 2.1 VM (seed `vm.c`; zig `vm.zig` es espejo byte a byte)

- Frame: `slot 0` = callee/retorno; params desde 1; `base + slot` es
  una referencia **absoluta** al stack.
- `SET_LOCAL slot`: `val = pop(); while (base+slot >= sp) push(nil); stack[base+slot] = val;`
  → **net runtime = 0** si `slot == sp-1` (pop + nil-pad de vuelta),
  **−1** si el slot está más abajo (sin pad). `GET_LOCAL` falla con
  `local variable at slot N not initialized` si `base+slot >= sp`.
- `CALL`: `fn_idx = sp - 1 - argc` — el callee debe estar **contiguo**
  con los argumentos. Esto es lo que revienta: entre receptor y
  resultado quedan los huecos del local oculto/binding.
- **El VM nunca encoge el frame**: `pop_scope` del emitter "emits no
  POP" (documentado en el código): tras un bloque, sus locales siguen
  ocupando alto en runtime y sus valores stale quedan para siempre.

### 2.2 Emitter (seed `src/emitter.c`; espejo `zig/src/emitter/emitter.zig`)

- Tabla local: `Local {name, slot, depth}`, `local_count` por
  recuento; `add_local` asigna `slot = local_count++`.
- `e->sp` = altura compile-time. **NO es la altura de runtime**: la
  tabla de efectos (`opcode_stack_effect`) da −1 a `SET_LOCAL`
  incondicionalmente, mientras el runtime netea 0 en el caso fresco
  → offset que crece por cada `let` fresco ejecutado (y depende del
  camino: un `let` dentro de una rama no tomada no deriva).
  Además el offset **no es constante**: los resync `e->sp = base` de
  los brazos del match lo colapsan dentro de los brazos.
- `NODE_MATCH`: snapshot `match_lc0` → (intento previo: pad) →
  `add_local($match_val)` → tests por brazo → fallback `MATCH_NONE`
  (opcode nuevo de §3.8: si ningún brazo casaba, aborta con
  `no match arm matched` en vez de nil) → restore `local_count` y
  `e->sp = base + 1`.
- **Residuos**: cada match en sentencia deja stale: valor del target
  en el slot oculto, bindings, arm-locals — conteo conocido en
  compile-time pero su EFECTO EN LA ALTURA runtime solo se ve en
  runtime (§5.2 muestra la evidencia).
- `emit_branch_value`: exige que cada brazo deje exactamente UN valor
  — su chequeo `sp != before+1` **no contempla los locales del brazo**
  (un `{ let t = 40; t + 2 }` netea +2 en el modelo honesto).
- Chequeos de balance: `sp_check` (expression/statement), el chequeo
  `function 'x' leaves N value(s) on the stack at return` (esperaba
  frame "vacío" bajo la convención vieja "los locales no cuentan").

### 2.3 Convención de alturas (lo que se validó en el intento #2)

- La convención **honest** es `compile = runtime − 1` (el +1 es el
  slot del callee), PERO solo se mantiene recto en sentencia recta;
  dentro de los brazos del match el resync la rompe (offset 0 o 2
  según el punto). Cualquier regla de "frescura" tipo
  `slot == e->sp` se deriva de esa convención y por eso fue frágil.
- El **efevo correcto de `SET_LOCAL` en compile-time** (demostrado por
  aritmética con traces): `net = max(0, slot − sp_pre + 1) − 1`
  — es decir 0 cuando `slot ≥ sp_pre`, −1 en otro caso. Implementado
  en el intento #2 como `fresh_local_set = (index == e->sp)` previo a
  `emit_inst` (funcionó en sentencia recta; falló en brazos por el
  resync).

---

## 3. Evidencia (verbatim, para no repetir los experimentos)

### 3.1 Trace del fallo (repro §1.1, seed, `ASTRA_TRACE=1`)

```
  sp=1 base=0 frame=1 | [<fn>]
  sp=2 base=0 frame=1 | [<fn>][5]           ; CONST 5
  sp=2 base=0 frame=1 | [<fn>][5]           ; SET_LOCAL 1 (let x)
  sp=3 base=0 frame=1 | [<fn>][5][<fn>]     ; GET_GLOBAL print  <-- idx2
  sp=4 base=0 frame=1 | [<fn>][5][<fn>][5]  ; GET_LOCAL target
  sp=3 base=0 frame=1 | [<fn>][5][5]        ; SET_LOCAL 2 <<< idx2 DESTRUIDO
  sp=4 base=0 frame=1 | [<fn>][5][5][5]     ; tests…
  sp=5 base=0 frame=1 | …[1]                ; brazo
  sp=4 base=0 frame=1 | …[false]
  sp=3 base=0 frame=1 | [<fn>][5][5]        ; (misma basura)
  sp=4 base=0 frame=1 | …[20]               ; fallback nil (¡y MATCH_NONE tras §3.8!)
  /tmp/…:1: runtime error: cannot call non-function value
```

### 3.2 Residuos de runtime (por qué la altura real > compile)

`ASTRA_TRACE` de `binding_reclaim` en su match en sentencia — tras la
primera sentencia `match`, el frame queda con valores stale que NADIE
popped (solo el consumidor de la izquierda saca el de arriba):

```
  … tras match #1 (sentencia):
  [fn@0][7@1][Pair.Two(1, 2)@2][3@3][1@4][2@5]   ; idx3,4,5 = STALE
                                                   ; sp=6 antes de print
  ; el receiver `print` se empuja en idx6 — MÁS ALLÁ de lc0=4:
  [fn][7][Pair][3][1][2][<fn>]
```

Conclusión clave: **`rt_sp = compile_sp + 1 + Σ(residuos de matches
anteriores)`** y los residuos crecen con cada match en sentencia.
Todo objetivo estático (pad target, close target, índice del receptor)
debe conocer ese término — y ningún intento previo lo contó.

### 3.3 Bytecode de un caso que casi funciona (block_arm, con pad)

```
[41] CONST 10 (40)        ; let t = 40 dentro del brazo
[42] SET_LOCAL slot=4     ; t
[43] GET_LOCAL slot=4
[44] CONST 11 (2)
[45] ADD                  ; = 42
[46] JUMP
[47] MATCH_NONE           ; fallback sin wildcard (§3.8)
[48] SET_LOCAL slot=3     ; cierre: mueve 42 al slot del oculto
[49] SET_LOCAL slot=3     ; `let n = match…`
…
; sin el POP de residuo: t(40) queda ARRIBA de 42 -> `let n` poppea 40
; salida: 40 (esperado 42)
```

---

## 4. Intento #1 (revertido) — qué se hizo y por qué fracasó

**Diseño:** pad de la tabla de locales hasta `base` en la entrada de
`NODE_MATCH` (el oculto queda sobre los valores vivos) + cierre al
final con `SET_LOCAL(base)` + POPs (`lc1 − base − 1`).

**Qué funcionó:** el caso simple (`s24b` → 20).

**Por qué fracasó:** el pad usaba la altura compile-time, que NO
coincide con la de runtime (efecto −1 de `SET_LOCAL` vs net 0 real);
el offset crece **por cada local fresco ejecutado** y es dependiente
del camino → margen estático insound. Empíricamente: caso de 1 local
bien, `binding_reclaim` (3 lets) roto.

**Alternativas descartadas en el intento #1 (no reintentar sin leer
por qué):**

| Alternativa | Por qué no |
|:------------|:-----------|
| Margen estático de pad (`base + 2`, `base + F_emitidos`) | insound con drift creciente y dependiente de camino |
| Slot derivado de `sp` en compile | requiere altura honesta (el mismo problema) |
| Target sin local (solo stack) | `GET_LOCAL` de los tests de patrón exige un índice absoluto |
| Arreglar desde el CALL | cambiaría la semántica de llamada para todos |

---

## 5. Intento #2 (revertido) — componentes VALIDADOS y el bloqueador

Se implementó como **un solo árbol de trabajo** (no commiteado) con
estos componentes, cada uno verificado en aislamiento:

1. **E1 — efecto honesto de `SET_LOCAL`** en `emit_inst_index`:
   `fresh_local_set = (op == SET_LOCAL) && (index == e->sp)` previo a
   `emit_inst`; si fresco → `sp_advance(+1)` (deshace el −1 de la
   tabla). Regla equivalente por aritmética: `net = (slot ≥ sp_pre) ? 0 : −1`.
2. **`fresh_sets`** (contador de SETs frescos en `priv.h`): cada local
   fresco aporta +1 de alto persistente; `sp_check` pasa a
   `want = before + expected + (fresh − fresh_before)` (término de
   `reclaimed`/`lc` descartado: se contaba doble con `pop_scope`).
3. **Contrato de unión en ramas** (`emit_branch_value`): mide
   `left = delta − fresh_delta == 1`, publica `last_branch_fresh` y
   **restaura** `fresh_sets`/`sp` (los locales de brazo no cruzan la
   unión — mismo trato que los transitorios del match).
4. **`match_fresh0`**: el match restaura `fresh_sets` en el epílogo
   (pad/oculto/bindings son transitorios: el cierre los pliega).
5. **Cierre con contador explícito `close_holes`**: +1 por binding
   (3 sitios de `add_local` en `NODE_MATCH`) y `+= last_branch_fresh`
   tras cada `emit_branch_value` de brazo — sin aritmética de `lc`/`sp`.
6. **RET/ocupación**: `leftover = sp − fresh_sets` en vez de `sp ≠ 0`
   (los locales ocupan alto legal en el frame).
7. **Cierre CONDICIONAL (`if (padded)`)**: en sentencia el valor ya
   está encima del todo y los consumidores por pop bastan (como
   siempre); el cierre solo hace falta con receptor.

**Bisección final (lección: usa variantes de archivo, no la memoria):**

| Variante | binding | s24b | block_arm | mixed | if_value |
|:---------|:-------:|:----:|:---------:|:-----:|:--------:|
| A = lc-formula + branch-erase | ✅ 3/7/3 | ✅ 20 | ❌ 40 | ❌ | ✅ |
| B = self-calc `sp−(base+1)` sin branch-erase | ❌ | ✅ 20 | ❌ 40 | ❌ | ✅ |
| C = self-calc + branch-erase | ❌ | ✅ 20 | ❌ 40 | ❌ | ✅ |
| A + contador `close_holes` | ✅ 3/7/3 | ✅ 20 | ❌ 40 | ❌ | ✅ |
| A + contador + cierre **condicional** | ❌ inline | ✅ 20 | ✅ **42** | ✅ **1/third/2** | ✅ |

Ninguna combinación pasó **todos**: el cierre condicional arregló los
casos de sentencia pero el inline de `binding_reclaim` dejó de
rellenar (`base=4, lc0=4` → el pad no cubre al receptor en idx6 por
los residuos del match previo — ver §3.2).

**Bloqueador estructural (conclusión de #2):** el cierre/pad/receptor
necesitan la altura runtime exacta, y esta = compile + 1 +
`Σ(residuos)` donde cada residuo es el alto stale de un match
completado en sentencia — **creciente, acumulativo y solo
computable si se contabiliza** (§3.2). Los fixes válidos en programa
fresco rompían en `binding_reclaim` precisamente por eso.

---

## 6. Direcciones de fix (diseñadas, ninguna implementada)

### (i) RECOMENDADA — contador compile-time de residuos `rt_residue`

Idea: el emitter **sí** conoce la contribución stale de cada match
(sus slots internos: oculto + pad + bindings + arm-locals, que es
`match_lc1 − base − 1` justo antes del restore — el número que antes
usábamos mal como `close_holes`). Mantener un acumulador:

```c
/* en Emitter */
uint32_t rt_residue;   /* alto stale acumulado por matches completados */
/* en el epílogo de NODE_MATCH, tras restore: */
e->rt_residue += /* slots internos que el runtime conserva:
                    - en sentencia: todos (sin cierre)
                    - en expresión con cierre: solo los que quedan
                      por debajo del resultado movido */;
/* en la entrada de NODE_MATCH: */
int32_t rt_h = base + 1 + (int32_t)e->rt_residue;  /* altura runtime real */
/* pad: while (lc < rt_h) …   (el oculto queda sobre TODO lo vivo)
   índice del receptor = rt_h − 1 (ya no se necesita: el pad lo cubre)
   cierre: SET_LOCAL(base + 1 + ???) … — AQUÍ la duda abierta: el
   cierre debe mover el resultado al índice receptor+1, que es
   `rt_h`… validar con probes qué target exacto deja
   [receiver @ rt_h−1, result @ rt_h] y sp = rt_h+1. */
```

Preguntas abiertas que los probes deben responder (hay que medir, no
deducir): (a) ¿la contribución stale de un match en EXPRESIÓN (con
cierre) es realmente cero para su propio residuo?; (b) ¿los `for`
añaden residuo propio (sus ocultos `for_i/for_arr` también son
stale-permanente)?; (c) ¿el cierre debe apuntar a `rt_h` o a
`base+1` cuando hay residuo? — la matriz de probes del §7 es el
árbitro.

### (ii) Slot dinámico en runtime

Opcode nuevo (contrato compartido `astra.h` + `bytecode.zig`): por
ejemplo `SET_LOCAL_DYN` — la VM elige el índice (`sp−1` o un registro
de match por frame) y los tests de brazo usan `GET_LOCAL_DYN`. Elige
la altura correcta donde solo la VM la conoce. Coste: opcode nuevo en
4-5 switches (vm.c, vm.zig, emitter.c, emitter.zig, codegen.c) +
modelos de efecto.

### (iii) Reclamar el alto en origen

Al terminar cada match (también en sentencia), POPear el alto stale
para que `rt_sp` vuelva a `base+1` — elimina los residuos de raíz y
con ellos el bloqueador. PERO: hacerlo exige conocer la altura exacta
(= necesita (i) o (ii))… y además CHOCA con los consumidores actuales
de sentencia (el valor del match se poppea con POP del statement; si
el cierre también corre, se poppea dos veces). Es la dirección más
invasiva: evaluar solo después de (i).

---

## 7. Invariants y tests que el fix DEBE preservar

Arbitro final = la suite. Mandatorios:

| Test | Esperado |
|:-----|:---------|
| `./seed/tests/run_tests.sh` | **224/224** |
| `./tests/sweep_emit_c.sh` | **84/84** skip=3 |
| `./astra-seed --check-constructs` | OK |
| `./zig/tests/dump_parity.sh` | **112/112** |
| `./zig/tests/ui_message_parity.sh` | total=115, first_fail=0, known=0 |
| `cd zig && zig build test --summary all` | 73/73 |

Probes de comportamiento (re-hazlos, están en `/tmp/opencode/` que es
efímero — recrea de este doc):

| Probe | Código | Esperado (VM seed = zig = C donde aplique) |
|:------|:-------|:-------------------------------------------|
| s24b | `fn main() { let x = 5; print(match x { 1 => 10, _ => 20 }) }` | `20`, rc=0 |
| binding_reclaim | suite `enums/match_binding_reclaim.astra` | `3\n7\n3` |
| block_arm | suite `enums/match_block_arm.astra` | `true\n42` |
| mixed | suite `enums/mixed_patterns.astra` | `1\nthird\n2` |
| if_value | suite `blocks/if_value.astra` | `6\n10\n20` |
| s25a | `print(match x { _ => match y { _ => 40 } })` | `40` |
| s25b | `print([match x { _ => 1 }])` | `[1]` |
| s22b | sentencia (`let r = match o { some(v) => v, none => 0 }` con `o = ok(7)`) | `nil`-trampa de §3.8 → **`no match arm matched`** (NO romper el backstop) |

Invariantes de `AGENTS.md` que aplican: balance de pila (1), offsets
`T-P` (2), frames slot 0/1 (3), arena-only (5). Reglas del loop:
`make debug` siempre (ASan), warnings = fallo, **zig espeja el fix**
(misma semántica en `emitter.zig`; su emitter tiene el mismo bug),
commit convencional español, push + CI verde.

## 8. Trampas conocidas (lecciones de los intentos)

1. **Baseline por stash/mtime:** `git stash && make debug` NO siempre
   reconstruye (mtime) — te da un baseline falso que "confirma" cosas
   que no son. Usa `touch src/emitter.c && make debug` o un worktree.
2. **`===` rompe zsh** y los `sed -e` con comillas imposibles — usa
   `python3 - <<'PYEOF'` para editar con asserts (`assert s.count(x)==1`)
   y verifica SIEMPRE que el assert pasó (varias veces un script
   abortó a medias y los "tests" corrieron contra el mismo código).
3. **Sub-agentes en paralelo en el mismo árbol** reconstruyen el
   binario mientras tú mides — no midas con agents vivos.
4. `ASTRA_TRACE=1` (pila por instrucción) y `ASTRA_DUMP_VM=1`
   (bytecode) son tus ojos; `ASTRA_DBG_SET=1` no existe — se instrumenta
   con `getenv` temporal (quitar antes del commit).
5. `msg_diff_full` sube con tests nuevos de cascada — es informativo;
   el gate es `first_fail`/`known`.
6. El emitter tiene CHEQUEOS internos (`internal: stack imbalance…`,
   `leaves N value(s)…`, `body left N values…`) que **validan la
   convención vieja** ("los locales no cuentan en `e->sp`"): si cambias
   la convención de altura, hay que actualizarlos en bloque (el intento
   #2 lo hizo con el término `fresh`; funcionó — ver §5).

## 9. Inventario de archivos del territorio

- `seed/src/emitter.c` — `NODE_MATCH` (~1326+), `emit_inst_index`,
  `opcode_stack_effect`, `sp_check`, `emit_branch_value`,
  `emit_value_branch`, `add_local`/`find_local`/`pop_scope`, chequeo
  RET de fn/lambda.
- `seed/src/priv.h` — `struct Emitter` (campos `locals`, `local_count`,
  `sp`, `scope_depth`…; contrato compartido light — cambios aquí avisar).
- `seed/src/vm.c` — `SET_LOCAL`/`GET_LOCAL`/`CALL`/`MATCH_NONE`.
- Espejo zig: `zig/src/emitter/emitter.zig` (`emitMatch`, `addLocal`,
  `setLocal`…), `zig/src/vm/vm.zig`, `zig/src/emitter/bytecode.zig`.
- Tests: `seed/tests/conformance/enums/match_binding_reclaim.astra`,
  `enums/match_block_arm.astra`, `enums/mixed_patterns.astra`,
  `blocks/if_value.astra`, `expressions/match_fallthrough_trap.astra`.
- Contexto del audit: `Documentacion/06_auditorias/PRE_LLVM_AUDIT.md` §4.7 (fila)
  y §3.8/§4.3 (el opcode `MATCH_NONE` y el snapshot `match_lc0` que
  ya existen y no deben perderse).

## 10. Definición de hecho

1. `s24b`, `s25a`, `s25b` → salen correctos en seed **y** zig.
2. Los 6 probes de la tabla §7 correctos en los tres backends.
3. Batería completa verde (§7) + CI verde.
4. (Opcional pero deseado) bug §4.8 (bind+guard) arreglado o
   registrado en `PRE_LLVM_AUDIT` como fila nueva.
5. Fila §4.7 → ✅ fix `<hash>`; este dossier → cabecera
   "RESUELTA el <fecha> por <hash>" con un párrafo final de *qué*
   funcionó (la dirección (i)/(ii)/(iii) real, no la teórica).
6. Commit `fix(lang): … (audit §4.7)` en español, push, CI.

---

## 11. Resolución (2026-10-15, `ed1792e`) — qué funcionó de verdad

Los items 1-3 y 6 de §10 se cumplen (229/229 en seed — 224 originales +
5 tests nuevos —, sweep 88/88 skip=3, `--check-constructs` OK,
`zig build test` 73/73, `dump_parity` 117/117 con 0 divergentes,
`ui_message_parity` total=115 first_fail=0 known=0, CI verde, y 40
probes sin una sola divergencia seed↔zig). El item 4 (§4.8) **no** se
arregló y quedó registrado como fila nueva del audit; hoy está cerrado
como §4.8+§4.11 (`a29f1af`, 2026-10-16 — ver el párrafo de cierre más
abajo en §11). El item 5 (esta
cabecera) es este párrafo.

**La dirección (i), pero con cuatro piezas que los intentos previos no
tuvo y una que rechazó:**

1. **Altura exacta `e->rt` en paralelo al `sp` viejo** (la convención
   `compile = runtime − 1` de §2.3 NO se tocó: los chequeos internos
   siguen validando la convención vieja). `rt_advance` modela
   `SET_LOCAL` como `max(rt−1, slot+1)` — exactamente lo que hace
   `vm.c` — y **cada** resync (`&&`/`||`, brazos del match, epílogo,
   ramas del `if`, entrada/salida de fn/lambda) lo empareja con su
   valor exacto. Sin esto, cualquier objetivo estático sigue a ciegas.
2. **Pad hasta la frontera runtime** en la entrada de `match` e `if`
   (`pad_locals_to_rt`): el oculto, los bindings y los `let` de brazo
   obtienen slots `== rt`, es decir, donde el runtime empuja de verdad.
   Gracias al pad, durante el construct `local_count == rt` y cada
   `SET_LOCAL` es fresco por construcción.
3. **Cierre POR CAMINO** (`emit_value_close` = `SET_LOCAL(target)` +
   `POP` de excedentes), emitido tras **cada** `emit_branch_value` y en
   las aristas `guard=false`. El intento #2 cerraba una sola vez al
   final (`variant A`: `block_arm` ❌ 40) — el cierre por camino es lo
   que resolvió el conteo dependiente-del-camino de los locales de
   brazo. Efecto colateral decisivo: **los matches en sentencia ya no
   dejan residuo** (el cierre lo reclama en origen) — el bloqueador
   estructural de §5 desaparece en vez de contabilizarse.
4. **Normalización de bucles**: `emit_loop_exit_ensure` al objetivo de
   salida de `while`/`for` (crea con `CONST nil; SET_LOCAL` las celdas
   que solo creó un camino: 0 iteraciones, `break` temprano) y **stubs
   de reconciliación para `break`** en `loop_leave` (un `break` salta
   los cierres del `if`/`match` por los que pasa y deja celdas de más;
   cada `break` estatura su altura en el offset placeholder y el stub
   hace el `POP` exacto antes del join — pinjado por
   `loops/loop_residue_inline.astra`).
5. **Pieza que los intentos previos rechazaron y aquí fue
   imprescindible: el backend C.** Los closes estáticos direccionan
   `target` en coordenadas de frame; el C backend pre-alocaba
   `[0, max_slot)` y su receptor vivía en `max_slot`, no en la frontera
   del VM. `codegen.c` ahora replica `vm.c` al pie de la letra:
   `SET_LOCAL` con pad de nil y `sp = local_count` en `emit_fn_body`
   (no `max_slot`). Sin esto, `s24b` rompía en el binario C aunque el
   VM imprimiera `20`.

**Adyacentes resueltos en el mismo commit:** `print(if … { let … })`
(el §1.2 daba el `if` por "correcto" — lo era solo sin `let` en rama);
`NEW_ENUM` no corregía `rt` (la construcción `A(3,1)` inflaba la
frontera y rompía el match siguiente — hallazgo del espejo zig); el
`guard_false` de los brazos `_ if`/bind aterrizaba *después* del
`CONST nil` (off-by-one que dejaba la pila sin valor).

**§4.8 → CERRADO como `a29f1af` (2026-10-16), junto con §4.11:** el
`break` incondicional tras un binding (o wildcard) con guardia ya no
corta el bucle de brazos — la armada con guardia es *refutable* y su
`guard_false` cae al brazo siguiente a la altura de entrada, con un POP
de reconciliación cuando el binding dejó celda viva; el backstop
MATCH_NONE ahora solo lo suprime un catch-all **sin** guardia (antes el
wildcard con guardia devolvía nil silencioso en
`_ if c => 1, n => n + 100`). La sugerencia de reutilizar el stub POP de
variantes/builtins se siguió… y **destapó §4.11**: ese stub era código
muerto desde `ed1792e` (el re-parcheo de `arm_gf_patch` volvía a apuntar
el JIF al final de la iteración, saltándose el POP) y su count era
`bind_count` a ciegas cuando el drop exacto es `bind_rt − rt_test` —
`match v { E.B(n) if n > 1 => n, _ => 0 }` con v=B(1) trapeaba
`cannot call non-function value` en los tres backends. Ambos bugs cerrados
en el mismo commit, en seed y zig, con tests
`enums/match_guard_fallthrough.astra` y `enums/match_guard_payload_stub.astra`
(+ gemelos codegen); ver la sección datada del audit §4.8+§4.11.

**Hueco conocido → CERRADO como §4.10 (`4cc9ca2`, 2026-10-16):** el
"por debajo del modelo" resultó ser **más ancho** que el escenario
`continue`-que-salta-declaraciones de aquí arriba: la normalización
faltaba en el **back-edge** (el cuerpo de la iteración ≥2 corría a la
altura del fin del cuerpo mientras el código asumía la de entrada) y en
`continue` (saltaba al objetivo sin reconciliar). El repro mínimo no
llevaba `continue`: `for i in 0..3 { let e = B(s); print(match e { … });
let z = 0 }` trapeaba `cannot call non-function value` en la iteración 2
— el close del match pisaba la celda del receptor de `print` y el
`CALL` leía una celda stale vía `sp-1-argc`. El tratamiento prescrito
aquí (stub de reconciliación con patrón `break`) se aplicó a los dos
sitios: drenaje POP en el back-edge hasta `head_rt` y stubs por
`continue` hasta `continue_rt` (POP si la ruta llega alta, `CONST nil`
si llega baja). Descubierto con una batería diferencial
`continue`-vs-guarda (150 pares → 2 divergencias; tras el fix, 750
pares a 5 semillas, 0 divergencias) y pineado en
`conformance/loops/iter_height_norm.astra` + gemelo
`codegen/loop_iter_height.astra`. El detalle del cierre está en el
audit §4.10.

**Trampas nuevas aprendidas (añadir a §8):** los brazos
variant/builtin caen en una **copia plain duplicada** del mismo brazo
(`emitter.c` no tiene `break` al final de esos bloques): re-testear allí
es inofensivo, pero una arista `guard=false` aterrizando en la copia
re-evaluaba la guardia sobre bindings nunca extraídos — los stubs
emergentes se parchan AL FINAL de la iteración, no dentro del bloque.
Y los tests nuevos se escriben con la sintaxis real de Astra-0:
`let mut`, `i32`, variantes de enum separadas por espacio/línea,
construcción con el nombre plano (`A(3)`), lambdas `|x: i32| -> i32`.
