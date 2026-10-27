# 028 — Stdlib mínimo de Astra-0 para escribir el propio lexer (primer paso de self-hosting)

> **Alcance**: investigación y planificación. Ningún código de producción ni
> test se toca en este documento. Fecha: 2026-10-27. **[verificado]** = ejecutado
> o leído en este repo durante la sesión (seed compilado con `make`, zig
> `zig-out/bin/astra-zig` con LLVM, programas en
> `/tmp/opencode/astra-critica/selfhost/`); **[citado]** = conocimiento de
> dominio sobre otros lenguajes, no consultado en línea (la búsqueda web no
> estuvo disponible). Los plazos de §3 son estimaciones, no mediciones.

---

## 0. Resumen ejecutivo

**MVP (4 primitivas)** — con ellas ya se puede escribir `lexer.astra`:

| # | Primitiva | Firma | Coste real |
|:-:|:----------|:------|:-----------|
| 1 | `len` | `len(x: string \| [T]) -> i64` | **Bajo**: el opcode `OPCODE_LEN` ya acepta arrays **y strings** en los tres handlers de bytecode; solo falta *exponerlo* |
| 2 | índice de string | `s[i]` → `string` de 1 byte (reutiliza `OPCODE_INDEX`) | **Medio**: typechecker + handler en 3 rutas + emisión LLVM + helper de alloc de 1 byte |
| 3 | lectura de fichero | `read_file(path: string) -> string` (error de runtime si no abre) | **Medio-alto**: builtin nuevo ×4 implementaciones + `preopens` en el runner de wasm |
| 4 | int→string | `to_string(i: i64) -> string` | **Bajo-medio**: builtin nuevo, pero `print` admite **1 solo argumento** y `+` no convierte ⇒ sin esto no hay salida con números |

**M2 (para un lexer de verdad, no para la demo)**: `push`, `ord`, `substr`,
`str_to_int`. **M3**: `chr`, `read_line`, `for c in s`, `contains`/`split`.

**Esfuerzo por ruta (estimación)**:

| Ruta | Ficheros | Estimación | ¿Comparte código con otra ruta? |
|:-----|:---------|:-----------|:--------------------------------|
| seed VM (`vm.c`+`typechecker.c`) | 2–3 | 1–2 d por builtin | no |
| backend C (`codegen.c`+`codegen_runtime.h`) | 2 | 0,5–1 d | **sí**: `astra_runtime_llvm.c` incluye `codegen_runtime.h` (línea 23), así que el *corazón* del builtin se escribe una vez para C y LLVM |
| zig VM (`vm.zig`+`typechecker.zig`) | 2 | 1 d (espejo del seed) | no |
| LLVM (`emitter.zig` + `astra_runtime_llvm.c`) | 2 | 1–2 d | JIT/wasm/aarch64 **cero código**: comparten el mismo runtime TU |
| **Total por builtin completo** | **8–9** | **~4–6 d** | 4 implementaciones, 9 gates |

**Plan de 4 PRs** (§3): PR1 `len` + `s[i]` → PR2 `to_string` + `read_file` →
PR3 `lexer.astra` + gate dedicado → PR4 M2 (`push`/`ord`/`substr`/`str_to_int`).

**Hallazgo central**: el trabajo no está en el runtime sino en la *exposición*.
`OPCODE_LEN` ya calcula `len` de strings con el mismo texto de error en las
tres rutas **[verificado]**, `==` entre strings ya compara por contenido
**[verificado]**, `match` con literales de string y or-patterns ya funciona en
4 rutas **[verificado]** — pero **no se puede escribir `len(s)`** porque
`print` es el único builtin *función* registrado (además de los tipos
`Option`/`Result`) y **los dos VMs despachan *todo* builtin a
`builtinPrint`** (`vm.c:1402-1409`, `vm.zig:1215-1218`)
**[verificado]**. El coste de cada builtin nuevo es, por tanto, 8 ficheros y
4 implementaciones, no uno.

**Riesgo que gobierna el plan**: la suite `tests/conformance/` es **compartida
por cuatro implementaciones** (seed VM, backend C vía `sweep_emit_c.sh`, zig VM
vía `conformance.zig`, ruta LLVM vía `llvm_parity.sh`) **[verificado]**. Un
builtin implementado «solo en el seed» no pasa la CI: `zig build test` falla
en el typechecker zig y `sweep_emit_c.sh` falla en el backend C. La regla de
AGENTS.md («el zig debe aceptar todo lo que acepta el seed») **aplica a
builtins**, no solo a sintaxis — y así se resolvió para `print`: siempre estuvo
en los 4 sitios a la vez.

---

## 1. Superficie mínima, firmas y justificación

### 1.1 Qué tiene Astra-0 hoy (todo [verificado] con ejecución)

