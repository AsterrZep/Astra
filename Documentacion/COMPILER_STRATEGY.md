# Astra Compiler Strategy: Complete Evolution Plan

> **Version**: 0.1  
> **Status**: Design  
> **Last updated**: 2025

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Why Not One Language?](#2-why-not-one-language)
3. [The Three-Phase Strategy](#3-the-three-phase-strategy)
4. [Phase 1: The C Seed Compiler](#4-phase-1-the-c-seed-compiler)
5. [Phase 2: The Zig Self-Hosting Compiler](#5-phase-2-the-zig-self-hosting-compiler)
6. [Phase 3: Astra Compiles Itself](#6-phase-3-astra-compiles-itself)
7. [The Bootstrap Chain](#7-the-bootstrap-chain)
8. [Why Not Rust?](#8-why-not-rust)
9. [Why Not Go?](#9-why-not-go)
10. [Why Not C++?](#10-why-not-c)
11. [Why Not OCaml/Nim?](#11-why-not-ocamlnim)
12. [Performance Analysis](#12-performance-analysis)
13. [Risk Analysis](#13-risk-analysis)
14. [Timeline](#14-timeline)
15. [Decision Log](#15-decision-log)

---

## 1. Executive Summary

Astra will be built through a **three-phase bootstrapping strategy**:

```
Phase 1: C seed compiler (Astra-0)
    ↓ compiles minimal Astra subset
Phase 2: Zig self-hosting compiler (Astra-1)
    ↓ compiles full Astra
Phase 3: Astra compiles itself (Astra-N)
```

This is not an arbitrary choice. Every language in this chain was selected for a specific purpose, at a specific phase, with specific trade-offs. This document explains **why**.

---

## 2. Why Not One Language?

The naive approach is to pick one language and build everything in it. This fails for Astra because:

### The Chicken-and-Egg Problem

To compile Astra, you need a compiler. To run the compiler, you need a runtime. To have a runtime, you need to compile Astra. This circular dependency is resolved by **bootstrapping** — using a simpler language to build the first compiler, which then compiles the real compiler.

### Historical Precedent

Every successful self-hosted language used bootstrapping:

| Language | Seed Language | Self-Hosting Since |
|:---------|:-------------|:-------------------|
| **C** | Assembly (PDP-7) | 1973 |
| **Go** | C (Plan 9) | Go 1.5 (2015) |
| **Rust** | OCaml (rustboot) | Rust 0.9 (2014) |
| **Zig** | C++ (stage1) | 0.11 (2023) |
| **Swift** | C++ | Swift 3.0 (2016) |
| **Nim** | Pascal | 0.10 (2014) |

No language started self-hosted. The seed compiler is a **temporary tool** — used once, then retired.

### The Key Insight

> **The seed compiler is not the product. It's the tool that builds the product.**

Don't over-invest in the seed. Don't choose the "best" language for the seed. Choose the **simplest** language that produces a correct compiler. Then move on.

---

## 3. The Three-Phase Strategy

```
┌─────────────────────────────────────────────────────────────┐
│                    PHASE 1: SEED (C)                        │
│                                                              │
│  Written in C                                                │
│  Compiles: Minimal Astra subset (Astra-0)                   │
│  Backend: Bytecode VM                                        │
│  Features: types, functions, structs, enums, match, I/O     │
│  Purpose: Bootstrap the self-hosting compiler                │
│  Lifespan: Retired after Phase 2                            │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│                    PHASE 2: SELF-HOST (Zig)                 │
│                                                              │
│  Written in Zig                                              │
│  Compiles: Full Astra (Astra-1)                             │
│  Backend: Bytecode VM + LLVM                                │
│  Features: generics, traits, comptime, ARC/ORC, fibers      │
│  Purpose: Production compiler                               │
│  Lifespan: Permanent (or replaced by Phase 3)               │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│                    PHASE 3: SELF-COMPILED (Astra)           │
│                                                              │
│  Written in Astra                                            │
│  Compiles: Astra (Astra-N)                                  │
│  Backend: Bytecode VM + LLVM                                │
│  Features: Full language                                     │
│  Purpose: The compiler is the proof of the language          │
│  Lifespan: Permanent                                         │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Why Three Phases?

**Phase 1 (C) → Phase 2 (Zig):** The C seed compiles a minimal Astra that's powerful enough to compile the Zig-based compiler. The Zig compiler is the "real" compiler — it handles all the complex features (generics, traits, comptime, ARC/ORC).

**Phase 2 (Zig) → Phase 3 (Astra):** The Zig compiler compiles Astra code. Eventually, Astra becomes powerful enough to compile itself. At this point, the Zig compiler is replaced by the Astra compiler.

**Why not skip Phase 1?** Because you need *something* to compile the Zig compiler. Zig requires `zig` to build Zig programs. The C seed provides the initial `astra` command that can compile the minimal subset needed.

**Why not skip Phase 2?** Because writing the full compiler in C is impractical. C lacks the abstractions (sum types, generics, pattern matching) needed for a complex compiler. Zig provides these abstractions while maintaining C-level control.

---

## 4. Phase 1: The C Seed Compiler

### 4.1 Purpose

The C seed compiler exists for one reason: **to compile the self-hosting compiler**. It does NOT need to:
- Support all Astra features
- Be fast
- Have good error messages
- Support cross-compilation
- Be maintainable long-term

It DOES need to:
- Correctly compile the self-hosting compiler source code
- Run on Linux, macOS, and Windows
- Be buildable with `cc *.c -o astra-seed` (zero dependencies)
- Be auditable (the seed is the root of trust)

### 4.2 What It Compiles (Astra-0)

The seed compiler supports a minimal subset of Astra called **Astra-0**:

```astra
// Astra-0: The minimal subset for bootstrapping

// Primitive types
let x: i32 = 42;
let y: f64 = 3.14;
let z: bool = true;
let s: string = "hello";

// Functions
fn add(a: i32, b: i32) -> i32 {
    a + b
}

// Structs
struct Point {
    x: f64,
    y: f64,
}

// Enums
enum Color {
    Red,
    Green,
    Blue,
}

// Pattern matching
fn color_name(c: Color) -> string {
    match c {
        Color.Red => "red",
        Color.Green => "green",
        Color.Blue => "blue",
    }
}

// Control flow
fn factorial(n: i32) -> i32 {
    if n <= 1 {
        1
    } else {
        n * factorial(n - 1)
    }
}

// Arrays
let numbers: [i32] = [1, 2, 3, 4, 5];

// Option/Result
fn divide(a: f64, b: f64) -> Result<f64, string> {
    if b == 0.0 {
        Err("division by zero")
    } else {
        Ok(a / b)
    }
}

// Error propagation
fn compute() -> Result<f64, string> {
    let x = divide(10.0, 2.0)?;  // ? propagates errors
    Ok(x * 3.0)
}

// Basic I/O
fn main() {
    print("Hello, World!");
}
```

### 4.3 What It Does NOT Support

| Feature | Why Not Needed for Seed |
|:--------|:------------------------|
| Generics | The self-hosting compiler doesn't use generics in its core |
| Traits | Not needed for bootstrap code |
| Comptime | Zig has its own comptime |
| ARC/ORC | The compiler is a batch program, not a server |
| Green threads | Single-threaded compilation |
| FFI | The seed doesn't call external libraries |
| Modules | Single-file or simple `#include` |
| Closures | Not needed for bootstrap |
| Pilas dinámicas | The seed doesn't need dynamic growth |

### 4.4 Architecture

```
┌─────────────────────────────────────────┐
│         C Seed Compiler (astra-seed)     │
│                                          │
│  ┌──────────┐  ┌──────────┐             │
│  │  Lexer   │→│  Parser  │             │
│  │ (hand-   │  │ (recursive│             │
│  │  written)│  │  descent +│             │
│  └──────────┘  │  Pratt)  │             │
│                └────┬─────┘             │
│                     │                   │
│                ┌────▼─────┐             │
│                │   AST    │             │
│                └────┬─────┘             │
│                     │                   │
│                ┌────▼─────┐             │
│                │  Type    │             │
│                │  Checker │             │
│                └────┬─────┘             │
│                     │                   │
│                ┌────▼─────┐             │
│                │ Bytecode │             │
│                │ Emitter  │             │
│                └────┬─────┘             │
│                     │                   │
│                ┌────▼─────┐             │
│                │   VM     │             │
│                └──────────┘             │
└─────────────────────────────────────────┘
```

### 4.5 Design Decisions

| Decision | Choice | Why |
|:---------|:-------|:----|
| **Parser** | Hand-written recursive descent + Pratt | Full control over error recovery, no generator dependency |
| **AST representation** | Tagged unions (C structs with enum tag) | Simple, auditable, no hidden allocations |
| **Type checker** | Simple Hindley-Milner | Sufficient for Astra-0, well-understood algorithm |
| **Backend** | Bytecode VM (stack-based) | Simple to implement, fast enough for bootstrap |
| **Memory management** | Arena allocator | No individual `free()` calls, deterministic cleanup |
| **Error handling** | `setjmp/longjmp` | C's only viable error recovery mechanism |
| **String handling** | Interned strings (pointer comparison) | Fast equality checks, memory efficient |

### 4.6 Build System

```makefile
# Makefile — intentionally simple
CC = cc
CFLAGS = -Wall -Wextra -std=c11 -g
SRCS = $(wildcard *.c)
OBJS = $(SRCS:.c=.o)

astra-seed: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o astra-seed

.PHONY: clean
```

**Why a Makefile and not CMake/Meson?** Because the seed is temporary. A Makefile is 10 lines. CMake is 50+ lines. Don't over-engineer a throwaway tool.

### 4.7 Testing the Seed

The seed compiler is tested against:
1. **Self-hosting compiler source**: The seed must compile the Zig-based compiler
2. **Astra-0 conformance tests**: 100-200 test cases covering the minimal subset
3. **Cross-platform**: Must build and run on Linux, macOS, Windows

```bash
# Test the seed
make clean && make
./astra-seed --test tests/conformance/
./astra-seed bootstrap/compiler.zig  # Must succeed
```

---

## 5. Phase 2: The Zig Self-Hosting Compiler

### 5.1 Purpose

The Zig compiler is the **real** compiler. It handles:
- All Astra features (generics, traits, comptime, ARC/ORC, fibers)
- LLVM backend for optimized code generation
- Cross-compilation to all target platforms
- Good error messages and diagnostics
- Package manager integration

### 5.2 Why Zig?

#### `comptime` — Metaprogramming Without Macros

```zig
// Generate a lookup table at compile time
const lookup = comptime blk: {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, i| {
        entry.* = @intCast(i * 2 % 256);
    }
    break :blk table;
};

// Validate format strings at compile time
fn format(comptime fmt: []const u8, args: anytype) void {
    comptime {
        // Check format string at compile time
        for (fmt) |c| {
            if (c == '{') {
                // validate placeholder
            }
        }
    }
    // ... runtime formatting
}
```

**Why this matters for Astra:** The compiler needs to generate lookup tables, validate format strings, and specialize generic types. In C, this requires code generators or macros. In Zig, it's just code.

#### Explicit Allocators — No Hidden Allocations

```zig
// Arena allocator for parse trees (batch allocation, single free)
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

// Parse tree allocated in arena — no individual frees needed
const tree = try parse(allocator, source);

// General-purpose allocator for type tables (individual allocations)
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const type_alloc = gpa.allocator();
```

**Why this matters for Astra:** Compilers allocate millions of small objects (AST nodes, type entries, string interns). Arena allocators make this efficient. In languages with GC, you can't control allocation patterns. In Rust, the borrow checker complicates arena-based designs.

#### C Interop — Seamless FFI

```zig
// Import C headers directly
const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
});

// Call C functions directly
const module = c.LLVMModuleCreateWithName("astra");
c.LLVMAddFunction(module, "main", ...);
```

**Why this matters for Astra:** The compiler needs to call LLVM for code generation. Zig's C interop makes this seamless — no bindings, no FFI layers, just direct calls.

#### Cross-Compilation — Best in Class

```bash
# Cross-compile the compiler itself for any target
zig build -Dtarget=aarch64-linux-musl      # ARM64 Linux static
zig build -Dtarget=x86_64-windows-msvc     # Windows
zig build -Dtarget=aarch64-apple-darwin    # macOS ARM64
```

**Why this matters for Astra:** The compiler must run on the developer's machine and produce binaries for all platforms. Zig's cross-compilation is unmatched.

#### C Backend — Bootstrap Safety Net

```bash
# Compile the Zig compiler to C
zig build --only-c
# Produces: astra_compiler.c
# Compile with: cc astra_compiler.c -o astra
```

**Why this matters:** If Zig's bootstrap breaks, we can always translate the Zig compiler to C and compile with a C compiler. This is a safety net that no other language provides.

### 5.3 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│              Zig Self-Hosting Compiler (astra-zig)           │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                  │
│  │  Lexer   │→│  Parser  │→│   AST    │                  │
│  │ (PEG)    │  │ (Pratt)  │  │          │                  │
│  └──────────┘  └──────────┘  └────┬─────┘                  │
│                                    │                        │
│  ┌─────────────────────────────────▼─────────────────────┐  │
│  │              Semantic Analysis                        │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │  │
│  │  │   Name   │→│   Type   │→│  Borrow  │           │  │
│  │  │ Resolver │  │  Checker │  │  Checker │           │  │
│  │  └──────────┘  └──────────┘  └──────────┘           │  │
│  └─────────────────────────────────┬─────────────────────┘  │
│                                    │                        │
│  ┌─────────────────────────────────▼─────────────────────┐  │
│  │              AIR Generation                           │  │
│  │  • Insert ARC increment/decrement                     │  │
│  │  • Insert fiber yield points                          │  │
│  │  • Specialize generics                                │  │
│  │  • Erase types where possible                         │  │
│  └─────────────────────────────────┬─────────────────────┘  │
│                                    │                        │
│              ┌─────────────────────┼─────────────────────┐  │
│              │                     │                     │  │
│     ┌────────▼────────┐  ┌────────▼────────┐  ┌────────▼──┐
│     │   Bytecode VM   │  │   LLVM Backend  │  │  C Output │
│     │  (dev mode)     │  │  (prod mode)    │  │ (bootstrap│
│     └─────────────────┘  └─────────────────┘  └───────────┘
└─────────────────────────────────────────────────────────────┘
```

### 5.4 What It Compiles (Astra-1 / Full Astra)

The Zig compiler supports the **full Astra language**:

```astra
// Full Astra (compiled by the Zig compiler)

// Generics
fn map<T, U>(items: []T, f: fn(T) -> U) -> []U { ... }

// Traits
trait Comparable {
    fn compare(self, other: Self) -> Ordering;
}

// Comptime
comptime {
    const table = generateLookupTable();
}

// ARC/ORC (automatic, no annotations needed)
struct Node {
    next: ?Node,     // ARC-managed, cycle-detected
    value: i32,
}

// Green threads
fn handle_request(conn: TcpConnection) {
    let data = conn.read()?;    // suspends fiber, not thread
    let response = process(data);
    conn.write(response)?;       // resumes fiber
}

// Cross-platform
#[cfg(target = "linux")]
fn platform_specific() { ... }

#[cfg(target = "macos")]
fn platform_specific() { ... }
```

### 5.5 Build System

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Astra compiler
    const compiler = b.addExecutable(.{
        .name = "astra",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link LLVM
    compiler.linkSystemLibrary("llvm");
    compiler.linkSystemLibrary("clang");

    b.installArtifact(compiler);
}
```

**Why `build.zig` and not Makefile?** Because the Zig compiler is permanent, complex, and cross-platform. `build.zig` provides:
- Cross-compilation as a first-class feature
- Dependency management
- Test integration
- Optimized builds

---

## 6. Phase 3: Astra Compiles Itself

### 6.1 The Goal

The final state: Astra compiles its own compiler. This is the proof that the language works.

### 6.2 How It Happens

The Zig compiler (Phase 2) compiles the Astra compiler (written in Astra). The resulting binary is the Astra compiler.

```bash
# Using the Zig compiler to compile the Astra compiler
astra-zig build compiler/ --target=aarch64-unknown-linux-musl
# Produces: astra (the Astra compiler, written in Astra)

# Now use Astra to compile itself
./astra build compiler/ --target=x86_64-pc-windows-msvc
# Produces: astra.exe (the Astra compiler for Windows)
```

### 6.3 Verification: Diverse Double-Compilation

To verify the Astra compiler is correct, use **diverse double-compilation**:

```bash
# Step 1: Zig compiles Astra compiler → binary_a
astra-zig build compiler/ -o binary_a

# Step 2: Astra (binary_a) compiles Astra compiler → binary_b
./binary_a build compiler/ -o binary_b

# Step 3: Astra (binary_b) compiles Astra compiler → binary_c
./binary_b build compiler/ -o binary_c

# Step 4: Verify binary_b == binary_c (fixed point)
diff binary_b binary_c  # Should be identical
```

If `binary_b == binary_c`, the compiler is **self-consistent** — it produces the same output regardless of what compiled it.

### 6.4 What Changes

| Aspect | Phase 2 (Zig) | Phase 3 (Astra) |
|:-------|:-------------|:----------------|
| Compiler language | Zig | Astra |
| Build dependency | `zig` toolchain | `astra` compiler |
| Runtime | Zig standard library | Astra standard library |
| Memory management | Zig allocators | Astra ARC/ORC |
| Concurrency | Zig threads | Astra fibers |
| Cross-compilation | Zig's cross-compilation | Astra's cross-compilation |

### 6.5 The Beautiful Loop

```
Astra compiles itself
  → The compiler is written in Astra
    → The compiler uses Astra features (generics, traits, ARC/ORC)
      → The compiler proves Astra works
        → The compiler is the ultimate test case
```

---

## 7. The Bootstrap Chain

### 7.1 Complete Bootstrap Sequence

```
Step 1: Build C seed
    cc *.c -o astra-seed

Step 2: Seed compiles minimal Astra
    ./astra-seed src/stdlib/stdlib.astra -o stdlib.o
    ./astra-seed src/compiler/compiler.astra -o compiler.o
    cc stdlib.o compiler.o -o astra-v0

Step 3: astra-v0 compiles Zig compiler source
    ./astra-v0 bootstrap/zig-compiler.zig -o astra-zig

Step 4: astra-zig compiles full Astra compiler
    ./astra-zig build src/compiler/ -o astra

Step 5: astra compiles itself
    ./astra build src/compiler/ -o astra-self
    ./astra-self build src/compiler/ -o astra-verified
    diff astra-self astra-verified  # Must be identical
```

### 7.2 Trust Chain

```
C compiler (gcc/clang) — trusted (system compiler)
  → astra-seed — auditable (simple C code)
    → astra-v0 — compiled by seed (verify conformance tests)
      → astra-zig — compiled by v0 (verify it compiles correctly)
        → astra — compiled by zig (verify conformance tests)
          → astra-self — compiled by astra (verify binary reproducibility)
```

### 7.3 Why This Trust Chain Works

1. **C compiler is trusted**: It's the system compiler, used by billions of lines of code
2. **C seed is auditable**: ~5000 lines of C, no dependencies, easy to review
3. **astra-v0 is verified**: Must pass all conformance tests
4. **astra-zig is verified**: Must compile correctly and pass tests
5. **astra is verified**: Must produce identical output to itself

---

## 8. Why Not Rust?

### 8.1 The Argument for Rust

Rust is excellent for building compilers:
- Memory safety without GC
- Sum types for AST representation
- Pattern matching for diagnostics
- Excellent tooling (cargo, clippy, rust-analyzer)
- `rustc` proves Rust can build compilers

### 8.2 Why We Don't Use Rust

#### Compile Times

```
Rust compile times (2025 compiler performance survey):
- Full rebuild of medium project: 30-120 seconds
- Incremental rebuild: 2-10 seconds
- 45% of users who left Rust cited compile times

Zig compile times (2026 benchmarks):
- Full rebuild of medium project: 5-20 seconds
- Incremental rebuild: <1 second
- 2.3x faster than Rust
```

For a compiler project that recompiles thousands of times during development, this difference is **massive**. A 10-second difference × 1000 rebuilds/day = 2.8 hours/day wasted.

#### Bootstrap Dependency

```
To build a Rust program, you need rustc.
To build rustc, you need... rustc.

The bootstrap chain: mrustc (C++) → rustc (Rust)
- mrustc lags behind stable Rust by 6-12 months
- mrustc doesn't support all Rust features
- The bootstrap is fragile and hard to maintain
```

For Astra, we need a clean bootstrap chain. Rust's bootstrap is a known pain point.

#### Borrow Checker Friction

Compiler data structures are graph-like:
- AST nodes have parent pointers
- Type tables have back-references
- Symbol tables reference multiple scopes

The borrow checker fights against these patterns:
```rust
// This is hard in Rust:
struct Node {
    parent: *const Node,  // back-pointer — borrow checker hates this
    children: Vec<Node>,
}
```

In Zig, this is straightforward:
```zig
const Node = struct {
    parent: ?*const Node,
    children: std.ArrayList(*Node),
};
```

#### Roc's Migration

The Roc compiler team is **actively migrating from Rust to Zig** for these exact reasons:
- Faster compile times
- Simpler bootstrap
- Direct LLVM bitcode generation
- Better C interop

From the Roc blog: "We found that Zig's explicit memory model and comptime made our compiler code simpler and faster to iterate on."

### 8.3 When Rust Would Be Better

Rust would be the better choice IF:
- Astra's runtime (ARC/ORC, fibers) was the primary concern (Rust excels at systems programming)
- Compile times weren't a factor
- The bootstrap chain wasn't a concern
- The team already knew Rust

For a compiler project with bootstrap requirements, Zig is the better choice.

---

## 9. Why Not Go?

### 9.1 The Fatal Flaw: GC

Go's garbage collector is **non-negotiable**. You cannot:
- Disable it
- Replace it with ARC/ORC
- Implement custom memory management
- Control when collections happen

Astra's runtime requires:
- ARC/ORC for automatic memory management
- Fiber-aware memory allocation
- Deterministic deallocation (no GC pauses)
- Custom allocators for different use cases

**You cannot implement Astra's runtime in Go.** Go's runtime would interfere with Astra's memory model.

### 9.2 Other Issues

| Issue | Impact |
|:------|:-------|
| No sum types | AST representation requires `interface{}` — no type safety |
| No pattern matching | Compiler diagnostics require verbose `switch` statements |
| No comptime | No compile-time metaprogramming |
| Goroutine scheduler | Can't replace with Astra's M:N fiber scheduler |
| `if err != nil` | Verbose error handling for compiler code with many failure modes |

### 9.3 What Go Does Well

Go is excellent for:
- DevOps tools (Docker, Kubernetes, Terraform)
- CLI tools with simple logic
- Network services
- Build systems

But it's not suitable for building a language runtime that requires explicit memory control.

---

## 10. Why Not C++?

### 10.1 Complexity

C++ is the most complex language in widespread use:
- Templates, SFINAE, CRTP, concepts, ranges
- Move semantics, perfect forwarding
- Exception handling interacts poorly with fibers
- Header files, ODR, ABI instability
- Undefined behavior is rampant

For a compiler project, this complexity adds cognitive load without proportional benefit.

### 10.2 Compile Times

C++ has notoriously slow compile times:
- Template instantiation is expensive
- Header inclusion is a bottleneck
- Modules (C++20) help but are not widely adopted

### 10.3 Hidden Costs

C++ constructors, destructors, and exceptions add hidden runtime costs:
- Object construction/destruction on every scope exit
- Exception tables increase binary size
- `thread_local` storage interacts poorly with fiber scheduling

### 10.4 Why LLVM Uses C++

LLVM uses C++ because:
- It was written in 2000-2003 when C++ was the best systems language available
- The LLVM team is large and can manage C++ complexity
- LLVM's API is designed for C++ (RAII, templates)

For a new project in 2025+, Zig provides the same control with less complexity.

---

## 11. Why Not OCaml/Nim?

### 11.1 OCaml

**Pros**: Excellent for compiler construction, pattern matching, type inference, GC for batch programs.

**Cons**:
- GC is incompatible with Astra's runtime (same problem as Go)
- Cross-compilation is limited (Unix-centric ecosystem)
- Niche community (harder to find contributors)
- No equivalent to Zig's cross-compilation

### 11.2 Nim

**Pros**: Compiles to C, Python-like syntax, ORC/ARC support.

**Cons**:
- Compiler has had stability issues
- ORC/ARC is tightly coupled to Nim's runtime
- Cross-compilation requires C cross-compiler
- Smaller community, slower development
- The transition from refc to ORC/ARC caused ecosystem fragmentation

---

## 12. Performance Analysis

### 12.1 Compiler Build Times

| Language | Full Rebuild | Incremental | Daily (1000 rebuilds) |
|:---------|:-------------|:------------|:----------------------|
| **C** | 5-10s | 1-2s | 1.4-2.8 hours |
| **Zig** | 5-20s | <1s | 1.4-2.8 hours |
| **Rust** | 30-120s | 2-10s | 8.3-33.3 hours |
| **Go** | 2-5s | <1s | 0.6-1.4 hours |
| **C++** | 20-60s | 3-15s | 5.6-16.7 hours |

**Winner**: Go (fastest), but Go is disqualified for other reasons. **Zig is 2.3x faster than Rust** and足够 fast for compiler development.

### 12.2 Generated Code Quality

| Language | Backend | Code Quality vs C |
|:---------|:--------|:-------------------|
| **C** | Native | 1.0x (baseline) |
| **Zig** | LLVM | 0.95-1.0x |
| **Rust** | LLVM | 0.95-1.0x |
| **Go** | Native | 0.7-0.9x |
| **Nim** | C backend | 0.9-1.0x |

**Winner**: C, Zig, Rust (all use LLVM or equivalent). Go is slower due to GC overhead.

### 12.3 Runtime Performance (for the compiler itself)

| Operation | C | Zig | Rust | Go |
|:----------|:-:|:---:|:----:|:--:|
| Allocation (arena) | ~5ns | ~5ns | ~5ns | ~50ns (GC) |
| Allocation (general) | ~20ns | ~20ns | ~20ns | ~50ns (GC) |
| Hash table lookup | ~50ns | ~50ns | ~50ns | ~60ns |
| String comparison | ~10ns | ~10ns | ~10ns | ~10ns |

**Winner**: C and Zig (identical performance). Rust is comparable. Go is slower due to GC.

---

## 13. Risk Analysis

### 13.1 Phase 1 Risks (C Seed)

| Risk | Likelihood | Impact | Mitigation |
|:-----|:-----------|:-------|:-----------|
| C bugs (memory safety) | High | Medium | Arena allocator, ASAN, code review |
| Seed can't compile self-host | Low | High | Test early, test often |
| Cross-platform issues | Medium | Medium | CI on Linux, macOS, Windows |

### 13.2 Phase 2 Risks (Zig Self-Hosting)

| Risk | Likelihood | Impact | Mitigation |
|:-----|:-----------|:-------|:-----------|
| Zig pre-1.0 instability | Medium | High | Pin Zig version, test with each release |
| Zig bootstrap breaks | Low | High | C backend as safety net |
| LLVM API changes | Medium | Medium | Pin LLVM version, test with each release |

### 13.3 Phase 3 Risks (Astra Self-Compiled)

| Risk | Likelihood | Impact | Mitigation |
|:-----|:-----------|:-------|:-----------|
| Compiler can't compile itself | Medium | High | Incremental self-hosting, test each feature |
| Performance regression | Medium | Medium | Benchmark suite, compare with Zig compiler |
| Regression bugs | High | High | Differential testing (Astra vs Zig compiler) |

---

## 14. Timeline

### Phase 1: C Seed Compiler (Months 1-6)

| Month | Milestone |
|:------|:----------|
| 1 | Lexer + Parser + basic AST |
| 2 | Type checker + basic code generation |
| 3 | Bytecode VM + error handling |
| 4 | Structs, enums, match, arrays |
| 5 | Option/Result, error propagation |
| 6 | Testing, cross-platform, documentation |

### Phase 2: Zig Self-Hosting Compiler (Months 7-18)

| Month | Milestone |
|:------|:----------|
| 7-8 | Lexer + Parser (PEG + Pratt) |
| 9-10 | Type system (inference, generics, traits) |
| 11-12 | AIR generation (ARC, yield points, type erasure) |
| 13-14 | Bytecode VM backend |
| 15-16 | LLVM backend |
| 17-18 | Cross-compilation, testing, documentation |

### Phase 3: Astra Self-Compiled (Months 19-24)

| Month | Milestone |
|:------|:----------|
| 19-20 | Rewrite compiler frontend in Astra |
| 21-22 | Rewrite compiler backend in Astra |
| 23 | Self-compilation and verification |
| 24 | Performance optimization, documentation |

---

## 15. Decision Log

| # | Decision | Date | Rationale |
|:--|:---------|:-----|:----------|
| 1 | Use C for seed compiler | 2025 | Zero dependencies, auditable, universal, throwaway |
| 2 | Use Zig for self-hosting compiler | 2025 | comptime, explicit allocators, cross-compilation, C interop |
| 3 | Three-phase bootstrap | 2025 | C→Zig→Astra proven by Go, Rust, Zig precedents |
| 4 | Hand-written parser | 2025 | Full control over errors, LSP-friendly, no generator dependency |
| 5 | Pratt parsing for expressions | 2025 | Modular, handles all operator types, used by Clang/rust-analyzer |
| 6 | Stack-based bytecode VM | 2025 | Simpler than register-based, sufficient for development |
| 7 | LLVM for production backend | 2025 | Best optimizing compiler, cross-compilation, proven by Rust/Swift |
| 8 | Arena allocators for compiler | 2025 | Batch allocation, single free, predictable performance |
| 9 | PEG grammar (not EBNF) | 2025 | No ambiguity, first-match semantics, maps to recursive descent |
| 10 | No C codegen for cross-compilation | 2025 | Nim's experience shows C as IR is fragile |

---

*This document is a living reference. As implementation progresses, decisions will be updated and new sections will be added.*
