# Astra Language: Comprehensive Research Report

**Topics:** WASM Backend, GPU Kernel Generation, REPL/Jupyter, LSP Integration

---

## Table of Contents

1. [WebAssembly (WASM) Backend](#1-webassembly-wasm-backend)
2. [GPU Kernel Generation](#2-gpu-kernel-generation)
3. [REPL and Jupyter Notebook Support](#3-repl-and-jupyter-notebook-support)
4. [LSP (Language Server Protocol) Integration](#4-lsp-language-server-protocol-integration)

---

## 1. WebAssembly (WASM) Backend

### 1.1 How Existing Languages Compile to WASM

#### Zig

Zig uses a two-stage compilation approach. The self-hosted compiler can emit WASM directly via `-ofmt=wasm`, bypassing LLVM entirely. The Zig compiler has been successfully compiled to a single WASM module (`zig1.wasm`) using its own backend, demonstrating true self-hosting to WASM. For production, Zig uses LLVM's WASM backend with optimizations. Key characteristics:

- **Self-hosted WASM backend:** Hand-written code generation targeting WASM instruction set directly, avoiding LLVM dependency.
- **Cross-compilation first:** `zig build -Dtarget=wasm32-wasi` produces WASM with WASI support.
- **Lazy compilation:** Only compiles referenced functions, reducing output size.

#### Rust (wasm-pack / wasm-bindgen)

Rust's WASM story uses LLVM's `wasm32-unknown-unknown` target with `wasm-bindgen` for JS interop:

```
rustup target add wasm32-unknown-unknown
wasm-pack build --target web
```

**Toolchain:**
- `rustc` → LLVM → WASM binary (core module)
- `wasm-bindgen` → Generates JS glue code and type definitions
- `wasm-pack` → Bundles into npm-compatible package
- `wasm-opt` → Binary size optimization (Oz, O3)

**Key design:** Rust compiles to a core WASM module, then `wasm-bindgen` post-processes it to generate host bindings. Memory is managed via the WASM linear memory (`ArrayBuffer`), with Rust's allocator writing directly into it. JS↔WASM boundary crossing has high cost (~10x for primitives, ~50x for strings, ~100x for serde roundtrips).

#### AssemblyScript

AssemblyScript is a TypeScript dialect that compiles directly to WASM via Binaryen:

- **Compiler pipeline:** Source → TypeScript-like parser → AST → Binaryen IR → WASM binary
- **No LLVM dependency:** Uses Binaryen as the WASM-specific optimizer and code generator.
- **Standard library:** Dual-mode standard library (`assembly/` for WASM target, `portable/` for JS target with `tsc`).
- **Tree shaking:** Starts from entry file exports and traverses reachable code only, skipping dead code at compile time.
- **Self-hosting:** The compiler itself compiles to WASM, though it currently uses a JavaScript frontend for I/O and links to Binaryen (C++ compiled with Emscripten).

**Architecture (from AssemblyScript wiki):**
1. Tokenizer and parser → AST (syntax-level checking)
2. Program construction from AST (sanity checking)
3. Elements act as IR, holding type/identifier resolution info
4. Code generation to Binaryen module (statement/expression-level checking)
5. Binaryen validation, optimization, and emission (.wat, .wasm, .js)

#### Grain

Grain is a functional language that compiles to WASM via Binaryen:

- Uses Binaryen as the compilation target (similar to AssemblyScript).
- The compiler itself is written in OCaml.
- Generates lean WASM modules with minimal runtime overhead.
- WASI-first design: Grain programs are WASI components by default.

### 1.2 WASM Component Model and WASI

#### Component Model

The WebAssembly Component Model provides a higher-level abstraction over core WASM modules:

- **Components** vs **Core Modules:** A component uses the Component Model binary format with WIT (WebAssembly Interface Types) for type information, and follows the Canonical ABI for rich type conversions.
- **Interoperability:** Components from different languages (Rust, Go, Python, JS) can communicate via shared WIT interfaces.
- **Resource types:** Components support resource handles with proper ownership semantics.
- **Shared-nothing linking:** Components have isolated memories; data exchange uses canonical ABI serialization.

**WIT (WebAssembly Interface Types):** An IDL for defining component interfaces:

```wit
package astra:math;

interface linear-algebra {
    record vec3 { x: f64, y: f64, z: f64 }
    add: func(a: vec3, b: vec3) -> vec3;
    dot: func(a: vec3, b: vec3) -> f64;
}

world astra-runtime {
    export linear-algebra;
}
```

#### WASI (WebAssembly System Interface)

| Version | Status | Key Features |
|:--------|:-------|:-------------|
| WASI 0.1 (Preview 1) | Stable, widely used | POSIX-like syscalls, witx IDL, single-address-space |
| WASI 0.2 (Preview 2) | Stable (Jan 2024) | Component Model foundation, WIT-based, modular interfaces (wasi:cli, wasi:http, wasi:sockets) |
| WASI 0.3 (Preview 3) | Current (Jun 2026) | Native async (`async func`, `stream<T>`, `future<T>`), removes wasi:io package |

**WASI 0.2 Worlds:**
- `wasi:cli/command` — CLI applications (stdin/stdout/stderr, args, env, filesystem)
- `wasi:http/proxy` — HTTP handlers (outgoing/incoming requests)

**Security model:** Capability-based sandboxing. A WASM component starts with zero ambient authority and can only access resources explicitly granted by the host.

**Supported runtimes:** Wasmtime, WasmEdge, Wasmer, WAMR, wazero, wasmi, wasm3.

### 1.3 Astra's AIR → WASM Translation Strategy

Given Astra's architecture (AIR as unified IR with ARC injection, yield points, and type erasure), the WASM backend should follow this pipeline:

```
AIR (Astra IR)
    │
    ▼
┌─────────────────────────────┐
│ 1. Type Erasure             │  Units of measure → f64/i64/etc.
│    (already in AIR)         │  Generic specializations resolved
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│ 2. ARC/ORC Lowering         │  Ref-count intrinsics → WASM function calls
│    to WASM primitives       │  atomic_ref_inc → WASM atomic operations
│                             │  trial_deletion → ORC cycle collector calls
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│ 3. Fiber Runtime Emission   │  yield_point → WASM suspend/resume
│    (for WASM target)        │  Stack switching via WASM stack-switching
│                             │  proposal or continuation-passing
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│ 4. Code Generation          │  AIR instructions → WASM instructions
│    (WASM instruction        │  Control flow → block/loop/br/if
│     selection)              │  Memory ops → i32.load/store etc.
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│ 5. Module Assembly          │  Imports: WASI interfaces (wasi:cli)
│    + WASI Component         │  Exports: Astra functions, _start
│    binding                  │  Memory: Linear memory with grow
└─────────────────────────────┘
```

#### Key Translation Decisions

**Strategy choice: Binaryen backend (recommended over raw WASM codegen)**

AssemblyScript and Grain both use Binaryen successfully. Binaryen provides:
- Mature WASM optimizer (dead code elimination, constant folding, CFG simplification)
- Text format output (.wat) for debugging
- Binaryen IR is close to WASM semantics, making lowering straightforward

For Astra, the recommended approach is:

```
AIR → Binaryen IR → WASM binary
```

Rather than AIR → custom WASM codegen, which would require reimplementing optimization passes.

**Alternative: LLVM WASM backend** for production builds (AOT mode) using LLVM's `wasm32-wasi` target, which provides better optimization but larger toolchain dependency.

#### Dual Backend Strategy for WASM

| Astra Mode | WASM Strategy | Rationale |
|:-----------|:--------------|:----------|
| Dev (`astra run --wasm`) | Binaryen (fast compilation) | Sub-second compilation, reasonable output quality |
| Prod (`astra build --wasm --release`) | LLVM WASM backend | Aggressive optimization, monomorphization, inlining |

### 1.4 Memory Model Implications (ARC in WASM)

#### The Core Challenge

WASM linear memory is a single contiguous `ArrayBuffer`. ARC reference counts must be stored in this memory, and atomic operations must be supported for cross-fiber sharing.

**Reference count storage:**
```
┌─────────────────────────────────────────┐
│ WASM Linear Memory                      │
│                                         │
│ ┌─────────┬──────┬────────────────────┐ │
│ │ refcount│ type │ object data...     │ │
│ │ (i32)   │ ptr  │                    │ │
│ └─────────┴──────┴────────────────────┘ │
│         ▲                               │
│         └── All Astra object pointers   │
│             point here                  │
└─────────────────────────────────────────┘
```

**ARC overhead in WASM:**
- `atomic_inc(ptr)`: WASM `i32.atomic.rmw.cmpxchg` (if shared memory) or plain `i32.load` + `i32.add` + `i32.store` (single-threaded)
- `atomic_dec(ptr)`: WASM `i32.atomic.rmw.cmpxchg` with compare-to-zero check
- Bounds checking on every WASM memory access adds overhead (up to 650% in worst case per research)

**Mitigation strategies:**

1. **Thread-local ARC fast path:** For objects confined to a single fiber, use non-atomic RC (plain `i32.load` + add/sub). Only promote to atomic when the object is shared across fibers.

2. **RC caching:** Batch reference count changes. Instead of inc/dec on every assignment, the compiler can elide redundant RC operations within basic blocks.

3. **ORC cycle collector in WASM:** The trial deletion algorithm (MarkGray → Scan → CollectWhite) runs incrementally. In WASM, this can be implemented as:
   - A separate WASM function called periodically
   - Uses DFS traversal of object graph via WASM call stack
   - No STW pause required (incremental by design)

4. **WASM Memory Control proposal:** The `memory-control` proposal adds `memory.discard`, protection bits, and multiple memories. This could allow:
   - Separate memories for different allocation kinds (ARC-managed vs manual)
   - Memory protection for debugging use-after-free

5. **RC overhead in practice:** Research shows WASM overhead over native is 1.5x–2.5x for compute-bound workloads. ARC adds ~5–15% overhead on top of that for reference-heavy workloads, primarily from cache pollution (refcounts contend with object data in cache lines).

### 1.5 Performance Considerations

| Factor | Impact | Mitigation |
|:-------|:-------|:-----------|
| WASM bounds checking | Up to 650% for memory-intensive workloads | Bulk memory operations, explicit bounds check elision in Binaryen/LLVM |
| ARC reference counting | 5–15% overhead for ref-heavy code | RC elision, batched RC, non-atomic fast path |
| JS↔WASM boundary crossing | 10x–200x depending on data type | Minimize crossings; batch work on WASM side |
| WASM integer division | ~10x slower than native | Use WASM SIMD where available; avoid division in hot loops |
| Function call overhead | ~2x native (indirect calls through table) | Inlining at AIR level before WASM emission |
| Memory growth | `memory.grow` can be expensive | Pre-allocate; use `memory.grow` hint in WASM 2.0 |

**WASM-specific optimizations for Astra:**

1. **ARC elision at AIR level:** Before WASM emission, the AIR optimizer should:
   - Elide RC for objects with provably single-owner lifetime (within one fiber)
   - Fuse consecutive retain/release pairs
   - Move RC increments to dominate position, decrements to post-dominator

2. **Yield point optimization:** WASM's stack-switching proposal (or poll/continuation) should be used instead of setjmp/longjmp. Yield points in AIR should map to:
   ```
   (suspend (ref.func $fiber_yield))
   ```

3. **SIMD vectorization:** WASM SIMD (128-bit) maps well to Astra's scientific computing use cases. The LLVM WASM backend auto-vectorizes loops; Binaryen supports SIMD intrinsics.

4. **Dead code elimination:** WASM modules should be small. Tree shaking from entry points (like AssemblyScript) reduces binary size.

---

## 2. GPU Kernel Generation

### 2.1 Existing Approaches to GPU Compilation from High-Level Languages

#### CUDA C++ (NVIDIA)

The canonical approach to GPU programming:

```
Host code (C++) → nvcc → PTX/SASS → NVIDIA GPU
Device code (CUDA C++)
```

- **Separate compilation:** Host and device code compiled separately, then linked.
- **Execution model:** Grid → Block → Thread hierarchy.
- **Memory hierarchy:** Global, shared, local, registers, constant, texture memory.
- **Limitations:** NVIDIA-only, proprietary, no dynamic allocation in kernels, no exceptions, no virtual functions.

#### HIP (AMD)

AMD's CUDA equivalent, designed for portability:

```
HIP source → hipcc (Clang-based) → AMDGPU ISA / SPIR-V → AMD GPU
```

- **Syntax near-identical to CUDA:** HIP is a strong subset of CUDA in functionality.
- **Cross-platform:** Can target NVIDIA (via HIP-to-CUDA translation) and AMD GPUs.
- **Clang-based:** Uses LLVM's AMDGPU backend for code generation.
- **Compilation modes:** `-fno-gpu-rdc` (default, self-contained per TU) and `-fgpu-rdc` (bitcode for cross-TU calls).

#### SYCL (Khronos Group)

A higher-level, single-source C++ programming model:

```
SYCL source → DPC++/hipSYCL/ComputeCpp → CUDA/HIP/OpenCL/SPIR-V
```

- **No language extensions:** Pure C++17 with standard library parallelism.
- **Single-source:** Host and device code in the same file.
- **Implicit data transfer:** Compiler manages host↔device memory movement.
- **NDRange:** Abstracts GPU execution dimensions (global, local, sub-group).
- **Interoperability:** Can call CUDA/HIP/OpenCL kernels from SYCL code.
- **Performance:** hipSYCL compiling directly to CUDA achieves competitive performance with native CUDA.

**SYCL kernel example:**
```cpp
sycl::queue Q{sycl::gpu_selector{}};
int *A = sycl::malloc_shared<int>(N, Q);
Q.parallel_for(N, [=](sycl::item<1> id) {
    A[id] = id;
}).wait();
```

#### ISPC (Intel SPMD Program Compiler)

- **SPMD model:** Single Program, Multiple Data — each ISPC program instance runs on a different SIMD lane.
- **Targets:** CPU (SSE/AVX/AVX-512) and GPU (via Level Zero).
- **Compiler:** Custom compiler producing LLVM IR.

#### Vulkan Compute Shaders

- **Language:** GLSL or SPIR-V (binary format).
- **Explicit synchronization:** No automatic host↔device transfer.
- **Cross-vendor:** Works on NVIDIA, AMD, Intel, mobile GPUs.
- **SYCL → Vulkan:** The Sylkan project maps SYCL to Vulkan compute shaders, demonstrating feasibility.

### 2.2 Type System for GPU: Workgroups, Shared Memory, Barriers

GPU programming requires explicit management of parallelism and memory. A high-level language targeting GPUs needs a type system that captures these concepts:

#### Execution Hierarchy

| Concept | CUDA | SYCL | OpenCL | Astra (Proposed) |
|:--------|:-----|:-----|:-------|:-----------------|
| Global grid | `gridDim` | `nd_range` | `global_work_size` | `@grid(M, N, P)` |
| Workgroup | `blockDim` | `nd_range` local range | `local_work_size` | `@workgroup(K)` |
| Thread | `threadIdx` | `item` / `id` | `get_global_id()` | implicit (loop variable) |
| Sub-group | warp (32/64) | sub-group | sub-group | `@subgroup(S)` |

#### Memory Hierarchy

| Concept | CUDA | SYCL | Astra (Proposed) |
|:--------|:-----|:-----|:-----------------|
| Global memory | `__device__` buffers | `sycl::device_global` | `@device_mem` |
| Shared memory | `__shared__` | `sycl::local_accessor` | `@shared_mem` |
| Private/local | registers/locals | private variables | automatic (registers) |
| Constant | `__constant__` | `sycl::device_global<T, read>` | `@const_mem` |

#### Synchronization Primitives

| Concept | CUDA | SYCL | Astra (Proposed) |
|:--------|:-----|:-----|:-----------------|
| Workgroup barrier | `__syncthreads()` | `group_barrier(item.get_group())` | `@barrier` |
| Memory fence | `__threadfence()` | `sycl::group_barrier` with memory order | `@mem_fence` |
| Sub-group vote | `__ballot()` | `sycl::reduce_over_group()` | `@vote(mask)` |

### 2.3 Astra's Units of Measure → GPU Dimensions

Astra's dimensional type system provides a natural mapping to GPU execution dimensions:

```
type Meters = f64[1, 0, 0, 0, 0, 0, 0]
type Seconds = f64[0, 0, 1, 0, 0, 0, 0]
type Velocity = f64[1, 0, -1, 0, 0, 0, 0]  # m/s
```

**Proposed mapping:**

```astra
# GPU kernel declaration using dimensional types for thread dimensions
@kernel @grid(256, 1, 1)   # 256 threads in x-dimension
fn vec_add(
    a: @device_mem [f64],
    b: @device_mem [f64],
    out: @device_mem [f64],
    n: Int
) {
    let idx = @thread_id.x  # Dimensionless integer index
    
    # Units of measure verify correctness at compile time
    if idx < n {
        let va: Velocity = a[idx] as Velocity
        let vb: Velocity = b[idx] as Velocity
        out[idx] = (va + vb)  # Type-checked: same dimension
    }
}

# Workgroup-level kernel with shared memory
@kernel @grid(256, 1, 1) @workgroup(32, 1, 1)
fn parallel_reduce(
    data: @device_mem [f64],
    result: @device_mem [f64],
    n: Int
) {
    @shared_mem sum: [f64; 32]  # One slot per sub-group thread
    
    let tid = @thread_id.x
    let lid = @local_id.x
    
    # Each thread loads and accumulates into shared memory
    sum[lid] = if tid < n { data[tid] } else { 0.0 }
    
    @barrier  # Ensure all threads have written to shared memory
    
    # Parallel reduction in shared memory
    var stride = 16  # Half the workgroup size
    while stride > 0 {
        if lid < stride {
            sum[lid] = sum[lid] + sum[lid + stride]
        }
        @barrier
        stride = stride / 2
    }
    
    # Thread 0 writes result
    if lid == 0 {
        result[@group_id.x] = sum[0]
    }
}
```

**Key insight:** Units of measure provide compile-time verification that:
- Thread indices are dimensionless (integers)
- Memory offsets are computed correctly
- Quantities being reduced have compatible dimensions
- Final results have expected units

The dimensional types are erased at code generation time (zero-cost abstraction), so the generated GPU code is pure integer arithmetic.

### 2.4 Astra GPU Compilation Pipeline

```
Astra Source
    │
    ▼
┌─────────────────────────────────────┐
│ 1. Parse + Type Check               │
│    - Units of measure verified      │
│    - GPU attribute validated        │
│    - @kernel, @grid, @workgroup     │
│      @shared_mem, @device_mem       │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│ 2. AIR Generation                   │
│    - GPU intrinsics lowered to AIR  │
│    - @thread_id → intrinsic call    │
│    - @barrier → intrinsic call      │
│    - Type erasure (units removed)   │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│ 3. AIR → GPU Code Generation        │
│    Backend selection:               │
│    - NVIDIA: PTX/SASS via NVPTX     │
│    - AMD: AMDGPU ISA via LLVM       │
│    - Intel: SPIR-V via LLVM         │
│    - Vulkan: GLSL/SPIR-V via mpsc   │
│    - Portable: OpenCL C via Clang   │
└──────────────┬──────────────────────┘
               │
┌──────────────────────────────────────┐
│ 4. Host Code Generation             │
│    - Kernel launch wrappers         │
│    - Memory allocation (cudaMalloc,  │
│      hipMalloc, clCreateBuffer)     │
│    - Data transfer (host ↔ device)  │
│    - ARC for device_mem objects      │
└──────────────────────────────────────┘
```

### 2.5 Concrete Code Generation Strategies

#### NVIDIA (PTX via LLVM NVPTX backend)

```
AIR → LLVM IR (NVPTX target) → PTX → SASS (cuobjdump)
```

- LLVM has a mature NVPTX backend.
- Astra's AIR maps well: loop constructs → GPU loops, intrinsics → PTX instructions.
- Shared memory → `alloca` in PTX address space 3 (shared).

#### AMD (AMDGPU ISA via LLVM)

```
AIR → LLVM IR (AMDGPU target) → AMDGPU ISA
```

- LLVM's AMDGPU backend is mature (used by HIP/ROCm).
- Target specific GFX architectures (gfx906, gfx1030, gfx1100).

#### Vulkan (SPIR-V via glslang/spirv-tools)

```
AIR → GLSL compute shader → glslang → SPIR-V
  or
AIR → SPIR-V (direct via spirv-headers)
```

- More complex mapping: Vulkan's explicit API requires buffer descriptors, pipeline layout, dispatch commands.
- Sylkan project demonstrates SYCL → Vulkan feasibility.

#### Portable (OpenCL C via Clang)

```
AIR → OpenCL C source → Clang → SPIR-V / Binary
```

- OpenCL C is the most portable GPU kernel language.
- Supports CPU, GPU, FPGA, and other accelerators.

### 2.6 Recommended Strategy for Astra

**Phase 1: OpenCL C + SYCL backend** (most portable)
- Generate OpenCL C kernels from AIR
- Use SYCL (via DPC++) for host-side kernel launch
- Support NVIDIA, AMD, Intel GPUs from single source

**Phase 2: Native backends** (performance-critical)
- LLVM NVPTX for NVIDIA (via `--emit=nvidia`)
- LLVM AMDGPU for AMD (via `--emit=amd`)
- SPIR-V for Vulkan compute (via `--emit=vulkan`)

**Type system extensions needed:**
1. `@kernel`, `@grid`, `@workgroup` attributes for kernel declaration
2. `@device_mem`, `@shared_mem`, `@const_mem` memory qualifiers
3. `@thread_id`, `@group_id`, `@local_id` built-in functions
4. `@barrier`, `@mem_fence` synchronization primitives
5. Restriction: no heap allocation, no virtual dispatch, no exceptions inside kernels

---

## 3. REPL and Jupyter Notebook Support

### 3.1 How Existing Languages Implement REPLs

#### Python

Python's REPL is built into the interpreter itself:

- **Implementation:** The `code` module provides `InteractiveInterpreter` and `InteractiveConsole`.
- **Execution:** Code is compiled to Python bytecode (`.pyc`), then executed by the CPython VM.
- **State persistence:** The interpreter maintains a global namespace (`__main__.__dict__`) between inputs.
- **Error handling:** Syntax errors caught at compile time; runtime errors caught by the VM without process termination.
- **Key design:** Python is interpreted, so the REPL is simply a read-eval loop with no JIT compilation overhead.

#### Julia

Julia's REPL is built on LLVM JIT compilation:

- **Implementation:** `Base.REPL` module with `REPL.LineEdit` for UI.
- **Execution:** Source → LLVM IR → JIT machine code (via Julia's custom LLVM pass pipeline).
- **State persistence:** The Main module persists between inputs; precompiled packages accelerate startup.
- **Multi-mode:** Normal mode, package mode (`]`), help mode (`?`), shell mode (`;`).
- **Key insight:** Julia achieves near-native performance in the REPL because it JIT-compiles each input.

#### Swift

Swift's REPL is tightly integrated with LLDB (the debugger):

- **Implementation:** Uses LLDB's expression evaluator, which contains a full Swift compiler.
- **Execution:** Source → Swift AST → SIL (Swift Intermediate Language) → LLVM IR → JIT machine code.
- **State persistence:** Each REPL input is wrapped in an implicit scope; declarations persist in the session.
- **Failure recovery:** Fatal errors can be caught and recovered from (unlike normal Swift where they terminate).
- **Key design:** The REPL is also a full debugger — you can set breakpoints in functions defined in the REPL.
- **Package support:** `swift run --repl` compiles package targets into a dynamic library and loads them into the REPL.

**Swift REPL architecture:**
```
Input → Swift Parser → AST → SILGen → SIL Optimizer → LLVM IR → JIT → Execute
                                                         │
                                                    LLDB integration
                                                    (breakpoints, inspection)
```

#### Kotlin

Kotlin uses the JVM for its REPL:

- **Implementation:** `kotlin-interactive-shell` (ki-shell) and IntelliJ's built-in REPL.
- **Execution:** Source → Kotlin compiler → JVM bytecode → JVM execution.
- **State persistence:** Each line is compiled as a new class; state is maintained via static fields.
- **Dependencies:** Can download Maven dependencies at runtime using coordinates.
- **Scripting:** Kotlin Scripting API allows custom script definitions with typed parameters.

#### Clang-Repl (C++)

Clang-Repl demonstrates REPL for a compiled language:

- **Implementation:** Uses Clang as a library for incremental compilation + LLVM JIT.
- **Execution:** Source → incremental Clang AST → LLVM IR → LLVM ORC JIT → machine code.
- **Key design:** The AST is extended incrementally; each input adds new declarations to the existing AST.
- **Architecture:**
  1. Input → incremental Clang compilation → AST
  2. AST → LLVM IR
  3. LLVM IR → LLVM JIT (ORC v2)
  4. JIT executes specified functions

### 3.2 Jupyter Kernel Protocol

The Jupyter protocol uses ZeroMQ (ZMQ) for communication between kernels and frontends:

#### ZMQ Channels

| Channel | Socket Type | Purpose |
|:--------|:-----------|:--------|
| **Shell** | ROUTER/DEALER | Request/reply: execute, complete, inspect, history |
| **Control** | ROUTER/DEALER | High-priority: shutdown, restart (runs in separate thread) |
| **IOPub** | PUB/XPUB | Broadcast: stdout, stderr, execute_result, display_data, status |
| **Stdin** | ROUTER/DEALER | Kernel → frontend input requests (raw_input equivalent) |
| **Heartbeat** | PUSH/PULL | Keep-alive ping |

#### Wire Protocol

Every message is serialized as:
```
[ident, b'<IDS|MSG>', hmac_signature, header_json, parent_header_json, metadata_json, content_json, ...buffers]
```

**Message types on Shell channel (client → kernel):**

| Message | Purpose | Response |
|:--------|:--------|:---------|
| `execute_request` | Run code | `execute_result` (IOPub) + `execute_reply` |
| `complete_request` | Autocomplete | `complete_reply` |
| `inspect_request` | Hover/docs | `inspect_reply` |
| `history_request` | Command history | `history_reply` |
| `is_complete_request` | Check if code is complete | `is_complete_reply` |
| `kernel_info_request` | Kernel metadata | `kernel_info_reply` |

**Message types on IOPub channel (kernel → all clients):**

| Message | Purpose |
|:--------|:--------|
| `status` | `busy` / `idle` |
| `execute_result` | Execution result (last expression) |
| `display_data` | Rich display (HTML, images, etc.) |
| `stream` | stdout/stderr output |
| `error` | Exception traceback |
| `clear_output` | Clear current output |

**Execution flow:**
1. Client sends `execute_request` on Shell
2. Kernel publishes `status: busy` on IOPub
3. Kernel publishes `stream: stdout` for print output
4. Kernel publishes `execute_result` for expression result
5. Kernel sends `execute_reply` on Shell
6. Kernel publishes `status: idle` on IOPub

#### Kernel Registration

Kernels are registered via `kernel.json`:
```json
{
  "argv": ["astra", "kernel", "--connection-file={connection_file}"],
  "display_name": "Astra",
  "language": "astra",
  "codemirror_mode": "astra"
}
```

### 3.3 Incremental Compilation for REPL

For a compiled language like Astra, the REPL must support incremental compilation. Two approaches:

#### Approach A: LLVM JIT (for production/LLVM backend)

```
┌──────────────────────────────────────────────────┐
│ LLVM JIT REPL Pipeline                           │
│                                                  │
│ Input → Parser → AIR → LLVM IR → LLVM ORC JIT    │
│                                                  │
│ State maintained in:                             │
│ - LLVM Module (growing with each input)          │
│ - JIT execution engine (symbol table persists)   │
│ - Astra runtime (ARC-managed state)              │
└──────────────────────────────────────────────────┘
```

**Implementation details:**
1. Parse input incrementally (add new declarations to existing AST)
2. Generate AIR for new code
3. Link new LLVM IR module with existing JIT state
4. Execute new functions via LLVM ORC JIT
5. Persist declarations in runtime state (ARC-managed)

**Key challenge:** ARC reference counting across REPL inputs. Each input must properly increment/decrement references for objects defined in previous inputs.

#### Approach B: VM Interpreter (for dev/VM backend)

```
┌──────────────────────────────────────────────────┐
│ VM REPL Pipeline                                 │
│                                                  │
│ Input → Parser → AIR → Bytecode → VM execution   │
│                                                  │
│ State maintained in:                             │
│ - VM heap (ARC-managed objects persist)           │
│ - Bytecode module (new bytecode appended)        │
│ - Global frame (symbols from all inputs)         │
└──────────────────────────────────────────────────┘
```

**This is the recommended approach for Astra's REPL:**
- Astra already has a bytecode VM for dev mode
- The VM can execute code incrementally without full recompilation
- Startup time < 10ms (matches Astra's dev mode goal)
- ARC state persists naturally between inputs

#### Approach C: Hybrid (fast startup + good performance)

```
Input 1-N: VM interpreter (fast startup)
     │
     ▼ (when user requests or after threshold)
     │
Hot path: LLVM JIT recompilation of accumulated code
```

This matches Astra's dual-backend philosophy: VM for interactive exploration, LLVM for performance when needed.

### 3.4 State Persistence Between REPL Sessions

For session persistence (save/restore REPL state):

```astra
# Save session
astra repl --save-session my_session.ast

# Restore session
astra repl --load-session my_session.ast
```

**Implementation:**
1. **Serialization format:** Serialize ARC-managed heap objects to disk (JSON or binary format)
2. **Challenge:** Function closures, pointers, and I/O handles cannot be trivially serialized
3. **Solution:** Only serialize pure data; re-execute initialization code on restore
4. **Alternative:** Snapshot the entire VM state (heap + stack + bytecode) — simpler but larger

### 3.5 Astra REPL Implementation Strategy

```astra
# astra repl implementation (pseudocode)

fn start_repl() {
    let session = ReplSession::new()  # ARC-managed state
    let vm = VM::new()  # or JIT::new() for production mode
    
    loop {
        let input = read_input("astra> ")  # or "astra* " for continuation
        
        match parse_incremental(input) {
            Ok(ast) => {
                let air = typecheck_and_lower(ast, &session)
                let bytecode = emit_bytecode(air)
                
                match vm.execute(bytecode, &session) {
                    Ok(value) => {
                        if !value.is_unit() {
                            println!("${session.execution_count} = {value}")
                        }
                        session.add_declaration(ast)
                        session.execution_count += 1
                    }
                    Err(e) => {
                        eprintln!("Error: {e}")
                        session.add_error_context(e)
                    }
                }
            }
            Err(SyntaxError::Incomplete) => {
                // Continue reading (multi-line input)
                continue_read()
            }
            Err(e) => {
                eprintln!("Syntax error: {e}")
            }
        }
    }
}
```

### 3.6 Jupyter Kernel Implementation

```astra
# astra jupyter kernel (pseudocode)

use zmq

fn start_jupyter_kernel(connection_file: String) {
    let config = load_connection_file(connection_file)
    let ctx = zmq::Context::new()
    
    // Create ZMQ sockets
    let shell = ctx.socket(zmq::ROUTER)
    let control = ctx.socket(zmq::ROUTER)
    let iopub = ctx.socket(zmq::PUB)
    let stdin = ctx.socket(zmq::ROUTER)
    let heartbeat = ctx.socket(zmq::PULL)
    
    // Bind sockets
    shell.bind(&config.shell_port)
    control.bind(&config.control_port)
    iopub.bind(&config.iopub_port)
    stdin.bind(&config.stdin_port)
    heartbeat.bind(&config.hb_port)
    
    let vm = VM::new()
    let session_state = ARCState::new()
    
    // Message loop
    loop {
        let msg = shell.recv_message()
        
        match msg.msg_type {
            "execute_request" => {
                send_status(iopub, "busy")
                
                let code = msg.content.code
                match execute_code(&vm, &session_state, code) {
                    Ok(result) => {
                        send_execute_result(iopub, result)
                    }
                    Err(e) => {
                        send_error(iopub, e)
                    }
                }
                
                send_execute_reply(shell, msg, result)
                send_status(iopub, "idle")
            }
            "complete_request" => {
                let completions = autocomplete(&session_state, msg.content)
                send_complete_reply(shell, msg, completions)
            }
            "inspect_request" => {
                let info = hover_info(&session_state, msg.content)
                send_inspect_reply(shell, msg, info)
            }
            "kernel_info_request" => {
                send_kernel_info_reply(shell, msg)
            }
            "shutdown_request" => {
                send_shutdown_reply(shell, msg)
                break
            }
            _ => {}
        }
    }
}
```

### 3.7 Comparison: REPL Approaches

| Approach | Startup Time | Performance | State Persistence | Complexity |
|:---------|:-------------|:------------|:------------------|:-----------|
| Pure interpreter | < 1ms | Low (10-100x) | Natural | Low |
| Bytecode VM | < 10ms | Medium (2-5x) | Natural (Astra's dev mode) | Medium |
| LLVM JIT | 50-200ms | High (near-native) | Requires serialization | High |
| Hybrid VM + JIT | < 10ms (VM) → JIT when hot | High | Medium | High |

**Recommendation:** Use Astra's existing bytecode VM for the REPL (fast startup, natural state persistence), with optional LLVM JIT recompilation for hot code paths.

---

## 4. LSP (Language Server Protocol) Integration

### 4.1 How Existing LSPs Are Implemented

#### rust-analyzer

The reference implementation for a modern, incremental LSP:

**Architecture (from official docs):**
```
┌─────────────────────────────────────────────────┐
│  crates/ide                                     │  IDE features (completion, hover, goto)
│     │                                           │
│  crates/hir                                     │  High-level IR (type-checked representation)
│     │                                           │
│  crates/hir-ty                                 │  Type inference and checking
│     │                                           │
│  crates/base-db + salsa                         │  Incremental computation framework
│     │                                           │
│  crates/syntax (rowan)                          │  Concrete syntax tree (CST)
│     │                                           │
│  crates/parser                                  │  Hand-written recursive descent parser
└─────────────────────────────────────────────────┘
```

**Key design principles:**

1. **Parsing never fails:** The parser produces `(T, Vec<Error>)` rather than `Result<T, Error>`. This means partial results are always available even with syntax errors.

2. **Incremental computation via salsa:** The `salsa` crate provides a key-value store with automatic invalidation. Core invariant: "typing inside a function's body never invalidates global derived data."

3. **Cancellation support:** When a new edit arrives, in-flight computations are cancelled via `Canceled::throw`. Each LSP request is protected by `catch_unwind`.

4. **Error handling:** Core parts (ide/hir) don't interact with the outside world and can't fail. Only LSP-facing code does IO. Internals deal with broken code as normal, not error conditions.

5. **Syntax tree design (rowan):** Trees are intentionally incomplete and don't enforce well-formedness. AST methods return `Option` which can be `None` at runtime even if the grammar forbids it.

#### gopls (Go Language Server)

**Architecture (from official docs):**

```
┌──────────────────────────────────────────────────┐
│  protocol          │ LSP wire format types        │
│  command           │ Non-standard commands         │
├───────────────────┼──────────────────────────────┤
│  parsego           │ Parsed Go source (File type) │
│  cache             │ Memoized computations         │
│  methodsets        │ Incremental method-set index  │
├───────────────────┼──────────────────────────────┤
│  golang            │ Go-specific features          │
│  mod               │ go.mod handling               │
│  work              │ go.work handling              │
│  template          │ text/template handling        │
├───────────────────┼──────────────────────────────┤
│  server            │ LSP handler dispatch          │
│  lsprpc            │ JSON-RPC2 transport           │
└──────────────────────────────────────────────────┘
```

**Key design principles:**

1. **File-based architecture:** Each source file has a `File` type wrapping `go/ast.File` with content, syntax tree, and coordinate mappings.

2. **Cache layer:** The largest component. Manages `Snapshot` (immutable state), `Package` (type-checked package), and memoized computations.

3. **Language dispatch:** The server switches on file type and dispatches to language-specific packages (golang, mod, work, template).

4. **Incremental invalidation:** Only modified files trigger re-type-checking; dependencies are minimally re-checked.

5. **Error recovery:** `parsego` performs tree repair to work around parser error-recovery shortcomings.

#### ZLS (Zig Language Server)

- Uses Zig's self-hosted parser for incremental parsing.
- The parser produces a full AST even with errors.
- Direct integration with Zig's compiler infrastructure.

### 4.2 Key LSP Features Implementation

#### Autocompletion

| Approach | Latency | Accuracy | Implementation |
|:---------|:--------|:---------|:---------------|
| Prefix matching | < 5ms | Low | Filter symbols by prefix |
| Semantic completion | 10-50ms | High | Type-check partial expression |
| Snippet-based | < 5ms | Medium | Template expansion |

**For Astra:**
```rust
fn completion(document: &Document, position: Position) -> CompletionList {
    let prefix = document.prefix_at(position);
    
    // Fast path: symbol prefix matching
    let symbols = document.scope_symbols(prefix);
    
    // Slow path: semantic completion (type-based)
    let partial_expr = document.parse_partial(position);
    let inferred = type_engine.infer_partial(partial_expr);
    
    CompletionList {
        items: symbols.chain(inferred).collect(),
        is_incomplete: false,
    }
}
```

#### Hover Information

```rust
fn hover(document: &Document, position: Position) -> HoverContents {
    let token = document.token_at(position);
    
    match token.kind {
        TokenKind::Identifier(name) => {
            let def = resolve_definition(document, name);
            let ty = type_of(def);
            let docs = documentation_of(def);
            
            HoverContents {
                markup: format!("```astra\n{ty}\n```\n\n{docs}"),
                range: token.range,
            }
        }
        _ => HoverContents::empty(),
    }
}
```

#### Go-to-Definition

```rust
fn goto_definition(document: &Document, position: Position) -> Vec<Location> {
    let token = document.token_at(position);
    let def = resolve_definition(document, token);
    
    vec![Location {
        uri: def.source_file,
        range: def.name_range,
    }]
}
```

#### Diagnostics

```rust
fn diagnostics(document: &Document) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();
    
    // Parse diagnostics (syntax errors with recovery)
    diagnostics.extend(document.parse_errors());
    
    // Type diagnostics
    diagnostics.extend(type_checker.check(document));
    
    // Lint diagnostics
    diagnostics.extend(linter.run(document));
    
    diagnostics
}
```

### 4.3 Incremental Parsing for Responsive LSP

For an LSP to be responsive (< 100ms for most operations), it must avoid re-parsing entire files on every keystroke.

#### Strategy 1: Tree-sitter style incremental parsing

- Uses a GLR parser that can reuse unchanged portions of the parse tree.
- Only re-parses regions affected by edits.
- Produces a concrete syntax tree (CST) with error nodes for incomplete input.

#### Strategy 2: Hand-written incremental parser (rust-analyzer approach)

- Recursive descent parser that emits events (start node, finish node, token).
- Parser is independent of tree structure (can produce different tree types).
- Error recovery is built-in: parser always produces output, never fails.
- The parser can handle partial input (e.g., incomplete expressions).

**For Astra (recommended approach):**

```rust
// Astra parser design (inspired by rust-analyzer)
// 
// Architecture invariants:
// 1. Parser never fails - produces (CST, Vec<SyntaxError>)
// 2. Parser is independent of tree representation
// 3. Parsing is incremental - only re-parse changed regions
// 4. Error recovery allows partial results

struct Parser {
    tokens: TokenStream,
    position: usize,
    events: Vec<ParseEvent>,  // start_node, token, finish_node, error
}

enum ParseEvent {
    Start { kind: NodeKind },
    Token { kind: TokenKind, text: TextRange },
    Finish,
    Error { message: String, range: TextRange },
}

impl Parser {
    // Entry point - never returns Result, always produces output
    fn parse(&mut self) -> (CST, Vec<SyntaxError>) {
        let mut errors = Vec::new();
        self.parse_file(&mut errors);
        (self.build_cst(), errors)
    }
    
    // Error recovery: insert missing tokens, skip unexpected tokens
    fn parse_function_def(&mut self, errors: &mut Vec<SyntaxError>) {
        self.expect(TokenKind::Fn, errors);
        let name = self.parse_identifier(errors);
        self.expect(TokenKind::LParen, errors);
        // ... parameters ...
        self.expect(TokenKind::RParen, errors);
        
        // Optional return type
        if self.at(TokenKind::Arrow) {
            self.bump();
            self.parse_type(errors);
        }
        
        // Body - even if opening brace is missing, try to parse body
        if self.at(TokenKind::LBrace) {
            self.parse_block(errors);
        } else {
            errors.push(SyntaxError::missing_lbrace(self.current_range()));
            // Try to parse body anyway (it might be there)
            self.parse_block(errors);
        }
    }
}
```

#### Incremental Re-parsing Strategy

```
Edit: position 42, delete 5 chars, insert "hello"

1. Find the smallest enclosing syntax node containing position 42
2. If the edit is within a token, re-lex that token
3. Re-parse from the start of the enclosing node
4. If the new parse produces the same tree structure for unchanged portions,
   splice the new subtree into the existing CST
5. Update dependent computations (type checking, name resolution)
```

### 4.4 Handling Dual Backend (VM vs LLVM) in LSP

Astra's dual backend presents a unique challenge for the LSP. The LSP must provide IDE features regardless of which backend is active.

#### Architecture

```
┌─────────────────────────────────────────────────────┐
│  LSP Server                                         │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  Shared Analysis Layer                       │   │
│  │  - Parser (incremental)                      │   │
│  │  - Type Checker                              │   │
│  │  - Name Resolution                           │   │
│  │  - Semantic Analysis                         │   │
│  └──────────────────────────────────────────────┘   │
│         │                                           │
│  ┌──────┴──────┐                                    │
│  │             │                                    │
│  ▼             ▼                                    │
│  VM Backend   LLVM Backend                          │
│  (dev mode)   (production mode)                     │
│                                                     │
│  Shared diagnostics, completions, hover, etc.       │
│  Backend-specific: code generation diagnostics,     │
│  optimization suggestions, build configuration      │
└─────────────────────────────────────────────────────┘
```

**Key insight:** Most LSP features (completion, hover, goto-definition, diagnostics) are backend-independent. They rely on:
- Syntax (parser output)
- Type information (type checker output)
- Name resolution (symbol table)

These are computed before backend selection. The dual backend only affects:
- Code generation diagnostics (backend-specific errors)
- Build configuration suggestions
- Performance profiling data

#### Backend-Aware Diagnostics

```rust
fn backend_specific_diagnostics(document: &Document, backend: Backend) -> Vec<Diagnostic> {
    match backend {
        Backend::VM => {
            // VM-specific warnings
            let mut diags = Vec::new();
            if document.uses_unsupported_vm_features() {
                diags.push(Diagnostic {
                    severity: Warning,
                    message: "This feature requires --release (LLVM backend)",
                    ..Default::default()
                });
            }
            diags
        }
        Backend::LLVM => {
            // LLVM-specific warnings
            let mut diags = Vec::new();
            if document.has_large_monomorphizations() {
                diags.push(Diagnostic {
                    severity: Info,
                    message: "Consider using trait objects to reduce binary size",
                    ..Default::default()
                });
            }
            diags
        }
    }
}
```

### 4.5 Error Recovery in Parser for Partial Results

Error recovery is critical for LSP responsiveness. The parser must produce useful output even with incomplete or malformed input.

#### Strategies

1. **Panic mode recovery:** On error, skip tokens until a synchronization point (statement boundary, closing brace).

2. **Insertion recovery:** Insert missing tokens (e.g., missing semicolon, missing closing brace).

3. **Deletion recovery:** Skip unexpected tokens.

4. **Transformation recovery:** Replace incorrect constructs with error nodes.

5. **Partial parsing:** Parse what can be parsed, return error nodes for the rest.

#### Astra Error Recovery Rules

```rust
// Error recovery examples for Astra parser

// 1. Missing semicolon
// fn foo() { x = 1 }  →  fn foo() { x = 1; }  (insert semicolon)

// 2. Unclosed brace
// fn foo() { x = 1  →  fn foo() { x = 1; }  (insert semicolon + closing brace)

// 3. Missing function body
// fn foo() -> Int  →  fn foo() -> Int { }  (insert empty body)

// 4. Incomplete expression
// let x = 1 +  →  let x = 1 + <error>  (partial expression with error node)

// 5. Wrong indentation (Astra uses significant whitespace?)
// Handle by inserting missing dedent tokens

// 6. Partial type annotation
// fn foo(x: Int ->  →  fn foo(x: Int) -> <error>  (partial type)
```

#### Error Recovery Implementation

```rust
impl Parser {
    fn parse_with_recovery(&mut self) -> (CST, Vec<SyntaxError>) {
        let mut errors = Vec::new();
        
        while !self.is_at_end() {
            match self.try_parse_statement() {
                Ok(stmt) => self.emit(stmt),
                Err(recovery) => {
                    // Record error
                    errors.push(recovery.error);
                    
                    // Skip to next synchronization point
                    self.skip_to_sync_point(recovery.sync_strategy);
                }
            }
        }
        
        (self.build_cst(), errors)
    }
    
    fn skip_to_sync_point(&mut self, strategy: SyncStrategy) {
        match strategy {
            SyncStrategy::NextStatement => {
                // Skip until we see a statement-starting token
                while !self.is_at_statement_start() && !self.is_at_end() {
                    self.bump();
                }
            }
            SyncStrategy::NextClosingBrace => {
                // Skip until we see a closing brace
                let mut depth = 0;
                while !self.is_at_end() {
                    if self.at(TokenKind::LBrace) { depth += 1; }
                    if self.at(TokenKind::RBrace) {
                        if depth == 0 { break; }
                        depth -= 1;
                    }
                    self.bump();
                }
            }
            SyncStrategy::EndOfLine => {
                // Skip until end of line
                while !self.at(TokenKind::Newline) && !self.is_at_end() {
                    self.bump();
                }
            }
        }
    }
}
```

### 4.6 LSP Implementation Architecture for Astra

```
┌─────────────────────────────────────────────────────────────┐
│  astra-lsp (binary)                                        │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  LSP Transport Layer (stdin/stdout JSON-RPC)         │  │
│  │  - Message parsing/serialization                      │  │
│  │  - Request/response routing                           │  │
│  └───────────────────────┬───────────────────────────────┘  │
│                          │                                  │
│  ┌───────────────────────▼───────────────────────────────┐  │
│  │  Request Handlers                                     │  │
│  │  - textDocument/completion                            │  │
│  │  - textDocument/hover                                 │  │
│  │  - textDocument/definition                            │  │
│  │  - textDocument/diagnostic                            │  │
│  │  - textDocument/formatting                            │  │
│  │  - textDocument/rename                                │  │
│  │  - workspace/symbol                                   │  │
│  │  - textDocument/codeAction                            │  │
│  └───────────────────────┬───────────────────────────────┘  │
│                          │                                  │
│  ┌───────────────────────▼───────────────────────────────┐  │
│  │  Analysis Core                                       │  │
│  │  - Incremental parser (CST)                           │  │
│  │  - Semantic analysis (AST)                            │  │
│  │  - Type inference (HIR)                               │  │
│  │  - Name resolution                                    │  │
│  │  - Incremental computation (salsa-like)               │  │
│  └───────────────────────┬───────────────────────────────┘  │
│                          │                                  │
│  ┌───────────────────────▼───────────────────────────────┐  │
│  │  Document Store                                      │  │
│  │  - Open file management                               │  │
│  │  - Incremental re-parse on edit                       │  │
│  │  - Dependency graph                                   │  │
│  │  - Virtual file system (for generated code)           │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4.7 Recommended LSP Stack for Astra

| Component | Technology | Rationale |
|:----------|:-----------|:----------|
| LSP transport | `lsp-server` crate (from rust-analyzer) | Proven, minimal, cross-platform |
| Parser | Hand-written recursive descent with error recovery | Incremental, always produces output |
| Syntax tree | `rowan` (CST library) | Incremental, used by rust-analyzer |
| Incremental computation | `salsa` or custom query system | Automatic invalidation, memoization |
| Type inference | Hindley-Milner (as in Astra spec) | Well-understood, efficient |
| Diagnostics | Real-time (on every keystroke for small files, debounced for large) | Responsive UX |

### 4.8 Performance Targets

| Operation | Target Latency | Strategy |
|:----------|:---------------|:---------|
| Autocompletion | < 50ms | Prefix matching fast path; semantic completion on demand |
| Hover | < 20ms | Type information cached per position |
| Go-to-definition | < 10ms | Name resolution cached, indexed |
| Diagnostics | < 100ms (small files), < 500ms (large) | Incremental re-type-check only changed regions |
| Formatting | < 200ms | Incremental formatting (only changed lines) |
| Rename | < 500ms | Workspace-wide index, parallel application |

---

## Summary: Recommended Implementation Order

### Phase 1: Foundation (Months 1-3)
1. **LSP core:** Incremental parser + type checker + basic diagnostics
2. **REPL:** VM-based REPL with state persistence
3. **WASM backend:** Binaryen-based code generation (dev mode)

### Phase 2: Integration (Months 4-6)
1. **LSP features:** Completion, hover, goto-definition, rename
2. **Jupyter kernel:** ZMQ-based kernel with execute/complete/inspect
3. **WASM production:** LLVM WASM backend for optimized output
4. **WASI support:** wasi:cli/world integration for WASM components

### Phase 3: GPU & Advanced (Months 7-12)
1. **GPU type system:** @kernel, @grid, @workgroup, @device_mem
2. **GPU code generation:** OpenCL C backend (portable first)
3. **GPU native backends:** LLVM NVPTX (NVIDIA), LLVM AMDGPU (AMD)
4. **LSP advanced:** Code actions, refactorings, inlay hints
5. **REPL advanced:** LLVM JIT mode, package loading, debugging

---

*Report generated from research on existing compiler architectures (Rust, Zig, AssemblyScript, Grain, Swift, Julia, Kotlin, Go), WASM specifications (Component Model, WASI 0.2/0.3), GPU programming models (CUDA, HIP, SYCL, Vulkan), Jupyter protocol, and LSP implementations (rust-analyzer, gopls).*
