# 027 — Decisiones de semántica de runtime: enteros, aliasing, memoria y variantes

> **Alcance**: investigación y pruebas sobre las cuatro decisiones de semántica
> de runtime que el informe `025_critica_externa_seguridad_y_proceso.md` §2.8
> deja abiertas (§5, P0.2 pide congelarlas con una conformance test cada una).
> Ningún código de producción ni ninguna test de la suite se modifican en este
> documento. Fecha: 2026-10-27. Todo lo marcado **[verificado]** se ejecutó o se
> leyó en este repo durante la sesión (Debian, seed compilado con `make`, zig
> precompilado en `zig/zig-out/bin/astra-zig` con `-Dllvm`); lo marcado
> **[citado]** es lectura de documentación o razonamiento sobre código sin
> ejecución. Los programas de reproducción están en
> `/tmp/opencode/astra-critica/semantica/` y los comandos en §6.

---

## 0. Resumen ejecutivo

Primero, un dato estructural que cambia el coste de cada decisión: **las
«7 rutas» comparten dos frontends y cuatro runtimes**.

| Ruta | Frontend | Runtime |
|:-----|:---------|:--------|
| seed VM (`./astra-seed f.astra`) | `seed/src/typechecker.c` | `seed/src/vm.c` (arena) |
| C backend (`--emit-c` + gcc) | `seed/src/typechecker.c` | `codegen.c` + `codegen_runtime.h` (malloc vitalicio) |
| zig VM (`astra-zig f.astra`) | `zig/src/typechecker/typechecker.zig` | `zig/src/vm/vm.zig` (arena) |
| LLVM `--emit-obj` (nativo) | `zig/src/typechecker/typechecker.zig` | `astra_runtime_llvm.c` (ARC, M4.e) |
| LLVM `--jit` | ídem | ídem (en proceso) |
| wasm32-wasi | ídem | ídem (wasi-libc) |
| aarch64 cross | ídem | ídem (qemu) |

**[verificado]**: `llvm_parity.sh`, `llvm_jit.sh`, `llvm_cross.sh` y
`llvm_wasm.sh` copian *el mismo* conjunto (`seed/tests/conformance` +
`seed/tests/codegen` + `zig/tests/llvm/*.astra`). Consecuencias:

- Las decisiones **1** (enteros) y **4** (variantes) son decisiones de
  *frontend*: hay **dos** implementadores (`typechecker.c` y
  `typechecker.zig`), no siete — más tres emisores para la decisión 4
  (emitter C, bytecode.zig, llvm/emitter.zig).
- Las decisiones **2** (aliasing) y **3** (memoria) son decisiones de
  *runtime*: hay **cuatro** runtimes cubriendo las siete rutas.

### Las cuatro recomendaciones (una por decisión, con coste)

1. **Anchos de enteros → error de compile-time para literales fuera de rango
   del ancho anotado + envolver (`wrap`) definido y documentado en runtime.**
   Nada de truncar ni saturar; el checked-overflow se difiere a Fase 2.
   **Coste: BAJO** — dos typecheckers (C y Zig) + mensajes de UI
   byte-idénticos (gate `ui_message_parity.sh`) + 2 tests nuevos; **cero
   cambios en los cuatro runtimes**, porque las siete rutas ya coinciden hoy
   en el comportamiento (verificado). Rompe **0 tests** existentes.
2. **`let` vs alias → se mantiende el handle compartido (§2.5) y `let` se
   declara formalmente como «inmutabilidad de *binding*, no del objeto»; la
   copia profunda pasa a ser explícita (`.copy()`, futuro) y la garantía de
   objetos entre fibras la pone el informe 026 (pendiente de escribir).**
   **Coste: BAJO hoy** — 0 líneas de runtime, 1 test de conformidad + 1 UI
   nuevos que congelan el contrato. Las alternativas (valor, copy-on-write,
   freeze) **rompen exactamente 3 fixtures** (`alias_write`,
   `ownership_alias`, `ownership_shared`) y exigen rc o flags en los cuatro
   runtimes.
3. **Liberación de memoria → divergencia explícita y aceptada: arena/vitalicio
   en el seed (C y Zig) y en el C codegen; ARC en las rutas LLVM (ya
   implementado y gateado con LSan).** Se documenta como límite del seed
   (sancionado por `research/002` §5.3) y se añade un **gate de techo de RSS
   por backend**, no una conformance test. **Coste: BAJO** — documentación +
   un script gate; la alternativa «ARC también en los VMs» es **ALTA** (portar
   el checklist M4.e a `vm.c`, `vm.zig` y `codegen_runtime.h`, que hoy tiene
   campos `refcount` vestigiales: se ponen a 1 y nunca se decrementan).
4. **Variantes de enums → construcción calificada obligatoria
   (`A.Some2(1)`), con rechazo de la forma pelona.** Unifica el lenguaje:
   las variantes unitarias ya solo funcionan calificadas, los patrones ya solo
   aceptan `Enum.Variant` (ni siquiera parsean sin calificar), y los nombres
   homónimos entre enums ya funcionan cuando se califican. **Coste: MEDIO** —
   dos typecheckers + tres emisores + reescribir **17 tests seed**, **5
   fixtures LLVM**, **2 tests unitarios de zig** y una línea del generador de
   fuzz; la alternativa «pelón si es inequívoco» cuesta **0 tests** pero deja
   dos ortografías para siempre. El AST no cambia ⇒ el gate de dump parity no
   se entera.

Baseline de la suite antes de cualquier cambio, todo verde [verificado]:

- `cd seed && make test` → **passed: 260, failed: 0**
- `cd zig && zig build -Dllvm && zig build -Dllvm test` → sin errores
- `cd zig && ./tests/llvm_parity.sh` → **total=159 ok=159 skip=0 excl=0
  fail=0** (opt=0)

---

## 1. Ancho de enteros (`i32`/`i64`/`u32`/`u64`)

### 1.1 Comportamiento actual [verificado]

Programa `/tmp/opencode/astra-critica/semantica/int_width.astra` y
`overflow.astra`:

