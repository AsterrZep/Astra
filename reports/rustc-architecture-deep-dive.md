# Deep Dive: Internal Architecture of the Rust Compiler (rustc)

*For the Astra Language Project — Understanding HOW and WHY Rust works*

---

## Table of Contents

1. [Compiler Pipeline](#1-compiler-pipeline)
2. [Key Compiler Crates](#2-key-compiler-crates)
3. [Type System Internals](#3-type-system-internals)
4. [Memory Safety at Compile Time](#4-memory-safety-at-compile-time)
5. [Error Handling and Diagnostics](#5-error-handling-and-diagnostics)
6. [What Makes Rust's Approach Unique](#6-what-makes-rusts-approach-unique)
7. [Lessons for Astra](#7-lessons-for-astra)

---

## 1. Compiler Pipeline

### 1.1 The Full Pipeline

```
Source Code (.rs)
    │
    ▼
Token Stream (rustc_parse)
    │
    ▼
AST (rustc_ast)  ← macros expanded, names NOT resolved
    │
    ▼
HIR (rustc_hir)  ← desugared AST, names resolved, lifetimes elided
    │
    ▼
THIR (rustc_mir_build::thir) ← fully typed, explicit derefs/borrows
    │
    ▼
MIR (rustc_middle::mir)  ← control-flow graph, borrow checking happens here
    │
    ▼
Optimized MIR (rustc_mir_transform) ← optimizations on generic MIR
    │
    ▼
Monomorphized MIR (rustc_monomorphize) ← concrete types substituted
    │
    ▼
LLVM IR (rustc_codegen_llvm) ← lowered to SSA form
    │
    ▼
Machine Code (LLVM) ← optimization + code generation
    │
    ▼
Object Files (.o) → Linked Binary
```

### 1.2 What Each IR Does and WHY It Exists

#### AST (`rustc_ast`)
- **Purpose**: Faithful representation of what the programmer wrote
- **Characteristics**: Tree structure, nested expressions, macro invocations unexpanded
- **Why it exists**: Clean separation between parsing and semantic analysis. The AST can be transformed by macro expansion before any semantic work begins.

#### HIR (`rustc_hir`)
- **Purpose**: Compiler-friendly representation for type checking
- **Characteristics**: Desugared (no `for` loops — converted to `loop`), macro-expanded, names resolved, some lifetimes elided. Nodes have unique `HirId` identifiers.
- **Why it exists**: The AST is too syntactic for semantic analysis. HIR removes syntactic sugar while preserving structure. It's the basis for all type checking and name resolution queries.
- **Key design**: HIR stores items in flat maps (not nested trees) for efficient incremental compilation — accessing one item doesn't require traversing siblings.

#### THIR (`rustc_mir_build::thir`)
- **Purpose**: Intermediate between HIR and MIR, fully typed and desugared
- **Characteristics**: All types filled in after type checking, method calls and implicit derefs made explicit, statements/expressions stored separately as indexed arrays
- **Why it exists**: MIR construction from HIR is complex because HIR still has high-level constructs. THIR makes everything explicit: `a.method(b)` becomes `<Type as Trait>::method(a, b)`, implicit references/dereferences are made explicit. This makes MIR lowering straightforward.
- **Lifecycle**: THIR is temporary — it's created, used for MIR construction/unsafety checking, then dropped to save memory.

#### MIR (`rustc_middle::mir`)
- **Purpose**: Control-flow graph for borrow checking, optimization, and codegen
- **Characteristics**: Flat CFG with basic blocks, no nested expressions, all types fully explicit, operations are simple (assignments, function calls, borrows)
- **Why it exists**: This is Rust's most important IR. It enables:
  1. **Borrow checking** via dataflow analysis (impossible on HIR's tree structure)
  2. **Non-Lexical Lifetimes (NLL)** — regions derived from CFG, not syntax
  3. **MIR optimizations** on generic code (before monomorphization)
  4. **Const evaluation** via Miri (an interpreter for MIR)
  5. **Monomorphization collection** — determining which concrete types to generate

#### LLVM IR
- **Purpose**: Backend code generation target
- **Characteristics**: SSA form, platform-independent, rich optimization infrastructure
- **Why it exists**: LLVM provides decades of optimization passes, multiple target architectures, and battle-tested code generation. Rust piggybacks on this rather than building from scratch.

### 1.3 HIR vs MIR: Why Two High-Level IRs?

This is a critical design question. The answer is **layered desugaring**:

**HIR is for analysis, MIR is for transformation.**

| Property | HIR | MIR |
|----------|-----|-----|
| Structure | Nested tree | Flat CFG |
| Types | Some inferred | All explicit |
| Pattern matching | Syntactic | Exhaustiveness checked |
| Borrows | Implicit | Explicit `&`/`&mut` as `Rvalue::Ref` |
| Control flow | `if`/`match`/`for` | `SwitchInt`/`Goto` only |
| Suitable for | Type checking, trait resolution | Borrow checking, optimization |

**Why not just use MIR for everything?** Because MIR is too low-level for type checking. When you write `fn foo<T: Clone>(x: T)`, the type checker needs to see the generic parameter `T` and its bounds clearly. MIR has already monomorphized these away (or will later). The HIR preserves the programmer's intent; MIR is closer to machine code.

**Why not just use HIR for borrow checking?** Because HIR is a tree, not a CFG. You can't do dataflow analysis on a tree efficiently. The borrow checker needs to know what happens at *every point* in the control flow — which requires a CFG representation.

### 1.4 MIR Construction (HIR → THIR → MIR)

The lowering happens in two steps:

1. **HIR → THIR**: `thir_body(tcx, def_id)` produces a `Thir` structure. This fills in all types, makes desugaring explicit, and converts to an expression-array representation.

2. **THIR → MIR**: `mir_built(tcx, def_id)` walks the THIR and produces a `Body<'tcx>` containing:
   - `BasicBlockData` — a vector of basic blocks, each with statements and a terminator
   - `LocalDecl` — metadata for each local variable
   - `SourceInfo` — span information for diagnostics

The MIR builder processes THIR expressions recursively, creating:
- **Rvalues**: right-hand sides of assignments (e.g., `a + b` → `Rvalue::BinaryOp(Add, a, b)`)
- **Places**: memory locations (e.g., `_3.f` → `Place { local: _3, projection: [Field(f)] }`)
- **Operands**: arguments to rvalues (either constants or copies/moves from places)

Operators on built-in types become `Rvalue::BinaryOp`/`Rvalue::UnaryOp` (lowered to LLVM intrinsics later). Operators on custom types become function calls to trait implementations.

### 1.5 Borrow Checking Integrated into MIR (NLL)

The borrow checker (`rustc_borrowck`) operates on MIR and works in these stages:

#### Stage 1: Region Replacement
```rust
// In nll.rs
pub(crate) fn replace_regions_in_mir(infcx, body, promoted) -> UniversalRegions<'tcx> {
    let universal_regions = UniversalRegions::new(infcx, def);
    renumber_mir(infcx, body, promoted);  // Replace all regions with fresh inference vars
    universal_regions
}
```
All lifetime annotations are replaced with fresh inference variables. The compiler then solves for the *minimal* lifetimes that satisfy all constraints — this is what makes lifetimes "non-lexical."

#### Stage 2: MIR Type Check
Walks every statement and terminator, collecting region constraints:
- `'_1: &'a u32` → constraint: `'a` must outlive the borrow
- Function calls → constraints from where clauses
- Assignments → constraints from subtyping

#### Stage 3: Region Inference
```
RegionInferenceContext::new(infcx, lowered_constraints, universal_region_relations)
```
Uses a constraint graph with SCC (Strongly Connected Components) to solve for region values. Each region becomes a set of CFG points where the borrow must be live.

#### Stage 4: Dataflow Analysis
Three sub-analyses compose the borrow check:

1. **Borrows**: Tracks which borrows are active at each CFG point
2. **MaybeUninitializedPlaces**: Tracks which places might be uninitialized
3. **EverInitializedPlaces**: Tracks which places were ever initialized

```rust
pub(crate) struct Borrowck<'a, 'tcx> {
    pub(crate) borrows: Borrows<'a, 'tcx>,
    pub(crate) uninits: MaybeUninitializedPlaces<'a, 'tcx>,
    pub(crate) ever_inits: EverInitializedPlaces<'a, 'tcx>,
}
```

#### Stage 5: Error Reporting
A second walk over MIR checks each operation against active borrows:
- Use of moved value → error
- Mutable borrow while shared borrow active → error
- Assignment while borrowed → error

### 1.6 Monomorphization at the MIR Level

Monomorphization happens in two phases:

**Phase 1: Collection** (`rustc_monomorphize::collector`)
- Starts from roots: public non-generic items
- Walks MIR to find used generic items
- For each generic function call, determines the concrete type arguments
- Produces a set of "mono items" — (DefId, concrete_type_args) pairs

**Phase 2: Partitioning** (`rustc_monomorphize::partitioning`)
- Groups mono items into codegen units (CGUs)
- Items marked `#[inline]` are duplicated in every CGU that references them
- Non-generic items stay in one CGU for their source module
- Generic instantiations go in a single CGU per crate

### 1.7 Codegen Backend: MIR → LLVM IR

The codegen happens in `rustc_codegen_ssa::mir::codegen_mir`:

1. **Pre-codegen analysis**: Identify SSA-like locals that can map directly to SSA registers
2. **For each basic block**: Create an LLVM basic block
3. **For each statement**: Lower MIR statement to LLVM IR
   - `Assign(_1, Rvalue::BinaryOp(Add, _2, _3))` → `add i32 %2, %3`
   - `Assign(_1, Rvalue::Ref(...))` → pointer arithmetic
4. **For each terminator**: Lower MIR terminator to LLVM terminator
   - `Call(fn, args, destination)` → LLVM `call` instruction
   - `SwitchInt(discriminant, targets)` → LLVM `switch` instruction

Monomorphization happens lazily during this process — `FunctionCx::monomorphize` substitutes concrete types into generic MIR on-the-fly.

---

## 2. Key Compiler Crates

### 2.1 Crate Dependency Graph

```
rustc_driver (orchestration)
    └─ rustc_interface (session, queries)
        └─ rustc_middle (TyCtxt, MIR types, query system)
            ├─ rustc_ast (AST definitions)
            ├─ rustc_hir (HIR definitions, visitor)
            ├─ rustc_resolve (name resolution)
            ├─ rustc_ast_lowering (HIR construction)
            ├─ rustc_hir_analysis (type checking, trait solving)
            ├─ rustc_hir_typeck (type inference per-function)
            ├─ rustc_mir_build (THIR/MIR construction, unsafety checking)
            ├─ rustc_mir_transform (MIR optimizations)
            ├─ rustc_mir_dataflow (dataflow analysis framework)
            ├─ rustc_borrowck (borrow checking)
            ├─ rustc_monomorphize (mono item collection)
            ├─ rustc_codegen_ssa (backend-agnostic codegen)
            ├─ rustc_codegen_llvm (LLVM code generation)
            └─ rustc_infer (type inference, trait resolution)
```

### 2.2 Core Crates

#### `rustc_ast`
- Defines the AST node types (`Expr`, `Item`, `Pat`, `Ty`, etc.)
- Token definitions, span types
- Pretty printing infrastructure
- Located at: `compiler/rustc_ast/src/`

#### `rustc_hir`
- HIR node definitions (similar to AST but desugared)
- The `HirId` identifier system (owner + local_id)
- Intravisit trait for walking HIR
- Maps for efficient item lookup
- Located at: `compiler/rustc_hir/src/`

#### `rustc_mir_build`
- HIR/THIR → MIR lowering
- THIR definition (`thir::Expr`, `thir::Block`, `thir::Stmt`)
- Unsafety checking (operates on THIR)
- Pattern/exhaustiveness checking
- Located at: `compiler/rustc_mir_build/src/`

#### `rustc_mir_transform`
- MIR optimization passes
- The `MirPass` trait definition
- Pass manager that sequences optimizations
- Includes: `Inline`, `GVN`, `DataflowConstProp`, `JumpThreading`, `SimplifyCfg`, etc.
- Located at: `compiler/rustc_mir_transform/src/`

#### `rustc_mir_dataflow`
- Framework for dataflow analysis
- `Analysis` trait with forward/backward variants
- `iterate_to_fixpoint` algorithm
- Lattice infrastructure
- Results cursors and visitors
- Used by: borrow checker, uninitialized variable checking, dead code analysis
- Located at: `compiler/rustc_mir_dataflow/src/`

#### `rustc_codegen_llvm`
- Translates MIR to LLVM IR
- Builder interface wrapping LLVM's C API
- Intrinsic handling
- Type lowering to LLVM types
- Located at: `compiler/rustc_codegen_llvm/src/`

#### `rustc_resolve`
- Name resolution
- Module resolution, import resolution
- Macro resolution
- Label resolution
- Located at: `compiler/rustc_resolve/src/`

#### `rustc_infer`
- Type inference engine
- Inference variables (type, region, const)
- Unification tables
- Subtyping/equality constraints
- Trait obligation tracking
- Located at: `compiler/rustc_infer/src/`

#### `rustc_borrowck`
- The borrow checker
- NLL region inference
- MIR type checking
- Polonius analysis (next-gen borrow checker)
- Error diagnostics
- Located at: `compiler/rustc_borrowck/src/`

### 2.3 Why This Modular Architecture?

The modular architecture serves several purposes:

1. **Incremental compilation**: Each crate provides queries that can be cached independently
2. **Parallel compilation**: Crates can be compiled in parallel if dependencies are satisfied
3. **Testing**: Each crate can be tested independently
4. **Maintainability**: Clear separation of concerns
5. **Bootstrapping**: The compiler is written in Rust, so crates must have clean dependency boundaries

The key insight is that **all crates communicate through `TyCtxt`** — the central query context. There's no global mutable state. Every piece of information flows through queries, making the system inherently incremental and parallelizable.

---

## 3. Type System Internals

### 3.1 Hindley-Milner Inference Implementation

Rust's type inference is based on Hindley-Milner but extended significantly:

```rust
// Creating an inference context
let infcx = tcx.infer_ctxt().build();

// The inference context houses inference variables
let placeholder_ty = infcx.next_ty_var(TypeVariableOrigin::MiscVariable(span));

// Equality constraints
infcx.at(&cause, param_env).eq(DefineOpaqueTypes::Yes, expected, actual)?;

// Subtyping constraints
infcx.at(&cause, param_env).sub(DefineOpaqueTypes::Yes, subtype, supertype)?;
```

**Key differences from standard HM:**

1. **Subtyping**: Rust has limited subtyping (lifetimes, coercions). The inferencer handles `?T <: i32` by converting to equality when possible, or enqueuing obligations.

2. **Regions**: Lifetimes are inferred separately from types. Region constraints are collected as outlives constraints (`'a: 'b`) and solved at the end of type checking.

3. **Higher-ranked types**: `for<'a> fn(&'a u32) -> &'a u32` requires special handling with placeholders and bound variables.

4. **Two-phase unification**: Types are unified eagerly, but regions are solved lazily at the end.

### 3.2 Trait Resolution Algorithm

Trait resolution has three major components:

#### Selection (`SelectionContext::select`)
```
1. Candidate Assembly:
   - Search for impls matching the Self type
   - Check where clauses in scope
   - Look for builtin impls (Copy, Sized, etc.)

2. Winnowing:
   - Remove candidates that don't match where clauses
   - Use `evaluate_candidate` to check nested obligations
   - Prefer more specific candidates (specialization)

3. Confirmation:
   - Unify output type parameters
   - Verify associated types
   - Report errors if types don't match
```

#### Fulfillment (`FulfillmentContext`)
- Tracks pending obligations as a worklist
- Processes obligations via `ObligationForest`
- When an obligation is selected, its nested obligations are enqueued
- Runs until fixpoint or error

#### Evaluation (`EvaluationResult`)
- Checks if obligations hold without constraining inference variables
- Used during selection to disambiguate candidates
- Returns: `EvaluatedToOk`, `EvaluatedToAmbig`, `EvaluatedToErr`

### 3.3 The Next-Generation Trait Solver

The new solver (available with `-Znext-solver=globally`) introduces:

1. **Provisional caching**: When exploring a trait implementation, the solver marks it as "provisionally true" in the cache. If the exploration completes successfully, the entry is upgraded to "actually true."

2. **Cycle handling**: If the solver encounters a cycle (needing `Link: Debug` to prove `Link: Debug`), it can use the provisional cache entry to break the cycle.

3. **Canonicalization**: Obligations are rewritten to remove type variables, enabling more cache hits. This also enables proof tree reconstruction for better error messages.

4. **Proof trees**: The solver records the chain of reasoning used to resolve each obligation. These are only materialized when an error needs to be shown, avoiding overhead for correct code.

### 3.4 Monomorphization vs Dynamic Dispatch

#### Monomorphization (Static Dispatch)
```rust
fn draw_static<T: Drawable>(item: &T) {
    item.draw();  // Compiler knows exact type, inlines the call
}
// Binary contains: draw_static_Circle, draw_static_Square (separate copies)
```

- **Zero runtime cost**: Each call is resolved at compile time
- **Inlining**: Compiler can inline across call boundaries
- **Code bloat**: One function body per concrete type
- **Compile time**: Increases with each instantiation

#### Dynamic Dispatch (`dyn Trait`)
```rust
fn draw_dynamic(item: &dyn Drawable) {
    item.draw();  // Vtable lookup at runtime
}
// Binary contains: one draw_dynamic function, vtables for Circle and Square
```

- **Runtime cost**: Vtable load + indirect call (~2-5ns overhead)
- **No code bloat**: One function body regardless of types
- **Heterogeneous collections**: `Vec<Box<dyn Drawable>>` is possible
- **No inlining**: Compiler can't see through the vtable

**Vtable structure:**
```rust
// Generated by the compiler, never written by hand
struct Vtable {
    drop_in_place: fn(*mut ()),  // Destructor
    size: usize,                  // Size of the type
    align: usize,                 // Alignment of the type
    // Method function pointers follow...
    draw: fn(&Self),
    // ...
}
```

### 3.5 `impl Trait` vs `dyn Trait` Compilation

#### `impl Trait` (Static Dispatch)
```rust
fn make_greeter() -> impl Greetable {
    Person { name: "Alice".into() }
}
// Return type is erased to a fresh type parameter
// The caller gets: fn make_greeter() -> __Greeter
// where __Greeter is a unique, unnameable type
```

- The compiler creates a fresh type variable for the return
- All calls are monomorphized — the concrete type is known at each call site
- No vtable, no indirection

#### `dyn Trait` (Dynamic Dispatch)
```rust
fn make_greeter() -> Box<dyn Greetable> {
    Box::new(Person { name: "Alice".into() })
}
// Return type is a fat pointer: (data_ptr, vtable_ptr)
```

- The compiler generates a vtable for `Person: Greetable`
- The `Box<dyn Greetable>` is 16 bytes (two pointers)
- Method calls go through the vtable

### 3.6 Associated Types and GATs

#### Associated Types
```rust
trait Iterator {
    type Item;  // Associated type
    fn next(&mut self) -> Option<Self::Item>;
}
```

During trait resolution, associated types are "projected":
```
<O as Iterator>::Item = i32
```

The projection cache (`ProjectionCache`) memoizes these results to avoid redundant computation.

#### Generic Associated Types (GATs)
```rust
trait LendingIterator {
    type Item<'a> where Self: 'a;
    fn next<'a>(&'a mut self) -> Option<Self::Item<'a>>;
}
```

GATs add lifetime parameters to associated types. The compiler handles this by:
1. Introducing higher-ranked types (`for<'a>`)
2. Adding region constraints from the `where Self: 'a` bound
3. Using the same projection machinery with additional lifetime arguments

---

## 4. Memory Safety at Compile Time

### 4.1 How the Borrow Checker Enforces Ownership

The borrow checker enforces three rules at every point in the program:

1. **At any given time, you can have either one mutable reference OR any number of shared references**
2. **References must always be valid** (no dangling references)
3. **No data races** (enforced by the combination of rules 1 and 2)

These are enforced through dataflow analysis on MIR:

```rust
// Example:
let mut x = 5;
let y = &x;      // Shared borrow of x
let z = &x;      // Another shared borrow — OK
// let w = &mut x;  // Mutable borrow — ERROR: y and z still live
println!("{y} {z}");
// y and z go out of scope here
let w = &mut x;   // OK now
```

In MIR, this looks like:
```mir
_1 = const 5;                    // x = 5
_2 = &_1;                        // y = &x (shared borrow)
_3 = &_1;                        // z = &x (shared borrow)
// Dataflow: borrow of _1 is active here
_4 = &raw mut _1;                // w = &mut x — CONFLICT with active borrows
```

### 4.2 MIR-Based Dataflow Analysis

The dataflow framework (`rustc_mir_dataflow`) provides:

```rust
pub trait Analysis<'tcx> {
    type Domain: Clone + JoinSemiLattice;
    const NAME: &'static str;
    
    fn bottom_value(&self, body: &Body<'tcx>) -> Self::Domain;
    fn initialize_start_block(&self, body: &Body<'tcx>, state: &mut Self::Domain);
    
    // Per-statement effects
    fn apply_early_statement_effect(&self, state: &mut Self::Domain, stmt: &Statement<'tcx>, location: Location);
    fn apply_primary_statement_effect(&self, state: &mut Self::Domain, stmt: &Statement<'tcx>, location: Location);
    
    // Per-terminator effects
    fn apply_early_terminator_effect(&self, state: &mut Self::Domain, term: &Terminator<'tcx>, location: Location);
    fn apply_primary_terminator_effect<'mir>(&self, state: &mut Self::Domain, term: &'mir Terminator<'tcx>, location: Location) -> TerminatorEdges<'mir, 'tcx>;
}
```

**The Borrows analysis tracks:**
- When a borrow is created: `state.gen_(borrow_index)`
- When a borrow goes out of scope: `state.kill(borrow_index)` (based on region liveness)
- When a place is overwritten: kill all borrows of that place

### 4.3 Lifetime Inference Algorithm

1. **Constraint Collection**: During MIR type checking, the compiler collects outlives constraints:
   ```
   'a: 'b  (region 'a must outlive region 'b)
   ```

2. **SCC Computation**: Constraints are grouped into Strongly Connected Components. Regions in the same SCC must have the same value.

3. **Constraint Solving**: The `RegionInferenceContext` solves constraints by:
   - Building a constraint graph with CFG points as nodes
   - Propagating region values forward through the CFG
   - Finding the minimal solution that satisfies all constraints

4. **Borrow Scope Determination**: For each borrow, the compiler determines:
   - The set of CFG points where the borrow is "live" (the region contains that point)
   - At each point, whether any conflicting borrow is also live

### 4.4 How `unsafe` Blocks Bypass Checks

`unsafe` blocks create a `SafetyContext::UnsafeBlock` in the unsafety visitor:

```rust
fn in_safety_context(&mut self, safety_context: SafetyContext, f: impl FnOnce(&mut Self)) {
    let prev_context = mem::replace(&mut self.safety_context, safety_context);
    f(self);
    self.safety_context = prev_context;
}
```

Inside an unsafe block, operations like:
- Dereferencing raw pointers
- Calling unsafe functions
- Accessing mutable statics
- Implementing unsafe traits

...are allowed without error. The borrow checker still runs, but certain safety checks are relaxed.

### 4.5 How the Compiler Verifies `unsafe` Code

Unsafe checking happens on THIR (`rustc_mir_build::check_unsafety`):

```rust
pub(crate) fn check_unsafety(tcx: TyCtxt<'_>, def_id: LocalDefId) {
    let Ok((thir, expr)) = tcx.thir_body(def_id) else { return };
    
    let mut visitor = UnsafetyVisitor {
        tcx,
        thir,
        safety_context: /* determined by fn_sig safety */,
        // ...
    };
    
    // Visit all expressions in the THIR
    visitor.visit_expr(&thir[expr]);
    
    // Report warnings for unused unsafe blocks
    for warning in warnings {
        tcx.emit_node_span_lint(UNUSED_UNSAFE, ...);
    }
}
```

The visitor tracks:
- Whether we're in an `unsafe` block/function
- Which unsafe operations were encountered
- Which `unsafe` blocks were actually used (for the `unused_unsafe` lint)

**Runtime UB checks** are implemented via `assert_unsafe_precondition!` in the standard library:
```rust
if ::core::ub_checks::check_language_ub() {
    precondition_check(ptr, align, is_zst);
}
```
These checks are enabled at codegen time when debug assertions are on, allowing detection of UB even in `unsafe` code during testing.

---

## 5. Error Handling and Diagnostics

### 5.1 How rustc Produces Rich Error Messages

The diagnostic infrastructure is built around the `Diag` type:

```rust
// Basic error emission
tcx.dcx().span_err(span, "mismatched types");

// Structured error with suggestions
tcx.dcx().struct_span_err(span, "mismatched types")
    .span_label(expected_span, "expected due to this")
    .span_label(found_span, "found type here")
    .span_suggestion(
        suggestion_span,
        "try wrapping the expression in a block",
        format!("{{ {} }}", snippet),
        Applicability::MachineApplicable,
    )
    .emit();
```

### 5.2 Diagnostic Infrastructure

#### `DiagCtxt` (Diagnostic Context)
- Thread-safe (behind `Lock`)
- Manages error counts, deduplication, stashing
- Handles incremental compilation replay

#### `Diag` (Individual Diagnostic)
- Builder pattern for adding notes, suggestions, labels
- Must be consumed via `emit()`, `cancel()`, or `delay_as_bug()`
- Drop bomb: panics if not consumed

#### `Diagnostic` Trait (Derive Macro)
```rust
#[derive(Diagnostic)]
#[diag(typeck_error mismatched_types)]
pub struct MismatchedTypes<'tcx> {
    #[primary_span]
    pub span: Span,
    #[label(expected_label)]
    pub expected: Ty<'tcx>,
    #[label(found_label)]
    pub found: Ty<'tcx>,
}
```

#### Suggestion Types
- `MachineApplicable`: Can be auto-applied by `cargo fix`
- `MaybeIncorrect`: Might fix the problem
- `Placeholder`: Shows the intended fix but needs review
- `Unspecified`: No specific applicability

### 5.3 Incremental Compilation (Query System)

The query system is the foundation of incremental compilation:

#### Core Concept
```rust
// Every query is a pure function from key to value
query type_of(key: DefId) -> Ty<'tcx> {
    desc { |tcx| "computing the type of `{}`", tcx.def_path_str(key) }
    cache_on_disk
}
```

#### Query Execution Model
1. Check in-memory cache → return if found
2. Check disk cache → load if valid (dep-node is green)
3. Execute provider → compute result, cache it

#### Dependency Graph
- Each query execution creates a node in the dep-graph
- Edges record which queries were accessed during execution
- 128-bit `Fingerprint`s identify nodes across sessions

#### Red-Green Algorithm
```
try_mark_green(node):
    if node is already green: return
    for each dependency of node:
        try_mark_green(dependency)
        if dependency turned red:  // result changed
            re-execute node
            if result changed: mark red
            else: mark green (backdate)
            return
    mark node green (no deps changed)
```

#### Disk Persistence
- Query results are serialized with `StableHash` (not raw `DefId`s)
- Uses `DefPath` instead of `DefId` for cross-session stability
- `Fingerprint`s allow fast comparison without full deserialization

### 5.4 Salsa: The Incremental Computation Framework

Salsa is a library for incremental computation, inspired by rustc's query system:

#### Key Concepts
- **Input structs**: Mutable state from outside (e.g., file contents)
- **Tracked functions**: Memoized computations that record dependencies
- **Tracked structs**: Derived entities with identity
- **Interned structs**: Canonicalized values for structural equality
- **Accumulators**: Side channels for diagnostics/errors

#### Durability System
```rust
// Inputs can have different durability levels
file.set_text(db, contents)
    .with_durability(Durability::Low);  // Changes frequently

// Standard library inputs
stdlib_file.set_text(db, contents)
    .with_durability(Durability::High);  // Rarely changes
```

When a low-durability input changes, queries depending only on high-durability inputs are skipped entirely — no version number comparison needed.

#### Used By
- `rust-analyzer` (Rust LSP)
- Chalk (trait solver prototype)
- Not yet used in rustc itself (too complex to retrofit)

---

## 6. What Makes Rust's Approach Unique

### 6.1 Zero-Cost Abstractions: How the Compiler Achieves This

"Zero-cost" means the abstraction compiles to the same code as the hand-written equivalent:

1. **Monomorphization**: Generic code becomes type-specific code
   - `fn foo<T: Display>(x: T)` → `foo_i32(x)`, `foo_String(x)`, etc.
   - Each instantiation is optimized independently

2. **Inlining**: Small functions are inlined away completely
   - The MIR inliner runs before codegen
   - LLVM inlines further during optimization

3. **Dead code elimination**: Unused abstractions are removed
   - The collector only includes reachable mono items
   - LLVM eliminates dead code after inlining

4. **Layout optimization**: Enums use discriminant tagging efficiently
   - `Option<&T>` is the same size as `&T` (null pointer optimization)
   - Niche optimization uses invalid bit patterns

5. **Iterator fusion**: Iterator chains compile to loops
   - `.map().filter().collect()` → single loop with fused operations
   - No intermediate allocations

### 6.2 LLVM Optimizations vs Rust-Specific Optimizations

**Rust-specific MIR optimizations:**
- `SimplifyCfg`: Remove unreachable blocks, merge blocks
- `Inline`: Heuristic inlining based on cost
- `GVN`: Global Value Numbering (eliminate redundant computations)
- `DataflowConstProp`: Propagate constants using dataflow
- `JumpThreading`: Simplify jump chains
- `CopyPropagation`: Eliminate unnecessary copies
- `DeadStoreElimination`: Remove writes that are never read

**LLVM optimizations:**
- Instruction selection and scheduling
- Loop optimizations (unrolling, vectorization)
- Register allocation
- Constant folding and propagation
- Interprocedural optimizations (LTO)

**Why both?**
- MIR optimizations work on **generic** code (before monomorphization)
- LLVM optimizations work on **monomorphized** code (after type substitution)
- Some optimizations are easier at MIR level (e.g., `simplify_try` — LLVM can't optimize the pattern Rust generates for `?` operator)
- Some optimizations require low-level knowledge (e.g., instruction scheduling — only LLVM knows the target)

### 6.3 Why Rust Chose LLVM Over a Custom Backend

1. **Maturity**: LLVM has 20+ years of optimization and code generation
2. **Target support**: x86, ARM, RISC-V, WASM, and more — all battle-tested
3. **Ecosystem**: Interop with C/C++ codegen, linker infrastructure
4. **Development speed**: Rust team could focus on language features, not backend
5. **Quality**: LLVM generates excellent machine code

**Trade-offs:**
- LLVM is slow (optimization passes take time)
- Rust can't easily add custom LLVM passes
- Some Rust-specific optimizations are blocked by LLVM's IR model

### 6.4 Performance Characteristics of rustc Itself

**Compile time breakdown (typical):**
- Parsing + macro expansion: ~10%
- Type checking + trait resolution: ~30%
- Borrow checking: ~15%
- MIR optimization: ~5%
- Codegen + LLVM: ~40%

**Known bottlenecks:**
- Trait resolution (especially with complex bounds)
- Monomorphization (large generics = many instantiations)
- LLVM optimization (especially at higher opt levels)
- Disk I/O for incremental compilation
- Hashing for dependency tracking

**Optimization strategies:**
- Query-level parallelism (different queries on different threads)
- CGU-level parallelism (different codegen units in parallel LLVM threads)
- Incremental compilation (skip unchanged queries)
- Parallel compilation (experimental, uses `Mutex` instead of `RefCell`)

---

## 7. Lessons for Astra

### 7.1 What Rust Got RIGHT That Astra Should Adopt

#### 1. Multi-IR Architecture
**Lesson**: Each IR should be designed for a specific purpose.

Astra should have:
- **HIR** (or equivalent): For type checking and name resolution
- **MIR** (or equivalent): For borrow checking and optimization
- **Low-level IR**: For code generation

Don't try to do everything with one IR. The separation enables better analysis and optimization at each level.

#### 2. Query-Based Architecture
**Lesson**: Build incremental compilation in from the start.

```
// Instead of pass-based:
fn compile(crate) {
    parse_all();
    type_check_all();
    borrow_check_all();
    codegen_all();
}

// Use query-based:
fn compile(crate) {
    tcx.codegen_crate();  // Drives everything via queries
}
```

Benefits:
- Automatic incremental compilation
- Natural parallelism
- Lazy computation (only compute what's needed)
- Better error recovery

#### 3. Dataflow Analysis Framework
**Lesson**: Build a reusable dataflow framework, not one-off analyses.

```rust
trait Analysis {
    type Domain: JoinSemiLattice;
    fn apply_statement_effect(state: &mut Self::Domain, stmt: &Statement);
    fn apply_terminator_effect(state: &mut Self::Domain, term: &Terminator);
}
```

This framework can be reused for:
- Borrow checking
- Uninitialized variable checking
- Dead code analysis
- Move analysis
- Custom language-specific analyses

#### 4. Rich Diagnostics Infrastructure
**Lesson**: Invest in diagnostics from day one.

```rust
// Derive macros for diagnostic structs
#[derive(Diagnostic)]
#[diag("type mismatch: expected `{expected}`, found `{found}`")]
pub struct TypeError {
    #[primary_span]
    pub span: Span,
    pub expected: String,
    pub found: String,
}
```

This enables:
- Machine-applicable suggestions (`cargo fix`)
- JSON output for IDEs
- Translatable error messages
- Consistent error formatting

#### 5. Interning for Types
**Lesson**: Intern types for fast comparison and reduced memory.

```rust
// Types are interned — comparison is just pointer comparison
let ty1 = tcx.types.i32;
let ty2 = tcx.types.i32;
assert_eq!(ty1, ty2);  // O(1) pointer comparison
```

### 7.2 What Rust Got WRONG or Could Improve

#### 1. Trait Solver Complexity
**Problem**: The trait solver is the most complex part of rustc, with known soundness issues.

**Lesson for Astra**: Design trait resolution to be simpler from the start.
- Consider limiting trait features (no associated types initially?)
- Use a simpler resolution algorithm (even if less expressive)
- Build formal verification into the design (like Chalk attempted)

#### 2. Macro System Hygiene
**Problem**: Proc macros are powerful but have hygiene issues and can generate arbitrary code.

**Lesson for Astra**: Consider a more restricted macro system.
- Declarative macros with clear hygiene rules
- Limited procedural macros (AST-to-AST transforms only?)
- Compile-time execution for metaprogramming

#### 3. Compile Time
**Problem**: Rust compilation is slow, especially for large generic-heavy codebases.

**Lesson for Astra**:
- Design for parallel compilation from the start
- Limit monomorphization depth or offer alternatives
- Consider profile-guided optimization for faster debug builds
- Build in incremental compilation from day one (don't retrofit it)

#### 4. Error Recovery
**Problem**: rustc sometimes stops at the first error in a function, making multi-error reporting difficult.

**Lesson for Astra**: Design error recovery into the type system.
- Use `TyKind::Error` for error propagation
- Continue checking after errors
- Provide "error model" types that satisfy any constraint

#### 5. `unsafe` Complexity
**Problem**: The interaction between `unsafe` and the borrow checker is complex and has subtle bugs.

**Lesson for Astra**: If Astra has unsafe blocks, keep them simple.
- Clearly define what unsafe can bypass
- Consider a separate "trusted" mode rather than inline unsafe blocks
- Build runtime UB detection into the standard library

### 7.3 How Astra Can Simplify What Rust Makes Complex

#### 1. Simpler Lifetime System
Rust's lifetime system is powerful but complex. Astra could:
- Use simpler region-based lifetimes (no higher-ranked lifetimes initially?)
- Provide default lifetime rules that cover 90% of cases
- Make lifetime elision more aggressive

#### 2. Simpler Trait System
- No associated types initially (use separate traits instead)
- No GATs (Generic Associated Types) — these are extremely complex
- Simpler orphan rules (allow more flexibility)
- Consider trait sets instead of trait objects

#### 3. Simpler Error Handling
- `Result` type with `?` operator (like Rust)
- No `panic!` — use `Result` everywhere
- No `unsafe` panics — all errors are recoverable

#### 4. Simpler Memory Model
- No `unsafe` initially — if you need FFI, use a separate mechanism
- No raw pointers — use references and `Box` only
- No unions — use enums instead
- Simpler drop semantics (no drop flags)

### 7.4 Specific Architectural Decisions Astra Can Learn From

#### 1. Query System Design
```rust
// Astra's query system should be designed for parallelism
// from the start, not retrofitted like rustc

// Use Salsa-like architecture
#[salsa::query_group(AstraDb)]
pub trait TypeChecking {
    fn type_of(&self, item: ItemId) -> Ty;
    fn impls_for(&self, trait_id: TraitId) -> Vec<ImplId>;
}
```

#### 2. MIR Design
Rust's MIR is well-designed. Astra should:
- Use a similar CFG structure
- Keep MIR generic (before monomorphization)
- Run borrow checking on MIR, not HIR
- Use MIR for const evaluation

#### 3. Type Representation
```rust
// Rust interns types — Astra should too
// This enables O(1) type comparison and reduces memory

// Rust's TyKind enum covers all type forms:
enum TyKind<'tcx> {
    Bool, Char, Int(IntTy), Float(FloatTy),
    Adt(DefId, &'tcx List<GenericArg<'tcx>>),
    Ref(Region<'tcx>, Ty<'tcx>, Mutability),
    FnDef(DefId, &'tcx List<GenericArg<'tcx>>),
    // ... many more variants
}
```

#### 4. Monomorphization Strategy
- Default to monomorphization (like Rust)
- Offer `dyn Trait` for dynamic dispatch
- Consider partial monomorphization (monomorphize some types, not all)
- Profile-guided monomorphization (only monomorphize hot paths)

#### 5. Incremental Compilation
Build it in from the start:
- Every compilation step is a query
- Queries are memoized and tracked
- Dependency graph is built automatically
- Disk caching is built into the framework

---

## Appendix A: Key Source Locations

| Component | Location |
|-----------|----------|
| AST definitions | `compiler/rustc_ast/src/ast.rs` |
| HIR definitions | `compiler/rustc_hir/src/hir.rs` |
| MIR definitions | `compiler/rustc_middle/src/mir/syntax.rs` |
| THIR definitions | `compiler/rustc_mir_build/src/thir/` |
| MIR optimizations | `compiler/rustc_mir_transform/src/lib.rs` |
| Borrow checker | `compiler/rustc_borrowck/src/` |
| Dataflow framework | `compiler/rustc_mir_dataflow/src/` |
| Type inference | `compiler/rustc_infer/src/infer/` |
| Trait resolution | `compiler/rustc_trait_selection/src/traits/` |
| Codegen | `compiler/rustc_codegen_ssa/src/mir/` |
| LLVM backend | `compiler/rustc_codegen_llvm/src/` |
| Diagnostics | `compiler/rustc_errors/src/` |
| Query system | `compiler/rustc_middle/src/query/` |
| Monomorphization | `compiler/rustc_monomorphize/src/` |

## Appendix B: Key Data Types

```rust
// The central context
struct TyCtxt<'tcx> {
    gcx: &'tcx GlobalCtxt<'tcx>,
}

// A function body in MIR
struct Body<'tcx> {
    basic_blocks: IndexVec<BasicBlock, BasicBlockData<'tcx>>,
    local_decls: IndexVec<Local, LocalDecl<'tcx>>,
    // ...
}

// A basic block in MIR
struct BasicBlockData<'tcx> {
    statements: Vec<Statement<'tcx>>,
    terminator: Terminator<'tcx>,
    // ...
}

// A type in the compiler
type Ty<'tcx> = &'tcx TyS<'tcx>;

// A region (lifetime)
type Region<'tcx> = &'tcx RegionKind<'tcx>;

// An obligation to prove
struct Obligation<'tcx, T> {
    cause: ObligationCause<'tcx>,
    param_env: ParamEnv<'tcx>,
    predicate: T,
    recursion_depth: usize,
}
```

---

*This report was compiled from the Rust Compiler Development Guide, rustc source code, and technical blog posts. It represents the architecture as of late 2026.*
