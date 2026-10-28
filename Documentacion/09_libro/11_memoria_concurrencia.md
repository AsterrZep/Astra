# Capítulo 11 — Memoria y concurrencia: el modelo honesto

Este es el capítulo más importante del libro si vas a sacar Astra de un
script. Aquí no hay promesas de marketing: hay **dos modelos de memoria
conviviendo hoy en el mismo lenguaje**, un modelo de concurrencia que está
**especificado pero no implementado**, y una lista corta de lo que el libro
—y el proyecto— **no dice nunca sin la coletilla adecuada**.

Todo lo que sigue está verificado hoy en el código y fijado por decisiones
(`DEC-009`, `DEC-012`) con sus gates.

## Dónde libera memoria hoy

Astra-0 no tiene *un* modelo de memoria: tiene **el que le toque a la ruta
que ejecutas**.

| Ruta | Motor de memoria | ¿Libera durante la ejecución? | Evidencia |
|:-----|:-----------------|:------------------------------|:----------|
| VM seed (`astra-seed`) | arena | **No** — todo vive hasta que el proceso sale | `research/027` §3.1: 404 764 KB con 2 M de arrays |
| VM zig (`astra-zig`) | arena | **No** | `research/027` §3.1: 721 916 KB (ídem) |
| Backend C (`--emit-c` + gcc) | `malloc` sin `free` | **No** | `research/027` §3.1: 489 220 KB (ídem) |
| **Ruta LLVM** (`--emit-obj`, `--jit`, wasm, cross) | **ARC** con header `{rc, kind}` | **Sí**, en cuanto el contador llega a 0 — salvo ciclos | gate `zig/tests/llvm_mem.sh`: techo 64 MB; hoy **1 248 KB** |

Dos ideas, sin rodeos:

1. **Las dos VMs y el backend C no liberan nada en ejecución.** Su memoria
   es una arena (o un `malloc` sin `free`): cada array o string que creas se
   mantiene vivo hasta que el proceso termina. No es una fuga — es el diseño
   actual del seed, que está explícitamente fuera del alcance del
   refcounting (`research/002` §5.3) y de las VMs en general por ahora.
2. **La ruta nativa (LLVM) sí libera de verdad.** Cada objeto heap lleva un
   header `{int32_t rc; int32_t kind;}`; cada store, retorno, parámetro y
   local retiene o suelta, y cuando el rc llega a 0 la memoria vuelve al
   sistema **en ese momento** (M4.e, `PHASE_LLVM_PROGRESS.md` §12). Ciclos
   (p. ej. un closure cuyo entorno alcanza al propio closure) quedan fuera:
   los libera ORC, que aún no existe.

### Las cifras, en el mismo test

El test B2 de `research/030` —dos millones de arrays de 8 elementos
creados y descartados, el mismo patrón que
`ejemplos/11/asignacion_sostenida.astra` a menor escala— mide pico de
memoria por ruta con la misma máquina y el mismo programa
(`030_benchmarks_suite/results_extra.json`):

| Ruta | Pico RSS | Tiempo |
|:-----|---------:|-------:|
| C gcc -O2 | 1 232 KB | 39 ms |
| **Astra LLVM -O0** | **1 200 KB** | 181 ms |
| Astra seed-VM | **409 588 KB** (~400 MB) | 10,3 s |
| Astra zig-VM | **729 472 KB** (712 MiB) | 8,4 s |

El nativo de Astra se queda en **1,2 MB sostenidos** — el mismo piso que C
—, mientras las VMs trepan a **400–729 MB** (el rango con el que el propio
gate resume la divergencia). En el test de concatenación de strings (B3) la
separación es igual de clara: 1,4 MB constantes en LLVM frente a 320–354 MB
acumulados en las VMs.

### Esto es una divergencia documentada y gateada (DEC-009)

`DEC-009` (aceptada, test-pinned + gate) fija exactamente esto: **los VMs y
el backend C no liberan; la ruta LLVM libera con ARC; la divergencia queda
documentada y con techo de RSS medido.** El gate es
`zig/tests/llvm_mem.sh`, que ejecuta un bucle de 2 M de asignaciones por la
ruta nativa y falla si el pico supera **64 MB** (medido hoy: ~50× de
holgura):

```console
$ ./zig/tests/llvm_mem.sh
llvm_mem: ok — peak RSS 1248 KB <= ceiling 65536 KB (loop_reuse, native route)
```