```astra
fn main() {
    let big: i32 = 9999999999; print(big);   // -> 9999999999  (no truncó)
    let u: u32 = -1;                print(u);            // -> -1   (acepta signo)
    let a: i32 = 2147483647; let b = a + 1; print(b);    // -> 2147483648 (sin wrap en i32)
    let s: i64 = 4611686018427387904; let t = s + s; print(t);
                                                  // -> -9223372036854775808 (wrap i64)
}
```

Las **cinco rutas ejecutables en esta caja** imprimen **idéntico**:

| Ruta | Salida |
|:-----|:-------|
| seed VM | `9999999999 / -1 / 2147483648 / -9223372036854775808` [verificado] |
| zig VM | ídem [verificado] |
| LLVM `--jit` | ídem [verificado] |
| C backend `gcc -O0` | ídem [verificado] |
| C backend `gcc -O2` | ídem [verificado] |

(wasm y aarch64 comparten el emisor LLVM → mismas constantes [verificado
parcial: ambos pasan por el único `zig/src/llvm/emitter.zig`, pero ese emisor
tiene ramas por target — `targetIsWasm` (`:824`), datalayout/ABI (`:446,4514,
4592`) —, así que la constante entera es la misma y el layout no]).

Otros datos verificados:

- **No existen sufijos**: `let x = 5i32;` → `error: undefined variable 'i32'`
  (el lexer parte el token en `5` + identificador `i32`) [verificado]. La
  decisión «¿qué hacen los sufijos?» es, hoy, una decisión sobre *anotaciones*,
  no sobre literales.
- **El único rango que se chequea es el de i64**: `let u: u64 =
  18446744073709551615` → `error: integer literal is out of range for i64`
  (lexer, `lexer.c:211-218,251`) [verificado].
- **Anchos disponibles**: `i32/i64/u32/u64` resuelven
  (`typechecker.c:782-784`, `typechecker.zig:485-487`); `i8/i16/u8/u16` están
  en la gramática (`ARCHITECTURE.md:2039`) pero **no resuelven** en ninguno de
  los dos checkers [verificado por lectura].
- **No hay cast**: el token `as` solo se usa en imports (`TOKEN_AS`,
  `lexer.c:33`); `@narrow`/`@intFromFloat` de `ARCHITECTURE.md` §31 no existen
  en el código [verificado].

### 1.2 Qué hace cada backend con `i32` hoy [verificado en el código]

| Capa | Evidencia |
|:-----|:----------|
| Valor del seed VM | `struct Value { … int64_t int_val; … }` — `include/astra/astra.h:1059` |
| C backend (runtime) | `AstraValue.as.int64_t int_val` y `astra_int(int64_t v)` — `codegen_runtime.h:111,224` |
| zig VM | espejo del seed (bytecode sin tipos; `typechecker.zig:921` lo dice literal: «the bytecode emitter ignores static types») |
| LLVM | `llvm/emitter.zig:4339`: `.int, .int64, .uint32, .uint64, .int_literal => .i64_`; constantes en `i64` (`:2201`) |
| LLVM aritmética | `LLVMBuildAdd` **sin `nsw`/`nuw`** (`emitter.zig:2906`) ⇒ wrap de dos complementos *definido*, no UB |
| Typechecker | regla de adopción de literales sin rango (`typechecker.c:59-62`); el default de binding es `i32` (`:1336`) |
| C aritmética | `int64_t` crudo ⇒ UB teórico en overflow firmado (sin `-fwrapv`); en la práctica envuelve en `-O0` y `-O2` — medido, pero **no garantizado** [verificado + citado] |

Es decir: **los anchos son solo chequeo de tipos; el runtime modela un único
entero de 64 bits en las siete rutas.** Lo dice ya la doc:
`PHASE1_PROGRESS.md` §6.3 («Ancho de los enteros no verificado en runtime»)
y `ARCHITECTURE.md:174-180`, que lo deja para Fase 2 (`research/002` §9.2)
[verificado parcial: los dos tramos existen — `ARCHITECTURE.md:174-180` y
`PHASE1_PROGRESS.md:602` (§6.3) —, pero `research/002:641` §9.2 se titula
«C Codegen Backend (Bootstrap Path)» y no menciona la semántica de anchuras].

### 1.3 Opciones y coste por ruta

| Opción | Coste de implementación | ¿Rompe tests? |
|:-------|:------------------------|:---------------|
| **1A. Rango en literales (compile-time)**: `let big: i32 = 9999999999` → error; `u32 = -1` → error | 2 typecheckers (el punto donde el literal adopta un tipo concreto: `typechecker.c:59-62/1336`, `typechecker.zig:845/1523`) + mensaje duplicado byte-idéntico (gate `ui_message_parity.sh`) | **0** — `integer_widths.astra` (conformance + codegen) solo usa valores en rango (i64 max, u32 max) [verificado grep] |
| **1B. Truncar al ancho** (`9999999999` en i32 → `1410065407`) | **ALTA**: el runtime debe saber el ancho en cada operación, pero el bytecode es **sin tipos** (lo consume el VM *y* el C backend desde `codegen.c`) ⇒ exige bytecode con tipos o nuevos opcodes por ancho: `vm.c`, `emitter.c`, `zig emitter`, `codegen.c`, emisor LLVM (ya tipado) | 0 tests hoy, pero cambia salidas de todos los programas con anchos estrechos |
| **1C. Saturar** | Igual que 1B (misma infraestructura) | 0 |
| **1D. Checked overflow en runtime** (trap/error al desbordar) | **MEDIA-ALTA en los 4 runtimes**: guards en `vm.c` (op ADD/SUB/MUL), en `vm.zig`, en `codegen.c` y en el LLVM (hay precedente: el guard de división por cero, M6.b) + **paridad de mensajes de runtime** entre VM y código generado (hoy ya se exige, p. ej. `error_line_in_fn.astra`) | 0 tests (ningún caso de la suite se acerca al rango i64) [verificado por inspección de `integer_widths` y ausencia de literales grandes], pero es cambio de comportamiento en 4 runtimes |
| **1E. Wrap definido documentado + test** | **0** (es el comportamiento de las siete rutas, ya coincidente) | 0 |

