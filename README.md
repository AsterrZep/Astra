<p align="center">
  <img src="https://raw.githubusercontent.com/AsterrZep/Astra/main/assets/astra-logo.svg" width="200" alt="Astra Logo">
</p>

<h1 align="center">Astra</h1>

<p align="center">
  <strong>Multi-paradigm programming language with Python ergonomics and C performance</strong>
</p>

<p align="center">
  <a href="https://github.com/AsterrZep/Astra/releases"><img src="https://img.shields.io/github/v/release/AsterrZep/Astra?style=flat-square" alt="Release"></a>
  <a href="https://github.com/AsterrZep/Astra/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
  <a href="https://github.com/AsterrZep/Astra/stargazers"><img src="https://img.shields.io/github/stars/AsterrZep/Astra?style=flat-square" alt="Stars"></a>
</p>

---

**Astra** is a compiled programming language that unifies the ergonomics of Python/TypeScript with the native speed of C/Rust — without the complexity of Rust's Borrow Checker or GC pauses.

## Features

| Feature | Description |
|:--------|:------------|
| **ARC/ORC Memory** | Automatic reference counting with cycle detection. No GC pauses, no manual memory management. |
| **Green Threads** | M:N fiber scheduling. Write synchronous-looking code that executes asynchronously. No `async`/`await`. |
| **Zero-Copy FFI** | Direct memory mapping to C, Python (NumPy/PyTorch), and Julia without data duplication. |
| **Dual Backend** | Bytecode VM for development (<10ms startup) and LLVM AOT for production (native speed). |
| **Cross-Platform** | Compile from any host to Linux, macOS, Windows, Android, iOS, visionOS, and WebAssembly. |
| **Type Inference** | Hindley-Milner type inference with dimensional types (units of measure). |
| **Comptime** | Zig-style compile-time metaprogramming. No macros, no templates — just code. |
| **Curated Stdlib** | ~64 modules covering networking, crypto, JSON, HTTP, testing, and more. |

## Quick Start

```bash
# Install Astra
curl -sSf https://astralang.dev/install.sh | sh

# Create your first program
echo 'fn main() { print("Hello, World!"); }' > hello.astra

# Run it (development mode — instant)
astra run hello.astra

# Build for production (optimized binary)
astra build --release hello.astra -o hello
./hello
```

## Example

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

## Architecture

Astra compiles through a multi-stage pipeline:

```
Source → Lexer → Parser → AST → Type Checker → AIR → Backend
                                                    │
                                          ┌─────────┴─────────┐
                                          │                   │
                                    VM (dev mode)      LLVM (prod mode)
```

- **VM Backend**: Bytecode interpreter, <10ms startup, ideal for development
- **LLVM Backend**: Full AOT compilation with optimizations, native performance
- **AIR (Astra Intermediate Representation)**: Unified IR where ARC, fiber yield points, and type erasure are inserted

## Project Structure

```
Astra/
├── ARCHITECTURE.md          # Complete language specification (~85KB)
├── PHILOSOPHY.md            # Design philosophy and principles
├── COMPARATIVE_ANALYSIS.md  # Comparison with Mojo, Nim, Zig, Julia, Vale, Swift
├── docs/                    # Technical research reports
│   ├── go-internals-report.md
│   ├── cpython-internals-report.md
│   ├── julia_internals_research.md
│   ├── compiler-internals-report.md
│   └── abi-stability-report.md
└── reports/                 # Deep-dive research
    ├── rustc-architecture-deep-dive.md
    ├── serialization-and-allocators.md
    └── runtime-systems-and-language-design.md
```

## Documentation

- **[Architecture Specification](ARCHITECTURE.md)** — The complete technical specification (41 sections)
- **[Design Philosophy](PHILOSOPHY.md)** — Why Astra exists and the principles behind it
- **[Comparative Analysis](COMPARATIVE_ANALYSIS.md)** — How Astra compares to other languages
- **[Technical Reports](docs/)** — Deep research into compiler internals and runtime systems

## Roadmap

- [x] Language design and architecture specification
- [x] Cross-platform research (Linux, macOS, Windows, Android, iOS, visionOS)
- [x] Compiler architecture (multi-IR, query system, dual backend)
- [x] Memory model (ARC/ORC, cycle detection, fiber-aware)
- [x] Concurrency model (green threads, channels, atomics)
- [x] Standard library design (~64 modules)
- [x] Package manager design
- [x] Formal grammar (EBNF)
- [ ] **Phase 1**: Seed compiler in C (Astra-0)
- [ ] **Phase 2**: Self-hosting compiler (Astra-1)
- [ ] **Phase 3**: Full language with all features
- [ ] **Phase 4**: LLVM backend and production toolchain

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Governance

Astra is governed by a BDFL model with a Core Team. See [GOVERNANCE.md](GOVERNANCE.md) for details.

## Community

- [GitHub Discussions](https://github.com/AsterrZep/Astra/discussions) — Ask questions, share ideas
- [Issues](https://github.com/AsterrZep/Astra/issues) — Report bugs, request features

## License

Astra is licensed under the [MIT License](LICENSE).

---

<p align="center">
  <sub>Built with dedication to simplicity, safety, and performance.</sub>
</p>
