//! Astra-0 type checker (Phase 2, Zig).
//!
//! A port of `seed/src/typechecker.c`. The behaviour that matters is parity: a
//! program the seed rejects must be rejected here with a diagnostic containing
//! the same phrase (`seed/tests/conformance/ui/*` matches on substrings).
//!
//! Three rules from the seed are easy to lose and are preserved deliberately:
//!
//! 1. **Integer literals are polymorphic** (`COHERENCE_AUDIT.md` Hallazgo E):
//!    `TYPE_INT_LITERAL` unifies with any integer width, and an unannotated
//!    binding resolves it to the default `i32`.
//! 2. **`nil` unifies with any optional** and `TYPE_UNKNOWN` matches anything
//!    (used by the polymorphic builtin `print`).
//! 3. **Scope removal by insertion sequence**, never by hash order: popping a
//!    scope removes exactly the symbols introduced since it was pushed, so
//!    builtins like `print` can never be evicted by an inner pop.

const std = @import("std");
const lexer = @import("../lexer/lexer.zig");
const ast = @import("../ast/ast.zig");
const parser = @import("../parser/parser.zig");

fn isTag(n: ast.Node, tag: ast.Tag) bool {
    return std.meta.activeTag(n) == tag;
}

pub const Kind = enum {
    void,
    bool_,
    int, // i32
    int64,
    uint32,
    uint64,
    int_literal, // polymorphic integer literal (no width yet)
    float, // f64
    string,
    optional,
    array,
    fn_type,
    struct_,
    enum_,
    nil,
    unknown,
    error_,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .void => "void",
            .bool_ => "bool",
            .int => "i32",
            .int_literal => "integer literal",
            .int64 => "i64",
            .uint32 => "u32",
            .uint64 => "u64",
            .float => "f64",
            .string => "string",
            .optional => "optional",
            .array => "array",
            .fn_type => "fn",
            .struct_ => "struct",
            .enum_ => "enum",
            .nil => "nil",
            .unknown => "unknown",
            .error_ => "<error>",
        };
    }
};

pub const Field = struct { name: []const u8, type_: *Type };

/// Compile-time payload layout of one data-carrying variant, parallel to
/// `variants`. Unnamed fields keep an empty name.
pub const VariantLayout = struct {
    names: []const []const u8 = &.{},
    types: []const *Type = &.{},
    field_count: usize = 0,
};

pub const Type = struct {
    kind: Kind,
    inner: ?*Type = null, // optional
    elem: ?*Type = null, // array
    params: []const *Type = &.{}, // fn
    ret: ?*Type = null, // fn
    name: []const u8 = "", // struct / enum
    fields: []const Field = &.{}, // struct
    variants: []const []const u8 = &.{}, // enum
    payloads: []const VariantLayout = &.{}, // enum
};

const Symbol = struct {
    name: []const u8,
    type_: *Type,
    is_mut: bool,
    is_fn: bool,
};

const Variant = struct { name: []const u8, enum_type: *Type };

fn isInteger(t: *const Type) bool {
    return switch (t.kind) {
        .int, .int64, .uint32, .uint64, .int_literal => true,
        else => false,
    };
}

fn isNumeric(t: *const Type) bool {
    return isInteger(t) or t.kind == .float;
}

/// Port of `type_eq` (seed/src/typechecker.c).
pub fn typeEq(a: *const Type, b: *const Type) bool {
    if (a.kind == .unknown or b.kind == .unknown) return true;
    if ((a.kind == .nil and b.kind == .optional) or (a.kind == .optional and b.kind == .nil)) return true;
    if (a.kind == .int_literal and b.kind != .int_literal) return isInteger(b);
    if (b.kind == .int_literal and a.kind != .int_literal) return isInteger(a);
    if (a.kind != b.kind) return false;
    return switch (a.kind) {
        .optional => typeEq(a.inner.?, b.inner.?),
        .array => typeEq(a.elem.?, b.elem.?),
        .fn_type => blk: {
            if (a.params.len != b.params.len) break :blk false;
            for (a.params, b.params) |pa, pb| {
                if (!typeEq(pa, pb)) break :blk false;
            }
            const ar = a.ret orelse voidType;
            const br = b.ret orelse voidType;
            break :blk typeEq(ar, br);
        },
        .struct_ => std.mem.eql(u8, a.name, b.name),
        .enum_ => std.mem.eql(u8, a.name, b.name),
        else => true,
    };
}

fn isErrorType(t: *const Type) bool {
    return t.kind == .error_;
}

var voidTypeInstance = Type{ .kind = .void };
var voidType: *Type = &voidTypeInstance;

