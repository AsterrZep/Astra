# Changelog

All notable changes to the Astra programming language will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Complete architecture specification (41 sections)
- Design philosophy documentation
- Comparative analysis with Mojo, Nim, Zig, Julia, Vale, Swift
- Cross-platform research (Linux, macOS, Windows, Android, iOS, visionOS)
- Compiler architecture design (multi-IR, query system, dual backend)
- Memory model specification (ARC/ORC, cycle detection)
- Concurrency model (green threads, channels, atomics)
- Standard library design (~64 modules)
- Package manager design
- Formal grammar (EBNF)
- Error handling design (Result/Option, panic/recover)
- Type coercion rules
- Variable scoping and shadowing rules
- Seed compiler design
- Compiler testing methodologies
- Governance and RFC process
- Evolution demo scripts (01_basics through 06_advanced) in `scripts/evolution/`
- Terminal status dashboard (`scripts/status.sh`)
- Phase 2 kickoff document (`Documentacion/PHASE2_KICKOFF.md`)
- **Module declarations in the Zig compiler (Phase 2.2, step 1)**: `use`/`import`/`from` are lexed and parsed into `use_decl`/`import_decl`/`from_decl`/`import_item` nodes, with dot-separated `ImportPath` (`zig/src/`). No module resolution yet
- **Module declarations in the seed (Phase 2.2, step 1)**: `import`/`from`/`as` are lexed and parsed into `NODE_IMPORT`/`NODE_FROM`/`NODE_IMPORT_ITEM`, sharing one dot-separated `ImportPath` builder with `use`. The registry grows to 46 constructs (`seed/src/`). Parsed and discarded, as before: no module resolution in the seed

### Fixed
- **`from` with no import items was silently accepted**: `from a.b import` built a `From` that imported nothing and reported nothing; the production requires at least one item, so it now reports `expected at least one import item` (`ui/from_without_items.astra`)
- **`use` was dead code in the seed**: the type checker had no `NODE_USE` case, so every `use` declaration — an Astra-0 construct — failed with `unhandled node kind 46` (S18)
- **Module path separator drift**: the seed's `parse_use` matched `::` while its own declared grammar (`constructs/use.c`, `research/010` §12.1) says `.`; the parser now accepts the dot-separated `ImportPath` and rejects `::` (S19)
- **SHL/SHR undefined behavior**: Added range validation (`< 0 || >= 64`) and `uint64_t` cast in VM and C codegen runtime
- **String concatenation memory leak**: Added `free(buf)` after `astra_string_new` in C codegen runtime
- **Runtime errors in module code**: Modified `astra_runtime_error` to use `longjmp` when `astra_error_active` is set; updated `ASTRA_TRY_CONTEXT` macro and module-level error handlers

## [0.1.0] - 2025-XX-XX

### Added
- Initial language design and architecture
- Project repository and community infrastructure

[Unreleased]: https://github.com/AsterrZep/Astra/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/AsterrZep/Astra/releases/tag/v0.1.0
