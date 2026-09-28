# Phase 2 Gap Analysis — Astra Self-Hosting Compiler (Zig)

> **Status:** Working document
> **Last updated:** 2026-09-28
> **Baseline:** Phase 1 seed compiler (C, v0.1.0) — 44 constructs, 27 operators, 89 tests

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Phase 1 Feature Inventory](#2-phase-1-feature-inventory)
3. [Feature Mapping: Carry to Phase 2](#3-feature-mapping-carry-to-phase-2)
4. [Features Requiring Redesign in Zig](#4-features-requiring-redesign-in-zig)
5. [Missing Features (Required by Architecture, Not in Seed)](#5-missing-features)
6. [Bytecode Format Analysis](#6-bytecode-format-analysis)
7. [Type System Gaps](#7-type-system-gaps)
8. [Construct Registry Status](#8-construct-registry-status)
9. [Zig-Specific Considerations](#9-zig-specific-considerations)
10. [Risk Areas](#10-risk-areas)
11. [Recommended Implementation Order](#11-recommended-implementation-order)
12. [Debugging & Low-Level Inspection](#12-debugging--low-level-inspection)

---

## 1. Executive Summary

Phase 1 delivered a self-contained C compiler that lexes, parses, type-checks, emits bytecode, and executes programs via a stack VM — plus an alternative C code-generation backend. It covers the Astra-0 subset: enough of the language to compile itself once Phase 2 adds the missing features.

Phase 2 must:
- **Port** the working pipeline to Zig, replacing C idioms with Zig's comptime, allocators, and error handling.
- **Extend** the language beyond Astra-0 to the full Astra spec: generics, traits, comptime, modules, methods, error propagation, async, and operator overloading.
- **Replace** the C codegen backend with a real AOT backend (LLVM or native Zig codegen).
- **Maintain** the construct-registry pattern and self-validation tooling.

The gap is large but structured: the seed compiler's architecture (construct registry, pipeline stages, test harness) is the skeleton; the Zig port fills in the muscle.

---

## 2. Phase 1 Feature Inventory

### 2.1 Pipeline Stages

| Stage | File(s) | What it does |
|:------|:--------|:-------------|
| Lexer | `lexer.c` | Hand-written tokenizer, 32 keywords, string interning |
| Parser | `parser.c` | Recursive descent + Pratt expressions, max depth 256 |
| AST | `ast.c` | Node construction, source locations |
| Type Checker | `typechecker.c` | Scoped symbol table, structural type unification |
| Emitter | `emitter.c` | AST → stack bytecode, compile-time stack-height model |
| VM | `vm.c` | Stack-based interpreter, value model, builtins |
| C Codegen | `codegen.c`, `codegen_runtime.h` | Bytecode → C source, gcc-compiled |

### 2.2 Data Types

| Type | VM Kind | Notes |
|:-----|:--------|:------|
| Nil | `VAL_NIL` | Unit type, `none` literal |
| Bool | `VAL_BOOL` | `true`/`false` |
| Int | `VAL_INT` | 64-bit signed |
| Int64 | `VAL_INT64` | Explicit 64-bit (unused differently from Int in practice) |
| UInt32 | `VAL_UINT32` | Unsigned 32-bit |
| UInt64 | `VAL_UINT64` | Unsigned 64-bit |
| Float | `VAL_FLOAT` | 64-bit double |
| String | `VAL_STRING` | Heap-allocated, immutable, interned literals |
| Array | `VAL_ARRAY` | Homogeneous, heap-allocated, `len`/`push`/`pop` |
| Struct | `VAL_STRUCT` | Structural, named fields, heap-allocated |
| Enum | `VAL_ENUM` | Unit variants + data-carrying variants |
| Optional | `VAL_OPTION` | `some(x)` / `none`, unwrap with `?` |
| Result | `VAL_RESULT` | `ok(x)` / `err(e)`, propagate with `?` |
| Range | `VAL_RANGE` | `start..end`, used in `for..in` |
| Tuple | `VAL_TUPLE` | Fixed-size, heterogeneous (partial support) |
| Function | `VAL_FN` | Top-level named functions |
| Closure | `VAL_CLOSURE` | Lambda/closure values (no captured upvalues in Astra-0) |

### 2.3 Operators (27)

| Category | Operators |
|:---------|:----------|
| Arithmetic | `+`, `-`, `*`, `/`, `%` |
| Comparison | `==`, `!=`, `<`, `>`, `<=`, `>=` |
| Logical | `and`, `or`, `not` |
| Bitwise | `&`, `\|`, `^`, `<<`, `>>`, `~` |
| Assignment | `=` |
| Index | `[]` (array/string index) |
| Access | `.` (field access) |
| Call | `()` (function call) |
| Range | `..` |
| Pipe | `\|` (lambda start / bitwise-or disambiguation) |
| Spread | `*` (array spread) |
| Negation | `-` (unary) |

### 2.4 Control Flow

- `if` / `else` (statement and expression)
- `while` with `break` / `continue`
- `for..in` over arrays and ranges
- `match` with pattern binding, guards (`if`), alternatives (`|`)

### 2.5 Functions

- Top-level `fn` declarations (emitted as VM globals)
- Parameters in frame slots 1..n (slot 0 = callee)
- Recursive calls
- Lambdas (`|params| { body }`) as expressions
- Function values (first-class functions, but no closures with captured variables)

### 2.6 Patterns

- Literal patterns (int, string, bool, nil)
- Variable binding patterns
- Wildcard patterns (`_`)
- Enum variant patterns (unit + data-carrying)
- Guard clauses (`if condition`)
- Alternative patterns (`|`)

### 2.7 Builtins

| Builtin | Signature | Notes |
|:--------|:----------|:------|
| `print` | `fn(any...) -> nil` | Variadic, prints to stdout |
| `len` | `fn(array) -> int` | Array/string length |
| `push` | `fn(array, value) -> nil` | Mutates array in-place |
| `pop` | `fn(array) -> nil` | Mutates array in-place |

### 2.8 Test Coverage

- 89 total tests (conformance + codegen round-trip)
- 42 non-UI conformance cases verified on both VM and C backend
- `make test` runs VM + `--emit-c` + gcc round-trip, compares output

---

## 3. Feature Mapping: Carry to Phase 2

These features work correctly in Phase 1 and should be **ported as-is** (with Zig idioms) to Phase 2.

| Feature | Porting Difficulty | Notes |
|:--------|:-------------------|:------|
| Lexer (tokenizer) | Low | Straightforward Zig port; replace `malloc` with `Allocator` |
| String interning | Low | Zig `HashMap` replaces hand-rolled table |
| Pratt parser | Low | Well-understood algorithm; port directly |
| Recursive descent | Low | Straightforward; preserve max-depth guard |
| AST node construction | Low | Arena allocation maps cleanly to Zig |
| Source location tracking | Low | Simple struct |
| Type checker (structural) | Medium | Port symbol table; Zig's compile-time checks may help |
| Stack bytecode emitter | Medium | Port opcode emission; preserve stack-height model |
| Stack VM | Medium | Straightforward port; value representation needs care |
| C codegen backend | Medium-High | Consider replacing with native/Zig codegen (see §5) |
| Construct registry | Low | Port `ConstructSpec` and self-check logic |
| Operator table | Low | Port precedence data |
| Test harness | Low | Port `run_tests.sh` logic to Zig build system |

---

## 4. Features Requiring Redesign in Zig

### 4.1 Memory Management

**Current (C):** Arena allocator (`arena.c`) — all compiler memory freed in bulk.

**Phase 2 (Zig):** Zig provides `std.mem.Allocator` interface. Options:
- **Arena allocator** (`std.heap.ArenaAllocator`) — same pattern, port directly.
- **General Purpose allocator** (`std.heap.GeneralPurposeAllocator`) — for runtime allocations.
- **Fixed Buffer allocator** — for hot paths where size is bounded.

**Decision:** Keep arena for compiler phases (same as C). Use GPA for VM runtime values. This is a clean port with no architectural change.

### 4.2 Value Representation

**Current (C):** `Value` is a tagged union with `ValueKind` enum. Heap objects (strings, arrays, structs, enums, closures) are pointer-tagged.

**Phase 2 (Zig):** Zig's `union(enum)` maps directly. Key change: Zig enforces exhaustive switches, which catches missing cases at compile time. Port the `Value` union as-is; Zig's type system adds safety for free.

### 4.3 Error Handling

**Current (C):** `setjmp`/`longjmp` for runtime errors in C codegen; `vm.error` flag + error message in VM.

**Phase 2 (Zig):** Replace with Zig error unions (`error{...}!Value`). The VM execution loop becomes:
```zig
fn execute(pc: [*]const Instruction, stack: []Value) !Value {
    // errors propagate via try/catch
}
```
No `setjmp`/`longjmp` needed. Cleaner, comptime-checked error paths.

### 4.4 C Codegen Backend → Native/Zig Backend

**Current:** `codegen.c` emits C source from bytecode, compiled by gcc.

**Phase 2 decision:** The C backend was a bootstrap shortcut. For the self-hosting compiler, replace with:
- **Option A:** LLVM backend (via `llvm-zig` or direct C API from Zig). Full optimization, existing ecosystem.
- **Option B:** Native Zig codegen. Simpler, no LLVM dependency, but less optimization.
- **Option C:** Keep C backend as a fallback, add Zig native as primary.

**Recommendation:** Option C — keep C backend for bootstrapping verification, add Zig native backend incrementally.

Whichever backend is chosen, it must surface the same "inspect what the
compiler produced" affordance C/C++ users get: `--emit-llvm`, `--emit-asm` and
`--emit-obj` in debug builds, plus DWARF debug info so external debuggers map
machine instructions back to Astra source lines. See §12 for the full plan and
the open decisions.

### 4.5 Build System

**Current:** GNU Make with recursive make, per-variant object trees.

**Phase 2:** Zig build system (`build.zig`). Benefits:
- Single `build.zig` file replaces Makefile
- Cross-compilation for free
- Integrated test runner
- Faster incremental builds

---

## 5. Missing Features

These are required by the architecture (`ARCHITECTURE.md`) but **not implemented** in Phase 1.

### 5.1 Tier 1 — Required for Self-Hosting

The self-hosting compiler must be written in Astra-0 (the subset Phase 1 implements), so these are NOT needed for Phase 2 to start. However, they are needed for the *full* language.

| Feature | Spec Reference | Complexity | Notes |
|:--------|:---------------|:-----------|:------|
| **Modules / Imports** | `ARCHITECTURE §5` | High | Multi-file compilation, namespace resolution, package manager |
| **Traits** | `ARCHITECTURE §7` | High | Interface definitions, dynamic dispatch, trait bounds |
| **Generics** | `ARCHITECTURE §6` | High | Monomorphization or erasure, type inference |
| **Methods (`self`)** | `ARCHITECTURE §7` | Medium | UFCS or vtable dispatch, receiver syntax |
| **Type Aliases** | `ARCHITECTURE §8` | Low | Named type synonyms |
| **Error Propagation (`?`)** | `ARCHITECTURE §9` | Low | Already partially implemented for Result; extend to all error paths |

### 5.2 Tier 2 — Required for Production Language

| Feature | Spec Reference | Complexity | Notes |
|:--------|:---------------|:-----------|:------|
| **Comptime** | `ARCHITECTURE §10` | Very High | Compile-time evaluation, type-level computation |
| **Operator Overloading** | `ARCHITECTURE §11` | Medium | Trait-based, `opAdd`, `opEq` etc. |
| **Macros** | `ASTRA-0_SUBSET.md §3` | High | Code transformation, hygiene |
| **Async / Fibers** | `ARCHITECTURE §12` | Very High | Green threads, scheduler, await/yield |
| **ARC/ORC Memory Management** | `ARCHITECTURE §4` | High | Reference counting with cycle detection |
| **Zero-Copy FFI** | `ARCHITECTURE §13` | High | C interop, pointer passing, no marshaling |

### 5.3 Tier 3 — Quality of Life

| Feature | Complexity | Notes |
|:--------|:-----------|:------|
| Pattern matching extensions (rest, spread) | Low | Extend existing match |
| Destructuring assignment | Low | `let (a, b) = tuple;` |
| String interpolation | Low | `f"hello {name}"` |
| Closures with captured upvalues | Medium | Currently lambdas can't capture |
| Default parameter values | Low | `fn foo(x: int = 5)` |
| Variadic functions | Low | Already partially built in `print` |
| Attributes / annotations | Low | `@deprecated`, `@inline` |

---

## 6. Bytecode Format Analysis

### 6.1 Current Format

The seed compiler uses a **flat byte buffer** of variable-length instructions:

| Field | Size | Notes |
|:------|:-----|:------|
| Opcode | 1 byte | `OpCode` enum (0–58 defined) |
| Operands | 0–3 bytes | Depends on opcode |
| Jump offset | 2 bytes (when present) | Signed, relative to next instruction |

Stack values are pushed/popped implicitly by opcode semantics (stack-machine model).

### 6.2 Limitations

1. **No instruction boundaries** — corrupted bytes cascade silently.
2. **No function metadata** — function boundaries are implicit in the bytecode stream.
3. **No persisted line number table** — the in-memory `Instruction` carries a
   `line` (which is why runtime errors already print `file:line`), but the flat
   serialized stream does not store one.
4. **No constant pool metadata** — only raw bytes, no type information attached.
5. **Fixed-size limits** — `MAX_CODE=1MB`, `MAX_CONSTS=1MB`, `MAX_LOCALS=256`.

### 6.3 Phase 2 Redesign

For a production compiler, the bytecode should be restructured:

```
Module
├── Header (magic, version, endianness)
├── Constant Pool
│   ├── Strings (with length prefix)
│   ├── Integers
│   ├── Floats
│   └── Struct/Enum definitions
├── Function Table
│   ├── Name, parameter count, local count
│   ├── Bytecode offset + length
│   └── Line number table (PC → source location)
├── Global Variables
│   ├── Name, type info
│   └── Initializer bytecode
└── Main entry point
```

**Recommendation:** Design the new format early in Phase 2, then write a converter to import Phase 1 test cases.

---

## 7. Type System Gaps

### 7.1 Current Types (Phase 1)

```
Nil, Bool, Int, Int64, UInt32, UInt64, Float, String,
Array(T), Fn(P) -> R, Struct(fields), Enum(variants),
Optional(T), Tuple(...), Unknown, IntLiteral, NilLiteral
```

### 7.2 Missing Types

| Type | Required By | Complexity |
|:-----|:------------|:-----------|
| **Generics `T`** | `ARCHITECTURE §6` | High — monomorphization or erasure |
| **Trait objects `dyn Trait`** | `ARCHITECTURE §7` | High — vtable + fat pointer |
| **References `&T`, `&mut T`** | `ARCHITECTURE §4` | High — borrow checker or ARC |
| **Function pointers `fn(P) -> R`** | `ARCHITECTURE §8` | Low — already partially there |
| **Type aliases** | `ARCHITECTURE §8` | Low |
| **Never type `!`** | `ARCHITECTURE §9` | Low — for exhaustive error paths |
| **Comptime types** | `ARCHITECTURE §10` | Very High |
| **Slice `[]T`** | `ARCHITECTURE §8` | Medium — pointer + length |
| **Pointer `*T`, `[*]T`** | `ARCHITECTURE §8` | Medium — unsafe pointers |

### 7.3 Structural vs. Nominal Typing

Phase 1 uses **structural typing** for structs and enums (two structs with the same fields are compatible). The architecture spec (`ARCHITECTURE §6`) implies **nominal typing** for traits and generics. Phase 2 must decide:

- **Keep structural** for plain structs (ergonomic, TypeScript-like).
- **Use nominal** for trait implementations (a struct implements a trait by name, not by shape).

This hybrid approach requires the type checker to distinguish "structural types" (plain structs) from "nominal types" (traits, interfaces).

---

## 8. Construct Registry Status

### 8.1 Registry Summary

The construct registry (`constructs/registry.c`) has **44 entries** organized by category:

| Category | Count | In Astra-0 | Notes |
|:---------|:------|:-----------|:------|
| Module items | 8 | 3 | `fn`, `let`, `const` are in; `trait`, `impl`, `import`, `type_alias`, `export` are out |
| Statements | 4 | 4 | `print`, `assign`, `expression_stmt`, `block` — all in |
| Control flow | 4 | 4 | `if`, `while`, `for`, `return`/`break`/`continue` — all in |
| Patterns | 3 | 3 | `match`, `binding`, `wildcard` — all in |
| Expressions | 25 | 18 | Most in; `lambda`, `method_call`, `field_access` have partial support |
| Excluded | 3 | 0 | `comptime`, `trait`, `impl` — lexed but rejected |

### 8.2 Constructs Marked OUTSIDE ASTRA-0

These are registered (keyword lexes, grammar documented) but `parse = NULL, check = NULL, emit = NULL`:

| Construct | Token | Node | Why Excluded |
|:----------|:------|:-----|:-------------|
| `trait` | `TOKEN_TRAIT` | `NODE_NONE` | Needs generics, dynamic dispatch |
| `impl` | `TOKEN_IMPL` | `NODE_NONE` | Needs methods, self parameter, vtable |
| `comptime` | `TOKEN_COMPTIME` | `NODE_NONE` | Meta-programming, not needed for seed |
| `lambda` | `TOKEN_PIPE` | `NODE_LAMBDA` | Actually IN Astra-0, but closures lack captures |
| `import` | `TOKEN_IDENT` | `NODE_NONE` | No multi-file support yet |
| `type_alias` | `TOKEN_IDENT` | `NODE_NONE` | No lexer token for `type` keyword |
| `export` | none | `NODE_NONE` | No module system |

### 8.3 Phase 2 Action

Phase 2 must:
1. **Implement** `import`/`export` and module resolution first (everything else depends on multi-file compilation).
2. **Implement** `trait` and `impl` next (needed for generics and methods).
3. **Implement** `comptime` last (complex, not blocking other features).

---

## 9. Zig-Specific Considerations

### 9.1 Comptime Advantage

Zig's `comptime` can replace several C preprocessor patterns and simplify the compiler:

- **Construct registry:** Can be a `comptime` generated array instead of a hand-maintained C array.
- **Operator table:** Can be `comptime` validated at compile time.
- **Token/Node enums:** Can use `@typeInfo` for exhaustive switch handling.
- **Test discovery:** Zig's test runner automatically finds `test` blocks.

### 9.2 Allocator Pattern

Every Zig function that allocates takes an `Allocator` parameter explicitly. This replaces the implicit global `arena` in C:

```zig
// C: arena_alloc(&compiler->arena, size)
// Zig: allocator.alloc(u8, size)
```

Benefits: no hidden allocations, easy to swap allocators (debug vs release), comptime-checked.

### 9.3 Error Handling

Replace `setjmp`/`longjmp` and error flags with Zig error unions:

```zig
const CompileError = error{ OutOfMemory, SyntaxError, TypeError, ... };

fn compile(source: []const u8) CompileError!Module {
    const ast = try parse(source);
    const typed = try typecheck(ast);
    return try emit(typed);
}
```

Caller uses `try` or `catch`, no runtime cost for the happy path.

### 9.4 Cross-Compilation

Zig's build system supports cross-compilation natively. The Phase 2 compiler can target:
- Native platform (development)
- WebAssembly (browser execution)
- Embedded targets (no_std)

### 9.5 No Undefined Behavior

Zig catches most C UB at compile time or with safety checks:
- Buffer overflows → bounds checking
- Use-after-free → (manual, but arena pattern helps)
- Integer overflow → `wrappingAdd`/`saturationAdd` explicit
- Null pointer dereference → `?T` optional type

---

## 10. Risk Areas

### 10.1 High Risk

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| **Module system complexity** | Blocks everything else | Implement minimal `use` first, iterate |
| **Generic type inference** | Hard to get right | Start with explicit type parameters, add inference later |
| **Comptime evaluation** | Very complex, easy to break | Defer to Tier 2, implement incrementally |
| **Async/fiber scheduler** | OS-level complexity | Use Zig's async primitives, defer to Tier 2 |
| **ARC correctness** | Memory leaks or use-after-free | Extensive testing, sanitizer support |

### 10.2 Medium Risk

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| **Bytecode format migration** | Existing tests break | Write format converter, keep old tests |
| **Structural → nominal typing shift** | Type errors change | Design hybrid system early, document rules |
| **Operator overloading ambiguity** | Unreadable code | Limit to trait-defined operators, no ad-hoc overloading |
| **Zig learning curve** | Slower development | Start with simple ports, learn idioms gradually |

### 10.3 Low Risk

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| **Build system complexity** | Annoying but solvable | Zig build system is simpler than Make |
| **Test coverage regression** | Missing bugs | Port all 89 tests, add new ones per feature |
| **Performance regression** | Slower compilation | Profile early, use Zig's performance tools |

---

## 11. Recommended Implementation Order

### Phase 2.1 — Foundation (Zig Port)

1. **Set up Zig project** (`build.zig`, directory structure)
2. **Port lexer** — tokenizer + string interning
3. **Port parser** — recursive descent + Pratt
4. **Port AST** — node types + arena
5. **Port type checker** — structural types, symbol table
6. **Port emitter** — bytecode emission
7. **Port VM** — stack interpreter
8. **Port construct registry** — self-validation
9. **Port all 89 tests** — verify parity with Phase 1
10. **Port C codegen backend** — keep for bootstrap verification

**Exit criteria:** `astra-zig` produces identical output to `astra-seed` on all 89 tests.

### Phase 2.2 — Module System

1. **Lexer:** Add `import`, `from`, `as`, `export` tokens
2. **Parser:** Parse `use` and `from...import` statements
3. **Module loader:** Resolve file paths, load source files
4. **Namespace:** Symbol table per module, `pub` visibility
5. **Multi-file compilation:** Link modules, resolve cross-module references
6. **Build system integration:** `build.zig` discovers and compiles modules

**Exit criteria:** Multi-file Astra programs compile and run correctly.

### Phase 2.3 — Traits and Methods

1. **Parser:** Parse `trait`, `impl`, method definitions
2. **AST:** Add `TraitDef`, `ImplBlock`, `MethodDecl` nodes
3. **Type checker:** Trait bounds, method resolution, `self` parameter
4. **Emitter:** Method calls → dispatch (static for now)
5. **Runtime:** Trait object representation (vtable or monomorphization)

**Exit criteria:** `impl Trait for Type` with method dispatch works.

### Phase 2.4 — Generics

1. **Parser:** Parse `<T>` generic parameters
2. **Type checker:** Generic type inference, trait bounds on generics
3. **Emitter:** Monomorphization (instantiate generic functions per type)
4. **Runtime:** Generic struct/enum instantiation

**Exit criteria:** `fn identity<T>(x: T) -> T` works with type inference.

### Phase 2.5 — Error Propagation

1. **Parser:** `?` operator on any expression (not just Result)
2. **Type checker:** Infer error types, check `try` usage
3. **Emitter:** Implicit error propagation through call stack
4. **Runtime:** Error unwinding

**Exit criteria:** `?` propagates errors automatically through function calls.

### Phase 2.6 — Native Backend

1. **Design:** Choose LLVM or native Zig codegen
2. **Implement:** Bytecode → target code
3. **Emit flags:** `--emit-llvm` (`.ll`), `--emit-asm` (`.s`), `--emit-obj` (`.o`)
4. **Debug info:** attach DWARF (`DICompileUnit`/`DILocation`/`DICompositeType`)
   so gdb/lldb step on Astra source lines (see §12)
5. **Optimize:** Basic optimizations (constant folding, dead code elimination)
6. **Test:** Verify all conformance tests pass on native backend

**Exit criteria:** Astra programs compile to native executables without C backend,
and a debug build exposes source-mapped assembly.

### Phase 2.7 — Production Features

1. **Operator overloading** (trait-based)
2. **Macros** (code transformation)
3. **Closures with captures** (upvalue handling)
4. **Advanced patterns** (rest, spread, destructuring)
5. **String interpolation**
6. **Default parameters**
7. **Attributes / annotations**

---

## 12. Debugging & Low-Level Inspection

How a user sees what the compiler produced and why a program failed at a low
level. Split by layer, because the answer changes with the backend.

### 12.1 What exists today (bytecode VM)

Phase 1 and the Phase 2 port already expose the compiler's own low-level view:

| Facility | Output |
|:---------|:-------|
| `--dump-bytecode` | module bytecode, operands and constant values |
| `ASTRA_DUMP_VM=1` | bytecode of the module and of every called function |
| `ASTRA_TRACE=1` | one line per instruction: `sp`/`base`/`frame` + top of stack |
| `--debug` | interactive bytecode debugger: breakpoints on Astra lines, `step`, stack/locals/frames |
| runtime errors | `file:line: runtime error: <message>` |

This is the VM-layer equivalent of `-S`: it shows the instructions the compiler
emitted and how the stack evolves, but it is bytecode, not machine code. The
in-memory `Instruction` already carries a `line`, so the source mapping needed
for higher-level diagnostics exists — it is just not surfaced everywhere yet.

### 12.2 Native output flags (Phase 2.6)

The AOT backend (§4.4, §11 Phase 2.6) must expose the `g++ -S` affordance:

| Flag | Output | C/C++ equivalent |
|:-----|:-------|:-----------------|
| `--emit-llvm` | human-readable LLVM IR (`.ll`) | `clang -emit-llvm -S` |
| `--emit-asm` | target assembly (`.s`) | `gcc -S` |
| `--emit-obj` | object file (`.o`) | `gcc -c` |

With LLVM these are nearly free: the target machine emits them through
`addPassesToEmitFile` (`PHASE2_RESEARCH.md §2`).

### 12.3 Source-level debugging (DWARF)

The C/C++ experience — "step and see which source line failed, in the generated
assembly" — is *debug info*, not the asm dump alone. To match it the backend
must attach:

- `DICompileUnit`/`DIFile` per module,
- `DILocation` on every lowered instruction, derived from `Instruction.line`
  and the AST `SourceLoc`, and
- `DICompositeType` for structs and enums.

Existing debuggers (gdb/lldb) then provide `disassemble /m`, line breakpoints,
variable inspection and source-mapped stack traces.

> `ARCHITECTURE.md` forbids *inline* assembly in source. That is unrelated to
> inspecting the *generated* assembly, which is expected.

### 12.4 Built-in tooling (Phase 2.7 / Phase 3)

Because the toolchain is ours, debugging can go further than C++:

- a **bytecode debugger** (breakpoints on Astra lines, step, stack/local
  inspection) that works on the VM, with no LLVM involvement — **implemented**
  (`--debug`, see §12.1);
- `astra debug` showing the whole pipeline: AST → bytecode/AIR → LLVM IR → asm;
- runtime-aware inspection: ARC/ORC reference counts, fiber stacks.

### 12.5 Open decisions

1. **Debug-info source:** let LLVM emit DWARF from the metadata we attach, or
   emit DWARF ourselves (needed for non-LLVM targets)?
2. ~~**Timing of the bytecode debugger:** build it before the AOT backend?~~
   **Decided (2026-09-28):** built now, with the VM (§12.1). It shares the
   per-instruction line table, needs no LLVM, and is useful during Phase 2.1.
3. **Use the serialized bytecode (§6) as the debug format too?** A persisted
   line table (§6.3) would let the debugger work without recompiling.
4. **Debug-build guarantee:** commit to an unoptimized "debug build" mode where
   no optimization removes frames or reorders statements, so stepping is exact?
5. **Flag shape:** `--emit-asm`/`--emit-llvm`/`--emit-obj`, or a single
   `--emit=<kind>` matching the existing `--emit-c` from the seed?

---

## Appendix A: Files to Port

### Infrastructure
- `include/astra/astra.h` → `src/astra.zig` (public API)
- `src/priv.h` → inline in respective modules
- `src/arena.c` → `std.heap.ArenaAllocator` (stdlib)
- `src/string_table.c` → `StringTable.zig` (HashMap-based)

### Frontend
- `src/lexer.c` → `Lexer.zig`
- `src/parser.c` → `Parser.zig`
- `src/ast.c` → `Ast.zig` (with comptime node types)

### Semantics
- `src/typechecker.c` → `TypeChecker.zig`
- `src/scope.c` → inline in TypeChecker

### Codegen
- `src/emitter.c` → `Emitter.zig`
- `src/vm.c` → `Vm.zig`
- `src/codegen.c` → `CodeGen.zig` (C backend)
- `src/codegen_runtime.h` → `codegen_runtime.zig` or keep as C header

### Constructs (44 files)
- `src/constructs/*.c` → `src/constructs/*.zig`
- `src/constructs/construct.h` → `src/constructs/ConstructSpec.zig`
- `src/constructs/registry.c` → `src/constructs/registry.zig`
- `src/constructs/operator_table.c` → `src/constructs/operator_table.zig`

### Driver
- `src/driver.c` → `Driver.zig`
- `src/main.zig` (entry point)

### Tests
- `tests/conformance/*.astra` → unchanged (language-level tests)
- `tests/codegen/*.astra` → unchanged
- `tests/run_tests.sh` → `build.zig` test runner

---

## Appendix B: Open Questions

1. **Bytecode format:** Design new format first, or port flat format and redesign later?
2. **Structural vs. nominal typing:** Hybrid approach — when exactly does a type become nominal?
3. **Generics implementation:** Monomorphization (C++-style) or type erasure (Go-style)?
4. **Async model:** Stackful fibers (Go-style) or stackless (Rust-style)?
5. **C backend retention:** Keep as bootstrap tool, or replace once native backend works?
6. **Module path syntax:** `use std.io` (dot-separated) or `use "std/io"` (path string)?
   Note the current state is a third variant: both parsers (`seed/src/parser.c`
   `parse_use` and the Zig port) accept `ident ("::" ident)*`, but the construct
   spec `seed/src/constructs/use.c` declares
   `ImportPath ::= Identifier ("." Identifier)*`. The grammar string is not
   enforced by `--check-constructs`, so the two have drifted; Phase 2.2 must
   pick one and fix the other.
7. **Operator overloading scope:** Trait-only, or allow ad-hoc overloading for user types?
8. **Assembly/debug output:** which emit flags, and does the AOT backend emit
   DWARF itself or delegate to LLVM? (see §12)
9. **Timing of low-level debugging:** ship the bytecode debugger with the VM
   (Phase 2.1/2.2) or defer all debug tooling to the native backend (2.6)?

---

*This document should be updated as Phase 2 implementation progresses.*
