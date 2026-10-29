# 034 — Informe de auditoría: 42 hallazgos verificados (seguridad y robustez del compilador)

> **Fecha.** 2026-10-29, sobre `main` @ `1a2eddb` (tras `git pull` de 16
> commits). Companion de `033_taxonomia_vulnerabilidades_cvss.md` (la lista de
> 90 casos contra la que se auditaron las superficies). Los números A/M/B de
> este informe son los IDs que usan los issues de GitHub.
>
> **Método.** Cinco auditorías paralelas con superficies disjuntas (front-end ·
> emitter/codegen/runtime-C · VM/builtins · typechecker/driver/arena ·
> features de fase E), cada una contra su rebanada de la taxonomía 033, con
> reproducción obligatoria. Estado de verificación:
> **✓ = reproducido por el revisor principal** con binario ASan restaurado;
> **[sub] = reproducido por el auditor de esa superficie con salida capturada**.
>
> **Gate base.** `cd seed && make test` → **352 passed, 0 failed** en el commit
> auditado (la auditoría no cambia comportamiento).

---

## A. Nivel ALTO (CVSS 7.0–8.9) — 10 hallazgos

### A1 — `FnObj.local_count` (`uint8_t`) trunca el frame de funciones con 255 parámetros → el C generado se sobrescribe a sí mismo
- **CWE-197/682** · `include/astra/astra.h:1050`, `emitter.c:2588` (fn) / `emitter.c:2441` (lambda), consumido en `codegen.c:1412` (`uint16_t sp = %u`) y el floor de `codegen.c:1403-1404`.
- `$ret` + 255 params = 256 → 0 en `uint8_t`; el código generado arranca `sp = 0` y los temporales crecen **por encima de las celdas de parámetros**. El VM no usa `local_count` para montar frames, por eso no se ve ahí.
- **Impacto**: respuesta silenciosamente incorrecta en el backend C; sin diagnóstico; `--emit-c` rc=0 y gcc limpio.
- **Repro** ✓: función de 255 params cuyo cuerpo hace `(p1+p2)-1`; VM imprime `4`, el binario C imprime `2`.
- **Por qué el gate no lo ve**: ningún caso de `tests/codegen/` llega a 255 parámetros.

### A2 — `fn_obj_reg[512]` falla **abierta**: lambdas sin registrar se emiten como puntero NULL y el programa compilado muere
- **CWE-476/755** · `codegen.c:263` (`if (count >= 512) return "astra_too_many_fns";` **sin `error_count++`**, a diferencia de `make_fn_cname`/`make_global_cname`) → `codegen.c:1100` emite `cname = "NULL"` → `astra_closure_new((AstraFnPtr)NULL, …)` (`codegen.c:1122-1128`) y `astra_fn_new((AstraFnPtr)NULL, 0)` (`codegen.c:841`).
- **Impacto**: `--emit-c` reporta **éxito** para un programa válido; el binario compilado **SIGSEGV** (`pc 0x0`), mientras el VM lo ejecuta bien. Falla abierta en un registro cuyo tope sí respeta la familia AST-019.
- **Repro** ✓: 540 lambdas (3 fns × 180) → VM `0 0 179` rc=0; `--emit-c` rc=0; binario C `rc=139`.

### A3 — Sentinela `0xFF` de `add_local` colisiona con el slot 255 válido: VM con error, C devuelve `nil`
- **CWE-684** · `emitter.c:281-307` devuelve `0xFF` como «límite» **y** como slot legítimo cuando `local_count == 255`; llamadores (`emitter.c:2638-2645` VAR_DECL, `2660-2669` CONST_DECL, `2614-2621` FN_DECL) tratan `0xFF` como fallo **sin `error_count++`**.
- El 256º local se emite como `SET_GLOBAL "v255"` mientras las lecturas resuelven `GET_LOCAL 255` (slot nunca escrito). El C además no valida inicialización en `GET_LOCAL` (`codegen.c:900-902`).
- **Repro** ✓: VM → `runtime error: local variable at slot 255 not initialized`, rc=1; C → imprime `nil`, **rc=0** (divergencia silenciosa + escritura a global inesperada).