Y hay dos puertas más contra fugas en la ruta nativa: `make debug` en el
seed (ASan + UBSan + LSan sobre la suite) y `zig/tests/llvm_sanitize.sh`,
que termina ejecutando `leaks.astra` con `detect_leaks=1`.

### Qué significa en la práctica

- **Desarrollo y tests** (VM): perfecto; los programas de la suite caben
  con holgura, y la arena se vacía al salir del proceso.
- **Un proceso largo** (servicio, daemon): si vas a asignar mucho durante
  horas, la ruta arena crecería sin límite — usa la **ruta LLVM**
  (`--emit-obj` o `--jit`), que es la única que devuelve memoria mientras
  corre. Es la razón práctica detrás del gate de 64 MB.
- El resultado **nunca** depende de cuándo se reclame la memoria: por eso
  mismo los mismos tests de conformidad pasan en arena y en ARC. El ejemplo
  `ejemplos/11/asignacion_sostenida.astra` lo ilustra — misma salida en las
  tres rutas:

```console
$ seed/astra-seed Documentacion/09_libro/ejemplos/11/asignacion_sostenida.astra
200000
8
$ zig/zig-out/bin/astra-zig Documentacion/09_libro/ejemplos/11/asignacion_sostenida.astra
200000
8
$ zig/zig-out/bin/astra-zig --jit Documentacion/09_libro/ejemplos/11/asignacion_sostenida.astra
200000
8
```

## El contrato sobre el que se cimienta todo: handles compartidos

Antes de hablar de concurrencia, el dato que la sostiene. **`let b = a`
copia el handle (la referencia), no los elementos** — DEC-001, fijado por
`seed/tests/conformance/arrays/alias_write.astra`:

```astra
let mut a = [1, 2, 3]
let mut b = a
b[0] = 99
print(a[0])
print(b[0])
```

(`ejemplos/11/handle_compartido.astra`)

```text
99
99
```

Esto es deliberado: **contar referencias significa compartir con
contabilidad, no duplicar** (el ARC de la ruta LLVM contabiliza
precisamente estos handles). Un `let` protege *tu binding* — no puedes
escribir `a[0] = 1` si `a` es `let` —, pero el objeto al que apunta es el
mismo (`ARCHITECTURE.md` §2.5; el contrato completo es el capítulo 05).

## Concurrencia: lo que está especificado

Primero el hecho, sin adornos: **hoy Astra-0 es de un solo hilo.** No hay
fibras, no hay `spawn`, no hay `transfer`, no hay `Atomic[T]`, no hay
`async/await` — un `grep` en `seed/src` y `zig/src` no encuentra ninguna de
esas palabras como keyword ni como builtin: `spawn` no aparece en absoluto,
`transfer` sólo está en comentarios en español (`transferir`) y `Atomic`
sólo como no-terminal de gramática (`AtomicType`). Puedes ejecutar
cualquier ejemplo de este capítulo en un hilo y se comportará igual.

Lo que sí existe está en la arquitectura, en dos capas:

**§2.4/§2.5 — las reglas *dentro* de una fibra (el modelo Astra-0).**

- **Inmutabilidad por defecto**: `let` no admite escrituras a través del
  binding; `let mut` sí (y los handles se comparten, como arriba).
- **Move semantics**: transferir un valor mutable a otra fibra invalidaría
  la variable emisora (`transfer(var)`).
- **Barreras de memoria**: modificación concurrente sólo vía `Atomic[T]`
  con semántica Acquire-Release.
- Los agregados (`let b = a`) se comparten como handles — §2.5 / DEC-001,
  el ejemplo de arriba.

(Nomenclatura: §2.4 del documento de arquitectura habla de `val`/`var`; la
forma canónica real de Astra-0 es `let`/`let mut` — `val` se descartó el
2026-09-16 y hoy ni siquiera lexea como palabra clave.)

**§2.6 — la frontera de fibra («especificado, NO implementado»).**
Este es el texto que hay que leer con la etiqueta que lleva encima.
La **DEC-012 está en estado `Propuesta`**: la dirección está elegida
(Opción F de `research/026`) pero **nada de ello existe en el código**.
La regla, resumida:

1. compartir *dentro* de una fibra es gratis (DEC-001);
2. lo inmutable (el `val` de la regla §2.4) cruza siempre;
3. un `let mut` sólo cruza si el compilador **prueba unicidad** en ese punto
   de flujo;
4. si no se prueba: `.copy()` explícito (deep copy) o `Atomic[T]`;
   `transfer(x)` será un **builtin** (no una keyword) que exige unicidad y
   invalida el binding emisor;
