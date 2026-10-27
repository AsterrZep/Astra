# 025 — Análisis de la crítica externa: el cuarteto de promesas de seguridad y el proceso

> **Alcance**: análisis y verificación de una crítica externa recibida sobre el
> lenguaje. Ningún código de producción se toca en este documento. Fecha:
> 2026-10-27. Todo lo marcado **[verificado]** se ejecutó o se leyó en este
> repo durante la investigación (Debian, seed compilado con `make`); lo marcado
> **[citado]** es conocimiento de dominio sobre otros lenguajes, no verificado
> en línea en esta sesión (la búsqueda web no estuvo disponible). La crítica
> recibida se reproduce en §2 bajo el título «afirmación» y se contrasta
> cita por cita con archivo:línea o con la salida de un comando.

---

## 0. Resumen ejecutivo

1. **La crítica acierta en el diagnóstico central.** Las cuatro promesas del
   README (seguridad, sin pausas de GC, sin borrow checker, fibras que comparten
   datos) **no tienen ningún mecanismo de aplicación escrito en ninguna parte**
   del repo **[verificado]**: `ARCHITECTURE.md` enuncia reglas (§2.4, §2.5) pero
   nunca dice quién las verifica; `transfer(var)` y `Atomic[T]` **no existen como
   constructo en el código** (`grep` en `seed/src` y `zig/src`: 0 apariciones
   reales, ver §2.1) mientras `README.md:124-125` los da por hechos.
2. **La contradicción aliasing↔transfer es real y además está cementada en la
   suite.** `ARCHITECTURE.md:60-72` (§2.5) fija que `let b = a` comparte el
   handle y lo **pincha con un test**: `seed/tests/conformance/arrays/alias_write.astra`
   (`EXPECT: 99`) **[verificado]**. `transfer(a)` (§2.4) solo invalidaría el
   binding `a`; `b` seguiría apuntando al agregado. Ningún análisis de
   unicidad, de ownership ni de escape está especificado ni implementado.
3. **Las cuatro «decisiones abiertas» de la crítica se reproducen todas**
   **[verificado]** (§2.8): ancho de enteros ignorado por la anotación (`i32`
   con `9999999999` imprime `9999999999`), `let` no impide mutación a través
   de un alias (imprime `5`), la memoria nunca se libera en ejecución (un
   bucle que aloja 2M de arreglos llega a **408 MB de RSS** sin liberar nada),
   y las variantes de enums colisionan entre enums (reproducido; el mensaje
   exacto «expected enum, got enum» **no** existe en HEAD, la sustancia sí).
4. **La crítica acierta en el proceso**: el registro de constructs tiene
   `0 / 47` constructos migrados a sus hooks **[verificado con
   `--check-constructs`]** — los 47 asignan `.parse/.check/.emit = NULL` y
   nadie los consume fuera del self-check; el trabajo de los últimos ~6 semanas
   se concentró en backends/paridad (**73 commits de 234**, ~31%); hay
   **40.693 líneas** de documentación en `Documentacion/` antes de este informe
   (**41.140** con él) **[verificado]**.
5. **Donde exagera**: plantea el problema como binario («borrow checker o
   nada»), cuando hay un espacio intermedio real (tipos de unicidad,
   `isolate`-style, deep copy en el cruce de fibras — que el propio
   `ARCHITECTURE.md:31` ya nombra sin reconocerlo como opción). Y sus cifras
   están desfasadas (226→**234** commits, 68→**73**, 5→**6** semanas,
   `README:120`→**124**); la sustancia no cambia.
6. **Recomendación** (§4): decidir y **escribir el mecanismo** de aplicación
   de «una fibra a la vez» antes de construir más backends; congelar las cuatro
   decisiones de runtime con una conformance test cada una; corregir
   `COMPILER_STRATEGY.md` §7.1 (paso imposible); y añadir el mínimo de
   stdlib de Astra-0 (`len`, `push`, índice/iteración de strings,
   int→string, lectura de ficheros) como paso previo a un lexer mini escrito
   en Astra.

---

## 1. Metodología

