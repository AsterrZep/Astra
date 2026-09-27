# AGENTS.md — Astra project knowledge for coding agents

This file is read by Codebuff / Freebuff and other agents. It describes how to
build, test and extend the project, and how to split work into parallel
sub-agent workstreams.

## What this repository is

**Astra** is a compiled, multi-paradigm programming language (Python/TypeScript
ergonomics, C/Rust performance, no borrow checker, no tracing-GC pauses).

The repository currently holds **design documentation** (`Documentacion/`),
**Phase 1 of the implementation** — the *seed compiler* (`seed/`), written in C,
which compiles a bootstrap subset called **Astra-0** — and **Phase 2** (`zig/`),
the self-hosting compiler written in Zig, whose Astra-0 frontend is ported (see
`Documentacion/PHASE2_PROGRESS.md`).

Full background lives in:
- `Documentacion/ARCHITECTURE.md` — language specification
- `Documentacion/COMPILER_STRATEGY.md` — the C → Zig → Astra bootstrap plan
- `Documentacion/research/010_grammar_and_parser_design.md` — grammar/parser
- `Documentacion/research/011_seed_compiler_design.md` — seed compiler design
- `Documentacion/PHASE1_PROGRESS.md` — current implementation status

## Build and test

```bash
cd seed
make            # development build (-g -O0) -> seed/astra-seed
make debug      # ASan + UBSan + LSan (recommended while developing)
make release    # gcc -O2
make test       # runs tests/run_tests.sh

# Each variant compiles into its own object tree (build/debug, build/release)
# and drops the binary before linking, so switching variants always rebuilds.
# Never share build/ between variants: the flags are not part of an object's
# timestamp, and mixing them used to link-fail with "creating DT_TEXTREL".
```

`run_tests.sh` runs two paths: the VM (every case in `tests/conformance/`) and
the C backend (`tests/codegen/*.astra` through `--emit-c` + `gcc`). When you add
a codegen-only behaviour, add its case to `tests/codegen/`.

Compiling generated C requires `-Isrc` (the emitted file includes
`codegen_runtime.h`, which lives in `seed/src/`):

```bash
./astra-seed --emit-c input.astra
gcc -Wall -Wextra -Isrc -o output input.c -lm
```

Runtime debugging switches:

```bash
ASTRA_DUMP_VM=1 ./astra-seed file.astra   # dump bytecode
ASTRA_TRACE=1   ./astra-seed file.astra   # trace VM stack per instruction
./astra-seed --dump-tokens file.astra     # lexer output
./astra-seed --dump-ast file.astra        # AST output
```

Compiler-introspection switches (no input file, they describe the compiler):

```bash
./astra-seed --check-constructs   # construct registry invariants; exit 1 on drift
./astra-seed --dump-constructs    # every construct: EBNF, research, deps, phases
./astra-seed --dump-operators     # operator precedence table + documented deviations
```

## Phase 2 (`zig/`) — Zig self-hosting compiler

Requires **Zig 0.16.x**. The Astra-0 frontend (lexer, flat AST, parser) is
implemented; the type checker, emitter and VM are next.

```bash
cd zig
export PATH="$HOME/zig:$PATH"   # this environment keeps Zig at ~/zig/zig
zig build                       # -> zig-out/bin/astra-zig
zig build test                  # unit tests + conformance over seed/tests/conformance
zig build -Doptimize=ReleaseFast

./zig-out/bin/astra-zig file.astra            # parse check (exit 1 on error)
./zig-out/bin/astra-zig --dump-tokens file.astra
./zig-out/bin/astra-zig --dump-ast file.astra
```

Layout: `src/lexer/`, `src/ast/`, `src/parser/`, `src/main.zig`,
`src/conformance.zig` (parses every non-UI seed conformance file). The target
directories `src/typechecker/`, `src/emitter/`, `src/vm/` are empty so far.

Porting rule: **the Zig compiler must accept everything the seed accepts before
new features are added** (the suite is the gate). Match `seed/src/*.c` and the
`research/010`–`012` reports for behaviour.

## Seed compiler layout (`seed/src`)

