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
- `Documentacion/research/001_grammar_and_parser_design.md` — grammar/parser
- `Documentacion/research/002_seed_compiler_design.md` — seed compiler design
- `Documentacion/PHASE1_PROGRESS.md` — current implementation status

## Build and test

```bash
cd seed
make            # development build (-g -O0) -> seed/astra-seed
make debug      # ASan + UBSan + LSan (recommended while developing)
make release    # gcc -O2
make test       # runs tests/run_tests.sh
make fuzz       # clang + libFuzzer -> build/fuzz/astra-fuzz (requires clang)
make fuzz-run FUZZ_TIME=300   # campaign: seeds from tests/, dict, 1 worker

# Each variant compiles into its own object tree (build/debug, build/release)
# and drops the binary before linking, so switching variants always rebuilds.
# Never share build/ between variants: the flags are not part of an object's
# timestamp, and mixing them used to link-fail with "creating DT_TEXTREL".
```

`run_tests.sh` runs two paths: the VM (every case in `tests/conformance/`) and
the C backend (`tests/codegen/*.astra` through `--emit-c` + `gcc`). When you add
a codegen-only behaviour, add its case to `tests/codegen/`.

Fuzzing (PHASE1 §4bis#23): `make fuzz` builds the libFuzzer harness
(`seed/fuzz/fuzz_compile.c` — lexer, parser, typechecker and emitter, no VM);
`make fuzz-run FUZZ_TIME=N` seeds the corpus from `tests/` and runs **one**
worker with `-rss_limit_mb=512` (the ASan build costs ~250 MB; parallel
workers will OOM a small box). Campaigns set `ASTRA_FUZZ_QUIET=1`: the
harness masks fd 2 per input so the tens of thousands of diagnostics per
second cannot stall and show up as a fake libFuzzer `timeout`, with
`ASAN_OPTIONS=log_path=build/fuzz/asan` keeping ASan/LSan reports in files
while fd 2 is masked. CI replays the corpus `-runs=0` **without** quiet
mode, so a red replay keeps its diagnostics in the log.

Triage any artifact (`crash-*`, `timeout-*`, `oom-*`, `leak-*`) with
`fuzz/classify.sh <artifact>` **before** reporting it: it replays standalone
×20 (measures the real wall time) and in-process ×3000 with stderr closed.
Reproducible standalone = real finding: keep the input in
`seed/fuzz/regressions/` with the fix and add its replay to
`.github/workflows/ci.yml`. Clean otherwise = environment flake (load,
memory pressure, allocator state). A campaign killed by the OOM killer
(rc 137, no artifact) is the machine, not the compiler.

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

Requires **Zig 0.16.x**. The Astra-0 frontend (lexer, flat AST, parser, type
checker, emitter, VM) is ported and verified against the seed suite. The module
system (`src/modules/` + the multi-module path in `src/main.zig`) compiles and
runs multi-file programs: `pub` gating, shared type pool, mangled globals,
dependency-order execution, `use` re-exports and foreign struct/enum values
(`Documentacion/PHASE2_PROGRESS.md` §7). Diagnostics
from every phase go through one sink (`src/diagnostics.zig`, §7.4).

```bash
cd zig
export PATH="$HOME/zig:$PATH"   # this environment keeps Zig at ~/zig/zig
zig build                       # -> zig-out/bin/astra-zig
zig build test                  # unit tests + conformance over seed/tests/conformance
zig build -Doptimize=ReleaseFast

./zig-out/bin/astra-zig file.astra            # compile and run (exit 1 on error)
./zig-out/bin/astra-zig --dump-tokens file.astra
./zig-out/bin/astra-zig --dump-ast file.astra
./zig-out/bin/astra-zig --dump-modules file.astra
./zig-out/bin/astra-zig --dump-bytecode file.astra
./zig-out/bin/astra-zig --debug file.astra    # interactive bytecode debugger
```

`--dump-tokens`/`--dump-ast` are byte-parity-gated against the seed
(PHASE2 §4 #6): after touching either dump, run
`./zig/tests/dump_parity.sh` from the repo root (needs both binaries;
`SHOW_DIFF=1` prints the first diffs). CI's `parity` job runs it.

Layout: `src/lexer/`, `src/ast/`, `src/parser/`, `src/typechecker/`,
`src/emitter/` (emitter + bytecode), `src/vm/`, `src/modules/`,
`src/diagnostics.zig` (one `Diagnostic{file, span, msg}` sink for every
phase), `src/main.zig`, `src/conformance.zig` (compiles and runs every non-UI
seed conformance file, rejects every UI file).

Porting rule: **the Zig compiler must accept everything the seed accepts before
new features are added** (the suite is the gate). Match `seed/src/*.c` and the
`research/001`–`003` reports for behaviour.

### LLVM backend (`-Dllvm`, opt-in)

The native LLVM backend (Fase LLVM, `Documentacion/LLVM_BACKEND_PLAN.md`;
progress log `Documentacion/PHASE_LLVM_PROGRESS.md`) lives in `src/llvm/` plus
the `src/llvm.zig` facade. It is **strictly opt-in**: without `-Dllvm` the
build and binary are byte-identical and none of the existing gates change.
**M0–M5 and M6.a are closed** (2026-10-22): the emitter compiles the Astra-0 subset —
scalars, floats, strings, Option/Result with `match`/`?`, closures,
arrays/structs/enums, `for..in`/`break`/`continue`, monomorphized generics,
traits/impls, unannotated returns and pointer-typed `let` without initializer
— straight from the typed AST (no bytecode/VM) to a native object via
TargetMachine (`--emit-obj`, M2.e). `zig/tests/llvm_parity.sh` gates it
against the zig VM: **154 cases — 154 ok, 0 skip, 0 excl, 0 fail**.
`zig/tests/llvm_filecheck.sh` pins the IR shapes of the guards/match/depth/`?`/debug
fixtures in `zig/tests/llvm/`, and `zig/tests/llvm_fuzz.sh` (generator:
`llvm_fuzz_gen.py`) compares generated programs across VM↔C↔zig↔LLVM. Real
multi-module programs stay out of scope (the emitter is single-file; the
driver rejects them cleanly with exit 2); `--single-file` reproduces the
seed's inert-import semantics for the `module/` fixtures. M4 (quality) is
closed: `--opt-level=N` runs the new-PM pipeline (`default<O2>` + LICM /
simple-loop-unswitch / IRCE for N=2), `--debug-info` emits source-mapped DWARF
(verified via `tests/llvm_dwarf_test.sh` under `lldb`), and the parity gate is
run both plain and with `ASTRA_LLVM_OPT=2` (154/154 in both); `zig/tests/llvm_bench.sh`
publishes VM/C/LLVM timings. `--sanitize=address` marks functions and runs the
new-PM `asan` pass before the optimizer; `zig/tests/llvm_sanitize.sh` proves
the artifacts are instrumented, that a plain link fails without
`-fsanitize=address`, runs the whole 154-case suite under ASan at `-O0` and
`-O2`, and closes with an LSan step (`detect_leaks=1`) on
`zig/tests/llvm/leaks.astra`. UBSan is not offered because LLVM 19..23 does
not register a `ubsan` new-PM pass (`opt-19 --print-passes`); see
`PHASE_LLVM_PROGRESS.md` §8. The post-M4 audit (§11) closed nil-related SEGVs,
bool-array equality and function-value printing. Values are owned by
**reference counting** (M4.e, §12): every heap object carries an `{rc, kind}`
header, stores/returns/params retain, locals/globals/temporaries release, and
the generated code frees everything it allocates except cycles (a closure
whose env reaches the closure). Derived element metadata is still not carried
(`a[0][1]`, `a[0](x)` are clean rejections). M5 (cross-compilation) is closed:
`--target=<triple>` (e.g. `aarch64-linux-gnu`) emits a foreign object — the
module carries the target's triple and datalayout, and `src/llvm/target.zig`
registers every target (`LLVMInitializeAllTargets`) — and
`zig/tests/llvm_cross.sh` gates it by cross-linking with `<triple>-gcc` and
cross-running under `qemu-<arch>-static`: **154/154**, byte-identical to the
native VM (CI job `llvm-cross`). The wasm route (progress §13.4) is likewise
formal: `zig/tests/llvm_wasm.sh` compiles every fixture with `--emit-obj
--target=wasm32-wasi`, links with `wasm-ld` + wasi-libc (crt1) and runs it
under Node's WASI — **154/154**, plain and `-O2` (CI job `llvm-wasm`; needs
`lld`, a wasi-libc sysroot and Node >= 22). The sysroot must ship a modern
`<setjmp.h>` (the runtime TU includes `codegen_runtime.h`, which includes
it): **Ubuntu's apt `wasi-libc` predates EH setjmp and ships none**, so CI
pins the official `wasi-sysroot` tarball from wasi-sdk instead; the gate
passes the sysroot's `include/<triple>` with an explicit `-I` (any clang
works, no driver patches). M6.a
(LLJIT, progress §14) adds `--jit`: the emitted module is compiled and run
**in-process** via ORC/LLJIT (no cc/link step — the runtime TU is linked into
the `astra-zig` binary with `-rdynamic` so LLJIT's process-symbol generator
resolves `astra_llvm_*`+libc); `zig/tests/llvm_jit.sh` gates it against the VM
with the same 154 cases (154/154, plain and `-O2`) — the foundation for a
future REPL/eval. The remaining M6 items (Option/Result unboxing, fast-math,
error-union for `?`) stay optional; scalar unboxing is already delivered (the
backend walks the typed AST and emits native `i64`/`f64`/`i8` in SSA — 2-8×
faster than the boxed C backend per `llvm_bench.sh`).

