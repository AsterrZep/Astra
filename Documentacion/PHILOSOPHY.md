# Astra — Filosofía de Diseño

## El Axioma Central

> **Todo está permitido siempre y cuando mejore el lenguaje Astra.**

No hay dogma. No hay "así se hace porque Rust/Go/Python lo hace así". Cada decisión se mide contra un solo criterio: **¿hace a Astra mejor?** Si la respuesta es sí, se adopta. Si la respuesta es no, se rechaza sin importar de dónde venga.

---

## Los Principios Fundamentales

### 1. Simplicidad como Estrategia de Ingeniería

> "Less is exponentially more" — Rob Pike (Go)

La simplicidad no es falta de potencia. Es la decisión deliberada de que cada característica debe justificar su existencia con un beneficio claro y medible.

**Lo que esto significa para Astra:**
- Cada keyword nuevo debe pasar la prueba: "¿Resuelve un problema que no se puede resolver con las primitivas existentes?"
- La sintaxis debe ser predecible. Si aprendes 10 reglas, debes poder predecir el comportamiento de las 100 combinaciones posibles.
- La complejidad accidental (boilerplate, ceremony) se elimina. La complejidad esencial (concurrency, memory safety) se gestiona con abstracciones elegantes.

**Lecciones de otros lenguajes:**
- **Go:** Demostró que un lenguaje con 25 keywords puede construir servidores a escala de Google. La simplicidad del Go permite que un desarrollador nuevo lea y entienda cualquier programa Go en minutos.
- **Python:** Demostró que la legibilidad es una propiedad de diseño, no un adorno. `import this` revela la filosofía.
- **Zig:** Demostró que puedes tener control de bajo nivel sin sacrificar la claridad. `comptime` reemplaza macros, templates, y constexpr con una sola primitiva.

### 2. Seguridad Sin La Tortura

> "La seguridad de memoria no debería requerir un PhD para usar."

ARC/ORC proporciona seguridad de memoria sin la complejidad explícita del Borrow Checker de Rust. El programador no necesita pensar en "lifeetimes" o "borrowing rules" — el compilador gestiona todo automáticamente, con la opción de tomar control manual cuando se necesita rendimiento extremo.

**Lo que esto significa para Astra:**
- Por defecto: ARC/ORC automático. Memoria segura sin escribir una línea extra.
- Opcionalmente: bloques `unsafe` con punteros crudos para cuando el programador necesita control total.
- Sin `null` — Option types que fuerzan el manejo explícito de la ausencia.
- Sin excepciones que explotan — Result/Option que fuerzan el manejo explícito de errores.

**Lecciones de otros lenguajes:**
- **Rust:** Demostró que la seguridad de memoria sin GC es posible. Pero su Borrow Checker frustra a muchos desarrolladores y dificulta la productividad inicial.
- **Nim:** Demostró que ARC/ORC funciona para lenguajes de propósito general. Pero su transición de GC a ARC rompió código existente.
- **Swift:** Demostró que ARC puede ser ergonomico en un lenguaje de producción. Pero sus ciclos de retención en closures son un problema conocido.
- **Vale:** Demostró que las "generational references" pueden ser una alternativa al borrow checker. Pero su ecosistema es demasiado joven.

### 3. Concurrencia Sin Colores

> "Las funciones no deberían tener colores." — Bob Nystrom

async/await divide las funciones en dos mundos incompatibles: síncronas y asíncronas. Esto crea un "error de diseño" que se propaga por toda la base de código. Los hilos verdes (fibras) eliminan este problema: el código parece síncrono pero se ejecuta de forma asíncrona.

**Lo que esto significa para Astra:**
- No hay `async` ni `await`. Las funciones son funciones.
- El runtime gestiona la suspensión y reanudación automáticamente.
- Las operaciones de I/O suspenden la fibra actual sin bloquear el hilo del SO.
- El programador escribe código simple; el runtime hace el trabajo pesado.

**Lecciones de otros lenguajes:**
- **Go:** Demostró que los goroutines (hilos verdes) funcionan a escala masiva. 100,000+ conexiones concurrentes con código que parece síncrono.
- **Erlang/Elixir:** Demostró que el modelo de actores con mensajes es poderoso para sistemas distribuidos.
- **Rust:** Demostró que async/await puede ser eficiente, pero a costa de complejidad (tokio, colored functions, pin).
- **JavaScript:** Demostró que async/await puede ser adictivo peroAlso demostró los problemas de "callback hell" y "promise hell".