**Matiz de 1D**: incluso con checked-overflow a nivel i64, `let a: i32 =
2147483647; a + 1` **no** desborda i64 y seguiría dando `2147483648`: sin
operaciones por ancho (1B) el chequeo no puede ser i32-preciso. Por eso 1D y
1B están atados, y ninguno de los dos es barato.

**Matiz del default**: sin anotación, `let x = 9999999999` tomaría el tipo
por defecto `i32` (`typechecker.c:1336`) — aplicar 1A a ciegas convertiría ese
programa en error. La variante honesta es la de Rust: **si el literal no cabe
en el default `i32`, el default pasa a `i64`; solo la anotación explícita
rechaza.** Coste adicional: una línea en cada checker.

### 1.4 Recomendación

**1A (error de rango en literales anotados, con fallback a `i64` para el
default) + 1E (wrap definido, documentado y fijado por test).** Justificación:

- Es la única opción cuyo coste está confinado a los frontends: los siete
  backends ya coinciden (medido) y el gate de paridad no cambia.
- Truncar/saturar (1B/1C) exige meter tipos en el bytecode — un cambio de
  formato que arrastra a `emitter.c`, `vm.c`, `zig emitter` y `codegen.c`
  — para un resultado que hoy ningún test pide.
- Checked (1D) es deseable a largo plazo (coherente con el error en runtime
  de la división por cero), pero debe venir con las operaciones por ancho de
  Fase 2 o quedará a medias (ver matiz). Debe ser un flag (`--overflow=check`)
  para que los gates de paridad, que comparan salidas, sigan deterministas.
- El wrap silencioso **queda documentado como comportamiento definido**, no
  como accidente: es lo que ya hacen las cinco rutas ejecutadas y lo que
  fija el test de abajo; así la crítica deja de poder decir «cada backend
  decidirá lo suyo».

### 1.5 Tests de conformidad propuestos

```astra
// seed/tests/conformance/ui/int_literal_range.astra  (nuevo; UI)
// Literal fuera del rango del ancho anotado es error de compilación.
// EXPECT-ERROR: literal 9999999999 out of range for i32
fn main() {
    let big: i32 = 9999999999;
    print(big);
}
```

```astra
// seed/tests/conformance/types/int_width_semantics.astra  (nuevo)
// Anchos = chequeo de tipos; el runtime es i64 con wrap definido (§1).
// EXPECT: 4294967295
// EXPECT: -9223372036854775808
// EXPECT: 2147483648
fn main() {
    let u: u32 = 4294967295;      // en rango: compila
    print(u);
    let s: i64 = 4611686018427387904;
    print(s + s);                 // wrap de i64 definido (dos complementos)
    let a: i32 = 2147483647;
    print(a + 1);                 // la aritmética corre en i64: no trunca a i32
}
```

(El segundo EXPECT documenta *explícitamente* la limitación: sin operaciones
por ancho, `i32 + i32` no envuelve a 32 bits — si en Fase 2 eso cambia, este
test cambia *con* la decisión, que es justo el objetivo.)

---

## 2. `let` vs alias (semántica de agregados)

### 2.1 Comportamiento actual [verificado]

```astra
struct P { x: i32 }
fn main() {
    let p = P { x: 1 };   // binding INMUTABLE
    let mut q = p;        // alias mutable
    q.x = 5;
    print(p.x);           // -> 5
}
```

- Imprime `5` en **seed VM, zig VM y LLVM `--jit`** [verificado].
- Escribir *directamente* a través del `let` sí está prohibido:
  `p.x = 5` → `error: cannot assign through immutable variable 'p'` [verificado].
- Compartir también atraviesa closures: `let mut p = …; let bump = |d| { p.x =
  p.x + d; … }; bump(4); print(p.x)` → `5` y `5` [verificado] — el capture
  «por valor» copia el *handle*, no el agregado (amplifica el aliasing, como
  dice 025 §2.1).
- `alias_write.astra` (§2.5) → `99/99` en seed VM, zig VM y LLVM `--jit`
  [verificado]; corre además en `make test`, `zig build test`, `llvm_parity`,
  `llvm_jit`, `llvm_cross`, `llvm_wasm`, `llvm_sanitize` (los gates LLVM
  copian toda la conformance).
- La semántica está **decidida y escrita**: `ARCHITECTURE.md` §2.5 («`let b =
  a` comparte el handle; no copia los elementos», decisión 2026-09-21, con
  tres razones: coherencia con ARC/ORC, inmutabilidad observable, y que el seed
  no tiene refcounting) [verificado: `ARCHITECTURE.md:61-86`, §2.5 «decisión
  del 2026-09-21», con el cita textual «`let b = a` comparte el handle; no copia
  los elementos» y las tres razones (la tercera: «El seed no tiene refcounting»)].
- **El informe 026 (enforcement de fibras) no existe todavía**: glob sobre
  `Documentacion/**/026*` → 0 ficheros; `07_investigacion/` llega hasta 025
  [verificado]. Toda interacción con «una fibra a una vez» queda, por tanto,
  *pendiente de 026* (que es el P0.1 de 025).

### 2.2 Opciones, coste y tests que pinchan

Hay cuatro opciones serias. **Tres de ellas rompen exactamente los mismos
tres fixtures**, porque los tres fijan «la escritura a través de un alias se ve
en el otro»:

| # | Opción | Tests que rompen (hay que reescribir sus EXPECT) |
|:--|:-------|:--------------------------------------------------|
| **A** | Semántica de valor (copia profunda al asignar/pasar) | `seed/tests/conformance/arrays/alias_write.astra` (99→1); `zig/tests/llvm/ownership_alias.astra` (`b[1]=…` deja de verse en `a`, `bx.s=…` deja de verse en `bx2`); `zig/tests/llvm/ownership_shared.astra` («mutar a través de un alias hecho con `let mut`» deja de verse en `s`) [citado: leídos los EXPECTs] |
| **B** | Referencia + `let mut` con copy-on-write | **Los mismos tres** (COW rompe la visibilidad: `alias_write` daría `1`; `ownership_*` darían copias) [razonamiento sobre los EXPECTs leídos] |
| **C** | Freeze: el objeto vinculado con `let` queda inmutable para todos | **Los mismos tres, pero como errores**: en `alias_write` no hay `let` (todo `let mut`) y pasa; pero `ownership_alias` hace `let a = […]` y luego escribe vía `b` → error; `ownership_shared` hace `let s_alias = s` y luego muta vía `inner` → error. Además `let c = a; a[0] = 9` (con `a: let mut`) pasaría a fallar por culpa de `c` — sorpresa difícil de explicar |
| **D** | **Contrato**: compartir se mantiene; `let` = inmutabilidad de *binding*; snapshot explícito con `.copy()` (futuro) | **0 tests** [verificado: baseline `make test` 260/0 verde con el comportamiento actual] |