| File | Responsibility |
|:-----|:---------------|
| `constructs/` | **one file per grammar production** — the construct registry |
| `arena.c` | bump/arena allocator; all compiler memory is freed in bulk |
| `string_table.c` | string interning (pointer-compare equality) |
| `lexer.c` | hand-written tokenizer, keyword table |
| `parser.c` | recursive descent + Pratt expressions |
| `ast.c` | AST node construction, source locations |
| `typechecker.c` | symbol table (scoped) + type checking |
| `emitter.c` | AST → stack bytecode; loop/jump patching |
| `vm.c` | stack VM, value model, builtins |
| `codegen.c` | `--emit-c`: bytecode → C code generation |
| `codegen.h` | public codegen API |
| `codegen_runtime.h` | C runtime included by generated .c files |
| `driver.c`, `main.c` | pipeline wiring and CLI |

Interfaces between phases are declared in `seed/include/astra/astra.h`.
Private-to-compiler types (Arena, Lexer, Emitter, VM, SymbolTable) live in
`seed/src/priv.h`.

## Invariants to preserve

These are easy to break and expensive to debug:

1. **Stack balance.** Every emitter path must leave the VM stack at a
   predictable height. Statement-position nodes that produce no value
   (`while`, `for`, `return`, `break`, `continue`) must not be given a
   trailing `POP`. Assignment *is* an expression and yields its value.
2. **Jump offsets.** A jump at instruction `P` targeting `T` uses
   `offset = T - P` (see `OPCODE_JUMP` handling in `vm.c`). Off-by-one here
   silently corrupts control flow.
3. **Function frames.** Slot 0 of a frame is the callee/return slot, so
   parameters start at slot 1. Top-level functions/vars/consts are *globals*;
   locals belong to a single function frame.
4. **Scope removal.** `symbol_table_pop_scope` removes symbols by monotonic
   insertion sequence, never by hash-bucket order.
5. **Arena-only allocation.** Compiler phases do not `free()`; everything is
   arena-allocated and released together.
6. **Registry agreement.** A construct's keyword must lex to the token it
   declares, and the operator table in `constructs/operator_table.c` must match
   the parser's precedence table. `--check-constructs` enforces both; never
   silence it.
7. **Bounded recursion.** The parser is the trust boundary: `PARSER_MAX_DEPTH`
   (256) caps nesting in `parser.c`, and breaching it aborts parsing. Both the
   expression and the block entry points are guarded, because nested blocks reach
   the parser by a different path. Without this, 20k of `(`, `{`, calls, arrays
   or `if` chains segfaulted the compiler.

## C Codegen (`--emit-c`)

The C codegen generates executable C from Astra bytecode. The pipeline is:

```
.astra → Lexer → Parser → Typecheck → Emitter → Bytecode → [C Codegen] → .c → gcc
```

### Architecture

1. **Runtime header** (`codegen_runtime.h`): Types (AstraValue, AstraStruct,
   AstraEnumObj, AstraFn), constructors, arithmetic/comparison/logic ops,
   print, error handling with setjmp/longjmp.
2. **API** (`codegen.h`): `codegen_create()`, `codegen_emit_to_file()`,
   `codegen_destroy()`.
3. **Driver** (`codegen.c`): Scans bytecodes for globals, emits struct/enum
   type declarations, struct def static globals, function forward declarations,
   function bodies, module-level code, and main().

### What works (verified against VM)

All 42 non-UI conformance cases are compiled through `--emit-c`, run, and
compared against the VM's output by `make test` (identical output, no leaks under
LSan). That covers:

- Arithmetic, comparisons, booleans, strings, nil, **bitwise operators**
- `let` variables (local and global), **module-level statements**
- `if`/`else` (as statement and expression), `for..in`, `while`
- Builtins (`print`)
- Function calls, recursion, **lambdas**
- Arrays (literal + indexed access), **structs** (literal + field access/write)
- **Enums** (unit variants and data-carrying), **`match`** with bindings/guards/or-patterns
- **Option/Result** tagged values, pattern matching and the **`?` operator**

### Key codegen invariants

