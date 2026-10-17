# Astra Language Design Report: Compile-Time Serialization & Custom Allocators

## Topic 1: Compile-Time Serialization (JSON/Protobuf/TOML)

---

### 1. Derive-Based Serialization: How Existing Languages Work

#### 1.1 Rust `serde` — The Gold Standard

Rust's `serde` is the most influential compile-time serialization framework. It operates entirely without runtime reflection via a trait-based derive system.

**Core architecture:**
- `Serialize` trait: data structures implement this to describe their fields
- `Serializer` trait: data formats (JSON, TOML, etc.) implement this
- The two traits interact generically — any serializable type works with any format

**Automatic derivation:**

```rust
use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize, Debug)]
struct Point {
    x: i32,
    y: i32,
}

fn main() {
    let point = Point { x: 1, y: 2 };
    let json = serde_json::to_string(&point).unwrap();
    // {"x":1,"y":2}
    let deserialized: Point = serde_json::from_str(&json).unwrap();
}
```

**Attribute-based customization:**

```rust
#[derive(Serialize, Deserialize)]
struct UserProfile {
    #[serde(rename = "user_name")]
    name: String,

    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,

    #[serde(default)]
    age: u32,

    #[serde(flatten)]
    metadata: HashMap<String, String>,

    #[serde(rename_all = "camelCase")]
    created_at: String,
}
```

**Nested structs and enums:**

```rust
#[derive(Serialize, Deserialize)]
enum Message {
    Quit,
    Move { x: i32, y: i32 },
    Write(String),
    Color(i32, i32, i32),
}

#[derive(Serialize, Deserialize)]
struct Chat {
    messages: Vec<Message>,
    #[serde(default)]
    pinned: bool,
}
```

**Key design insight:** `serde` achieves zero-cost abstraction. The compiler monomorphizes the serialization code for each concrete type, eliminating all dynamic dispatch. Benchmarks show hand-written serializers are often no faster than `serde`-generated code.

#### 1.2 Swift `Codable`

Swift's `Codable` uses protocol conformance with compiler synthesis, but takes a different approach from `serde` by introducing an intermediate "container" abstraction.

**Core architecture:**
- `Encodable` protocol: `func encode(to encoder: Encoder) throws`
- `Decodable` protocol: `init(from decoder: Decoder) throws`
- `Codable` = `Encodable & Decodable`

**Automatic synthesis:**

```swift
struct User: Codable {
    var name: String
    var age: Int
}

// The compiler synthesizes encode(to:) and init(from:) automatically
let user = User(name: "John", age: 31)
let data = try JSONEncoder().encode(user)
let decoded = try JSONDecoder().decode(User.self, from: data)
```

**Key renaming via `CodingKey`:**

```swift
enum CodingKeys: String, CodingKey {
    case fullName = "full_name"
    case userAge = "user_age"
}

struct User: Codable {
    var fullName: String
    var userAge: Int
}
```

**Custom encoding/decoding:**

```swift
struct Temperature: Codable {
    var celsius: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fahrenheit = try container.decode(Double.self, forKey: .fahrenheit)
        celsius = (fahrenheit - 32) * 5 / 9
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(celsius * 9 / 5 + 32, forKey: .fahrenheit)
    }
}
```

**Trade-off vs serde:** Swift's approach is more ergonomic but relies on runtime type metadata for container navigation. This means slightly less optimal code generation compared to `serde`'s fully monomorphized approach, though the difference is negligible for most applications.

#### 1.3 Go `encoding/json`

Go uses struct tags for serialization metadata, relying on runtime reflection for encoding/decoding.

**Struct tag approach:**

```go
type User struct {
    Name     string `json:"name"`
    Age      int    `json:"age,omitempty"`
    Email    string `json:"-"`
    Password string `json:"-"` // omitted from JSON
}

type Config struct {
    Database struct {
        Host string `json:"host" toml:"host" yaml:"host"`
        Port int    `json:"port" toml:"port" yaml:"port"`
    } `json:"database" toml:"database" yaml:"database"`
}
```

