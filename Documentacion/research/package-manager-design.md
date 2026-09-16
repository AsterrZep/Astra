# Astra Package Manager Design Report

## Executive Summary

This report analyzes package manager architectures across major ecosystems (Rust/Cargo, Go modules, Zig, npm, Python) and provides specific design recommendations for Astra's package manager (`astra pkg`). The design prioritizes **simplicity, fast resolution, cross-compilation support, and supply chain security** — aligning with Astra's philosophy of unified toolchains and developer ergonomics.

**Key recommendation:** A hybrid architecture combining Go's Minimal Version Selection (MVS) for deterministic resolution with Cargo's centralized registry model, extended with first-class cross-compilation support and content-addressed package storage inspired by Zig.

---

## 1. Package Manager Architectures

### 1.1 Centralized Registry (npm, crates.io, PyPI)

**How it works:** A single authoritative server hosts all package metadata and artifacts. Clients query the registry for version information and download tarballs.

**Pros:**
- Single source of truth for discovery and resolution
- Easiest to implement and maintain
- Built-in search and discovery
- Central authority for security (yanking, deprecation)

**Cons:**
- Single point of failure (npm outage = no installs)
- Vendor lock-in risk
- Scaling challenges for massive ecosystems
- No offline-first workflow by default

**Used by:** npm (registry.npmjs.org), crates.io, PyPI (pypi.org)

### 1.2 Decentralized (Go modules, Git-based)

**How it works:** Packages live in their original repositories. The package manager fetches directly from Git URLs or module proxies. No central authority.

**Pros:**
- No single point of failure
- Packages stay where they're developed
- Supports private repos natively
- Simpler publishing (just tag a release)

**Cons:**
- No global discovery mechanism
- Repository availability affects builds
- Harder to enforce security policies
- Proxy servers needed for reliability

**Used by:** Go modules (proxy.golang.org as optional cache), cargo (git dependencies)

### 1.3 Hybrid (Recommended for Astra)

**How it works:** Centralized default registry for public packages, with support for private registries, Git dependencies, and path dependencies. The registry is an optimization layer, not a requirement.

**Pros:**
- Best of both worlds
- Works offline with local cache
- Supports corporate/private packages
- Public registry for discovery, but not required

**Used by:** Cargo (crates.io + git + path), Zig (URL + hash + path)

**Recommendation:** Astra should adopt a **hybrid model** with:
1. Centralized public registry (`pkg.astralang.dev`) for discovery and distribution
2. Git dependencies for unreleased code
3. Path dependencies for local development
4. Private registry support for enterprises
5. Content-addressed storage (hash-based identity, not URL-based)

---

## 2. Dependency Resolution Algorithms

### 2.1 SAT Solvers (Cargo's historical approach, libsolv)

**How it works:** Encodes version constraints as boolean satisfiability problems. Each package-version pair is a boolean variable; dependencies and conflicts become clauses. A SAT solver finds a satisfying assignment.

**Pros:**
- Can solve complex constraint problems
- Can prove unsatisfiability (definitive "no solution" errors)
- Backend-swappable (Varisat, CaDiCaL)
- Well-studied theoretical foundations

**Cons:**
- NP-complete in worst case (though practical instances are fast)
- Opaque error messages without extra work
- Complex implementation
- Overkill for most real-world dependency graphs

**Used by:** Composer, DNF, Conda/libsolv, opam, Cargo (historically)

### 2.2 PubGrub (Modern Cargo, uv, Poetry, Bundler)

**How it works:** Conflict-driven backtracking algorithm with structured incompatibility tracking. Similar to SAT but designed specifically for version resolution. Produces human-readable error messages.

**Pros:**
- Human-readable conflict reports
- Native semver awareness
- Fast in practice (3x faster than naive backtracking for large graphs)
- Growing adoption (uv, Poetry, Bundler, Swift PM)
- Proven at scale (npm, Rust ecosystem)

**Cons:**
- More complex than MVS
- Requires backtracking (non-deterministic in some edge cases)
- Lock file needed for reproducibility

