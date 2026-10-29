# 032 — Typechecker en Astra-0: alcance, estructuras de datos y gates

> **Alcance**: investigación (sólo lectura) para el paso 5 del plan de
> crecimiento de `PHASE1_PROGRESS.md` §7 — «typechecker (proyecto aparte —
> `research/002` §6.3, ~4k líneas de C)». Fuentes: `research/002` §5.2/§5.4/§6.3/
> §8/§12, `COMPILER_STRATEGY.md` §7.1, `seed/src/typechecker.c` (4677 líneas,
> 102 mensajes, 125 sitios de error), `zig/src/typechecker/typechecker.zig`
> (3322 líneas), el corpus `seed/tests/conformance/` (304 ficheros, corrido
> contra `parser.astra`), el emitter LLVM (`zig/src/llvm/emitter.zig`) y 20
> experimentos ejecutados en las rutas VM-zig/LLVM. **No modifica ningún
> fichero del repo**; ninguna decisión se toma aquí — abre la lista que
> `DEC-032` debe cerrar (§6). Fecha: 2026-10-29. **[verificado]** = ejecutado
> o leído en esta sesión.

---

## §0 La frase que define el paso

`PHASE1_PROGRESS.md` §7: **«5. Solo entonces el siguiente componente:
typechecker (proyecto aparte — `research/002` §6.3, ~4k líneas de C)»** —
los pasos 1–4 (NEWLINE, match+lambdas, items, diagnósticos) están cerrados
con DEC-028..031. La cadena ratificada es: seed C → frontend Zig a mano →
**fuentes Astra-0 del compilador compiladas por `astra-zig`**
(`COMPILER_STRATEGY.md:612-615`, Step 4) → punto fijo de auto-compilación
(`:617-620`). `research/002 §6.3` (313-336) es el hito: «Write the
self-hosting compiler in Astra-0, compile it with the seed, verify it can
compile itself», con el criterio `diff astra-v2.c astra-v3.c` byte-a-byte.

Lo que la doc **ya fija** (§1 de la síntesis de fuentes):

- **Superficie**: el compilador en Astra usa sólo Astra-0
  (`002 §5.4:254-259`: sin comptime, sin fibras, sin ARC/ORC, **sin traits,
  sin generics** — «use concrete types»). Tier 1-2 de `002 §5.2` es el
  lenguaje disponible; el Tier 3 («stdlib io/string/collections») está
  **parcialmente hecho**: el listado operativo es el de `research/028`
  M1–M3 = DEC-013..024, **todo implementado en 4 rutas** (`INDICE.md:136`).
  El listado distinto de `002 §12.3` (`concat`, `abs`, `sqrt`) está
  **superado** — no lo usar.
- **Gates heredados**: patrón selfhost = fixture + golden commiteado +
  rutas (4 para io, **7** para lexer/parser) con skip limpio, más el gate
  «fuerte» que compara contra la implementación en C (`lexer_tokens_parity`
  vs `--dump-tokens`; freshness vs `--dump-ast`; desde DEC-031,
  `parser_diag_parity` 16/16). Los gates de suite que todo PR mantiene
  verdes: `make test`, `sweep_emit_c`, `zig build test`, `dump_parity`,
  `ui_message_parity`, `llvm_parity`×2, jit/cross/wasm/sanitize.
- **Memoria**: los VMs no liberan (DEC-009) — sin techo propio; el techo
  64 MB de `llvm_mem.sh` sólo cubre la ruta LLVM.

## §1 Qué tiene que typecheker v1 (inventario de checks)

De los **102 mensajes / 125 sitios** de `typechecker.c`, el subconjunto que
el fixture `parser_input.astra` ejercita en sus caminos de aceptación + los
negativos del corpus parseable hoy (~77 `ui/`) pide ≈ **55 mensajes**:

| Bloque | Checks (mensaje exacto entre comillas — `typechecker.c`) |
|:--|:--|
| Nombres | `undefined variable '%s'` · `duplicate function '%s'` · `duplicate field '%s' in struct '%s'` · `duplicate variant '%s' in enum '%s'` · `method '%s' is already defined for type '%s'` · `'%s' is a builtin and cannot be redeclared` (DEC-015; kBuiltins = print…chr, read_line, **transfer, copy**) · `generic function '%s' used as a value` (postergable con generics) |
| Funciones | `expected %zu arguments, got %zu` · `argument %zu: expected %s, got %s` · `function '%s' returns %s but its body has type %s` · `function '%s' declares that it returns %s but its body produces no value…` · `return type %s does not match function return type %s` · `return outside of a function` |
| let/const | `variable '%s' must have a type annotation or initializer` · `type mismatch: variable '%s' declared as %s but initialized with %s` · `integer literal %lld out of range for %s` (DEC-006) · `variable '%s' cannot be initialized with a void expression…` (const homólogos) |
| Asignación | `invalid assignment target` (LValue) · `cannot assign to immutable variable '%s'` · `cannot assign through immutable variable '%s' (declare it with 'let mut')` · `cannot assign to string element` · `type mismatch: cannot assign %s to %s of type %s` · `cannot reassign function '%s'` |
| Operadores | `logical operator requires bool, got %s` · `arithmetic operator requires numeric type, got %s` · `type mismatch: cannot apply '%s' to %s and %s` · `type mismatch: cannot compare %s and %s` · `bitwise operator requires integer type, got %s` · `negation requires numeric type, got %s` · `logical not requires bool, got %s` · `bitwise not requires integer type, got %s` |
| Índice/literals | `cannot index non-array type %s` · `array index must be integer type, got %s` · `array element %zu has type %s, expected %s` |
| Llamadas/métodos | `cannot call non-function type %s` · `use Enum.Variant to construct '%s'` (DEC-008) · `variant '%s.%s' expects %zu field(s), got %s` · `type of 'self' must be '%s'` · `impl requires a struct or enum type, got %s` · `unknown trait '%s'` · `type '%s' does not implement trait '%s': missing method '%s'` · `signature of method '%s' of '%s' does not match trait '%s'` · `default trait methods are not yet supported` |
| Struct/enum | `unknown struct '%s'` · `struct '%s' has no field '%s'` · `missing field '%s' in '%s' literal` · `field '%s' expects %s, got %s` · `cannot access field on non-struct type %s` · `duplicate field '%s' in struct literal` · `enum '%s' has no variant '%s'` |
| match | `pattern must be a literal, '_' or Enum.Variant` · `pattern type %s does not match match target type %s` · `variant '%s' has %zu fields but pattern binds %zu` · `match guard must be bool, got %s` · `match arm type %s does not match previous arm type %s` · **exhaustividad (6)**: `non-exhaustive match: missing variant '%s.%s'` / `missing 'none' arm` / `missing 'false' arm` / `missing 'true' arm` / `non-exhaustive match: missing '_' arm` / `missing payload arm (some/ok/err)` |
| Control/lambda | `if condition must be bool, got %s` · `if branches have different types: %s vs %s` · `while condition must be bool, got %s` · `lambda requires explicit return type annotation` · `'break'/'continue' used outside of a loop` (**viven en el EMITTER, no en el typechecker** — `emitter.c:2263/2280`; v1 debe implementarlos con el mismo texto o excluir esos 5 `ui/`) |
| `?`/opcionales | `? operator requires Result or Option, got %s` · `? operator requires the enclosing function to return an optional type` |
| Módulo | pasos 0 (struct/enum nominal con forward refs), 0.5 (traits, firmas), 1 (fn/impl/conformance), 2 (cuerpos); `use/import/from` = **void sin ningún check** (se descartan); `pub` = **nunca inspeccionado** |

Tres reglas de `type_eq` que v1 **debe** reproducir (líneas 48–85): `unknown`
casa con todo; `nil ≃ optional`; **adopción de literales enteros**
(`5` adopta i32/i64/u32/u64; default DEC-006 = i32, o i64 si no cabe).

Quirks verificados que el port debe clonar (o decidir no clonar — DEC-032):
el retorno de un `fn` **sin anotación** no se chequea (los `return` pasan
sin comparar); la anotación de retorno de una **lambda** no se compara con
el body-tail (`|x: i32| -> i32 { "s" }` compila); no existe ningún check
de código inalcanzable; no hay check de `let` duplicado (shadowing legal).