**Limitations:**
- Runtime reflection causes allocations per decode operation
- No compile-time validation of tag syntax
- Performance degrades with deeply nested structures
- The `reflect` package cannot be eliminated by the compiler

**Go's mitigation:** `go generate` and code generators like `easyjson` and `ffjson` produce reflection-free marshalers at build time, acknowledging that the tag-based reflection approach has fundamental performance limitations.

#### 1.4 Comparative Analysis

| Feature | Rust serde | Swift Codable | Go json |
|---|---|---|---|
| Derivation mechanism | Proc macro | Compiler synthesis | Struct tags |
| Runtime reflection | None | Minimal | Heavy |
| Zero-allocation | Yes | Near-zero | No |
| Custom formats | Via trait | Via protocol | N/A |
| Schema evolution | Attribute-based | CodingKey enum | Manual |
| Compile-time errors | Yes (type-level) | Partial | No |

---

### 2. Compile-Time Code Generation

#### 2.1 How the Compiler Generates Serialization Code

The fundamental challenge: given a struct definition, the compiler must emit code that:

1. **Enumerates all fields** with their names and types
2. **Generates serialization logic** that visits each field
3. **Generates deserialization logic** that reads and validates each field
4. **Handles edge cases** like nested types, enums, and optionals

**Approach A: Procedural Macros (Rust serde_derive)**

The compiler invokes a macro at compile time that receives the AST of the annotated type and produces new code:

```
#[derive(Serialize)]
struct Point { x: i32, y: i32 }

// The macro generates approximately:
impl Serialize for Point {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Err> {
        let mut state = serializer.serialize_struct("Point", 2)?;
        state.serialize_field("x", &self.x)?;
        state.serialize_field("y", &self.y)?;
        state.end()
    }
}
```

**Approach B: Compiler-Built-in Synthesis (Swift)**

The Swift compiler has built-in knowledge of `Encodable`/`Decodable` and synthesizes the `init(from:)` and `encode(to:)` methods during type checking, without invoking external macros.

**Approach C: Code Generation Tools (Go)**

External tools (`protoc`, `stringer`, `easyjson`) parse source files and emit new `.go` files. The `go generate` directive runs these tools as part of the build process.

#### 2.2 Reflection Alternatives

Since Astra has no runtime reflection, the serialization system must use one of these strategies:

1. **Compile-time type introspection:** The compiler provides a built-in mechanism to inspect type layouts at compile time. This is the most ergonomic approach.

2. **Procedural macros/attributes:** External or built-in macros that transform annotated types into serialization implementations.

3. **Explicit schema definitions:** Separate schema files (like `.proto` files) that define the wire format independently of the language types.

4. **Hybrid:** Built-in type introspection with attribute-based customization.

#### 2.3 Zero-Allocation Deserialization Strategies

**Arena deserialization:**
```rust
// Concept: deserialize into an arena, all allocations are bump-pointer
let arena = Arena::new();
let config: Config = from_slice_arena(&data, &arena)?;
// arena.drop() frees everything at once
```

**Zero-copy deserialization:**
```rust
// Concept: borrowed data references the input buffer directly
struct Document<'a> {
    title: &'a str,        // borrowed from input
    body: &'a [u8],        // borrowed from input
    links: Vec<&'a str>,   // references into input
}
```

**Pre-sized buffers:**
```rust
// Concept: allocate output buffer with known size from schema
fn deserialize_into(data: &[u8], buf: &mut [u8]) -> Result<Config> {
    // Write directly into pre-allocated buffer
}
```

---

### 3. Format Support

#### 3.1 JSON

- **Text-based:** Human-readable, verbose
- **No schema:** Types must be inferred or defined in the language
- **Key constraints:** String keys only, no binary data, no comments
- **Use cases:** Web APIs, configuration files, logging

#### 3.2 TOML

- **Text-based:** Human-readable, designed for configuration
- **Explicit types:** `table`, `array`, `string`, `integer`, `float`, `boolean`, `datetime`
- **Nesting via tables:** `[section.subsection]` syntax
- **Use cases:** Configuration files (`Cargo.toml`, `pyproject.toml`)

#### 3.3 YAML

