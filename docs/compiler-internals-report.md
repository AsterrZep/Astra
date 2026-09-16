# Internal Architecture of GCC and Clang/LLVM Compilers

## Research Report for Astra Language Design

---

# 1. GCC Architecture

## 1.1 The GCC Pipeline

GCC uses a multi-stage compilation pipeline with three distinct intermediate representations:

```
Source Code
    │
    ▼
Frontend (Language-specific parsing)
    │
    ▼
GENERIC (Language-independent AST)
    │
    ▼
GIMPLE (Simplified three-address code)
    │
    ▼
Tree SSA Optimizations (High-level, target-independent)
    │
    ▼
RTL (Register Transfer Language)
    │
    ▼
RTL Optimizations (Low-level, target-dependent)
    │
    ▼
Machine Code
```

### Key Design Points:

- **Three IRs, not one**: GENERIC provides language-independence, GIMPLE enables high-level optimizations, RTL handles target-specific code generation
- **Progressive lowering**: Each stage lowers the abstraction level, trading expressiveness for optimization accessibility
- **Target independence until late**: GIMPLE optimizations are completely target-independent; RTL is where target-specific behavior enters

## 1.2 GENERIC: Language-Independent AST

GENERIC is the common tree representation that all GCC frontends produce. It serves as the interface between parsing and optimization.

### Purpose:
- Provide a language-independent way to represent entire functions in tree form
- Allow frontends to emit language-specific tree codes while providing hooks for conversion to GIMPLE

### Key Characteristics:
- Stored in `DECL_SAVED_TREE` for each function
- Uses GCC's `tree` data structure (a pointer type with many variant forms)
- Contains two universal fields: `TREE_CHAIN` (singly-linked list) and `TREE_TYPE` (type information)
- Language-specific constructs are removed via the gimplifier

### Example Tree Structure:
```c
int x = 5 + 3;
// Becomes:
// BIND_EXPR
//   DECLS: x
//   BODY: MODIFY_EXPR
//           DECL: x
//           RHS: PLUS_EXPR
//                 INTEGER_CST: 5
//                 INTEGER_CST: 3
```

### Limitations of GENERIC:
- Cannot represent all control flow cleanly
- Side effects can appear anywhere
- No constraint on expression complexity (arbitrarily nested)

## 1.3 GIMPLE: Simplified Three-Address Code

GIMPLE is the primary IR for high-level optimizations. Derived from the SIMPLE representation from McGill University's McCAT compiler project.

### Core Constraints:
1. **Maximum 3 operands per expression** (except function calls)
2. **No control flow structures** within expressions
3. **Side effects only on RHS of assignments**
4. **Temporary variables** for intermediate values
5. **No nested expressions** - everything is flattened

### GIMPLE Statement Types:

```gimple
// Assignment
x_1 = 5 + 3;

// Function call
result_2 = foo(arg1, arg2);

// Control flow (lowered from structured forms)
if (cond_3) goto <bb 3>; else goto <bb 4>;

// PHI nodes (for SSA form)
x_4 = PHI <x_1(2), x_2(3)>;

// Memory operations (explicit)
*ptr_5 = value_6;
value_7 = *ptr_5;
```

### The Gimplification Process:
- Entry point: `gimplify_function_tree()` in `gimplify.cc`
- Main workhorse: `gimplify_expr()`
- Language frontends provide `lang_hooks.gimplify_expr` callback
- Returns `GS_UNHANDLED`, `GS_OK`, `GS_ALL_DONE`, or `GS_ERROR`
- Works recursively, replacing complex statements with simple sequences

### GIMPLE Tuple Representation:
Modern GCC uses a tuple-based representation for GIMPLE statements:
```c
struct gimple_statement_base {
  enum gimple_code code;
  unsigned subcode;
  unsigned int uid;
  location_t locus;
  // ...
};
```

### Block Scopes:
- Represented using `BIND_EXPR`
- Variables collected in `BIND_EXPR_VARS`
- Runtime initialization moved from `DECL_INITIAL` to controlled block
- Variable-length arrays require splitting blocks

### Loops:
- Originally expressed as `LOOP_EXPR` (infinite loop)
- Conditions, break, continue converted to explicit gotos
- Future loop optimizations may use `DO_LOOP_EXPR`

## 1.4 RTL (Register Transfer Language)

RTL is the low-level, target-specific representation. It exists in two forms:

### MD-RTL (Machine Description RTL):
- Human-readable form used at development time
- Specifies target instruction semantics
- Lives in `.md` files

### IR-RTL (Intermediate Representation RTL):
- Machine-readable form used at runtime
- Generated from MD-RTL at build time
- Represents the actual program being compiled

### RTL Structure:
RTL expressions are Lisp-like S-expressions:
```lisp
;; Register assignment
(set (reg:SI 0) (const_int 5))

;; Memory access
(set (reg:DI 1) (mem:DI (reg:DI 2)))

;; Arithmetic
(set (reg:SI 3) (plus:SI (reg:SI 0) (reg:SI 1)))

;; Conditional branch
(set (pc)
    (if_then_else (gt (reg:SI 0) (const_int 0))
        (label_ref (pc))
        (pc)))
```

### RTL Features:
- **Untyped** - no type information (unlike GIMPLE)
- **Explicit register usage** - maps to machine registers
- **Address modes** - supports complex addressing
- **Condition codes** - maps to processor flags
- **Machine-specific** - each target defines its own patterns

### RTL Generation:
Source files: `stmt.cc`, `calls.cc`, `expr.cc`, `explow.cc`, `expmed.cc`, `function.cc`, `optabs.cc`, `emit-rtl.cc`

Generated files from machine description:
- `insn-emit.cc` - instruction emission
- `insn-flags.h` - available standard names
- `insn-codes.h` - pattern codes

## 1.5 The Pass Manager

### Pass Declaration:
Every optimization pass is declared as an instance of `struct tree_opt_pass`:
```c
struct tree_opt_pass {
  const char *name;
  unsigned int (*execute)(function *);
  // Properties required, provided, destroyed
  // Gate function (enable/disable)
  // TODO flags
};
```

