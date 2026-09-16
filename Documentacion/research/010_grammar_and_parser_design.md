# Astra — Formal Grammar Design & Parser Implementation

## Executive Summary

This report investigates formal grammar formalisms, parsing algorithms, and syntax design decisions for Astra. Based on analysis of Rust, Zig, Python, Swift, and Go grammar designs — combined with Astra's philosophy of simplicity, readability, and dual execution — the recommendations converge on:

- **Grammar formalism:** PEG (for specification) + Pratt parsing (for expressions)
- **Parser type:** Hand-written recursive descent (already in ARCHITECTURE.md)
- **Expression philosophy:** Expression-oriented like Rust, with block expressions
- **Indentation:** Braces primary; optional indentation via INDENT/DEDENT tokens (Python-style lexer pass)

---

## 1. Grammar Formalism: EBNF, PEG, LR(1), LALR(1), GLR, Pratt

### 1.1 Formalism Comparison

| Formalism | Power | Determinism | Direction | Hand-Writable? | Used By |
|:----------|:------|:------------|:----------|:---------------|:--------|
| **EBNF** | CFG | Ambiguous (notation only) | N/A | Yes | Documentation, specs |
| **PEG** | CFG subset | Deterministic (ordered choice) | Top-down | Yes (recursive descent) | Zig (580-line PEG spec), Python 3.9+ PEG grammar |
| **LR(1)** | CFG (deterministic) | Deterministic | Bottom-up | No (needs generator) | GCC (historically), Yacc/Bison |
| **LALR(1)** | Subset of LR(1) | Deterministic | Bottom-up | No | Yacc, Bison, most parser generators |
| **GLR** | Full CFG | Non-deterministic | Bottom-up | No | Bison GLR mode, SDF/Stratego |
| **Earley** | Full CFG | Non-deterministic | Dynamic programming | No | Marpa, Parsekit |
| **Pratt/TDOP** | Expressions only | Deterministic | Top-down | Yes | Clang (C/C++), JSLint, Rust (rust-analyzer) |

**Key empirical result (Vo et al., 2026):** GLR incurs only 3× median overhead vs LR(1) on deterministic grammars. GLL is 6×, Earley is 10×. For a hand-written parser, this is irrelevant — we control the algorithm directly.

### 1.2 Recommendation for Astra

**PEG for specification, hand-written recursive descent for implementation.**

Rationale:
- Zig's entire syntax is a 580-line PEG grammar — proven tractable for languages of Astra's complexity
- PEG maps directly to recursive descent (the parser ARCHITECTURE.md already specifies)
- PEG's ordered choice `/` resolves ambiguities deterministically without precedence declarations
- No generator dependency — the parser is self-contained, debuggable, and LSP-friendly
- Pratt parsing supplements PEG for expression parsing (PEG alone handles expressions poorly due to left recursion)

### 1.3 PEG Notation for Astra Specification

```peg
# PEG notation used throughout this document
# / = ordered choice (try left, then right on failure)
# & = positive lookahead (consume nothing)
# ! = negative lookahead (consume nothing)
# * = zero or more (greedy)
# + = one or more (greedy)
# ? = optional
# { } = grouping
```

---

## 2. Operator Precedence: Pratt Parsing vs Precedence Climbing

### 2.1 The Problem

Astra needs these precedence levels (low to high):

| Level | Operators | Associativity |
|:------|:----------|:--------------|
| 1 | `\|\|` (logical or) | Left |
| 2 | `&&` (logical and) | Left |
| 3 | `\|` (bitwise or) | Left |
| 4 | `^` (bitwise xor) | Left |
| 5 | `&` (bitwise and) | Left |
| 6 | `==`, `!=`, `<`, `>`, `<=`, `>=` | Left (non-assoc) |
| 7 | `<<`, `>>` | Left |
| 8 | `+`, `-` | Left |
| 9 | `*`, `/`, `%` | Left |
| 10 | `**` (power) | Right |
| 11 | `-` (unary), `!`, `~`, `*` (deref), `&` (ref) | Prefix |
| 12 | `.`, `[]`, `()`, `?` | Left (postfix) |

### 2.2 Pratt Parsing (Recommended)

Pratt parsing is a **generalization of precedence climbing**. Each token carries:
- `nud` (null denotation): what to do when this token starts an expression (prefix, literals, parens)
- `led` (left denotation): what to do when this token follows an expression (infix, postfix)
- `lbp` (left binding power): numeric precedence for right-binding decisions

**Why Pratt over raw precedence climbing:**
- Pratt handles prefix, infix, AND postfix operators uniformly
- Precedence climbing is ad-hoc for non-binary operators
- Pratt is modular: adding a new operator = registering a handler, no grammar rewrite
- Clang, rust-analyzer, and many production compilers use Pratt

### 2.3 Pratt Parser Implementation for Astra Expressions

```python
# Pseudocode for Pratt parser core
def parse_expr(min_bp=0):
    lhs = parse_atom()  # nud: literals, identifiers, parens, blocks, if, match, etc.

    while not at_end():
        op = peek()
        if op.binding_power < min_bp:
            break

        if op.is_postfix():
            lhs = op.nud(lhs)  # e.g., x++, x?
            advance()
        elif op.is_infix():
            rhs = parse_expr(op.right_bp())  # right-assoc: bp stays; left-assoc: bp+1
            lhs = op.led(lhs, rhs)
            advance()
        else:
            break

    return lhs
```

