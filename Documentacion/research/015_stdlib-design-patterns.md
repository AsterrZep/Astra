# Astra Standard Library — Design Patterns & Recommendations

## Executive Summary

This report analyzes stdlib design patterns across Go, Rust, Zig, and Python, then provides concrete recommendations for Astra's standard library. Astra's unique position — ARC/ORC memory, green threads, Python/TypeScript ergonomics with C/Rust performance, dual execution modes — demands a stdlib that is neither maximally minimal (Rust) nor maximally comprehensive (Go), but **curated and principled**.

**Core recommendation:** Astra should ship ~35-40 modules (~1,500-2,000 public functions) in the "curated batteries" zone — enough that common tasks require zero external dependencies, small enough that every API is final-quality and the entire stdlib is maintainable.

---

## 1. Standard Library Organization

### 1.1 How Other Languages Do It

**Go** — Flat hierarchy, one import path per package:
```
std/
├── archive/    ├── compress/  ├── crypto/    ├── database/
├── debug/      ├── encoding/  ├── errors/    ├── expvar/
├── flag/       ├── fmt/       ├── go/        ├── hash/
├── html/       ├── index/     ├── io/        ├── log/
├── math/       ├── mime/      ├── net/       ├── os/
├── path/       ├── reflect/   ├── regexp/    ├── runtime/
├── sort/       ├── strconv/   ├── strings/   ├── sync/
├── testing/    ├── text/      ├── time/      └── unicode/
```
- ~150 packages, ~5,000+ functions
- Strict dependency lattice: leaf packages (unsafe, cmp) → runtime → syscall → str → os → fmt
- Everything needed for production HTTP servers ships in std

**Rust** — Three-crate layering:
```
library/
├── core/       # No allocation, no OS (no-std compatible)
│   ├── iter/   ├── option/   ├── result/    ├── fmt/
│   └── ...
├── alloc/      # Allocation types (Vec, Box, String)
│   └── vec/    ├── string/   ├── boxed/     └── collections/
└── std/        # Full OS features
    ├── collections/  ├── io/      ├── fs/      ├── net/
    ├── sync/         ├── thread/  ├── process/ └── ...
```
- ~50 modules, ~2,000 functions
- "Small stdlib + ecosystem" philosophy — HTTP, JSON, crypto are external crates
- Prelude imports core traits (Iterator, Option, Result, etc.)

**Zig** — Flat with domain groupings:
```
lib/std/
├── std.zig              # Root re-export
├── mem.zig              # Allocators, byte utilities (~195 KB)
├── heap.zig             # GeneralPurposeAllocator, ArenaAllocator
├── array_list.zig       # ArrayList (~93 KB)
├── hash_map.zig         # HashMap (~80 KB)
├── fmt.zig              # String formatting (~58 KB)
├── fs.zig               # Filesystem
├── posix.zig            # POSIX bindings (~263 KB)
├── crypto/              # Full crypto suite
├── http.zig             # HTTP client/server
├── json.zig             # JSON parser+serializer
├── Io.zig               # Reader/Writer traits
├── Thread.zig           # Threading + Pool + Mutex
├── testing.zig          # Testing framework
├── Random.zig           # PRNGs
└── ...
```
- ~90 modules, ~3,000+ functions
- "Batteries included but principled" — everything must work without libc on freestanding targets
- Regex was removed from stdlib because implementation quality wasn't sufficient

**Python** — Flat module namespace:
```
Lib/
├── os.py, sys.py, io.py, math.py, json.py
├── pathlib/      ├── collections/    ├── concurrent/
├── asyncio/      ├── typing/         ├── dataclasses/
├── unittest/     ├── logging/        ├── hashlib/
├── ssl/          ├── socket/         ├── http/
├── email/        ├── html/           ├── xml/
└── ... (200+ modules)
```
- ~200+ modules, enormous function count
- "Batteries included" — everything from HTML parsing to IMAP email
- Quality is uneven; some modules haven't aged well

### 1.2 Key Patterns

| Pattern | Description | Languages |
|---------|-------------|-----------|
| **Layered crates** | core → alloc → std with strict dependency rules | Rust |
| **Dependency lattice** | Strict layer ordering prevents cycles | Go |
| **Flat with domain** | All modules at top level, grouped by purpose | Zig, Go |
| **Platform isolation** | Platform-specific code hidden behind abstract APIs | Zig, Rust |
| **Prelude** | Small set of commonly-used types auto-imported | Rust |
| **Root re-export** | Single entry point re-exports all sub-modules | Zig |

---

## 2. Core Modules Analysis

### 2.1 Collections

**What others provide:**

| Language | In Stdlib | External |
|----------|-----------|----------|
| Go | slice, map, container/{heap,ring,list} | — |
| Rust | Vec, HashMap, HashSet, BTreeMap, LinkedList, VecDeque, BinaryHeap | — |
| Zig | ArrayList, ArrayHashMap, HashMap, DoublyLinkedList, SinglyLinkedList, PriorityQueue, BitSet, BitSet | — |
| Python | list, dict, set, tuple, deque, defaultdict, OrderedDict, Counter, namedtuple | — |

**Recommendation for Astra:**

Ship in stdlib:
- **Array[T]** — Dynamic contiguous array (value semantics, ARC-managed). This is the workhorse.
- **HashMap[K, V]** — Hash map (open addressing or Robin Hood, ARC-managed keys/values).
- **HashSet[T]** — Set backed by HashMap.
- **LinkedHashMap[K, V]** — Ordered iteration (for LRU caches, insertion-order maps).
- **TreeMap[K, V]** — Red-black or AVL tree (O(log n) ordered operations).
- **Deque[T]** — Double-ended queue (ring buffer).
- **Stack[T]** — LIFO stack (wrapper over Array with push/pop/peek).
- **PriorityQueue[T]** — Binary heap.
- **BitSet** — Compact bitset for set operations on small integers.