```bash
cd zig
zig build -Dllvm                        # requires LLVM 19..23 via llvm-config
./zig-out/bin/astra-zig --emit-llvm file.astra          # write file.ll
./zig-out/bin/astra-zig --emit-llvm-stdout file.astra   # print IR (for tests)
./zig-out/bin/astra-zig --emit-obj file.astra           # native <file>.o via TargetMachine (M2.e)
./zig-out/bin/astra-zig --emit-obj --opt-level=2 file.astra  # new-PM pipeline (M4)
./zig-out/bin/astra-zig --emit-obj --target=aarch64-linux-gnu file.astra  # cross aarch64 object (M5)
./zig-out/bin/astra-zig --jit file.astra               # compile + run in-process via LLJIT (M6.a)
./tests/llvm_parity.sh                  # VM <-> --emit-obj -> link runtime
ASTRA_LLVM_OPT=2 ./tests/llvm_parity.sh # same gate through default<O2>+extras
./tests/llvm_jit.sh                     # VM <-> --jit, in-process (M6.a)
./tests/llvm_filecheck.sh               # IR shapes (FileCheck-19..23)
./tests/llvm_sanitize.sh                # ASan artifacts + parity under ASan (M4.d)
./tests/llvm_cross.sh                   # cross aarch64 -> qemu, vs VM (M5; needs gcc-aarch64-linux-gnu + qemu-user-static)
./tests/llvm_wasm.sh                    # wasm32-wasi -> wasm-ld -> Node WASI, vs VM (needs lld + a wasi-libc sysroot with <setjmp.h> — Ubuntu's apt pkg ships none — + node >= 22)
./tests/llvm_fuzz.sh -n 40 -s 1         # differential fuzz, 4 routes
./tests/llvm_bench.sh -n 3 -O 2         # VM / C / LLVM timings (M4)
```