### Pass Scheduling:
- Controlled by `init_tree_optimization_passes()` in `tree-optimize.cc`
- Uses `NEXT_PASS()` macro for sequencing
- `DUP_PASS()` for passes that need multiple invocations
- Properties system: passes declare what they need and what they destroy

### Property Flags:
- `PROP_cfg` - control flow graph is available
- `PROP_ssa` - SSA form is available
- `PROP_loops` - loop structures exist
- `PROP_cfg_layout` - relaxed CFG layout

### Optimization Levels:
- `-O0`: Minimal optimization
- `-O1`: Basic optimizations enabled
- `-O2`: Full optimizations
- `-O3`: Aggressive optimizations (may increase code size)
- `-Os`: Optimize for size
- `-Ofast`: Fast math + `-O3`

## 1.6 Tree SSA: GCC's SSA-Based IR

### SSA Form Implementation:
Based on: R. Cytron, J. Ferrante, B. Rosen, M. Wegman, K. Zadeck (1991)

### Key Data Structures:

**SSA_NAME nodes**:
```c
// Represents a version of a variable
// Contains version number and defining statement
tree ssa_name = build_ssa_name(type, def_stmt);
```

**PHI nodes**:
```c
// Merge point for control flow
gphi *phi = create_phi_node(var, bb);
```

### SSA Construction Process:
1. **Find variable references** (`tree-dfa.cc`)
2. **Build control flow graph** (`tree-cfg.cc`)
3. **Compute dominance frontiers**
4. **Insert PHI nodes** at iterated dominance frontiers
5. **Rename variables** to SSA form (`tree-into-ssa.cc`)

### SSA Update:
When transformations invalidate SSA:
1. Identify names needing update
2. Register replacement mappings
3. Call `update_ssa()` with appropriate TODO flags

### SSA TODO Flags:
- `TODO_update_ssa` - Full SSA update with PHI insertion
- `TODO_update_ssa_no_phi` - Skip PHI insertion
- `TODO_update_ssa_full_phi` - Insert all possible PHIs
- `TODO_update_ssa_only_virtuals` - Only update virtual names

### Key Optimization Passes on GIMPLE SSA:

1. **CCP (Sparse Conditional Constant Propagation)**
   - Finds constants and unreachable code
   - Efficient sparse formulation

2. **PRE (Partial Redundancy Elimination)**
   - Eliminates redundant computations
   - Makes partially redundant expressions fully redundant
   - Implements GVN-PRE

3. **DCE (Dead Code Elimination)**
   - Removes statements with no effect on output
   - Enabled at `-O1` and above

4. **Dominator-based Optimizations** (`tree-ssa-dom.cc`)
   - Copy propagation
   - Constant propagation
   - Redundancy elimination via value numbering
   - Jump threading

5. **GVN (Global Value Numbering)** (`tree-ssa-sccvn.cc`)
   - Computes value numbers for expressions
   - Foundation for FRE and PRE

6. **VRP (Value Range Propagation)**
   - Determines value ranges for variables
   - Enables branch elimination

7. **Scalar Replacement of Aggregates (SRA)**
   - Converts structure references to scalar references
   - Enables standard scalar optimizations

### Alias Analysis in GIMPLE SSA:
Two components:
1. **Virtual SSA web** - ties conflicting memory accesses
2. **Alias oracle** - disambiguates explicit and implicit memory references

Type-based alias analysis (TBAA) is frontend-dependent but supported by `alias.cc`.

---

# 2. Clang/LLVM Architecture

## 2.1 The Clang Frontend

```
Source Code
    │
    ▼
Preprocessor (#include, macros, directives)
    │
    ▼
Lexer (Tokenization)
    │
    ▼
Parser (Recursive descent)
    │
    ▼
Sema (Semantic analysis, AST construction)
    │
    ▼
AST (Abstract Syntax Tree)
    │
    ▼
CodeGen (AST → LLVM IR)
```

### Preprocessor:
- Handles `#include`, `#define`, `#ifdef`
- Token-based macro expansion
- Supports both function-like and object-like macros

### Lexer:
- Produces tokens (not AST nodes)
- Does NOT distinguish between types and identifiers
- All identifiers marked as `tok::identifier`

### Parser (Recursive Descent):
- Hand-written, NOT generated by Bison/Yacc
- No "lexer hack" - information flows one direction
- Uses `Sema` module for semantic queries

### Sema (Semantic Analysis):
- Maintains symbol table
- Performs name lookup
- Type checking
- AST construction
- Called from parser via "actions" interface

### The Type/Name Ambiguity Solution:
Clang handles C/C++'s ambiguity between types and variables without a lexer hack:

1. Parser encounters `tok::identifier`
2. Parser asks Sema: "Is this a type?" via `Actions.getTypeName`
3. Sema performs name lookup in nested scope stack
4. If type: parser continues as declaration specifier
5. If not type: parser continues as expression

### Annotation Tokens:
To avoid repeated lookups during backtracking:
- First discovery: identifier → `tok::annot_typename`
- Subsequent encounters: annotation token recognized immediately

### Error Recovery:
Clang's parser has sophisticated error recovery:
- `SkipUntil()` function skips tokens to recovery points
- Balanced delimiter tracking (parens, brackets, braces)
- `TentativeParsingAction` for trying alternative parses
- Fix-it hints for common errors

## 2.2 How Clang's AST Differs from GCC's GENERIC

### Clang AST:
- **Self-contained**: No external data structures needed
- **Typed**: Every node has complete type information
- **Persistent**: AST nodes survive the entire compilation
- **Typed pointers**: `Expr*`, `Stmt*`, `Decl*` are distinct types

### GCC GENERIC:
- **Uses tree nodes**: Single `tree` type for everything
- **Not self-contained**: References back to source-level trees
- **Not typed**: RTL is untyped
- **Transient**: Trees are lowered to GIMPLE then discarded

### Key Differences:

| Feature | Clang AST | GCC GENERIC |
|---------|-----------|-------------|
| Self-contained | Yes | No |
| Type information | Complete | Partial |
| Persistence | Full compilation | Transient |
| Textual form | Clang AST dump | No standard form |
| Serialization | Complete round-trip | Limited |

### Why This Matters:
- Clang AST can be serialized to disk and reloaded
- Enables tools like clangd, clang-tidy, libtooling
- No need for additional data structures for tools