Do NOT ship: bloom filter, skip list, rope (as a collection), persistent/immutable data structures. These go to ecosystem packages.

**Value semantics by default** (like Rust's Vec, Zig's ArrayList):
```
val arr = Array{1, 2, 3}
val arr2 = arr           # Deep copy (ARC shared, CoW on mutation)
arr2.push(4)             # COW: arr2 detaches, arr unchanged
```

### 2.2 I/O

**What others provide:**

| Language | In Stdlib | Design |
|----------|-----------|--------|
| Go | io.Reader, io.Writer, io.Closer, bufio, os.File, bytes.Buffer | Interface-based |
| Rust | std::io::{Read, Write, BufRead, Cursor, BufReader, BufWriter} | Trait-based |
| Zig | std.Io (Reader/Writer vtable-based structs), std.fs, std.io | VTable structs |
| Python | io module: FileIO, BufferedReader, StringIO, BytesIO | Class hierarchy |

**Recommendation for Astra:**

Zig's approach (vtable-based structs) fits Astra better than Rust's traits because:
1. ARC/ORC means we prefer structs with methods over trait objects
2. VTable structs are more cache-friendly than trait objects
3. Green threads mean I/O is non-blocking automatically — no need for async traits

Ship in stdlib:
- **io.Reader** — Vtable struct for reading bytes (file, network, memory, compression)
- **io.Writer** — Vtable struct for writing bytes
- **io.Buffer** — In-memory buffer (backing for BufReader/BufWriter)
- **io.BufReader** — Buffered wrapper over any Reader
- **io.BufWriter** — Buffered wrapper over any Writer
- **io.LimitedReader** — Reader with byte limit
- **io.TeeReader** — Read + write simultaneously
- **fs.File** — Platform-abstracted file handle (wraps fd/HANDLE)
- **fs.open/read/write/stat** — Top-level filesystem operations
- **fs.Path** — Cross-platform path manipulation (no backslash confusion)

**Key design decision:** Reader/Writer should be context-vtable structs, not traits:
```
struct Reader {
    context: *any
    read_fn: fn(*any, []u8) -> Result<usize>
}

struct Writer {
    context: *any
    write_fn: fn(*any, []const u8) -> Result<usize>
}
```
This allows zero-cost dispatch without virtual dispatch overhead for concrete types.

### 2.3 Strings

**What others provide:**

| Language | Design | Notes |
|----------|--------|-------|
| Go | `string` (immutable UTF-8), `[]byte` | No indexing by char |
| Rust | `String` (mutable, owned, UTF-8), `&str` (borrowed slice) | Complex ownership |
| Zig | `[]const u8` (bytes), no String type | Raw bytes, manual UTF-8 |
| Python | `str` (immutable Unicode), `bytes` | UTF-8 internally |

**Recommendation for Astra:**

Astra should have:
- **String** — Immutable, UTF-8 encoded, ARC-managed. The primary string type.
- **StringView** — Borrowed slice (`[]const u8` equivalent) for zero-copy operations.
- **Rope** — Optional rope data structure for heavy string building (string builders, text editors).

**String design:**
```
# String is immutable, ARC-managed
val name = "Hello, 世界"
val len = name.len         # Byte length
val chars = name.chars()   # Char iterator (lazy)
val byte0 = name[0]        # ERROR: no byte indexing (prevents UTF-8 mistakes)

# StringView is a borrowed slice
val view: StringView = name[0..5]  # Zero-copy slice

# String building uses StringBuilder (not rope by default)
val sb = StringBuilder::new()
sb.write("Hello, ")
sb.write(name)
val result = sb.build()    # Produces String
```

**Rope design:**
- O(1) concatenation via tree nodes
- Lazy flattening to String only when content is accessed
- Useful for: text editors, template engines, log aggregation
- Ship as `std.text.Rope` — a separate module, not baked into String

**String interning:** Ship as `std.text.Intern` — a string interning pool. Not built into String itself. Used by: compilers, parsers, configuration systems.

**Key decisions:**
1. UTF-8 by default, no UTF-16 or UTF-32 types in stdlib (FFI handles conversion)
2. No `str[single_index]` — prevents bugs with multi-byte characters
3. Immutable by default (ARC handles sharing)
4. StringBuilder for building, String for storing

### 2.4 Math

**What others provide:**

| Language | In Stdlib |
|----------|-----------|
| Go | math (basic, trig, hyperbolic), math/big, math/cmplx, math/rand |
| Rust | std::f32/f64 (basic, trig), no big integer in std, rand external |
| Zig | std.math (basic, trig, big integer, complex, SIMD) |
| Python | math (basic, trig, combinatorics), cmath, decimal, fractions |

**Recommendation for Astra:**

Ship in stdlib:
- **math** — Basic: abs, min, max, sqrt, pow, log, exp, floor, ceil, round
- **math.trig** — sin, cos, tan, asin, acos, atan, atan2, degrees, radians
- **math.random** — Thread-safe PRNG (xoshiro256** or chacha8), `random.int()`, `random.float()`, `random.bytes()`
- **math.big** — Arbitrary-precision integers and rationals (for crypto, parsing)

Do NOT ship: linear algebra (external `astra-linalg`), complex numbers (external), statistics (external), SIMD intrinsics (compiler handles automatically).