### 2.4 Operator Registration

```python
# Astra operator table (binding power, associativity)
OPERATORS = {
    # Binary (left-assoc: right_bp = bp + 1)
    "||":  (10, "left"),
    "&&":  (20, "left"),
    "|":   (30, "left"),
    "^":   (40, "left"),
    "&":   (50, "left"),
    "==":  (60, "left"),  "!=": (60, "left"),
    "<":   (65, "left"),  ">":  (65, "left"),
    "<=":  (65, "left"),  ">=": (65, "left"),
    "<<":  (70, "left"),  ">>": (70, "left"),
    "+":   (80, "left"),  "-":  (80, "left"),
    "*":   (90, "left"),  "/":  (90, "left"),  "%": (90, "left"),

    # Binary (right-assoc)
    "**":  (95, "right"),

    # Prefix (nud only, bp = 100)
    "-":   (100, "prefix"),  "!": (100, "prefix"),
    "~":   (100, "prefix"),  "*": (100, "prefix"),
    "&":   (100, "prefix"),
}
```

---

## 3. Expression vs Statement Grammar

### 3.1 The Spectrum

| Language | Philosophy | Example |
|:---------|:-----------|:--------|
| **C/Go** | Statements don't return values | `if (x > 0) { ... }` is not an expression |
| **Rust/Zig** | Nearly everything is an expression | `let y = if x > 0 { 1 } else { 0 };` |
| **Python** | All statements are expressions (except `def`, `class`, etc.) | `y = x if x > 0 else 0` |
| **Haskell** | 100% expression-oriented | No statements at all |

### 3.2 Recommendation for Astra: Expression-Oriented (Rust Model)

**Rationale from PHILOSOPHY.md:**
- "Si aprendes 10 reglas, debes poder predecir el comportamiento de las 100 combinaciones posibles"
- Expression-oriented languages compose better: `let x = if cond { a } else { b }`
- Block expressions `{ stmt; stmt; expr }` returning the last expression's value is natural for Astra
- Astra already uses `let x = expr` (from ARCHITECTURE.md §8.1), which is expression-oriented

**What counts as a statement in Astra:**
- `let`/`val`/`mut` declarations (statements, not expressions — like Rust)
- Expression statements: `expr;` (turns any expression into a statement)
- `return`, `break`, `continue` (statements)

**What counts as an expression:**
- Everything else: literals, variables, binary ops, function calls, `if`, `match`, `while`, `for`, blocks, closures

### 3.3 Grammar Fragment

```ebnf
(* Statements and expressions *)
Statement       ::= Declaration | ExprStatement | ReturnStmt | BreakStmt | ContinueStmt
Declaration     ::= ("let" | "val" | "mut") Pattern (":" Type)? "=" Expression
ExprStatement   ::= Expression ";"
ReturnStmt      ::= "return" Expression?
BreakStmt       ::= "break" Expression?
ContinueStmt    ::= "continue"

(* Everything below is an expression *)
Expression      ::= Assignment
Assignment      ::= LValue "=" Assignment | LogicOr
```

---

## 4. Block Expressions

### 4.1 How Languages Handle This

**Rust:**
```rust
let x = {
    let a = 5;
    let b = 10;
    a + b  // no semicolon → this is the block's value
};
// x == 15
```
- Statements end with `;`
- The last expression (without `;`) is the block's value
- Adding `;` to the last expression makes the block return `()`

**Zig:**
```zig
const x = blk: {
    var a: i32 = 5;
    var b: i32 = 10;
    break :blk a + b;
};
// x == 15
```
- Must use explicit `break :label value` to return from block
- No implicit tail expression

**Swift:**
```swift
let x = {
    let a = 5
    let b = 10
    return a + b  // explicit return
}
```
- Blocks are closures; must use `return`

### 4.2 Recommendation for Astra: Rust-Style Implicit Tail Expression

```astra
// Block expression — tail expression (no semicolon) is the value
val x = {
    val a = 5
    val b = 10
    a + b        // no semicolon → block evaluates to this
}
// x == 15

// Explicit return also works
val y = {
    val a = 5
    if a > 0 {
        return a    // early return from enclosing function
    }
    10
}
```

**Rationale:**
- More concise than Zig's `break :label` (fits Astra's simplicity principle)
- More predictable than Swift's closure semantics
- Matches Rust's proven model that Astra's ARCHITECTURE.md already aligns with
- The parser distinguishes: `Expression";"` = expression statement, `Expression` (no `;`) = tail expression

### 4.3 Grammar Fragment

```ebnf
Block           ::= "{" Statement* Expression? "}"
(* Expression? is the "tail expression" — its value is the block's value *)

IfExpr          ::= "if" Expression Block ("else" (IfExpr | Block))?
WhileExpr       ::= "while" Expression Block
ForExpr         ::= "for" Pattern "in" Expression Block
MatchExpr       ::= "match" Expression "{" MatchArm* "}"
```

