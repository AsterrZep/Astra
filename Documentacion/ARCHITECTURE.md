# Astra — Especificación Arquitectónica v0.1

Lenguaje de programación multi-paradigma, de propósito general y científico, diseñado para unir la ergonomía de Python/TypeScript con la velocidad nativa de C/Rust, sin la complejidad del Borrow Checker ni las pausas de GC tradicionales.

---

## 1. Pilares Fundamentales

| Pilar | Descripción |
|:------|:------------|
| **Simplicidad Ergonómica** | Sintaxis limpia, legible, inmutabilidad por defecto. |
| **Seguridad Sin Lucha** | Memoria segura vía ARC/ORC, sin GC stop-the-world y sin la complejidad explícita de Rust. |
| **Ejecución Dual** | Modo interpretado/VM para desarrollo rápido (<10ms) y compilación AOT a binario estático nativo para producción. |
| **Concurrencia Transparente** | Hilos verdes (fibras) sin `async/await`, código que parece síncrono pero ejecuta de forma asíncrona. |
| **Cero-Copia (Zero-Copy FFI)** | Mapeo directo de memoria de C y Python (NumPy, PyTorch) sin duplicación de datos. |

---

## 2. Modelo de Memoria

### 2.1 Gestión Híbrida Alto/Bajo Nivel

| Modo | Mecanismo | Cuándo Usar |
|:-----|:----------|:------------|
| **Alto Nivel (Por Defecto)** | ARC/ORC: Conteo de referencias automático, liberación determinista sin pausas STW. | Código general, scripts, servidores. |
| **Bajo Nivel (`unsafe`)** | Manual / Arenas: Punteros crudos (`Ptr<T>`), `alloc`/`free`. | Kernels, drivers, optimización extrema. |

### 2.2 ARC/ORC Detallado

- **ARC (Atomic Reference Counting):** Conteo de referencias atómico para objetos compartidos entre fibras en diferentes núcleos.
- **ARC No-Atómico Local a la Fibra:** Para objetos que no cruzan fronteras de fibras, se usa RC no atómico (transferencia de propiedad estricta). Si un objeto debe compartirse entre fibras, se fuerza la promoción a `AtomicRef[T]` o se realiza deep copy.
- **ORC (Ownership-based Reference Counting):** Detecta y libera ciclos de memoria mediante el algoritmo de Trial Deletion (Bacon-Rajan) sin Stop-The-World.

### 2.3 Algoritmo de Eliminación de Prueba (Trial Deletion)

El ciclo de recolección incremental opera con coloración de nodos:

| Color | Estado | Significado |
|:------|:-------|:------------|
| **Negro (Black)** | Vivo / Estable | Objeto en uso activo o alcanzable desde raíz. |
| **Púrpura (Purple)** | Sospechoso de Ciclo | RC decrementado pero > 0. Añadido a `possible_roots`. |
| **Gris (Gray)** | Marcado en Prueba | RC provisionalmente decrementado vía DFS. |
| **Blanco (White)** | Basura Cíclica | Verificado como inalcanzable externamente. Candidato a liberación. |

Fases del algoritmo:
1. **MarkGray:** DFS decrementando RC temporalmente y coloreando de gris.
2. **Scan:** Si nodo gris tiene RC > 0, tiene referencias externas → ScanBlack (restaura negro). Si RC = 0 → blanco.
3. **CollectWhite:** Nodos blancos se desasignan determinísticamente con destructores en dos etapas.

### 2.4 Prevención de Data Races (SC-DRF)

Modelo de Memoria: Secuencialmente Consistente para Programas Libres de Carreras de Datos.

| Regla | Descripción |
|:------|:------------|
| **Inmutabilidad por Defecto** | `val` = inmutable profundo. Compartible entre fibras sin sincronización. |
| **Move Semantics** | `var` = mutable. Para transferir a otra fibra: `transfer(var)`. Invalida la variable emisora. |
| **Barreras de Memoria** | Para modificación concurrente: `Atomic[T]` con semántica Acquire-Release. |

---

## 3. Concurrencia

### 3.1 Hilos Verdes (Fibras) — Modelo M:N

- Planificador M:N: M fibras mapeadas a N hilos del SO.
- Pilas dinámicas de ~2 KB que crecen según necesidad.
- **Sin `async/await`:** No hay funciones de "distinto color". El runtime suspende/reanuda I/O automáticamente.
- Interrupciones cooperativas: punto de ceder paso (yield point) en cada operación de I/O.

### 3.2 Cambio de Contexto en FFI

Patrón `entersyscall` / `exitsyscall` (estilo Go):

- **Pre-Invocación FFI (`entersyscall`):** La fibra notifica al runtime. El planificador desvincula el `L` (procesador lógico) del hilo actual. El hilo queda dedicado a la llamada foránea.
- **Transferencia de Estado:** Un nuevo hilo del pool toma el `L`, permitiendo que otras fibras continúen.
- **Post-Invocación FFI (`exitsyscall`):** Al regresar, la fibra busca un `L` libre. Si no hay, se suspende en la cola global.

**Anotaciones de Atributos FFI:**
- `@ffi::direct`: Función C ultra-corta (<50ns), no bloqueante. Se ejecuta en el stack de la fibra.
- `@ffi::blocking`: Aplica desvinculación completa del hilo.

### 3.3 Consistencia de Memoria

- `val` (inmutable): Sin necesidad de barreras de memoria entre fibras.
- `var` (mutable): Solo una fibra a la vez. Para compartir: `transfer(var)` o `Atomic[T]`.

---

## 4. Interoperabilidad (FFI)

### 4.1 Estrategia Universal: C-ABI como Punto de Encuentro

| Lenguaje | Mecanismo | Complejidad | Impacto |
|:---------|:----------|:------------|:--------|
| **C** | Nativo directo: Carga de `.so`/`.dll` leyendo símbolos. | Muy Baja | Nulo (velocidad nativa). |
| **C++** | C-Wrapper: Capa `extern "C"` para evitar name mangling. | Media | Nulo. |
| **Python** | C-API (`libpython`): PyBuffer para acceder a NumPy/PyTorch en RAM sin copiar. | Media | Bajo (zero-copy). |
| **Julia** | C-API (`libjulia`): Motor de Julia en proceso ligero, paso por punteros. | Alta | Bajo (tras JIT inicial). |

### 4.2 FFI Zero-Copy con Python

```
from python import numpy as np
let a = np.array([1.0, 2.0, 3.0])  // Se obtiene puntero C directo
let resultado = a.map_native(fn(x) => x * 2.0)  // Operación SIMD sobre memoria NumPy
```

### 4.3 Seguridad en FFI

**Barreras ABI Estrictas:**
- **Pánicos de Astra → C:** Funciones `extern "C"` envuelven en `catch_unwind`. Si panic → código de estado numérico o aborte seguro.
- **Excepciones de C++ → Astra:** Envoltura en `extern "C-unwind"` → `Result[T, FfiError]`.
- **Fallo de segmentación foráneo:** `sigaction` (POSIX) / Vectored Exception Handling (Windows) → Pánico de fibra aislado, sin derribar todo el proceso.

**Gestión de Referencias en FFI:**
- Anclas de alcance (`scope tethers`) e incrementos de referencia (`Py_INCREF`) durante la vida de la llamada.
- Pointer pinning para buffers que salen del alcance de Astra.

---

## 5. Sistema de Tipos

### 5.1 Tipado Fuerte e Inferido

- Inferencia estática agresiva (Hindley-Milner / Constraint-Based).
- Inferencia limitada al ámbito local; anotaciones requeridas en firmas públicas.
- Sin coerción silenciosa de tipos: `entero.to_float() + flotante`.

### 5.2 Unidades de Medida (Dimensional Types)

Verificación en tiempo de compilación con costo cero (borrado de tipos en compilación final).

```
type Meter = f64[1, 0, 0, 0, 0, 0, 0]
type Second = f64[0, 0, 1, 0, 0, 0, 0]
type Velocity = f64[1, 0, -1, 0, 0, 0, 0]

fn compute_velocity(dist: Meter, time: Second) -> Velocity {
    return dist / time  // Correcto: [1,0,0...] - [0,0,1...] = [1,0,-1...]
}

// Error de compilación:
// val fail: Meter = dist + time  // Incompatibilidad de vectores dimensionales
```

### 5.3 Opcionales y Nulos

- Sin `null`/`None` tradicional. Uso de opcionales explícitos: `let nombre: String? = None`.
- Desempaquetado seguro: `let valor = nombre ?? "Desconocido"`.

### 5.4 Manejo de Errores

- `Result<T, E>` y `Option<T>` (tipos algebraicos).
- Operador `?` para propagación rápida (estilo Rust).
- Sin excepciones tradicionales estilo Python/Java.

### 5.5 Traits / Interfaces (POO Simplificada)

- Composición sobre herencia.
- Estructuras (`struct`) + Traits (comportamiento).
- UFCS (Universal Function Call Syntax): `saludar(usuario)` equivale a `usuario.saludar()`.

---

## 6. Compilador

### 6.1 Pipeline Arquitectónico

```
┌────────────────────────┐
│   Código Fuente (.ast) │
└───────────┬────────────┘
            │
┌───────────▼────────────┐
│   Lexer & Parser       │  (Descenso recursivo a mano)
│   CST → AST            │
└───────────┬────────────┘
            │
┌───────────▼────────────┐
│   Type Checker         │  (Hindley-Milner + Verificación Dimensional)
└───────────┬────────────┘
            │
┌───────────▼────────────┐
│   AIR (Astra IR)       │  (Representación intermedia unificada)
│   - Inyección ARC      │
│   - Yield points       │
│   - Borrado de tipos   │
└───────────┬────────────┘
            │
┌────────────────────┴────────────────────┐
│                                         │
│  [Modo Dev: `astra run`]              │  [Modo Prod: `astra build --release`]
│                                         │
┌──────────▼──────────┐       ┌──────────▼──────────┐
│   Bytecode / VM     │       │   Generador C / LLVM│
│   (TCC/Cranelift)   │       │   (Monomorfización)  │
└──────────┬──────────┘       └──────────┬──────────┘
           │                             │
┌──────────▼──────────┐       ┌──────────▼──────────┐
│  Arranque < 10ms    │       │  Executable Estático │
└─────────────────────┘       └─────────────────────┘
```

### 6.2 Backend Dual

| Modo | Backend | Descripción |
|:-----|:--------|:------------|
| **Desarrollo** | Bytecode VM + TCC/Cranelift | Compilación en milisegundos, <100 MB RAM, arranque <10ms. |
| **Producción** | AOT vía C99/LLVM | Monomorfización completa, inlining, optimizaciones SIMD. |