| Capacidade | Estado | Evidencia |
|:-----------|:-------|:----------|
| `print` (1 argumento) | ✅ único builtin función | `vm.c:381`, `typechecker.c:611-624` registra **1 parámetro**; `print(1, 2)` → `expected 1 arguments, got 2` (p18) |
| Literales y `+` de string | ✅ | `vm.c:761-765` concat por longitud; p1: `"a"+"b"` → `ab` |
| `==` / `!=` de string (contenido) | ✅ | `vm.c:275 value_eq` + `:319` case VAL_STRING; p1 → `true`; suite `expressions/empty_string_eq.astra` |
| `<` de string | ❌ runtime error | `expressions/string_order_rejected.astra` → `cannot compare string and string` (ejecutado, rc=1) |
| `s[i]` sobre string | ❌ | typechecker `typechecker.c:1754-1758` → `cannot index non-array type string` (t2); `vm.c:1147` solo `VAL_ARRAY`; zig `typechecker.zig:1177`; LLVM `emitter.zig:1418` |
| `len(...)` | ❌ como símbolo, ✅ como opcode | `grep '"len"'` → 0; `OPCODE_LEN` acepta array **y string** en `vm.c:1164-1180`, `codegen.c:1129-1144`, `vm.zig:1083-1093` (mismo texto `cannot take length of X`) |
| `push` / crecer un array | ❌ | `a[2] = 3` sobre `[1,2]` → `index 2 out of bounds (len 2)` (p2); no hay `realloc` en el runtime |
| `to_string` / `str_to_int` | ❌ | `grep '"to_string"'` → 0; t3 → `undefined variable` |
| I/O de fichero/stdin | ❌ | `input(` → 0 en `seed/src` y `zig/src`; `fopen`/`read_file` solo existen en el driver C `main.c:30-31` (leen el fuente `.astra`); ningún builtin de I/O en `vm.c` ni `vm.zig` |
| char→int / char literal | ❌ | `'a'` → `unexpected character` (p4); no hay tipo `char` |
| `for .. in` array / rango | ✅ | p7 → `6`, `0 1 2`; `emitter.c:2066-2078` emite `LEN`+`INDEX` |
| `for .. in string` | ❌ | `typechecker.c:2048-2051` → `must iterate over an array or range, got string` (t6) — **aunque el opcode ya sirve** |
| `match` con literal de string + `_` | ✅ | p8 → `1 0` en **seed VM, backend C (`--emit-c`+gcc), zig VM y ruta LLVM** (emit-obj+link+run, rc=0) |
| or-patterns en `match` (`"0" \| "1"`) | ✅ | p22 → `true false` en las **4 rutas** |
| `while`, `break`/`continue`, `if`/`else if`, `if`-expresión | ✅ | p7, p17, p25 |
| `&&` / `\|\|` con llamadas y comparaciones de string | ✅ | p25 en seed y zig → `5 / or-works / 1` |
| closures `\|x: i32\| -> i32 { }`, structs sin comas, arrays con `[]` | ✅ | suite `lambda/closures.astra`, p15/p14 |
| Compuesto `+=` | ❌ (diseño) | `ui/compound_assign_rejected.astra` |
| Hex `0x41` | ✅ | p5 → `65` |
| `?` sobre `Result`/`Option` | ✅ | suite `enums/`, `types/` |

### 1.2 Lista FINAL con prioridad

**M1 — MVP, bloqueante para `lexer.astra`:**

```astra
len(x: string) -> i64          // y len(x: [T]) -> i64; receptores no-string/array en compile-time
s[i]   : string, i64 -> string // 1 byte; out-of-bounds = runtime error
                              //   "index N out of bounds (len M)" (mismo texto que arrays)
read_file(path: string) -> string   // si no abre: runtime error (estilo Astra-0)
to_string(i: i64) -> string    // snprintf("%ld")
```

Justificación una a una:

1. **`len`** — sin él no hay bucle `while i < len(src)`. *Ya está implementado
   en los tres handlers de bytecode* (§1.1); solo falta registrarlo como
   símbolo y exponerlo. Es la primitiva más barata de las cuatro.
2. **`s[i]` → 1 byte como `string`** — decisión de diseño:
   - *1-byte-string* (Python) frente a *código numérico* (Go): elijo
     `string` porque **`match c { "(" => …, _ => … }` ya funciona en 4 rutas**
     (p8) y porque `value_eq` ya compara por contenido; con `i64` habría que
     escribir `ord("a")` para cada comparación y **no existe char literal**
     (p4). Un lexer mini compara caracteres contra literales todo el día.
   - *byte* frente a *codepoint*: **byte**, porque el lexer del seed es
     byte-oriented (`lexer.c` recorre `char` sin UTF-8, `read_string` solo
     sabe `\n \t \r \\ \"` — leído en `seed/src/lexer.c:141-175`) y las
     strings son buffers con longitud explícita (`vm.c:209-211` usa
     `fwrite(..., len)` precisamente para no cortar en un NUL). Indexar por
     byte reproduce el comportamiento del lexer C que queremos emular.
   - *¿`char_at(s,i)` builtin en vez de `s[i]`?* No: `s[i]` reutiliza
     `OPCODE_INDEX` (ya existe en `vm.c:1140`, `codegen.c:1110`, `vm.zig:1072`)
     y no consume el presupuesto de builtin; `char_at` obligaría al
     plumbing completo por un solo número.
3. **`read_file`** — sin entrada no hay lexer. `ARCHITECTURE.md:1617` ya
   especifica `read_file(path)?` con `FileError`, así que el nombre está
   fijado por la spec; el MVP devuelve `string` y falla en runtime (barato en
   las 7 rutas), M2 sube a `-> Result[string, string]` con `value_ok`
   (`vm.c:127`) / `astra_ok` (`codegen_runtime.h:350`), que ya existen.
4. **`to_string`** — **imprescindible, no cosmético**: `print` acepta exactamente
   1 argumento (p18) y `"n" + 1` es error de tipo (`arithmetic operator
   requires numeric type, got string`, p20/p21). Con `print` como única
   salida, cualquier mensaje con números (`ERROR en línea 12`) necesita
   `to_string`. *Existe una salida sin números* (`print(kind + " " + lex)`) y
   por eso `to_string` sería opcional en una demo mínima; pero el lexer real
   reporta líneas y columnas, y `ARCHITECTURE.md:1819` ya lo da por hecho
   (`.to_string()` / `.parse()`).

**M2 — lexer «de verdad» y primer pasos del parser:**

```astra
push(a: [T], v: T) -> [T]            // arrays no crecen hoy [verificado p2]
ord(c: string) -> i64                // primer byte; clasificación O(1)
substr(s: string, start: i64, end: i64) -> string   // lexemas O(n) en vez de concat O(n²)
str_to_int(s: string) -> i64?        // literales numéricos (parser); o Result[i64, string]
```

**M3 — deseable, no bloquea:**

```astra
chr(i: i64) -> string
read_line() -> string?               // stdin (la otra mitad de la entrada)
for c in s { … }                     // azúcar: typecheck_for acepta TYPE_STRING
contains(s, sub) / index_of / split  // en Astra puro sobre M1+M2
```

**Workarounds que ya funcionan sin tocar código (todos [verificado]):**

