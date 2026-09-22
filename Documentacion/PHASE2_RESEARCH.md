# Phase 2 Research: Zig-Based Self-Hosting Compiler for Astra

> **Status**: Research Synthesis  
> **Date**: 2026-09-21  
> **Purpose**: Everything needed to design and implement the Astra Phase 2 compiler in Zig with LLVM backend.

---

## Table of Contents

1. [Zig Compiler Architecture Patterns](#1-zig-compiler-architecture-patterns)
2. [LLVM Integration in Zig](#2-llvm-integration-in-zig)
3. [Type Inference Algorithms](#3-type-inference-algorithms)
4. [Monomorphization Strategies](#4-monomorphization-strategies)
5. [ARC/ORC Implementation Patterns](#5-arcorc-implementation-patterns)
6. [Self-Hosting Bootstrap Strategies](#6-self-hosting-bootstrap-strategies)
7. [Lessons from Other Compiler Projects](#7-lessons-from-other-compiler-projects)
8. [Recommended Libraries and Tools](#8-recommended-libraries-and-tools)
9. [Astra-Specific Design Decisions](#9-astra-specific-design-decisions)

---

## 1. Zig Compiler Architecture Patterns

### 1.1 Multi-Stage IR Pipeline

The Zig compiler uses a progressive lowering pipeline with distinct IRs, each optimized for different concerns:

```
Source -> Tokens -> AST -> ZIR -> AIR -> Machine Code
         (Lexer)  (Parser) (AstGen) (Sema)  (CodeGen)
```

**Key IR stages:**

| IR | Purpose | Scope | Type System |
|:---|:--------|:------|:------------|
| **AST** | Source structure, syntax errors | Per-file | Untyped |
| **ZIR** | Untyped instruction-based IR | Per-file | Untyped |
| **AIR** | Typed, analyzed IR | Per-function | Fully typed |
| **MIR** | Machine-specific IR | Per-function | Target-typed |

**Why this matters for Astra:** Each IR serves a specific purpose. ZIR enables file-level caching (unchanged files skip re-analysis). AIR enables function-level analysis and optimization. This separation is critical for incremental compilation.

### 1.2 Data-Oriented Design with InternPool

The Zig compiler's most distinctive architectural choice is the **InternPool** -- a universal store for all types and values, both represented as `u32` indices.

```zig
// Core insight: types AND values are the same thing
const InternPool = struct {
    const Index = enum(u32) { ... };
    
    // Type checking is O(1): just compare indices
    fn eql(a: Index, b: Index) bool {
        return @intFromEnum(a) == @intFromEnum(b);
    }
};
```

**Type and Value are thin wrappers around `InternPool.Index`:**

```zig
pub const Type = struct {
    ip_index: InternPool.Index,
    pub fn zigTypeTag(self: Type, zcu: *const Zcu) std.builtin.TypeId { ... }
    pub fn abiSize(self: Type, zcu: *const Zcu) u64 { ... }
};

pub const Value = struct {
    ip_index: InternPool.Index,
    pub fn typeOf(self: Value, zcu: *const Zcu) Type { ... }
};
```

**The InternPool is sharded for concurrent access:**

```zig
const InternPool = struct {
    locals: []Local,   // one per thread, indexed by tid
    shards: []Shard,   // power-of-two count for concurrent writers
    // Thread IDs embedded in top bits of indices for global uniqueness
};
```

### 1.3 Flat Data Structures (No Pointer Trees)

Zig's AST, ZIR, and AIR all use **integer indices** instead of pointers, stored in flat arrays:

```zig
const Node = struct {
    tag: Tag,       // What kind of node
    lhs: u32,       // Left child index (or data)
    rhs: u32,       // Right child index (or data)
};

// Extra data for nodes with >2 children
extra: []u32,       // Variable-length payloads
```

**Why this matters:**
- **Cache locality**: Nodes are contiguous in memory
- **Trivial serialization**: Just write the arrays to disk
- **Easy garbage collection**: No pointer chasing, arena works perfectly
- **37% less memory** than naive struct-of-structs approach

### 1.4 Structure-of-Arrays (MultiArrayList)

Zig uses `MultiArrayList` for hot data structures:

```zig
// Instead of ArrayList(Node) (cache-unfriendly):
const NodeList = MultiArrayList(Node);  // cache-friendly
// Equivalent to:
// tags: []Tag
// lhs: []u32
// rhs: []u32
```

### 1.5 Recommended Architecture for Astra Phase 2

```
+-----------------------------------------------------+
|               Astra Phase 2 Pipeline                 |
+-----------------------------------------------------+
|                                                      |
|  Source --> Lexer --> Parser --> AST                  |
|             (tokens)   (tree)    (flat nodes)        |
|                                                      |
|  AST --> AstGen --> AstraIR (untyped)                |
|                    (instruction-based, per-file)     |
|                                                      |
|  AstraIR --> Sema --> TypedIR (typed)                |
|                       (per-function, fully typed)    |
|                                                      |
|  TypedIR --> Monomorphizer --> MonoIR                 |
|              (generic instantiation)                 |
|                                                      |
|  MonoIR --> ARCInserter --> ARCIR                    |
|            (reference counting)                      |
|                                                      |
|  ARCIR --> LLVM Backend --> Object File               |
|                              (via zig_llvm.cpp)      |
|                                                      |
|  Object File --> LLD --> Executable                   |
|                                                      |
+-----------------------------------------------------+
```

**Key design principles to adopt from Zig:**
1. Use `u32` indices everywhere instead of pointers
2. Store all nodes in flat `MultiArrayList` structures
3. Use an InternPool for all types and values
4. Use arena allocators for each compilation phase
5. Cache at file level (AstraIR) and function level (TypedIR)

---

## 2. LLVM Integration in Zig

### 2.1 The C++ Wrapper Pattern

Zig isolates all C++ LLVM interaction in a single file: `zig_llvm.cpp`. This prevents C++ from infecting the rest of the codebase.

```
src/
  zig_llvm.h          # C interface header
  zig_llvm.cpp        # C++ implementation (wraps LLVM C++ API)
  codegen/
    llvm.zig          # Main LLVM backend (pure Zig)
    llvm/
      bindings.zig    # Zig extern declarations for C API
```

**Key pattern -- Zig side (bindings.zig):**

```zig
pub const Context = opaque {
    pub const create = LLVMContextCreate;
    extern fn LLVMContextCreate() *Context;
    pub const dispose = LLVMContextDispose;
    extern fn LLVMContextDispose(C: *Context) void;
};

pub const Module = opaque {
    pub const dispose = LLVMDisposeModule;
    extern fn LLVMDisposeModule(*Module) void;
};

pub const TargetMachine = opaque {
    pub const create = ZigLLVMCreateTargetMachine;
    extern fn ZigLLVMCreateTargetMachine(
        T: *Target, Triple: [*:0]const u8,
        CPU: ?[*:0]const u8, Features: ?[*:0]const u8,
        Level: CodeGenOptLevel, Reloc: RelocMode,
        CodeModel: CodeModel, function_sections: bool,
        data_sections: bool, float_abi: FloatABI,
        abi_name: ?[*:0]const u8, emulated_tls: bool,
    ) *TargetMachine;

    pub const emitToFile = ZigLLVMTargetMachineEmitToFile;
    extern fn ZigLLVMTargetMachineEmitToFile(
        T: *TargetMachine, M: *Module,
        ErrorMessage: *[*:0]const u8,
        options: *const EmitOptions,
    ) bool;
};
```

### 2.2 Key LLVM C++ Wrapper Functions

| Function | Purpose | Wraps |
|:---------|:--------|:------|
| `ZigLLVMCreateTargetMachine` | Create target machine with full options | `Target::createTargetMachine()` |
| `ZigLLVMTargetMachineEmitToFile` | Run optimization pipeline + emit | `PassBuilder`, `ModulePassManager` |
| `ZigLLDLinkCOFF/ELF/Wasm` | Link object files | LLD C++ API |
| `ZigLLVMWriteArchive` | Create .a archives | `archiveutil` |
| `ZigLLVMSetOptBisectLimit` | Debug optimization passes | `OptBisectLimit` |

### 2.3 Optimization Pipeline Configuration

```cpp
// From zig_llvm.cpp - the optimization pipeline
ModulePassManager module_pm;
OptimizationLevel opt_level;

if (options->is_debug)
    opt_level = OptimizationLevel::O0;
else if (options->is_small)
    opt_level = OptimizationLevel::Oz;
else
    opt_level = OptimizationLevel::O3;

// Build pipeline based on level
if (opt_level == OptimizationLevel::O0) {
    module_pm = pass_builder.buildO0DefaultPipeline(opt_level, lto);
} else if (options->lto) {
    module_pm = pass_builder.buildLTOPreLinkDefaultPipeline(opt_level);
} else {
    module_pm = pass_builder.buildPerModuleDefaultPipeline(opt_level);
}

// Run optimization
module_pm.run(llvm_module, module_am);

// Code generation (legacy PM)
legacy::PassManager codegen_pm;
codegen_pm.add(createTargetTransformInfoWrapperPass(
    target_machine.getTargetIRAnalysis()));
target_machine.addPassesToEmitFile(codegen_pm, dest, nullptr, ObjectType);
codegen_pm.run(llvm_module);
```

### 2.4 AIR to LLVM IR Translation

Each AIR instruction maps to one or more LLVM IR instructions:

```zig
fn airAdd(self: *Object, inst: Air.Inst.Index) ?Builder.Value {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const lhs = self.resolveInst(bin_op.lhs);
    const rhs = self.resolveInst(bin_op.rhs);
    return self.builder.buildAdd(lhs, rhs, "");
}
```

### 2.5 Type Lowering with Caching

```zig
const TypeMap = std.AutoHashMapUnmanaged(InternPool.Index, Builder.Type);

fn getLLVMType(self: *Object, ty: Type) Builder.Type {
    const ip_index = ty.toIntern();
    if (self.type_map.get(ip_index)) |llvm_type| {
        return llvm_type;  // Cache hit
    }
    // Compute and cache
    const llvm_type = self.lowerTypeImpl(ty);
    self.type_map.put(self.gpa, ip_index, llvm_type) catch unreachable;
    return llvm_type;
}
```

### 2.6 Target Triple Generation

```zig
fn targetTriple(arena: Allocator, target: std.Target) ![:0]u8 {
    var llvm_triple = std.ArrayList(u8).init(arena);
    
    const llvm_arch = switch (target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        // ... more architectures
    };
    
    const llvm_os = switch (target.os.tag) {
        .linux => "linux",
        .macos => "macosx",
        .windows => "windows",
        // ... more OSes
    };
    
    // Format: arch-subArch-vendor-os-abi
    try llvm_triple.appendSlice(llvm_arch);
    try llvm_triple.append('-');
    // ... etc
    
    return llvm_triple.toOwnedSlice();
}
```

### 2.7 Recommended Astra LLVM Integration Structure

```
src/
  astra_llvm.h            # C interface for Astra-specific LLVM ops
  astra_llvm.cpp          # C++ wrapper (ARC intrinsics, etc.)
  codegen/
    llvm_backend.zig      # Main LLVM backend
    llvm_backend/
      bindings.zig        # LLVM C API bindings
      target.zig          # Target triple/data layout generation
      types.zig           # Astra type -> LLVM type lowering
      codegen.zig         # TypedIR -> LLVM IR translation
      debug_info.zig      # DWARF debug info generation
```


---

## 3. Type Inference Algorithms

### 3.1 Hindley-Milner (Algorithm W)

Algorithm W is the classic type inference algorithm for polymorphic lambda calculus. It provides principal types through constraint generation and unification.

**Core operations:**

1. **Fresh variable generation**: Each unknown type gets a unique variable
2. **Constraint generation**: Walk the AST, collecting type equalities
3. **Unification**: Solve constraints by finding substitutions
4. **Generalization**: At `let` bindings, quantify over free type variables

**Key data structures:**

```zig
const TypeVar = u32;  // Fresh counter-based naming

const Type = union(enum) {
    var: TypeVar,           // Unknown type
    bool,                   // Primitive
    int,                    // Primitive  
    f64,                    // Primitive
    string,                 // Primitive
    fun: struct {           // Function type
        param: *const Type,
        ret: *const Type,
    },
    tuple: []const Type,    // Tuple type
    adt: AdtIndex,          // User-defined type
};

const TypeScheme = struct {
    forall: []const TypeVar,  // Quantified variables
    body: Type,              // Type body
};

const Subst = struct {
    map: std.AutoHashMap(TypeVar, Type),
    
    fn apply(self: Subst, ty: Type) Type { ... }
    fn compose(self: Subst, other: Subst) Subst { ... }
};
```

**Unification algorithm:**

```zig
fn unify(t1: Type, t2: Type) !Subst {
    return switch (t1) {
        .var => |v| bindVar(v, t2),
        .bool, .int, .f64, .string => {
            if (std.meta.eql(t1, t2)) return Subst.empty();
            return error.TypeMismatch;
        },
        .fun => |f1| {
            const t2_fun = try expectFun(t2);
            const s1 = try unify(f1.param, t2_fun.param);
            const s2 = try unify(
                s1.apply(f1.ret),
                s1.apply(t2_fun.ret)
            );
            return s2.compose(s1);
        },
        // ... other cases
    };
}

fn bindVar(v: TypeVar, ty: Type) !Subst {
    if (ty == .var and ty.var == v) return Subst.empty();
    if (occursCheck(v, ty)) return error.InfiniteType;
    return Subst.singleton(v, ty);
}
```

### 3.2 Algorithm J (Bidirectional)

Algorithm J is a variant that works bidirectionally, checking types against expected contexts. More suitable for languages with type annotations.

**Two modes:**
- **Infer mode**: Synthesize a type from context
- **Check mode**: Verify a type against expected

```zig
fn infer(env: Env, expr: Expr) !Type {
    return switch (expr) {
        .int_lit => .int,
        .bool_lit => .bool,
        .var => |name| env.lookup(name),
        .lam => |lam| {
            const param_ty = try freshTypeVar();
            const body_ty = try infer(
                env.extend(lam.param, param_ty),
                lam.body
            );
            return Type.fun(param_ty, body_ty);
        },
        .app => |app| {
            const callee_ty = try infer(env, app.callee);
            const arg_ty = try infer(env, app.arg);
            const result_ty = try freshTypeVar();
            const expected = Type.fun(arg_ty, result_ty);
            try unify(callee_ty, expected);
            return result_ty;
        },
        // ...
    };
}

fn check(env: Env, expr: Expr, expected: Type) !void {
    // Use check when we know the expected type
    // Falls back to infer + unify
    const actual = try infer(env, expr);
    try unify(actual, expected);
}
```

### 3.3 Constraint-Based Inference

Modern languages often use constraint-based inference, which separates constraint generation from solving:

```zig
const Constraint = union(enum) {
    equal: struct { lhs: Type, rhs: Type },
    instance: struct { var: TypeVar, scheme: TypeScheme },
    // ...
};

fn generateConstraints(env: Env, expr: Expr) !struct { Type, []Constraint } {
    return switch (expr) {
        .add => |add| {
            const (lhs_ty, c1) = try generateConstraints(env, add.lhs);
            const (rhs_ty, c2) = try generateConstraints(env, add.rhs);
            return .{ .int, c1 ++ c2 ++ .{
                Constraint{ .equal = .{ .lhs = lhs_ty, .rhs = .int } },
                Constraint{ .equal = .{ .lhs = rhs_ty, .rhs = .int } },
            }};
        },
        // ...
    };
}

fn solve(constraints: []Constraint) !Subst {
    var subst = Subst.empty();
    for (constraints) |c| {
        const s = try unify(c.equal.lhs, c.equal.rhs);
        subst = s.compose(subst);
    }
    return subst;
}
```

### 3.4 Type Inference for Astra's Type System

Astra needs inference for:
- **Structural types**: Structs, arrays, tuples
- **Nominal types**: Enums, classes (future)
- **Function types**: With type annotations optional
- **Generic types**: With constraints (traits)
- **Option/Result**: Tagged unions with pattern matching

**Recommended approach**: Start with Algorithm W, extend with:

1. **Row polymorphism** for structs (structural typing)
2. **Trait constraints** via Haskell-style type classes
3. **Subtyping** via bounded quantification
4. **Unification with defaults** (int/float literals default to i64/f64)

```zig
// Astra-specific type representation
const AstraType = union(enum) {
    type_var: TypeVar,
    bool, int, f64, string, void, never,
    array: *const AstraType,
    optional: *const AstraType,
    result: struct { ok: *const AstraType, err: *const AstraType },
    function: struct {
        params: []const AstraType,
        ret: *const AstraType,
        closure: []const TypeVar,  // Captured type vars
    },
    tuple: []const AstraType,
    adt: struct {
        def: AdtDefIndex,
        args: []const AstraType,  // Generic arguments
    },
    trait_ref: TraitIndex,  // Reference to a trait
};
```

---

## 4. Monomorphization Strategies

### 4.1 Lazy vs Eager Collection

**Lazy strategy** (used by Rust in debug mode):
- Items only instantiated when actually used
- Produces minimum machine code
- Longer individual function compile times
- Smaller binaries

**Eager strategy** (used by Rust in release/incremental mode):
- All reachable instantiations created upfront
- Better parallelism during compilation
- Larger binaries but faster builds
- Required for incremental compilation

```zig
const MonoItemCollectionStrategy = enum {
    eager,  // All reachable instantiations
    lazy,   // Only when actually used
};

const MonoItem = struct {
    kind: union(enum) {
        function: struct {
            def: FunctionDefIndex,
            args: []const Type,  // Concrete type arguments
        },
        global: GlobalDefIndex,
        drop_glue: struct {
            ty: Type,
        },
    },
};
```

### 4.2 The Collection Phase

The monomorphization collector discovers all items that need code generation:

```zig
fn collectMonoItems(root: FunctionDefIndex) ![]MonoItem {
    var items = std.ArrayList(MonoItem).init(allocator);
    var visited = std.AutoHashMap(MonoItem, void).init(allocator);
    
    // Start from root functions
    try worklist.append(.{ .function = .{
        .def = root,
        .args = &.{},
    }});
    
    while (worklist.popOrNull()) |item| {
        if (visited.contains(item)) continue;
        try visited.put(item, {});
        try items.append(item);
        
        // Scan function body for calls to generic functions
        const body = getFunctionBody(item.def);
        for (body.instructions) |inst| {
            if (inst == .call) {
                const callee = inst.call.callee;
                if (isGeneric(callee)) {
                    // Instantiate with concrete types from call site
                    const concrete_args = resolveTypeArgs(
                        callee, inst.call.type_args, item.kind.function.args
                    );
                    try worklist.append(.{
                        .function = .{
                            .def = callee,
                            .args = concrete_args,
                        },
                    });
                }
            }
        }
    }
    
    return items;
}
```

### 4.3 Codegen Unit Partitioning

Rust partitions monomorphized items into codegen units for parallel LLVM compilation:

```zig
const CodegenUnit = struct {
    items: std.ArrayList(MonoItem),
    source_module: ModuleIndex,
};

fn partitionIntoCodegenUnits(
    items: []const MonoItem,
    num_units: usize,
) ![]CodegenUnit {
    var units = try allocator.alloc(CodegenUnit, num_units);
    
    // Stable items (non-generic) -> one CGU per source module
    // Volatile items (monomorphized) -> distributed across CGUs
    for (items) |item| {
        const unit_idx = if (item.isGeneric())
            hashItem(item) % num_units  // Distribute generics
        else
            item.sourceModuleIdx % num_units;  // Keep non-generic together
        
        try units[unit_idx].items.append(item);
    }
    
    return units;
}
```

### 4.4 Type-Flow Analysis for Finite Monomorphization

A recent Rust proposal (2026) introduces flow-directed monomorphization based on the paper "The Simple Essence of Monomorphization":

```zig
// Build type-flow graph during collection
const FlowConstraint = struct {
    from: Type,  // Concrete type that flows in
    to: TypeVar, // Generic parameter it flows into
};

fn buildFlowGraph(function: FunctionDefIndex) !FlowGraph {
    var graph = FlowGraph{};
    
    // For each generic instantiation f::<T>(x):
    // Add constraint: typeof(x) flows into T
    for (getCallSites(function)) |call| {
        if (call.isGenericInstantiation()) {
            for (call.type_args, 0) |ty_arg, i| {
                const param = call.callee.type_params[i];
                try graph.addConstraint(.{ .from = ty_arg, .to = param });
            }
        }
    }
    
    return graph;
}

// Detect growing cycles (infinite monomorphization)
fn hasGrowingCycle(graph: FlowGraph) bool {
    // T -> Option<T> is a growing cycle (infinite)
    // T <-> U is NOT a growing cycle (finite, just equates two sets)
    // ...
}
```

### 4.5 Recommended Strategy for Astra

1. **Default to lazy collection** (smaller binaries, faster individual compiles)
2. **Use eager for incremental/watch mode** (stable set of mono items)
3. **Implement codegen unit partitioning** for parallel LLVM compilation
4. **Add recursion limit** to prevent infinite monomorphization
5. **Future: type-flow analysis** for advanced diagnostics

---

## 5. ARC/ORC Implementation Patterns

### 5.1 LLVM's ARC Infrastructure

LLVM provides ARC optimization passes for Objective-C. Key operations:

| Operation | Purpose | LLVM Intrinsic |
|:----------|:--------|:---------------|
| `retain` | Increment reference count | `@llvm.objc.retain` |
| `release` | Decrement reference count | `@llvm.objc.release` |
| `autorelease` | Deferred release | `@llvm.objc.autorelease` |
| `retainAutoreleasedReturnValue` | Optimized return | `@llvm.objc.retainAutoreleasedReturnValue` |
| `unsafeClaimAutoreleasedReturnValue` | Unsafe optimized return | `@llvm.objc.unsafeClaimAutoreleasedReturnValue` |

### 5.2 ARC Optimization Passes (LLVM)

LLVM's ObjCARC optimizer performs:

1. **Pair elimination**: Remove matching retain/release pairs
2. **Noop elimination**: Remove ARC calls on inert values
3. **Autorelease elision**: Convert autorelease to release when unused
4. **Return value forwarding**: Eliminate retain+autorelease on returns
5. **RV optimization**: Use retainRV/claimRV for return values

```cpp
// From LLVM's ObjCARCOpts.cpp
void ObjCARCOpt::OptimizeIndividualCallImpl(
    Function &F, Instruction *Inst,
    ARCInstKind Class, const Value *Arg
) {
    // Delete no-op casts
    if (Class == ARCInstKind::NoopCast) {
        Changed = true;
        EraseInstruction(Inst);
        return;
    }
    
    // ARC calls with null are no-ops
    if (IsNullOrUndef(Arg)) {
        Changed = true;
        EraseInstruction(Inst);
        return;
    }
    
    // objc_autorelease(x) -> objc_release(x) if x unused
    if (IsAutorelease(Class) && Inst->use_empty()) {
        auto *NewCall = CallInst::Create(EP.Release, Inst->getArgOperand(0));
        EraseInstruction(Inst);
    }
}
```

### 5.3 Astra's ARC/ORC Design

Based on the architecture document, Astra uses:

1. **Atomic ARC** for cross-fiber shared objects
2. **Non-atomic RC** for fiber-local objects (ownership transfer)
3. **ORC** with Trial Deletion for cycle detection

```zig
// Reference count header (embedded in every heap object)
const RefCountHeader = extern struct {
    strong: u32,         // Strong reference count (atomic for cross-fiber)
    weak: u32,           // Weak reference count
    color: u2,           // ORC color (black/purple/gray/white)
    flags: u30,          // Object flags
    
    const Color = enum(u2) {
        black = 0,   // Active, reachable from root
        purple = 1,  // Suspected cycle, RC > 0
        gray = 2,    // Being traced in trial deletion
        white = 3,   // Garbage, unreachable from outside cycle
    };
};

// Runtime functions (implemented in Astra runtime, called from generated code)
extern fn astra_retain(obj: ?*anyopaque) void;
extern fn astra_release(obj: ?*anyopaque) void;
extern fn astra_retain_uninit(obj: ?*anyopaque) void;  // For new objects
extern fn astra_weak_retain(obj: ?*anyopaque) void;
extern fn astra_weak_release(obj: ?*anyopaque) void;
extern fn astra_check_orc_cycle(obj: ?*anyopaque) void;  // Trial deletion trigger
```

### 5.4 ARC Insertion Strategy

The compiler inserts ARC operations during the ARCIR phase:

```zig
fn insertArcForValue(ir: *TypedIR, value: Value, op: ArcOp) void {
    // Don't insert for:
    // - Stack-allocated values
    // - Integer/bool/float primitives (non-heap)
    // - Values immediately consumed (no copy)
    // - @noARC annotated values
    
    if (isTriviallyManaged(value.type)) return;
    if (value.lifetime.isSingleOwner()) return;  // Move semantics
    
    ir.append(.{
        .tag = switch (op) {
            .retain => .arc_retain,
            .release => .arc_release,
            .autorelease => .arc_autorelease,
        },
        .operand = value,
    });
}
```

### 5.5 ARC Optimization at the Astra Level

Before LLVM, Astra should perform its own ARC optimizations:

1. **Paired retain/release elimination**: Remove matching pairs within basic blocks
2. **Borrow checking**: Don't retain for short borrows
3. **Move elision**: Don't retain+release for ownership transfers
4. **Autorelease pools**: Batch releases for temporary objects

```zig
fn optimizeArc(ir: *ARCIR) void {
    // Pass 1: Find matching retain/release pairs
    for (ir.instructions, 0..) |inst, i| {
        if (inst.tag == .arc_retain) {
            // Look for matching release
            if (findMatchingRelease(ir, i, inst.operand)) |release_idx| {
                // Check no observable side effects between them
                if (noSideEffectsBetween(ir, i, release_idx)) {
                    ir.instructions[i] = .nop;
                    ir.instructions[release_idx] = .nop;
                }
            }
        }
    }
    
    // Pass 2: Merge retain+autorelease into single operation
    // Pass 3: Hoist retains out of loops when possible
}
```

### 5.6 ORC Cycle Detection (Trial Deletion)

The ORC algorithm runs periodically to detect and collect cycles:

```zig
// ORC collector runs when heap pressure exceeds threshold
fn runOrcCycleDetection(runtime: *Runtime) void {
    // Phase 1: MarkGray - DFS from possible_roots
    for (runtime.possible_roots.items) |obj| {
        if (obj.refCount() > 0) {
            markGray(obj);
        }
    }
    
    // Phase 2: Scan - Check if gray nodes have external references
    for (runtime.gray_list.items) |obj| {
        if (obj.refCount() > 0) {
            scanBlack(obj);  // Has external refs, restore to black
        } else {
            // No external refs, mark as white (garbage)
        }
    }
    
    // Phase 3: CollectWhite - Free white objects
    for (runtime.white_list.items) |obj| {
        callDestructor(obj);
        freeObject(obj);
    }
    
    // Reset for next cycle
    runtime.possible_roots.clearRetainingCapacity();
}
```

---

## 6. Self-Hosting Bootstrap Strategies

### 6.1 Zig's Three-Stage Bootstrap

Zig uses a three-stage bootstrap process:

```
Stage 1: zig1 (WASM Bootstrap)
  - Minimal compiler compiled to WASM
  - Only C backend enabled
  - Optimized for size (-Os)
  - Input: zig source -> Output: C code

Stage 2: zig2 (Self-Hosted with C++)
  - Built by zig1 (compiles to C, then C++ compiler)
  - Full self-hosted compiler logic
  - Debug optimization (-O0)
  - Input: zig source -> Output: C/native

Stage 3: zig (Production)
  - Built by zig2
  - Full optimization
  - Input: zig source -> Output: native binary
```

### 6.2 Bootstrap from C Seed Compiler

For Astra, the bootstrap chain is:

```
Phase 1: C seed compiler (astra-seed)
  - Compiles: Astra-0 subset
  - Backend: Bytecode VM + C codegen
  - Purpose: Build the Phase 2 compiler

Phase 2: Zig self-hosting compiler (astra-zig)
  - Built by: astra-seed compiling astra-0 source
  - Compiles: Full Astra (Astra-1)
  - Backend: LLVM
  - Purpose: Production compiler

Phase 3: Astra compiler (astra-native)
  - Built by: astra-zig
  - Compiles: Full Astra
  - Purpose: Self-hosting, no Zig dependency
```

### 6.3 The Zig Bootstrap Technique for Astra

Zig's bootstrap uses WASM as a portable stage0. For Astra, we can use a simpler approach:

```
Step 1: Use astra-seed to compile a minimal Astra-to-C translator
        (subset of Astra that's enough to express the compiler)

Step 2: Use the translator to convert astra-zig source to C

Step 3: Use system C compiler to compile the C output into astra-zig

Step 4: Use astra-zig to build itself (now self-hosting)
```

**Key insight from Zig**: The translator only needs to handle a subset of the language. Most of the compiler's complexity (optimization, backends, debug info) can be excluded from the bootstrap translator.

### 6.4 Recommended Bootstrap Strategy for Astra

```zig
// bootstrap/ directory structure
const bootstrap = struct {
    // Stage 0: Minimal Astra-to-C translator
    // Written in C, compiled by system C compiler
    // Translates a subset of Astra to C
    
    // Stage 1: Built by astra-seed
    // The actual astra-zig compiler
    // But compiled via astra-seed -> C -> gcc
    
    // Stage 2: Built by Stage 1
    // Self-hosted astra-zig
    // Now we can use `astra-zig build` from here on
};
```

### 6.5 Cross-Compilation Support

The bootstrap should support cross-compilation:

```
Host: x86_64-linux
Target: aarch64-linux

1. astra-seed (x86_64) compiles astra-zig source -> C
2. Cross-compiler (aarch64) compiles C -> astra-zig (aarch64)
3. astra-zig (aarch64) can now compile for aarch64 natively
```

---

## 7. Lessons from Other Compiler Projects

### 7.1 Zig Compiler Lessons

1. **Data-oriented design is worth the complexity**: The InternPool and MultiArrayList patterns significantly improve performance and memory usage.

2. **Separate IRs for different concerns**: ZIR for file-level caching, AIR for function-level analysis. Don't try to do everything in one IR.

3. **Progressive capability via feature gating**: The `dev.zig` system allows the bootstrap compiler to exclude features it doesn't need, reducing binary size.

4. **C++ isolation is critical**: The `zig_llvm.cpp` wrapper prevents C++ from infecting the entire codebase. Essential for maintainability.

5. **Incremental from the start**: Dependency tracking via AnalUnit/Nav/TrackedInst was woven into core data structures from the beginning, not bolted on later.

### 7.2 Rust Compiler Lessons

1. **Monomorphization is expensive**: Both in compile time and binary size. Consider offering both monomorphized and vtable-based generics.

2. **Error recovery matters**: rustc's ability to continue compiling after errors and report multiple issues at once is crucial for developer experience.

3. **The borrow checker is complex**: Astra avoids this complexity by using ARC/ORC, but the trade-off is runtime overhead.

4. **Incremental compilation is hard**: Rust's query system and dependency tracking are sophisticated but required years of work.

### 7.3 Swift Compiler Lessons

1. **SIL (Swift Intermediate Language) is powerful**: A high-level IR enables Swift-specific optimizations like ARC optimization, devirtualization, and generic specialization before lowering to LLVM IR.

2. **Mandatory optimization passes are useful**: Running certain optimizations (like ARC optimization) always, even at -O0, ensures consistent behavior.

3. **Generic specialization at the SIL level**: Allows better optimization than doing it at LLVM IR level, because high-level type information is still available.

### 7.4 Go Compiler Lessons

1. **Simple is fast**: Go's compiler is fast because it avoids complex optimizations and uses a simple GC.

2. **Fast compilation is a feature**: Go's compile speed is a major selling point. Consider this for Astra's interpreted/VM mode.

3. **Interface-based polymorphism**: Go uses interfaces (similar to traits) with runtime dispatch, avoiding monomorphization entirely for interfaces.

### 7.5 Clang/LLVM Lessons

1. **ARC optimization is mature**: LLVM's ObjCARC passes are battle-tested. Leverage them rather than reimplementing.

2. **Debug info generation is complex**: Plan for DWARF generation from the start. Retroactive addition is painful.

3. **Target-specific code is inevitable**: Even with LLVM, you need target-specific handling for ABI, calling conventions, and intrinsics.

---

## 8. Recommended Libraries and Tools

### 8.1 Zig Dependencies

| Library | Purpose | Notes |
|:--------|:--------|:------|
| `std.zig.llvm` | LLVM bindings | Built into Zig std lib |
| `zig-llvm` (kassane) | Standalone LLVM bindings | Alternative, more complete |
| `zig-clang` | Clang bindings | For C interop analysis |

### 8.2 Build System

```zig
// build.zig for Astra Phase 2
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Main compiler executable
    const compiler = b.addExecutable(.{
        .name = "astra",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // LLVM integration
    compiler.linkSystemLibrary2("LLVM", .{
        .preferred_link_mode = .static,
    });
    
    // LLD for linking
    compiler.linkSystemLibrary2("lldELF", .{});
    compiler.linkSystemLibrary2("lldCOFF", .{});
    compiler.linkSystemLibrary2("lldWasm", .{});
    
    b.installArtifact(compiler);
}
```

### 8.3 Testing Infrastructure

```zig
// Test categories
test "lexer" { ... }           // Token generation
test "parser" { ... }          // AST construction
test "sema" { ... }            // Type checking
test "codegen_vm" { ... }      // Bytecode generation
test "codegen_llvm" { ... }    // LLVM IR generation
test "e2e_native" { ... }      // End-to-end native compilation
test "e2e_vm" { ... }          // End-to-end VM execution
test "bootstrap" { ... }       // Self-compilation test
test "conformance" { ... }     // Astra-0 conformance suite
```

### 8.4 Development Tools

- **Language Server Protocol (LSP)**: For IDE integration
- **Formatter**: Reuse Zig's formatter patterns
- **Profiler**: Use `perf`/` Instruments` for performance analysis
- **Sanitizers**: ASan, UBSan, LSan (Zig has built-in support)
- **Fuzzing**: libFuzzer or AFL++ for parser/sema fuzzing

---

## 9. Astra-Specific Design Decisions

### 9.1 IR Design for Astra

Based on the architecture document and Zig's patterns:

```
AstraIR (untyped, per-file):
  - Instruction-based like ZIR
  - Supports: functions, structs, enums, match, if/else, loops
  - Cached to disk for incremental compilation
  
TypedIR (typed, per-function):
  - Fully typed like AIR
  - Generic instantiation complete
  - Comptime evaluated
  - ARC operations explicit
  
MonoIR (monomorphized):
  - All generics instantiated
  - Ready for ARC insertion
  
ARCIR (with reference counting):
  - ARC operations inserted
  - Ready for LLVM codegen
```

### 9.2 Type System Design

```zig
// Astra's type hierarchy
const Type = union(enum) {
    // Primitives
    bool, int, f64, string, void, never,
    
    // Compound
    array: ArrayType,
    optional: *const Type,
    result: ResultType,
    function: FunctionType,
    tuple: []const Type,
    
    // User-defined
    adt: AdtType,  // structs, enums
    
    // Generic
    type_var: TypeVar,
    generic: GenericType,
    
    // Trait
    trait_ref: TraitRef,
};
```

### 9.3 ARC/ORC Integration Points

From the architecture document, key decisions needed:

1. **When to release**: At scope exit, or when last reference goes out of scope?
2. **Explicit copy**: `.copy()` for deep copy semantics
3. **Fiber crossing**: Force promotion to `AtomicRef[T]` or deep copy

### 9.4 Performance Targets

Based on the architecture document's goals:

| Metric | Target | Strategy |
|:-------|:-------|:---------|
| Compile speed | <10ms for small files | VM mode, lazy compilation |
| Runtime speed | Within 2x of C | LLVM optimization, ARC elision |
| Binary size | Competitive with C | Monomorphization control, LTO |
| Memory usage | Linear with source size | Arena allocators, InternPool |

### 9.5 Phased Implementation Order

1. **Lexer + Parser** (2-3 weeks)
2. **AST + AstGen** (2-3 weeks)
3. **Type checker with Algorithm W** (4-6 weeks)
4. **Basic codegen (VM or simple LLVM)** (3-4 weeks)
5. **ARC/ORC implementation** (4-6 weeks)
6. **Generic monomorphization** (3-4 weeks)
7. **LLVM optimization integration** (2-3 weeks)
8. **Bootstrap self-compilation** (2-3 weeks)
9. **Performance optimization** (ongoing)

**Total estimate**: 6-9 months for a working Phase 2 compiler.

---

## Appendix A: Key References

1. Zig compiler source: `github.com/ziglang/zig`
2. Zig bootstrap: `github.com/ziglang/zig-bootstrap`
3. Algorithm W tutorial: "Algorithm W Step by Step" (Martin Grabmuller)
4. Typechecker Zoo: `sdiehl.github.io/typechecker-zoo`
5. LLVM ObjCARC: `llvm.org/docs/ARCOpt.html`
6. Rust monomorphization: `rustc-dev-guide.rust-lang.org/backend/monomorph.html`
7. Swift SIL: `github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md`
8. Zig compiler architecture: DeepWiki articles on ziglang/zig
9. Astra architecture: `Documentacion/ARCHITECTURE.md`
10. Astra compiler strategy: `Documentacion/COMPILER_STRATEGY.md`

## Appendix B: Open Questions for Astra Phase 2

1. Should Astra use a high-level IR like Swift's SIL, or go directly to typed IR?
2. How aggressive should ARC optimization be at -O0?
3. Should generics use monomorphization, vtables, or both?
4. How should comptime evaluation interact with the type checker?
5. What is the minimum viable Astra-1 subset for Phase 2 bootstrap?
6. Should the fiber runtime be part of the compiler or a separate library?
7. How should FFI with C and Python be handled at the LLVM level?
8. What debugging information format (DWARF vs CodeView) should be default?