### 6.3 Estabilidad de ABI

- **Modo Desarrollo:** Protocol Witness Tables (PWT) para despacho dinámico (sin monomorfización).
- **Modo Producción:** Monomorfización codiciosa + Devirtualización en backend LLVM.
- **Bibliotecas dinámicas:** ABI estable basado en PWT para compatibilidad inter-versión.

### 6.4 AIR (Astra Intermediate Representation)

Representación intermedia unificada consumible por ambos backends. Se insertan automáticamente:
- Incrementos/decrementos de referencia (ARC/ORC).
- Yield points para el planificador de fibras.
- Borrado final de tipos de unidades de medida.

---

## 7. Toolchain

### 7.1 Ejecutable Único `astra`

```
astra run script.ast        # Modo interpretado/JIT (arranque <10ms)
astra build --release       # Genera binario estático optimizado
astra fmt                   # Formateador de código oficial
astra test                  # Suite de pruebas nativa
astra pkg                   # Gestor de paquetes y dependencias
```

### 7.2 Comparativa de Recursos

| Aspecto | Compiladores Tradicionales (Rust/C++) | Astra (Ultraligero) |
|:--------|:--------------------------------------|:---------------------|
| RAM al compilar | 2 GB a 8+ GB | < 100 MB |
| Tamaño Toolchain | > 2 GB | < 30 MB (binario único) |
| Tiempo de arranque (Dev) | Varios segundos/minutos | < 10 milisegundos |
| Requisitos | Multi-núcleo moderno | Cualquier x86/ARM básico |

---

## 8. Sintaxis Base (Borrador)

### 8.1 Variables y Mutabilidad

```
let x = 10           # Inmutable (por defecto)
mut y = 10           # Mutable
val z = "constante"  # Inmutable profundo (explícito)
```

### 8.2 Funciones

```
fn sumar(a: Int, b: Int) -> Int {
    return a + b
}

# Concisión
fn cuadrado(x: Int) -> Int = x * x
```

### 8.3 Estructuras y Traits

```
struct Particula {
    posicion: Metros
    velocidad: Velocidad
}

trait Movible {
    fn mover(&mut self, dt: Segundos)
}

impl Movible for Particula {
    fn mover(&mut self, dt: Segundos) {
        self.posicion = self.posicion + (self.velocidad * dt)
    }
}

# UFCS: saludar(usuario) == usuario.saludar()
fn saludar(u: Usuario) {
    println("Hola, {u.nombre}")
}
```

### 8.4 Concurrencia

```
# Código visualmente síncrono, ejecutado de forma asíncrona por el runtime
fn obtener_usuario(id: Int) -> Result<Usuario, Error> {
    let res = http.get("https://api.com/users/{id}")?  // Suspende fibra automáticamente
    return Ok(res.json::<Usuario>())
}

# Spawn de fibras
spawn fn tarea_larga() {
    // Se ejecuta en una fibra del planificador M:N
}
```

### 8.5 Bloque unsafe

```
fn acceso_directo(ptr: Ptr<Float>) {
    unsafe {
        ptr.write(3.14159)
    }
}
```

---

## 9. Casos de Uso

| Caso | Modo de Ejecución | Características Clave |
|:-----|:-------------------|:----------------------|
| Scripts rápidos / CLI | Interpretado (Bytecode) | Arranque < 10ms, tipado inferido. |
| Ciencia de Datos / ML | JIT / AOT Híbrido | Unidades numéricas, vectores nativos, SIMD automático. |
| Servidores / Microservicios | Compilado (Nativo) | Fibras para I/O, consumo mínimo, binario único. |
| Sistemas / Bajo Nivel | Compilado (`--release`) | Bloques unsafe, punteros, FFI directo con C. |

---

## 10. Sistema de Módulos

### 10.1 Diseño: File-as-Module

Cada archivo `.astra` es un módulo. Sin declaraciones `mod` adicionales.

```
// geometry/vector.astra
pub struct Vec2 {
    pub x: f64
    pub y: f64
}

pub fn add(a: Vec2, b: Vec2) -> Vec2 {
    Vec2 { x: a.x + b.x, y: a.y + b.y }
}

fn internal_helper() -> void {  // privado por defecto
    // ...
}
```

### 10.2 Visibilidad

- **Privado por defecto:** Todo es privado al archivo.
- **`pub`:** Exporta funciones, structs, enums, traits a otros módulos.
- **Dos niveles:** `pub` y privado (sin `pub(crate)` ni `fileprivate`).

```
pub struct Vec2 {
    pub x: f64    // visible externamente
    y: f64        // privado
}
```

### 10.3 Sintaxis de Imports

```
import vector                          // importa archivo hermano
import geometry.mesh                   // sub-módulo
import geometry.mesh as gm             // alias
from geometry.vector import Vec2, add  // importación selectiva
import @/utils/logger                  // raíz del proyecto
import std/io                          // biblioteca estándar
```

### 10.4 Resolución de Rutas

1. **Relativa:** `import mesh` → busca `mesh.astra` en el mismo directorio.
2. **Sub-ruta:** `import geometry.mesh` → busca `geometry/mesh.astra`.
3. **Absoluta desde raíz:** `import @/utils/logger` → desde el directorio de `astra.toml`.
4. **Estándar:** `import std/io` → siempre resuelve a la stdlib.

### 10.5 Re-exports

```
// utils.astra
pub use @/internal/logger
pub use @/internal/config

// Consumidor:
import utils
utils.Logger.info("hello")  // re-exportado desde internal/logger
```

### 10.6 Prohibición de Dependencias Circulares

El compilador detecta ciclos en tiempo de compilación y reporta error con sugerencias de resolución (fusionar módulos o extraer tipos compartidos).

### 10.7 Manifest del Proyecto: `astra.toml`

```toml
[package]
name = "my-project"
version = "0.1.0"

[dependencies]
http = { version = "^1.0", registry = "astra-registry" }
json = "^2.0"

[dev-dependencies]
testing = "^1.0"

[ffi]
headers = ["include/"]
link = ["z", "ssl"]
```

---

## 11. Enums Algebraicos y Pattern Matching

### 11.1 Enums con Datos Asociados (Sum Types)

```
# Enum simple
enum Color {
    Rojo
    Verde
    Azul
}

# Enum con datos (ADT completo)
enum Forma {
    Circulo(Float)
    Rectangulo(ancho: Float, alto: Float)
    Triangulo(a: Float, b: Float, c: Float)
}

# Enum mixto
enum Mensaje {
    Reniciar
    Mover(x: Int, y: Int)
    Escribir(String)
    CambiarColor(Color)
}

# Tipo recursivo (requiere Box<T>)
enum Arbol<T> {
    Hoja
    Nodo(valor: T, izq: Box<Arbol<T>>, der: Box<Arbol<T>>)
}
```

### 11.2 Pattern Matching

```
# match como expresión
fn area(forma: Forma) -> Float {
    match forma {
        Circulo(r) => Float.PI * r * r
        Rectangulo(ancho, alto) => ancho * alto
        Triangulo(a, b, c) =>
            let s = (a + b + c) / 2.0
            sqrt(s * (s-a) * (s-b) * (s-c))
    }
}

# Guards
fn clasificar(forma: Forma) -> String {
    match forma {
        Circulo(r) if r < 0.0 => "Radio negativo"
        Circulo(r) if r > 100.0 => "Círculo grande"
        Circulo(_) => "Círculo normal"
        Rectangulo(w, h) if w == h => "Cuadrado"
        _ => "Otro"
    }
}

# Or-patterns
fn es_primario(color: Color) -> Bool {
    match color {
        Rojo | Verde | Azul => true
        _ => false
    }
}

# Patrones anidados
match mensaje {
    CambiarColor(Rojo) => "Cambio a rojo"
    Mover(x, y) if x < 0 => "Movimiento negativo"
    _ => "Otro"
}

# Bindings con @
match n {
    n @ 0..=9 => "Dígito: {n}"
    n @ 10..=99 => "Dos dígitos: {n}"
    _ => "Otro"
}
```

### 11.3 Exhaustiveness Checking

- **Compile error por defecto** (como Rust).
- `@non_exhaustive` para enums de bibliotecas que requieren wildcard.

### 11.4 Option y Result (Built-in)

```
# Option<T>
enum Option<T> { Some(T) None }

# Result<T, E>
enum Result<T, E> { Ok(T) Err(E) }

# Propagación con ?
fn procesar(datos: Array<Int>) -> Result<Int, Error> {
    let primero = datos.get(0)?
    let segundo = datos.get(1)?
    return Ok(primero + segundo)
}

# Combinadores
let r = dividir(10.0, 3.0)
    .map(|r| r * 2.0)
    .filter(|r| *r > 5.0)
    .unwrap_or(0.0)
```

### 11.5 Integración con ARC/ORC

Cada campo de cada variante se gestiona con ARC/ORC independientemente. El enum en sí es un valor en stack (o `Box<Enum>` en heap si es grande). El pattern matching extrae los campos sin copiar (borrowing).

---

## 12. Metaprogramación en Tiempo de Compilación (`comptime`)

### 12.1 Filosofía: Zig-style Comptime

Un solo lenguaje para código runtime y compile-time. Sin macros separadas, sin manipulación de AST, sin proc macros.

### 12.2 Parámetros comptime

```
fn max(comptime T: type, a: T, b: T) -> T:
    return if a > b: a else: b

val x = max(Int, 10, 20)       # x: Int = 20
val names = repeat(3, "hello") # names: [3]String
```

### 12.3 Bloques comptime

```
val greeting = comptime:
    var msg = "hello"
    msg = msg.to_upper()
    msg
# greeting: "HELLO" (constante embebida en binario)
```

### 12.4 Reflexión en Compile-time

```
fn type_name(comptime T: type) -> String:
    return @type_name(T)

fn field_count(comptime T: type) -> Int:
    return @field_count(T)

comptime:
    assert(type_name(Int) == "Int")
    assert(field_count(User) == 3)
```

### 12.5 Type Functions

```
fn Pair(comptime T: type, comptime U: type) -> type:
    return struct:
        first: T
        second: U

val p = Pair(Int, String)(first: 42, second: "hello")
```

### 12.6 Restricciones

- Sin I/O de archivos en compile-time.
- Sin heap allocation (usa arena del compilador).
- Sin inline assembly.
- Sin llamadas a funciones FFI.
- Branch quota: 1000 backward branches por defecto.

### 12.7 Derive-Like Mechanism

