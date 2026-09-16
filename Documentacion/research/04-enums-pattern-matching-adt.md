# Astra — Enums Algebraicos, Pattern Matching y Tipos Algebraicos de Datos (ADTs)

**Estado:** Propuesta de Diseño v0.1
**Fecha:** 2026-09-16
**Cubre:** Sección 5.4 del ARCHITECTURE.md (pendiente: "Patrones y enums algebraicos")

---

## 1. Resumen Ejecutivo

Este documento investiga en profundidad cómo los lenguajes de programación modernos implementan **tipos algebraicos de datos (ADTs)**, **enums con datos asociados** y **pattern matching**, y propone un diseño concreto para Astra. El análisis cubre Rust, Swift, Kotlin, Haskell, OCaml, Scala, F# y Elixir, evaluando trade-offs en ergonomía, seguridad, rendimiento y compatibilidad con el modelo de memoria ARC/ORC de Astra.

**Recomendación central:** Adoptar un modelo inspirado en Rust para los enums (como ADTs sumatoria), con exhaustiveness checking estricto por defecto, integración nativa con ARC/ORC, y una sintaxis limpio y consistente con el estilo de Astra ya definido.

---

## 2. Tipos Algebraicos de Datos: Fundamentos Teóricos

### 2.1 Tipos Suma (Sum Types) vs Tipos Producto (Product Types)

Los ADTs se construyen a partir de dos operaciones algebraicas fundamentales:

| Operación | Tipo | Significado | Ejemplo Astra |
|-----------|------|-------------|---------------|
| **Suma (+)** | Sum type (tagged union) | Un valor es **una de** varias variantes | `enum Result<T, E>` |
| **Producto (×)** | Product type | Un valor contiene **todos** los campos | `struct Punto { x: Float, y: Float }` |

La "algebra" proviene de contar posibles valores:
- `Bool × u8` = 2 × 256 = 512 valores posibles
- `Bool + u8` = 2 + 256 = 258 valores posibles

### 2.2 ¿Por qué importan?

Los ADTs hacen **estados inválidos irrepresentables**. Si un pago solo puede ser Aprobado, Rechazado o Pendiente, el tipo lo garantiza. No hay "tercer estado" accidental, no hay `null` misterioso, no hay `default` que oculte bugs.

```astra
enum EstadoPago {
    Aprobado(Float)          # monto aprobado
    Rechazado(String)        # razón
    Pendiente                # sin datos
}
```

---

## 3. Investigación Comparativa: Lenguajes Existentes

### 3.1 Haskell

Haskell es la fuente original del término "algebraic data type". Su sintaxis es la más compacta:

```haskell
-- Sum type (data keyword)
data Forma = Circulo Float
           | Rectangulo Float Float
           | Triangulo Float Float Float

-- Product type (record syntax)
data Punto = Punto { x :: Float, y :: Float }

-- Patrón más común: Maybe y Either
data Maybe a = Nothing | Just a
data Either a b = Left a | Right b
```

**Características clave:**
- Un solo keyword (`data`) para sum y product types
- Constructores son funciones: `Circulo :: Float -> Forma`
- Exhaustiveness checking: **warning** por defecto (`-Wincomplete-patterns` no está en `-Wall` en todas las versiones)
- Necesita flag explícito: `-Wincomplete-patterns` o `-Werror`
- Laziness: pattern matching puede forzar evaluación
- Soporta GADTs (Generalized Algebraic Data Types)

```haskell
area :: Forma -> Float
area (Circulo r)       = pi * r * r
area (Rectangulo w h)  = w * h
area (Triangulo a b c) = let s = (a + b + c) / 2
                         in sqrt (s * (s-a) * (s-b) * (s-c))
```

### 3.2 Rust

Rust ha popularizado los ADTs en programación de sistemas. Enums con datos asociados son el mecanismo central:

```rust
enum Forma {
    Circulo(f64),
    Rectangulo { ancho: f64, alto: f64 },
    Triangulo(f64, f64, f64),
}

// Patrones con datos asociados (named fields)
match forma {
    Forma::Circulo(r) => pi * r * r,
    Forma::Rectangulo { ancho, alto } => ancho * alto,
    Forma::Triangulo(a, b, c) => {
        let s = (a + b + c) / 2.0;
        (s * (s-a) * (s-b) * (s-c)).sqrt()
    }
}
```

**Características clave:**
- Exhaustiveness checking: **compile error** (E0004) — el más estricto
- `match` es una **expresión** (retorna valor)
- Guards: `if condición` después del patrón
- Anidamiento completo de patrones
- `#[non_exhaustive]` para escapar en bibliotecas
- Niche optimization: `Option<&T>` = mismo tamaño que `&T`
- Patrones: literales, rangos, or-patterns (`A | B`), `@` bindings
- Tipos vacíos (`enum Vacio {}`) — sin variantes

```rust
// Exhaustiveness en acción
enum Color { Rojo, Verde, Azul }

fn nombre(c: Color) -> &str {
    match c {
        Color::Rojo => "rojo",
        Color::Verde => "verde",
        // Error E0004: non-exhaustive patterns: `Color::Azul` not covered
    }
}

// Con wildcard
fn nombre_seguro(c: Color) -> &str {
    match c {
        Color::Rojo => "rojo",
        _ => "otro",
    }
}

// Guards
fn clasificar(x: i32) -> &'static str {
    match x {
        n if n < 0 => "negativo",
        0 => "cero",
        n if n > 100 => "grande",
        _ => "normal",
    }
}
```