- Seed compilado con `make` (clang, `-Wall -Wextra -Wpedantic`); todos los
  programas de reproducción están en `/tmp/opencode/astra-critica/` y se
  listan íntegros en §6.
- Citas de documentos: `grep -n` sobre el fichero indicado; se transcribe
  `archivo:línea`.
- Presencia/ausencia de features: `grep -r` sobre `seed/src` y `zig/src`
  (`*.c`, `*.h`, `*.zig`).
- Conteos: `git log`, `wc -l` sobre `Documentacion/`.
- Registro de constructs: `./astra-seed --check-constructs` + lectura de
  `constructs/*.c` y `constructs/construct.c`.

---

## 2. Verificación cita por cita

### 2.1 El cuarteto de promesas

| Afirmación de la crítica | Veredicto | Evidencia |
|:-------------------------|:----------|:----------|
| README.md:21 promete «sin la complejidad del Borrow Checker de Rust ni pausas de GC» | **[verificado]** | `README.md:21` |
| ARCHITECTURE.md:875 dice «ARC/ORC atómico — Thread-safe sin borrow checker» | **[verificado]** | `ARCHITECTURE.md:875` |
| ARCHITECTURE.md:118: un `var` es «solo una fibra a la vez», se comparte con `transfer(var)` o `Atomic[T]` | **[verificado]** | `ARCHITECTURE.md:118`; la regla completa está en §2.4 (`:50-57`) |
| El diseño nunca dice cómo el compilador haría cumplir sus reglas | **[verificado]** | `grep -inE "uniqueness|linear type|ownership|borrow" ARCHITECTURE.md`: solo la frase de marketing (`:3`, `:875`) y la tabla comparativa (`:861`). **No existe** sección de enforcement: ni análisis de unicidad, ni de ownership, ni de escape, ni check en runtime |
| `transfer` y `Atomic[T]` están en la doc pero no en el código | **[verificado]** | `grep -rn "transfer" seed/src` → 0; en `zig/src` solo 2 coincidencias en **comentarios** sin relación (`llvm/jit.zig:70` «transferir la propiedad al JIT», `llvm/emitter.zig:3445` «Store con transferencia»); `grep "Atomic\["` en ambos árboles → 0. `Atomic` solo aparece como la producción gramatical `AtomicType` (`type_annotation.c:4`). `channels`/`atomics`: 0 en ambos árboles |
| README.md:120 (hoy 124) marca `[x] Memory model (ARC/ORC, cycle detection, fiber-aware)` | **[verificado con desfase de línea]** | `README.md:124` (y `:125` marca también `[x] Concurrency model (green threads, channels, atomics)`) |

**Análisis.** El cuarteto es exactamente la combinación que ningún lenguaje
de producción ofrece gratis, y el repo no elige entre ellas: §2.4 da la regla
(«transfer invalida la variable emisora»), §2.5 da la semántica de agregados
(«`let b = a` comparte el handle»), y **nada en medio**. La crítica tiene
razón en que la regla «una fibra a la vez» es, tal como está escrita, una
aspiración: no hay código que la verifique ni doc que diga qué la verifica.

**Matiz importante (no favorece al repo):** la semántica de compartir de §2.5
no es un descuido — está **fijada por un test de conformidad**
(`alias_write.astra`, `EXPECT: 99`). Es decir: la decisión «compartir handle»
ya está tomada y cementada; lo que falta es la contraparte de seguridad de
`transfer`. Cambiar a semántica de move rompería un test verde: la crítica
tiene razón en que «elegir tiene coste», y el coste ya es visible.

**Matiz sobre closures:** los closures de Astra-0 capturan **por valor**
(`AGENTS.md:338`), pero «por valor» copia el *handle* (`Value`), no el
agregado — así que capturar **no reduce el aliasing**: amplifica el problema
que plantea la crítica (un closure enviado a otra fibra arrastra el alias).

### 2.2 El ejemplo aliasing ↔ transfer

```astra
let mut a = [1, 2, 3]
let mut b = a      # §2.5: b comparte el arreglo de a
transfer(a)        # §2.4: a queda inválida
b[0] = 99          # b sigue apuntando → dos fibras escribiendo a la vez
```