```
struct User:
    @deriving(Debug, Serialize, Deserialize)
    name: String
    age: Int
    email: String
```

---

## 13. Serialización en Compile-Time

### 13.1 Derivación de Serialización

```
@serialize
struct Point {
    x: i32,
    y: i32,
}

val json = point.to_json()?
let restored = Point::from_json(json)?
```

### 13.2 Atributos de Personalización

```
@serialize
struct UserProfile {
    @rename("user_name")
    name: String,

    @skip_if_none
    email: Option<String>,

    @default
    age: u32,

    @flatten
    metadata: HashMap<String, String>,
}
```

### 13.3 Soporte de Formatos

- JSON, TOML, Protobuf, MessagePack.
- Soporte de schema evolution con `@since(N)` y `@deprecated(N)`.
- Deserialización zero-allocation: `from_json_arena()` y `from_json_zero_copy()`.

---

## 14. Asignadores de Memoria Personalizados

### 14.1 Allocator Trait

```
trait Allocator {
    fn alloc(self: *Self, layout: Layout) ?*u8
    fn free(self: *Self, ptr: *u8, layout: Layout) void
    fn resize(self: *Self, ptr: *u8, old_layout: Layout, new_len: usize) ?*u8
    fn clone(self: Self) Self
}
```

### 14.2 Allocators Incorporados

| Allocator | Estrategia | Uso |
|:----------|:-----------|:----|
| `GlobalAllocator` | malloc/free | Default |
| `ArenaAllocator` | Bump + reset masivo | Fases de request, queries |
| `FixedBufferAllocator` | Buffer estático | Embedded, sin heap |
| `PoolAllocator` | Bloques fijos O(1) | Muchos objetos del mismo tamaño |
| `BumpAllocator` | Incremento de puntero | Game frames, compilers |

### 14.3 Integración con ARC/ORC

```
# Layout co-allocado: [refcount | weak_count | allocator | T]
let arena = ArenaAllocator::new(std.heap.page_allocator)
let shared = Arc::new_in(MyStruct { ... }, arena.allocator())
```

---

## 15. Soporte WASM

### 15.1 Estrategia de Backend

| Modo | Estrategia | Rationale |
|:-----|:-----------|:----------|
| Dev | Binaryen | Compilación sub-segundo, calidad razonable |
| Prod | LLVM WASM backend | Optimización agresiva, monomorfización |

### 15.2 Pipeline

```
AIR → Type Erasure → ARC/ORC Lowering → Fiber Runtime → WASM Code Gen → Module Assembly
```

### 15.3 Restricciones WASM

- ARC overhead: 5-15% en código ref-heavy.
- Bounds checking WASM: mitigation via bulk memory ops.
- JS↔WASM boundary crossing: minimize crossings.

---

## 16. Generación de Kernels GPU

### 16.1 Pipeline

```
Astra Source → Parse + Type Check → AIR → GPU Code Gen → Host Code
```

### 16.2 Backends

| Fase | Backend | Uso |
|:-----|:--------|:----|
| Fase 1 | OpenCL C + SYCL | Portabilidad máxima |
| Fase 2 | LLVM NVPTX (NVIDIA) | Rendimiento nativo |
| Fase 2 | LLVM AMDGPU (AMD) | Rendimiento nativo |
| Fase 2 | SPIR-V (Vulkan) | Compute shaders |

### 16.3 Extensiones de Tipo

```
@kernel @grid(256, 1, 1)
fn vec_add(a: @device_mem [f64], b: @device_mem [f64], out: @device_mem [f64], n: Int) {
    let idx = @thread_id.x
    if idx < n { out[idx] = a[idx] + b[idx] }
}
```

---

## 17. REPL y Jupyter

### 17.1 Estrategia Recomendada

- **REPL:** Basado en la VM de bytecode existente (arranque <10ms).
- **Jupyter Kernel:** Protocolo ZMQ con canales Shell/Control/IOPub/Stdin/Heartbeat.

### 17.2 Persistencia de Estado

- Estado ARC-managed persiste entre inputs.
- Sesiones guardables: `astra repl --save-session my_session.ast`.
- Solo datos puros serializables; closures/handles se re-ejecutan.

---

## 18. LSP (Language Server Protocol)

### 18.1 Arquitectura

```
LSP Server
├── Shared Analysis Layer (Parser, Type Checker, Name Resolution)
├── VM Backend (dev diagnostics)
└── LLVM Backend (prod diagnostics)
```

### 18.2 Características Clave

- **Parser nunca falla:** Produce `(CST, Vec<SyntaxError>)` siempre.
- **Incremental parsing:** Solo re-parsea regiones modificadas.
- **Error recovery:** Inserta tokens faltantes, salta tokens inesperados.
- **Backend-aware diagnostics:** Advertencias específicas por backend.

---

## 19. Análisis Comparativo

### 19.1 Matriz de Comparación

| Aspecto | **Astra** | **Mojo** | **Nim** | **Zig** | **Julia** | **Vale** | **Swift** |
|:--------|:----------|:---------|:--------|:--------|:----------|:---------|:----------|
| Memoria | ARC/ORC | Ownership | ARC/ORC | Manual | Tracing GC | GenRefs | ARC |
| Concurrencia | Green Threads | GPU+OS | Async/Await | Async(Io) | Tasks | None | Async/Await |
| Green Threads | **Sí** | No | No | Experimental | No | No | No |
| FFI Safety | Safe | Safe | Unsafe | Unsafe | Safe | Fearless | Safe |
| Zero-Copy FFI | **Sí (Py+C)** | Python | Limitado | C | C | Limitado | C |
| Python FFI | **Sí** | Sí(100%) | Limitado | No | PyCall | No | Limitado |
| Backend | VM+LLVM | MLIR→LLVM | C/C++ | LLVM+Self | LLVM JIT+AOT | LLVM | LLVM(SIL) |
| Arranque Dev | **<10ms** | Rápido | Rápido | Rápido | Lento(JIT) | Rápido | Rápido |
| Units of Measure | **Sí** | No | No | No | No | No | No |

### 19.2 Diferenciadores Únicos de Astra

1. **Green Threads sin async/await** — Único lenguaje con M:N scheduling y código síncrono.
2. **Dual Backend** — <10ms dev + AOT producción.
3. **ARC/ORC atómico** — Thread-safe sin borrow checker.
4. **Zero-Copy Python FFI** — Acceso directo a NumPy/PyTorch.
5. **Unidades de Medida** — Análisis dimensional en compile-time.
6. **Toolchain unificado** — Binario único <30MB vs 2GB+ de Rust/C++.

### 19.3 Trade-offs

| Aspecto | Trade-off |
|:--------|:----------|
| Rendimiento raw | ARC overhead vs Zig manual o Mojo ownership |
| Control de bajo nivel | Menos que Zig o Mojo |
| Madurez | Pre-alpha vs competidores estables |
| Ecosistema | Sin paquetes existentes vs Julia/Python/Swift |
| GPU | No es first-class como Mojo o Julia |

---

## 20. Arquitectura del Compilador (Detalle)

### 20.1 Pipeline Multi-IR

```
Source → Lexer → Parser → AST → Type Checker → AIR → Backend
                                                    │
                                          ┌─────────┴─────────┐
                                          │                   │
                                    VM (dev mode)      LLVM (prod mode)
```

Cada Representación Intermedia tiene un propósito específico:
- **AST:** Representación cercana al código fuente. Para herramientas IDE (LSP).
- **AIR:** Representación unificada para análisis y transformación. Donde se insertan ARC, yield points, y type erasure.
- **Bytecode:** Para el backend de desarrollo (VM).
- **LLVM IR:** Para el backend de producción (optimizaciones de LLVM).

### 20.2 Componentes del Compilador

| Componente | Responsabilidad | Inspiración |
|:-----------|:----------------|:------------|
| **Lexer** | Tokenización, manejo de Unicode | Clang (recursive descent) |
| **Parser** | AST con error recovery, nunca falla | rust-analyzer (produces CST + errors) |
| **Name Resolver** | Resolución de nombres, visibilidad | Rust (two-phase resolution) |
| **Type Checker** | Inferencia Hindley-Milner, unificación | Rust + Julia (lattice-based) |
| **Comptime Evaluator** | Evaluación en compile-time | Zig (comptime blocks) |
| **AIR Generator** | Inyección ARC, yield points, type erasure | Rust (MIR builder) |
| **VM Backend** | Bytecode emission, execution | CPython (ceval loop) |
| **LLVM Backend** | AOT compilation, optimization | Rust (codegen_llvm) |
| **Diagnostics** | Error messages, suggestions | Rust (structured diagnostics) |
| **Incremental Engine** | Query-based memoization | Rust (Salsa framework) |

### 20.3 Query-Based Architecture

Cada paso del compilador es una query con memoización:
- La compilación incremental solo re-evalúa lo que cambió.
- El LSP puede responder en <100ms para la mayoría de operaciones.
- El dependency graph se construye automáticamente.

### 20.4 Backend Dual: Detalles

| Aspecto | VM Backend (Dev) | LLVM Backend (Prod) |
|:--------|:-----------------|:--------------------|
| Velocidad de compilación | <10ms | Segundos/Minutos |
| Velocidad de ejecución | 5-10x vs C | 1x vs C |
| RAM al compilar | <100 MB | 500MB-2GB |
| Optimizaciones | Ninguna | Full LLVM pipeline |
| Monomorfización | No (dynamic dispatch) | Sí (greedy) |
| Fibras | Interpretadas en VM | Compiladas a código nativo |

---

## 21. Runtime y Sistema de Ejecución

### 21.1 Arquitectura del Runtime

```
┌─────────────────────────────────────────────────┐
│                  Astra Runtime                   │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  ARC/ORC  │  │  Fibers  │  │  I/O System  │  │
│  │  Memory   │  │  M:N     │  │  Non-blocking│  │
│  │  Manager  │  │  Sched.  │  │  I/O         │  │
│  └──────────┘  └──────────┘  └──────────────┘  │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  FFI     │  │  Signal  │  │  Allocator   │  │
│  │  Bridge  │  │  Handler │  │  Interface   │  │
│  │  (C-ABI) │  │  (SIGSEGV│  │  (Custom)    │  │
│  └──────────┘  └──────────┘  └──────────────┘  │
└─────────────────────────────────────────────────┘
```

### 21.2 Planificador de Fibras (M:N Scheduler)