5. la comprobación en runtime (walk de `rc == 1` en el grafo) llega con la
   **primera feature con cruce real** (scheduler/send) — los VMs no tienen
   refcounting (DEC-009), así que no se adelanta.

Hoy `transfer` no lexea, no hay chequeo de unicidad y no hay fibras que
crucen nada. `research/026` §3–§4 guarda el detalle operativo (reglas
R1–R7); mientras DEC-012 sea `Propuesta`, la regla 5 de `AGENTS.md`
bloquea cualquier trabajo de backend que tenga que codificarla.

## Lo que el libro no promete

- **Nunca decimos «thread-safe» a secas.** La garantía que el proyecto
  sostiene —«dos fibras no pueden escribir el mismo objeto mutable a la
  vez»— está **especificada** (§2.6) y **todavía no se puede cumplir,
  porque no hay fibras**. Decir hoy que Astra es «thread-safe» sería
  vender §2.6 como si estuviera implementada.
- **No prometemos tiempos de liberación en las VMs**: no liberan, punto
  (DEC-009). Si un foro o una nota dice «Astra libera memoria», añade
  «…en la ruta LLVM».
- **No existe ORC ni ciclo colector**: el ARC de la ruta LLVM no libera
  ciclos. Estructuras cíclicas deliberadas crecen sin más hoy.
- `unsafe`, FFI y el resto del modelo grandilocuente de `ARCHITECTURE.md`
  §2–§3 (ARC atómico entre fibras, trial deletion, planificador M:N) son
  **diseño**, no comportamiento de Astra-0.

## Límites conocidos, resumidos

| Pregunta | Respuesta corta |
|:---------|:----------------|
| ¿Libera la VM seed? | No (arena; se vacía al salir el proceso) |
| ¿Libera la VM zig? | No (arena) |
| ¿Libera el backend C? | No (`malloc` sin `free`) |
| ¿Libera la ruta LLVM? | Sí — ARC con `{rc, kind}`, salvo ciclos |
| ¿Y si creo un ciclo? | Crece; ORC no existe aún |
| ¿Puedo lanzar un segundo hilo hoy? | No. No hay fibras ni `spawn` |
| ¿Existe `transfer(x)`? | No. DEC-012 `Propuesta`, builtin futuro |
| ¿`Atomic[T]`? | No existe |
| ¿Puedo confiar en «thread-safe»? | Sólo como promesa de §2.6, marcada como no implementada |

## Resumen

- **Dos modelos, una divergencia medida**: VMs seed/zig + backend C =
  arena (400–729 MB en el test de 2 M de asignaciones); ruta LLVM = ARC con
  header `{rc, kind}` (1,2 MB sostenidos). **DEC-009** lo documenta y lo
  gatea: `zig/tests/llvm_mem.sh` con techo de **64 MB** (hoy 1 248 KB).
- **El ARC libera todo salvo ciclos**; las arenas no liberan nada hasta
  que el proceso sale. Elige ruta según eso: VM para desarrollo, LLVM para
  procesos largos.
- **La concurrencia está especificada, no implementada**: §2.4/§2.5 son las
  reglas intra-fibra; §2.6 (frontera de fibra, DEC-012 `Propuesta`) es la
  regla de cruce, y hoy no hay fibras, ni `transfer`, ni `spawn`, ni
  `Atomic[T]` en el código.
- **El libro no dice «thread-safe» sin su coletilla**: la garantía existe
  como texto de diseño, no como comportamiento verificable.

## Ejercicios

1. Ejecuta `ejemplos/11/asignacion_sostenida.astra` por las tres rutas y
   comprueba idéntica salida. Después mide el pico de memoria de cada una
   (`/usr/bin/time -v <comando>`, mira «Maximum resident set size») y
   compáralo con el techo de 64 MB del gate.
2. Verifica por tu cuenta la ausencia de concurrencia:
   `grep -rn "transfer\|spawn\|Atomic" seed/src zig/src` — no hay ninguna
   keyword ni builtin: `spawn` da cero resultados, `transfer` sólo aparece
   en comentarios en español y `Atomic` sólo como no-terminal de gramática
   (`AtomicType`).
3. Lee `DEC-009` y `DEC-012` en `Documentacion/01_lenguaje/DECISIONES.md`
   y resume cada una en una frase que puedas defender delante de alguien
   que pregunte «¿Astra libera memoria?» y «¿Astra es thread-safe?».