### A4 — Anidación 240–255: el parser la acepta y el **emitter** desborda la pila del proceso
- **CWE-674** · Contrato de `parser.c:14-17` («acotar aquí acota el typechecker y el emitter») falso: `emit_expr`/`emit_stmt` se desbordan con **menos** profundidad que el guard.
- **Medidas** ✓: no instrumentado, bloques anidados: 239 ok, **240 SEGV**, 255 rechazado limpio por el guard; cadena binaria: 240 ok, **241 SEGV**. Con ASan el umbral baja a ~166.
- **Repro** ✓: `python3 -c "print('fn main() {' + '{'*240 + ' 42' + '}'*240 + ' }')" > x.astra && astra-seed --dump-ast x.astra` → rc=0 (legal), `astra-seed x.astra` → ASan `stack-overflow … emitter.c:1272 emit_expr`.
- **Impacto**: DoS determinista del compilador con entrada que él mismo valida; y rompe el gate ASan con input «legal».

### A5 — Ciclos en structs: `print(n)` y `a == b` recursan infinitamente en C nativo → SIGSEGV (8 líneas de Astra legal)
- **CWE-674** · `vm.c:229/266` (print: struct→some/ok/err→struct) y `vm.c:336/339/372` (igualdad). Los ciclos son legales (pinned por `tests/conformance/transfer/copy_cycle.astra`, DEC-027) y `value_copy` **sí** tiene `COPY_MAX_DEPTH 64` (`vm.c:694-700`) — `==` y `print` no.
- **Repro** ✓: `n.kid = some(n); print(n)` → rc=139 (plain) / ASan `stack-overflow value_print_stream`; dos structs cíclicas + `a == b` → igual (autocomparación `a == a` sí es segura por puntero).
- **Impacto**: DoS determinista de cualquier host que ejecute Astra no confiable (juez, REPL, CI).

### A6 — `NEW_ENUM`: `break` muerto en el escaneo hacia atrás → enums anidados con etiquetas del enum interno (igualdad y print falsos en C)
- **CWE-682** · `codegen.c:1282-1297`: el guard `if (code[ip-back].op != OPCODE_CONST) break;` está **dentro** de la rama `== OPCODE_CONST` (código muerto), así que el escaneo salta instrucciones no-CONST (incluido el `NEW_ENUM` interno) y se queda con la def del interno. El VM lee los nombres del def real (`vm.c:242-248`).
- **Repro** ✓: `Outer.V(Inner.W(5))` → VM `true true`, **C `false false`** (igualdad) y `Inner.W(Inner.W(5))` impreso en C.

### A7 — Constantes float emitidas con `%g` (6 dígitos): redondeo irreversible, comparaciones silenciosamente distintas al VM
- **CWE-681** · `codegen.c:792` (`astra_float(%g)`).
- **Repro** ✓: `1.0000000000000002 == 1.0` → VM `false`, **C `true`**; `9.01501e-14` → C `0`; `3.14159265358979` → C `3.14159`.

### A8 — Familia de punteros NULL sin comprobar (OOM): el compilador muere con SEGV en vez de «out of memory»
- **CWE-476** · Probados con crash real ✓:
  - `main.c:212-213`: `out_path = malloc(fn_len+4)` sin NULL-check antes del `memcpy` (el único malloc de `main.c` sin check).
  - `string_table.c:46`: `st_grow` sin check → `entries = NULL` con capacidad ya doblada → `slot_empty` (`:21`) SEGV. Es el **más alcanzable**: dispara con `ulimit -v 40000` en un fichero de 1,18 MB → **rc=139** ✓.
  - Familia idéntica (mismo defecto, sin repro forzado): `typechecker.c:197/201/215/258-259/405-407/482-484/534-536/564-566/1421-1439/1511-1513/3432-3434/4097-4099/1604-1620`, `driver.c:624-630`, `parser.c` (todos los grow de vectores), `lexer.c:369-374`, `emitter.c:181-189` (write through NULL, repro ✓ en sweep `ulimit -v 50000-70000`), `codegen.c:62` (`realloc` sin check; además **fuga** el bloque original).
  - Cada sitio además conserva la capacidad nueva tras el fallo → el fallo es permanente.