**No ejercitado por el fixture (postergable)**: generics/§4bis (~15
mensajes), ownership §8b (12 ficheros `transfer_*`), builtins `transfer`/
`copy` (15 ficheros), sintaxis `T?`/`[T]`/`fn(..)` (ni siquiera la parsea
hoy parser.astra).

## §2 Corpus y factibilidad medida

`parser.astra` corrió sobre los **304** ficheros de `conformance/` **[verificado]**:

| | total | parsea hoy | detalle |
|:--|--:|--:|:--|
| no-ui | 160 | **99** | positivos del gate |
| ui | 144 | **90** | 77 con `EXPECT-ERROR` utilizables (~61 typechecker, 10 builtin-shadow, 3 «must be called»/«has no field», **5 emitter-owned**: `break/continue_outside_loop`, `loop_nesting_deep`, `capture_assign`, `too_many_locals`; **12 `transfer_*`** necesitan §8b) |
| **suma** | 304 | **189 (62 %)** | v1 gatea ≈ **176 ficheros sin tocar el parser** |

Los **115 que no parsean**: 24 son `ui/` de errores de parseo (irrelevantes
— el seed los rechaza también) y **91 son parseables por el seed y no por
`parser.astra`** — la medida de cada gap: **`for`/`continue`/rangos ≈ 14
ficheros · generics ≈ 20 · `?`/tipos opcionales ≈ 8 · `some/none/ok/err`
como keyword (forma AST distinta), escapes de string, ops bitwise,
compound assign**. Esos 91 son el backlog medido de futuras extensiones del
parser (cada paso en la misma forma DEC-gated de DEC-028..031).

## §3 Restricciones de datos en las 4 rutas (lo que decide el diseño)

Tabla completa con citas en la §1 del informe de factibilidad; lo que
**obliga** al diseño:

| Restricción | Veredicto | Citación |
|:--|:--|:--|
| `a[i][j]`, `let r = a[i]; r[j]`, `for r in m { r[j] }` | **muerto en LLVM** (`array without an element type`); funciona copiando a un local **anotado**: `let row: [i32] = m[0]` | `emitter.zig:1542/1553/2210`; experimentos e1–e4 |
| `a[i].field` (índice→campo) | **muerto en LLVM**; `s.arr[i]` (campo→índice) **vivo** (lectura, escritura y push) — pinneado por `structs/field_assign.astra` y `codegen/copy_independent.astra` dentro de las 221 | `emitter.zig:1699`, `1725-1730` |
| Arrays heterogéneos | imposibles en las 4 rutas (literal: elemento0; VM push: kind; LLVM push: pty) — un AST no puede ser un array mixto de strings y nodos | `typechecker.c:2011`, `vm.c:670`, `emitter.zig:4162` |
| `[[i32]]` | valores anidados OK (push/len/==/print/campo); **indexar fila sólo con local anotado**; el corpus sólo lo usa en `aggregate_equality.astra:26` (comparación, nunca índice) | experimentos e8/e13 |
| `[]` vacío | rechazado en LLVM; idiom = sembrar con `[""]` + push (DEC-024) | `emitter.zig:1421`; `stdlib/split_basic.astra:11` |
| Strings | `+` (copia O(n) → append O(n²)), `==`/`!=` por contenido, `s[i]`, `len`, `substr`, `ord`, `chr`, `to_string`(i64), `for c in s` — **suficiente para tabla de símbolos por escaneo lineal**; **`<` de strings = error de runtime** (sin ordenación) | `vm.c:328/1251/1416`; experimento e16 |
| Profundidad | llamadas **256** en las 4 rutas; **256 globales** (¡cada `fn`/`let`/`const` de nivel módulo consume uno!); frame 1024 slots; LLVM: 64 campos de struct, 15 params, 32 brazos de match | `priv.h:220-221`, `emitter.zig:367/5389` |
| Closures | capturan por valor; en LLVM **lambda exige `-> T` anotado** (la VM acepta sin anotar) | experimento e18; `emitter.zig` «lambda requires a known return type» |