| Necesidad | Truco hoy | Coste |
|:----------|:----------|:------|
| `is_digit` / `is_alpha` | or-patterns de 10/52 ramas en `match` (p22, 4 rutas) | feo, correcto, O(1) |
| lexema acumulado | `word = word + s[i]` en bucle | O(n²), vale para la demo |
| salida multi-campo | un solo `print(...)` con concatenación de strings | sin números, o `to_string` |
| keywords | `match word { "fn" => …, _ => … }` (p8) | ya es lo que hace el seed (`lexer.c:8-43`, 36 keywords) |
| recorrer la fuente | `while i < n { … }` con `len`+índice | idéntico al lexer C (cursor `pos`) |

### 1.3 Decisiones que hay que escribir antes de implementar

1. **Sombreado de nombres**: hoy `let print = 5` se acepta y luego
   `print(...)` muere con `cannot call non-function type i32` (p28, igual en
   seed y zig) mientras `fn print` da `duplicate function 'print'`
   (`typechecker.c:3069-3074`). Con más builtins el síntoma se multiplica:
   **recomendación**: rechazar en el typechecker cualquier `let`/`fn` global
   con nombre de builtin, en ambos compilers con el mismo texto.
2. **Discriminador de builtin**: `FnObj` no tiene id (`astra.h:1044-1053`;
   `bytecode.zig:196-207`) y **ambos VMs despachan todo a `print`**
   (`vm.c:1403-1409`, `vm.zig:1215-1218`). Dos salidas:
   - **(A) `uint8_t builtin_id` en `FnObj`** — limpio, pero toca
     `include/astra/astra.h`, que AGENTS.md marca como *shared contract*
     (un solo workstream lo cambia primero).
   - **(B) tabla de punteros** `vm->builtins[]` + identidad de puntero en
     `OPCODE_CALL` — cero cambios de cabecera compartida, `O(1)` con N chico.
   Recomiendo **(A)** por legibilidad; (B) si se quiere el PR sin tocar
   `astra.h`.
3. **`len(…)` ¿compile-time o runtime?**: aceptar `TYPE_UNKNOWN` (como `print`,
   `typechecker.c:615`) es gratis y los tres handlers ya coinciden en
   `cannot take length of int` (`vm.c:185`, `codegen_runtime.h:160`,
   `vm.zig:59-61`); restringir a `string|array` es mejor lenguaje pero exige
   un caso `ui/` con **primera línea byte-idéntica en ambos compilers**
   (`ui_message_parity.sh`). Recomiendo restringir ya y añadir el `ui/` en el
   mismo PR, verificando el gate localmente antes de subir.

---

## 2. Mapa de puntos de toque por backend

### 2.1 Cómo funciona hoy `print` (traza completa, [verificado])

```
typechecker.c:611-624   registra el símbolo "print": fn(TYPE_UNKNOWN) -> void
emitter.c               (sin dispatch del builtin: solo comentarios en `printf`/`value_print`) emite
                        GET_GLOBAL "print" + CALL argc
vm.c:689-690            GET_GLOBAL: si el nombre es "print" → push(builtin_print_fn)
vm.c:1402-1409          OPCODE_CALL: param_count==255 && code==NULL → builtin_print(args, argc)
vm.c:1717-1726          vm_create crea el FnObj marcador (param_count = 255)
codegen.c:572/582/1411  declara `static AstraValue g_print`, su init y la llamada a ese init
codegen.c:767            constante `VAL_FN` de builtin en el pool → astra_builtin_fn_new(print, 255)
codegen.c:878-888        GET_GLOBAL **genérico**: nombre → `g_<cname>` (no conoce a print)
codegen.c:1007-1018     dispatch de llamada GENÉRICO: `fun(args, argc)` (¡no conoce a print!)
codegen_runtime.h:770   astra_builtin_print (static inline)
zig typechecker.zig:402 espejo del registro
zig vm.zig:815/1215     espejo de GET_GLOBAL y CALL (→ builtinPrint, vm.zig:1396)
zig llvm/emitter.zig:3069  emitCall: `if (name == "print") return emitPrint(idx)` (inline, por nombre)
zig llvm/emitter.zig:4155  inferencia de tipo de retorno para llamadas a print
zig llvm/runtime/astra_runtime_llvm.c:163-216  astra_llvm_print_* (imprime por tipo SSA)
```

Tres observaciones que determinan el coste:

- **El backend C ya despacha genéricamente** (`codegen.c:1014-1018` llama a
  `fun(args, argc)`): añadir un builtin allí es *solo* la tabla
  nombre→función (4 sitios hoy hardcodeados con `strcmp(..., "print")`).
- **La ruta LLVM no usa objetos de función**: emite la llamada inline por
  nombre de compilación. Un builtin nuevo es una rama en `emitCall` + una
  función en el runtime.
- **`codegen_runtime.h` es compartido**: `astra_runtime_llvm.c:23` lo incluye
  (único incluidor, porque el header *define* sus globals — AGENTS.md). El
  cuerpo de un builtin puede escribirse **una sola vez** para C y LLVM; la
  ruta LLVM solo añade un wrapper no-static (`astra_llvm_*`), como ya hace
  con `astra_llvm_str_concat` (`astra_runtime_llvm.c:224`).

### 2.2 Tabla builtin × ruta × archivo [verificado]

