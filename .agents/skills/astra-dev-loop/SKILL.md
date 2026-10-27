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

   # zig side
   cd zig && export PATH="$HOME/zig:$PATH" && zig build test --summary all
   ```

   Manual repro programs live in `/tmp/opencode/*.astra`; run them through
   EVERY backend touched (VM, `--emit-c`+gcc, astra-zig) and diff outputs.
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