### 3.3 Swift

Swift enums con valores asociados son ADTs completos:

```swift
enum Forma {
    case circulo(Double)
    case rectangulo(ancho: Double, alto: Double)
    case triangulo(Double, Double, Double)
}

// Match como expresión
let area = switch forma {
case .circulo(let r): Double.pi * r * r
case .rectangulo(let w, let h): w * h
case .triangulo(let a, let b, let c):
    let s = (a + b + c) / 2
    sqrt(s * (s-a) * (s-b) * (s-c))
}
```

**Características clave:**
- Exhaustiveness: **compile error** (como Rust)
- `switch` siempre exhaustivo, no necesita `break`
- Associated values por caso (cada caso puede tener tipo diferente)
- Raw values para enums simples (`enum Color: Int`)
- `indirect` para recursion (wrapper explícito)
- Métodos computados y extensiones en enums
- `@unknown default` para compatibilidad hacia adelante

```swift
// Recursive enum con indirect
enum Expresion {
    case numero(Int)
    indirect case suma(Expresion, Expresion)
    indirect case multiplica(Expresion, Expresion)
}

// Patrón con where
switch forma {
case .circulo(let r) where r < 0:
    print("Radio negativo")
case .circulo(let r):
    print("Circulo de radio \(r)")
default:
    break
}
```

### 3.4 Kotlin

Kotlin usa `sealed class` / `sealed interface` para ADTs:

```kotlin
sealed class Forma {
    data class Circulo(val radio: Double) : Forma()
    data class Rectangulo(val ancho: Double, val alto: Double) : Forma()
    object Vacio : Forma()
}

// when como expresión (exhaustive)
fun area(forma: Forma): Double = when (forma) {
    is Forma.Circulo -> Math.PI * forma.radio * forma.radio
    is Forma.Rectangulo -> forma.ancho * forma.alto
    is Forma.Vacio -> 0.0
    // Exhaustive si sealed: no necesita else
}
```

**Características clave:**
- `sealed` restringe subtipos al mismo archivo
- Exhaustiveness: solo cuando `when` se usa como **expresión** (asignado a variable)
- `when` como statement: NO es exhaustivo (necesita `else`)
- Data classes automáticas para product types
- Sin associated values nativos (usar data classes anidadas)
- Polyfills limitados vs Rust/Swift

```kotlin
// Con when como expression (exhaustive)
val descripcion = when (forma) {
    is Forma.Circulo -> "Circulo de radio ${forma.radio}"
    is Forma.Rectangulo -> "Rect ${forma.ancho}x${forma.alto}"
    is Forma.Vacio -> "Vacio"
} // OK: exhaustive

// Con when como statement (NO exhaustive)
when (forma) {
    is Forma.Circulo -> println("Circulo")
    // No error: falta Rectangulo y Vacio
}
```

### 3.5 OCaml

OCaml fue pionero en pattern matching eficiente para lenguajes funcionales:

```ocaml
type forma =
  | Circulo of float
  | Rectangulo of float * float
  | Triangulo of float * float * float

let area = function
  | Circulo r -> Float.pi *. r *. r
  | Rectangulo (w, h) -> w *. h
  | Triangulo (a, b, c) ->
    let s = (a +. b +. c) /. 2.0 in
    sqrt (s *. (s -. a) *. (s -. b) *. (s -. c))
```

**Características clave:**
- Exhaustiveness: **warning** por defecto, `Match_failure` en runtime
- Polymorphic variants: ADTs abiertos, sin keyword `type` explícito
- Guards con `when` en patrones
- Or-patterns: `| Circulo _ | Rectangulo _ -> ...`
- Compilación a decision trees con heurísticas optimizadas

```ocaml
(* Polymorphic variants: ADTs abiertos *)
let area = function
  | `Circulo r -> Float.pi *. r *. r
  | `Rectangulo (w, h) -> w *. h

(* Or-patterns *)
let es_grande = function
  | Circulo r when r > 10.0 -> true
  | Rectangulo (w, h) when w *. h > 100.0 -> true
  | _ -> false
```

### 3.6 Scala

Scala combina OOP y FP con sealed traits + case classes:

```scala
sealed trait Forma
case class Circulo(radio: Double) extends Forma
case class Rectangulo(ancho: Double, alto: Double) extends Forma
case object Vacio extends Forma

// match con exhaustiveness (warning por defecto)
def area(forma: Forma): Double = forma match {
  case Circulo(r) => Math.PI * r * r
  case Rectangulo(w, h) => w * h
  case Vacio => 0.0
}
```

**Características clave:**
- Exhaustiveness: **warning** por defecto; `-Xfatal-warnings` para error
- `sealed` no es transitivo (bug conocido en Scala 2/3)
- `case class` = product type automático
- `case object` = singleton
- Pattern matching avanzado: nested, guards, type patterns, extractors

```scala
// Nested patterns
forma match {
  case Rectangulo(Circulo(r), _) if r > 5 => "big nested"
  case _ => "other"
}

// Type patterns
def descripcion(x: Any): String = x match {
  case i: Int => s"Integer: $i"
  case s: String => s"String: $s"
  case _ => "Unknown"
}
```

### 3.7 F#

F# discriminated unions son equivalentes a Haskell/Rust:

```fsharp
type Forma =
    | Circulo of float
    | Rectangulo of float * float
    | Triangulo of float * float * float

let area = function
    | Circulo r -> System.Math.PI * r * r
    | Rectangulo (w, h) -> w * h
    | Triangulo (a, b, c) ->
        let s = (a + b + c) / 2.0
        sqrt (s * (s-a) * (s-b) * (s-c))
```

**Características clave:**
- Exhaustiveness: **warning** por defecto
- Active patterns: pattern matching extensible
- Units of measure integrados (relevante para Astra)
- Named fields: `type Punto = { x: float; y: float }`

### 3.8 Elixir/Erlang

Elixir hereda pattern matching de Erlang pero con structs:

```elixir
defmodule Forma do
  defstruct [:tipo, :datos]
end

defmodule Geometria do
  def area(%Forma{tipo: :circulo, datos: %{radio: r}}) do
    :math.pi() * r * r
  end

  def area(%Forma{tipo: :rectangulo, datos: %{ancho: w, alto: h}}) do
    w * h
  end
end
```

**Características clave:**
- Pattern matching en argumentos de función (no expression)
- Guards con `when`
- Tuples como tagged unions naturales: `{:circulo, r}`
- Sin exhaustiveness checking (runtime errors)
- Recursión + pattern matching como patrón fundamental

```elixir
# Tuples como tagged unions
def area({:circulo, r}), do: :math.pi() * r * r
def area({:rectangulo, w, h}), do: w * h

# Con guards
def clasificar(n) when n < 0, do: :negativo
def clasificar(0), do: :cero
def clasificar(n) when n > 100, do: :grande
def clasificar(_), do: :normal
```

---

## 4. Exhaustiveness Checking: Análisis Profundo

### 4.1 Comparativa de Estrategias

| Lenguaje | Comportamiento por defecto | ¿Se puede endurecer? | Mecanismo |
|----------|--------------------------|----------------------|-----------|
| **Rust** | Compile error (E0004) | N/A (ya es el más estricto) | Uso de algoritmo de "usefulness" |
| **Java (JEP 441)** | Compile error (pattern switch sobre sealed) | N/A | Solo para nuevos pattern switches |
| **Swift** | Compile error | N/A | Verificación estática en switch |
| **Kotlin** | Compile error solo si `when` es expresión | N/A | Exhaustiveness condicional |
| **Scala** | Warning por defecto | `-Xfatal-warnings` | Análisis de sealed traits |
| **Haskell** | Nada por defecto | `-Wincomplete-patterns` | Flag explícito |
| **OCaml** | Warning por defecto | `-warn-error A` | Análisis estático |
| **F#** | Warning por defecto | TreatWarningsAsErrors | Análisis estático |

### 4.2 Algoritmo de Verificación (Modelo Rust)

El algoritmo de Rust opera sobre **matrices de patrones** y se basa en el concepto de **"usefulness"**:

1. **Matriz de patrones:** Cada fila es un arm del match, cada columna corresponde a un "slot" del scrutinee
2. **Usefulness:** Un patrón `q` es útil相对于 `p1..pn` si existe un valor que coincide con `q` pero con ninguno de `pi`
3. **Exhaustiveness:** El match es exhaustivo si `_` (wildcard) no es útil相对于 todos los patrones
4. **Constructor splitting:** Para tipos como `u32`, se agrupan constructores que se comportan igual (ej: `0..49` vs `50..100`)

```
// Ejemplo de matriz de patrones:
// Forma      | Result
// -----------+-------
// Circulo _  | ok
// Rectangulo | ok
// _          | fallback

// Verificación:
// 1. ¿Circulo cubierto? Sí (fila 1)
// 2. ¿Rectangulo cubierto? Sí (fila 2)
// 3. ¿_ es útil? Sí → catch-all cubre el resto
// 4. ¿Triangulo cubierto? Solo por _ → match no es "missing" pero sí usa wildcard
```

### 4.3 Redundancia vs Inexhaustividad

```rust
match forma {
    Forma::Circulo(r) => ...,           // Útil
    Forma::Circulo(_) => ...,           // redundante (nunca alcanzado)
    Forma::Rectangulo { .. } => ...,    // Útil
    _ => ...,                           // Útil si hay más variantes
}
```

Rust reporta:
- **Redundante:** Patrón nunca alcanzado (compila con warning)
- **No exhaustivo:** Faltan casos (compila con error)

---

## 5. Opcionales y Result como ADTs

### 5.1 Implementación en Rust

```rust
// Definición real en std
enum Option<T> {
    Some(T),
    None,
}

enum Result<T, E> {
    Ok(T),
    Err(E),
}
```

**Niche optimization:** `Option<&T>` tiene el mismo tamaño que `&T` porque el puntero nulo representa `None`. Esto es posible porque `&T` nunca puede ser nulo.

```rust
use std::mem::size_of;

assert_eq!(size_of::<&i32>(), 8);
assert_eq!(size_of::<Option<&i32>>(), 8);  // Misma taille!

// Option<Box<T>> también usa niche
assert_eq!(size_of::<Box<i32>>(), 8);
assert_eq!(size_of::<Option<Box<i32>>>(), 8);
```

### 5.2 Patrón de Uso Idiomático