```
┌─────────────────────────────────────────┐
│          Fiber Scheduler (M:N)          │
│                                          │
│  M fibras ←→ N hilos del SO             │
│                                          │
│  Cola Local (por hilo):                 │
│  ┌────┬────┬────┬────┐                  │
│  │ F1 │ F2 │ F3 │ F4 │ ← work-stealing │
│  └────┴────┴────┴────┘                  │
│                                          │
│  Cola Global:                           │
│  ┌────┬────┬────┬────┐                  │
│  │ F5 │ F6 │ F7 │... │ ← fibras listas │
│  └────┴────┴────┴────┘                  │
│                                          │
│  Hilos del SO:                          │
│  ┌────┬────┬────┬────┐                  │
│  │ T1 │ T2 │ T3 │ T4 │ ← pool fijo    │
│  └────┴────┴────┴────┘                  │
└─────────────────────────────────────────┘
```

### 21.3 Sistema de Memoria

```
┌─────────────────────────────────────────┐
│          Memory Management              │
│                                          │
│  Alto Nivel (Por Defecto):              │
│  ┌──────────────────────────────┐       │
│  │ ARC (Atomic Reference Count) │       │
│  │ - Conteo atómico por fibra   │       │
│  │ - Liberación determinista     │       │
│  │ - Sin pausas STW             │       │
│  └──────────────────────────────┘       │
│  ┌──────────────────────────────┐       │
│  │ ORC (Cycle Collector)        │       │
│  │ - Trial Deletion (Bacon)     │       │
│  │ - Incremental, sin STW       │       │
│  │ - Coloración: P→G→B/W        │       │
│  └──────────────────────────────┘       │
│                                          │
│  Bajo Nivel (unsafe):                   │
│  ┌──────────────────────────────┐       │
│  │ Custom Allocators            │       │
│  │ - Arena, Pool, Bump, Fixed   │       │
│  │ - Integración con ARC/ORC    │       │
│  │ - Control total del dev      │       │
│  └──────────────────────────────┘       │
└─────────────────────────────────────────┘
```

### 21.4 Layout de Objetos en Memoria

```
Objeto ARC (Reference-Counted):
┌──────────┬──────────┬──────────────────┐
│ refcount │ weak_cnt │ object data...   │
│ (i64)    │ (i64)    │                  │
└──────────┴──────────┴──────────────────┘

Objeto ORC (Cycle-Detectable):
┌──────────┬──────────┬──────────┬──────┬──────────────────┐
│ refcount │ weak_cnt │ marked   │color │ object data...   │
│ (i64)    │ (i64)    │ (bool)   │(u8)  │                  │
└──────────┴──────────┴──────────┴──────┴──────────────────┘

String (UTF-8, Inmutable):
┌──────────┬──────────┬──────────────────┐
│ length   │ capacity │ bytes...         │
│ (usize)  │ (usize)  │                  │
└──────────┴──────────┴──────────────────┘

Array (Contiguo):
┌──────────┬──────────┬──────────────────┐
│ length   │ capacity │ elements...      │
│ (usize)  │ (usize)  │                  │
└──────────┴──────────┴──────────────────┘
```

---

## 22. Estrategia de Testing

### 22.1 Pirámide de Testing

```
                    /\
                   /  \
                  / Fuzz\          <- Long-running, find rare bugs
                 /--------\
                / Property  \       <- Test invariants across inputs
               /--------------\
              / Differential    \    <- Compare with other compilers
             /--------------------\
            / Regression/Conform.  \  <- Catch known bugs, spec compliance
           /------------------------\
          / Unit Tests               \ <- Test individual components
         /------------------------------\
```

### 22.2 Estructura de Tests

```
tests/
├── conformance/           # Language specification tests
│   ├── expressions/       # Expression evaluation
│   ├── statements/        # Control flow
│   ├── types/             # Type system
│   ├── modules/           # Module system
│   └── stdlib/            # Standard library
├── ui/                    # Error message tests
│   ├── compile_error/     # Expected compile errors
│   └── runtime_error/     # Expected runtime errors
├── codegen/               # Generated code checks
│   ├── assembly/          # Assembly output verification
│   └── optimization/      # Optimization effectiveness
├── incr/                  # Incremental compilation
├── cross/                 # Cross-compilation tests
├── property/              # Property-based tests
└── fuzz/                  # Fuzzing corpora
```

### 22.3 Estrategias de Testing

| Estrategia | Herramienta | Uso |
|:-----------|:------------|:----|
| **Unit Tests** | testing framework nativo | Cada componente del compilador |
| **Conformance** | Plum Hall style | Validar contra especificación |
| **Property-based** | QuickCheck/Proptest | Verificar invariantes |
| **Fuzzing** | AFL++/LibFuzzer | Encontrar bugs raros |
| **Differential** | Custom scripts | Comparar output entre backends |
| **Regression** | Issue-indexed tests | Bugs previamente encontrados |

### 22.4 Differential Testing

```bash
#!/bin/bash
# Comparar output entre optimizaciones
for file in corpus/*.astra; do
    ./astra -O0 "$file" -o out0 && ./out0 > out0.txt
    ./astra -O2 "$file" -o out2 && ./out2 > out2.txt
    if ! diff -q out0.txt out2.txt; then
        echo "MISCOMPILATION: $file"
    fi
done
```

---

## 23. Bootstrap y Cross-Compilation

### 23.1 Estrategia de Bootstrap

```
Fase 1: Seed Compiler (0-6 meses)
    Escrito en C/Rust → Compila subconjunto de Astra
    ↓
Fase 2: Self-Hosting (6-12 meses)
    Astra compiler v0.1 compilado por seed → Compila más features
    ↓
Fase 3: Full Self-Hosting (12+ meses)
    Astra compiler v0.N compila v0.(N+1)
    ↓
Fase 4: Verified Bootstrap
    Binary reproducibility + diverse double-compilation
```

### 23.2 Cross-Compilation

**Target Triple:**
```
<arch>-<vendor>-<os>-<env>

Ejemplos:
x86_64-unknown-linux-gnu
aarch64-apple-darwin
x86_64-pc-windows-msvc
wasm32-wasi
```

**Uso:**
```bash
astra build --target aarch64-unknown-linux-musl
astra build --target x86_64-pc-windows-msvc
astra build --target wasm32-wasi
```

### 23.3 Distribución del Toolchain

| Componente | Tamaño | Descripción |
|:-----------|:-------|:------------|
| `astra` (binario) | ~20 MB | Compilador + runtime + stdlib |
| `astra-docs` | ~5 MB | Documentación offline |
| `astra-stdlib` | ~2 MB | Biblioteca estándar fuente |
| **Total** | **~27 MB** | vs 2GB+ de Rust/C++ |

---

## 24. Cross-Platform Architecture

### 24.1 La Realidad: No Existe un Binario Universal

Un binario nativo es un contrato entre 4 capas. Romper cualquiera hace el binario no portable:

| Capa | Linux | Windows | macOS |
|:-----|:------|:--------|:------|
| Formato de ejecutable | ELF (`\x7fELF`) | PE (`MZ`) | Mach-O (`\xFE\xED\xFA\xCE`) |
| Syscalls | `syscall`/`int 0x80` | `NtWriteFile` (ntdll) | `syscall` |
| ABI (x86-64) | System V: `RDI,RSI,RDX,RCX` | Microsoft: `RCX,RDX,R8,R9` | System V: `RDI,RSI,RDX,RCX` |
| C Runtime | glibc/musl | msvcrt.dll | libSystem.B.dylib |

**Conclusión:** Un solo binario nativo para Linux+Windows+macOS **no es posible**. Pero un **solo comando de compilación** que produzca binarios para todas las plataformas **sí es posible**.

### 24.2 Estrategia Recomendada: Cross-Compiler por Diseño

```
                    ┌─────────────────────────────┐
                    │    Código Fuente Astra       │
                    └──────────────┬──────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │    Compiler (cross-compiler) │
                    │    --target=<triple>         │
                    └──────────────┬──────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
    ┌─────────▼─────────┐ ┌───────▼───────┐ ┌─────────▼─────────┐
    │   ELF (Linux)     │ │  PE (Windows) │ │  Mach-O (macOS)   │
    │   x86_64/arm64    │ │  x86_64       │ │  arm64/x86_64     │
    │   musl static     │ │  MSVC dynamic │ │  Universal fat    │
    └───────────────────┘ └───────────────┘ └───────────────────┘
```

**Inspiración:** Go (2 env vars para cross-compile) + Zig (bundled toolchain completo).

### 24.3 Target Triples

```
<arch>-<vendor>-<os>-<env>

Plataformas soportadas:
  x86_64-unknown-linux-musl        # Linux x86_64 estático (recomendado)
  x86_64-unknown-linux-gnu         # Linux x86_64 dinámico
  aarch64-unknown-linux-musl       # Linux ARM64 estático
  aarch64-unknown-linux-android21  # Android ARM64 (API 21+)
  x86_64-pc-windows-msvc           # Windows x86_64 (MSVC)
  aarch64-apple-darwin             # macOS Apple Silicon
  x86_64-apple-darwin              # macOS Intel
  aarch64-apple-ios17              # iOS ARM64
  aarch64-apple-xros1.0           # visionOS ARM64
  wasm32-wasi                      # WebAssembly
```

### 24.4 Compilación para Todas las Plataformas

```bash
# Un solo comando, binarios separados
astra build --target=x86_64-unknown-linux-musl -o bin/linux-x64
astra build --target=aarch64-apple-darwin -o bin/macos-arm64
astra build --target=x86_64-pc-windows-msvc -o bin/windows-x64.exe

# O múltiples targets simultáneamente
astra build --target=all -o bin/

# Produce:
# bin/linux-x64/myapp       (ELF, estático, ~2MB)
# bin/macos-arm64/myapp     (Mach-O, universal, ~2MB)
# bin/windows-x64/myapp.exe (PE, dinámico, ~2MB)
```

### 24.5 Formato Universal para Apple (Fat Binaries)

```
┌─────────────────────────────┐
│ fat_header                  │
│   magic: 0xCAFEBABE         │
│   nfat_arch: 2              │
├─────────────────────────────┤
│ fat_arch[0]                 │
│   cputype: X86_64           │
│   offset, size, align       │
├─────────────────────────────┤
│ fat_arch[1]                 │
│   cputype: ARM64            │
│   offset, size, align       │
├─────────────────────────────┤
│ Mach-O (x86_64)             │
├─────────────────────────────┤
│ Mach-O (ARM64)              │
└─────────────────────────────┘
```

```bash
# Astra crea universal binaries automáticamente para Apple
astra build --target=universal-apple-darwin
# Internamente: compila para arm64 + x86_64, luego usa lipo para combinar
```