1. **Stack-local separation**: `sp` must start at `max_slot` (not 0) so stack
   operations don't overwrite local variable slots. The max slot is computed
   by scanning GET_LOCAL/SET_LOCAL instructions in the bytecode.
2. **Jump target**: C jump target = `ip + offset` (VM does `ip += offset; ip--`).
3. **Function call frame**: Builtins use `frame + _fn_slot + 1`, user functions
   use `frame + _fn_slot`. Detection: `param_count == 255 && code == NULL`.
4. **Struct def emission**: StructDefs are emitted as static globals with field
   name arrays. They're discovered by scanning module + function bytecodes for
   VAL_STRUCT_DEF constants.
5. **Field access**: GET_FIELD/SET_FIELD use runtime strcmp lookup (not index),
   matching the VM's behavior.
6. **String literals must be escaped**: source strings are written with
   `cg_write_c_escaped()`. Writing them raw made a valid Astra program produce
   invalid C and let a `"` in a string inject arbitrary C into the output.
7. **Name registries are fixed-size**: `fn_map[512]`, `global_map[256]`,
   `struct_defs[256]`, `enum_defs[256]`, `fn_obj_reg[512]`. A breach is recorded in
   `Codegen.error_count` and fails the run; indexing past one was a reachable
   out-of-bounds write (registering a name must never grow a count past its cap).
8. **Every opcode the VM knows must have a handler**, or codegen fails: a
   placeholder comment silently drops the instruction and yields a program that
   computes the wrong answer. Both switches end in a hard error for this reason.

### What remains for Phase 1 completion

| Item | Issue | Effort |
|:-----|:------|:-------|
| Module-level runtime errors | `astra_runtime_error` used outside a setjmp context in generated module code — **unverified** | Low |

Everything else that was on this list (lambdas, match, Option/Result, `?`,
data-carrying enums, the full suite through the C backend) is implemented and now
verified by `make test` on both backends.

## Sub-agent workstreams

When a spawner agent is available, Phase 1 work splits cleanly along these
boundaries. Each workstream owns its files, so they can run concurrently
provided the shared headers are changed by **one** workstream at a time (or
agreed up front).

| Workstream | Owns | Verifies with |
|:-----------|:-----|:--------------|
| **registry** | `constructs/construct.{h,c}`, `constructs/registry.c`, `constructs/operator_table.c` | `--check-constructs` |
| **one construct** | a single `constructs/<name>.c` | `--check-constructs` + conformance |
| **frontend** (lexer + parser + AST) | `lexer.c`, `parser.c`, `ast.c` | `--dump-tokens`, `--dump-ast` |
| **types** (semantics) | `typechecker.c` | `tests/conformance/ui/*` |
| **codegen** (emitter + VM) | `emitter.c`, `vm.c` | `ASTRA_DUMP_VM=1`, conformance |
| **c-codegen** | `codegen.c`, `codegen.h`, `codegen_runtime.h` | `--emit-c` + gcc round-trip |
| **runtime** (values, builtins) | `vm.c` value helpers | conformance |
| **tests** (conformance suite) | `tests/**` | `make test` |
| **docs** | `Documentacion/**`, `AGENTS.md` | review |

The construct workstreams are the finest-grained split: 44 independent files,
so several can run at once. They have exactly one shared contract —
`constructs/construct.h` — and the self-check is the arbiter: if two of them
claim the same node kind, token or keyword, `--check-constructs` fails the suite
before anything is compiled.

Shared-contract files (`include/astra/astra.h`, `src/priv.h`) are the
integration points: changes to them must be done by the workstream that needs
them first, then rebased on by the others.

Every workstream must, before handing off:

1. build with `make debug` and fix any new sanitizer warning;
2. run `make test` and keep all conformance tests green;
3. add or update conformance cases for the behaviour it introduced;
4. commit a single, focused change.

## Conventions

- C11, Clang for development, `-Wall -Wextra -Wpedantic` must stay warning-free.
- Match the existing style: `snake_case`, 4-space indent, block comments
  describing the *why* above non-obvious code.
- Conventional-commit messages (`feat(seed): ...`, `fix(seed): ...`, `docs: ...`).
- New language behaviour requires a conformance test in `seed/tests/`.