- `transfer()` **no existe** en el compilador **[verificado]**: el ejemplo no
  se puede ejecutar hoy. Es una **contradicción de diseño futura**, no un bug
  vivo. La crítica lo presenta correctamente como problema de diseño.
- Para rechazar el programa, el compilador tendría que saber que `b` aliasa a
  `a` — incluyendo aliases creados por captura de closures. Eso es análisis de
  aliasing/unicidad. **[verificado]**: no hay rastro de ese análisis en
  `typechecker.c` ni en el Zig port (`grep` sin resultados).
- La crítica dice: «eso es lo que hace el borrow checker de Rust; no es
  complejidad extra, es la seguridad». **Para la garantía estática tal como
  está especificada, es correcto.** El matiz (§3.1) es que el espacio entre
  «sin check» y «borrow checker completo» es más ancho de lo que la crítica
  admite.

### 2.3 El contador RC y el coste atómico

| Afirmación | Veredicto | Notas |
|:-----------|:----------|:------|
| Dos fibras hacen `count = count + 1` sobre un objeto compartido → carrera de RMW | **[verificado por diseño]** | Sin `Atomic[T]` implementado no hay primitiva; el análisis es correcto: RC no atómico puede corromperse (doble free / use-after-free) |
| `COMPARATIVE_ANALYSIS.md:131` cita 40% de penalización con threads en Nim | **[verificado]** | Texto literal: «40% performance penalty with `--threads:on` in Nim 2.0» (también `:32` y `:146`) |
| RC atómico protege solo el contador, no los datos | **[correcto]** | Estándar del dominio **[citado]** |
| El colector de ciclos Bacon–Rajan hace trabajo real y retrasa la liberación | **[correcto]** | Trial Deletion descrito en `ARCHITECTURE.md:36-48` — la doc misma describe el trabajo que la crítica señala |

### 2.4 Qué eligieron otros lenguajes

Todo **[verificado 2026-10-27 — fuentes en «Verificación externa» al final]**
(dominio bien establecido; la sesión no tuvo búsqueda web):

| Lenguaje | Elección | Coste real |
|:---------|:---------|:-----------|
| Go | tracing GC concurrente (pausas <1 ms desde 1.8) | Pausas existentes (small); carreras de datos siguen posibles |
| Swift < 6 | RC atómico | Lento + carreras de datos; **Swift 6 añadió verificación en compile-time** (Strict Concurrency) — admisión de que el RC solo no basta |
| Nim | ORC + `isolate`/move | Check de ownership **limitado** (más barato que el borrow checker); anotaciones y rechazos; `COMPARATIVE_ANALYSIS.md:131` de *este repo* cita el 40% con threads (la medición original de Nim no se localizó — ver §Verificación externa) |
| Pony | reference capabilities en el type system | Ownership/aliasing estáticos completos; curva de aprendizaje y APIs restringidas |
| Check en runtime | lock o owner-check por acceso | Overhead por acceso; instrumentar **cada acceso en cada backend** |

Ninguno de los cuatro ofrece el cuarteto gratis. **La crítica pide lo justo:
elegir, escribir el coste y declarar la garantía con honestidad.**

### 2.5 «Nim ya existe y la diferencia no está construida»

- `COMPARATIVE_ANALYSIS.md:114` describe Nim como compilado, sintaxis
  tipo Python, ARC/ORC **[verificado]** — es el pitch de memoria de Astra.
- La ventaja declarada es la concurrencia: `COMPARATIVE_ANALYSIS.md:30`
  («Astra's combination of green threads + ARC/ORC + zero-copy FFI is
  unmatched») **[verificado]**.
- `grep -riE "fiber|scheduler|spawn" seed/src zig/src` → **0 coincidencias**
  **[verificado]**; `thread` solo aparece en comentarios (`emitter.c:2682`) y
  en el stdlib Zig de IO (`link.zig`). **No hay implementación de fibras,
  scheduler ni canales en ninguna parte.**
- `README.md:124-125` sigue marcando `[x]` los dos puntos que no existen
  **[verificado]**.

