# AGENTS.md — Astra project knowledge for coding agents

This file is read by Codebuff / Freebuff and other agents. It describes how to
build, test and extend the project, and how to split work into parallel
sub-agent workstreams.

## What this repository is

**Astra** is a compiled, multi-paradigm programming language (Python/TypeScript
ergonomics, C/Rust performance, no borrow checker, no tracing-GC pauses).

The repository currently holds **design documentation** (`Documentacion/`) and
**Phase 1 of the implementation**: the *seed compiler* (`seed/`), written in C,
which compiles a bootstrap subset called **Astra-0**.

Full background lives in:
- `Documentacion/ARCHITECTURE.md` — language specification
- `Documentacion/COMPILER_STRATEGY.md` — the C → Zig → Astra bootstrap plan
- `Documentacion/research/010_grammar_and_parser_design.md` — grammar/parser
- `Documentacion/research/011_seed_compiler_design.md` — seed compiler design
- `Documentacion/PHASE1_PROGRESS.md` — current implementation status

## Build and test

```bash
cd seed
make            # debug build -> seed/astra-seed
make debug      # ASan + UBSan (recommended while developing)
make release    # gcc -O2
make test       # runs tests/run_tests.sh
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

## Seed compiler layout (`seed/src`)

| File | Responsibility |
|:-----|:---------------|
| `constructs/` | **one file per grammar production** — the construct registry; see `Documentacion/CONSTRUCT_REGISTRY.md` |
| `arena.c` | bump/arena allocator; all compiler memory is freed in bulk |
| `string_table.c` | string interning (pointer-compare equality) |
| `lexer.c` | hand-written tokenizer, keyword table |
| `parser.c` | recursive descent + Pratt expressions |
| `ast.c` | AST node construction, source locations |
| `typechecker.c` | symbol table (scoped) + type checking |
| `emitter.c` | AST → stack bytecode; loop/jump patching |
| `vm.c` | stack VM, value model, builtins |
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
- Conventional-commit messages (`feat(seed): …`, `fix(seed): …`, `docs: …`).
- New language behaviour requires a conformance test in `seed/tests/`.