## 2.3 LLVM IR: The Core Intermediate Representation

### Design Philosophy:
LLVM IR is designed to be:
1. **Low-level** - close to machine code
2. **Strongly typed** - explicit type information
3. **SSA-based** - Static Single Assignment form
4. **Target-independent** - no machine-specific details
5. **Self-contained** - complete program representation
6. **Shippable** - can be stored and executed

### Three Forms of LLVM IR:

1. **In-memory form**: C++ data structures
2. **Bitcode (`.bc`)**: Compact binary format
3. **Assembly (`.ll`)**: Human-readable text

### LLVM IR Structure:

```llvm
; Module
@global_var = global i32 42

; Function definition
define i32 @add(i32 %a, i32 %b) {
entry:
  %result = add i32 %a, %b
  ret i32 %result
}
```

### Basic Blocks:
```llvm
define void @example(i32 %x) {
entry:
  %cmp = icmp sgt i32 %x, 0
  br i1 %cmp, label %then, label %else

then:
  ; ...
  br label %merge

else:
  ; ...
  br label %merge

merge:
  ret void
}
```

### Instructions:
LLVM uses three-address code:
```llvm
%result = add i32 %a, %b      ; Arithmetic
%ptr = getelementptr i32, i32* %base, i32 %idx  ; Address calculation
%val = load i32, i32* %ptr     ; Memory load
store i32 %val, i32* %ptr      ; Memory store
%cond = icmp eq i32 %a, %b     ; Comparison
br i1 %cond, label %T, label %F  ; Branch
```

### PHI Nodes:
```llvm
%x = phi i32 [ %a, %bb1 ], [ %b, %bb2 ]
```

### Type System:
- **Primitive types**: `i1`, `i8`, `i16`, `i32`, `i64`, `float`, `double`
- **Derived types**: pointers, arrays, vectors, structs
- **Function types**: `i32 (i32, i32)*`
- **Void type**: `void`

### Memory Model:
- **Stack**: `alloca` instruction (promoted by `mem2reg`)
- **Heap**: Via function calls (`malloc`, etc.)
- **Globals**: `@` prefixed global variables
- **Explicit load/store**: All memory access is explicit

### Key Properties:
- **Infinite virtual registers**: No physical register constraints
- **No addressing modes**: Simple RISC-like operations
- **No condition codes**: Explicit comparisons
- **No hardware details**: Target-independent

## 2.4 LLVM Pass Infrastructure

### New Pass Manager (LLVM 13+):

**IR Hierarchy:**
```
Module → (CGSCC →) Function → Loop
```

**Pass Types:**
- **Module passes**: Operate on entire module
- **CGSCC passes**: Operate on strongly connected components of call graph
- **Function passes**: Operate on individual functions
- **Loop passes**: Operate on loops

**Analysis Manager:**
- Separate from pass management
- Lazily computes and caches analyses
- Handles invalidation

```cpp
PassBuilder PB;
PB.registerModuleAnalyses(MAM);
PB.registerCGSCCAnalyses(CGAM);
PB.registerFunctionAnalyses(FAM);
PB.registerLoopAnalyses(LAM);
PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

ModulePassManager MPM = PB.buildPerModuleDefaultPipeline(OptimizationLevel::O2);
MPM.run(MyModule, MAM);
```

**Pass Composition:**
```cpp
// Function pass wrapped in module adaptor
ModulePassManager MPM;
MPM.addPass(createModuleToFunctionPassAdaptor(MyFunctionPass()));

// Loop pass wrapped in function adaptor
FunctionPassManager FPM;
FPM.addPass(createFunctionToLoopPassAdaptor(MyLoopPass()));
```

**Analysis Caching:**
- Analyses computed on-demand
- Cached until invalidated
- `PreservedAnalyses` return value declares what's still valid

**Invalidation:**
```cpp
PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM) {
  // ... transformation ...
  PreservedAnalyses PA;
  PA.preserve<DominatorTreeAnalysis>();
  // Other analyses invalidated
  return PA;
}
```

### Legacy Pass Manager:
- Still used for codegen pipeline
- Passes scheduled explicitly
- No analysis caching
- Being deprecated for middle-end

### Pass Injection:
```cpp
PassBuilder PB;
PB.registerPipelineStartEPCallback(
    [&](ModulePassManager &MPM, PassBuilder::OptimizationLevel Level) {
      MPM.addPass(FooPass());
    });
```

## 2.5 The MC Layer

The MC (Machine Code) layer handles assembly and object file generation:

### Components:
- **MCParser**: Parses assembly text
- **MCStreamer**: Emits object file sections
- **MCCodeEmitter**: Encodes instructions
- **MCAsmBackend**: Handles target-specific assembly
- **MCInstPrinter**: Prints assembly text

### Assembly Emission:
```cpp
// Create MCStreamer for target format
autoStreamer = Target.createMCStreamer(Out, DwoOut, FileType, Ctx);

// Emit instructions
Streamer->emitInstruction(MCInst, STI);
```

### Object File Generation:
- Handles DWARF debug information
- Manages relocations
- Produces ELF, COFF, Mach-O formats

## 2.6 How LLVM Enables New Languages

### The Key Insight:
LLVM IR is low-level enough to represent any language, but high-level enough to preserve optimization information.

### Language Integration Pattern:
```
Language Source
    │
    ▼
Frontend (Language-specific)
    │
    ▼
LLVM IR (Universal intermediate form)
    │
    ▼
LLVM Optimizer
    │
    ▼
Target-specific code generation
```

### Examples:

**Rust:**
- `rustc` parses Rust → HIR → MIR → LLVM IR
- Uses LLVM for all optimizations
- Leverages LLVM's type system for safety

**Swift:**
- Swift AST → SIL (Swift Intermediate Language) → LLVM IR
- SIL enables Swift-specific optimizations
- LLVM handles low-level optimizations

**Julia:**
- Julia AST → Julia IR → LLVM IR
- Type inference at Julia level
- LLVM handles code generation

### Benefits:
1. **No need to implement optimizations**: LLVM provides hundreds
2. **Cross-platform for free**: LLVM supports many targets
3. **JIT compilation**: LLVM's MCJIT or ORC JIT
4. **LTO support**: Link-time optimization built-in
5. **Debug information**: DWARF generation handled