---

## 5. Pattern Matching Grammar

### 5.1 Syntax Comparison

| Language | Syntax | Separators |
|:---------|:-------|:-----------|
| **Rust** | `match expr { pattern => expr, ... }` | Commas, trailing comma optional |
| **Haskell** | `case expr of { pattern -> expr; ... }` | Semicolons |
| **Elixir** | `case expr do pattern -> expr end` | Keywords |
| **Swift** | `switch expr { case pattern: expr }` | Colons, no separators |
| **Zig** | `switch (expr) { pattern => expr, ... }` | Commas |

### 5.2 Recommendation for Astra: Rust-Style `match` with Commas

```astra
match value {
    Pattern1 => Expression,
    Pattern2 if guard => Expression,
    _ => Expression,   // wildcard, exhaustiveness
}
```

**Rationale:**
- `=>` is visually distinct from `=` (avoids confusion with assignment)
- Commas as separators (not semicolons) match Astra's C-like primary syntax
- `if guard` after pattern is clean and readable
- Exhaustiveness checking (compile error by default) matches Astra's safety principle

### 5.3 Pattern Grammar

```ebnf
MatchExpr       ::= "match" Expression "{" MatchArm+ "}"
MatchArm        ::= Pattern ("if" Expression)? "=>" (Expression | Block) ","?
Pattern         ::= LiteralPattern
                   | IdentifierPattern
                   | TuplePattern
                   | StructPattern
                   | EnumPattern
                   | RangePattern
                   | OrPattern
                   | RefPattern
                   | WildcardPattern
                   | AtPattern

LiteralPattern  ::= Literal | "-" Literal
IdentifierPattern ::= Identifier
WildcardPattern ::= "_"
OrPattern       ::= Pattern ("|" Pattern)+
RangePattern    ::= Literal (".." | "..=") Literal
AtPattern       ::= Identifier "@" Pattern
RefPattern      ::= ("ref" | "ref" "mut") IdentifierPattern

(* Destructuring patterns *)
TuplePattern    ::= "(" Pattern ("," Pattern)* ")"
StructPattern   ::= Identifier "{" StructFieldPattern ("," StructFieldPattern)* "}"
StructFieldPattern ::= Identifier (":" Pattern)?
EnumPattern     ::= Path ("(" Pattern ("," Pattern)* ")")?
```

---

## 6. Type Annotation Grammar

### 6.1 Syntax Comparison

| Language | Variable | Function Param | Return Type |
|:---------|:---------|:---------------|:------------|
| **Rust** | `let x: T = v` | `fn f(x: T)` | `-> T` |
| **Zig** | `var x: T = v` | `fn f(x: T)` | `T` (no arrow) |
| **Go** | `var x T = v` | `func f(x T) T` | Type after param |
| **C++** | `T x = v` | `void f(T x)` | Type before name |
| **Python** | `x: T = v` | `def f(x: T) -> T:` | `-> T` |

### 6.2 Recommendation for Astra: Rust-Style `name: Type`

```astra
val x: Int = 10           # Variable with annotation
mut y: Float = 3.14       # Mutable with annotation
val z = 42                # Inferred type (Int)

fn add(a: Int, b: Int) -> Int { a + b }   # Function params
fn greet(name: String) { ... }             # No return type = void
```

**Rationale:**
- `name: Type` reads naturally ("x of type Int")
- Consistent across variables, function parameters, struct fields
- Return type with `->` arrow is visually distinct from type annotations
- Already in ARCHITECTURE.md §8.1-8.2

### 6.3 Type Annotation Grammar

```ebnf
Type            ::= NamedType | GenericType | PointerType | SliceType
                   | OptionalType | ResultType | FunctionType | TupleType

NamedType       ::= Identifier ("." Identifier)*
GenericType      ::= Identifier "<" Type ("," Type)* ">"
PointerType      ::= "*" ("const"?) Type
SliceType        ::= "[" Type "]"
OptionalType     ::= Type "?"
ResultType       ::= "!" Type          (* Result<T, E> shorthand *)
FunctionType     ::= "(" TypeList? ")" "->" Type
TupleType        ::= "(" Type ("," Type)+ ")"
TypeList         ::= Type ("," Type)*
```

---

## 7. Function Signature Grammar

### 7.1 Syntax Comparison

| Language | Syntax | Generics | Where Clause |
|:---------|:-------|:---------|:-------------|
| **Rust** | `fn name<T: Bound>(params) -> Ret` | `<>` after name | `where T: Bound` |
| **Zig** | `fn name(params) Ret` | `comptime T: type` param | No where clause |
| **Go** | `func name[T Constraint](params) Ret` | `[]` after name | Constraint in `[]` |
| **Swift** | `func name<T: Protocol>(params) -> Ret` | `<>` after name | No where clause |
| **C++** | `template<typename T> Ret name(params)` | Before return type | Specialization |

### 7.2 Recommendation for Astra: Rust-Style with Optional Zig-Style Shorthand