- **Text-based:** Human-readable, supports anchors and aliases
- **Superset of JSON:** More flexible syntax
- **Pitfalls:** Implicit type coercion, inconsistent parsing across implementations
- **Use cases:** CI/CD configs, Kubernetes manifests

#### 3.4 Protocol Buffers

- **Binary format:** Compact, fast, schema-based
- **Explicit field numbering:** Fields identified by number, not name
- **Schema evolution rules:**
  - Add new fields with new numbers (backward compatible)
  - Never reuse field numbers
  - Mark fields as `reserved` when removed
  - Use `optional` for fields that can be absent

```protobuf
message Person {
  string name = 1;
  int32 id = 2;
  string email = 3;

  enum PhoneType {
    MOBILE = 0;
    HOME = 1;
    WORK = 2;
  }

  message PhoneNumber {
    string number = 1;
    PhoneType type = 2;
  }

  repeated PhoneNumber phones = 4;
}
```

**Editions system (2024+):** Replaces `syntax = "proto2"` / `syntax = "proto3"` with feature-based configuration, enabling gradual evolution without hard forks.

#### 3.5 MessagePack

- **Binary format:** Like JSON but more compact and faster to parse
- **Self-describing:** Includes type information in the wire format
- **No schema required:** Flexible but less type-safe
- **Use cases:** Inter-process communication, caching

#### 3.6 Schema Evolution and Backward Compatibility

**Protobuf compatibility rules:**

| Change | Backward | Forward | Full |
|---|---|---|---|
| Add optional field | ✓ | ✓ | ✓ |
| Remove optional field | ✓ | ✓ | ✓ |
| Add required field | — | ✓ | — |
| Remove required field | ✓ | — | — |
| Add enum variant | ✓ | ✓ | ✓ |
| Change field number | ✗ | ✗ | ✗ |
| Change field type | Conditional | Conditional | ✗ |

**Key principle:** Field numbers are the stable identity in protobuf. Field names are for human readability only and can be changed freely.

---

### 4. Recommendation for Astra: Concrete Syntax Proposal

#### 4.1 Design Principles

1. **No runtime reflection:** All serialization code generated at compile time
2. **Derive-based:** Attribute annotations on types
3. **Format-agnostic:** Single derive works with all formats
4. **Zero-allocation option:** Arena-based deserialization for performance-critical paths
5. **Schema evolution:** Built-in support for field versioning

#### 4.2 Proposed Syntax

**Basic derivation:**

```astra
// Derive serialization for a struct
@serialize
struct Point {
    x: i32,
    y: i32,
}

// Usage
let point = Point { x: 1, y: 2 };
let json = point.to_json()?;
let toml = point.to_toml()?;
let proto = point.to_protobuf()?;

let restored: Point = Point::from_json(json)?;
```

**Attribute-based customization:**

```astra
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

    @rename_all("camelCase")
    created_at: Timestamp,
}
```

**Enums:**

```astra
@serialize
enum Message {
    Quit,
    Move { x: i32, y: i32 },
    Write(String),
    Color(i32, i32, i32),
}

// JSON representation:
// {"Quit": null} or {"Move": {"x": 1, "y": 2}}
```

**Protobuf-specific annotations:**

```astra
@serialize(protocol = "protobuf")
@proto_package("mypackage.v1")
struct Person {
    @proto_number(1)
    name: String,

    @proto_number(2)
    id: i32,

    @proto_number(3)
    @proto_optional
    email: Option<String>,

    @proto_number(4)
    phones: Vec<PhoneNumber>,
}

@serialize(protocol = "protobuf")
@proto_package("mypackage.v1")
struct PhoneNumber {
    @proto_number(1)
    number: String,

    @proto_number(2)
    type: PhoneType,
}

@proto_enum
enum PhoneType {
    @proto_value(0) Mobile,
    @proto_value(1) Home,
    @proto_value(2) Work,
}
```

**Schema evolution with versioning:**

```astra
@serialize
struct Config {
    @since(1)
    name: String,

    @since(1)
    version: i32,

    @since(2)
    @optional
    debug: bool,

    @since(3)
    @default(0)
    max_retries: i32,

    @deprecated(2, use: "new_setting")
    old_setting: String,
}
```