---

# 3. LLVM Optimization Passes

## 3.1 Key Optimization Passes

### mem2reg:
**Purpose**: Promotes stack allocations to SSA registers

**How it works**:
1. Find `alloca` instructions in entry block
2. Check if address is never taken
3. Insert PHI nodes at dominance frontiers
4. Replace loads/stores with register copies

**Why it matters**:
- Simplifies IR for other passes
- Enables SSA-based optimizations
- Clang uses this for local mutable variables

```llvm
; Before mem2reg
%x = alloca i32
store i32 5, i32* %x
%val = load i32, i32* %x

; After mem2reg
%val = i32 5  ; Direct SSA value
```

### SROA (Scalar Replacement of Aggregates):
**Purpose**: Decomposes aggregates into scalar values

**How it works**:
1. Analyze aggregate usage
2. Split into independent scalar parts
3. Replace aggregate loads/stores with scalar operations

**Benefits**:
- Enables scalar optimizations on struct fields
- Reduces memory traffic
- Improves register allocation

### GVN (Global Value Numbering):
**Purpose**: Eliminates redundant computations

**How it works**:
1. Assign value numbers to expressions
2. Expressions with same operands and operation get same number
3. Replace redundant computations with existing values

**Example**:
```llvm
%a = add i32 %x, %y
%b = add i32 %x, %y  ; Same as %a
; GVN: %b → %a
```

### LICM (Loop Invariant Code Motion):
**Purpose**: Moves loop-invariant code out of loops

**How it works**:
1. Identify expressions that don't change across iterations
2. Move them to loop preheader
3. Replace with references to moved computation

**Example**:
```llvm
loop:
  %x = load i32, i32* @global  ; Loop invariant
  ; ... use %x ...
  br label %loop

; After LICM:
preheader:
  %x = load i32, i32* @global  ; Moved here
  br label %loop
loop:
  ; ... use %x ...
  br label %loop
```

### Loop Unrolling:
**Purpose**: Replicates loop body to reduce branch overhead

**Types**:
- **Full unrolling**: Complete elimination for small trip counts
- **Partial unrolling**: Replicate body N times
- **Runtime unrolling**: Use trip count to decide

### Vectorization (SLP and Loop Vectorization):
**Purpose**: Use SIMD instructions for data parallelism

**Loop Vectorization**:
```llvm
; Scalar version
for (i = 0; i < n; i++)
  a[i] = b[i] + c[i];

; Vectorized (4-wide)
for (i = 0; i < n; i += 4)
  a[i:i+3] = b[i:i+3] + c[i:i+3];
```

**SLP (Superword-Level Parallelism)**:
- Finds independent scalar operations
- Packs them into vector operations
- Works within basic blocks

### Inlining:
**Purpose**: Replace function calls with function body

**Heuristics**:
- Function size
- Call frequency
- Callee benefit
- Caller size increase

**CGSCC Pass**: Processes call graph bottom-up

## 3.2 How SSA Enables These Optimizations

### Properties of SSA:

1. **Single definition**: Each variable defined exactly once
2. **Def-use chains**: Direct links from definition to uses
3. **Use-def chains**: Direct links from use to definition
4. **No aliases**: Scalar SSA values cannot alias

### Optimization Benefits:

**Constant Propagation**:
```llvm
%x = 5
%y = add i32 %x, 3  ; Constant folding
; Result: %y = 8
```

**Dead Code Elimination**:
```llvm
%x = add i32 1, 2  ; Result unused
; Eliminate entirely
```

**Copy Propagation**:
```llvm
%a = i32 5
%b = %a  ; Copy
%c = add i32 %b, 1  ; Use %a directly
```

### PHI Nodes and Control Flow:
```llvm
if (cond) {
  %x = 5;
} else {
  %x = 10;
}
// After SSA:
%x = phi i32 [ 5, %if ], [ 10, %else ]
```

### Sparse Analysis:
SSA enables sparse dataflow analysis:
- No need for bit vectors
- Follow def-use chains directly
- O(number of uses) instead of O(n)

## 3.3 Pass Manager: Legacy vs New PM

### Legacy Pass Manager:
- Passes scheduled explicitly
- Passes run sequentially
- Analysis results stored in pass objects
- No automatic invalidation

### New Pass Manager:
- Passes composed via adaptors
- Analysis manager separate from passes
- Lazy analysis computation
- Explicit invalidation via `PreservedAnalyses`
- Better cache locality

### Migration Status:
- **Middle-end**: New PM is default (LLVM 13+)
- **Codegen**: Still uses legacy PM
- **Ongoing**: Migration efforts for codegen

## 3.4 Link-Time Optimization (LTO)

### How LTO Works:
1. **Compile time**: Generate LLVM bitcode instead of native code
2. **Link time**: Linker loads all bitcode modules
3. **Optimization**: Run optimizations on combined module
4. **Code generation**: Generate optimized native code

### Benefits:
- Cross-module inlining
- Interprocedural constant propagation
- Dead function elimination
- Whole-program devirtualization

### LLVM LTO Implementation:
```bash
# Compile to bitcode
clang -c file.c -o file.bc

# Link with LTO
clang -flto file1.bc file2.bc -o output
```

### Object File Format:
- Bitcode stored in `.llvmbc` section of ELF/COFF/Mach-O
- Native object files contain both bitcode and native code
- Linker uses bitcode for optimization, native code as fallback

## 3.5 ThinLTO

### Problem with Full LTO:
- Loads all bitcode into memory
- Single-threaded optimization
- High memory usage for large projects

### ThinLTO Solution:
1. **Compile time**: Generate bitcode with summary information
2. **Link time**: Build call graph from summaries
3. **Parallel optimization**: Optimize modules independently
4. **Importing**: Import functions from other modules as needed
5. **Code generation**: Generate native code in parallel

### Summary Information:
- Function declarations and definitions
- Type information
- Call graph edges
- Global variable references

### Benefits:
- Parallel compilation
- Lower memory usage
- Incremental optimization
- Cross-module inlining (with importing)