**Linear algebra rationale:** SIMD is handled by the compiler (auto-vectorization). A standalone linalg package can be optimized for specific use cases without bloating the stdlib.

### 2.5 Crypto

**What others provide:**

| Language | In Stdlib |
|----------|-----------|
| Go | crypto/* (aes, rsa, sha, tls, x509, etc.) — comprehensive |
| Rust | Only basic hash in std; ring/rustls are external |
| Zig | std.crypto (hash, hmac, aes, chacha, tls, signatures) — comprehensive |
| Python | hashlib, hmac, ssl (basic wrappers) |

**Recommendation for Astra:**

Ship in stdlib:
- **crypto.hash** — SHA-256, SHA-512, SHA-3, BLAKE3, MD5 (legacy)
- **crypto.hmac** — HMAC for any hash function
- **crypto.aead** — AES-GCM, ChaCha20-Poly1305 (authenticated encryption)
- **crypto.tls** — TLS 1.3 client/server (via OpenSSL/BoringSSL bindings)

Do NOT ship: RSA/ECC key generation (external `astra-crypto`), certificate management (external), password hashing (external argon2/bcrypt).

**TLS rationale:** Go and Zig both ship TLS in std because it's essential for any networked application. Astra's green threads make TLS even more natural (no async complexity).

### 2.6 Networking

**What others provide:**

| Language | In Stdlib |
|----------|-----------|
| Go | net (TCP, UDP, DNS, Unix), net/http (full server+client), net/url, net/smtp |
| Rust | std::net (TCP, UDP, DNS lookup); HTTP/WS external (reqwest, tungstenite) |
| Zig | std.net (TCP, UDP, DNS), std.http (client/server) |
| Python | socket, http, urllib, email, xmlrpc |

**Recommendation for Astra:**

Ship in stdlib:
- **net.Tcp** — TCP client/server (green-threaded, non-blocking)
- **net.Udp** — UDP client/server
- **net.Dns** — DNS resolution (getaddrinfo wrapper)
- **net.Http** — HTTP/1.1 + HTTP/2 client + server (like Go's net/http)
- **net.WebSocket** — WebSocket client/server (upgrade + framing)
- **net.Url** — URL parsing and manipulation

**Rationale:** Astra's green threads make networking the killer feature. Shipping HTTP in stdlib is essential because:
1. Every microservice needs HTTP
2. Green threads make it trivially easy
3. The stdlib HTTP server can demonstrate the power of fibers
4. Without stdlib HTTP, Astra can't compete with Go for server-side adoption

### 2.7 Concurrency

**What others provide:**

| Language | In Stdlib |
|----------|-----------|
| Go | goroutines, channels, sync.Mutex, sync.RWMutex, sync.WaitGroup, sync.Once, sync.Pool |
| Rust | std::sync::{Mutex, RwLock, Arc, Once, mpsc}, std::thread |
| Zig | std.Thread (spawn, Pool), std.Mutex, std.ResetEvent |
| Python | threading, multiprocessing, asyncio, queue |

**Recommendation for Astra:**

Ship in stdlib (critical for green threads):
- **sync.Mutex** — Fiber-aware mutual exclusion (not OS mutex)
- **sync.RWMutex** — Fiber-aware read/write lock
- **sync.Channel[T]** — Go-style typed channels (MPMC, buffered)
- **sync.WaitGroup** — Wait for N fibers to complete
- **sync.Semaphore** — Counting semaphore
- **sync.Once** — Execute function exactly once (lazy init)
- **sync.Atomic[T]** — Atomic operations (load, store, CAS, fence)

**Key design decision:** Since Astra has green threads, all synchronization primitives must be **fiber-aware** (yield the fiber, not block the OS thread). This is critical — using OS-level mutexes with green threads would block the entire OS thread.

```
# Fiber-aware channel
val ch = Channel[Int](capacity: 100)
spawn fn producer() {
    for i in 0..100 {
        ch.send(i)?    # Yields fiber if buffer full
    }
    ch.close()
}
spawn fn consumer() {
    while let val msg = ch.recv()? {
        process(msg)   # Yields fiber if buffer empty
    }
}
```

### 2.8 OS

**What others provide:**

| Language | In Stdlib |
|----------|-----------|
| Go | os (env, args, stat, mkdir, remove), os/exec, os/signal, os/user |
| Rust | std::env, std::fs, std::process, std::os (platform extensions) |
| Zig | std.os, std.posix, std.process, std.fs, std.dynamic_library |
| Python | os, sys, subprocess, signal, pathlib, shutil |

**Recommendation for Astra:**

Ship in stdlib:
- **os.env** — Environment variables (get, set, list)
- **os.args** — Command-line arguments
- **os.process** — Spawn, exec, wait (wraps fork/exec or CreateProcess)
- **os.signal** — Signal handling (SIGINT, SIGTERM, etc.)
- **os.fs** — (re-exported from fs module above)
- **os.dynlib** — Dynamic library loading (dlopen/LoadLibrary)

### 2.9 Serialization

**What others provide:**

| Language | In Stdlib |
|----------|-----------|
| Go | encoding/json, encoding/xml, encoding/gob, encoding/base64, encoding/hex |
| Rust | serde (external), serde_json (external), bincode (external) |
| Zig | std.json, std.zon (Zig's own format) |
| Python | json, pickle, csv, struct, base64, xml.etree |

**Recommendation for Astra:**

Ship in stdlib:
- **json** — JSON parser + serializer (like Go's encoding/json, compile-time derived)
- **toml** — TOML parser + serializer (config files)
- **base64** — Base64 encode/decode
- **hex** — Hex encode/decode
- **csv** — CSV parser + writer

Do NOT ship: YAML (external `astra-yaml` — too complex for stdlib), Protocol Buffers (external `astra-protobuf`), MessagePack (external), CBOR (external).

**Rationale:** JSON is universal. TOML is the config format standard. CSV is ubiquitous. YAML is too complex (anchors, tags, multiple document streams) and has too many edge cases — ship as external.

**Compile-time serialization** (already in ARCHITECTURE.md):
```
@serialize
struct User {
    name: String
    age: Int
}

val json = user.to_json()?         # Compile-time derived
let restored = User::from_json(json)?  # Compile-time derived
```

### 2.10 Testing

**What others provide:**

| Language | In Stdlib |
|----------|-----------|
| Go | testing (T, B, M), testdata, testify (external) |
| Rust | #[test], assert!, std::test (minimal) |
| Zig | std.testing (expectEqual, expectError, test runner) |
| Python | unittest, doctest, test support |

**Recommendation for Astra:**

Ship in stdlib:
- **testing.assert** — assert_eq, assert_ne, assert_match, assert_approx
- **testing.Test** — Test runner (discovers `@test` functions, reports results)
- **testing.Benchmark** — Benchmark runner (like Go's testing.B)
- **testing.Mock** — Mock/stub framework (comptime-generated mocks)

Do NOT ship: property-based testing (external `astra-proptest`), fuzz testing (built into compiler, not stdlib), coverage tools (external).

---

## 3. Design Philosophy: Minimal vs Comprehensive

### 3.1 The Spectrum

```
Minimal ◄────────────────────────────────────────────► Comprehensive
  Elm (18 modules)  Gleam (19)  Rust (50)  Deno (43)  Zig (90)  Go (150)  Python (200+)
```

### 3.2 What Works and What Doesn't

**Rust's minimalism** works because Cargo makes adding dependencies trivial. But it creates:
- "HTTP client choice paralysis" (reqwest vs surf vs ureq vs isahc)
- Every project reinvents basic patterns
- The 2017 "Libz Blitz" was Rust admitting ecosystem quality was insufficient

**Go's comprehensiveness** works because:
- Zero external dependencies for most projects
- Consistent API style across all packages
- But: `net/http` design flaws are permanent; `encoding/json` limitations are permanent

**Zig's principled comprehensiveness** works because:
- Everything works without libc on freestanding
- Regex was removed when quality wasn't sufficient (principled)
- But: stdlib is huge (~3,000 functions) and growing

**Deno's curated model** is promising:
- Modules versioned independently
- Each module reaches 1.0 at its own pace
- "Stdlib-level trust with package-level evolution speed"

### 3.3 Recommendation for Astra

**Curated batteries** — the "Almide/Deno" zone:

| Criterion | Include in Stdlib | External Package |
|-----------|-------------------|------------------|
| Every program needs it | ✓ | |
| Cannot be reimplemented well in user code | ✓ | |
| Compiler/runtime integration required | ✓ | |
| High-quality API is hard to get right | ✓ | |
| Domain-specific or evolving rapidly | | ✓ |
| Multiple valid design approaches | | ✓ |
| Requires platform-specific dependencies | | ✓ |

**The permanent contract:** Every function in Astra's stdlib is a permanent commitment. The Go lesson: once `encoding/json` is in std, fixing its design flaws becomes nearly impossible. Every API must be final-quality before shipping.

---

## 4. Iterator Patterns

### 4.1 How Languages Do It

**Rust** — Lazy iterator adapters (the gold standard):
```rust
let sum: i32 = (0..10)
    .filter(|x| x % 2 == 0)
    .map(|x| x * x)
    .sum();
// Nothing executes until .sum() consumes the iterator
```
- Single `Iterator` trait with `next() -> Option<Item>`
- 70+ adapter methods (map, filter, chain, zip, enumerate, peekable, etc.)
- Zero-cost: compiler inlines everything
- `collect()` to materialize into collections

**Zig** — No standard iterator pattern (community experiments):
```zig
// Zig uses for-in with slices
for (items) |item| { ... }
// No lazy iteration in stdlib
// Community repos: ziter, funzig, Zigerator
```

**Go** — Range-based (no lazy iteration):
```go
for i, v := range items { ... }
// No iterator adapters in stdlib
// Community: iter package (Go 1.23+)
```

**Python** — Generators + itertools:
```python
sum(x*x for x in range(10) if x % 2 == 0)
# Lazy via generators
```

### 4.2 Recommendation for Astra

Astra should adopt **Rust-style lazy iterators** because:
1. Green threads + lazy iterators = powerful data pipeline processing
2. Zero-cost abstraction fits Astra's performance goals
3. Python/TypeScript users are familiar with map/filter chains

```
# Lazy iterator chain
val sum = (0..10)
    .filter(|x| x % 2 == 0)
    .map(|x| x * x)
    .sum()

# Materialize to collection
val evens: Array<Int> = (0..100)
    .filter(|x| x % 2 == 0)
    .collect()

# Custom iterator
struct Fibonacci {
    a: Int
    b: Int
}

impl Iterator[Int] for Fibonacci {
    fn next(mut self) -> Option[Int] {
        val result = self.a
        self.a = self.b
        self.b = result + self.b
        return Some(result)
    }
}

# Usage
val fibs: Array<Int> = Fibonacci{0, 1}
    .take(10)
    .collect()
```

**Iterator trait design:**
```
trait Iterator[T] {
    fn next(self) -> Option[T]

    # Provided methods (adapters)
    fn map[U](self, f: fn(T) -> U) -> MapIterator[T, U]
    fn filter(self, predicate: fn(T) -> Bool) -> FilterIterator[T]
    fn take(self, n: Int) -> TakeIterator[T]
    fn skip(self, n: Int) -> SkipIterator[T]
    fn chain(self, other: impl Iterator[T]) -> ChainIterator[T]
    fn enumerate(self) -> EnumerateIterator[T]
    fn zip[U](self, other: impl Iterator[U]) -> ZipIterator[T, U]

    # Consuming methods
    fn collect[C](self) -> C where C: FromIterator[T]
    fn sum(self) -> T
    fn count(self) -> Int
    fn any(self, predicate: fn(T) -> Bool) -> Bool
    fn all(self, predicate: fn(T) -> Bool) -> Bool
    fn fold[B](self, init: B, f: fn(B, T) -> B) -> B
}
```

**Ranges:**
```
val r1 = 0..10          # 0, 1, 2, ..., 9 (exclusive end)
val r2 = 0..=10         # 0, 1, 2, ..., 10 (inclusive end)
val r3 = 'a'..'z'       # 'a', 'b', ..., 'z'
```

---

## 5. String Handling

### 5.1 Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Encoding | UTF-8 | Universal, Go/Rust/Zig all use it |
| Mutability | Immutable (ARC) | Safe to share between fibers, COW for mutation |
| Indexing | No single-byte indexing | Prevents UTF-8 bugs (Rust's lesson) |
| Comparison | Byte comparison | UTF-8 is designed for this |
| Hashing | SipHash (default) | DoS-resistant, like Rust/Go |
| Large strings | StringBuilder | Rope available but not default |

### 5.2 Memory Layout

```
String (immutable, ARC-managed):
┌──────────────┬──────────────┬──────────────────┐
│ refcount (i64)│ length (usize)│ bytes (UTF-8)    │
└──────────────┴──────────────┴──────────────────┘

StringView (borrowed, stack-allocated):
┌──────────────┬──────────────┐
│ ptr (*const u8)│ length (usize)│
└──────────────┴──────────────┘

StringBuilder (mutable, grows):
┌──────────────┬──────────────┬──────────────────┬──────────────┐
│ refcount (i64)│ length (usize)│ capacity (usize) │ buffer (u8[])│
└──────────────┴──────────────┴──────────────────┴──────────────┘
```

### 5.3 Key String Operations

```
# Construction
val s1 = "Hello"
val s2 = String.from_bytes([72, 101, 108, 108, 111])
val s3 = String.format("Hello, {}!", name)

# Inspection
val len = s1.len              # Byte length
val char_count = s1.chars().count()  # Character count
val is_ascii = s1.is_ascii()  # Check if ASCII-only

# Slicing (zero-copy)
val slice = s1[0..5]          # StringView into s1

# Searching
val pos = s1.find("ell")      # Option[Int]
val has = s1.contains("Hello") # Bool

# Transformation (returns new String)
val upper = s1.to_upper()
val replaced = s1.replace("Hello", "Goodbye")
val trimmed = "  hi  ".trim()

# Iteration
for ch in s1.chars() { ... }   # Iterate Unicode scalars
for byte in s1.bytes() { ... } # Iterate raw bytes

# Building (O(n) amortized)
val sb = StringBuilder::new()
for i in 0..1000 {
    sb.write("item {i}\n")
}
val result = sb.build()        # Produces String
```

---

## 6. Container Design

### 6.1 Value vs Reference Semantics

Astra should use **value semantics with ARC-managed heap data** (like Rust's Vec, not Java's ArrayList):

```
val a = Array{1, 2, 3}    # Stack: [refcount | len | cap | ptr → heap data]
val b = a                  # ARC shared, same heap data (cheap clone)
b.push(4)                  # COW: b detaches, allocates new heap, copies
# a is still {1, 2, 3}    # a unchanged
# b is {1, 2, 3, 4}      # b has its own copy
```

### 6.2 Fixed-Size vs Dynamic

| Type | Use Case | Example |
|------|----------|---------|
| `[T; N]` | Fixed-size arrays (stack) | `val pixels: [u8; 3] = [255, 128, 0]` |
| `Array[T]` | Dynamic arrays (heap) | `val list = Array{1, 2, 3}` |
| `ArrayView[T]` | Borrowed slice | `val slice = list[1..3]` |

### 6.3 Container API Design

```
struct Array[T] {
    # Fields (private)
    len: usize
    cap: usize
    ptr: Ptr[T]    # ARC-managed

    # Construction
    fn new() -> Array[T]
    fn with_capacity(cap: usize) -> Array[T]
    fn from_slice(slice: []const T) -> Array[T]

    # Access
    fn len(self) -> usize
    fn is_empty(self) -> Bool
    fn get(self, index: usize) -> Option[T]
    fn first(self) -> Option[T]
    fn last(self) -> Option[T]

    # Mutation
    fn push(mut self, value: T) -> void
    fn pop(mut self) -> Option[T]
    fn insert(mut self, index: usize, value: T) -> void
    fn remove(mut self, index: usize) -> T
    fn clear(mut self) -> void

    # Iteration
    fn iter(self) -> Iterator[T]
    fn iter_mut(mut self) -> MutableIterator[T]

    # Sorting
    fn sort(mut self) -> void
    fn sort_by(mut self, cmp: fn(T, T) -> Ordering) -> void

    # Search
    fn contains(self, value: T) -> Bool
    fn find(self, predicate: fn(T) -> Bool) -> Option[T]
    fn index_of(self, value: T) -> Option<usize]

    # Bulk operations
    fn extend(mut self, other: Array[T]) -> void
    fn truncate(mut self, len: usize) -> void
    fn resize(mut self, len: usize, default: T) -> void
}
```

---

## 7. Error Handling in Stdlib

### 7.1 Pattern

All stdlib functions that can fail return `Result[T, E]`:

```
# File operations
fn open(path: StringView) -> Result[fs.File, fs.Error]
fn read(path: StringView) -> Result<String, fs.Error]

# Network operations
fn connect(addr: net.Address) -> Result[net.Tcp, net.Error]
fn send(self: net.Tcp, data: []const u8) -> Result[usize, net.Error]

# Parse operations
fn parse_int(s: StringView) -> Result[Int, parse.Error]
fn parse_float(s: StringView) -> Result[Float, parse.Error]
```

### 7.2 Error Types

Each domain defines its own error enum:

```
enum fs.Error {
    NotFound
    PermissionDenied
    AlreadyExists
    IsDirectory
    NotDirectory
    IoError(Int)      # errno / GetLastError
}

enum net.Error {
    ConnectionRefused
    ConnectionReset
    AddressInUse
    HostUnreachable
    Timeout
    TlsError(crypto.Error)
}

enum parse.Error {
    InvalidDigit
    Overflow
    InvalidUtf8
}
```

### 7.3 Error Propagation

```
# ? operator for propagation
fn read_config(path: StringView) -> Result[Config, Error] {
    let content = fs.read(path)?           # Propagates fs.Error
    let parsed = json.from_string(content)? # Propagates json.Error
    return Ok(parsed)
}

# Error conversion via .map_err()
fn read_config_safe(path: StringView) -> Result[Config, String] {
    let content = fs.read(path)
        .map_err(|e| "Failed to read config: {e}")?
    let parsed = json.from_string(content)
        .map_err(|e| "Invalid config: {e}")?
    return Ok(parsed)
}
```

### 7.4 The `?` Operator

Works like Rust's `?`:
```
fn process() -> Result[Int, Error] {
    let a = step1()?;    # Returns early if Err
    let b = step2(a)?;   # Returns early if Err
    return Ok(b)
}
```

---

## 8. Platform-Specific Stdlib

### 8.1 Architecture

```
┌─────────────────────────────────────────────┐
│           User Code (Astra)                  │
├─────────────────────────────────────────────┤
│        Public API (cross-platform)           │
│  fs.open()  net.connect()  process.spawn()  │
├─────────────────────────────────────────────┤
│        Platform Abstraction Layer            │
│  Translates OS errors → Astra errors        │
│  Unifies API differences                    │
├─────────────────────────────────────────────┤
│     Platform Implementations (private)       │
│  linux/  darwin/  windows/  android/         │
└─────────────────────────────────────────────┘
```

### 8.2 Compile-Time Dispatch

```
# In stdlib source (hidden from user)
fn getCurrentThreadId() -> Int {
    return switch (builtin.os) {
        .linux   => linux.gettid(),
        .macos   => darwin.pthread_threadid_np(),
        .windows => windows.GetCurrentThreadId(),
    }
}
```

### 8.3 Exposing Platform APIs

Two strategies:

**Strategy 1: Conditional imports (like Zig)**
```
# Linux-only APIs
import std.os.linux

val ring = linux.io_uring::new(256)?
```

**Strategy 2: Feature detection at compile-time**
```
if @has_feature("io_uring") {
    # Use io_uring
} else if @has_feature("epoll") {
    # Use epoll
}
```

**Recommendation:** Use Strategy 1 (explicit imports) — it's clearer and more maintainable.

---

## 9. Astra Stdlib Module Structure

### 9.1 Complete Module Map

```
std/
├── core/                    # Language primitives (auto-imported)
│   ├── option.astra         # Option[T] { Some, None }
│   ├── result.astra         # Result[T, E] { Ok, Err }
│   ├── iter.astra           # Iterator[T] trait + adapters
│   └── cmp.astra            # Ordering, PartialEq, PartialOrd, Eq, Ord
│
├── collections/             # Data structures
│   ├── array.astra          # Array[T] (dynamic, ARC)
│   ├── hashmap.astra        # HashMap[K, V]
│   ├── hashset.astra        # HashSet[T]
│   ├── linked_hashmap.astra # LinkedHashMap[K, V]
│   ├── treemap.astra        # TreeMap[K, V]
│   ├── deque.astra          # Deque[T]
│   ├── stack.astra          # Stack[T]
│   ├── priority_queue.astra # PriorityQueue[T]
│   └── bitset.astra         # BitSet
│
├── io/                      # I/O primitives
│   ├── reader.astra         # Reader (vtable struct)
│   ├── writer.astra         # Writer (vtable struct)
│   ├── buffer.astra         # Buffer, BufReader, BufWriter
│   └── limited.astra        # LimitedReader, TeeReader
│
├── fs/                      # Filesystem
│   ├── file.astra           # File (open, read, write, stat)
│   ├── dir.astra            # Directory operations (read, create, walk)
│   └── path.astra           # Path manipulation
│
├── net/                     # Networking
│   ├── tcp.astra            # TCP client/server
│   ├── udp.astra            # UDP client/server
│   ├── dns.astra            # DNS resolution
│   ├── http.astra           # HTTP/1.1 + HTTP/2 client/server
│   ├── websocket.astra      # WebSocket client/server
│   └── url.astra            # URL parsing
│
├── sync/                    # Concurrency primitives
│   ├── channel.astra        # Channel[T] (MPMC)
│   ├── mutex.astra          # Mutex, RwLock
│   ├── waitgroup.astra      # WaitGroup
│   ├── semaphore.astra      # Semaphore
│   ├── once.astra           # Once
│   └── atomic.astra         # Atomic[T]
│
├── os/                      # OS interaction
│   ├── env.astra            # Environment variables
│   ├── args.astra           # Command-line arguments
│   ├── process.astra        # Process spawn/exec
│   ├── signal.astra         # Signal handling
│   └── dynlib.astra         # Dynamic library loading
│
├── text/                    # Text processing
│   ├── string.astra         # String, StringBuilder
│   ├── string_view.astra    # StringView (borrowed slice)
│   ├── rope.astra           # Rope (lazy concatenation tree)
│   ├── format.astra         # String formatting (f-strings / format!)
│   ├── regex.astra          # Regular expressions
│   ├── unicode.astra        # Unicode utilities
│   └── intern.astra         # String interning pool
│
├── math/                    # Mathematics
│   ├── math.astra           # Basic math (abs, sqrt, pow, log, etc.)
│   ├── trig.astra           # Trigonometry (sin, cos, tan, etc.)
│   ├── random.astra         # PRNG (xoshiro256**, chacha8)
│   └── big.astra            # Arbitrary-precision integers
│
├── crypto/                  # Cryptography
│   ├── hash.astra           # SHA-256, SHA-512, SHA-3, BLAKE3
│   ├── hmac.astra           # HMAC
│   ├── aead.astra           # AES-GCM, ChaCha20-Poly1305
│   └── tls.astra            # TLS 1.3
│
├── encoding/                # Data encoding
│   ├── json.astra           # JSON parser + serializer
│   ├── toml.astra           # TOML parser + serializer
│   ├── base64.astra         # Base64 encode/decode
│   ├── hex.astra            # Hex encode/decode
│   └── csv.astra            # CSV parser + writer
│
├── testing/                 # Testing framework
│   ├── assert.astra         # Assertions (assert_eq, assert_match, etc.)
│   ├── test.astra           # Test runner (@test functions)
│   ├── benchmark.astra      # Benchmark runner
│   └── mock.astra           # Mock/stub framework
│
└── time/                    # Time handling
    ├── instant.astra        # Instant (monotonic clock)
    ├── duration.astra       # Duration (arithmetic, comparison)
    └── clock.astra          # System clock, timezone
```

### 9.2 Module Count Summary

| Category | Modules | Est. Functions |
|----------|---------|----------------|
| Core | 4 | ~60 |
| Collections | 9 | ~200 |
| I/O | 4 | ~80 |
| Filesystem | 3 | ~60 |
| Networking | 6 | ~150 |
| Concurrency | 6 | ~80 |
| OS | 5 | ~50 |
| Text | 7 | ~180 |
| Math | 4 | ~120 |
| Crypto | 4 | ~60 |
| Encoding | 5 | ~80 |
| Testing | 4 | ~50 |
| Time | 3 | ~40 |
| **Total** | **~64** | **~1,210** |

This is in the "medium" range — comparable to Rust (~2,000), smaller than Go (~5,000), larger than Elm (~200).

### 9.3 What's NOT in Stdlib (External Packages)

| Package | Rationale |
|---------|-----------|
| YAML | Too complex, too many edge cases |
| Protocol Buffers | Requires code generation tooling |
| MessagePack, CBOR | Niche serialization formats |
| Linear algebra | Compiler handles SIMD; domain-specific |
| Statistics | Domain-specific |
| Image processing | Domain-specific |
| Database drivers | Too many databases, too specific |
| ORM | High-level, opinionated |
| Web framework | Too many approaches, too fast-moving |
| Logging framework | Use `testing.log` for now; ecosystem will provide |
| Argument parsing | CLI-specific |
| Date/timezone | Ship `time` but not full tz database |
| Compression (gzip, zstd) | External `astra-compress` |
| Regular expressions | Ship in stdlib (essential for text processing) |

---

## 10. Benchmark Targets

### 10.1 Performance Goals

Every stdlib function should meet these minimum performance targets:

| Category | Metric | Target | Comparison |
|----------|--------|--------|------------|
| **Array push** | Amortized | O(1) | Same as Rust Vec |
| **Array get** | Bounds-checked | O(1) | Same as Rust Vec |
| **HashMap lookup** | Average | O(1) | Same as Go map |
| **String concat** | StringBuilder | O(n) amortized | Same as Go strings.Builder |
| **Rope concat** | Lazy | O(1) | Better than String concat |
| **Iterator chain** | Zero-cost | Same as manual loop | Compiler must inline |
| **Channel send/recv** | Fiber-aware | <100ns uncontended | Same as Go channel |
| **Mutex lock/unlock** | Fiber-aware | <50ns uncontended | Same as Go mutex |
| **TCP connect** | Green-threaded | Same as OS | No fiber overhead |
| **HTTP request** | Green-threaded | Same as Go net/http | No async overhead |
| **JSON parse** | Streaming | >100MB/s | Same as Go encoding/json |
| **JSON serialize** | Streaming | >150MB/s | Same as Go encoding/json |
| **File read** | Buffered | >1GB/s | Near OS limit |
| **SHA-256** | Throughput | >500MB/s | Hardware-accelerated |

### 10.2 Memory Goals

| Category | Metric | Target |
|----------|--------|--------|
| **String** | Overhead | 16 bytes + refcount (24 bytes total) |
| **Array** | Overhead | 24 bytes + refcount (32 bytes total) |
| **HashMap** | Load factor | 75% max |
| **Channel** | Buffer | Configurable, default 0 (unbuffered) |
| **Fiber stack** | Initial | 2 KB |
| **Fiber stack** | Max growth | 8 MB |

### 10.3 Concurrency Goals

| Category | Metric | Target |
|----------|--------|--------|
| **Fiber spawn** | Latency | <1μs |
| **Context switch** | Fiber→Fiber | <100ns |
| **Fiber→OS thread** | Entersyscall | <1μs |
| **Channel contention** | Throughput | >1M messages/sec |
| **Atomic ops** | Throughput | >10M ops/sec |

### 10.4 Testing Strategy for Benchmarks

```
tests/benchmarks/
├── collections/
│   ├── array_push_bench.astra
│   ├── hashmap_lookup_bench.astra
│   └── deque_push_pop_bench.astra
├── io/
│   ├── file_read_bench.astra
│   ├── buffer_write_bench.astra
│   └── tcp_throughput_bench.astra
├── text/
│   ├── string_concat_bench.astra
│   ├── string_find_bench.astra
│   └── rope_concat_bench.astra
├── encoding/
│   ├── json_parse_bench.astra
│   └── json_serialize_bench.astra
└── sync/
    ├── channel_throughput_bench.astra
    └── mutex_contention_bench.astra
```

Each benchmark should:
1. Compare against Go/Zig implementations (reference)
2. Run on Linux, macOS, Windows
3. Report p50, p95, p99 latencies
4. Track regression over versions

---

## 11. API Design Guidelines

### 11.1 Naming Conventions

| Pattern | Convention | Example |
|---------|------------|---------|
| Types | PascalCase | `Array`, `HashMap`, `String` |
| Functions | snake_case | `get()`, `push()`, `to_string()` |
| Constants | SCREAMING_SNAKE | `MAX_SIZE`, `DEFAULT_CAPACITY` |
| Modules | snake_case | `std.collections`, `std.net.http` |
| Traits | PascalCase | `Iterator`, `Comparable`, `Hashable` |

### 11.2 Common Patterns

```
# Construction: ::new() or ::from_*()
val arr = Array[Int]::new()
val arr = Array.from_slice([1, 2, 3])

# Conversion: to_*()
val s = 42.to_string()
val bytes = s.to_bytes()
val view = s.as_view()  # Borrowed, zero-copy

# In-place mutation: mut self
arr.push(42)
arr.sort()

# Functional transformation: self (returns new)
val sorted = arr.sorted()      # Returns new sorted Array
val upper = str.to_upper()     # Returns new String
val mapped = arr.map(|x| x * 2)  # Returns new Array

# Option/Result for fallible operations
val first = arr.first()         # Option[T]
val file = fs.open("x.txt")    # Result[File, fs.Error]

# Builder pattern for complex construction
val server = HttpServer::builder()
    .bind("0.0.0.0:8080")
    .max_connections(1000)
    .handler(my_handler)
    .build()?
```

### 11.3 Error Message Quality

Every error should include:
1. **What** failed
2. **Why** it failed
3. **How** to fix it (when possible)

```
# Bad
Error: file not found

# Good
Error: File not found at '/etc/config.toml'
  → The file does not exist at the specified path.
  → Check that the path is correct and the file has been created.
  → If this is a configuration file, create it with:
    cp /etc/config.toml.example /etc/config.toml
```

---

## 12. Summary of Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Stdlib size** | ~64 modules, ~1,210 functions | "Curated batteries" zone |
| **String** | Immutable, UTF-8, ARC | Safe for fibers, like Go |
| **Collections** | Value semantics, COW | Like Rust Vec, not Java ArrayList |
| **Iterators** | Lazy, Rust-style | Zero-cost, powerful pipelines |
| **I/O** | VTable structs | Cache-friendly, ARC-compatible |
| **Networking** | Green-threaded, in stdlib | Killer feature of Astra |
| **HTTP** | In stdlib | Essential for adoption |
| **TLS** | In stdlib | Essential for networking |
| **JSON** | In stdlib, compile-time derived | Universal format |
| **YAML** | External | Too complex for stdlib |
| **Testing** | In stdlib | First-class testing |
| **Property testing** | External | Niche, evolving |
| **Platform APIs** | Explicit imports (`std.os.linux`) | Clear, maintainable |
| **Error handling** | Result/T with ? operator | Like Rust, proven pattern |
| **Channels** | Fiber-aware MPMC | Essential for green threads |
| **Mutexes** | Fiber-aware | Critical — OS mutexes block threads |

---

## Appendix: References

1. Go Standard Library: https://pkg.go.dev/std
2. Rust Standard Library: https://doc.rust-lang.org/stable/std/
3. Zig Standard Library: https://github.com/ziglang/zig/tree/master/lib/std
4. Python Standard Library: https://docs.python.org/3/library/
5. "Better Batteries" (matklad): https://matklad.github.io/2026/08/20/better-batteries.html
6. "Standard Libraries and their Discontents" (Alex Gaynor): https://alexgaynor.net/2025/may/19/standard-libraries/
7. Almide Stdlib Size Comparison: https://github.com/almide/almide/blob/develop/docs/research/stdlib-size-comparison.md
8. Zig Stdlib Organization Issue: https://github.com/ziglang/zig/issues/5792
9. Zig Iterator Discussion: https://github.com/ziglang/zig/issues/6185
