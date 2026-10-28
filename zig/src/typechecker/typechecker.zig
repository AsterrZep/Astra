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
    /// A generic function (Phase 2.4 step 2a): registered with TYPE_PARAM
    /// placeholders; calls need call-site inference (step 2b) and the name
    /// can never be used as a value.
    is_generic: bool = false,
    /// The `fn_decl` node this symbol was registered from (Phase 2.4 step
    /// 2b): call-site inference reads the `<...>` list and clones an
    /// instance wrapper from it. Null for non-function symbols.
    fn_ast: ?u32 = null,
    /// The `struct_decl` node this symbol was registered from (Phase 2.4
    /// step 3b): instantiating `Box<i32>` re-resolves the declaration's
    /// field types with the parameters bound to the arguments, and struct
    /// literal inference reads the `<...>` list off it. Null for
    /// non-type symbols.
    type_ast: ?u32 = null,
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

const Variant = struct { name: []const u8, enum_type: *Type, builtin: bool };

/// Phase 2.4 step 2b: one generic-parameter binding of a call site. A null
/// type means "not inferred yet" while the arguments are unified.
const Binding = struct { name: []const u8, type_: ?*Type };

/// One callee-ident node of a generic body renamed to a mangled instance
/// global: the same node is shared by every instance of the enclosing fn,
/// so the emitter resolves the name per instance (see emitter.Instance).
pub const Rewrite = struct { callee: u32, name: []const u8 };

/// One materialized instantiation of a generic fn. `rewrites` covers the
/// calls inside the shared body whose target depended on the enclosing
/// declaration's parameters; concrete call sites inside non-generic bodies
/// are renamed in place and add none.
pub const Instance = struct {
    source: u32,
    wrapper: u32,
    rewrites: std.ArrayListUnmanaged(Rewrite) = .empty,
};

/// One materialized generic struct instance (Phase 2.4 step 3b). The pool
/// type carries the concrete fields; the LLVM backend needs them per
/// instance (each has its own field ptypes for print/eq), while the
/// bytecode/C backends share the source declaration's runtime def.
pub const StructInstance = struct {
    /// Mangled type name (`Box<i32>`), the key every annotation resolves to.
    name: []const u8,
    /// Source declaration name (`Box`) — what the VM prints for a struct.
    source_name: []const u8,
    /// Source declaration node (diagnostics).
    decl: u32,
    fields: []const Field,
};

/// A call inside a generic body whose bindings still mention the enclosing
/// fn's parameters; resolved once per instance of `fn_decl`.
const PendingCall = struct {
    fn_decl: u32,
    callee: u32,
    target: u32,
    bindings: []Binding,
};

/// One method declared in an `impl` block (research/001 §12), keyed by the
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

/// One generic parameter of the fn currently being checked (Phase 2.4 step
/// 2a): a flat stack with save/restore marks, so `T` in an annotation
/// resolves to the enclosing generic fn's placeholder.
const GenericBinding = struct { name: []const u8, type_: *Type };