**Used by:** Cargo 1.90+, uv, Poetry, Bundler, Swift PM, Dart pub

### 2.3 Minimal Version Selection - MVS (Go modules)

**How it works:** For each dependency, pick the highest of the lowest requirements. Walk the dependency graph once, collecting all version requirements, take the maximum. No solver needed — just a graph traversal.

**Pros:**
- Deterministic (no lock file needed)
- Linear time complexity (O(V+E))
- Predictable and explainable
- Unique minimal answer (no ambiguity)
- High-fidelity builds (uses exact versions authors tested)

**Cons:**
- No automatic "latest" selection (must explicitly upgrade)
- Requires semver compatibility convention
- Less flexible than SAT/PubGrub
- Major versions use different import paths (semantic import versioning)

**Used by:** Go modules

### 2.4 Backtracking (npm, pip)

**How it works:** DFS with backtracking on conflicts. Try newest version first, backtrack when hitting a conflict, try alternatives.

**Pros:**
- Simple to implement
- Good enough for most cases
- Well-understood

**Cons:**
- Can be exponential in worst case
- Non-deterministic output in some cases
- Less informative error messages
- May miss valid solutions in complex graphs

**Used by:** npm (via Arborist), pip (via resolvelib)

### 2.5 Recommendation for Astra

**Use MVS as the primary algorithm** with PubGrub as a fallback for complex conflict resolution.