```astra
# Full signature
fn max<T: Comparable>(a: T, b: T) -> T {
    if a > b { a } else { b }
}

# With where clause (for complex bounds)
fn process<T>(items: Array<T>) -> T
where
    T: Serializable + Debug
{
    // ...
}

# Comptime parameters (Zig-style)
fn repeat(comptime N: Int, value: String) -> [N]String {
    // N is comptime-known, used as array length
}

# Single-expression shorthand
fn square(x: Int) -> Int = x * x

# No return type = void
fn log(msg: String) {
    print(msg)
}
```

### 7.3 Function Grammar

```ebnf
Function        ::= FunctionQualifiers "fn" Identifier GenericParams?
                     "(" FunctionParams? ")" ReturnType? WhereClause?
                     (Block | "=" Expression ";")

FunctionQualifiers ::= ("pub" | "extern" | "async" | "unsafe" | "comptime")*

GenericParams  ::= "<" GenericParam ("," GenericParam)* ">"
GenericParam   ::= Identifier (":" TraitBounds)?

FunctionParams ::= FunctionParam ("," FunctionParam)* ","?
FunctionParam  ::= Identifier ":" Type
                 | "comptime" Identifier ":" Type
                 | "self"
                 | "mut" "self"
                 | "&" "self"
                 | "&" "mut" "self"

ReturnType     ::= "->" Type
WhereClause    ::= "where" WhereBound ("," WhereBound)*
WhereBound     ::= Identifier ":" TraitBounds
TraitBounds    ::= TraitBound ("+" TraitBound)*
TraitBound     ::= Identifier ("<" Type ("," Type)* ">")?
```

---

## 8. Comptime Grammar

### 8.1 Zig-Style Comptime (Astra's Model)

Zig's comptime has three forms:
1. **Comptime parameters:** `fn foo(comptime T: type, x: T) T`
2. **Comptime variables:** `comptime var x: Int = compute()`
3. **Comptime blocks:** `comptime { ... }`

Astra adopts all three (per ARCHITECTURE.md §12).

### 8.2 Comptime Grammar

```ebnf
(* Comptime blocks — evaluated at compile time *)
ComptimeBlock   ::= "comptime" (Block | ":" Statement)

(* Comptime expressions — force compile-time evaluation *)
ComptimeExpr    ::= "comptime" Expression

(* Comptime parameters in functions *)
ComptimeParam   ::= "comptime" Identifier ":" Type

(* Comptime variable declarations *)
ComptimeDecl    ::= "comptime" "var" Identifier (":" Type)? "=" Expression
                 | "comptime" "val" Identifier (":" Type)? "=" Expression

(* @builtins for compile-time reflection *)
BuiltinCall     ::= "@" Identifier "(" ArgumentList? ")"
```

### 8.3 Example Grammar for Comptime Block

```ebnf
ComptimeBlock   ::= "comptime" Block
(* Block is a normal block expression, but all expressions
   within are evaluated at compile time *)
```

This is beautifully simple: a `comptime` block is syntactically identical to any other block. The semantic layer (not the parser) enforces compile-time evaluation constraints (no I/O, no heap, no FFI calls).

---

## 9. Error Recovery in Parser

### 9.1 Strategies

| Strategy | Description | Quality | Used By |
|:---------|:-----------|:--------|:--------|
| **Panic mode** | Skip tokens until sync token (`;`, `}`) | Poor (cascading errors) | Yacc/Bison default |
| **Phrase-level** | Delete/insert tokens to complete current construct | Good | ANTLR 4, rust-analyzer |
| **Error productions** | Grammar rules for common mistakes | Good | Yacc (manual) |
| **CPCT+** | Minimum-cost repair sequences | Excellent | Academic (ECOOP 2020) |
| **Labeled failures** | PEG-specific: label failure points | Good | Tree-sitter,Titan parser |

### 9.2 Recommendation for Astra: Phrase-Level Recovery

The parser should **never fail completely**. It always produces a CST + error list.

```rust
// Parser output type (from ARCHITECTURE.md §18.2)
struct ParseResult {
    cst: CST,              // Always produced
    errors: Vec<SyntaxError>, // May be empty
}
```

**Recovery techniques for Astra's recursive descent parser:**

1. **Synchronizing tokens:** After an error, skip to the next `;`, `}`, `)`, `]`, or newline
2. **Token insertion:** Insert missing `;`, `}`, `)` when the parser expects them
3. **Token deletion:** Skip unexpected tokens with a diagnostic
4. **Error productions:** `ExprList := Expr ("," Expr)* ","?` (trailing comma)

### 9.3 Error Recovery Pseudocode

```python
def parse_statement(self):
    try:
        return self.parse_statement_impl()
    except ParseError as e:
        self.errors.append(e)
        # Synchronize to next statement boundary
        self.skip_to_sync({SEMICOLON, RBRACE, NEWLINE})
        return ErrorNode(e.span)

def skip_to_sync(self, tokens):
    while self.current.kind not in tokens and not self.at_end():
        self.advance()
    if self.current.kind in tokens:
        self.advance()  # consume the sync token
```

### 9.4 Synchronizing Token Sets

| Context | Sync Tokens | Rationale |
|:--------|:------------|:----------|
| Statement | `;`, `}`, EOF | Statement ends at semicolon or block end |
| Expression | `)`, `]`, `}`, `,` | Expression ends at closing delimiter or separator |
| Block | `}` | Block ends at closing brace |
| Function params | `)` | Params end at closing paren |
| Match arm | `,`, `}` | Arms separated by commas |