### Comparison:
| Feature | Full LTO | ThinLTO |
|---------|----------|---------|
| Memory | High | Low |
| Parallelism | No | Yes |
| Optimization quality | Best | Very good |
| Compile time | Slow | Fast |

---

# 4. C and C++ Language Specifics

## 4.1 C's Simple Type System

### Mapping to Compiler Internals:
- **Primitive types**: Direct mapping to machine types
- **Pointers**: Single address space, simple indirection
- **Arrays**: Contiguous memory, pointer arithmetic
- **Structs**: Sequential layout, padding for alignment
- **Unions**: Overlapping storage

### Type Conversion:
- Implicit conversions defined by standard
- Integer promotion rules
- Usual arithmetic conversions
- No runtime type checking

### Memory Model:
- **Flat memory**: No segmentation (mostly)
- **Strict aliasing**: Type-based alias analysis
- **Object lifetime**: Storage duration rules

## 4.2 C++ Template Compilation

### Two-Phase Name Lookup:

**Phase 1 (Definition Time)**:
- Non-dependent names looked up immediately
- Syntax checked
- Non-dependent bindings locked

**Phase 2 (Instantiation Time)**:
- Dependent names looked up
- Template arguments substituted
- Full semantic analysis

**Dependent vs Non-Dependent Names**:
```cpp
template<typename T>
void f(T x) {
  g(42);      // Non-dependent: bound at phase 1
  x.bar();    // Dependent: bound at phase 2
  T::value;   // Dependent: bound at phase 2
}
```

### Monomorphization:
For each unique set of template arguments, compiler generates separate code:

```cpp
template<typename T>
T max(T a, T b) { return a > b ? a : b; }

max(1, 2);      // Generates: int max(int, int)
max(1.0, 2.0);  // Generates: double max(double, double)
```

### Implementation Strategy:
- **Greedy instantiation**: Generate all specializations encountered
- **Weak linkage (COMDAT)**: Each TU emits weak symbols
- **Linker deduplication**: Selects one copy per specialization

### Template Bloat:
- Each instantiation is a separate function
- Can lead to code size explosion
- Mitigation: Export/hidden visibility, selective instantiation

### Two-Phase Lookup Challenges:
- C++ standard mandates it
- MSVC historically didn't implement it
- Clang implemented from the start
- GCC implemented since version 3.4

## 4.3 Name Mangling in C++

### Why Mangling Exists:
- C++ has overloading, templates, namespaces
- C linker uses simple name strings
- Need to encode additional information in symbol names

### Itanium C++ ABI Mangling:

**Basic Structure**:
```
_Z           # Mangling prefix
  <name>     # Function/variable name
    N        # Nested name
      <scope>  # Scope qualifier
      <name>   # Unqualified name
    E        # End nested name
  <type>     # Function type (for functions)
```

**Examples**:
```cpp
// C++ code
void foo(int);
void foo(double);
namespace N { void bar(); }

// Mangled names
_Z3fooi        # foo(int)
_Z3food        # foo(double)
_ZN1N3barEv    # N::bar()
```

**Template Mangling**:
```cpp
template<typename T>
void f(T);

f<int>();      // _Z1fIiEvT_
f<double>();   // _Z1fIdEvT_
```

### Mangling Rules:
1. **Prefix**: `_Z` for all mangled names
2. **Nested names**: `N...E` encloses scope
3. **Substitution**: `S0_`, `S1_` for repeated types
4. **Template args**: `I...E` encloses template arguments
5. **CV-qualifiers**: `K` for const, `r` for volatile

### Implementation:
- Clang: `ItaniumMangle.cpp`
- GCC: `cp/mangle.c`
- Both follow Itanium ABI

## 4.4 C++ Exceptions: Zero-Cost Implementation

### The Itanium ABI Exception Model:

**Normal Execution Cost**: ~0 instructions
- No exception handling code in normal path
- Tables describe handlers separately

**Exception Cost**: Expensive
- Walk stack using tables
- Search for matching handler
- Unwind and transfer control

### Exception Tables:

**LSDA (Language-Specific Data Area)**:
```
LSDA Header:
  - LPStart: Landing pad start pointer
  - TType: Type table pointer

Call Site Table:
  - Start: Call site start offset
  - Length: Call site range
  - LandingPad: Landing pad offset
  - Action: Action record offset

Action Table:
  - TTypeFilter: Index into type table
  - NextRecord: Offset to next action

Type Table:
  - type_info pointers (encoded)
```

### Unwinding Process:

1. **Throw**: `__cxa_throw` allocates exception object
2. **Search phase**: Walk stack looking for handler
   - For each frame, check LSDA
   - Call personality function
   - Return `URC_HANDLER_FOUND` or `URC_CONTINUE_UNWIND`
3. **Cleanup phase**: Unwind stack, run cleanups
4. **Transfer**: Jump to landing pad

### Landing Pads:
```cpp
try {
  // Code that might throw
} catch (const std::exception& e) {
  // Landing pad code
}
```

LLVM IR:
```llvm
invoke void @may_throw()
  to label %cont unwind label %lpad

lpad:
  %exn = landingpad { i8*, i32 }
    catch i8* @_ZTISt9exception  ; type_info for exception
  ; Handle exception
```

### Personality Functions:
- `__gxx_personality_v0`: C++ personality
- Called during unwind to check if handler matches
- Language-specific matching logic

## 4.5 C++ RTTI Implementation

### type_info Structure:
```cpp
class type_info {
  virtual ~type_info();
  const char* name() const;
  bool before(const type_info&) const;
  bool operator==(const type_info&) const;
};
```

### VTable Layout:
For polymorphic types, vtable contains:
```
vtable[-2]: Offset from most-derived object
vtable[-1]: Pointer to type_info (or offset to it)
vtable[0]:  Virtual function pointer
vtable[1]:  Virtual function pointer
...
```

### Type Hierarchy Representation:

**Simple classes**: `__si_class_type_info`
- Single non-virtual base
- Direct base type_info pointer

**Complex classes**: `__vmi_class_type_info`
- Multiple/virtual inheritance
- Array of base class descriptions:
  - Type pointer
  - Offset
  - Flags (virtual, public)