### 4. Ejecución Dual: La Solución al Problema de los Dos Lenguajes

> "El problema de los dos lenguajes es real: prototipar en Python, reescribir en C++."

Astra elimina este problema con un backend dual: en desarrollo se comporta como un script rápido (interpretado, arranque <10ms), en producción se compila a binario nativo de máximo rendimiento.

**Lo que esto significa para Astra:**
- `astra run script.ast` — Interpretado, arranque instantáneo, ideal para desarrollo.
- `astra build --release` — Compilación AOT completa, binario estático nativo.
- La misma sintaxis, las mismas garantías, diferentes niveles de optimización.
- Sin la latencia de JIT de Julia ("time-to-first-plot").

### 5. Cero-Copia: El Puente entre Mundos

> "No dupliques datos. Comparte memoria."

La interoperabilidad zero-copy permite que Astra acceda directamente a la memoria de NumPy, PyTorch, y bibliotecas C sin copiar datos. Esto elimina la barrera de adopción para científicos y desarrolladores que ya tienen ecosistema en Python.

**Lo que esto significa para Astra:**
- FFI con C: acceso directo a punteros, sin marshaling.
- FFI con Python: PyBuffer protocol para acceder a arrays de NumPy/PyTorch.
- FFI con Julia: punteros compartidos vía C-API.
- Seguridad: anclas de alcance y pointer pinning para evitar liberación prematura.

---

## La Filosofía del Compilador

### Arquitectura Multi-IR

> "Cada representación intermedia tiene un propósito. No intentes hacer todo con una sola."

Rust demuestra que múltiples IRs (AST → HIR → MIR → LLVM IR) permiten optimizaciones específicas en cada nivel. Astra adopta este enfoque con su AIR (Astra Intermediate Representation):

```
Source → Lexer → Parser → AST → Type Checker → AIR → Backend
```

**El AIR es el corazón del compilador:**
- Donde se insertan los incrementos/decrementos de ARC/ORC.
- Donde se insertan los yield points para fibras.
- Donde se eliminan los tipos de unidades de medida.
- Donde se specializan los genéricos.

### Query-Based Architecture

> "El compilador debe recordar lo que ya计算ó."

Rust usa un sistema de queries (Salsa) para compilación incremental. Astra adopta este enfoque desde el inicio: cada paso del compilador es una query con memoización, permitiendo compilación incremental y tiempos de respuesta rápidos para el LSP.

### Dual Backend Filosofy

> "El mejor compilador es el que no compila cuando no necesitas que compile."

- **Modo Desarrollo:** Bytecode VM con TCC/Cranelift. Compilación en milisegundos.
- **Modo Producción:** AOT vía LLVM. Optimizaciones completas, monomorfización, inlining.

La clave es que el AIR es consumible por ambos backends. El comptime se resuelve antes de la selección del backend.

---

## La Filosofía del Runtime

### ARC/ORC: El Mejor Compromiso

> "El Garbage Collector ideal es el que no existe."

ARC/ORC proporciona:
- **Liberación determinista:** La memoria se libera en el microsegundo exacto en que deja de usarse.
- **Sin pausas STW:** A diferencia de los tracing GCs (Go, Java, JavaScript).
- **Detección de ciclos:** ORC con Trial Deletion (Bacon-Rajan) para grafos de objetos cíclicos.
- **Control manual opcional:** Bloques `unsafe` con allocators personalizados para rendimiento extremo.

### Hilos Verdes: El Futuro es Síncrono

> "El código debe leerse de arriba a abajo, como una receta."

Las fibras de Astra son el modelo M:N inspirado en Go:
- M fibras mapeadas a N hilos del SO.
- Pilas dinámicas de ~2 KB que crecen según necesidad.
- Puntos de ceder paso (yield points) en cada operación de I/O.
- Cambio de contexto en FFI con patrón entersyscall/exitsyscall.

### Custom Allocators: Control Total Cuando Se Necesita

> "No todas las allocaciones son iguales."

Astra soporta allocators personalizados para diferentes casos de uso:
- **ArenaAllocator:** Para fases de request en servidores.
- **FixedBufferAllocator:** Para sistemas embedded sin heap.
- **BumpAllocator:** Para game engines (reset por frame).
- **PoolAllocator:** Para muitos objetos del mismo tamaño.

---

## La Filosofía del Ecosistema

