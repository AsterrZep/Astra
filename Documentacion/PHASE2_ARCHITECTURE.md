# Phase 2 Architecture: Zig Self-Hosting Compiler

> **Version**: 1.0  
> **Status**: Design  
> **Last updated**: 2026-09-21  
> **Depends on**: Phase 1 (C seed compiler) — completed

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Module Structure](#2-module-structure)
3. [Data Structures](#3-data-structures)
4. [Algorithm Choices](#4-algorithm-choices)
5. [LLVM Integration](#5-llvm-integration)
6. [Error Handling Strategy](#6-error-handling-strategy)
7. [Memory Management](#7-memory-management)
8. [Testing Strategy](#8-testing-strategy)
9. [Implementation Plan](#9-implementation-plan)

---

## 1. Executive Summary

Phase 2 replaces the C seed compiler with a Zig-based self-hosting compiler that supports the full Astra language. The Zig compiler inherits the proven architecture from Phase 1 (recursive descent + Pratt parser, arena allocation, dual backend) while adding support for generics, traits, comptime, ARC/ORC, fibers, and LLVM optimization.

### Key Design Principles

| Principle | Description |
|:----------|:------------|
| **Progressive Lowering** | AST → ZIR → AIR → LLVM IR, each stage trading expressiveness for optimization accessibility |
| **Arena-Only Allocation** | All compiler phases use arena allocators; no individual free() calls |
| **Error Recovery** | Parser never fails; always produces partial AST + error list |
| **Dual Backend** | VM for development (<10ms startup), LLVM for production |
| **Query-Based Architecture** | Each compilation step is a memoized query for incremental support |

### Inherited from Phase 1

- 44 grammar constructs fully implemented
- 27 operators with correct precedence
- 89 passing tests (conformance + codegen + UI errors)
- Recursive descent + Pratt parser architecture
- Scoped symbol table with type inference

---

## 2. Module Structure

### 2.1 Top-Level Layout

```
zig/
├── build.zig                    # Build system configuration
├── build.zig.zon                # Package manifest
├── src/
│   ├── main.zig                 # CLI entry point
│   ├── compiler.zig             # Compiler driver (orchestrates pipeline)
│   │
│   ├── lexer/
│   │   ├── mod.zig              # Lexer module exports
│   │   ├── token.zig            # Token types and definitions
│   │   ├── lexer.zig            # Hand-written tokenizer
│   │   └── unicode.zig          # Unicode identifier support
│   │
│   ├── parser/
│   │   ├── mod.zig              # Parser module exports
│   │   ├── parser.zig           # Recursive descent parser
│   │   ├── pratt.zig            # Pratt expression parser
│   │   ├── recovery.zig         # Error recovery strategies
│   │   └── precedence.zig       # Operator precedence table
│   │
│   ├── ast/
│   │   ├── mod.zig              # AST module exports
│   │   ├── node.zig             # AST node definitions
│   │   ├── tree.zig             # AST tree structure
│   │   ├── source.zig           # Source location tracking
│   │   └── print.zig            # AST pretty-printer
│   │
│   ├── sema/
│   │   ├── mod.zig              # Semantic analysis module exports
│   │   ├── name_resolver.zig    # Name resolution and scoping
│   │   ├── type_checker.zig     # Type inference and checking
│   │   ├── generics.zig         # Generic specialization
│   │   ├── traits.zig           # Trait resolution
│   │   ├── comptime.zig         # Compile-time evaluation
│   │   └── borrow.zig           # Borrow checker (optional)
│   │
│   ├── air/
│   │   ├── mod.zig              # AIR module exports
│   │   ├── air.zig              # AIR instruction definitions
│   │   ├── builder.zig          # AIR construction
│   │   ├── arc_insert.zig       # ARC increment/decrement insertion
│   │   ├── yield_insert.zig     # Fiber yield point insertion
│   │   └── print.zig            # AIR pretty-printer
│   │
│   ├── codegen/
│   │   ├── mod.zig              # Codegen module exports
│   │   ├── vm.zig               # Bytecode VM backend
│   │   ├── llvm.zig             # LLVM backend
│   │   ├── c_backend.zig        # C code generation
│   │   └── wasm.zig             # WebAssembly backend (future)
│   │
│   ├── compiler_internals/
│   │   ├── intern_pool.zig      # String/value interning
│   │   ├── source_manager.zig   # Source file management
│   │   ├── diagnostics.zig      # Error/warning messages
│   │   ├── options.zig          # Compiler options
│   │   └── cache.zig            # Compilation cache
│   │
│   └── std/
│       └── ...                  # Astra standard library (future)
│
├── tests/
│   ├── conformance/             # Language specification tests
│   ├── ui/                      # Error message tests
│   ├── codegen/                 # Generated code checks
│   ├── incr/                    # Incremental compilation
│   ├── property/                # Property-based tests
│   └── fuzz/                    # Fuzzing corpora
│
└── lib/
    └── astra_runtime/           # Astra runtime library
        ├── arc.zig              # ARC/ORC implementation
        ├── fiber.zig            # Fiber scheduler
        └── io.zig               # Async I/O
```

### 2.2 File Responsibilities

| File | Responsibility | Lines (est.) |
|:-----|:---------------|:-------------|
| `main.zig` | CLI parsing, option handling | ~500 |
| `compiler.zig` | Pipeline orchestration, incremental compilation | ~1500 |
| `lexer/token.zig` | Token enum, keyword table | ~400 |
| `lexer/lexer.zig` | Tokenizer, Unicode support | ~1200 |
| `parser/parser.zig` | Recursive descent, statement parsing | ~2500 |
| `parser/pratt.zig` | Expression parsing, precedence climbing | ~800 |
| `parser/recovery.zig` | Error recovery, synchronization | ~600 |
| `ast/node.zig` | AST node tagged unions | ~1500 |
| `ast/tree.zig` | Tree structure, node storage | ~600 |
| `sema/type_checker.zig` | Type inference, unification | ~3000 |
| `sema/generics.zig` | Monomorphization, type parameters | ~1500 |
| `sema/traits.zig` | Trait resolution, witness tables | ~2000 |
| `sema/comptime.zig` | Compile-time evaluation | ~1500 |
| `air/air.zig` | AIR instruction definitions | ~800 |
| `air/builder.zig` | AIR construction from AST | ~2000 |
| `air/arc_insert.zig` | ARC insertion pass | ~1000 |
| `codegen/vm.zig` | Bytecode VM execution | ~3000 |
| `codegen/llvm.zig` | LLVM IR generation | ~4000 |
| `compiler_internals/intern_pool.zig` | String/value interning | ~800 |
| `compiler_internals/diagnostics.zig` | Error messages, suggestions | ~1500 |

**Total estimated**: ~30,000 lines of Zig

---

## 3. Data Structures

### 3.1 Token

```zig
pub const Token = struct {
    tag: Tag,
    loc: Loc,
    data: Data,

    pub const Tag = enum(u16) {
        // Literals
        int_literal,
        float_literal,
        string_literal,
        char_literal,
        multiline_string,
        
        // Identifiers
        identifier,
        
        // Keywords
        fn_kw,          // fn
        let_kw,         // let
        mut_kw,         // mut
        return_kw,      // return
        if_kw,          // if
        else_kw,        // else
        while_kw,       // while
        for_kw,         // for
        in_kw,          // in
        break_kw,       // break
        continue_kw,    // continue
        match_kw,       // match
        struct_kw,      // struct
        enum_kw,        // enum
        trait_kw,       // trait
        impl_kw,        // impl
        type_kw,        // type
        comptime_kw,    // comptime
        unsafe_kw,      // unsafe
        pub_kw,         // pub
        import_kw,      // import
        as_kw,          // as
        true_kw,        // true
        false_kw,       // false
        none_kw,        // none
        some_kw,        // some
        ok_kw,          // ok
        err_kw,         // err
        spawn_kw,       // spawn
        transfer_kw,    // transfer
        weak_kw,        // weak
        use_kw,         // use
        derive_kw,      // derive
        
        // Operators
        plus,           // +
        minus,          // -
        star,           // *
        slash,          // /
        percent,        // %
        bang,           // !
        amp,            // &
        pipe,           // |
        caret,          // ^
        tilde,          // ~
        shift_left,     // <<
        shift_right,    // >>
        eq,             // ==
        neq,            // !=
        lt,             // <
        gt,             // >
        lte,            // <=
        gte,            // >=
        and_kw,         // &&
        or_kw,          // ||
        assign,         // =
        plus_assign,    // +=
        minus_assign,   // -=
        star_assign,    // *=
        slash_assign,   // /=
        percent_assign, // %=
        amp_assign,     // &=
        pipe_assign,    // |=
        caret_assign,   // ^=
        shift_left_assign,  // <<=
        shift_right_assign, // >>=
        arrow,          // ->
        fat_arrow,      // =>
        dot,            // .
        dotdot,         // ..
        dotdoteq,       // ..=
        colon,          // :
        coloncolon,     // ::
        comma,          // ,
        semicolon,      // ;
        lparen,         // (
        rparen,         // )
        lbrace,         // {
        rbrace,         // }
        lbracket,       // [
        rbracket,       // ]
        question,       // ?
        at,             // @
        hash,           // #
        
        // Special
        eof,
        error_token,
        
        // Comments
        line_comment,
        block_comment,
    };

    pub const Loc = struct {
        start: u32,
        end: u32,
        line: u32,
        column: u32,
    };

    pub const Data = union(enum) {
        none,
        interned: u32,      // Index into intern pool
        integer: u64,
        float: f64,
    };
};
```

### 3.2 AST Nodes

```zig
pub const Node = union(enum) {
    // Top-level items
    fn_decl: FnDecl,
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    trait_decl: TraitDecl,
    impl_decl: ImplDecl,
    type_alias: TypeAlias,
    const_decl: ConstDecl,
    comptime_block: ComptimeBlock,
    import: Import,
    module_level_stmt: Stmt,
    
    // Statements
    stmt: Stmt,
    
    // Expressions
    expr: Expr,
    
    // Patterns
    pattern: Pattern,
    
    // Types
    type_expr: TypeExpr,
    
    pub const FnDecl = struct {
        name: Token.Index,
        generics: ?[]const TypeParam,
        params: []const Param,
        return_type: ?TypeExpr,
        body: ?Block,
        is_pub: bool,
        is_async: bool,     // spawn
        attrs: []const Attr,
    };
    
    pub const TypeParam = struct {
        name: Token.Index,
        bounds: []const TypeExpr,  // Trait bounds
    };
    
    pub const Param = struct {
        name: Token.Index,
        type: TypeExpr,
        is_mut: bool,
        default: ?Expr,
    };
    
    pub const StructDecl = struct {
        name: Token.Index,
        generics: ?[]const TypeParam,
        fields: []const Field,
        methods: []const FnDecl,
        derives: []const Attr,
        is_pub: bool,
    };
    
    pub const Field = struct {
        name: Token.Index,
        type: TypeExpr,
        default: ?Expr,
        is_pub: bool,
    };
    
    pub const EnumDecl = struct {
        name: Token.Index,
        generics: ?[]const TypeParam,
        variants: []const Variant,
        is_pub: bool,
    };
    
    pub const Variant = struct {
        name: Token.Index,
        data: ?Union(enum) {
            tuple: []const TypeExpr,
            struct_fields: []const Field,
        },
    };
    
    pub const TraitDecl = struct {
        name: Token.Index,
        generics: ?[]const TypeParam,
        methods: []const FnDecl,
        is_pub: bool,
    };
    
    pub const ImplDecl = struct {
        trait: ?TypeExpr,      // None for inherent impl
        self_type: TypeExpr,
        generics: ?[]const TypeParam,
        methods: []const FnDecl,
    };
    
    pub const Stmt = union(enum) {
        let: LetStmt,
        expr_stmt: ExprStmt,
        return_stmt: ReturnStmt,
        break_stmt: BreakStmt,
        continue_stmt: ContinueStmt,
        block: Block,
        while_loop: WhileLoop,
        for_loop: ForLoop,
    };
    
    pub const LetStmt = struct {
        pattern: Pattern,
        type: ?TypeExpr,
        init: ?Expr,
        is_mut: bool,
    };
    
    pub const ExprStmt = struct {
        expr: Expr,
        has_semicolon: bool,
    };
    
    pub const ReturnStmt = struct {
        value: ?Expr,
    };
    
    pub const BreakStmt = struct {
        value: ?Expr,
    };
    
    pub const WhileLoop = struct {
        condition: Expr,
        body: Block,
        else_block: ?Block,
    };
    
    pub const ForLoop = struct {
        iterator: ForIterator,
        body: Block,
        else_block: ?Block,
    };
    
    pub const ForIterator = union(enum) {
        range: struct { start: Expr, end: Expr, inclusive: bool },
        pattern_in_expr: struct { pattern: Pattern, expr: Expr },
    };
    
    pub const Block = struct {
        stmts: []const Stmt,
        result: ?Expr,
    };
    
    pub const Expr = union(enum) {
        // Literals
        int_literal: u64,
        float_literal: f64,
        string_literal: Token.Index,
        char_literal: u32,
        bool_literal: bool,
        none_literal,
        
        // Identifiers
        identifier: Token.Index,
        
        // Binary operations
        binary: BinaryExpr,
        
        // Unary operations
        unary: UnaryExpr,
        
        // Function call
        call: CallExpr,
        
        // Method call
        method_call: MethodCallExpr,
        
        // Field access
        field_access: FieldAccessExpr,
        
        // Index access
        index: IndexExpr,
        
        // Parenthesized
        paren: *const Expr,
        
        // Block
        block: Block,
        
        // Control flow
        if_expr: IfExpr,
        match_expr: MatchExpr,
        while_expr: WhileExpr,
        for_expr: ForExpr,
        
        // Lambda/closure
        lambda: LambdaExpr,
        
        // Array
        array_literal: ArrayLiteral,
        
        // Struct literal
        struct_literal: StructLiteral,
        
        // Type as expression
        type_expr: TypeExpr,
        
        // Comptime
        comptime_expr: *const Expr,
        
        // Unsafe
        unsafe_expr: *const Expr,
        
        // Question (error propagation)
        try_expr: *const Expr,
        
        pub const BinaryExpr = struct {
            op: BinaryOp,
            lhs: *const Expr,
            rhs: *const Expr,
        };
        
        pub const UnaryExpr = struct {
            op: UnaryOp,
            operand: *const Expr,
        };
        
        pub const CallExpr = struct {
            callee: *const Expr,
            args: []const Expr,
        };
        
        pub const MethodCallExpr = struct {
            receiver: *const Expr,
            method: Token.Index,
            args: []const Expr,
        };
        
        pub const FieldAccessExpr = struct {
            object: *const Expr,
            field: Token.Index,
        };
        
        pub const IndexExpr = struct {
            object: *const Expr,
            index: *const Expr,
        };
        
        pub const IfExpr = struct {
            condition: Expr,
            then_block: Block,
            else_expr: ?*const Expr,
        };
        
        pub const MatchExpr = struct {
            scrutinee: Expr,
            arms: []const MatchArm,
        };
        
        pub const MatchArm = struct {
            pattern: Pattern,
            guard: ?Expr,
            body: Expr,
        };
        
        pub const LambdaExpr = struct {
            params: []const Param,
            captures: []const Capture,
            body: union(enum) { expr: Expr, block: Block },
        };
        
        pub const Capture = struct {
            name: Token.Index,
            is_weak: bool,
        };
        
        pub const ArrayLiteral = struct {
            elements: []const Expr,
        };
        
        pub const StructLiteral = struct {
            type: TypeExpr,
            fields: []const FieldInit,
        };
        
        pub const FieldInit = struct {
            name: Token.Index,
            value: Expr,
        };
    };
    
    pub const BinaryOp = enum {
        add, sub, mul, div, mod,
        eq, neq, lt, gt, lte, gte,
        and_op, or_op,
        bit_and, bit_or, bit_xor,
        shift_left, shift_right,
        assign, plus_assign, minus_assign,
        star_assign, slash_assign, percent_assign,
    };
    
    pub const UnaryOp = enum {
        neg, not, bit_not, deref, ref, try_op,
    };
    
    pub const Pattern = union(enum) {
        wildcard,
        identifier: Token.Index,
        literal: Expr,
        tuple: []const Pattern,
        struct_: StructPattern,
        enum_: EnumPattern,
        or: []const Pattern,
        at: AtPattern,
        range: RangePattern,
    };
    
    pub const StructPattern = struct {
        type: TypeExpr,
        fields: []const FieldPattern,
    };
    
    pub const FieldPattern = struct {
        name: Token.Index,
        pattern: ?Pattern,
    };
    
    pub const EnumPattern = struct {
        type: ?TypeExpr,
        variant: Token.Index,
        payload: ?Pattern,
    };
    
    pub const AtPattern = struct {
        binding: Token.Index,
        pattern: *const Pattern,
    };
    
    pub const RangePattern = struct {
        start: Expr,
        end: Expr,
        inclusive: bool,
    };
    
    pub const TypeExpr = union(enum) {
        primitive: PrimitiveType,
        named: NamedType,
        function: FunctionType,
        array: ArrayType,
        slice: SliceType,
        optional: *const TypeExpr,
        result: ResultType,
        reference: *const TypeExpr,
        mutable_reference: *const TypeExpr,
        pointer: *const TypeExpr,
        comptime_type: *const TypeExpr,
        type_of: *const Expr,
    };
    
    pub const PrimitiveType = enum {
        i8, i16, i32, i64,
        u8, u16, u32, u64,
        f32, f64,
        bool, string, void, never,
    };
    
    pub const NamedType = struct {
        name: Token.Index,
        generics: ?[]const TypeExpr,
    };
    
    pub const FunctionType = struct {
        params: []const TypeExpr,
        return_type: *const TypeExpr,
    };
    
    pub const ArrayType = struct {
        element: *const TypeExpr,
        size: ?Expr,
    };
    
    pub const SliceType = struct {
        element: *const TypeExpr,
    };
    
    pub const ResultType = struct {
        ok_type: *const TypeExpr,
        err_type: *const TypeExpr,
    };
    
    pub const Attr = struct {
        name: Token.Index,
        args: ?[]const Expr,
    };
    
    pub const ComptimeBlock = struct {
        body: Block,
    };
    
    pub const Import = struct {
        path: []const Token.Index,
        alias: ?Token.Index,
        selective: ?[]const SelectiveImport,
    };
    
    pub const SelectiveImport = struct {
        name: Token.Index,
        alias: ?Token.Index,
    };
};
```

### 3.3 Type System

```zig
pub const Type = union(enum) {
    // Primitives
    primitive: PrimitiveType,
    
    // Named types (user-defined)
    named: NamedTypeId,
    
    // Function type
    function: FunctionType,
    
    // Composite types
    array: ArrayType,
    slice: SliceType,
    optional: *const Type,
    result: ResultType,
    
    // Pointer types
    pointer: PointerType,
    
    // Generic type parameter
    type_param: TypeParamId,
    
    // Type inference variable (unresolved)
    inference_var: InferenceVarId,
    
    // Comptime-known type
    comptime_type: ComptimeTypeId,
    
    // Never type (unreachable)
    never,
    
    pub const PrimitiveType = enum {
        i8, i16, i32, i64,
        u8, u16, u32, u64,
        f32, f64,
        bool, string, void,
    };
    
    pub const NamedTypeId = u32;  // Index into intern pool
    
    pub const FunctionType = struct {
        params: []const Type,
        return_type: *const Type,
        is_variadic: bool,
    };
    
    pub const ArrayType = struct {
        element: *const Type,
        size: u32,
    };
    
    pub const SliceType = struct {
        element: *const Type,
    };
    
    pub const ResultType = struct {
        ok_type: *const Type,
        err_type: *const Type,
    };
    
    pub const PointerType = struct {
        element: *const Type,
        is_mut: bool,
        alignment: ?u32,
    };
    
    pub const TypeParamId = u32;
    pub const InferenceVarId = u32;
    pub const ComptimeTypeId = u32;
};

pub const TypeId = u32;  // Index into type table

pub const TypeTable = struct {
    types: std.ArrayList(Type),
    arena: *std.heap.ArenaAllocator,
    
    pub fn intern(self: *TypeTable, ty: Type) TypeId {
        // Deduplicate types via hashing
        // ...
    }
    
    pub fn resolve(self: *TypeTable, id: TypeId) ?Type {
        // Resolve inference variables
        // ...
    }
};
```

### 3.4 AIR (Astra Intermediate Representation)

```zig
pub const Air = struct {
    instructions: std.MultiArrayList(Inst),
    extra: std.ArrayList(u32),
    values: std.ArrayList(Value),
    types: std.ArrayList(Type),
    arena: *std.heap.ArenaAllocator,
    
    pub const Inst = struct {
        tag: Tag,
        data: Data,
        loc: ?SourceLoc,
        
        pub const Tag = enum(u16) {
            // Debug
            dbg_stmt,
            dbg_var,
            
            // Function
            arg,
            ret,
            
            // Arithmetic (safe)
            add_safe,
            sub_safe,
            mul_safe,
            div_safe,
            mod_safe,
            
            // Arithmetic (unsafe - comptime known no overflow)
            add_unsafe,
            sub_unsafe,
            mul_unsafe,
            
            // Comparison
            cmp_eq,
            cmp_neq,
            cmp_lt,
            cmp_gt,
            cmp_lte,
            cmp_gte,
            
            // Logical
            logical_and,
            logical_or,
            logical_not,
            
            // Bitwise
            bit_and,
            bit_or,
            bit_xor,
            bit_not,
            shift_left,
            shift_right,
            
            // Memory
            load,
            store,
            alloca,
            
            // Control flow
            br,            // Unconditional branch
            br_cond,       // Conditional branch
            phi,           // SSA merge point
            
            // Function call
            call,
            call_indirect,
            
            // Type operations
            trunc,
            zext,
            sext,
            fptrunc,
            fpext,
            fptoui,
            fptosi,
            uitofp,
            sitofp,
            
            // Aggregate operations
            get_field,
            set_field,
            get_element_ptr,
            array_len,
            
            // Option/Result
            optional_some,
            optional_none,
            optional_unwrap,
            result_ok,
            result_err,
            result_unwrap,
            
            // ARC operations
            arc_increment,
            arc_decrement,
            arc_alloc,
            
            // Fiber operations
            yield_point,
            fiber_spawn,
            fiber_resume,
            
            // Comptime
            comptime_block,
            
            // Panic
            panic,
            unreachable_inst,
            
            // Misc
            nop,
            constant,
        };
        
        pub const Data = union(enum) {
            none,
            unary_op: struct { operand: Ref },
            bin_op: struct { lhs: Ref, rhs: Ref },
            tri_op: struct { op1: Ref, op2: Ref, op3: Ref },
            block: struct { body: []const Inst.Index },
            call: struct { callee: Ref, args: []const Ref },
            phi_node: []const Ref,
            constant_value: Value,
            type_operand: Type,
        };
    };
    
    pub const Ref = enum(u32) {
        _,
        
        pub fn index(self: Ref) u32 {
            return @intFromEnum(self);
        }
    };
    
    pub const Value = union(enum) {
        void,
        bool: bool,
        int: i64,
        float: f64,
        string: []const u8,
        null,
        undefined_val,
    };
};
```

### 3.5 Intern Pool

```zig
pub const InternPool = struct {
    strings: std.StringHashMap(u32),
    string_data: std.ArrayList(u8),
    values: std.ArrayList(Value),
    types: std.ArrayList(Type),
    arena: *std.heap.ArenaAllocator,
    
    pub const StringId = u32;
    pub const ValueId = u32;
    pub const TypeId = u32;
    
    pub fn intern_string(self: *InternPool, str: []const u8) StringId {
        if (self.strings.get(str)) |id| {
            return id;
        }
        const new_id: u32 = @intCast(self.string_data.items.len);
        self.string_data.appendSlice(str) catch unreachable;
        self.strings.put(str, new_id) catch unreachable;
        return new_id;
    }
    
    pub fn get_string(self: *InternPool, id: StringId) []const u8 {
        // Return string slice from string_data
        // ...
    }
};
```

---

## 4. Algorithm Choices

### 4.1 Type Inference: Hindley-Milner with Constraint Generation

The type checker uses a bidirectional type inference algorithm combining Hindley-Milner with constraint generation:

```zig
pub const TypeChecker = struct {
    ctx: *Context,
    constraints: std.ArrayList(Constraint),
    substitutions: std.AutoHashMap(TypeVarId, Type),
    
    pub const Constraint = union(enum) {
        equal: struct { left: Type, right: Type },
        has_field: struct { object: Type, field: StringId, field_type: Type },
        has_method: struct { object: Type, method: StringId, method_type: Type },
        satisfies_bound: struct { type: Type, bound: TraitId },
        numeric_literal: struct { var_id: TypeVarId, context: TypeContext },
    };
    
    pub fn infer(self: *TypeChecker, node: *const Node) !Type {
        return switch (node.*) {
            .expr => |e| self.infer_expr(e),
            .stmt => |s| self.infer_stmt(s),
            // ...
        };
    }
    
    fn infer_expr(self: *TypeChecker, expr: *const Node.Expr) !Type {
        return switch (expr.*) {
            .int_literal => |val| self.infer_int_literal(val),
            .binary => |bin| self.infer_binary(bin),
            .call => |call| self.infer_call(call),
            // ...
        };
    }
    
    fn infer_binary(self: *TypeChecker, bin: Node.Expr.BinaryExpr) !Type {
        const lhs_type = try self.infer_expr(bin.lhs);
        const rhs_type = try self.infer_expr(bin.rhs);
        
        // Generate constraint: lhs_type == rhs_type
        try self.constraints.append(.{ .equal = .{ .left = lhs_type, .right = rhs_type } });
        
        // Return type depends on operator
        return switch (bin.op) {
            .add, .sub, .mul, .div, .mod => lhs_type,
            .eq, .neq, .lt, .gt, .lte, .gte => Type.primitive(.bool),
            .and_op, .or_op => Type.primitive(.bool),
            // ...
        };
    }
};
```

### 4.2 Monomorphization

Generic functions are specialized at compile-time using a worklist algorithm:

```zig
pub const Monomorphizer = struct {
    worklist: std.ArrayList(SpecializationTask),
    specialized: std.AutoHashMap(SpecializationKey, FunctionId>,
    intern_pool: *InternPool,
    
    pub const SpecializationTask = struct {
        generic_fn: FunctionId,
        type_args: []const Type,
        call_site: SourceLoc,
    };
    
    pub const SpecializationKey = struct {
        generic_fn: FunctionId,
        type_args: []const Type,
    };
    
    pub fn specialize(self: *Monomorphizer, task: SpecializationTask) !FunctionId {
        const key = SpecializationKey{
            .generic_fn = task.generic_fn,
            .type_args = task.type_args,
        };
        
        if (self.specialized.get(key)) |existing| {
            return existing;
        }
        
        // Create new function with substituted types
        const specialized_fn = try self.create_specialized_fn(task);
        try self.specialized.put(key, specialized_fn);
        
        // Add body to worklist for further specialization
        try self.worklist.append(.{
            .generic_fn = specialized_fn,
            .type_args = task.type_args,
            .call_site = task.call_site,
        });
        
        return specialized_fn;
    }
    
    fn create_specialized_fn(self: *Monomorphizer, task: SpecializationTask) !FunctionId {
        // 1. Clone generic function AST
        // 2. Substitute type parameters with concrete types
        // 3. Update type annotations
        // 4. Return new function ID
        // ...
    }
};
```

### 4.3 Trait Resolution

Traits are resolved using a dictionary-passing approach for dynamic dispatch and monomorphization for static dispatch:

```zig
pub const TraitResolver = struct {
    implementations: std.AutoHashMap(TraitImplKey, ImplId>,
    witness_tables: std.AutoHashMap(TraitImplKey, WitnessTable>,
    
    pub const TraitImplKey = struct {
        trait_id: TraitId,
        self_type: Type,
    };
    
    pub const ImplId = u32;
    
    pub const WitnessTable = struct {
        methods: []const FunctionId,
        associated_types: []const Type,
    };
    
    pub fn resolve_impl(self: *TraitResolver, trait_id: TraitId, self_type: Type) !ImplId {
        const key = TraitImplKey{
            .trait_id = trait_id,
            .self_type = self_type,
        };
        
        return self.implementations.get(key) orelse return error.TraitNotImplemented;
    }
    
    pub fn get_witness_table(self: *TraitResolver, trait_id: TraitId, self_type: Type) !*WitnessTable {
        const key = TraitImplKey{
            .trait_id = trait_id,
            .self_type = self_type,
        };
        
        return self.witness_tables.get(key) orelse return error.WitnessTableNotFound;
    }
    
    pub fn check_trait_bounds(self: *TraitResolver, type_args: []const Type, bounds: []const TraitBound) !void {
        for (bounds) |bound| {
            for (type_args) |type_arg| {
                _ = try self.resolve_impl(bound.trait_id, type_arg);
            }
        }
    }
};
```

### 4.4 Borrow Checker (Optional Phase 2+)

A lightweight borrow checker for safe memory access:

```zig
pub const BorrowChecker = struct {
    scopes: std.ArrayList(Scope),
    borrows: std.ArrayList(Borrow),
    
    pub const Scope = struct {
        parent: ?usize,
        borrows: std.ArrayList(BorrowId),
    };
    
    pub const Borrow = struct {
        variable: VariableId,
        kind: Kind,
        start_pc: u32,
        end_pc: ?u32,
        
        pub const Kind = enum {
            immutable,   // &T
            mutable,     // &mut T
        };
    };
    
    pub fn check_function(self: *BorrowChecker, func: *const Function) !void {
        // 1. Build control flow graph
        // 2. Compute borrow lifetimes
        // 3. Check for conflicting borrows
        // 4. Check for use-after-free
        // ...
    }
    
    fn check_conflicts(self: *BorrowChecker, b1: Borrow, b2: Borrow) bool {
        // Two borrows conflict if:
        // - At least one is mutable
        // - Their lifetimes overlap
        // - They refer to the same variable
        // ...
    }
};
```

---

## 5. LLVM Integration

### 5.1 LLVM C API Wrapper

The compiler uses LLVM's C API via Zig's `@cImport` for seamless interop:

```zig
const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/BitWriter.h");
    @cInclude("llvm-c/Transforms/PassBuilder.h");
    @cInclude("llvm-c/TargetMachine.h");
});

pub const LLVMBackend = struct {
    context: c.LLVMContextRef,
    module: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,
    target_machine: c.LLVMTargetMachineRef,
    func_map: std.AutoHashMap(FunctionId, c.LLVMValueRef),
    
    pub fn init(target_triple: []const u8) !LLVMBackend {
        const ctx = c.LLVMContextCreate();
        const module = c.LLVMModuleCreateWithNameInContext("astra", ctx);
        const builder = c.LLVMCreateBuilderInContext(ctx);
        
        // Initialize target
        c.LLVMInitializeAllTargetInfos();
        c.LLVMInitializeAllTargets();
        c.LLVMInitializeAllTargetMCs();
        c.LLVMInitializeAllAsmParsers();
        c.LLVMInitializeAllAsmPrinters();
        
        var error_msg: ?[*:0]u8 = null;
        const target = c.LLVMGetTargetFromTriple(
            @ptrCast(target_triple.ptr),
            &target,
            &error_msg,
        );
        
        const target_machine = c.LLVMCreateTargetMachine(
            target,
            @ptrCast(target_triple.ptr),
            "generic",
            "",
            c.LLVMCodeGenLevelDefault,
            c.LLVMRelocDefault,
            c.LLVMCodeModelDefault,
        );
        
        return .{
            .context = ctx,
            .module = module,
            .builder = builder,
            .target_machine = target_machine,
            .func_map = std.AutoHashMap(FunctionId, c.LLVMValueRef).init(allocator),
        };
    }
    
    pub fn emit_to_file(self: *LLVMBackend, filename: []const u8, output_type: OutputType) !void {
        var error_msg: ?[*:0]u8 = null;
        
        switch (output_type) {
            .object => {
                c.LLVMTargetMachineEmitToFile(
                    self.target_machine,
                    self.module,
                    @ptrCast(filename.ptr),
                    c.LLVMObjectFile,
                    &error_msg,
                );
            },
            .assembly => {
                c.LLVMTargetMachineEmitToFile(
                    self.target_machine,
                    self.module,
                    @ptrCast(filename.ptr),
                    c.LLVMAssemblyFile,
                    &error_msg,
                );
            },
            .bitcode => {
                c.LLVMWriteBitcodeToFile(self.module, @ptrCast(filename.ptr));
            },
        }
        
        if (error_msg) |msg| {
            defer c.LLVMDisposeMessage(msg);
            return error.LLVMError;
        }
    }
    
    pub fn optimize(self: *LLVMBackend, level: OptimizationLevel) !void {
        const pass_builder = c.LLVMCreatePassBuilder();
        defer c.LLVMDisposePassBuilder(pass_builder);
        
        const pipeline = switch (level) {
            .none => c.LLVMCreatePassBuilderOptions(),
            .default => c.LLVMCreatePassBuilderOptions(),
            .aggressive => c.LLVMCreatePassBuilderOptions(),
        };
        defer c.LLVMDisposePassBuilderOptions(pipeline);
        
        var error_msg: ?[*:0]u8 = null;
        c.LLVMRunPasses(
            self.module,
            "default<O2>",  // Pass pipeline string
            self.target_machine,
            pipeline,
            &error_msg,
        );
        
        if (error_msg) |msg| {
            defer c.LLVMDisposeMessage(msg);
            return error.LLVMError;
        }
    }
    
    pub fn codegen_function(self: *LLVMBackend, func: *const Function, air: *const Air) !c.LLVMValueRef {
        // 1. Create LLVM function
        // 2. Create entry basic block
        // 3. Lower AIR instructions to LLVM IR
        // 4. Return function value
        // ...
    }
};
```

### 5.2 AIR to LLVM IR Lowering

```zig
pub fn lower_air_to_llvm(self: *LLVMBackend, air: *const Air) !void {
    // Process each function in the AIR
    for (air.functions) |func_id| {
        const func = air.get_function(func_id);
        const llvm_fn = try self.codegen_function(func, air);
        try self.func_map.put(func_id, llvm_fn);
    }
    
    // Process global initializers
    for (air.globals) |global| {
        try self.codegen_global(global);
    }
}

fn codegen_inst(self: *LLVMBackend, inst: Air.Inst) !c.LLVMValueRef {
    return switch (inst.tag) {
        .add_safe => {
            const lhs = try self.get_value(inst.data.bin_op.lhs);
            const rhs = try self.get_value(inst.data.bin_op.rhs);
            return c.LLVMBuildAdd(self.builder, lhs, rhs, "add");
        },
        .cmp_eq => {
            const lhs = try self.get_value(inst.data.bin_op.lhs);
            const rhs = try self.get_value(inst.data.bin_op.rhs);
            return c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, lhs, rhs, "cmp");
        },
        .br => {
            const target = try self.get_block(inst.data.block);
            return c.LLVMBuildBr(self.builder, target);
        },
        .br_cond => {
            const cond = try self.get_value(inst.data.tri_op.op1);
            const then_bb = try self.get_block(inst.data.tri_op.op2);
            const else_bb = try self.get_block(inst.data.tri_op.op3);
            return c.LLVMBuildCondBr(self.builder, cond, then_bb, else_bb);
        },
        .call => {
            const callee = try self.get_value(inst.data.call.callee);
            var args = try self.get_values(inst.data.call.args);
            return c.LLVMBuildCall(self.builder, callee, args.ptr, @intCast(args.len), "call");
        },
        // ... more instructions
    };
}
```

### 5.3 Target Triple Support

| Platform | Target Triple | Notes |
|:---------|:--------------|:------|
| Linux x86_64 | `x86_64-unknown-linux-musl` | Static binary recommended |
| Linux ARM64 | `aarch64-unknown-linux-musl` | For embedded/ARM |
| macOS ARM64 | `aarch64-apple-darwin` | Universal binary |
| macOS x86_64 | `x86_64-apple-darwin` | Intel Macs |
| Windows x86_64 | `x86_64-pc-windows-msvc` | MSVC ABI |
| WebAssembly | `wasm32-wasi` | For plugins/browser |
| Android ARM64 | `aarch64-unknown-linux-android21` | API 21+ |

---

## 6. Error Handling Strategy

### 6.1 Zig Error Unions

All compiler operations return error unions for type-safe error handling:

```zig
pub const CompilerError = error{
    // Lexer errors
    InvalidCharacter,
    UnterminatedString,
    InvalidUnicode,
    
    // Parser errors
    UnexpectedToken,
    UnterminatedExpression,
    InvalidPattern,
    TooManyArguments,
    
    // Semantic errors
    UndefinedVariable,
    UndefinedType,
    TypeMismatch,
    DuplicateDeclaration,
    MissingImplementation,
    TraitNotImplemented,
    
    // Codegen errors
    UnreachableCode,
    InvalidCast,
    Overflow,
    
    // LLVM errors
    LLVMError,
    CodeGenerationFailed,
    
    // Memory errors
    OutOfMemory,
};

pub fn compile(options: Options) CompilerError!CompilationResult {
    // ...
}
```

### 6.2 Diagnostic System

```zig
pub const Diagnostic = struct {
    level: Level,
    message: []const u8,
    location: ?SourceLoc,
    notes: []const Note,
    fixits: []const Fixit,
    
    pub const Level = enum {
        @"error",
        warning,
        note,
        help,
    };
    
    pub const Note = struct {
        message: []const u8,
        location: SourceLoc,
    };
    
    pub const Fixit = struct {
        location: SourceLoc,
        replacement: []const u8,
        label: []const u8,
    };
};

pub const DiagnosticEngine = struct {
    diagnostics: std.ArrayList(Diagnostic),
    arena: *std.heap.ArenaAllocator,
    has_errors: bool,
    
    pub fn report(self: *DiagnosticEngine, diag: Diagnostic) void {
        self.diagnostics.append(diag) catch unreachable;
        if (diag.level == .@"error") {
            self.has_errors = true;
        }
    }
    
    pub fn format(self: *DiagnosticEngine, writer: anytype) void {
        for (self.diagnostics.items) |diag| {
            self.format_diagnostic(writer, diag);
        }
    }
    
    fn format_diagnostic(self: *DiagnosticEngine, writer: anytype, diag: Diagnostic) void {
        // Format with colors, line numbers, context, fixits
        // ...
    }
};
```

### 6.3 Error Recovery in Parser

The parser uses panic-mode recovery to continue after errors:

```zig
pub const RecoverySet = struct {
    tokens: std.AutoHashMap(Token.Tag, void),
    
    pub fn init() RecoverySet {
        var set = RecoverySet{ .tokens = std.AutoHashMap(Token.Tag, void).init(allocator) };
        // Synchronization tokens
        set.tokens.put(.semicolon, {}) catch unreachable;
        set.tokens.put(.rbrace, {}) catch unreachable;
        set.tokens.put(.fn_kw, {}) catch unreachable;
        set.tokens.put(.let_kw, {}) catch unreachable;
        set.tokens.put(.return_kw, {}) catch unreachable;
        set.tokens.put(.eof, {}) catch unreachable;
        return set;
    }
};

pub fn parse_statement(self: *Parser) ParseError!Stmt {
    self.synchronize_tokens = RecoverySet.init();
    
    return self.parse_statement_inner() catch |err| {
        // Report error
        self.diagnostics.report(.{
            .level = .@"error",
            .message = @errorName(err),
            .location = self.current_token.loc,
        });
        
        // Skip to synchronization point
        self.skip_to_sync_point();
        
        // Return dummy statement
        return .{ .expr_stmt = .{ .expr = .{ .none_literal = {} } } };
    };
}
```

---

## 7. Memory Management

### 7.1 Arena Allocator Strategy

The compiler uses arena allocators for each compilation phase:

```zig
pub const CompilationContext = struct {
    // Per-phase arenas
    parse_arena: std.heap.ArenaAllocator,
    sema_arena: std.heap.ArenaAllocator,
    air_arena: std.heap.ArenaAllocator,
    codegen_arena: std.heap.ArenaAllocator,
    
    // General purpose allocator for long-lived data
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    
    pub fn init() CompilationContext {
        return .{
            .parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .sema_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .air_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .codegen_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .gpa = std.heap.GeneralPurposeAllocator(.{}){},
        };
    }
    
    pub fn deinit(self: *CompilationContext) void {
        // Free all arenas in reverse order
        self.codegen_arena.deinit();
        self.air_arena.deinit();
        self.sema_arena.deinit();
        self.parse_arena.deinit();
        _ = self.gpa.deinit();
    }
    
    pub fn parse_allocator(self: *CompilationContext) std.mem.Allocator {
        return self.parse_arena.allocator();
    }
    
    pub fn sema_allocator(self: *CompilationContext) std.mem.Allocator {
        return self.sema_arena.allocator();
    }
    
    pub fn reset_parse(self: *CompilationContext) void {
        // Reset parse arena for incremental compilation
        _ = self.parse_arena.reset(.retain_capacity);
    }
};
```

### 7.2 Memory Layout for Astra Objects

```
ARC Object:
┌──────────┬──────────┬──────────────────┐
│ refcount │ weak_cnt │ object data...   │
│ (i64)    │ (i64)    │                  │
└──────────┴──────────┴──────────────────┘

ORC Object (Cycle-Detectable):
┌──────────┬──────────┬──────────┬──────┬──────────────────┐
│ refcount │ weak_cnt │ marked   │color │ object data...   │
│ (i64)    │ (i64)    │ (bool)   │(u8)  │                  │
└──────────┴──────────┴──────────┴──────┴──────────────────┘

String (UTF-8, Immutable):
┌──────────┬──────────┬──────────────────┐
│ length   │ capacity │ bytes...         │
│ (usize)  │ (usize)  │                  │
└──────────┴──────────┴──────────────────┘

Array (Contiguous):
┌──────────┬──────────┬──────────────────┐
│ length   │ capacity │ elements...      │
│ (usize)  │ (usize)  │                  │
└──────────┴──────────┴──────────────────┘
```

---

## 8. Testing Strategy

### 8.1 Test Pyramid

```
                    /\
                   /  \
                  / Fuzz\          <- Long-running, find rare bugs
                 /--------\
                / Property  \       <- Test invariants across inputs
               /--------------\
              / Differential    \    <- Compare with other compilers
             /--------------------\
            / Regression/Conform.  \  <- Catch known bugs, spec compliance
           /------------------------\
          / Unit Tests               \ <- Test individual components
         /------------------------------\
```

### 8.2 Test Structure

```
tests/
├── conformance/           # Language specification tests
│   ├── expressions/       # Expression evaluation
│   ├── statements/        # Control flow
│   ├── types/             # Type system
│   ├── modules/           # Module system
│   ├── generics/          # Generic functions
│   ├── traits/            # Trait implementations
│   └── stdlib/            # Standard library
├── ui/                    # Error message tests
│   ├── compile_error/     # Expected compile errors
│   └── runtime_error/     # Expected runtime errors
├── codegen/               # Generated code checks
│   ├── assembly/          # Assembly output verification
│   └── optimization/      # Optimization effectiveness
├── incr/                  # Incremental compilation
├── cross/                 # Cross-compilation tests
├── property/              # Property-based tests
└── fuzz/                  # Fuzzing corpora
```

### 8.3 Differential Testing

Compare output between VM and LLVM backends:

```bash
#!/bin/bash
# differential_test.sh
for file in tests/conformance/**/*.astra; do
    # Run with VM
    ./astra run "$file" > /tmp/out_vm.txt 2>&1
    vm_exit=$?
    
    # Run with LLVM
    ./astra build --release "$file" -o /tmp/test_bin
    /tmp/test_bin > /tmp/out_llvm.txt 2>&1
    llvm_exit=$?
    
    # Compare
    if [ $vm_exit -ne $llvm_exit ]; then
        echo "MISMATCH: $file (VM=$vm_exit, LLVM=$llvm_exit)"
    elif ! diff -q /tmp/out_vm.txt /tmp/out_llvm.txt > /dev/null; then
        echo "OUTPUT DIFF: $file"
    fi
done
```

### 8.4 Property-Based Testing

```zig
test "addition is commutative" {
    const testing = std.testing;
    
    var rng = std.rand.DefaultPrng.init(0);
    const random = rng.random();
    
    for (0..1000) |_| {
        const a = random.int(i64);
        const b = random.int(i64);
        
        const result1 = try compile_and_run(&.{ .int = a }, &.{ .int = b }, "add");
        const result2 = try compile_and_run(&.{ .int = b }, &.{ .int = a }, "add");
        
        try testing.expectEqual(result1, result2);
    }
}
```

### 8.5 Fuzzing Targets

```zig
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) c_int {
    const input = data[0..size];
    
    // Fuzz lexer
    var lexer = Lexer.init(input);
    while (lexer.next_token()) |_| {}
    
    // Fuzz parser (if valid tokens)
    if (valid_tokens) {
        var parser = Parser.init(tokens);
        _ = parser.parse() catch return 0;
    }
    
    return 0;
}
```

---

## 9. Implementation Plan

### 9.1 Phase 2.1: Foundation (Months 1-3)

| Week | Task | Deliverable |
|:-----|:-----|:------------|
| 1-2 | Project setup, build.zig, basic lexer | Tokenizer working |
| 3-4 | Token types, keyword table | All Astra-0 tokens |
| 5-6 | Recursive descent parser core | Statement parsing |
| 7-8 | Pratt expression parser | Expression parsing |
| 9-10 | AST node definitions | Full AST for Astra-0 |
| 11-12 | Error recovery | Parser never crashes |

### 9.2 Phase 2.2: Semantic Analysis (Months 4-6)

| Week | Task | Deliverable |
|:-----|:-----|:------------|
| 13-14 | Name resolver, scoping | Variable resolution |
| 15-16 | Type checker core | Basic type inference |
| 17-18 | Type unification | Type constraint solving |
| 19-20 | Function type checking | Call validation |
| 21-22 | Pattern type checking | Match exhaustiveness |
| 23-24 | Error diagnostics | Helpful error messages |

### 9.3 Phase 2.3: AIR + VM Backend (Months 7-9)

| Week | Task | Deliverable |
|:-----|:-----|:------------|
| 25-26 | AIR instruction definitions | AIR format complete |
| 27-28 | AIR builder | AST → AIR lowering |
| 29-30 | ARC insertion | Reference counting |
| 31-32 | VM bytecode emission | Bytecode generation |
| 33-34 | VM execution engine | Running Astra programs |
| 35-36 | Pass all 89 tests | Compatibility achieved |

### 9.4 Phase 2.4: LLVM Backend (Months 10-12)

| Week | Task | Deliverable |
|:-----|:-----|:------------|
| 37-38 | LLVM C API integration | Basic codegen |
| 39-40 | Function codegen | Function emission |
| 41-42 | Control flow codegen | If/else, loops |
| 43-44 | Aggregate codegen | Structs, arrays |
| 45-46 | ARC codegen | Reference counting |
| 47-48 | Optimization passes | O0, O1, O2 |

### 9.5 Phase 2.5: New Features (Months 13-18)

| Month | Feature | Complexity |
|:------|:--------|:-----------|
| 13 | Generics syntax + parsing | Medium |
| 14 | Generic type checking | High |
| 15 | Monomorphization | High |
| 16 | Traits syntax + parsing | Medium |
| 17 | Trait resolution | High |
| 18 | Comptime evaluation | Very High |

### 9.6 Phase 2.6: Runtime + Polish (Months 19-24)

| Month | Feature | Complexity |
|:------|:--------|:-----------|
| 19 | ARC/ORC runtime | High |
| 20 | Fiber scheduler | Very High |
| 21 | Async I/O | High |
| 22 | Standard library basics | Medium |
| 23 | Package manager | Medium |
| 24 | Bootstrap self-compilation | High |

---

## Appendix A: Comparison with Zig Compiler Architecture

| Aspect | Zig Compiler | Astra Phase 2 | Rationale |
|:-------|:-------------|:---------------|:----------|
| **IR Count** | 3 (ZIR, AIR, MIR) | 2 (AIR, LLVM IR) | Simpler pipeline |
| **Type System** | Simple generics | Hindley-Milner + traits | More expressive |
| **Comptime** | Built-in | Optional, Zig-style | Inherited from Zig |
| **Memory** | Manual allocators | Arena + ARC/ORC | Safety + performance |
| **Backend** | Multiple (LLVM, self-hosted, C) | LLVM + VM | Focus on quality |
| **Incremental** | In-place binary patching | Query-based memoization | Simpler initially |

---

## Appendix B: Risk Mitigation

| Risk | Likelihood | Impact | Mitigation |
|:-----|:-----------|:-------|:-----------|
| Zig pre-1.0 instability | Medium | High | Pin Zig version, test with each release |
| LLVM API changes | Medium | Medium | Pin LLVM version, use stable C API |
| Type inference complexity | High | High | Start simple, add features incrementally |
| ARC/ORC correctness | High | High | Extensive testing, formal verification |
| Fiber scheduler bugs | Medium | High | Use proven M:N scheduling algorithms |
| Self-compilation failure | Medium | Critical | Incremental self-hosting, test each feature |

---

*This document is the authoritative reference for Phase 2 implementation. Update it as implementation progresses and design decisions are finalized.*