---

## 10. Parser Implementation: Recursive Descent vs Generated

### 10.1 Comparison

| Aspect | Hand-Written RD | Generated (Bison/ANTLR) |
|:-------|:----------------|:-------------------------|
| **Control** | Full control over error messages, recovery, AST | Limited to generator's error strategy |
| **Debugging** | Step through with debugger | Hard to debug generated code |
| **Error quality** | Excellent (custom messages per construct) | Good (ANTLR) / Poor (Bison) |
| **Maintenance** | Grammar is the code | Grammar is separate from actions |
| **Performance** | Optimizable by hand | Overhead from tables/generic dispatch |
| **Incremental** | Easy to add features | May need grammar restructuring |
| **Industry usage** | Clang, V8, rust-analyzer, Go, Rust | GCC (C/C++ historically), Java (early) |

### 10.2 Recommendation for Astra: Hand-Written Recursive Descent

**Already specified in ARCHITECTURE.md §20.1:**
> "Lexer & Parser (Descenso recursivo a mano)"

**Rationale:**
- Clang, V8, and rust-analyzer all use hand-written recursive descent for exactly the reasons above
- The parser must produce CST + errors (never fail) — hand-written gives full control
- LSP requires incremental parsing — hand-written is trivially incremental
- Error recovery is the hardest part of parsing — hand-written is superior
- Pratt parsing for expressions is easy to integrate into recursive descent

### 10.3 Parser Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     Parser (Recursive Descent)           │
│                                                          │
│  ┌──────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │  Lexer    │───▶│  Tokenizer   │───▶│  Token Stream │  │
│  │  (hand)   │    │  + INDENT/   │    │  (with spans) │  │
│  │           │    │    DEDENT    │    │               │  │
│  └──────────┘    └──────────────┘    └───────┬───────┘  │
│                                              │          │
│  ┌───────────────────────────────────────────▼────────┐  │
│  │              Grammar Parser                        │  │
│  │                                                    │  │
│  │  parse_module()                                    │  │
│  │    ├── parse_item()  → fn, struct, enum, trait     │  │
│  │    ├── parse_stmt()  → let, val, mut, expr stmt   │  │
│  │    ├── parse_expr()  → Pratt parser (precedence)  │  │
│  │    └── parse_type()  → Type annotations           │  │
│  │                                                    │  │
│  │  Error Recovery: skip_to_sync() per context       │  │
│  └────────────────────────────────────────────────────┘  │
│                          │                               │
│                          ▼                               │
│  ┌────────────────────────────────────────────────────┐  │
│  │  Output: (CST, Vec<SyntaxError>)                   │  │
│  │  CST is always valid, errors are always reported   │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

---

## 11. Indentation-Sensitive Parsing

### 11.1 Options for Astra

| Option | Description | Pros | Cons |
|:-------|:-----------|:-----|:-----|
| **A. Braces only** (Go, Rust, Zig) | `{}` always required | Simple parser, no ambiguity | Verbose, style debates |
| **B. Indentation required** (Python, Haskell) | Indentation defines blocks | Enforced consistent style | Fragile, hard to embed in other languages |
| **C. Braces primary, indentation optional** | `{}` preferred; `:` + indent legal | Best of both worlds | Parser complexity (two grammar paths) |
| **D. Braces primary, indentation as sugar** | `{}` always works; indentation is syntactic sugar | Backward-compatible | Two parsing modes, confusion |

### 11.2 Recommendation: Option A (Braces Primary) with Future Option C

**Phase 1 (current):** Braces-only for simplicity.

```astra
fn add(a: Int, b: Int) -> Int {
    return a + b
}

if x > 0 {
    print("positive")
} else {
    print("non-positive")
}
```

**Phase 2 (future, optional):** Add indentation support via lexer-level INDENT/DEDENT tokens.

```astra
# Optional: colon + indent syntax (alternative to braces)
fn add(a: Int, b: Int) -> Int:
    return a + b

if x > 0:
    print("positive")
else:
    print("non-positive")
```

**Implementation strategy (from Cornell CS4120 notes):**
- Lexer inserts `INDENT`/`DEDENT` tokens based on indentation level changes
- Grammar uses these tokens as invisible braces: `Block ::= INDENT Statement* Expression? DEDENT`
- Both `{ ... }` and `INDENT ... DEDENT` are valid block delimiters
- This is how Python's PEG grammar handles it

**Why defer indentation:**
- Increases parser complexity significantly
- Python's indentation handling is notoriously tricky (continuation lines, ambiguous indentation)
- Astra's philosophy: "Simplicidad como Estrategia de Ingeniería" — braces are simpler
- Can be added later as an opt-in feature without breaking existing code

### 11.3 Lexer Changes for Future Indentation Support

