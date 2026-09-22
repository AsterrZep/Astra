# Phase 2 Kickoff: Zig Self-Hosting Compiler

> **Status**: Ready to begin  
> **Depends on**: Phase 1 (C seed compiler) — completed  
> **Target**: Full Astra language (Astra-1)

## Overview

Phase 1 is complete. The C seed compiler (`astra-seed`) compiles the Astra-0 subset through a bytecode VM and C backend. Phase 2 replaces this with a Zig-based self-hosting compiler that supports the full Astra language.

```
Phase 1 (DONE)                    Phase 2 (NOW)
─────────────────────────────────────────────────────────
C seed compiler (astra-seed)   →  Zig compiler (astra-zig)
Compiles: Astra-0              →  Compiles: Full Astra
Backend: VM + C codegen        →  Backend: LLVM + C output
Features: 44 constructs        →  Features: all + generics, traits, comptime
```

## What We Inherited from Phase 1

The seed compiler provides:

- **44 grammar constructs** fully implemented and tested
- **27 operators** with correct precedence
- **89 passing tests** (conformance + codegen + UI errors)
- **Dual backend** (VM + `--emit-c`)
- **Self-checking registry** (`--check-constructs`)
- **Arena allocation** model
- **Recursive descent + Pratt** parser architecture
- **Scoped symbol table** with type inference

### What Works in Astra-0 (Verified)

| Category | Features |
|:---------|:---------|
| **Types** | `i32`, `i64`, `u32`, `u64`, `f32`, `f64`, `bool`, `string`, `void`, `nil` |
| **Variables** | `let`, `let mut` |
| **Operators** | Arithmetic, comparison, logical (`&&`, `\|\|`), bitwise (`&`, `\|`, `^`, `<<`, `>>`), unary `-` |
| **Control** | `if`/`else` (statement + expression), `while`, `for..in`, `break`, `continue` |
| **Functions** | Typed parameters, return types, recursion, lambdas |
| **Data** | Arrays, structs (nested), enums (unit + data-carrying) |
| **Pattern matching** | `match` (exhaustive), or-patterns (`A \| B`), guards (`if cond`), bindings |
| **Error handling** | `Option`/`Result`, `?` operator |
| **I/O** | `print()` |
| **Module-level** | Top-level statements, struct/enum definitions |

### What Does NOT Work (Phase 2 scope)

| Feature | Why |
|:--------|:----|
| Generics / monomorphization | Needed for type-safe containers |
| Traits / interfaces | Needed for polymorphism |
| `comptime` | Zig has its own; Astra needs its own eventually |
| ARC/ORC memory management | Needed for safe memory handling |
| Closures (capturing variables) | Not needed for bootstrap |
| Module system / imports | Needed for multi-file projects |
| `unsafe` blocks / pointers | Needed for systems programming |
| FFI | Needed for C interop |
| Green threads / fibers | Needed for async I/O |
| `!` prefix operator | Registered but not working in seed |
| Nested functions | Not in Astra-0 |

## Phase 2 Architecture

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

## Implementation Checklist

### Step 1: Project Setup
- [ ] Initialize `zig/` directory with `build.zig`
- [ ] Set up project structure: `src/`, `tests/`, `lib/`
- [ ] Configure LLVM bindings (via `@cImport` or `lazy` dependency)
- [ ] Set up CI pipeline (zig build + test)

### Step 2: Lexer (Phase 2)
- [ ] Port lexer to Zig (or reuse seed's token definitions)
- [ ] Support all Astra-1 tokens
- [ ] Better error locations (line + column)
- [ ] Unicode identifier support

### Step 3: Parser (Phase 2)
- [ ] Port recursive descent + Pratt to Zig
- [ ] Add generics syntax parsing: `fn map<T, U>(...)`
- [ ] Add trait syntax parsing: `trait Comparable { ... }`
- [ ] Add `comptime` block parsing
- [ ] Add `unsafe` block parsing
- [ ] Add module/import parsing
- [ ] Error recovery (continue parsing after errors)

### Step 4: AST (Phase 2)
- [ ] Define full AST node types in Zig
- [ ] Support all new syntax nodes
- [ ] Source location tracking
- [ ] Pretty-printing for diagnostics

### Step 5: Semantic Analysis
- [ ] Name resolver (scopes, imports)
- [ ] Type checker (with generics)
- [ ] Borrow checker (if applicable)
- [ ] Trait resolution
- [ ] Monomorphization

### Step 6: AIR (Astra Intermediate Representation)
- [ ] Design AIR format
- [ ] AST → AIR lowering
- [ ] ARC insertion
- [ ] Fiber yield point insertion
- [ ] Generic specialization

### Step 7: Backends
- [ ] Bytecode VM (for dev mode, fast iteration)
- [ ] LLVM backend (for production, optimized output)
- [ ] C output (for bootstrap safety net)
- [ ] Cross-compilation support

### Step 8: Runtime
- [ ] ARC/ORC runtime
- [ ] Fiber scheduler
- [ ] Standard library basics (`io`, `fs`, `net`)
- [ ] Package manager

### Step 9: Bootstrap
- [ ] Compile the Zig compiler with itself
- [ ] Verify identical output
- [ ] Retire the C seed compiler

## Key Design Decisions

| Decision | Choice | Rationale |
|:---------|:-------|:----------|
| **Lexer** | Hand-written (Zig) | Full control, no dependencies |
| **Parser** | Recursive descent + Pratt | Same as seed, proven pattern |
| **Type system** | Hindley-Milner + traits | Sound, well-understood |
| **Memory** | Arena allocators (Zig) | Efficient for compiler workloads |
| **Error handling** | Zig error unions | Type-safe, no exceptions |
| **Backend** | LLVM (via Zig's C interop) | Best optimization, cross-compilation |
| **Bootstrap** | Compile self with self | Prove correctness |

## Migration Path from Phase 1

The Zig compiler should:

1. **Accept the same Astra-0 syntax** as the seed compiler
2. **Pass all 89 existing tests** (conformance + codegen)
3. **Support `--emit-c`** output (safety net)
4. **Then extend** with new features (generics, traits, etc.)

This ensures the bootstrap chain is never broken.

## Risk Mitigation

| Risk | Mitigation |
|:-----|:-----------|
| Zig bootstrap breaks | Use `--emit-c` to compile Zig compiler to C |
| LLVM version issues | Pin LLVM version, use Zig's bundled LLVM |
| Feature creep | Ship Astra-1 without all features, iterate |
| Testing gaps | Port all 89 seed tests, add Phase 2 tests |

## Timeline Estimate

| Phase | Duration | Milestone |
|:------|:---------|:----------|
| Setup + Lexer | 2-3 weeks | Tokenizes Astra-0 |
| Parser + AST | 3-4 weeks | Parses Astra-0 |
| Type checker | 4-6 weeks | Type-checks Astra-0 |
| AIR + VM | 4-6 weeks | Runs Astra-0 (passes all 89 tests) |
| LLVM backend | 4-6 weeks | Optimized compilation |
| New features | 8-12 weeks | Generics, traits, comptime |
| **Total** | **6-9 months** | Self-hosting compiler |

## Next Steps

1. **Today**: Commit Phase 1 completion (all fixes + evolution scripts)
2. **This week**: Initialize `zig/` directory, set up `build.zig`
3. **Next week**: Start lexer port
4. **Month 1**: Parser + AST in Zig
5. **Month 2-3**: Type checker + AIR + VM
6. **Month 4-6**: LLVM backend + new features
7. **Month 6-9**: Bootstrap + retire seed

---

*This document is the starting point for Phase 2. Update it as implementation progresses.*
