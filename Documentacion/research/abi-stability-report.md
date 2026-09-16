# ABI Stability and Linking Strategies for Astra

## Table of Contents

1. [ABI Stability Fundamentals](#1-abi-stability-fundamentals)
2. [C ABI as Lingua Franca](#2-c-abi-as-lingua-franca)
3. [Dynamic vs Static Linking](#3-dynamic-vs-static-linking)
4. [Shared Library Formats](#4-shared-library-formats)
5. [Versioned Shared Libraries](#5-versioned-shared-libraries)
6. [Symbol Visibility](#6-symbol-visibility)
7. [ABI Compatibility for FFI](#7-abi-compatibility-for-ffi)
8. [ABI Breaks and Migration](#8-abi-breaks-and-migration)
9. [Static Linking with musl](#9-static-linking-with-musl)
10. [Astra ABI Strategy](#10-astra-abi-strategy)

---

## 1. ABI Stability Fundamentals

### What is ABI?

ABI (Application Binary Interface) defines the contract between compiled code at the binary level:

- **Calling convention**: How function arguments/return values are passed (registers vs stack, which registers, who cleans up)
- **Data layout**: Size, alignment, and padding of structs, unions, and primitive types
- **Name mangling**: How source-level names map to binary symbols
- **vtable layout**: How virtual dispatch tables are organized
- **Exception handling**: How stack unwinding works across module boundaries
- **Type size and alignment**: Canonical sizes for `int`, `long`, pointers, etc.

### What is ABI Stability?

ABI stability guarantees that a compiled binary can link against a different version of a library than it was originally compiled against, and it will work correctly at runtime without recompilation.

**Source compatibility** = users can recompile and it works.
**ABI compatibility** = users don't need to recompile at all; the new library loads and works with old binaries.

### Why ABI Stability Matters

1. **Plugin ecosystems**: Third-party extensions load at runtime without recompilation
2. **OS updates**: System libraries can be patched without rebuilding every application
3. **SDK distribution**: Enterprise SDKs embedded in products can be updated without redeploying all clients
4. **Language interop**: Cross-language FFI requires a stable binary contract
5. **Long-lived binaries**: Enterprise software deployed to thousands of endpoints

### ABI Stability by Language

| Language | ABI Stability | Strategy |
|----------|--------------|----------|
| **C** | De facto stable | Platform ABI is the C ABI; no name mangling, simple layouts |
| **C++** | Unstable (except Itanium ABI on some platforms) | Name mangling changes across compilers/versions; no standard ABI |
| **Rust** | No ABI stability by default | `extern "C"` for FFI; `abi_stable` crate for Rust-to-Rust; Rust internal ABI is explicitly unstable |
| **Go** | Internal ABI unstable | ABI0 (stack-based, stable for assembly); ABIInternal (register-based, unstable, changes per release) |
| **Swift** | Stable since Swift 5 | Library evolution with resilient types; `@frozen` opt-out; value witness tables for opaque layout |
| **Python** | Limited stable subset | Limited API / Stable ABI (`Py_LIMITED_API`); ABI-compatible across minor versions within same compile settings |

---

## 2. C ABI as Lingua Franca

### Why C ABI is Universal

The C ABI is the de facto standard because:

1. **OS APIs are C**: Linux syscalls, POSIX, Win32 API, macOS frameworks — all exposed via C interfaces
2. **Simplicity**: No name mangling (with `extern "C"`), no templates, no inheritance, no exceptions at the boundary
3. **Platform-defined**: Each platform defines its C ABI formally (System V AMD64 ABI on Linux, Microsoft x64 on Windows)
4. **Every language speaks it**: Python, Rust, Go, Swift, Java (JNI), C# (P/Invoke), Node.js (N-API) all have C FFI mechanisms
5. **Historical inertia**: Decades of libraries, tools, and infrastructure built around C calling conventions

### C ABI Mechanics

```
// Simple C function — no name mangling, predictable layout
extern "C" int32_t add(int32_t a, int32_t b);

// Structs have defined layout rules
struct Point {
    double x;  // offset 0, size 8
    double y;  // offset 8, size 8
};             // total size: 16, alignment: 8
```

### Limitations of C ABI

| Limitation | Impact |
|-----------|--------|
| No rich types | No generics, traits, Option, Result — must use primitives, pointers, enums-as-ints |
| No type safety across boundary | Caller and callee can disagree on struct layout silently |
| No standard name mangling | Each compiler does it differently (but `extern "C"` avoids this) |
| No exception propagation | C has no exceptions; cross-boundary exceptions require C-style error codes |
| No namespace support | Symbol collision risk; must manually prefix names |
| No standard vtable layout | C++ vtables are compiler-specific |
| Platform-dependent sizes | `long` is 4 bytes on Windows x64, 8 bytes on Linux x64 |
| No standard for variadic args | Varargs handling varies across platforms |

### crABI: A Proposed Enhancement

Rust's crABI RFC proposes a standardized ABI above C but below language-specific ABIs:
- Defines `Option<T>`, `Result<T, E>`, slices, ranges as first-class cross-language types
- Uses `repr(crabi)` for explicit layout control
- Built on top of C calling conventions (no new assembly required)
- Goal: make cross-language FFI safer without dropping to raw C pointers

---

## 3. Dynamic vs Static Linking

### Static Linking

The linker copies all referenced library code into the final executable at build time.

**Pros:**
- Self-contained binary — no external dependencies at runtime
- Simplified deployment (single file, works anywhere on same OS/arch)
- Faster startup (no dynamic loader work)
- Better dead code elimination
- Easier security auditing (all code is in one place)

**Cons:**
- Larger binaries (duplicate code across processes)
- Security patches require full rebuild and redeploy
- No runtime extensibility (no plugins via `dlopen`)
- Memory waste: each process has its own copy of library code

**How languages handle it:**
- **Go**: Defaults to static linking (`CGO_ENABLED=0` produces fully static binary)
- **Rust**: Can target `x86_64-unknown-linux-musl` for fully static binaries
- **C/C++**: Requires explicit `-static` flag; many system libraries assume dynamic linking

### Dynamic Linking

The executable contains references to shared libraries; the OS loader resolves them at load time.

**Pros:**
- Smaller executables
- Shared memory: one library copy mapped into multiple processes
- Security patches propagate system-wide without relinking
- Runtime extensibility (plugins, modules, `dlopen`/`LoadLibrary`)
- Separate compilation and update of components

**Cons:**
- Dependency management complexity ("DLL Hell")
- Startup overhead (loader must resolve symbols)
- ABI incompatibility risk across versions
- Platform-specific tooling and formats

### Linking Mechanisms

| Mechanism | Linux (ELF) | Windows (PE) | macOS (Mach-O) |
|-----------|-------------|--------------|-----------------|
| Lazy binding | PLT/GOT | IAT (eager by default) | Two-level namespace |
| Symbol resolution | `ld-linux.so` | Windows Loader | `dyld` |
| Library search | `LD_LIBRARY_PATH`, RPATH, `/etc/ld.so.cache` | PATH, DLL directory | `DYLD_LIBRARY_PATH`, `@rpath`, `@loader_path` |
| Runtime loading | `dlopen()`/`dlsym()` | `LoadLibrary()`/`GetProcAddress()` | `dlopen()`/`dlsym()` |

---

## 4. Shared Library Formats

### Linux: ELF (.so)

```bash
# Build shared library
gcc -shared -fPIC -Wl,-soname,libfoo.so.1 -o libfoo.so.1.0.0 foo.c

# Symlinks for versioning
ln -sf libfoo.so.1.0.0 libfoo.so.1
ln -sf libfoo.so.1 libfoo.so
```

Key properties:
- **SONAME**: Embedded in library, identifies ABI version (`libfoo.so.1`)
- **PIC**: Position-Independent Code required for shared libraries
- **Symbol versioning**: `.gnu.version` sections for multi-version symbol support
- **Visibility**: `-fvisibility=hidden` + version scripts control exports

### macOS: Mach-O (.dylib)

```bash
# Build shared library
clang -dynamiclib \
    -install_name "libfoo.1.dylib" \
    -current_version 1.2.3 \
    -compatibility_version 1.2.0 \
    -o libfoo.1.2.3.dylib foo.c

# Symlink
ln -sf libfoo.1.2.3.dylib libfoo.1.dylib
```

Key properties:
- **install_name**: Records how the library should be found at load time (equivalent to SONAME)
- **compatibility_version**: Minimum version a client requires
- **current_version**: Full semantic version
- **Two-level namespace**: Each import records the source library
- **`@rpath`/`@loader_path`/`@executable_path`**: Relocatable paths

### Windows: PE (.dll)

```c
// Export macro
#ifdef MYLIB_EXPORTS
#define MYLIB_API __declspec(dllexport)
#else
#define MYLIB_API __declspec(dllimport)
#endif

MYLIB_API int32_t my_function(int32_t x);
```

```bash
# Build DLL
cl /LD /DMYLIB_EXPORTS foo.c /link /OUT:foo.dll

# Or using .def file for explicit export control
```

Key properties:
- **No SONAME equivalent**: DLL filename IS the identity
- **Import library (.lib)**: Required at link time, contains import stubs
- **Ordinal-based exports**: Can export by name or ordinal number
- **No symbol versioning**: New ABI = new DLL name or side-by-side assembly
- **`__declspec(dllexport/dllimport)`**: Explicit import/export annotation required

### Cross-Platform Comparison

| Concept | ELF (Linux) | PE (Windows) | Mach-O (macOS) |
|---------|-------------|--------------|-----------------|
| Library identity | SONAME | DLL filename | install_name |
| Versioning | Symbol versioning (.gnu.version) | File/product version | compat_version / current_version |
| Export mechanism | .dynsym (STV_DEFAULT) | Export table (ordinals) | LC_DYLD_INFO exports trie |
| Symbol binding | GLOBAL / WEAK / LOCAL | Exported / forwarded | External / weak |
| Import library | Not needed | .lib required | Not needed |

---

## 5. Versioned Shared Libraries

### Linux SONAME Versioning

The SONAME is the ABI epoch. It is embedded in the library and recorded as a dependency by consumers.

```bash
# Library: libfoo.so.1.2.3
# SONAME: libfoo.so.1
# Development symlink: libfoo.so → libfoo.so.1
```

**Rule: SONAME major = ABI epoch.** Bumping the SONAME major signals an incompatible change.

### Symbol Versioning (GNU ELF)

Symbol versioning allows multiple ABI generations in one `.so`:

```c
// v1 implementation
__asm__(".symver foo_v1,foo@LIBFOO_1.0");

// v2 implementation (new default)
__asm__(".symver foo_v2,foo@@LIBFOO_2.0");
```

```
# Version script
LIBFOO_1.0 {
    global: foo; bar;
    local: *;
};

LIBFOO_2.0 {
    global: foo; baz;
} LIBFOO_1.0;  # inherits from LIBFOO_1.0
```

**How it works:**
- `.gnu.version_d`: Version definitions (what this library provides)
- `.gnu.version_r`: Version requirements (what this binary needs)
- `.gnu.version`: Per-symbol version index
- Dynamic linker resolves by both name AND version

**glibc precedent:** `GLIBC_2.0` has been append-only since 1997. A binary built against old glibc loads against current glibc.

### macOS Versioning

```bash
-install_name libfoo.1.dylib \
-current_version 1.2.3 \
-compatibility_version 1.2.0
```

- `compatibility_version`: Minimum version a client requires (loader rejects older)
- `current_version`: Full version for information
- For breaking changes: ship under a new install_name path (`libfoo.2.dylib`)

### Windows

No formal symbol versioning. Breaking ABI = new DLL name (e.g., `foo_v2.dll`).

---

## 6. Symbol Visibility

### Why Visibility Matters

Uncontrolled symbol export causes:
1. **Namespace pollution**: Internal symbols collide with other libraries
2. **Larger dynamic symbol tables**: Slower loader performance
3. **ABI commitment**: Every exported symbol becomes a contract
4. **Security**: Internal symbols exposed to interposition

### Hiding Everything by Default

```bash
# Compiler flag: hide all symbols by default
gcc -fvisibility=hidden -shared -o libfoo.so foo.c
```

### Explicit Export

**Linux/macOS:**
```c
__attribute__((visibility("default")))
int32_t public_api_function(int32_t x);
```

**Windows:**
```c
__declspec(dllexport) int32_t public_api_function(int32_t x);
```

### Version Scripts (Linux)

```map
{
    global:
        astra_*;           # Export all symbols starting with astra_
        plugin_init;       # Export specific symbol
    local:
        *;                 # Hide everything else
};
```

```bash
gcc -shared -o libastra.so astra.c -Wl,--version-script=astra.map
```

### Export Headers (Cross-Platform)

```c
// astra_export.h
#if defined(_WIN32)
    #ifdef ASTRA_EXPORTS
        #define ASTRA_API __declspec(dllexport)
    #else
        #define ASTRA_API __declspec(dllimport)
    #endif
#else
    #ifdef ASTRA_EXPORTS
        #define ASTRA_API __attribute__((visibility("default")))
    #else
        #define ASTRA_API
    #endif
#endif
```

### Export Control Mechanisms

| Mechanism | Where | Granularity | Recompile needed? |
|-----------|-------|-------------|-------------------|
| `static` keyword | Source | Per-symbol, per-file | Yes |
| `visibility` attribute | Source | Per-symbol | Yes |
| Version script (.map) | Linker | Per-symbol or wildcard | No (relink only) |
| `.def` file (Windows) | Linker | Per-symbol + ordinals | No (relink only) |

---

## 7. ABI Compatibility for FFI

### Data Types Across Boundaries

**Safe FFI types (portable, well-defined):**
- Fixed-width integers: `int8_t`, `int16_t`, `int32_t`, `int64_t`
- Floating point: `float`, `double`
- Raw pointers: `void*`, `const char*`
- Opaque handles: forward-declared structs used only as pointers

**Dangerous types (platform-dependent):**
- `int` (16-bit on some embedded, 32-bit on most desktop)
- `long` (4 bytes on Windows x64, 8 bytes on Linux x64)
- `size_t`, `ptrdiff_t` (pointer-sized, platform-dependent)
- Pointers (different across architectures)

### Passing Complex Types

```c
// Safe: opaque handle pattern
typedef struct AstraContext AstraContext;

AstraContext* astra_create(void);
void astra_destroy(AstraContext* ctx);
int32_t astra_process(AstraContext* ctx, const uint8_t* data, size_t len);

// Safe: explicit struct with fixed layout
#pragma pack(push, 1)  // or use #[repr(C)] in Rust
struct AstraConfig {
    uint32_t version;
    uint32_t flags;
    double   threshold;
    uint32_t max_threads;
};
#pragma pack(pop)
```

### FFI-Safe Patterns

| Pattern | Description | Languages |
|---------|-------------|-----------|
| Opaque handles | Pass pointers to opaque types; implementation hidden | C, C++, Rust, Swift |
| C ABI functions | `extern "C"` / `extern "Astra"` | C, C++, Rust, Swift |
| Callback function pointers | Both sides agree on signature | All |
| Flat struct layout | `#[repr(C)]` / `__attribute__((packed))` | Rust, C |
| Versioned vtables | Function pointer tables with version check | Rust (`abi_stable`), C++ (COM) |

### Rust FFI Patterns

```rust
// Expose to C consumers
#[no_mangle]
pub extern "C" fn astra_create() -> *mut AstraContext {
    // ...
}

// Use Rust types safely inside, expose C at boundary
#[repr(C)]
pub struct AstraSlice {
    ptr: *const u8,
    len: usize,
}

// For Rust-to-Rust FFI, use abi_stable crate
```

---

## 8. ABI Breaks and Migration

### What Constitutes an ABI Break

| Change | ABI Impact |
|--------|-----------|
| Adding a function parameter | **BREAKING** — changes calling convention |
| Reordering struct fields | **BREAKING** — changes offsets |
| Adding a struct field (without reserved space) | **BREAKING** — changes size |
| Changing a type's size/alignment | **BREAKING** — changes layout |
| Removing a function | **BREAKING** — undefined symbol |
| Adding a new function | **COMPATIBLE** — additive |
| Adding an enum value (C enum as int) | **COMPATIBLE** — if enum is `int`-sized |
| Adding a vtable method (non-downstream) | **BREAKING** — vtable shape changes |
| Adding fields at end (with reserved space) | **COMPATIBLE** — if consumers zero-reserve |

### GCC/libstdc++ Strategy

- **Symbol versioning**: glibc-style versioned symbols in libstdc++
- **Dual ABI**: `_GLIBCXX_USE_CXX11_ABI` — old ABI (`_GLIBCXX_USE_CXX11_ABI=0`) and new ABI (`=1`) coexist
- **SONAME bump**: When ABI truly breaks (e.g., libstdc++ `std::string` layout change)
- **Cost**: Cannot use `std::string`, `std::vector` in stable C++ APIs

### LLVM Strategy

- **`LLVM_ABI` macro**: Explicit per-symbol export annotation
- **Hidden default visibility**: `-fvisibility-default=hidden` for shared library builds
- **ABI checkers**: Automated tools to detect ABI-incompatible changes
- **Resilient types**: Internal implementation details behind opaque pointers

### Rust Strategy

- **No stable ABI by design**: Rust's internal ABI is explicitly unstable
- **`extern "C"` for FFI**: Only stable ABI boundary available
- **`abi_stable` crate**: For Rust-to-Rust dynamic linking:
  - `#[derive(StableAbi)]`: Compile-time + runtime layout checking
  - Prefix types: extensible vtables/modules
  - `DynTrait`: FFI-safe trait objects
  - Load-time type verification against expected layout
- **`cdylib` output**: Produces C-compatible shared library

### Swift Strategy

- **ABI stability since Swift 5**: Full ABI stability on Apple platforms
- **Library evolution** (`-enable-library-evolution`):
  - Types are **resilient by default** — layout is opaque, accessed through accessors
  - `@frozen` opt-out: commits to fixed layout for performance
  - Structs can gain/lose fields without breaking ABI (unless `@frozen`)
  - Enums can gain cases without breaking ABI (unless `@frozen`)
- **Value witness tables**: Runtime type metadata for opaque layout operations
- **Resilience domains**: Version-locked module groups share layout knowledge

### Go Strategy

- **ABI0** (stable, stack-based): Used for hand-written assembly, preserved for backwards compatibility
- **ABIInternal** (unstable, register-based): Used for all Go-compiled code, may change between releases
- **ABI wrappers**: Transparent bridging between ABI0 and ABIInternal
- **No cross-version dynamic linking**: Go plugins must be compiled with the same Go version
- **CGo boundary**: C ABI is the stable interface between Go and C

---

## 9. Static Linking with musl

### What is musl?

musl is an alternative C standard library designed for static linking. It produces fully self-contained binaries with no runtime libc dependency.

### Building Static Binaries

```bash
# Rust
rustup target add x86_64-unknown-linux-musl
cargo build --release --target x86_64-unknown-linux-musl

# Go
CGO_ENABLED=0 go build -ldflags="-s -w" -o myapp .

# C/C++ with musl-gcc
musl-gcc -static -o myapp main.c -lm -lpthread
```

### Docker Multi-Stage Build

```dockerfile
# Build stage
FROM rust:alpine AS builder
RUN apk add --no-cache musl-dev
COPY . .
RUN cargo build --release --target x86_64-unknown-linux-musl

# Runtime stage (minimal)
FROM scratch
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/myapp /myapp
ENTRYPOINT ["/myapp"]
```

### Pros and Cons

| Aspect | Static (musl) | Dynamic (glibc) |
|--------|---------------|------------------|
| Binary size | Larger (includes libc) | Smaller |
| Deployment | Single binary, works anywhere | Must ensure correct libraries installed |
| Security patches | Must rebuild + redeploy | Update shared lib once, all benefit |
| Startup time | Faster (no loader work) | Slower (dynamic resolution) |
| Memory usage | Higher (per-process copy) | Lower (shared across processes) |
| DNS resolution | musl's resolver (simpler) | glibc's NSS (more configurable) |
| Thread stack size | 128 KiB default | Multi-megabyte default |
| dlopen/dlclose | Works, but dlclose is no-op | Full support |

### When to Use Static Linking

- **Containers**: Deploying to `scratch` or distroless images
- **Embedded systems**: No package manager, must be self-contained
- **CLI tools**: Distributed as single binary for users to download
- **Security-hardened environments**: No external library dependencies
- **Reproducible builds**: Binary is byte-for-byte identical regardless of target system

---

## 10. Astra ABI Strategy

### Design Principles

Based on the research, Astra should adopt the following ABI strategy:

#### Principle 1: C ABI as the FFI Boundary

Astra's external ABI should be C-compatible. This provides:
- Universal interop with every language that has a C FFI
- Compatibility with existing OS APIs and tooling
- Predictable behavior across compilers and platforms

```astra
// Astra code exposed to C consumers
export fn create_engine(config: *const Config) -> *mut Engine {
    // ...
}

export fn process(engine: *mut Engine, data: [*]u8, len: usize) -> i32 {
    // ...
}

export fn destroy(engine: *mut Engine) void {
    // ...
}
```

#### Principle 2: Opaque Handles for Complex Types

Never expose Astra's internal data layout across the FFI boundary:

```astra
// Good: opaque handle
export fn engine_new() -> *mut Engine;
export fn engine_destroy(engine: *mut Engine) void;
export fn engine_process(engine: *mut Engine, input: Slice(u8)) -> Result(i32);

// Bad: exposing struct layout
export struct RawEngine {  // DON'T DO THIS
    allocator: *Allocator,
    state: State,
    buffer: Buffer,
}
```

#### Principle 3: Versioned ABI

Use semantic versioning tied to ABI epochs:

```
libastra.so.1.0.0
libastra.so.1 → libastra.so.1.0.0    # SONAME symlink (ABI epoch)
libastra.so → libastra.so.1           # Development symlink
```

**ABI versioning scheme:**
- **Major version bump** (1.x.x → 2.0.0): Breaking ABI changes
- **Minor version bump** (1.0.x → 1.1.0): New functions, backward compatible
- **Patch version bump** (1.0.0 → 1.0.1): Bug fixes only, no ABI change

#### Principle 4: Symbol Visibility by Default Hidden

```bash
# All Astra shared libraries built with:
astra build --shared --visibility hidden --export-api astra_api.map
```

```map
# astra_api.map
ASTRA_1.0 {
    global:
        astra_*;            # All public API functions
        astra_version_*;    # Version query functions
    local:
        *;                  # Hide everything else
};
```

#### Principle 5: Platform-Specific Output

| Target | Command | Output |
|--------|---------|--------|
| Linux | `astra build --target linux --shared` | `libastra.so.1.0.0` |
| macOS | `astra build --target macos --shared` | `libastra.1.0.0.dylib` |
| Windows | `astra build --target windows --shared` | `astra.dll` + `astra.lib` |
| Static | `astra build --target linux --static` | `libastra.a` (or `astra` executable) |
| Full static | `astra build --target linux-musl --static` | Fully static binary |

#### Principle 6: ABI Stability Tiers

Define which parts of Astra are ABI-stable:

| Tier | Description | Stability |
|------|-------------|-----------|
| **Tier 0** | C FFI API (`extern "C"` functions) | Stable across major versions |
| **Tier 1** | Core runtime types (opaque handles) | Stable across major versions |
| **Tier 2** | Standard library | Stable within minor versions |
| **Tier 3** | Internal implementation | Unstable, may change anytime |

#### Principle 7: Forward-Compatible Struct Design

For types that must be exposed:

```astra
// Always reserve space for future fields
export struct Config {
    version: u32,       // Must be checked by consumers
    flags: u32,         // Reserved for future use
    threshold: f64,
    max_threads: u32,
    reserved: [8]u32,   // Zero-initialized; consumers must not touch
}
```

#### Principle 8: ABI Checking Tooling

```bash
# Check ABI compatibility between versions
astra abi-check --old libastra.so.1.0.0 --new libastra.so.1.1.0

# Generate ABI dump for tracking
astra abi-dump libastra.so.1.0.0 > abi_v1.json
```

### Recommended ABI Design for Astra

```
┌─────────────────────────────────────────────────────────┐
│                    Astra Application                     │
├─────────────────────────────────────────────────────────┤
│              Astra C FFI Layer (Tier 0)                  │
│  extern "C" functions with #[no_mangle]                 │
│  Opaque handles, fixed-width types, C struct layout     │
├─────────────────────────────────────────────────────────┤
│              Astra Core Runtime (Tier 1)                 │
│  Internal types behind opaque pointers                  │
│  Version-checked vtables for plugin dispatch            │
├─────────────────────────────────────────────────────────┤
│              Astra Standard Library (Tier 2)             │
│  Evolvable within minor versions                        │
│  Resilient types with accessor indirection              │
├─────────────────────────────────────────────────────────┤
│              Astra Internal (Tier 3)                     │
│  Unstable, may change between any versions              │
│  Compiler internals, optimization passes, etc.          │
└─────────────────────────────────────────────────────────┘
```

### Implementation Checklist

1. **Phase 1: C FFI Foundation**
   - Define `astra_export.h` macro for cross-platform export
   - Implement opaque handle pattern for all core types
   - Set up version scripts for Linux, export headers for Windows
   - Add `#[no_mangle] pub extern "C"` functions for all public API

2. **Phase 2: Shared Library Support**
   - Implement SONAME versioning for Linux
   - Implement install_name versioning for macOS
   - Implement DLL export/import for Windows
   - Add symbol visibility control (hidden by default)

3. **Phase 3: ABI Tooling**
   - Build ABI dump tool (JSON-based ABI metadata)
   - Build ABI compatibility checker (old vs new)
   - Integrate ABI checks into CI pipeline
   - Add ABI stability documentation

4. **Phase 4: Advanced Features**
   - Symbol versioning for backward-compatible evolution
   - Plugin system with ABI-safe vtable dispatch
   - Cross-language binding generation (C, Python, Rust, Go)
   - musl static linking support

---

## References

- [Drepper, "How To Write Shared Libraries"](https://www.akkadia.org/drepper/dsohowto.pdf)
- [abicheck: Designing for Stability](https://abicheck.github.io/abicheck/learn/abi-series/07-designing-for-stability/)
- [Swift ABI Stability Manifesto](https://github.com/swiftlang/swift/blob/main/docs/ABIStabilityManifesto.md)
- [Swift Library Evolution](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
- [Go Internal ABI Specification](https://go.googlesource.com/go/+/refs/heads/master/src/cmd/compile/abi-internal.md)
- [Rust abi_stable crate](https://docs.rs/abi_stable/latest/abi_stable/)
- [crABI RFC](https://github.com/joshtriplett/rfcs/blob/crabi-v1/text/3470-crabi-v1.md)
- [TVM FFI: Building an Open ABI](https://tvm.apache.org/2025/10/21/tvm-ffi)
- [LLVM Interface Export Annotations](https://www.llvm.org/docs/InterfaceExportAnnotations.html)
- [C Isn't A Programming Language Anymore (Faultlore)](https://faultlore.com/blah/c-isnt-a-language/)
- [ABI Stability in a Cross-Platform C++ SDK](https://doincpp.in/abi-stability-cross-platform-cpp-sdk/)
- [Android ABI Stability](https://source.android.com/docs/core/architecture/vndk/abi-stability)
- [musl libc](https://www.musl-libc.org/)