- **Contraste**: `arena.c:84-85` (`arena_strdup`), `driver.c:738` y `main.c:47` **sí** comprueban — el patrón existe, se aplicó de forma inconsistente.

### A9 — `--emit-c` escribe a través de symlink preexistente → sobrescritura de ficheros del workspace (poisoning de build en CI)
- **CWE-59** · Ruta en `main.c:210-221`, apertura `codegen.c:1561` `fopen(path,"w")` sin `O_NOFOLLOW`/`lstat`.
- **Repro** ✓: `ln -sf svictim.txt foo.c && astra-seed --emit-c foo.astra` → rc=0 y `svictim.txt` truncado con `/* Generated by astra-seed --emit-c */`.
- **Impacto**: un repo malicioso con `foo.c` como symlink (a ficheros que pasos posteriores consumen, dotfiles, artefactos) los pisa al correr la suite.

### A10 — Fase E: un **método de usuario llamado `copy`** elude el check de receiver-escape (S2) → `transfer` aceptado con doble propiedad
- **CWE-282** · `typechecker.c:4339` (y `zig/src/typechecker/typechecker.zig:3006`): el walker `is_copy` decide **solo por el nombre del campo**, pero el typechecker deja ganar a un método `copy` de usuario al builtin. El receiver debe escapar por DEC-027 §3 (pinned por `ui/transfer_method_escaped.astra` con método `get`), pero `own_escape_root` se salta.
- **Repro** ✓: método `fn copy(self) -> S` que devuelve `self` → `transfer(s)` **aceptado** y el valor transferido sigue legible (`1`), idéntico en las 4 rutas. Renombrar `copy`→`get` lo rechaza: el renombrado es todo el bypass.
- **Sin test** que pinnee un método `copy` de usuario contra el walker.

---

## M. Nivel MEDIO (CVSS 4.0–6.9) — 15 hallazgos

### M1 — `read_line()` aliasa el búfer stdin reutilizado: la línea 2ª corrompe silenciosamente a la 1ª
**CWE-664** · `vm.c:933` devuelve `value_string(vm->stdin_buf, len)` sobre un búfer **reutilizado entre llamadas** (`vm.c:906-928`), violando el contrato de strings inmutables/arena del modelo (`astra.h:1061-1064`).
**Repro** ✓: `printf 'first line here\nsecond\n' | astra-seed p.astra` con `let a=read_line(); let b=read_line(); print(a)` → imprime **`secondline here`**. No es inseguridad (el búfer solo crece) pero corrompe datos de cualquier lector multi-línea (p.ej. un lexer escrito en Astra).

### M2 — Global referenciado antes de definirse: VM aborta, C lee `nil` y sigue
**CWE-665** · `codegen.c:920-941` lee la `static AstraValue` a cero; el VM valida (`vm.c:1153-1197`, `undefined global variable`).
**Repro** [sub]: VM rc=1 con `file:1: runtime error: undefined global variable 'f'`; C imprime `nil` rc=0 (con `print(a())`: mensajes y líneas distintas además).

### M3 — S2 falsos negativos: las lecturas derivadas de contenedores no se enlazan con su contenedor
**CWE-282** · `typechecker.c:4391-4396` (solo un `Ident` crea alias en `NODE_VAR_DECL`; campo/índice solo «visita»), `own_walk_pattern`/`NODE_FOR` declaran bindings `Único` incondicionalmente. RT1 (el backstop diseñado) no existe en v1.
**Repro** [sub], aceptado en las 4 rutas, ASan/LSan limpio (hoy doble propiedad silencioso, no UAF): `let y=arr[0]; transfer(y); use arr[0]` · `let y=b.xs; transfer(y); use b.xs` (y la inversa) · `match o { some(x)=>transfer(x) }` + re-match · `for e in arr { transfer(e) }`.

