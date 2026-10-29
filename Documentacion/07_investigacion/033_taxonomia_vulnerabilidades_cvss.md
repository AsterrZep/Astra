# 033 — Taxonomía de auditoría: 90 casos (30 críticos / 30 intermedios / 30 básicos) por niveles CVSS, extrapolados a Astra

> **Objetivo.** Investigación externa (web) sobre los casos de fallo más graves
> documentados — corrupción de memoria, ejecución remota, escala de
> privilegios — ordenados por severidad CVSS/CWE, y su extrapolación concreta
> al compilador y runtime de Astra (`seed/` en C, más el runtime C generado y
> el backend LLVM opcional). Este documento es la **lista de verificación** de
> la auditoría; cada caso tiene superficie, Vector de Ataque y método de
> detección.
>
> **Alcance.** Implementación (C), no diseño del lenguaje (eso vive en
> `research/025`). No propone cambios de lenguaje: es una auditoría de
> seguridad y robustez del software.

## 0. Fuentes y metodología

### 0.1 Escalas (verbatim de las fuentes)

| Fuente | Dato |
|:-------|:-----|
| CVSS v3.1 / v4.0 (first.org, §Severity Rating Scale) | **Critical 9.0–10.0 · High 7.0–8.9 · Medium 4.0–6.9 · Low 0.1–3.9** |
| 2025 CWE Top 25 (cwe.mitre.org/top25/archive/2025) | Ranking = CVEs × severidad; **CWE-787 Out-of-bounds Write #5 (12.68, 12 en KEV)**, **CWE-416 Use After Free #7 (8.47, 14 en KEV)**, **CWE-125 OOB Read #8**, **CWE-78 OS Command Injection #9 (20 en KEV)**, **CWE-94 Code Injection #10**, **CWE-120 #11, CWE-476 #13, CWE-121 #14, CWE-122 #16, CWE-770 #25** |
| CISA *Secure by Design Alert: Eliminating Buffer Overflows* | Los buffer overflows siguen dominando la explotación práctica; diseño sin buffers fijos + sanitizadores como mitigación |
| CVEs recientes usados como arquetipos | **CVE-2026-109618/109619 «php2shell»** (RCE sin autenticación, CVSS 9.8/9.2); **CVE-2026-111497 «Node2Shell»** (decodificador brotli confunde error de formato con «necesito más entrada» y **acumula bytes atacante en un buffer interno de 8 bytes** → heap overflow → RCE: el patrón literal de un lexer que crece mal); **CVE-2026-48122** (Ruby LSP: repositorio malicioso ejecuta código al abrirse — el arquetipo exacto de «toolchain que procesa código de terceros»); **CVE-2026-66066 «KindaRails2Shell»**; hallazgos oss-fuzz (`Heap-buffer-overflow WRITE`, 90-day disclosure) |

### 0.2 Modelo de amenaza de Astra (cómo se asigna cada tier)

El compilador es una **toolchain que procesa código no confiable**: `astra-seed`
se ejecuta sobre fuentes de terceros en CI, en un IDE, y (DEC-021) sobre la
futura CLI `astraea`. Con `AV:L/AC:L/PR:N/UI:R` un fallo que da ejecución de
código arbitraria *dentro del alcance cambiado* (comprometer el build →
suministro de código) se puntuó **9.x**; corrupción de memoria sin explotación
demostrable pero con write OOB, **7.x–8.x**; leak/DoS/semántica local
**4.x–6.9**; menores **0.1–3.9**.

Superficies: `seed/src/{lexer,parser,ast,typechecker,emitter,codegen,vm,driver,main,arena,string_table}.c`,
`seed/src/codegen_runtime.h` (runtime de los `.c` generados), `seed/fuzz/`,
`zig/src/` (paridad) y `zig/src/llvm/` (opcional).