Coste de implementación por opción (cuatro runtimes + tres emisores, ver
tabla de §0):

- **A (valor)**: rotinas de *clone* profundo en `vm.c`, `vm.zig`,
  `codegen_runtime.h` y el runtime LLVM (donde hoy hay `rcRef`, no clone) +
  un punto de copia en los tres emisores (SET_LOCAL, paso de parámetro,
  return). Riesgo adicional: ciclos `closure env → closure` (M4.e ya los
  nombra) hacen el clone profundo recursivo sin análisis de unicidad; hoy el
  modelo ARC los tolera, el deep copy no. **Coste ALTO.**
- **B (COW)**: sin rc en seed/zig/C no hay «cuándo copiar»: hay que añadir
  un flag/contador por objeto en los cuatro runtimes y marcarlo en cada
  creación de alias en los tres emisores. **Coste ALTO** (y es semántica
  *observable*: `99` pasa a `1`, así que los fixtures se reescriben igual).
- **C (freeze)**: bit de congelado en `ArrayObj/StructObj/EnumObj` (seed),
  en los objetos del VM Zig, en `AstraArray/AstraStruct` (C) y en el header
  `{rc,kind}` (LLVM) + chequeo en cada `SET_FIELD`/`SET_INDEX` de los cuatro
  runtimes + decisión de *dónde* se congela (¿`let` de declaración sí, ¿parámetros
  no, ¿patrones?, ¿globales?) — la regla se prolifera rápidamente. **Coste
  MEDIO-ALTO y regla frágil.**
- **D (contrato)**: **0 líneas de runtime**. Coste real: escribirlo en
  `ARCHITECTURE.md` §2.5 (ya casi está escrito; le falta la frase «`let`
  protege el binding, no el objeto»), añadir `.copy()` cuando haya stdlib, y
  dejar constancia de que la garantía de objeto entre fibras depende de 026.

### 2.3 Recomendación

**Opción D: congelar el estado actual como contrato, no como descuido.**

Justificación:

1. **Es la única opción que no miente en dos sitios a la vez.** A y B rompen
   §2.5 (decisión escrita con tres razones) y los tres fixtures de aliasing;
   C convierte en error de runtime programas que hoy funcionan y que los
   fixtures LLVM dan por buenos. D deja *un solo* texto que contar: «compartimos
   handles con contabilidad (ARC en Fase 2); `let` impide escribir *a través del
   binding*; si necesitas una foto, copia (`.copy()`); si necesitas cruzar
   fibras, la regla es la de 026».
2. **El bug de la crítica no es un bug de runtime, es una promesa no
   escrita.** La repro (`p.x` cambia vía `q`) es exactamente el comportamiento
   que `ownership_shared.astra` *deliberadamente* verifica en el backend LLVM
   («mutar el objeto a través de un alias hecho con `let mut`»). Cambiarlo
   ahora significaría que el seed y el backend LLVM tuvieron, durante semanas,
   dos verdades distintas sobre el mismo programa.
3. **La salida de seguridad no es esta decisión, es 026.** 025 §4 recomienda
   unicidad/isolate + deep copy en la frontera de fibra. Con `let` como
   contrato *shallow*, 026 puede añadir después un análisis de unicidad
   barato («este `let` es único ⇒ snapshot gratis») sin reescribir runtimes;
   congelar ahora la opción A/B/C compraría un freeze/COW que 026 podría
   volver obsoleto.
4. **`.copy()` es el parche honesto y barato** para el usuario sorprendido:
   un builtin/método con copia profunda (el VM ya tiene rutinas de clonación
   internas para constantes; el LLVM puede reutilizar el path de clone), en
   lugar de cambiar la semántica de asignación de todo el lenguaje.

### 2.4 Tests de conformidad propuestos

```astra
// seed/tests/conformance/arrays/alias_let_visibility.astra  (nuevo)
// Contrato de aliasing (decisión 027 §2): `let` protege el BINDING, no el
// objeto; escribir vía un alias `let mut` es visible en todos los bindings.
// EXPECT: 5
// EXPECT: 5
struct P { x: i32 }
fn main() {
    let p = P { x: 1 };        // binding inmutable
    let mut q = p;             // alias mutable del MISMO objeto
    q.x = 5;
    print(p.x);                // 5: el objeto es compartido (§2.5)
    print(q.x);                // 5
}
```

```astra
// seed/tests/conformance/ui/immutable_field_assign.astra  (nuevo; UI)
// La otra mitad del contrato: a través del binding `let` no se escribe nunca.
// EXPECT-ERROR: cannot assign through immutable variable 'p'
struct P { x: i32 }
fn main() {
    let p = P { x: 1 };
    p.x = 5;
    print(p.x);
}
```

(Con esto, el contrato queda fijado por *tres* tests: `alias_write` para
`let mut`↔`let mut`, este nuevo para `let`↔`let mut`, y el UI para escritura
directa. Cualquier futuro cambio a semántica de valor tendría que romper tres
puertas a la vez, que es lo que significa «decisión congelada».)

---

## 3. Liberación de memoria

### 3.1 Comportamiento actual [verificado con medición]

Programa `loop_alloc.astra` (2 M arreglos de 8 elementos):