### M4 — S1 sin back-edge de bucle: programa aceptado que muere en la 2ª iteración
**CWE-682** · `typechecker.c:4479-4515`: el cuerpo se recorre una vez y `join` corre **después**; el estado de cabecera no se revalida. `research/026` §3.3 exige «uso de binding en movidos → S1».
**Repro** [sub]: `print(a[0]); transfer(a);` dentro de `while`/`for` → las 4 rutas exit 1 con `runtime error: cannot index nil` en la vuelta 2. Sin test loops × transfer.

### M5 — `transfer(param)`/`transfer(self)` solo nil-ea el frame del caldeva; `transfer(const)` acepta y revienta en runtime
**CWE-682** · Params nacen `Único` (DEC-026 §3) y el nil-red emite `SET_LOCAL` solo en el callee; para globals sí existe `transfer_global_nil`. Const: `own_declare` acepta y el emiter escribe el global sin guard de inmutabilidad (`emitter.c:1443-1477`).
**Repro** [sub]: callee hace `transfer(x)` y el caller **sigue leyendo** el agregado (4 rutas exit 0); `transfer(G)` de un const → 4 rutas exit 1 `cannot index nil` (asignación normal a const → rechazo limpio en compile).

### M6 — El pase de ownership se **desactiva en silencio** pasados sus topes
**CWE-754** · `typechecker.c:4040`: `own_declare` devuelve NULL con `n_marks ≥ 256` o `n_entries ≥ 512` («bail conservatively») **sin diagnóstico**: más allá, los cheques de transfer no aplican a nombres no rastreados y los transfers de esos locales se malreportan como «value has escaped».

### M7 — Hash-DoS: FNV-1a 32 sin semilla en interning + tabla de símbolos
**CWE-407** · `string_table.c:30-37,64-85` y `typechecker.c:206-251` (mismo hash, sondeo lineal, sin cap de cadena).
**Medida** [sub]: 60 s de preparación de 30.000 identificadores en un mismo bucket → compile completo 44–58 s → **70–88 s**; `--dump-tokens` 0–1 s → 6 s. O(chain²) con ambos términos controlados por el atacante (build-time DoS en CI).

### M8 — Pool de constantes O(n²) sin dedup de strings
**CWE-407** · `emitter.c:240-252` (`add_constant` lineal, sin caso `VAL_STRING`), pool por función.
**Medida** [sub]: 100k refs → `print(global)` **50 s**, `print(print)` **62 s** (parse+lex <1 s). Explica el timeout de 300 s en el test de 70.000 `let` *tras* imprimir ya el error.

### M9 — Directorio como entrada → exit 0 en todos los modos
**CWE-710** · `main.c:31-66`: `fopen` de directorio tiene éxito en glibc, `ftell`→0, el check de lectura corta pasa. Es la única celda rota de la matriz de exit codes (el resto verificado: todos los errores → 1).
**Repro** ✓: `astra-seed adir` → 0; `--dump-ast adir` → 0; `--emit-c adir` → 0 y crea `adir.c`.

### M10 — `fwrite`/`fclose` sin comprobar: disco lleno → `.c` truncado con exit 0
**CWE-252** · `codegen.c:1566-1567`. **Repro** [sub]: `ln -sf /dev/full out.c` → `--emit-c` rc=0. (El `fopen` NULL sí está comprobado.)

### M11 — `cg_writef` (`tmp[2048]`, retorno ignorado): identificadores >2 KB → `.c` malformado con `--emit-c` exit 0
**CWE-170/252** · `codegen.c:75-82` + ~20 call sites con `%s` de contenido de usuario (nombres struct/enum/fn/fields). Los literales de string **no** pasan por aquí (vía `cg_write`/`cg_write_c_escaped`, verificado con 6 KB) — solo identificadores. gcc rechaza el resultado (falla ruidoso), el defecto es el éxito falso. **Repro** [sub]: línea de 3168 bytes fusionada a media.

