# Capítulo 15 — Glosario

> **Estado de este capítulo** (2026-10-28): términos del proyecto Astra tal
> como se usan hoy en el libro y en `Documentacion/`. Cada entrada enlaza al
> capítulo o documento donde se explica; este capítulo no enseña, **ubica**.

**AOT** (*ahead-of-time*) — Compilar a código nativo antes de ejecutar: las
rutas 4/6/7 del [capítulo 12](12_rutas_ejecucion.md) (`--emit-obj`), frente a
`--jit` que compila al correr.

**ARC** (*Automatic Reference Counting*) — Modelo de memoria de la ruta LLVM:
cada valor de heap lleva un contador de referencias y se libera al llegar a
cero — sin GC y sin pausas. Implementado en el backend
([PHASE_LLVM_PROGRESS](../05_fase_llvm/PHASE_LLVM_PROGRESS.md) §12); los VMs
aún no lo tienen (ver *arena*, y DEC-009 para la divergencia gateada).
**ORC** es otra cosa: la infraestructura de JIT de LLVM (*On-Request
Compilation*) que `--jit` usa vía LLJIT — ver *JIT*.

**Astra-0** — El subconjunto de Astra que hoy compilan el seed y el zig:
scalars, strings, arrays, structs, enums, `match`, Option/Result con `?`,
closures, genéricos monomorfizados, traits/impls, módulos (solo zig). Es lo
que el libro describe «tal como es» —
[`ARCHITECTURE.md`](../01_lenguaje/ARCHITECTURE.md) documenta el lenguaje
completo planeado.

**arena** — Asignador lineal: reservas un bloque grande y todo se libera de
golpe al terminar la fase, sin `free` por objeto. Así viven las VMs seed/zig
y el backend C (su deuda medida: 400–729 MB donde la ruta LLVM usa ≤ 2 MB);
así **no** vive la ruta LLVM, que usa ARC. Ver DEC-009 y el
[capítulo 11](11_memoria_concurrencia.md).

**backend** — El componente que traduce del formato interno a código
ejecutable: `codegen.c` (bytecode → C), el emisor LLVM (typed AST → objeto
nativo). No confundir con *VM*: un backend produce código, una VM lo ejecuta.
Ver [capítulo 12](12_rutas_ejecucion.md).

**builtin** — Función resuelta por nombre por el runtime, sin importar nada:
`print`, `len`, `s[i]`, `to_string`, `read_file` hoy. Sus nombres están
reservados (DEC-015). Ver [capítulo 14](14_referencia_builtins.md).

**bytecode** — Código de la VM: instrucciones (`CONST`, `CALL`, `JUMP`…) que
produce el emisor de `emitter.c`/`emitter.zig` y ejecutan las VMs. Míralo con
`--dump-bytecode` o `ASTRA_DUMP_VM=1`. Ver [capítulo 13](13_toolchain_cli.md).

**conformance** — `seed/tests/conformance/`: la suite de cumplimiento que
fija el comportamiento del lenguaje caso a caso con comentarios `EXPECT:`.
Todo cambio de comportamiento exige su caso aquí; es la puerta que el frontend
zig debe pasar por completo.

**DEC-NNN** — Entrada numerada en
[`DECISIONES.md`](../01_lenguaje/DECISIONES.md): la decisión de lenguaje que
justifica un comportamiento, con alternativas consideradas, coste aceptado y
evidencia (el test que la fija). Nada de lenguaje cambia sin su DEC-NNN —
por eso el libro cita «DEC-013» donde otros libros dirían «según la
especificación».

**dump parity** — El gate `zig/tests/dump_parity.sh`: los dumps de tokens y
AST del seed y del zig deben ser **byte-idénticos** sobre la misma suite
(184 ficheros, 0 divergente al 2026-10-28). Garantiza que los dos frontends
ven el mismo programa. Ver [capítulo 13](13_toolchain_cli.md).

**emisor** (*emitter*) — Quien produce código: `emitter.c` (AST → bytecode)
en el seed, `zig/src/emitter/` en el zig, `zig/src/llvm/` (typed AST → LLVM
IR) en el backend nativo.

**fibra** — Unidad de concurrencia del diseño de Astra: hilos ligeros con
mensajes, sin data races por construcción. **Especificado, NO implementado**
([`ARCHITECTURE.md`](../01_lenguaje/ARCHITECTURE.md) §2.6 — Astra-0 no tiene
concurrencia; el libro lo dice donde importa, [capítulo 11](11_memoria_concurrencia.md)).

**gate** — Comando que decide si algo está verde: `make test`, `zig build
test`, `llvm_parity.sh`, etc. Un gate o pasa o falla; no se discute. La
cultura del proyecto es que cada comportamiento nuevo llegue con su gate.
Ver [capítulo 12](12_rutas_ejecucion.md) (gates por ruta) y
[AGENTS.md](../../AGENTS.md) (la lista completa).