```python
class Lexer:
    def tokenize(self, source):
        tokens = []
        indent_stack = [0]  # Track indentation levels

        for line in source.lines():
            indent = line.leading_spaces()

            if indent > indent_stack[-1]:
                tokens.append(Token(INDENT, line.span))
                indent_stack.append(indent)
            elif indent < indent_stack[-1]:
                while indent < indent_stack[-1]:
                    tokens.append(Token(DEDENT, line.span))
                    indent_stack.pop()

            tokens.extend(self.tokenize_line(line))

        return tokens
```

---

## 12. Complete Astra Grammar Specification

### 12.1 Full EBNF Grammar

```ebnf
(* ============================================================ *)
(* Astra Grammar Specification v0.1                              *)
(* ============================================================ *)

(* --- Module Structure --- *)
Module          ::= Item*
Item            ::= FunctionDef | StructDef | EnumDef | TraitDef
                   | ImplBlock | ImportStmt | ExportStmt
                   | ConstDef | TypeAlias | ComptimeBlock

(* --- Function Definition --- *)
FunctionDef     ::= FunctionQualifiers "fn" Identifier
                     GenericParams? "(" FunctionParams? ")"
                     ReturnType? WhereClause?
                     (Block | "=" Expression)
FunctionQualifiers ::= ("pub" | "extern" StringLiteral? | "unsafe" | "comptime")*
GenericParams  ::= "<" GenericParam ("," GenericParam)* ">"
GenericParam   ::= Identifier (":" TraitBounds)?
FunctionParams ::= FunctionParam ("," FunctionParam)* ","?
FunctionParam  ::= ("comptime"? Identifier ":" Type)
                 | ("&" | "&&")? "mut"? "self"
ReturnType     ::= "->" Type
WhereClause    ::= "where" WhereBound ("," WhereBound)*
WhereBound     ::= TypePath ":" TraitBounds
TraitBounds    ::= TraitBound ("+" TraitBound)*
TraitBound     ::= TypePath

(* --- Type System --- *)
Type            ::= FunctionType
FunctionType    ::= "(" TypeList? ")" "->" Type
                 | AtomicType
AtomicType      ::= OptionalType
OptionalType    ::= PrimaryType "?"
PrimaryType     ::= SimpleType ("." "<" TypeArgs ">")?
SimpleType      ::= Identifier | "(" Type ("," Type)+ ")"
                   | "[" Type (";" Expression)? "]"
                   | "*" "const"? Type
                   | "&" "mut"? Type
TypeArgs        ::= Type ("," Type)*
TypeList        ::= Type ("," Type)*

(* --- Struct Definition --- *)
StructDef       ::= StructQualifiers "struct" Identifier
                     GenericParams? WhereClause? "{" StructFields? "}"
StructQualifiers ::= ("pub" | "extern")*
StructFields    ::= StructField ("," StructField)* ","?
StructField     ::= Identifier ":" Type

(* --- Enum Definition --- *)
EnumDef         ::= "enum" Identifier GenericParams? WhereClause?
                     "{" EnumVariants? "}"
EnumVariants    ::= EnumVariant ("," EnumVariant)* ","?
EnumVariant     ::= Identifier ("(" EnumPayload ")")?
EnumPayload     ::= EnumPayloadField ("," EnumPayloadField)*
EnumPayloadField ::= Identifier ":" Type
                   | Type

(* --- Trait Definition --- *)
TraitDef        ::= "trait" Identifier GenericParams? WhereClause?
                     "{" TraitItem* "}"
TraitItem       ::= FunctionDef | ConstDef

(* --- Impl Block --- *)
ImplBlock       ::= "impl" GenericParams? Type ("for" Type)?
                     WhereClause? "{" ImplItem* "}"
ImplItem        ::= FunctionDef | ConstDef

(* --- Import/Export --- *)
ImportStmt      ::= "import" ImportPath ("as" Identifier)?
                 | "from" ImportPath "import" ImportItem ("," ImportItem)*
ImportPath      ::= Identifier ("." Identifier)*
ImportItem      ::= Identifier ("as" Identifier)?

ExportStmt      ::= "use" ImportPath

(* --- Constants --- *)
ConstDef        ::= ("pub"? "const" | "val") Identifier (":" Type)? "=" Expression

TypeAlias       ::= "type" Identifier ("=" | "<" GenericParams ">") Type

(* ============================================================ *)
(* STATEMENTS                                                    *)
(* ============================================================ *)

Statement       ::= Declaration | ExprStatement | ReturnStmt
                   | BreakStmt | ContinueStmt | ComptimeStmt
Declaration     ::= ("val" | "mut" | "let") Pattern (":" Type)? "=" Expression
ExprStatement   ::= Expression ";"
ReturnStmt      ::= "return" Expression?
BreakStmt       ::= "break" Expression?
ContinueStmt    ::= "continue"
ComptimeStmt    ::= ComptimeBlock

(* ============================================================ *)
(* EXPRESSIONS                                                   *)
(* ============================================================ *)

Expression      ::= Assignment

(* Assignment (right-assoc) *)
Assignment      ::= LValue ("=" | "+=" | "-=" | "*=" | "/=" | "%="
                            | "&=" | "|=" | "^=" | "<<=" | ">>=" | "**=")
                     Assignment
                 | LogicOr

(* Binary operators (precedence low to high) *)
LogicOr         ::= LogicAnd ("||" LogicAnd)*
LogicAnd        ::= BitOr ("&&" BitOr)*
BitOr           ::= BitXor ("|" BitXor)*
BitXor          ::= BitAnd ("^" BitAnd)*
BitAnd          ::= Equality ("&" Equality)*
Equality        ::= Comparison (("==" | "!=") Comparison)*
Comparison      ::= Shift (("<" | ">" | "<=" | ">=") Shift)*
Shift           ::= Additive (("<<" | ">>") Additive)*
Additive        ::= Multiplicative (("+" | "-") Multiplicative)*
Multiplicative  ::= Power (("*" | "/" | "%") Power)*
Power           ::= Unary ("**" Unary)*

(* Unary operators *)
Unary           ::= ("-" | "!" | "~" | "*" | "&") Unary
                 | Postfix

(* Postfix operators *)
Postfix         ::= Primary
                     ("." Identifier
                     | "[" Expression (".." Expression)? "]"
                     | "(" ArgumentList? ")"
                     | "?"
                     | "++" | "--"
                     )*

(* Primary expressions *)
Primary         ::= Literal
                 | Identifier
                 | Block
                 | IfExpr
                 | WhileExpr
                 | ForExpr
                 | MatchExpr
                 | LambdaExpr
                 | ComptimeExpr
                 | "(" Expression ")"
                 | Type "." "new" "(" ArgumentList? ")"
                 | BuiltinCall

(* --- Literals --- *)
Literal         ::= IntegerLiteral | FloatLiteral | StringLiteral
                   | CharLiteral | BoolLiteral | "null" | "none"
                   | ArrayLiteral | TupleLiteral | StructLiteral

IntegerLiteral  ::= DecimalLiteral | HexLiteral | OctalLiteral | BinaryLiteral
DecimalLiteral  ::= [0-9]+ ("_" [0-9]+)*
HexLiteral      ::= "0x" [0-9a-fA-F]+ ("_" [0-9a-fA-F]+)*
OctalLiteral    ::= "0o" [0-7]+ ("_" [0-7]+)*
BinaryLiteral   ::= "0b" [01]+ ("_" [01]+)*
FloatLiteral    ::= [0-9]+ "." [0-9]+ ([eE] [+-]? [0-9]+)?
StringLiteral   ::= '"' StringChar* '"' | "''" StringChar* "''"
                   | "'''" MultiLineString "'''"
StringChar      ::= EscapeSequence | !('"') any_char
EscapeSequence  ::= "\" ("n" | "t" | "r" | "\" | '"' | "'" | "u{" [0-9a-fA-F]+ "}")
BoolLiteral     ::= "true" | "false"
CharLiteral     ::= "'" CharChar "'"
CharChar        ::= EscapeSequence | !("'") any_char

(* --- Compound Literals --- *)
ArrayLiteral    ::= "[" Expression ("," Expression)* ","? "]"
TupleLiteral    ::= "(" Expression ("," Expression)+ ")"
StructLiteral   ::= Identifier "{" StructFieldInit ("," StructFieldInit)* ","? "}"
StructFieldInit ::= Identifier ("=" Expression)?

(* --- Block Expression --- *)
Block           ::= "{" Statement* Expression? "}"

(* --- Control Flow Expressions --- *)
IfExpr          ::= "if" Expression Block ("else" (IfExpr | Block))?
WhileExpr       ::= "while" Expression Block
ForExpr         ::= "for" (Pattern | Identifier) "in" Expression Block
MatchExpr       ::= "match" Expression "{" MatchArm+ "}"
MatchArm        ::= Pattern ("if" Expression)? "=>" (Expression | Block) ","?

(* --- Lambda/Closure --- *)
LambdaExpr      ::= "|" LambdaParams? "|" ("->" Type)? Block
LambdaParams    ::= LambdaParam ("," LambdaParam)* ","?
LambdaParam     ::= Identifier (":" Type)?

(* --- Comptime --- *)
ComptimeBlock   ::= "comptime" (Block | ":" Statement)
ComptimeExpr    ::= "comptime" Expression

(* --- Builtins --- *)
BuiltinCall     ::= "@" Identifier "(" ArgumentList? ")"
ArgumentList    ::= NamedArg ("," NamedArg)* | Expression ("," Expression)*
NamedArg        ::= Identifier "=" Expression

(* ============================================================ *)
(* PATTERNS                                                      *)
(* ============================================================ *)

Pattern         ::= OrPattern
OrPattern       ::= AndPattern ("|" AndPattern)*
AndPattern      ::= RangePattern ("&" RangePattern)?
RangePattern    ::= ComparisonPattern (".." RangePattern)?
                 | ComparisonPattern ("..=" ComparisonPattern)?
ComparisonPattern ::= PrefixPattern
PrefixPattern   ::= ("-" | "!") PrefixPattern
                 | AtPattern
AtPattern       ::= Identifier "@" Pattern
                 | AtomicPattern
AtomicPattern   ::= LiteralPattern
                 | IdentifierPattern
                 | TuplePattern
                 | StructPattern
                 | EnumPattern
                 | WildcardPattern
                 | RefPattern
                 | TypePattern

LiteralPattern  ::= Literal | "-" Literal
IdentifierPattern ::= Identifier ("@" Identifier)?
WildcardPattern ::= "_"
TuplePattern    ::= "(" Pattern ("," Pattern)* ")"
StructPattern   ::= Identifier "{" StructPatternField ("," StructPatternField)* ","? "}"
StructPatternField ::= Identifier (":" Pattern)?
EnumPattern     ::= Path ("(" Pattern ("," Pattern)* ")")?
RefPattern      ::= ("ref" | "ref" "mut") IdentifierPattern
TypePattern     ::= Identifier

(* ============================================================ *)
(* LEXICAL CONVENTIONS                                           *)
(* ============================================================ *)

(* Keywords *)
Keyword         ::= "fn" | "struct" | "enum" | "trait" | "impl" | "for"
                   | "if" | "else" | "while" | "for" | "in"
                   | "match" | "return" | "break" | "continue"
                   | "val" | "var" | "let" | "mut" | "const"
                   | "pub" | "import" | "from" | "use" | "as"
                   | "where" | "type" | "comptime" | "unsafe"
                   | "spawn" | "async" | "extern"
                   | "true" | "false" | "null" | "none"

(* Operators *)
Operator        ::= "." | "->" | "=>" | "::"
                   | "+" | "-" | "*" | "/" | "%" | "**"
                   | "=" | "==" | "!=" | "<" | ">" | "<=" | ">="
                   | "<<" | ">>"
                   | "&" | "|" | "^" | "~"
                   | "&&" | "||" | "!"
                   | "?" | "++" | "--"
                   | "+=" | "-=" | "*=" | "/=" | "%=" | "**="
                   | "&=" | "|=" | "^=" | "<<=" | ">>="

(* Delimiters *)
Delimiter       ::= "(" | ")" | "{" | "}" | "[" | "]" | ";" | "," | ":"

(* Identifiers *)
Identifier      ::= [a-zA-Z_] [a-zA-Z0-9_]*

(* Comments *)
LineComment     ::= "//" !"\n" any_char*
BlockComment    ::= "/*" (!"*/" any_char)* "*/"

(* Whitespace *)
Whitespace      ::= (" " | "\t" | "\r")*
Newline         ::= "\n" | "\r\n" | "\r"
```