| Punto de toque | Archivo:línea | `len` | `s[i]` | `to_string` | `read_file` | `push` |
|:---------------|:--------------|:-----:|:------:|:-----------:|:-----------:|:------:|
| seed — símbolo | `seed/src/typechecker.c:611` | ✔ tabla | — (rama en `typecheck_index:1750`) | ✔ tabla | ✔ tabla | ✔ tabla |
| seed — GET_GLOBAL | `seed/src/vm.c:689` | ✔ | — | ✔ | ✔ | ✔ |
| seed — dispatch CALL | `seed/src/vm.c:1402` | ✔ discriminador | — | ✔ | ✔ | ✔ |
| seed — handler opcode | `seed/src/vm.c:1164` (LEN, ya string) / `:1140` (INDEX) | ya ✅ | rama `VAL_STRING` | — | — | — |
| seed — cuerpo builtin | `seed/src/vm.c:381` (patrón) | nuevo | — | nuevo | nuevo | nuevo |
| backend C — init/nombre | `seed/src/codegen.c:572,582,767,1411` | tabla | — | tabla | tabla | tabla |
| backend C — handler opcode | `seed/src/codegen.c:1129` (LEN, ya string) / `:1110` (INDEX) | ya ✅ | rama `AST_STRING` | — | — | — |
| backend C — runtime | `seed/src/codegen_runtime.h` (patrón `:770`) | nuevo | helper (patrón `astra_string_new:238`) | nuevo | nuevo (`fopen`) | nuevo (grow) |
| zig — símbolo | `zig/src/typechecker/typechecker.zig:402` | ✔ | — (rama en `checkIndex:1172`) | ✔ | ✔ | ✔ |
| zig — GET_GLOBAL / CALL | `zig/src/vm/vm.zig:815` / `:1215` | ✔ | — | ✔ | ✔ | ✔ |
| zig — handler opcode | `zig/src/vm/vm.zig:1083` (LEN, ya string) / `:1072` (INDEX) | ya ✅ | rama `.string` | — | — | — |
| LLVM — emisión de llamada | `zig/src/llvm/emitter.zig:3069` (patrón print) | ✔ | — | ✔ | ✔ | ✔ |
| LLVM — inferencia retorno | `zig/src/llvm/emitter.zig:4155` | ✔ | ✔ | ✔ | ✔ | ✔ |
| LLVM — emisión de índice | `zig/src/llvm/emitter.zig:1415` | — | rama `str_` + bounds check | — | — | — |
| LLVM — runtime | `zig/src/llvm/runtime/astra_runtime_llvm.c` | **no hace falta**: `len` = load `i64` en offset 0 (hace `emitFor:2039-2055`) | helper 1-byte (patrón `str_concat:224`) | wrapper sobre `codegen_runtime.h` | wrapper `fopen` | wrapper grow |
| JIT (`--jit`) | `zig/src/llvm/jit.zig` | — comparte LLVM — | | | | |
| wasm (`--target=wasm32-wasi`) | `demo/wasi_run.mjs` | comparte | comparte | comparte | **+ `preopens`** (hoy no hay ninguno) | comparte |
| aarch64 (`--target=aarch64-linux-gnu`) | `zig/src/llvm/target.zig` | comparte | comparte | comparte | comparte (cwd bajo qemu) | comparte |

**Regla práctica**: 8–9 ficheros, 4 implementaciones reales (seed VM, backend
C, zig VM, LLVM+runtime), 0 en JIT/wasm/aarch64 salvo I/O.

### 2.3 Gates: qué falla si solo se implementa en el seed

| Gate | CI job | ¿Fallaría con `len` solo en el seed? | Por qué |
|:-----|:-------|:--------------------------------------|:--------|
| `tests/run_tests.sh` (`make test`) | `seed (C)` | ❌ no falla, pero es la mitad débil | solo prueba lo que ya pasa en el seed |
| **`tests/sweep_emit_c.sh`** | `seed (C)` | **✅ FALLA** si hay caso nuevo en `conformance/` | corre **todo** caso no-UI por VM **y** por `--emit-c`+gcc comparando byte a byte (`sweep_emit_c.sh:1-60`) |
| **`zig build test`** | `zig (Phase 2)` | **✅ FALLA** | `conformance.zig` compila **cada** caso no-UI de `seed/tests/conformance/` con el typechecker zig → `undefined variable 'len'` |
| `dump parity` | `dump parity` | ❌ no | solo `--dump-tokens`/`--dump-ast`; un builtin no cambia tokens ni AST |
| `ui diagnostic messages` | `dump parity` | solo si se añade caso `ui/` | primera línea byte-idéntica |
| `llvm_parity.sh` (y `-O2`) | `llvm` | ⚠️ **no falla: SKIP** | si `--emit-obj` responde `not supported by the LLVM backend` el caso se cuenta como `skip` (`llvm_parity.sh:129-135`) — **agujero silencioso**: el total sube, `ok` no |
| `llvm_jit.sh` ×2 | `llvm` | ⚠️ skip | misma disciplina (`llvm_jit.sh:84-89`) |
| `llvm_cross.sh` (aarch64) | `llvm-cross` | ⚠️ skip | idem (`llvm_cross.sh:89-93`) |
| `llvm_wasm.sh` ×2 | `llvm-wasm` | ⚠️ skip; con `read_file` **FAIL** | idem + **`demo/wasi_run.mjs` no declara `preopens`**, luego `fopen` falla en WASI y la salida diverge de la VM |
| `llvm_filecheck.sh` | `llvm` | ❌ no | solo fija shapes de IR de fixtures propios |
| `llvm_sanitize.sh` | `llvm` | ❌ no (salvo fuga/ASan nuevo) | ASan/LSan sobre la ruta LLVM |
| fuzz (`make fuzz … -runs=0`) | `seed (C)` | ⚠️ solo si el caso nuevo tropieza con ASan | los `.astra` nuevos entran solos en el corpus |
| `codeql.yml` | no bloquea | ❌ no | análisis estático C |

**Conclusión**: implementar «solo seed + C» y dejar zig para el PR siguiente
**no es viable** si el PR trae casos de conformance (que es la regla del repo:
«add or update conformance cases for the behaviour it introduced»). El mínimo
viable de un PR es **seed VM + backend C + zig VM**; la ruta LLVM puede ir en
el mismo PR (recomendado: el número `159/159` es parte de la reputación del
gate) o en un PR1b explícito aceptando `skip` contados.

**¿Aplica la regla «zig acepta todo lo que acepta el seed» a builtins?** Sí.
`zig/src/conformance.zig:1-15` lo dice sin ambigüedad («the Zig compiler must
accept every Astra program the C seed accepts … and run every program to the
same stdout») y `findRoot` **falla en verde** si no encuentra la suite. Para
`print` la respuesta histórica es la evidencia: el símbolo está registrado en
**ambos** typecheckers (`typechecker.c:611` / `typechecker.zig:402`), el
dispatch existe en **ambos** VM (`vm.c:689` / `vm.zig:815`) y en **las dos**
rutas de emisión (`codegen.c:572` / `emitter.zig:3069`) — nunca se añadió de
forma incremental.

### 2.4 Riesgos concretos del «plumbing»