### Toolchain Unificado

> "Una herramienta, todas las funcionalidades."

```
astra run      # Ejecutar
astra build    # Compilar
astra test     # Testear
astra fmt      # Formatear
astra pkg      # Gestionar paquetes
astra repl     # REPL interactivo
astra kernel   # Jupyter kernel
```

### Error Messages como Documentación

> "Un buen error message enseña al programador a ser mejor."

Astra adopta el enfoque de Rust y Elm para mensajes de error:
- Explicar QUÉ falló.
- Explicar POR QUÉ falló.
- Sugerir CÓMO arreglarlo.
- Mostrar el código relevante con subrayado.

### Testing como Ciudadano de Primera Clase

> "Si no se puede testear, no se puede mantener."

Estructura de testing del compilador:
```
tests/
├── conformance/    # Contra la especificación del lenguaje
├── ui/             # Mensajes de error
├── codegen/        # Código generado
├── incr/           # Compilación incremental
├── cross/          # Cross-compilation
├── fuzz/           # Fuzzing a largo plazo
└── property/       # Property-based testing
```

---

## Lecciones de la Historia

### Por Qué Algunos Lenguajes Fracasan

1. **JIT Latency (Julia):** "Time-to-first-plot" mató la adopción en CLI/scripts.
2. **GC Pauses (Java viejo):** Las pausas impredecibles lo descartaron para tiempo real.
3. **Async Complexity (Rust):** Las funciones coloreadas frustran a desarrolladores nuevos.
4. **Ownership Complexity (Mojo):** La curva de aprendizaje aleja al público objetivo.
5. **Concurrency Crisis (Nim):** Evolucionar features antes de que estén estables rompe el ecosistema.
6. **Ecosystem Lock-in (Swift):** La percepción de Apple-only limita la adopción cross-platform.

### Por Qué Algunos Lenguajes Éxitan

1. **Ecosistema (Python):** Miles de paquetes, tutoriales, soporte en la nube.
2. **Simplicidad (Go):** Un lenguaje que un equipo puede aprender en una semana.
3. **Rendimiento (C/C++):** Velocidad nativa para sistemas operativos y juegos.
4. **Herramientas (Rust):** Cargo, rustfmt, clippy, rust-analyzer son best-in-class.
5. **Community (Python/Rust):** Comunidades activas que contribuyen paquetes y documentación.
6. **Corporate Backing (Go/Google, Swift/Apple):** Recursos para desarrollo y adopción.

### La Verdad Incómoda

> "El rendimiento técnico es necesario pero insuficiente."

Un lenguaje nuevo necesita:
1. **Mérito técnico:** Rendimiento, seguridad, ergonomía.
2. **Herramientas:** Formatter, LSP, package manager, debugger.
3. **Documentación:** Tutoriales, guías, referencia de API.
4. **Ecosistema:** Paquetes populares que la gente necesita.
5. **Comunidad:** Personas que responden preguntas y ayudan.
6. **Adopción temprana:** Casos de uso reales que demuestran valor.

Astra debe construir todo esto desde el día uno. No es suficiente tener un gran lenguaje; se necesita un gran ecosistema.

---

## La Promesa de Astra

Astra no intenta ser el "mejor lenguaje del mundo". Intenta ser **el lenguaje correcto** para:

1. **Científicos** que quieren rendimiento nativo sin reescribir en C++.
2. **Desarrolladores web** que quieren concurrencia masiva sin async/await.
3. **Ingenieros de sistemas** que quieren seguridad de memoria sin la complejidad de Rust.
4. **Estudiantes** que quieren un lenguaje potente pero aprendible.
5. **Equipos** que quieren un toolchain unificado sin dependencias externas.

La promesa es simple: **Escribe una vez, ejecuta en cualquier modo.** En desarrollo, es rápido y flexible. En producción, es seguro y eficiente. Siempre es el mismo lenguaje.

---

## Referencias Filosóficas

- "Worse is better" — Richard P. Gabriel
- "The Simplest Thing That Could Possibly Work" — Ward Cunningham
- "Make it work, make it right, make it fast" — Kent Beck
- "Premature optimization is the root of all evil" — Donald Knuth
- "SimPLICITY IS PREREQUISITE FOR RELIABILITY" — Edsger Dijkstra
- "All problems in computer science can be solved by another level of indirection" — David Wheeler
- "The key to performance is elegance, not battalions of special cases" — Jon Bentley