```rust
fn dividir(a: f64, b: f64) -> Option<f64> {
    if b == 0.0 { None } else { Some(a / b) }

}

fn buscar(indice: usize, datos: &[i32]) -> Option<&i32> {
    datos.get(indice)
}

// Uso con match
match dividir(10.0, 3.0) {
    Some(resultado) => println!("Resultado: {resultado}"),
    None => println!("División por cero"),
}

// Uso con if-let (destructuring parcial)
if let Some(r) = dividir(10.0, 3.0) {
    println!("Resultado: {r}");
}

// Uso con ? (propagación)
fn procesar(datos: &[i32]) -> Option<i32> {
    let primero = datos.get(0)?;  // Si None, retorna None
    let segundo = datos.get(1)?;
    Some(primero + segundo)
}

// Uso con combinadores
let resultado = dividir(10.0, 3.0)
    .map(|r| r * 2.0)
    .unwrap_or(0.0);
```

### 5.3 Comparación con Nullable y Excepciones

| Característica | `Option<T>` / `Result<T,E>` | Nullable (`T?`) | Excepciones |
|---------------|----------------------------|-----------------|-------------|
| **Explicidad** | Tipo visible en firma | A menudo oculto | No visible en firma |
| **Manejo** | Forzado por compiler | Puede ignorarse | Puede ignorarse |
| **Performance** | Zero-cost (monomorfización) | Branch condicional | Stack unwinding costoso |
| **Composición** | `map`, `and_then`, `?` | Nullable chaining | try/catch |
| **Exhaustiveness** | Sí (con pattern matching) | No | No |
| **Anidamiento** | `Option<Result<T,E>>` | `T??` (confuso) | Un catch puede capturar todo |

```astra
# Astra: estilo similar a Rust
fn dividir(a: Float, b: Float) -> Option<Float> {
    if b == 0.0 { None } else { Some(a / b) }
}

fn procesar(datos: Array<Int>) -> Result<Int, Error> {
    let primero = datos.get(0)?   # Si error, retorna error
    let segundo = datos.get(1)?
    return Ok(primero + segundo)
}
```

---

## 6. Enums en la Práctica: Memoria y Layout

### 6.1 Tagged Union Manual (C)

```c
typedef enum { TAG_INT, TAG_FLOAT, TAG_STRING } Tag;

typedef struct {
    Tag tag;
    union {
        int i;
        float f;
        char* s;
    } data;
} Value;
// Layout: [tag (4B)] [padding (4B)] [union (8B)] = 16 bytes en 64-bit
```

### 6.2 Rust Enum: Tagged Union Optimizado

```rust
enum Value {
    Int(i32),
    Float(f32),
    Str(String),
}
// Layout: [tag (1-4B)] [data (hasta 24B)] 
// Rust optimiza el tag: caben en "nichos" del payload
```

**Optimizaciones de Rust:**
1. **Niche optimization:** Si un tipo tiene valores inválidos (nullos), se usan para el tag
2. **Discriminant packing:** Tags compactos según número de variantes
3. **Struct field packing:** El tag puede colocarse en bits no usados de fields

### 6.3 C++ std::variant

```cpp
using Value = std::variant<int, float, std::string>;

// Uso con std::visit + overloading
std::visit(overloaded{
    [](int i) { /* ... */ },
    [](float f) { /* ... */ },
    [](const std::string& s) { /* ... */ }
}, value);
```

**Limitaciones vs Rust:**
- Sin pattern matching real (necesita `std::visit` + lambdas)
- Sin exhaustiveness checking
- Sin niche optimization
- Más verboso para casos anidados
- `std::monostate` para variantes sin datos

### 6.4 Swift Enum: Layout Optimizado

Swift enum layout (según documentación ABI):
1. **C-like enums:** Tag entero mínimo bits
2. **Single-payload:** Usa "extra inhabitants" del payload type
3. **Multi-payload:** Busca "spare bits" comunes entre payloads
4. **Tag scattering:** Tag distribuido en spare bits cuando es posible

```swift
// Ejemplo de optimización
enum Opt<T> {
    case some(T)
    case none
}
// Para Opt<UnsafePointer<Int>>: none = null pointer, some = puntero válido
// Misma taille que el puntero
```

### 6.5 Kotlin: Synthesized Enums

Kotlin sealed classes son más costosas que Rust/Swift enums porque usan jerarquía de clases + GC:
- Cada subclase es un objeto en heap
- Dispatch virtual en `when`
- Sin optimizaciones de niche (depende del JVM/GC)

### 6.6 Haskell: Constructor Tags + Heap Objects

GHC representa constructores como heap objects con tag:
- Single-constructor: sin tag explícito
- Multi-constructor: word con tag + punteros a campos
- Bottom (⊥) representado como tag inválido

---

## 7. Pattern Matching: Implementación y Rendimiento

### 7.1 Estrategias de Compilación

| Estrategia | Usada por | Ventaja | Desventaja |
|------------|-----------|---------|------------|
| **Decision Tree** | OCaml, Haskell, Rust (parcial) | Sin backtracking, camino promedio corto | Código duplicado (branching) |
| **Jump Table** | Rust, C++ (switch), Swift | O(1) dispatch | Solo para discriminants densos |
| **Backtracking Automaton** | OCaml (optimizado) | Código compacto | Costo promedio mayor |
| **If-else chain** | Implementaciones simples | Fácil de implementar | O(n) peor caso |

### 7.2 Decision Trees: Detalles

El algoritmo de Maranget (2005, OCaml) es el estándar:

1. **Matrix splitting:** Dividir la matriz de patrones por el constructor de la primera columna
2. **Heurística de elección:** Elegir qué columna testear primero (minimiza código duplicado)
3. **Maximal sharing:** Reutilizar subárboles idénticos (DAG en vez de tree)