### 12.2 Operator Precedence Table (Summary)

| Precedence | Operators | Associativity | Type |
|:-----------|:----------|:--------------|:-----|
| 1 (lowest) | `\|\|` | Left | Binary |
| 2 | `&&` | Left | Binary |
| 3 | `\|` | Left | Binary |
| 4 | `^` | Left | Binary |
| 5 | `&` | Left | Binary |
| 6 | `==`, `!=`, `<`, `>`, `<=`, `>=` | Left (non-assoc) | Binary |
| 7 | `<<`, `>>` | Left | Binary |
| 8 | `+`, `-` | Left | Binary |
| 9 | `*`, `/`, `%` | Left | Binary |
| 10 | `**` | Right | Binary |
| 11 | `-`, `!`, `~`, `*`, `&` | Right (prefix) | Unary |
| 12 | `.`, `[]`, `()`, `?`, `++`, `--` | Left | Postfix |
| 13 (highest) | `=` `+=` `-=` ... | Right | Assignment |

---

## 13. Implementation Roadmap

### Phase 1: Core Parser (Weeks 1-4)

```
1. Lexer with token types, spans, and comments
2. Pratt parser for expressions
3. Recursive descent for statements and items
4. Basic error recovery (panic mode with sync tokens)
5. CST/AST output
```

