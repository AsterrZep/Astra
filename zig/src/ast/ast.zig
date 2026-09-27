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

    // Declarations / auxiliary nodes
    param,
    field_decl,
    struct_init_field,
    enum_variant,
    payload,
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

pub const FnDecl = struct { name: []const u8, params: List, ret: ?u32, body: u32 };
pub const Lambda = struct { params: List, ret: ?u32, body: u32 };
pub const StructDecl = struct { name: []const u8, fields: List };
pub const EnumDecl = struct { name: []const u8, variants: List };
pub const VarDecl = struct { name: []const u8, type_node: ?u32, value: ?u32, is_mut: bool };
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
pub const FieldAccess = struct { object: u32, field: []const u8 };
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
    param: Param,
    field_decl: FieldDecl,
    struct_init_field: StructInitField,
    enum_variant: EnumVariant,
    payload: List, // list of `field_decl` nodes
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

    /// Stable, indented dump used by `--dump-ast` and the conformance test.
    /// Starts at `root` — node 0 is whichever node the parser created first, not
    /// necessarily the module.
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
                try writer.print("source_file ({d} items)\n", .{l.len});
                for (self.extraSlice(l)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .fn_decl => |f| {
                try writer.print("fn_decl {s}\n", .{f.name});
                try indent(writer, depth + 1);
                try writer.writeAll("params\n");
                for (self.extraSlice(f.params)) |c| try self.dumpNode(writer, c, depth + 2);
                if (f.ret) |r| {
                    try indent(writer, depth + 1);
                    try writer.writeAll("ret\n");
                    try self.dumpNode(writer, r, depth + 2);
                }
                try self.dumpNode(writer, f.body, depth + 1);
            },
            .lambda_expr => |f| {
                try writer.writeAll("lambda\n");
                for (self.extraSlice(f.params)) |c| try self.dumpNode(writer, c, depth + 1);
                if (f.ret) |r| try self.dumpNode(writer, r, depth + 1);
                try self.dumpNode(writer, f.body, depth + 1);
            },
            .struct_decl => |s| {
                try writer.print("struct_decl {s}\n", .{s.name});
                for (self.extraSlice(s.fields)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .enum_decl => |e| {
                try writer.print("enum_decl {s}\n", .{e.name});
                for (self.extraSlice(e.variants)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .var_decl, .const_decl => {
                const v = n.var_decl; // both share the same payload shape
                try writer.print("{s} {s}{s}\n", .{
                    @tagName(n),
                    v.name,
                    if (v.is_mut) " (mut)" else "",
                });
                if (v.type_node) |t| try self.dumpNode(writer, t, depth + 1);
                if (v.value) |val| try self.dumpNode(writer, val, depth + 1);
            },
            .use_decl => |path| try writer.print("use_decl {s}\n", .{path}),
            .param => |p| {
                try writer.print("param {s}: ", .{p.name});
                if (p.type_node) |t| try self.dumpInline(writer, t) else try writer.writeAll("<inferred>");
                try writer.writeByte('\n');
            },
            .field_decl => |f| {
                try writer.print("field {s}: ", .{f.name});
                try self.dumpInline(writer, f.type_node);
                try writer.writeByte('\n');
            },
            .struct_init_field => |f| {
                try writer.print("init {s} =\n", .{f.name});
                try self.dumpNode(writer, f.value, depth + 1);
            },
            .enum_variant => |v| {
                try writer.print("variant {s}\n", .{v.name});
                if (v.payload) |p| try self.dumpNode(writer, p, depth + 1);
            },
            .payload => |l| {
                try writer.writeAll("payload\n");
                for (self.extraSlice(l)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .match_arm => |a| {
                try writer.writeAll("arm\n");
                try self.dumpNode(writer, a.pattern, depth + 1);
                if (a.guard) |g| {
                    try indent(writer, depth + 1);
                    try writer.writeAll("guard\n");
                    try self.dumpNode(writer, g, depth + 2);
                }
                try self.dumpNode(writer, a.body, depth + 1);
            },
            .expr_stmt => |e| {
                try writer.writeAll("expr_stmt\n");
                try self.dumpNode(writer, e, depth + 1);
            },
            .return_stmt => |v| {
                try writer.writeAll("return\n");
                if (v) |x| try self.dumpNode(writer, x, depth + 1);
            },
            .break_stmt => try writer.writeAll("break\n"),
            .continue_stmt => try writer.writeAll("continue\n"),
            .block => |b| {
                try writer.writeAll("block\n");
                for (self.extraSlice(b.stmts)) |c| try self.dumpNode(writer, c, depth + 1);
                if (b.tail) |t| {
                    try indent(writer, depth + 1);
                    try writer.writeAll("tail\n");
                    try self.dumpNode(writer, t, depth + 2);
                }
            },
            .int_literal => |v| try writer.print("int {d}\n", .{v}),
            .float_literal => |v| try writer.print("float {d}\n", .{v}),
            .string_literal => |v| try writer.print("string \"{s}\"\n", .{v}),
            .bool_literal => |v| try writer.print("bool {}\n", .{v}),
            .nil_literal => try writer.writeAll("nil\n"),
            .identifier => |v| try writer.print("ident {s}\n", .{v}),
            .binary_expr => |b| {
                try writer.print("binary {s}\n", .{@tagName(b.op)});
                try self.dumpNode(writer, b.left, depth + 1);
                try self.dumpNode(writer, b.right, depth + 1);
            },
            .unary_expr => |u| {
                try writer.print("unary {s}\n", .{@tagName(u.op)});
                try self.dumpNode(writer, u.operand, depth + 1);
            },
            .call_expr => |c| {
                try writer.writeAll("call\n");
                try self.dumpNode(writer, c.callee, depth + 1);
                for (self.extraSlice(c.args)) |a| try self.dumpNode(writer, a, depth + 1);
            },
            .index_expr => |i| {
                try writer.writeAll("index\n");
                try self.dumpNode(writer, i.object, depth + 1);
                try self.dumpNode(writer, i.index, depth + 1);
            },
            .field_access => |f| {
                try writer.print("field .{s}\n", .{f.field});
                try self.dumpNode(writer, f.object, depth + 1);
            },
            .array_literal => |l| {
                try writer.print("array ({d})\n", .{l.len});
                for (self.extraSlice(l)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .range_expr => |r| {
                try writer.print("range {s}\n", .{if (r.inclusive) "..=" else ".."});
                if (r.start_node) |s| try self.dumpNode(writer, s, depth + 1);
                if (r.end_node) |e| try self.dumpNode(writer, e, depth + 1);
            },
            .struct_literal => |s| {
                try writer.print("struct_lit {s}\n", .{s.name});
                for (self.extraSlice(s.fields)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .some_expr, .ok_expr, .err_expr, .try_expr => |inner| {
                try writer.print("{s}\n", .{@tagName(n)});
                try self.dumpNode(writer, inner, depth + 1);
            },
            .none_expr => try writer.writeAll("none\n"),
            .if_expr => |i| {
                try writer.writeAll("if\n");
                try self.dumpNode(writer, i.cond, depth + 1);
                try self.dumpNode(writer, i.then_block, depth + 1);
                if (i.else_block) |e| {
                    try indent(writer, depth + 1);
                    try writer.writeAll("else\n");
                    try self.dumpNode(writer, e, depth + 2);
                }
            },
            .while_expr => |w| {
                try writer.writeAll("while\n");
                try self.dumpNode(writer, w.cond, depth + 1);
                try self.dumpNode(writer, w.body, depth + 1);
            },
            .for_expr => |f| {
                try writer.print("for {s} in\n", .{f.var_name});
                try self.dumpNode(writer, f.iter, depth + 1);
                try self.dumpNode(writer, f.body, depth + 1);
            },
            .match_expr => |m| {
                try writer.writeAll("match\n");
                try self.dumpNode(writer, m.target, depth + 1);
                for (self.extraSlice(m.arms)) |a| try self.dumpNode(writer, a, depth + 1);
            },
            .assignment => |a| {
                try writer.writeAll("assign\n");
                try self.dumpNode(writer, a.target, depth + 1);
                try self.dumpNode(writer, a.value, depth + 1);
            },
            .compound_assignment => |a| {
                try writer.print("compound_assign {s}\n", .{@tagName(a.op)});
                try self.dumpNode(writer, a.target, depth + 1);
                try self.dumpNode(writer, a.value, depth + 1);
            },
            .pattern_wildcard => try writer.writeAll("pattern _\n"),
            .pattern_bind => |name| try writer.print("pattern bind {s}\n", .{name}),
            .pattern_variant_bind => |v| {
                try writer.writeAll("pattern variant\n");
                try self.dumpNode(writer, v.variant, depth + 1);
                for (self.extraSlice(v.bindings)) |b| try self.dumpNode(writer, b, depth + 1);
            },
            .pattern_builtin_variant => |v| {
                try writer.print("pattern {s}\n", .{@tagName(v.kind)});
                if (v.payload) |p| try self.dumpNode(writer, p, depth + 1);
            },
            .pattern_or => |l| {
                try writer.writeAll("pattern or\n");
                for (self.extraSlice(l)) |c| try self.dumpNode(writer, c, depth + 1);
            },
            .type_ident => |name| try writer.print("type {s}\n", .{name}),
            .type_optional => |inner| {
                try writer.writeAll("type optional\n");
                try self.dumpNode(writer, inner, depth + 1);
            },
            .type_array => |a| {
                try writer.writeAll("type array\n");
                try self.dumpNode(writer, a.elem, depth + 1);
                if (a.size) |s| try self.dumpNode(writer, s, depth + 1);
            },
            .type_fn => |f| {
                try writer.writeAll("type fn\n");
                for (self.extraSlice(f.params)) |p| try self.dumpNode(writer, p, depth + 1);
                if (f.ret) |r| try self.dumpNode(writer, r, depth + 1);
            },
        }
    }

    /// Single-line rendering for types, to keep param/field lines compact.
    fn dumpInline(self: *const Tree, writer: anytype, idx: u32) !void {
        const n = self.nodes.items[idx];
        switch (n) {
            .type_ident => |name| try writer.writeAll(name),
            .type_optional => |inner| {
                try self.dumpInline(writer, inner);
                try writer.writeByte('?');
            },
            .type_array => |a| {
                try writer.writeByte('[');
                try self.dumpInline(writer, a.elem);
                try writer.writeByte(']');
            },
            .type_fn => |f| {
                try writer.writeAll("fn(");
                for (self.extraSlice(f.params), 0..) |p, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.dumpInline(writer, p);
                }
                try writer.writeAll(") -> ");
                if (f.ret) |r| try self.dumpInline(writer, r) else try writer.writeAll("void");
            },
            else => try writer.print("<{s}>", .{@tagName(n)}),
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
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "int 42") != null);
}