### 24.6 WASM como Target Secundario

WASM es útil para plugins, sandboxing, y deployment en browser. No reemplaza binarios nativos.

```bash
astra build --target=wasm32-wasi -o plugin.wasm
# Requiere runtime WASM en el host (Wasmtime/Wasmer)
# Overhead: 10-30% vs nativo
```

### 24.7 Binarios Estáticos con musl

Linux es la plataforma donde los binarios estáticos funcionan mejor:

```
Binario Astra (musl static):
┌─────────────────────────────┐
│ ELF Header                  │
│ .text (código Astra)        │
│ .rodata (strings, constantes)│
│ .data (globals)             │
│ musl libc (estáticamente    │
│   linkada, ~200KB)          │
│ Astra Runtime (ARC, fibers) │
└─────────────────────────────┘
```

**Ventajas:**
- Un solo binario funciona en CUALQUIER distribución Linux
- Sin dependencias de glibc version
- Sin dependencias del sistema
- Funciona en containers Docker (imagen `scratch`)

---

## 25. Platform Abstraction Layer

### 25.1 Arquitectura en 3 Capas

```
┌─────────────────────────────────────────────┐
│           User Code (Astra)                  │
│  fs.open("/path")  net.connect("host:port")  │
├─────────────────────────────────────────────┤
│        Public API (cross-platform)           │
│  fs.zig  net.zig  thread.zig  process.zig   │
├─────────────────────────────────────────────┤
│        POSIX Layer (abstraction)             │
│  posix.zig — traduce errores, unifica API   │
├─────────────────────────────────────────────┤
│     Platform Implementations (private)       │
│  sys/linux/*.zig  sys/darwin/*.zig          │
│  sys/windows/*.zig  sys/android/*.zig       │
└─────────────────────────────────────────────┘
```

### 25.2 Compile-Time Platform Dispatch

Zero-cost abstraction: el compilador selecciona la implementación correcta en comptime.

```astra
pub fn getCurrentThreadId() -> Platform.ThreadId {
    return switch (builtin.os) {
        .linux   => linux.gettid(),
        .macos   => darwin.pthread_threadid_np(),
        .windows => windows.GetCurrentThreadId(),
        .android => android.gettid(),
    };
}
```

### 25.3 Estructura del Standard Library

```
astra-stdlib/src/
├── core/                    # Independiente de plataforma
│   ├── math.astra
│   ├── string.astra
│   ├── collections.astra
│   └── option.astra
│
├── sys/                     # Implementaciones específicas (privado)
│   ├── linux/
│   │   ├── fs.zig           # epoll, /proc/self/exe
│   │   ├── thread.zig       # futex
│   │   ├── net.zig          # epoll, io_uring
│   │   └── process.zig      # clone, waitid
│   ├── darwin/
│   │   ├── fs.zig           # kqueue, NSBundle
│   │   ├── thread.zig       # pthreads
│   │   ├── net.zig          # kqueue
│   │   └── process.zig      # posix_spawn
│   ├── windows/
│   │   ├── fs.zig           # Win32 APIs, IOCP
│   │   ├── thread.zig       # Windows threads, SRWLock
│   │   ├── net.zig          # IOCP, Winsock
│   │   └── process.zig      # CreateProcess
│   └── android/
│       ├── fs.zig           # Bionic libc specifics
│       ├── thread.zig
│       ├── net.zig
│       └── process.zig
│
├── posix.zig                # Capa POSIX unificada
│   # Traduce errno → errores Astra
│   # Unifica: socket, bind, read, write, close, fork, exec
│
├── fs.zig                   # API pública de filesystem
├── net.zig                  # API pública de red
├── thread.zig               # API pública de threading
├── process.zig              # API pública de procesos
├── dynlib.zig               # Carga dinámica de librerías
└── io.zig                   # Async I/O (epoll/kqueue/IOCP)
```

### 25.4 Mapeo de APIs por Plataforma

| Operación | Linux | macOS | Windows | Android |
|:----------|:------|:------|:--------|:--------|
| Async I/O | epoll / io_uring | kqueue | IOCP | epoll |
| Threads | pthreads | pthreads | Windows threads | pthreads (Bionic) |
| Señales | sigaction | sigaction | Console ctrl events | sigaction |
| Dinámica | dlopen/dlsym | dlopen/dlsym | LoadLibrary | dlopen (Bionic) |
| Procesos | fork+exec / posix_spawn | fork+exec | CreateProcess | fork+exec |
| DNS | getaddrinfo | getaddrinfo | GetAddrInfoW | getaddrinfo |
| Permisos | mode bits | mode bits | ACLs | mode bits |
| Paths | `/` separator | `/` separator | `\` or `/` | `/` separator |

### 25.5 Errores Unificados

```astra
// Todas las traducciones de errores ocurren en la capa POSIX
pub fn bind(sock: Socket, addr: *const Sockaddr, len: u32) !void {
    const rc = if (builtin.os == .windows)
        windows.ws2_32.bind(sock.handle, addr, len)
    else
        posix.system.bind(sock.handle, addr, len);

    if (rc == error) return error.AddressInUse; // error unificado
}
```

---

## 26. Apple Ecosystem

### 26.1 Plataformas Apple Soportadas

| Plataforma | Framework | Target Triple | Notas |
|:-----------|:----------|:--------------|:------|
| macOS | Cocoa (AppKit) | `aarch64-apple-darwin` | Universal binary (arm64+x86_64) |
| iOS | UIKit | `aarch64-apple-ios17` | App bundles, code signing |
| visionOS | RealityKit | `aarch64-apple-xros1.0` | ECS, eye/hand tracking |
| watchOS | WatchKit | `armv7k-apple-watchos` | Extremadamente limitado |

### 26.2 Interoperabilidad con Swift

```
Astra → C ABI → Swift Module Bridge → Swift/Objective-C
```

1. Astra expone funciones via C ABI (`extern "C"`)
2. Genera un bridging header automáticamente
3. Swift importa el módulo y llama las funciones
4. Para frameworks Apple: Astra llama C-API del framework

### 26.3 Metal GPU

```astra
// Astra compila kernels GPU a Metal Shading Language (MSL)
@kernel
fn matrix_multiply(a: Matrix, b: Matrix) -> Matrix {
    // Astra → MSL → Metal Library
    // Unified memory en Apple Silicon = zero-copy
}
```

### 26.4 Universal Binary para macOS

```bash
astra build --target=universal-apple-darwin
# Internamente:
# 1. Compila para aarch64-apple-darwin → arm64.o
# 2. Compila para x86_64-apple-darwin → x86_64.o
# 3. lipo -create arm64.o x86_64.o -output universal
```

### 26.5 Consideraciones Apple Silicon

- **Unified Memory:** CPU y GPU comparten memoria → perfecto para zero-copy FFI
- **P-cores/E-cores:** El scheduler de fibras debe awareness de eficiencia
- **AMX:** Operaciones matriciales via Accelerate framework
- **NEON:** SIMD para vectorización

---

## 27. Android Support

### 27.1 Target Triple

```
aarch64-unknown-linux-android21    # ARM64, API level 21+
armv7a-unknown-linux-android21     # ARM32 legacy
x86_64-unknown-linux-android21     # Emuladores
```

### 27.2 Restricciones Críticas

| Restricción | Detalle |
|:------------|:--------|
| **No binarios estáticos** | Bionic requiere linking dinámico |
| **JNI es la única vía de interop** | Astra debe producir `.so` libraries |
| **Bionic ≠ glibc** | Sin System V IPC, allocator diferente |
| **arm64-v8a obligatorio** | Google Play requiere ARM64 desde Ago 2023 |
| **NEON obligatorio** | SIMD siempre disponible en ARM64 |

### 27.3 Integración con Android

```bash
# Compilar library para Android
astra build --target=aarch64-unknown-linux-android21 --shared -o libapp.so
# Produce: libapp.so (cargable via System.loadLibrary())
```

### 27.4 JNI Bridge

```astra
// Astra genera JNI bridge automáticamente
@jni
fn native_init() -> i32 {
    // Llamado desde Java: System.loadLibrary("app")
    // JNI critical: @CriticalNative para 25ns overhead
}

@jni
fn native_process(buffer: *const u8, len: usize) -> i32 {
    // Acceso directo a memoria Java via GetPrimitiveArrayCritical
}
```

### 27.5 Optimizaciones ARM

- **NEON:** 3-4x speedup para SIMD (FFT, matrix multiply)
- **Dot product (ARMv8.2+):** `vdotq_s32` para int8 GEMM (ML workloads)
- **Function multi-versioning:** `ifunc` para detección de CPU en runtime

---

## 28. ABI Stability

### 28.1 C ABI como Lingua Franca

```
┌─────────────────────────────────────────────┐
│         ABI Stability Tiers                  │
│                                              │
│  Tier 0: C FFI API                           │
│  - Estable para siempre                      │
│  - Nunca rompe compatibilidad                │
│  - Para interoperabilidad con otros lenguajes│
│                                              │
│  Tier 1: Standard Library                    │
│  - Estable por versión mayor                 │
│  - Puede agregar features en menores         │
│                                              │
│  Tier 2: Internal ABI (Astra→Astra)          │
│  - Puede cambiar entre versiones             │
│  - Requiere recompilación                    │
│                                              │
│  Tier 3: Compiler Internals                  │
│  - Inestable, puede cambiar任何时候          │
│  - No para consumo externo                   │
└─────────────────────────────────────────────┘
```

### 28.2 Layout de Objetos (Estable)

```
Objeto ARC (estable, no cambia):
┌──────────┬──────────┬──────────────────┐
│ refcount │ weak_cnt │ object data...   │
│ (i64)    │ (i64)    │                  │
└──────────┴──────────┴──────────────────┘

String (estable):
┌──────────┬──────────┬──────────────────┐
│ length   │ capacity │ bytes (UTF-8)    │
│ (usize)  │ (usize)  │                  │
└──────────┴──────────┴──────────────────┘

Array (estable):
┌──────────┬──────────┬──────────────────┐
│ length   │ capacity │ elements         │
│ (usize)  │ (usize)  │                  │
└──────────┴──────────┴──────────────────┘
```

### 28.3 Symbol Visibility

```bash
# Por defecto: todos los símbolos son privados
# Exportar explícitamente:
@export
fn my_public_function() -> void { ... }