**Veredicto: confirmado.** La única diferenciación sobre Nim está exactamente
en el sitio donde no hay código.

### 2.6 «Astra-0 no puede escribir su propio lexer»

Ejecutado contra el seed **[verificado]**:

| Prueba | Resultado |
|:-------|:----------|
| `print` como único builtin | `vm.c:1405` — «Built-in: print» es el **único** dispatch de builtin; `grep '"len"\|"push"\|"to_string"' seed/src` → 0 |
| `print(len(a))` | `error: undefined variable 'len'` (rc=1) |
| `s[0]` sobre un string | `error: cannot index non-array type string` (rc=1) |
| I/O de ficheros desde Astra | No existe builtin alguno; `fopen` solo está en el driver de C (`main.c:31`) que lee el fuente |
| `input`, iteración de string, int→string | 0 apariciones |

Matices: los **literales de string y la concatenación sí existen**
(`vm.c:765` concatena con arena), así que «no hay strings» sería demasiado
fuerte — pero la lista exacta de la crítica (len, push, índice, iteración,
int→string, fichero) es correcta. Un lexer en Astra-0 no puede ni leer el
fichero ni recorrer sus caracteres: **el paso 1 del self-hosting no tiene
por dónde empezar**. La propuesta «hacer primero ese stdlib mínimo y luego
un lexer mini en Astra como test real» es correcta.

### 2.7 «La cadena de bootstrap no cuadra»

`COMPILER_STRATEGY.md:588` §7.1 **[verificado]**:

```
Step 3: astra-v0 compiles Zig compiler source
    ./astra-v0 bootstrap/zig-compiler.zig -o astra-zig
```

Y `:303`: «The seed must compile the Zig-based compiler». **Ambos pasos son
imposibles**: Astra-0 no compila `.zig`, y no existe `bootstrap/zig-compiler.zig`
como realidad. La cadena real es: C seed → **port manual** del frontend a Zig
(`zig build`, Zig 0.16) → verificación por suite de conformidad. La crítica
acierta: hay **dos implementaciones** (C y Zig) y **ninguna escrita en Astra**
**[verificado vía AGENTS.md + estructura]**. La historia de bootstrap de
Rust/Go/Zig que cita (semilla en OCaml/C/C++, self-hosting años después)
**[verificado: rust-lang/rust árbol de 2010 → `src/boot/*.ml` (OCaml);
golang/go `src/cmd/dist` en go1.4 → `main.c`/`build.c` (C);
ziglang.org/news/goodbye-cpp → «80,000 lines of C++»]** es correcta, y de
hecho `COMPILER_STRATEGY.md:64` lo admite
(«No language started self-hosted») — contradiciendo su propio §7.1.

### 2.8 Las cuatro decisiones abiertas (todas reproducidas)

| Decisión | Reproducción (seed) | Resultado **[verificado]** |
|:---------|:---------------------|:---------------------------|
| Ancho de enteros | `let big: i32 = 9999999999; print(big)` | Imprime `9999999999` — la anotación no truncó; todo `i64` en runtime. Además `4611686018427387904 + x` **envuelve en wrap silencioso** a `-9223372036854775808` (relacionado: ¿overflow checked o wrap?) |
| `let` vs alias | `let p = P{x:1}; let mut q = p; q.x = 5; print(p.x)` | Imprime `5` — `let` no aporta inmutabilidad observable mientras §2.5 comparta handles |
| Memoria nunca liberada | `grep -c "free(" seed/src/vm.c` → **0**; `grep -c "malloc" seed/src/vm.c` → **0**; todo se aloja con `arena_new*` (`vm.c:53,56,...`); `vm_destroy` es no-op (`(void)vm`) | **[verificado con medición]**: bucle que crea 2M de arreglos de 8 elems → **maxRSS 407.848 KB**, sin liberación en toda la ejecución (la arena se libera en bloque solo al final del proceso) |
| Variantes de enums colisionan | `enum A { Some2(i32) None2 } enum B { Some2(i32) None2 }` + construcción sin calificar | Ambas construcciones resuelven a **A**; `match` contra `B.Some2` falla: «pattern type enum does not match match target type enum» + «non-exhaustive: missing variant 'A.Some2'» (rc=1) |