**Zero-allocation deserialization:**

```astra
// Arena-based: all allocations from the arena
let arena = Arena::new();
let config = Config::from_json_arena(data, &arena)?;
// config borrows strings from arena
// arena.drop() frees everything at once

// Zero-copy: borrows directly from input buffer
let config = Config::from_json_zero_copy(data)?;
// config.title: &str points into `data`
```

**Format-agnostic derivation:**

```astra
// One derive, all formats
@serialize(formats = [json, toml, protobuf, msgpack])
struct ApiConfig {
    host: String,
    port: u16,
    #[serde(default = "default_timeout")]
    timeout_ms: u64,
}

fn default_timeout() -> u64 { 5000 }

// Generic serialization
fn save<T: Serialize>(value: &T, format: Format) -> Bytes {
    match format {
        Format::Json => value.to_json(),
        Format::Toml => value.to_toml(),
        Format::Protobuf => value.to_protobuf(),
        Format::Msgpack => value.to_msgpack(),
    }
}
```

**Schema definition file (optional, for protobuf compatibility):**

```astra
// schema.astra
package mypackage.v1;

message Person {
    string name = 1;
    int32 id = 2;
    optional string email = 3;
    repeated PhoneNumber phones = 4;
}

message PhoneNumber {
    string number = 1;
    PhoneType type = 2;
}

enum PhoneType {
    MOBILE = 0;
    HOME = 1;
    WORK = 2;
}
```

The compiler generates Astra structs from the schema file, ensuring wire-format compatibility with protobuf consumers.

---

## Topic 2: Custom Allocators

---

### 1. Allocator Interfaces: How Languages Handle Custom Allocation

#### 1.1 Zig — The Allocator Interface

Zig's allocator model is the cleanest design among modern systems languages. Every allocator implements the same interface, and all standard library data structures accept an allocator parameter.

**Core interface:**

```zig
// From std.mem.Allocator
pub const Allocator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        alloc: *const fn (ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8,
        resize: *const fn (ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool,
        free: *const fn (ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void,
    };
};
```

**Built-in allocators:**

```zig
// Page allocator (OS-backed, one syscall per alloc)
var page_alloc = std.heap.page_allocator;

// Arena allocator (bulk free)
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const alloc = arena.allocator();

// Fixed buffer (no heap allocation)
var buf: [1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);
const alloc = fba.allocator();

// General-purpose debug allocator (detects leaks, double-frees)
var gpa = std.heap.DebugAllocator(.{}){};
defer _ = gpa.deinit();
const alloc = gpa.allocator();

// SMP allocator (optimized for multithreaded)
const alloc = std.heap.smp_allocator;
```

**Usage pattern — allocators passed explicitly:**

```zig
fn processData(allocator: std.mem.Allocator) !void {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    try list.appendSlice("hello");
    try list.append(' ');
    try list.appendSlice("world");
}
```

**Key design decision:** Zig has zero hidden allocations. Every allocation in the standard library requires an explicit allocator parameter. This gives full control but increases verbosity.

#### 1.2 Rust — The `Allocator` Trait (Nightly)

Rust's allocator system is split between the stable `GlobalAlloc` trait and the nightly `Allocator` trait.

**Core trait:**

```rust
pub unsafe trait Allocator {
    fn allocate(&self, layout: Layout) -> Result<NonNull<[u8]>, AllocError>;

    unsafe fn deallocate(&self, ptr: NonNull<u8>, layout: Layout);

    fn grow(&self, ptr: NonNull<u8>, old_layout: Layout, new_layout: Layout) -> Result<NonNull<[u8]>, AllocError> {
        // default: allocate + copy + free
    }

    fn shrink(&self, ptr: NonNull<u8>, old_layout: Layout, new_layout: Layout) -> Result<NonNull<[u8]>, AllocError> {
        // default: allocate + copy + free
    }

    fn by_ref(&self) -> &Self where Self: Sized { self }
}
```

**Allocator-aware collections:**