**Rationale:**
- Astra compiles to native code — reproducible builds are critical
- MVS is deterministic, simple, and fast (linear time)
- No lock file needed for library crates (like Go)
- Lock file only for binary crates (like Go's `go.sum` vs `go.mod`)
- PubGrub fallback handles edge cases where MVS cannot resolve

**Implementation approach:**
1. MVS for version selection (primary)
2. PubGrub for conflict detection and error reporting
3. Content-addressed storage for reproducibility (hash = identity)

---

## 3. Versioning Strategies

### 3.1 Semantic Versioning (SemVer)

**Format:** `MAJOR.MINOR.PATCH` (e.g., `1.2.3`)

**Convention:**
- MAJOR: Breaking changes
- MINOR: New features (backward-compatible)
- PATCH: Bug fixes (backward-compatible)

**Used by:** Rust, npm, most ecosystems

### 3.2 Calendar Versioning (CalVer)

**Format:** `YYYY.MM.DD` or `YY.MINOR.PATCH` (e.g., `2025.1.0`)

**Used by:** Ubuntu, some Python packages

### 3.3 Exact Versions

**Format:** `1.2.3` (no ranges)

**Used by:** Go modules (MVS uses exact minimum versions)

### 3.4 Version Ranges

**Formats:**
- `^1.2.3` (compatible with 1.2.3, equivalent to >=1.2.3 <2.0.0)
- `~1.2.3` (compatible with 1.2.x, equivalent to >=1.2.3 <1.3.0)
- `>=1.2.3` (any version >= 1.2.3)
- `*` (any version)

**Used by:** npm, Cargo

### 3.5 Lockfiles

| Ecosystem | Lockfile | Format |
|-----------|----------|--------|
| Cargo | `Cargo.lock` | TOML |
| npm | `package-lock.json` | JSON |
| Go | `go.sum` | Text (hashes only) |
| Yarn | `yarn.lock` | Custom text |
| Zig | (none) | Hash in build.zig.zon |

### 3.6 Recommendation for Astra

**SemVer with MVS semantics:**
- Dependencies declare minimum versions: `http = "^1.0"` means `>=1.0.0 <2.0.0`
- MVS selects the highest minimum that satisfies all requirements
- No ranges beyond caret (`^`) — keeps it simple
- `astra.lock` only for binary crates (executables), not libraries
- Library crates are inherently reproducible via MVS

**Why not ranges?** MVS makes ranges unnecessary. The version in `astra.toml` is the minimum; MVS picks the exact version. No ambiguity.

---

## 4. Package Format

### 4.1 Source Packages (Rust, Go, Zig)

**How it works:** Packages are distributed as source code. The consumer compiles from source.

**Pros:**
- Universal (no platform-specific binaries needed)
- Cross-compilation works naturally
- Smaller download size
- Source audit possible

**Cons:**
- Slower installation (compilation required)
- Build dependencies needed on consumer machine

### 4.2 Binary Packages (Conda, some npm)

**How it works:** Pre-compiled binaries for specific platforms are distributed.

**Pros:**
- Fast installation (no compilation)
- No build tools needed on consumer machine

**Cons:**
- Must build for every target platform
- Larger download size
- Cannot cross-compile
- Binary reproducibility concerns

### 4.3 Both (Cargo, Zig)

**How it works:** Source packages by default, with optional binary packages for specific platforms.

**Pros:**
- Flexibility
- Cross-compilation via source
- Fast install via binaries when available

**Cons:**
- More complex to maintain
- Binary availability varies

### 4.4 Content-Addressed (Zig)

**How it works:** Packages are identified by their content hash, not by URL or version. The hash is the identity; URLs are just delivery mechanisms.

**Pros:**
- Immutable by design
- URL-independent (can mirror anywhere)
- Tamper-evident
- No registry trust needed for integrity

**Cons:**
- Hash must be known upfront
- Less human-friendly discovery

### 4.5 Recommendation for Astra

**Source packages with content-addressed storage:**
1. **Default: Source packages** — consumers compile from source (like Go, Zig)
2. **Content-addressed** — package identity is the hash of the source archive (like Zig)
3. **Optional binary cache** — pre-built packages for fast CI/CD (like Zig's cache)
4. **Cross-compilation native** — source packages work for any target

**Package archive format:**
```
mypackage-1.0.0.tar.gz
├── astra.toml          # Package manifest
├── src/                # Source code
│   ├── main.astra
│   └── lib.astra
├── tests/              # Optional test files
├── LICENSE
└── README.md
```

**Why source packages?**
- Astra has cross-compilation as a first-class feature
- Source packages enable cross-compilation naturally
- Binary packages would require building for every target
- Content-addressing provides integrity without a central authority

---

## 5. Cross-Compilation Support

### 5.1 Current Approaches

| Language | Approach | Mechanism |
|----------|----------|-----------|
| **Rust** | Target triples + conditional compilation | `#[cfg(target_os = "linux")]`, `build.rs` |
| **Go** | Environment variables | `GOOS=linux GOARCH=arm64 go build` |
| **Zig** | First-class cross-compilation | `zig build -target=aarch64-linux-musl` |
| **C/C++** | Separate toolchains | `aarch64-linux-gnu-gcc` |

### 5.2 Platform-Specific Dependencies

**The problem:** Some packages only work on certain platforms (e.g., Windows API wrappers, Linux-specific system libraries).

**Solutions:**

| Solution | Used By | Description |
|----------|---------|-------------|
| **Conditional dependencies** | Cargo | `[target.'cfg(windows)'.dependencies]` |
| **Platform-specific features** | npm | OS-optional dependencies |
| **Build-time selection** | Zig | Comptime platform dispatch |
| **Separate packages** | Go | Different import paths per platform |

### 5.3 Recommendation for Astra

**Platform-specific dependencies in `astra.toml`:**
```toml
[package]
name = "my-app"
version = "1.0.0"

[dependencies]
http = "^1.0"                    # Cross-platform
json = "^2.0"                    # Cross-platform

[target.'cfg(os = "linux")'.dependencies]
io_uring = "^0.5"               # Linux-only

[target.'cfg(os = "windows")'.dependencies]
winapi = "^0.3"                 # Windows-only

[target.'cfg(os = "macos")'.dependencies]
core_foundation = "^1.0"        # macOS-only
```

**Build-time platform dispatch:**
```astra
# Automatic compile-time selection
import io_uring  # Only available on Linux

pub fn setup_io() -> Void {
    switch (builtin.os) {
        .linux => io_uring.setup(),
        .macos => kqueue.setup(),
        .windows => iocp.setup(),
    }
}
```

**Cross-compilation workflow:**
```bash
# Build for specific target
astra build --target=aarch64-unknown-linux-musl

# Build for all supported targets
astra build --target=all

# The package manager resolves platform-specific deps automatically
astra pkg install  # Only downloads deps needed for current target
```

---

## 6. Private Registries

### 6.1 Current Approaches

| Registry | Authentication | Scoping | Mirroring |
|----------|---------------|---------|-----------|
| **npm** | Bearer tokens | `@scope/package` | Proxy support |
| **Cargo** | API tokens | Registry config | Sparse index |
| **Go** | Git credentials | Module paths | GOPROXY |
| **Artifactory** | API keys + tokens | Virtual repos | Full mirroring |

### 6.2 Authentication Methods

1. **Bearer tokens** (npm, Cargo) — Token-based, can be scoped
2. **API keys** (Artifactory) — Long-lived, per-user
3. **SSH keys** (Git-based) — For Git dependencies
4. **OAuth/OIDC** (GitHub Packages) — Federated authentication
5. **mTLS** (enterprise) — Certificate-based mutual TLS

### 6.3 Recommendation for Astra

**Registry configuration in `~/.astra/config.toml`:**
```toml
[registries]
# Public registry (default)
default = "https://pkg.astralang.dev"

# Private corporate registry
corporate = { url = "https://packages.mycompany.com/astra", token = "${ASTRA_TOKEN}" }

# Local cache/mirror
mirror = "https://cache.mycompany.com/astra"
```

**Per-project override in `astra.toml`:**
```toml
[package]
name = "internal-tool"
version = "1.0.0"
registry = "corporate"

[dependencies]
internal-lib = { version = "^2.0", registry = "corporate" }
public-lib = "^1.0"  # Uses default registry
```

**Authentication flow:**
```bash
# Login to registry
astra pkg login corporate
# Opens browser for OAuth or prompts for token

# Or set token directly
astra pkg login corporate --token $ASTRA_TOKEN

# Publish to private registry
astra pkg publish --registry corporate
```

**Mirroring support:**
```bash
# Mirror public registry locally
astra pkg mirror https://pkg.astralang.dev --local ./mirror

# Use mirror in CI/CD
ASTRA_REGISTRIES=default=https://cache.mycompany.com/astra astra pkg install
```

---

## 7. Build System Integration

### 7.1 Current Approaches

| Language | Manifest | Build Script | Integration |
|----------|----------|-------------|-------------|
| **Rust** | `Cargo.toml` | `build.rs` | Cargo IS the build system |
| **Go** | `go.mod` | `//go:generate` | go command IS the build system |
| **Zig** | `build.zig.zon` | `build.zig` | Build script IS the package manifest |
| **npm** | `package.json` | `scripts` | Separate build tools |

### 7.2 Build Scripts

| Language | Purpose | Sandboxed? |
|----------|---------|-----------|
| **Cargo** | `build.rs` — compile-time code generation, system library detection | No (full filesystem access) |
| **Zig** | `build.zig` — build graph definition | No (full access) |
| **npm** | `preinstall`, `postinstall` — arbitrary scripts | No |

### 7.3 Recommendation for Astra

**Manifest file: `astra.toml`**
```toml
[package]
name = "my-library"
version = "1.0.0"
description = "A useful library"
license = "MIT"
authors = ["Developer <dev@example.com>"]

[dependencies]
http = "^1.0"
json = "^2.0"

[dev-dependencies]
testing = "^1.0"

[build-dependencies]
codegen = "^0.5"  # Only available during build

[ffi]
headers = ["include/"]
link = ["z", "ssl"]

[platform.linux]
link = ["pthread"]

[platform.windows]
link = ["ws2_32"]
```

**Build script: `build.astra`**
```astra
# Runs during `astra build` — can generate code, detect system libs
import astra.build as build

fn configure(ctx: BuildContext) -> Void {
    # Detect system libraries
    if ctx.has_system_lib("openssl") {
        ctx.link("ssl")
    } else {
        # Use bundled version
        ctx.dependency("bundled-openssl")
    }

    # Generate code
    ctx.generate("src/generated.astra", || {
        # Code generation logic
    })
}
```

**Integration with build system:**
- `astra build` reads `astra.toml`, resolves dependencies, runs build scripts, compiles
- `astra run` interprets/runs the project
- `astra test` runs tests defined in the project
- `astra pkg` manages dependencies separately from build

---

## 8. Workspace/Monorepo Support

### 8.1 Current Approaches

| Language | Approach | Mechanism |
|----------|----------|-----------|
| **Cargo** | Workspaces | `[workspace]` in root `Cargo.toml` |
| **Go** | Go workspaces | `go.work` file |
| **npm** | Workspaces | `workspaces` field in `package.json` |
| **Zig** | Path dependencies | `build.zig.zon` with `.path` deps |

### 8.2 Cargo Workspaces

```toml
# Root Cargo.toml
[workspace]
members = ["crates/*", "apps/*"]
resolver = "2"

[workspace.dependencies]
serde = { version = "1.0", features = ["derive"] }
tokio = { version = "1.0", features = ["full"] }
```

```toml
# crates/my-lib/Cargo.toml
[dependencies]
serde.workspace = true  # Inherit from workspace
tokio.workspace = true
```

### 8.3 Go Workspaces

```go
// go.work
go 1.22

use (
    ./mylib
    ./myapp
    ./tools
)
```

### 8.4 Recommendation for Astra

**Workspace manifest: `astra.work.toml`**
```toml
[workspace]
members = ["packages/*", "apps/*"]

# Shared dependencies (inherited by members)
[workspace.dependencies]
http = "^1.0"
json = "^2.0"
testing = "^1.0"

# Shared build settings
[workspace.build]
target = "x86_64-unknown-linux-musl"
optimize = "release"
```

**Member package: `packages/my-lib/astra.toml`**
```toml
[package]
name = "my-lib"
version = "1.0.0"

[dependencies]
http = { workspace = true }  # Inherit from workspace
json.workspace = true        # Shorthand
```

**Commands:**
```bash
# Build all workspace members
astra build --workspace

# Build specific member
astra build --package my-lib

# Run all tests
astra test --workspace

# Add dependency to all members
astra pkg add serde --workspace
```

---

## 9. Dependency Security

### 9.1 Threat Landscape

**Recent attacks (2025):**
- **Shai-Hulud worm** (npm): Self-replicating malware that compromised 500+ packages, stealing credentials and propagating via compromised maintainer tokens
- **chalk/debug compromise** (npm): Popular packages with billions of weekly downloads injected with cryptocurrency-stealing malware
- **Dependency confusion**: Attacker publishes public package with same name as internal private package

### 9.2 Security Mechanisms

| Mechanism | Description | Used By |
|-----------|-------------|---------|
| **Integrity hashes** | SHA-256/SHA-512 of package contents | All major PMs |
| **Lockfiles** | Pin exact versions and hashes | All major PMs |
| **Yanking** | Mark versions as unsafe without deletion | Cargo, npm |
| **Vulnerability scanning** | Check against known CVE databases | npm audit, cargo audit |
| **License auditing** | Ensure compatible licenses | cargo-deny, license-checker |
| **Signed packages** | Cryptographic signatures | Go (sum database), Sigstore |
| **Supply chain transparency** | SBOM generation, provenance | SLSA, in-toto |
| **Content addressing** | Hash = identity, tamper-evident | Zig, Go modules |

### 9.3 Recommendation for Astra

**Layer 1: Content-Addressed Storage**
- Package identity = SHA-256 hash of source archive
- Registry cannot serve different content for same hash
- Mirrors are trustless (hash verification on download)

**Layer 2: Lockfile with Integrity**
```toml
# astra.lock
[[package]]
name = "http"
version = "1.2.3"
hash = "sha256:abc123..."
registry = "https://pkg.astralang.dev"

[[package]]
name = "json"
version = "2.1.0"
hash = "sha256:def456..."
source = "git+https://github.com/user/json.git@abc123"
```

**Layer 3: Vulnerability Scanning**
```bash
# Check for known vulnerabilities
astra pkg audit

# Output:
# Checking 45 dependencies against advisory database...
# Found 2 vulnerabilities:
#   CRITICAL: http@1.0.0 - RCE in HTTP parser (ASTRA-2025-001)
#   HIGH: json@1.5.0 - Prototype pollution (ASTRA-2025-002)
#
# Run `astra pkg audit --fix` to update to safe versions.
```

**Layer 4: License Compliance**
```bash
# Check licenses
astra pkg licenses

# Output:
# Package         License    Category
# http            MIT        Permissive
# json            Apache-2.0 Permissive
# native-dep      GPL-3.0    Copyleft ⚠️
#
# Warning: GPL-3.0 dependency detected. Ensure compatibility.
```

**Layer 5: Supply Chain Transparency**
```bash
# Generate SBOM
astra pkg sbom --format spdx-json > sbom.json

# Verify package provenance
astra pkg verify http@1.2.3
# Package http@1.2.3:
#   Signed by: developer@example.com
#   Built at: 2025-01-15T10:30:00Z
#   Source: https://github.com/astralang/http
#   Signature: valid (GPG key ABC123)
```

**Anti-confusion measures:**
1. **Scoped packages by default** for private registries
2. **Name reservation** — claim names in public registry before internal use
3. **Registry priority** — private registry always checked before public
4. **Dependency lock verification** — hash mismatch = error, not warning

---

## 10. CLI Design

### 10.1 Command Structure

```
astra pkg <command> [options]

Commands:
  init                  Initialize a new package
  install (i)          Install dependencies
  add                  Add a dependency
  remove (rm)          Remove a dependency
  update               Update dependencies
  upgrade              Upgrade to latest compatible versions
  search               Search packages in registry
  info                 Show package information
  publish              Publish package to registry
  yank                 Mark version as unsafe
  audit                Check for security vulnerabilities
  licenses             Check dependency licenses
  sbom                 Generate Software Bill of Materials
  tree                 Show dependency tree
  cache                Manage package cache
  login                Authenticate with registry
  logout               Logout from registry
  mirror               Mirror registry locally

Options:
  --registry <url>     Use specific registry
  --target <triple>    Cross-compile for target
  --offline            Use only cached packages
  --locked             Fail if lockfile would change
  --dry-run            Show what would be done
  --verbose            Enable verbose output
```

### 10.2 Command Details

#### `astra pkg init`
```bash
# Interactive initialization
astra pkg init
# Name: my-package
# Version: 0.1.0
# Description: My awesome package
# License: MIT

# Non-interactive
astra pkg init --name my-package --version 0.1.0
```

**Creates:**
```
my-package/
├── astra.toml
├── src/
│   └── main.astra
├── tests/
│   └── main_test.astra
├── LICENSE
└── README.md
```

#### `astra pkg add`
```bash
# Add from public registry
astra pkg add http
astra pkg add http@^1.0
astra pkg add http@">=1.0 <2.0"

# Add from specific registry
astra pkg add internal-lib --registry corporate

# Add from Git
astra pkg add git+https://github.com/user/repo.git

# Add from local path
astra pkg add ../my-local-lib

# Add as dev dependency
astra pkg add testing --dev

# Add as build dependency
astra pkg add codegen --build
```

#### `astra pkg install`
```bash
# Install all dependencies
astra pkg install

# Install with specific target
astra pkg install --target=aarch64-unknown-linux-musl

# Install from lockfile (CI mode)
astra pkg install --locked

# Install offline (no network)
astra pkg install --offline

# Install with audit
astra pkg install --audit
```

#### `astra pkg search`
```bash
# Search by name/description
astra pkg search http
astra pkg search "web framework"

# Filter by category
astra pkg search --category networking

# Sort by downloads
astra pkg search http --sort downloads

# Show only verified packages
astra pkg search http --verified
```

#### `astra pkg publish`
```bash
# Publish to default registry
astra pkg publish

# Publish to specific registry
astra pkg publish --registry corporate

# Dry run (validate without publishing)
astra pkg publish --dry-run

# Publish with signature
astra pkg publish --sign --key ~/.astra/keys/package.key
```

#### `astra pkg audit`
```bash
# Check for vulnerabilities
astra pkg audit

# Auto-fix vulnerabilities
astra pkg audit --fix

# Output as JSON (for CI)
astra pkg audit --format json

# Include advisories database update
astra pkg audit --update-db
```

#### `astra pkg tree`
```bash
# Show dependency tree
astra pkg tree

# Output:
# my-package@0.1.0
# ├── http@1.2.3
# │   ├── tls@0.5.1
# │   └── async-io@1.3.0
# ├── json@2.1.0
# └── logging@0.3.0

# Show only direct dependencies
astra pkg tree --depth 1

# Show platform-specific deps
astra pkg tree --target=linux
```

---

## 11. Registry Protocol

### 11.1 API Design

**Base URL:** `https://pkg.astralang.dev/v1`

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/packages/{name}` | Get package metadata |
| `GET` | `/packages/{name}/versions` | List all versions |
| `GET` | `/packages/{name}/{version}` | Get specific version metadata |
| `GET` | `/packages/{name}/{version}/download` | Download source archive |
| `PUT` | `/packages/{name}/{version}` | Publish new version |
| `DELETE` | `/packages/{name}/{version}/yank` | Yank a version |
| `PUT` | `/packages/{name}/{version}/unyank` | Unyank a version |
| `GET` | `/packages?q={query}` | Search packages |
| `GET` | `/audit/{name}/{version}` | Get vulnerability info |

### 11.2 Package Metadata Response

```json
{
  "name": "http",
  "description": "HTTP client library for Astra",
  "versions": {
    "1.2.3": {
      "version": "1.2.3",
      "hash": "sha256:abc123...",
      "dependencies": {
        "tls": "^0.5.0",
        "async-io": "^1.0.0"
      },
      "targets": ["x86_64-unknown-linux-musl", "aarch64-apple-darwin"],
      "published_at": "2025-01-15T10:30:00Z",
      "published_by": "developer@example.com",
      "license": "MIT",
      "size_bytes": 24576
    }
  },
  "dist-tags": {
    "latest": "1.2.3",
    "beta": "2.0.0-beta.1"
  }
}
```

### 11.3 Publish Protocol

```
Client                          Registry
  |                                |
  |  PUT /packages/http/1.2.3      |
  |  Content-Type: application/gzip|
  |  Authorization: Bearer <token> |
  |  Body: <source archive>        |
  |  ----------------------------> |
  |                                |
  |  201 Created                   |
  |  Location: /packages/http/1.2.3|
  |  <---------------------------- |
  |                                |
  |  GET /packages/http (verify)   |
  |  ----------------------------> |
  |                                |
  |  200 OK (version listed)       |
  | <----------------------------  |
```

### 11.4 Batch Resolution (npm v2 inspired)

```json
// POST /v1/resolve
// Body:
{
  "packages": [
    {"name": "http", "version": "^1.0"},
    {"name": "json", "version": "^2.0"}
  ]
}

// Response:
{
  "resolved": {
    "http": {"version": "1.2.3", "hash": "sha256:abc...", "url": "..."},
    "json": {"version": "2.1.0", "hash": "sha256:def...", "url": "..."}
  },
  "integrity": {
    "http": "sha256:abc...",
    "json": "sha256:def..."
  }
}
```

---

## 12. Astra-Specific Design Decisions

### 12.1 Cross-Compilation Native

Unlike other package managers that bolt on cross-compilation support, Astra's package manager is designed from the ground up for it:

1. **Source packages only** — no binary packages to maintain per-platform
2. **Platform-specific dependencies** — `cfg(os = "linux")` in `astra.toml`
3. **Build-time target selection** — `astra build --target=<triple>` resolves correct deps
4. **Content-addressed** — same package works for any target

### 12.2 Deterministic Resolution

MVS provides determinism without lock files for libraries:
- Library crates: `astra.toml` defines minimum versions, MVS selects exact versions
- Binary crates: `astra.lock` pins exact versions for reproducible builds
- No "it works on my machine" problems

### 12.3 Unified Toolchain

```
astra run          # Interpret (dev mode)
astra build        # Compile (production)
astra test         # Run tests
astra fmt          # Format code
astra pkg          # Package management
astra repl         # Interactive REPL
astra kernel       # Jupyter kernel
```

All in a single ~20MB binary. No external dependencies.

### 12.4 Security by Default

1. **Content addressing** — hash = identity, tamper-evident
2. **Lockfile verification** — hash mismatch = hard error
3. **Scoped packages** — prevent name confusion attacks
4. **Built-in audit** — vulnerability scanning out of the box
5. **No `postinstall` scripts by default** — must explicitly enable

---

## 13. Implementation Roadmap

### Phase 1: Core (Months 1-3)
- [ ] Package manifest format (`astra.toml`)
- [ ] MVS dependency resolver
- [ ] Content-addressed package storage
- [ ] Basic CLI (init, add, install, remove)
- [ ] Local path dependencies

### Phase 2: Registry (Months 4-6)
- [ ] Public registry API
- [ ] Package publishing
- [ ] Git dependencies
- [ ] Lockfile generation and verification
- [ ] Search and discovery

### Phase 3: Advanced (Months 7-9)
- [ ] Workspaces/monorepo support
- [ ] Private registries
- [ ] Platform-specific dependencies
- [ ] Build script integration
- [ ] Vulnerability scanning

### Phase 4: Enterprise (Months 10-12)
- [ ] License auditing
- [ ] SBOM generation
- [ ] Mirroring support
- [ ] OIDC/SAML authentication
- [ ] Audit logging

---

## 14. Comparison Matrix

| Feature | Cargo | Go modules | Zig | npm | **Astra (proposed)** |
|---------|-------|------------|-----|-----|---------------------|
| Resolution | PubGrub | MVS | Hash-based | Arborist | **MVS + PubGrub** |
| Lockfile | Yes | No (go.sum) | No | Yes | **Binary only** |
| Cross-compilation | cfg attrs | GOOS/GOARCH | First-class | Limited | **First-class** |
| Package format | Source | Source | Source | Binary+Source | **Source** |
| Registry | Centralized | Decentralized | URL+Hash | Centralized | **Hybrid** |
| Private repos | Git deps | Native | Path deps | Scoped pkgs | **Native** |
| Security audit | cargo-audit | govulncheck | None | npm audit | **Built-in** |
| Workspaces | Yes | go.work | Path deps | Yes | **Yes** |
| Binary cache | No | No | Yes | No | **Optional** |
| Content addressing | No | Partial | Yes | No | **Yes** |

---

## 15. Conclusion

Astra's package manager should be designed as a **cross-compilation-native, content-addressed, MVS-based package manager** that prioritizes:

1. **Determinism** — MVS provides reproducible builds without lock files for libraries
2. **Cross-compilation** — Source packages + platform-specific dependencies
3. **Security** — Content addressing, built-in audit, scoped packages
4. **Simplicity** — Single binary, minimal configuration, predictable behavior
5. **Enterprise support** — Private registries, mirroring, license compliance

The design draws the best ideas from:
- **Go modules** — MVS for deterministic resolution
- **Cargo** — Centralized registry + build scripts + workspaces
- **Zig** — Content addressing + first-class cross-compilation
- **npm v2** — Batch resolution for performance

This approach avoids the pitfalls of other ecosystems:
- No npm's non-deterministic hoisting
- No Rust's complex feature unification
- No Go's inability to use ranges (Astra supports caret ranges with MVS)
- No Zig's lack of a public registry

The result is a package manager that is **fast, secure, predictable, and cross-compilation-native** — exactly what Astra needs to succeed.
