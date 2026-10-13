//! Astra-0 abstract syntax tree (Phase 2, Zig).
//!
//! Design follows `PHASE2_RESEARCH.md` §1.3/§1.5: nodes are **flat** and referred
//! to by `u32` index, never by pointer. Variable-length child lists live in a
//! single shared `extra` buffer and are described by `List { start, len }`.
//!
//! This replaces the previous stub, which stored `start = 0` for every list, so
//! all child lists aliased node 0 and the tree could not represent a program.
//! The node set mirrors `seed/include/astra/astra.h` §7 (`NodeKind`).

const std = @import("std");
const lexer = @import("../lexer/lexer.zig");
const dump_mod = @import("../dump.zig");

/// Slice into `Tree.extra`.
pub const List = struct { start: u32, len: u32 };

pub const Tag = enum {
    // Top-level
    source_file,
    fn_decl,
    lambda_expr,
    struct_decl,
    enum_decl,
    var_decl,
    const_decl,
    use_decl,
    import_decl,
    from_decl,
    trait_decl,
    impl_decl,

    // Declarations / auxiliary nodes
    param,
    field_decl,
    struct_init_field,
    enum_variant,
    payload,
    import_item,
    match_arm,

    // Statements
    expr_stmt,
    return_stmt,
    break_stmt,
    continue_stmt,
    block,

    // Expressions
    int_literal,
    float_literal,
    string_literal,
    bool_literal,
    nil_literal,
    identifier,
    binary_expr,
    unary_expr,
    call_expr,
    index_expr,
    field_access,
    array_literal,
    range_expr,
    struct_literal,
    some_expr,
    none_expr,
    ok_expr,
    err_expr,
    try_expr,
    if_expr,
    while_expr,
    for_expr,
    match_expr,
    assignment,
    compound_assignment,

    // Patterns
    pattern_wildcard,
    pattern_bind,
    pattern_variant_bind,
    pattern_builtin_variant,
    pattern_or,

    // Types
    type_ident,
    type_optional,
    type_array,
    type_fn,
};

pub const FnDecl = struct { name: []const u8, params: List, ret: ?u32, body: u32, is_pub: bool = false };
pub const Lambda = struct { params: List, ret: ?u32, body: u32 };
pub const StructDecl = struct { name: []const u8, fields: List, is_pub: bool = false };
pub const EnumDecl = struct { name: []const u8, variants: List, is_pub: bool = false };
/// `trait Name { fn ... }` (research/010 §12.1 TraitDef). A signature-only
/// method carries an empty body block, so every consumer sees a well-formed
/// `fn_decl`.
pub const TraitDecl = struct { name: []const u8, items: List, is_pub: bool = false };
/// `impl [TraitName for] Type { fn methods }` (research/010 §12.1 ImplBlock).
/// `trait_name` is null for an inherent impl; generics/where are Phase 2.4.
pub const ImplDecl = struct { trait_name: ?[]const u8, type_name: []const u8, items: List };
pub const VarDecl = struct { name: []const u8, type_node: ?u32, value: ?u32, is_mut: bool, is_pub: bool = false };
/// `import ImportPath ("as" Identifier)?` (research/010 §12.1). `path` is the
/// source text of the whole path (`a.b.c`).
pub const ImportDecl = struct { path: []const u8, alias: ?[]const u8 };
/// `from ImportPath import ImportItem ("," ImportItem)*`.
pub const FromDecl = struct { path: []const u8, items: List };
/// `ImportItem ::= Identifier ("as" Identifier)?`.
pub const ImportItem = struct { name: []const u8, alias: ?[]const u8 };
pub const Param = struct { name: []const u8, type_node: ?u32 };
pub const FieldDecl = struct { name: []const u8, type_node: u32 };
pub const StructInitField = struct { name: []const u8, value: u32 };
pub const EnumVariant = struct { name: []const u8, payload: ?u32 };
pub const MatchArm = struct { pattern: u32, guard: ?u32, body: u32 };
pub const Block = struct { stmts: List, tail: ?u32 };
pub const Binary = struct { op: lexer.Tag, left: u32, right: u32 };
pub const Unary = struct { op: lexer.Tag, operand: u32 };
pub const Call = struct { callee: u32, args: List };
pub const Index = struct { object: u32, index: u32 };
pub const FieldAccess = struct {
    object: u32,
    field: []const u8,
    /// Non-empty when the type checker resolved this access as a method call
    /// (`x.m()`): the mangled global to dispatch to (`Type.method`, static
    /// dispatch). The emitter lowers such a call to get_global + receiver +
    /// args + call instead of a field read.
    method: []const u8 = "",
};
pub const Range = struct { start_node: ?u32, end_node: ?u32, inclusive: bool };
pub const StructLiteral = struct { name: []const u8, fields: List };
pub const IfExpr = struct { cond: u32, then_block: u32, else_block: ?u32 };
pub const WhileExpr = struct { cond: u32, body: u32 };
pub const ForExpr = struct { var_name: []const u8, iter: u32, body: u32 };
pub const MatchExpr = struct { target: u32, arms: List };
pub const Assign = struct { target: u32, value: u32 };
pub const CompoundAssign = struct { op: lexer.Tag, target: u32, value: u32 };
pub const VariantBind = struct { variant: u32, bindings: List };
pub const BuiltinVariant = struct { kind: BuiltinKind, payload: ?u32 };
pub const TypeArray = struct { elem: u32, size: ?u32 };
pub const TypeFn = struct { params: List, ret: ?u32 };