Tres vías de ataque principales, derivadas de la investigación:
1. **Fuente maliciosa → compilador** (arquetipo Node/Ruby-LSP): lexer/parser/typer/emitter.
2. **Fuente maliciosa → programa compilado** (runtime C y VM): valores de usuario en buffers, índices, tamaños.
3. **Pipeline de build**: salida `--emit-c` hacia `cc`, rutas, imports, lectura de ficheros.

---

## 1. Nivel CRÍTICO — 30 casos (CVSS 9.0–10.0: ejecución de código, corrupción de memoria explotable)

| # | CWE | Arquetipo (web) | Extrapo­lación a Astra | Detección |
|---|-----|-----------------|------------------------|-----------|
| AST-001 | CWE-787 OOB write | Node2Shell: bytes atacante en buffer de 8 | Crecimiento de vectores del parser (`parser.c`): `new_cap*2`/`memcpy(new, old, len*elem)` sin comprobar desbordamiento de `size_t` en `len*elem` | ASan + PoC con ~2^31 entradas en un literal (vector de args/stmts) |
| AST-002 | CWE-122 heap overflow | php2shell | `vm.c` concat: `len_a + len_b` antes de `arena_alloc`/`malloc` — envoltura → alloc pequeño + `memcpy` grande | UBSan/ASan con dos strings ~2^63 (vía fuzz de literales) |
| AST-003 | CWE-122 heap overflow | Idem | `codegen_runtime.h` `astra_str_concat` (línea ~477): misma suma sin check en el runtime de los `.c` generados | Compilar programa con concat masivo; ASan sobre el binario generado |
| AST-004 | CWE-94 Code Injection | CVE-2026-48122 (repo malicioso → RCE) | `--emit-c`: cualquier byte que cierre el literal C (escape no cubierto → `?` trigrafos, U+2028, secuencias octales que se fusionan con el siguiente carácter) inyecta C que `cc` compila | Corpus de escapes por byte 0–255 en literales; grep del `.c` generado |
| AST-005 | CWE-787/corrupción silenciosa | Heap overflow por truncación (Node2Shell) | `cg_writef`: `vsnprintf(tmp, 2048, …)` **trunca** y `cg_write` usa `strlen` — un identificador/formato >2040 B genera C truncado → malformado **o válido pero incorrecto** | Generador de nombres/strings >2040 B; comparar salida vs VM |
| AST-006 | CWE-416 UAF | 14 CVEs en KEV (CWE-416 #7) | `codegen_runtime.h` ref-count: retain/release desbalanceado en `?`, `match` con guards, temporales de llamada → free prematuro del valor aún en uso | LSan + ASan sobre `tests/codegen/` con ciclos y errores largjmp |
| AST-007 | CWE-416 UAF/double-free | Idem | `transfer(x)` (fase E1, DEC-012/022/026): puntero cedido a otro ámbito y usado en el origen (checks S2/RT1 — verificar que **todos** los caminos emiten el check) | `tests/conformance/ui/transfer_*.astra` + PoCs que eluden el check |
| AST-008 | CWE-787 write sobre frame | Stack buffer overflow (CWE-121 #14) | Invariante 1/3: `SET_LOCAL` con slot ≥ capacidad → escribe sobre el frame vecino si el emitter calcula mal el máximo slot (`codegen.c` escanea GET/SET — ¿cubre todos los opcodes nuevos: `OPCODE_*` de `.copy`, `transfer`?) | Matriz de opcodes × rutas de slot; fuzz de programas con muchos locales |
| AST-009 | CWE-190→salta a memoria arbitraria | Clásico jump-offset | Parche de saltos (`offset = T - P`): saturación de `int32_t`/tipo del offset en bloques enormes → salto fuera de la imagen de código | Bloque con >2^31 bytes de bytecode (PoC sintético) + revisión de tipos |
| AST-010 | CWE-843 type confusion | Deserialización de datos no confiables (CWE-502 #15) | VM: `match`/campos/índices que castean `Value.as.*` sin revalidar `kind` tras aliasing/`transfer`/`.copy` | PoCs que confunden array/str/struct en match y field access |
| AST-011 | CWE-476→corrupción | NULL deref (#13, +8 posiciones 2025) | `cg_ensure`: `realloc` sin comprobar `NULL` y `memcpy` posterior; `main.c` `out_path = malloc(...)` sin check; `arena.c` `string_intern` `memcpy(dup, s, len)` sin check de `arena_alloc` | Fallo simulado de alloc (fuzz `-max_len` + `ASAN_OPTIONS=allocator_may_return_null=1`) |
| AST-012 | CWE-770→CWE-122 | Allocation without limits (#25) | Doubling `new_cap *= 2` con wrap en `lexer.c`/`emitter.c`/`typechecker.c`/`codegen.c` → `while (new_cap < needed) new_cap *= 2` **infinito** si `new_cap` satura en 0 | Fuente con buffer que duplique hasta saturar (fuzz largo) |
| AST-013 | CWE-125 OOB read | oss-fuzz `Heap-buffer-overflow READ` | `lexer.c` lookahead en `pos`/`pos+1` al final del fichero (EOF) y offsets de columnas | `make fuzz` (libFuzzer, ya existe) + corpus de 1-byte files |
| AST-014 | CWE-121 stack buffer | Formato de valor | `vm.c:457 char buf[512]` en `to_string` de valores: ¿string largo o struct profundo cabe? (idem `typechecker.c:1394/1650`) | `to_string` sobre string 10^6 y struct con campo 10^6 |
| AST-015 | CWE-78 Command Injection | CWE-78 #9, 20 en KEV | Ruta futura: quien invoque `cc`/`llc` con rutas de proyecto (scripts `zig/tests/*.sh`, futuro `astraea`) usando shell sin quoting → ejecución vía nombre de fichero `;rm -rf` | Grep de `sh -c`/`system` con concatenación de rutas; revisar zig build runner |
| AST-016 | CWE-22 Path Traversal | CWE-22 #6 (10 en KEV) | Resolución de módulos (`use`/`from … import`) en `zig/src/modules/`: ¿acepta `../../` y sale del árbol del proyecto? | `from "../../etc/passwd" import x` (zig y seed) |
| AST-017 | CWE-200/22 lectura arbitraria | Exposición de información (#20) | Builtin `read_file(path)` sin restricción: en la futura CLI ejecutando Astra no confiable → exfiltración de `/etc/passwd` vía `print` | Programa Astra que lea y emita un fichero sensible (necesita DEC si se limita) |
| AST-018 | CWE-416 puntero huérfano | UAF | `string_table.c`/`ast.c`: interning tras `compiler_destroy` o nodos usados tras reset de arena (owner incorrecto en drivers de 2 fases: `--emit-c` conserva punteros) | ASan en pipeline completo con `--emit-c`, `--dump-ast`, errores |
| AST-019 | CWE-787 registries fijos | Classic Buffer Overflow (CWE-120 #11) | `codegen.c`: `fn_map[512]`, `global_map[256]`, `struct_defs[256]`, `enum_defs[256]`, `fn_obj_reg[512]` — la regla documenta el tope, pero **verificar el contador de cada uno** (¿algún `count++` sin `error_count` antes de indexar?) y rutas de errores | Auditoría estática de los 5 registros + programa con 600 funciones |
| AST-020 | CWE-416 use-after-free en closures | UAF | Lambdas/capturas (`OPCODE_*` de closure): objeto `AstraFn` liberado con la arena mientras la VM lo referencia (o al revés) | Programas con lambda que escapa de su frame + LSan |
| AST-021 | CWE-787 índice negativo | Heap overflow por entero | `a[i] = v` / `push` con `i` negativo o `i64` enorme: la comprobación usa signed y el acceso unsigned (`(size_t)(-1)`) → write OOB | `let a = [1,2]; a[-1] = 9;` y `a[9223372036854775807]` en VM, C y LLVM |
| AST-022 | CWE-122/190 capacidades de array | Heap overflow | `builtin_push` y `str_*` con `cap*2*sizeof(Value)` sin check (VM y runtime C) | ASan + push en bucle hasta cap creciente (con limitación de RAM: unit test del cálculo) |
| AST-023 | CWE-190 aritmética punteros | Heap overflow | `substr(s, a, b)`: `b - a` con `a > b` o negativos → `memcpy(dst, s+a, b-a)` con tamaño gigante | `substr("abc", -5, 3)`, `substr(s, 3, 1)` en las 4 rutas |
| AST-024 | CWE-476 propagación de NULL | NULL deref | `driver.c`: cadena `compiler_*_create` donde un fallo de OOM se propaga sin comprobar y se dereferencea en la fase siguiente | `allocator_may_return_null=1` + ejecución completa de la suite |
| AST-025 | CWE-94 inyección vía nombres | Code Injection (#10) | Nombres generados en C desde identificadores de usuario (`g_`, `astra_fn_`): identificador Astra con caracteres raros (futuros `µ`, emoji, o colisión con keywords C: `int`, `static`) → C malformado/inyectado | Generar nombres `static`, `int`, `__asm__` y no-ASCII; compilar el `.c` |
| AST-026 | CWE-787 constantes/instrucciones | OOB write | `emitter.c`: `constants`/`code` arrays con `memcpy(new, old, len*elemsize)`; índice `inst.arg.index` confiado del bytecode emitido sin validar contra `const_len` | Fuzz del emitter + revisión de todos los `inst.arg.index` |
| AST-027 | CWE-416 VM: frame/stack tras error | UAF | `OPCODE_CALL` + `longjmp` del `?` (contexto de error global, código ya conocido §9): verificar el **resto** de rutas de salida temprana (runtime error dentro de builtin) con frames apilados | PoCs de error dentro de callbacks builtins y anidamiento |
| AST-028 | CWE-843/476 en `--jit` (ORC) | RCE en runtime | `--jit` (M6.a): símbolos del proceso resueltos con `-rdynamic` → código generado (de fuente no confiable) corre **dentro del proceso del compilador** con todos los símbolos expuestos — equivalente funcional a php2shell si el JIT no sandboxa | Revisar qué símbolos exporta `astra-zig` y si un `.astra` malicioso puede llamarlos vía indirect calls |
| AST-029 | CWE-770 recursion/alloca del compilador | DoS → crash (fuerza bruta del parser) | `PARSER_MAX_DEPTH=256` existe: verificar **todas** las rutas recursivas (typechecker, emitter, `to_string` de AST, match de patrones, normalización selfhost) — una ruta sin guard = stack overflow del proceso (corruptible en C) | `--dump-ast`/typecheck sobre patrones anidados 10^4; ASan detecta stack-overflow |
| AST-030 | CWE-680 Integer overflow → buffer alloc | Heap overflow | `astra_malloc`/`arena_alloc` con `count * sizeof` en arrays de Vals del runtime C (`args[argc]`, arrays con `len` de usuario × 8) | Fuzz de `make_array(len)` con len > SIZE_MAX/8 |

## 2. Nivel INTERMEDIO — 30 casos (CVSS 4.0–8.9: leak, DoS local, corrupción lógica, miscompilación)

| # | CWE | Arquetipo (web) | Extrapo­lación a Astra | Detección |
|---|-----|-----------------|------------------------|-----------|
| AST-031 | CWE-125 OOB read | oss-fuzz READ | `to_string`/`print` de string no NUL-terminated (slices internados con longitud): leer hasta `\0` fuera del slice → fuga de memoria en la salida | Imprimir string con byte NUL intermedio y longitud > strlen (4 rutas) |
| AST-032 | CWE-770 OOM DoS | CWE-770 #25 | Intering sin límite: 10^7 literales distintos → memoria del compilador sin techo | Fuzz con tokens únicos; medir RSS |
| AST-033 | CWE-674 Recursion inesperada | Stack overflow de parser (ya documentado parcialmente) | DFS sin límite: typechecker sobre AST profundo legal (líneas 2000 de `if` en cascada), `to_string`, dump de módulos | Profundidad legal >256 con ramas, no con paréntesis |
| AST-034 | CWE-190 UB de enteros | UB clásico | `str_to_int`: negación de `INT64_MIN` o acumulación con UB firmado → resultado distinto bajo optimización (UBSan lo marca; `-O2` lo «optimiza») | UBSan + `--emit-obj -O2` sobre `"−9223372036854775808"` y strings de 30 dígitos |
| AST-035 | CWE-681 Numérico↔texto incorrecto | Conversion bug | `chr(n)` con `n` fuera de 0..255 o negativo → byte inválido/NUL inesperado en el programa | `chr(-1)`, `chr(256)`, `chr(65536)` en 4 rutas |
| AST-036 | CWE-682 Cálculo incorrecto | Wrong result | Aritmética i64 con signo: la VM usa cast a `uint64_t` para sumar — ¿coincide con el C generado y con LLVM en overflow y en división `INT64_MIN / -1`? | Matriz de casos borde × {VM, C, LLVM, zig} |
| AST-037 | CWE-754 Validación de condiciones | Check failure | Builtins con `argc` de `uint8_t` (255 = trampa documentada): ¿algún camino trata 255 como «sin comprobar»? | Fuzz de llamadas con arity manipulada (emitter lo permite?) |
| AST-038 | CWE-835 Bucle infinito | DoS | `while` sin `break` es legal (esperado) — el problema es `for..in` sobre contenedor mutado en vuelo (push durante iteración) → índice fuera de rango o bucle infinito | Iterar array con `push` dentro; documentar/fijar con DEC |
| AST-039 | CWE-125 OOB read (índices) | OOB Read #8 | `s[i]`/`a[i]` con `i == len` y `i < 0` en cada ruta (VM, C, LLVM, zig): ¿mensaje de error o lectura? | Matriz de índices {-1, len, len+1, INT64_MAX} |
| AST-040 | CWE-400 Consumo de recursos | Amplificación | Literales repetidos / concat en bucle sin límite (runtime C): doble tamaño por iteración hasta OOM del **programa** (esperado) vs del **compilador** (no esperado) | Medir RSS compilador vs programa |
| AST-041 | CWE-611/22 import remoto | SSRF-ish | Si `use` acepta rutas absolutas/URLs futuras: hoy `from "…" import` ¿lee cualquier ruta? (interrelacionado con AST-016) | `from "/etc/passwd" import x` |
| AST-042 | CWE-704 Conversión de tipo incorrecta | Type confusion suave | Enteros en posiciones de índice/longitud truncados a `int`/`uint32_t`/`uint8_t` en la frontera C (p.ej. `argc`, `slot` de frame, `op.arg`) | Auditar casts de `int64_t` → tipos menores en VM/codegen |
| AST-043 | CWE-682 semántica de `match` | Wrong result | Guards con efectos y or-patterns con bindings: ¿se evalúa el binding correcto en cada rama (orden, reintento)? Paridad VM↔C↔LLVM | Corpus `tests/conformance/match/*` + casos nuevos con efectos |
| AST-044 | CWE-459 Limpieza incompleta | Resource leak | `fopen` sin `fclose` en rutas de error (`read_file`, dumps, `--emit-c` con fallo); FILE* en paridad de errores | LSan/valgrind sobre suite con errores simulados |
| AST-045 | CWE-401 Memory leak | Leak | Fugas puntuales en rutas de error del compilador (malloc de `main.c`/`codegen.c` sin free en ramas de fallo) — ASan LSan en `make test` | LSan con suite completa (¿está en CI?) |
| AST-046 | CWE-200 Fuga por mensajes de error | Info leak | Mensajes de error que imprimen punteros, rutas internas o contenido de memoria no inicializada (`%s` sobre buffer sin `\0`) | Fuzz de mensajes con `-dump-*` y sanitizadores |
| AST-047 | CWE-117 Log injection | Inyección en diagnósticos | Identificadores con `\n`/ANSI en mensajes de error → forjar «error: …» en CI (falso diagnóstico) | `let \u001b[31mfake-error = 1` |
| AST-048 | CWE-665 Inicialización | Uninit read | `Value`/`Node` creados sin inicializar todos los campos y leídos en rutas de error o dumps (`VM` reutilizado entre fases) | MSan si disponible; revisión de constructores |
| AST-049 | CWE-457 Puntero sin inicializar / doble uso | Dangling init | Puntero guardado tras `realloc` (aliasing del buffer viejo: `cg->buf` tras realloc en `cg_ensure` si algún código conservó el puntero anterior) | Auditoría de alias de buffers con realloc |
| AST-050 | CWE-755 Excepción mal manejada | Error handling | `setjmp/longjmp` del runtime C: longjmp con `jmp_buf` de frame ya devuelto (parcialmente fijado — §9) — el resto: `?` dentro de `match` dentro de lambda, errores en inicializadores globales | `tests/codegen/try_*.astra` ampliados con anidamiento extremo |
| AST-051 | CWE-476 nil-dereference semántica | NULL deref | `nil.field` / `nil[i]` / método sobre nil: ¿error limpio en todas las rutas o crash en alguna (LLVM sin nil-check)? | `nil.a`, `nil[0]`, `nil.f()` en VM/C/LLVM (M4 ya cerró nil-SEGV — verificar regresiones nuevas: `.copy`, `transfer`) |
| AST-052 | CWE-841 Comportamiento incorrecto (orden) | Semántica | Evaluación de operandos: orden de evaluación de argumentos/distintos entre VM (pila) y C (declaración) → doble efecto observable distinto | Llamadas con efectos (`print` + mutación) en paridad |
| AST-053 | CWE-835/617 Bucle infinito del runtime | DoS | `for..in` sobre string mutado / `substr` con puntero a string liberado por `.copy`/`transfer` (aliasing nuevo fase E) | PoCs de mutación durante iteración de string |
| AST-054 | CWE-662 Mutex/carrera | Race (futuro) | Hilos: hoy el seed es single-thread — la regla es **no introducir estado global sin lock** (registros estáticos en codegen/VM) — verificar cero estado compartido si aparecen threads | Grep de `static` mutable en runtime C |
| AST-055 | CWE-770 Profundidad de llamadas | DoS | Recursión de usuario: ¿la VM tiene profundidad de frames acotada (`vm_push_frame` con cap)? Si no, recursión 10^7 = stack overflow del proceso | `fn f() { f() }` con profundidad creciente |
| AST-056 | CWE-190 Overflow en offsets de slots | Saturación | `uint16_t base/slot` en frames: >65535 locales/params → wrap → acceso al slot equivocado (corrupción lógica) | Función con 70.000 locales (typechecker/emitter) |
| AST-057 | CWE-662/CWE-400 hash flooding | DoS | `string_table.c`: hash sin aleatorización → DoS por colisión si se procesan fuentes maliciosas (aplicable a servidor/CI) | Corpus con colisiones forzadas (medir) |
| AST-058 | CWE-128/190 Off-by-one | Boundary | `path[plen] = '\0'` estilo off-by-one en strings internados con `len` exacto de la capacidad | ASan con literales cuyo longitud = potencia de 2 |
| AST-059 | CWE-476 puntero tras `?` | Use tras error | Operador `?` que sale con `*out` sin escribir → valor de retorno sin inicializar leído por el caller | PoC `?` en la última expresión de cada forma |
| AST-060 | CWE-330/940 Canal lateral | Confusión de rutas | `--emit-c` escribe `archivo.c` **junto al fuente**: compilar fuente en `/tmp` compartido escribe en directorio atacante-creable (symlink race: `foo.astra` → `foo.c` como symlink a fichero sensible) | Ataque symlink: `ln -s /etc/x foo.c` |

## 3. Nivel BÁSICO — 30 casos (CVSS 0.1–3.9: menores, robustez, calidad de diagnóstico)

| # | CWE | Arquetipo | Extrapo­lación a Astra | Detección |
|---|-----|-----------|------------------------|-----------|
| AST-061 | CWE-703 Manejo de errores | Menor | Builtins con `argc` erróneo devuelven mensajes con «arguments» inconsistente / número mal | Tabla de casos de arity × mensaje |
| AST-062 | CWE-754 | Menor | `ord("")` documentado — verificar `len(nil)` y compañía | Suite de builtins con tipos malos |
| AST-063 | CWE-459 | Menor | `fclose` olvidado solo en rama rara de dumps | Revisión/valgrind |
| AST-064 | CWE-561 Código muerto | Menor | `constructs/*.c` hooks `parse/check/emit` no usados (§8 registry) — confusión de mantenimiento | `--dump-constructs` vs código |
| AST-065 | CWE-665 | Menor | Flags de estado no inicializados en rutas raras (`ov`, `error_count`) | MSan/revisión |
| AST-066 | CWE-662 | Menor | Estado `static` mutable en construct registry (solo lectura después de init) | grep `static` no-const |
| AST-067 | CWE-676 Uso de mecanismos peligrosos | Menor | Uso de `strcpy`/`sprintf` detectado: hoy ninguno (grep limpio) — **regresión vigilable** | grep en CI |
| AST-068 | CWE-116/117 Escape en dumps | Menor | `--dump-tokens` con bytes de control en literales → terminal corrompida (inyección de escape) | Literal con `\x1b]0;...` + dump |
| AST-069 | CWE-697 Cálculo incorrecto | Menor | Columnas/offsets en mensajes de error desplazados en presencia de tabs/UTF-8 | Casos con `\t` y bytes >127 |
| AST-070 | CWE-755/703 exit codes | Menor | Códigos de salida: ¿todos los errores ≠ 0 y los éxitos = 0 en cada subcomando? | Matriz de CLI × exit code |
| AST-071 | CWE-253 Comprobación de retorno | Menor | Retorno de `fwrite`/`fprintf` ignorado en salida de `--emit-c` (disco lleno → `.c` truncado compilable) | `ulimit -f` + emit |
| AST-072 | CWE-681 | Menor | `%ld` con `long` sobre `int64_t` en plataformas donde difieren; `(long)v.as.int_val` en prints | Compilar en 32-bit/Windows-cross |
| AST-073 | CWE-128 | Menor | `char msg[192]`/`msg[96]` del runtime con mensajes largos (ruta + identificador) → truncación del diagnóstico | Mensajes con nombre 500 chars |
| AST-074 | CWE-242 Uso de función potencialmente peligrosa | Menor | `getenv` de `ASTRA_*` sin validar (¿`ASTRA_DUMP_VM` no afecta semántica?) — ver que ningún env cambia resultados de compilación | Comparar salida con/without env |
| AST-075 | CWE-476 | Menor | `f = fopen` y chequeo de `feof` vs `ferror` confundidos (ya corregido en `read_file` — ¿otros sitios?) | grep `fopen` |
| AST-076 | CWE-703 | Menor | Mensajes «expected 1 arguments» (gramática) y mensajes sin `file:line` en alguna ruta (paridad de diagnósticos con zig) | diff de mensajes seed↔zig |
| AST-077 | CWE-665 | Menor | Arrays de opcodes/`opcode_is_fallible` desactualizados vs opcodes nuevos (invariante de anotación de línea) | `--check` + auditoría de switch exhaustivo |
| AST-078 | CWE-476 | Menor | `strcmp` con `name` NULL en rutas de `GET_GLOBAL`/builtins (`name &&` presente — verificar todos) | grep `strcmp(` sin guard |
| AST-079 | CWE-190 | Menor | `line`/`col` en `uint32_t`: fichero con >4000 M de líneas → wrap en mensajes | (límite teórico) |
| AST-080 | CWE-20 Validación de CLI | Menor | Opciones desconocidas/argumentos repetidos: ¿rechazo limpio? (zig ya fixó «unknown option») — el seed | `astra-seed --nope` |
| AST-081 | CWE-754 | Menor | Extensiones: fichero sin `.astra` (rama del `memcpy` de `out_path`) — ¿path correcto? | Compilar `foo.txt` |
| AST-082 | CWE-459 | Menor | Ficheros de salida a media escritura no eliminados (artefacto huérfano) | Disco lleno simulado |
| AST-083 | CWE-665 | Menor | Orden de inicialización de builtins en VM (`vm->builtin_*`) — algún puntero a función no seteado en rutas parciales | ASan en driver con fases omitidas |
| AST-084 | CWE-117 | Menor | Fuga de contenido de fuente en mensajes (hasta 40 chars) — ¿podría exfiltrar línea sensible? (comportamiento documentado — verificar límite) | Fuente con token secreto largo |
| AST-085 | CWE-703 | Menor | Diferencia de mensajes entre rutas de error idénticas («cannot open» para error de lectura, ya visto `read_file`) | Casos I/O |
| AST-086 | CWE-252 | Menor | `realloc` del emitter sin comprobar (¿`emitter.c` crece `code`/`constants` con check?) | grep `realloc` en seed/src |
| AST-087 | CWE-561 | Menor | Tests huérfanos: `tests/*.c` generados a mano que enmascaran bugs de codegen (¿se regeneran siempre?) | Regenerar y diff |
| AST-088 | CWE-665 | Menor | Constantes de fase (`max_slot`) recalculadas si cambia el orden de emisión | Fuzz de orden de declaraciones |
| AST-089 | CWE-703 | Menor | `--dump-bytecode` con índice de constante fuera de rango (dump confiado al bytecode) | Bytecode mutado |
| AST-090 | CWE-770 | Menor | Sin límite de tamaño de fichero de entrada (lectura completa a memoria) — 10 GB `.astra` = OOM | `truncate -s 5G x.astra` |

## 4. Puertas de verificación (ya disponibles en el repo)

```bash
cd seed && make debug      # ASan+UBSan+LSan  → cubre AST-0xx de memoria
make test                  # suite conformance + codegen round-trip
make fuzz && make fuzz-run FUZZ_TIME=300   # cubre AST-013, 001, 012, 090...
./zig/tests/llvm_parity.sh # VM ↔ C ↔ LLVM (paridad semántica)
./zig/tests/llvm_sanitize.sh  # ASan sobre artefactos LLVM
./zig/build -Dllvm && ./zig-out/bin/astra-zig --jit  # AST-028
./astra-seed --check-constructs    # invariantes de registro
```

## 5. Referencias

1. FIRST, CVSS v3.1/v4.0 Specification — Severity Rating Scale (9.0–10.0 Critical…).
2. MITRE, *2025 CWE Top 25 Most Dangerous Software Weaknesses* (cwe.mitre.org/top25/archive/2025).
3. CISA, *Secure by Design Alert: Eliminating Buffer Overflow Vulnerabilities*.
4. CISA/NOTA: CVE-2026-109618 y CVE-2026-109619 («php2shell», CVSS v4.0 9.2 / v3.1 9.8).
5. SecPod, CVE-2026-111497 «Node2Shell» — heap overflow de 8 bytes por confusión de estado en el decodificador.
6. SentinelOne, CVE-2026-48122 — Ruby LSP: repositorio malicioso → RCE.
7. Google oss-fuzz — `Heap-buffer-overflow WRITE/READ` (clase de hallazgos).
8. Interno: `Documentacion/07_investigacion/025_critica_externa_seguridad_y_proceso.md` (diseño), `seed/AGENTS.md` §Invariantes.