# En Linux: version script
# { global: my_public_function; local: *; };
# En macOS: -exported_symbols_list
# En Windows: .def file o __declspec(dllexport)
```

### 28.4 Shared Libraries

| Plataforma | Extensión | Naming | Versioning |
|:-----------|:----------|:-------|:-----------|
| Linux | `.so` | `libfoo.so.1.2.3` | SONAME + symlink chain |
| macOS | `.dylib` | `libfoo.1.2.3.dylib` | install_name + @rpath |
| Windows | `.dll` | `foo.dll` | Sin versioning automático |

---

## 29. Error Handling

### 29.1 Filosofía

> **Panic para bugs de programación. Result para fallos esperados.**

No hay excepciones. Los errores son datos que se retornan, no flujo de control invisible.

### 29.2 Tipos Fundamentales (Built-in)

```astra
enum Result<T, E> {
    Ok(T),
    Err(E),
}

enum Option<T> {
    Some(T),
    None,
}
```

### 29.3 Propagación con `?`

```astra
fn read_config(path: &str) -> Result<Config, AppError> {
    let content = read_file(path)?;           // auto-convert FileError → AppError
    let config = parse_toml(content)?;        // auto-convert ParseError → AppError
    Ok(config)
}

// Con contexto
fn read_config(path: &str) -> Result<Config, AppError> {
    let content = read_file(path)
        .context("reading config file")?;     // wraps error con contexto
    let config = parse_toml(content)
        .context("parsing config")?;
    Ok(config)
}
```

### 29.4 Panic/Recover

```astra
panic!("unreachable: value was {}", x);      // crash (bugs de programación)
assert(x > 0, "x must be positive");         // debug-only assertion
unreachable!();                               // marca código imposible

// Recover en boundaries de fibras
fn run_task() {
    spawn_fiber(|| {
        recover {
            do_work();
        } on_panic |msg, backtrace| {
            log.error("Task panicked", message: msg);
            // La fibra muere, el programa continúa
        }
    });
}
```

### 29.5 errdefer (de Zig)

```astra
fn process_order(order: Order) -> Result<Receipt, OrderError> {
    let resource = acquire_resource(order.id)?;
    errdefer resource.release();              // solo en error

    let payment = charge_payment(&order)?;
    errdefer refund_payment(payment.id);      // solo en error

    let receipt = confirm_order(order, resource, payment)?;
    resource.commit();                        // éxito — no liberar
    Ok(receipt)
}
```

### 29.6 Exhaustive Matching

```astra
// #[must_use] automático en Result y Option
let x = do_work();  // ERROR: Result descartado. Manejar con match, ?, o _ = expr;

// Match exhaustivo requerido
match do_work() {
    Ok(v) => ...,
    Err(e) => ...,
    // ERROR: patrones no exhaustivos. Faltante: Err(_)
}

// Ignorar explícitamente
_ = do_work();  // OK, ignorado explícitamente
```

### 29.7 Niche Optimization (Zero-Cost)

```
Option<ARC<T>> = same size as ARC<T>   (null = None)
Option<NonZeroU32> = same size as u32  (0 = None)
Result<T, ()> con niche = same size as T
```

### 29.8 Tabla Comparativa

| Feature | Astra | Rust | Zig | Go |
|:--------|:------|:-----|:----|:---|
| Propagación | `?` | `?` | `try` | `if err != nil` |
| Contexto | `.context()` | anyhow | N/A | `fmt.Errorf` |
| Panic | `panic!()` | `panic!()` | `unreachable` | `panic()` |
| Recover | `recover{}` | N/A | N/A | `recover()` |
| Errdefer | `errdefer` | drop patterns | `errdefer` | defer |
| Must use | Automático | `#[must_use]` | Compile error | N/A |
| Niche opt | Sí | Sí | Parcial | N/A |

---

## 30. Scoping y Shadowing

### 30.1 Ámbito por Bloque

```astra
{
    let x = 5;
    {
        let x = 10;       // shadowing en scope anidado: OK
    }
    assert(x == 5);        // x original sigue siendo 5
}

// Redeclaración en mismo scope: ERROR
let x = 5;
let x = 10;               // COMPILE ERROR: x ya declarada
```

### 30.2 let vs var

```astra
let x = 5;                // inmutable por defecto
var y = 5;                // mutable
y = 10;                   // OK
// x = 10;                // ERROR
```

### 30.3 Block Expressions

```astra
let y = {
    let x = 5;
    x + 1                 // sin `;` = expresión, valor = 6
};
// y == 6
```

### 30.4 Destructuring

```astra
let (a, b) = getPair();
let Point { x: px, y: py } = point;

// En pattern matching
match person {
    Person { name, age } => print(name),
}
```

### 30.5 Closure Captures

```astra
// Capture por valor (ARC increment)
let closure = || use(x);

// Capture por referencia (requiere &)
let closure = || use(&x);

// Weak capture para evitar ciclos
let closure = weak(x) || use(x);
```

### 30.6 Interacción con ARC/ORC

Cuando una variable sale de scope, ARC decrementa el refcount. Si llega a 0, el objeto se desasigna. Shadowing fuerza drop inmediato del valor anterior.

```astra
{
    let x = Arc.create(MyClass());   // refcount = 1
    let x = Arc.create(Other());    // old x dropped, refcount → 0
    use(x);
}
```

---

## 31. Type Coercion

### 31.1 Regla de Oro

> **Si la conversión es sin pérdida, no ambigua, y de costo cero → implícita.**
> **Si puede perder datos, fallar, o tiene costo → explícita.**

### 31.2 Coerciones Implícitas (Seguras)

```
Widening de enteros:      i8→i16→i32→i64, u8→u16→u32→u64
Widening unsigned→signed:  u8→i16, u16→i32 (si el signed es suficiente)
Widening de floats:       f32→f64
Int→Float (exacto):       u8→f32, u32→f64 (mantisa cubre todos los valores)
T→Option<T>:              wrapping automático
T→Result<T,E>:            Ok wrapping
Error set widening:       error{A} → error{A,B}
Reference weakening:      &mut T → &T, &T → *const T
Array→slice:              [T; N] → [T]
```

### 31.3 Conversiones Explícitas

```
Narrowing de enteros:     i64→i32, u32→u16      → @narrow(x) o x as int
Float→integer:            f64→i32                → @intFromFloat(x)
Float narrowing:          f64→f32                → @floatCast(x)
Int→Float (lossy):        u32→f32 (>24 bits)    → @floatFromInt(x)
Bool↔int:                 bool→int               → @intFromBool(x)
Downcasting:              Super→Sub              → @downcast(x)
Number↔String:            42→"42"               → .to_string() / .parse()
```

### 31.4 Prohibiciones (Compile Error)

```
float→int implícito
narrowing de int implícito
bool↔number implícito
string↔number implícito
reinterpretation de punteros sin cast
```

### 31.5 Operadores Binarios

```
int + int   → mismo tipo
i8 + i32    → i32 (widening al más amplio)
u8 + i16    → i16 (unsigned→wider signed es seguro)
f32 + f64   → f64 (float widening)
int + float → COMPILE ERROR (requiere explícito)
```

---

## 32. Standard Library

### 32.1 Filosofía: "Batteries Curated"

Ni minimalista (Go) ni maximalista (Python). Un stdlib completo pero no monolítico: ~64 módulos, ~1210 funciones.

### 32.2 Estructura del Stdlib

```
astra-stdlib/
├── core/                    # Fundamentos
│   ├── math/               # trigonometría, linear algebra, random
│   ├── text/               # string (UTF-8), rope, regex, formatting
│   ├── collections/        # Array, HashMap, Set, TreeMap, Queue, Stack
│   ├── io/                 # File, Buffer, Reader, Writer, Stream
│   └── time/               # DateTime, Duration, Timer, Instant
│
├── net/                     # Red (en stdlib)
│   ├── tcp/                # TcpListener, TcpStream
│   ├── udp/                # UdpSocket
│   ├── http/               # HTTP client/server (green-threaded)
│   ├── websocket/          # WebSocket client/server
│   └── dns/                # DNS resolution
│
├── sync/                    # Concurrency
│   ├── channel/            # Channel (buffered/unbuffered)
│   ├── mutex/              # Mutex, RwLock, Spinlock
│   ├── atomic/             # AtomicInt, AtomicRef, AtomicPointer
│   └── primitive/          # WaitGroup, Semaphore, Barrier, Once
│
├── crypto/                  # Criptografía
│   ├── hash/               # SHA-256, SHA-512, BLAKE3
│   ├── hmac/               # HMAC
│   ├── aead/               # AES-GCM, ChaCha20
│   └── tls/                # TLS 1.3 client/server
│
├── encoding/                # Formatos
│   ├── json/               # JSON parser/serializer (compile-time derive)
│   ├── toml/               # TOML parser/serializer
│   ├── base64/             # Base64 encode/decode
│   └── csv/                # CSV parser
│
├── os/                      # Sistema operativo
│   ├── process/            # spawn, kill, wait
│   ├── env/                # environment variables
│   └── fs/                 # filesystem operations
│
├── testing/                 # Testing
│   ├── assert/             # assertions
│   ├── test_runner/        # test discovery & execution
│   ├── property/           # property-based testing
│   └── mock/               # mocking framework
│
└── com/                     # Interop
    ├── ffi/                # C-ABI bridge
    ├── python/             # Python zero-copy FFI
    └── platform/           # platform-specific APIs
```

### 32.3 Lo que NO va en Stdlib

YAML, protobuf, linear algebra completa, statistics, image processing, database drivers, web frameworks, compresión, logging frameworks. Todo esto va en el ecosistema de paquetes.

### 32.4 Targets de Performance

| Operación | Target |
|:----------|:-------|
| Fiber spawn | <1μs |
| Context switch (fiber) | <100ns |
| Channel throughput | >1M msg/sec |
| JSON parse | >100MB/s |
| SHA-256 | >500MB/s |
| HashMap lookup | <50ns |

---

## 33. Package Manager

### 33.1 Arquitectura: Registry Híbrido

```
┌─────────────────────────────────────────────┐
│           pkg.astralang.dev                 │
│         (Public Registry)                   │
│   Paquetes públicos, descubrimiento         │
└──────────────────┬──────────────────────────┘
                   │
    ┌──────────────┼──────────────┐
    │              │              │
┌───▼────┐   ┌────▼───┐   ┌─────▼─────┐
│ Git    │   │ Path   │   │ Private   │
│ deps   │   │ deps   │   │ Registry  │
│        │   │ (local)│   │ (corp)    │
└────────┘   └────────┘   └───────────┘
```

### 33.2 Formato de Configuración

