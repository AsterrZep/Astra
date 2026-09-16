# Contributing to Astra

Thank you for your interest in contributing to Astra! This document provides guidelines for contributing to the project.

## Getting Started

1. **Fork** the repository on GitHub
2. **Clone** your fork locally:
   ```bash
   git clone git@github.com:your-username/Astra.git
   cd Astra
   ```
3. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/my-feature
   ```

## Types of Contributions

### Bug Reports

If you find a bug, please open an issue with:

- A clear, descriptive title
- Steps to reproduce the issue
- Expected behavior vs actual behavior
- Environment details (OS, Astra version)
- Relevant code snippets or error messages

### Feature Requests

Feature requests are welcome. Please include:

- A clear description of the problem you're trying to solve
- Proposed solution or API design
- Examples of how the feature would be used
- Comparison with how other languages handle this

### Code Contributions

1. **Read the [Architecture Specification](ARCHITECTURE.md)** to understand the language design
2. **Check existing issues** to see if someone is already working on similar changes
3. **Discuss significant changes** in GitHub Discussions before implementing
4. **Write tests** for any new functionality
5. **Update documentation** if your change affects public APIs

### Documentation

- Fix typos and grammar errors
- Improve explanations and examples
- Add missing documentation
- Translate documentation (future)

## Development Setup

### Prerequisites

- C compiler (gcc or clang)
- LLVM 17+ (for the LLVM backend)
- Python 3.10+ (for build scripts)

### Building from Source

```bash
# Clone the repository
git clone git@github.com:AsterrZep/Astra.git
cd Astra

# Build the seed compiler
make seed

# Run the test suite
make test

# Run the full build
make all
```

## Code Style

### C Code (Seed Compiler)

- Follow the [C11 standard](https://en.wikipedia.org/wiki/C11_(C_standard_revision))
- Use 4-space indentation
- Prefer descriptive variable names
- Comment complex algorithms and data structures
- Keep functions focused and under 50 lines when possible

### Astra Code

- Use 4-space indentation
- Follow the naming conventions defined in the architecture spec
- Write self-documenting code with clear variable names
- Add comments only when the "why" is not obvious from the code

## Testing

```bash
# Run all tests
make test

# Run specific test categories
make test-unit          # Unit tests
make test-conformance   # Language conformance tests
make test-fuzz          # Fuzz testing (long-running)
```

### Writing Tests

- Place unit tests in the `tests/unit/` directory
- Place conformance tests in `tests/conformance/` with the format:
  ```astra
  //@ check-pass
  //@ expected-output: "expected output"
  fn test_name() {
      // test code
  }
  ```
- Place error tests in `tests/ui/` with:
  ```astra
  //@ check-fail
  //@ expected-error: "expected error message"
  fn test_name() {
      // code that should fail
  }
  ```

## Pull Request Process

1. **Update the README.md** with details of changes if applicable
2. **Update the CHANGELOG.md** with a summary of changes
3. **Ensure all tests pass** (`make test`)
4. **Write a clear PR description** explaining what and why
5. **Link related issues** in the PR description
6. **Request review** from a maintainer

### PR Title Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat: add new syntax feature`
- `fix: resolve compilation error`
- `docs: update architecture spec`
- `test: add conformance tests for enums`
- `refactor: simplify type checker`

## Review Process

- All PRs require at least one review from a maintainer
- Reviewers may request changes before merging
- Address review feedback promptly
- Once approved, a maintainer will merge the PR

## Code of Conduct

Please follow our [Code of Conduct](CODE_OF_CONDUCT.md) in all interactions.

## Questions?

If you have questions about contributing, feel free to ask in [GitHub Discussions](https://github.com/AsterrZep/Astra/discussions).

---

Thank you for helping make Astra better!
