# Compile-Time Metaprogramming (`comptime`) for Astra

## Comprehensive Research Report

---

## 1. Zig-Style Comptime Evaluation

Zig's `comptime` is the most radical simplification of compile-time metaprogramming in modern language design. It replaces macros, generics, and template metaprogramming with a single, unified mechanism: **ordinary code that runs at compile time**.

### 1.1 Core Mechanism

Zig's comptime operates on one principle: **types are first-class values at compile time**. Any function that receives compile-time-known arguments can be evaluated by the compiler at compile time, producing a result that is either baked into the binary or used to specialize further compilation.

```zig
// comptime parameter: this function becomes a "type function"
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

// Called at compile time with concrete types — produces specialized code
const result = max(i32, 10, 20);    // compiler inlines: max_i32(10, 20)
const result2 = max(f64, 1.5, 2.5); // compiler inlines: max_f64(1.5, 2.5)
```

### 1.2 Comptime Blocks

Blocks of code can be forcibly executed at compile time:

```zig
// Comptime block — evaluated during compilation
const greeting = comptime blk: {
    var msg: [5]u8 = "hello".*;
    for (&msg) |*c| {
        c.* = std.ascii.toUpper(c.*);
    }
    break :blk msg;
};
// greeting is "HELLO", embedded as a compile-time constant
```

### 1.3 Comptime Variables and Loops

```zig
// comptime var: mutable state during compilation
comptime var lookup_table: [256]u32 = undefined;
comptime {
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        lookup_table[i] = i * i;
    }
}
// lookup_table is fully computed at compile time, zero runtime cost
```

### 1.4 Compile-Time Reflection

Zig provides `@typeInfo` to inspect types at compile time:

```zig
fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn printStructFields(comptime T: type) void {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            for (s.fields) |field| {
                std.debug.print("{s}: {s}\n", .{
                    field.name, @typeName(field.type)
                });
            }
        },
        else => @compileError("not a struct"),
    }
}
```

### 1.5 Key Insight: No Separate Macro Language

Zig has **no macros, no templates, no preprocessor**. The same language you write runtime code in is the language you write compile-time code in. The compiler is simultaneously an interpreter for comptime code and a code generator for runtime code.

### 1.6 Restrictions