Matiz sobre el mensaje: la crítica cita «expected enum, got enum»; esa cadena
**no existe** en `seed/src`/`zig/src` de HEAD (grep → 0). La **sustancia se
reproduce** (colisión real, primer enum en ganar, errores confusos). Detalle
adicional encontrado: la construcción **calificada** `A.Some2(1)` falla con
«cannot call non-function type enum» — solo funciona la forma sin calificar,
que es justo la que hace la colisión inevitable.

**Por qué esto no es «un bug para parchear»** (la crítica tiene razón): cada
una de estas cuatro decisiones debe codificarse en el VM del seed, el backend
C, el VM Zig, el backend LLVM (con `--opt-level` 0/2), el JIT, wasm y
aarch64 — **7 rutas** (la crítica dice «seis»; con wasm y aarch64 listados
sean siete). Cada backend construido antes de decidir es un sitio más que
reescribir.

### 2.9 «El trabajo que termina en un test se hace; las decisiones no»

| Afirmación | Veredicto | Evidencia |
|:-----------|:----------|:----------|
| AGENTS.md plantea 47 workstreams de constructs, pero los hooks `parse/check/emit` son NULL y nunca dirigen la compilación | **[verificado]** | `--check-constructs` imprime **«migrated (all three phases): 0 / 47»**; los 47 `constructs/*.c` asignan `.parse = NULL, .check = NULL, .emit = NULL` (p. ej. `binding.c`); el único consumidor de los hooks es el propio self-check (`construct.c:167`); `parser.c`/`typechecker.c`/`emitter.c` **no** consultan al registro |
| ~40k líneas de doc, incluidos los 24 informes de investigación | **[verificado con desfase por este propio informe]** | `Documentacion/`: **40.693 líneas** en 43 `.md` antes de añadir el 025 (**41.140** y 44 `.md` con él); `07_investigacion/`: **24 informes** (001–024) en el momento de la crítica, **25** hoy |
| 226 commits en 5 semanas, 68 de LLVM/paridad | **[verificado con desfase]** | `git log`: **234 commits**; primero `2026-09-16`, HEAD `2026-10-27` → **6 semanas**; **73** commits con «llvm» o «parity» (~31%). Sustancia idéntica |

**Matiz a favor del repo:** el registro **no esconde** el 0/47 — el self-check
lo imprime en verde. El problema no es ocultación sino **ficción de
migración**: la infraestructura de hooks existe, nadie la usa, y mientras
tanto el roadmap marca `[x]` cosas que no existen. Y la disciplina de gates
del repo (paridad seed↔zig, ASan, fuzzing, conformidad) es real — la crítica
apunta bien: **no se gatea lo que importa decidir** porque eso no termina en
un test.

---

## 3. Dónde acierta la crítica y dónde exagera

### 3.1 Exagera: el encuadre binario «borrow checker o nada»

La crítica dice: «eso es lo que hace el borrow checker de Rust; no es
complejidad extra, es la seguridad». Para la **garantía estática fuerte** tiene
razón. Pero el espacio entre «sin ningún check» y «borrow checker completo»
es más ancho de lo que la tabla de «lo que eligieron los demás» sugiere:

1. **Deep copy en el cruce de fibras** — ya nombrada por el propio repo sin
   reconocerla como opción: `ARCHITECTURE.md:31` («si un objeto debe
   compartirse entre fibras, se fuerza la promoción a `AtomicRef[T]` o se
   realiza deep copy»). Copy conservador = **cero análisis de aliasing**, coste
   = copias. La crítica no la evalúa.
2. **Tipos de unicidad / move condicional** — solo transferir cuando el
   binding es *provablemente único* (análisis de flujo sobre aliases
   directos y capturas). Es lo que Nim hace con `isolate` (la propia crítica
   lo llama «a limited ownership check») y lo que hizo el move inicial de Rust.
   **Más barato que el borrow checker** (sin lifetimes, sin préstamos
   compartidos), pero **sí** un check estático — y su punto débil es exactamente
   el que la crítica señala: closures que capturan y se envían a otra fibra.
