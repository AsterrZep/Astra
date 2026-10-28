---
name: astra-seed-workstreams
description: Splits Astra Phase 1 (C seed compiler) work into parallel, file-owned workstreams for sub-agent execution. Use when implementing or extending the Astra-0 seed compiler, when several features must land together, or when asked to parallelize compiler work. Activates on queries about Astra, Astra-0, the seed compiler, lexer/parser/typechecker/emitter/VM, or conformance tests.
---

# Astra seed-compiler workstreams

Orchestration protocol for Phase 1 of Astra. Read `AGENTS.md` at the repository
root first — it has the build commands, file map and invariants.

## Purpose

Phase 1 work is naturally parallel, but the compiler is a pipeline over a small
set of shared files. This skill defines workstreams with **explicit file
ownership** so several agents can work at once without clobbering each other,
plus the handoff protocol that keeps the pipeline consistent.

## Workstreams

| # | Name | Owns (exclusive write) | Depends on |
|:--|:-----|:-----------------------|:-----------|
| 1 | frontend | `seed/src/lexer.c`, `seed/src/parser.c`, `seed/src/ast.c` | shared contract |
| 2 | semantics | `seed/src/typechecker.c` | frontend AST shape |
| 3 | codegen | `seed/src/emitter.c` | AST shape, opcodes |
| 4 | runtime | `seed/src/vm.c` | opcodes, value model |
| 5 | tests | `seed/tests/**`, `seed/tests/run_tests.sh` | observable behaviour |
| 6 | docs | `Documentacion/**`, `AGENTS.md`, `README.md` | nothing |

Shared contract (coordinate before changing): `seed/include/astra/astra.h`
and `seed/src/priv.h`. Treat these as a lock: one workstream proposes the diff,
the others rebase.

## Recommended execution order for a feature

1. Decide the **shared-contract change first** (tokens, node kinds, structs,
   opcodes) and apply it in one pass. Everything else keys off it.
2. Run frontend + semantics + codegen/runtime in parallel where the contract is
   already fixed.
3. Tests run last but are written alongside: each workstream adds its own cases.
4. Docs capture the behaviour that landed.

## Handoff checklist

A workstream is done only when all hold:

- [ ] `cd seed && make debug` builds with **no new warnings**.
- [ ] `cd seed && make test` is fully green (VM conformance + `tests/codegen/`
      `--emit-c` round-trip).
- [ ] New behaviour has a case in `seed/tests/conformance/<area>/` with
      `// EXPECT:` lines — rejections in `ui/` with `// EXPECT-ERROR:`
      (compile time) or `// EXPECT-RUNTIME-ERROR:` (runtime). **One error
      directive per file** (run_tests audits this, audit §7.8).
- [ ] New behaviour has its **`DEC-NNN`** in `Documentacion/01_lenguaje/
      DECISIONES.md` (table row + section), in the same PR — rule 1 of
      AGENTS; a `Propuesta` DEC that the feature needs blocks the PR.
- [ ] Grammar/registry touchers re-run `./astra-seed --check-constructs`
      (47/27 must stay OK, invariant 6) and update `dump_parity` fixtures
      if `--dump-tokens`/`--dump-ast` output changed.
- [ ] Test-only or Astra-0-fixture changes also run
      `./tests/sweep_emit_c.sh` and `./tests/selfhost/{io,lexer,parser}_gate.sh`
      (the selfhost gates run the same fixtures through up to 7 routes).
- [ ] One focused conventional commit (`feat(seed): …`, `fix(seed): …`).
- [ ] Commit signed: `git commit -S` and
      `git cat-file commit HEAD | grep -c gpgsig` → 1.

## Invariants that sub-agents most often break

- **Stack balance in the emitter.** No trailing `POP` for value-less
  statements; assignment yields its value.
- **Jump offsets** are `target - instruction_index`, not a relative count.
- **Frame slot 0** is the callee/return slot; params start at slot 1.
- **Scope pop** removes by insertion sequence, not hash-bucket order.
- **Arena-only allocation** — never `free()` compiler data.
- **Fiber-crossing features carry their own checks** (AGENTS invariant 8):
  a feature that moves handles across fibers ships S2/RT1 in the same PR;
  `transfer(x)` will be a builtin (DEC-022), RT1 is M4-only (DEC-023).

If a change touches more than two of these, stop and re-plan: it is probably
one workstream's job, not several.

## Verification commands

```bash
cd seed && make debug && make test
./astra-seed --check-constructs                  # registry/lexer/parser/operators agree
./tests/sweep_emit_c.sh                          # every non-ui case through --emit-c + gcc
ASTRA_DUMP_VM=1 ./astra-seed tests/conformance/loops/range_exclusive.astra
./astra-seed --dump-tokens tests/conformance/arrays/literal_index.astra
./tests/selfhost/parser_gate.sh                  # Astra-0 parser: 7 routes + golden freshness
```

Conformance layout (all auto-discovered by `run_tests.sh`): `arrays/ blocks/
control/ enums/ expressions/ functions/ generics/ lambda/ loops/ memory/
module/ stdlib/ structs/ traits/ types/ ui/`. Multi-file/shared-library code
does not exist yet: the seed compiles exactly one file and `std/…` is
rejected (zig modules rule 4), so helpers are duplicated per fixture
(DEC-024 pattern).