| Riesgo | Evidencia | Mitigación |
|:-------|:----------|:-----------|
| Olvidar un sitio hardcodeado de `print` en `codegen.c` | 4 sitios: `:572`, `:582`, `:767`, `:1411` | refactor a tabla `builtin_table[] {name, C fn}` antes del primer builtin nuevo; `sweep_emit_c.sh` lo caza |
| Overflow de registros del backend C | `fn_map[512]` (`codegen.c:23`), `global_map[256]` (`:27`), error en `:1506` | los builtins añaden entradas solo si se referencian; no cambia el orden de magnitud, pero el refactor debe conservar el conteo de error |
| `FnObj` sin discriminador | `astra.h:1044-1053`, `bytecode.zig:196-207`; dispatch único a print | §1.3 decisión 2 |
| `--check-constructs` / registry | `construct.c` solo valida keywords y tabla de operadores; grep de `print` en `constructs/` → 0 | **sin riesgo**: los builtins no son constructs |
| Paridad de dumps | `dump_parity.sh` compara tokens/AST | **sin riesgo** mientras el MVP no añada sintaxis (por eso `for c in s` y char-literals van a M3) |
| Mensajes de runtime entre rutas | `cannot take length of X` ya coincide en 3 rutas | reutilizar ese texto; nunca inventar uno nuevo por backend |
| `ui/` nuevo | `ui_message_parity.sh` exige 1ª línea idéntica | verificar localmente antes de subir; si duda, caso de runtime error en vez de `ui/` |
| cwd distinto por gate | seed corre desde `seed/`, zig desde `zig/`, llvm desde la raíz (`ci.yml`) | **nunca** leer ficheros con path relativo desde `conformance/`: gate propio con `cd` (§4) |
| wasm sin preopens | `demo/wasi_run.mjs` (leído íntegro) | PR2 añade `preopens: {"/": process.cwd()}` o el I/O se gatea fuera de wasm |

---

## 3. Plan de PRs con tests

Convención del repo: rama `feat/<slug>`, commits firmados, PR con
`.github/PULL_REQUEST_TEMPLATE.md`, gates locales citados en la sección de
evidencia. Cada PR cierra con `make test` + `zig build test` en verde.

### PR1 — `len` + índice de string (superficie de lenguaje, sin I/O)

- **Alcance**: seed (`typechecker.c`, `vm.c`, `codegen.c` con refactor de la
  tabla de builtins, `codegen_runtime.h`), zig (`typechecker.zig`, `vm.zig`),
  LLVM (`emitter.zig` rama `str_` en `emitIndex` + load de `len`; helper
  `astra_llvm_str_index` en `astra_runtime_llvm.c`).
- **Tests** (conformance, con `EXPECT:`):
  - `expressions/len_string.astra`, `arrays/len_array.astra` → `// EXPECT: 5`
  - `arrays/len_int_rejected.astra` en `ui/` (si se restringe el tipo; mensaje
    idéntico en ambos compilers)
  - `expressions/str_index.astra` → `// EXPECT: h` (primer byte de `"hello"`)
  - `expressions/str_index_oob.astra` → `// EXPECT-RUNTIME-ERROR: index 5 out of bounds (len 5)`
  - `codegen/str_index.astra` para el redondeo C (`make test`)
  - actualizar nada: `ui/index_non_array.astra` debe seguir rechazando `i32`
- **Gates**: `make test`, `./tests/sweep_emit_c.sh`, `zig build test`,
  `./zig/tests/dump_parity.sh`, `./zig/tests/ui_message_parity.sh`,
  `zig build -Dllvm && ./zig/tests/llvm_parity.sh` (hoy 159/159; el total
  debe subir con los casos nuevos **y** `skip` debe quedarse en 0), `llvm_jit`,
  `llvm_cross`, `llvm_wasm`, `llvm_sanitize`.
- **Por qué primero**: es lo más barato (el opcode ya hace el trabajo) y
  desbloquea bucles sobre la fuente.

### PR2 — `to_string` + `read_file`

- **Alcance**: los 4 sitios de plumbing de un builtin nuevo (§2.2) +
  `fopen/fread` en `codegen_runtime.h` (una sola implementación para C y
  LLVM) + wrapper `astra_llvm_read_file` + **`demo/wasi_run.mjs` con
  `preopens`**.
- **Tests**:
  - `expressions/to_string.astra` (enteros, negativo, 0) — conformance, sin I/O
  - `codegen/to_string.astra` — redondeo C
  - `expressions/str_concat_int_rejected.astra` en `ui/` si se quiere pinchar
    que `+` sigue sin convertir (p20)
  - **`read_file` NO entra en `conformance/`** (cwd distinto por gate, §2.4):
    se gatea con el script de §4 o con un caso dedicado en `seed/tests/io/`
    que primero `cd` a un directorio conocido.
- **Gates**: mismos que PR1; en la ruta wasm, verificar que el caso de I/O
  corre con los preopens (o dejarlo en skip declarado).

### PR3 — `demo/lexer.astra` + gate de self-hosting

- **Alcance**: `demo/lexer.astra` + fixture + `demo/lexer.expected` +
  `seed/tests/selfhost/lexer_gate.sh` + paso en `.github/workflows/ci.yml`.
- **Tests**: el gate es el test (§4); no toca `conformance/`.
- **Gates**: el gate nuevo + los de regresión (ningún cambio de lenguaje en
  este PR, así que todos siguen verdes).

### PR4 — M2: `push`, `ord`, `substr`, `str_to_int`

- **Alcance**: `push` es el más caro (los arrays no crecen: hay que
  reubicar/copy en las 3 rutas; el seed usa arena sin `realloc` —
  `grep malloc vm.c` → 0). `ord`/`substr` son builtins pequeños;
  `str_to_int` debe decidir entre `i64?` y `Result[i64,string]` (el spec ya
  usa `?`).
- **Tests**: uno por primitiva en `conformance/` + uno en `codegen/`; para
  `push`, además un caso de crecimiento repetido (arena: comprobar que no hay
  OOB ni ASan).
- **Orden interno**: `ord` → `substr` → `push` → `str_to_int`.