### dynamic_cast Implementation:
1. Get dynamic type from vtable
2. Compare with target type
3. If same: adjust pointer directly
4. If different: traverse hierarchy
5. Check access control

### typeid Operator:
- For polymorphic types: read type_info from vtable
- For non-polymorphic: compile-time known
- Returns const reference to type_info

---

# 5. Parser Technology

## 5.1 Recursive Descent (Clang) vs Bison (GCC)

### Recursive Descent:
**Advantages**:
- Hand-written, easy to customize
- Natural error recovery
- Can handle context-sensitive grammar
- No lexer hack needed
- Clean, readable code

**Implementation in Clang**:
```cpp
// Parser method per grammar rule
ExprResult Parser::ParseExpression() {
  return ParseAssignmentExpression();
}

ExprResult Parser::ParseAssignmentExpression() {
  ExprResult LHS = ParseConditionalExpression();
  if (Tok.is(tok::equal)) {
    // Parse assignment
  }
  return LHS;
}
```

### Bison (LALR(1)):
**Advantages**:
- Automatic parser generation
- Well-understood theory
- Efficient parsing

**Disadvantages**:
- Requires lexer hack for C/C++
- Poor error recovery
- Hard to customize
- Grammar conflicts

### GCC's Approach:
- Originally used Bison
- Now uses hand-written parser for C++
- Still uses Bison for some languages

### Why Clang Chose Recursive Descent:
1. C++ grammar is context-sensitive
2. Need for excellent error recovery
3. Natural integration with Sema
4. No lexer hack

## 5.2 Error Recovery in Production Parsers

### Clang's Error Recovery:

**SkipUntil Function**:
```cpp
bool Parser::SkipUntil(ArrayRef<tok::TokenKind> Toks, SkipUntilFlags Flags) {
  // Skip tokens until finding target
  // Handles balanced delimiters
  // Reports errors along the way
}
```

**Strategies**:
1. **Synchronization points**: Semicolons, braces, EOF
2. **Balanced delimiter tracking**: Skip nested parens/brackets/braces
3. **Heuristic recovery**: Look for likely statement boundaries
4. **Fix-it hints**: Suggest corrections

**Example**:
```cpp
// User writes:
int x = (a + b;  // Missing closing paren

// Clang suggests:
int x = (a + b);  // Insert ')'
```

### GCC's Error Recovery:
- Less sophisticated historically
- Improving with recent versions
- `-ferror-limit` controls error count

## 5.3 The Most Vexing Parse

### Problem:
```cpp
Widget w(Stream());  // Function declaration, not object creation!
```

### C++ Rule:
Anything that can be parsed as a function declaration is a function declaration.

### Examples:
```cpp
// These are all function declarations:
Widget w(int);           // Function taking int
Widget w(int());         // Function taking function
Widget w(int(*)());      // Function taking function pointer

// These are object creations:
Widget w((int()));       // Extra parens disambiguate
Widget w{int()};         // Brace initialization
auto w = Widget(int());  // Assignment form
```

### How Parsers Handle It:
- Clang's parser tries declaration first
- If it looks like function declaration, it is
- `-Wvexing-parse` warning in Clang

### Solution for Language Designers:
- Use brace initialization `{}` instead of `()`
- Or: Always require explicit `new`/`make` syntax
- Or: Different syntax for object creation vs function declaration

## 5.4 Template Parsing Challenges in C++

### The `template` Keyword:
```cpp
// Problem:
t.foo<int>();  // Is foo a template?

// Solution:
t.template foo<int>();  // Explicit template keyword
```

### Dependent Names:
```cpp
template<typename T>
void f(T t) {
  T::foo();      // Error: need typename
  typename T::foo();  // OK
  t.template bar<int>();  // OK
}
```

### Template Argument Lists:
```cpp
// Ambiguity:
a < b > c;  // Comparison or template?

// Context determines meaning:
T::template foo<a<b>>();  // Template nested in template
```

### Two-Phase Parsing:
1. **Phase 1**: Parse template definition
   - Check syntax
   - Resolve non-dependent names
   - Mark dependent names
2. **Phase 2**: At instantiation
   - Resolve dependent names
   - Full semantic analysis

---

# 6. Code Generation

## 6.1 Instruction Selection

### SelectionDAG Approach:
1. **DAG Construction**: Convert basic block to DAG
2. **Legalization**: Make operations legal for target
3. **Instruction Selection**: Match patterns to instructions
4. **Scheduling**: Order instructions for pipeline
5. **Register Allocation**: Assign physical registers
6. **Emission**: Generate machine code

### Pattern Matching:
```tablegen
// In target .td file
def : Pat<(addi32:$src1, $src2),
          (ADDrr $src1, $src2)>;
```

### GlobalISel (Newer Approach):
1. **IRTranslator**: Lower LLVM IR to generic MIR
2. **Legalizer**: Make operations legal
3. **RegBankSelect**: Assign register banks
4. **InstructionSelect**: Choose final opcodes

### Advantages of GlobalISel:
- Faster compilation
- Better debuggability
- Works on whole function
- Easier to extend

## 6.2 Register Allocation

### Graph Coloring:
**Chaitin-Briggs Algorithm**:
1. Build interference graph
2. Simplify: Remove low-degree nodes
3. Select: Color nodes
4. Spill: If can't color, spill to stack

**Advantages**: Optimal coloring when graph is colorable
**Disadvantages**: Expensive graph construction

### Linear Scan:
1. Compute live intervals
2. Sort by start point
3. Scan linearly, assigning registers
4. Spill when no register available

**Advantages**: Fast O(n) algorithm
**Disadvantages**: Suboptimal in some cases

### LLVM's Greedy Allocator:
**Algorithm**:
1. Priority queue of live ranges
2. Allocate large ranges first
3. Evict smaller ranges when needed
4. Split live ranges around hot regions

**Key Features**:
- No predetermined allocation order
- No explicit interference graph
- On-the-fly live range splitting
- Trivial rewriter (85 lines vs 2600)

**Performance**:
- 1-2% smaller code than linear scan
- Up to 10% faster execution
- Same compile time