**JIT** — Compilar *al ejecutar*, dentro del propio proceso: `--jit` usa
ORC/LLJIT de LLVM, sin paso de `cc` ni fichero objeto. Cimiento de un futuro
REPL. Ver [capítulo 12](12_rutas_ejecucion.md), ruta 5.

**keyword** — Palabra reservada del lenguaje (`let`, `fn`, `match`, `ok`…):
36 en el lexer de Astra-0, no usable como identificador. Lista completa en
[capítulo 14](14_referencia_builtins.md).

**monomorfización** — Cómo el backend LLVM implementa genéricos: cada uso
concreto de una función genérica se compila como una copia especializada con
los tipos reales — cero coste de boxing en el código final. El VM en cambio
usa valores boxed. Ver [capítulo 09](09_generics_traits.md).

**paridad** (*parity*) — Que dos rutas de ejecución produzcan stdout, stderr
y código de salida **byte a byte idénticos**. Es la propiedad central del
proyecto: seed VM ↔ zig VM ↔ backend C ↔ LLVM ↔ JIT ↔ wasm ↔ aarch64, todas
contra la misma referencia. Ver [capítulo 12](12_rutas_ejecucion.md).

**runtime (TU)** — `zig/src/llvm/runtime/astra_runtime_llvm.c`: el fichero C
fino que la ruta LLVM enlaza contra tu programa (`cc prog.o runtime.o -lm`).
Implementa los builtins y el manejo de errores nativos; incluye
`codegen_runtime.h` exactamente una vez. No confundir con el *runtime* del
VM, que es `vm.c`/`vm.zig`.

**seed** — El compilador semilla en C de la Fase 1 (`seed/`): lexer, parser,
typechecker, emisor de bytecode, VM y backend C en un binario
(`astra-seed`). Es la referencia de semántica y el eslabón primero de la
cadena de autoalojamiento. Ver [capítulo 13](13_toolchain_cli.md).

**self-hosting** — Que un componente del compilador esté escrito en el propio
lenguaje: hoy el lexer (`seed/tests/selfhost/lexer.astra`, DEC-016) corre por
7 rutas y su flujo de tokens se compara contra `--dump-tokens`. El primer
eslabón del plan de autoalojamiento C → Zig → Astra. Ver
[capítulo 13](13_toolchain_cli.md).

**skip** — En los gates LLVM, un caso que el emisor rechaza por estar fuera
de su subconjunto («not supported by the LLVM backend»). Contar un skip como
pass escondió una regresión una vez; **hoy un skip hace fallar el gate** y lo
que está fuera a propósito se lista en `EXCLUDE`, con comentario.

**stdlib M1/M2** — Los hitos de la librería estándar mínima: M1 fusionó
`len`, `s[i]`, `to_string`, `read_file` (DEC-013/014/015); M2 añade `ord`,
`substr` (M2a, DEC-018, PR en revisión al 2026-10-28) y `push`,
`str_to_int` (M2b, en implementación). Ver [capítulo 14](14_referencia_builtins.md).

**UI tests** — `seed/tests/conformance/ui/`: los casos que deben **fallar**
— diagnósticos de compilación correctos (sombreado de builtin, asignación a
elemento de string…). Su primera línea debe ser byte-idéntica seed↔zig.

**VM** — Máquina virtual de pila que ejecuta bytecode: `vm.c` (seed) y
`zig/src/vm/` (zig). Herramientas de desarrollo: arranque rápido, dumps,
depurador — pero **no liberan memoria** (arena lineal). Para producción, la
ruta LLVM. Ver [capítulo 12](12_rutas_ejecucion.md) y
[capítulo 11](11_memoria_concurrencia.md).

**wasm32-wasi** — Target WebAssembly con la interfaz de sistema WASI: la ruta
6 del [capítulo 12](12_rutas_ejecucion.md). Compila con
`--target=wasm32-wasi`, enlaza con `wasm-ld` + wasi-libc y corre bajo un
runtime WASI (Node ≥ 22). Requiere un sysroot con `<setjmp.h>` moderno.

**worktree** — Copia de trabajo de un repositorio git apuntando a otra rama,
con su propio directorio: la unidad de trabajo en paralelo del proyecto
(`git worktree add`). Permite que varios agentes editen ramas distintas sin
tocar el checkout principal. Ver [AGENTS.md](../../AGENTS.md).

**wrap** — Desbordamiento controlado de los tipos enteros: en vez de
undefined behavior, `i32`/`i64`/`u32`/`u64` dan la vuelta al módulo 2ⁿ
(fijado en DEC-007). Ver [capítulo 02](02_variables_tipos.md).

## Resumen

- Los términos con mayúsculas en este libro (`DEC-NNN`, `gate`, `paridad`)
  son vocabulario del proyecto, no jerga decorativa: cada uno apoya una
  práctica verificable.
- Donde una palabra describe algo **planeado** pero no existente (fibra,
  stdlib completa, CLI unificada), el libro lo dice — el glosario no vende.
- La palabra que más vas a oír es *paridad*: todo el andamiaje de gates
  existe para que «las 7 rutas dan lo mismo» sea un hecho comprobable, no una
  esperanza.
