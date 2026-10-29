# The Astra Programming Language — guía de usuario (libro)

> **Alcance**: libro de usuario estilo *The Rust Programming Language*.
> **Contenido en evolución** (decisión del 2026-10-28): primero el texto; el
> build HTML (mdBook o equivalente) llega después. Cada capítulo documenta
> **solo lo implementado hoy** (Astra-0 + los 10 builtins + las 7 rutas) —
> nunca el pitch futuro; lo que existirá se marca con «Aún no existe» y
> remite a `ARCHITECTURE.md`/`DECISIONES.md`.

## Guía de estilo (obligatoria para todos los capítulos)

1. **Idioma**: español; nombres de código/identificadores en inglés, como en
   el resto de `Documentacion/`.
2. **Todo ejemplo es real**: cada bloque de código vive en
   `ejemplos/<cap>/<nombre>.astra`, se compila y se ejecuta con
   `zig/zig-out/bin/astra-zig <fichero>` (ruta VM) y el texto pegado es la
   **salida real** entre `// salida:` o bloque `text`. Si algo no compila hoy,
   no está en el libro — se documenta en la sección «Aún no existe».
3. **Honestidad primero**: el libro describe Astra-0 TAL COMO ES (con sus
   límites: `len` devuelve `i64`, strings inmutables, sin fibers, VMs sin
   liberación). Cada afirmación de semántica que tenga decisión detrás cita
   su `DEC-NNN` (una frase + enlace a `Documentacion/01_lenguaje/DECISIONES.md`).
4. **Estructura de capítulo**: por qué → conceptos → ejemplos crecientes →
  «Resumen» → «Ejercicios» (2-3, sin respuesta en página).
5. **Tono**: tuteo, sin marketing, sin comparaciones con otros lenguajes salvo
   una nota breve donde ayude (p. ej. «esto recuerda a…»).
6. **Profundidad técnica**: el libro enseña a *programar*; el *por qué* fino
   está en `ARCHITECTURE.md` y los informes — el libro enlaza, no duplica.

## Esquema de capítulos (v1 — contenido, sin HTML aún)

| Cap | Título | Estado |
|:---:|:-------|:-------|
| 00 | `00_introduccion.md` — qué es Astra, qué puede hacer hoy, instalar/builder | ✅ 2026-10-28 (1 ejemplo) |
| 01 | `01_primer_programa.md` — hola mundo, correrlo (VM) y nativo (`--emit-obj`), estructura de un fichero | ✅ 2026-10-28 (3) |
| 02 | `02_variables_tipos.md` — `let`/`let mut`/`val`, tipos (i32/i64/u32/u64/f64/bool/string), defaults DEC-006, wrap DEC-007 | ✅ 2026-10-28 (11) |
| 03 | `03_control_flujo.md` — `if`/`else`, `while`, `for..in`, `break`/`continue` | ✅ 2026-10-28 (9) |
| 04 | `04_funciones_closures.md` — funciones, return implícito, recursión, closures (captura por valor DEC-004) | ✅ 2026-10-28 (5) |
| 05 | `05_arrays_structs.md` — arrays, structs, **el contrato de aliasing** (DEC-001/002: `let` protege el binding, no el objeto) | ✅ 2026-10-28 (8) |
| 06 | `06_enums_match.md` — enums, construcción calificada DEC-008, match (guards, or-patterns, exhaustividad) | ✅ 2026-10-28 (6) |
| 07 | `07_option_result.md` — `some`/`none`/`ok`/`err`, `match`, el operador `?` | ✅ 2026-10-28 (6) |
| 08 | `08_strings_texto.md` — literales, inmutabilidad, los 10 builtins (`len`, `s[i]`, `ord`, `substr`, `to_string`, `read_file`, `push`, `str_to_int`, `chr`, `read_line`), errores de runtime | ✅ 2026-10-28 (8) |
| 09 | `09_generics_traits.md` — genéricos monomorfozados, `impl`, traits (lo que existe) | ✅ 2026-10-28 (8) |
| 10 | `10_modulos_multifichero.md` — `use`, `pub`, rutas `@/`, orden de dependencias | ✅ 2026-10-28 (13) |
| 11 | `11_memoria_concurrencia.md` — modelo honesto: dónde libera (LLVM/ARC) y dónde no (VMs arena), §2.6 de fibras = especificado NO implementado | ✅ 2026-10-28 (2) |
| 12 | `12_rutas_ejecucion.md` — las 7 rutas (VM/C/LLVM/JIT/wasm/cross), cuándo usar cada una, gates que las protegen | ✅ 2026-10-28 (1) |
| 13 | `13_toolchain_cli.md` — comandos reales del día (`astra-zig`, `astra-seed`, `--emit-obj`, `--jit`, gates de selfhost) | ✅ 2026-10-28 (4) |
| 14 | `14_referencia_builtins.md` — tabla de referencia: 10 builtins + keywords + errores de runtime con sus textos exactos | ✅ 2026-10-28, actualizado 2026-10-29 (6) |
| 15 | `15_glosario.md` — términos (fibra, ARC/ORC, DEC, gate, Astra-0, seed, paridad…) | ✅ 2026-10-28 (0) |

## Puertas (mínimas en v1)

- Los ejemplos viven en `ejemplos/` y **se ejecutan** antes de pegarlos.
- Gate futuro (fuera de v1): script que re-ejecute todos los `ejemplos/**/*.astra`
  y compare con los bloques de salida — anotado en este fichero, no implementado.