3. **Owner check en runtime** — la crítica lo lista como «cuesta velocidad»
   sin notar que es el único camino que **no** necesita análisis estático y
   que, bien acotado (check solo en accesos cruzados, promovido a compile-time
   cuando el compiler puede probarlo), es un camino de fases: primero correcto,
   después rápido.

Es decir: la conclusión operativa de la crítica («hay que elegir y escribir
el coste») es correcta; su conclusión fuerte («sin tracking = un deseo») es
correcta **para la garantía estática**, pero **hay tracking más barato que el
borrow checker**, y el repo ya nombra dos de las salidas sin darse cuenta.

### 3.2 Exagera: el proceso es «tests, no decisiones»… con matices

- Cierto: 73/234 commits en LLVM/paridad; registry 0/47; roadmap con `[x]`
  infundados; 40k líneas de doc.
- Pero la suite de conformidad **ya pincha decisiones** (p. ej.
  `alias_write.astra`), lo que demuestra que decisiones se toman — **se toman
  en tests, no en la especificación**, que es peor: la spec (ARCHITECTURE) queda
  desincronizada y cuesta saber qué es norma. La crítica lo dice como «las
  decisiones que definirían el lenguaje no se han hecho»; matiz: algunas están
  hechas *de facto* en tests y **no están escritas como decisiones**.

### 3.3 Aciertos innegables (lista corta para responder)

1. Ningún mecanismo de enforcement para las cuatro promesas, en ninguna fase.
2. §2.4 y §2.5 se contradicen sobre el mismo objeto, y §2.5 está test-pinned.
3. `transfer`/`Atomic[T]`/fibras/canales: doc marcada, código ausente.
4. §7.1 paso imposible (Astra-0 compilando `.zig`) y cadena de bootstrap
   autocontradicha (`:64` vs `:588`).
5. Cuatro decisiones de runtime abiertas, reproducidas, **antes** de que los
   7 backends las codifiquen.
6. Astra-0 sin I/O ni operaciones de string → self-hosting sin primer paso.
7. Registro de constructs con 0/47 migrados mientras AGENTS.md vende 47
   workstreams paralelos.

---

## 4. El espacio de decisión (para «elige uno, escribe su coste»)

| Opción | Garantía que da | Coste que hay que escribir | ¿Encaja con el README actual? |
|:-------|:----------------|:---------------------------|:-------------------------------|
| A. Tracing GC (estilo Go) | Sin race por construction en la recolección; sin aliasing check | Pausas (sub-ms, pero existentes); sobrecarga de barreras | **No** — contradice «sin pausas de GC» |
| B. RC atómico + aceptar carreras (Swift <6) | Contadores seguros; nada más | ~overhead (el repo ya cita 40% con threads); `b[0]=99` sigue raceando | **No** — contradice «thread-safe» |
| C. Unicidad/isolate (Nim) + deep copy de respaldo | «Una fibra a la vez» **estática** para lo que el análisis prueba; copia para el resto | Análisis de flujo + rechazo de programas; closures capturantes son el caso duro | **Parcial** — es la opción más honesta compatible con «sin borrow checker completo» |
| D. Owner-check por acceso en runtime | Siempre correcto (o error en runtime) | Overhead por acceso, instrumentar los 7 backends | Parcial — «thread-safe» se cumple, «sin coste» no |
| E. Sin mutable compartido (estilo Erlang): solo canales/copia | Carreras imposibles por construcción | Pierde el pitch de «fibras que comparten datos» | **No** — pero es la única garantía *barata* |

**Recomendación de este informe:** **C con deep copy de respaldo** (la opción
ya medio nombrada en `ARCHITECTURE.md:31`), escrita así:

> `var` solo puede cruzar fibras si el compilador prueba unicidad en ese punto
> de flujo (incluyendo closures capturantes); si no puede probarlo, el cruce
> es deep copy (o `Atomic[T]` explícito). `transfer` es azúcar sobre esa regla.