### Phase 2: Full Grammar (Weeks 5-8)

```
1. Pattern matching parser
2. Generic type parameters
3. Where clauses
4. Impl blocks
5. Import/export system
6. Comptime blocks
```

### Phase 3: Error Recovery (Weeks 9-10)

```
1. Phrase-level recovery
2. Token insertion/deletion
3. Custom error messages per construct
4. Error recovery tests
```

### Phase 4: LSP Integration (Weeks 11-12)

```
1. Incremental parsing
2. CST re-parsing on edits
3. Error squiggles
4. Syntax highlighting from CST
```

---

## 14. References

- Pratt, V. (1973). "Top Down Operator Precedence." POPL.
- Ford, B. (2002). "Parsing Expression Grammars." POPL.
- Vo et al. (2026). "An Empirical Comparison of General Context-Free Parsers." arXiv:2606.08465.
- Diekmann & Tratt (2020). "Don't Panic! Better, Fewer, Syntax Errors for LR Parsers." ECOOP.
- Tomita, M. (1987). "Efficient Parsing for Natural Languages." Kluwer.
- Eli Bendersky. "Parsing Expressions by Precedence Climbing." (2012).
- Andy Chu. "Pratt Parsing and Precedence Climbing Are the Same Algorithm." (2016).
- Brunauer & Mühlbacher. "Indentation Sensitive Languages." (2006).
- Erdweg et al. "Principled Parsing for Indentation-Sensitive Languages." POPL 2013.
- Zig Language Reference. "Grammar." ziglang.org.
- Rust Reference. "Statements and Expressions." doc.rust-lang.org.
- Cornell CS4120. "LR(1) and LALR Parsing." (2026).