```
// Ejemplo: compilar match sobre (forma, bool)
match (forma, es_grande) {
    (Circulo r, true) => ...,
    (Circulo r, false) => ...,
    (Rectangulo w h, true) => ...,
    _ => ...,
}

// Decision tree óptimo:
if forma == Circulo:
    if es_grande:
        action1
    else:
        action2
else if forma == Rectangulo:
    if es_grande:
        action3
    else:
        action4  // del wildcard
else:
    action4  // wildcard, reusado (sharing)
```

### 7.3 Jump Tables para Enums Simples

Para enums con discriminants enteros densos (0, 1, 2, 3...), LLVM genera jump tables:

```rust
enum Color { Rojo, Verde, Azul, Negro }

match color {
    Color::Rojo => 1,
    Color::Verde => 2,
    Color::Azul => 3,
    Color::Negro => 4,
}
// Compila a: jump_table[color_discriminant]
// Costo: O(1), una sola operación de memoria
```

### 7.4 Rendimiento Real

Según benchmarks del paper de Maranget y experimentación en OCaml/Rust:
- **Decision trees:** Average path length ~3-4 tests para enums típicos (3-10 variantes)
- **Jump tables:** 1 test siempre (O(1))
- **If-else chain:** ~n/2 tests en promedio (O(n))
- **Patrones anidados:** Pueden aumentar costo; profundidad del árbol importa

Para 3-16 tags en AMD64:
- Jump tables: 2x más lento que decision trees con branches aleatorios
- Jump tables: 2x más rápido con branch predecible (cache efectiva)
- Decision trees: mejores para branches impredecibles

---

## 8. Patrones Avanzados

### 8.1 Patrones Compuestos

```rust
match expresion {
    // Literales
    0 => "cero",
    
    // Rangos
    1..=10 => "pequeño",
    11..=100 => "medio",
    
    // Or-patterns
    Color::Rojo | Color::Verde | Color::Azul => "primario",
    
    // Nested destructuring
    Some(Ok(value)) => println!("Dato: {value}"),
    Some(Err(e)) => println!("Error: {e}"),
    None => println!("Vacío"),
    
    // Bindings con @
    n @ 100..=999 => println!("Tres dígitos: {n}"),
    
    // Guards
    x if x > 0 && x < 100 => "positivo pequeño",
    
    // Wildcards
    _ => "otros",
}
```

### 8.2 Patrones en Let Bindings

```rust
// irrefutable patterns
let (a, b, c) = (1, 2, 3);
let Punto { x, y } = punto;
let Some(valor) = opcion else { return Err("vacío") };

// if let
if let Some(valor) = opcion {
    procesar(valor);
}

// while let
while let Some(item) = iter.next() {
    procesar(item);
}
```

### 8.3 Patrones en Funciones

```rust
// Irrefutable patterns en argumentos
fn distancia(Punto { x: x1, y: y1 }: &Punto, Punto { x: x2, y: y2 }: &Punto) -> f64 {
    ((x2 - x1).powi(2) + (y2 - y1).powi(2)).sqrt()
}

// Refutable patterns en closures
let procesar = |Some(valor)| valor * 2;  // Error: refutable
```

### 8.4 Exhaustiveness con Tipos Vacíos

```rust
enum Vacio {}  // Sin variantes

// Match exhaustivo sin patrones
let v: Vacio = unsafe { std::mem::unreachable() };
match v {}  // Vacío: no hay casos que manejar

// Útil para typestate patterns
enum SoloLectura {}
enum LecturaEscritura {}

struct Archivo<Estado> {
    handle: i32,
    _estado: std::marker::PhantomData<Estado>,
}

impl Archivo<LecturaEscritura> {
    fn escribir(&mut self, data: &[u8]) { /* ... */ }
}

impl Archivo<SoloLectura> {
    fn escribir(&mut self, data: &[u8]) {
        // Error de compilación: tipo no tiene este método
    }
}
```

---

## 9. Propuesta Concreta para Astra

### 9.1 Filosofía de Diseño

Astra hereda de la arquitectura existente:
- **ARC/ORC** como modelo de memoria (como Nim)
- **Inmutabilidad por defecto** (`val` = inmutable)
- **Sintaxis limpia** estilo Swift/Python
- **Hilos verdes** (M:N fibers)
- **Strong static typing** con inferencia

Para ADTs, la recomendación es: **modelo Rust con sintaxis simplificada**.

### 9.2 Declaración de Enums (Sum Types)

```astra
# Enum simple (sin datos)
enum Color {
    Rojo
    Verde
    Azul
    Negro
}

# Enum con datos asociados (ADT completo)
enum Forma {
    Circulo(Float)
    Rectangulo(ancho: Float, alto: Float)
    Triangulo(a: Float, b: Float, c: Float)
}

# Enum con variantes unnamed y named mezcladas
enum Mensaje {
    Reniciar                        # unit variant
    Mover(x: Int, y: Int)          # named fields
    Escribir(String)               # unnamed field
    CambiarColor(Color)            # tipo personalizado
}

# Recursive enum (usa puntero implícito para ciclos)
enum Arbol<T> {
    Hoja
    Nodo(valor: T, izq: Box<Arbol<T>>, der: Box<Arbol<T>>)
}

# Empty type (sin variantes)
enum Imposible {}
```

### 9.3 Declaración de Structs (Product Types)

```astra
# Product type con campos nombrados
struct Punto {
    x: Float
    y: Float
}

# Product type posicional (tuple struct)
struct Milisegundos(Int)

# Unit type
struct Metadata
```