Gotchas that will bite you:

- **Link `-lc` before `-lLLVM-19`** (see `linkLlvm` in `build.zig`): LLVM's
  shared library references libc symbols, and with the linker's `--as-needed`
  default a leading `-lLLVM-19` with a trailing `-lc` drops libc — the link
  dies on undefined `printf`/`putchar`.
- **PIC o el enlazador rechaza el objeto**: el `cc` default-PIE de la distro
  no enlaza objetos no-PIC (`relocation R_X86_64_32 against …`). `--emit-obj`
  crea el TargetMachine con `LLVMRelocPIC`, así que ya no hace falta nada; si
  enlazas a mano un `.ll` vía `llc`, pasa `-relocation-model=pic`.
- `build.zig` discovers `llvm-config` as `ASTRA_LLVM_CONFIG` env → `llvm-config`
  → `llvm-config-19..-23`. `zig/tests/llvm_parity.sh` no necesita `llc` desde
  M2.e: el objeto sale de `--emit-obj` y sólo usa `${CC:-cc}` para enlazar.
- The runtime TU (`src/llvm/runtime/astra_runtime_llvm.c`) includes the seed's
  `codegen_runtime.h` **exactly once** (that header *defines* its globals), and
  compiles with `-I<repo>/seed/src`. A link error duplicating `astra_file`/…
  means a second translation unit started including the header too.
- CI's `llvm` job pins LLVM 19 via apt.llvm.org; the seed/zig/parity jobs are
  untouched because `-Dllvm` is opt-in.

Beyond M0 the backend splits into parallel workstreams (`llvm-infra`,
`llvm-core`, `llvm-values`, `llvm-errors`, `llvm-testing`, `llvm-quality`),
each owning a slice of `src/llvm/` and verified by `llvm_parity.sh` +
`zig build -Dllvm` — the file/ownership map is in `LLVM_BACKEND_PLAN.md` §5.

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

The conformance suite itself runs on the VM; the C round-trip is its own
gate: every case in `tests/codegen/` is compiled through `--emit-c`, run
with gcc and compared against its `EXPECT:` comments by `make test` (22
cases; check new ones by hand with `-Wall -Wextra`). That covers:

- Arithmetic, comparisons, booleans, strings, nil, **bitwise operators**
- `let` variables (local and global), **module-level statements**
- `if`/`else` (as statement and expression), `for..in`, `while`
- Builtins (`print`)
- Function calls, recursion, **lambdas**, **closures** (capture by value;
  assigning to a captured variable is a compile error)
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
9. **The `?` context is a global pair** (`astra_error_jmp` +
   `astra_error_active`, `codegen_runtime.h`): every `OPCODE_CALL` saves and
   restores it around the callee. Dropping the save/restore lets a
   `?`-installing callee leave its popped frame behind, and the caller's next
   `?` longjmps into dead stack (pinned by
   `tests/codegen/try_nested_frames.astra`, Fase 2.5).

### What remains for Phase 1 completion

Nothing: this list is complete (its last row, module-level runtime
errors, was verified 2026-10-12 — `tests/codegen/toplevel_oob.astra`
and `error_line_in_fn.astra` exercise the `ASTRA_TRY_CONTEXT` longjmp
with `file:line:` positions).

Everything else that was on this list (lambdas, match, Option/Result, `?`,
data-carrying enums, the `tests/codegen/` round-trip) is implemented and now
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

The construct workstreams are the finest-grained split: 47 constructs (one
file per grammar production), so several can run at once. They have exactly
one shared contract — `constructs/construct.h` — and the self-check is the
arbiter: if two of them claim the same node kind, token or keyword,
`--check-constructs` fails the suite before anything is compiled.

Shared-contract files (`include/astra/astra.h`, `src/priv.h`) are the
integration points: changes to them must be done by the workstream that needs
them first, then rebased on by the others.

Every workstream must, before handing off:

1. build with `make debug` and fix any new sanitizer warning;
2. run `make test` and keep all conformance tests green;
3. add or update conformance cases for the behaviour it introduced;
4. commit a single, focused change.

## GitHub workflow — rulesets, PRs, signed commits

`main` is protected by two active repository rulesets (GitHub → Settings →
Rules → Rulesets). Read this section before touching the remote; it is their
operational summary:

- **`integridad-main`** — *no bypass actors*. Every commit landing on `main`
  must be **signed**: SSH signing is configured locally (`commit.gpgsign=true`,
  `gpg.format=ssh`, `user.signingkey=~/.ssh/id_ed25519_astra_signing`), so a
  plain `git commit` signs automatically — never pass `--no-verify`, and if a
  push is rejected as unsigned check the signing config instead of forcing.
  Force-push and branch deletion are rejected. Merges additionally require
  **three status checks green** — the CI contexts
  `seed (C) — ASan/UBSan/LSan + suite`, `zig (Phase 2) — zig build test` and
  `dump parity (seed <-> zig)`.
- **`proceso-pull-requests`** — changes reach `main` through a pull request
  with **1 approving review**, every review thread resolved, and stale
  approvals dismissed on new pushes. Allowed merge methods: `merge`,
  `squash`, `rebase`. The **admin role is a bypass actor**, so as a solo
  author (you cannot self-approve) merge with the admin bypass:
  `gh pr merge --admin`.

The loop for agents — **never push to `main` directly**:

```bash
git switch -c feat/<slug>        # from an up-to-date main; also fix/, docs/, test/
git commit -m "feat(...): ..."   # signed automatically, conventional style
git push -u origin feat/<slug>
gh pr create --title "..." --body-file <body>   # follow .github/PULL_REQUEST_TEMPLATE.md
gh pr checks --watch             # CI (seed / zig / parity / llvm*) + CodeQL
gh pr merge --admin --squash --delete-branch
```

- The PR template (`.github/PULL_REQUEST_TEMPLATE.md`) demands: local gates
  green for the areas the PR touches (`make test` / `zig build test` /
  `zig build -Dllvm && ./tests/llvm_parity.sh`), signed commits, **no
  secrets** (secret-scanning push protection blocks the push if any leak),
  tests for every new language behaviour, docs updated, and an «Evidencia de
  verificación» section quoting the actual gate outputs.
- CI (`ci.yml`) runs on `push` to `main` **and** on every pull request;
  `codeql.yml` additionally analyzes the C compiler (`seed/`) on PRs, pushes
  and weekly. Only the three contexts above gate merges, but keep every job
  green — `llvm (latest) — canario no bloqueante` is `continue-on-error` by
  design (it exists to alarm on LLVM-latest churn, as in §14.5 of
  `Documentacion/PHASE_LLVM_PROGRESS.md`).

## Conventions

- C11, Clang for development, `-Wall -Wextra -Wpedantic` must stay warning-free.
- Match the existing style: `snake_case`, 4-space indent, block comments
  describing the *why* above non-obvious code.
- Conventional-commit messages (`feat(seed): ...`, `fix(seed): ...`, `docs: ...`).
- New language behaviour requires a conformance test in `seed/tests/`.