```rust
use std::alloc::{Allocator, Global};
use bumpalo::Bump;

// Default: Global allocator (System malloc)
let mut vec: Vec<i32> = Vec::new();

// Custom allocator
let bump = Bump::new();
let mut vec: Vec<i32, &Bump> = Vec::new_in(&bump);

// Arena-based allocation
let mut vec: Vec<String, &Bump> = Vec::new_in(&bump);
vec.push("hello".to_string()); // allocated from bump, not system heap
// bump.drop() frees everything
```

**Key design point:** Rust's `Allocator` trait is generic over `Allocator` parameter on collections. `Vec<T, A = Global>` means you can use any allocator, but the default is the system allocator.

#### 1.3 C++ — `std::pmr::memory_resource`

C++17 introduced polymorphic memory resources (PMR) for runtime-polymorphic allocation.

**Core interface:**

```cpp
class memory_resource {
public:
    virtual ~memory_resource() = default;

    virtual void* do_allocate(size_t bytes, size_t alignment) = 0;
    virtual void do_deallocate(void* p, size_t bytes, size_t alignment) = 0;
    virtual bool do_is_equal(const memory_resource& other) const noexcept = 0;

    void* allocate(size_t bytes, size_t alignment = alignof(max_align_t)) {
        return do_allocate(bytes, alignment);
    }

    void deallocate(void* p, size_t bytes, size_t alignment = alignof(max_align_t)) {
        do_deallocate(p, bytes, alignment);
    }
};
```

**Polymorphic allocator:**

```cpp
template <class T = byte>
class polymorphic_allocator {
    memory_resource* memory_rsrc;
public:
    // Allocates from the underlying memory_resource
    T* allocate(size_t n) {
        return static_cast<T*>(memory_rsrc->allocate(n * sizeof(T), alignof(T)));
    }

    void deallocate(T* p, size_t n) {
        memory_rsrc->deallocate(p, n * sizeof(T), alignof(T));
    }
};
```

**Built-in resources:**

```cpp
// Default: malloc/free
auto* default_res = std::pmr::get_default_resource();

// Pool allocator
std::pmr::monotonic_buffer_resource pool_res{initial_buf, sizeof(initial_buf)};

// Container using pool allocator
std::pmr::vector<int> vec{&pool_res};
vec.push_back(42); // allocated from pool

// Synchronized pool (thread-safe)
std::pmr::synchronized_pool_resource sync_pool;

// Null allocator (for measuring allocation costs)
auto* null_res = std::pmr::null_memory_resource(); // throws on alloc
```

**Usage in containers:**

```cpp
// PMR containers use runtime polymorphism
using pool_string = std::pmr::string;
using pool_vector = std::pmr::vector<pool_string>;

std::pmr::monotonic_buffer_resource pool;

pool_vector names{&pool};
names.push_back(pool_string("Alice", &pool));
names.push_back(pool_string("Bob", &pool));
// All memory freed when pool is destroyed
```

#### 1.4 Standard Allocators Summary

| Allocator | Strategy | Use Case |
|---|---|---|
| `malloc/free` | General-purpose | Default fallback |
| Arena | Bump-pointer, bulk free | Phase-based allocation |
| Pool | Fixed-size blocks, O(1) alloc/free | Many same-sized objects |
| Bump | Pointer increment, no individual free | Parse trees, compilers |
| Stack | LIFO allocation | Temporary buffers, recursive algorithms |
| FixedBuffer | Pre-allocated static buffer | Embedded, no-heap contexts |
| Slab | Fixed-size chunks per size class | Kernel objects, allocators |
| Thread-local | Per-thread free lists | Multithreaded allocators |

---

### 2. Use Cases

#### 2.1 Game Engines — Frame Allocators

```astra
// Game loop frame allocator
fn game_loop() {
    let frame_arena = Arena::new(); // fresh each frame

    for entity in world.query::<Physics>() {
        let transform = frame_arena.alloc(Transform::default());
        transform.position = entity.position + entity.velocity * dt;
        // No individual free needed — arena resets at frame end
    }

    // All frame memory freed in one operation
    frame_arena.reset();
}
```

**Why this matters:** Game engines allocate thousands of short-lived objects per frame (transforms, particles, temporary vectors). An arena allocator eliminates the overhead of individual `free` calls and prevents fragmentation.