| Ruta | maxRSS (VmHWM) | Mecanismo |
|:-----|:---------------|:----------|
| seed VM | 1 M → **201 476 KB**, 2 M → **404 764 KB** (lineal) | arena: `arena_new*` en todo `vm.c`; `grep -c "free(" vm.c` → **0**, `grep -c malloc` → **0**; `vm_destroy` es no-op (`(void)vm`); `arena_destroy` solo se llama al final del proceso (`driver.c:620,626,793`) |
| zig VM | 2 M → **721 916 KB** | arena de programa (`main.zig:181-182` `defer arena.deinit()`) |
| C backend | 2 M → **489 220 KB** | `malloc` en `codegen_runtime.h` y **ningún `free`** (el único es un buffer temporal, línea 481); los campos `refcount` de `AstraString/AstraArray` se ponen a 1 y **nunca se decrementan** (grep: solo `:244,:260`) |
| LLVM `--jit` | 1 M → **76 764 KB**, 2 M → **76 896 KB**, 4 M → **76 924 KB** (acotado) | ARC real: header `{int32_t rc; int32_t kind;}` en `astra_runtime_llvm.c:43`, `retain/release` en `:70-86`; libera todo salvo ciclos (M4.e) |

La divergencia **ya existe hoy** y es enorme: ~77 MB acotados frente a
200-700 MB lineales. Los gates de salida no la detectan porque comparan
stdout/rc, no memoria. El backend LLVM tiene además su propio gate de fugas:
`llvm_sanitize.sh` paso 5 ejecuta `leaks.astra` con `detect_leaks=1` y falla
si LSan reporta algo [verificado leyendo el script].

Marco documental: `research/002` §5.3 lista «ARC/ORC runtime» como algo que
el seed **no necesita**; §2.5 de ARCHITECTURE dice «el seed no tiene
refcounting —está explícitamente fuera de su alcance» [verificado:
`research/002:235` §5.3 «What the Seed Compiler Does NOT Need» con `:239`
«- [ ] ARC/ORC runtime», y `ARCHITECTURE.md:82` con el texto literal].

### 3.2 Opciones y coste

| Opción | Coste | Comentario |
|:-------|:------|:-----------|
| **3A. Documentar la divergencia + gate de RSS por backend** | **BAJO**: texto en `PHASE1_PROGRESS`/`ARCHITECTURE` + un `zig/tests/llvm_mem.sh` (o un paso más en `llvm_parity.sh`) que fije un techo de RSS para el bucle de 2 M (~80 MB medidos ⇒ techo holgado de 128 MB) | Respeta `research/002` §5.3; la paridad de salidas no se toca |
| **3B. ARC también en los VMs (seed, zig) y en el C codegen** | **ALTO**: portar el checklist de M4.e (retain en store/return/param, release en frame/call-temp/global) a `vm.c`, `vm.zig` y `codegen_runtime.h` (que ya tiene los campos, sin usar); mantener paridad de salidas; cuidado con ciclos (closure→array→closure) que el ARC de M4.e *no* resuelve y ORC (§2.3) tampoco existe aún | Acaba con la divergencia, pero es el trabajo de Fase 2 que la doc ya tiene asignado |
| **3C. Arena con reset por frame/statement** | **INSEGURA hoy**: los `Value` de la arena se cuelgan de locals del stack VM, de globales (`toplevel_aggregates.astra` guarda agregados en globales), del `env` de los closures (`astra.h:1051`, arena-allocated) y de campos de structs; un reset liberaría objetos vivos ⇒ use-after-free. Solo sería válida con análisis de escape o con rc | No recomendable ni siquiera como atajo |

**¿Divergencia aceptable o debe liberar también el seed?**
Aceptable, y ya está *casi* escrita: el seed es una herramienta temporal de
bootstrap con presupuesto de memoria de una campaña de fuzzing
(`-rss_limit_mb=512`, `AGENTS.md`), no un runtime de producción; la ruta
«productiva» (LLVM) **ya libera y ya está gateada con LSan**. Lo que falta no
es código, es decirlo: hoy un lector de `ARCHITECTURE.md` §2.1/§2.2 cree que
todo libera. La única consecuencia operativa que conviene fijar es **el techo
de RSS** para que el «no libera» no se convierta en una regresión silenciosa
en las rutas que sí liberan.

### 3.3 Test propuesto

La memoria no es observable por stdout, así que la decisión se fija en dos
piezas:

```astra
// seed/tests/conformance/memory/loop_reuse.astra  (nuevo)
// Asignación sostenida sin observar diferencias: los resultados no dependen
// de cuándo se reclame la memoria (pasa en arena y en ARC por igual).
// Bajo `make debug` (ASan/LSan) y bajo llvm_sanitize.sh debe pasar sin fugas.
// EXPECT: 2000000
// EXPECT: 8
fn make() -> [i32] { return [1, 2, 3, 4, 5, 6, 7, 8]; }
fn main() {
    let mut i = 0;
    let mut s = 0;
    while i < 2000000 { let a = make(); s = s + a[0]; i = i + 1; }
    print(s);      // 2000000
    let last = make();
    print(last[7]); // 8 — el valor sobrevive a su scope mientras se referencia
}
```

+ el **gate de memoria** (no conformance): `zig/tests/llvm_mem.sh` que ejecute
ese bucle por la ruta LLVM y fije `maxRSS < 128 MB` (medido: 77 MB), y que
corra el mismo programa en el seed con un techo *documentado* como «arena:
lineal, sin límite» — es decir, el gate mide lo que cada modelo promete.

---

## 4. Scope de variantes de enums

### 4.1 Comportamiento actual [verificado]

Reproducción (`enum_use.astra`, §2.8 de 025):

```
enum A { Some2(i32) None2 }
enum B { Some2(i32) None2 }
let x = Some2(1);   // resuelve a A (primer enum en registrar gana)
let y = Some2(2);   // también A — colisión
match y { B.Some2(n) => … }  // rc=1: "pattern type enum does not match
                             // match target type enum" + "non-exhaustive:
                             // missing variant 'A.Some2'" (6 errores)
```

Ejecutado en **seed VM y zig VM: mismos 6 errores, byte idénticos**
[verificado] (el port Zig replica el mismo registro plano). Con `--jit`
(LM route) el fallo es el mismo, porque el frontend es el zig
[verificado].

El detalle adicional de 025 §2.8, confirmado y ampliado:

| Forma | ¿Funciona hoy? | Evidencia |
|:------|:---------------|:----------|
| `let v = Some2(1)` (pelón, con payload) | Sí, pero **colisiona** entre enums | registro plano, primer gana: `typechecker.c:294-417` (comentario: «this flat registry is the checker's view»), lookup en `:1617` |
| `let a = A.Some2(1)` (calificado, con payload) | **No**: `error: cannot call non-function type enum` | `typecheck_call` solo resuelve variantes en `NODE_IDENT` (`:1616`); el `NODE_FIELD_ACCESS` cae al chequeo de método y luego a `:1693-1696` |
| `let x = Red` (unitario, pelón) | **No**: `undefined variable 'Red'` | [verificado] |
| `let a = A.Red` (unitario, calificado) | Sí | `typecheck_field_access:1900-1919` («`Enum.Variant` is a value of the enum's type») |
| Homónimos unitarios `A.Red`/`B.Red` | **Sí, ambos**: imprime `1` y `1` | [verificado] — el namespace calificado ya funciona para unitarios |
| Patrón pelón `Rgb(r,g,b) =>` | **Ni parsea**: `expected '=>'` | [verificado] — los patrones ya exigen `Enum.Variant` |
| `A.Some2` como valor sin llamar | Sí (imprime `A.Some2`) — **sin chequeo de aridad** | [verificado]; `typecheck_field_access` no mira payloads |

El emisor LLVM lo confirma en su propio código: «Dónde vive un nombre de
variante (para el constructor pelón `Circle(x)`: … guardamos **solo la
primera aparición**)» (`zig/src/llvm/emitter.zig:164-166`, mapa en `:509-510`);
el emisor C tiene su propio mapa plano (`emitter.c:584-658`) y el bytecode
zig también (`emitter.zig:742-828`) [verificado: `zig/src/emitter/emitter.zig:
742-828` contiene `findEnumByVariant` (`:743`), el registro de `enums` y la
llena de `variant_index` (`:835,887`)].

**Conclusión de diagnóstico**: el bug no es «falta namespace», es que el
lenguaje tiene **tres ortografías distintas según la forma de la variante**
(unitario ⇒ calificado; payload ⇒ pelón; patrón ⇒ calificado y obligatorio),
y la única combinación que *no* colisiona es justo la que el parser exige en
los patrones.

### 4.2 Opciones, coste y tests que pinchan

| Opción | Coste | Tests rotos hoy |
|:-------|:------|:----------------|
| **4A. Construcción calificada obligatoria** (`A.Some2(1)`), rechazo de la pelona | 2 typecheckers (rama `NODE_FIELD_ACCESS` en `typecheck_call` antes del chequeo de método: aridad + tipos de payload + retorno = tipo enum; borrar la rama pelona de usuario, **manteniendo el registro para los builtins `some/ok/err/none`** que pasan por ahí) + 3 emisores (C `emitter.c`, zig `bytecode.zig`, `llvm/emitter.zig`, que ya tienen resolución de `Enum.Variant` para unitarios y patrones) + mensajes UI idénticos seed↔zig | **17 tests seed** + **5 fixtures LLVM** + **2 tests unitarios zig** + 1 generador (lista abajo) |
| **4B. Pelón si es inequívoco; calificado obligatorio solo si hay colisión** | 4A *sin* borrar la rama pelona + detección de ambigüedad en el typechecker (el emisor ya no importa: solo corre tras un typecheck limpio) | **0 tests** — todos los ficheros multi-enum del suite tienen variantes disjuntas (`toplevel_aggregates`: Color/Tag; `forward_type_refs`: Accion/Color) [verificado] |
| **4C. Status quo (primer enum en ganar)** | 0 | 0, pero el bug sigue vivo |

**Lista exacta de lo que rompe 4A** [verificado con grep sobre
`(^|[^.:a-zA-Z_"'])[A-Z]\w*\(`]:

- *seed conformance* (12): `blocks/tail_compound_multiline.astra`,
  `enums/match_binding_reclaim.astra`, `enums/match_guard_payload_stub.astra`,
  `enums/mixed_patterns.astra`, `enums/nested_pattern_bind.astra`,
  `enums/pattern_bind.astra`, `expressions/aggregate_equality.astra`,
  `expressions/match_inline_call.astra`, `loops/iter_height_norm.astra`,
  `module/toplevel_aggregates.astra`, `types/forward_type_refs.astra`,
  `ui/pattern_bind_wrong_type.astra` (hay que calificarlo para que siga
  llegando a su error real: su EXPECT-ERROR no cambia).
- *seed codegen* (5): `aggregate_equality.astra`, `enum_payload_print.astra`,
  `loop_iter_height.astra`, `match_guard_payload_stub.astra`,
  `toplevel_aggregates.astra`.
- *fixtures LLVM* (5): `zig/tests/llvm/check_match.astra`,
  `leaks.astra`, `ownership_alias.astra`, `ownership_containers.astra`,
  `ownership_shared.astra`.
- *tests unitarios de zig* (2): `zig/src/emitter/emitter.zig:2557-2562`
  (`First(1)`) y `zig/src/llvm/emitter.zig:4909-4913` (`Verde(7)` — además
  afirma `error_count == 0`).
- *generador* (1): `zig/tests/llvm_fuzz_gen.py:182` emite `Num(…)` pelón (la
  línea 187 ya escribe `Kind.Num(v)` en patrones).
- **No afecta**: `zig/src/parser/parser.zig:1584` (test solo-parseo) ni
  `generics/inert.astra` (el `Some(T)` detectado es la *declaración*, no una
  construcción — el fichero no construye nada).
- **No afecta a dump parity**: el AST de `A.Some2(1)` ya existe (es un
  `NODE_CALL` con `NODE_FIELD_ACCESS`); no cambia ni `--dump-tokens` ni
  `--dump-ast` [razonamiento citado sobre el pipeline].

### 4.3 Recomendación

**4A: construcción calificada obligatoria.** Justificación:

1. **Es la única opción que deja *una* ortografía.** Hoy el usuario aprende
   tres reglas y una de ellas (payload ⇒ pelón) es exactamente la que produce
   el bug. 4B conserva las dos y añade una tercera («pelón solo si no hay
   colisión»), que además deja de funcionar en cuanto otro fichero importa un
   segundo enum — con el sistema de módulos de Fase 2 (`use` re-exports) la
   ambigüedad se vuelve dependiente del conjunto de imports, que es el peor
   lugar para una regla de resolución.
2. **Ya está medio hecho**: unitarios, patrones y homónimos calificados
   funcionan (verificado); solo falta la forma *llamada* calificada, que es
   la pieza que hoy da «cannot call non-function type enum».
3. **Es más código muerto que código nuevo**: al rechazar la forma pelona de
   usuario se pueden retirar los mapas planos de variante de los tres
   emisores y el registro de usuario del typechecker (quedan los builtins),
   es decir, se *elimina* el estado que causó el bug en tres sitios.
4. **El coste de test es mecánico** (prefijo `Enum.` en 17+5+2 ficheros) y
   se hace una vez; el coste de 4B es mantener dos formas para siempre.

Riesgo de 4A a escribir en el PR: el mensaje de rechazo de la forma pelona
debe ser idéntico en los dos compiladores (gate `ui_message_parity.sh`
exige primera línea byte-idéntica [citado del script]).

### 4.4 Tests de conformidad propuestos

```astra
// seed/tests/conformance/enums/qualified_construction.astra  (nuevo)
// Variantes con payload se construyen SOLO como Enum.Variant (decisión 027 §4):
// el namespace por enum es obligatorio y los homónimos no colisionan.
// EXPECT: 1
// EXPECT: 2
// EXPECT: 3
enum A { Some2(i32) None2 }
enum B { Some2(i32) None2 }
fn main() {
    let a = A.Some2(1);
    let b = B.Some2(2);
    print(match a { A.Some2(n) => n, A.None2 => 0 });   // 1
    print(match b { B.Some2(n) => n, B.None2 => 0 });   // 2
    let c = A.None2;
    print(match c { A.Some2(n) => n + 2, A.None2 => 3 }); // 3
}
```

```astra
// seed/tests/conformance/ui/enum_bare_construction_rejected.astra  (nuevo; UI)
// La forma pelona se rechaza con una pista hacia la calificada.
// EXPECT-ERROR: use Enum.Variant to construct 'Some2'
enum A { Some2(i32) None2 }
fn main() {
    let x = Some2(1);
    print(x);
}
```

---

## 5. Orden de implementación e interdependencias

**Previo (no es una de las cuatro, pero las condiciona): escribir el informe
026** (enforcement de §2.4, P0.1 de 025). Hoy no existe [verificado] y la
decisión 2 lo nombra como su salida de seguridad; sin 026, la decisión 2 solo
puede congelar el contrato *dentro* de una fibra.

Orden sugerido:

1. **Decisión 1 (enteros)** — primero por barata y por independiente:
   solo dos typecheckers, 0 runtimes, 0 tests rotos. Cierra además la
   puerta a que cada backend invente un truncamiento.
2. **Decisión 4 (variantes)** — segundo, porque es frontend puro pero toca
   *fixtures que también son gates de la decisión 3* (`leaks.astra`,
   `ownership_*`): reescribirlos una sola vez, con el prefijo `Enum.`,
   antes de que esos fixtures cambien de propósito por el trabajo de memoria.
3. **026 (escrito)** — paralelo a 1-2: es documentación de enforcement, no
   depende de ellas.
4. **Decisión 2 (aliasing)** — después de 026: si 026 elige
   unicidad/deep-copy en la frontera, se puede *añadir* después un
   «`let` único ⇒ snapshot» barato sobre el contrato D; si se hiciera antes
   congelando A/B/C, 026 podría volver obsoleta esa elección.
5. **Decisión 3 (memoria)** — la parte de documentación y el gate de RSS
   pueden ir en cualquier momento (idealmente junto al paso 2 por los
   fixtures); la parte «ARC también en los VMs» solo si se decide que el seed
   debe liberar, y en ese caso va **junto con la decisión 2**, porque ambas
   necesitan el mismo rc en los cuatro runtimes.

Interdependencias explícitas:

- **2 ↔ 3**: cualquier opción de las decisiones 2 que cambie el reparto de
  referencias (valor, COW, freeze, ARC en el seed) exige rc/flags en los
  cuatro runtimes; la opción recomendada (D) no toca memoria en absoluto.
- **2 ↔ 026**: la garantía de «una fibra a la vez» es la contraparte de
  seguridad del aliasing; sin 026, D solo es medio contrato.
- **4 ↔ 3 (gates)**: los fixtures que 4A reescribe son los mismos que
  `llvm_sanitize.sh` usa como gate de fugas.
- **1 ↔ todos**: no interactúa con nada (frontend puro), salvo si más tarde
  se añade checked-overflow (1D), que sí tocaría los cuatro runtimes.
- **Paridad**: decisiones 1 y 4 exigen mensajes seed↔zig idénticos
  (`ui_message_parity.sh`); la decisión 4 no toca dumps (`dump_parity.sh`);
  ninguna de las cuatro debe tocar los EXPECT de `alias_write` salvo que se
  rechace explícitamente la opción D.

---

## 6. Reproducción (todos los comandos ejecutados)

```bash
# baseline (verde antes de cualquier cambio)
cd seed && make test                 # -> passed: 260  failed: 0
cd ../zig && zig build -Dllvm && zig build -Dllvm test   # -> sin errores
./tests/llvm_parity.sh               # -> total=159 ok=159 skip=0 excl=0 fail=0

cd /tmp/opencode/astra-critica/semantica
S=/home/aster/Astra/seed/astra-seed
Z=/home/aster/Astra/zig/zig-out/bin/astra-zig

# Decisión 1
$S int_width.astra        # 9999999999 / -1 / 2147483648 / -9223372036854775808
$Z overflow.astra         # idéntico (zig VM)
$Z --jit overflow.astra   # idéntico (LLVM)
$S --emit-c overflow.astra && gcc -Wall -Wextra -I$S/../src -o o0 overflow.c -lm && ./o0
gcc -O2 ... && ./o2                     # idéntico en -O0 y -O2
echo 'fn main() { let x = 5i32; print(x); }' > suffix.astra && $S suffix.astra
        # -> error: undefined variable 'i32'  (no hay sufijos)
echo 'fn main() { let u: u64 = 18446744073709551615; print(u); }' > u64max.astra
$S u64max.astra           # -> error: integer literal is out of range for i64

# Decisión 2
$S alias_struct.astra     # -> 5     (seed VM)
$Z alias_struct.astra     # -> 5     (zig VM)
$Z --jit alias_struct.astra           # -> 5     (LLVM)
$S alias_direct.astra     # -> error: cannot assign through immutable variable 'p'
$S closure_alias.astra    # -> 5 / 5 (el closure comparte el handle)
$S /home/aster/Astra/seed/tests/conformance/arrays/alias_write.astra  # 99/99
$Z /home/aster/Astra/seed/tests/conformance/arrays/alias_write.astra
$Z --jit /home/aster/Astra/seed/tests/conformance/arrays/alias_write.astra   # 99/99 en ambos

# Decisión 3 (VmHWM leído de /proc/PID/status mientras corre)
$S loop_alloc.astra                     # 2M -> 404764 KB  (1M -> 201476 KB)
$Z loop_alloc.astra                     # 2M -> 721916 KB
$S --emit-c loop_alloc.astra && gcc -I.../seed/src -o loop_c loop_alloc.c -lm
./loop_c                                # 2M -> 489220 KB
$Z --jit loop_alloc.astra               # 2M ->  76896 KB
$Z --jit loop_1000000.astra             # 1M ->  76764 KB
$Z --jit loop_4000000.astra             # 4M ->  76924 KB   (acotado: ARC libera)
grep -c 'free(' seed/src/vm.c          # -> 0
grep -c 'malloc' seed/src/vm.c          # -> 0
grep -n 'refcount' seed/src/codegen_runtime.h   # solo inicializaciones (=1)

# Decisión 4
$S enum_use.astra          # rc=1, 6 errores (colisión, primer enum gana)
$Z enum_use.astra          # rc=1, mismos 6 errores byte a byte
$S enum_qualified.astra    # rc=1, "cannot call non-function type enum" (×2)
$Z enum_qualified.astra ; $Z --jit enum_qualified.astra   # mismos errores
$S enum_forms.astra        # "undefined variable 'Red'" (unitario pelón no existe)
$S enum_val.astra          # A.Some2 como valor: compila (sin aridad check)
$S enum_unit_col.astra     # A.Red / B.Red homónimos -> 1 / 1 (calificado ya funciona)
$S bare_pattern.astra      # patron pelón -> parse error ("expected '=>'")

# estructura / gates
grep -rn "findVariant" zig/src/typechecker/typechecker.zig   # :281-286 espejo del seed
grep -n "i64_" zig/src/llvm/emitter.zig                      # :4339 todos los enteros -> i64
ls Documentacion/**/026*      # -> 0 ficheros (el informe 026 no existe)
```

## 7. Referencias internas

- `Documentacion/07_investigacion/025_…` §2.8 (las cuatro reproducciones),
  §4 (espacio de decisión), §5 P0.2 («congelar con una conformance test»)
- `Documentacion/01_lenguaje/ARCHITECTURE.md` §2.5 (agregados, decisión
  2026-09-21), §5.1:161-180 (literales polimórficos + limitación de ancho),
  §11.2 (ejemplos de match desincronizados con el parser actual), §30.2/§30.5
- `Documentacion/07_investigacion/002_seed_compiler_design.md` §5.2 (Tier 1
  de enteros), §5.3 (ARC/ORC fuera del alcance del seed), §9.2 (C codegen)
- `Documentacion/03_fase1_seed/PHASE1_PROGRESS.md` §6.3 (ancho no verificado)
- `seed/src/typechecker.c:48-126` (type_eq/nombres), `:294-417` (registro
  plano de variantes), `:1609-1723` (typecheck_call), `:1896-1947`
  (Enum.Variant), `:2072-2255` (patrones)
- `seed/include/astra/astra.h:1055-1076` (Value: `int64_t int_val`),
  `seed/src/codegen_runtime.h:111,187,195` (int64_t + refcount vestigial)
- `zig/src/typechecker/typechecker.zig:281-286,485-487,1058` (espejo zig),
  `zig/src/llvm/emitter.zig:164-166,4339` (mapa de variantes, enteros→i64)
- `zig/tests/llvm/ownership_alias.astra`, `ownership_shared.astra`,
  `leaks.astra` (fijan aliasing y no-fugas en las rutas LLVM)
- `zig/tests/llvm_parity.sh`, `llvm_sanitize.sh` (conjunto de casos y gate LSan)
- `AGENTS.md` (estructura, gates, M4.e reference counting)

---

## Verificación externa (2026-10-27)

Este informe no apelaba a la web sino a lectura pendiente de docs/código del
repo; aquí «fuente primaria» = el propio repo (se comprobó con `grep`/`sed`,
sin tocar código).

| Marcador | Resultado |
|:---------|:----------|
| `:115` «wasm y aarch64 comparten el emisor LLVM → mismas constantes» | **[verificado parcial]**: los dos pasan por el único `zig/src/llvm/emitter.zig`, pero el emisor ramifica por target (`targetIsWasm:824`, datalayout/ABI `:446,4514,4592`) ⇒ la constante entera es la misma, el layout de wasm32 no |
| `:150` `ARCHITECTURE.md:174-180` + `PHASE1_PROGRESS.md` §6.3 + `research/002` §9.2 | **[verificado parcial]**: los dos primeros existen (`:602`); **matiz**: `research/002:641` §9.2 es «C Codegen Backend (Bootstrap Path)» y no menciona semántica de anchuras, así que el puntero que ambas docs hacen a §9.2 es impreciso |
| `:254` `ARCHITECTURE.md` §2.5 «decisión del 2026-09-21» + `let b = a` + 3 razones | **[verificado]** (`ARCHITECTURE.md:61-86`, cita textual incluida) |
| `:385` `research/002` §5.3 «ARC/ORC runtime» + «el seed no tiene refcounting» | **[verificado]** (`research/002:235` y `:239`; `ARCHITECTURE.md:82` textual) |
| `:472` mapa de variantes del bytecode zig (`emitter.zig:742-828`) | **[verificado]** (`zig/src/emitter/emitter.zig:742-828`: `findEnumByVariant`, `enums`, `variant_index`) |

No se tocó ningún otro marcador; el `[verificado + citado]` de `:144` (UB
teórico de overflow en el C backend) queda tal cual: medido, no garantizado.