### M12 — Ruta zig: escritura a capturas (`a[0]=9`, `s.v=9`) no entra al set de capturas → programa legal falla **solo en zig**
**Paridad** · `zig/src/emitter/emitter.zig:608-621`: `FreeVars.walk` solo referencia el target si es `.identifier` plano; cae a `GET_GLOBAL`.
**Repro** [sub]: seed/C/LLVM → `9`; **zig** rc=1 `undefined global variable 'a'` — viola «the Zig compiler must accept everything the seed accepts».

### M13 — LLVM: rechaza arrays opcionales legales y `.copy()` de pareja es shallow solo ahí
**Paridad** · `zig/src/llvm/emitter.zig:2157` (`unsupported: array without an element type`) → `some([1,2])` con binding/índice funciona en 3 rutas y LLVM sale 9. Y `emitCopy` `.pair_` (`:4059-4065`) hace share frente al deep de seed/zig/C (DEC-027 §2 vs §«deep copy»; hoy invisible porque la rama anterior rechaza los bindings). El gate 221/221 no lo ve: ningún caso del suite ata un array de un optional.

### M14 — Identificadores C-keyword como campos/variantes → C no compila, `--emit-c` dice éxito
**CWE-94 residuo** · `codegen.c:339` (`AstraValue %.*s;`) y `:382`. El charset de identificadores Astra (`[A-Za-z0-9_]`) ya bloqueó la inyección real (verificado en 033 AST-004: escape robusto) — queda `union`/`char`/`int`/`__asm__` → gcc error ruidoso + éxito falso de `--emit-c`.

### M15 — >255 parámetros: `param_count` truncado a `uint8` → error *interno* opaco
**CWE-197** · `emitter.c:2531/2407` + `sp_set_argcount`. Declarar 300 params compila **sin diagnóstico** (44 slots reales, el resto cae a `GET_GLOBAL` inexistente); llamarlo → `error: internal: stack imbalance … expected height 1, computed 257`. Sin corrupción (el invariante de balance la frena) pero sin diagnóstico útil. (Lambda incluida.)

---

## B. Nivel BAJO (CVSS 0.1–3.9) — resumido

- **B1** `opcode_is_fallible` omite 24 opcodes (`codegen.c:109-125`) → diagnósticos con línea 0/stale cuando se alcanzan (hoy: `GET_LOCAL` de A3). CWE-697.
- **B2** Paridad menor: valores función imprimen `<fn>` (VM) vs `fn` (C, `codegen_runtime.h:453`).
- **B3** `gt_depth` filtrado: `fn f<T` truncado deja `> >` mal-lexado en el resto (solo parses ya fallidos); `previous.text` viejo entra en AST parcial (contestado por el gate de errores). `parser.c:1027/1692/129`.
- **B4** `generic_stack` cap 32 con truncado silencioso (`typechecker.c:1602`) → diagnósticos «unknown type» engañosos.
- **B5** Posiciones `uint32_t`: entradas >4 GiB envuelven offset/línea (`astra.h:24`, `lexer.c:426/505`) — diagnósticos erróneos, sin OOB.
- **B6** DEC-026 documenta el mensaje `M2 transfer must be its own statement` para `let y = transfer(a)`; el compilador emite otro distinto (`typechecker.c:2901`, byte-idéntico seed↔zig). Rechazo correcto, mensaje documentado incorrecto.
- **B7** Sin techo de tamaño de entrada (CWE-770): RSS ≈ 2–3× tamaño del fichero; el caso de 4 GiB degrada a swap/OOM ambiental (la ruta de `malloc` fallido **sí** es limpia: `error: out of memory reading`, rc=1 ✓).

## Riesgos de diseño (no bugs; para DEC-021 / `astraea`)