#### 2.2 Embedded Systems — No Heap

```astra
// Embedded system with no heap
@allocator(Static(4096))
struct EmbeddedApp {
    buffer: [u8; 4096],
}

fn main() !void {
    // Stack-allocated buffer, no malloc/free needed
    var buf: [256]u8 = undefined;
    var fba = FixedBufferAllocator.init(&buf);

    var parser = JsonParser.init(fba.allocator());
    defer parser.deinit();

    let result = try parser.parse(input);
    // All memory from fba, no heap allocation
}
```

#### 2.3 High-Frequency Trading — Zero Allocation Hot Path

```astra
// Trading engine: hot path must allocate nothing
@allocator(Bump)
struct TradingEngine {
    order_arena: BumpAllocator,  // reset every microsecond
    tick_arena: BumpAllocator,   // reset every tick
}

fn process_tick(engine: *TradingEngine, tick: Tick) !void {
    engine.tick_arena.reset(); // O(1) — no individual frees

    let orders = try engine.tick_arena.alloc_slice(Order, tick.orders.len);
    for tick.orders, 0.. |order, i| {
        orders[i] = Order{
            .id = order.id,
            .price = order.price,
            .quantity = order.quantity,
        };
    }

    // All memory freed at once with reset()
    // Zero malloc calls in hot path
}
```

#### 2.4 Database Engines — Buffer Pool Management

```astra
// Database buffer pool: fixed-size page allocator
struct BufferPool {
    pages: [Page; MAX_PAGES]Page,
    free_list: std.ArrayList(usize),
}

impl BufferPool {
    fn alloc_page(self: *BufferPool) !*Page {
        let idx = self.free_list.pop() orelse return error.OutOfMemory;
        return &self.pages[idx];
    }

    fn free_page(self: *BufferPool, page: *Page) void {
        let idx = @intFromPtr(page) - @intFromPtr(&self.pages[0]);
        self.free_list.append(idx);
    }
}
```

---

### 3. Integration with ARC/ORC

#### 3.1 Can Custom Allocators Work with Reference Counting?

**Yes.** The reference count metadata must be co-located with the allocated object, and the allocator must handle the combined allocation (object + refcount). This is a solved problem in several languages.

**Rust's approach (nightly `Allocator` + `Arc`):**

```rust
// Arc<T, A> — allocator-aware Arc
use std::sync::Arc;
use bumpalo::Bump;

let bump = Bump::new();

// Arc allocated from the bump allocator
// Both the Arc control block AND the T are in the bump arena
let shared: Arc<String, &Bump> = Arc::new_in("hello".to_string(), &bump);

// Reference counting still works normally
let clone = Arc::clone(&shared);
// But the memory comes from bump, not the system heap
```

**Key insight:** The `Arc` layout becomes `[refcount | strong_count | weak_count | T]` — all allocated as a single allocation from the custom allocator. The reference counting machinery uses the same allocator for its metadata.

#### 3.2 How to Inject Allocator into ARC Machinery

**Memory layout for allocator-aware ARC:**

```
+------------------+------------------+------------------+------------------+
| Allocator State  | Weak Count (64)  | Strong Count (64)|      T           |
+------------------+------------------+------------------+------------------+
|                  |                  |                  |                  |
^                  ^                  ^                  ^
ptr (returned)     metadata ptr      metadata ptr       data ptr
```

**Implementation strategy:**

```astra
// Conceptual implementation
struct Arc<T, A: Allocator = Global> {
    ptr: *mut ArcInner<T, A>,
    allocator: A,
}

struct ArcInner<T, A: Allocator> {
    strong: atomic::AtomicU64,
    weak: atomic::AtomicU64,
    allocator: A,
    data: T,
}

impl<T, A: Allocator> Arc<T, A> {
    fn new_in(value: T, allocator: A) -> Self {
        let layout = Layout::new::<ArcInner<T, A>>();
        let ptr = allocator.allocate(layout) as *mut ArcInner<T, A>;

        unsafe {
            ptr.write(ArcInner {
                strong: atomic::AtomicU64::new(1),
                weak: atomic::AtomicU64::new(1),
                allocator: allocator.clone(),
                data: value,
            });
        }

        Arc { ptr, allocator }
    }

    fn clone(&self) -> Self {
        self.inner().strong.fetch_add(1, Ordering::Relaxed);
        Arc { ptr: self.ptr, allocator: self.allocator.clone() }
    }

    fn drop(&mut self) {
        if self.inner().strong.fetch_sub(1, Ordering::AcqRel) == 1 {
            unsafe {
                // Drop the data
                self.ptr.read().data.drop_in_place();
                // Free using the allocator
                self.allocator.deallocate(
                    self.ptr as *mut u8,
                    Layout::new::<ArcInner<T, A>>(),
                );
            }
        }
    }
}
```

