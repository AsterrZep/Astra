# Astra Phase 2: Zig Compiler — Practical Implementation Plan

> **Version**: 0.1
> **Status**: Plan
> **Date**: 2026-09-21
> **Prerequisite**: Phase 1 seed compiler (`seed/`) — see `PHASE1_PROGRESS.md`

---

## Table of Contents

1. [Overview](#1-overview)
2. [Build System (`build.zig`)](#2-build-system)
3. [Module Structure (`src/` layout)](#3-module-structure)
4. [Core Data Structures](#4-core-data-structures)
5. [Lexer Implementation](#5-lexer-implementation)
6. [Parser Implementation](#6-parser-implementation)
7. [Type Checker Implementation](#7-type-checker-implementation)
8. [Emitter + Bytecode](#8-emitter--bytecode)
9. [VM Implementation](#9-vm-implementation)
10. [LLVM Backend](#10-llvm-backend)
11. [Testing Strategy](#11-testing-strategy)
12. [Development Workflow](#12-development-workflow)
13. [Estimated Effort](#13-estimated-effort)
14. [Migration Notes: C → Zig](#14-migration-notes)

---

## 1. Overview

Phase 2 replaces the C seed compiler with a Zig self-hosting compiler. The Zig
compiler compiles **full Astra** (Astra-1): generics, traits, comptime, ARC/ORC,
fibers, and both a bytecode VM backend (development) and an LLVM backend
(production).

The compiler is built with `zig build` and follows the standard Zig project
conventions (0.16.x): `build.zig` + `build.zig.zon`, one-file-per-module, arena
allocators, comptime-known tables.

### Design Principles

| Principle | Rationale |
|:----------|:----------|
| **Port the seed's architecture** | The C seed's pipeline (Lexer→Parser→TypeCheck→Emit→VM) is proven. Zig's type system makes it safer. |
| **Arena-first allocation** | Compilers allocate millions of small objects. Arena = bulk free. Use `std.heap.ArenaAllocator`. |
| **No hidden allocations** | Every allocator is explicit. The `Allocator` parameter is threaded through every function. |
| **Zero-cost abstractions** | Sum types (tagged unions), optional types, and error unions replace C's manual patterns. |
| **Comptime for static tables** | Keyword tables, operator precedence, opcode metadata — all computed at comptime. |
| **C interop for LLVM** | `@cImport` for LLVM C API headers. No FFI layer needed. |

---

## 2. Build System (`build.zig`)

### 2.1 `build.zig.zon`

```zig
.{
    .name = .astra_compiler,
    .version = "0.1.0",
    .fingerprint = 0xa57a_0001_0001_0001, // generated with `zig fetch`
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        // No external dependencies for Phase 2 MVP.
        // LLVM is linked via system library (see build.zig).
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "tests",
        "LICENSE",
        "README.md",
    },
}
```

### 2.2 `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Options ──────────────────────────────────────────────
    const enable_llvm = b.option(bool, "enable-llvm",
        "Enable LLVM backend (default: true)") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_llvm", enable_llvm);

    // ── Main executable ──────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "astra",
        .root_module = exe_mod,
    });

    if (enable_llvm) {
        exe.linkSystemLibrary("llvm");
        exe.linkSystemLibrary("clang");
        exe.linkSystemLibrary("lldCore");
        exe.linkLibCpp();
    }

    b.installArtifact(exe);

    // ── Run step ─────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Astra compiler");
    run_step.dependOn(&run_cmd.step);

    // ── Unit tests ───────────────────────────────────────────
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addOptions("build_options", build_options);

    if (enable_llvm) {
        unit_tests.linkSystemLibrary("llvm");
        unit_tests.linkSystemLibrary("clang");
        unit_tests.linkLibCpp();
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ── Integration tests ────────────────────────────────────
    const int_tests = b.addTest(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    int_tests.root_module.addOptions("build_options", build_options);
    int_tests.root_module.addImport("astra", exe_mod);

    const run_int_tests = b.addRunArtifact(int_tests);
    const int_test_step = b.step("test-integration", "Run integration tests");
    int_test_step.dependOn(&run_int_tests.step);

    // ── Conformance tests (run .astra files through the compiler) ──
    const conformance_step = b.addTest(.{
        .root_source_file = b.path("tests/conformance.zig"),
        .target = target,
        .optimize = optimize,
    });
    conformance_step.root_module.addOptions("build_options", build_options);
    conformance_step.root_module.addImport("astra", exe_mod);

    const run_conformance = b.addRunArtifact(conformance_step);
    const conformance_step_cmd = b.step("test-conformance",
        "Run Astra conformance tests");
    conformance_step_cmd.dependOn(&run_conformance.step);
}
```

### 2.3 Build commands

```bash
cd zig/
zig build                          # debug build
zig build -Doptimize=ReleaseFast   # optimized
zig build -Denable-llvm=false      # VM-only (no LLVM)
zig build test                     # unit tests
zig build test-integration         # integration tests
zig build test-conformance         # conformance suite
zig build run -- file.astra        # run compiler on a file
```

---

## 3. Module Structure (`src/` layout)

Every `.zig` file is a module. The root module (`src/root.zig`) re-exports the
public API for library consumers (and tests).

```
zig/
├── build.zig
├── build.zig.zon
├── src/
│   ├── root.zig                  # library root (re-exports for tests)
│   ├── main.zig                  # CLI entry point
│   │
│   ├── common/
│   │   ├── Allocator.zig         # allocator traits/helpers
│   │   ├── Arena.zig             # arena allocator wrapper
│   │   ├── StringTable.zig       # string interning
│   │   ├── SrcLoc.zig            # source location type
│   │   ├── diagnostics.zig       # error/warning reporting
│   │   └── InternedString.zig    # interned string type
│   │
│   ├── lexer/
│   │   ├── Lexer.zig             # tokenizer
│   │   ├── Token.zig             # TokenKind enum + Token struct
│   │   └── keywords.zig          # comptime keyword table
│   │
│   ├── ast/
│   │   ├── Node.zig              # AST node types (tagged unions)
│   │   ├── NodeKind.zig          # NodeKind enum
│   │   └── pretty_print.zig      # AST dump for --dump-ast
│   │
│   ├── parser/
│   │   ├── Parser.zig            # recursive descent + Pratt
│   │   ├── precedence.zig        # comptime operator precedence table
│   │   └── errors.zig            # parser error recovery
│   │
│   ├── typechecker/
│   │   ├── TypeChecker.zig       # main checker driver
│   │   ├── Type.zig              # type representation
│   │   ├── TypeKind.zig          # type kind enum
│   │   ├── SymbolTable.zig       # scoped symbol table
│   │   └── unify.zig             # type unification / coercion
│   │
│   ├── emitter/
│   │   ├── Emitter.zig           # AST → bytecode emitter
│   │   ├── OpCode.zig            # opcode enum + metadata
│   │   └── JumpPatch.zig         # loop/conditional jump patching
│   │
│   ├── vm/
│   │   ├── VM.zig                # stack-based virtual machine
│   │   ├── Value.zig             # runtime value type
│   │   ├── ValueKind.zig         # value kind enum
│   │   ├── CallFrame.zig         # function call frame
│   │   └── Builtins.zig          # print, etc.
│   │
│   ├── codegen/
│   │   ├── Codegen.zig           # C code generation (--emit-c)
│   │   └── runtime_header.zig    # codegen_runtime.h equivalent
│   │
│   └── llvm_backend/
│       ├── Backend.zig           # LLVM backend driver
│       ├── Module.zig            # LLVM module wrapper
│       ├── Function.zig          # LLVM function builder
│       ├── IRBuilder.zig         # LLVM IR builder wrapper
│       └── Target.zig            # target triple + data layout
│
├── tests/
│   ├── integration.zig           # integration test runner
│   ├── conformance.zig           # conformance test runner
│   ├── conformance/              # .astra test files (shared with seed/)
│   └── unit/                     # per-module unit tests
│       ├── lexer_test.zig
│       ├── parser_test.zig
│       ├── typechecker_test.zig
│       ├── emitter_test.zig
│       └── vm_test.zig
```

### Module imports

```zig
// Example: main.zig imports
const Lexer = @import("lexer/Lexer.zig");
const Parser = @import("parser/Parser.zig");
const TypeChecker = @import("typechecker/TypeChecker.zig");
const Emitter = @import("emitter/Emitter.zig");
const VM = @import("vm/VM.zig");
```

---

## 4. Core Data Structures

### 4.1 Source Location (`common/SrcLoc.zig`)

```zig
pub const SrcLoc = struct {
    filename: []const u8,
    line: u32,
    column: u32,
    offset: u32,

    pub fn init(filename: []const u8, line: u32, column: u32, offset: u32) SrcLoc {
        return .{ .filename = filename, .line = line, .column = column, .offset = offset };
    }

    pub fn format(self: SrcLoc, comptime _: []const u8, _: anytype, writer: anytype) !void {
        try writer.print("{s}:{d}:{d}", .{ self.filename, self.line, self.column });
    }
};
```

### 4.2 String Interning (`common/StringTable.zig`)

```zig
const std = @import("std");

pub const InternedString = struct {
    ptr: [*:0]const u8,
    len: u32,
    hash: u32,

    pub fn eql(a: InternedString, b: InternedString) bool {
        return a.ptr == b.ptr; // pointer comparison for interned strings
    }

    pub fn slice(self: InternedString) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const StringTable = struct {
    arena: *std.heap.ArenaAllocator,
    map: std.HashMapUnmanaged(InternedString, void, Context, 70),

    const Context = struct {
        pub fn hash(_: Context, s: InternedString) u64 {
            return s.hash;
        }
        pub fn eql(_: Context, a: InternedString, b: InternedString) bool {
            return a.eql(b);
        }
    };

    pub fn init(arena: *std.heap.ArenaAllocator) StringTable {
        return .{ .arena = arena, .map = .{} };
    }

    pub fn intern(self: *StringTable, str: []const u8) InternedString {
        const hash = std.hash.Fnv1a_32.hash(str);
        const key = InternedString{
            .ptr = str.ptr,
            .len = @intCast(str.len),
            .hash = hash,
        };
        const gop = self.map.getOrPut(self.arena.child_allocator, key) catch unreachable;
        return gop.key_ptr.*;
    }
};
```

### 4.3 Token Types (`lexer/Token.zig`)

```zig
pub const TokenKind = enum(u16) {
    // Literals
    int_literal,
    float_literal,
    string_literal,
    ident,

    // Keywords
    fn_kw, let, var, if_kw, else_kw, while_kw, for_kw, match_kw,
    return_kw, break_kw, continue_kw, struct_kw, enum_kw, trait_kw,
    impl_kw, use_kw, mod_kw, pub_kw, mut_kw, true_kw, false_kw,
    ok_kw, err_kw, and_kw, or_kw, not_kw, comptime_kw, const_kw,
    in_kw, some_kw, none_kw, option_kw, result_kw,

    // Operators
    plus, minus, star, slash, percent,
    eq, eq_eq, neq, lt, gt, le, ge,
    and_and, or_or, bang,
    amp, pipe, caret, tilde, shl, shr,
    arrow, fat_arrow,
    dot, comma, semicolon, colon, colon_colon,
    lparen, rparen, lbracket, rbracket,
    dotdot, dotdot_eq,
    lbrace, rbrace,
    question, underscore,

    // Special
    newline,
    eof,
    error_token,

    pub fn isKeyword(self: TokenKind) bool {
        return @intFromEnum(self) >= @intFromEnum(TokenKind.fn_kw) and
               @intFromEnum(self) <= @intFromEnum(TokenKind.result_kw);
    }
};

pub const Token = struct {
    kind: TokenKind,
    text: InternedString,
    loc: SrcLoc,
    literal: union(enum) {
        none: void,
        int_val: i64,
        float_val: f64,
    } = .{ .none = {} },
};
```

### 4.4 AST Nodes (`ast/Node.zig`)

The C seed uses a tagged union with a `NodeKind` enum. In Zig, we use a
sum type (tagged union) which is exhaustive and zero-cost.

```zig
pub const NodeKind = enum {
    // Expressions
    int_literal, float_literal, string_literal, bool_literal, ident,
    binary_op, unary_op, call, index, array_literal, range,
    struct_literal, field_access,
    some_expr, none_expr, ok_expr, err_expr, try_expr,
    block, if_expr, while_expr, for_expr, match_expr,
    return_expr, break_expr, continue_expr,
    assign, compound_assign,

    // Patterns
    pattern_wildcard, pattern_bind, pattern_variant_bind,
    pattern_builtin_variant, pattern_or,
    payload,

    // Declarations
    fn_decl, lambda, struct_decl, enum_decl, const_decl, var_decl,

    // Types
    type_ident, type_optional, type_array, type_fn,

    // Top-level
    module, use, impl,
};

pub const Node = struct {
    kind: NodeKind,
    loc: SrcLoc,
    data: Data,

    pub const Data = union(NodeKind) {
        int_literal: i64,
        float_literal: f64,
        string_literal: InternedString,
        bool_literal: bool,
        ident: InternedString,

        binary_op: struct { op: BinaryOp, left: *Node, right: *Node },
        unary_op: struct { op: UnaryOp, operand: *Node },
        call: struct { callee: *Node, args: []*Node },
        index: struct { object: *Node, index: *Node },
        array_literal: []*Node,
        range: struct { start: ?*Node, end: ?*Node, inclusive: bool },
        struct_literal: StructLitData,
        field_access: struct { object: *Node, field: InternedString },

        some_expr: *Node,
        none_expr: void,
        ok_expr: *Node,
        err_expr: *Node,
        try_expr: *Node,

        block: BlockData,
        if_expr: struct { cond: *Node, then: *Node, else_block: ?*Node },
        while_expr: struct { cond: *Node, body: *Node },
        for_expr: struct { var_name: InternedString, iter: *Node, body: *Node },
        match_expr: struct { target: *Node, arms: []MatchArm },
        return_expr: ?*Node,
        break_expr: void,
        continue_expr: void,

        assign: struct { target: *Node, value: *Node },
        compound_assign: struct { op: BinaryOp, target: *Node, value: *Node },

        pattern_wildcard: void,
        pattern_bind: InternedString,
        pattern_variant_bind: struct { variant: *Node, bindings: []InternedString },
        pattern_builtin_variant: struct { kind: BuiltinVariant, payload: ?*Node },
        pattern_or: []*Node,

        payload: []PayloadField,

        fn_decl: FnDeclData,
        lambda: LambdaData,
        struct_decl: StructDeclData,
        enum_decl: EnumDeclData,
        const_decl: DeclData,
        var_decl: VarDeclData,

        type_ident: InternedString,
        type_optional: *Node,
        type_array: struct { elem: *Node, size: ?*Node },
        type_fn: struct { param_types: []*Node, return_type: ?*Node },

        module: []*Node,
        use: InternedString,
        impl: void, // placeholder for Phase 2

        pub const StructLitData = struct {
            name: InternedString,
            field_names: []InternedString,
            field_values: []*Node,
        };

        pub const BlockData = struct {
            stmts: []*Node,
            last_expr: ?*Node,
        };

        pub const MatchArm = struct {
            pattern: *Node,
            guard: ?*Node,
            body: *Node,
        };

        pub const FnDeclData = struct {
            name: InternedString,
            params: []InternedString,
            param_types: []*Node,
            return_type: ?*Node,
            body: *Node,
        };

        pub const LambdaData = struct {
            params: []InternedString,
            param_types: []*Node,
            return_type: ?*Node,
            body: *Node,
        };

        pub const StructDeclData = struct {
            name: InternedString,
            field_names: []InternedString,
            field_types: []*Node,
        };

        pub const EnumDeclData = struct {
            name: InternedString,
            variants: []InternedString,
            payloads: []*Node, // NODE_PAYLOAD nodes, parallel to variants
        };

        pub const DeclData = struct {
            name: InternedString,
            type: ?*Node,
            value: ?*Node,
        };

        pub const VarDeclData = struct {
            name: InternedString,
            type: ?*Node,
            value: ?*Node,
            is_mut: bool,
        };

        pub const PayloadField = struct {
            name: InternedString,
            type: *Node,
        };

        pub const BuiltinVariant = enum { ok, err, some, none };
    };

    pub const BinaryOp = enum {
        add, sub, mul, div, mod,
        eq, neq, lt, gt, le, ge,
        @"and", @"or",
        bit_and, bit_or, bit_xor, shl, shr,
    };

    pub const UnaryOp = enum { neg, not, bit_not, ref, deref };
};
```

### 4.5 Type Representation (`typechecker/Type.zig`)

```zig
pub const TypeKind = enum {
    void, @"bool", int, int64, uint32, uint64,
    int_literal, // polymorphic integer literal
    float, string, optional, array, fn_type,
    @"struct", @"enum", nil, unknown, @"error",
};

pub const Type = struct {
    kind: TypeKind,
    data: Data,

    pub const Data = union(TypeKind) {
        void: void,
        @"bool": void,
        int: void,
        int64: void,
        uint32: void,
        uint64: void,
        int_literal: void,
        float: void,
        string: void,
        optional: *Type,
        array: struct { elem: *Type, size: ?*Node },
        fn_type: struct { params: []*Type, ret: ?*Type },
        @"struct": StructData,
        @"enum": EnumData,
        nil: void,
        unknown: void,
        @"error": void,

        pub const StructData = struct {
            name: InternedString,
            fields: []StructField,
        };

        pub const EnumData = struct {
            name: InternedString,
            variants: []InternedString,
            payloads: []VariantLayout,
        };

        pub const StructField = struct {
            name: InternedString,
            type: *Type,
        };

        pub const VariantLayout = struct {
            names: ?[]InternedString, // null when all fields unnamed
            types: []*Type,
            field_count: u32,
        };
    };

    pub fn eql(a: *const Type, b: *const Type) bool {
        if (a.kind != b.kind) {
            // Integer literal coercion
            if (a.kind == .int_literal and isInteger(b.kind)) return true;
            if (b.kind == .int_literal and isInteger(a.kind)) return true;
            return false;
        }
        return switch (a.kind) {
            .optional => a.data.optional.eql(b.data.optional),
            .array => a.data.array.elem.eql(b.data.array.elem),
            .fn_type => blk: {
                if (a.data.fn_type.params.len != b.data.fn_type.params.len) break :blk false;
                for (a.data.fn_type.params, b.data.fn_type.params) |pa, pb| {
                    if (!pa.eql(pb)) break :blk false;
                }
                const a_ret = a.data.fn_type.ret orelse &Type{ .kind = .void, .data = .{ .void = {} } };
                const b_ret = b.data.fn_type.ret orelse &Type{ .kind = .void, .data = .{ .void = {} } };
                break :blk a_ret.eql(b_ret);
            },
            .@"struct" => a.data.@"struct".name.eql(b.data.@"struct".name),
            .@"enum" => a.data.@"enum".name.eql(b.data.@"enum".name),
            else => true,
        };
    }

    fn isInteger(kind: TypeKind) bool {
        return switch (kind) {
            .int, .int64, .uint32, .uint64 => true,
            else => false,
        };
    }
};
```

### 4.6 Bytecode (`emitter/OpCode.zig`)

```zig
pub const OpCode = enum(u8) {
    // Stack
    @"const", pop, dup, swap,

    // Locals
    get_local, set_local,

    // Globals
    get_global, set_global,

    // Arithmetic
    add, sub, mul, div, mod, neg,

    // Comparison
    eq, neq, lt, gt, le, ge,

    // Logical
    @"and", @"or", not,

    // Bitwise
    bit_and, bit_or, bit_xor, shl, shr, bit_not,

    // Control flow
    jump, jump_if_false, jump_if_true,

    // Aggregates
    new_array, index, len,
    new_struct, get_field, set_index, set_field,
    new_enum, get_enum_field,

    // Functions
    call, ret,

    // I/O
    print,

    // Option/Result
    wrap_ok, wrap_err, wrap_some,

    // Special
    halt, try_unwrap, tag_is, unwrap,

    pub fn stackEffect(self: OpCode, operand: u32) i32 {
        return switch (self) {
            .@"const", .dup, .get_local, .get_global => 1,
            .pop => @intCast(-(if (operand == 0) @as(i32, 1) else @as(i32, @intCast(operand)))),
            .set_local, .set_global, .jump_if_false, .jump_if_true,
            .index, .print, .add, .sub, .mul, .div, .mod,
            .eq, .neq, .lt, .gt, .le, .ge,
            .@"and", .@"or", .bit_and, .bit_or, .bit_xor,
            .shl, .shr, .ret => -1,
            .new_array => 1 - @as(i32, @intCast(operand)),
            .new_struct, .call => -@as(i32, @intCast(operand)),
            .swap, .neg, .not, .bit_not, .len, .get_field,
            .jump, .halt => 0,
            .set_field => -1,
            .set_index => -2,
            .get_enum_field, .try_unwrap, .wrap_ok, .wrap_err,
            .wrap_some, .tag_is, .unwrap => 0,
            .new_enum => 0, // special: pops layout + N fields, pushes 1
        };
    }
};

pub const Instruction = struct {
    op: OpCode,
    line: u32,
    arg: union(enum) {
        index: u32,
        offset: i32,
        arg_count: u8,
        none: void,
    },
};
```

### 4.7 Value (VM runtime) (`vm/Value.zig`)

```zig
pub const ValueKind = enum {
    nil, @"bool", int, float, string,
    array, @"struct", struct_def,
    @"enum", enum_data, enum_def,
    @"fn", ok, err, some,
};

pub const Value = struct {
    kind: ValueKind,
    data: Data,

    pub const Data = union(ValueKind) {
        nil: void,
        @"bool": bool,
        int: i64,
        float: f64,
        string: [*:0]const u8, // interned
        array: *ArrayObj,
        @"struct": *StructObj,
        struct_def: *StructDef,
        @"enum": EnumVal,
        enum_data: *EnumObj,
        enum_def: *EnumDef,
        @"fn": *FnObj,
        ok: *Value,
        err: *Value,
        some: *Value,
    };

    pub const EnumVal = struct {
        enum_name: [*:0]const u8,
        variant_name: [*:0]const u8,
    };

    pub const ArrayObj = struct {
        elems: []Value,
        len: usize,
    };

    pub const StructDef = struct {
        name: [*:0]const u8,
        field_names: []const [*:0]const u8,
        field_count: u32,
    };

    pub const StructObj = struct {
        def: *StructDef,
        fields: []Value,
    };

    pub const EnumDef = struct {
        name: [*:0]const u8,
        variants: []VariantDef,
    };

    pub const VariantDef = struct {
        name: ?[*:0]const u8,
        field_names: []const [*:0]const u8,
        field_count: u32,
    };

    pub const EnumObj = struct {
        def: *EnumDef,
        variant: u32,
        fields: []Value,
    };

    pub const FnObj = struct {
        code: []const Instruction,
        constants: []const Value,
        param_count: u8,
        local_count: u8,
    };

    // Constructors
    pub fn nil() Value { return .{ .kind = .nil, .data = .{ .nil = {} } }; }
    pub fn bool_val(b: bool) Value { return .{ .kind = .@"bool", .data = .{ .@"bool" = b } }; }
    pub fn int(i: i64) Value { return .{ .kind = .int, .data = .{ .int = i } }; }
    pub fn float(f: f64) Value { return .{ .kind = .float, .data = .{ .float = f } }; }
    pub fn string(s: [*:0]const u8) Value { return .{ .kind = .string, .data = .{ .string = s } }; }
    // ... other constructors

    pub fn isTruthy(self: Value) bool {
        return switch (self.kind) {
            .nil => false,
            .@"bool" => self.data.@"bool",
            .int => self.data.int != 0,
            .float => self.data.float != 0.0,
            .string => true,
            .ok, .err, .some => true,
            else => true,
        };
    }
};
```

---

## 5. Lexer Implementation

### 5.1 Structure

The lexer is a hand-written scanner (same as the seed). In Zig it becomes a
struct with methods. The keyword table is a `comptime` sorted array for binary
search.

### 5.2 `lexer/Lexer.zig`

```zig
const std = @import("std");
const Token = @import("Token.zig");
const TokenKind = Token.TokenKind;
const SrcLoc = @import("../common/SrcLoc.zig");
const StringTable = @import("../common/StringTable.zig");
const InternedString = StringTable.InternedString;

pub const Lexer = struct {
    filename: []const u8,
    source: []const u8,
    pos: usize,
    line: u32,
    column: u32,
    strings: *StringTable,
    cached: ?Token,
    source_len: usize,

    pub fn init(filename: []const u8, source: []const u8, strings: *StringTable) Lexer {
        return .{
            .filename = filename,
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
            .strings = strings,
            .cached = null,
            .source_len = source.len,
        };
    }

    pub fn next(self: *Lexer) Token {
        if (self.cached) |tok| {
            self.cached = null;
            return tok;
        }
        return self.scanToken();
    }

    pub fn peek(self: *Lexer) Token {
        if (self.cached) |tok| return tok;
        const tok = self.scanToken();
        self.cached = tok;
        return tok;
    }

    fn scanToken(self: *Lexer) Token {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source_len) return self.makeToken(.eof, self.line, self.column, self.pos, "");

        const start_line = self.line;
        const start_col = self.column;
        const start_offset = self.pos;

        const c = self.advance();
        return switch (c) {
            '(' => self.makeToken(.lparen, start_line, start_col, start_offset, "("),
            ')' => self.makeToken(.rparen, start_line, start_col, start_offset, ")"),
            '{' => self.makeToken(.lbrace, start_line, start_col, start_offset, "}"),
            '}' => self.makeToken(.rbrace, start_line, start_col, start_offset, "}"),
            '[' => self.makeToken(.lbracket, start_line, start_col, start_offset, "["),
            ']' => self.makeToken(.rbracket, start_line, start_col, start_offset, "]"),
            ';' => self.makeToken(.semicolon, start_line, start_col, start_offset, ";"),
            ',' => self.makeToken(.comma, start_line, start_col, start_offset, ","),
            '.' => {
                if (self.peekChar() == '.') {
                    _ = self.advance();
                    if (self.peekChar() == '=') {
                        _ = self.advance();
                        return self.makeToken(.dotdot_eq, start_line, start_col, start_offset, "..=");
                    }
                    return self.makeToken(.dotdot, start_line, start_col, start_offset, "..");
                }
                return self.makeToken(.dot, start_line, start_col, start_offset, ".");
            },
            ':' => {
                if (self.peekChar() == ':') {
                    _ = self.advance();
                    return self.makeToken(.colon_colon, start_line, start_col, start_offset, "::");
                }
                return self.makeToken(.colon, start_line, start_col, start_offset, ":");
            },
            // ... more single/double char tokens
            '0'...'9' => self.scanNumber(start_line, start_col, start_offset),
            'a'...'z', 'A'...'Z', '_' => self.scanIdentifier(start_line, start_col, start_offset),
            '"' => self.scanString(start_line, start_col, start_offset),
            else => self.makeError("unexpected character", start_line, start_col, start_offset),
        };
    }

    fn advance(self: *Lexer) u8 {
        if (self.pos >= self.source_len) return 0;
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn peekChar(self: *Lexer) u8 {
        if (self.pos >= self.source_len) return 0;
        return self.source[self.pos];
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source_len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = self.advance();
            } else if (c == '/' and self.pos + 1 < self.source_len and self.source[self.pos + 1] == '/') {
                // Line comment
                while (self.pos < self.source_len and self.source[self.pos] != '\n') {
                    _ = self.advance();
                }
            } else if (c == '/' and self.pos + 1 < self.source_len and self.source[self.pos + 1] == '*') {
                // Block comment (skip /* ... */)
                _ = self.advance(); _ = self.advance();
                while (self.pos < self.source_len) {
                    if (self.source[self.pos] == '*' and self.pos + 1 < self.source_len and self.source[self.pos + 1] == '/') {
                        _ = self.advance(); _ = self.advance();
                        break;
                    }
                    _ = self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn scanIdentifier(self: *Lexer, line: u32, col: u32, offset: u32) Token {
        const start = self.pos - 1;
        while (self.pos < self.source_len) {
            const c = self.source[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                _ = self.advance();
            } else {
                break;
            }
        }
        const text = self.source[start..self.pos];
        const kind = keywords.find(text);
        return self.makeToken(kind, line, col, offset, text);
    }

    fn scanNumber(self: *Lexer, line: u32, col: u32, offset: u32) Token {
        const start = self.pos - 1;
        var is_float = false;
        while (self.pos < self.source_len) {
            const c = self.source[self.pos];
            if (std.ascii.isDigit(c) or c == '_') {
                _ = self.advance();
            } else if (c == '.' and !is_float) {
                is_float = true;
                _ = self.advance();
            } else {
                break;
            }
        }
        const text = self.source[start..self.pos];
        if (is_float) {
            const val = std.fmt.parseFloat(f64, text) catch 0.0;
            var tok = self.makeToken(.float_literal, line, col, offset, text);
            tok.literal = .{ .float_val = val };
            return tok;
        } else {
            const val = std.fmt.parseInt(i64, text, 10) catch 0;
            var tok = self.makeToken(.int_literal, line, col, offset, text);
            tok.literal = .{ .int_val = val };
            return tok;
        }
    }

    fn scanString(self: *Lexer, line: u32, col: u32, offset: u32) Token {
        // ... handle escapes, return .string_literal
    }

    fn makeToken(self: *Lexer, kind: TokenKind, line: u32, col: u32, offset: u32, text: []const u8) Token {
        return .{
            .kind = kind,
            .text = self.strings.intern(text),
            .loc = SrcLoc.init(self.filename, line, col, @intCast(offset)),
            .literal = .{ .none = {} },
        };
    }

    fn makeError(self: *Lexer, msg: []const u8, line: u32, col: u32, offset: u32) Token {
        return .{
            .kind = .error_token,
            .text = self.strings.intern(msg),
            .loc = SrcLoc.init(self.filename, line, col, @intCast(offset)),
            .literal = .{ .none = {} },
        };
    }

    // keyword lookup via comptime-generated table
    pub fn keywordToken(text: []const u8) TokenKind {
        return keywords.find(text);
    }
};
```

### 5.3 Comptime Keyword Table (`lexer/keywords.zig`)

```zig
const std = @import("std");
const TokenKind = @import("Token.zig").TokenKind;

pub const Entry = struct { text: []const u8, kind: TokenKind };

// Sorted at comptime for binary search
pub const table: []const Entry = comptime blk: {
    const raw = [_]Entry{
        .{ .text = "and",      .kind = .and_kw },
        .{ .text = "break",    .kind = .break_kw },
        .{ .text = "comptime", .kind = .comptime_kw },
        .{ .text = "const",    .kind = .const_kw },
        // ... all keywords
        .{ .text = "while",    .kind = .while_kw },
    };
    // Sort by text at comptime
    var sorted = raw;
    std.mem.sort(Entry, &sorted, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.text, b.text) == .lt;
        }
    }.lessThan);
    break :blk &sorted;
};

pub fn find(text: []const u8) TokenKind {
    // Binary search
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, text, table[mid].text)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return table[mid].kind,
        }
    }
    return .ident;
}
```

---

## 6. Parser Implementation

### 6.1 Structure

Same recursive descent + Pratt parser as the seed. The key Zig improvements:
- Error unions instead of `setjmp/longjmp`
- `?*Node` for nullable nodes
- `[]*Node` slices instead of DYNARRAY macros
- Comptime operator precedence table

### 6.2 `parser/Parser.zig`

```zig
const std = @import("std");
const Lexer = @import("../lexer/Lexer.zig");
const Token = @import("../lexer/Token.zig");
const TokenKind = Token.TokenKind;
const Node = @import("../ast/Node.zig");
const SrcLoc = @import("../common/SrcLoc.zig");
const StringTable = @import("../common/StringTable.zig");
const InternedString = StringTable.InternedString;
const precedence = @import("precedence.zig");

const MAX_DEPTH = 256;

pub const Parser = struct {
    lexer: *Lexer,
    allocator: std.mem.Allocator,
    strings: *StringTable,
    current: Token,
    previous: Token,
    had_error: bool,
    depth: u32,
    aborted: bool,
    no_struct_lit: bool,
    last_stmt_semi: bool,

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator, strings: *StringTable) Parser {
        var p = Parser{
            .lexer = lexer,
            .allocator = allocator,
            .strings = strings,
            .current = undefined,
            .previous = undefined,
            .had_error = false,
            .depth = 0,
            .aborted = false,
            .no_struct_lit = false,
            .last_stmt_semi = false,
        };
        p.current = lexer.next();
        return p;
    }

    pub fn parseModule(self: *Parser) !*Node {
        var items = std.ArrayList(*Node).init(self.allocator);
        defer items.deinit();

        while (!self.check(.eof) and !self.aborted) {
            const item = try self.parseTopLevel();
            try items.append(item);
        }

        const module = try self.allocator.create(Node);
        module.* = .{
            .kind = .module,
            .loc = self.previous.loc,
            .data = .{ .module = try items.toOwnedSlice() },
        };
        return module;
    }

    // ── Recursive descent methods ────────────────────────────

    fn advance(self: *Parser) void {
        self.previous = self.current;
        self.current = self.lexer.next();
    }

    fn check(self: *Parser, kind: TokenKind) bool {
        return self.current.kind == kind;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind) !void {
        if (!self.match(kind)) {
            self.errorAtCurrent("expected " ++ @tagName(kind));
            return error.ParseError;
        }
    }

    fn enter(self: *Parser) bool {
        if (self.aborted) return false;
        if (self.depth >= MAX_DEPTH) {
            self.aborted = true;
            self.errorAtCurrent("nesting too deep");
            return false;
        }
        self.depth += 1;
        return true;
    }

    fn leave(self: *Parser) void {
        if (self.depth > 0) self.depth -= 1;
    }

    fn errorAtCurrent(self: *Parser, msg: []const u8) void {
        if (self.current.kind == .error_token) {
            // Lexer error wins
            self.had_error = true;
            return;
        }
        // Report error to stderr
        std.debug.print("error:{s}:{d}:{d}: {s}\n", .{
            self.current.loc.filename,
            self.current.loc.line,
            self.current.loc.column,
            msg,
        });
        self.had_error = true;
    }

    // ── Expression parsing (Pratt) ──────────────────────────

    fn parseExpression(self: *Parser, min_bp: u8) !*Node {
        var lhs = try self.parsePrefix();
        while (!self.aborted) {
            const op = self.current.kind;
            const bp = precedence_bp(op) orelse break;
            if (bp < min_bp) break;
            lhs = try self.parseInfix(lhs, bp);
        }
        return lhs;
    }

    fn parsePrefix(self: *Parser) !*Node {
        if (self.check(.int_literal)) {
            return self.parseIntLiteral();
        }
        if (self.check(.ident)) {
            return self.parseIdentOrStructLit();
        }
        if (self.match(.lparen)) {
            const expr = try self.parseExpression(0);
            try self.expect(.rparen);
            return expr;
        }
        // ... more prefix cases
        self.errorAtCurrent("unexpected token");
        return error.ParseError;
    }

    fn parseInfix(self: *Parser, lhs: *Node, bp: u8) !*Node {
        const op_kind = self.current.kind;
        if (op_kind == .lparen) {
            return self.parseCall(lhs);
        }
        if (op_kind == .dot) {
            return self.parseFieldAccess(lhs);
        }
        if (op_kind == .lbracket) {
            return self.parseIndex(lhs);
        }
        // Binary operator
        self.advance();
        const rhs = try self.parseExpression(bp + 1);
        return self.allocNode(.{
            .kind = .binary_op,
            .data = .{ .binary_op = .{
                .op = tokenToBinaryOp(op_kind),
                .left = lhs,
                .right = rhs,
            } },
            .loc = lhs.loc,
        });
    }

    // ── Statement parsing ────────────────────────────────────

    fn parseStatement(self: *Parser) !*Node {
        if (self.check(.let) or self.check(.const_kw)) {
            return self.parseVarDecl();
        }
        if (self.check(.if_kw)) return self.parseIf();
        if (self.check(.while_kw)) return self.parseWhile();
        if (self.check(.for_kw)) return self.parseFor();
        if (self.check(.return_kw)) return self.parseReturn();
        if (self.check(.lbrace)) return self.parseBlock();
        // Expression statement
        const expr = try self.parseExpression(0);
        self.last_stmt_semi = self.match(.semicolon);
        return expr;
    }

    fn parseBlock(self: *Parser) !*Node {
        _ = try self.enter();
        defer self.leave();

        try self.expect(.lbrace);
        var stmts = std.ArrayList(*Node).init(self.allocator);
        defer stmts.deinit();

        while (!self.check(.rbrace) and !self.aborted) {
            const stmt = try self.parseStatement();
            try stmts.append(stmt);
        }
        try self.expect(.rbrace);

        return self.allocNode(.{
            .kind = .block,
            .data = .{ .block = .{
                .stmts = try stmts.toOwnedSlice(),
                .last_expr = null, // determined by last_stmt_semi
            } },
            .loc = self.previous.loc,
        });
    }

    // ... (other methods follow the seed's pattern)

    fn allocNode(self: *Parser, node: Node) !*Node {
        const ptr = try self.allocator.create(Node);
        ptr.* = node;
        return ptr;
    }
};
```

### 6.3 Comptime Precedence Table (`parser/precedence.zig`)

```zig
const TokenKind = @import("../lexer/Token.zig").TokenKind;

pub fn precedence_bp(kind: TokenKind) ?u8 {
    return switch (kind) {
        .pipe => 5,           // a | b
        .caret => 10,         // a ^ b
        .amp => 15,           // a & b
        .eq_eq, .neq => 20,  // a == b
        .lt, .gt, .le, .ge => 25, // a < b
        .shl, .shr => 30,    // a << b
        .plus, .minus => 35,  // a + b
        .star, .slash, .percent => 40, // a * b
        .dot => 50,           // a.b (field access)
        .lparen => 55,        // a() (call)
        .lbracket => 55,      // a[i] (index)
        else => null,
    };
}
```

---

## 7. Type Checker Implementation

### 7.1 Structure

Same design as the seed: scoped symbol table, simple Hindley-Milner unification,
integer literal polymorphism. Zig improvements:
- Error unions instead of manual error counts
- `?*Type` for nullable types
- Exhaustive `match` checking via Zig's exhaustive switches

### 7.2 `typechecker/TypeChecker.zig`

```zig
const std = @import("std");
const Node = @import("../ast/Node.zig");
const Type = @import("Type.zig");
const SymbolTable = @import("SymbolTable.zig");
const SrcLoc = @import("../common/SrcLoc.zig");
const StringTable = @import("../common/StringTable.zig");
const InternedString = StringTable.InternedString;

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    strings: *StringTable,
    symbols: SymbolTable,
    error_count: u32,

    pub fn init(allocator: std.mem.Allocator, strings: *StringTable) TypeChecker {
        return .{
            .allocator = allocator,
            .strings = strings,
            .symbols = SymbolTable.init(allocator),
            .error_count = 0,
        };
    }

    pub fn check(self: *TypeChecker, node: *Node) !?*Type {
        return switch (node.kind) {
            .int_literal => try self.resolveIntLiteral(node),
            .float_literal => Type.init(.float),
            .string_literal => Type.init(.string),
            .bool_literal => Type.init(.@"bool"),
            .ident => try self.resolveIdent(node),
            .binary_op => try self.checkBinary(node),
            .unary_op => try self.checkUnary(node),
            .call => try self.checkCall(node),
            .block => try self.checkBlock(node),
            .if_expr => try self.checkIf(node),
            .while_expr => try self.checkWhile(node),
            .for_expr => try self.checkFor(node),
            .match_expr => try self.checkMatch(node),
            .fn_decl => try self.checkFnDecl(node),
            .struct_decl => try self.checkStructDecl(node),
            .enum_decl => try self.checkEnumDecl(node),
            .const_decl => try self.checkConstDecl(node),
            .var_decl => try self.checkVarDecl(node),
            .assign => try self.checkAssign(node),
            .return_expr => try self.checkReturn(node),
            // ... etc
        };
    }

    fn checkBinary(self: *TypeChecker, node: *Node) !?*Type {
        const data = node.data.binary_op;
        const left = try self.check(data.left) orelse return null;
        const right = try self.check(data.right) orelse return null;

        return switch (data.op) {
            .add, .sub, .mul, .div, .mod => blk: {
                if (!self.isNumeric(left) or !self.isNumeric(right)) {
                    self.reportError(node.loc, "arithmetic on non-numeric types");
                    break :blk null;
                }
                // Integer literal coercion
                if (left.kind == .int_literal) break :blk right;
                if (right.kind == .int_literal) break :blk left;
                if (!left.eql(right)) {
                    self.reportError(node.loc, "type mismatch in binary op");
                    break :blk null;
                }
                break :blk left;
            },
            .eq, .neq, .lt, .gt, .le, .ge => blk: {
                if (!left.eql(right)) {
                    self.reportError(node.loc, "comparison of incompatible types");
                    break :blk null;
                }
                break :blk try self.resolveBool();
            },
            .@"and", .@"or" => blk: {
                if (left.kind != .@"bool" or right.kind != .@"bool") {
                    self.reportError(node.loc, "logical op requires bool");
                    break :blk null;
                }
                break :blk left;
            },
            // ... bitwise ops
        };
    }

    fn checkMatch(self: *TypeChecker, node: *Node) !?*Type {
        const data = node.data.match_expr;
        const target = try self.check(data.target) orelse return null;
        var result_type: ?*Type = null;

        for (data.arms) |arm| {
            self.symbols.pushScope();
            defer self.symbols.popScope();

            try self.checkPattern(arm.pattern, target);
            if (arm.guard) |guard| {
                const guard_type = try self.check(guard) orelse return null;
                if (guard_type.kind != .@"bool") {
                    self.reportError(guard.loc, "guard must be bool");
                }
            }
            const body_type = try self.check(arm.body) orelse return null;
            if (result_type) |rt| {
                if (!rt.eql(body_type)) {
                    self.reportError(arm.body.loc, "match arm type mismatch");
                }
            } else {
                result_type = body_type;
            }
        }

        // Exhaustiveness check
        try self.checkExhaustiveness(node.loc, target, data.arms);
        return result_type;
    }

    // ... (other methods)

    fn reportError(self: *TypeChecker, loc: SrcLoc, msg: []const u8) void {
        std.debug.print("error:{s}:{d}:{d}: {s}\n", .{
            loc.filename, loc.line, loc.column, msg,
        });
        self.error_count += 1;
    }
};
```

### 7.3 Symbol Table (`typechecker/SymbolTable.zig`)

```zig
const std = @import("std");
const Type = @import("Type.zig");
const InternedString = @import("../common/StringTable.zig").InternedString;
const SrcLoc = @import("../common/SrcLoc.zig");

pub const Symbol = struct {
    name: InternedString,
    type: ?*Type,
    is_mut: bool,
    is_fn: bool,
    def_loc: SrcLoc,
    seq: u32, // monotonic insertion order for scoped removal
};

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Symbol),
    scope_stack: std.ArrayListUnmanaged(u32), // scopes: start indices
    next_seq: u32,

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{
            .allocator = allocator,
            .entries = .{},
            .scope_stack = .{},
            .next_seq = 0,
        };
    }

    pub fn pushScope(self: *SymbolTable) !void {
        try self.scope_stack.append(self.allocator, @intCast(self.entries.items.len));
    }

    pub fn popScope(self: *SymbolTable) void {
        const start = self.scope_stack.pop();
        self.entries.items.len = start;
    }

    pub fn insert(self: *SymbolTable, sym: Symbol) !void {
        var s = sym;
        s.seq = self.next_seq;
        self.next_seq += 1;
        try self.entries.append(self.allocator, s);
    }

    pub fn lookup(self: *SymbolTable, name: InternedString) ?*Symbol {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i].name.eql(name)) {
                return &self.entries.items[i];
            }
        }
        return null;
    }
};
```

---

## 8. Emitter + Bytecode

### 8.1 Structure

The emitter walks the typed AST and emits stack bytecode. Key Zig improvements:
- `std.ArrayList` replaces manual dynamic arrays
- Tagged unions for instruction args
- Comptime `stackEffect` for the stack-height model

### 8.2 `emitter/Emitter.zig`

```zig
const std = @import("std");
const Node = @import("../ast/Node.zig");
const OpCode = @import("OpCode.zig");
const Instruction = OpCode.Instruction;
const Value = @import("../vm/Value.zig");
const Type = @import("../typechecker/Type.zig");
const InternedString = @import("../common/StringTable.zig").InternedString;
const StringTable = @import("../common/StringTable.zig");

const MAX_LOCALS = 256;
const MAX_LOOP_DEPTH = 32;

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    strings: *StringTable,

    code: std.ArrayListUnmanaged(Instruction),
    constants: std.ArrayListUnmanaged(Value),

    locals: [MAX_LOCALS]Local,
    local_count: u16,
    scope_depth: u8,

    loops: [MAX_LOOP_DEPTH]LoopPatch,
    loop_depth: i32,

    structs: std.ArrayListUnmanaged(StructInfo),
    enums: std.ArrayListUnmanaged(EnumInfo),
    variant_index: std.ArraylistUnmanaged(VariantEntry),
    fns: std.ArrayListUnmanaged(FnName),

    sp: i32, // compile-time stack height model
    sp_high: i32,
    error_count: u32,

    const Local = struct {
        name: InternedString,
        slot: u8,
        depth: u8,
    };

    const LoopPatch = struct {
        breaks: std.ArrayListUnmanaged(usize),
        conts: std.ArrayListUnmanaged(usize),
        continue_target: usize,
    };

    const StructInfo = struct {
        name: InternedString,
        fields: []InternedString,
        def: *Value.StructDef,
    };

    const EnumInfo = struct {
        name: InternedString,
        variants: []InternedString,
        field_names: []const []const InternedString,
        field_counts: []u32,
    };

    const VariantEntry = struct {
        variant: InternedString,
        enum_idx: usize,
    };

    const FnName = struct { name: InternedString };

    pub fn init(allocator: std.mem.Allocator, strings: *StringTable) Emitter {
        return .{
            .allocator = allocator,
            .strings = strings,
            .code = .{},
            .constants = .{},
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 0,
            .loops = undefined,
            .loop_depth = 0,
            .structs = .{},
            .enums = .{},
            .variant_index = .{},
            .fns = .{},
            .sp = 0,
            .sp_high = 0,
            .error_count = 0,
        };
    }

    pub fn emit(self: *Emitter, module: *Node) !void {
        try self.emitModule(module);
    }

    fn emitModule(self: *Emitter, module: *Node) !void {
        for (module.data.module) |item| {
            try self.emitTopLevel(item);
        }
        try self.emitOp(.halt, 0);
    }

    fn emitTopLevel(self: *Emitter, node: *Node) !void {
        switch (node.kind) {
            .fn_decl => try self.emitFnDecl(node),
            .const_decl => try self.emitConstDecl(node),
            .var_decl => try self.emitVarDecl(node),
            .struct_decl => try self.emitStructDecl(node),
            .enum_decl => try self.emitEnumDecl(node),
            .use => {}, // import handling (Phase 2)
            else => try self.emitStmt(node),
        }
    }

    fn emitExpr(self: *Emitter, node: *Node) !void {
        switch (node.kind) {
            .int_literal => {
                const idx = try self.addConstant(Value.int(node.data.int_literal));
                try self.emitOp(.@"const", idx);
                self.sp += 1;
            },
            .binary_op => {
                try self.emitExpr(node.data.binary_op.left);
                try self.emitExpr(node.data.binary_op.right);
                const op = switch (node.data.binary_op.op) {
                    .add => OpCode.add,
                    .sub => OpCode.sub,
                    // ... map all binary ops
                };
                try self.emitOp(op, 0);
                self.sp -= 1; // two values consumed, one pushed
            },
            .call => try self.emitCall(node),
            // ... all expression kinds
        }
    }

    fn emitOp(self: *Emitter, op: OpCode, arg: u32) !void {
        const inst = Instruction{
            .op = op,
            .line = self.getCurrentLine(),
            .arg = switch (op) {
                .jump, .jump_if_false, .jump_if_true => .{ .offset = @intCast(arg) },
                .call => .{ .arg_count = @intCast(arg) },
                else => .{ .index = arg },
            },
        };
        try self.code.append(self.allocator, inst);
    }

    fn emitJump(self: *Emitter, op: OpCode) !usize {
        try self.emitOp(op, 0); // placeholder offset
        return self.code.items.len - 1;
    }

    fn patchJump(self: *Emitter, offset: usize) void {
        const target = self.code.items.len;
        const inst = &self.code.items[offset];
        inst.arg = .{ .offset = @intCast(target - offset) };
    }

    // ... (other methods)

    fn getCurrentLine(self: *Emitter) u32 {
        // Return line from the most recently emitted AST node
        return 0; // simplified
    }
};
```

---

## 9. VM Implementation

### 9.1 Structure

Stack-based VM, same architecture as the seed. Zig improvements:
- Exhaustive switches for opcode dispatch
- Error unions for runtime errors
- No hidden allocations

### 9.2 `vm/VM.zig`

```zig
const std = @import("std");
const Value = @import("Value.zig");
const Instruction = @import("../emitter/OpCode.zig").Instruction;
const OpCode = @import("../emitter/OpCode.zig").OpCode;

const STACK_SIZE = 1024;
const CALL_DEPTH = 256;
const MAX_GLOBALS = 256;

pub const VMResult = enum { ok, runtime_error };

pub const VM = struct {
    allocator: std.mem.Allocator,
    stack: [STACK_SIZE]Value,
    sp: u16,
    frames: [CALL_DEPTH]CallFrame,
    frame_count: u16,
    globals: [MAX_GLOBALS]Global,
    global_count: u16,
    error_msg: ?[]const u8,
    error_line: u32,

    const CallFrame = struct {
        ip: [*]const Instruction,
        base: u16,
        code: []const Instruction,
        constants: []const Value,
    };

    const Global = struct {
        name: [*:0]const u8,
        value: Value,
    };

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{
            .allocator = allocator,
            .stack = undefined,
            .sp = 0,
            .frames = undefined,
            .frame_count = 0,
            .globals = undefined,
            .global_count = 0,
            .error_msg = null,
            .error_line = 0,
        };
    }

    pub fn run(self: *VM, code: []const Instruction, constants: []const Value) !void {
        var frame = CallFrame{
            .ip = code.ptr,
            .base = 0,
            .code = code,
            .constants = constants,
        };
        self.frames[0] = frame;
        self.frame_count = 1;

        while (true) {
            const inst = frame.ip[0];
            frame.ip += 1;

            switch (inst.op) {
                .halt => return,
                .@"const" => {
                    self.push(frame.constants[inst.arg.index]);
                },
                .pop => {
                    _ = self.pop();
                },
                .add => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(try self.intAdd(a, b));
                },
                .sub => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(try self.intSub(a, b));
                },
                // ... all opcodes
                .jump => {
                    const offset = inst.arg.offset;
                    frame.ip = @ptrFromInt(@intFromPtr(frame.ip) + @as(usize, @intCast(offset)));
                },
                .jump_if_false => {
                    const val = self.pop();
                    if (!val.isTruthy()) {
                        const offset = inst.arg.offset;
                        frame.ip = @ptrFromInt(@intFromPtr(frame.ip) + @as(usize, @intCast(offset)));
                    }
                },
                .call => {
                    const arg_count = inst.arg.arg_count;
                    const callee = self.peek(arg_count);
                    if (callee.kind != .@"fn") {
                        return self.runtimeError("call to non-function", inst.line);
                    }
                    const fn_obj = callee.data.@"fn";
                    self.frame_count += 1;
                    if (self.frame_count >= CALL_DEPTH) {
                        return self.runtimeError("call stack overflow", inst.line);
                    }
                    frame = CallFrame{
                        .ip = fn_obj.code.ptr,
                        .base = self.sp - arg_count,
                        .code = fn_obj.code,
                        .constants = fn_obj.constants,
                    };
                    self.frames[self.frame_count - 1] = frame;
                },
                .ret => {
                    const result = self.pop();
                    self.frame_count -= 1;
                    if (self.frame_count == 0) return;
                    frame = self.frames[self.frame_count - 1];
                    self.sp = frame.base;
                    self.push(result);
                },
                .print => {
                    const val = self.pop();
                    try self.printValue(val);
                },
                // ... remaining opcodes
            }
        }
    }

    fn push(self: *VM, val: Value) void {
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    fn pop(self: *VM) Value {
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn peek(self: *VM, distance: u16) Value {
        return self.stack[self.sp - 1 - distance];
    }

    fn runtimeError(self: *VM, msg: []const u8, line: u32) !void {
        self.error_msg = msg;
        self.error_line = line;
        return error.RuntimeError;
    }

    fn printValue(self: *VM, val: Value) !void {
        const stdout = std.io.getStdOut().writer();
        switch (val.kind) {
            .nil => try stdout.print("nil", .{}),
            .@"bool" => try stdout.print("{}", .{val.data.@"bool"}),
            .int => try stdout.print("{d}", .{val.data.int}),
            .float => try stdout.print("{d}", .{val.data.float}),
            .string => try stdout.print("{s}", .{val.data.string}),
            // ... other value types
        }
    }

    fn intAdd(self: *VM, a: Value, b: Value) !Value {
        if (a.kind == .int and b.kind == .int) return Value.int(a.data.int + b.data.int);
        if (a.kind == .float and b.kind == .float) return Value.float(a.data.float + b.data.float);
        return self.runtimeError("type error in addition", 0);
    }

    // ... other arithmetic helpers
};
```

---

## 10. LLVM Backend

### 10.1 Strategy

The LLVM backend uses Zig's C interop (`@cImport`) to call the LLVM C API
directly. No wrapper library needed. This follows the same pattern the Zig
compiler itself uses (`src/codegen/llvm/`).

### 10.2 `llvm_backend/Backend.zig`

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
    @cInclude("llvm-c/Initialization.h");
});
const Node = @import("../ast/Node.zig");
const Type = @import("../typechecker/Type.zig");

pub const Backend = struct {
    context: *c.LLVMContext,
    module: *c.LLVMModule,
    builder: *c.LLVMBuilder,
    target_machine: *c.LLVMTargetMachine,

    pub fn init(target_triple: [*:0]const u8) Backend {
        const context = c.LLVMContextCreate();
        const module = c.LLVMModuleCreateWithNameInContext("astra", context);
        c.LLVMSetTarget(module, target_triple);

        // Initialize target
        c.LLVMInitializeX86TargetInfo();
        c.LLVMInitializeX86Target();
        c.LLVMInitializeX86TargetMC();
        c.LLVMInitializeX86AsmPrinter();

        var error_message: [*:0]const u8 = undefined;
        var target: *c.LLVMTarget = undefined;
        _ = c.LLVMGetTargetFromTriple(target_triple, &target, &error_message);

        const target_machine = c.LLVMCreateTargetMachine(
            target,
            target_triple,
            null, // CPU
            null, // Features
            c.LLVMCodeGenLevelDefault,
            c.LLVMRelocDefault,
            c.LLVMCodeModelDefault,
        );

        return .{
            .context = context,
            .module = module,
            .builder = c.LLVMCreateBuilderInContext(context),
            .target_machine = target_machine,
        };
    }

    pub fn deinit(self: *Backend) void {
        c.LLVMDisposeBuilder(self.builder);
        c.LLVMDisposeModule(self.module);
        c.LLVMContextDispose(self.context);
        c.LLVMDisposeTargetMachine(self.target_machine);
    }

    pub fn emitToFile(self: *Backend, filename: [*:0]const u8, output_type: OutputType) !void {
        var error_message: [*:0]const u8 = undefined;
        const result = switch (output_type) {
            .object => c.LLVMTargetMachineEmitToFile(
                self.target_machine, self.module, @constCast(filename),
                &error_message,
            ),
            .assembly => c.LLVMTargetMachineEmitToFile(
                self.target_machine, self.module, @constCast(filename),
                &error_message,
            ),
        };
        if (result != 0) {
            return error.LLVMError;
        }
    }

    pub const OutputType = enum { object, assembly, llvm_ir };

    // ── IR Generation ────────────────────────────────────────

    pub fn genModule(self: *Backend, module: *Node, type_info: *const TypeMap) !void {
        for (module.data.module) |item| {
            try self.genTopLevel(item, type_info);
        }
    }

    fn genTopLevel(self: *Backend, node: *Node, type_info: *const TypeMap) !void {
        switch (node.kind) {
            .fn_decl => try self.genFunction(node, type_info),
            .struct_decl => try self.genStruct(node, type_info),
            .enum_decl => try self.genEnum(node, type_info),
            .const_decl => try self.genGlobal(node, type_info),
            // ...
        }
    }

    fn genFunction(self: *Backend, node: *Node, type_info: *const TypeMap) !void {
        const data = node.data.fn_decl;
        const fn_type = try self.lowerType(type_info.get(node), type_info);

        const fn_val = c.LLVMAddFunction(
            self.module,
            @ptrCast(data.name.ptr),
            fn_type,
        );

        const bb = c.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        c.LLVMPositionBuilderAtEnd(self.builder, bb);

        try self.genBody(data.body, type_info);
    }

    fn lowerType(self: *Backend, typ: *const Type, type_info: *const TypeMap) !c.LLVMTypeRef {
        return switch (typ.kind) {
            .void => c.LLVMVoidTypeInContext(self.context),
            .@"bool" => c.LLVMInt1TypeInContext(self.context),
            .int => c.LLVMInt32TypeInContext(self.context),
            .int64 => c.LLVMInt64TypeInContext(self.context),
            .float => c.LLVMDoubleTypeInContext(self.context),
            .string => c.LLVMPointerType(c.LLVMInt8TypeInContext(self.context), 0),
            .optional => blk: {
                // Lower as tagged union or i1 + inner type
                break :blk try self.lowerOptionalType(typ, type_info);
            },
            .@"struct" => try self.lowerStructType(typ, type_info),
            .@"enum" => try self.lowerEnumType(typ, type_info),
            .array => try self.lowerArrayType(typ, type_info),
            .fn_type => try self.lowerFnType(typ, type_info),
        };
    }

    // ... (other codegen methods)
};
```

### 10.3 build.zig LLVM integration

```zig
if (enable_llvm) {
    // System LLVM linking
    exe.linkSystemLibrary("llvm");
    exe.linkSystemLibrary("clang");
    exe.linkSystemLibrary("lldCore");
    exe.linkLibCpp();
}
```

---

## 11. Testing Strategy

### 11.1 Unit Tests

Each module has inline tests (Zig convention):

```zig
// In src/lexer/Lexer.zig
test "lexes simple tokens" {
    var st = StringTable.init(std.testing.allocator);
    var lexer = Lexer.init("test.astra", "let x = 42;", &st);
    const tok = lexer.next();
    try std.testing.expectEqual(TokenKind.let, tok.kind);
}
```

Run with: `zig build test`

### 11.2 Integration Tests

Test the full pipeline (Lexer → Parser → TypeCheck → Emit → VM):

```zig
// tests/integration.zig
const astra = @import("astra");

test "hello world" {
    const source = "fn main() { print(\"hello\"); }";
    const result = try astra.compileAndRun("test.astra", source);
    try std.testing.expectEqual(astra.VMResult.ok, result);
}
```

### 11.3 Conformance Tests

Reuse the seed's test files from `seed/tests/conformance/`. The test runner
compiles each `.astra` file through the Zig compiler and compares output.

```zig
// tests/conformance.zig
test "conformance suite" {
    const dir = std.fs.cwd().openDir("tests/conformance", .{}) catch return;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".astra")) {
            try runConformanceTest(entry.name);
        }
    }
}
```

### 11.4 Cross-backend Verification

Both the VM and LLVM backends must produce identical output for the same
conformance tests.

---

## 12. Development Workflow

### 12.1 Build Commands

```bash
cd zig/

# Build
zig build                          # debug
zig build -Doptimize=ReleaseFast   # optimized
zig build -Denable-llvm=false      # VM-only

# Test
zig build test                     # unit tests
zig build test-integration         # integration
zig build test-conformance         # conformance suite

# Run
zig build run -- file.astra        # compile and run
zig build run -- --dump-tokens file.astra
zig build run -- --dump-ast file.astra
zig build run -- --emit-c file.astra
zig build run -- --emit-llvm file.astra

# Development cycle
zig build run -- tests/conformance/arithmetic.astra
```

### 12.2 Iteration Strategy

Build the compiler incrementally, verifying at each step:

| Step | What | Verification |
|:-----|:-----|:-------------|
| 1 | Lexer + Token | `--dump-tokens` matches seed output |
| 2 | Parser + AST | `--dump-ast` matches seed output |
| 3 | Type checker | Conformance tests pass (EXPECT-ERROR cases) |
| 4 | Emitter + VM | All conformance tests pass |
| 5 | C codegen | `--emit-c` produces valid C |
| 6 | LLVM backend | `--emit-llvm` produces valid LLVM IR |

### 12.3 Conformance Test Sharing

The conformance tests in `seed/tests/conformance/` are shared with the Zig
compiler. Symlink or copy them into `zig/tests/conformance/`.

### 12.4 Debugging

```bash
ASTRA_DUMP_VM=1 zig build run -- file.astra   # dump bytecode
ASTRA_TRACE=1   zig build run -- file.astra   # trace VM
zig build run -- --dump-tokens file.astra     # lexer output
zig build run -- --dump-ast file.astra        # AST output
```

---

## 13. Estimated Effort

| Module | Files | LOC (est.) | Effort (days) | Notes |
|:-------|:------|:-----------|:--------------|:------|
| `build.zig` + `build.zig.zon` | 2 | ~150 | 1 | Build system setup |
| `common/` (Arena, StringTable, SrcLoc, diagnostics) | 5 | ~400 | 2 | Foundation |
| `lexer/` (Lexer, Token, keywords) | 3 | ~600 | 3 | Port from seed, comptime tables |
| `ast/` (Node, NodeKind, pretty_print) | 3 | ~800 | 3 | Tagged unions replace C unions |
| `parser/` (Parser, precedence, errors) | 3 | ~1500 | 5 | Largest module, recursive descent |
| `typechecker/` (TypeChecker, Type, SymbolTable, unify) | 5 | ~1200 | 5 | Type system + exhaustiveness |
| `emitter/` (Emitter, OpCode, JumpPatch) | 3 | ~1000 | 4 | Stack model + jump patching |
| `vm/` (VM, Value, CallFrame, Builtins) | 5 | ~1000 | 3 | Port from seed, exhaustive switches |
| `codegen/` (C codegen) | 2 | ~800 | 3 | Port `--emit-c` |
| `llvm_backend/` (Backend, Module, Function, IRBuilder, Target) | 5 | ~1500 | 7 | LLVM C API integration |
| `tests/` (unit + integration + conformance) | 6 | ~600 | 3 | Test infrastructure |
| **Total** | **~42** | **~9,550** | **~39** | |

### Phase 2 MVP (no LLVM): ~25 days
### Phase 2 Full (with LLVM): ~39 days

---

## 14. Migration Notes: C → Zig

### 14.1 Pattern Mapping

| C Pattern | Zig Equivalent |
|:----------|:---------------|
| `Arena` + `arena_new` | `std.heap.ArenaAllocator` |
| `DYNARRAY(T)` | `std.ArrayListUnmanaged(T)` |
| Tagged union (`NodeKind` + union) | `union(NodeKind)` (exhaustive) |
| `NULL` pointer | `?*T` (optional) |
| `setjmp/longjmp` | `error{}` unions |
| `fprintf(stderr, ...)` | `std.debug.print(...)` |
| Manual `free()` | `defer arena.deinit()` |
| `bool` return for errors | `!void` or `error{}` |
| `switch` with fallthrough | Exhaustive switch (no fallthrough) |
| `#define` constants | `comptime` constants |
| `typedef struct` | Direct struct types |
| Function pointers | `*const fn(...)` |
| C string (`char*`) | `[:0]const u8` |
| `size_t` | `usize` |
| `uint32_t` | `u32` |
| `int64_t` | `i64` |

### 14.2 What Changes

| Seed (C) | Zig Compiler |
|:---------|:-------------|
| `arena_new(a, Type)` | `try allocator.create(Type)` |
| `da_push(T, arr, val, arena)` | `try list.append(val)` |
| `fprintf(stderr, ...)` | `std.debug.print(...)` |
| `setjmp/longjmp` error handling | `try` / `catch` |
| `bool` error flags | Error unions |
| `NULL` checks | Optional unwrapping |
| Manual memory management | `defer` + arena |

### 14.3 What Stays the Same

- Pipeline architecture (Lexer → Parser → TypeCheck → Emit → VM)
- Recursive descent + Pratt parser
- Stack-based bytecode VM
- Arena allocation strategy
- String interning
- Conformance test suite
- CLI interface and flags

---

*End of Phase 2 Implementation Plan*
