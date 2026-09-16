# Astra Compiler Toolchain: Comprehensive Report

## Table of Contents

1. [C Development Tools (Seed Compiler)](#1-c-development-tools)
2. [Zig Development Tools (Self-Hosting Compiler)](#2-zig-development-tools)
3. [LLVM Integration](#3-llvm-integration)
4. [Parser Tools](#4-parser-tools)
5. [Testing Tools](#5-testing-tools)
6. [Version Control & CI](#6-version-control--ci)
7. [Documentation](#7-documentation)
8. [Development Environment](#8-development-environment)
9. [Performance Tools](#9-performance-tools)
10. [Security Tools](#10-security-tools)

---

## 1. C Development Tools (Seed Compiler)

### 1.1 C Compilers

| Compiler | Use Case | Why |
|----------|----------|-----|
| **Clang** | Primary development | Best diagnostics, fastest compile times, excellent error messages, LLVM-native integration |
| **GCC** | Production builds | Mature optimizations, broad platform support, proven reliability |
| **TCC** | Rapid iteration | Tiny C compiler, instant compile times, useful for development hot-reload cycles |

**Recommendation:** Use **Clang** for development (best diagnostics, matches LLVM target), **GCC** for production release builds.

**Installation:**
```bash
# Ubuntu/Debian
sudo apt install clang gcc tcc

# macOS
xcode-select --install  # Clang included
brew install gcc tcc

# Windows
winget install LLVM.LLVM  # Clang
winget install GnuWin32.Make
```

### 1.2 Build Systems

| System | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **CMake** | Industry standard, cross-platform, IDE integration | Verbose syntax, complex for simple projects | **Primary** for C seed compiler |
| **Ninja** | Fastest build execution | Needs CMake/Meson to generate build files | **Backend** for CMake |
| **Meson** | Clean syntax, fast, Python-like | Smaller ecosystem than CMake | Alternative if simplicity preferred |
| **Make** | Universal, simple for small projects | Doesn't scale well, platform differences | Use for quick prototypes |

**Recommended Setup:** CMake + Ninja
```cmake
# CMakeLists.txt for astra-cc
cmake_minimum_required(VERSION 3.20)
project(astra-cc C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(LLVM REQUIRED CONFIG)

add_executable(astra-cc
    src/main.c
    src/lexer.c
    src/parser.c
    src/type_checker.c
    src/codegen.c
    src/vm.c
)

target_link_libraries(astra-cc PRIVATE LLVM)
```

```bash
# Build with Ninja
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build
```

**Installation:**
```bash
# Ubuntu/Debian
sudo apt install cmake ninja-build

# macOS
brew install cmake ninja

# Windows
winget install Kitware.CMake
winget install Ninja-build.Ninja
```

### 1.3 Debugging

| Tool | What It Does | When to Use |
|------|-------------|-------------|
| **GDB** | GNU debugger, step through C code | Linux primary debugger |
| **LLDB** | LLVM debugger, better with Clang | macOS primary, Linux alternative |
| **Valgrind** | Memory error detector (memcheck) | Find memory leaks, invalid reads/writes |
| **AddressSanitizer (ASAN)** | Compile-time memory error detection | Faster than Valgrind, use during development |
| **UndefinedBehaviorSanitizer (UBSAN)** | Detects undefined behavior | Enable in all debug builds |

**Recommended Setup:**
```bash
# Compile with sanitizers (always in debug builds)
clang -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -o astra-cc src/*.c

# Run with Valgrind (periodic check)
valgrind --leak-check=full --show-leak-kinds=all ./astra-cc test.astra

# GDB debugging
gdb ./astra-cc
(gdb) break main
(gdb) run
```

**Installation:**
```bash
# Ubuntu/Debian
sudo apt install gdb lldb valgrind

# macOS
xcode-select --install  # LLDB included
brew install valgrind  # Limited support on macOS
```

### 1.4 Memory Leak Detection

| Tool | Speed | Accuracy | Recommendation |
|------|-------|----------|----------------|
| **ASAN** | 2x slowdown | Good | Daily development |
| **MSAN** | 3x slowdown | Excellent (uninitialized memory) | Nightly CI |
| **Valgrind memcheck** | 20-50x slowdown | Excellent | Periodic deep analysis |
| **LeakSanitizer** | Part of ASAN | Good | Default with ASAN |

```bash
# ASAN + LeakSanitizer (default)
clang -fsanitize=address -o test src/*.c && ./test

# MSAN (separate build)
clang -fsanitize=memory -fno-omit-frame-pointer -o test src/*.c && ./test
```

### 1.5 Profiling

| Tool | Platform | What It Does |
|------|----------|-------------|
| **perf** | Linux | CPU profiling, flame graphs, hardware counters |
| **Instruments** | macOS | GUI profiling, CPU, memory, leaks |
| **gprof** | Cross-platform | Basic call-graph profiling |
| **samply** | Cross-platform | Modern sampling profiler |

```bash
# Linux perf profiling
perf record -g ./astra-cc large_file.astra
perf report

# Generate flame graph
perf script | stackcollapse-perf.pl | flamegraph.pl > profile.svg

# macOS Instruments
instruments -t "Time Profiler" ./astra-cc large_file.astra
```

### 1.6 Code Formatting

**clang-format** — the standard for C formatting.

```yaml
# .clang-format
BasedOnStyle: LLVM
IndentWidth: 4
ColumnLimit: 100
AllowShortFunctionsOnASingleLine: None
BreakBeforeBraces: Allman
PointerAlignment: Right
SortIncludes: true
```

```bash
# Format all C files
clang-format -i src/*.c src/*.h

# Check without modifying
clang-format --dry-run --Werror src/*.c
```

### 1.7 Static Analysis

| Tool | What It Does | When to Use |
|------|-------------|-------------|
| **cppcheck** | C/C++ static analysis, memory errors | CI pipeline |
| **clang-tidy** | Clang-based linter, modernize,性能 | IDE integration, CI |
| **Coverity** | Deep static analysis, enterprise | Periodic deep scans |

```bash
# cppcheck
cppcheck --enable=all --suppress=missingIncludeSystem src/

# clang-tidy
clang-tidy src/*.c -- -std=c11 -Isrc/

# Generate compilation database for clang-tidy
bear -- cmake --build build
```

### 1.8 Editor/IDE Setup

**VS Code** (recommended):
- C/C++ extension (Microsoft) — IntelliSense, debugging
- clangd extension — fast code completion
- CodeLLDB — LLDB debugging

**Neovim/Vim**:
- nvim-lspconfig + clangd
- DAP (Debug Adapter Protocol) for debugging

---

## 2. Zig Development Tools (Self-Hosting Compiler)

### 2.1 Zig Version

**Recommendation:** Use **latest stable release** (currently 0.16.0 as of 2026).

- For production: pin to a specific stable release
- For development: can use dev builds for bleeding-edge features
- Multiple Zig versions coexist without conflict

```bash
# Install via package manager
# macOS
brew install zig

# Linux
snap install zig --classic
# or
sudo snap install zig

# Windows
winget install zig.zig

# Direct download from ziglang.org
```

### 2.2 Zig Build System (`build.zig`)

The Zig build system is self-hosted and excellent. Key patterns:

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Seed compiler (C interop)
    const seed = b.addExecutable(.{
        .name = "astra-cc",
        .root_source_file = b.path("src/seed/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Self-hosting compiler
    const self = b.addExecutable(.{
        .name = "astra",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    const test_step = b.step("test", "Run all tests");
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    b.installArtifact(seed);
    b.installArtifact(self);
}
```

**Best Practices:**
- Use `b.standardTargetOptions()` for cross-compilation
- Use `b.standardOptimizeOption()` for debug/release modes
- Define tests inline with `zig test` convention
- Use `build.zig.zon` for dependencies

### 2.3 Zig Debugging

```bash
# Build with debug info (default in Debug mode)
zig build-exe src/main.zig

# Use GDB/LLDB with Zig binaries
gdb ./zig-out/bin/astra
lldb ./zig-out/bin/astra

# Zig has built-in stack traces in debug mode
# Panic messages include source locations automatically

# Build with release-safe for runtime checks + optimizations
zig build -Doptimize=ReleaseSafe
```

### 2.4 Zig Testing

Zig has a **built-in test framework** — no external dependencies needed:

```zig
const std = @import("std");
const testing = std.testing;

test "lexer tokenizes identifiers" {
    var lexer = Lexer.init("foo bar");
    const tok1 = lexer.next();
    try testing.expectEqual(Token.Identifier, tok1.kind);
    try testing.expectEqualStrings("foo", tok1.text);
}

test "type checker rejects invalid types" {
    var checker = TypeChecker.init();
    const result = checker.checkexpr(expr);
    try testing.expectError(error.TypeMismatch, result);
}
```

```bash
# Run all tests
zig test src/main.zig

# Run specific test
zig test src/main.zig --test-filter "lexer"

# Run tests with verbose output
zig test src/main.zig --verbose
```

### 2.5 Zig Formatting

```bash
# Format all Zig files
zig fmt src/

# Check formatting (CI)
zig fmt --check src/

# Format specific file
zig fmt src/main.zig
```

Zig formatting is opinionated and non-negotiable — this is by design.

### 2.6 Zig Cross-Compilation

Zig has **first-class cross-compilation** — this is one of its killer features:

```bash
# Cross-compile for Linux x86_64
zig build -Dtarget=x86_64-linux

# Cross-compile for macOS ARM
zig build -Dtarget=aarch64-macos

# Cross-compile for Windows
zig build -Dtarget=x86_64-windows

# Cross-compile for Android
zig build -Dtarget=aarch64-linux-android

# List all available targets
zig targets
```

### 2.7 LLVM Integration from Zig

Zig has built-in LLVM integration:

```zig
const llvm = @import("llvm");  // Built-in

// Generate LLVM IR
pub fn emitLLVM(self: *Compiler) !void {
    // Use Zig's LLVM bindings
    const context = llvm.Context.create();
    const module = llvm.Module.create("astra", context);
    // ... build IR ...
}
```

For the Astra compiler, you can use Zig's C interop to call LLVM C API directly:

```zig
const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/IRWriter.h");
});

pub fn createModule() void {
    const ctx = c.LLVMContextCreate();
    const mod = c.LLVMModuleCreateWithName("astra", ctx);
    // ...
}
```

---

## 3. LLVM Integration

### 3.1 C API vs C++ API

| API | Pros | Cons | Recommendation |
|-----|------|------|----------------|
| **LLVM C API** | Stable ABI, language-agnostic, simpler | Less complete, slower updates | **Use for seed compiler (C)** |
| **LLVM C++ API** | Full functionality, direct access | ABI instability, C++ dependency | Use from Zig (via C++ interop) |

**Recommendation:** Use **LLVM C API** from the C seed compiler. Use **LLVM C++ API** from the Zig self-hosting compiler (Zig has excellent C++ interop).

### 3.2 LLVM Version to Target

**Recommendation:** Target **LLVM 17+** (current stable is LLVM 23.x as of 2026).

- LLVM 17+: Mature MLIR, good WASM support
- LLVM 18+: Improved memory safety features
- LLVM 19+: Better ARM/RISC-V codegen

For maximum compatibility, support the last 3 major LLVM versions.

### 3.3 Static vs Dynamic Linking

| Approach | Pros | Cons | When to Use |
|----------|------|------|-------------|
| **Static linking** | Self-contained binary, no runtime deps | Larger binary, no auto-updates | **Production distribution** |
| **Dynamic linking** | Smaller binary, shared across tools | Runtime dependency required | Development |

```cmake
# CMake - Static LLVM linking
find_package(LLVM REQUIRED CONFIG)
target_link_libraries(astra-cc PRIVATE LLVM static)
```

```bash
# Check LLVM linking
llvm-config --libs --ldflags --system-libs
```

### 3.4 LLVM IR Generation Best Practices

1. **Use typed pointers** (LLVM 15+ default)
2. **Use opaque pointers** instead of typed pointers
3. **Emit debug info** with `LLVMCreateDIBuilder`
4. **Use TargetMachine** for target-specific codegen
5. **Run optimization passes** before emitting code

```c
// Example: Basic LLVM IR generation pattern
LLVMModuleRef mod = LLVMModuleCreateWithName("astra", ctx);
LLVMBuilderRef builder = LLVMCreateBuilder(ctx);

// Create function
LLVMTypeRef func_type = LLVMFunctionType(LLVMInt32Type(), NULL, 0, 0);
LLVMValueRef func = LLVMAddFunction(mod, "main", func_type);
LLVMBasicBlockRef entry = LLVMAppendBasicBlock(func, "entry");
LLVMPositionBuilderAtEnd(builder, entry);

// Build IR
LLVMValueRef ret = LLVMConstInt(LLVMInt32Type(), 42, 0);
LLVMBuildRet(builder, ret);

// Verify and emit
char *error = NULL;
LLVMVerifyModule(mod, LLVMAbortProcessAction, &error);
```

### 3.5 Relevant LLVM Optimization Passes

| Pass | What It Does | When to Use |
|------|-------------|-------------|
| **SROA** | Scalar replacement of aggregates | Always |
| **SimplifyCFG** | Control flow simplification | Always |
| **InstCombine** | Instruction combining | Always |
| **GVN** | Global value numbering | Optimization level > 0 |
| **LICM** | Loop-invariant code motion | Optimization level > 0 |
| **Inlining** | Function inlining | Optimization level > 0 |

---

## 4. Parser Tools

### 4.1 Hand-Written vs Generated Parsers

| Approach | Pros | Cons | Recommendation |
|----------|------|------|----------------|
| **Hand-written recursive descent** | Full control, easy debugging, best error messages | More code to write | **Primary** for Astra |
| **ANTLR** | Grammar-driven, multiple target languages | Learning curve, less control | Use for prototyping grammars |
| **Tree-sitter** | Incremental, error recovery, IDE support | Heavier dependency | Use for IDE integration |
| **Bison/Yacc** | Mature, well-documented | LALR(1) limitations, dated tooling | Avoid |

**Recommendation:** Use **hand-written recursive descent** for the production parser. Use **Pratt parsing** for expressions.

### 4.2 Pratt Parsing

Pratt parsing is ideal for expression parsing with operator precedence. Key concepts:

- **Binding Power (BP):** Numeric precedence for each operator
- **Null denotation (NUD):** Prefix position handler
- **Left denotation (LED):** Infix position handler

**For C seed compiler:** Implement Pratt parser manually (it's ~100 lines):

```c
// Pratt parser core (simplified)
typedef struct {
    int lbp;              // left binding power
    ASTNode* (*nud)(Parser*);  // prefix handler
    ASTNode* (*led)(Parser*, ASTNode* left);  // infix handler
} PrattRule;

ASTNode* parse_expression(Parser* p, int rbp) {
    Token tok = advance(p);
    ASTNode* left = tok.nud(p);
    while (rbp < peek(p).lbp) {
        tok = advance(p);
        left = tok.led(p, left);
    }
    return left;
}
```

**For Zig self-hosting:** Use Zig's comptime for a type-safe Pratt parser:

```zig
fn PrattParser(comptime Token: type, comptime BP: type) type {
    return struct {
        // ...
    };
}
```

### 4.3 PEG Parsing Libraries

| Library | Language | Notes |
|---------|----------|-------|
| **packcc** | C | Minimal PEG parser generator, single-file |
| **microtar + custom** | C | Lightweight approach |
| **Zig PEG** | Zig | Community PEG libraries available |
| **tree-sitter** | C | Incremental, error recovery |

For Astra, hand-written recursive descent with Pratt for expressions is recommended over PEG generators for better error messages and control.

---

## 5. Testing Tools

### 5.1 C Testing Frameworks

| Framework | Pros | Cons | Recommendation |
|-----------|------|------|----------------|
| **Unity** | Minimal, portable, widely used | Basic features | **Recommended** for C seed compiler |
| **CMock** | Mock generation from headers | Ruby dependency | Use with Unity |
| **cmocka** | Lightweight, built-in mocks | Less ecosystem | Alternative to Unity |
| **Check** | Fork-based, advanced fixtures | Heavier | Overkill for most cases |

**Recommendation:** Use **Unity + Ceedling** (Unity's build system).

```c
// test/test_lexer.c
#include "unity.h"
#include "lexer.h"

void setUp(void) {}
void tearDown(void) {}

void test_lexer_tokenizes_identifier(void) {
    Lexer lexer;
    lexer_init(&lexer, "foo");
    Token tok = lexer_next(&lexer);
    TEST_ASSERT_EQUAL(TOKEN_IDENTIFIER, tok.type);
    TEST_ASSERT_EQUAL_STRING("foo", tok.text);
}

int main(void) {
    UNITY_BEGIN();
    RUN_TEST(test_lexer_tokenizes_identifier);
    return UNITY_END();
}
```

### 5.2 Zig Built-in Testing

Zig's testing is built into the language — no external framework needed:

```zig
const std = @import("std");
const testing = std.testing;

test "parser parses function declarations" {
    var parser = try Parser.init(testing.allocator, "fn main() void {}");
    defer parser.deinit();
    
    const ast = try parser.parse();
    try testing.expectEqual(@as(usize, 1), ast.nodes.len);
    try testing.expectEqual(NodeKind.Function, ast.nodes[0].kind);
}
```

### 5.3 Fuzzing

| Fuzzer | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **AFL++** | Fast, mutation-based, wide platform | Requires instrumentation | **Primary** fuzzer |
| **LibFuzzer** | In-process, LLVM-native | Requires LLVM | Use for parser/type checker |
| **Honggfuzz** | Hardware-based coverage | Complex setup | Secondary fuzzer |

**Setup for Astra compiler fuzzing:**

```c
// fuzz_parser.c (for LibFuzzer/AFL++)
#include <stdint.h>
#include <stddef.h>

extern int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size > 1024) return 0;
    
    // Fuzz the parser
    Lexer lexer;
    lexer_init(&lexer, (const char*)data, size);
    Parser parser;
    parser_init(&parser, &lexer);
    Ast *ast = parser_parse(&parser);
    if (ast) ast_free(ast);
    return 0;
}
```

```bash
# AFL++ fuzzing
afl-clang-fast -fsanitize=fuzzer,address -o fuzz_parser fuzz_parser.c src/parser.c
afl-fuzz -i testcases/ -o findings/ ./fuzz_parser

# LibFuzzer
clang -fsanitize=fuzzer,address -o fuzz_parser fuzz_parser.c src/parser.c
./fuzz_parser corpus/
```

### 5.4 Differential Testing

Compare Astra's output against known-correct implementations:

```bash
#!/bin/bash
# diff_test.sh
for f in test/*.astra; do
    # Run Astra compiler
    ./astra-cc "$f" -o /tmp/out_astra
    # Run reference compiler (e.g., gcc for similar constructs)
    gcc "${f%.astra}.c" -o /tmp/out_ref
    
    # Compare outputs
    /tmp/out_astra > /tmp/out_astra.txt
    /tmp/out_ref > /tmp/out_ref.txt
    diff /tmp/out_astra.txt /tmp/out_ref.txt
done
```

### 5.5 Conformance Test Framework

Create a test suite with:
1. **Syntax tests** — valid/invalid syntax
2. **Type checking tests** — type inference, error cases
3. **Code generation tests** — compare generated LLVM IR
4. **Runtime tests** — execute compiled programs, check output

---

## 6. Version Control & CI

### 6.1 Git Workflow

**Recommendation:** **Trunk-based development** with feature branches.

- `main` branch is always deployable
- Feature branches are short-lived (< 1 week)
- Use conventional commits: `feat:`, `fix:`, `test:`, `docs:`
- Require PR reviews before merge

### 6.2 GitHub Actions CI

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  c-seed:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        compiler: [clang, gcc]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      
      - name: Install dependencies (Ubuntu)
        if: runner.os == 'Linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y cmake ninja-build clang llvm-dev valgrind cppcheck
      
      - name: Install dependencies (macOS)
        if: runner.os == 'macOS'
        run: |
          brew install cmake ninja llvm
      
      - name: Install dependencies (Windows)
        if: runner.os == 'Windows'
        run: |
          choco install cmake ninja
      
      - name: Build
        run: |
          cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
          cmake --build build
      
      - name: Test
        run: ctest --test-dir build --output-on-failure
      
      - name: Static Analysis
        if: matrix.os == 'ubuntu-latest'
        run: |
          cppcheck --enable=all src/
      
      - name: Memory Check (Linux)
        if: matrix.os == 'linux-latest'
        run: |
          valgrind --leak-check=full --error-exitcode=1 ./build/astra-cc test.astra

  zig-selfhost:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0
      
      - name: Build
        run: zig build
      
      - name: Test
        run: zig build test
      
      - name: Format Check
        run: zig fmt --check src/

  fuzzing:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install AFL++
        run: sudo apt install aflplusplus
      
      - name: Build for fuzzing
        run: |
          afl-clang-fast -fsanitize=fuzzer,address -o fuzz_parser \
            fuzz/fuzz_parser.c src/parser.c src/lexer.c
      
      - name: Run fuzzing (10 minutes)
        run: |
          mkdir -p corpus
          echo 'fn main() void {}' > corpus/valid.astra
          timeout 600 afl-fuzz -i corpus -o findings ./fuzz_parser
```

### 6.3 Cross-Platform CI Matrix

| Platform | Compiler | Notes |
|----------|----------|-------|
| Ubuntu 22.04 | Clang 15+, GCC 12+ | Primary CI |
| macOS 13 | Apple Clang | LLVM from Homebrew |
| Windows | MSVC, MinGW | CMake + Ninja |
| Android (NDK) | Clang | Cross-compilation test |
| iOS (Xcode) | Apple Clang | Cross-compilation test |

---

## 7. Documentation

### 7.1 Doxygen (C Documentation)

**Installation:**
```bash
# Ubuntu/Debian
sudo apt install doxygen graphviz

# macOS
brew install doxygen graphviz

# Windows
winget install doxygen
```

**Configuration:**
```bash
doxygen -g  # Generates Doxyfile
```

```yaml
# Doxyfile key settings
PROJECT_NAME = "Astra Compiler"
OUTPUT_DIRECTORY = docs/doxygen
INPUT = src/
RECURSIVE = YES
GENERATE_HTML = YES
GENERATE_LATEX = NO
EXTRACT_ALL = YES
HAVE_DOT = YES
```

```c
/**
 * @brief Tokenize source code into tokens.
 * 
 * @param lexer The lexer instance
 * @return Next token from input, or TOKEN_EOF at end
 * 
 * @note Lexer must be initialized with lexer_init() first
 * @see lexer_init(), Token
 */
Token lexer_next(Lexer *lexer);
```

### 7.2 Zig Documentation

```bash
# Generate documentation from Zig source
zig build docs

# View generated docs
open zig-out/docs/index.html
```

Zig uses `///` doc comments which are parsed automatically:

```zig
/// Parse a function declaration from the token stream.
/// Returns a FunctionNode on success, or ParseError.InvalidSyntax.
///
/// The parser advances past the closing brace automatically.
pub fn parseFunction(self: *Parser) ParseError!FunctionNode {
    // ...
}
```

### 7.3 Architecture Diagrams

**Mermaid** (for Markdown docs):
```markdown
```mermaid
graph TD
    A[Source Code] --> B[Lexer]
    B --> C[Tokens]
    C --> D[Parser]
    D --> E[AST]
    E --> F[Type Checker]
    F --> G[Typed AST]
    G --> H[Code Generator]
    H --> I[LLVM IR]
    I --> J[Object Code]
    J --> K[Linker]
    K --> L[Executable]
``

**Graphviz** (for detailed diagrams):
```dot
digraph AstraCompiler {
    rankdir=LR;
    node [shape=box];
    
    Source -> Lexer -> Tokens -> Parser -> AST
    AST -> TypeChecker -> TypedAST
    TypedAST -> CodeGen -> LLVMIR
    LLVMIR -> ObjectCode -> Linker -> Executable
}
```

---

## 8. Development Environment

### 8.1 Recommended OS

| OS | Pros | Cons | Use For |
|----|------|------|---------|
| **Linux (Ubuntu 22.04)** | Best tool support, Docker, CI | Desktop experience | Primary development |
| **macOS** | Unix tools, iOS cross-compile | Limited hardware | Cross-compilation testing |
| **Windows (WSL2)** | Windows + Linux tools | WSL overhead | Windows target testing |

### 8.2 Recommended Shell Setup

```bash
# .bashrc or .zshrc additions
export PATH="$HOME/.local/bin:$PATH"

# Zig
export PATH="/path/to/zig:$PATH"

# LLVM
export PATH="/usr/lib/llvm-17/bin:$PATH"
export LLVM_DIR="/usr/lib/llvm-17"

# Build tools
export CMAKE_GENERATOR="Ninja"

# Aliases
alias build='cmake --build build'
alias test='ctest --test-dir build'
alias clean='rm -rf build && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug'
alias format='clang-format -i src/*.c src/*.h && zig fmt src/'
alias lint='cppcheck --enable=all src/ && clang-tidy src/*.c'
```

### 8.3 Package Managers

| Platform | Package Manager | Key Packages |
|----------|----------------|--------------|
| **Ubuntu** | apt | cmake, ninja-build, clang, llvm-dev, valgrind, cppcheck |
| **macOS** | Homebrew | cmake, ninja, llvm, doxygen, graphviz |
| **Windows** | winget/choco | cmake, ninja, llvm, doxygen |
| **All** | pip | meson, compiledb |

---

## 9. Performance Tools

### 9.1 Benchmarking

| Framework | Language | Notes |
|-----------|----------|-------|
| **Google Benchmark** | C++ | Industry standard, statistical rigor |
| **Criterion** | Rust | Statistical analysis, regression detection |
| **Zig built-in** | Zig | `std.benchmark` |

**For C seed compiler — Google Benchmark:**

```cpp
// bench/bench_parser.cpp
#include <benchmark/benchmark.h>
#include "parser.h"

static void BM_ParseSmallFile(benchmark::State& state) {
    const char* source = "fn main() void { return 42; }";
    for (auto _ : state) {
        Lexer lexer;
        lexer_init(&lexer, source);
        Parser parser;
        parser_init(&parser, &lexer);
        Ast* ast = parser_parse(&parser);
        ast_free(ast);
    }
}
BENCHMARK(BM_ParseSmallFile);

BENCHMARK_MAIN();
```

**For Zig self-hosting — std.benchmark:**

```zig
const std = @import("std");

test "benchmark parser" {
    var timer = try std.time.Timer.start();
    // ... run parser ...
    const elapsed = timer.read();
    std.debug.print("Parser: {}ns\n", .{elapsed});
}
```

### 9.2 Flame Graphs

```bash
# Linux perf
perf record -g -p $(pidof astra-cc) -- sleep 10
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg

# macOS
instruments -t "Time Profiler" -D output.trace ./astra-cc
# Open in Instruments GUI, export flame graph
```

### 9.3 Memory Profiling

| Tool | Platform | What It Does |
|------|----------|-------------|
| **Massif** (Valgrind) | Linux | Heap memory profiling |
| **heaptrack** | Linux | Memory allocation tracking |
| **Instruments (Leaks)** | macOS | Memory leak detection |

```bash
# Massif
valgrind --tool=massif ./astra-cc large_file.astra
ms_print massif.out.*

# heaptrack
heaptrack ./astra-cc large_file.astra
heaptrack_gui heaptrack.astra-cc.*
```

---

## 10. Security Tools

### 10.1 Fuzzing (Detailed)

| Fuzzer | Type | Speed | Coverage |
|--------|------|-------|----------|
| **AFL++** | Mutation-based | Fast | Hardware + software |
| **LibFuzzer** | In-process | Fastest | Software |
| **Honggfuzz** | Multi-process | Fast | Hardware (Intel PT) |

**Recommended fuzzing strategy for Astra:**

1. **Parser fuzzing** — LibFuzzer for in-process speed
2. **Full compiler fuzzing** — AFL++ for end-to-end testing
3. **Fuzzing dictionary** — Include Astra keywords and syntax patterns

```bash
# Create fuzzing dictionary
cat > fuzz/dict.txt << EOF
fn
return
if
else
while
for
let
mut
pub
struct
enum
impl
trait
+
-
*
/
%
=
==
!=
<
>
<=
>=
(
)
{
}
[
]
;
,
.
EOF

# Run AFL++ with dictionary
afl-fuzz -i corpus -o findings -x fuzz/dict.txt ./fuzz_compiler
```

### 10.2 Static Analysis (Security)

| Tool | What It Does | When to Use |
|------|-------------|-------------|
| **Coverity** | Deep analysis, enterprise | Periodic scans |
| **CodeQL** | Query-based analysis, GitHub-native | CI integration |
| **Semgrep** | Lightweight pattern-based | Pre-commit, CI |
| **Clang Static Analyzer** | Built into Clang | Development |

**CodeQL setup for Astra:**

```yaml
# .github/workflows/codeql.yml
name: CodeQL Analysis

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 6 * * 1'  # Weekly Monday 6am

jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: github/codeql-action/init@v3
        with:
          languages: c
      - uses: github/codeql-action/autobuild@v3
      - uses: github/codeql-action/analyze@v3
```

**Semgrep setup:**

```yaml
# .github/workflows/semgrep.yml
name: Semgrep

on:
  push:
    branches: [main]
  pull_request:

jobs:
  semgrep:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: semgrep/semgrep-action@v1
        with:
          config: >-
            p/default
            p/security-audit
            p/owasp-top-ten
            p/cwe-top-25
```

### 10.3 Compiler-Specific Security Checks

For a compiler, pay special attention to:

1. **Buffer overflows** in lexer/parser (user input handling)
2. **Integer overflows** in type calculations
3. **Use-after-free** in AST/IR management
4. **Infinite loops** in parser/type checker (DoS prevention)
5. **Stack overflow** in recursive parsing

```c
// Compile with all security sanitizers
CFLAGS=-fsanitize=address,undefined -fstack-protector-strong \
       -D_FORTIFY_SOURCE=2 -Wformat -Wformat-security
```

---

## Summary: Recommended Toolchain

### C Seed Compiler
- **Compiler:** Clang (development), GCC (production)
- **Build:** CMake + Ninja
- **Debug:** GDB + ASAN + UBSAN
- **Test:** Unity + Ceedling
- **Format:** clang-format
- **Analyze:** cppcheck + clang-tidy
- **Fuzz:** AFL++ + LibFuzzer
- **Docs:** Doxygen + Mermaid

### Zig Self-Hosting Compiler
- **Compiler:** Zig 0.16.0 (stable)
- **Build:** build.zig (built-in)
- **Debug:** GDB/LLDB + built-in stack traces
- **Test:** Built-in test framework
- **Format:** zig fmt
- **Cross-compile:** Built-in (first-class)
- **LLVM:** C API via @cImport

### CI/CD
- **Platform:** GitHub Actions
- **Matrix:** Linux + macOS + Windows
- **Security:** CodeQL + Semgrep + AFL++
- **Docs:** Doxygen + Mermaid in GitHub Pages
