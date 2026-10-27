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

> **Status: Phase 1 complete, Phase 2 in progress** — the seed compiler (`seed/`, C) compiles and runs Astra-0 (suite in green on the VM, the C backend and Zig); the self-hosting Zig compiler (`zig/`) implements the Astra-0 frontend plus the module system. The standard library and the LLVM backend (Phase 2.6) do not exist yet.

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
    ├── 07_investigacion/         # Research reports 001–024 (24 files)
    └── 08_originales/            # Source PDFs (2)
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
- **[07_investigacion](Documentacion/07_investigacion/)** — 24 deep-dive research reports (001–024) on compilers, runtimes and language design
- **[08_originales](Documentacion/08_originales/)** — Original design PDFs

## Roadmap

### Design & Research (Complete)
- [x] Language design and architecture specification
- [x] Cross-platform research (Linux, macOS, Windows, Android, iOS, visionOS)
- [x] Compiler architecture (multi-IR, query system, dual backend)
- [x] Memory model (ARC/ORC, cycle detection, fiber-aware)
- [x] Concurrency model (green threads, channels, atomics)
- [x] Standard library design (~64 modules)
- [x] Package manager design
- [x] Formal grammar (EBNF)
- [x] Compiler strategy (C → Zig → Astra bootstrapping)

### Implementation
- [x] **Phase 1**: Seed compiler in C (Astra-0) — compiles, runs, C backend, fuzzed; 259 checks green
- [x] **Phase 2 core**: Self-hosting compiler in Zig — Astra-0 frontend, modules, traits, generics and error propagation verified against the seed suite
- [x] **LLVM backend**: native `--emit-obj`/`--jit`, cross aarch64, wasm32-wasi, `--fast-math`, unboxed Option/Result — 157/157 parity (opt-in `-Dllvm`)
- [ ] **Phase 2 full language**: comptime, ARC/ORC, fibers, FFI and the standard library
- [ ] **Phase 3**: Astra compiles itself — the proof

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Governance

Astra is governed by a BDFL model with a Core Team. See [GOVERNANCE.md](GOVERNANCE.md) for details.

## Community

- [GitHub Discussions](https://github.com/AsterrZep/Astra/discussions) — Ask questions, share ideas
- [Issues](https://github.com/AsterrZep/Astra/issues) — Report bugs, request features

## License

Astra is licensed under the [MIT License](LICENSE).