/// One `impl T for X` block (Phase 2.4 step 4): bound checking asks this
/// registry whether a concrete type carries the trait. The method table
/// alone cannot answer — an impl of a method-less trait registers no
/// method entry, so scanning it would report a satisfied bound as missing.
const ImplRecord = struct { type_name: []const u8, trait_name: []const u8 };

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
    /// Every `impl T for X` block (Phase 2.4 step 4): bound checking asks
    /// this registry whether a concrete type carries the trait.
    impls: std.ArrayListUnmanaged(ImplRecord) = .empty,
    generic_stack: std.ArrayListUnmanaged(GenericBinding) = .empty,
    /// The generic fn whose body is being checked (Phase 2.4 step 2b):
    /// call sites whose bindings still mention its parameters are recorded
    /// as pending and resolved per instance.
    current_generic_fn: ?u32 = null,
    /// Instantiations materialized so far and the not-yet-concrete call
    /// sites inside generic bodies (Phase 2.4 step 2b).
    instances: std.ArrayListUnmanaged(Instance) = .empty,
    /// Materialized generic struct instances (Phase 2.4 step 3b), for the
    /// LLVM backend's per-instance layouts.
    struct_instances: std.ArrayListUnmanaged(StructInstance) = .empty,
    pending: std.ArrayListUnmanaged(PendingCall) = .empty,
    current_fn_return: ?*Type = null,
    // Depth of enclosing fn/lambda bodies: current_fn_return is also null
    // for an *unannotated* fn, so module scope is detected with this
    // counter, not with the annotation (audit §4.5, mirror of the seed).
    fn_depth: u32 = 0,
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

    /// One flat entry per declared variant. DEC-008 (research/027 §4): the
    /// bare spelling `some(x)` is only legal for the built-in Option/Result
    /// variants, so each entry records which kind it is; a user variant is
    /// constructed only as `Enum.Variant(...)`.
    fn addVariant(self: *TypeChecker, name: []const u8, enum_type: *Type, builtin: bool) void {
        self.variants.append(self.a, .{ .name = name, .enum_type = enum_type, .builtin = builtin }) catch @panic("OOM");
    }

    /// First registry entry for `name`, or null.
    fn findVariant(self: *TypeChecker, name: []const u8) ?Variant {
        for (self.variants.items) |v| {
            if (std.mem.eql(u8, v.name, name)) return v;
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

        // len(value) -> i64: length of an array or a string (DEC-013,
        // research/028 PR1). Unknown parameter like print's, so the runtime
        // wording (`cannot take length of int`) is the parity surface.
        const len_params = try self.a.alloc(*Type, 1);
        len_params[0] = self.newType(.unknown);
        self.insert(.{ .name = "len", .type_ = self.newFn(len_params, self.newType(.int64)), .is_mut = false, .is_fn = true });

        // to_string(value) -> string: int -> string (DEC-014, research/028
        // PR2). Unknown parameter like print's — the checker cannot say "any
        // integer" without breaking the i32-default literal rule (DEC-006);
        // each runtime rejects other values with the same defensive text.
        const ts_params = try self.a.alloc(*Type, 1);
        ts_params[0] = self.newType(.unknown);
        self.insert(.{ .name = "to_string", .type_ = self.newFn(ts_params, self.newType(.string)), .is_mut = false, .is_fn = true });

        // read_file(path: string) -> string (DEC-014, research/028 PR2): the
        // annotated path rejects `read_file(42)` at compile time; an
        // unopenable path is one runtime error, worded identically on all
        // routes (`cannot open file '<path>'`).
        const rf_params = try self.a.alloc(*Type, 1);
        rf_params[0] = self.newType(.string);
        self.insert(.{ .name = "read_file", .type_ = self.newFn(rf_params, self.newType(.string)), .is_mut = false, .is_fn = true });

        // ord(s) -> i64: the first BYTE of a string (DEC-018, research/028
        // M2a). Unknown parameter like print's — the runtime wording
        // (`ord expects a string, got <tipo>` / `ord() of empty string`) is
        // the parity surface, byte-identical to the seed.
        const ord_params = try self.a.alloc(*Type, 1);
        ord_params[0] = self.newType(.unknown);
        self.insert(.{ .name = "ord", .type_ = self.newFn(ord_params, self.newType(.int64)), .is_mut = false, .is_fn = true });

        // substr(s, start, len) -> string (DEC-018, research/028 M2a): three
        // unknown parameters, because a call checks arguments by exact type
        // equality — an annotated i64 would reject `substr(s, 1, 3)` (i32
        // literal, DEC-006) and an annotated i32 would reject `len(s)`.
        const sub_params = try self.a.alloc(*Type, 3);
        sub_params[0] = self.newType(.unknown);
        sub_params[1] = self.newType(.unknown);
        sub_params[2] = self.newType(.unknown);
        self.insert(.{ .name = "substr", .type_ = self.newFn(sub_params, self.newType(.string)), .is_mut = false, .is_fn = true });

        // push(arr, value) -> array (DEC-019, research/028 M2b): a NEW array
        // with value appended — the caller rebinds (`a = push(a, x)`). Both
        // parameters are unknown like print's, and the return is
        // array<unknown>: the checker cannot compare the element against the
        // array's type without breaking literal adoption (DEC-006); each
        // runtime rejects a mismatch with the same defensive text
        // (`push expects an array, got <tipo>` / `push element has type <X>,
        // expected <Y>`).
        const push_params = try self.a.alloc(*Type, 2);
        push_params[0] = self.newType(.unknown);
        push_params[1] = self.newType(.unknown);
        self.insert(.{
            .name = "push",
            .type_ = self.newFn(push_params, self.newArray(self.newType(.unknown))),
            .is_mut = false,
            .is_fn = true,
        });

        // str_to_int(s) -> i64 (DEC-019, research/028 M2b): the decimal
        // to_string produces; unknown parameter like ord's — an invalid or
        // out-of-range input is one runtime error on every route, not an
        // optional (a `some`/`none` builtin would need the pair ABI in four
        // places and a `match` in every caller).
        const sti_params = try self.a.alloc(*Type, 1);
        sti_params[0] = self.newType(.unknown);
        self.insert(.{ .name = "str_to_int", .type_ = self.newFn(sti_params, self.newType(.int64)), .is_mut = false, .is_fn = true });

        // chr(i) -> string (DEC-020, research/028 M3): the 1-byte string whose
        // first byte is `i` (0..255) — the inverse of `ord` (DEC-018). Unknown
        // parameter like ord's, so `chr(65)` (i32 literal, DEC-006) type checks
        // and the runtime guard rejects non-int / out-of-range values with
        // `chr expects an int, got <tipo>` / `chr value N out of bounds (0..255)`.
        const chr_params = try self.a.alloc(*Type, 1);
        chr_params[0] = self.newType(.unknown);
        self.insert(.{ .name = "chr", .type_ = self.newFn(chr_params, self.newType(.string)), .is_mut = false, .is_fn = true });

        // read_line() -> string (DEC-020, research/028 M3): one line of stdin
        // up to (not including) the trailing `\n`, or a runtime error `end of
        // input` on EOF with no data. No parameters: the runtime's argc check
        // reports `expected 0 arguments but got N`.
        const rl_params = try self.a.alloc(*Type, 0);
        self.insert(.{ .name = "read_line", .type_ = self.newFn(rl_params, self.newType(.string)), .is_mut = false, .is_fn = true });

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
            self.addVariant("some", opt, true);
            self.addVariant("none", opt, true);
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
            self.addVariant("ok", res, true);
            self.addVariant("err", res, true);
        }
    }

    // ── Type node resolution ──────────────────────────────────────

    /// Phase 2.4 step 2a: bind the `<T, U: Show>` parameters of `fn` as
    /// `.param` placeholders for the duration of the signature and body
    /// check. The owner node makes `T` of two different fns distinct even
    /// when they share a name. Save/restore the mark like `current_fn_return`.
    fn pushGenericScope(self: *TypeChecker, fn_idx: u32) usize {
        return self.pushGenericBindings(self.tree.node(fn_idx).fn_decl.generics, fn_idx);
    }

    /// Step 3b: a generic struct declaration binds its own `<...>` the same
    /// way; `owner` is the declaration node the parameters belong to. The
    /// same helper seeds an instance check with the concrete bindings.
    fn pushGenericBindings(self: *TypeChecker, gens: ast.List, owner: u32) usize {
        const mark = self.generic_stack.items.len;
        for (self.tree.extraSlice(gens)) |g| {
            const tp = self.tree.node(g).type_param;
            // Step 4: every bound must name a known trait. Checked at
            // binding time (eager, like Rust): the trait pre-pass has run
            // before any signature or field resolves, so the registry is
            // complete. Only fn and struct declarations bind their
            // parameters — enum/trait/impl generics stay inert until their
            // own step.
            for (self.tree.extraSlice(tp.bounds)) |bi| {
                const bound = self.tree.node(bi).type_ident.name;
                if (self.findTrait(bound) == null)
                    self.errFmt(self.tree.loc(bi), "unknown trait '{s}'", .{bound});
            }
            const pt = self.pool.paramType(tp.name, owner) catch @panic("OOM");
            self.generic_stack.append(self.a, .{ .name = tp.name, .type_ = pt }) catch @panic("OOM");
        }
        return mark;
    }

    fn popGenericScope(self: *TypeChecker, mark: usize) void {
        self.generic_stack.items.len = mark;
    }

    fn resolveTypeNode(self: *TypeChecker, idx: ?u32) *Type {
        const i = idx orelse return self.newType(.unknown);
        const loc = self.tree.loc(i);
        return switch (self.tree.node(i)) {
            .type_ident => |t| blk: {
                const name = t.name;
                if (std.mem.eql(u8, name, "void")) break :blk self.newType(.void);
                if (std.mem.eql(u8, name, "bool")) break :blk self.newType(.bool_);
                if (std.mem.eql(u8, name, "i32")) break :blk self.newType(.int);
                if (std.mem.eql(u8, name, "i64")) break :blk self.newType(.int64);
                if (std.mem.eql(u8, name, "u32")) break :blk self.newType(.uint32);
                if (std.mem.eql(u8, name, "u64")) break :blk self.newType(.uint64);
                if (std.mem.eql(u8, name, "f64")) break :blk self.newType(.float);
                if (std.mem.eql(u8, name, "string")) break :blk self.newType(.string);
                // `Name<args...>` in type position (Phase 2.4 step 3b):
                // resolve the arguments and materialize the instance.
                if (t.generics.len > 0) break :blk self.resolveTypeWithArgs(i, loc, name);
                // A generic parameter of the fn being checked shadows every
                // other binding (Phase 2.4 step 2a).
                var g: usize = self.generic_stack.items.len;
                while (g > 0) {
                    g -= 1;
                    if (std.mem.eql(u8, self.generic_stack.items[g].name, name))
                        break :blk self.generic_stack.items[g].type_;
                }
                if (self.lookup(name)) |sym| {
                    // A bare generic struct name is not a type (step 3b).
                    if (sym.is_generic and sym.type_.kind == .struct_ and sym.type_ast != null)
                        break :blk self.errorType(loc, "type '{s}' requires type arguments", .{name});
                    break :blk sym.type_;
                }
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
            // Phase 2.4 step 2a: a generic function has no single runtime
            // value before call-site inference names an instance.
            if (sym.is_fn and sym.is_generic) {
                return self.errorType(loc, "generic function '{s}' used as a value", .{name});
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

        // Phase 2.4 step 2a: a type parameter carries no operations of its
        // own. Bounds (`<T: Show>`) land with step 4; until then only
        // pass-through (calls, returns, bindings) is valid.
        if (left.kind == .param or right.kind == .param) {
            const tp = if (left.kind == .param) left else right;
            return self.errorType(loc, "operator '{s}' cannot be applied to type parameter '{s}'", .{ opName(op), tp.name });
        }

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
        // Phase 2.4 step 2a: see the binary counterpart.
        if (operand.kind == .param) {
            return self.errorType(loc, "operator not applicable to type parameter '{s}'", .{operand.name});
        }
        return switch (op) {
            .minus => if (isNumeric(operand)) operand else self.errorType(loc, "negation requires numeric type, got {s}", .{operand.kind.name()}),
            .bang => if (operand.kind == .bool_) self.newType(.bool_) else self.errorType(loc, "logical not requires bool, got {s}", .{operand.kind.name()}),
            .tilde => if (isInteger(operand)) operand else self.errorType(loc, "bitwise not requires integer type, got {s}", .{operand.kind.name()}),
            else => self.errorType(loc, "operator not supported in Astra-0", .{}),
        };
    }

    // ── Call-site inference & instances (Phase 2.4 step 2b) ──────

    /// Mangled instance name: `identity<i32,string>` — the `<...>` cannot
    /// appear in a source identifier, so the name is unique per binding
    /// tuple (the C backend sanitizes the punctuation). Null on buffer
    /// overflow: a truncated name would collide with another truncated
    /// name and silently merge two different instances.
    fn mangleInstance(self: *TypeChecker, fn_idx: u32, env: []Binding) ?[]const u8 {
        return self.mangleNamed(self.tree.node(fn_idx).fn_decl.name, env);
    }

    /// Shared mangling for function and struct instances (Phase 2.4 step
    /// 3b): `Base<T1,T2>`, unique per argument spelling via the pool.
    fn mangleNamed(self: *TypeChecker, base: []const u8, env: []Binding) ?[]const u8 {
        var buf: [512]u8 = undefined;
        var pos: usize = 0;
        if (!bufPut(buf[0..], &pos, base)) return null;
        if (!bufPut(buf[0..], &pos, "<")) return null;
        for (env, 0..) |b, i| {
            if (i > 0 and !bufPut(buf[0..], &pos, ",")) return null;
            pos = mangleTypeStr(b.type_ orelse unreachable, buf[0..], pos) orelse return null;
        }
        if (!bufPut(buf[0..], &pos, ">")) return null;
        return self.a.dupe(u8, buf[0..pos]) catch @panic("OOM");
    }

    /// Build a type-annotation node for a concrete type (Phase 2.4 step
    /// 2b/3b): instance wrappers carry their substituted signature so the
    /// LLVM backend can declare a real LLVM type. Null for types with no
    /// annotation form (void/param/unknown) — the wrapper keeps the original
    /// node and the backend rejects it cleanly.
    fn typeNodeFor(self: *TypeChecker, t: *Type, loc: lexer.Loc) ?u32 {
        const n: ast.Node = switch (t.kind) {
            .bool_ => .{ .type_ident = .{ .name = "bool" } },
            .int, .int_literal => .{ .type_ident = .{ .name = "i32" } },
            .int64 => .{ .type_ident = .{ .name = "i64" } },
            .uint32 => .{ .type_ident = .{ .name = "u32" } },
            .uint64 => .{ .type_ident = .{ .name = "u64" } },
            .float => .{ .type_ident = .{ .name = "f64" } },
            .string => .{ .type_ident = .{ .name = "string" } },
            .struct_, .enum_ => .{ .type_ident = .{ .name = t.name } },
            .optional => .{ .type_optional = self.typeNodeFor(t.inner.?, loc) orelse return null },
            .array => blk: {
                const el = self.typeNodeFor(t.elem.?, loc) orelse return null;
                break :blk .{ .type_array = .{ .elem = el, .size = null } };
            },
            .fn_type => blk: {
                const ps = self.a.alloc(u32, t.params.len) catch @panic("OOM");
                for (t.params, 0..) |pt, i| ps[i] = self.typeNodeFor(pt, loc) orelse return null;
                const plist = self.tree.addExtra(ps) catch @panic("OOM");
                const ret = if (t.ret) |rt| self.typeNodeFor(rt, loc) else null;
                break :blk .{ .type_fn = .{ .params = plist, .ret = ret } };
            },
            else => return null,
        };
        return self.tree.addNode(n, loc) catch @panic("OOM");
    }

    /// `Name<args...>` in a type position (Phase 2.4 step 3b): resolve the
    /// arguments, check the arity against the declaration and materialize
    /// the cached struct instance under the mangled name.
    fn resolveTypeWithArgs(self: *TypeChecker, idx: u32, loc: lexer.Loc, name: []const u8) *Type {
        const sym = self.lookup(name) orelse
            return self.errorType(loc, "unknown type '{s}'", .{name});
        if (sym.type_.kind != .struct_ or !sym.is_generic or sym.type_ast == null)
            return self.errorType(loc, "type '{s}' does not take type arguments", .{name});
        const decl = sym.type_ast.?;
        const s = self.tree.node(decl).struct_decl;
        const gargs = self.tree.extraSlice(self.tree.node(idx).type_ident.generics);
        const params = self.tree.extraSlice(s.generics);
        if (gargs.len != params.len)
            return self.errorType(loc, "wrong number of type arguments for '{s}' (expected {d}, got {d})",
                .{ name, params.len, gargs.len });
        var env = self.a.alloc(Binding, params.len) catch @panic("OOM");
        for (params, 0..) |g, k| {
            const tp = self.tree.node(g).type_param;
            env[k] = .{ .name = tp.name, .type_ = self.resolveTypeNode(gargs[k]) };
            if (isErrorType(env[k].type_.?)) return env[k].type_.?;
        }
        self.checkGenericBounds(params, env, name, loc);
        const inst = self.ensureStructInstance(decl, env, loc);
        if (isErrorType(inst)) return inst;
        // Annotate the annotation node: the LLVM backend needs the concrete
        // instance name to pick the per-instance layout (the bytecode/C
        // backends keep reading `name`).
        self.tree.nodes.items[idx].type_ident.inst_name = inst.name;
        return inst;
    }

    /// Materialize (or find) the instance of the generic struct declared at
    /// `decl` under `env`. The symbol is inserted *before* the field types
    /// are resolved, so a field mentioning the instance itself (linked
    /// lists, trees) finds the type being built instead of recursing. The
    /// instance type is interned by its mangled name in the pool, so every
    /// scope that spells `Box<i32>` gets the same `*Type`.
    fn ensureStructInstance(self: *TypeChecker, decl: u32, env: []Binding, loc: lexer.Loc) *Type {
        const mangled = self.mangleNamed(self.tree.node(decl).struct_decl.name, env) orelse {
            return self.errorType(loc, "generic instance name for '{s}' is too long",
                .{self.tree.node(decl).struct_decl.name});
        };
        if (self.lookup(mangled)) |isym| return isym.type_;
        const st = self.pool.structType(mangled) catch @panic("OOM");
        self.insert(.{ .name = mangled, .type_ = st, .is_mut = false, .is_fn = false, .type_ast = decl });
        // Re-resolve the declaration's fields with the parameters bound to
        // the concrete arguments: the template's own types stay abstract
        // (Approach A), so declarations and scope order do not interfere.
        const s = self.tree.node(decl).struct_decl;
        const mark = self.generic_stack.items.len;
        for (env) |b| {
            self.generic_stack.append(self.a, .{ .name = b.name, .type_ = b.type_ orelse unreachable })
                catch @panic("OOM");
        }
        defer self.popGenericScope(mark);
        const fields = self.tree.extraSlice(s.fields);
        if (fields.len == 0) {
            self.recordStructInstance(mangled, s.name, decl, st.fields);
            return st;
        }
        const buf = self.a.alloc(Field, fields.len) catch @panic("OOM");
        for (fields, 0..) |fidx, i| {
            const fd = self.tree.node(fidx).field_decl;
            const ft = self.resolveTypeNode(fd.type_node);
            if (isErrorType(ft)) return ft;
            buf[i] = .{ .name = fd.name, .type_ = ft };
        }
        st.fields = buf;
        self.recordStructInstance(mangled, s.name, decl, st.fields);
        return st;
    }

    fn recordStructInstance(self: *TypeChecker, mangled: []const u8, source_name: []const u8, decl: u32, fields: []const Field) void {
        self.struct_instances.append(self.a, .{
            .name = mangled,
            .source_name = source_name,
            .decl = decl,
            .fields = fields,
        }) catch @panic("OOM");
    }

    /// Does the concrete type `ty` carry an `impl T for ...` record?
    /// Nominal types answer by name; everything else cannot have an impl
    /// at all (the impl pass requires struct or enum), and abstract
    /// `.param` bindings are skipped by the caller.
    fn implRecordExists(self: *TypeChecker, ty: *Type, trait_name: []const u8) bool {
        if (ty.kind != .struct_ and ty.kind != .enum_) return false;
        for (self.impls.items) |r| {
            if (std.mem.eql(u8, r.type_name, ty.name) and
                std.mem.eql(u8, r.trait_name, trait_name)) return true;
        }
        return false;
    }

    /// Phase 2.4 step 4: at each instantiation, every bound declared on the
    /// parameter list must hold for the concrete binding. Abstract bindings
    /// (`.param` — a call inside another generic body) are skipped: bodies
    /// are checked once symbolically, so verifying them would need a
    /// per-instance re-check (documented gap, §9). A bound whose trait is
    /// unknown was already reported when the declaration bound its
    /// parameters (pushGenericBindings), so it is skipped here instead of
    /// duplicated.
    fn checkGenericBounds(self: *TypeChecker, generics: []const u32, env: []Binding, owner: []const u8, loc: lexer.Loc) void {
        const n = @min(generics.len, env.len);
        for (generics[0..n], env[0..n]) |g, b| {
            const ty = b.type_ orelse continue;
            if (ty.kind == .param or isErrorType(ty)) continue;
            const tp = self.tree.node(g).type_param;
            for (self.tree.extraSlice(tp.bounds)) |bi| {
                const bound = self.tree.node(bi).type_ident.name;
                if (self.findTrait(bound) == null) continue;
                if (self.implRecordExists(ty, bound)) continue;
                const tname: []const u8 = if (ty.kind == .struct_ or ty.kind == .enum_)
                    ty.name
                else
                    ty.kind.name();
                self.errFmt(loc, "type parameter '{s}' of '{s}' requires bound '{s}': type '{s}' does not implement trait '{s}'",
                    .{ tp.name, owner, bound, tname, bound });
            }
        }
    }

    /// Replace the type parameters of `fn_idx` inside `t` with their binding
    /// in `env`; everything else (including parameters of *other* fns, which
    /// stay abstract for the enclosing symbolic check) passes through.
    fn typeSubst(self: *TypeChecker, t: ?*Type, fn_idx: u32, env: []Binding) ?*Type {
        const ty = t orelse return null;
        switch (ty.kind) {
            .param => {
                if (ty.owner == fn_idx) {
                    for (env) |b| {
                        if (std.mem.eql(u8, b.name, ty.name)) return b.type_ orelse ty;
                    }
                }
                return ty;
            },
            .optional => {
                const inner = self.typeSubst(ty.inner, fn_idx, env);
                if (inner == ty.inner) return ty;
                return self.newOptional(inner.?);
            },
            .array => {
                const elem = self.typeSubst(ty.elem, fn_idx, env);
                if (elem == ty.elem) return ty;
                return self.newArray(elem.?);
            },
            .fn_type => {
                var changed = false;
                const tparams = self.a.alloc(*Type, ty.params.len) catch @panic("OOM");
                for (ty.params, 0..) |p, i| {
                    tparams[i] = self.typeSubst(p, fn_idx, env).?;
                    if (tparams[i] != p) changed = true;
                }
                const tret = self.typeSubst(ty.ret, fn_idx, env);
                if (tret != ty.ret) changed = true;
                if (!changed) return ty;
                return self.newFn(tparams, tret);
            },
            else => return ty,
        }
    }

    /// One unification step of call-site inference: bind the parameters of
    /// `fn_idx` inside `template` to `arg`. A conflict reports the parameter
    /// name and the rejected type.
    const UnifyFail = struct { name: []const u8, got: *Type };
    fn unifyBind(self: *TypeChecker, template: *Type, arg: *Type, fn_idx: u32, env: []Binding) ?UnifyFail {
        if (template.kind == .param and template.owner == fn_idx) {
            // An unadorned integer literal takes the default i32 (the same
            // default typecheckVarDecl gives a `let` without annotation).
            var bound = arg;
            if (bound.kind == .int_literal) bound = self.newType(.int);
            for (env) |*b| {
                if (!std.mem.eql(u8, b.name, template.name)) continue;
                if (b.type_ == null) {
                    b.type_ = bound;
                    return null;
                }
                if (!typeEq(b.type_.?, bound)) return .{ .name = template.name, .got = bound };
                return null;
            }
            return null; // not one of fn's declared parameters
        }
        if (template.kind == .optional and arg.kind == .optional)
            return self.unifyBind(template.inner.?, arg.inner.?, fn_idx, env);
        if (template.kind == .array and arg.kind == .array)
            return self.unifyBind(template.elem.?, arg.elem.?, fn_idx, env);
        if (template.kind == .fn_type and arg.kind == .fn_type) {
            if (template.params.len != arg.params.len) return null;
            for (template.params, arg.params) |tp, ap| {
                if (self.unifyBind(tp, ap, fn_idx, env)) |f| return f;
            }
            if (template.ret != null and arg.ret != null)
                return self.unifyBind(template.ret.?, arg.ret.?, fn_idx, env);
        }
        return null;
    }

    /// Materialize (or find) the instance of generic `fn_idx` under `env`
    /// and resolve the pending call sites recorded in its body against it.
    /// The instance is registered *before* those resolutions, so a recursive
    /// call inside the body finds this very instance. Null when the mangled
    /// name does not fit (already reported).
    fn ensureInstance(self: *TypeChecker, fn_idx: u32, env: []Binding) ?u32 {
        const mangled = self.mangleInstance(fn_idx, env) orelse {
            _ = self.errorType(self.tree.loc(fn_idx),
                "generic instance name for '{s}' is too long",
                .{self.tree.node(fn_idx).fn_decl.name});
            return null;
        };
        for (self.instances.items) |inst| {
            if (std.mem.eql(u8, self.tree.node(inst.wrapper).fn_decl.name, mangled))
                return inst.wrapper;
        }

        // Hard cap: a recursive generic that grows its binding every step
        // (`f([x])` instantiating f<[i32]>, f<[[i32]]>, ...) would otherwise
        // chain until the global limit with a misleading message.
        if (self.instances.items.len >= 256) {
            _ = self.errorType(self.tree.loc(fn_idx), "too many generic instances (max 256)", .{});
            return null;
        }

        var n = self.tree.node(fn_idx);
        n.fn_decl.name = mangled;
        n.fn_decl.generics = .{ .start = 0, .len = 0 };
        // Per-instance copies of the parameter and return type nodes: the
        // substitution below must not rewrite the shared source declaration
        // (a second instance would then resolve concrete types instead of
        // `T` and inherit the first instance's signature).
        const src_params = self.tree.extraSlice(n.fn_decl.params);
        const new_params = self.a.alloc(u32, src_params.len) catch @panic("OOM");
        for (src_params, 0..) |pi, i| {
            new_params[i] = self.tree.addNode(self.tree.node(pi), self.tree.loc(pi)) catch @panic("OOM");
        }
        n.fn_decl.params = self.tree.addExtra(new_params) catch @panic("OOM");
        if (n.fn_decl.ret) |rn| {
            n.fn_decl.ret = self.tree.addNode(self.tree.node(rn), self.tree.loc(rn)) catch @panic("OOM");
        }
        const widx = self.tree.addNode(n, self.tree.loc(fn_idx)) catch @panic("OOM");
        self.instances.append(self.a, .{ .source = fn_idx, .wrapper = widx }) catch @panic("OOM");
        const gi_idx = self.instances.items.len - 1;

        // Substitute the concrete bindings into the wrapper's signature
        // (`x: T` → `x: i32`): the bytecode emitter ignores static types, but
        // the LLVM backend declares the LLVM signature from them.
        {
            const mark = self.generic_stack.items.len;
            for (env) |b| {
                self.generic_stack.append(self.a, .{ .name = b.name, .type_ = b.type_ orelse unreachable })
                    catch @panic("OOM");
            }
            defer self.popGenericScope(mark);
            const wfd = self.tree.node(widx).fn_decl;
            for (self.tree.extraSlice(wfd.params)) |pidx| {
                const p = self.tree.node(pidx).param;
                const tn = p.type_node orelse continue;
                const t = self.resolveTypeNode(tn);
                if (isErrorType(t) or typeMentionsParamOf(t, fn_idx)) continue;
                if (self.typeNodeFor(t, self.tree.loc(pidx))) |nn|
                    self.tree.nodes.items[pidx].param.type_node = nn;
            }
            if (wfd.ret) |rn| {
                const t = self.resolveTypeNode(rn);
                if (!isErrorType(t) and !typeMentionsParamOf(t, fn_idx)) {
                    if (self.typeNodeFor(t, self.tree.loc(rn))) |nn|
                        self.tree.nodes.items[widx].fn_decl.ret = nn;
                }
            }
        }

        for (self.pending.items) |pc| {
            if (pc.fn_decl != fn_idx) continue;
            // Substitute this instance's bindings into the recorded
            // (abstract) ones; a leftover parameter of `fn_idx` means the
            // env did not cover it (unreachable: completeness already
            // checked the env at the call site).
            var nb: []Binding = self.a.alloc(Binding, pc.bindings.len) catch @panic("OOM");
            var still = false;
            for (pc.bindings, 0..) |b, j| {
                nb[j] = .{ .name = b.name, .type_ = self.typeSubst(b.type_, fn_idx, env) };
                if (typeMentionsParamOf(nb[j].type_, fn_idx)) still = true;
            }
            if (still) continue;
            const tidx = self.ensureInstance(pc.target, nb) orelse continue;
            self.instances.items[gi_idx].rewrites.append(self.a, .{
                .callee = pc.callee,
                .name = self.tree.node(tidx).fn_decl.name,
            }) catch @panic("OOM");
        }
        return widx;
    }

    /// Call site of a generic function: infer the bindings from the
    /// arguments, instantiate the concrete ones and record the abstract
    /// ones (a call inside another generic body) for per-instance
    /// resolution. The call type is the return type with the bindings
    /// substituted in.
    fn checkGenericCall(self: *TypeChecker, callee_idx: u32, args: ast.List, loc: lexer.Loc, fn_idx: u32, fn_type: *Type, fname: []const u8) *Type {
        const arg_slice = self.tree.extraSlice(args);
        if (arg_slice.len != fn_type.params.len) {
            return self.errorType(loc, "expected {d} arguments, got {d}", .{ fn_type.params.len, arg_slice.len });
        }

        // Env pre-seeded with the declared parameter names in declaration
        // order (the mangle depends on that order).
        const generics = self.tree.extraSlice(self.tree.node(fn_idx).fn_decl.generics);
        var env = self.a.alloc(Binding, generics.len) catch @panic("OOM");
        for (generics, 0..) |g, i| {
            env[i] = .{ .name = self.tree.node(g).type_param.name, .type_ = null };
        }

        for (arg_slice, 0..) |arg, i| {
            const at = self.checkNode(arg);
            if (isErrorType(at)) return at;
            if (self.unifyBind(fn_type.params[i], at, fn_idx, env)) |fail| {
                // `fail.name` is always one of env's bindings (the conflict
                // came from a non-null binding); the fallback keeps the
                // diagnostic well-formed even if that ever stops holding.
                var prev: *Type = fail.got;
                for (env) |b| {
                    if (std.mem.eql(u8, b.name, fail.name)) {
                        prev = b.type_ orelse fail.got;
                        break;
                    }
                }
                return self.errorType(loc, "type parameter '{s}' of '{s}' cannot be both {s} and {s}", .{
                    fail.name, fname, prev.kind.name(), fail.got.kind.name(),
                });
            }
        }

        for (env) |b| {
            if (b.type_ == null) {
                return self.errorType(loc, "cannot infer type parameter '{s}' of '{s}'", .{ b.name, fname });
            }
        }
        self.checkGenericBounds(generics, env, fname, loc);

        const ret: *Type = if (fn_type.ret) |r|
            self.typeSubst(r, fn_idx, env) orelse self.newType(.void)
        else
            self.newType(.void);

        // Abstract bindings (an argument typed by the *enclosing* generic
        // fn) cannot name an instance yet: the call is recorded and resolved
        // when that fn is instantiated. Concrete calls instantiate now and
        // rename the callee — safe, because a callee inside a non-generic
        // body is emitted exactly once.
        var abstract = false;
        if (self.generic_stack.items.len > 0) {
            if (self.current_generic_fn) |cgf| {
                for (env) |b| {
                    if (typeMentionsParamOf(b.type_, cgf)) {
                        abstract = true;
                        break;
                    }
                }
            }
        }
        if (abstract) {
            self.pending.append(self.a, .{
                .fn_decl = self.current_generic_fn.?,
                .callee = callee_idx,
                .target = fn_idx,
                .bindings = env,
            }) catch @panic("OOM");
            return ret;
        }

        const widx = self.ensureInstance(fn_idx, env) orelse return self.newType(.error_);
        self.tree.nodes.items[callee_idx].identifier = self.tree.node(widx).fn_decl.name;
        return ret;
    }

    /// Positional construction of a data-carrying variant against its
    /// payload layout (research/004 §9.2), mirror of the seed's
    /// `check_variant_construction`. DEC-008 (research/027 §4) routes both
    /// spellings here: the qualified `Enum.Variant(args)` — the only legal
    /// one for user variants — and the bare builtin `some(x)` / `ok(x)` /
    /// `err(x)`.
    fn checkVariantConstruction(self: *TypeChecker, args: ast.List, et: *Type, vname: []const u8, loc: lexer.Loc) *Type {
        const vi = enumVariantIndex(et, vname) orelse return self.newType(.error_);
        const vl = if (vi < et.payloads.len) et.payloads[vi] else VariantLayout{};
        const arg_slice = self.tree.extraSlice(args);
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

    fn checkCall(self: *TypeChecker, callee_idx: u32, args: ast.List, loc: lexer.Loc) *Type {
        const arg_slice = self.tree.extraSlice(args);

        // A bare identifier callee may name a built-in Option/Result variant.
        // DEC-008 (research/027 §4): a *user* variant is only legal in the
        // qualified spelling `Enum.Variant(...)`, so the bare form is
        // rejected with a hint — the flat registry that used to let the
        // first-registered enum win now only serves the builtins.
        if (isTag(self.tree.node(callee_idx), .identifier)) {
            const vname = self.tree.node(callee_idx).identifier;
            if (self.findVariant(vname)) |entry| {
                const sym = self.lookup(vname);
                if (!(sym != null and sym.?.is_fn)) {
                    if (entry.builtin) {
                        return self.checkVariantConstruction(args, entry.enum_type, vname, loc);
                    }
                    return self.errorType(loc, "use Enum.Variant to construct '{s}'", .{vname});
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
                // DEC-008 (research/027 §4): `Enum.Variant(args)` is a
                // variant construction, not a method call — resolved before
                // the method table so a method cannot shadow a variant.
                if (obj.kind == .enum_ and enumVariantIndex(obj, fa.field) != null) {
                    return self.checkVariantConstruction(args, obj, fa.field, loc);
                }
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

        // Phase 2.4 step 2b: a generic callee is instantiated per call site
        // instead of being rejected (the generic-as-value rule still fires
        // on every non-call use, handled by checkIdent).
        if (isTag(self.tree.node(callee_idx), .identifier)) {
            if (self.lookup(self.tree.node(callee_idx).identifier)) |csym| {
                if (csym.is_fn and csym.is_generic) {
                    if (csym.fn_ast) |fn_idx| {
                        // Snapshot what is needed: checking the arguments may
                        // insert symbols and reallocate the table under `csym`.
                        const fname = csym.name;
                        const ftype = csym.type_;
                        if (ftype.kind == .fn_type) {
                            return self.checkGenericCall(callee_idx, args, loc, fn_idx, ftype, fname);
                        }
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
        // DEC-013 (research/028 PR1): strings index for reading — `s[i]`
        // yields the one-byte string at byte i. Anything else keeps the
        // historical rejection (ui/index_non_array.astra); writing through a
        // string index is rejected in checkAssign (strings are immutable).
        if (object.kind != .array and object.kind != .string) {
            return self.errorType(self.tree.loc(object_idx), "cannot index non-array type {s}", .{object.kind.name()});
        }
        const index = self.checkNode(index_idx);
        if (isErrorType(index)) return index;
        if (!isInteger(index)) {
            return self.errorType(self.tree.loc(index_idx), "array index must be integer type, got {s}", .{index.kind.name()});
        }
        if (object.kind == .string) return self.newType(.string);
        return object.elem.?;
    }

    fn checkStructLit(self: *TypeChecker, idx: u32, name: []const u8, fields: ast.List, loc: lexer.Loc) *Type {
        const sym = self.lookup(name) orelse return self.errorType(loc, "unknown struct '{s}'", .{name});
        if (sym.type_.kind != .struct_) return self.errorType(loc, "unknown struct '{s}'", .{name});
        var st = sym.type_;

        // Unknown fields first (against the template: instance fields keep
        // the declaration's names); a repeated key used to silently reuse
        // the first value (audit §3.5, mirror of the seed).
        for (self.tree.extraSlice(fields), 0..) |fidx, i| {
            const fname = self.tree.node(fidx).struct_init_field.name;
            for (self.tree.extraSlice(fields)[0..i]) |pidx| {
                if (std.mem.eql(u8, self.tree.node(pidx).struct_init_field.name, fname)) {
                    return self.errorType(loc, "duplicate field '{s}' in struct literal", .{ fname });
                }
            }
            var found = false;
            for (st.fields) |f| {
                if (std.mem.eql(u8, f.name, fname)) {
                    found = true;
                    break;
                }
            }
            if (!found) return self.errorType(loc, "struct '{s}' has no field '{s}'", .{ name, fname });
        }

        // `Box { v: 1 }` (Phase 2.4 step 3b): a generic declaration has no
        // usable literal type, so the argument types are inferred from the
        // values and the instance is materialised before the field loop
        // checks against its concrete types. The values are type-checked
        // once here and reused below.
        var vts: ?[]*Type = null;
        if (sym.is_generic and sym.type_ast != null and
            self.tree.node(sym.type_ast.?).struct_decl.generics.len > 0)
        {
            const decl = sym.type_ast.?;
            const params = self.tree.extraSlice(self.tree.node(decl).struct_decl.generics);
            const fslice = self.tree.extraSlice(fields);
            var env = self.a.alloc(Binding, params.len) catch @panic("OOM");
            for (params, 0..) |g, i| {
                const tp = self.tree.node(g).type_param;
                env[i] = .{ .name = tp.name, .type_ = null };
            }
            const vtbuf = self.a.alloc(*Type, fslice.len) catch @panic("OOM");
            for (fslice, 0..) |fidx, j| {
                vtbuf[j] = self.checkNode(self.tree.node(fidx).struct_init_field.value);
                if (isErrorType(vtbuf[j])) return vtbuf[j];
            }
            vts = vtbuf;
            for (fslice, 0..) |fidx, j| {
                const fname = self.tree.node(fidx).struct_init_field.name;
                var tf: ?*Type = null;
                for (st.fields) |f| {
                    if (std.mem.eql(u8, f.name, fname)) {
                        tf = f.type_;
                        break;
                    }
                }
                if (tf) |tfv| {
                    if (self.unifyBind(tfv, vtbuf[j], decl, env)) |fail| {
                        var prev = self.newType(.unknown);
                        for (env) |b| {
                            if (std.mem.eql(u8, b.name, fail.name)) {
                                if (b.type_) |p| prev = p;
                                break;
                            }
                        }
                        return self.errorType(loc, "type parameter '{s}' of '{s}' cannot be both {s} and {s}",
                            .{ fail.name, name, prev.kind.name(), fail.got.kind.name() });
                    }
                }
            }
            for (env) |b| {
                if (b.type_ == null)
                    return self.errorType(loc, "cannot infer type parameter '{s}' of '{s}'", .{ b.name, name });
            }
            self.checkGenericBounds(self.tree.extraSlice(self.tree.node(decl).struct_decl.generics), env, name, loc);
            // NOTE: `sym` must not be used after this point — inserting the
            // instance may grow the symbol array and invalidate the pointer.
            const inst = self.ensureStructInstance(decl, env, loc);
            if (isErrorType(inst)) return inst;
            st = inst;
            // The LLVM backend needs the concrete instance (per-instance
            // field types); the bytecode/C backends keep the source name.
            self.tree.nodes.items[idx].struct_literal.inst_name = inst.name;
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
            const vt = if (vts) |v| v[j] else self.checkNode(val);
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
            if (iter.kind != .array and iter.kind != .string) {
                return self.errorType(self.tree.loc(f.iter), "for loop must iterate over an array, string or range, got {s}", .{iter.kind.name()});
            }
            // Un string itera BYTE a BYTE, con `c` como string de 1 byte — el
            // mismo modelo que `s[i]` (DEC-013). El emitter reutiliza LEN+INDEX
            // sin distinguir receiver, así que la semántica es la misma en las
            // cuatro rutas.
            var_type = if (iter.kind == .string) self.newType(.string) else iter.elem.?;
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
                    return;
                }
                // A bool literal marks its slot on a bool target (audit
                // §3.8): covered[0] = false arm, covered[1] = true arm.
                if (target.kind == .bool_ and covered.len > 1 and
                    isTag(self.tree.node(pat_idx), .bool_literal))
                {
                    const bv = self.tree.node(pat_idx).bool_literal;
                    covered[if (bv) @as(usize, 1) else 0] = true;
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
                if (bv.kind == .none) {
                    // none covers the absence slot of an optional target
                    // (audit §3.4, mirror of the seed).
                    if (target.kind == .optional and covered.len > 1) covered[1] = true;
                    return;
                }
                // some/ok/err carry the payload tag (slot 0 of an optional).
                if (target.kind == .optional and covered.len > 0) covered[0] = true;
                // ok/err/some bind against the payload type: the
                // constructors return optional(inner), so passing `target`
                // down typed the binding `optional` and rejected literal
                // payloads like `some(1)` (audit §3.3, mirror of the seed).
                if (bv.payload) |p| {
                    const pt: *Type = if (target.kind == .optional and target.inner != null)
                        target.inner.?
                    else
                        target;
                    self.checkPattern(p, pt, has_wildcard, covered);
                }
            },
            else => self.errFmt(self.tree.loc(pat_idx), "unsupported pattern in match arm", .{}),
        }
    }

    fn checkMatch(self: *TypeChecker, m: ast.MatchExpr, loc: lexer.Loc) *Type {
        const target = self.checkNode(m.target);
        if (isErrorType(target)) return target;

        // Option/Result static type is .optional: slot 0 = payload tag
        // (some/ok/err), slot 1 = none. Without this the check never ran
        // for optionals and `match x { some(v) => v }` returned nil under
        // an i32 promise (audit §3.4, mirror of the seed).
        const covered_n: usize = if (target.kind == .enum_)
            target.variants.len
        else if (target.kind == .optional)
            2
        // bool has a finite, enumerable space too: slot 0 = false,
        // slot 1 = true (audit §3.8). Scalars get no slots: infinite
        // space, no range patterns — a catch-all covers them and sets
        // has_wildcard instead (mirror of the seed).
        else if (target.kind == .bool_)
            2
        else
            0;
        const covered = self.a.alloc(bool, if (covered_n > 0) covered_n else 1) catch @panic("OOM");
        @memset(covered, false);
        var has_wildcard = false;
        var result_type: ?*Type = null;

        for (self.tree.extraSlice(m.arms)) |arm_idx| {
            const arm = self.tree.node(arm_idx).match_arm;
            self.pushScope();
            // A guarded arm only covers its variant when the guard holds at
            // run time (audit §3.4): it must neither mark coverage nor
            // waive exhaustiveness — `E.B if flag =>` alone used to accept
            // a match that printed nil under an i32 promise.
            var guard_wildcard = false;
            const wc: *bool = if (arm.guard != null) &guard_wildcard else &has_wildcard;
            const cov: []bool = if (arm.guard != null) covered[0..0] else covered[0..covered_n];
            self.checkPattern(arm.pattern, target, wc, cov);
            // An unguarded bare binding matches every value, like `_`.
            if (arm.guard == null and isTag(self.tree.node(arm.pattern), .pattern_bind))
                has_wildcard = true;
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

        // Exhaustiveness (mirror of the seed; research/004 §9, ARCH
        // §11.3): enums prove their variants, optionals payload+none,
        // bool its two literals; every other target needs a catch-all `_`
        // (audit §3.4 + §3.8). What still slips through at run time
        // (Tier-2 optional aliasing) hits the .match_none backstop
        // instead of yielding a lying nil.
        if (!has_wildcard and target.kind == .enum_) {
            for (covered[0..covered_n], 0..) |c, v| {
                if (!c) {
                    self.errFmt(loc, "non-exhaustive match: missing variant '{s}.{s}'", .{ target.name, target.variants[v] });
                }
            }
        } else if (!has_wildcard and target.kind == .optional) {
            if (!covered[0]) self.errFmt(loc, "non-exhaustive match: missing payload arm (some/ok/err)", .{});
            if (!covered[1]) self.errFmt(loc, "non-exhaustive match: missing 'none' arm", .{});
        } else if (!has_wildcard and target.kind == .bool_) {
            if (!covered[0]) self.errFmt(loc, "non-exhaustive match: missing 'false' arm", .{});
            if (!covered[1]) self.errFmt(loc, "non-exhaustive match: missing 'true' arm", .{});
        } else if (!has_wildcard and !isErrorType(target)) {
            // Every other target (int, float, string, struct, fn, …) needs
            // a catch-all: infinite space, no range patterns in Astra-0
            // (audit §3.8, mirror of the seed; ARCHITECTURE.md §11.3 and
            // the strict model of research/004).
            self.errFmt(loc, "non-exhaustive match: missing '_' arm", .{});
        }

        return result_type orelse self.newType(.void);
    }

    /// `expr?` may unwind the enclosing frame with the absence/error, so
    /// that frame's declared return must be able to carry it (mirror of
    /// the seed's `try_check_enclosing_return`): a `?` inside a fn declared
    /// `-> i32`, with no return at all, or at module level would hand the
    /// caller a nil/err value under an i32 promise.
    fn tryCheckEnclosingReturn(self: *TypeChecker, loc: lexer.Loc) void {
        if (self.current_fn_return) |ret| {
            if (isErrorType(ret) or ret.kind == .unknown) return;
            if (ret.kind == .optional) return;
        }
        self.errFmt(loc, "? operator requires the enclosing function to return an optional type", .{});
    }

    fn checkReturn(self: *TypeChecker, value: ?u32, loc: lexer.Loc) *Type {
        var value_type = self.newType(.void);
        if (value) |v| {
            value_type = self.checkNode(v);
            if (isErrorType(value_type)) return value_type;
        }
        // A module-scope `return` used to be silently accepted: both VMs
        // treated it as "end of module" (rc=0, main never ran) and the C
        // backend generated uncompilable C (audit §4.5, mirror of the seed).
        // fn_depth, not current_fn_return: an unannotated fn also leaves
        // the annotation null.
        if (self.fn_depth == 0)
            return self.errorType(loc, "return outside of a function", .{});
        // An unannotated fn leaves the annotation null (inference path):
        // only compare when there is one, like before (mirror of the seed).
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

        // DEC-013: indexing a string is read-only (mirror of the seed's
        // typecheck_assign). The receiver is checked here, and an errored
        // receiver returns before checkNode(target) re-walks it, so no
        // diagnostic fires twice for the same node.
        if (isTag(self.tree.node(target), .index_expr)) {
            const obj = self.checkNode(self.tree.node(target).index_expr.object);
            if (isErrorType(obj)) return obj;
            if (obj.kind == .string) {
                return self.errorType(self.tree.loc(target), "cannot assign to string element", .{});
            }
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

    // ------------------------------------------------------------
    // DEC-006/DEC-007 (research/027 §1, ratificada 2026-10-27) — mirror of
    // int_lit_value / int_lit_fits / default_int_type in
    // seed/src/typechecker.c. Messages must stay byte-identical: the first
    // diagnostic line is gated by zig/tests/ui_message_parity.sh.
    // ------------------------------------------------------------

    // The value of an integer literal node, folding a leading `-` (`-1` is
    // a negated literal). False for any other shape.
    fn intLitValue(self: *const TypeChecker, n: ?u32, out: *i64) bool {
        const idx = n orelse return false;
        switch (self.tree.node(idx)) {
            .int_literal => |v| { out.* = v; return true; },
            .unary_expr => |u| {
                if (u.op != .minus) return false;
                switch (self.tree.node(u.operand)) {
                    .int_literal => |v| { out.* = -v; return true; },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    /// Does the value fit the concrete integer type? The i64/u64 upper
    /// bounds cannot be exceeded through an int64 literal (the lexer
    /// already rejects anything past i64 max), so those reduce to sign.
    fn intLitFits(v: i64, k: Kind) bool {
        return switch (k) {
            .int => v >= std.math.minInt(i32) and v <= std.math.maxInt(i32),
            .uint32 => v >= 0 and v <= @as(i64, std.math.maxInt(u32)),
            .int64 => true,
            .uint64 => v >= 0,
            else => true,
        };
    }

    fn isIntegerKind(k: Kind) bool {
        return k == .int or k == .int64 or k == .uint32 or k == .uint64;
    }

    // DEC-015 (research/028 PR2): a builtin name is a reserved global. The VM
    // resolves builtins by *name* in GET_GLOBAL and the LLVM emitter by name
    // in emitCall (before consulting the fn/local tables), so a user binding
    // named `len`/`print`/… would run the builtin on one route and the
    // binding on another. Reports and returns true when `name` is builtin —
    // byte-identical to seed's builtin_redeclare_error.
    fn builtinRedeclareError(self: *TypeChecker, loc: lexer.Loc, name: []const u8) bool {
        const k_builtins = [_][]const u8{ "print", "len", "to_string", "read_file", "ord", "substr", "push", "str_to_int", "chr", "read_line" };
        for (k_builtins) |b| {
            if (std.mem.eql(u8, name, b)) {
                self.errFmt(loc, "'{s}' is a builtin and cannot be redeclared", .{name});
                return true;
            }
        }
        return false;
    }

    fn checkVarDecl(self: *TypeChecker, v: ast.VarDecl, loc: lexer.Loc, is_const: bool) void {
        if (self.builtinRedeclareError(loc, v.name)) return;
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
            // Audit §7.1: mirrored from seed/src/typechecker.c — the old hint
            // asserted a `;`-terminated trailing statement, which is untrue
            // for `{ while … }`, `print(1)` or any other void value.
            self.errFmt(loc, "variable '{s}' cannot be initialized with a void expression: this expression has no value to bind (a block has one only when it ends in an expression, not a statement)", .{v.name});
            return;
        }

        var final_type: *Type = undefined;
        if (decl_type != null and val_type != null) {
            if (!typeEq(decl_type.?, val_type.?)) {
                const what = if (is_const) "const" else "variable";
                self.errFmt(loc, "type mismatch: {s} '{s}' declared as {s} but initialized with {s}", .{ what, v.name, decl_type.?.kind.name(), val_type.?.kind.name() });
            } else if (isIntegerKind(decl_type.?.kind)) {
                // DEC-006: the literal adopted a concrete integer type — it
                // has to fit it (`let big: i32 = 9999999999` is an error).
                var lit: i64 = 0;
                if (self.intLitValue(v.value, &lit) and !intLitFits(lit, decl_type.?.kind)) {
                    self.errFmt(loc, "integer literal {d} out of range for {s}", .{ lit, decl_type.?.kind.name() });
                }
            }
            final_type = decl_type.?;
        } else if (decl_type) |d| {
            final_type = d;
        } else if (val_type) |vt| {
            // DEC-006: the default integer type is i32 — unless the literal
            // does not fit it, in which case it falls to i64 (Rust's rule;
            // mirrors seed/src/typechecker.c default_int_type).
            final_type = if (vt.kind == .int_literal) blk: {
                var lit: i64 = 0;
                break :blk if (self.intLitValue(v.value, &lit) and !intLitFits(lit, .int))
                    self.newType(.int64) else self.newType(.int);
            } else vt;
        } else {
            self.errFmt(loc, "{s} '{s}' must have a type annotation or initializer", .{ if (is_const) "const" else "variable", v.name });
            final_type = self.newType(.error_);
        }
        self.insert(.{ .name = v.name, .type_ = final_type, .is_mut = v.is_mut and !is_const, .is_fn = false });
    }

    fn checkFnDecl(self: *TypeChecker, fn_idx: u32) void {
        const f = self.tree.node(fn_idx).fn_decl;

        // DEC-015 for nested fns: a top-level `fn len()` is reported once, in
        // checkModule's first pass, before the duplicate-function check (a
        // nested fn has no pass-1 arm, so its only entry point is here).
        if (self.fn_depth > 0 and self.builtinRedeclareError(self.tree.loc(fn_idx), f.name)) return;

        const params = self.tree.extraSlice(f.params);

        // Phase 2.4 step 2a: `<T>` binds as `.param` for the signature and
        // the body check — a symbolic check over every instantiation. The
        // enclosing-fn pointer (step 2b) is set even for a non-generic fn
        // so a nested generic body always knows its owner.
        const gmark = self.pushGenericScope(fn_idx);
        const saved_gfn = self.current_generic_fn;
        self.current_generic_fn = fn_idx;

        var param_types = self.a.alloc(*Type, params.len) catch @panic("OOM");
        for (params, 0..) |p, i| {
            param_types[i] = self.resolveTypeNode(self.tree.node(p).param.type_node);
            if (isErrorType(param_types[i])) {
                self.current_generic_fn = saved_gfn;
                self.popGenericScope(gmark);
                return;
            }
        }
        const ret_type: ?*Type = if (f.ret) |r| self.resolveTypeNode(r) else null;
        if (ret_type) |r| {
            if (isErrorType(r)) {
                self.current_generic_fn = saved_gfn;
                self.popGenericScope(gmark);
                return;
            }
        }

        const fn_type = self.newFn(param_types, ret_type);
        if (self.lookup(f.name)) |existing| {
            existing.type_ = fn_type;
            existing.fn_ast = fn_idx;
        } else {
            self.insert(.{ .name = f.name, .type_ = fn_type, .is_mut = false, .is_fn = true, .is_generic = f.generics.len > 0, .fn_ast = fn_idx });
        }
        self.checkFnBody(f, param_types, ret_type);
        self.current_generic_fn = saved_gfn;
        self.popGenericScope(gmark);
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
        self.fn_depth += 1;

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
        self.fn_depth -= 1;
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
        self.fn_depth += 1;
        const body_type = self.checkNode(l.body);
        self.current_fn_return = saved;
        self.fn_depth -= 1;
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
        const generic = s.generics.len > 0;
        // Keyed by name: a re-declaration aliases this entry and overwrites
        // the layout below (see types.zig header; the seed has no
        // duplicate-name error either).
        const st = self.pool.structType(s.name) catch @panic("OOM");
        const fields = self.tree.extraSlice(s.fields);
        var flds: []const Field = &.{};
        if (fields.len > 0) {
            const buf = self.a.alloc(Field, fields.len) catch @panic("OOM");
            // A generic declaration resolves its fields with the `<T>`
            // parameters bound (Phase 2.4 step 3b): the template keeps them
            // abstract; concrete instances re-resolve from `type_ast`.
            const mark = self.pushGenericBindings(s.generics, idx);
            for (fields, 0..) |fidx, i| {
                const fd = self.tree.node(fidx).field_decl;
                // Duplicate field names silently overwrote each other — a
                // struct with two `a` fields type-checked and the last
                // declaration won (audit §3.5, mirror of the seed).
                for (fields[0..i]) |pidx| {
                    if (std.mem.eql(u8, self.tree.node(pidx).field_decl.name, fd.name)) {
                        self.errFmt(self.tree.loc(idx), "duplicate field '{s}' in struct '{s}'", .{ fd.name, s.name });
                        break;
                    }
                }
                const ft = self.resolveTypeNode(fd.type_node);
                if (isErrorType(ft)) {
                    self.popGenericScope(mark);
                    return;
                }
                buf[i] = .{ .name = fd.name, .type_ = ft };
            }
            self.popGenericScope(mark);
            flds = buf;
        }
        st.fields = flds;
        // Pass 0 already bound the module-level name to this canonical type;
        // an unrelated binding (a shadowing local) gets a fresh symbol.
        if (self.lookup(s.name)) |existing| {
            if (existing.type_ != st) self.insert(.{ .name = s.name, .type_ = st, .is_mut = false, .is_fn = false, .is_generic = generic, .type_ast = idx });
        } else {
            self.insert(.{ .name = s.name, .type_ = st, .is_mut = false, .is_fn = false, .is_generic = generic, .type_ast = idx });
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
            // Duplicate variant names made the enum ambiguous: covered[]
            // has one slot per spelling, so a correct match then reported
            // an impossible "non-exhaustive missing variant 'E.A'"
            // (audit §3.7, the enum analogue of the struct-field check,
            // mirror of the seed).
            for (variants[0..i]) |pi| {
                if (std.mem.eql(u8, self.tree.node(pi).enum_variant.name, v.name)) {
                    self.errFmt(self.tree.loc(idx), "duplicate variant '{s}' in enum '{s}'", .{ v.name, e.name });
                    break;
                }
            }
            vs[i] = v.name;
            self.addVariant(v.name, en, false);
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
            .struct_literal => |s| self.checkStructLit(idx, s.name, s.fields, loc),
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
                // Seed parity: only a tagged value can unwind — a type
                // parameter is checked once symbolically and left to its
                // instantiations, everything else fails at run time on
                // both backends, so it fails here instead. The bare `none`
                // literal types as nil, not `T?`, so `none?` is rejected
                // too: propagate absence through a typed optional or
                // `return none`.
                if (inner.kind != .optional and inner.kind != .param) {
                    self.errFmt(loc, "? operator requires Result or Option, got {s}", .{inner.kind.name()});
                    break :blk inner;
                }
                self.tryCheckEnclosingReturn(loc);
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
            .source_file => blk: {
                self.checkModule(idx);
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
        const recv_node = self.tree.addNode(.{ .type_ident = .{ .name = im.type_name } }, self.tree.loc(impl_idx)) catch @panic("OOM");
        const recv = self.resolveTypeNode(recv_node);
        if (isErrorType(recv)) return;
        if (recv.kind != .struct_ and recv.kind != .enum_) {
            self.errFmt(self.tree.loc(impl_idx), "impl requires a struct or enum type, got {s}", .{recv.kind.name()});
            return;
        }
        const inherent = im.trait_name == null;
        const trait_name = im.trait_name orelse "";
        // Phase 2.4 step 4: bound checking consults this record; the method
        // table alone cannot (a method-less trait impl registers no method
        // entry).
        if (im.trait_name) |trn|
            self.impls.append(self.a, .{ .type_name = im.type_name, .trait_name = trn })
                catch @panic("OOM");
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
                const syn = self.tree.addNode(.{ .type_ident = .{ .name = im.type_name } }, floc) catch @panic("OOM");
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

    fn checkModule(self: *TypeChecker, module: u32) void {
        const items = self.tree.extraSlice(self.tree.node(module).source_file);
        // Pass 0: bind every top-level struct/enum name to an empty type
        // before any signature or field type is resolved, so declarations may
        // reference each other in any order (forward references, mutual
        // recursion). checkStructDecl/checkEnumDecl fill the layouts in
        // pass 1 — the pool hands back the same canonical type.
        for (items) |it| {
            switch (self.tree.node(it)) {
                .struct_decl => |s| {
                    // Generic structs register too (Phase 2.4 step 3b):
                    // their name needs a template to instantiate and
                    // `resolveTypeNode` rejects the bare name afterwards.
                    const st = self.pool.structType(s.name) catch @panic("OOM");
                    self.insert(.{ .name = s.name, .type_ = st, .is_mut = false, .is_fn = false,
                        .is_generic = s.generics.len > 0, .type_ast = it });
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
                    // DEC-015: a top-level `fn print()` reports here, before
                    // parameter resolution and the duplicate-function check —
                    // either would otherwise name the wrong rule. Nothing is
                    // registered on the way out; the body pass below still
                    // runs (with the builtin symbol still in place), so a
                    // trivial body reports exactly this one error, like the
                    // seed.
                    if (self.builtinRedeclareError(self.tree.loc(it), f.name)) continue;
                    // A generic signature registers with `.param` placeholders
                    // and is marked `is_generic` (Phase 2.4 step 2a); the body
                    // is checked in pass 2 with the same placeholders in scope.
                    const gmark = self.pushGenericScope(it);
                    const saved_gfn = self.current_generic_fn;
                    self.current_generic_fn = it;
                    const params = self.tree.extraSlice(f.params);
                    var param_types = self.a.alloc(*Type, params.len) catch @panic("OOM");
                    for (params, 0..) |p, j| {
                        param_types[j] = self.resolveTypeNode(self.tree.node(p).param.type_node);
                    }
                    const ret_type: ?*Type = if (f.ret) |r| self.resolveTypeNode(r) else null;
                    // A duplicate top-level fn used to be accepted: the VM
                    // kept the LAST definition while the C backend emitted
                    // the FIRST, so the same file printed different answers
                    // on the two backends (audit §3.10, mirror of the seed).
                    if (self.lookup(f.name)) |prev| {
                        if (prev.is_fn)
                            self.errFmt(self.tree.loc(it), "duplicate function '{s}'", .{f.name});
                    }
                    self.insert(.{ .name = f.name, .type_ = self.newFn(param_types, ret_type), .is_mut = false, .is_fn = true, .is_generic = f.generics.len > 0, .fn_ast = it });
                    self.current_generic_fn = saved_gfn;
                    self.popGenericScope(gmark);
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
                .fn_decl => {
                    self.pending_fn_loc = self.tree.loc(it);
                    self.checkFnDecl(it);
                },
                .var_decl => |v| self.checkVarDecl(v, self.tree.loc(it), false),
                .const_decl => |v| self.checkVarDecl(v, self.tree.loc(it), true),
                .impl_decl => self.checkImplBodies(it),
                // Bodies were fully checked in the first pass; the `else`
                // path re-checked them and duplicated every diagnostic
                // (audit §3.5 surfaced it: "duplicate field" printed
                // twice, mirror of the seed). Nested declarations still
                // go through checkNode inside function bodies.
                .struct_decl, .enum_decl => {},
                else => _ = self.checkNode(it),
            }
        }

        // Phase 2.4 step 2b: append every instance wrapper right after its
        // source item, preserving module-level decl-before-use order. The
        // emitter then sees plain non-generic fn decls; the callee idents
        // of shared bodies resolve through the per-instance rewrites.
        if (self.instances.items.len > 0) {
            var new_items: std.ArrayListUnmanaged(u32) = .empty;
            for (items) |it| {
                new_items.append(self.a, it) catch @panic("OOM");
                for (self.instances.items) |inst| {
                    if (inst.source == it)
                        new_items.append(self.a, inst.wrapper) catch @panic("OOM");
                }
            }
            const list = self.tree.addExtra(new_items.items) catch @panic("OOM");
            self.tree.nodes.items[module].source_file = list;
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
        .and_and => "and",
        .or_or => "or",
        else => @tagName(tag),
    };
}

/// Phase 2.4 step 2b: append `text` to a bounded mangle buffer, stopping
/// silently at the cap (instance names stay far below 512 bytes).
fn bufPut(buf: []u8, pos: *usize, text: []const u8) bool {
    for (text) |c| {
        if (pos.* + 1 < buf.len) {
            buf[pos.*] = c;
            pos.* += 1;
        } else return false;
    }
    return true;
}

/// One recursive step of the mangle: the type's source-level spelling, with
/// fn types collapsed to `fn` (they cannot appear in a binding tuple in
/// practice, and the punctuation would dominate the name). Null on overflow.
fn mangleTypeStr(t: *Type, buf: []u8, pos0: usize) ?usize {
    var pos = pos0;
    switch (t.kind) {
        .void => if (!bufPut(buf, &pos, "void")) return null,
        .bool_ => if (!bufPut(buf, &pos, "bool")) return null,
        .int, .int_literal => if (!bufPut(buf, &pos, "i32")) return null,
        .int64 => if (!bufPut(buf, &pos, "i64")) return null,
        .uint32 => if (!bufPut(buf, &pos, "u32")) return null,
        .uint64 => if (!bufPut(buf, &pos, "u64")) return null,
        .float => if (!bufPut(buf, &pos, "f64")) return null,
        .string => if (!bufPut(buf, &pos, "string")) return null,
        .nil => if (!bufPut(buf, &pos, "nil")) return null,
        .optional => {
            if (!bufPut(buf, &pos, "?")) return null;
            pos = mangleTypeStr(t.inner.?, buf, pos) orelse return null;
        },
        .array => {
            if (!bufPut(buf, &pos, "[")) return null;
            pos = mangleTypeStr(t.elem.?, buf, pos) orelse return null;
            if (!bufPut(buf, &pos, "]")) return null;
        },
        .fn_type => if (!bufPut(buf, &pos, "fn")) return null,
        .struct_, .enum_, .param => if (!bufPut(buf, &pos, t.name)) return null,
        else => if (!bufPut(buf, &pos, "unknown")) return null,
    }
    return pos;
}

/// True when `t` mentions a type parameter owned by `fn_idx` — i.e. the
/// type is still abstract with respect to that declaration.
fn typeMentionsParamOf(t: ?*Type, fn_idx: u32) bool {
    const ty = t orelse return false;
    switch (ty.kind) {
        .param => return ty.owner == fn_idx,
        .optional => return typeMentionsParamOf(ty.inner, fn_idx),
        .array => return typeMentionsParamOf(ty.elem, fn_idx),
        .fn_type => {
            for (ty.params) |p| {
                if (typeMentionsParamOf(p, fn_idx)) return true;
            }
            return typeMentionsParamOf(ty.ret, fn_idx);
        },
        else => return false,
    }
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
