# Astra — Seed (Bootstrap) Compiler Design & Implementation Report

**Version:** 1.0 | **Date:** September 2026

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Lessons from Reference Implementations](#2-lessons-from-reference-implementations)
3. [Seed Compiler Architecture](#3-seed-compiler-architecture)
4. [Implementation Language: C vs Rust](#4-implementation-language-c-vs-rust)
5. [Minimal Viable Language (MVP)](#5-minimal-viable-language-mvp)
6. [Bootstrapping Strategy](#6-bootstrapping-strategy)
7. [Parser Implementation](#7-parser-implementation)
8. [Type Checker Implementation](#8-type-checker-implementation)
9. [Code Generation](#9-code-generation)
10. [Error Reporting](#10-error-reporting)
11. [Testing Strategy](#11-testing-strategy)
12. [Toolchain Integration](#12-toolchain-integration)
13. [Phased Development Plan](#13-phased-development-plan)
14. [Timeline](#14-timeline)
15. [Risk Analysis](#15-risk-analysis)

---

## 1. Executive Summary

This report investigates how to design and implement the **seed compiler** (also called bootstrap compiler) for Astra — the initial compiler written in C that compiles the first version of the Astra-to-Astra compiler.

The seed compiler's purpose is narrowly defined: **compile enough of Astra to compile the self-hosting compiler**. It does not need to be production-quality, fast, or feature-complete. It needs to be correct enough and complete enough that the self-hosting compiler (written in Astra) can be compiled by it.

### Key Recommendations

| Decision | Recommendation |
|:---------|:---------------|
| **Implementation language** | **C** (not Rust) — simpler, no dependencies, smaller binary |
| **Parser** | Hand-written recursive descent + Pratt parsing |
| **Backend** | Bytecode VM (stack-based) for dev; C codegen for bootstrap |
| **MVP scope** | Types, functions, structs, enums, match, if/while/for, basic I/O |
| **Type system** | Hindley-Milner inference, but simplified for MVP |
| **Self-hosting timeline** | 12-18 months to first self-hosted compiler |
| **Testing** | Unit tests per phase + conformance test suite from day 1 |

---

## 2. Lessons from Reference Implementations

### 2.1 How Languages Bootstrapped Their Compilers

| Language | Seed Language | Self-Hosting Since | Strategy |
|:---------|:-------------|:-------------------|:---------|
| **C** | Assembly (PDP-7) | 1973 | Wrote C compiler in C, hand-translated to assembly, then compiled with itself |
| **Pascal** | Fortran | 1970 | Wrote first compiler in Fortran, then rewrote in Pascal |
| **Go** | C (Plan 9-style) | Go 1.5 (2015) | Mechanical C→Go translation of compiler, then refined in Go |
| **Rust** | OCaml | 2011 | Wrote `rustboot` in OCaml, gradually rewrote in Rust, dropped OCaml |
| **Zig** | C++ (stage1) | 0.11.0 (2022) | C++ compiler → self-hosted compiler, checked-in WASM blob for bootstrap |
| **Swift** | C++ | Xcode 6 beta | Written in C++ with Swift-like subset; gradually migrated to Swift |
| **Nim** | Pascal | 0.9.0 | First compiler in Pascal, rewritten in Nim |

### 2.2 Key Patterns Observed

**Pattern 1: "Sacrificial compiler" (Drew Devault's advice)**
> "Write a sacrificial implementation... prepared to throw it away later. Its purpose is to prove that your design ideas work and can be implemented efficiently, but not to be the production-ready implementation."

**Pattern 2: "Verticals over waterfall" (Fernando Borretti's Austral compiler)**
> "Implement all stages of compilation from the start, but they do nothing. Then implement each language facet one at a time." This gives you a compilable program from day 1.

**Pattern 3: "Incremental bootstrap" (Ibrahim Ghuloum's incremental compiler construction)**
> "Every step yields a fully working compiler for a progressively expanding subset." Start with integers, add booleans, add functions, etc.

**Pattern 4: "Keep the seed forever" (Rust, Go)**
Both Rust (`mrustc`) and Go keep the seed compiler available for reproducible bootstrap from scratch. The seed becomes part of the trusted computing base.

### 2.3 Anti-Patterns to Avoid

1. **Over-engineering the seed**: The seed compiler should be "quick and dirty" — it's used once to bootstrap, then retired.
2. **Feature-creep**: Don't implement traits, generics, or comptime in the seed. Only what's needed to compile the self-hosting compiler.
3. **Premature optimization**: The seed doesn't need to generate fast code. Correctness only.
4. **No tests**: The seed needs rigorous tests because it's the root of the trust chain.

---

## 3. Seed Compiler Architecture

### 3.1 Pipeline Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Seed Compiler (C)                         │
│                                                             │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌────────┐  │
│  │  Lexer   │──▶│  Parser  │──▶│  Type    │──▶│  IR    │  │
│  │ (hand-   │   │ (recursive│   │  Checker │   │  Gen   │  │
│  │  written)│   │  descent) │   │  (HM)    │   │        │  │
│  └──────────┘   └──────────┘   └──────────┘   └───┬────┘  │
│                                                    │       │
│                                          ┌─────────▼─────┐ │
│                                          │   Backend     │ │
│                                          │  ┌──────────┐ │ │
│                                          │  │ Bytecode │ │ │
│                                          │  │ VM (dev) │ │ │
│                                          │  └──────────┘ │ │
│                                          │  ┌──────────┐ │ │
│                                          │  │ C Codegen│ │ │
│                                          │  │(bootstrap│ │ │
│                                          │  │  path)   │ │ │
│                                          │  └──────────┘ │ │
│                                          └───────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Why Two Backends in the Seed?

The seed compiler needs **two backends**:

1. **Bytecode VM backend** — For development iteration. You write Astra code, run it instantly. The VM is simple, self-contained, and fast to implement.

2. **C codegen backend** — For the actual bootstrap. The self-hosting compiler (written in Astra) is compiled to C, then compiled by the system's C compiler (gcc/clang) to produce the first native Astra compiler.

**This is the critical insight from Go's bootstrap:**
> "Starting with Go 1.5, Go completed a landmark transition: the compiler and runtime were rewritten in Go in their entirety, the C toolchain was deleted."

Go's approach: write `cmd/dist` in Go (a deliberately simple program), compile it with Go 1.4, then use it to build everything else. The C codegen path is the escape hatch for cross-compilation and initial bootstrap.

### 3.3 Module Structure

```
seed-compiler/
├── src/
│   ├── main.c              # Entry point, CLI parsing
│   ├── lexer.c / lexer.h   # Tokenizer
│   ├── parser.c / parser.h # Recursive descent parser
│   ├── ast.c / ast.h       # AST node definitions
│   ├── typechecker.c       # Type checking + inference
│   ├── air.c / air.h       # AIR (Astra IR) generation
│   ├── bytecode.c          # Bytecode emitter
│   ├── vm.c                # Bytecode virtual machine
│   ├── codegen_c.c         # C code generation
│   ├── diagnostics.c       # Error reporting
│   └── utils.c             # String interning, memory, etc.
├── tests/
│   ├── test_lexer.c
│   ├── test_parser.c
│   ├── test_typechecker.c
│   ├── test_codegen.c
│   └── test_integration.c
├── Makefile
└── README.md
```

---

## 4. Implementation Language: C vs Rust

### 4.1 Trade-off Analysis

| Criterion | C | Rust |
|:----------|:--|:-----|
| **Simplicity** | ✅ Trivial to build, no dependencies | ❌ Requires Rust toolchain to build |
| **Safety** | ❌ Manual memory management | ✅ Memory-safe by default |
| **Build deps** | ✅ `cc *.c -o astra-seed` | ❌ `cargo build` needs Rust installed |
| **Binary size** | ✅ ~500KB | ❌ ~5MB+ (static linking) |
| **Contributor pool** | ✅ Everyone knows C | ⚠️ Rust knowledge growing but limited |
| **Trust** | ✅ Auditable, transparent | ⚠️ Complex ownership model to audit |
| **Error handling** | ⚠️ Manual (setjmp/longjmp or error codes) | ✅ `Result<T,E>` |
| **String handling** | ⚠️ Manual, error-prone | ✅ `String` type |
| **Existing compiler infra** | ✅ Clang/GCC are C compilers | ⚠️ Need rustc to bootstrap |
| **Cross-compilation** | ✅ C cross-compilers are ubiquitous | ⚠️ Cross-compiling Rust is complex |

### 4.2 Recommendation: **C**

**Rationale:**

1. **Minimal dependencies**: The seed compiler must be buildable with just `cc *.c -o astra-seed`. No package managers, no build systems beyond Make.

2. **Trust chain**: C is the most auditable language. The seed compiler is the root of the trust chain — transparency matters more than safety here.

3. **Cross-compilation**: C cross-compilers exist for every platform Astra targets. This is essential for the bootstrap.

4. **Historical precedent**: Go (C→Go), Rust (OCaml→Rust), Zig (C++→Zig) all started with simpler languages. C is simpler than Rust.

5. **"Used once" nature**: The seed compiler is retired after bootstrapping. Investing in Rust's safety features for a throwaway compiler is wasteful.

### 4.3 Mitigating C's Weaknesses

- **Memory safety**: Use a simple arena allocator for the compiler. All allocations go to an arena, freed in bulk at the end. No individual `free()` calls needed.
- **String handling**: Use a string interning table. All strings are interned once, compared by pointer.
- **Error handling**: Use `setjmp/longjmp` for error recovery (like Lua), or a simple error flag pattern.
- **Build system**: Single `Makefile`, no autotools, no CMake.

---

## 5. Minimal Viable Language (MVP)

### 5.1 What the Seed Compiler Must Support

The self-hosting compiler needs to be compilable by the seed. Therefore, the seed must support the **intersection of Astra features used by the self-hosting compiler's source code**.

### 5.2 MVP Feature Set

**Tier 1: Absolute Minimum (Weeks 1-8)**
- [ ] Integer types (`i32`, `i64`, `u32`, `u64`)
- [ ] Float types (`f64`)
- [ ] Boolean type (`bool`)
- [ ] String type (basic, no Unicode)
- [ ] Variables (`val`, `mut`)
- [ ] Basic operators (`+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `>`, `<=`, `>=`)
- [ ] If/else expressions
- [ ] While loops
- [ ] Function declarations and calls
- [ ] Return statements
- [ ] Basic I/O (`print()`)
- [ ] Single-file programs

**Tier 2: Enough for Self-Hosting Compiler (Weeks 9-16)**
- [ ] Structs (basic, no generics)
- [ ] Enums (basic, no associated data)
- [ ] Match expressions (exhaustive matching)
- [ ] For-in loops (on ranges and arrays)
- [ ] Arrays (`[N]T` and `[T]`)
- [ ] Optional type (`T?`)
- [ ] Result type (`Result<T, E>`)
- [ ] Error propagation (`?` operator)
- [ ] Closures (basic, single captured variable)
- [ ] Module system (single-file, no imports yet)

**Tier 3: For Quality Self-Hosting Compiler (Weeks 17-24)**
- [ ] Generics (basic monomorphization)
- [ ] Traits (basic, single-trait)
- [ ] Import system (file-based modules)
- [ ] Standard library (`io`, `string`, `collections`)
- [ ] Proper error messages with source locations

### 5.3 What the Seed Compiler Does NOT Need

- [ ] Comptime/metaprogramming
- [ ] Green threads / fibers
- [ ] ARC/ORC runtime
- [ ] Units of measure
- [ ] Cross-compilation
- [ ] LLVM backend
- [ ] Incremental compilation
- [ ] LSP support
- [ ] Package manager integration
- [ ] Advanced generics (trait bounds, where clauses)

### 5.4 The "Subset of Astra" is Really "Astra-0"

The MVP language is informally called **Astra-0** or **Astra/bootstrap**. It's a strict subset of full Astra. The self-hosting compiler is written in Astra-0, using only features the seed can compile.

**Constraint on the self-hosting compiler:**
```astra
# The self-hosting compiler MUST use only Astra-0 features:
# - No comptime blocks
# - No green threads
# - No ARC/ORC (manual memory management in bootstrap compiler only)
# - No traits (use simple dispatch)
# - No generics (use concrete types)
```

---

## 6. Bootstrapping Strategy

### 6.1 The Four-Phase Strategy

```
Phase 1: Seed Compiler (C → Astra-0)
    │
    │  C compiler compiles seed
    │  Seed compiles Astra-0 code
    │
    ▼
Phase 2: Self-Hosting Compiler (Astra-0 → Astra-1)
    │
    │  Seed compiles self-hosting compiler
    │  Self-hosting compiler compiles itself
    │
    ▼
Phase 3: Full Compiler (Astra-1 → Astra-N)
    │
    │  Each version compiles the next
    │  Features added incrementally
    │
    ▼
Phase 4: Verified Bootstrap
    │
    │  Binary reproducibility
    │  Diverse double-compilation
    │  Trusted computing base minimization
```

### 6.2 Phase 1: Seed Compiler (0-6 months)

**Goal:** Write a C compiler for Astra-0 that can compile the self-hosting compiler.

**Deliverables:**
- `astra-seed` binary (~500KB)
- Lexer, parser, type checker, bytecode VM
- C codegen backend for bootstrap
- Test suite (1000+ tests)

**Success criteria:**
```bash
# The seed compiler compiles the self-hosting compiler
$ ./astra-seed compile compiler/main.ast -o compiler.c
$ gcc compiler.c -o astra-v1
$ ./astra-v1 compile compiler/main.ast -o compiler.c
$ diff compiler.c compiler.c  # Must be identical!
```

### 6.3 Phase 2: Self-Hosting Compiler (6-12 months)

**Goal:** Write the self-hosting compiler in Astra-0, compile it with the seed, verify it can compile itself.

**Deliverables:**
- Self-hosting compiler (written in Astra-0)
- Standard library (minimal)
- Package manager (basic)
- Error reporting (good diagnostics)

**Bootstrap chain:**
```bash
# Step 1: Seed compiles self-hosting compiler
$ ./astra-seed compile src/compiler/main.ast -o astra-v1.c
$ gcc astra-v1.c -o astra-v1

# Step 2: Self-hosted compiler compiles itself
$ ./astra-v1 compile src/compiler/main.ast -o astra-v2.c
$ gcc astra-v2.c -o astra-v2

# Step 3: Verify equivalence
$ ./astra-v2 compile src/compiler/main.ast -o astra-v3.c
$ diff astra-v2.c astra-v3.c  # Must be identical!
```

### 6.4 Phase 3: Full Compiler (12-24 months)

**Goal:** Add full Astra features to the compiler, each version compiling the next.

**Feature additions (each a new compiler version):**
1. Generics
2. Traits
3. Comptime
4. ARC/ORC runtime
5. Green threads
6. Units of measure
7. Cross-compilation

### 6.5 Phase 4: Verified Bootstrap (24+ months)

**Goal:** Ensure the bootstrap chain is trustworthy and reproducible.

**Techniques:**
- **Binary reproducibility**: Same source + same compiler = same binary
- **Diverse double-compilation**: Compile with two different compilers, compare outputs
- **Minimal trusted base**: Reduce seed compiler to minimal C code
- **WASM bootstrap**: Provide WASM blob of compiler for platform-independent bootstrap

---

## 7. Parser Implementation

### 7.1 Architecture: Recursive Descent + Pratt

The parser follows the architecture specified in `ARCHITECTURE.md` and `010_grammar_and_parser_design.md`:

```
Source Code
    │
    ▼
┌──────────────────┐
│     Lexer        │  Hand-written, produces token stream
│  (tokenizer)     │  with source locations
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│   Recursive      │  Grammar rules → AST nodes
│   Descent        │  Error recovery at statement level
│   Parser         │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│   Pratt Parser   │  Expression parsing with precedence
│   (embedded)     │  nud/led/lbp per operator
└────────┬─────────┘
         │
         ▼
   AST (always valid, errors reported separately)
```

### 7.2 Lexer Design

**Key decisions:**
- Token types: ~60 tokens (keywords, operators, literals, delimiters)
- Source locations: Every token carries `file`, `line`, `column`, `length`
- String interning: All identifiers and strings are interned
- Comments: Stripped during lexing (not preserved in token stream)

**Token structure (C):**
```c
typedef struct {
    TokenKind kind;
    InternedString value;    // interned string value
    SourceLoc loc;           // file, line, column
    u32 length;              // byte length in source
} Token;
```

### 7.3 Pratt Parser for Expressions

**Implementation approach:**
- Each operator has a `binding_power` (precedence) and a `parse_fn` (handler)
- `nud` (null denotation): prefix operators, literals, parentheses, identifiers
- `led` (left denotation): infix and postfix operators
- Left-associative: `right_bp = bp + 1`
- Right-associative: `right_bp = bp`

**Operator table:**
```c
typedef struct {
    const char* op;
    u8 bp;           // binding power
    bool left_assoc; // left or right associative
    ParseFn nud;     // prefix handler (NULL for infix-only)
    ParseFn led;     // infix/postfix handler
} OperatorInfo;
```

### 7.4 Error Recovery

**Strategy: Phrase-level recovery (from `010_grammar_and_parser_design.md`)**

```c
// After a parse error, skip to synchronization point
void parser_sync(Parser* p, SyncSet sync_tokens) {
    while (!at_end(p) && !in_set(p->current, sync_tokens)) {
        advance(p);
    }
    if (in_set(p->current, sync_tokens)) {
        advance(p);  // consume the sync token
    }
}

// Synchronizing tokens by context:
// Statement:   { SEMICOLON, RBRACE, FN, LET, VAL, MUT, RETURN, EOF }
// Expression:  { RPAREN, RBRACKET, RBRACE, COMMA }
// Block:       { RBRACE }
```

### 7.5 Parser Output

```c
typedef struct {
    AstNode* root;           // AST root (always valid, may have error nodes)
    Diagnostic* diagnostics; // Array of syntax errors/warnings
    u32 diagnostic_count;
} ParseResult;

// The parser NEVER fails completely.
// It always produces an AST + error list.
```

---

## 8. Type Checker Implementation

### 8.1 Simplified Hindley-Milner for MVP

Full HM inference is complex. For the seed compiler, use a **simplified version**:

**Simplifications for MVP:**
1. No let-polymorphism (no `let` generalization) — each binding is monomorphic
2. No higher-rank types
3. No subtyping (except integer widening)
4. Simple unification (Robinson's algorithm)
5. No type classes/traits (use ad-hoc overloading or explicit dispatch)

### 8.2 Core Algorithm

```
1. Parse source → AST
2. Walk AST, generating type constraints
3. Unify constraints using union-find
4. Report type errors
5. Annotate AST with resolved types
```

**Type representation:**
```c
typedef enum {
    TYPE_INT, TYPE_FLOAT, TYPE_BOOL, TYPE_STRING, TYPE_VOID,
    TYPE_FUNCTION, TYPE_STRUCT, TYPE_ENUM, TYPE_ARRAY,
    TYPE_OPTIONAL, TYPE_RESULT, TYPE_VARIABLE  // type variable for inference
} TypeKind;

typedef struct Type {
    TypeKind kind;
    union {
        struct { struct Type* param; struct Type* ret; } function;
        struct { InternedString name; struct Type** fields; u32 count; } struc;
        struct { struct Type* element; u32 length; } array;
        struct { struct Type* inner; } optional;
        struct { u32 id; struct Type* bound; } variable;  // union-find
    } as;
} Type;
```

### 8.3 Unification

```c
// Robinson's unification algorithm
Type* unify(Type* a, Type* b, Diagnostics* diag) {
    if (a == b) return a;

    if (a->kind == TYPE_VARIABLE) {
        if (occurs_in(a, b, diag)) return NULL;  // occurs check
        a->as.variable.bound = b;
        return b;
    }
    if (b->kind == TYPE_VARIABLE) {
        return unify(b, a, diag);  // swap
    }

    if (a->kind != b->kind) {
        report_type_error(diag, a, b);
        return NULL;
    }

    switch (a->kind) {
        case TYPE_FUNCTION:
            return unify_function(a, b, diag);
        case TYPE_ARRAY:
            return unify_array(a, b, diag);
        // ... etc
    }
}
```

### 8.4 Type Environment

```c
typedef struct TypeEnv {
    InternedString name;
    Type* type;
    struct TypeEnv* next;  // linked list (scope chain)
} TypeEnv;

// Push/pop scope for block-level scoping
void env_push_scope(TypeEnv** env);
void env_pop_scope(TypeEnv** env);
void env_bind(TypeEnv** env, InternedString name, Type* type);
Type* env_lookup(TypeEnv* env, InternedString name);
```

---

## 9. Code Generation

### 9.1 Bytecode VM Backend (Development)

**Design: Stack-based bytecode** (simpler than register-based for a seed compiler)

**Why stack-based for MVP:**
- Simpler code generation (no register allocation)
- Simpler VM implementation
- Easier to debug
- Performance is not the goal for the seed

**Bytecode instruction set (minimal):**
```c
typedef enum {
    // Stack
    OP_PUSH_CONST,    // push constant
    OP_POP,           // discard top
    OP_DUP,           // duplicate top

    // Local variables
    OP_GET_LOCAL,     // push local variable
    OP_SET_LOCAL,     // set local variable

    // Arithmetic
    OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD,
    OP_NEG,

    // Comparison
    OP_EQ, OP_NE, OP_LT, OP_GT, OP_LE, OP_GE,

    // Logic
    OP_AND, OP_OR, OP_NOT,

    // Control flow
    OP_JUMP,          // unconditional jump
    OP_JUMP_IF_FALSE, // conditional jump
    OP_JUMP_IF_TRUE,
    OP_CALL,          // function call
    OP_RETURN,        // return from function

    // I/O
    OP_PRINT,         // print value
    OP_READ_LINE,     // read line from stdin

    // Memory
    OP_ALLOC_ARRAY,   // allocate array
    OP_GET_INDEX,     // array index
    OP_SET_INDEX,     // array set
} Opcode;
```

**VM structure:**
```c
typedef struct {
    u8* ip;           // instruction pointer
    Value* sp;        // stack pointer
    Value stack[STACK_SIZE];
    CallFrame frames[MAX_FRAMES];
    u32 frame_count;
    ObjHeap heap;     // heap-allocated objects
} VM;

typedef enum {
    VAL_INT, VAL_FLOAT, VAL_BOOL, VAL_STRING, VAL_NONE,
    VAL_OBJ  // heap-allocated (arrays, structs, closures)
} ValueKind;

typedef struct {
    ValueKind kind;
    union {
        i64 i;
        f64 f;
        bool b;
        ObjString* str;
        Obj* obj;
    } as;
} Value;
```

### 9.2 C Codegen Backend (Bootstrap Path)

For the actual bootstrap, the seed compiler generates C code that can be compiled by gcc/clang.

**Strategy (inspired by Nim and Zig):**
```c
// Astra code:
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

// Generated C code:
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Astra runtime (minimal)
typedef struct { int64_t refcount; } AstraObj;

int64_t astra_add(int64_t a, int64_t b) {
    return a + b;
}

int main(int argc, char** argv) {
    // ... generated code ...
    return 0;
}
```

**What the C codegen needs to generate:**
1. `#include` directives for standard C headers
2. Type definitions (structs as C structs)
3. Function implementations
4. A minimal runtime (memory allocation, string handling)
5. `main()` function entry point

### 9.3 AIR (Astra Intermediate Representation)

For the seed compiler, AIR is **optional**. The seed can go directly from AST to bytecode or C code. AIR is important for the full compiler where both VM and LLVM backends consume the same IR.

**Simplified seed compiler pipeline:**
```
Source → Lexer → Parser → AST → Type Checker → AST (annotated) → Backend
                                                                          │
                                                          ┌───────────────┤
                                                          │               │
                                                      Bytecode VM    C Codegen
                                                      (development)   (bootstrap)
```

---

## 10. Error Reporting

### 10.1 Diagnostic Structure

```c
typedef enum {
    DIAG_ERROR, DIAG_WARNING, DIAG_NOTE
} DiagnosticKind;

typedef struct {
    DiagnosticKind kind;
    SourceLoc loc;          // file, line, column
    const char* message;    // primary message
    const char* help;       // optional help text
    SourceLoc* notes;       // optional additional locations
    u32 note_count;
} Diagnostic;
```

### 10.2 Error Message Quality

**From Astra's philosophy (PHILOSOPHY.md):**
> "Un buen error message enseña al programador a ser mejor."

**Example error messages:**
```
error[E001]: type mismatch
  --> main.astra:5:16
   |
 5 |     let x: i32 = "hello"
   |                 ^^^^^^^^ expected `i32`, found `String`
   |
   = help: try converting explicitly: `hello.len()` or `hello.to_int()`

error[E002]: missing return type
  --> main.astra:8:1
   |
 8 | fn greet(name) {
   |          ^^^^ parameter needs type annotation
   |
   = help: add type: `fn greet(name: String)`

error[E003]: undefined variable
  --> main.astra:12:5
   |
12 |     y = x + 1
   |     ^ not found in this scope
   |
   = help: did you mean `x`? (if x was defined nearby)
```

### 10.3 Source Location Tracking

Every AST node carries a `SourceLoc`:
```c
typedef struct {
    u32 file_id;   // index into file table
    u32 line;      // 1-based line number
    u32 column;    // 1-based column number
    u32 offset;    // byte offset from start of file
    u32 length;    // byte length of the token/node
} SourceLoc;
```

### 10.4 Error Recovery Integration

The parser, type checker, and code generator all share the same diagnostic system. Each phase can emit diagnostics and continue processing:

```c
// Parser: emit error, skip to sync point, continue
void parser_error(Parser* p, const char* msg) {
    diag_emit(p->diag, DIAG_ERROR, p->current.loc, msg, NULL);
    parser_sync(p, get_sync_set(p->context));
}
```

---

## 11. Testing Strategy

### 11.1 Testing Pyramid

```
                    /\
                   /  \
                  / Fuzz\          <- Long-running (AFL++)
                 /--------\
                / Property  \       <- Input invariants
               /--------------\
              / Integration     \    <- Full compilation + execution
             /--------------------\
            / Conformance/Regression \  <- Language spec tests
           /--------------------------\
          / Unit Tests                 \ <- Per-component tests
         /------------------------------\
```

### 11.2 Unit Tests (Per Phase)

```c
// test_lexer.c
void test_lex_integer() {
    Token tokens[] = lex("42");
    assert(tokens[0].kind == TOKEN_INT);
    assert(tokens[0].as.integer == 42);
}

void test_lex_string() {
    Token tokens[] = lex("\"hello world\"");
    assert(tokens[0].kind == TOKEN_STRING);
    assert(strcmp(tokens[0].as.string, "hello world") == 0);
}

// test_parser.c
void test_parse_function() {
    AstNode* ast = parse("fn add(a: i32, b: i32) -> i32 { return a + b }");
    assert(ast->kind == AST_FUNCTION);
    assert(ast->as.fn.params.count == 2);
}

// test_typechecker.c
void test_type_inference() {
    AstNode* ast = parse("let x = 42");
    Type* t = typecheck(ast);
    assert(t->kind == TYPE_INT);
}
```

### 11.3 Conformance Tests

```bash
# tests/conformance/
# Each file tests one language feature

# tests/conformance/expressions/arithmetic.astra
# EXPECT: 42
fn main() {
    let x = 6 * 7
    print(x)
}

# tests/conformance/types/struct.astra
# EXPECT: Point(1, 2)
struct Point { x: i32, y: i32 }
fn main() {
    let p = Point { x: 1, y: 2 }
    print(p)
}

# tests/conformance/control/match.astra
# EXPECT: positive
fn classify(n: i32) -> String {
    match n {
        n if n > 0 => "positive",
        n if n < 0 => "negative",
        _ => "zero"
    }
}
fn main() { print(classify(5)) }
```

### 11.4 Error Message Tests

```bash
# tests/ui/compile_error/
# Each file expects specific error messages

# tests/ui/compile_error/type_mismatch.astra
# EXPECT_ERROR: E001
# EXPECT_MESSAGE: expected `i32`, found `String`
fn main() {
    let x: i32 = "hello"
}
```

### 11.5 Differential Testing

```bash
# Compare output between VM and C codegen
for file in tests/conformance/*.astra; do
    ./astra-seed run "$file" > vm_output.txt
    ./astra-seed compile "$file" -o test_out.c
    gcc test_out.c -o test_out
    ./test_out > c_output.txt
    diff vm_output.txt c_output.txt
done
```

### 11.6 Bootstrap Tests

```bash
# The most important test: can the seed compile the self-hosting compiler?
./astra-seed compile src/compiler/main.ast -o astra-v1.c
gcc astra-v1.c -o astra-v1
./astra-v1 compile src/compiler/main.ast -o astra-v2.c
diff astra-v1.c astra-v2.c  # Must be byte-for-byte identical
```

---

## 12. Toolchain Integration

### 12.1 CLI Interface

The seed compiler provides the same CLI as the final `astra` toolchain:

```bash
astra-seed run script.ast          # Run via bytecode VM
astra-seed build script.ast -o out # Compile to native binary
astra-seed build --release script.ast  # Optimized build
astra-seed compile script.ast -o script.c  # Generate C code (bootstrap)
```

### 12.2 File Layout

```
astra-seed/
├── bin/
│   └── astra-seed          # The seed compiler binary
├── lib/
│   └── std/                # Minimal standard library (Astra source)
│       ├── io.astra
│       ├── string.astra
│       └── math.astra
├── include/
│   └── astra_runtime.h     # C runtime header for C codegen
└── src/
    └── runtime/
        └── runtime.c       # Minimal C runtime (print, alloc, etc.)
```

### 12.3 Standard Library (Minimal)

The seed compiler ships with a minimal standard library that the self-hosting compiler can use:

```astra
// std/io.astra
pub fn print(value: String) { /* builtin */ }
pub fn print(value: i32) { /* builtin */ }
pub fn read_line() -> String { /* builtin */ }

// std/string.astra
pub fn len(s: String) -> i32 { /* builtin */ }
pub fn concat(a: String, b: String) -> String { /* builtin */ }

// std/math.astra
pub fn abs(x: i32) -> i32 { /* builtin */ }
pub fn sqrt(x: f64) -> f64 { /* builtin */ }
```

### 12.4 Build Integration

The seed compiler is used as part of the build process:

```makefile
# Makefile for Astra project
SEED = ./astra-seed
COMPILER_SRC = src/compiler/main.ast

# Bootstrap: seed compiles self-hosting compiler
bootstrap: $(COMPILER_SRC)
	$(SEED) compile $(COMPILER_SRC) -o astra-v1.c
	cc astra-v1.c -o astra-v1

# Self-host: self-hosting compiler compiles itself
self-host: astra-v1
	./astra-v1 compile $(COMPILER_SRC) -o astra-v2.c
	cc astra-v2.c -o astra-v2

# Verify: check that self-hosting is consistent
verify: astra-v2
	./astra-v2 compile $(COMPILER_SRC) -o astra-v3.c
	diff astra-v2.c astra-v3.c
```

### 12.5 Integration with Package Manager

The seed compiler is a standalone binary. It doesn't need the package manager for itself, but the self-hosting compiler it produces should support `astra.toml`:

```
# astra.toml (used by self-hosting compiler)
[package]
name = "astra-compiler"
version = "0.1.0"

[dependencies]
# Minimal dependencies for bootstrap
```

### 12.6 Integration with LSP

The seed compiler doesn't provide LSP, but the self-hosting compiler should. The parser design (recursive descent, always produces AST) is LSP-friendly:

- Parser never fails → always has AST for tools
- Source locations on every node → error squiggles
- Incremental parsing possible → fast re-parsing on edits

---

## 13. Phased Development Plan

### Phase 1: Lexer + Parser + AST (Weeks 1-4)

**Week 1: Infrastructure**
- [ ] Project setup (Makefile, directory structure)
- [ ] Arena allocator
- [ ] String interning
- [ ] Source location tracking
- [ ] Basic diagnostics

**Week 2: Lexer**
- [ ] Token types (keywords, operators, literals, delimiters)
- [ ] Integer/float/string literal parsing
- [ ] Comment handling
- [ ] Lexer tests

**Week 3: Pratt Parser Core**
- [ ] Expression parsing (Pratt algorithm)
- [ ] Operator binding power table
- [ ] Prefix/infix/postfix handlers
- [ ] Parenthesized expressions
- [ ] Parser tests for expressions

**Week 4: Statement + Declaration Parsing**
- [ ] Variable declarations (`val`, `mut`)
- [ ] If/else, while, for expressions
- [ ] Function declarations
- [ ] Return, break, continue
- [ ] Block expressions
- [ ] Basic error recovery (panic mode)
- [ ] Integration tests

### Phase 2: Type Checker + Bytecode VM (Weeks 5-8)

**Week 5: Type System Foundation**
- [ ] Type representations (int, float, bool, string, void)
- [ ] Type environment (scope chain)
- [ ] Type inference for literals and operators
- [ ] Basic unification

**Week 6: Type Checker**
- [ ] Function type checking
- [ ] If/while/for type checking
- [ ] Variable type inference
- [ ] Type errors with good messages

**Week 7: Bytecode VM**
- [ ] Bytecode instruction set
- [ ] Bytecode emitter (AST → bytecode)
- [ ] Stack-based VM
- [ ] Basic I/O builtins

**Week 8: Integration**
- [ ] Full pipeline: source → lexer → parser → type checker → bytecode → VM
- [ ] Run simple programs end-to-end
- [ ] Integration test suite

### Phase 3: Structs, Enums, Match (Weeks 9-12)

**Week 9: Structs**
- [ ] Struct declaration parsing
- [ ] Struct type checking
- [ ] Struct field access
- [ ] Struct literal syntax

**Week 10: Enums**
- [ ] Enum declaration parsing
- [ ] Enum type checking
- [ ] Enum variant access

**Week 11: Match**
- [ ] Match expression parsing
- [ ] Pattern matching in type checker
- [ ] Exhaustiveness checking
- [ ] Match in bytecode VM

**Week 12: Arrays + Optionals**
- [ ] Array type and literals
- [ ] Array indexing
- [ ] Optional type (`T?`)
- [ ] Result type (`Result<T, E>`)
- [ ] Error propagation (`?`)

### Phase 4: C Codegen + Bootstrap (Weeks 13-16)

**Week 13: C Code Generation**
- [ ] AST → C translation
- [ ] Type → C type mapping
- [ ] Function → C function translation
- [ ] Minimal runtime in C

**Week 14: Runtime + Standard Library**
- [ ] `print()`, `read_line()` in C runtime
- [ ] String handling in C
- [ ] Array allocation in C
- [ ] Error handling in C

**Week 15: Bootstrap Preparation**
- [ ] Write minimal self-hosting compiler skeleton in Astra-0
- [ ] Test seed compiler can compile it
- [ ] Fix any issues

**Week 16: Bootstrap Execution**
- [ ] Compile self-hosting compiler with seed
- [ ] Verify self-hosting compiler works
- [ ] Self-hosting compiler compiles itself
- [ ] Verify binary equivalence
- [ ] **BOOTSTRAP COMPLETE**

### Phase 5: Polish + Testing (Weeks 17-24)

**Weeks 17-18: Error Messages**
- [ ] Rich error messages with source locations
- [ ] Help text and suggestions
- [ ] Error recovery improvements

**Weeks 19-20: Standard Library**
- [ ] `io` module
- [ ] `string` module
- [ ] `math` module
- [ ] `collections` (basic)

**Weeks 21-22: Testing**
- [ ] Conformance test suite
- [ ] Differential testing (VM vs C codegen)
- [ ] Fuzzing setup
- [ ] Property-based tests

**Weeks 23-24: Documentation + Release**
- [ ] Seed compiler documentation
- [ ] Bootstrap instructions
- [ ] Release packaging
- [ ] **SEED COMPILER v1.0**

---

## 14. Timeline

### Realistic Estimates

| Phase | Duration | Milestone |
|:------|:---------|:----------|
| **Phase 1** (Lexer + Parser) | 4 weeks | Parser produces AST for full grammar |
| **Phase 2** (Types + VM) | 4 weeks | Can run simple Astra programs |
| **Phase 3** (Structs + Enums + Match) | 4 weeks | Full Astra-0 feature set |
| **Phase 4** (C Codegen + Bootstrap) | 4 weeks | Self-hosting compiler bootstrapped |
| **Phase 5** (Polish + Testing) | 8 weeks | Production-quality seed compiler |
| **TOTAL** | **24 weeks (6 months)** | Seed compiler v1.0 |

### Risk Buffer

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| Type inference bugs | +2-4 weeks | Start with simple inference, no polymorphism |
| C codegen issues | +1-2 weeks | Test early with simple programs |
| Bootstrap self-compilation | +2-4 weeks | This is the hardest part; allocate extra time |
| Error recovery quality | +1-2 weeks | Start with panic-mode, improve iteratively |

**Best case:** 5 months (20 weeks)
**Realistic case:** 6-7 months (24-28 weeks)
**Worst case:** 9-12 months (if major design issues discovered)

### Milestones

| Month | Milestone |
|:------|:----------|
| Month 1 | Lexer + parser working, can parse full grammar |
| Month 2 | Type checker + bytecode VM, can run simple programs |
| Month 3 | Full Astra-0 feature set, all tests passing |
| Month 4 | C codegen working, can compile simple programs to C |
| Month 5 | Self-hosting compiler skeleton compilable by seed |
| Month 6 | **Bootstrap successful** — self-hosting compiler compiles itself |
| Month 7-8 | Polish, testing, documentation |
| Month 9 | **Seed compiler v1.0 released** |

---

## 15. Risk Analysis

### 15.1 Technical Risks

| Risk | Probability | Impact | Mitigation |
|:-----|:-----------|:-------|:-----------|
| Type inference too complex for MVP | Medium | High | Use simplified HM, no let-polymorphism |
| C codegen produces incorrect code | Medium | High | Extensive differential testing |
| Self-hosting compiler too large for seed | Low | Medium | Keep self-hosting compiler minimal |
| Bootstrap loop doesn't terminate | Low | High | Test early and often |
| Error recovery produces cascading errors | Medium | Medium | Phrase-level recovery, extensive testing |

### 15.2 Design Risks

| Risk | Probability | Impact | Mitigation |
|:-----|:-----------|:-------|:-----------|
| Astra-0 subset too small for self-hosting | Medium | High | Design self-hosting compiler to minimize feature use |
| Astra-0 subset too large (scope creep) | Medium | Medium | Strict feature cutoff, defer to Phase 3 |
| Grammar ambiguity in parser | Low | High | PEG grammar, hand-written parser for control |
| Memory safety bugs in seed compiler | High | Low | Arena allocator, minimal individual allocations |

### 15.3 Process Risks

| Risk | Probability | Impact | Mitigation |
|:-----|:-----------|:-------|:-----------|
| Timeline slip (6 months → 12 months) | High | Medium | Acceptable — this is a complex project |
| Loss of motivation | Medium | High | Celebrate small wins, test early, iterate |
| Design changes during implementation | High | Medium | Keep seed compiler minimal, design changes affect full compiler only |

### 15.4 Bootstrap-Specific Risks

| Risk | Description | Mitigation |
|:-----|:------------|:-----------|
| **Trusting Trust** | Seed compiler could contain undetectable backdoor | Use diverse compilers (gcc AND clang), audit seed compiler |
| **ABI mismatch** | Generated C code ABI doesn't match expectations | Test on multiple platforms, use standard C ABI |
| **Self-compilation divergence** | Seed-compiled and self-compiled compilers differ | Byte-for-byte comparison, deterministic compilation |
| **Feature creep in self-hosting compiler** | Self-hosting compiler uses features seed can't compile | Strict feature cutoff, review self-hosting compiler code |

---

## Appendix A: Reference Implementations

### A.1 Zig's Bootstrap Strategy (Most Relevant)

Zig's approach is the most relevant to Astra because:
1. Both target systems programming
2. Both have LLVM as primary backend
3. Both want fast compilation in dev mode

**Zig's strategy:**
1. Stage 1: C++ compiler (uses LLVM) — this is the "seed"
2. Stage 2: Self-hosted compiler (written in Zig)
3. Bootstrap: Check-in `zig1.wasm` (WASM blob of compiler)
4. Reproducibility: Anyone can rebuild `zig1.wasm` from source

**Astra should follow a similar pattern:**
1. Seed: C compiler (generates C code, compiled by gcc/clang)
2. Self-hosted: Written in Astra-0, compiled by seed
3. Bootstrap: Provide `astra-seed` binary + source
4. Reproducibility: Anyone can rebuild from seed + source

### A.2 Go's Bootstrap Strategy

Go's approach is instructive:
1. Go 1.0-1.4: Compiler written in C
2. Go 1.5: Mechanical C→Go translation of compiler
3. Build process: 3 rounds of self-compilation for verification
4. Bootstrap requirement: `GOROOT_BOOTSTRAP` pointing to previous Go

**Key lesson from Go:** The build system (`cmd/dist`) is deliberately simple and restricts itself to features available in the bootstrap Go version. Astra's self-hosting compiler should similarly restrict itself to Astra-0 features.

### A.3 Rust's Bootstrap Strategy

Rust's approach:
1. Original compiler (`rustboot`): Written in OCaml
2. Self-hosting: Gradually rewrote in Rust, dropped OCaml by 2011
3. Modern bootstrap: Downloads beta `rustc`, uses it to build current
4. `mrustc`: Independent C++ compiler for verified bootstrap

**Key lesson from Rust:** Having an independent reimplementation (`mrustc`) is valuable for verification. Astra could benefit from a second, independent seed compiler implementation (perhaps in Python or OCaml) for cross-checking.

---

## Appendix B: Seed Compiler Source Layout

```
astra-seed/
├── Makefile                    # Simple, no dependencies
├── README.md                   # Build and usage instructions
│
├── src/
│   ├── main.c                  # Entry point, CLI
│   ├── common.h                # Common types, macros
│   ├── arena.c / arena.h       # Arena allocator
│   ├── interning.c / interning.h  # String interning
│   ├── source.c / source.h     # Source file loading
│   │
│   ├── lexer.c / lexer.h       # Tokenizer
│   │
│   ├── ast.c / ast.h           # AST node definitions
│   ├── parser.c / parser.h     # Recursive descent + Pratt
│   │
│   ├── type.c / type.h         # Type representations
│   ├── typechecker.c           # Type checking + inference
│   ├── unify.c / unify.h       # Unification algorithm
│   │
│   ├── air.c / air.h           # AIR (optional, can skip for MVP)
│   │
│   ├── bytecode.c / bytecode.h # Bytecode emitter
│   ├── vm.c / vm.h             # Bytecode virtual machine
│   │
│   ├── codegen_c.c             # C code generation
│   │
│   ├── diagnostics.c / diagnostics.h  # Error reporting
│   └── driver.c                # Compilation driver (orchestrates phases)
│
├── tests/
│   ├── test_main.c             # Test runner
│   ├── test_lexer.c
│   ├── test_parser.c
│   ├── test_typechecker.c
│   ├── test_vm.c
│   ├── test_codegen.c
│   └── test_integration.c
│
├── tests/conformance/          # Language conformance tests
│   ├── expressions/
│   ├── statements/
│   ├── types/
│   └── control/
│
├── runtime/
│   ├── astra_runtime.h         # C runtime header
│   └── astra_runtime.c         # Minimal C runtime
│
└── stdlib/
    ├── io.astra
    ├── string.astra
    └── math.astra
```

---

## Appendix C: Key Design Decisions Summary

| Decision | Choice | Rationale |
|:---------|:-------|:----------|
| Implementation language | C | Minimal deps, auditable, ubiquitous |
| Parser type | Recursive descent + Pratt | Full control, LSP-friendly, no generator dep |
| Type system | Simplified HM | Good enough for MVP, no let-polymorphism |
| VM type | Stack-based | Simpler than register-based, correctness only |
| Backend | Bytecode VM + C codegen | VM for dev, C for bootstrap |
| Error recovery | Phrase-level | Good quality, not over-engineered |
| Testing | Unit + conformance + differential | Comprehensive coverage |
| Standard library | Minimal builtins only | Keep seed small, expand in self-hosting compiler |
| Memory management | Arena allocator | Simple, no individual free, fast |
| String handling | Interning | Fast comparison, no duplicates |

---

*This report provides the comprehensive foundation for implementing Astra's seed compiler. The key insight is that the seed compiler is a **temporary, minimal, correct** tool — not a production compiler. Its sole purpose is to break the circular dependency and enable the self-hosting compiler to exist.*