```toml
# astra.toml
[package]
name = "myproject"
version = "0.1.0"
edition = "2025"

[dependencies]
http = "^1.2"                    # SemVer range
json = "^2.0"
mylib = { git = "https://...", branch = "main" }
local = { path = "../local" }

[target.'cfg(os = "linux")'.dependencies]
io_uring = "^0.5"               # Platform-specific
```

### 33.3 Resolución de Dependencias: MVS

MVS (Minimal Version Selection) como algoritmo principal:
- Determinista: mismas entradas → mismas salidas
- Lineal en tiempo: O(n log n)
- No necesita lockfiles para libraries
- Lockfiles solo para binarios (executables)

### 33.4 CLI

```
astra pkg init                    # Crear nuevo paquete
astra pkg add <dep>               # Agregar dependencia
astra pkg remove <dep>            # Remover dependencia
astra pkg update                  # Actualizar dependencias
astra pkg search <query>          # Buscar paquetes
astra pkg publish                 # Publicar al registry
astra pkg audit                   # Escanear vulnerabilidades
astra pkg licenses                # Verificar licencias
astra pkg tree                    # Árbol de dependencias
```

### 33.5 Seguridad

- Content-addressed storage (hash = identity)
- Lockfile integrity verification
- Scoped packages (prevenir name confusion)
- Built-in vulnerability scanning
- License compliance checking
- SBOM generation

---

## 34. Gramática Formal

### 34.1 Formalismo: PEG + Hand-Written Parser

PEG (Parsing Expression Grammar) con parser escrito a mano, como Zig. Razón: control total sobre errores, soporte LSP, parseo incremental.

### 34.2 Precedencia de Operadores (de mayor a menor)

| Nivel | Operadores | Asociatividad |
|:------|:-----------|:--------------|
| 1 | `::` | Left |
| 2 | `.` `->` `[]` `()` | Left |
| 3 | `-x` `!` `~` `@` `*ptr` `&ref` | Prefix |
| 4 | `*` `/` `%` | Left |
| 5 | `+` `-` | Left |
| 6 | `<<` `>>` | Left |
| 7 | `&` (bitwise AND) | Left |
| 8 | `^` (bitwise XOR) | Left |
| 9 | `\|` (bitwise OR) | Left |
| 10 | `==` `!=` `<` `>` `<=` `>=` | Left |
| 11 | `&&` (logical AND) | Left |
| 12 | `\|\|` (logical OR) | Left |
| 13 | `..` `..=` | Left |
| 14 | `=` `+=` `-=` etc. | Right |
| 15 | `->` (return type) | Left |
| 16 | `,` | Left |

### 34.3 Fragmentos de Gramática EBNF

```ebnf
(* Programa *)
program         = { item } ;

(* Items *)
item            = fn_decl | struct_decl | enum_decl | trait_decl
                | impl_decl | const_decl | type_alias | comptime_block ;

(* Funciones *)
fn_decl         = "fn" IDENT [ type_params ] params [ "->" type ] block ;
params          = "(" [ param { "," param } [ "," ] ] ")" ;
param           = [ "mut" ] IDENT ":" type ;

(* Tipos *)
type            = type_atom { type_suffix } ;
type_atom       = primitive_type | IDENT [ type_args ] | "(" type ")"
                | "fn" params "->" type | "[" type "]" | "[]" type ;
type_args       = "<" type { "," type } [ "," ] ">" ;
primitive_type  = "i8" | "i16" | "i32" | "i64" | "u8" | "u16" | "u32" | "u64"
                | "f32" | "f64" | "bool" | "string" | "void" | "never" ;

(* Expresiones *)
expr            = expr_binary ;
expr_binary     = expr_unary { bin_op expr_unary } ;
expr_unary      = unary_op expr_postfix | expr_postfix ;
expr_postfix    = expr_primary { postfix_op } ;
expr_primary    = LITERAL | IDENT | "(" expr ")"
                | block | if_expr | match_expr | comptime_expr
                | closure_expr | "true" | "false" | "null" ;

block           = "{" { statement } [ expr ] "}" ;
if_expr         = "if" expr block [ "else" if_expr | block ] ;
match_expr      = "match" expr "{" { match_arm } "}" ;
match_arm       = pattern "=>" ( expr | block ) "," ;

(* Patterns *)
pattern         = literal_pattern | identifier_pattern | tuple_pattern
                | struct_pattern | enum_pattern | wildcard_pattern ;
```

### 34.4 Parser Implementation

- **Recursive descent** con **Pratt parsing** para expresiones
- **Error recovery** por frase: synchronizar en `;`, `}`, `fn`, `let`, `return`
- Nunca falla: siempre produce CST + lista de errores
- **Incremental**: solo re-parsea lo que cambió (para LSP)

### 34.5 Indentación

Llaves como primario. Indentación diferida a Phase 2 (pasada de lexer que agrega tokens INDENT/DEDENT opcionalmente).

---

## 35. Concurrencia Profunda

### 35.1 Primitivas de Sincronización

| Primitiva | Uso | Costo |
|:----------|:----|:------|
| **Mutex** | Exclusión mutua, sección crítica | ~25-40ns |
| **RwLock** | Lectura concurrente, escritura exclusiva | ~50-100ns |
| **Spinlock** | Secciones críticas <100ns | ~5-10ns |
| **TryLock** | Evitar deadlocks, timeouts | ~25-40ns (falla) |
| **Channel** | Comunicación entre fibras (CSP) | ~40-100ns |
| **WaitGroup** | Esperar N fibras | ~15ns |
| **Semaphore** | Limitar concurrencia | ~50ns |
| **Barrier** | Sincronizar N fibras | ~100ns |
| **Once** | Inicialización singleton | ~5ns |

### 35.2 Channels (CSP)

```astra
// Channel tipado, no bufferizado (sincronía)
let ch = Channel::new::<Message>();

// Channel bufferizado
let ch = Channel::buffered::<Message>(1024);

// Envío/recepción
ch.send(msg);                    // suspende si lleno
let msg = ch.recv();             // suspende si vacío

// Select (multiplexar múltiples canales)
select {
    msg in ch1 => handle(msg),
    msg in ch2 => handle(msg),
    after 5s => timeout(),
    default => non_blocking(),
}
```

### 35.3 Atomics

```astra
// Memoria ordenada
let counter = AtomicInt::new(0);
counter.fetch_add(1, Ordering::Relaxed);    // sin ordenamiento
counter.load(Ordering::Acquire);            // acquire barrier
counter.store(1, Ordering::Release);        // release barrier

// AtomicRef para referencias compartidas
let ref = AtomicRef::new(data);
let val = ref.load(Ordering::AcqRel);
ref.store(new_data, Ordering::SeqCst);
```

### 35.4 Prevención de Deadlocks

- **Lock ordering**: siempre adquirir locks en orden consistente
- **TryLock + yield**: intentar lock, si falla → ceder fibra → reintentar
- **Lock-free data structures**: para paths de alta concurrencia
- **Detection**: wait-for graph cycle detection (debug mode)

### 35.5 Send/Sync Traits

```astra
// Send: el tipo puede moverse entre fibras
trait Send { }

// Sync: el tipo puede ser compartido entre fibras (&T es seguro)
trait Sync { }

// ARC<T> es Send + Sync si T es Send + Sync
// Mutex<T> es Send + Sync si T es Send
// Channel<T> es Send si T es Send
```

### 35.6 Fiber-Aware vs OS-Level

| Primitiva | Fiber-Aware | OS-Level |
|:----------|:------------|:---------|
| Mutex | ✅ (suspends fibra) | ❌ (bloquea hilo) |
| Channel | ✅ (park/unpark fibra) | N/A |
| WaitGroup | ✅ | N/A |
| RwLock | ✅ | ❌ |
| Semaphore | ✅ | N/A |

**Regla**: Todas las primitivas de alto nivel son fiber-aware. OS-level solo en `unsafe` o para integración con C.

### 35.7 Performance Targets

| Operación | Target | Go | Rust |
|:----------|:-------|:---|:-----|
| Fiber spawn | <150ns | ~150ns (goroutine) | N/A |
| Fiber ctx switch | <100ns | ~100ns | N/A |
| Mutex lock/unlock | ~25-40ns | ~20ns | ~25ns |
| Channel send/recv | ~40-100ns | ~100ns | ~50ns (crossbeam) |
| Atomic load | ~1-5ns | ~1ns | ~1ns |

---

## 37. Especificación Formal

### 37.1 Estructura Recomendada

```
Astra Language Specification

1. Scope
2. Normative References
3. Terminology and Definitions
4. Conformance
5. Environment (translation phases, execution environments)
6. Lexical Structure (charset, tokens, comments, Unicode)
7. Grammar Notation (EBNF conventions, operator precedence)
8. Type System (primitives, generics, inference, coercion, subtyping)
9. Expressions (literals, operators, control flow, pattern matching)
10. Statements and Declarations (bindings, scope, control flow)
11. Memory Model (ARC/ORC, happens-before, pointer model, unsafe)
12. Concurrency (fibers, channels, atomics, synchronization)
13. Modules and Packages (imports, exports, visibility)
14. Error Handling (Result, Option, panic, propagation)
15. Metaprogramming (comptime, reflection, macros)
16. FFI (C ABI, calling conventions, type mapping)
17. Standard Library (core contracts, API specifications)
Annex A: Grammar summary (EBNF)
Annex B: Implementation-defined behavior
Annex C: Unspecified behavior
Annex D: Portability issues
Annex E: Glossary
```

### 37.2 Nivel de Formalidad

| Componente | Formalidad | Notación |
|:-----------|:-----------|:---------|
| Gramática | Formal | EBNF (machine-parseable) |
| Sistema de tipos | Formal | Reglas de inferencia + algoritmo |
| Semántica | Semi-formal | Prosa + ejemplos + operational semantics |
| Modelo de memoria | Formal | Happens-before relations |
| Concurrency | Formal | Atomic operations + scheduling |

### 37.3 Decisiones Clave a Documentar

1. **Orden de evaluación**: Left-to-right (determinístico)
2. **Undefined behavior**: Mínimo — definir comportamiento explícito
3. **Enteros**: Two's complement, anchos garantizados
4. **Floats**: IEEE 754, round-to-nearest
5. **Modelo de memoria**: Basado en C11
6. **ARC/ORC**: Cuándo se incrementa/decrementa, algoritmo de trial deletion
7. **Unsafe**: Qué requiere bloques unsafe
8. **Plataforma**: Qué es target-dependent

### 37.4 Artefactos Complementarios

- **Reference interpreter**: Para testing del spec
- **MiniAstra**: Core calculus minimalista para verificación formal
- **Suite de conformance**: Programas que deben compilar/pasar/fallar
- **Archivos de gramática**: EBNF machine-parseable para generación de parsers