Eso es compatible con «sin borrow checker de Rust» (no hay lifetimes ni
préstamos), tiene coste escrito, y **rechaza el programa de la crítica**
(`b` aliasa → o el compiler prueba unicidad, o copia; en ningún caso dos
fibras escriben el mismo arreglo).

---

## 5. Plan de acción priorizado

**P0 — antes de tocar otro backend:**

1. **Escribir el enforcement** de §2.4 en `ARCHITECTURE.md` (elegir de §4,
   con coste). Mientras exista `transfer` en la doc, debe existir la regla que
   lo valida.
2. **Congelar las 4 decisiones de runtime** (ancho de enteros + overflow,
   semántica de `let`/alias, reálculo de memoria → ¿ARC real en el VM?,
   scope de variantes de enums) con **una conformance test por decisión** en
   `seed/tests/`. Los 7 backends pasan a ser sus implementantes.
3. **Corregir `COMPILER_STRATEGY.md` §7.1** (quitar el paso 3 imposible; la
   cadena real es port manual C→Zig) y `:303`.
4. **Desmarcar `README.md:124-125`** o implementar: los `[x]` de «fiber-aware»
   y «green threads, channels, atomics» son falsos hoy.

**P1 — el primer paso del self-hosting:**

5. **Mínimo de Astra-0**: `len`, `push`, índice/iteración de string,
   int→string, lectura de fichero (los que lista la crítica) — entonces
   **lexer mini en Astra** como gate real de self-hosting, no la paridad
   seed↔zig.
6. **Decidir el destino del registro de constructs**: o los hooks dirigen
   algo (empezar por 1 constructo migrado de verdad), o el doc dice
   «índice documental, 0/47 — no es un plan de migración».

**P2 — proceso:**

7. Single source of truth: `transfer`/`Atomic[T]` no pueden existir en dos
   doc y en ningún código; mover el roadmap a «hecho / implementado /
   especificado» de tres estados, no `[x]` binario.
8. Presupuesto de proceso: la proporción commits-de-decisión vs
   commits-de-backend es hoy ~0:31 — invertirlo durante un ciclo.

---

## 6. Reproducción (todos los comandos de §2)

```bash
# build del seed (repo root)
cd seed && make && cd ..
./seed/astra-seed --check-constructs   # -> "migrated (all three phases): 0 / 47"

# §2.8 — las cuatro decisiones abiertas (programas en /tmp/opencode/astra-critica/)
cd /tmp/opencode/astra-critica
S=/home/aster/Astra/seed/astra-seed
$S int_width.astra     # let big: i32 = 9999999999  -> imprime 9999999999
$S alias_mut.astra     # let p/q share               -> imprime 5
$S enum_use.astra      # variantes colisionadas      -> rc=1, errores citados
$S loop_alloc.astra    # 2M arreglos -> maxRSS ~408 MB, jamás libera (mide con
                       #   un bucle de lectura de /proc/$PID/status mientras corre)

# §2.5/§2.6 — ausencias (repo root)
cd /home/aster/Astra
grep -riE "fiber|scheduler|spawn" seed/src zig/src   # -> 0
grep -rn "transfer" seed/src                          # -> 0
grep -rnE '"len"|"push"|"to_string"' seed/src        # -> 0
grep -c "free(" seed/src/vm.c                         # -> 0
$S /tmp/opencode/astra-critica/len_test.astra  # -> "undefined variable 'len'"
$S /tmp/opencode/astra-critica/str_test.astra  # -> "cannot index non-array type string"

# §2.9 — proceso (repo root) — los conteos de línea/informes incluyen ya este 025
find Documentacion -name "*.md" | xargs wc -l | tail -1   # -> 41140 (40693 antes de este informe)
ls Documentacion/07_investigacion/*.md | wc -l            # -> 25  (24 antes de este informe)
git log --oneline | wc -l                                 # -> 234
git log --reverse --format=%ci | head -1                  # -> 2026-09-16
git log --oneline | grep -icE "llvm|parity"               # -> 73
```

**Programas de reproducción** (`/tmp/opencode/astra-critica/`):