What **cannot** be done at comptime in Zig:
- No inline assembly (`asm`)
- No calls to external C functions (comptime runs inside the compiler, not in a separate process)
- No heap allocation (comptime values live on the compiler's internal arena)
- Evaluation budget: capped at 1000 backward branches by default (`@setEvalBranchQuota` to override)
- No runtime-only operations (file I/O, network, etc.)

---

## 2. Nim's Macros and Templates

Nim takes a fundamentally different approach: **AST manipulation as a first-class citizen**. Templates and macros are distinct constructs that operate on the compiler's internal Abstract Syntax Tree.

### 2.1 Templates (Hygienic Inline Expansion)

Templates are compile-time AST substitutions — essentially smart text replacement that respects scoping:

```nim
template `!=`*(a, b: untyped): bool =
  not (a == b)

template newDebugStream(name: string): Stream =
  var s = newFileStream(name, fmWrite)
  if s.isNil:
    echo "Could not open: ", name
  s
```

Templates are **inlined** at the call site. They don't create new scopes — variables inside a template refer to the caller's scope. This is powerful but requires care.

### 2.2 Macros (AST Transformations)

Macros receive the AST as `NimNode` values and return a new AST:

```nim
import std/macros

macro repeat(n: static[int], body: untyped): untyped =
  result = newStmtList()
  for i in 0..<n:
    result.add(body)

repeat(3):
  echo "Hello"
# Expands to:
# echo "Hello"
# echo "Hello"
# echo "Hello"
```

### 2.3 AST Node Types

Nim's AST is a tree of `NimNode` objects, each with a kind:

```nim
# Key node kinds:
# nnkProcDef    - function definition
# nnkCall        - function call
# nnkIdent       - identifier
# nnkStrLit      - string literal
# nnkIntLit      - integer literal
# nnkBracketExpr - array indexing (a[i])
# nnkDotExpr     - dot access (a.b)
# nnkIfExpr      - conditional expression
# nnkStmtList    - statement list
```

### 2.4 The Quote DSL

Nim provides a `quote do:` template for constructing ASTs naturally:

```nim
macro makeGetter(fieldName: static[string]): untyped =
  let procName = ident("get" & fieldName)
  let fieldAccess = nnkDotExpr.new(ident("self"), ident(fieldName))
  quote do:
    proc `procName`(self: MyType): auto =
      `fieldAccess`
```

### 2.5 Hygiene

Nim macros are **hygienic** — identifiers introduced by a macro do not conflict with identifiers at the call site. The compiler maintains separate symbol tables for macro-generated code vs. user code.

### 2.6 Limitations

- Nim macros are complex to write and debug — you are manipulating raw AST nodes
- The AST representation changes between Nim versions (breaking macro libraries)
- Compile-time execution is restricted (no file I/O, limited standard library)
- Error messages from macros can be opaque

---

## 3. Rust Procedural Macros

Rust has the most elaborate macro system in modern languages, with four distinct categories. This power comes at a steep learning curve.

### 3.1 Declarative Macros (`macro_rules!`)

Pattern-matching macros that expand at the syntax level:

```rust
macro_rules! vec {
    ( $( $x:expr ),* $(,)? ) => {
        {
            let mut temp_vec = Vec::new();
            $(
                temp_vec.push($x);
            )*
            temp_vec
        }
    };
}

let v = vec![1, 2, 3, 4];  // expands to push calls
```

### 3.2 Derive Macros (`#[derive(...)]`)

Automatically implement traits for structs and enums:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Point {
    x: f64,
    y: f64,
}

// The derive macro generates:
// impl fmt::Debug for Point { ... }
// impl Clone for Point { ... }
// impl Serialize for Point { ... }
// impl Deserialize for Point { ... }
```

Internally, a derive macro receives a `TokenStream` and returns a `TokenStream`:

```rust
use proc_macro::TokenStream;
use quote::quote;
use syn;

#[proc_macro_derive(HelloMacro)]
pub fn hello_macro_derive(input: TokenStream) -> TokenStream {
    let ast = syn::parse(input).unwrap();
    impl_hello_macro(&ast)
}

fn impl_hello_macro(ast: &syn::DeriveInput) -> TokenStream {
    let name = &ast.ident;
    let gen = quote! {
        impl HelloMacro for #name {
            fn hello_macro() {
                println!("Hello, Macro! My name is {}!", stringify!(#name));
            }
        }
    };
    gen.into()
}
```

### 3.3 Attribute Macros

Transform any item with a custom attribute:

```rust
#[route(GET, "/users")]
fn list_users() -> Vec<User> { ... }

// The macro receives the entire function definition as tokens
// and can transform it into something completely different
```

### 3.4 Function-Like Macros

Custom syntax that looks like function calls:

```rust
sql!(SELECT * FROM users WHERE id = 1);
// Macro receives the token stream and generates type-safe query code
```

### 3.5 Ecosystem Dependencies

Rust proc macros require:
- `proc-macro` crate (compiler-provided)
- `syn` — parsing Rust syntax into AST
- `quote` — quasi-quoting for code generation
- A separate crate of type `proc-macro = true`

### 3.6 Hygiene

Rust macros operate on `TokenStream`, not AST. The compiler performs hygiene checks after expansion. Macro-generated code follows Rust's normal scoping rules, but the `Span` of each token tracks its origin for error reporting.

---

## 4. Other Approaches

### 4.1 C++ `constexpr` and `consteval`

C++ has progressively expanded compile-time evaluation since C++11:

```cpp
// C++11: constexpr functions (must be single-return)
constexpr int factorial(int n) {
    return n <= 1 ? 1 : n * factorial(n - 1);
}

// C++14: relaxed constexpr (loops, local variables allowed)
constexpr int fibonacci(int n) {
    if (n <= 1) return n;
    int a = 0, b = 1;
    for (int i = 2; i <= n; ++i) {
        int tmp = a + b;
        a = b;
        b = tmp;
    }
    return b;
}

// C++20: consteval (MUST be evaluated at compile time)
consteval int compile_time_only(int x) {
    return x * x;
}

// C++20: if consteval (branch on compile-time vs runtime context)
constexpr int adapt(int x) {
    if consteval {
        return x * 2;  // compile-time path
    } else {
        return x + 1;  // runtime path
    }
}
```

**Key distinction from Zig:** C++ `constexpr` is a *hint* — the compiler *may* evaluate at compile time. C++ `consteval` forces it. Zig's `comptime` is always compile-time, with runtime evaluation being the explicit fallback.

### 4.2 D's CTFE and Mixins

D combines two powerful mechanisms:

**CTFE (Compile-Time Function Execution):**
```d
// Any function can potentially be evaluated at compile time
uint factorial(uint n) {
    if (n == 0) return 1;
    return n * factorial(n - 1);
}

enum x = factorial(4);  // computed at compile time, result is 24
static val = sqrt(50);  // also computed at compile time
```

**String Mixins:**
```d
// Generate code as a string, then compile it as D code
string genStruct(string name, string field) {
    return "struct " ~ name ~ " { int " ~ field ~ "; }";
}

mixin(genStruct("Foo", "bar"));
// Compiles as: struct Foo { int bar; }
```

**CTFE + String Mixins together:**
```d
string_REPEAT(string s, int n) {
    string result;
    foreach (i; 0..n) result ~= s;
    return result;
}

mixin(REPEAT("echo(\"hi\");", 3));
// Inserts 3 echo statements
```

D's approach is powerful but unsafe: string mixins inject arbitrary code and are hard to debug.

### 4.3 Swift's Result Builders and Property Wrappers

**Result Builders** transform function body syntax into a declarative DSL:

```swift
@resultBuilder
struct ArrayBuilder {
    static func buildBlock(_ components: Int...) -> [Int] {
        components
    }
}

func makeArray(@ArrayBuilder content: () -> [Int]) -> [Int] {
    content()
}

let arr = makeArray {
    1
    2
    3
}
// arr == [1, 2, 3]
```

**Property Wrappers** add computed behavior around stored properties:

```swift
@propertyWrapper
struct Clamped {
    var value: Int
    let range: ClosedRange<Int>
    
    var wrappedValue: Int {
        get { value }
        set { value = min(max(range.lowerBound, newValue), range.upperBound) }
    }
    
    init(wrappedValue: Int, _ range: ClosedRange<Int>) {
        self.range = range
        self.value = min(max(range.lowerBound, wrappedValue), range.upperBound)
    }
}

struct Player {
    @Clamped(0...100) var health: Int = 100
}

var player = Player()
player.health = 150  // clamped to 100
player.health = -20  // clamped to 0
```

**Swift Macros** (Swift 5.9+): Full AST manipulation via SwiftSyntax, similar to Nim's approach but with explicit macro roles:

```swift
@attached(member)
@attached(conformance)
macro OptionSet() = #externalMacro(module: "SwiftMacros", type: "OptionSetMacro")
```

---

## 5. Use Cases for Comptime

### 5.1 Serialization Code Generation (JSON, Protobuf)

The most common use case. Define a struct, get `serialize()`/`deserialize()` for free:

```zig
// Zig approach (using comptime reflection)
const User = struct {
    name: []const u8,
    age: u32,
    email: []const u8,
};

fn serialize(comptime T: type, value: T) []const u8 {
    const info = @typeInfo(T);
    // Use comptime reflection to iterate fields
    // Generate serialization code for each field
    // Return JSON string
}

// The compiler evaluates serialize(User, my_user) at compile time
// if my_user is comptime-known, or monomorphizes for runtime
```

```rust
// Rust approach (derive macro)
#[derive(Serialize, Deserialize)]
struct User {
    name: String,
    age: u32,
    email: String,
}
// proc macro generates the Serialize/Deserialize implementations
```

**For Astra:** A derive-like mechanism using comptime reflection would cover this without a separate macro system.

### 5.2 Unit Type Verification (Dimensional Analysis)

Already part of Astra's design. Comptime enables zero-cost dimensional checks:

```zig
// Zig-style for Astra's units
fn compute_velocity(dist: Meter, time: Second) -> Velocity {
    return dist / time
}

// The compiler:
// 1. At comptime, computes the dimension vector: [1,0,0...] - [0,0,1...] = [1,0,-1...]
// 2. Verifies the return type matches the computed dimension
// 3. Erases the dimension info in the final binary (zero runtime cost)
```

### 5.3 Domain-Specific Languages (DSLs)

Comptime enables embedded DSLs without a separate parser:

```zig
// Comptime SQL-like DSL
const query = comptime buildQuery(
    "SELECT * FROM users WHERE age > ? AND name LIKE ?",
    .{ age_threshold, name_pattern }
);
// Validates the query at compile time, generates optimized code
```

### 5.4 Validation of Format Strings, SQL Queries

Zig's `std.debug.print` validates format strings at compile time because the format string is a comptime parameter:

```zig
std.debug.print("{d}\n", .{42});      // OK
std.debug.print("{d}\n", .{"hello"});  // COMPILE ERROR — {d} can't format a string
```

### 5.5 Generic Specialization

Write one generic function, get optimized versions for specific types:

```zig
fn sort(comptime T: type, items: []T) void {
    // Generic sort works for any type with a defined <
    // At comptime, the compiler can generate specialized versions
    // for i32, f64, custom structs, etc.
}
```

---

## 6. Recommendation for Astra

### 6.1 Design Goals Recap

From ARCHITECTURE.md:
- **Simplicity:** Clean syntax, readable, immutable by default
- **Fast dev compilation:** <10ms startup, <100MB RAM
- **Dual backend:** VM for dev, LLVM for production
- **No complex macro system** (explicitly listed as a goal)

### 6.2 Why Zig-Style Comptime Fits Astra

| Criterion | Zig Comptime | Rust Proc Macros | Nim Macros | C++ constexpr |
|-----------|-------------|------------------|------------|---------------|
| **Learning curve** | Low | High | High | Medium |
| **Separate macro language** | No | Yes (Rust in Rust) | Yes (Nim in Nim) | No |
| **Compile-time impact** | Bounded | Unbounded | Unbounded | Bounded |
| **Debuggability** | Good (same language) | Poor (token streams) | Poor (AST nodes) | Good |
| **VM compatibility** | High | Low | Medium | Medium |
| **Power ceiling** | High | Very High | Very High | Low-Medium |

**Zig's comptime is the best fit** because:

1. **No separate language:** Astra developers use Astra to write comptime code. No need to learn proc_macro, syn, quote.
2. **Fast compilation:** The interpreter in the type checker can evaluate comptime code without LLVM. Perfect for the VM backend.
3. **Bounded compile time:** Branch quotas and restrictions prevent comptime from slowing compilation.
4. **Natural for Astra's type system:** The existing Hindley-Milner inference + dimensional analysis naturally extends to comptime type computation.
5. **Dual backend friendly:** Comptime is evaluated before backend selection, so it works identically in VM and LLVM modes.

### 6.3 Concrete Proposal: Astra Comptime

#### Syntax: Comptime Parameters

```astra
# Type parameters via comptime
fn max(comptime T: type, a: T, b: T) -> T:
    return if a > b: a else: b

# Value parameters via comptime
fn repeat(comptime n: Int, value: String) -> [n]String:
    return [value] * n

# Usage:
val x = max(Int, 10, 20)          # x: Int = 20
val names = repeat(3, "hello")    # names: [3]String = ["hello", "hello", "hello"]
```

#### Syntax: Comptime Blocks

```astra
# Block evaluated at compile time
val greeting = comptime:
    var msg = "hello"
    msg = msg.to_upper()
    msg
# greeting: String = "HELLO" (embedded in binary)
```

#### Syntax: Comptime Reflection

```astra
fn type_name(comptime T: type) -> String:
    return @type_name(T)  # Built-in reflection

fn field_count(comptime T: type) -> Int:
    return @field_count(T)

# Usage at compile time:
comptime:
    assert(type_name(Int) == "Int")
    assert(field_count(User) == 3)
```

#### Syntax: Comptime Type Functions

```astra
# Generate a struct at compile time
fn Pair(comptime T: type, comptime U: type) -> type:
    return struct:
        first: T
        second: U

# Pair(Int, String) is a concrete struct type
val p = Pair(Int, String)(first: 42, second: "hello")

# Conditional compilation
fn debug_only(comptime T: type, value: T) -> T:
    if @build_mode() == .debug:
        @print("Value: {value}")
    return value
```

#### Syntax: Comptime Loops

```astra
# Unroll loops at compile time
fn fibonacci_table(comptime n: Int) -> [n]Int:
    comptime var table: [n]Int = undefined
    comptime:
        table[0] = 0
        table[1] = 1
        for i in 2..n:
            table[i] = table[i-1] + table[i-2]
    return table

val fib10 = fibonacci_table(10)  # [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
```

#### Syntax: Comptime Derive-Like Mechanism

Instead of Rust's `#[derive(...)]`, use comptime reflection:

```astra
# Generate Debug implementation at compile time
fn derive_debug(comptime T: type) -> impl Trait:
    comptime:
        var impl_str = "impl Debug for " + @type_name(T) + ":\n"
        impl_str += "    fn fmt(&self, f: Formatter) -> String:\n"
        impl_str += "        return @\"{"
        for i in 0..@field_count(T):
            if i > 0: impl_str += ", "
            impl_str += @field_name(T, i) + ": {self." + @field_name(T, i) + "}"
        impl_str += "}\""
        return impl_str  # compiler parses and compiles the generated code
```

Or more idiomatically, use a built-in `@deriving` annotation:

```astra
struct User:
    @deriving(Debug, Serialize, Deserialize)
    name: String
    age: Int
    email: String
```

### 6.4 Comptime and the Dual Backend

The comptime system must work identically across both backends:

```
┌──────────────────────────────────────────────────┐
│                   Source Code                     │
│  val x = comptime factorial(10)                  │
└──────────────────┬───────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────┐
│              Type Checker + Comptime Evaluator    │
│  - Interprets comptime blocks                    │
│  - Evaluates comptime function calls             │
│  - Specializes generic functions                 │
│  - Validates dimensional types                   │
│  - Branches for conditional compilation          │
└──────────────────┬───────────────────────────────┘
                   │ (comptime fully resolved)
          ┌────────┴────────┐
          │                 │
┌─────────▼─────────┐ ┌────▼──────────────┐
│   VM Backend      │ │   LLVM Backend    │
│   (dev mode)      │ │   (prod mode)     │
│   No comptime     │ │   No comptime     │
│   code remains    │ │   code remains    │
└───────────────────┘ └───────────────────┘
```

**Key insight:** Comptime is resolved *before* backend selection. The type checker evaluates all comptime code and produces a fully monomorphized AST. Neither the VM nor LLVM ever sees comptime constructs.

### 6.5 Restrictions (What Comptime Cannot Do)

```astra
# These are NOT allowed in comptime blocks:
comptime:
    # No file I/O
    # val f = File.open("data.txt")     # ERROR
    
    # No network
    # val data = http.get("api.com")     # ERROR
    
    # No heap allocation (use compiler arena)
    # val list = List[Int]()              # ERROR
    
    # No inline assembly
    # asm("mov eax, 1")                   # ERROR
    
    # No runtime-only values
    # val x = some_runtime_function()     # ERROR
```

### 6.6 Interaction with Green Threads

Comptime is evaluated entirely at compile time — no fiber runtime is involved. Comptime code runs inside the compiler process, not in the Astra runtime. This means:

- Comptime code has no access to fibers, channels, or the scheduler
- Comptime code cannot call FFI functions (it runs in the compiler, not in the target)
- Comptime results are fully resolved before any fiber-related code is generated

### 6.7 Comparison: What Astra Gets vs. What It Avoids

| Feature | Included in Astra | Avoided |
|---------|-------------------|---------|
| Comptime function evaluation | ✓ | |
| Comptime type reflection | ✓ | |
| Comptime loops and conditionals | ✓ | |
| Generic specialization | ✓ | |
| Compile-time assertions | ✓ | |
| Code generation via reflection | ✓ | |
| Separate macro language | | ✓ |
| Token stream manipulation | | ✓ |
| AST transformation API | | ✓ |
| Hygiene problems | | ✓ |
| Compile-time file I/O | | ✓ |
| Compile-time heap allocation | | ✓ |

---

## 7. Trade-offs

### 7.1 Simplicity vs. Power

**What Astra gains:**
- Developers learn one language for both runtime and compile-time code
- No proc_macro crate, no syn, no quote dependencies
- Error messages are from the same language, with familiar syntax
- The compiler is simpler (no macro expansion phase)

**What Astra gives up:**
- Cannot generate arbitrary code at compile time (Zig can't either — comptime is not as powerful as Rust proc macros for code generation)
- Cannot create new syntax (no DSLs with custom syntax like Nim's `/= /` operators)
- Some patterns that require deep AST manipulation in Rust are awkward in comptime

### 7.2 Performance vs. Compile Speed

Comptime evaluation adds overhead to compilation. Zig mitigates this with:
- Branch quotas (default 1000 backward branches)
- Bounded evaluation (no I/O, no external calls)
- Memoization (same comptime call with same args = cached result)

For Astra, the VM backend benefits most: comptime is resolved before the VM sees the code, so there's no interpretation overhead for metaprogrammed code.

### 7.3 Extensibility

With comptime, the standard library can provide derive-like functionality without special syntax:

```astra
# In stdlib:
fn derive_json_serializer(comptime T: type) -> impl Trait:
    # ... comptime reflection + code generation

# User code:
struct Point:
    x: Float
    y: Float

# Option A: explicit annotation
val serializer = derive_json_serializer(Point)

# Option B: built-in sugar (compiler desugars to Option A)
@json_serializable
struct Point:
    x: Float
    y: Float
```

Option B is just syntactic sugar — the compiler translates `@json_serializable` to a comptime function call. No new language feature needed.

---

## 8. Conclusion

**Recommendation: Adopt Zig-style comptime for Astra.**

The approach satisfies all of Astra's design goals:
1. **Simplicity** — no separate macro language, no token stream manipulation
2. **Fast compilation** — comptime is resolved in the type checker, before backend code generation
3. **Dual backend compatibility** — comptime is backend-agnostic
4. **Powerful enough** — covers serialization, validation, generics, dimensional analysis, DSLs
5. **Debuggable** — comptime code is ordinary Astra code with familiar error messages

The key syntax elements are:
- `comptime` keyword for blocks, parameters, and variables
- `@type_name()`, `@field_count()`, `@field_name()` for reflection
- `@typeInfo()` for detailed type inspection
- Comptime functions can return types (type functions)
- Branch quotas to prevent compile-time blowups

This positions Astra as having the most ergonomic compile-time metaprogramming of any language targeting scientific/systems programming — simpler than Zig (which it's inspired by), far simpler than Rust, and more practical than C++ `constexpr`.

---

*Report prepared for Astra language design. Sources: Zig language documentation, Nim manual, Rust Reference, C++ standard proposals (P2564R3), D language tour, Swift Evolution proposals SE-0258/SE-0289/SE-0382.*