Baseline probado: `lexer.astra` (192 líneas, sin arrays) y `parser.astra`
(1207 líneas, 38 fns, **sin arrays** — su «AST» es un string s-expresión)
corren en 7 rutas. **Ningún Astra-0 del repo indexa nunca un array de
arrays.**

## §4 Representaciones candidatas (decisión de DEC-032)

**(a) El AST que camina el typechecker** — hoy `parser.astra` sólo *imprime*
s-expresiones; el typechecker necesita un árbol recorrible. Tres opciones:

1. **SoA en un struct (recomendada)**: `struct Ast { kind: [i64], a: [i64],
   b: [i64], s: [string] }` — los hijos son índices `i64` dentro de la misma
   arena; los payloads de nombre van a `s`. Todo acceso caliente es
   `ast.kind[i]` — **campo→índice, 100 % soportado en lectura Y escritura
   en LLVM sin danza de anotaciones**; un solo slot global frente a ~6
   columnas sueltas (importa contra el cap de 256 globales); crece con
   `ast.kind = push(ast.kind, k)` e idiom de siembra `[""]`. Dispatch de
   kind = `match` sobre literales i64 (≤32 brazos por match).
2. **Array de structs de nodo**: viable pero cada toque necesita
   `let nd: Node = nodes[i];` (índice→campo está prohibido en LLVM);
   cómodo en rutas frías, invasivo en calientes.
3. **Columnas globales paralelas**: lo que `parser.astra` ya hace con
   escalares — funciona, pero quema slots de los 256 globales.

**Consecuencia de diseño clave**: refactorizar `parser.astra` para
*construir* las tablas SoA en vez de imprimir, y que la s-expresión
imprimida sea un **rendering de esas tablas** — el gate de rutas/freshness
existente sigue funcionando byte a byte, y el typechecker consume las
tablas directamente (por `read_file`… no: por compartir el mismo fichero —
ver §6-abi).

**(b) La tabla de símbolos**:

1. **Entradas planas + pila de marcas de scope (recomendada)**: struct SoA
   (`names: [string]`, `types: [i64]`, `muts: [bool]`) + `marks: [i64]`
   (pila de aperturas; pop = truncado lógico). Lookup = escaneo lineal con
   `==` (igualdad por contenido probada); insert = `push` paralelo en cada
   columna. **Todo campo→índice: LLVM-safe sin anotaciones.**
2. Hash abierto en dos arrays 1-D (`keys`/`vals` con hash polinómico vía
   `ord`/`s[i]`) si el coste importa; mismas garantías LLVM. `[[i64]]`
   **fuera de la mesa** (índice de fila prohibido en LLVM).
3. Frames-como-structs: viable sólo con struct literal fresco (alias por
   handle — `alias_write.astra`); la marca de opción 1 es más simple.

La disciplina que LLVM impone — **stringly-typed, index-based,
campo→índice, sin arrays vacíos, con copia-anotada como única escapatoria**
— es exactamente el subconjunto en el que ya vive `parser.astra`,
extendido con columnas 1-D dentro de structs.

## §5 Shape del gate diferencial

Sin `--dump-types` en ningún compilador **[verificado]**, el gate fuerte no
puede ser «diff de un dump» — es **diferencial contra el seed**:

1. **Veredicto + primera línea** por fichero (patrón de
   `parser_diag_parity.sh`, DEC-031): para cada fixture del corpus
   curado, `astra-seed f` (accept ⟺ exit 0) y el typechecker-Astra (su
   propio parser → sus tablas → sus checks) deben coincidir en
   **veredicto** y en la **primera** `file:line:col: error: msg`
   (rutas normalizadas). Cascadas fuera de alcance v1 — igual que DEC-031
   §3.
2. **Honor a las directivas**: `EXPECT-ERROR` = substring de la primera
   línea (los `ui/` ya pinnean `line:col` exactos con
   `EXPECT-ERROR-FIRST`); un `EXPECT-ERROR` por fichero (regla del repo).
3. **Freshness**: los primeros-errores esperados se extraen del seed
   actual en cada corrida (como el golden del parser) — deriva del seed =
   rojo.