pub const BuiltinKind = enum { ok, err, some, none };

pub const Node = union(Tag) {
    source_file: List,
    fn_decl: FnDecl,
    lambda_expr: Lambda,
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    var_decl: VarDecl,
    const_decl: VarDecl,
    use_decl: []const u8,
    import_decl: ImportDecl,
    from_decl: FromDecl,
    trait_decl: TraitDecl,
    impl_decl: ImplDecl,
    param: Param,
    field_decl: FieldDecl,
    struct_init_field: StructInitField,
    enum_variant: EnumVariant,
    payload: List, // list of `field_decl` nodes
    import_item: ImportItem,
    match_arm: MatchArm,
    expr_stmt: u32,
    return_stmt: ?u32,
    break_stmt: void,
    continue_stmt: void,
    block: Block,
    int_literal: i64,
    float_literal: f64,
    string_literal: []const u8,
    bool_literal: bool,
    nil_literal: void,
    identifier: []const u8,
    binary_expr: Binary,
    unary_expr: Unary,
    call_expr: Call,
    index_expr: Index,
    field_access: FieldAccess,
    array_literal: List,
    range_expr: Range,
    struct_literal: StructLiteral,
    some_expr: u32,
    none_expr: void,
    ok_expr: u32,
    err_expr: u32,
    try_expr: u32,
    if_expr: IfExpr,
    while_expr: WhileExpr,
    for_expr: ForExpr,
    match_expr: MatchExpr,
    assignment: Assign,
    compound_assignment: CompoundAssign,
    pattern_wildcard: void,
    pattern_bind: []const u8,
    pattern_variant_bind: VariantBind,
    pattern_builtin_variant: BuiltinVariant,
    pattern_or: List,
    type_ident: []const u8,
    type_optional: u32,
    type_array: TypeArray,
    type_fn: TypeFn,
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    locs: std.ArrayListUnmanaged(lexer.Loc) = .empty,
    extra: std.ArrayListUnmanaged(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Tree {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.allocator);
        self.locs.deinit(self.allocator);
        self.extra.deinit(self.allocator);
    }

    pub fn addNode(self: *Tree, n: Node, location: lexer.Loc) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, n);
        try self.locs.append(self.allocator, location);
        return idx;
    }

    /// Copy `items` into the shared extra buffer and return a handle to them.
    pub fn addExtra(self: *Tree, items: []const u32) !List {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.allocator, items);
        return .{ .start = start, .len = @intCast(items.len) };
    }

    pub fn extraSlice(self: *const Tree, list: List) []const u32 {
        return self.extra.items[list.start .. list.start + list.len];
    }

    pub fn node(self: *const Tree, idx: u32) Node {
        return self.nodes.items[idx];
    }

    pub fn loc(self: *const Tree, idx: u32) lexer.Loc {
        return self.locs.items[idx];
    }

    pub fn sourceText(self: *const Tree, l: lexer.Loc) []const u8 {
        return self.source[l.start..l.end];
    }

    /// Byte-parity dump used by `--dump-ast` (PHASE2 §4 #6): it prints exactly
    /// what `seed/astra-seed --dump-ast` prints — the reference format lives in
    /// `seed/src/driver.c` `dump_node` (labels like `FnDecl(name)`, types as
    /// child nodes, no inline headers). Kinds the seed parser never produces
    /// (`expr_stmt`, `compound_assignment`, `nil_literal`) keep seed-shaped
    /// stubs so the switch stays exhaustive.
    pub fn dump(self: *const Tree, writer: anytype, root: u32) !void {
        try self.dumpNode(writer, root, 0);
    }

    fn indent(writer: anytype, depth: usize) !void {
        var i: usize = 0;
        while (i < depth) : (i += 1) try writer.writeAll("  ");
    }

    fn dumpNode(self: *const Tree, writer: anytype, idx: u32, depth: usize) anyerror!void {
        const n = self.nodes.items[idx];
        try indent(writer, depth);
        switch (n) {
            .source_file => |l| {
                try writer.writeAll("Module\n");
                for (self.extraSlice(l)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .fn_decl => |f| {
                try writer.print("{s}FnDecl({s})\n", .{ if (f.is_pub) "Pub" else "", f.name });
                for (self.extraSlice(f.params)) |p| {
                    const par = self.nodes.items[p].param;
                    try indent(writer, depth + 1);
                    try writer.print("Param({s})\n", .{par.name});
                    if (par.type_node) |t| try self.dumpNode(writer, t, depth + 2);
                }
                if (f.ret) |r| {
                    try indent(writer, depth + 1);
                    try writer.writeAll("ReturnType\n");
                    try self.dumpNode(writer, r, depth + 2);
                }
                try self.dumpNode(writer, f.body, depth + 1);
            },
            .lambda_expr => |f| {
                try writer.writeAll("Lambda\n");
                for (self.extraSlice(f.params)) |p| {
                    // The seed prints lambda params without their types.
                    try indent(writer, depth + 1);
                    try writer.print("Param({s})\n", .{self.nodes.items[p].param.name});
                }
                if (f.ret) |r| try self.dumpNode(writer, r, depth + 1);
                try self.dumpNode(writer, f.body, depth + 1);
            },
            .struct_decl => |s| {
                try writer.print("{s}StructDecl({s})\n", .{ if (s.is_pub) "Pub" else "", s.name });
                for (self.extraSlice(s.fields)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .enum_decl => |e| {
                try writer.print("{s}EnumDecl({s})\n", .{ if (e.is_pub) "Pub" else "", e.name });
                for (self.extraSlice(e.variants)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .trait_decl => |t| {
                try writer.print("{s}Trait({s})\n", .{ if (t.is_pub) "Pub" else "", t.name });
                for (self.extraSlice(t.items)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .impl_decl => |im| {
                try writer.writeAll("Impl(");
                if (im.trait_name) |tn| try writer.print("{s} for ", .{tn});
                try writer.print("{s})\n", .{im.type_name});
                for (self.extraSlice(im.items)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .var_decl => |v| {
                try writer.print("VarDecl({s}{s})\n", .{ v.name, if (v.is_mut) ", mut" else "" });
                if (v.type_node) |t| try self.dumpNode(writer, t, depth + 1);
                if (v.value) |val| try self.dumpNode(writer, val, depth + 1);
            },
            .const_decl => |v| {
                try writer.print("{s}ConstDecl({s})\n", .{ if (v.is_pub) "Pub" else "", v.name });
                if (v.type_node) |t| try self.dumpNode(writer, t, depth + 1);
                if (v.value) |val| try self.dumpNode(writer, val, depth + 1);
            },
            .use_decl => try writer.writeAll("Use\n"),
            .import_decl => |d| {
                try writer.print("Import({s}", .{d.path});
                if (d.alias) |al| try writer.print(" as {s}", .{al});
                try writer.writeAll(")\n");
            },
            .from_decl => |d| {
                try writer.print("From({s})\n", .{d.path});
                for (self.extraSlice(d.items)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .import_item => |i| {
                try writer.print("ImportItem({s}", .{i.name});
                if (i.alias) |al| try writer.print(" as {s}", .{al});
                try writer.writeAll(")\n");
            },
            .param => |p| {
                // Standalone fallback; fn_decl prints Param inline at +1/+2.
                try writer.print("Param({s})\n", .{p.name});
                if (p.type_node) |t| try self.dumpNode(writer, t, depth + 1);
            },
            .field_decl => |f| {
                try writer.print("Field({s})\n", .{f.name});
                try self.dumpNode(writer, f.type_node, depth + 1);
            },
            .struct_init_field => |f| {
                try writer.print("Field({s})\n", .{f.name});
                try self.dumpNode(writer, f.value, depth + 1);
            },
            .enum_variant => |v| {
                try writer.print("Variant({s})\n", .{v.name});
                if (v.payload) |p| {
                    // Payload fields inline at +1 (no `Payload` wrapper header).
                    for (self.extraSlice(self.nodes.items[p].payload)) |fl| {
                        const fd = self.nodes.items[fl].field_decl;
                        try indent(writer, depth + 1);
                        if (fd.name.len > 0) {
                            try writer.print("Field({s}:)\n", .{fd.name});
                        } else {
                            try writer.writeAll("Field\n");
                        }
                        try self.dumpNode(writer, fd.type_node, depth + 2);
                    }
                }
            },
            .payload => |l| {
                try writer.writeAll("Payload\n");
                for (self.extraSlice(l)) |fl| {
                    const fd = self.nodes.items[fl].field_decl;
                    try indent(writer, depth + 1);
                    if (fd.name.len > 0) {
                        try writer.print("Field({s}:)\n", .{fd.name});
                    } else {
                        try writer.writeAll("Field\n");
                    }
                    try self.dumpNode(writer, fd.type_node, depth + 2);
                }
            },
            .match_arm => |a| {
                try writer.writeAll("Arm\n");
                try self.dumpNode(writer, a.pattern, depth + 1);
                // The seed drops the guard from the dump.
                try self.dumpNode(writer, a.body, depth + 1);
            },
            // Dead node (the seed has no expr_stmt): transparent wrapper.
            .expr_stmt => |e| try self.dumpNode(writer, e, depth),
            .return_stmt => |v| {
                try writer.writeAll("Return\n");
                if (v) |x| try self.dumpNode(writer, x, depth + 1);
            },
            .break_stmt => try writer.writeAll("Break\n"),
            .continue_stmt => try writer.writeAll("Continue\n"),
            .block => |b| {
                try writer.writeAll("Block\n");
                for (self.extraSlice(b.stmts)) |c| try self.dumpNode(writer, c, depth + 1);
                // The seed folds the tail expr into the statement list, no header.
                if (b.tail) |t| try self.dumpNode(writer, t, depth + 1);
            },
            .int_literal => |v| try writer.print("IntLit({d})\n", .{v}),
            .float_literal => |v| {
                try writer.writeAll("FloatLit(");
                try dump_mod.writeG(writer, v);
                try writer.writeAll(")\n");
            },
            .string_literal => |v| try writer.print("StringLit(\"{s}\")\n", .{v}),
            .bool_literal => |v| try writer.print("BoolLit({})\n", .{v}),
            // Dead node (the seed lexes `nil` as an identifier).
            .nil_literal => try writer.writeAll("Ident(nil)\n"),
            .identifier => |v| try writer.print("Ident({s})\n", .{v}),
            .binary_expr => |b| {
                try writer.print("BinaryOp({s})\n", .{b.op.seedName()});
                try self.dumpNode(writer, b.left, depth + 1);
                try self.dumpNode(writer, b.right, depth + 1);
            },
            .unary_expr => |u| {
                try writer.print("UnaryOp({s})\n", .{u.op.seedName()});
                try self.dumpNode(writer, u.operand, depth + 1);
            },
            .call_expr => |c| {
                try writer.writeAll("Call\n");
                try self.dumpNode(writer, c.callee, depth + 1);
                for (self.extraSlice(c.args)) |a| try self.dumpNode(writer, a, depth + 1);
            },
            .index_expr => |i| {
                try writer.writeAll("Index\n");
                try self.dumpNode(writer, i.object, depth + 1);
                try self.dumpNode(writer, i.index, depth + 1);
            },
            .field_access => |f| {
                try writer.print("FieldAccess({s})\n", .{f.field});
                try self.dumpNode(writer, f.object, depth + 1);
            },
            .array_literal => |l| {
                try writer.print("ArrayLit({d})\n", .{l.len});
                for (self.extraSlice(l)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .range_expr => |r| {
                try writer.print("Range({s})\n", .{if (r.inclusive) "..=" else ".."});
                if (r.start_node) |s| try self.dumpNode(writer, s, depth + 1);
                if (r.end_node) |e| try self.dumpNode(writer, e, depth + 1);
            },
            .struct_literal => |s| {
                try writer.print("StructLit({s})\n", .{s.name});
                for (self.extraSlice(s.fields)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .some_expr => |inner| {
                try writer.writeAll("SomeExpr\n");
                try self.dumpNode(writer, inner, depth + 1);
            },
            .none_expr => try writer.writeAll("NoneExpr\n"),
            .ok_expr => |inner| {
                try writer.writeAll("OkExpr\n");
                try self.dumpNode(writer, inner, depth + 1);
            },
            .err_expr => |inner| {
                try writer.writeAll("ErrExpr\n");
                try self.dumpNode(writer, inner, depth + 1);
            },
            .try_expr => |inner| {
                try writer.writeAll("TryExpr\n");
                try self.dumpNode(writer, inner, depth + 1);
            },
            .if_expr => |i| {
                try writer.writeAll("If\n");
                try self.dumpNode(writer, i.cond, depth + 1);
                try self.dumpNode(writer, i.then_block, depth + 1);
                if (i.else_block) |e| {
                    try indent(writer, depth + 1);
                    try writer.writeAll("Else\n");
                    try self.dumpNode(writer, e, depth + 2);
                }
            },
            .while_expr => |w| {
                try writer.writeAll("While\n");
                try self.dumpNode(writer, w.cond, depth + 1);
                try self.dumpNode(writer, w.body, depth + 1);
            },
            .for_expr => |f| {
                try writer.print("For({s})\n", .{f.var_name});
                try self.dumpNode(writer, f.iter, depth + 1);
                try self.dumpNode(writer, f.body, depth + 1);
            },
            .match_expr => |m| {
                try writer.writeAll("Match\n");
                try self.dumpNode(writer, m.target, depth + 1);
                for (self.extraSlice(m.arms)) |a| try self.dumpNode(writer, a, depth + 1);
            },
            .assignment => |a| {
                try writer.writeAll("Assign\n");
                try self.dumpNode(writer, a.target, depth + 1);
                try self.dumpNode(writer, a.value, depth + 1);
            },
            // Dead: the seed's parser rejects `x += 1`; its dump prints a bare
            // line with no children, so mirror that if the node ever appears.
            .compound_assignment => try writer.writeAll("CompoundAssign\n"),
            .pattern_wildcard => try writer.writeAll("PatternWildcard\n"),
            .pattern_bind => |name| try writer.print("PatternBind({s})\n", .{name}),
            .pattern_variant_bind => |v| {
                try writer.writeAll("PatternVariantBind\n");
                try self.dumpNode(writer, v.variant, depth + 1);
                for (self.extraSlice(v.bindings)) |b| {
                    try indent(writer, depth + 1);
                    try writer.print("Bind({s})\n", .{self.nodes.items[b].pattern_bind});
                }
            },
            .pattern_builtin_variant => |v| {
                // BuiltinKind order matches the seed's BuiltinVariantKind:
                // ok=0, err=1, some=2, none=3.
                try writer.print("PatternBuiltinVariant({d})\n", .{@intFromEnum(v.kind)});
                if (v.payload) |p| try self.dumpNode(writer, p, depth + 1);
            },
            .pattern_or => |l| {
                try writer.print("PatternOr({d})\n", .{l.len});
                for (self.extraSlice(l)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .type_ident => |name| try writer.print("TypeIdent({s})\n", .{name}),
            .type_optional => |inner| {
                try writer.writeAll("TypeOptional\n");
                try self.dumpNode(writer, inner, depth + 1);
            },
            .type_array => |a| {
                try writer.writeAll("TypeArray\n");
                try self.dumpNode(writer, a.elem, depth + 1);
                if (a.size) |s| try self.dumpNode(writer, s, depth + 1);
            },
            .type_fn => |f| {
                try writer.writeAll("TypeFn\n");
                for (self.extraSlice(f.params)) |p| try self.dumpNode(writer, p, depth + 1);
                if (f.ret) |r| try self.dumpNode(writer, r, depth + 1);
            },
        }
    }
};

const testing = std.testing;

fn makeSimple(alloc: std.mem.Allocator) !Tree {
    var tree = Tree.init(alloc, "let x = 42;");
    const lit = try tree.addNode(.{ .int_literal = 42 }, .{ .start = 0, .end = 0, .line = 1, .col = 1 });
    const decl = try tree.addNode(.{ .var_decl = .{ .name = "x", .type_node = null, .value = lit, .is_mut = false } }, .{ .start = 0, .end = 0, .line = 1, .col = 1 });
    const list = try tree.addExtra(&.{decl});
    _ = try tree.addNode(.{ .source_file = list }, .{ .start = 0, .end = 0, .line = 1, .col = 1 });
    return tree;
}

test "flat ast stores real child lists" {
    var tree = try makeSimple(testing.allocator);
    defer tree.deinit();

    const var_decl = tree.nodes.items[1];
    try testing.expectEqualStrings("x", var_decl.var_decl.name);
    // Regression: the old stub stored start = 0 for every list, so this list
    // would have pointed at node 0 instead of the single statement.
    const list = tree.nodes.items[2].source_file;
    try testing.expectEqual(@as(u32, 1), list.len);
    try testing.expectEqual(@as(u32, 1), tree.extraSlice(list)[0]);
}

test "ast dump runs" {
    var tree = try makeSimple(testing.allocator);
    defer tree.deinit();
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tree.dump(&w, 2);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "IntLit(42)") != null);
}
