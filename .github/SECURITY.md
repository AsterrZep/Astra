# Security Policy / Política de Seguridad

---

## 🇬🇧 English

### Supported Versions

Astra is pre-1.0 software under active development. Security fixes are applied to
the `main` branch only; there are no versioned releases yet.

| Component | Supported |
|-----------|-----------|
| `main` branch (seed compiler + Zig compiler + LLVM backend) | ✅ |
| Any tag / release | ❌ (none published yet) |
| Older commits | ❌ |

### Reporting a Vulnerability

**Please do NOT report vulnerabilities through public issues.**

Report them privately via GitHub Security Advisories:

👉 **https://github.com/AsterrZep/Astra/security/advisories/new**

Include as much as you can:

- A description of the vulnerability and its impact.
- Steps to reproduce (a minimal `.astra` input, crashing command, or a fuzz
  artifact from `seed/fuzz/` is ideal).
- Affected component (`seed/` C compiler, `zig/` compiler, LLVM backend,
  C runtime `codegen_runtime.h`, or the toolchain scripts).
- Any known workarounds.

### What to expect

- **Acknowledgement** within **72 hours**.
- An initial assessment within **7 days**.
- A coordinated fix and disclosure timeline agreed with the reporter.
- Credit in the advisory unless you prefer to remain anonymous.

### Scope

In scope:

- Memory-safety bugs in the seed compiler (`seed/src/`), the Zig compiler
  (`zig/src/`), the LLVM backend and `codegen_runtime.h` (e.g. buffer
  overflows, use-after-free, uninitialized reads reachable from source input).
- Compiler crash / hang / miscompilation bugs reachable from untrusted `.astra`
  input (the compilers are the trust boundary; the parser must stay bounded —
  see `PARSER_MAX_DEPTH`).
- Leaked secrets, injection via codegen string escaping, or arbitrary code
  execution from source input.

Out of scope:

- Vulnerabilities only reachable from code that the compiler was explicitly
  asked to compile and execute (the emitted programs run with the user's
  privileges by design).
- Denial of service via machine-scale resource exhaustion (e.g. consuming all
  RAM of the build machine) without a bounded-input trigger.
- Findings from fuzzing that `fuzz/classify.sh` proves to be environment
  flakes.

### Safe Harbor

We consider security research conducted in good faith and in accordance with
this policy to be authorized. We will not pursue legal action against
researchers who:

- Avoid privacy violations, destruction of data, and service disruption.
- Only interact with accounts they own or with explicit authorization.
- Report findings promptly and keep them confidential until a fix ships.

---

## 🇪🇸 Español

### Versiones soportadas

Astra es software pre-1.0 en desarrollo activo. Los arreglos de seguridad se
aplican **solo a la rama `main`**; todavía no hay releases versionados.

| Componente | Soportado |
|------------|-----------|
| Rama `main` (compilador seed + compilador Zig + backend LLVM) | ✅ |
| Cualquier tag / release | ❌ (ninguno publicado aún) |
| Commits antiguos | ❌ |

### Cómo reportar una vulnerabilidad

**NO reportes vulnerabilidades en issues públicas.**

Repórtalas de forma privada mediante GitHub Security Advisories:

👉 **https://github.com/AsterrZep/Astra/security/advisories/new**

Incluye todo lo que puedas:

- Descripción de la vulnerabilidad y su impacto.
- Pasos para reproducirla (una entrada `.astra` mínima que crashee, el comando
  que la provoca, o un artefacto de `seed/fuzz/` es lo ideal).
- Componente afectado (`seed/` compilador C, `zig/` compilador, backend LLVM,
  runtime C `codegen_runtime.h`, o scripts de toolchain).
- Workarounds conocidos.

### Qué esperar

- **Acuse de recibo** en un máximo de **72 horas**.
- Evaluación inicial en **7 días**.
- Cronograma de arreglo y divulgación coordinado con quien reporta.
- Crédito en el advisory salvo que prefieras ser anónimo.

### Alcance

Dentro del alcance:

- Bugs de seguridad de memoria en el compilador seed (`seed/src/`), el
  compilador Zig (`zig/src/`), el backend LLVM y `codegen_runtime.h` (p. ej.
  buffer overflows, use-after-free, lecturas sin inicializar alcanzables desde
  una entrada de código fuente).
- Bugs de compilador que crashean, cuelgan o generan código incorrecto
  alcanzables desde entradas `.astra` no confiadas (el compilador es la frontera
  de confianza; el parser debe mantenerse acotado — ver `PARSER_MAX_DEPTH`).
- Fugas de secretos, inyección vía escape de strings del codegen, o ejecución
  arbitraria de código a partir de código fuente.

Fuera del alcance:

- Vulnerabilidades alcanzables solo desde código que el compilador fue
  explícitamente invitado a compilar y ejecutar (los programas emitidos corren
  con los privilegios del usuario por diseño).
- Denegación de servicio por agotamiento de recursos a escala de máquina
  (p. ej. consumir toda la RAM del equipo de build) sin un trigger de entrada
  acotada.
- Hallazgos de fuzzing que `fuzz/classify.sh` demuestre que son flakes de
  entorno.

### Garantía de buena fe

Consideramos autorizada la investigación de seguridad hecha de buena fe y
según esta política. No emprenderemos acciones legales contra investigadores
que:

- Eviten violaciones de privacidad, destrucción de datos y interrupción del
  servicio.
- Interactúen solo con cuentas propias o con autorización explícita.
- Reporten los hallazgos de forma prompt y los mantengan confidenciales hasta
  que un arreglo se publique.