**ORC integration (cycle detection):**

```astra
struct Orc<T, A: Allocator = Global> {
    ptr: *mut OrcInner<T, A>,
    allocator: A,
}

struct OrcInner<T, A: Allocator> {
    strong: atomic::AtomicU64,
    weak: atomic::AtomicU64,
    marked: atomic::AtomicBool,  // for cycle detection
    color: Color,                // for ORC coloring
    allocator: A,
    data: T,
}

impl<T, A: Allocator> Orc<T, A> {
    // ORC uses coloring to detect cycles efficiently
    fn drop_cycle(root: &Orc<T, A>) {
        // Walk the object graph, color objects
        // If an object is reachable from root AND has a cycle,
        // break the cycle by decrementing reference counts
        // All cycle participants are freed using their allocator
    }
}
```

**Key design requirements for Astra:**

1. **Co-allocated metadata:** The refcount, weak count, and allocator state are allocated in the same block as the object. This means a single allocation/deallocation for the entire `Arc`/`Orc`.

2. **Allocator must be clonable or stored in the control block:** The allocator is stored in the `ArcInner`/`OrcInner` struct, so `clone()` and `drop()` can access it.

3. **Type-erased deallocation:** The control block stores a function pointer for deallocation, so the correct allocator is used regardless of the concrete type `T`.

4. **ORC cycle detection must respect allocator boundaries:** Cycles that span different allocators should be detected and freed using the appropriate allocator for each object.

---

### 4. Recommendation for Astra: Concrete Proposal

#### 4.1 Allocator Interface

```astra
// Core allocator trait
trait Allocator {
    fn alloc(self: *Self, layout: Layout) ?*u8;
    fn free(self: *Self, ptr: *u8, layout: Layout) void;
    fn resize(self: *Self, ptr: *u8, old_layout: Layout, new_len: usize) ?*u8;
    fn clone(self: Self) Self;
}

// Layout describes size and alignment
struct Layout {
    size: usize,
    align: u24, // power-of-two, max 2^23
}
```

#### 4.2 Built-in Allocators

```astra
// Standard allocator implementations in std::alloc

// General-purpose (system malloc/free wrapper)
struct GlobalAllocator;

// Arena allocator (bulk free)
struct ArenaAllocator {
    backing: Allocator,
    // ... internal state
}

impl ArenaAllocator {
    fn new(backing: Allocator) Self;
    fn reset(self: *Self) void;          // free all at once
    fn snapshot(self: Self) ArenaSnapshot; // save state for selective rollback
}

// Fixed buffer allocator (no heap)
struct FixedBufferAllocator {
    buffer: []u8,
    offset: usize,
}

// Pool allocator (fixed-size blocks)
struct PoolAllocator {
    block_size: usize,
    backing: Allocator,
}

// Bump allocator (fastest, no individual free)
struct BumpAllocator {
    backing: Allocator,
    // ... internal state
}
```

#### 4.3 Allocator-Aware Smart Pointers

```astra
// ARC with custom allocator support
struct Arc<T, A: Allocator = Global> {
    inner: *mut ArcInner<T, A>,
    allocator: A,
}

struct ArcInner<T, A: Allocator = Global> {
    strong: AtomicU64,
    weak: AtomicU64,
    allocator: A,
    data: T,
}

// ORC with custom allocator and cycle detection
struct Orc<T, A: Allocator = Global> {
    inner: *mut OrcInner<T, A>,
    allocator: A,
}

struct OrcInner<T, A: Allocator = Global> {
    strong: AtomicU64,
    weak: AtomicU64,
    marked: AtomicBool,
    color: OrcColor,
    allocator: A,
    data: T,
}
```

