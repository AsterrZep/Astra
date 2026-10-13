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
const types = @import("types.zig");
const diagnostics_mod = @import("../diagnostics.zig");

fn isTag(n: ast.Node, tag: ast.Tag) bool {
    return std.meta.activeTag(n) == tag;
}

pub const Type = types.Type;
pub const Kind = types.Kind;
pub const Field = types.Field;
pub const VariantLayout = types.VariantLayout;
pub const TypePool = types.TypePool;
/// Port of the seed's `type_eq`; operates on interned types (see `types.zig`).
pub const typeEq = types.typeEq;
const isInteger = types.isInteger;

const Symbol = struct {
    name: []const u8,
    type_: *Type,
    is_mut: bool,
    is_fn: bool,
    /// Non-null when the name is a module binding (`import a.b as m`, or a
    /// bare `import a.b` which binds `b`): member access goes through this
    /// export list instead of the type system (`ARCHITECTURE.md` §10.1, §10.5).
    module_exports: ?[]const Export = null,
};

/// One exported name of a module and the type it resolves to. Collected from
/// the `pub` top-level declarations after a module is checked; the type comes
/// from the shared pool, so it is the same `*Type` every other module sees.
pub const Export = struct { name: []const u8, type_: *Type };

/// A name an importing module binds, as seen from that module. Built by the
/// driver from the import declarations plus the exporting module's exports,
/// then injected before the module is checked.
pub const ImportBinding = struct {
    /// The name as written in the importing module (`add`, or the alias).
    local: []const u8,
    /// The bound type for a plain name binding (`from x import add`). Unused
    /// when `module_exports` is set.
    type_: *Type,
    /// Non-null for a module-namespace binding (`import a.b as m` / bare
    /// `import a.b`): `m.x` resolves `x` in this list.
    module_exports: ?[]const Export = null,
};

const Variant = struct { name: []const u8, enum_type: *Type };

/// One method declared in an `impl` block (research/010 §12), keyed by the
/// receiver's nominal type name plus the method name — static dispatch, no
/// vtable (Phase 2.3 step 3-4). `fn_type` keeps the receiver at parameter 0,
/// so a call site checks its arguments against `params[1..]`. `trait_name` is
/// empty for an inherent impl and joins the duplicate key, letting an
/// inherent method shadow a trait method of the same name (inherent first).
const Method = struct {
    type_name: []const u8,
    method_name: []const u8,
    trait_name: []const u8,
    global: []const u8, // mangled runtime global `Type.method`
    inherent: bool,
    fn_type: *Type,
    loc: lexer.Loc, // the impl item, for conformance errors
};

/// One required method of a trait declaration (Phase 2.3 step 5): the
/// signature an `impl T for X` must provide. Collected in its own pre-pass so
/// the impl may appear before the trait in source order. `param_types` skips
/// the receiver — both sides of a conformance check compare what follows
/// `self` — and `ret` is null when the signature omits `->`.
const TraitMethod = struct {
    name: []const u8,
    param_types: []const *Type,
    ret: ?*Type,
};

const TraitInfo = struct {
    name: []const u8,
    methods: []const TraitMethod,
};

fn isNumeric(t: *const Type) bool {
    return isInteger(t) or t.kind == .float;
}

fn isErrorType(t: *const Type) bool {
    return t.kind == .error_;
}

