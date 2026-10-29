---
name: astra-dev-loop
description: The development loop for Astra — small tested commits, push per green commit, docs last, and fan-out to sub-agents. Use when executing any implementation task on the Astra repository (seed C compiler, Zig compiler, conformance, codegen, docs), when asked to continue the roadmap, or when the user says "sigue", "continue", "commit and push", or asks for parallel/multi-agent execution. Companion of astra-seed-workstreams (which owns the file-ownership map).
---

# Astra development loop

Orchestration protocol used for every implementation task in this repo.
Read `AGENTS.md` at the repository root first — build commands, file map,
invariants and the workstream table live there.

## The loop (in order, every time)

1. **Todo list first.** Before touching a file, write the work as a todo
   list: one item per commit-sized unit, with priority. Update statuses
   (`pending` → `in_progress` → `completed`) as you go, never batch.
2. **Fan out research to sub-agents.** Anything requiring more than two file
   reads goes to an `explore` agent (or the relevant specialist) with a
   precise question. Parallel tool calls in one message. The integrating
   agent keeps the conclusions, not the raw dumps.
3. **Small, focused commits.** One conventional commit per todo item
   (`feat(seed): …`, `feat(zig): …`, `fix(tests): …`, `docs: …`).
   NEVER mix a feature, its tests and unrelated refactors in one commit.
4. **Test gate BEFORE every commit.** The commit does not exist until green:

   ```bash
   # seed side (always with the sanitizer build while developing)
   cd seed && make debug && ./tests/run_tests.sh && ./astra-seed --check-constructs
   ./tests/sweep_emit_c.sh                      # every non-ui case through --emit-c + gcc

   # zig side
   cd zig && export PATH="$HOME/zig:$PATH" && zig build test --summary all

   # selfhost gates when touching seed/tests/selfhost/** or Astra-0 fixtures
   ./seed/tests/selfhost/{io,lexer,parser}_gate.sh

   # llvm_parity (plain + ASTRA_LLVM_OPT=2) when touching zig/src or the suite
   ./zig/tests/llvm_parity.sh && ASTRA_LLVM_OPT=2 ./zig/tests/llvm_parity.sh
   ```

   Manual repro programs live in `/tmp/opencode/*.astra`; run them through
   EVERY backend touched (VM, `--emit-c`+gcc, astra-zig) and diff outputs.
   **Counters are measured, never remembered**: paste the actual output of
   every gate you cite in a PR or status table (INDICE rule). EXPECT
   directives: one `// EXPECT:` per output line; **one** `EXPECT-ERROR:` /
   `EXPECT-RUNTIME-ERROR:` per file (run_tests fails a file with more —
   split it).
5. **Push after every green commit.** `git push` immediately; never
   accumulate a stack of local commits.
6. **Watch CI.** After pushing, `gh run list --limit 5`. A red run must be
   explained in the same session (log via `gh run view <id> --log-failed`)
   — fix forward with a `fix(...)` commit, never leave `main` red silently.
   Green-on-CI is the real gate; local green is the precondition.
7. **Docs last, in their own commit.** Status tables
   (`Documentacion/03_fase1_seed/PHASE1_PROGRESS.md`, `Documentacion/04_fase2_zig/PHASE2_PROGRESS.md`,
   `Documentacion/04_fase2_zig/PHASE2_GAP_ANALYSIS.md`), `CHANGELOG.md` (Keep-a-Changelog, newest
   first) and `AGENTS.md` counts/claims are updated in a final `docs:`
   commit once the behaviour is verified on both compilers.
8. **Close the loop.** Mark the last todo `completed`, report the commit
   list, the test counts (e.g. "seed 101/101, zig 60/60") and what is next.

## Parallelism with sub-agents

The default posture is **more agents, not fewer**:

- Research → `explore` agents (quick/medium), one question each, parallel.
- Implementation → one sub-agent per workstream using the file-ownership map
  in `astra-seed-workstreams` (frontend / semantics / codegen / runtime /
  tests / docs). Only the integrating agent commits.
- Review → `Code Reviewer` sub-agent on any change touching shared headers
  (`seed/include/astra/astra.h`, `seed/src/priv.h`, `zig/src/emitter/bytecode.zig`).
- A shared-contract change lands FIRST, serially, from the integrating
  agent; the fan-out starts after it is committed.

## Rules that make the loop safe

- **Decisions before code.** Any PR that adds/changes/rejects a language
  behaviour ships its `DEC-NNN` (table row + section) and the conformance
  test that pins it, in the same PR — see AGENTS §"Language decisions".
  A PR whose `DEC` needed by it is in `Propuesta` cannot land (rule 5).
- **Signed commits, verify locally.** Signing is SSH (`gpg.format=ssh`,
  key `~/.ssh/id_ed25519`); pass **`-S` explicitly** (`commit.gpgsign`
  alone did not fire on an amend) and check
  `git cat-file commit HEAD | grep -c gpgsig` → 1 before pushing. Never
  `--no-verify`: `main` rejects unsigned commits.
- **Golden files come from the real compiler, never from the new
  implementation** (DEC-025 pattern): generate expected output from
  `astra-seed --dump-tokens/--dump-ast` through a dumb normalizer, commit
  it, and have the gate re-derive it each run (freshness check). Otherwise
  the gate only proves the new code agrees with itself.
- **Seed↔Zig parity.** The Zig compiler must accept everything the seed
  accepts (the conformance suite is the gate). A bug found in one backend
  is fixed in BOTH. Accepting more in Zig than in the seed is allowed only
  when documented in PHASE2_PROGRESS.