#### 4.4 Usage Examples

```astra
// Example 1: Arena allocator for request processing
fn handle_request(request: Request) !Response {
    var arena = ArenaAllocator.new(std.heap.page_allocator);
    defer arena.reset(); // free everything at once

    let alloc = arena.allocator();
    let body = try parse_body(alloc, request.body);
    let result = try process(alloc, body);
    let response = try serialize(alloc, result);
    return response;
}

// Example 2: Game frame allocator
struct GameEngine {
    frame_arena: BumpAllocator,
    persistent: GlobalAllocator,
}

impl GameEngine {
    fn tick(self: *GameEngine) void {
        self.frame_arena.reset();

        // Short-lived allocations from bump allocator
        let transforms = try self.frame_arena.alloc_slice(
            Transform,
            self.entities.len,
        );

        // Long-lived allocations from global allocator
        let new_entity = try self.persistent.alloc(Entity);
    }
}

// Example 3: Embedded system with no heap
@target("embedded")
fn main() !void {
    var buffer: [4096]u8 = undefined;
    var fba = FixedBufferAllocator.init(&buffer);
    let alloc = fba.allocator();

    var parser = Parser.init(alloc);
    defer parser.deinit();

    let config = try parser.parse(config_bytes);
    // All memory from stack buffer, no heap
}

// Example 4: ARC with arena allocator
fn process_shared_data() void {
    var arena = ArenaAllocator.new(std.heap.page_allocator);
    let alloc = arena.allocator();

    // Both the refcount block AND the data are from the arena
    let shared = Arc::new_in(MyStruct { ... }, alloc);

    // Clone uses the same arena
    let clone = Arc::clone(&shared);

    // All freed when arena resets — no individual Arc::drop needed
    arena.reset();
}

// Example 5: Database buffer pool
struct Database {
    pool: BufferPool,
}

impl Database {
    fn query(self: *Database, sql: &str) !Result {
        // Temporary allocations from arena (reset per query)
        var arena = ArenaAllocator.new(self.pool.allocator());
        defer arena.reset();

        let plan = try self.plan_query(arena.allocator(), sql);
        let result = try self.execute(arena.allocator(), plan);
        return result;
    }
}
```

#### 4.5 Integration Rules

1. **All heap-allocating APIs accept an allocator parameter** — no hidden allocations
2. **`Arc<T>` and `Orc<T>` have an optional allocator type parameter** — defaults to `Global`
3. **Allocator is co-allocated in the control block** — single allocation for refcount + data
4. **`defer` pattern for cleanup** — `defer arena.reset()` or `defer alloc.free(ptr)`
5. **Zero-cost abstraction** — allocator is monomorphized, no dynamic dispatch in hot paths
6. **ORC respects allocator boundaries** — cycles within the same allocator are collected together

---

## Summary

### Serialization Recommendations for Astra

| Feature | Recommendation |
|---|---|
| Derivation | `@serialize` attribute with compiler synthesis |
| Customization | `@rename`, `@skip_if_none`, `@default`, `@flatten` |
| Protobuf | `@proto_number(N)` for field numbering, `.astra` schema files |
| Evolution | `@since(N)` and `@deprecated(N)` attributes |
| Zero-allocation | `from_json_arena()` and `from_json_zero_copy()` variants |
| Formats | JSON, TOML, Protobuf, MessagePack as standard |

### Allocator Recommendations for Astra

| Feature | Recommendation |
|---|---|
| Interface | `Allocator` trait with `alloc/free/resize/clone` |
| Default | `GlobalAllocator` wrapping system malloc |
| ARC/ORC | `Arc<T, A>` with co-allocated control block |
| Game engines | `BumpAllocator` per frame, `reset()` at frame end |
| Embedded | `FixedBufferAllocator` on stack buffer |
| HFT | `BumpAllocator` with microsecond-level resets |
| Databases | `PoolAllocator` for pages, `ArenaAllocator` per query |