### Live Range Splitting:
```llvm
; Before splitting
%v0 = phi [...], [...]  ; Live across entire function

; After splitting
%v0.spill = spill %v0   ; Outside hot loop
%v0.hot = load %v0.spill ; In hot loop
; %v0.hot assigned to register
```

## 6.3 Calling Conventions

### System V AMD64 ABI:
- **Integer args**: RDI, RSI, RDX, RCX, R8, R9
- **Float args**: XMM0-XMM7
- **Return**: RAX (int), XMM0 (float)
- **Caller-saved**: RAX, RCX, RDX, RSI, RDI, R8-R11, XMM0-XMM15
- **Callee-saved**: RBX, RBP, R12-R15

### ARM64 (AAPCS64):
- **Integer args**: X0-X7
- **Float args**: V0-V7
- **Return**: X0, V0
- **Caller-saved**: X0-X18, V0-V7
- **Callee-saved**: X19-X29, V8-V15

### LLVM Representation:
```llvm
define i64 @add(i64 %a, i64 %b) #0 {
  %result = add i64 %a, %b
  ret i64 %result
}

attributes #0 = { nounwind }
```

## 6.4 SIMD Vectorization at IR Level

### LLVM Vector Types:
```llvm
<4 x i32>    ; 4-wide integer vector
<8 x float>  ; 8-wide float vector
<16 x i8>    ; 16-byte vector
```

### Vector Operations:
```llvm
%va = load <4 x i32>, <4 x i32>* %a
%vb = load <4 x i32>, <4 x i32>* %b
%vc = add <4 x i32> %va, %vb
store <4 x i32> %vc, <4 x i32>* %c
```

### Auto-Vectorization:
**Loop Vectorization**:
- Analyze loop for data dependencies
- Determine vectorization factor
- Generate vector instructions
- Handle epilog loops

**SLP Vectorization**:
- Find scalar operations that can be packed
- Build vector operations
- Handle non-power-of-two sizes

### Target Support:
- **x86**: SSE, AVX, AVX-512
- **ARM**: NEON, SVE
- **RISC-V**: V extension

---

# 7. What Makes These Approaches Unique

## 7.1 GCC: Plugin Architecture, Old-but-Stable Design

### Plugin System:
```c
// GCC plugin interface
int plugin_init(struct plugin_name_info *info,
                struct plugin_gcc_version *version) {
  // Register callbacks
  register_callback(info->base_name, PLUGIN_FINISH_UNIT,
                    my_callback, NULL);
  return 0;
}
```

### Advantages:
- **Stability**: 30+ years of development
- **Wide platform support**: More targets than LLVM
- **Mature optimizations**: Battle-tested on huge codebases
- **GPL license**: Ensures improvements flow back

### Disadvantages:
- **Monolithic design**: Hard to reuse components
- **Poor modularity**: Can't extract individual passes
- **Limited tooling**: Hard to build external tools
- **Slow compilation**: Less optimized for build speed

### Architecture Issues:
- GIMPLE not self-contained (references source trees)
- No standard textual representation
- RTL is untyped
- Hard to experiment with new approaches

## 7.2 LLVM: Library-Based Design

### Key Design Principles:
1. **Modular libraries**: Each component is independent
2. **Well-defined interfaces**: Clean API boundaries
3. **Separation of concerns**: Frontend, optimizer, backend separate
4. **Self-contained IR**: LLVM IR can be serialized, loaded, executed

### Library Structure:
```
libLLVMCore          - LLVM IR and verifier
libLLVMSupport       - Utility library
libLLVMCodeGen       - Machine code generation
libLLVMAnalysis      - Analysis passes
libLLVMTransformUtils - Transformation passes
libLLVMTarget        - Target-independent codegen
libLLVMX86CodeGen    - X86 backend
libLLVMMC            - Machine code layer
libLLVMObject        - Object file reading/writing
```

### Benefits:
- **Language innovation**: Easy to build new languages
- **Tool reuse**: Clang tooling, LLDB, etc.
- **JIT compilation**: LLVM ExecutionEngine
- **LTO support**: Built into the linker
- **Rapid iteration**: Can change APIs without breaking everything

## 7.3 Why LLVM Won for New Languages

### The Problem:
Before LLVM, implementing a new language required:
- Writing a parser
- Writing an optimizer
- Writing a code generator for each target
- Total effort: Years of work

### The LLVM Solution:
- Write a frontend only
- Reuse LLVM's optimizer and code generators
- Total effort: Months of work

### Success Stories:

**Rust**:
- Uses LLVM for all optimizations
- Leverages LLVM's type system for safety
- LLVM's LTO for whole-program optimization
- Debug info generation handled by LLVM

**Swift**:
- Custom intermediate language (SIL) for Swift-specific optimizations
- LLVM for low-level optimizations and code generation
- JIT compilation via LLVM ORC

**Julia**:
- Type inference at Julia level
- LLVM for code generation
- JIT compilation for interactive use
- Leverages LLVM's vectorization

**Zig**:
- Custom frontend with C interop
- LLVM for optimizations
- Also building custom backends for faster compilation

### Technical Reasons:
1. **Self-contained IR**: Can ship and execute without source
2. **Strong typing**: Enables optimizations across languages
3. **SSA form**: Modern optimization framework
4. **Modular passes**: Can add language-specific optimizations
5. **JIT support**: For interpreted/compiled hybrid languages

## 7.4 How the LLVM Ecosystem Benefits Astra

### Immediate Benefits:
- **Cross-compilation**: Support many targets without effort
- **Optimizations**: Hundreds of optimization passes
- **Debug information**: DWARF generation
- **JIT compilation**: For REPL and scripting
- **Tooling**: LSP support via clangd-like infrastructure

### Long-term Benefits:
- **Community**: LLVM improves constantly
- **Research**: New optimizations available
- **Performance**: LLVM generates high-quality code
- **Interoperability**: Can call and be called by C/C++

---

# 8. Lessons for Astra

## 8.1 Why Astra Should Target LLVM

### Strategic Reasons:
1. **Proven infrastructure**: LLVM is battle-tested
2. **Wide platform support**: x86, ARM, RISC-V, WebAssembly, etc.
3. **Active development**: Constant improvements
4. **Large community**: Easy to get help
5. **Tooling ecosystem**: Clang tooling, LLDB, etc.

