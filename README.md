<p align="center">
  <img src="https://raw.githubusercontent.com/AsterrZep/Astra/main/assets/astra-logo.svg" width="200" alt="Astra Logo">
</p>

<h1 align="center">Astra</h1>

<p align="center">
  <strong>Multi-paradigm programming language with Python ergonomics and C performance</strong>
</p>

<p align="center">
  <a href="https://github.com/AsterrZep/Astra/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
  <a href="https://github.com/AsterrZep/Astra/stargazers"><img src="https://img.shields.io/github/stars/AsterrZep/Astra?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/AsterrZep/Astra/issues"><img src="https://img.shields.io/github/issues/AsterrZep/Astra?style=flat-square" alt="Issues"></a>
</p>

---

> **Status (2026-10-28)**: Phase 1 (`seed/`, C) complete — `cd seed && make test` → **350 passed, 0 failed**. Phase 2 (`zig/`) has the Astra-0 frontend, module system, traits, generics and `?`, verified against the seed suite — `zig build test` → **74/74**, `dump_parity.sh` → **209 files, 0 divergent**. The LLVM backend is **opt-in** (`-Dllvm`) and green: `llvm_parity.sh` → **221/221** (skips fail the gate; native, `-O2`, aarch64 under qemu, wasm32-wasi under Node) — see [Benchmarks](#benchmarks-2026-10-27). **Stdlib M1/M2b/M3 shipped (MVP complete)**: `len`, `s[i]`, `to_string`, `read_file`, `ord`, `substr`, `push`, `str_to_int`, `chr`, `read_line` + `for c in s` + a self-hosted lexer gate (`selfhost/lexer_gate.sh` → 7/7 routes + token-stream parity vs `--dump-tokens`, `selfhost/parser_gate.sh` → 7/7 routes + golden freshness — a self-hosted PARSER, DEC-025 — and `selfhost/io_gate.sh` → 8/8) + userland helpers `contains`/`index_of`/`split` (DEC-024). **User guide**: [the book](Documentacion/09_libro/README.md) — 16 chapters, 91 executed examples. **Not built yet**: wider stdlib, ARC/ORC + fibers, comptime, package manager, Phase 3 self-compilation. Single source of truth for status: [`Documentacion/00_indice/INDICE.md`](Documentacion/00_indice/INDICE.md).

**Astra** is a compiled programming language that aims to unify the ergonomics of Python/TypeScript with the native speed of C/Rust — without the complexity of Rust's Borrow Checker or GC pauses.

![Alt](https://repobeats.axiom.co/api/embed/60f9b8ead8a187207feef11bacda3145c47d9c87.svg "Repobeats analytics image")

## Design Goals

| Goal | Description |
|:-----|:------------|
| **ARC/ORC Memory** | Automatic reference counting with cycle detection. No GC pauses, no manual memory management. |
| **Green Threads** | M:N fiber scheduling. Write synchronous-looking code that executes asynchronously. No `async`/`await`. |
| **Zero-Copy FFI** | Direct memory mapping to C, Python (NumPy/PyTorch), and Julia without data duplication. |
| **Dual Backend** | Bytecode VM for development (<10ms startup) and LLVM AOT for production (native speed). |
| **Cross-Platform** | Compile from any host to Linux, macOS, Windows, Android, iOS, visionOS, and WebAssembly. |
| **Type Inference** | Hindley-Milner type inference with dimensional types (units of measure). |
| **Comptime** | Zig-style compile-time metaprogramming. No macros, no templates — just code. |
| **Fiber Ownership Enforcement** | Shared within a fiber, verified unique on every fiber crossing (ARCHITECTURE §2.6; v1+E2 gated: S1/S2 + nil-red + `.copy()`, DEC-012/027 test-pinned — RT1/spawn deferred). |
| **Curated Stdlib** | ~64 modules covering networking, crypto, JSON, HTTP, testing, and more. |

## What the Language Will Look Like

```astra
import std.net.http
import std.encoding.json

struct User {
    name: string
    age: u32
    email: string
}

fn fetch_users(url: string) -> Result<[]User, http.Error> {
    let response = http.get(url)?
    let data = json.decode<[User]>(response.body)?
    Ok(data)
}

fn main() -> Result<(), Box<dyn Error>> {
    let users = fetch_users("https://api.example.com/users")?
    
    for user in users {
        print(f"{user.name} ({user.age}) — {user.email}")
    }
    
    Ok(())
}
```

## Project Structure

```
Astra/
├── README.md                    # This file
├── LICENSE                      # MIT License
├── CONTRIBUTING.md              # How to contribute
├── GOVERNANCE.md                # Decision-making process
├── CODE_OF_CONDUCT.md           # Community standards
├── CHANGELOG.md                 # Version history
├── AGENTS.md                    # Knowledge for coding agents
├── .gitignore
├── seed/                        # Phase 1: C seed compiler (Astra-0)
├── zig/                         # Phase 2: self-hosting Zig compiler
├── assets/
│   └── astra-logo.svg           # Project logo
└── Documentacion/                # Numbered folders — start at 00_indice/INDICE.md
    ├── 00_indice/                # Master index of every document
    ├── 01_lenguaje/              # Language: spec, philosophy, comparison, constructs (4)
    ├── 02_compilador/            # Compiler strategy, toolchain, multi-agent setup (3)
    ├── 03_fase1_seed/            # Phase 1 status: the C seed compiler (1)
    ├── 04_fase2_zig/             # Phase 2: kickoff, architecture, plans, status (6)
    ├── 05_fase_llvm/             # LLVM backend: plan + status (2)
    ├── 06_auditorias/            # Audits: coherence + pre-LLVM (2)
    ├── 07_investigacion/         # Research reports 001–030 (30 files)
    ├── 08_originales/            # Source PDFs (2)
    └── 09_libro/                 # User guide: 16 chapters + 91 examples (17)
```

## Documentation

All documentation lives in `Documentacion/`, organised in numbered folders.
**Start at the [master index](Documentacion/00_indice/INDICE.md)** — every
document is listed there with a one-line description.

- **[00_indice](Documentacion/00_indice/)** — Where to find everything
- **[01_lenguaje](Documentacion/01_lenguaje/)** — Language definition
  - [Architecture Specification](Documentacion/01_lenguaje/ARCHITECTURE.md) — the complete technical specification (40 sections)
  - [Design Philosophy](Documentacion/01_lenguaje/PHILOSOPHY.md) — why Astra exists and the principles behind it
  - [Comparative Analysis](Documentacion/01_lenguaje/COMPARATIVE_ANALYSIS.md) — Astra vs. Mojo, Nim, Zig, Julia, Vale, Swift
  - [Construct Registry](Documentacion/01_lenguaje/CONSTRUCT_REGISTRY.md) — one file per EBNF production
- **[02_compilador](Documentacion/02_compilador/)** — How the compiler is built
  - [Compiler Strategy](Documentacion/02_compilador/COMPILER_STRATEGY.md) — why C and Zig, and the C → Zig → Astra bootstrap
  - [Compiler Toolchain](Documentacion/02_compilador/COMPILER_TOOLCHAIN.md) — tools, libraries and workflows
  - [Multi-agent Setup](Documentacion/02_compilador/MULTI_AGENT_SETUP.md) — verified findings on parallel agent workstreams
- **[03_fase1_seed](Documentacion/03_fase1_seed/)** — [Phase 1 status](Documentacion/03_fase1_seed/PHASE1_PROGRESS.md): the C seed compiler
- **[04_fase2_zig](Documentacion/04_fase2_zig/)** — Phase 2 (self-hosting Zig compiler): kickoff, architecture, implementation plan, research, gap analysis and [live status](Documentacion/04_fase2_zig/PHASE2_PROGRESS.md)
- **[05_fase_llvm](Documentacion/05_fase_llvm/)** — LLVM backend: [plan](Documentacion/05_fase_llvm/LLVM_BACKEND_PLAN.md) and [status](Documentacion/05_fase_llvm/PHASE_LLVM_PROGRESS.md)
- **[06_auditorias](Documentacion/06_auditorias/)** — [Coherence audit](Documentacion/06_auditorias/COHERENCE_AUDIT.md) and [pre-LLVM audit](Documentacion/06_auditorias/PRE_LLVM_AUDIT.md)
- **[07_investigacion](Documentacion/07_investigacion/)** — 30 deep-dive research reports (001–030) on compilers, runtimes, language design, external critique analysis and benchmarks
- **[08_originales](Documentacion/08_originales/)** — Original design PDFs
- **[09_libro](Documentacion/09_libro/README.md)** — *The Astra Programming Language*: user guide in book style (16 chapters, 91 executed examples; ES)

## Benchmarks (2026-10-27)

Measured on **Debian 13 · AMD Ryzen 3 3250C (4C, 15 W) · 2.7 GB RAM**, at
commit `6e0954d` (Astra-0 subset, LLVM backend M0–M6.c, parity 159/159).
**These numbers are for the LLVM native route (`--emit-obj` + runtime), not
the VMs.** The seed and Zig VMs are *development tools and still have no
memory reclamation* (bump arena — everything is freed only at process exit).
That divergence is accepted and RSS-gated short-term; creating reclamation
in the VMs is Phase-2 work (option 3B of
[research/027](Documentacion/07_investigacion/027_runtime_semantics_decisions.md)).
Their rows appear below only as reference.

Method: min of N wall-time runs (shared machine, loadavg 0.5–1.5), peak
memory via `VmHWM` sampling every 2 ms, outputs verified on every run,
identical test programs in every language. Toolchains: rustc 1.99.1 · go
1.24.4 · gcc 14.2.0 · zig 0.16.0 · Astra `--emit-obj` (O0 and O2). Full
report, sources and raw data:
[research/030](Documentacion/07_investigacion/030_benchmarks_llvm_vs_compilados.md)
+ `030_benchmarks_suite/` (reproducible: `build_all.sh` → `run_bench.py`).

**CPU — naive `fib(30)` (min of 5):**

| C -O2 | Rust -O | Zig -OReleaseFast | Go | **Astra LLVM -O2** | **Astra LLVM -O0** | seed VM* | zig VM* |
|------:|--------:|------------------:|---:|-------------------:|-------------------:|---------:|--------:|
| 4.9 ms | 7.0 ms | 7.2 ms | 10.7 ms | **41.2 ms** | **44.6 ms** | 5.34 s | 3.79 s |

**Memory — 2M arrays created & discarded (peak RSS):**

| C -O2 | Zig | Rust -O0 | Go | **Astra LLVM** | seed VM* | zig VM* |
|------:|----:|---------:|---:|---------------:|---------:|--------:|
| 1.2 MB | 0.5 MB | 1.9 MB | 1.9 MB | **1.2 MB** | **400 MB** | **712 MB** |

**Memory — 25k string concats O(n²), peak RSS** (reclamation vs accumulation):

| Zig | C -O2 | Rust -O0 | **Astra LLVM** | Go (GC) | seed VM* | zig VM* |
|----:|------:|---------:|---------------:|--------:|---------:|--------:|
| 0.6 MB | 1.3 MB | 2.1 MB | **1.4 MB** | 20 MB | **320 MB** | **354 MB** |

**Startup (empty program, min of 20) & binary size:**

| | **Astra LLVM** | C | Zig | Rust | Go |
|:--|---------------:|--:|----:|-----:|---:|
| Start | **0.8 ms** | 0.8 ms | 0.7 ms | 1.2 ms | 1.7 ms |
| Binary | **23 KB** | 16 KB | 0.95 MB | 4.5 MB | 1.6 MB |

\* VM rows are the development interpreter paths — **no memory reclamation
yet** (that work is pending), and they compile+run the source on every
invocation.

Honest read: the LLVM route already behaves like a native language (0.8 ms
startup, flat 1.2 MB under sustained allocation, no GC pauses, 23 KB
binaries) and is **8–9× slower than C** on recursive CPU work — a
first-iteration backend without escape analysis or aggressive inlining; the
gap-closing milestones are listed in `PHASE_LLVM_PROGRESS.md`.

## Roadmap

**Single source of truth: [`Documentacion/00_indice/INDICE.md`](Documentacion/00_indice/INDICE.md) → «Estado del proyecto».**
This table mirrors it. A row may only change in the same PR that changes that
table, and only with the gate command + figure pasted under «Evidencia de
verificación».

States — never a bare `[x]`:
**Specified** = written in a document, no code ·
**Implemented** = code exists, not gated ·
**Verified** = gate executed, command + number.

### Design & Research

| Item | State | Evidence |
|:-----|:------|:---------|
| Language design and architecture specification | **Specified** | `Documentacion/01_lenguaje/ARCHITECTURE.md` (§1–§41) |
| Cross-platform research (Linux, macOS, Windows, Android, iOS, visionOS) | **Specified** | `research/018`, `research/019`, ARCHITECTURE §24–27. *Cross-verified* only for `aarch64-linux-gnu` and `wasm32-wasi`: `zig/tests/llvm_cross.sh`, `llvm_wasm.sh` → 221/221 |
| Compiler architecture (multi-IR, query system) | **Specified (partial)** | multi-IR: ARCHITECTURE §20.1 · query system: **0 hits** in `seed/src`+`zig/src` · dual backend **Verified**: `make test` 350/350 + `llvm_parity.sh` 221/221 |
| Memory model (ARC/ORC, cycle detection, fiber-aware) | **Specified — not implemented** | ARCHITECTURE §2; `vm.c` never frees (`grep -c 'free(' seed/src/vm.c` → 0, arena-only), no cycle detection, no fiber-awareness. Ref-counting exists only on the LLVM route (M4.e, no cycles) |
| Concurrency model (green threads, channels, atomics) | **Specified — not implemented** | ARCHITECTURE §3/§35; `grep -riE "fiber\|scheduler\|spawn\|channel\|Atomic\[" seed/src zig/src` → **0**; `transfer` → 0 |
| Standard library design (~64 modules) | **Specified** | `research/015`, ARCHITECTURE §32; `std/…` is rejected by the Zig CLI |
| Package manager design | **Specified** | `research/016`, ARCHITECTURE §33; only `@/` root resolution from `astra.toml` |
| Formal grammar (EBNF) | **Specified + gated** | `research/001` §12.1; `./astra-seed --check-constructs` → 47 constructs / 27 operators, registry⇔lexer⇔parser agree |
| Compiler strategy (C → Zig → Astra bootstrapping) | **Specified** | `COMPILER_STRATEGY.md` §7.1 rewritten as-built (manual port + gates) — correction landed2026-10-27, `research/029` §1 |

### Implementation

| Item | State | Evidence |
|:-----|:------|:---------|
| **Phase 1**: seed compiler in C (Astra-0) — VM, C backend, fuzzing | **Verified** | `cd seed && make test` → **350 passed, 0 failed** (2026-10-28, ASan/UBSan/LSan) |
| **Phase 2 core**: Zig compiler — Astra-0 frontend, modules, traits, generics, `?` | **Verified** | `cd zig && zig build test` → **74/74**; `zig/tests/dump_parity.sh` → **209 files, 0 divergent** (2026-10-28) |
| **LLVM backend** (`-Dllvm`, opt-in): `--emit-obj`/`--jit`, cross aarch64, wasm32-wasi, `--fast-math`, unboxed Option/Result | **Verified (CI)** | `zig/tests/llvm_parity.sh` → **221/221**, plain and `ASTRA_LLVM_OPT=2` (skips fail since #21); jobs `llvm`, `llvm-cross`, `llvm-wasm` green on every PR |
| **Phase 2 full language**: comptime, ARC/ORC, fibers, FFI, stdlib | **Not started** | `Documentacion/04_fase2_zig/PHASE2_GAP_ANALYSIS.md` §11 |
| **Astra-0 stdlib (M1/M2b/M3 — MVP complete)**: `len`, `s[i]`, `to_string`, `read_file`, `ord`, `substr`, `push`, `str_to_int`, `chr`, `read_line`, `for c in s` + self-hosted lexer | **Verified** | 10 builtins in 4 routes (DEC-013..020); `seed/tests/selfhost/lexer_gate.sh` → **7/7** (seed VM, C backend, zig VM, LLVM `--jit`/`--emit-obj`/cross/wasm) + strong token-stream parity vs `--dump-tokens`; `seed/tests/selfhost/io_gate.sh` → **8/8**; userland helpers `contains`/`index_of`/`split` (DEC-024, `conformance/stdlib/`); `make test` → **350/0** |
| **Language decisions registry** | **Verified** | `Documentacion/01_lenguaje/DECISIONES.md` → 29 entries (DEC-001..029; only DEC-021 in `Propuesta`), rule in AGENTS.md |
| **Fase 3**: Astra compiles itself | **Not started** | needs Phase 2 + the compiler tree written in Astra (prereq stdlib M1/M2/M3 done) |

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Governance

Astra is governed by a BDFL model with a Core Team. See [GOVERNANCE.md](GOVERNANCE.md) for details.

## Community

- [GitHub Discussions](https://github.com/AsterrZep/Astra/discussions) — Ask questions, share ideas
- [Issues](https://github.com/AsterrZep/Astra/issues) — Report bugs, request features

## License

Astra is licensed under the [MIT License](LICENSE).
