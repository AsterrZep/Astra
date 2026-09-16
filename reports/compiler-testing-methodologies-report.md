# Compiler Testing Methodologies & Tools for Astra

**Date:** 2026-09-16
**Scope:** Comprehensive research on compiler testing strategies for a dual-backend (LLVM + bytecode VM) language

---

## Table of Contents

1. [Compiler Testing Frameworks](#1-compiler-testing-frameworks)
2. [Fuzzing Compilers](#2-fuzzing-compilers)
3. [Conformance Test Suites](#3-conformance-test-suites)
4. [Differential Testing](#4-differential-testing)
5. [Regression Testing](#5-regression-testing)
6. [Performance Benchmarking](#6-performance-benchmarking)
7. [Static Analysis of Compiler Code](#7-static-analysis-of-compiler-code)
8. [Property-Based Testing](#8-property-based-testing)
9. [Formal Verification of Compilers](#9-formal-verification-of-compilers)
10. [Recommendations for Astra](#10-recommendations-for-astra)

---

## 1. Compiler Testing Frameworks

### 1.1 Csmith

**What it is:** A random C program generator developed at the University of Utah (Yang, Chen, Eide, Regehr). Open-sourced in 2009.

**How it works:**
1. Generates random C programs from scratch using a 40,000-line C++ generator
2. Programs are **guaranteed free of undefined behavior** (UB) — the generator interleaves static analysis with code generation
3. Each generated program prints a deterministic CRC hash of global variables at exit
4. The test harness compiles the program with multiple compilers (GCC, Clang, etc.), runs each executable, and compares output hashes
5. Hash mismatch = miscompilation bug; crash = compiler crash bug

**Key design decisions:**
- Generates complex code: structs, unions, arrays, pointer arithmetic, control flow, function calls
- Programs are surprisingly large (~81 KB median) for maximum bug-finding power
- Avoids UB by construction — each generated variable has a single, well-defined interpretation
- Uses `randprog` as ancestor, evolved significantly

**Findings:** Found 300+ bugs in GCC and LLVM combined. Bugs concentrated in optimization passes.

**Relevance to Astra:** Csmith is C-specific, but its approach (generate → compile with N backends → compare output) is the blueprint for Astra's differential testing strategy. A "Csmith for Astra" would generate valid Astra programs and compare VM vs LLVM output.

### 1.2 YARPGen (Yet Another Random Program Generator)

**What it is:** Intel/Utah compiler fuzzer focused on scalar and loop optimizations. Created by Livinskii, Babokin, and Regehr.

**How it works:**
1. Generates random C/C++ programs targeting specific optimization patterns
2. Uses **generation policies** to increase the probability of triggering optimizations:
   - Loop nest, loop sequence, stencil, reduction patterns
   - Common subexpression buffers, used constant buffers
   - Skewed probability for vectorizable loops and INT_MAX/INT_MIN
3. **Statically avoids UB** without runtime checks (unlike Csmith's dynamic approach)
4. Generates a high-level model of computation first, then augments with random computations

**Key differences from Csmith:**
- More structured: targets specific optimization bugs rather than general correctness
- Statically avoids UB (Csmith uses dynamic checks)
- Better at finding optimization-specific bugs (loop fusion, vectorization, dead code elimination)
- Extensible to DPC++ (data-parallel C++) and ISPC

**Findings:** 260+ bugs in GCC, Clang, ISPC, DPC++, SDE, and Alive2.

**Relevance to Astra:** YARPGen's optimization-targeting policies are directly applicable. Astra could build generation policies for its specific optimizations (ARC insertion, fiber yield-point insertion, type erasure, monomorphization).

### 1.3 LLBMC (Low-Level Bounded Model Checker)

**What it is:** A bounded model checking tool for C/C++ that operates on LLVM IR rather than source code.

**How it works:**
1. Compiles C/C++ to LLVM IR (using LLVM frontend)
2. Unrolls loops and inlines functions to a fixed bound
3. Converts LLVM IR to a logical representation (bitvector theory with arrays)
4. Passes the logical encoding to the SMT solver Boolector
5. Checks for: invalid memory accesses, use-after-free, double free, overflow, division by zero, assertion violations

**Key insight:** Operating on compiler IR rather than source code provides:
- Bit-precise memory model
- Compiler optimizations come "for free" (already applied)
- Simpler semantics to encode

**Relevance to Astra:** LLBMC's approach of analyzing compiler IR directly is highly relevant. Astra could build a bounded model checker for AIR (Astra IR) to verify that optimization passes preserve semantics.

### 1.4 Equivalence Modulo Inputs (EMI)

**What it is:** A methodology introduced by Le, Afshari, and Su (PLDI 2014) for compiler validation.

**How it works:**
1. Profile a program's execution on a set of test inputs
2. Identify code that is **never executed** for those inputs
3. Stochastically mutate (delete/modify) the unexecuted code to create a variant
4. The variant is equivalent to the original **modulo the test inputs** (same behavior for those inputs)
5. Compile both original and variant, run on the same inputs
6. If outputs differ → compiler bug (the compiler's optimization of the variant is wrong for some input)

**Key insight:** The compiler must produce correct code for ALL inputs, but we only test on a SUBSET. Unexecuted code is "dead" for those inputs, so mutating it preserves equivalence for testing purposes. But the compiler must still handle it correctly for all possible inputs.

**Implementations:**
- **Orion:** First implementation. Profiles with gcc/gcov, mutates dead code, found 147 bugs in GCC/LLVM
- **Hermes:** Extends EMI to mutate LIVE code (flip operations, insert operations), finding more bugs
- **DeEI:** Uses deep learning to guide which code to mutate

**Relevance to Astra:** EMI is the most practical approach for Astra. Given Astra's test corpus, the compiler can generate variants by mutating unreachable code paths, then differentially test VM vs LLVM output. This requires NO reference compiler — just two compilation tracks.

### 1.5 Differential Testing (McKeeman, 1998)

**What it is:** The foundational oracle-free testing methodology for compilers.

**How it works:**
1. Generate or select a test program
2. Compile with two or more independent implementations (different compilers, different optimization levels, different versions)
3. Execute all compiled versions on the same inputs
4. Compare outputs: divergence = potential bug

**Three strategies:**
- **Cross-compiler:** Compare GCC vs Clang vs Astra (different implementations)
- **Cross-optimization:** Compare `-O0` vs `-O2` vs `-O3` within the same compiler
- **Cross-version:** Compare `astra v0.1` vs `astra v0.2`

**Relevance to Astra:** Differential testing is Astra's **primary testing strategy**. The dual backend (VM vs LLVM) provides a natural differential testing setup. Additionally, comparing Astra-compiled code with C equivalents of the same algorithm provides cross-language differential testing.

---

## 2. Fuzzing Compilers

### 2.1 Grammar-Based Fuzzing

**Approach:** Define the language grammar, then randomly derive valid programs from it.

**How it works:**
1. Formalize the Astra grammar (EBNF or similar)
2. Use a grammar fuzzer (e.g., `狗尾草` (Grammarinator), `Grammatech`, custom tools)
3. Generate random valid programs by traversing production rules
4. Weight rules to favor interesting constructs (nested expressions, complex types, loops)

**Advantages:**
- Every generated program is syntactically valid
- Can target specific grammar rules for coverage
- Easy to parameterize (max depth, specific constructs)

**Disadvantages:**
- Syntactically valid ≠ semantically valid (type errors, undefined behavior)
- May miss bugs that require specific semantic combinations

**Tools:** Grammarinator (Python), Domato (JS/CSS), custom ANTLR-based generators

### 2.2 Mutation-Based Fuzzing

**Approach:** Start with valid seed programs and apply random mutations.

**Mutation operators for compilers:**
- **Syntax mutations:** Insert/delete/swap tokens, change operators, modify literals
- **Semantic mutations (EMI-style):** Delete dead code, flip arithmetic ops, change branch conditions
- **Structural mutations:** Inline functions, duplicate loops, reorder statements
- **Type mutations:** Change type annotations, widen/narrow types

**Advantages:**
- Mutations preserve some structure from real programs
- More likely to trigger complex optimization interactions
- Can combine with coverage feedback

**Tools:** AFL++ (with custom mutation operators), LibFuzzer, Radamsa

### 2.3 Coverage-Guided Fuzzing

**Approach:** Use runtime coverage feedback to guide input generation toward unexplored code paths.

**How it works for compilers:**
1. Instrument the compiler binary with coverage tracking (SanitizerCoverage, AFL's instrumentation)
2. Feed random/mutated Astra source files to the compiler
3. Track which compiler code paths are exercised
4. Mutate inputs that discover new compiler code paths
5. Check for crashes, hangs, assertion failures, and (with differential testing) miscompilations

**Key insight:** Coverage-guided fuzzing targets the **compiler itself** (finding crashes, panics, infinite loops in the compiler), while grammar/mutation-based fuzzing targets the **compiled code** (finding miscompilations).

### 2.4 Tools

#### AFL++ (American Fuzzy Lop ++)
- **Type:** Coverage-guided, mutation-based, out-of-process fuzzer
- **Key features:**
  - fork-based execution (robust against compiler crashes)
  - cmplog/redqueen mode for input-to-state fuzzing
  - Persistent mode for fast in-process fuzzing
  - Custom mutation strategies (MOpt, explore, exploit)
  - Supports instrumentation via LLVM pass, GCC plugin, or QEMU
- **Best for:** Fuzzing the compiler binary itself (crash finding)

#### LibFuzzer
- **Type:** Coverage-guided, in-process, evolutionary fuzzer (LLVM project)
- **Key features:**
  - In-process fuzzing (no fork overhead, 10-100x faster than AFL)
  - Uses LLVM SanitizerCoverage for coverage
  - Compare-trace-guided mutations (`-fsanitize-coverage=trace-cmp`)
  - Dictionary support for structured inputs
  - Can combine with ASAN/UBSAN/MSAN for memory safety
- **Best for:** Fuzzing compiler APIs, parser functions, individual optimization passes

#### Honggfuzz
- **Type:** Coverage-guided fuzzer with hardware feedback support
- **Key features:**
  - Hardware-based code coverage (Intel PT, Intel BTS) — no instrumentation needed
  - Software-based fallback (SanitizerCoverage)
  - Multi-process and persistent modes
  - Better at finding bugs in opaque code (e.g., when compiler is closed-source or hard to instrument)
- **Best for:** Fuzzing when you can't easily instrument the compiler, or when you need hardware coverage for deeper paths

### 2.5 Compiler-Specific Fuzzing Strategy

For Astra, the recommended fuzzing setup is:

```
┌─────────────────────────────────────────────────────┐
│                Astra Compiler Fuzzing                 │
│                                                       │
│  Layer 1: Parser Fuzzing (LibFuzzer)                 │
│  ├── Fuzz the parser with random byte streams        │
│  ├── Check: no crashes, proper error recovery        │
│  └── Instrument: parser module directly              │
│                                                       │
│  Layer 2: Compiler Fuzzing (AFL++/Honggfuzz)         │
│  ├── Feed random .astra files to `astra build`       │
│  ├── Check: no crashes, no ICEs, no hangs            │
│  └── Instrument: full compiler binary                │
│                                                       │
│  Layer 3: Code Generator Fuzzing (Custom + AFL++)    │
│  ├── Generate random Astra programs (grammar-based)  │
│  ├── Compile with VM and LLVM backends               │
│  ├── Compare output hashes (differential testing)    │
│  └── Check: miscompilations, wrong code bugs         │
│                                                       │
│  Layer 4: Runtime Fuzzing (LibFuzzer)                │
│  ├── Fuzz the VM interpreter with random bytecodes   │
│  ├── Fuzz the ARC/ORC runtime with random ref patterns│
│  └── Check: memory safety, no leaks, no data races   │
└─────────────────────────────────────────────────────┘
```

---

## 3. Conformance Test Suites

### 3.1 How Language Conformance Tests Work

Conformance test suites validate that an implementation correctly implements the language specification. They are the "ground truth" for language behavior.

**General architecture:**
1. **Test files** contain small, focused test cases (one assertion per test or per group)
2. **Metadata** specifies expected behavior (should compile? should run? expected output?)
3. **Test harness** runs each test against the implementation and compares results
4. **Reporting** shows pass/fail/skip per test with detailed diagnostics

### 3.2 Plum Hall (C/C++)

- **What:** Commercial conformance test suite for C and C++ compilers
- **Structure:** Thousands of test files organized by language feature
- **Coverage:** Covers every normative clause in the C/C++ standard
- **Metadata:** Each test has expected output and expected compilation behavior
- **Usage:** Run against compiler, compare actual vs expected output
- **Cost:** Commercial (expensive), but gold standard for C/C++ conformance

**Key lesson:** Tests are organized by **spec section**, not by compiler feature. Every normative statement in the spec should have corresponding tests.

### 3.3 Test262 (JavaScript)

- **What:** Official ECMAScript conformance test suite (ECMA TR/104), maintained by TC39
- **Size:** 50,000+ test files as of May 2025
- **Structure:**
  ```
  test/
  ├── language/          # Language features
  │   ├── expressions/
  │   ├── statements/
  │   ├── types/
  │   └── literals/
  ├── built-ins/         # Standard library built-ins
  ├── harness/           # Test harness infrastructure
  └── src/               # Test generation tools
  ```
- **Test format:** Each file is a self-contained JS program with YAML frontmatter metadata:
  ```yaml
  ---
  flags: [onlyStrict]
  includes: [sta.js]
  features: [arrow-function, default-parameters]
  negative:
    phase: parse
    type: SyntaxError
  ---
  // Test code here
  ```
- **Metadata fields:**
  - `flags`: `[noStrict]`, `[onlyStrict]`, `[module]`, `[raw]`, `[async]`, `[generated]`
  - `negative`: Expected error phase (`parse`/`resolution`/`runtime`) and type
  - `features`: Language features required for the test
  - `includes`: Helper files to include
- **Execution:** Tests must run in isolated ECMAScript realms. Each test produces exactly one pass/fail.
- **Contributor model:** Tests written by proposal champions, implementers, or community members. Stage 4 proposals require tests.

**Key lessons for Astra:**
- Self-contained tests with metadata are the gold standard
- Negative tests (expected errors) are as important as positive tests
- Feature flags allow progressive implementation
- Community contribution model scales test suite growth

### 3.4 Rust Compiler Test Suite (compiletest)

- **What:** The Rust compiler's test harness, called `compiletest`
- **Structure:**
  ```
  tests/
  ├── ui/                    # Check stdout/stderr snapshots
  ├── ui-fulldeps/           # UI tests requiring linkable rustc
  ├── pretty/                # Pretty printing tests
  ├── incremental/           # Incremental compilation
  ├── run-make/              # General purpose Makefile-based tests
  ├── codegen/               # Codegen verification
  ├── codegen-units/         # Codegen unit partitioning
  ├── assembly/              # Assembly output verification
  ├── debuginfo/             # Debug info tests
  ├── rustdoc/               # Documentation tests
  └── build-std/             # Build-std tests
  ```
- **Test annotation system:** Tests use comment annotations to configure behavior:
  ```rust
  //@ compile-flags: -Zmir-opt-level=3
  //@ check-pass
  //@ stderr-pattern: warning
  ```
- **Run modes:** `check-pass` (must compile), `check-fail` (must fail with specific error), `run-pass` (must compile and run)
- **Revision system:** Tests can have multiple revisions for testing different configurations
- **Parallel execution:** compiletest runs tests in parallel with caching

**Key lessons for Astra:**
- Snapshot testing (compare stdout/stderr) catches regression in error messages
- Multiple test "suites" for different aspects of the compiler
- Incremental test support is critical for Astra's dev-mode backend
- The `//@ compile-flags` pattern is essential for testing optimization levels

### 3.5 Go Test Suite

- **What:** Go's compiler and runtime test suite
- **Structure:**
  ```
  test/
  ├── *.go                  # Single-file test programs
  ├── fixedbugs/            # Regression tests for fixed bugs
  ├── live/                 # Tests for liveness analysis
  ├── scan/                 # Tests for escape analysis
  └── funct/                # Function-related tests
  ```
- **Convention:** Each `.go` file is a complete test program. The test runner compiles and runs each file, checking expected output vs actual output.
- **Bug tracking:** `fixedbugs/` directory named by issue number (e.g., `issue12345.go`)
- **Negative tests:** Comments like `// Error compiling or running` indicate expected failures

**Key lesson:** Issue-indexed regression tests make it trivial to verify that specific bugs don't recur.

---

## 4. Differential Testing for Astra

### 4.1 Backend Comparison (VM vs LLVM)

This is Astra's **most powerful testing strategy**. The dual backend provides a natural oracle.

**Approach:**
```bash
#!/bin/bash
# differential_test.sh
for file in corpus/*.astra; do
    # Compile with both backends
    ./astra run --backend=vm "$file" > vm_output.txt 2>&1
    ./astra build --backend=llvm -o test_llvm "$file" && ./test_llvm > llvm_output.txt 2>&1
    
    # Compare outputs
    if ! diff -q vm_output.txt llvm_output.txt > /dev/null 2>&1; then
        echo "DIVERGENCE: $file"
        diff vm_output.txt llvm_output.txt
        # Save the test case for reduction
        cp "$file" failures/
    fi
done
```

**Variations:**
1. **Optimization level comparison:** `-O0` vs `-O2` vs `-O3` within each backend
2. **Cross-backend comparison:** VM output vs LLVM output
3. **Cross-version comparison:** `astra v0.1` vs `astra v0.2`
4. **Cross-language comparison:** Astra program vs equivalent C program

### 4.2 Test Oracle Strategies

**Strategy 1: Hash-based (Csmith-style)**
```astra
# Generated program prints hash of global state
val x = 42
val y = 3.14
val z = "hello"
# ... complex computation ...
println(compute_hash(x, y, z))
```
Compile with VM and LLVM, compare hashes. Hash mismatch = bug.

**Strategy 2: Assertion-based**
```astra
# Test program contains assertions
assert(2 + 2 == 4)
assert(sqrt(4.0) == 2.0)
assert(factorial(5) == 120)
# ... compile with both backends, both must pass assertions
```

**Strategy 3: Output comparison**
```astra
# Test program produces deterministic output
println("expected output line 1")
println("expected output line 2")
# Both backends must produce identical output
```

**Strategy 4: Property-based (QuickCheck-style)**
```astra
# Test program checks properties
for i in 0..1000:
    val a = random_int()
    val b = random_int()
    assert(a + b == b + a)  # Commutativity
    assert(a * b == b * a)  # Commutativity of multiplication
```

### 4.3 Handling Non-Determinism

The VM and LLVM backends may produce different execution orders for concurrent code. To handle this:

1. **Deterministic test programs:** Use programs without concurrency, I/O timing dependencies, or memory allocation ordering
2. **Output normalization:** Strip timestamps, memory addresses, thread IDs from output before comparison
3. **Property-based comparison:** Instead of comparing exact output, verify that both backends satisfy the same properties

### 4.4 Test Case Reduction

When a divergence is found, minimize the test case:

1. **C-Reduce:** General-purpose test case reducer (works on any language)
   - Takes a large failing test case and a predicate (e.g., "still reproduces the bug")
   - Applies reduction passes: delta debugging, unparse, corpus-based reduction
   - Produces minimal reproducing test case

2. **Custom Astra reducer:** Since Astra has its own syntax, build a language-specific reducer that:
   - Removes unused functions/variables
   - Simplifies expressions
   - Reduces loop bounds
   - Inline small functions

---

## 5. Regression Testing

### 5.1 Test Organization for Astra

Based on Rust's compiletest model, adapted for Astra's dual backend:

```
tests/
├── conformance/              # Language specification compliance
│   ├── expressions/
│   │   ├── arithmetic.astra
│   │   ├── comparison.astra
│   │   ├── logical.astra
│   │   └── ...
│   ├── control-flow/
│   │   ├── if-else.astra
│   │   ├── while.astra
│   │   ├── for.astra
│   │   ├── match.astra
│   │   └── ...
│   ├── types/
│   │   ├── integers.astra
│   │   ├── floats.astra
│   │   ├── strings.astra
│   │   ├── structs.astra
│   │   ├── enums.astra
│   │   ├── option.astra
│   │   ├── result.astra
│   │   ├── arrays.astra
│   │   ├── slices.astra
│   │   ├── maps.astra
│   │   ├── functions.astra
│   │   ├── closures.astra
│   │   ├── traits.astra
│   │   └── ...
│   ├── modules/
│   │   ├── imports.astra
│   │   ├── visibility.astra
│   │   └── ...
│   ├── concurrency/
│   │   ├── fibers.astra
│   │   ├── spawn.astra
│   │   ├── channels.astra
│   │   └── ...
│   └── stdlib/
│       ├── io.astra
│       ├── math.astra
│       ├── collections.astra
│       └── ...
│
├── ui/                       # Error message and diagnostic tests
│   ├── compile_error/
│   │   ├── type_mismatch.astra         # //@ check-fail
│   │   ├── undefined_variable.astra    # //@ check-fail
│   │   ├── missing_return.astra        # //@ check-fail
│   │   └── ...
│   ├── runtime_error/
│   │   ├── index_out_of_bounds.astra   # //@ runtime-error
│   │   ├── null_pointer.astra          # //@ runtime-error
│   │   └── ...
│   └── warnings/
│       ├── unused_variable.astra       # //@ check-pass (with warning)
│       └── ...
│
├── codegen/                  # Generated code quality
│   ├── assembly/             # Verify specific assembly patterns
│   │   ├── vectorization.astra
│   │   ├── inlining.astra
│   │   └── ...
│   ├── optimization/         # Verify optimization effectiveness
│   │   ├── constant_folding.astra
│   │   ├── dead_code_elimination.astra
│   │   └── ...
│   └── ARC/                  # ARC injection correctness
│       ├── basic_retain.astra
│       ├── cycle_detection.astra
│       └── ...
│
├── incr/                     # Incremental compilation
│   ├── add_function.astra
│   ├── modify_type.astra
│   └── ...
│
├── dual-backend/             # Differential VM vs LLVM tests
│   ├── vm_vs_llvm/
│   │   ├── basic_math.astra
│   │   ├── string_ops.astra
│   │   └── ...
│   ├── optimization_levels/
│   │   ├── o0_vs_o2.astra
│   │   └── ...
│   └── regression/
│       └── issue_001.astra
│
├── property/                 # Property-based tests
│   ├── arithmetic_properties.astra
│   ├── string_properties.astra
│   └── ...
│
├── fuzz/                     # Fuzzing corpora
│   ├── seeds/                # Initial seed corpus
│   ├── crashes/              # Crash-reproducing test cases
│   └── miscompilations/      # Divergence-reproducing test cases
│
└── benchmarks/               # Performance benchmarks
    ├── compile_time/
    ├── runtime/
    └── memory/
```

### 5.2 Test Metadata Format

Following test262's model, each Astra test file should have structured metadata:

```astra
//@ compile-flags: --backend=vm -O2
//@ check-pass
//@ expected-output: "42\n"
//@ requires: feature XYZ
//@ slow: false
//@ backend: both
```

**Metadata fields:**
- `compile-flags`: Additional compiler flags
- `check-pass` / `check-fail` / `run-pass` / `run-fail`: Expected compilation/execution result
- `expected-output`: Expected stdout (for output comparison tests)
- `expected-error`: Expected error message pattern (for negative tests)
- `requires`: Language features or stdlib modules required
- `slow`: Whether to skip in quick test runs
- `backend`: Which backend(s) to test (`vm`, `llvm`, `both`)
- `issue`: GitHub issue number for regression tests

### 5.3 Test Selection and Prioritization

As the test suite grows, not all tests need to run on every CI run:

**Tier 1 (Every PR):**
- All conformance tests
- All UI tests
- Differential tests for modified compiler modules
- Quick property-based tests

**Tier 2 (Nightly/Pre-merge):**
- Full differential testing corpus
- Fuzzing regression tests
- Incremental compilation tests
- Performance regression tests

**Tier 3 (Weekly):**
- Full fuzzing runs (hours)
- Full property-based test suite
- Cross-platform tests
- Bootstrap tests (Astra compiling itself)

### 5.4 Flaky Test Detection

Flaky tests (tests that sometimes pass, sometimes fail) are especially problematic for compilers because:
- Timing-dependent tests (fiber scheduling)
- Memory-dependent tests (address-dependent behavior)
- Non-deterministic test order

**Detection strategies:**
1. **Track pass/fail history:** Record each test's pass/fail status over time. Tests that fail intermittently are flagged.
2. **Retry on failure:** Run failed tests up to 3 times. If any pass, mark as flaky.
3. **Quarantine flaky tests:** Move flaky tests to a separate suite that doesn't block CI.
4. **Root cause analysis:** Flaky tests often reveal real bugs (race conditions, uninitialized memory, ordering assumptions).

**Implementation:**
```
tests/
├── flaky/           # Known flaky tests (don't block CI)
│   ├── timing_fiber.astra
│   └── random_order.astra
└── stable/          # Deterministic tests (block CI on failure)
```

---

## 6. Performance Benchmarking

### 6.1 Benchmarking Compiler Speed

**Metrics to track:**
1. **Cold compile time:** Time to compile from scratch (no cache)
2. **Incremental compile time:** Time to recompile after a small change
3. **Memory usage:** Peak RSS during compilation
4. **Bootstrap time:** Time for Astra to compile itself

**Benchmark methodology:**
```
# Compile time benchmark
for file in benchmarks/compile_time/*.astra; do
    /usr/bin/time -f "%e %M" ./astra build --release "$file" 2>&1
done

# Incremental compile time
touch benchmarks/compile_time/incremental_target.astra
/usr/bin/time -f "%e" ./astra build --release benchmarks/compile_time/project.astra
```

**Statistical methods:**
- Run each benchmark 30+ times
- Report median and interquartile range (IQR), not mean
- Use Mann-Whitney U test for comparing two compiler versions
- Use bootstrapped confidence intervals for uncertainty
- Discard the first 5 runs (warmup)

### 6.2 Benchmarking Generated Code Quality

**Benchmark suites:**
1. **SPEC CPU 2017/2026:** Industry-standard compute-intensive benchmarks
   - 43 benchmarks (2017), 52 benchmarks (2026)
   - Covers integer, floating-point, single-threaded, and throughput workloads
   - Uses geometric mean for overall score
   - **Limitation:** C/C++/Fortran only. Astra would need equivalent Astra programs.

2. **Polybench/C:** Polyhedral benchmarks for loop-heavy computations
   - Good for testing loop optimization quality
   - Easy to port to Astra

3. **Rosetta Code:** Small programs implementing common algorithms
   - Good for testing compilation of diverse patterns
   - Easy to port

4. **Custom Astra benchmarks:**
   - `benchmarks/runtime/` — Measure execution time of specific programs
   - `benchmarks/memory/` — Measure memory usage
   - `benchmarks/startup/` — Measure startup time (critical for Astra's <10ms goal)
   - `benchmarks/fibers/` — Measure fiber scheduling overhead

**Code quality metrics:**
1. **Execution time:** How fast is the compiled code?
2. **Binary size:** How large is the compiled binary?
3. **Memory usage:** How much memory does the compiled code use?
4. **Cache efficiency:** L1/L2/L3 cache miss rates
5. **Instruction mix:** SIMD usage, branch prediction accuracy

### 6.3 Performance Regression Detection

**Approach:** Track performance metrics over time, detect regressions automatically.

```
# Performance regression test
baseline_time=$(cat benchmarks/baseline/fib_time.txt)
current_time=$(./astra build --release benchmarks/fib.astra && time ./fib)
ratio=$(echo "scale=2; $current_time / $baseline_time" | bc)
if (( $(echo "$ratio > 1.10" | bc -l) )); then
    echo "PERFORMANCE REGRESSION: 10%+ slowdown detected"
    exit 1
fi
```

**Tools:**
- `cargo-bench` (if Astra's toolchain is Rust-based)
- Custom benchmarking framework
- GitHub Actions with performance tracking (e.g., `benchmark-action/github-action-benchmark`)

---

## 7. Static Analysis of Compiler Code

### 7.1 Miri (for Rust-based compiler)

If Astra's compiler is written in Rust:
- **What:** An interpreter for Rust's MIR (Mid-level Intermediate Representation)
- **Detects:** Undefined behavior, memory safety violations, data races, memory leaks
- **How:** Executes MIR step-by-step with exhaustive checks at every operation
- **Usage:** `cargo miri test` runs all tests through Miri's interpreter
- **Findings:** Dozens of bugs in Rust's standard library and beyond

**Relevance:** If Astra's compiler is in Rust, running `cargo miri test` on the compiler catches undefined behavior in the compiler code itself (not the compiled code).

### 7.2 Sanitizers (for C/C++ or Rust-based compiler)

#### AddressSanitizer (ASAN)
- Detects: buffer overflows, use-after-free, double-free, memory leaks
- Overhead: ~2x slowdown, ~3x memory
- Usage: Compile with `-fsanitize=address`

#### UndefinedBehaviorSanitizer (UBSAN)
- Detects: signed integer overflow, null pointer dereference, misaligned access, integer divide by zero
- Overhead: Minimal (~5%)
- Usage: Compile with `-fsanitize=undefined`
- **Most important sanitizer for compiler testing** — catches UB in the compiler code

#### ThreadSanitizer (TSAN)
- Detects: data races, deadlocks
- Overhead: ~5-15x slowdown
- Usage: Compile with `-fsanitize=thread`
- **Critical for Astra's concurrent runtime** — the fiber scheduler and ARC/ORC must be race-free

#### MemorySanitizer (MSAN)
- Detects: use of uninitialized memory
- Overhead: ~3x slowdown
- Usage: Compile with `-fsanitize=memory`

### 7.3 Valgrind

- **What:** Dynamic analysis tool for memory debugging, memory leak detection, and profiling
- **Tools:** Memcheck (memory errors), Cachegrind (cache profiling), Callgrind (call profiling), Helgrind (thread errors)
- **Advantage:** No recompilation needed (works on existing binaries)
- **Disadvantage:** Very slow (~20-50x slowdown)
- **Best for:** Deep memory analysis when ASAN doesn't find the bug, profiling compiler performance

### 7.4 Static Analyzers

For the compiler code itself:

| Tool | Language | What it finds |
|:-----|:---------|:--------------|
| Clippy | Rust | Idiomatic Rust, common mistakes |
| Clang Static Analyzer | C/C++ | Memory leaks, null derefs, API misuse |
| Coverity | C/C++/Java | Deep interprocedural bugs |
| Infer (Facebook) | C/C++/Java | Null derefs, resource leaks |
| MIRI | Rust | Undefined behavior |

### 7.5 Recommended Static Analysis for Astra Compiler

```bash
# If compiler is in Rust:
cargo clippy -- -D warnings          # Lint
cargo miri test                      # UB detection
RUSTFLAGS="-Z sanitizer=address" cargo test  # Memory safety
RUSTFLAGS="-Z sanitizer=thread" cargo test   # Data races

# If compiler is in C/C++:
clang -fsanitize=address,undefined -g compiler.c
./compiler_test_suite
valgrind --tool=memcheck ./compiler_test_suite
```

---

## 8. Property-Based Testing

### 8.1 QuickCheck / Proptest Approach

**Concept:** Instead of writing specific test cases, write **properties** that should hold for ALL inputs, and let the framework generate random inputs to test.

**For compiler testing, properties include:**

```python
# Pseudo-code for Astra property tests

# Property 1: Compilation preserves semantics
def prop_compilation_preserves_semantics(program, input):
    vm_output = run_vm(compile_vm(program), input)
    llvm_output = run_llvm(compile_llvm(program), input)
    assert vm_output == llvm_output

# Property 2: Optimization doesn't change semantics
def prop_optimization_preserves_semantics(program, input):
    o0_output = run(compile(program, "-O0"), input)
    o2_output = run(compile(program, "-O2"), input)
    assert o0_output == o2_output

# Property 3: ARC doesn't change program behavior
def prop_arc_preserves_semantics(program, input):
    no_arc_output = run(compile(program, "--no-arc"), input)
    arc_output = run(compile(program, "--arc"), input)
    assert no_arc_output == arc_output

# Property 4: Type erasure is correct
def prop_type_erasure_correctness(program, input):
    typed_output = run(compile(program, "--show-types"), input)
    erased_output = run(compile(program, "--erase-types"), input)
    assert typed_output == erased_output

# Property 5: Monomorphization produces equivalent code
def prop_monomorphization_correctness(program, input):
    generic_output = run(compile(program, "--no-monomorphize"), input)
    mono_output = run(compile(program, "--monomorphize"), input)
    assert generic_output == mono_output
```

### 8.2 Generating Random Valid Astra Programs

The key challenge is generating **semantically valid** programs. Strategies:

**Strategy 1: Template-based generation**
```python
templates = [
    "let x = {int}\nprintln(x)",
    "let x = {int}\nlet y = {int}\nprintln(x + y)",
    "fn add(a: Int, b: Int) -> Int = a + b\nprintln(add({int}, {int}))",
    # ... hundreds of templates
]
```

**Strategy 2: AST-based generation**
```python
def generate_expr(depth=0, max_depth=5):
    if depth >= max_depth:
        return Literal(random_int())
    op = random.choice([Add, Sub, Mul, Div, Eq, Lt, Gt])
    left = generate_expr(depth + 1, max_depth)
    right = generate_expr(depth + 1, max_depth)
    return BinaryOp(op, left, right)
```

**Strategy 3: Mutation from real programs**
```python
def mutate_program(program):
    # Randomly apply one of:
    # - Replace a literal with another literal
    # - Change an operator
    # - Add/remove a variable
    # - Add/remove a function call
    # - Reorder statements
    # - Duplicate a statement
    pass
```

### 8.3 Shrinking

When a property fails, **shrink** the failing input to find the minimal reproduction:

```python
# Property fails: compile("+ 1 2") crashes
# Shrink: try removing parts
# "1 2" → still crashes
# "1" → doesn't crash
# Minimal reproduction: "+ 1" 
```

**Proptest** (Rust) and **Hypothesis** (Python) have excellent built-in shrinking.

### 8.4 Astra-Specific Properties

| Property | What it tests | How to verify |
|:---------|:-------------|:--------------|
| `compile(program) ⊇ compile(program, -O0)` | Optimizations don't add behavior | Differential testing |
| `sizeof(serialize(x)) == len(deserialize(serialize(x)))` | Serialization roundtrip | Property testing |
| `ARC_count(obj) >= 1 while obj reachable` | ARC correctness | Instrumentation + property |
| `fiber_yield() returns to same fiber` | Fiber scheduling | Deterministic scheduling |
| `match exhaustive = no runtime error` | Exhaustiveness checking | Random enum generation |
| `type_check(program) != Error ⇒ run(program) != TypeError` | Type soundness | Random program generation |

---

## 9. Formal Verification of Compilers

### 9.1 CompCert Approach

**What:** A formally verified optimizing C compiler written in Coq (proof assistant).

**How it works:**
1. The compiler is written as a function `Comp: SourceProgram → TargetProgram`
2. Each compilation pass is a function with a proven correctness theorem:
   ```
   ∀ S C, Comp(S) = OK(C) ⇒ S ≈ C
   ```
   (If compilation succeeds, the target program behaves like the source)
3. The proof is machine-checked by Coq — no trusted base except the Coq kernel

**Key results:**
- Csmith found **zero wrong-code bugs** in CompCert (after 6 CPU-years of testing)
- Middle-end bugs found in all other compilers were absent from CompCert
- Compilation times within 2x of `gcc -O0`

**Limitations:**
- Only covers the optimizing backend (parsing and linking are NOT verified)
- Requires deep expertise in Coq (very steep learning curve)
- Verification of a new optimization pass can take months
- Only covers C (not Astra)

### 9.2 Alternative Verification Approaches

#### Translation Validation
Instead of verifying the compiler, verify each compilation:
1. Compiler produces target code + a proof certificate
2. A separate validator checks the certificate
3. If validation passes, the compilation is correct

**Advantage:** Validator is much simpler than compiler
**Used by:** CompCert's instruction scheduling pass

#### Diverse Double-Compilation (DDC)
1. Compile program S with compiler C₁ → binary B₁
2. Compile program S with compiler C₂ → binary B₂
3. Disassemble B₁ and B₂, compare semantics
4. If they're equivalent, both compilers agree

**Advantage:** No formal methods needed, just two compilers
**Used by:** GCC validation, Rust compiler testing

### 9.3 Is Formal Verification Practical for Astra?

**Assessment:**

| Factor | Rating | Notes |
|:-------|:-------|:------|
| Team size | ❌ | Formal verification requires dedicated experts |
| Language complexity | ⚠️ | Astra's features (ARC, fibers, comptime) are complex to formalize |
| Time investment | ❌ | Months to years for meaningful verification |
| Value proposition | ⚠️ | High value, but may not justify the cost early on |
| Alternative: DDC | ✅ | Diverse double-compilation is practical and valuable |

**Recommendation:** Do NOT pursue full formal verification initially. Instead:

1. **Year 1-2:** Use differential testing (VM vs LLVM) and DDC-style cross-validation
2. **Year 2-3:** Begin formal specification of AIR semantics (the math, not the Coq proofs)
3. **Year 3+:** Consider partial verification of critical passes (ARC insertion, type erasure) if resources allow
4. **Ongoing:** Use property-based testing as "poor man's verification"

---

## 10. Recommendations for Astra

### 10.1 Testing Strategy Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Astra Testing Strategy                        │
│                                                                   │
│  Layer 0: Unit Tests (always)                                   │
│  ├── Every compiler component has unit tests                    │
│  ├── Run on every commit                                        │
│  └── Framework: built-in test framework or Rust #[test]         │
│                                                                   │
│  Layer 1: Conformance Tests (always)                            │
│  ├── Organized by language spec section                         │
│  ├── Self-contained with metadata annotations                   │
│  ├── Run on every PR                                            │
│  └── Modeled after test262                                      │
│                                                                   │
│  Layer 2: Differential Tests (always)                           │
│  ├── VM vs LLVM output comparison                               │
│  ├── Cross-optimization-level comparison                        │
│  ├── Run on every PR                                            │
│  └── Use hash-based output comparison                           │
│                                                                   │
│  Layer 3: Property-Based Tests (nightly)                        │
│  ├── Random program generation + invariant checking             │
│  ├── Run nightly                                                │
│  └── Use proptest (Rust) or Hypothesis (Python)                 │
│                                                                   │
│  Layer 4: Fuzzing (nightly/weekly)                              │
│  ├── AFL++ for compiler crash finding                           │
│  ├── LibFuzzer for parser/runtime fuzzing                       │
│  ├── Custom grammar fuzzer for Astra programs                   │
│  └── Run nightly, full run weekly                               │
│                                                                   │
│  Layer 5: Performance Benchmarks (nightly)                      │
│  ├── Compile time tracking                                      │
│  ├── Runtime performance tracking                               │
│  ├── Memory usage tracking                                      │
│  └── Regression detection with statistical tests                │
│                                                                   │
│  Layer 6: Static Analysis (always)                              │
│  ├── Clippy (if Rust compiler)                                  │
│  ├── Miri (UB detection in compiler)                            │
│  ├── ASAN/UBSAN (memory safety)                                 │
│  └── Run on every PR                                            │
└─────────────────────────────────────────────────────────────────┘
```

### 10.2 Prioritized Implementation Roadmap

#### Phase 1: Foundation (Month 1-2)

**Priority: CRITICAL**

1. **Set up test harness** — Choose and configure a test runner
   - If compiler is in Rust: use `cargo test` + `compiletest` (adapt from rustc)
   - If compiler is in another language: build a custom test runner modeled after compiletest
   - Define test metadata format (compile-flags, expected-output, etc.)

2. **Create initial conformance test suite** — Start with 100-200 tests covering:
   - Basic expressions (arithmetic, comparison, logical)
   - Variables (let, mut, val)
   - Control flow (if/else, while, for, match)
   - Functions (definition, calling, return)
   - Basic types (Int, Float, String, Bool)
   - Basic structs and enums
   - Option and Result types

3. **Set up differential testing** — Compare VM vs LLVM output
   - Build the differential test harness
   - Run on conformance tests
   - Fix any divergences immediately

4. **Enable sanitizers** — Run all tests with ASAN and UBSAN
   - Catches memory bugs in compiler and runtime
   - Low effort, high value

#### Phase 2: Coverage Growth (Month 3-4)

**Priority: HIGH**

5. **Expand conformance suite** to 500+ tests:
   - All type system features (generics, traits, type inference)
   - Module system (imports, visibility, re-exports)
   - Error handling (try/catch, Result propagation)
   - Closures and higher-order functions
   - Concurrency (fibers, spawn, channels)
   - ARC/ORC memory management
   - Comptime evaluation

6. **Build "Astra-Csmith"** — Random Astra program generator
   - Grammar-based generation with semantic validity
   - Generates programs that print hash of state
   - Enables continuous differential testing

7. **Set up LibFuzzer** for parser and compiler APIs
   - Fuzz parser with random byte streams
   - Fuzz type checker with random ASTs
   - Fuzz code generators with random AIR

8. **Build property-based test suite**
   - Start with 10-20 core properties
   - Use proptest (Rust) or Hypothesis (Python)
   - Focus on: arithmetic properties, string operations, type system invariants

#### Phase 3: Deep Testing (Month 5-6)

**Priority: MEDIUM**

9. **Set up AFL++** for full compiler fuzzing
   - Instrument `astra build` binary
   - Run with seed corpus from conformance tests
   - Target: 24-hour continuous fuzzing

10. **Build optimization-specific tests**
    - Test each optimization pass independently
    - Verify ARC insertion correctness
    - Verify fiber yield-point insertion
    - Verify monomorphization
    - Verify type erasure

11. **Set up performance benchmarks**
    - Track compile time (cold + incremental)
    - Track runtime performance (execution time, memory)
    - Track startup time (critical for Astra's <10ms goal)
    - Automated regression detection

12. **Build regression test infrastructure**
    - Every bug fix gets a test case
    - Test named by issue number (e.g., `issue_042.astra`)
    - Indexed and searchable

#### Phase 4: Maturity (Month 7+)

**Priority: LOWER (ongoing)**

13. **Cross-language differential testing**
    - Generate equivalent Astra + C programs
    - Compare compiled output
    - Find bugs in Astra's code generation

14. **Bootstrap testing**
    - Astra compiles itself
    - Compare bootstrap output with reference
    - Diverse double-compilation

15. **Cross-platform testing**
    - Linux (x86_64, aarch64)
    - macOS (x86_64, aarch64)
    - Windows (x86_64)
    - WASM

16. **Community contribution model**
    - Accept test contributions from users
    - Test review process
    - Automated CI for contributions

### 10.3 Tool Recommendations Summary

| Category | Tool | Priority | Notes |
|:---------|:-----|:---------|:------|
| **Test Runner** | compiletest (adapted from rustc) | Critical | If Rust-based compiler |
| **Test Runner** | Custom (pytest/cargo test) | Critical | If other language |
| **Conformance** | Custom suite (test262-style) | Critical | Self-contained tests with metadata |
| **Differential** | Custom scripts | Critical | VM vs LLVM output comparison |
| **Fuzzing (crash)** | AFL++ | High | Full compiler binary fuzzing |
| **Fuzzing (API)** | LibFuzzer | High | Parser, type checker, optimizer |
| **Fuzzing (programs)** | Custom grammar fuzzer | Medium | Random Astra program generation |
| **Property Testing** | proptest (Rust) | Medium | If compiler is in Rust |
| **Property Testing** | Hypothesis (Python) | Medium | If compiler is in Python |
| **Static Analysis** | Clippy | High | If Rust-based compiler |
| **Static Analysis** | Miri | High | UB detection in compiler |
| **Sanitizers** | ASAN + UBSAN | Critical | Memory safety + UB detection |
| **Sanitizers** | TSAN | High | Data race detection (concurrent runtime) |
| **Memory** | Valgrind | Medium | Deep analysis when ASAN insufficient |
| **Test Reduction** | C-Reduce | High | Minimize failing test cases |
| **Benchmarking** | Custom + criterion | Medium | Performance regression detection |
| **CI** | GitHub Actions | High | Automated testing pipeline |

### 10.4 CI Pipeline Design

```yaml
# .github/workflows/test.yml
name: Astra Compiler Tests

on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cargo test --all  # or equivalent
      
  conformance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: astra test tests/conformance/
      
  differential:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: astra test tests/dual-backend/
      
  sanitizers:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: RUSTFLAGS="-Z sanitizer=address" cargo test
      - run: RUSTFLAGS="-Z sanitizer=undefined" cargo test
      
  static-analysis:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cargo clippy -- -D warnings
      - run: cargo miri test

  # Nightly jobs
  fuzzing:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./fuzz/run_afl.sh --hours 4
      
  property-tests:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cargo test --test property_tests
```

### 10.5 Key Metrics to Track

| Metric | Target | How to measure |
|:-------|:-------|:---------------|
| **Test coverage** | >80% compiler code | LLVM source coverage or tarpaulin |
| **Conformance tests** | Growing monthly | Count of tests in conformance/ |
| **Differential divergence rate** | <0.1% | Divergences / total differential tests |
| **Fuzzing bugs found** | Tracked monthly | New bugs from AFL++/LibFuzzer |
| **Mean time to failure (MTTF)** | Increasing | Time between compiler crashes |
| **Compile time (median)** | <100ms for small files | Benchmark suite |
| **Startup time** | <10ms | Startup benchmark |
| **Sanitizer violations** | 0 | ASAN/UBSAN/TSAN test runs |

---

## Appendix A: Key Research Papers

| Paper | Year | Key Contribution |
|:------|:-----|:-----------------|
| McKeeman "Differential Testing for Software" | 1998 | Foundation of compiler differential testing |
| Yang et al. "Finding and Understanding Bugs in C Compilers" (Csmith) | 2011 | Random C program generation for compiler testing |
| Le et al. "Compiler Validation via Equivalence Modulo Inputs" | 2014 | EMI methodology, 147 bugs in GCC/LLVM |
| Livinskii et al. "Random Testing for C and C++ Compilers with YARPGen" | 2020 | Optimization-targeted random generation, 260+ bugs |
| Leroy "Formal Verification of a Realistic Compiler" (CompCert) | 2009 | First formally verified realistic compiler |
| Claessen & Hughes "QuickCheck" | 2000 | Property-based testing foundation |
| "A Survey of Compiler Testing" (ACM Computing Surveys) | 2020 | Comprehensive survey of all compiler testing methods |
| "A Survey of Modern Compiler Fuzzing" | 2023 | Latest fuzzing techniques and tools |

## Appendix B: Glossary

| Term | Definition |
|:-----|:-----------|
| **Miscompilation** | Compiler produces incorrect code (no crash, wrong output) |
| **ICE** | Internal Compiler Error (compiler crashes) |
| **UB** | Undefined Behavior (C/C++ standard allows anything) |
| **Oracle** | Mechanism to determine correct output (often unavailable for compilers) |
| **Differential testing** | Compare outputs from multiple implementations |
| **Shrinking** | Minimizing a failing test case to its simplest form |
| **Corpus** | Collection of test inputs for fuzzing |
| **Seed** | Initial input for fuzzing (can be empty, random, or curated) |