- **Reproduce before fixing.** Every bug gets a minimal `/tmp/opencode`
  repro first; the fix is judged by the repro turning green plus the suite.
- **`make debug` for development.** ASan+UBSan+LSan catches emitter stack
  corruption and arena misuse that a release build hides. Never share
  `seed/build/` between debug and release (see AGENTS.md).
- **Zig invocation.** `zig build test --summary all` (never `zig build -s`).
  `workdir` applies to the whole bash chain. `Writer.print` returns an
  error union in 0.16 → `catch {}`.
- **Conventional commits, repo-root scope** (`feat(seed):`, `feat(zig):`,
  `test(lang):`, `fix(tests):`, `docs:`). One commit = one intent.
- **Warnings are failures.** `-Wall -Wextra -Wpedantic` stays clean; a new
  warning is a failed build.
- **No drive-by refactors.** If a change wants more than its commit scope,
  it becomes its own todo item and its own commit.

## Environment (verified 2026-10-28 on this box)

- **Zig 0.16.x** may be absent (CI pins 0.16.0 via `mlugg/setup-zig`). Install
  locally with:
  ```bash
  mkdir -p ~/zig && curl -sL https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
    | tar -xJ -C ~/zig --strip-components=1 && ~/zig/zig version   # 0.16.0
  export PATH="$HOME/zig:$PATH"
  ```
- **`zig build -Dllvm` fails to link on gcc-16/binutils-2.46 glibc** with
  `fatal linker error: unhandled relocation type R_X86_64_PC64 … crt1.o:.sframe`
  (zig 0.16's self-hosted linker cannot process `.sframe` relocations, and
  `-fno-lld` / `-flld` don't help — `-flld` segfaults the driver). Workaround
  that makes every llvm gate runnable locally (never commit any of it):
  ```bash
  mkdir -p /tmp/opencode/syslib
  objcopy --remove-section=.sframe --remove-section=.rela.sframe /usr/lib/crt1.o /tmp/opencode/syslib/crt1.o
  for f in /usr/lib/*; do b=$(basename "$f"); [ "$b" = crt1.o ] && continue; \
       [ -e /tmp/opencode/syslib/"$b" ] || ln -s "$f" /tmp/opencode/syslib/"$b"; done
  mkdir -p /tmp/opencode/fakegcc
  cat > /tmp/opencode/fakegcc/cc <<'SH'
  #!/bin/bash
  for a in "$@"; do [ "$a" = "-print-file-name=crt1.o" ] && { echo /tmp/opencode/syslib/crt1.o; exit 0; }; done
  exec /usr/bin/cc "$@"
  SH
  chmod +x /tmp/opencode/fakegcc/cc
  export PATH="/tmp/opencode/fakegcc:$HOME/zig:$PATH"   # zig asks `cc -print-file-name=crt1.o`
  zig build -Dllvm
  ```
  zig resolves `crti.o`/`libc.so`/… **relative to the returned crt1.o dir**,
  hence the symlink farm. Without this, llvm_parity/llvm_jit/cross/wasm are
  unrunnable locally — rely on CI only as a last resort.
  Two traps verified in practice: (a) **`/tmp/opencode` does not survive
  sessions** — if `ls /tmp/opencode/fakegcc` fails, re-create the wrapper
  and the symlink farm with the recipe above before any `-Dllvm` build;
  (b) a plain `zig build` (or `zig build test`) **overwrites the
  `-Dllvm` binary** — every llvm gate run needs `zig build -Dllvm` first
  (the gate's "compiler built without -Dllvm" skip is how you notice).

## Writing Astra-0 code (gotchas verified by execution)

Everything below was reproduced on VM seed, `--emit-c`+gcc, zig VM and LLVM
`--jit` — trust these over prose docs, and re-verify before citing:

- **`else` must sit on the same line as the closing `}`** (`} else {`); on
  its own line both compilers reject the file («unexpected token in
  expression»). Known limitation, deliberately NOT pinned yet (DEC-025).
- **A multiline `if/else if/else` as the LAST expression of a function
  does not type** («if branches have different types: string vs void») —
  use early `return`s, or bind it to a `let` first. Single-line
  `if c { a } else { b }` tails are fine.
- **`ok`, `err`, `some`, `none` and the 10 builtin names are reserved**
  (DEC-015): you cannot `let`/`fn` them — `fn err(…)` fails to parse.
  Pick `report_err`-style names.
- **Counters from `len()` are `i64`**: `let mut i = 0` then `i + len(s)`
  is a type error — write `let mut i: i64 = 0` (DEC-006/013).
- **`match` arms need commas** between them, and enum patterns must be
  qualified (`Color.Rojo`, DEC-008). Payload patterns only accept named
  bindings — no `_` per field, no nested qualified paths, no or-patterns
  of qualified variants (yet).
- **String arrays print unquoted**: `print(["a","b"])` → `[a, b]` on all
  routes; write EXPECTs accordingly.
- **`[]` (empty array literal) is rejected by the LLVM emitter** and any
  llvm_parity skip is a FAIL — seed arrays with a non-empty literal
  (`let mut parts = [""]`) instead.
- **`substr(s, start, len)`** (length, not end); `push` returns a NEW
  array (rebind: `a = push(a, v)`); `none` prints as `nil`, `some(n)` as
  `some(n)`.
- Assignment to globals from functions works (all 4 routes) — that is how
  parser.astra keeps its lexer state.