---

## 38. Seed Compiler

### 38.1 Lenguaje de Implementación: C

| Factor | C | Rust |
|:-------|:--|:-----|
| Dependencias | 0 | Rust toolchain |
| Auditabilidad | Mínima complejidad | Más features que el compiler |
| Cross-compilation | Universales | Requiere rustup targets |
| Uso | Una vez, luego se retira | Overkill para throwaway |

**Decisión**: C. Es el root de confianza auditable.

### 38.2 Fases de Bootstrapping

```
Fase 1: SEED (C → Astra-0)
    Escrito en C, compila subconjunto mínimo de Astra
    ↓
Fase 2: SELF-HOST (Astra-0 → Astra-1)
    Astra-0 compila el compilador escrito en Astra
    ↓
Fase 3: FULL (Astra-1 → Astra-N)
    Cada versión compila la siguiente
    ↓
Fase 4: VERIFIED
    Binary reproducibility + diverse double-compilation
```

### 38.3 Feature Set Mínimo (Astra-0)

| Feature | Necesario para seed | Necesario para self-host |
|:--------|:-------------------|:------------------------|
| Integer/Float/Bool/String | ✅ | ✅ |
| Structs | ✅ | ✅ |
| Enums | ✅ | ✅ |
| Functions | ✅ | ✅ |
| if/else, while, for | ✅ | ✅ |
| match | ✅ | ✅ |
| Option/Result | ✅ | ✅ |
| `?` propagation | ✅ | ✅ |
| Basic I/O builtins | ✅ | ✅ |
| Modules | ❌ | ✅ |
| Generics | ❌ | ✅ |
| Traits | ❌ | ✅ |
| Comptime | ❌ | ❌ |
| ARC/ORC | ❌ | ❌ |
| Green threads | ❌ | ❌ |
| LLVM backend | ❌ | ❌ |

### 38.4 Arquitectura del Seed

```
┌─────────────────────────────────────┐
│         Seed Compiler (C)            │
│                                      │
│  ┌──────────┐  ┌──────────┐         │
│  │  Lexer   │→│  Parser  │         │
│  │ (hand-   │  │ (recursive│         │
│  │  written)│  │  descent +│         │
│  └──────────┘  │  Pratt)  │         │
│                └────┬─────┘         │
│                     │               │
│                ┌────▼─────┐         │
│                │   AST    │         │
│                └────┬─────┘         │
│                     │               │
│                ┌────▼─────┐         │
│                │  Type    │         │
│                │  Checker │         │
│                └────┬─────┘         │
│                     │               │
│                ┌────▼─────┐         │
│                │   AIR    │         │
│                └────┬─────┘         │
│                     │               │
│          ┌──────────┼──────────┐    │
│          │          │          │    │
│     ┌────▼────┐ ┌───▼───┐ ┌───▼───┐│
│     │ Bytecode│ │  C    │ │ LLVM  ││
│     │   VM    │ │codegen│ │backend││
│     └─────────┘ └───────┘ └───────┘│
└─────────────────────────────────────┘
```

### 38.5 Parser: Hand-Written Recursive Descent + Pratt

- **Recursive descent** para estructura general
- **Pratt parsing** para expresiones (precedencia de operadores)
- **Error recovery**: Nunca falla, siempre produce AST + errores
- **LSP-friendly**: Siempre produce output utilizable

### 38.6 Code Generation: Dual Backend

| Backend | Uso | Ventaja |
|:--------|:----|:--------|
| **Bytecode VM** | Desarrollo | Arranque <10ms, debugácil |
| **C codegen** | Bootstrap | Genera `.c` que gcc/clang compila |
| **LLVM** | Producción | Optimizaciones completas |

### 38.7 Timeline Estimado

| Fase | Duración | Entregable |
|:-----|:---------|:-----------|
| Lexer + Parser + Type Checker + VM | Meses 1-2 | Interprete funcional |
| Structs, Enums, Match, Arrays, Optionals | Meses 3-4 | Lenguaje completo |
| C codegen + Bootstrap execution | Meses 5-6 | Self-hosting |
| Polish, testing, documentation | Meses 7-8 | Seed estable |

### 38.8 Lecciones de Referencia

| Lenguaje | Estrategia | Lección |
|:---------|:-----------|:--------|
| **Go** | C seed → mechanical translation → self-host | Seed "deliberadamente restringido" |
| **Rust** | OCaml → self-hosted | Gradual migration |
| **Zig** | C++ bootstrap → self-hosted | Cross-compiler desde el inicio |
| **Nim** | C codegen (siempre) | Simple pero frágil |
| **Swift** | C++ → self-hosted | Apple resources |

---

## 39. Testing del Compilador

### 39.1 Estrategia Principal: Differential Testing

Astra's dual backend (VM vs LLVM) es un oráculo natural:

```bash
# Comparar output entre backends
for file in corpus/*.astra; do
    astra run "$file" > out_vm.txt
    astra build --release "$file" -o /tmp/out && /tmp/out > out_llvm.txt
    diff out_vm.txt out_llvm.txt
done
```

### 39.2 Suite de Conformance

Modelo: test262 (JavaScript, 50,000+ tests). Archivos `.astra` con metadata:

```astra
//@ check-pass
//@ expected-output: "Hello, World!"
fn main() {
    print("Hello, World!");
}
```

```astra
//@ check-fail
//@ expected-error: "type mismatch"
fn main() {
    let x: i32 = "hello";
}
```

**Target inicial**: 100-200 tests cubriendo features core.

### 39.3 Sanitizers

```bash
# Siempre compilar con sanitizers durante desarrollo
cc -fsanitize=address,undefined -g compiler.c -o astra-seed
# ASAN: memory bugs
# UBSAN: undefined behavior
```

### 39.4 Fuzzing

| Herramienta | Target | Uso |
|:------------|:-------|:----|
| **AFL++** | `astra build` binary | Crash finding |
| **LibFuzzer** | Parser, type checker | Unit-level fuzzing |
| **Astra-Csmith** | Grammar-based | Genera programas válidos y compara hashes |

### 39.5 Roadmap de Testing

| Fase | Tests | Herramientas |
|:-----|:------|:-------------|
| Mes 1-2 | 200 conformance | Test harness + differential |
| Mes 3-4 | 500+ tests | Random generator + LibFuzzer |
| Mes 5-6 | 800+ tests | AFL++ + optimization tests |
| Mes 7+ | 1000+ tests | Cross-platform + community |

---

## 40. Governance

### 40.1 Modelo Actual (Pre-1.0): BDFL + Core Team

- Fundador como BDFL con veto, delega extensivamente
- 3-5 core team members de early contributors
- Decisiones por consenso, no por voto
- Proceso de propuestas ligero (GitHub Issues)

### 40.2 Proceso de Propuestas

```
1. Discussion (GitHub Discussion / Forum)
2. Proposal (GitHub Issue con template)
3. Review (Core team, ~2 semanas)
4. Decision (Accept / Reject / Defer)
5. Implementation (PR con tests + docs)
6. Stabilization (feature flag → stable)
```

### 40.3 En 1.0: Foundation

| Aspecto | Recomendación |
|:--------|:-------------|
| **Legal** | 501(c)(3) nonprofit |
| **Board** | 3 Project + 2-3 Corporate + 1-2 Community + 1 Independent |
| **Funding** | Corporate membership, donations, conferences, grants |
| **Owns** | Trademarks, infra, conferences, legal |
| **Does NOT own** | Technical decisions, language design |

### 40.4 Ciclo de Vida de Features

```
Idea → Discussion → Proposal → Core Team Review → Accept/Reject
→ Implementation (nightly) → Testing → Stabilization
```

### 40.5 Backwards Compatibility: Edition System

```toml
# astra.toml
[package]
edition = "2025"  # opt-in, como Rust
```

- Ediciones son "skin deep" — misma representación interna
- Crates de diferentes ediciones interoperan
- `astra fix` automatiza migración
- No hay breaking changes forzados

### 40.6 Cadencia de Release

| Canal | Frecuencia | Contenido |
|:------|:-----------|:----------|
| Nightly | Cada noche | Todas las features |
| Beta | Cada 2 meses | Branch de nightly |
| Stable | Cada 2 meses | Branch de beta |
| LTS | No (soportar solo últimos 2) | Security fixes |

### 40.7 Documents del Día 1

1. **GOVERNANCE.md** — Modelo actual, cómo se hacen decisiones
2. **CONTRIBUTING.md** — Cómo contribuir, code review
3. **RFC Process** — Cómo proponer cambios (incluso informal)
4. **CODE_OF_CONDUCT.md** — Estándares de comunidad
5. **TRADEMARK.md** — Cómo se puede usar el nombre/marca
6. **RELEASE.md** — Cómo se cortan releases
7. **ROADMAP.md** — Prioridades 12 meses

---

## 41. Puntos Pendientes

- [x] Todos los items investigados.
- [ ] Implementación del seed compiler.
- [ ] Escritura de la especificación formal.
- [ ] Creación de la suite de conformance tests.
- [ ] Setup de governance documents.

- [x] Sistema de módulos y resolución de rutas.
- [x] Pattern matching y enums algebraicos.
- [x] Metaprogramación comptime.
- [x] Serialización derivada en compile-time.
- [x] Asignadores de memoria personalizados.
- [x] Soporte WASM y kernels GPU.
- [x] REPL interactivo y Notebooks/Jupyter.
- [x] LSP e integración IDE.
- [x] Análisis comparativo profundo.
- [x] Arquitectura del compilador (multi-IR, query system).
- [x] Runtime systems (ARC/ORC, fibers, memory layout).
- [x] Testing strategies (fuzzing, differential, property-based).
- [x] Bootstrap y cross-compilation.
- [x] Ámbito de variables (scoping por bloque) y shadowing.
- [x] Conversión de tipos (coerción explícita vs implícita).
- [x] Gestión de pánicos y recuperación de errores críticos.
- [x] Diseño del standard library.
- [x] Gramática formal (EBNF, precedencia de operadores).
- [x] Concurrencia profunda (channels, locks, atomics).
- [x] Package manager (dependencias, registry, semver).
- [x] Cross-platform (Linux, Windows, macOS, Android).
- [x] Apple ecosystem (macOS, iOS, visionOS).
- [x] Android/ARM support.
- [x] ABI stability y linking.
- [x] Especificación formal completa del lenguaje.
- [x] Diseño del seed compiler.
- [x] Testing del compilador.
- [x] Governance y proceso RFC.