```astra
// int_width.astra
fn main() { let big: i32 = 9999999999; print(big); }

// alias_mut.astra
struct P { x: i32 }
fn main() {
    let p = P { x: 1 };
    let mut q = p;
    q.x = 5;
    print(p.x);            // 5
}

// enum_use.astra
enum A { Some2(i32) None2 }
enum B { Some2(i32) None2 }
fn main() {
    let x = Some2(1);      // resuelve a A
    let y = Some2(2);      // tambien A — colision
    print(match x { A.Some2(n) => n, A.None2 => 0 });
    print(match y { B.Some2(n) => n, B.None2 => 0 });  // rc=1
}

// loop_alloc.astra — 2M arreglos de 8 elems, RSS nunca baja
fn make() -> [i32] { return [1, 2, 3, 4, 5, 6, 7, 8]; }
fn main() {
    let mut i = 0; let mut s = 0;
    while i < 2000000 { let a = make(); s = s + a[0]; i = i + 1; }
    print(s);
}
```

---

## 7. Referencias internas

- `research/001` §2.4 (operadores), `research/002` §5.2/§5.4 (alcance Astra-0)
- `Documentacion/01_lenguaje/ARCHITECTURE.md` §2.2–§2.5, `:31`, `:875`
- `Documentacion/01_lenguaje/COMPARATIVE_ANALYSIS.md` §2.2 (Nim), `:131`
- `Documentacion/02_compilador/COMPILER_STRATEGY.md` §7.1, `:64`, `:303`
- `seed/src/constructs/construct.c` (self-check), `seed/src/vm.c` (arena)
- `seed/tests/conformance/arrays/alias_write.astra` (test-pinning de §2.5)
- Crítica externa analizada: recibida 2026-10-27 (texto completo en el hilo
  de trabajo; sus afirmaciones se citan literal en §2)

---

## Verificación externa (2026-10-27)

`websearch` seguía devolviendo HTTP 403 en esta sesión: todo lo siguiente se
comprobó con `webfetch` directo contra fuentes primarias (o con lectura del repo).

| Afirmación del informe | Resultado | Fuente |
|:-----------------------|:----------|:-------|
| §2.4 Go: GC concurrente, pausas <1 ms desde 1.8 | **[verificado]** | go.dev/doc/go1.8 — «usually under 100 microseconds and often as low as 10» |
| §2.4 Swift <6 sin chequeo / Swift 6 con verificación en compile-time | **[verificado]** | swift-evolution SE-0302 («warnings for Swift 5 and earlier», errores en modo 6) + SE-0414 (*Implemented (Swift 6.0)*) |
| §2.4 Nim: `isolate`/`Isolated[T]`, check de ownership limitado | **[verificado]** | nim-lang.org/docs/isolation.html («Isolation is checked at compile time», `=copy` `{.error.}`) y docs/destructors.html |
| §2.4 Pony: refcaps = ownership/aliasing estáticos sin locks | **[verificado]** | tutorial.ponylang.io/reference-capabilities/aliasing/ y /guarantees/ («Pony eliminates the need for locks») |
| §2.4 Rust E0382 / E0499 | **[verificado]** | doc.rust-lang.org/error_codes/{E0382,E0499}.html + rustc 1.99.1 local |
| §2.7 semillas OCaml/C/C++ de Rust/Go/Zig | **[verificado]** | rust-lang/rust árbol 2010 `src/boot/*.ml`; golang/go `src/cmd/dist` en go1.4 (`main.c`/`build.c`); ziglang.org/news/goodbye-cpp |

**Queda [citado]** (2 puntos): (1) «RC atómico protege solo el contador, no los
datos» (§2.3) — sin fuente primaria localizada; (2) la medición original del
«40 % con `--threads:on` en Nim 2.0»: la frase está literal en
`COMPARATIVE_ANALYSIS.md:131`, pero no se halló la medición de Nim que la
origina (ni en su manual, ni en `nim-lang.org/docs/*`). Matiz detectado: §2.4
dice «su propio doc cita el 40 %», lo que en el repo es *nuestro* doc, no el de Nim.