**¿Se puede partir seed+C y zig después?** No con casos de conformance (§2.3).
Sí existe una alternativa menor: PR1a «solo seed, sin tests de conformance»
(irresponsable: AGENTS exige test por comportamiento) — descartada.

---

## 4. Diseño de `lexer.astra` y de su gate

### 4.1 Qué features usa (todas verificadas hoy)

`while` + `continue`, `if`/`else if`, `&&`/`||`, `match` con literales de
string + or-patterns + `_` (4 rutas), structs sin comas, arrays `[]`,
concatenación de strings, `==`, closures. Y el MVP nuevo: `len`, `s[i]`,
`read_file`, `to_string`.

### 4.2 Pseudocódigo completo (Astra-0 + MVP)

```astra
// demo/lexer.astra — mini lexer en Astra-0. Lee un fichero y emite un token
// por línea:  "<KIND> <lexeme> @<line>"   (o "ERROR <line> char <c>")
// (el struct Tok de abajo se usa cuando haya `push` — M2 —; hoy se emite en
//  streaming, un print por token)

// struct Tok { kind: string lex: string line: i32 }   // sin comas (p15)

fn is_digit(c: string) -> bool {
    return match c {
        "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" => true,
        _ => false                                                        // obligatorio (p23)
    }
}

fn is_alpha(c: string) -> bool {
    return match c {
        "a" | "b" | /* … 52 ramas … */ "z" | "A" | /* … */ "Z" => true,
        _ => false
    }
}

fn keyword(word: string) -> string {
    return match word {
        "fn" => "KW_FN", "let" => "KW_LET", "mut" => "KW_MUT",
        "if" => "KW_IF", "else" => "KW_ELSE", "while" => "KW_WHILE",
        "for" => "KW_FOR", "in" => "KW_IN", "match" => "KW_MATCH",
        "return" => "KW_RETURN", "struct" => "KW_STRUCT",
        "enum" => "KW_ENUM", "true" => "KW_TRUE", "false" => "KW_FALSE",
        _ => "IDENT"
    }
}

fn punct(c: string) -> string {
    return match c {
        "(" => "LPAREN", ")" => "RPAREN", "{" => "LBRACE", "}" => "RBRACE",
        "[" => "LBRACKET", "]" => "RBRACKET",
        "+" => "PLUS", "-" => "MINUS", "*" => "STAR", "/" => "SLASH",
        "=" => "EQ", ";" => "SEMI", "," => "COMMA", "." => "DOT",
        _ => "UNKNOWN"
    }
}

fn main() {
    let src = read_file("lexer_input.astra")   // MVP #3
    let n = len(src)                           // MVP #1
    let mut i = 0
    let mut line = 1

    while i < n {
        let c = src[i]                         // MVP #2 (1 byte como string)

        if c == "\n" { line = line + 1; i = i + 1; continue }
        if c == " "  { i = i + 1; continue }
        if c == "\t" { i = i + 1; continue }

        // comentario "//" hasta fin de línea
        if c == "/" && i + 1 < n && src[i + 1] == "/" {
            while i < n && src[i] != "\n" { i = i + 1 }
            continue
        }

        // entero
        if is_digit(c) {
            let mut lex = ""
            while i < n && is_digit(src[i]) {
                lex = lex + src[i]              // concat O(n²): suficiente aquí
                i = i + 1
            }
            print("INT " + lex + " @" + to_string(line))   // MVP #4
            continue
        }

        // identificador / keyword
        if is_alpha(c) || c == "_" {
            let mut lex = ""
            while i < n && (is_alpha(src[i]) || src[i] == "_" || is_digit(src[i])) {
                lex = lex + src[i]
                i = i + 1
            }
            print(keyword(lex) + " " + lex + " @" + to_string(line))
            continue
        }

        // string literal (el lexer del seed no admite salto de línea)
        if c == "\"" {
            i = i + 1
            let mut lex = ""
            let mut closed = false
            while i < n {
                let d = src[i]
                if d == "\n" { break }
                if d == "\"" { i = i + 1; closed = true; break }
                lex = lex + d
                i = i + 1
            }
            if closed { print("STRING " + lex + " @" + to_string(line)) }
            else { print("ERROR " + to_string(line) + " unterminated string") }
            continue
        }

        // puntuación / error
        let kind = punct(c)
        if kind == "UNKNOWN" {
            print("ERROR " + to_string(line) + " char " + c)
        } else {
            print(kind + " " + c + " @" + to_string(line))
        }
        i = i + 1
    }
    print("EOF @" + to_string(line))
}
```

Notas de diseño:

- **`is_alpha` abreviado**: el brazo `/* … 52 ramas … */` son las 52
  or-patterns literales; con `ord` (M2) se sustituye por dos comparaciones.
- **Sin `substr`**: los lexemas se acumulan con `+` (O(n²)). Con M2 se cambia
  a `substr(src, start, i)` sin tocar el resto.
- **Sin `push`**: se emite en streaming (un `print` por token). Si se quiere
  el array `Tok`, añadir `push` (M2) y un bucle final `for t in toks { … }`.
- **Sin arrays anidados ni métodos**: todo funciona con lo que existe.
- **`match` de strings exige `_`** (p23: `non-exhaustive match: missing '_' arm`).
- **Cuidado con nombres de builtin/keyword**: `ok` es keyword (`lexer.c:29`) y
  una función llamada `ok` no parsea (p24).

### 4.3 Gate

**Gate principal (byte a byte, cwd fijo)** — `seed/tests/selfhost/lexer_gate.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)     # seed/tests/selfhost
root=$(cd "$here/../../.." && pwd)
cd "$here"                              # ← cwd fijo: read_file usa path relativo
"$root/seed/astra-seed" lexer.astra > lexer.actual
diff -u lexer.expected lexer.actual     # golden commiteado
```

- **Fixture**: `lexer_input.astra` (un trozo de Astra con comentarios,
  keywords, enteros, strings, puntuación y un carácter inválido a propósito).
- **Golden**: `lexer.expected` (una línea por token).
- El gate se puede parametrizar con el binario para correr también con
  `zig/zig-out/bin/astra-zig` (y más adelante con `--emit-obj` + runtime):
  cada ruta que lo supere añade una línea al script.