### Technical Reasons:
1. **High-quality code generation**: LLVM produces excellent machine code
2. **Optimization framework**: Modern SSA-based optimizations
3. **Type system**: Rich type information preserved
4. **Metadata**: Debug info, profiling, etc.
5. **Extensibility**: Can add custom passes

### Cost-Benefit Analysis:
**Costs**:
- Learning curve for LLVM API
- Compile time (LLVM can be slow)
- Dependency on external project

**Benefits**:
- Years of optimization work for free
- Cross-platform support
- Tooling ecosystem
- Community support

**Verdict**: Benefits vastly outweigh costs

## 8.2 Designing AIR (Astra IR) to Map Cleanly to LLVM IR

### Design Principles:

1. **SSA Form**: Design AIR to be SSA-based from the start
   - Matches LLVM IR naturally
   - Enables modern optimizations
   - Simplifies code generation

2. **Type System**: Preserve type information throughout
   - Map Astra types to LLVM types
   - Use LLVM's metadata for rich types
   - Enable type-based optimizations

3. **Memory Model**: Explicit memory operations
   - Use `alloca`/`load`/`store` pattern
   - Let LLVM's `mem2reg` promote to registers
   - Avoid custom register allocation

4. **Control Flow**: Explicit CFG
   - Basic blocks with terminators
   - PHI nodes for control flow merges
   - Matches LLVM's structure

5. **Function Calls**: Explicit calling conventions
   - Use LLVM's calling conventions
   - Preserve argument types
   - Handle varargs properly

### AIR Structure Proposal:

```astra
// AIR representation
fn add(a: i32, b: i32) -> i32 {
entry:
  %result = add i32 %a, %b
  return i32 %result
}

// Maps to LLVM IR:
define i32 @add(i32 %a, i32 %b) {
entry:
  %result = add i32 %a, %b
  ret i32 %result
}
```

### Type Mapping:

| Astra Type | LLVM Type | Notes |
|------------|-----------|-------|
| `i32` | `i32` | Direct mapping |
| `f64` | `double` | Direct mapping |
| `bool` | `i1` | Single bit |
| `*T` | `T*` | Pointer |
| `[N]T` | `[N x T]` | Array |
| `{...}` | `%struct.name` | Struct |

### Memory Model:

```astra
// Astra code
let x: i32 = 5;
let y: i32 = x + 3;

// AIR (simplified)
%x = alloca i32
store i32 5, i32* %x
%y = alloca i32
%tmp = load i32, i32* %x
%result = add i32 %tmp, 3
store i32 %result, i32* %y

// LLVM handles mem2reg:
// %x promoted to SSA
// %y eliminated
```

## 8.3 What Optimization Passes Astra Can Leverage

### Immediately Available:
1. **mem2reg**: Promote stack variables to SSA
2. **SROA**: Scalar replacement of aggregates
3. **GVN**: Global value numbering
4. **LICM**: Loop invariant code motion
5. **Loop unrolling**: Reduce loop overhead
6. **Vectorization**: SIMD instructions
7. **Inlining**: Function call elimination
8. **Constant folding**: Compile-time evaluation
9. **Dead code elimination**: Remove unused code
10. **Tail call optimization**: Recursive call optimization

### Language-Specific Optimizations:
Astra can add custom passes before LLVM:
- **Type specialization**: Like C++ templates
- **Devirtualization**: Remove virtual dispatch
- **Bounds checking elimination**: Remove redundant checks
- **Memory management optimization**: Optimize allocations

### Custom Pass Example:
```cpp
class BoundsCheckElimination : public FunctionPass {
  bool run(Function &F, FunctionAnalysisManager &AM) {
    // Find bounds checks
    // Prove they're redundant
    // Remove them
    return Changed;
  }
};
```

## 8.4 Designing for Cross-Compilation from Day One

### LLVM's Cross-Compilation Support:

**Target Triple**: `<arch>-<vendor>-<os>-<env>`
```
x86_64-unknown-linux-gnu
aarch64-apple-darwin21
riscv32-unknown-elf
```

**Data Layout**: Specifies target properties
```
e-m:e-p:64:64-i64:64-i128:128-n32:64-S128
```

### Astra Cross-Compilation Design:

1. **Separate frontend and backend**: Compile to LLVM IR on host, generate code for target
2. **Target specification in source**: Declare target in build system
3. **Standard libraries**: Provide cross-compilable standard library
4. **Sysroot support**: Target-specific headers and libraries

### Build System Integration:
```cmake
# CMake example
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)

# Astra cross-compilation
set(ASTRA_TARGET aarch64-unknown-linux-gnu)
```

### Runtime Support:
- **Startup code**: Target-specific
- **System calls**: Target-specific ABI
- **Standard library**: Cross-compiled
- **Debug information**: Target-specific DWARF

### Implementation Strategy:
1. **Phase 1**: Native compilation only
2. **Phase 2**: Add cross-compilation support
3. **Phase 3**: Target-specific optimizations
4. **Phase 4**: Full cross-compilation toolchain

---

# Summary

## Key Takeaways for Astra:

1. **LLVM is the right choice**: Proven, powerful, extensible
2. **Design for LLVM**: Make AIR map cleanly to LLVM IR
3. **Use SSA from the start**: Enables modern optimizations
4. **Preserve type information**: Enables better optimizations
5. **Plan for cross-compilation**: LLVM makes it easy
6. **Leverage existing passes**: Don't reinvent the wheel
7. **Add language-specific optimizations**: Custom passes for Astra features
8. **Build tooling early**: LLVM's modularity enables great tools

## Architecture Recommendation:

```
Astra Source
    │
    ▼
Parser (Recursive descent, like Clang)
    │
    ▼
Sema (Semantic analysis, type checking)
    │
    ▼
AIR (Astra Intermediate Representation)
    │
    ▼
Lowering (AIR → LLVM IR)
    │
    ▼
LLVM Optimizer
    │
    ▼
LLVM Code Generator
    │
    ▼
Target Machine Code
```

This architecture:
- Follows proven patterns (Clang, Rust, Swift)
- Leverages LLVM's power
- Enables tooling via AST
- Allows language-specific optimizations
- Supports cross-compilation from day one
