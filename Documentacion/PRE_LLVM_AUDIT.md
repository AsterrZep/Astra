# Astra — Auditoría previa a la Fase 2.6 (LLVM)

Fecha de inicio: 2026-10-14. Motivo: la Fase 2.6 introduce un backend
nativo (LLVM o codegen Zig) sobre **toda** la semántica ya construida;
antes de apilar una capa más se revisa desde el principio todo lo hecho
(Fase 1 `seed/` + Fase 2 `zig/`), se documenta por partes, y se fija cada
bug encontrado con su repro y su test.

> Relación con lo anterior: `COHERENCE_AUDIT.md` (2026-09-16/21) auditó
> coherencia doc↔código y memoria del seed *de la Fase 1*, con PoCs en
> `PHASE1_PROGRESS.md` §6. Esta auditoría cubre **todo lo posterior y
> rehecha la verificación activa** con herramientas que entonces no
> había (barridos diferenciales a los tres backends, campañas de fuzz
> con ASan sobre la suite, verificación de mensajes byte-a-byte).

---

## §0 — Plan, método y criterios

### Alcance y partes

| § | Parte | Qué cubre |
|:-:|:------|:----------|
| 1 | **Barridos activos** | Bugs encontrados *ejecutando*: conformance↔C (`--emit-c`+gcc vs VM), mensajes `ui/` seed↔zig, campaña de fuzz con ASan |
| 2 | **Frontend seed** | `lexer.c`, `parser.c` (Pratt, profundidad, recuperación), `ast.c`, `constructs/` + registry |
| 3 | **Semántica seed** | `typechecker.c`: ámbitos, literales polimorficos, `match`, structs/enums, traits/genéricos, `?`, mutabilidad |
| 4 | **Emitter + VM seed** | `emitter.c` (balance de pila, parcheo de saltos), `vm.c` (frames, opcodes, valores) |
| 5 | **C backend** | `codegen.c`, `codegen_runtime.h`: modelo de memoria, setjmp, límites de registro, posiciones de línea |
| 6 | **Zig** | Paridad real de mensajes (hoy sin gate), diagnósticos por fase, módulos, huecos de los `checked > N` |
| 7 | **Suite de tests** | Qué feature no tiene test, aserciones débiles, `EXPECT:` vs comportamiento real |
| 8 | **Docs** | AGENTS/PROGRESS/CHANGELOG/GAP/ARCHITECTURE vs código |
| 9 | **Síntesis** | Bugs fijados/diferidos, criterios de entrada a la Fase 2.6 |

### Método (igual para cada parte)

1. **Pruebas activas primero**: barridos/fuzz que ejercitan los tres
   caminos (VM seed, `--emit-c`+gcc, `astra-zig`) y comparan salida y
   mensajes; todo hallazgo empieza por una repro mínima en
   `/tmp/opencode/`.
2. **Lectura de código enfocada**, no línea a línea: los invariantes de
   `AGENTS.md` ("Invariantes que hay que preservar", "Key codegen
   invariants"), las rutas de error, los límites de tamaño, y las
   funciones que la repro toca. Se usa `explore` en paralelo cuando una
   parte supera dos lecturas.
3. **Fix-forward**: cada bug confirmado → repro verde tras el fix →
   test que lo fija → gates (`make debug` + `run_tests` +
   `--check-constructs`; `zig build test`; `dump_parity.sh`) → commit
   propio en convención (`fix(seed):`, `fix(zig):`, `test(lang):`…) con
   el número de hallazgo en el mensaje (`audit §N.M`).
4. **Documentación por parte**: cada § se escribe aquí con su tabla de
   hallazgos y se cierra con su propio commit `docs(audit): …`.

### Registro de hallazgos

Cada parte cierra con una tabla:

| # | Sev | Archivo:línea | Qué pasa | Estado |
|:-:|:---:|:--------------|:---------|:-------|
| N.1 | 🔴/🟠/🟡/🔵 | `emitter.c:123` | descripción | ✅ fix `<hash>` / ⚠️ diferido (razón) / 📋 abierto |

- 🔴 crash/UB/corrupción de memoria · 🟠 respuesta incorrecta o
  divergencia entre backends · 🟡 mensaje/edge-case · 🔵 higiene
  (docs, tests, aserciones).
- ⚠️ *diferido* exige razón explícita; 📋 *abierto* no puede pasar a §9.

### Criterios de salida hacia la Fase 2.6 (detalle en §9)

1. Cero hallazgos 🔴 abiertos; 🟠 cerrados o diferidos con repro
   documentada.
2. Los tres barridos de §1 en verde y **puestos como gate** (script en
   `seed/tests/`, hilo en CI o `make`).
3. Cobertura mínima: cada feature con `EXPECT:` o `EXPECT-ERROR` en al
   menos un caso; sin `checked > N` sueltos en `conformance.zig`.
4. §4 (emitter/VM) cerrado: la semántica que LLVM deberá replicar está
   verificada y fijada con tests — es la base que el backend nuevo
   copia.
5. Mensajes seed↔zig: o byte-idénticos o divergencia de formato
   aceptada y documentada en §6.

---

*(Las secciones siguientes se van añadiendo conforme avanza la
auditoría; cada una cierra con su commit.)*