4. **Rutas**: el typechecker-Astra es código Astra-0 → **las mismas 7
   rutas** del `parser_gate.sh` (seed VM, C, zig, `--jit`, `--emit-obj`,
   cross, wasm) reutilizando su infraestructura; seed-only el gate
   diferencial (como `lexer_tokens_parity`).
5. **Corpus v1**: ≈176 ficheros medidos hoy (§2); los 91 no-parseables
   son backlog de extensiones del parser, no del typechecker.

## §6 Preguntas abiertas para DEC-032

1. **Rutas**: ¿7 (patrón lexer/parser) o 4 (patrón io)? (Ningún doc lo
   decide.)
2. **Formato de entrada**: refactor de `parser.astra` a tablas SoA (§4a-1,
   recomendado) vs. que el typechecker re-analice el string s-expresión
   (no recomendado: re-parsear un parse) vs. formato máquina aparte.
3. **Alcance de v1**: ¿el subconjunto «fixture + 176» de §2 con los ~55
   mensajes de §1? ¿Se excluyen o implementan los 5 mensajes emitter-owned
   (`break/continue outside loop`…)? ¿Se incluye §8b (ownership) — 12
   ficheros — o queda para cuando `transfer` sea Astra-0?
4. **Los quirks**: ¿el port clona el retorno-sin-anotar sin chequear y la
   lambda-anotada-sin-comparar (paridad byte a byte) o los corrige y abre
   divergencia documentada? (Regla: el seed es la referencia salvo DEC.)
5. **`some/none/ok/err`**: parser.astra los lexea como IDENT (no keyword)
   → forma AST distinta del seed — ¿el typechecker los resuelve como
   variantes builtin por su cuenta (DEC-008) o se extiende el lexer del
   parser primero?
6. **Un archivo o el árbol `src/compiler/`**: ¿`selfhost/typechecker.astra`
   single-file (patrón actual, LLVM-safe) o primer paso del árbol Step 4?
   (El LLVM no compila multi-fichero — `12_rutas_ejecucion.md:320-322`.)
7. **Presupuesto de recursos**: 256 globales incl. todo `fn` de módulo y
   256 de profundidad de llamada son los topes reales del diseño — ¿se
   mide el RSS en el gate (análogo a `llvm_mem.sh`)?
8. **Verdad de semántica**: `typechecker.c` byte a byte (doctrina
   dump-parity) o las DEC ratificadas donde divergen? (Los 102 mensajes
   ya son la referencia de facto; DEC-006/008/015/022/026 están
   ratificados.)
9. **Scheduling**: después del typechecker, ¿el emitter (028 §5: «el
   codegen va el último») y cuándo se migra el conjunto al árbol
   `src/compiler/` de Step 4; interacción con DEC-021 (CLI, sigue
   `Propuesta`).
10. **Los dos hallazgos sin pinnear** de `PHASE1_PROGRESS §7`
    (`else` en línea aparte; `if/else-if` multilinea como cola no tipa) —
    un typechecker choca con ellos de inmediato: cerrarlos con DEC+test
    antes (regla «decisiones antes que código»).

## §7 Tamaño y estimación

| | líneas | mensajes |
|:--|--:|--:|
| `seed/src/typechecker.c` | **4677** | 102 (125 sitios) |
| `zig/src/typechecker/typechecker.zig` | 3322 | 106 |

v1 = ~55 mensajes del §1 + el refactor SoA del parser + el gate diferencial
de §5. Estimación (opinión calibrada, sin velocidad histórica por feature —
la misma salvedad que `028 §0`): **~10–15 días-hombre** para el ciclo
completo (refactor SoA del parser con gates existentes verdes → núcleo de
checks → methods/trait/match/exhaustividad → gate de corpus 176 → docs),
repartible en 4–5 PRs en la forma DEC-gated de la serie DEC-025..031.

---

**RealidadIntegration** · 2026-10-29 · evidencia: este informe + corpus
corrido (189/304) + 20 experimentos de ruta · siguiente artefacto:
`DEC-032` respondiendo §6.