**Gate fuerte (el de verdad, M3)**: normalizar la salida de `lexer.astra` y
compararla con `astra-seed --dump-tokens lexer_input.astra` — es decir, que el
lexer escrito en Astra **reproduzca el token stream del lexer escrito en C**.
Ese es el criterio real de «el lenguaje compila su propio lexer»; el gate
principal solo prueba que corre y emite lo esperado.

**Dónde NO ponerlo**: `seed/tests/conformance/` — los gates corren con cwd
distinto (`seed/`, `zig/`, raíz del repo según `ci.yml`) y la ruta wasm no
tiene `preopens`; un caso con `read_file` ahí fallaría por el camino de
ejecución, no por el lenguaje.

---

## 5. Lecciones de otros lenguajes [verificado parcial: 5/7 filas con fuente
primaria; Nim y Python sin verificar — «Verificación externa» al final]

| Lenguaje | Semilla | Primer paso de self-hosting | Lección para Astra |
|:---------|:--------|:----------------------------|:-------------------|
| **C** | B (y ensamblador PDP-7) | **Ritchie** extendió B→NB y escribió el compilador de C **en C** (1971-72); el kernel se reescribió en C en verano de 1973 (lo que Thompson reescribió en su propio lenguaje fue **B**). Las primitivas de E/S (`getc`, `putchar`) las daba la semilla | La semilla es desechable; el compilador es puro cómputo sobre bytes. Astra solo necesita `len`/índice/`read_file` |
| **Rust** | OCaml (`rustboot`) | Rust 0.9 (2014) se compila a sí mismo; lo primero que se portó fue el **front-end** (lexer/parser de `libsyntax`), apoyado en `std::io` ya escrito en Rust | El stdlib de I/O tiene que existir *antes* que el compiler; exactamente el orden de §3 |
| **Go** | C (Plan 9) + asm | Go 1.5 (2015): `cmd/compile` **y** `cmd/dist` (el bootstrap) pasan a Go en la **misma release** (`build.go`/`main.go` en go1.5; aún C en go1.4) | No hace falta que *todo* sea self-hosted de golpe: el compilador puede migrar primero y el bootstrap un release después |
| **Zig** | C++ (stage1) | El compiler self-hosted (0.11, 2023) empezó por el **lexer/parser/AST** y fue compilado por stage1; regla explícita: «el compiler debe ser compilable por el release anterior» | Un gate que compare el nuevo lexer con el viejo (§4.3) es la regla de Zig aplicada |
| **Nim** | Nim (versión previa) | 0.10 (2014) self-hosting; antes tuvo que existir `system`, `strutils` (`len`, `substr`, `parseInt`) y `os.readFile` | **La lista de M1/M2 es literalmente el stdlib que Nim necesitó** |
| **Swift** | C++ | La tabla de `COMPILER_STRATEGY.md:53-59` dice «Swift 3.0 (2016)» pero el compiler sigue siendo C++ en 2026 | Ojo con copiar tablas de bootstrap: verificar antes de citar |
| **Python** | C | CPython nunca se self-hosteó; PyPy está escrito en RPython (subconjunto) y arrancado por CPython | Hay caminos que no exigen self-hosting completo |

Patrón común **[verificado parcial: coherente con las filas que sí tienen
fuente — B reescrita en B por Thompson (chist), el front-end de rustc ya en
`rust-lang/rust`, Zig stage1→self-hosted — pero ninguna fuente consultada dice
«siempre el lexer primero»]**: (1) el primer componente self-hosted es **siempre el
lexer/parser**, porque es E/S + cómputo puro y no toca ABI; (2) antes hay que
tener **longitud + acceso a carácter + entero↔string + lectura de fichero**;
(3) el codegen va el último. Nada en esto contradice `research/002 §5.2/§5.4`
(el alcance de Astra-0 ya incluía «Basic I/O (`print()`)» y «Standard library
(`io`, `string`, `collections`)» como Tier 3 — el informe lo sube a Tier 1
implícito: sin `io` no hay Tier 1 real).

---

## 6. Reproducción

Ejecutado el 2026-10-27 con el seed ya compilado: `./seed/tests/run_tests.sh`
→ **`passed: 260  failed: 0`** (registry + conformance por VM + redondeo
`--emit-c` de `tests/codegen/`), es decir, la suite que este informe cita está
en verde.

```bash
# build
(cd seed && make)                     # -> seed/astra-seed
(cd zig && zig build)                 # -> zig/zig-out/bin/astra-zig (con LLVM: zig build -Dllvm)

cd /tmp/opencode/astra-critica/selfhost
S=/home/aster/Astra/seed/astra-seed
Z=/home/aster/Astra/zig/zig-out/bin/astra-zig

$S t1_basic.astra      # print(s == "hello") ok; len -> "undefined variable 'len'"
$S t2_index.astra      # s[0]  -> "cannot index non-array type string"
$S t3_intstr.astra     # to_string/str_to_int -> undefined variable
$S t4_push.astra       # push -> undefined variable
$S p2.astra            # a[2] = 3 -> "index 2 out of bounds (len 2)"   (arrays no crecen)
$S p7.astra            # while + continue + closure |x: i32| -> 5
$S p8.astra            # match con literal de string + _                -> 1 0
$S p22.astra           # or-patterns "0" | "1" …                        -> true false
$S p18.astra           # print(1, 2) -> "expected 1 arguments, got 2"
$S p20.astra           # "a" + 1   -> "arithmetic operator requires numeric type, got string"
$S p23.astra           # match string sin _ -> "non-exhaustive match: missing '_' arm"
$S p25.astra           # && || con llamadas y comparaciones de string
$S p28.astra           # let print = 5 -> "cannot call non-function type i32" (igual en zig)

# las 4 rutas con el mismo programa (p8 y p22)
$S p22.astra && $S --emit-c p22.astra && gcc -Wall -Wextra -I seed/src -o p22 p22.c -lm && ./p22
$Z p22.astra
cc -O2 -std=c11 -I seed/src -c zig/src/llvm/runtime/astra_runtime_llvm.c -o rt.o
$Z --emit-obj p22.astra && cc p22.o rt.o -o p22_llvm -lm && ./p22_llvm   # ruta LLVM

# gates citados (desde la raíz del repo salvo donde se indica)
./seed/tests/run_tests.sh            # conformance (VM) + tests/codegen (--emit-c)
./seed/tests/sweep_emit_c.sh         # TODA la suite no-UI por --emit-c
(cd zig && zig build test)           # conformance seed + ui parity (cwd = zig/)
./zig/tests/dump_parity.sh           # tokens/AST (no afectado por builtins)
./zig/tests/ui_message_parity.sh     # 1ª línea idéntica en ui/
(cd zig && zig build -Dllvm) && ./zig/tests/llvm_parity.sh   # 159 casos hoy; skip si el emitter no sabe el constructo
./zig/tests/llvm_jit.sh
./zig/tests/llvm_cross.sh
./zig/tests/llvm_wasm.sh
./zig/tests/llvm_sanitize.sh
```