### 9.4 Pattern Matching

```astra
# match como expresión (retorna valor)
fn area(forma: Forma) -> Float {
    match forma {
        Circulo(r) => Float.PI * r * r
        Rectangulo(ancho, alto) => ancho * alto
        Triangulo(a, b, c) =>
            let s = (a + b + c) / 2.0
            sqrt(s * (s-a) * (s-b) * (s-c))
    }
}

# match como statement (ejecuta efectos)
fn imprimir/forma: Forma) {
    match forma {
        Circulo(r) => println("Radio: {r}")
        Rectangulo(w, h) => println("Ancho: {w}, Alto: {h}")
        Triangulo(a, b, c) => println("Lados: {a}, {b}, {c}")
    }
}

# Guards
fn clasificar/forma: Forma) -> String {
    match forma {
        Circulo(r) if r < 0.0 => "Radio negativo"
        Circulo(r) if r > 100.0 => "Círculo grande"
        Circulo(_) => "Círculo normal"
        Rectangulo(w, h) if w == h => "Cuadrado"
        Rectangulo(w, h) => "Rectángulo"
        Triangulo(_, _, _) => "Triángulo"
    }
}

# Or-patterns
fn es_primario(color: Color) -> Bool {
    match color {
        Rojo | Verde | Azul => true
        _ => false
    }
}

# Nested patterns
fn descripcion(mensaje: Mensaje) -> String {
    match mensaje {
        Reniciar => "Reinicio del sistema"
        Mover(x, y) if x < 0 || y < 0 => "Movimiento negativo"
        Mover(x, y) => "Mover a ({x}, {y})"
        Escribir(texto) => "Escribir: {texto}"
        CambiarColor(Rojo) => "Cambio a rojo"
        CambiarColor(c) => "Cambio de color"
    }
}

# Ranges
fn es_valido_edad(edad: Int) -> Bool {
    match edad {
        0..=125 => true
        _ => false
    }
}

# Bindings con @
fn procesar数值(n: Int) -> String {
    match n {
        n @ 0..=9 => "Dígito: {n}"
        n @ 10..=99 => "Dos dígitos: {n}"
        n => "Otro: {n}"
    }
}
```

### 9.5 Patrones en Otras Posiciones

```astra
# if let (destructuring condicional)
if let Some(valor) = buscar_dato(indice) {
    procesar(valor)
}

# let else (destructuring con fallback)
let Some(valor) = buscar_dato(indice) else {
    return Err("Dato no encontrado")
}

# while let
while let Some(item) = iterator.siguiente() {
    procesar(item)
}

# Patrones en argumentos de función
fn distancia(Punto(x1, y1): Punto, Punto(x2, y2): Punto) -> Float {
    sqrt((x2-x1)^2 + (y2-y1)^2)
}

# Patrones en closures
let procesar = fn(Some(valor)) { valor * 2 }
```

### 9.6 Option y Result: Integración Nativa

```astra
# Option<T> y Result<T, E> son built-in (no requieren definición)
# Se comportan como enums algebraicos

# Option<T>
enum Option<T> {
    Some(T)
    None
}

# Result<T, E>
enum Result<T, E> {
    Ok(T)
    Err(E)
}

# Uso idiomático
fn dividir(a: Float, b: Float) -> Option<Float> {
    if b == 0.0 { None } else { Some(a / b) }
}

# Propagación con ?
fn procesar(datos: Array<Int>) -> Result<Int, Error> {
    let primero = datos.get(0)?    # Si None/Err, retorna
    let segundo = datos.get(1)?
    return Ok(primero + segundo)
}

# Combinadores
let resultado = dividir(10.0, 3.0)
    .map(|r| r * 2.0)
    .filter(|r| *r > 5.0)
    .unwrap_or(0.0)

# Pattern matching explícito
match dividir(10.0, 3.0) {
    Some(r) => println("Resultado: {r}")
    None => println("División por cero")
}
```

### 9.7 Exhaustiveness Checking: Estrategia

**Decisión: Compile error por defecto (como Rust)**

Justificación:
- Astra es un lenguaje de sistemas con safety guarantees
- ARC/ORC ya proporciona memory safety; exhaustiveness completa esta safety
- Evita la categoría de bugs donde se agrega un caso y se olvida actualizar un match
- Consistente con la filosofía de "make invalid states unrepresentable"

```astra
enum Estado { Activo, Inactivo, Suspendido }

fn descripcion(estado: Estado) -> String {
    match estado {
        Activo => "Activo"
        Inactivo => "Inactivo"
        # Error de compilación: `Suspendido` not covered
    }
}

# Solución: cubrir todos los casos
fn descripcion(estado: Estado) -> String {
    match estado {
        Activo => "Activo"
        Inactivo => "Inactivo"
        Suspendido => "Suspendido"
    }
}

# O usar wildcard explícito
fn descripcion(estado: Estado) -> String {
    match estado {
        Activo => "Activo"
        _ => "Otro estado"
    }
}
```

**`@non_exhaustive` para bibliotecas:**

```astra
# En una biblioteca
@non_exhaustive
enum ErrorAPI {
    Timeout
    NotFound
    ServerError(Int)
}

# Consumidor DEBE usar wildcard
fn manejar_error(err: ErrorAPI) {
    match err {
        Timeout => println("Timeout")
        NotFound => println("No encontrado")
        ServerError(codigo) => println("Error {codigo}")
        _ => println("Error desconocido")  # Requerido por @non_exhaustive
    }
}
```