pub const TypeChecker = struct {
    a: std.mem.Allocator,
    filename: []const u8,
    /// Interned types for the whole compilation. A pointer so every module's
    /// checker shares one pool: a type exported by one module must be the
    /// *same* interned type the importer resolves, or `typeEq` would compare
    /// strangers.
    pool: *TypePool,
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    scopes: std.ArrayListUnmanaged(usize) = .empty,
    variants: std.ArrayListUnmanaged(Variant) = .empty,
    methods: std.ArrayListUnmanaged(Method) = .empty,
    traits: std.ArrayListUnmanaged(TraitInfo) = .empty,
    current_fn_return: ?*Type = null,
    // Location of the function currently being checked, used for body-level
    // diagnostics (`checkFnDecl` sets it before `checkFnBody`).
    pending_fn_loc: lexer.Loc = .{ .start = 0, .end = 0, .line = 0, .col = 0 },
    error_count: usize = 0,
    tree: *ast.Tree,
    /// Optional sink: when wired, errors are recorded there (and echoed to
    /// stderr); when null, they print directly. Both paths share one format.
    diag: ?*diagnostics_mod.Sink = null,

    pub fn init(a: std.mem.Allocator, tree: *ast.Tree, filename: []const u8) !TypeChecker {
        const pool = try a.create(TypePool);
        pool.* = try TypePool.init(a);
        return initWithPool(a, tree, filename, pool);
    }

    /// Like `init`, but joins an existing pool — the multi-module driver's
    /// form: one pool for the whole compilation, one checker per module.
    pub fn initWithPool(a: std.mem.Allocator, tree: *ast.Tree, filename: []const u8, pool: *TypePool) !TypeChecker {
        var tc = TypeChecker{ .a = a, .filename = filename, .tree = tree, .pool = pool };
        try tc.registerBuiltins();
        return tc;
    }

    // ── Type constructors (all types are interned in `pool`) ──────

    fn newType(self: *TypeChecker, kind: Kind) *Type {
        return self.pool.primitive(kind) catch @panic("OOM");
    }

    fn newOptional(self: *TypeChecker, inner: *Type) *Type {
        return self.pool.optional(inner) catch @panic("OOM");
    }

    fn newArray(self: *TypeChecker, elem: *Type) *Type {
        return self.pool.array(elem) catch @panic("OOM");
    }

    fn newFn(self: *TypeChecker, params: []const *Type, ret: ?*Type) *Type {
        return self.pool.fnType(params, ret) catch @panic("OOM");
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

    // ── Method registry (static dispatch) ─────────────────────────

    /// The runtime global a method compiles to: `Type.method` for an inherent
    /// impl, `Type.Trait.method` for a trait impl. The trait segment keeps two
    /// impls of the same method name from sharing one runtime slot (the VM
    /// would mask it as last-write-wins; the C backend maps a name to one
    /// function). No module prefix — the emitter applies `globalName` at both
    /// ends.
    fn methodGlobal(self: *TypeChecker, type_name: []const u8, trait_name: []const u8,
        method_name: []const u8) []const u8 {
        if (trait_name.len > 0) {
            return std.fmt.allocPrint(self.a, "{s}.{s}.{s}", .{ type_name, trait_name, method_name }) catch @panic("OOM");
        }
        return std.fmt.allocPrint(self.a, "{s}.{s}", .{ type_name, method_name }) catch @panic("OOM");
    }

    fn addMethod(self: *TypeChecker, type_name: []const u8, method_name: []const u8,
        trait_name: []const u8, inherent: bool, fn_type: *Type, loc: lexer.Loc) void {
        for (self.methods.items) |m| {
            if (std.mem.eql(u8, m.type_name, type_name) and
                std.mem.eql(u8, m.method_name, method_name) and
                std.mem.eql(u8, m.trait_name, trait_name))
            {
                self.errFmt(loc, "method '{s}' is already defined for type '{s}'", .{ method_name, type_name });
                return;
            }
        }
        self.methods.append(self.a, .{
            .type_name = type_name,
            .method_name = method_name,
            .trait_name = trait_name,
            .global = self.methodGlobal(type_name, trait_name, method_name),
            .inherent = inherent,
            .fn_type = fn_type,
            .loc = loc,
        }) catch @panic("OOM");
    }

    /// Static-dispatch lookup for `recv.name()`. Inherent impls beat trait
    /// impls regardless of declaration order; between trait impls the first
    /// declared wins (cross-trait ambiguity is a documented Phase 2.4
    /// limitation). Only struct and enum receivers have a nominal name.
    fn findMethod(self: *TypeChecker, recv: *Type, name: []const u8) ?Method {
        if (recv.kind != .struct_ and recv.kind != .enum_) return null;
        var trait_fallback: ?Method = null;
        for (self.methods.items) |m| {
            if (!std.mem.eql(u8, m.method_name, name) or
                !std.mem.eql(u8, m.type_name, recv.name))
            {
                continue;
            }
            if (m.inherent) return m;
            if (trait_fallback == null) trait_fallback = m;
        }
        return trait_fallback;
    }

    fn addTrait(self: *TypeChecker, name: []const u8, methods: []const TraitMethod) void {
        self.traits.append(self.a, .{ .name = name, .methods = methods }) catch @panic("OOM");
    }

    fn findTrait(self: *TypeChecker, name: []const u8) ?*const TraitInfo {
        for (self.traits.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    /// Exact (type, method, trait) lookup for conformance — unlike findMethod
    /// it never falls back to an inherent entry or another trait of the same
    /// name.
    fn findTraitMethod(self: *TypeChecker, type_name: []const u8,
        method_name: []const u8, trait_name: []const u8) ?Method {
        for (self.methods.items) |m| {
            if (std.mem.eql(u8, m.type_name, type_name) and
                std.mem.eql(u8, m.method_name, method_name) and
                std.mem.eql(u8, m.trait_name, trait_name))
            {
                return m;
            }
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
        diagnostics_mod.emit(self.diag, self.filename, loc, fmt, args);
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
            const opt = self.pool.enumType("Option") catch @panic("OOM");
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
            const res = self.pool.enumType("Result") catch @panic("OOM");
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
        if (self.lookup(name)) |sym| {
            if (sym.module_exports != null) {
                return self.errorType(loc, "module '{s}' is not a value", .{name});
            }
            return sym.type_;
        }
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

        // `x.m(args)` is a static method call when `m` resolves in the
        // receiver's method table (Phase 2.3 step 3-4): annotate the callee
        // with the mangled global and check the arguments against the
        // signature with the receiver removed. Module-namespace callees keep
        // their export path — `m.helper()` is an imported function, not a
        // method — so the export layer is consulted first.
        if (std.meta.activeTag(self.tree.node(callee_idx)) == .field_access) {
            const fa = self.tree.node(callee_idx).field_access;
            var is_module_callee = false;
            if (std.meta.activeTag(self.tree.node(fa.object)) == .identifier) {
                if (self.lookup(self.tree.node(fa.object).identifier)) |sym| {
                    is_module_callee = sym.module_exports != null;
                }
            }
            if (!is_module_callee) {
                const obj = self.checkNode(fa.object);
                if (isErrorType(obj)) return obj;
                if (self.findMethod(obj, fa.field)) |m| {
                    self.tree.nodes.items[callee_idx].field_access.method = m.global;
                    const want = m.fn_type.params.len - 1;
                    if (arg_slice.len != want) {
                        return self.errorType(loc, "expected {d} arguments, got {d}", .{ want, arg_slice.len });
                    }
                    for (arg_slice, 0..) |arg, i| {
                        const at = self.checkNode(arg);
                        if (isErrorType(at)) return at;
                        const expected = m.fn_type.params[i + 1];
                        if (!typeEq(at, expected)) {
                            return self.errorType(loc, "argument {d}: expected {s}, got {s}", .{ i + 1, expected.kind.name(), at.kind.name() });
                        }
                    }
                    return m.fn_type.ret orelse self.newType(.void);
                }
                // No method: fall through — the object re-typechecks below,
                // but it was clean (an error type returned above), so no
                // message repeats.
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
        // Module namespace: `alias.x` where `alias` is a module binding.
        // File-as-module (§10.1): exactly one level — `alias.x.y` falls
        // through and fails below, because a module has no sub-namespaces.
        if (std.meta.activeTag(self.tree.node(object_idx)) == .identifier) {
            const obj_name = self.tree.node(object_idx).identifier;
            if (self.lookup(obj_name)) |sym| {
                if (sym.module_exports) |exps| {
                    for (exps) |ex| {
                        if (std.mem.eql(u8, ex.name, field)) return ex.type_;
                    }
                    return self.errorType(loc, "module '{s}' does not export '{s}'", .{ obj_name, field });
                }
            }
        }

        const object = self.checkNode(object_idx);
        if (isErrorType(object)) return object;

        if (object.kind == .enum_) {
            if (enumVariantIndex(object, field) == null) {
                if (self.findMethod(object, field) != null) {
                    return self.errorType(loc, "method '{s}' of '{s}' must be called", .{ field, object.name });
                }
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
        if (self.findMethod(object, field) != null) {
            return self.errorType(loc, "method '{s}' of '{s}' must be called", .{ field, object.name });
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
        // Phase 2.4 step 1: a declaration with `<...>` never binds its name
        // or its fields — instantiation lands with step 4. Reached from both
        // the module pass and checkNode's default path.
        if (s.generics.len > 0) return;
        // Keyed by name: a re-declaration aliases this entry and overwrites
        // the layout below (see types.zig header; the seed has no
        // duplicate-name error either).
        const st = self.pool.structType(s.name) catch @panic("OOM");
        const fields = self.tree.extraSlice(s.fields);
        var flds: []const Field = &.{};
        if (fields.len > 0) {
            const buf = self.a.alloc(Field, fields.len) catch @panic("OOM");
            for (fields, 0..) |fidx, i| {
                const fd = self.tree.node(fidx).field_decl;
                const ft = self.resolveTypeNode(fd.type_node);
                if (isErrorType(ft)) return;
                buf[i] = .{ .name = fd.name, .type_ = ft };
            }
            flds = buf;
        }
        st.fields = flds;
        // Pass 0 already bound the module-level name to this canonical type;
        // an unrelated binding (a shadowing local) gets a fresh symbol.
        if (self.lookup(s.name)) |existing| {
            if (existing.type_ != st) self.insert(.{ .name = s.name, .type_ = st, .is_mut = false, .is_fn = false });
        } else {
            self.insert(.{ .name = s.name, .type_ = st, .is_mut = false, .is_fn = false });
        }
    }

    fn checkEnumDecl(self: *TypeChecker, idx: u32) void {
        const e = self.tree.node(idx).enum_decl;
        // Phase 2.4 step 1: same contract as structs (checkStructDecl).
        if (e.generics.len > 0) return;
        const en = self.pool.enumType(e.name) catch @panic("OOM");
        const variants = self.tree.extraSlice(e.variants);
        var vs = self.a.alloc([]const u8, variants.len) catch @panic("OOM");
        for (variants, 0..) |vi, i| {
            const v = self.tree.node(vi).enum_variant;
            vs[i] = v.name;
            self.addVariant(v.name, en);
        }

        var payloads = self.a.alloc(VariantLayout, variants.len) catch @panic("OOM");
        for (variants, 0..) |vi, i| {
            const v = self.tree.node(vi).enum_variant;
            var vl = VariantLayout{};
            if (v.payload) |p| {
                const pf = self.tree.extraSlice(self.tree.node(p).payload);
                vl.field_count = pf.len;
                var names = self.a.alloc([]const u8, pf.len) catch @panic("OOM");
                var types_buf = self.a.alloc(*Type, pf.len) catch @panic("OOM");
                for (pf, 0..) |fidx, j| {
                    const fd = self.tree.node(fidx).field_decl;
                    names[j] = fd.name;
                    types_buf[j] = self.resolveTypeNode(fd.type_node);
                    if (isErrorType(types_buf[j])) return;
                }
                vl.names = names;
                vl.types = types_buf;
            }
            payloads[i] = vl;
        }
        en.variants = vs;
        en.payloads = payloads;
        if (self.lookup(e.name)) |existing| {
            if (existing.type_ != en) self.insert(.{ .name = e.name, .type_ = en, .is_mut = false, .is_fn = false });
        } else {
            self.insert(.{ .name = e.name, .type_ = en, .is_mut = false, .is_fn = false });
        }
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
            .fn_decl => |f| blk: {
                // Inert until Phase 2.4 step 2 (the seed's checkNode case).
                if (f.generics.len > 0) break :blk self.newType(.void);
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
            // Phase 2.3 steps 1-2: `trait`/`impl` parse into nodes but the
            // checks (method table, `self` binding, trait conformance) are
            // not wired yet, so the blocks are inert: their items are not
            // walked. The seed behaves the same way (typechecker.c).
            .trait_decl, .impl_decl => self.newType(.void),
            // Module declarations carry no value: they type as `void`, and the
            // drivers give them their semantics (namespace bindings, `pub`
            // gating — PHASE2_PROGRESS §7). Parsing them must not be a type
            // error.
            .use_decl, .import_decl, .from_decl, .import_item => self.newType(.void),
            .payload => self.errorType(loc, "variant payload outside an enum declaration", .{}),
            .source_file => |items| blk: {
                self.checkModule(self.tree.extraSlice(items));
                break :blk self.newType(.void);
            },
            else => self.errorType(loc, "unhandled node kind", .{}),
        };
    }

    // ── Module imports (multi-module driver) ─────────────────────

    /// Bind the names an import statement introduces, in the module-level
    /// scope. Called by the driver after `init`/`initWithPool` and before
    /// `check`, once the exporting modules have been checked and their
    /// exports collected.
    pub fn injectImports(self: *TypeChecker, bindings: []const ImportBinding) void {
        for (bindings) |b| {
            // Module bindings never consult `type_` (`module_exports`
            // short-circuits every lookup); void is a safe placeholder.
            const ty = if (b.module_exports != null) self.newType(.void) else b.type_;
            self.insert(.{
                .name = b.local,
                .type_ = ty,
                .is_mut = false,
                .is_fn = false,
                .module_exports = b.module_exports,
            });
        }
    }

    /// The `pub` top-level declarations of the module just checked, with the
    /// type each name resolves to. Allocated from the checker's arena (the
    /// compilation arena) — no `deinit`.
    pub fn collectExports(self: *TypeChecker, items: []const u32) []Export {
        var list: std.ArrayListUnmanaged(Export) = .empty;
        for (items) |it| {
            const name: ?[]const u8 = switch (self.tree.node(it)) {
                .fn_decl => |f| if (f.is_pub and f.generics.len == 0) f.name else null,
                .struct_decl => |s| if (s.is_pub and s.generics.len == 0) s.name else null,
                .enum_decl => |e| if (e.is_pub and e.generics.len == 0) e.name else null,
                .const_decl => |c| if (c.is_pub) c.name else null,
                else => null,
            };
            if (name) |n| {
                if (self.lookup(n)) |sym| {
                    list.append(self.a, .{ .name = n, .type_ = sym.type_ }) catch @panic("OOM");
                }
            }
        }
        return list.toOwnedSlice(self.a) catch @panic("OOM");
    }

    /// Phase 2.3 step 5: collect every trait's required method signatures.
    /// Runs after pass 0 (struct/enum names bound), so parameter and return
    /// types resolve in any source order, and before the impl pass, so
    /// `impl T for X` can verify conformance. A trait item with statements or
    /// a tail expression is a default method — rejected until a later phase
    /// defines the lookup rules; the empty block a signature-only item gets
    /// from the parser carries no statements, so it passes untouched.
    fn collectTraitDecls(self: *TypeChecker, items: []const u32) void {
        for (items) |it| {
            if (std.meta.activeTag(self.tree.node(it)) != .trait_decl) continue;
            const tr = self.tree.node(it).trait_decl;
            if (tr.generics.len > 0) continue; // inert (Phase 2.4 step 1)
            var methods: std.ArrayListUnmanaged(TraitMethod) = .empty;
            for (self.tree.extraSlice(tr.items)) |fidx| {
                if (std.meta.activeTag(self.tree.node(fidx)) != .fn_decl) continue;
                const f = self.tree.node(fidx).fn_decl;
                if (f.generics.len > 0) continue; // inert (Phase 2.4 step 1)
                const body = self.tree.node(f.body);
                const has_content = switch (body) {
                    .block => |b| self.tree.extraSlice(b.stmts).len > 0 or b.tail != null,
                    else => false,
                };
                if (has_content) {
                    self.errFmt(self.tree.loc(fidx), "default trait methods are not yet supported", .{});
                }
                const params = self.tree.extraSlice(f.params);
                if (params.len == 0) continue; // the parser already reported it
                const param_types = self.a.alloc(*Type, params.len - 1) catch @panic("OOM");
                for (params[1..], 1..) |p, k| {
                    param_types[k - 1] = self.resolveTypeNode(self.tree.node(p).param.type_node);
                }
                const ret: ?*Type = if (f.ret) |r| self.resolveTypeNode(r) else null;
                methods.append(self.a, .{
                    .name = f.name,
                    .param_types = param_types,
                    .ret = ret,
                }) catch @panic("OOM");
            }
            self.addTrait(tr.name, methods.items);
        }
    }

    /// Phase 2.3 step 3 (pass 1): register every `impl` item as a method of
    /// the receiver's nominal type. The receiver resolves through the same
    /// path a type annotation uses (builtins resolve, unknown names report),
    /// so `impl Point` only works once `Point` is bound — pass 0 guarantees
    /// that for struct/enum. The method's parameter-0 type node and its name
    /// are rewritten in the tree: the parameter becomes the receiver type and
    /// the name becomes the mangled runtime global `Type.method`, which the
    /// signature pass, the body pass and the emitter all read afterwards.
    fn registerImpl(self: *TypeChecker, impl_idx: u32) void {
        const im = self.tree.node(impl_idx).impl_decl;
        // Phase 2.4 step 1: a block with `<...>` stays inert.
        if (im.generics.len > 0) return;
        const recv_node = self.tree.addNode(.{ .type_ident = im.type_name }, self.tree.loc(impl_idx)) catch @panic("OOM");
        const recv = self.resolveTypeNode(recv_node);
        if (isErrorType(recv)) return;
        if (recv.kind != .struct_ and recv.kind != .enum_) {
            self.errFmt(self.tree.loc(impl_idx), "impl requires a struct or enum type, got {s}", .{recv.kind.name()});
            return;
        }
        const inherent = im.trait_name == null;
        const trait_name = im.trait_name orelse "";
        for (self.tree.extraSlice(im.items)) |fidx| {
            if (std.meta.activeTag(self.tree.node(fidx)) != .fn_decl) continue;
            const floc = self.tree.loc(fidx);
            const f = self.tree.node(fidx).fn_decl;
            if (f.generics.len > 0) continue; // inert (Phase 2.4 step 1)
            const params = self.tree.extraSlice(f.params);
            if (params.len == 0 or !std.mem.eql(u8, self.tree.node(params[0]).param.name, "self")) continue;
            // A typed receiver must name the impl's type; the typeless `self`
            // gets the receiver type written into its parameter node.
            if (self.tree.node(params[0]).param.type_node) |atn| {
                const ann = self.resolveTypeNode(atn);
                if (!isErrorType(ann) and !typeEq(ann, recv)) {
                    self.errFmt(floc, "type of 'self' must be '{s}'", .{im.type_name});
                }
            } else {
                const syn = self.tree.addNode(.{ .type_ident = im.type_name }, floc) catch @panic("OOM");
                self.tree.nodes.items[params[0]].param.type_node = syn;
            }
            // Signature with the receiver removed from the call-site arity
            // (it stays at parameter 0 for the callee).
            var param_types = self.a.alloc(*Type, params.len) catch @panic("OOM");
            param_types[0] = recv;
            var bad = false;
            for (params[1..], 1..) |p, k| {
                param_types[k] = self.resolveTypeNode(self.tree.node(p).param.type_node);
                if (isErrorType(param_types[k])) { bad = true; break; }
            }
            var ret: ?*Type = null;
            if (f.ret) |r| {
                ret = self.resolveTypeNode(r);
                if (isErrorType(ret.?)) bad = true;
            }
            if (bad) continue;
            const mangled = self.methodGlobal(im.type_name, trait_name, f.name);
            self.tree.nodes.items[fidx].fn_decl.name = mangled;
            self.addMethod(im.type_name, f.name, trait_name, inherent, self.newFn(param_types, ret), floc);
        }

        // Phase 2.3 step 5: a trait impl must name a known trait and provide
        // every required method with the required signature. Conformance is
        // per-impl-block — an inherent method never satisfies a trait
        // requirement (Rust's rule); it only shadows the trait's entry at
        // dispatch.
        if (im.trait_name) |trname| {
            if (self.findTrait(trname)) |ti| {
                for (ti.methods) |tm| {
                    const m = self.findTraitMethod(im.type_name, tm.name, trname) orelse {
                        self.errFmt(self.tree.loc(impl_idx), "type '{s}' does not implement trait '{s}': missing method '{s}'", .{ im.type_name, ti.name, tm.name });
                        continue;
                    };
                    var sig_ok = m.fn_type.params.len == tm.param_types.len + 1;
                    if (sig_ok) {
                        for (tm.param_types, 0..) |pt, q| {
                            if (!typeEq(m.fn_type.params[q + 1], pt)) {
                                sig_ok = false;
                                break;
                            }
                        }
                    }
                    if (sig_ok) {
                        const iret = m.fn_type.ret orelse self.newType(.void);
                        const tret = tm.ret orelse self.newType(.void);
                        if (!typeEq(iret, tret)) sig_ok = false;
                    }
                    if (!sig_ok) {
                        self.errFmt(m.loc, "signature of method '{s}' of '{s}' does not match trait '{s}'", .{ tm.name, im.type_name, ti.name });
                    }
                }
            } else {
                self.errFmt(self.tree.loc(impl_idx), "unknown trait '{s}'", .{trname});
            }
        }
    }

    /// Phase 2.3 step 4 (pass 2): type-check the bodies of `impl` methods,
    /// now that every method table in the module is complete — bodies may
    /// call methods declared later.
    fn checkImplBodies(self: *TypeChecker, impl_idx: u32) void {
        const im = self.tree.node(impl_idx).impl_decl;
        if (im.generics.len > 0) return; // inert (Phase 2.4 step 1)
        for (self.tree.extraSlice(im.items)) |fidx| {
            if (std.meta.activeTag(self.tree.node(fidx)) != .fn_decl) continue;
            const f = self.tree.node(fidx).fn_decl;
            const params = self.tree.extraSlice(f.params);
            if (params.len == 0 or !std.mem.eql(u8, self.tree.node(params[0]).param.name, "self")) continue;
            if (f.generics.len > 0) continue; // inert (Phase 2.4 step 1)
            self.pending_fn_loc = self.tree.loc(fidx);
            self.checkFnDecl(fidx);
        }
    }

    fn checkModule(self: *TypeChecker, items: []const u32) void {
        // Pass 0: bind every top-level struct/enum name to an empty type
        // before any signature or field type is resolved, so declarations may
        // reference each other in any order (forward references, mutual
        // recursion). checkStructDecl/checkEnumDecl fill the layouts in
        // pass 1 — the pool hands back the same canonical type.
        for (items) |it| {
            switch (self.tree.node(it)) {
                .struct_decl => |s| {
                    // Inert until Phase 2.4 step 4 (same rule as the seed).
                    if (s.generics.len > 0) continue;
                    const st = self.pool.structType(s.name) catch @panic("OOM");
                    self.insert(.{ .name = s.name, .type_ = st, .is_mut = false, .is_fn = false });
                },
                .enum_decl => |e| {
                    if (e.generics.len > 0) continue;
                    const en = self.pool.enumType(e.name) catch @panic("OOM");
                    self.insert(.{ .name = e.name, .type_ = en, .is_mut = false, .is_fn = false });
                },
                else => {},
            }
        }
        self.collectTraitDecls(items);
        // First pass: register signatures and type declarations.
        for (items) |it| {
            switch (self.tree.node(it)) {
                .fn_decl => |f| {
                    // A generic declaration is inert until Phase 2.4 step 2.
                    if (f.generics.len > 0) continue;
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
                .impl_decl => self.registerImpl(it),
                else => {},
            }
        }
        // Second pass: bodies and values.
        for (items) |it| {
            switch (self.tree.node(it)) {
                .fn_decl => |f| {
                    if (f.generics.len > 0) continue; // inert (Phase 2.4 step 1)
                    self.pending_fn_loc = self.tree.loc(it);
                    self.checkFnDecl(it);
                },
                .var_decl => |v| self.checkVarDecl(v, self.tree.loc(it), false),
                .const_decl => |v| self.checkVarDecl(v, self.tree.loc(it), true),
                .impl_decl => self.checkImplBodies(it),
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