Programas de reproducción en `/tmp/opencode/astra-critica/selfhost/`
(`t1_basic`, `t2_index`, `t3_intstr`, `t4_push`, `t5_for`, `t6_strfor`,
`t7_arr`, `p1`…`p31`).

---

## 7. Referencias internas

- `Documentacion/07_investigacion/025_critica_externa_seguridad_y_proceso.md` §2.6 (la crítica y su verificación)
- `Documentacion/07_investigacion/002_seed_compiler_design.md` §5.2 (MVP), §5.4 (Astra-0), §7.2 (diseño del lexer)
- `Documentacion/07_investigacion/015_stdlib-design-patterns.md` (diseño de stdlib)
- `Documentacion/02_compilador/COMPILER_STRATEGY.md` §5 (alcance), §7.1 (cadena de bootstrap), `:53-59` (tabla de self-hosting)
- `Documentacion/01_lenguaje/ARCHITECTURE.md:1617` (`read_file(path)?`), `:1819` (`.to_string()` / `.parse()`)
- `AGENTS.md` — rutas, gates, invariante «zig acepta todo lo que acepta el seed»
- `seed/src/vm.c:689,1140,1164,1402,1717` · `seed/src/codegen.c:23,27,572,767,1007,1110,1129,1411` ·
  `seed/src/codegen_runtime.h:65,156,238,317,770` · `seed/src/typechecker.c:611,1750,2014,3066` ·
  `zig/src/typechecker/typechecker.zig:402,1172` · `zig/src/vm/vm.zig:336,815,1072,1083,1215,1396` ·
  `zig/src/emitter/bytecode.zig:196` · `zig/src/llvm/emitter.zig:1415,1993,2249,3069,3198,3248,4155,4598` ·
  `zig/src/llvm/runtime/astra_runtime_llvm.c:23,163,224,247` · `demo/wasi_run.mjs`
- Gates: `seed/tests/run_tests.sh`, `seed/tests/sweep_emit_c.sh`, `zig/src/conformance.zig`,
  `zig/tests/llvm_{parity,jit,cross,wasm,sanitize,filecheck}.sh`, `zig/tests/ui_message_parity.sh`,
  `.github/workflows/ci.yml:10,51,72,101,165,201,250`

---

## Verificación externa (2026-10-27)

`websearch` → HTTP 403; toda la tabla de §5 se verificó con `webfetch` a
fuentes primarias (y GitHub API para histórico de repos).

| Fila de §5 | Resultado y fuente |
|:-----------|:-------------------|
| **C** | **[verificado parcial — con corrección]**: D. Ritchie, *The Development of the C Language* (bell-labs vía `web.archive.org/web/20191230170854`) dice que el que extendió B→NB y creó el compilador de C fue **Ritchie (1971-72)**, y que el kernel se reescribió en C en el **verano de 1973**; lo que Thompson reescribió en su propio lenguaje fue **B** («Thompson rewrote B in itself (a bootstrapping step)»). La fila atribuye el compilador C a Thompson y lo fecha 1973-74. |
| **Rust** | **[verificado parcial]**: árbol de 2010 en `api.github.com/repos/rust-lang/rust/git/trees/…` con `src/boot/**/*.ml` (semilla OCaml) y `src/comp/front/{lexer,parser}.rs`. «Lo primero que se portó fue el front-end» y «Rust 0.9 se compila a sí mismo» **no** se confirmaron; `github.com/graydon/rustboot` ya no existe (404). |
| **Go** | **[verificado con corrección]**: `api.github.com/…/golang/go/contents/src/cmd/dist?ref=go1.4` → `main.c`, `build.c`, … (C) **y** `?ref=go1.5` → `build.go`, `main.go`, … (Go): `cmd/dist` **no** «se quedó en C años», pasó a Go en la misma 1.5 que el compilador. |
| **Zig** | **[verificado]**: `ziglang.org/download/0.11.0/release-notes.html` («During this release cycle, the C++ implementation of Zig was deleted»; stage1 = `src/stage1/*` con el toolchain del sistema, stage2 = `src/*.zig` compilado por stage1) y `ziglang.org/news/goodbye-cpp` («The old one, written in 80,000 lines of C++»). «Empezó por lexer/parser/AST» y «compilable por el release anterior» **no** se localizaron en esa fuente. |
| **Nim** | **[sin verificar]** — sigue [citado]: ninguna fuente para «0.10 (2014)» ni para la lista `strutils`(`len`,`substr`,`parseInt`)+`os.readFile` (dicha lista coincide con la M1/M2 de Astra, parece reconstruida, no citada). |
| **Swift** | **[verificado]**: `api.github.com/repos/apple/swift/languages` → **C++ 64,8 MB** en 2026 (junto a 70,4 MB de Swift) y el README habla de «the C++ part of the swift build» ⇒ el compiler sigue siendo C++. |
| **Python** | **[sin verificar]** — sigue [citado]. |

**Patrón «siempre el lexer primero»**: **[verificado parcial]** — coherente con
los casos que sí tienen fuente (B→B de Thompson; el front-end de rustc ya existe
en `src/comp/front/` en 2010; Zig stage1→self-hosted), pero **ninguna fuente
consultada lo enuncia como regla universal**, así que se mantiene como
generalización del informe, no como hecho citado.