### 9.8 Integración con ARC/ORC

**Problema:** Los enums contienen datos. Si esos datos son referencias (strings, arrays, otros objetos), ARC/ORC debe manejarlos correctamente.

**Solución: Enum variants con datos heredan el lifecycle management de sus campos**

```astra
enum Mensaje {
    Texto(String)           # String es heap-allocated, ARC gestiona
    Binary(Array<Byte>)     # Array es heap-allocated, ARC gestiona
    Vacío                   # Sin datos, sin overhead de ARC
}

# ARC opera sobre el payload del enum:
# - Al crear Mensaje::Texto(s), ARC incrementa count de `s`
# - Al destruir el enum, ARC decrementa count
# - Si count llega a 0, libera la memoria
# - ORC detecta ciclos si los datos forman grafos cíclicos
```

**Reglas de integración:**
1. Cada campo de cada variante se gestiona con ARC/ORC independientemente
2. El enum en sí es un valor en stack (o Box<Enum> en heap si es grande)
3. Pattern matching extrae los campos sin copiar (borrowing)
4. Move semantics: al mover un enum, se transfieren todas las referencias

```astra
# Borrowing en pattern matching
fn procesar(mensaje: &Mensaje) {
    match mensaje {
        Texto(ref texto) => println("Texto: {texto}")  # borrow
        Binary(ref datos) => procesar_binary(datos)     # borrow
        Vacío => println("Vacío")
    }
}

# Move semantics
fn consumir(mensaje: Mensaje) {
    match mensaje {
        Texto(texto) => guardar(texto)  # texto se mueve
        Binary(datos) => procesar(datos) # datos se mueven
        Vacío => {}
    }
    # mensaje ya no es válido después del match
}
```

### 9.9 Recursive Types y Box<T>

```astra
# Recursive enum requiere Box<T> (heap allocation explícita)
enum Lista<T> {
    Nil
    Cons(valor: T, siguiente: Box<Lista<T>>)
}

# Construcción
let lista = Cons(1, Box::new(Cons(2, Box::new(Cons(3, Box::new(Nil))))))

# Pattern matching recursivo
fn longitud<T>(lista: &Lista<T>) -> Int {
    match lista {
        Nil => 0
        Cons(_, siguiente) => 1 + longitud(siguiente)
    }
}

# Binary tree
enum Arbol<T> {
    Hoja
    Nodo(valor: T, izq: Box<Arbol<T>>, der: Box<Arbol<T>>)
}

fn inorder<T: Display>(arbol: &Arbol<T>) -> String {
    match arbol {
        Hoja => "".to_string()
        Nodo(valor, izq, der) => {
            format!("{} {} {}", inorder(izq), valor, inorder(der))
        }
    }
}
```

### 9.10 Typestate Pattern

```astra
# Estados vacíos para typestate
enum Abierto {}
enum Cerrado {}

struct Archivo<Estado> {
    handle: FileHandle,
    _estado: PhantomData<Estado>
}

# Métodos disponibles según estado
impl Archivo<Cerrado> {
    fn abrir(ruta: String) -> Archivo<Abierto> {
        let handle = File::open(ruta)
        Archivo { handle, _estado: PhantomData }
    }
}

impl Archivo<Abierto> {
    fn leer(&self) -> String {
        self.handle.read_all()
    }
    
    fn cerrar(self) -> Archivo<Cerrado> {
        self.handle.close()
        Archivo { handle: self.handle, _estado: PhantomData }
    }
}

# Error de compilación: Archivo<Cerrado> no tiene método leer()
# let archivo: Archivo<Cerrado> = ...
# archivo.leer()  # ERROR
```

---

## 10. Sintaxis Resumida

### 10.1 Declaraciones

```astra
# Enums
enum Forma {
    Circulo(Float)
    Rectangulo(ancho: Float, alto: Float)
}

# Structs
struct Punto { x: Float, y: Float }

# Empty type
enum Imposible {}
struct Unit
```

### 10.2 Pattern Matching

```astra
# match expression
let area = match forma {
    Circulo(r) => PI * r * r
    Rectangulo(w, h) => w * h
}

# if let
if let Some(x) = opcion { procesar(x) }

# let else
let Some(x) = opcion else { return None }

# while let
while let Some(item) = iter.next() { procesar(item) }
```

### 10.3 Patrones

```astra
# Literales
0 | 1 | 2 => "pequeño"

# Ranges
0..=100 => "rango"

# Guards
x if x > 0 => "positivo"

# Nested
Some(Ok(x)) => x

# Bindings
n @ 10..=99 => procesar(n)

# Wildcards
_ => "otros"
```

---

## 11. Decisiones de Diseño Clave

| Decisión | Elección | Alternativa Rechazada | Razón |
|----------|---------|----------------------|-------|
| Exhaustiveness | Compile error | Warning | Consistente con safety guarantees de Astra |
| Keywords | `enum` + `struct` | `data` (Haskell) | Familiaridad para programadores de C/Rust |
| Pattern matching | `match` expression | `switch` (C/Java) | Expressions > statements |
| Option/Result | Built-in enums | Nullable types | Type safety, composition |
| Recursive types | `Box<T>` explícito | Implicit heap | Compatibilidad con ARC/ORC, zero-cost |
| Associated values | `Variant(Tipo)` | `Variant { field: Tipo }` | Consistente, compacto |
| Guard syntax | `if condición` | `when condición` | Consistente con `if let` |
| Niche optimization | Soportada | No soportada | Zero-cost abstractions |