- **R1** `read_file(path)` = lectura arbitraria de ficheros si la futura CLI ejecuta Astra no confiable (033 AST-017).
- **R2** `--jit` ejecuta el código de la fuente **dentro del proceso del compilador** con `-rdynamic` (033 AST-028).
- **R3** Path traversal de imports y command injection: **N/A hoy** (imports inertes en seed; sin `system`/`popen` en `seed/src`; el único `fopen` derivado de fuente es la escritura de salida → cubierto por A9).

## Verificado como CORRECTO (rastro de auditoría)

Escape de literales al C (octal 3 dígitos, NUL preservado con longitud explícita, bytes ≥0x80 byte-a-byte, trigrafos fallan ruidosos) · los **54** opcodes con handler en **ambos** switches con `default:` duro (invariante 8) · registros `fn_map`/`global_map` con `error_count` antes de escribir (300 globals/520 fns → error limpio) · `GET/SET_GLOBAL`, `GET/SET_FIELD`, `CLOSURE`, `TAG_IS`, `NEW_ENUM` con bounds-check · sin aliasing de punteros sobre `cg->buf` tras realloc · límites de índices/`substr`/`chr`/`str_to_int`/división/shifts/`INT64_MIN` (todos → error limpio, UBSan silencioso) · profundidad de llamadas VM = 256 con error limpio · **todos** los caminos recursivos del parser custodiados (paréntesis/blocks/patrones/tipos/cadenas planas) · literales enteros overflow-proof en las 4 bases · LSan limpio en 9 rutas de error y **306/306 conformance** · capturas, `for` con snapshot, temporales `.copy()`, guards de match con efectos, builtins nuevos byte-idénticos en 4 rutas · matiz de AST-019: el tope de `fn_obj_reg` sí evita OOB (el fallo es abierto, A2, no out-of-bounds).

## Notas de proceso

1. Un subagente ejecutó un `make` plano que dejó `seed/astra-seed` **sin instrumentar** (09:22, árbol `build/` por defecto); restaurado con `make debug` (665 símbolos `__asan`) antes de la verificación final. Los gates ASan deben comprobar `nm astra-seed | grep -c __asan`.
2. Se retiraron 2 artefactos huérfanos `tests/conformance/ui/{sa,za}.txt` generados por la auditoría.
3. Los PoCs viven en `/tmp/opencode/audit/{frontend,codegen,vm,tcd,phaseE}/` (efímeros); los repro mínimos quedan inline en los issues derivados.

## Comandos de reproducción global

```bash
cd seed && make debug && nm astra-seed | grep -c __asan   # 665
make test                                                   # 352/352
# A4: anidación legal que revienta el emitter
python3 -c "print('fn main() {' + '{'*240 + ' 42' + '}'*240 + ' }')" > /tmp/x.astra
./astra-seed --dump-ast /tmp/x.astra; echo $?   # 0 (acepta)
./astra-seed /tmp/x.astra; echo $?               # 1 (ASan stack-overflow emit_expr)
# A8: OOM como SEGV
( ulimit -v 40000; ./astra-seed <fichero 1MB> )  # 139 en string_table.c:21
# A9: symlink
echo secreto > victim; ln -sf victim foo.c; printf 'fn main(){print(1)}\n' > foo.astra
./astra-seed --emit-c foo.astra && head -c 40 victim   # "/* Generated by astra-seed…"
# M9: directorio
./astra-seed /tmp && echo $?                          # 0 (debería ser 1)
```

## Referencias

- `Documentacion/07_investigacion/033_taxonomia_vulnerabilidades_cvss.md` (taxonomía 90 casos + fuentes CVSS/CWE).
- `seed/AGENTS.md` §Invariantes (1 stack, 2 saltos, 3 frames, 6 registro, 7 profundidad, 8 checks de cruce, 9 `?`).
- `Documentacion/01_lenguaje/DECISIONES.md` DEC-012/022/026/027 (fase E), DEC-021 (CLI futura).