pub const TypeChecker = struct {
    a: std.mem.Allocator,
    filename: []const u8,
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    scopes: std.ArrayListUnmanaged(usize) = .empty,
    variants: std.ArrayListUnmanaged(Variant) = .empty,
    current_fn_return: ?*Type = null,
    // Location of the function currently being checked, used for body-level
    // diagnostics (`checkFnDecl` sets it before `checkFnBody`).
    pending_fn_loc: lexer.Loc = .{ .start = 0, .end = 0, .line = 0, .col = 0 },
    error_count: usize = 0,
    tree: *ast.Tree,

    pub fn init(a: std.mem.Allocator, tree: *ast.Tree, filename: []const u8) !TypeChecker {
        var tc = TypeChecker{ .a = a, .filename = filename, .tree = tree };
        try tc.registerBuiltins();
        return tc;
    }

    // ── Type constructors ─────────────────────────────────────────

    fn newType(self: *TypeChecker, kind: Kind) *Type {
        const t = self.a.create(Type) catch @panic("OOM");
        t.* = .{ .kind = kind };
        return t;
    }

    fn newOptional(self: *TypeChecker, inner: *Type) *Type {
        const t = self.newType(.optional);
        t.inner = inner;
        return t;
    }

    fn newArray(self: *TypeChecker, elem: *Type) *Type {
        const t = self.newType(.array);
        t.elem = elem;
        return t;
    }

    fn newFn(self: *TypeChecker, params: []const *Type, ret: ?*Type) *Type {
        const t = self.newType(.fn_type);
        t.params = params;
        t.ret = ret;
        return t;
    }

    // ── Symbol table ──────────────────────────────────────────────

    fn lookup(self: *TypeChecker, name: []const u8) ?*Symbol {
        var i = self.symbols.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.symbols.items[i].name, name)) return &self.symbols.items[i];
        }
        return null;
    }

    fn insert(self: *TypeChecker, sym: Symbol) void {
        self.symbols.append(self.a, sym) catch @panic("OOM");
    }

    fn pushScope(self: *TypeChecker) void {
        self.scopes.append(self.a, self.symbols.items.len) catch @panic("OOM");
    }

    /// Remove exactly the symbols introduced since this scope was pushed
    /// (`AGENTS.md` invariant #4; seed comment in `symbol_table_pop_scope`).
    fn popScope(self: *TypeChecker) void {
        if (self.scopes.items.len == 0) return;
        const cutoff = self.scopes.items[self.scopes.items.len - 1];
        _ = self.scopes.pop();
        self.symbols.shrinkRetainingCapacity(cutoff);
    }

    // ── Variant registry ──────────────────────────────────────────

    fn addVariant(self: *TypeChecker, name: []const u8, enum_type: *Type) void {
        self.variants.append(self.a, .{ .name = name, .enum_type = enum_type }) catch @panic("OOM");
    }

    fn findVariant(self: *TypeChecker, name: []const u8) ?*Type {
        for (self.variants.items) |v| {
            if (std.mem.eql(u8, v.name, name)) return v.enum_type;
        }
        return null;
    }

    fn enumVariantIndex(en: *const Type, variant: []const u8) ?usize {
        if (en.kind != .enum_) return null;
        for (en.variants, 0..) |v, i| {
            if (std.mem.eql(u8, v, variant)) return i;
        }
        return null;
    }

    // ── Diagnostics ───────────────────────────────────────────────

    fn errFmt(self: *TypeChecker, loc: lexer.Loc, comptime fmt: []const u8, args: anytype) void {
        self.error_count += 1;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "type error";
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ self.filename, loc.line, loc.col, msg });
    }

    fn errorType(self: *TypeChecker, loc: lexer.Loc, comptime fmt: []const u8, args: anytype) *Type {
        self.errFmt(loc, fmt, args);
        return self.newType(.error_);
    }

    // ── Builtins (seed typechecker_create) ────────────────────────

    fn registerBuiltins(self: *TypeChecker) !void {
        // print(value) -> void
        const print_params = try self.a.alloc(*Type, 1);
        print_params[0] = self.newType(.unknown);
        self.insert(.{ .name = "print", .type_ = self.newFn(print_params, self.newType(.void)), .is_mut = false, .is_fn = true });

        // Option: some(T) -> Option, none -> Option
        {
            const opt = self.newType(.enum_);
            opt.name = "Option";
            const vs = try self.a.alloc([]const u8, 2);
            vs[0] = "some";
            vs[1] = "none";
            opt.variants = vs;
            const pls = try self.a.alloc(VariantLayout, 2);
            const some_types = try self.a.alloc(*Type, 1);
            some_types[0] = self.newType(.unknown);
            pls[0] = .{ .field_count = 1, .types = some_types };
            pls[1] = .{ .field_count = 0 };
            opt.payloads = pls;
            self.addVariant("some", opt);
            self.addVariant("none", opt);
        }

        // Result: ok(T) -> Result, err(E) -> Result
        {
            const res = self.newType(.enum_);
            res.name = "Result";
            const vs = try self.a.alloc([]const u8, 2);
            vs[0] = "ok";
            vs[1] = "err";
            res.variants = vs;
            const pls = try self.a.alloc(VariantLayout, 2);
            const ok_t = try self.a.alloc(*Type, 1);
            ok_t[0] = self.newType(.unknown);
            const err_t = try self.a.alloc(*Type, 1);
            err_t[0] = self.newType(.unknown);
            pls[0] = .{ .field_count = 1, .types = ok_t };
            pls[1] = .{ .field_count = 1, .types = err_t };
            res.payloads = pls;
            self.addVariant("ok", res);
            self.addVariant("err", res);
        }
    }

    // ── Type node resolution ──────────────────────────────────────

    fn resolveTypeNode(self: *TypeChecker, idx: ?u32) *Type {
        const i = idx orelse return self.newType(.unknown);
        const loc = self.tree.loc(i);
        return switch (self.tree.node(i)) {
            .type_ident => |name| blk: {
                if (std.mem.eql(u8, name, "void")) break :blk self.newType(.void);
                if (std.mem.eql(u8, name, "bool")) break :blk self.newType(.bool_);
                if (std.mem.eql(u8, name, "i32")) break :blk self.newType(.int);
                if (std.mem.eql(u8, name, "i64")) break :blk self.newType(.int64);
                if (std.mem.eql(u8, name, "u32")) break :blk self.newType(.uint32);
                if (std.mem.eql(u8, name, "u64")) break :blk self.newType(.uint64);
                if (std.mem.eql(u8, name, "f64")) break :blk self.newType(.float);
                if (std.mem.eql(u8, name, "string")) break :blk self.newType(.string);
                if (self.lookup(name)) |sym| break :blk sym.type_;
                break :blk self.errorType(loc, "unknown type '{s}'", .{name});
            },
            .type_optional => |inner| blk: {
                const t = self.resolveTypeNode(inner);
                if (isErrorType(t)) break :blk t;
                break :blk self.newOptional(t);
            },
            .type_array => |arr| blk: {
                const elem = self.resolveTypeNode(arr.elem);
                if (isErrorType(elem)) break :blk elem;
                break :blk self.newArray(elem);
            },
            .type_fn => |f| blk: {
                var params = self.a.alloc(*Type, f.params.len) catch @panic("OOM");
                for (self.tree.extraSlice(f.params), 0..) |p, k| {
                    params[k] = self.resolveTypeNode(p);
                    if (isErrorType(params[k])) break :blk self.newType(.error_);
                }
                const ret = if (f.ret) |r| self.resolveTypeNode(r) else self.newType(.void);
                if (isErrorType(ret)) break :blk ret;
                break :blk self.newFn(params, ret);
            },
            else => self.errorType(loc, "invalid type expression", .{}),
        };
    }

    // ── Expressions ───────────────────────────────────────────────

    fn checkIdent(self: *TypeChecker, name: []const u8, loc: lexer.Loc) *Type {
        if (self.lookup(name)) |sym| return sym.type_;
        return self.errorType(loc, "undefined variable '{s}'", .{name});
    }

    fn checkBinary(self: *TypeChecker, op: lexer.Tag, left_idx: u32, right_idx: u32, loc: lexer.Loc) *Type {
        const left = self.checkNode(left_idx);
        const right = self.checkNode(right_idx);
        if (isErrorType(left)) return left;
        if (isErrorType(right)) return right;

        switch (op) {
            .and_and, .or_or => {
                if (left.kind != .bool_) return self.errorType(self.tree.loc(left_idx), "logical operator requires bool, got {s}", .{left.kind.name()});
                if (right.kind != .bool_) return self.errorType(self.tree.loc(right_idx), "logical operator requires bool, got {s}", .{right.kind.name()});
                return self.newType(.bool_);
            },
            .plus => {
                if (left.kind == .string and right.kind == .string) return left;
            },
            else => {},
        }

        if (op == .plus or op == .minus or op == .star or op == .slash or op == .percent) {
            if (!isNumeric(left)) return self.errorType(self.tree.loc(left_idx), "arithmetic operator requires numeric type, got {s}", .{left.kind.name()});
            if (!isNumeric(right)) return self.errorType(self.tree.loc(right_idx), "arithmetic operator requires numeric type, got {s}", .{right.kind.name()});
            if (!typeEq(left, right)) {
                return self.errorType(loc, "type mismatch: cannot apply '{s}' to {s} and {s}", .{ opName(op), left.kind.name(), right.kind.name() });
            }
            return if (left.kind == .int_literal) right else left;
        }

        if (op == .eq_eq or op == .neq or op == .lt or op == .gt or op == .le or op == .ge) {
            if (!typeEq(left, right)) {
                return self.errorType(loc, "type mismatch: cannot compare {s} and {s}", .{ left.kind.name(), right.kind.name() });
            }
            return self.newType(.bool_);
        }

        if (op == .amp or op == .pipe or op == .caret or op == .shl or op == .shr) {
            if (!isInteger(left)) return self.errorType(self.tree.loc(left_idx), "bitwise operator requires integer type, got {s}", .{left.kind.name()});
            if (!isInteger(right)) return self.errorType(self.tree.loc(right_idx), "bitwise operator requires integer type, got {s}", .{right.kind.name()});
            return if (left.kind == .int_literal) right else left;
        }

        return self.newType(.error_);
    }

    fn checkUnary(self: *TypeChecker, op: lexer.Tag, operand_idx: u32, loc: lexer.Loc) *Type {
        const operand = self.checkNode(operand_idx);
        if (isErrorType(operand)) return operand;
        return switch (op) {
            .minus => if (isNumeric(operand)) operand else self.errorType(loc, "negation requires numeric type, got {s}", .{operand.kind.name()}),
            .bang => if (operand.kind == .bool_) self.newType(.bool_) else self.errorType(loc, "logical not requires bool, got {s}", .{operand.kind.name()}),
            .tilde => if (isInteger(operand)) operand else self.errorType(loc, "bitwise not requires integer type, got {s}", .{operand.kind.name()}),
            else => self.errorType(loc, "operator not supported in Astra-0", .{}),
        };
    }

    fn checkCall(self: *TypeChecker, callee_idx: u32, args: ast.List, loc: lexer.Loc) *Type {
        const arg_slice = self.tree.extraSlice(args);

        // A bare identifier callee may name a data-carrying enum variant.
        if (isTag(self.tree.node(callee_idx), .identifier)) {
            const vname = self.tree.node(callee_idx).identifier;
            if (self.findVariant(vname)) |et| {
                const sym = self.lookup(vname);
                if (!(sym != null and sym.?.is_fn)) {
                    if (enumVariantIndex(et, vname)) |vi| {
                        const vl = if (vi < et.payloads.len) et.payloads[vi] else VariantLayout{};
                        if (arg_slice.len != vl.field_count) {
                            return self.errorType(loc, "variant '{s}.{s}' expects {d} field(s), got {d}", .{ et.name, vname, vl.field_count, arg_slice.len });
                        }
                        for (arg_slice, 0..) |arg, i| {
                            const at = self.checkNode(arg);
                            if (isErrorType(at)) return at;
                            if (i < vl.types.len and vl.types[i].kind != .unknown) {
                                const expected = vl.types[i];
                                if (!typeEq(at, expected)) {
                                    return self.errorType(loc, "field {d} of '{s}.{s}' expects {s}, got {s}", .{ i + 1, et.name, vname, expected.kind.name(), at.kind.name() });
                                }
                            }
                        }
                        return et;
                    }
                }
            }
        }

        const callee = self.checkNode(callee_idx);
        if (isErrorType(callee)) return callee;
        if (callee.kind != .fn_type) {
            return self.errorType(self.tree.loc(callee_idx), "cannot call non-function type {s}", .{callee.kind.name()});
        }
        if (arg_slice.len != callee.params.len) {
            return self.errorType(loc, "expected {d} arguments, got {d}", .{ callee.params.len, arg_slice.len });
        }
        for (arg_slice, 0..) |arg, i| {
            const at = self.checkNode(arg);
            if (isErrorType(at)) return at;
            if (!typeEq(at, callee.params[i])) {
                return self.errorType(loc, "argument {d}: expected {s}, got {s}", .{ i + 1, callee.params[i].kind.name(), at.kind.name() });
            }
        }
        return callee.ret orelse self.newType(.void);
    }

    fn checkArrayLit(self: *TypeChecker, elems: ast.List) *Type {
        const list = self.tree.extraSlice(elems);
        if (list.len == 0) return self.newArray(self.newType(.unknown));
        const elem_type = self.checkNode(list[0]);
        if (isErrorType(elem_type)) return elem_type;
        for (list[1..], 1..) |e, i| {
            const t = self.checkNode(e);
            if (isErrorType(t)) return t;
            if (!typeEq(elem_type, t)) {
                return self.errorType(self.tree.loc(e), "array element {d} has type {s}, expected {s}", .{ i + 1, t.kind.name(), elem_type.kind.name() });
            }
        }
        return self.newArray(elem_type);
    }

    fn checkIndex(self: *TypeChecker, object_idx: u32, index_idx: u32) *Type {
        const object = self.checkNode(object_idx);
        if (isErrorType(object)) return object;
        if (object.kind != .array) {
            return self.errorType(self.tree.loc(object_idx), "cannot index non-array type {s}", .{object.kind.name()});
        }
        const index = self.checkNode(index_idx);
        if (isErrorType(index)) return index;
        if (!isInteger(index)) {
            return self.errorType(self.tree.loc(index_idx), "array index must be integer type, got {s}", .{index.kind.name()});
        }
        return object.elem.?;
    }

    fn checkStructLit(self: *TypeChecker, name: []const u8, fields: ast.List, loc: lexer.Loc) *Type {
        const sym = self.lookup(name) orelse return self.errorType(loc, "unknown struct '{s}'", .{name});
        if (sym.type_.kind != .struct_) return self.errorType(loc, "unknown struct '{s}'", .{name});
        const st = sym.type_;

        // Unknown fields first.
        for (self.tree.extraSlice(fields)) |fidx| {
            const fname = self.tree.node(fidx).struct_init_field.name;
            var found = false;
            for (st.fields) |f| {
                if (std.mem.eql(u8, f.name, fname)) {
                    found = true;
                    break;
                }
            }
            if (!found) return self.errorType(loc, "struct '{s}' has no field '{s}'", .{ name, fname });
        }

        // Every declared field initialised exactly once, with a compatible type.
        for (st.fields) |f| {
            var vi: ?usize = null;
            for (self.tree.extraSlice(fields), 0..) |fidx, j| {
                if (std.mem.eql(u8, self.tree.node(fidx).struct_init_field.name, f.name)) {
                    vi = j;
                    break;
                }
            }
            const j = vi orelse return self.errorType(loc, "missing field '{s}' in '{s}' literal", .{ f.name, name });
            const val_idx = self.tree.extraSlice(fields)[j];
            const val = self.tree.node(val_idx).struct_init_field.value;
            const vt = self.checkNode(val);
            if (isErrorType(vt)) return vt;
            if (!typeEq(f.type_, vt)) {
                return self.errorType(self.tree.loc(val), "field '{s}' expects {s}, got {s}", .{ f.name, f.type_.kind.name(), vt.kind.name() });
            }
        }
        return st;
    }

    fn checkFieldAccess(self: *TypeChecker, object_idx: u32, field: []const u8, loc: lexer.Loc) *Type {
        const object = self.checkNode(object_idx);
        if (isErrorType(object)) return object;

        if (object.kind == .enum_) {
            if (enumVariantIndex(object, field) == null) {
                return self.errorType(loc, "enum '{s}' has no variant '{s}'", .{ object.name, field });
            }
            return object;
        }
        if (object.kind != .struct_) {
            return self.errorType(self.tree.loc(object_idx), "cannot access field on non-struct type {s}", .{object.kind.name()});
        }
        for (object.fields) |f| {
            if (std.mem.eql(u8, f.name, field)) return f.type_;
        }
        return self.errorType(loc, "struct '{s}' has no field '{s}'", .{ object.name, field });
    }

    fn checkBlock(self: *TypeChecker, b: ast.Block) *Type {
        self.pushScope();
        for (self.tree.extraSlice(b.stmts)) |s| _ = self.checkNode(s);
        const result = if (b.tail) |t| self.checkNode(t) else self.newType(.void);
        self.popScope();
        return result;
    }

    fn checkIf(self: *TypeChecker, i: ast.IfExpr, loc: lexer.Loc) *Type {
        const cond = self.checkNode(i.cond);
        if (isErrorType(cond)) return cond;
        if (cond.kind != .bool_ and cond.kind != .optional) {
            self.errFmt(self.tree.loc(i.cond), "if condition must be bool, got {s}", .{cond.kind.name()});
        }
        const then_type = self.checkNode(i.then_block);
        if (i.else_block) |e| {
            const else_type = self.checkNode(e);
            if (!typeEq(then_type, else_type)) {
                return self.errorType(loc, "if branches have different types: {s} vs {s}", .{ then_type.kind.name(), else_type.kind.name() });
            }
            return then_type;
        }
        return self.newType(.void);
    }

    fn checkWhile(self: *TypeChecker, w: ast.WhileExpr) *Type {
        const cond = self.checkNode(w.cond);
        if (isErrorType(cond)) return cond;
        if (cond.kind != .bool_) {
            self.errFmt(self.tree.loc(w.cond), "while condition must be bool, got {s}", .{cond.kind.name()});
        }
        _ = self.checkNode(w.body);
        return self.newType(.void);
    }

    fn checkFor(self: *TypeChecker, f: ast.ForExpr) *Type {
        var var_type: *Type = undefined;
        if (isTag(self.tree.node(f.iter), .range_expr)) {
            const r = self.tree.node(f.iter).range_expr;
            if (r.end_node == null) {
                return self.errorType(self.tree.loc(f.iter), "open-ended ranges are not supported in Astra-0", .{});
            }
            if (r.start_node) |s| {
                const st = self.checkNode(s);
                if (isErrorType(st)) return st;
                if (!isInteger(st)) return self.errorType(self.tree.loc(s), "range start must be integer type, got {s}", .{st.kind.name()});
            }
            const et = self.checkNode(r.end_node.?);
            if (isErrorType(et)) return et;
            if (!isInteger(et)) return self.errorType(self.tree.loc(r.end_node.?), "range end must be integer type, got {s}", .{et.kind.name()});
            var_type = self.newType(.int);
        } else {
            const iter = self.checkNode(f.iter);
            if (isErrorType(iter)) return iter;
            if (iter.kind != .array) {
                return self.errorType(self.tree.loc(f.iter), "for loop must iterate over an array or range, got {s}", .{iter.kind.name()});
            }
            var_type = iter.elem.?;
        }

        self.pushScope();
        self.insert(.{ .name = f.var_name, .type_ = var_type, .is_mut = false, .is_fn = false });
        _ = self.checkNode(f.body);
        self.popScope();
        return self.newType(.void);
    }

    fn checkPattern(self: *TypeChecker, pat_idx: u32, target: *Type, has_wildcard: *bool, covered: []bool) void {
        const pat = self.tree.node(pat_idx);
        switch (pat) {
            .pattern_wildcard => has_wildcard.* = true,
            .pattern_or => |alts| {
                for (self.tree.extraSlice(alts)) |alt| self.checkPattern(alt, target, has_wildcard, covered);
            },
            .field_access => |fa| {
                const obj = self.tree.node(fa.object);
                if (!isTag(obj, .identifier)) {
                    self.errFmt(self.tree.loc(pat_idx), "pattern must be a literal, `_` or Enum.Variant", .{});
                    return;
                }
                const et = self.checkIdent(obj.identifier, self.tree.loc(fa.object));
                if (isErrorType(et)) return;
                if (et.kind != .enum_) {
                    self.errFmt(self.tree.loc(pat_idx), "pattern must be a literal, `_` or Enum.Variant", .{});
                    return;
                }
                if (!typeEq(et, target)) {
                    self.errFmt(self.tree.loc(pat_idx), "pattern type {s} does not match match target type {s}", .{ et.kind.name(), target.kind.name() });
                    return;
                }
                if (enumVariantIndex(et, fa.field)) |vi| {
                    if (vi < covered.len) covered[vi] = true;
                } else {
                    self.errFmt(self.tree.loc(pat_idx), "enum '{s}' has no variant '{s}'", .{ et.name, fa.field });
                }
            },
            .int_literal, .float_literal, .string_literal, .bool_literal, .unary_expr => {
                const pt = self.checkNode(pat_idx);
                if (isErrorType(pt)) return;
                if (!typeEq(pt, target)) {
                    self.errFmt(self.tree.loc(pat_idx), "pattern type {s} does not match match target type {s}", .{ pt.kind.name(), target.kind.name() });
                }
            },
            .pattern_bind => |name| {
                self.insert(.{ .name = name, .type_ = target, .is_mut = false, .is_fn = false });
            },
            .pattern_variant_bind => |vb| {
                const var_path = self.tree.node(vb.variant);
                if (!isTag(var_path, .field_access)) {
                    self.errFmt(self.tree.loc(pat_idx), "pattern must be a literal, `_` or Enum.Variant", .{});
                    return;
                }
                const fa = var_path.field_access;
                const obj = self.tree.node(fa.object);
                if (!isTag(obj, .identifier)) {
                    self.errFmt(self.tree.loc(pat_idx), "pattern must be a literal, `_` or Enum.Variant", .{});
                    return;
                }
                const et = self.checkIdent(obj.identifier, self.tree.loc(fa.object));
                if (isErrorType(et)) return;
                if (et.kind != .enum_) {
                    self.errFmt(self.tree.loc(pat_idx), "pattern must be a literal, `_` or Enum.Variant", .{});
                    return;
                }
                if (!typeEq(et, target)) {
                    self.errFmt(self.tree.loc(pat_idx), "pattern type {s} does not match match target type {s}", .{ et.kind.name(), target.kind.name() });
                    return;
                }
                const vi = enumVariantIndex(et, fa.field) orelse {
                    self.errFmt(self.tree.loc(pat_idx), "enum '{s}' has no variant '{s}'", .{ et.name, fa.field });
                    return;
                };
                if (vi < covered.len) covered[vi] = true;

                const bindings = self.tree.extraSlice(vb.bindings);
                if (vi < et.payloads.len) {
                    const vl = et.payloads[vi];
                    if (bindings.len != vl.field_count) {
                        self.errFmt(self.tree.loc(pat_idx), "variant '{s}' has {d} fields but pattern binds {d}", .{ fa.field, vl.field_count, bindings.len });
                        return;
                    }
                    for (bindings, 0..) |b, k| {
                        self.insert(.{ .name = self.tree.node(b).pattern_bind, .type_ = vl.types[k], .is_mut = false, .is_fn = false });
                    }
                } else if (bindings.len > 0) {
                    self.errFmt(self.tree.loc(pat_idx), "variant '{s}' has no payload but pattern binds {d} names", .{ fa.field, bindings.len });
                }
            },
            .pattern_builtin_variant => |bv| {
                if (bv.kind == .none) return;
                if (bv.payload) |p| self.checkPattern(p, target, has_wildcard, covered);
            },
            else => self.errFmt(self.tree.loc(pat_idx), "unsupported pattern in match arm", .{}),
        }
    }

    fn checkMatch(self: *TypeChecker, m: ast.MatchExpr, loc: lexer.Loc) *Type {
        const target = self.checkNode(m.target);
        if (isErrorType(target)) return target;

        const covered_n: usize = if (target.kind == .enum_) target.variants.len else 0;
        const covered = self.a.alloc(bool, if (covered_n > 0) covered_n else 1) catch @panic("OOM");
        @memset(covered, false);
        var has_wildcard = false;
        var result_type: ?*Type = null;

        for (self.tree.extraSlice(m.arms)) |arm_idx| {
            const arm = self.tree.node(arm_idx).match_arm;
            self.pushScope();
            self.checkPattern(arm.pattern, target, &has_wildcard, covered[0..covered_n]);
            if (arm.guard) |g| {
                const gt = self.checkNode(g);
                if (!isErrorType(gt) and gt.kind != .bool_) {
                    self.errFmt(self.tree.loc(g), "match guard must be bool, got {s}", .{gt.kind.name()});
                }
            }
            const arm_type = self.checkNode(arm.body);
            if (result_type) |rt| {
                if (!typeEq(rt, arm_type)) {
                    self.errFmt(self.tree.loc(arm.body), "match arm type {s} does not match previous arm type {s}", .{ arm_type.kind.name(), rt.kind.name() });
                }
            } else {
                result_type = arm_type;
            }
            self.popScope();
        }

        if (target.kind == .enum_ and !has_wildcard) {
            for (covered[0..covered_n], 0..) |c, v| {
                if (!c) {
                    self.errFmt(loc, "non-exhaustive match: missing variant '{s}.{s}'", .{ target.name, target.variants[v] });
                }
            }
        }

        return result_type orelse self.newType(.void);
    }

    fn checkReturn(self: *TypeChecker, value: ?u32, loc: lexer.Loc) *Type {
        var value_type = self.newType(.void);
        if (value) |v| {
            value_type = self.checkNode(v);
            if (isErrorType(value_type)) return value_type;
        }
        if (self.current_fn_return) |expected| {
            if (!typeEq(value_type, expected)) {
                return self.errorType(loc, "return type {s} does not match function return type {s}", .{ value_type.kind.name(), expected.kind.name() });
            }
        }
        return value_type;
    }

    fn lvalueRoot(self: *TypeChecker, start: u32) ?u32 {
        var idx: ?u32 = start;
        while (idx) |i| {
            switch (self.tree.node(i)) {
                .field_access => |fa| idx = fa.object,
                .index_expr => |ix| idx = ix.object,
                else => return i,
            }
        }
        return null;
    }

    fn checkAssign(self: *TypeChecker, target: u32, value: u32, loc: lexer.Loc) *Type {
        // `Color.Rojo = x` parses as a field access on a type name.
        if (isTag(self.tree.node(target), .field_access)) {
            const fa = self.tree.node(target).field_access;
            const obj = self.checkNode(fa.object);
            if (isErrorType(obj)) return obj;
            if (obj.kind == .enum_) {
                return self.errorType(self.tree.loc(target), "cannot assign to enum variant '{s}.{s}'", .{ obj.name, fa.field });
            }
        }

        const root = self.lvalueRoot(target) orelse return self.errorType(self.tree.loc(target), "invalid assignment target", .{});
        if (!isTag(self.tree.node(root), .identifier)) return self.errorType(self.tree.loc(target), "invalid assignment target", .{});
        const name = self.tree.node(root).identifier;
        const sym = self.lookup(name) orelse return self.errorType(self.tree.loc(root), "undefined variable '{s}'", .{name});
        if (sym.is_fn) return self.errorType(self.tree.loc(root), "cannot reassign function '{s}'", .{name});
        if (!sym.is_mut) {
            if (!isTag(self.tree.node(target), .identifier)) {
                return self.errorType(self.tree.loc(root), "cannot assign through immutable variable '{s}' (declare it with 'let mut')", .{name});
            }
            return self.errorType(self.tree.loc(root), "cannot assign to immutable variable '{s}'", .{name});
        }

        const target_type = self.checkNode(target);
        if (isErrorType(target_type)) return target_type;
        const val_type = self.checkNode(value);
        if (isErrorType(val_type)) return val_type;
        if (!typeEq(target_type, val_type)) {
            const what = switch (self.tree.node(target)) {
                .index_expr => "array element",
                .field_access => "struct field",
                else => "variable",
            };
            return self.errorType(loc, "type mismatch: cannot assign {s} to {s} of type {s}", .{ val_type.kind.name(), what, target_type.kind.name() });
        }
        return target_type;
    }

    // ── Declarations ──────────────────────────────────────────────

    fn checkVarDecl(self: *TypeChecker, v: ast.VarDecl, loc: lexer.Loc, is_const: bool) void {
        var decl_type: ?*Type = null;
        if (v.type_node) |t| {
            decl_type = self.resolveTypeNode(t);
            if (isErrorType(decl_type.?)) return;
        }
        var val_type: ?*Type = null;
        if (v.value) |val| {
            val_type = self.checkNode(val);
            if (isErrorType(val_type.?)) return;
        }

        if (val_type != null and val_type.?.kind == .void) {
            self.errFmt(loc, "variable '{s}' cannot be initialized with a void expression: a block whose last statement ends in `;` has no value, so leave the trailing expression without a semicolon", .{v.name});
            return;
        }

        var final_type: *Type = undefined;
        if (decl_type != null and val_type != null) {
            if (!typeEq(decl_type.?, val_type.?)) {
                const what = if (is_const) "const" else "variable";
                self.errFmt(loc, "type mismatch: {s} '{s}' declared as {s} but initialized with {s}", .{ what, v.name, decl_type.?.kind.name(), val_type.?.kind.name() });
            }
            final_type = decl_type.?;
        } else if (decl_type) |d| {
            final_type = d;
        } else if (val_type) |vt| {
            final_type = if (vt.kind == .int_literal) self.newType(.int) else vt;
        } else {
            self.errFmt(loc, "{s} '{s}' must have a type annotation or initializer", .{ if (is_const) "const" else "variable", v.name });
            final_type = self.newType(.error_);
        }
        self.insert(.{ .name = v.name, .type_ = final_type, .is_mut = v.is_mut and !is_const, .is_fn = false });
    }

    fn checkFnDecl(self: *TypeChecker, fn_idx: u32) void {
        const f = self.tree.node(fn_idx).fn_decl;
        const params = self.tree.extraSlice(f.params);

        var param_types = self.a.alloc(*Type, params.len) catch @panic("OOM");
        for (params, 0..) |p, i| {
            param_types[i] = self.resolveTypeNode(self.tree.node(p).param.type_node);
            if (isErrorType(param_types[i])) return;
        }
        const ret_type: ?*Type = if (f.ret) |r| self.resolveTypeNode(r) else null;
        if (ret_type) |r| if (isErrorType(r)) return;

        const fn_type = self.newFn(param_types, ret_type);
        if (self.lookup(f.name)) |existing| {
            existing.type_ = fn_type;
        } else {
            self.insert(.{ .name = f.name, .type_ = fn_type, .is_mut = false, .is_fn = true });
        }
        self.checkFnBody(f, param_types, ret_type);
    }

    fn nodeContainsReturn(self: *TypeChecker, idx: ?u32) bool {
        const i = idx orelse return false;
        return switch (self.tree.node(i)) {
            .return_stmt => true,
            .block => |b| blk: {
                for (self.tree.extraSlice(b.stmts)) |s| {
                    if (self.nodeContainsReturn(s)) break :blk true;
                }
                break :blk self.nodeContainsReturn(b.tail);
            },
            .if_expr => |e| self.nodeContainsReturn(e.then_block) or self.nodeContainsReturn(e.else_block),
            .while_expr => |w| self.nodeContainsReturn(w.body),
            .for_expr => |fo| self.nodeContainsReturn(fo.body),
            .match_expr => |m| blk: {
                for (self.tree.extraSlice(m.arms)) |a| {
                    if (self.nodeContainsReturn(self.tree.node(a).match_arm.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn checkFnBody(self: *TypeChecker, f: ast.FnDecl, param_types: []const *Type, ret_type: ?*Type) void {
        self.pushScope();
        const prev_return = self.current_fn_return;
        self.current_fn_return = ret_type;

        const params = self.tree.extraSlice(f.params);
        for (params, 0..) |p, i| {
            self.insert(.{ .name = self.tree.node(p).param.name, .type_ = param_types[i], .is_mut = false, .is_fn = false });
        }

        const body_type = self.checkNode(f.body);
        if (ret_type) |declared| {
            const real = declared.kind != .void and declared.kind != .error_ and declared.kind != .unknown;
            if (real) {
                if (body_type.kind != .void) {
                    if (!typeEq(declared, body_type)) {
                        self.errFmt(self.fnLoc(), "function '{s}' returns {s} but its body has type {s}", .{ f.name, declared.kind.name(), body_type.kind.name() });
                    }
                } else if (!self.nodeContainsReturn(f.body)) {
                    self.errFmt(self.fnLoc(), "function '{s}' declares that it returns {s} but its body produces no value: end the body with an expression without a trailing `;`, or add a `return`", .{ f.name, declared.kind.name() });
                }
            }
        }

        self.current_fn_return = prev_return;
        self.popScope();
    }

    fn fnLoc(self: *TypeChecker) lexer.Loc {
        return self.pending_fn_loc;
    }

    fn checkLambda(self: *TypeChecker, idx: u32) *Type {
        const l = self.tree.node(idx).lambda_expr;
        const loc = self.tree.loc(idx);
        const params = self.tree.extraSlice(l.params);

        var param_types = self.a.alloc(*Type, params.len) catch @panic("OOM");
        for (params, 0..) |p, i| {
            param_types[i] = self.resolveTypeNode(self.tree.node(p).param.type_node);
            if (isErrorType(param_types[i])) return self.newType(.void);
        }
        const ret_type: ?*Type = if (l.ret) |r| self.resolveTypeNode(r) else null;
        if (ret_type) |r| if (isErrorType(r)) return self.newType(.void);

        self.pushScope();
        for (params, 0..) |p, i| {
            self.insert(.{ .name = self.tree.node(p).param.name, .type_ = param_types[i], .is_mut = false, .is_fn = false });
        }
        const saved = self.current_fn_return;
        self.current_fn_return = ret_type;
        const body_type = self.checkNode(l.body);
        self.current_fn_return = saved;
        self.popScope();

        if (ret_type == null) {
            if (body_type.kind != .void) {
                return self.newFn(param_types, body_type);
            }
            return self.errorType(loc, "lambda requires explicit return type annotation", .{});
        }
        return self.newFn(param_types, ret_type);
    }

    fn checkStructDecl(self: *TypeChecker, idx: u32) void {
        const s = self.tree.node(idx).struct_decl;
        const st = self.newType(.struct_);
        st.name = s.name;
        const fields = self.tree.extraSlice(s.fields);
        if (fields.len > 0) {
            var flds = self.a.alloc(Field, fields.len) catch @panic("OOM");
            for (fields, 0..) |fidx, i| {
                const fd = self.tree.node(fidx).field_decl;
                const ft = self.resolveTypeNode(fd.type_node);
                if (isErrorType(ft)) return;
                flds[i] = .{ .name = fd.name, .type_ = ft };
            }
            st.fields = flds;
        }
        self.insert(.{ .name = s.name, .type_ = st, .is_mut = false, .is_fn = false });
    }

    fn checkEnumDecl(self: *TypeChecker, idx: u32) void {
        const e = self.tree.node(idx).enum_decl;
        const en = self.newType(.enum_);
        en.name = e.name;
        const variants = self.tree.extraSlice(e.variants);
        var vs = self.a.alloc([]const u8, variants.len) catch @panic("OOM");
        for (variants, 0..) |vi, i| {
            const v = self.tree.node(vi).enum_variant;
            vs[i] = v.name;
            self.addVariant(v.name, en);
        }
        en.variants = vs;

        var payloads = self.a.alloc(VariantLayout, variants.len) catch @panic("OOM");
        for (variants, 0..) |vi, i| {
            const v = self.tree.node(vi).enum_variant;
            var vl = VariantLayout{};
            if (v.payload) |p| {
                const pf = self.tree.extraSlice(self.tree.node(p).payload);
                vl.field_count = pf.len;
                var names = self.a.alloc([]const u8, pf.len) catch @panic("OOM");
                var types = self.a.alloc(*Type, pf.len) catch @panic("OOM");
                for (pf, 0..) |fidx, j| {
                    const fd = self.tree.node(fidx).field_decl;
                    names[j] = fd.name;
                    types[j] = self.resolveTypeNode(fd.type_node);
                    if (isErrorType(types[j])) return;
                }
                vl.names = names;
                vl.types = types;
            }
            payloads[i] = vl;
        }
        en.payloads = payloads;
        self.insert(.{ .name = e.name, .type_ = en, .is_mut = false, .is_fn = false });
    }

    /// Public entry point: type-check a whole module and accumulate errors.
    pub fn check(self: *TypeChecker, root: u32) void {
        _ = self.checkNode(root);
    }

    // ── Dispatch ──────────────────────────────────────────────────

    fn checkNode(self: *TypeChecker, idx: u32) *Type {
        const loc = self.tree.loc(idx);
        return switch (self.tree.node(idx)) {
            .int_literal => self.newType(.int_literal),
            .float_literal => self.newType(.float),
            .string_literal => self.newType(.string),
            .bool_literal => self.newType(.bool_),
            .nil_literal => self.newType(.nil),
            .identifier => |name| self.checkIdent(name, loc),
            .binary_expr => |b| self.checkBinary(b.op, b.left, b.right, loc),
            .unary_expr => |u| self.checkUnary(u.op, u.operand, loc),
            .call_expr => |c| self.checkCall(c.callee, c.args, loc),
            .index_expr => |ix| self.checkIndex(ix.object, ix.index),
            .array_literal => |l| self.checkArrayLit(l),
            .struct_literal => |s| self.checkStructLit(s.name, s.fields, loc),
            .some_expr => |v| blk: {
                const inner = self.checkNode(v);
                if (isErrorType(inner)) break :blk inner;
                break :blk self.newOptional(inner);
            },
            .none_expr => self.newType(.nil),
            .ok_expr => |v| blk: {
                const inner = self.checkNode(v);
                if (isErrorType(inner)) break :blk inner;
                break :blk self.newOptional(inner);
            },
            .err_expr => |v| blk: {
                const inner = self.checkNode(v);
                if (isErrorType(inner)) break :blk inner;
                break :blk self.newOptional(inner);
            },
            .try_expr => |v| blk: {
                const inner = self.checkNode(v);
                if (isErrorType(inner)) break :blk inner;
                break :blk if (inner.kind == .optional) inner.inner.? else inner;
            },
            .range_expr => self.errorType(loc, "range expression is only valid as a for-loop iterator", .{}),
            .field_access => |fa| self.checkFieldAccess(fa.object, fa.field, loc),
            .block => |b| self.checkBlock(b),
            .if_expr => |i| self.checkIf(i, loc),
            .while_expr => |w| self.checkWhile(w),
            .for_expr => |f| self.checkFor(f),
            .match_expr => |m| self.checkMatch(m, loc),
            .return_stmt => |v| self.checkReturn(v, loc),
            .break_stmt, .continue_stmt => self.newType(.void),
            .assignment => |a| self.checkAssign(a.target, a.value, loc),
            .compound_assignment => |a| blk: {
                // x += e behaves as x = x + e.
                const ident = self.tree.addNode(.{ .identifier = self.tree.node(a.target).identifier }, loc) catch @panic("OOM");
                const bin = self.tree.addNode(.{ .binary_expr = .{ .op = a.op, .left = a.target, .right = a.value } }, loc) catch @panic("OOM");
                _ = ident;
                break :blk self.checkAssign(a.target, bin, loc);
            },
            .fn_decl => blk: {
                self.pending_fn_loc = loc;
                self.checkFnDecl(idx);
                break :blk self.newType(.void);
            },
            .lambda_expr => self.checkLambda(idx),
            .struct_decl => blk: {
                self.checkStructDecl(idx);
                break :blk self.newType(.void);
            },
            .enum_decl => blk: {
                self.checkEnumDecl(idx);
                break :blk self.newType(.void);
            },
            .var_decl => |v| blk: {
                self.checkVarDecl(v, loc, false);
                break :blk self.newType(.void);
            },
            .const_decl => |v| blk: {
                self.checkVarDecl(v, loc, true);
                break :blk self.newType(.void);
            },
            .payload => self.errorType(loc, "variant payload outside an enum declaration", .{}),
            .source_file => |items| blk: {
                self.checkModule(self.tree.extraSlice(items));
                break :blk self.newType(.void);
            },
            else => self.errorType(loc, "unhandled node kind", .{}),
        };
    }

    fn checkModule(self: *TypeChecker, items: []const u32) void {
        // First pass: register signatures and type declarations.
        for (items) |it| {
            switch (self.tree.node(it)) {
                .fn_decl => |f| {
                    const params = self.tree.extraSlice(f.params);
                    var param_types = self.a.alloc(*Type, params.len) catch @panic("OOM");
                    for (params, 0..) |p, j| {
                        param_types[j] = self.resolveTypeNode(self.tree.node(p).param.type_node);
                    }
                    const ret_type: ?*Type = if (f.ret) |r| self.resolveTypeNode(r) else null;
                    self.insert(.{ .name = f.name, .type_ = self.newFn(param_types, ret_type), .is_mut = false, .is_fn = true });
                },
                .struct_decl => self.checkStructDecl(it),
                .enum_decl => self.checkEnumDecl(it),
                else => {},
            }
        }
        // Second pass: bodies and values.
        for (items) |it| {
            switch (self.tree.node(it)) {
                .fn_decl => {
                    self.pending_fn_loc = self.tree.loc(it);
                    self.checkFnDecl(it);
                },
                .var_decl => |v| self.checkVarDecl(v, self.tree.loc(it), false),
                .const_decl => |v| self.checkVarDecl(v, self.tree.loc(it), true),
                else => _ = self.checkNode(it),
            }
        }
    }
};

fn opName(tag: lexer.Tag) []const u8 {
    return switch (tag) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .percent => "%",
        else => @tagName(tag),
    };
}

const testing = std.testing;

fn checkSource(a: std.mem.Allocator, source: []const u8, errors: *usize) !void {
    var tree = ast.Tree.init(a, source);
    defer tree.deinit();
    var p = parser.Parser.init(a, source, &tree);
    const root = try p.parse();
    var tc = try TypeChecker.init(a, &tree, "test.astra");
    _ = tc.checkNode(root);
    errors.* = tc.error_count;
}

test "accepts a well-typed program" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errors: usize = 0;
    try checkSource(arena.allocator(),
        \\fn add(a: i32, b: i32) -> i32 { return a + b; }
        \\fn main() { let x: i32 = 5; print(add(x, 1)); }
    , &errors);
    try testing.expectEqual(@as(usize, 0), errors);
}

test "rejects a type mismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errors: usize = 0;
    try checkSource(arena.allocator(),
        \\fn main() { let x: i32 = 5; print("s" + x); }
    , &errors);
    try testing.expect(errors > 0);
}

test "integer literal adopts context type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errors: usize = 0;
    try checkSource(arena.allocator(),
        \\fn takes(x: i64) {}
        \\fn main() { takes(5); let a: u32 = 7; }
    , &errors);
    try testing.expectEqual(@as(usize, 0), errors);
}