---

## 12. Casos de Uso Avanzados

### 12.1 AST para un Lenguaje

```astra
enum Expr {
    Lit(Int)
    Add(Box<Expr>, Box<Expr>)
    Mul(Box<Expr>, Box<Expr>)
    Var(String)
    Let(nombre: String, tipo: Tipo, valor: Box<Expr>, cuerpo: Box<Expr>)
}

fn eval(env: &Env, expr: &Expr) -> Result<Int, Error> {
    match expr {
        Lit(n) => Ok(*n)
        Add(l, r) => Ok(eval(env, l)? + eval(env, r)?)
        Mul(l, r) => Ok(eval(env, l)? * eval(env, r)?)
        Var(nombre) => env.buscar(nombre).ok_or(Error::VariableNoEncontrada(nombre.clone()))
        Let(nombre, _, valor, cuerpo) => {
            let val = eval(env, valor)?;
            let mut nuevo_env = env.extend(nombre.clone(), val);
            eval(&nuevo_env, cuerpo)
        }
    }
}
```

### 12.2 State Machine

```astra
enum EstadoConexion {
    Desconectado
    Conectando(socket: TcpSocket)
    Conectado(socket: TcpSocket, sesion: Sesion)
    Error(msg: String)
}

fn siguiente(estado: EstadoConexion, evento: Evento) -> EstadoConexion {
    match (estado, evento) {
        (Desconectado, Evento::IniciarConexión(addr)) =>
            Conectando(TcpSocket::new(addr))
        
        (Conectando(socket), Evento::ConexionEstablecida) =>
            Conectado(socket, Sesion::nueva())
        
        (Conectando(_), Evento::Error(msg)) =>
            Error(msg)
        
        (Conectado(socket, sesion), Evento::Datos(data)) =>
            Conectado(socket, sesion.procesar(data))
        
        (Conectado(_, _), Evento::Desconectar) =>
            Desconectado
        
        (Error(_), Evento::Reintentar) =>
            Desconectado
        
        _ => estado  # Sin cambio
    }
}
```

### 12.3 JSON Value

```astra
enum JsonValue {
    JNull
    JBool(Bool)
    JInt(Int)
    JFloat(Float)
    JString(String)
    JArray(Array<JsonValue>)
    JObject(Map<String, JsonValue>)
}

fn serializar(json: &JsonValue) -> String {
    match json {
        JNull => "null".to_string()
        JBool(b) => b.to_string()
        JInt(n) => n.to_string()
        JFloat(f) => f.to_string()
        JString(s) => format!("\"{s}\"")
        JArray(items) => {
            let elementos: Array<String> = items.map(|v| serializar(v))
            format!("[{}]", elementos.join(", "))
        }
        JObject(map) => {
            let pares: Array<String> = map.map(|(k, v)| 
                format!("\"{k}\": {}", serializar(v))
            )
            format!("{{{}}}", pares.join(", "))
        }
    }
}
```

---

## 13. Comparación Final: Astra vs Lenguajes Existentes

| Característica | Astra (propuesto) | Rust | Swift | Haskell | Kotlin |
|---------------|-------------------|------|-------|---------|--------|
| Enum ADTs | ✓ Nativo | ✓ Nativo | ✓ Nativo | ✓ Nativo | ✓ Sealed |
| Exhaustiveness | Error (default) | Error | Error | Warning | Error (expresión) |
| Pattern matching | Expresión | Expresión | Expresión | Expresión | when expression |
| Guards | `if cond` | `if cond` | `where` | `| guard` | `when` guard |
| Or-patterns | ✓ | ✓ | ✓ | ✓ | ✗ |
| Ranges | ✓ | ✓ | ✓ | ✗ | ✓ (limited) |
| Nested | ✓ | ✓ | ✓ | ✓ | ✓ |
| Typestate | ✓ (phantom) | ✓ (phantom) | ✗ | ✓ (GADTs) | ✗ |
| Niche optimization | ✓ (规划) | ✓ | ✓ | ✓ (GHC) | ✗ |
| ARC/ORC integration | Nativo | N/A (ownership) | Nativo (ARC) | GC | GC |
| Recursive | `Box<T>` | `Box<T>` | `indirect` | Nativo | Nativo |
| Memory safety | ARC/ORC + exhaustiveness | Ownership | ARC | GC | GC |

---

## 14. Próximos Pasos

1. **Semántica formal:** Definir las reglas de exhaustiveness checking formalmente
2. **Integración con type inference:** Cómo afecta pattern matching a la inferencia de tipos
3. **Interop con C:** Representación de enums en FFI (`@repr(C)` o similar)
4. **Derivation traits:** `derive(Eq, Debug, Clone, Serialize)` automático
5. **Pattern synonyms:** Alias de patrones para reutilización
6. **Compiler diagnostics:** Mensajes de error ricos para exhaustiveness

---

## Referencias

1. Maranget, L. (2008). "Compiling Pattern Matching to Good Decision Trees." ML Workshop.
2. Ramsey, N. (1999). "When Do Match-Compilation Heuristics Matter?" CMU.
3. The Rust Reference: Pattern Matching. https://doc.rust-lang.org/reference/
4. Swift Evolution SE-0055: Enums with Associated Values.
5. Haskell Report: Algebraic Data Types.
6. Astra Architecture v0.1: `ARCHITECTURE.md`
7. Nim ORC: https://nim-lang.org/blog/2020/12/08/introducing-orc.html
