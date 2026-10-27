//! Astra-0 bytecode emitter (Phase 2, Zig).
//!
//! A port of `seed/src/emitter.c`. It lowers the flat AST to the stack bytecode
//! the VM runs (`bytecode.zig`). Three properties from the seed are load-bearing
//! and preserved deliberately:
//!
//! 1. **Stack balance** (`AGENTS.md` invariant #1): every emitted instruction
//!    updates a linear model of the stack height (`sp`) and every `emitExpr` /
//!    `emitStmt` call asserts the net effect its node must have. Branchy
//!    constructs resynchronise `sp` explicitly where their paths rejoin, so an
//!    unbalanced path becomes a compile error instead of a stale-slot read.
//! 2. **Jump offsets**: a jump at instruction `P` targeting `T` stores
//!    `offset = T - P`; the VM does `ip += offset; ip--`.
//! 3. **Function frames**: slot 0 is the callee/return slot, so parameters start
//!    at slot 1. Top-level bindings are globals; function frames reset their
//!    local table.
//!
//! One deliberate deviation from the C seed: its `match` arm loop falls through
//! after handling a payload-binding or builtin-variant arm and emits the arm a
//! second time through the generic path. That copy is unreachable except when a
//! guard fails, where it makes the guard run twice. The Zig port exits the arm
//! after emitting it once; the VM-visible result for deterministic guards is
//! identical and the `sp` model stays clean.

const std = @import("std");
const lexer = @import("../lexer/lexer.zig");
const ast = @import("../ast/ast.zig");
const bc = @import("bytecode.zig");
const diagnostics_mod = @import("../diagnostics.zig");
const modules = @import("../modules/modules.zig");

const OpCode = bc.OpCode;
const Instruction = bc.Instruction;
const Value = bc.Value;

const MAX_LOCALS = 256;
const MAX_CODE = 1024 * 1024;
const MAX_CONSTS = 1024 * 1024;
const MAX_STRUCTS = 128;
const MAX_ENUMS = 128;
const MAX_VARIANTS = 512;
const MAX_FNS = 512;
const MAX_LOOP_DEPTH = 32;

const Local = struct { name: []const u8, slot: u8, depth: u8 };

/// One captured free variable of a lambda, in env-index order.
const Capture = struct { name: []const u8, index: u8 };

/// Compile-time view of a struct declaration.
pub const StructInfo = struct {
    name: []const u8,
    fields: []const []const u8,
    def: *bc.StructDef,
};

/// Compile-time view of an enum declaration. `field_names[v]` is parallel to
/// the variant's payload; an unnamed field keeps an empty name.
pub const EnumInfo = struct {
    name: []const u8,
    variants: []const []const u8,
    field_names: []const []const []const u8,
    field_counts: []const u32,
};

const VariantEntry = struct { variant: []const u8, enum_idx: usize };
const FnName = struct { name: []const u8 };

/// A re-exported name (`use`): `m.X` reads this global instead of `m.X` in
/// module `m`, because the declaration lives in the module that owns it.
pub const NameAlias = struct { name: []const u8, target: []const u8 };

/// One imported name, as the importing module's emitter must resolve it.
pub const ImportRef = struct {
    /// The name as written locally (`add`, or the alias / last segment).
    local: []const u8,
    /// Mangled global of a plain name binding (`from x import add` → `m0.add`).
    /// Empty for a module binding.
    target: []const u8 = "",
    /// Mangled prefix of the exporting module for a namespace binding
    /// (`import a.b as m` → `m0.`); `m.x` becomes global `m0.x`. Empty for a
    /// plain binding.
    module_prefix: []const u8 = "",
    /// Names the module re-exports (`use`): checked before the prefix read,
    /// since a forwarded name lives in its owning module's globals.
    aliases: []const NameAlias = &.{},
};

/// Pending jump sites for the enclosing loop, patched once the exit / continue
/// targets are known.
const LoopPatch = struct {
    breaks: std.ArrayListUnmanaged(usize) = .empty,
    conts: std.ArrayListUnmanaged(usize) = .empty,
    continue_target: usize = 0,
    /// Model height at the loop head (audit §4.10): the back-edge drains the
    /// body's declaration cells to it, so every iteration enters the head at
    /// the height the emitted code assumes.
    head_rt: i32 = 0,
    /// Model height the continue target runs at (the head for `while`, the
    /// increment for `for`): each `continue` path is reconciled to it.
    continue_rt: i32 = 0,
};

/// Phase 2.4 step 2b: one callee-ident node of a generic body renamed to a
/// mangled instance global. The same node is shared by every instance of
/// the enclosing fn, so the name is resolved per wrapper emission.
pub const Rewrite = struct { callee: u32, name: []const u8 };

/// One materialized instantiation of a generic fn, handed over by the
/// checker: `wrapper` is the cloned `fn_decl` whose body the emitter is
/// currently emitting when `current_instance` points here.
pub const Instance = struct { wrapper: u32, rewrites: []const Rewrite };

pub const Emitter = struct {
    a: std.mem.Allocator,
    tree: *ast.Tree,
    filename: []const u8,

    code: std.ArrayListUnmanaged(Instruction) = .empty,
    constants: std.ArrayListUnmanaged(Value) = .empty,

    locals: [MAX_LOCALS]Local = undefined,
    local_count: usize = 0,
    scope_depth: u8 = 0,

    /// Captures of the lambda whose body is currently being emitted (empty
    /// outside lambdas and inside named function bodies).
    captures: [MAX_LOCALS]Capture = undefined,
    capture_count: usize = 0,

    loops: [MAX_LOOP_DEPTH]LoopPatch = undefined,
    loop_depth: usize = 0,

    structs: std.ArrayListUnmanaged(StructInfo) = .empty,
    enums: std.ArrayListUnmanaged(EnumInfo) = .empty,
    variant_index: std.ArrayListUnmanaged(VariantEntry) = .empty,
    fns: std.ArrayListUnmanaged(FnName) = .empty,

    /// Struct/enum declarations of the modules this one imports, handed over
    /// by the driver before emission and merged into the registries by
    /// `registerTypes` after this module's own (a local name wins a
    /// collision). Kept separately as well so namespace-qualified lookups
    /// (`m.Shape.Circle`) can search only what came from imports.
    foreign_structs: []const StructInfo = &.{},
    foreign_enums: []const EnumInfo = &.{},
    /// One entry per `import` binding: the exporting module's registries,
    /// keyed by its mangled prefix, so `m.Enum.Variant` resolves at compile
    /// time (`m.Enum` itself is not a runtime global).
    namespaces: []const NamespaceTypes = &.{},

    sp: i32 = 0,
    sp_high: i32 = 0,

    /// Exact VM frame height (frame-relative, callee slot included; 0 at
    /// module level). Unlike `sp`, which models the historical "locals don't
    /// count" convention, `rt` tracks what the VM will actually see:
    /// SET_LOCAL pads the frame up to its slot, popScope reclaims table
    /// entries but never stack cells, and a value construct's pending values
    /// (a call's receiver) sit above the local table. The match/if emitters
    /// place their hidden slots, arm locals and closes at this frontier —
    /// see audit §4.7.
    rt: i32 = 0,

    /// Mangled prefix of this module's globals ("" for single-file).
    prefix: []const u8 = "",
    /// Names bound by import declarations, mapped to their real globals.
    imports: []const ImportRef = &.{},
    /// Module-level names THIS module declares (fn/let/var/const). Only these
    /// are mangled — a bare name that is not declared here is a builtin
    /// (`print`) or an undefined global, and both keep the source name.
    module_globals: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Generic instances materialized by the checker (Phase 2.4 step 2b):
    /// while a wrapper's body is being emitted, `current_instance` renames
    /// the callee idents listed in its rewrites to the mangled globals.
    instances: []const Instance = &.{},
    current_instance: ?*const Instance = null,

    error_count: usize = 0,
    /// Optional sink: when wired, errors are recorded there (and echoed to
    /// stderr); when null, they print directly. Both paths share one format.
    diag: ?*diagnostics_mod.Sink = null,

    // Limit reports fire once each: a 300-local function would otherwise
    // print the same diagnostic per binding.
    code_limit_reported: bool = false,
    const_limit_reported: bool = false,
    locals_limit_reported: bool = false,

    pub fn init(a: std.mem.Allocator, tree: *ast.Tree, filename: []const u8) Emitter {
        return .{ .a = a, .tree = tree, .filename = filename };
    }

    /// Phase 2.4 step 2b: the checker's materialized generic instances.
    /// Call before `emit`/`emitModule`.
    pub fn setInstances(self: *Emitter, instances: []const Instance) void {
        self.instances = instances;
    }

    /// Multi-module form: `prefix` mangles every module-level global this
    /// module defines (`m1.` + `add` → `m1.add`, unique across the graph —
    /// the VM's globals table is flat and name-keyed), and `imports` maps
    /// each imported local name to the global it must actually read.
    pub fn initWithModules(
        a: std.mem.Allocator,
        tree: *ast.Tree,
        filename: []const u8,
        prefix: []const u8,
        imports: []const ImportRef,
    ) Emitter {
        return .{ .a = a, .tree = tree, .filename = filename, .prefix = prefix, .imports = imports };
    }

    /// The runtime global name for a module-level declaration of this module.
    /// Builtins and unknown names pass through: they are not this module's
    /// globals and the VM resolves (or rejects) them under the source name.
    fn globalName(self: *const Emitter, name: []const u8) []const u8 {
        if (self.prefix.len == 0) return name;
        for (self.module_globals.items) |g| {
            if (std.mem.eql(u8, g, name)) {
                return std.fmt.allocPrint(self.a, "{s}{s}", .{ self.prefix, name }) catch @panic("OOM");
            }
        }
        return name;
    }

    /// Record the module-level names this module declares, for `globalName`.
    fn collectModuleGlobals(self: *Emitter, module: u32) void {
        const items = switch (self.tree.node(module)) {
            .source_file => |list| self.tree.extraSlice(list),
            else => return,
        };
        for (items) |item| {
            switch (self.tree.node(item)) {
                // A generic declaration is inert (Phase 2.4 step 1): it never
                // binds a runtime global, so nothing prefixes its name.
                .fn_decl => |f| if (f.generics.len == 0) self.module_globals.append(self.a, f.name) catch @panic("OOM"),
                .var_decl => |v| self.module_globals.append(self.a, v.name) catch @panic("OOM"),
                .const_decl => |v| self.module_globals.append(self.a, v.name) catch @panic("OOM"),
                // Method names are already mangled (`Type.method`) — the
                // checker rewrote them — and must prefix like any global.
                .impl_decl => |im| {
                    if (im.generics.len > 0) continue; // inert (Phase 2.4 step 1)
                    for (self.tree.extraSlice(im.items)) |fidx| {
                        if (std.meta.activeTag(self.tree.node(fidx)) == .fn_decl and
                            self.tree.node(fidx).fn_decl.generics.len == 0)
                        {
                            self.module_globals.append(self.a, self.tree.node(fidx).fn_decl.name) catch @panic("OOM");
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// The import binding a local name resolves to, if any.
    fn importFor(self: *const Emitter, name: []const u8) ?ImportRef {
        for (self.imports) |ref| {
            if (std.mem.eql(u8, ref.local, name)) return ref;
        }
        return null;
    }

    /// Report an emitter error against source line `ln` (0 when the emitter
    /// has no position — table overflows reported at a choke point). The
    /// sink/formatter adds the file prefix and the `error:` tag.
    fn err(self: *Emitter, ln: u32, comptime fmt: []const u8, args: anytype) void {
        self.error_count += 1;
        diagnostics_mod.emit(self.diag, self.filename, .{ .start = 0, .end = 0, .line = ln, .col = 0 }, fmt, args);
    }

    /// Same report with the position the emitter actually has for the node —
    /// `file:line:col:` like every other phase (used by the loop-nest guard,
    /// whose callers hold a full `Loc`; audit §6.3).
    fn errLoc(self: *Emitter, loc: lexer.Loc, comptime fmt: []const u8, args: anytype) void {
        self.error_count += 1;
        diagnostics_mod.emit(self.diag, self.filename, .{ .start = loc.start, .end = loc.end, .line = loc.line, .col = loc.col }, fmt, args);
    }

    fn line(self: *const Emitter, idx: u32) u32 {
        return self.tree.loc(idx).line;
    }

    // ── Stack-height model ────────────────────────────────────────

    fn spAdvance(self: *Emitter, delta: i32) void {
        self.sp += delta;
        if (self.sp > self.sp_high) self.sp_high = self.sp;
    }

    /// Height effect of one instruction on the *actual* VM frame (`self.rt`).
    /// Identical to `stackEffect` except for SET_LOCAL, where the VM pops the
    /// value and then pads the frame with nil up to the slot: the new height
    /// is max(rt-1, slot+1) — net 0 when the slot sits at the frontier (a
    /// fresh local), -1 when it reuses a slot further down (audit §4.7).
    fn rtAdvance(self: *Emitter, op: OpCode, operand: u32) void {
        if (op == .set_local) {
            const after_pop = self.rt - 1;
            const after_pad: i32 = @as(i32, @intCast(operand)) + 1;
            self.rt = @max(after_pop, after_pad);
        } else {
            self.rt += op.stackEffect(operand);
        }
    }

    fn emitInst(self: *Emitter, op: OpCode, ln: u32) void {
        // The limit is a policy, not a physical wall: report it, then keep
        // appending so the stack model stays consistent. error_count > 0
        // means nothing will run; dropping the instruction instead used to
        // corrupt the program silently (AGENTS.md invariant #8).
        if (self.code.items.len >= MAX_CODE and !self.code_limit_reported) {
            self.code_limit_reported = true;
            self.err(ln, "too many instructions (max {d})", .{MAX_CODE});
        }
        self.code.append(self.a, .{ .op = op, .line = ln }) catch @panic("OOM");
        self.spAdvance(op.stackEffect(0));
        // SET_LOCAL's height effect depends on its slot operand, which
        // emitInstIndex patches right after this returns — spSetIndex
        // applies it there. Every SET_LOCAL must go through emitInstIndex.
        if (op != .set_local) self.rtAdvance(op, 0);
    }

    /// Patch an instruction's `index` operand, correcting the stack model for
    /// opcodes whose operand changes their effect (POP, NEW_ARRAY, …).
    fn spSetIndex(self: *Emitter, code_index: usize, value: u32) void {
        if (code_index >= self.code.items.len) return;
        const op = self.code.items[code_index].op;
        const old = switch (self.code.items[code_index].arg) {
            .index => |v| v,
            else => 0,
        };
        self.code.items[code_index].arg = .{ .index = value };
        self.spAdvance(op.stackEffect(value) - op.stackEffect(old));
        if (op == .set_local) {
            // emitInst skipped it: now that the slot is known, apply the
            // exact runtime effect (see rtAdvance).
            self.rtAdvance(op, value);
        } else {
            self.rt += op.stackEffect(value) - op.stackEffect(old);
        }
    }

    fn spSetArgcount(self: *Emitter, code_index: usize, value: u8) void {
        if (code_index >= self.code.items.len) return;
        const op = self.code.items[code_index].op;
        const old = switch (self.code.items[code_index].arg) {
            .arg_count => |v| v,
            else => 0,
        };
        self.code.items[code_index].arg = .{ .arg_count = value };
        self.spAdvance(op.stackEffect(value) - op.stackEffect(old));
        self.rt += op.stackEffect(value) - op.stackEffect(old);
    }

    fn emitInstIndex(self: *Emitter, op: OpCode, index: u32, ln: u32) void {
        const base = self.code.items.len;
        self.emitInst(op, ln);
        self.spSetIndex(base, index);
    }

    fn emitInstOffset(self: *Emitter, op: OpCode, offset: i32, ln: u32) void {
        const base = self.code.items.len;
        self.emitInst(op, ln);
        self.code.items[base].arg = .{ .offset = offset };
    }

    // ── Constant pool ─────────────────────────────────────────────

    fn addConstant(self: *Emitter, val: Value) u32 {
        for (self.constants.items, 0..) |c, i| {
            if (std.meta.activeTag(c) != std.meta.activeTag(val)) continue;
            switch (val) {
                .nil => return @intCast(i),
                .bool_ => |b| if (c.bool_ == b) return @intCast(i),
                .int => |v| if (c.int == v) return @intCast(i),
                .float => |v| if (c.float == v) return @intCast(i),
                .struct_def => |p| if (c.struct_def == p) return @intCast(i),
                else => {},
            }
        }
        // Like emitInst, report and keep going: returning index 0 used to
        // silently alias every further constant to the first one.
        if (self.constants.items.len >= MAX_CONSTS and !self.const_limit_reported) {
            self.const_limit_reported = true;
            self.err(0, "too many constants (max {d})", .{MAX_CONSTS});
        }
        const idx: u32 = @intCast(self.constants.items.len);
        self.constants.append(self.a, val) catch @panic("OOM");
        return idx;
    }

    fn addNil(self: *Emitter) u32 {
        return self.addConstant(bc.vNil());
    }

    // ── Locals ────────────────────────────────────────────────────

    fn addLocal(self: *Emitter, name: []const u8) u8 {
        if (self.local_count >= MAX_LOCALS) {
            // Reporting here — at the choke point — closes every call site at
            // once. The seed used to reach this only from `match` and let a
            // plain `let` past 256 locals silently become a *global*, changing
            // the program's scoping without a word.
            if (!self.locals_limit_reported) {
                self.locals_limit_reported = true;
                self.err(0, "too many locals (max {d})", .{MAX_LOCALS});
            }
            return 0xFF;
        }
        const slot: u8 = @intCast(self.local_count);
        self.locals[self.local_count] = .{ .name = name, .slot = slot, .depth = self.scope_depth };
        self.local_count += 1;
        return slot;
    }

    fn findLocal(self: *Emitter, name: []const u8) ?usize {
        var i = self.local_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals[i].name, name)) return i;
        }
        return null;
    }

    /// Index of a captured variable in the current lambda's env, if any.
    fn findCapture(self: *const Emitter, name: []const u8) ?usize {
        var i = self.capture_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.captures[i].name, name)) return i;
        }
        return null;
    }

    /// Release the slots of the locals declared in the scope being left.
    ///
    /// Deliberately emits no POP: locals live in VM stack slots *below* sp
    /// (SET_LOCAL pads with nil to reach them), so a POP would remove the
    /// block's result instead. Dropping the index from the table is enough; a
    /// later binding reuses the slot.
    fn popScope(self: *Emitter) void {
        while (self.local_count > 0 and
            self.locals[self.local_count - 1].depth >= self.scope_depth)
        {
            self.local_count -= 1;
        }
    }

    /// Pad the local table up to the runtime frontier (audit §4.7). The
    /// locals a value construct allocates (hidden scrutinee, arm bindings,
    /// arm `let`s) must all land at or above every cell that is already
    /// live: a call receiver pushed just before the construct sits at rt-1,
    /// and a declaration-count slot below it would overwrite the receiver,
    /// because SET_LOCAL writes at base+slot. After padding,
    /// `local_count == rt`, so each of the construct's SET_LOCALs lands
    /// exactly on the frontier and extends the frame the way the VM's own
    /// padding does.
    fn padLocalsToRt(self: *Emitter, rt: i32) void {
        while (@as(i32, @intCast(self.local_count)) < rt) {
            if (self.addLocal("$pad") == 0xFF)
                break; // addLocal already reported the limit; recovery only
        }
    }

    /// Close a value construct (audit §4.7). Its result sits on top of the
    /// stack, but the cells the construct allocated — hidden scrutinee,
    /// bindings, arm locals — sit between the frontier the construct entered
    /// at and that result. Move the result down to `target` (the entry
    /// frontier) and drop everything above it, so every path leaves exactly
    /// one cell — the value — above where the construct started. The
    /// receiver of a surrounding call then sits at target-1 with the result
    /// at target, which keeps the callee and its arguments contiguous for
    /// CALL's fn_idx = sp - 1 - argc.
    fn emitValueClose(self: *Emitter, target: i32, ln: u32) void {
        self.emitInstIndex(.set_local, @intCast(target), ln);
        // rtAdvance's max() guarantees self.rt >= target + 1 after the store.
        const extra = self.rt - (target + 1);
        if (extra > 0) {
            self.emitInst(.pop, ln);
            self.spSetIndex(self.code.items.len - 1, @intCast(extra));
        }
    }

    /// After a loop, the cells its declarations created exist only on paths
    /// that executed them: a `while false { let t = 1 }` (or a `break`
    /// before the declaration) leaves the frame lower than the linear model
    /// counted, and a later value construct would compute its frontier from
    /// a height the runtime never reached (audit §4.7). Re-create the
    /// missing cells unconditionally at the exit target: each
    /// `CONST nil; SET_LOCAL s` either fills a hole — extending the frame up
    /// to the model, exactly like the VM's padding — or overwrites a dead
    /// loop local with nil. Every exit path (natural, `break`, zero
    /// iterations) then leaves the same height. The range starts at the
    /// loop-entry frontier, so loop state that outlives an iteration (for_i,
    /// for_arr, the loop variable) is only overwritten after the loop ends,
    /// when it is dead.
    fn emitLoopExitEnsure(self: *Emitter, entry_rt: i32, ln: u32) void {
        var s = entry_rt;
        while (s < self.rt) : (s += 1) {
            const z = self.addNil();
            self.emitInstIndex(.const_, z, ln);
            self.emitInstIndex(.set_local, @intCast(s), ln);
        }
    }

    /// Back-edge reconcile (audit §4.10). The body's model heights are
    /// computed at loop entry, but the natural back-edge carries the runtime
    /// to the body-end height: from the second iteration on, the body would
    /// run one (or more) cells high, and a value construct whose hidden slot
    /// or close target sits between the two heights overwrites live cells —
    /// a call's receiver among them (`print(match …)` then dials a stale
    /// cell and traps "cannot call non-function value"). Drain the
    /// difference before jumping back, so every iteration enters the head at
    /// head_rt and re-creates its own declaration cells. The stub only runs
    /// on the back-edge path, so the linear model (and loopLeave's exit
    /// height) stays untouched.
    fn emitBackEdgeReconcile(self: *Emitter, lp: ?*LoopPatch, ln: u32) void {
        const p = lp orelse return;
        const discard = self.rt - p.head_rt;
        if (discard <= 0) return;
        const sp_save = self.sp;
        const rt_save = self.rt;
        self.emitInst(.pop, ln);
        self.spSetIndex(self.code.items.len - 1, @intCast(discard));
        self.sp = sp_save;
        self.rt = rt_save;
    }

    // ── Free-variable analysis (closures) ───────────────────────

    /// Names visible to the analysis as a stack of (name, scope mark); a
    /// scope exit forgets everything bound after its mark. Free names that
    /// resolve in the *enclosing emitter* (a local slot or one of its own
    /// captures) become this lambda's env; everything else stays a global.
    /// This is the seed's FreeVars/fv_walk, transposed onto the flat tree.
    const FreeVars = struct {
        em: *Emitter,
        names: [MAX_LOCALS]FvName = undefined,
        name_count: usize = 0,
        marks: [MAX_LOCALS]u32 = undefined,
        mark_count: usize = 0,
        caps: [MAX_LOCALS]Capture = undefined,
        cap_count: usize = 0,
        overflow: bool = false,

        const FvName = struct { name: []const u8, mark: u32 };

        fn pushScope(fv: *FreeVars) void {
            if (fv.mark_count < MAX_LOCALS) {
                fv.marks[fv.mark_count] = @intCast(fv.name_count);
                fv.mark_count += 1;
            }
        }
        fn popScope(fv: *FreeVars) void {
            if (fv.mark_count == 0) return;
            fv.mark_count -= 1;
            fv.name_count = fv.marks[fv.mark_count];
        }
        fn bind(fv: *FreeVars, name: []const u8) void {
            if (fv.name_count >= MAX_LOCALS) return;
            fv.names[fv.name_count] = .{ .name = name, .mark = @intCast(fv.mark_count) };
            fv.name_count += 1;
        }
        fn bound(fv: *const FreeVars, name: []const u8) bool {
            var i = fv.name_count;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, fv.names[i].name, name)) return true;
            }
            return false;
        }
        fn ref(fv: *FreeVars, name: []const u8) void {
            if (fv.bound(name)) return;
            for (0..fv.cap_count) |i| {
                if (std.mem.eql(u8, fv.caps[i].name, name)) return;
            }
            const em = fv.em;
            if (em.findLocal(name) != null or em.findCapture(name) != null) {
                if (fv.cap_count >= 255) {
                    fv.overflow = true;
                    return;
                }
                fv.caps[fv.cap_count] = .{ .name = name, .index = @intCast(fv.cap_count) };
                fv.cap_count += 1;
            }
            // else: a module-level name — global or import binding — which
            // keeps resolving through GET_GLOBAL, unchanged.
        }
        fn pattern(fv: *FreeVars, pat: u32) void {
            switch (fv.em.tree.node(pat)) {
                .pattern_bind => |name| fv.bind(name),
                .pattern_variant_bind => |vb| {
                    for (fv.em.tree.extraSlice(vb.bindings)) |b| fv.pattern(b);
                },
                .pattern_builtin_variant => |b| {
                    if (b.payload) |p| fv.pattern(p);
                },
                .pattern_or => |alts| {
                    for (fv.em.tree.extraSlice(alts)) |a| fv.pattern(a);
                },
                else => {},
            }
        }
        fn walk(fv: *FreeVars, idx: u32) void {
            switch (fv.em.tree.node(idx)) {
                .identifier => |name| fv.ref(name),
                .assignment => |asn| {
                    // The target is treated as a read so that assigning to a
                    // captured name still lands in the capture set, where
                    // emission reports "cannot assign to captured variable".
                    const tgt = fv.em.tree.node(asn.target);
                    if (std.meta.activeTag(tgt) == .identifier) fv.ref(tgt.identifier);
                    fv.walk(asn.value);
                },
                .compound_assignment => |ca| {
                    const tgt = fv.em.tree.node(ca.target);
                    if (std.meta.activeTag(tgt) == .identifier) fv.ref(tgt.identifier);
                    fv.walk(ca.value);
                },
                .binary_expr => |b| {
                    fv.walk(b.left);
                    fv.walk(b.right);
                },
                .unary_expr => |u| fv.walk(u.operand),
                .call_expr => |c| {
                    fv.walk(c.callee);
                    for (fv.em.tree.extraSlice(c.args)) |a| fv.walk(a);
                },
                .index_expr => |ix| {
                    fv.walk(ix.object);
                    fv.walk(ix.index);
                },
                .field_access => |fa| fv.walk(fa.object),
                .array_literal => |list| {
                    for (fv.em.tree.extraSlice(list)) |e| fv.walk(e);
                },
                .range_expr => |r| {
                    if (r.start_node) |s| fv.walk(s);
                    if (r.end_node) |e| fv.walk(e);
                },
                .struct_literal => |sl| {
                    for (fv.em.tree.extraSlice(sl.fields)) |f| {
                        fv.walk(fv.em.tree.node(f).struct_init_field.value);
                    }
                },
                .some_expr, .ok_expr, .err_expr, .try_expr => |inner| fv.walk(inner),
                .none_expr, .nil_literal, .int_literal, .float_literal,
                .string_literal, .bool_literal, .break_stmt, .continue_stmt => {},
                .if_expr => |ie| {
                    fv.walk(ie.cond);
                    fv.walk(ie.then_block);
                    if (ie.else_block) |eb| fv.walk(eb);
                },
                .while_expr => |w| {
                    fv.walk(w.cond);
                    fv.walk(w.body);
                },
                .for_expr => |f| {
                    // emitFor evaluates the iterable before binding the loop
                    // variable, so the walker does too.
                    fv.pushScope();
                    fv.walk(f.iter);
                    fv.bind(f.var_name);
                    fv.walk(f.body);
                    fv.popScope();
                },
                .match_expr => |m| {
                    fv.walk(m.target);
                    for (fv.em.tree.extraSlice(m.arms)) |arm_idx| {
                        const arm = fv.em.tree.node(arm_idx).match_arm;
                        fv.pushScope();
                        fv.pattern(arm.pattern);
                        if (arm.guard) |g| fv.walk(g);
                        fv.walk(arm.body);
                        fv.popScope();
                    }
                },
                .block => |b| {
                    fv.pushScope();
                    for (fv.em.tree.extraSlice(b.stmts)) |s| fv.walk(s);
                    if (b.tail) |t| fv.walk(t);
                    fv.popScope();
                },
                .expr_stmt => |inner| fv.walk(inner),
                .return_stmt => |maybe| {
                    if (maybe) |v| fv.walk(v);
                },
                .lambda_expr => |l| {
                    // A nested lambda's free names may come from THIS frame
                    // (its locals or its own captures) and count as captures
                    // of the enclosing lambda — the chain the seed builds.
                    fv.pushScope();
                    for (fv.em.tree.extraSlice(l.params)) |p| {
                        fv.bind(fv.em.tree.node(p).param.name);
                    }
                    fv.walk(l.body);
                    fv.popScope();
                },
                .fn_decl => |f| {
                    // Named functions do not capture: bind only the name in
                    // the enclosing lambda; the body is not walked.
                    fv.bind(f.name);
                },
                .var_decl, .const_decl => {
                    const v = switch (fv.em.tree.node(idx)) {
                        .var_decl => |v| v,
                        .const_decl => |v| v,
                        else => unreachable,
                    };
                    if (v.value) |val| fv.walk(val);
                    fv.bind(v.name);
                },
                else => {},
            }
        }
    };

    // ── Type registries ───────────────────────────────────────────

    fn findStruct(self: *Emitter, name: []const u8) ?*StructInfo {
        for (self.structs.items) |*si| {
            if (std.mem.eql(u8, si.name, name)) return si;
        }
        return null;
    }

    fn findEnum(self: *Emitter, name: []const u8) ?*EnumInfo {
        for (self.enums.items) |*ei| {
            if (std.mem.eql(u8, ei.name, name)) return ei;
        }
        return null;
    }

    fn enumVariantIndex(ei: *const EnumInfo, variant: []const u8) ?usize {
        for (ei.variants, 0..) |v, i| {
            if (std.mem.eql(u8, v, variant)) return i;
        }
        return null;
    }

    fn findEnumByVariant(self: *Emitter, variant: []const u8) ?*EnumInfo {
        for (self.variant_index.items) |vi| {
            if (std.mem.eql(u8, vi.variant, variant)) return &self.enums.items[vi.enum_idx];
        }
        return null;
    }

    fn isKnownFn(self: *Emitter, name: []const u8) bool {
        for (self.fns.items) |f| {
            if (std.mem.eql(u8, f.name, name)) return true;
        }
        return false;
    }

    /// Give the emitter the declarations its imports bring in. Must run
    /// before emission (the driver builds the lists between `init` and
    /// `emitModule`): `registerTypes` merges them after this module's own.
    pub fn setForeignTypes(
        self: *Emitter,
        structs: []const StructInfo,
        enums: []const EnumInfo,
        namespaces: []const NamespaceTypes,
    ) void {
        self.foreign_structs = structs;
        self.foreign_enums = enums;
        self.namespaces = namespaces;
    }

    /// An enum of `prefix`'s module named `name`, for `m.Enum.Variant`.
    fn findNamespaceEnum(self: *const Emitter, prefix: []const u8, name: []const u8) ?*const EnumInfo {
        for (self.namespaces) |ns| {
            if (!std.mem.eql(u8, ns.prefix, prefix)) continue;
            for (ns.types.enums) |*ei| {
                if (std.mem.eql(u8, ei.name, name)) return ei;
            }
        }
        return null;
    }

    /// Collect struct/enum/function declarations before emitting code so that
    /// literals, field accesses and variants resolve without a type table.
    fn registerTypes(self: *Emitter, module: u32) void {
        for (self.tree.extraSlice(self.tree.node(module).source_file)) |item| {
            switch (self.tree.node(item)) {
                .fn_decl => |f| {
                    // Inert (Phase 2.4 step 1): the checker skipped it, so
                    // nothing can call it and no global binds its name.
                    if (f.generics.len > 0) continue;
                    if (self.fns.items.len >= MAX_FNS) {
                        self.err(self.line(item), "too many functions (max {d})", .{MAX_FNS});
                        continue;
                    }
                    self.fns.append(self.a, .{ .name = f.name }) catch @panic("OOM");
                },
                .enum_decl => |e| {
                    if (e.generics.len > 0) continue; // inert (Phase 2.4 step 1)
                    if (self.enums.items.len >= MAX_ENUMS) {
                        self.err(self.line(item), "too many enum declarations (max {d})", .{MAX_ENUMS});
                        continue;
                    }
                    const decl_variants = self.tree.extraSlice(e.variants);
                    const nv = decl_variants.len;
                    const names = self.a.alloc([]const u8, nv) catch @panic("OOM");
                    const counts = self.a.alloc(u32, nv) catch @panic("OOM");
                    const fnames = self.a.alloc([]const []const u8, nv) catch @panic("OOM");
                    for (decl_variants, 0..) |v_idx, j| {
                        const v = self.tree.node(v_idx).enum_variant;
                        names[j] = v.name;
                        const payload = v.payload;
                        const nf = if (payload) |p| self.tree.extraSlice(self.tree.node(p).payload).len else 0;
                        counts[j] = @intCast(nf);
                        const flist = self.a.alloc([]const u8, nf) catch @panic("OOM");
                        if (payload) |p| {
                            for (self.tree.extraSlice(self.tree.node(p).payload), 0..) |f, k| {
                                flist[k] = self.tree.node(f).field_decl.name;
                            }
                        }
                        fnames[j] = flist;
                    }
                    const enum_idx = self.enums.items.len;
                    self.enums.append(self.a, .{
                        .name = e.name,
                        .variants = names,
                        .field_names = fnames,
                        .field_counts = counts,
                    }) catch @panic("OOM");
                    // Only data-carrying variants need construction resolution.
                    for (names, 0..) |vname, j| {
                        if (counts[j] == 0) continue;
                        if (self.variant_index.items.len >= MAX_VARIANTS) {
                            self.err(self.line(item), "too many enum variants (max {d})", .{MAX_VARIANTS});
                            break;
                        }
                        self.variant_index.append(self.a, .{ .variant = vname, .enum_idx = enum_idx }) catch @panic("OOM");
                    }
                },
                .struct_decl => |s| {
                    // Generic declarations register under their source name
                    // (Phase 2.4 step 3b): literals always spell the bare
                    // name (`Box { ... }`) and every instance shares this
                    // definition — the field names are the same for all.
                    if (self.structs.items.len >= MAX_STRUCTS) {
                        self.err(self.line(item), "too many struct declarations (max {d})", .{MAX_STRUCTS});
                        continue;
                    }
                    const decl_fields = self.tree.extraSlice(s.fields);
                    const n = decl_fields.len;
                    const names = self.a.alloc([]const u8, n) catch @panic("OOM");
                    const def_names = self.a.alloc([]const u8, n) catch @panic("OOM");
                    for (decl_fields, 0..) |f, j| {
                        const fname = self.tree.node(f).field_decl.name;
                        names[j] = fname;
                        def_names[j] = fname;
                    }
                    const def = self.a.create(bc.StructDef) catch @panic("OOM");
                    def.* = .{ .name = s.name, .field_names = def_names };
                    self.structs.append(self.a, .{ .name = s.name, .fields = names, .def = def }) catch @panic("OOM");
                },
                else => {},
            }
        }
        // Imported declarations come after this module's own, so a local name
        // wins any collision. Their `def` pointers stay in the exporting
        // module's arena; sharing them across modules is safe (arena lives
        // for the whole compilation).
        for (self.foreign_structs) |fs| {
            if (self.structs.items.len >= MAX_STRUCTS) {
                self.err(0, "too many struct declarations (max {d})", .{MAX_STRUCTS});
                break;
            }
            self.structs.append(self.a, fs) catch @panic("OOM");
        }
        for (self.foreign_enums) |fe| {
            if (self.enums.items.len >= MAX_ENUMS) {
                self.err(0, "too many enum declarations (max {d})", .{MAX_ENUMS});
                break;
            }
            const enum_idx = self.enums.items.len;
            self.enums.append(self.a, fe) catch @panic("OOM");
            for (fe.variants, 0..) |vname, j| {
                if (fe.field_counts[j] == 0) continue;
                if (self.variant_index.items.len >= MAX_VARIANTS) {
                    self.err(0, "too many enum variants (max {d})", .{MAX_VARIANTS});
                    break;
                }
                self.variant_index.append(self.a, .{ .variant = vname, .enum_idx = enum_idx }) catch @panic("OOM");
            }
        }
    }

    // ── Loop patch lists ──────────────────────────────────────────

    fn loopEnter(self: *Emitter, loc: lexer.Loc) ?*LoopPatch {
        if (self.loop_depth >= MAX_LOOP_DEPTH) {
            self.errLoc(loc, "loop nesting too deep (max {d})", .{MAX_LOOP_DEPTH});
            return null;
        }
        const lp = &self.loops[self.loop_depth];
        lp.* = .{};
        self.loop_depth += 1;
        return lp;
    }

    /// Finish a loop and return the real join point of its exit paths. A
    /// `break` jumps out from wherever it appears: when it sits above the
    /// exit height — because it skipped a match/if close on its way — its
    /// path must drop those dead cells before joining, or a later value
    /// construct would compute a frontier the runtime never reaches (audit
    /// §4.7). `break_stmt` stashed the model height of each break in its
    /// placeholder offset. Breaks at or below the exit height join directly:
    /// the loop exit's ensure fills them in. The reconcile stubs are
    /// appended here, so the caller must re-patch the natural exit (the
    /// condition's jump) past them, onto the returned join.
    fn loopLeave(self: *Emitter, lp: ?*LoopPatch) usize {
        const p = lp orelse return self.code.items.len;
        const exit_rt = self.rt;
        const n = p.breaks.items.len;
        const heights = self.a.alloc(i32, n) catch @panic("OOM");
        const stub_jumps = self.a.alloc(usize, n) catch @panic("OOM");
        for (p.breaks.items, 0..) |b, i| {
            // break_stmt stashed the model height here; remember it before
            // the offset is patched away.
            heights[i] = switch (self.code.items[b].arg) {
                .offset => |v| v,
                else => 0,
            };
            stub_jumps[i] = 0;
        }
        for (p.breaks.items, 0..) |b, i| {
            const extra = heights[i] - exit_rt;
            if (extra > 0) {
                const site = b;
                const bline = self.code.items[site].line;
                // The stub only runs on this break's path; keep the linear
                // model (which continues at the natural exit) untouched.
                const sp_save = self.sp;
                const rt_save = self.rt;
                const site_off: i32 = @intCast(@as(i64, @intCast(self.code.items.len)) - @as(i64, @intCast(site)));
                self.code.items[site].arg = .{ .offset = site_off };
                self.emitInst(.pop, bline);
                self.spSetIndex(self.code.items.len - 1, @intCast(extra));
                self.emitInstOffset(.jump, 0, bline);
                self.sp = sp_save;
                self.rt = rt_save;
                stub_jumps[i] = self.code.items.len - 1;
            }
        }
        // Continue reconcile stubs (audit §4.10). A `continue` jumps straight
        // to the loop head (while) or the increment (for), skipping the
        // back-edge drain, so its path must arrive at the height the target
        // runs at: above it, drop the cells whose close the jump skips; below
        // it (a continue before declarations the target's natural path
        // executed), re-create them as nil — the next iteration overwrites
        // each before any read. continue_stmt stashed its model height in the
        // placeholder offset, like break_stmt.
        const nc = p.conts.items.len;
        const c_heights = self.a.alloc(i32, nc) catch @panic("OOM");
        const c_stub_jumps = self.a.alloc(usize, nc) catch @panic("OOM");
        for (p.conts.items, 0..) |c, i| {
            c_heights[i] = switch (self.code.items[c].arg) {
                .offset => |v| v,
                else => 0,
            };
            c_stub_jumps[i] = 0;
        }
        for (p.conts.items, 0..) |c, i| {
            const extra = c_heights[i] - p.continue_rt;
            if (extra == 0) continue;
            const site = c;
            const cline = self.code.items[site].line;
            // The stub only runs on this continue's path; keep the linear
            // model untouched, like the break stubs above.
            const sp_save = self.sp;
            const rt_save = self.rt;
            const site_off: i32 = @intCast(@as(i64, @intCast(self.code.items.len)) - @as(i64, @intCast(site)));
            self.code.items[site].arg = .{ .offset = site_off };
            if (extra > 0) {
                self.emitInst(.pop, cline);
                self.spSetIndex(self.code.items.len - 1, @intCast(extra));
            } else {
                const z = self.addNil();
                var k: i32 = 0;
                while (k < -extra) : (k += 1) self.emitInstIndex(.const_, z, cline);
            }
            self.emitInstOffset(.jump, 0, cline);
            c_stub_jumps[i] = self.code.items.len - 1;
            self.sp = sp_save;
            self.rt = rt_save;
        }
        const join = self.code.items.len;
        for (p.breaks.items, 0..) |b, i| {
            const stubbed = stub_jumps[i] != 0;
            const extra = heights[i] - exit_rt;
            if (!stubbed and extra <= 0) {
                const off: i32 = @intCast(@as(i64, @intCast(join)) - @as(i64, @intCast(b)));
                self.code.items[b].arg = .{ .offset = off };
            }
        }
        for (p.breaks.items, 0..) |_, i| {
            if (stub_jumps[i] != 0) {
                const sj = stub_jumps[i];
                const off: i32 = @intCast(@as(i64, @intCast(join)) - @as(i64, @intCast(sj)));
                self.code.items[sj].arg = .{ .offset = off };
            }
        }
        // `continue` jumps *back* to the continue target, so the offset is
        // negative; compute it signed rather than wrapping unsigned arithmetic.
        for (p.conts.items, 0..) |c, i| {
            const landing = if (c_stub_jumps[i] != 0) c_stub_jumps[i] else c;
            const off: i32 = @intCast(@as(i64, @intCast(p.continue_target)) - @as(i64, @intCast(landing)));
            self.code.items[landing].arg = .{ .offset = off };
        }
        self.loop_depth -= 1;
        return join;
    }

    fn patchPush(self: *Emitter, list: *std.ArrayListUnmanaged(usize), idx: usize) void {
        list.append(self.a, idx) catch @panic("OOM");
    }

    // ── Branch helpers ────────────────────────────────────────────

    fn blockHasTail(self: *Emitter, idx: u32) bool {
        const n = self.tree.node(idx);
        return std.meta.activeTag(n) == .block and n.block.tail != null;
    }

    /// Emit a branch so it always leaves exactly one value: a block with no tail
    /// would otherwise leave nothing and disagree with the other `if`/`match`
    /// arms on stack height.
    fn emitValueBranch(self: *Emitter, idx: u32) void {
        const n = self.tree.node(idx);
        if (std.meta.activeTag(n) == .block and n.block.tail == null) {
            self.emitExpr(idx);
            const z = self.addNil();
            self.emitInstIndex(.const_, z, self.line(idx));
        } else {
            self.emitExpr(idx);
        }
    }

    fn emitBranchValue(self: *Emitter, idx: u32, where: []const u8, ln: u32) void {
        const before = self.sp;
        self.emitValueBranch(idx);
        if (self.sp != before + 1) {
            self.err(ln, "internal: {s} body left {d} values, expected 1", .{ where, self.sp - before });
            self.sp = before + 1;
        }
    }

    /// Loop bodies are statements: a tail value must not accumulate across
    /// iterations.
    fn emitLoopBody(self: *Emitter, idx: u32) void {
        const n = self.tree.node(idx);
        if (std.meta.activeTag(n) == .block) {
            const has_tail = n.block.tail != null;
            self.emitExpr(idx);
            if (has_tail) {
                self.emitInst(.pop, self.line(idx));
                self.spSetIndex(self.code.items.len - 1, 1);
            }
        } else {
            self.emitStmt(idx);
        }
    }

    // ── Pattern emission ──────────────────────────────────────────

    fn emitPatternValue(self: *Emitter, pat: u32, ln: u32) void {
        switch (self.tree.node(pat)) {
            .int_literal, .float_literal, .string_literal, .bool_literal, .unary_expr => {
                self.emitExpr(pat);
            },
            .field_access => |fa| {
                const obj = self.tree.node(fa.object);
                const ei = if (std.meta.activeTag(obj) == .identifier)
                    self.findEnum(obj.identifier)
                else
                    null;
                if (ei == null) {
                    self.err(ln, "pattern must be a literal, `_` or Enum.Variant", .{});
                } else if (enumVariantIndex(ei.?, fa.field) == null) {
                    self.err(ln, "enum '{s}' has no variant '{s}'", .{ ei.?.name, fa.field });
                }
                const idx = self.addConstant(bc.vEnum(if (ei) |e| e.name else "", fa.field));
                self.emitInstIndex(.const_, idx, ln);
            },
            else => {
                self.err(ln, "unsupported pattern in match arm", .{});
                const z = self.addNil();
                self.emitInstIndex(.const_, z, ln);
            },
        }
    }

    /// Emit `target == pattern` tests; on success jump to the arm body. Patch
    /// sites are collected in `hits` for the caller to point at the body.
    fn emitPatternTests(self: *Emitter, pat: u32, slot: u8, ln: u32, hits: *std.ArrayListUnmanaged(usize)) void {
        switch (self.tree.node(pat)) {
            .pattern_or => |l| {
                for (self.tree.extraSlice(l)) |alt| {
                    self.emitPatternTests(alt, slot, ln, hits);
                }
                return;
            },
            .pattern_bind => {
                // Always matches; the caller binds then emits the body.
                self.emitInstOffset(.jump, 0, ln);
                self.patchPush(hits, self.code.items.len - 1);
                return;
            },
            .pattern_variant_bind => |vb| {
                const var_path = self.tree.node(vb.variant);
                if (std.meta.activeTag(var_path) != .field_access) {
                    self.err(ln, "pattern must be a literal, `_` or Enum.Variant", .{});
                    return;
                }
                const fa = var_path.field_access;
                const obj = self.tree.node(fa.object);
                const ei = if (std.meta.activeTag(obj) == .identifier)
                    self.findEnum(obj.identifier)
                else
                    null;
                if (ei == null) {
                    self.err(ln, "pattern must be a literal, `_` or Enum.Variant", .{});
                    return;
                }
                if (enumVariantIndex(ei.?, fa.field) == null) {
                    self.err(ln, "enum '{s}' has no variant '{s}'", .{ ei.?.name, fa.field });
                }
                const idx = self.addConstant(bc.vEnum(ei.?.name, fa.field));
                self.emitInstIndex(.get_local, slot, ln);
                self.emitInstIndex(.const_, idx, ln);
                self.emitInst(.eq, ln);
                self.emitInstOffset(.jump_if_true, 0, ln);
                self.patchPush(hits, self.code.items.len - 1);
                return;
            },
            .pattern_builtin_variant => |b| {
                const tag: u32 = switch (b.kind) {
                    .ok => 0,
                    .err => 1,
                    .some => 2,
                    .none => 3,
                };
                self.emitInstIndex(.get_local, slot, ln);
                self.emitInstIndex(.tag_is, tag, ln);
                self.emitInstOffset(.jump_if_true, 0, ln);
                self.patchPush(hits, self.code.items.len - 1);
                return;
            },
            else => {},
        }

        self.emitInstIndex(.get_local, slot, ln);
        self.emitPatternValue(pat, ln);
        self.emitInst(.eq, ln);
        self.emitInstOffset(.jump_if_true, 0, ln);
        self.patchPush(hits, self.code.items.len - 1);
    }

    // ── Stack-height assertions ───────────────────────────────────

    /// Height a node is required to leave behind when emitted as an expression.
    fn nodeValueEffect(self: *Emitter, idx: u32) i32 {
        return switch (self.tree.node(idx)) {
            .while_expr, .for_expr, .return_stmt, .break_stmt, .continue_stmt, .fn_decl, .struct_decl, .enum_decl, .trait_decl, .impl_decl, .const_decl, .var_decl, .use_decl, .import_decl, .from_decl, .import_item, .range_expr, .source_file => 0,
            .block => |b| if (b.tail != null) 1 else 0,
            else => 1,
        };
    }

    fn spCheck(self: *Emitter, idx: u32, before: i32, expected: i32, where: []const u8) void {
        const want = before + expected;
        if (self.sp == want) return;
        const n = self.tree.node(idx);
        self.err(self.line(idx), "internal: stack imbalance in {s} {s}: expected height {d}, emitter computed {d}", .{ where, @tagName(n), want, self.sp });
        self.sp = want;
    }

    // ── Statement / expression emitters ───────────────────────────

    fn emitAssignInto(self: *Emitter, place: u32, value: u32, ln: u32) void {
        switch (self.tree.node(place)) {
            .index_expr => |ix| {
                self.emitExpr(ix.index);
                self.emitExpr(value);
                self.emitInst(.set_index, ln);
            },
            .field_access => |fa| {
                const idx = self.addConstant(bc.vString(fa.field));
                self.emitExpr(value);
                self.emitInstIndex(.set_field, idx, ln);
            },
            else => {
                self.err(ln, "invalid assignment target", .{});
            },
        }
    }

    /// Emit a function or lambda body into a fresh code/constant pool, matching
    /// the seed's save/swap/restore. Slot 0 is reserved for the return value, so
    /// parameters start at slot 1. `caps` is the lambda's capture table (empty
    /// for named functions, which do not capture).
    fn emitFunctionBody(self: *Emitter, params: ast.List, body: u32, ln: u32, caps: []const Capture) *bc.FnObj {
        const fn_obj = self.a.create(bc.FnObj) catch @panic("OOM");
        fn_obj.* = .{ .code = &.{}, .constants = &.{} };

        const saved_code = self.code;
        const saved_consts = self.constants;
        const saved_local_count = self.local_count;
        const saved_scope_depth = self.scope_depth;
        const saved_sp = self.sp;
        const saved_rt = self.rt;
        const saved_capture_count = self.capture_count;
        var saved_locals: [MAX_LOCALS]Local = undefined;
        var i: usize = 0;
        while (i < saved_local_count) : (i += 1) saved_locals[i] = self.locals[i];
        var saved_captures: [MAX_LOCALS]Capture = undefined;
        i = 0;
        while (i < saved_capture_count) : (i += 1) saved_captures[i] = self.captures[i];

        self.code = .empty;
        self.constants = .empty;
        self.scope_depth = 1;
        self.local_count = 0;
        self.sp = 0;
        // Inside the body, free names resolve through this lambda's captures
        // (GET_CAPTURE), not the enclosing frame's.
        self.capture_count = caps.len;
        i = 0;
        while (i < caps.len) : (i += 1) self.captures[i] = caps[i];

        _ = self.addLocal("$ret");
        const plist = self.tree.extraSlice(params);
        for (plist) |p| _ = self.addLocal(self.tree.node(p).param.name);
        fn_obj.param_count = @truncate(plist.len);
        // The callee sits at slot 0 and the caller pushed the arguments
        // contiguously after it: the body starts with exactly local_count
        // cells on the frame (audit §4.7).
        self.rt = @intCast(self.local_count);

        // A block ending in a tail expression already left its value on the
        // stack: that is the Rust-style implicit tail return.
        const body_node = self.tree.node(body);
        const body_is_block = std.meta.activeTag(body_node) == .block;
        const implicit_return = body_is_block and body_node.block.tail != null;

        self.emitExpr(body);

        const last_op: ?OpCode = if (self.code.items.len > 0) self.code.items[self.code.items.len - 1].op else null;
        if (last_op == null or last_op.? != .ret) {
            if (!implicit_return) {
                const nil_idx = self.addNil();
                self.emitInstIndex(.const_, nil_idx, ln);
            }
            self.emitInst(.ret, ln);
        }

        // RET hands exactly one value back, so the frame must be empty here.
        if (self.sp != 0) {
            self.err(ln, "internal: function leaves {d} value(s) on the stack at return", .{self.sp});
        }

        fn_obj.local_count = @truncate(self.local_count);
        fn_obj.code = self.code.toOwnedSlice(self.a) catch @panic("OOM");
        fn_obj.constants = self.constants.toOwnedSlice(self.a) catch @panic("OOM");

        self.code = saved_code;
        self.constants = saved_consts;
        self.local_count = saved_local_count;
        self.scope_depth = saved_scope_depth;
        self.sp = saved_sp;
        self.rt = saved_rt;
        self.capture_count = saved_capture_count;
        i = 0;
        while (i < saved_local_count) : (i += 1) self.locals[i] = saved_locals[i];
        i = 0;
        while (i < saved_capture_count) : (i += 1) self.captures[i] = saved_captures[i];
        return fn_obj;
    }

    fn emitExpr(self: *Emitter, idx: u32) void {
        const sp_before = self.sp;
        const ln = self.tree.loc(idx).line;

        switch (self.tree.node(idx)) {
            .int_literal => |v| {
                const ci = self.addConstant(bc.vInt(v));
                self.emitInstIndex(.const_, ci, ln);
            },
            .float_literal => |v| {
                const ci = self.addConstant(bc.vFloat(v));
                self.emitInstIndex(.const_, ci, ln);
            },
            .string_literal => |s| {
                const ci = self.addConstant(bc.vString(s));
                self.emitInstIndex(.const_, ci, ln);
            },
            .bool_literal => |b| {
                const ci = self.addConstant(bc.vBool(b));
                self.emitInstIndex(.const_, ci, ln);
            },
            .nil_literal => {
                const ci = self.addNil();
                self.emitInstIndex(.const_, ci, ln);
            },
            .identifier => |name| {
                if (self.findLocal(name)) |slot| {
                    self.emitInstIndex(.get_local, @intCast(slot), ln);
                } else if (self.findCapture(name)) |cap| {
                    // Free variable of the enclosing lambda: read it out of
                    // the closure's env. Slot 0 of this frame still holds the
                    // callee, so GET_CAPTURE reaches it without a frame change.
                    self.emitInstIndex(.get_capture, @intCast(cap), ln);
                } else if (self.importFor(name)) |ref| {
                    const gname = if (ref.target.len > 0) ref.target else self.globalName(name);
                    const ci = self.addConstant(bc.vString(gname));
                    self.emitInstIndex(.get_global, ci, ln);
                } else {
                    // Phase 2.4 step 2b: inside an instance body a recorded
                    // callee ident names the mangled global of its target
                    // instance, not the source generic.
                    var gname = self.globalName(name);
                    if (self.current_instance) |inst| {
                        for (inst.rewrites) |rw| {
                            if (rw.callee == idx) {
                                gname = self.globalName(rw.name);
                                break;
                            }
                        }
                    }
                    const ci = self.addConstant(bc.vString(gname));
                    self.emitInstIndex(.get_global, ci, ln);
                }
            },
            .binary_expr => |b| {
                if (b.op == .and_and) {
                    // Short-circuit AND: each skip target is entered right after
                    // a JUMP_IF_FALSE popped its condition, so both rejoin at
                    // the same height.
                    const base = self.sp;
                    const rt0 = self.rt;
                    self.emitExpr(b.left);
                    self.emitInstOffset(.jump_if_false, 0, ln);
                    const patch_false = self.code.items.len - 1;
                    self.emitExpr(b.right);
                    self.emitInstOffset(.jump_if_false, 0, ln);
                    const patch_right_false = self.code.items.len - 1;
                    const true_idx = self.addConstant(bc.vBool(true));
                    self.emitInstIndex(.const_, true_idx, ln);
                    self.emitInstOffset(.jump, 0, ln);
                    const patch_end = self.code.items.len - 1;

                    self.code.items[patch_false].arg = .{ .offset = @intCast(self.code.items.len - patch_false) };
                    self.sp = base;
                    self.rt = rt0;
                    const false_idx = self.addConstant(bc.vBool(false));
                    self.emitInstIndex(.const_, false_idx, ln);
                    // Each branch target pushes its own constant: without this
                    // jump the first CONST falls through to the second and a
                    // CALL right after reads the wrong slot (the `&&` / `||`
                    // double-push bug, mirror of the seed emitter fix).
                    self.emitInstOffset(.jump, 0, ln);
                    const patch_first_end = self.code.items.len - 1;

                    self.code.items[patch_right_false].arg = .{ .offset = @intCast(self.code.items.len - patch_right_false) };
                    self.sp = base;
                    self.rt = rt0;
                    self.emitInstIndex(.const_, false_idx, ln);

                    self.code.items[patch_first_end].arg = .{ .offset = @intCast(self.code.items.len - patch_first_end) };
                    self.code.items[patch_end].arg = .{ .offset = @intCast(self.code.items.len - patch_end) };
                    self.sp = base + 1;
                    self.rt = rt0 + 1;
                } else if (b.op == .or_or) {
                    const base = self.sp;
                    const rt0 = self.rt;
                    self.emitExpr(b.left);
                    self.emitInstOffset(.jump_if_true, 0, ln);
                    const patch_true = self.code.items.len - 1;
                    self.emitExpr(b.right);
                    self.emitInstOffset(.jump_if_true, 0, ln);
                    const patch_right_true = self.code.items.len - 1;
                    const false_idx = self.addConstant(bc.vBool(false));
                    self.emitInstIndex(.const_, false_idx, ln);
                    self.emitInstOffset(.jump, 0, ln);
                    const patch_end = self.code.items.len - 1;

                    self.code.items[patch_true].arg = .{ .offset = @intCast(self.code.items.len - patch_true) };
                    self.sp = base;
                    self.rt = rt0;
                    const true_idx = self.addConstant(bc.vBool(true));
                    self.emitInstIndex(.const_, true_idx, ln);
                    // Same double-push guard as `&&`: the true path must skip
                    // the second CONST true or a CALL right after reads the
                    // wrong slot.
                    self.emitInstOffset(.jump, 0, ln);
                    const patch_first_end = self.code.items.len - 1;

                    self.code.items[patch_right_true].arg = .{ .offset = @intCast(self.code.items.len - patch_right_true) };
                    self.sp = base;
                    self.rt = rt0;
                    self.emitInstIndex(.const_, true_idx, ln);

                    self.code.items[patch_first_end].arg = .{ .offset = @intCast(self.code.items.len - patch_first_end) };
                    self.code.items[patch_end].arg = .{ .offset = @intCast(self.code.items.len - patch_end) };
                    self.sp = base + 1;
                    self.rt = rt0 + 1;
                } else {
                    self.emitExpr(b.left);
                    self.emitExpr(b.right);
                    const op: ?OpCode = switch (b.op) {
                        .plus => .add,
                        .minus => .sub,
                        .star => .mul,
                        .slash => .div,
                        .percent => .mod,
                        .eq_eq => .eq,
                        .neq => .neq,
                        .lt => .lt,
                        .gt => .gt,
                        .le => .le,
                        .ge => .ge,
                        .amp => .bit_and,
                        .pipe => .bit_or,
                        .caret => .bit_xor,
                        .shl => .shl,
                        .shr => .shr,
                        else => null,
                    };
                    if (op) |o| self.emitInst(o, ln);
                }
            },
            .unary_expr => |u| {
                self.emitExpr(u.operand);
                const op: ?OpCode = switch (u.op) {
                    .minus => .neg,
                    .bang => .not,
                    .tilde => .bit_not,
                    else => null,
                };
                if (op) |o| self.emitInst(o, ln);
            },
            .call_expr => |c| {
                const callee = self.tree.node(c.callee);
                // Static method dispatch (Phase 2.3 step 4): the checker
                // annotated the callee with its mangled global, so push that
                // function, then the receiver (argument 0), then the source
                // arguments — the frame layout the VM expects for methods.
                if (std.meta.activeTag(callee) == .field_access and callee.field_access.method.len > 0) {
                    const name_idx = self.addConstant(bc.vString(self.globalName(callee.field_access.method)));
                    self.emitInstIndex(.get_global, name_idx, ln);
                    self.emitExpr(callee.field_access.object);
                    for (self.tree.extraSlice(c.args)) |arg| self.emitExpr(arg);
                    self.emitInst(.call, ln);
                    self.spSetArgcount(self.code.items.len - 1, @truncate(self.tree.extraSlice(c.args).len + 1));
                    self.spCheck(idx, sp_before, self.nodeValueEffect(idx), "expression");
                    return;
                }
                // Qualified variant construction `Enum.Variant(args)` (DEC-008,
                // research/027 §4): the only spelling the checker accepts for
                // user variants — same bytecode the bare form used to emit.
                // Resolves both paths the checker accepts: `Enum.Variant`
                // (own or from-imported enum) and `alias.Enum.Variant`
                // through a module namespace.
                if (std.meta.activeTag(callee) == .field_access) {
                    const fa = callee.field_access;
                    const cobj = self.tree.node(fa.object);
                    const cen: ?*const EnumInfo = switch (cobj) {
                        .identifier => |nm| self.findEnum(nm),
                        .field_access => |inner| blk: {
                            const iobj = self.tree.node(inner.object);
                            if (std.meta.activeTag(iobj) == .identifier) {
                                if (self.importFor(iobj.identifier)) |iref| {
                                    if (iref.module_prefix.len > 0) {
                                        break :blk self.findNamespaceEnum(iref.module_prefix, inner.field);
                                    }
                                }
                            }
                            break :blk null;
                        },
                        else => null,
                    };
                    if (cen) |ei| {
                        if (enumVariantIndex(ei, fa.field)) |vi| {
                            const nf: usize = ei.field_counts[vi];
                            const args = self.tree.extraSlice(c.args);
                            if (args.len != nf) {
                                self.err(ln, "variant '{s}.{s}' expects {d} field(s), got {d}", .{ ei.name, fa.field, nf, args.len });
                            } else {
                                self.emitEnumConstruction(ei, vi, nf, args, ln);
                                self.spCheck(idx, sp_before, self.nodeValueEffect(idx), "expression");
                                return;
                            }
                        }
                    }
                }
                // A bare-identifier callee may name a data-carrying enum variant
                // (`Paso(x)`); mirror the checker's rule: variant, else call.
                // An imported name is never a local variant — skip the search
                // so `from dep import helper` cannot be shadowed by a variant
                // that happens to share the name.
                const callee_imported = std.meta.activeTag(callee) == .identifier and
                    self.importFor(callee.identifier) != null;
                if (std.meta.activeTag(callee) == .identifier and !callee_imported and !self.isKnownFn(callee.identifier)) {
                    const vname = callee.identifier;
                    if (self.findEnumByVariant(vname)) |ei| {
                        if (enumVariantIndex(ei, vname)) |vi| {
                            const nf: usize = ei.field_counts[vi];
                            const args = self.tree.extraSlice(c.args);
                            if (args.len != nf) {
                                self.err(ln, "variant '{s}.{s}' expects {d} field(s), got {d}", .{ ei.name, vname, nf, args.len });
                            } else {
                                self.emitEnumConstruction(ei, vi, nf, args, ln);
                                self.spCheck(idx, sp_before, self.nodeValueEffect(idx), "expression");
                                return;
                            }
                        }
                    }
                }
                self.emitExpr(c.callee);
                for (self.tree.extraSlice(c.args)) |arg| self.emitExpr(arg);
                self.emitInst(.call, ln);
                self.spSetArgcount(self.code.items.len - 1, @truncate(self.tree.extraSlice(c.args).len));
            },
            .array_literal => |l| {
                for (self.tree.extraSlice(l)) |e| self.emitExpr(e);
                self.emitInst(.new_array, ln);
                self.spSetIndex(self.code.items.len - 1, l.len);
            },
            .index_expr => |ix| {
                self.emitExpr(ix.object);
                self.emitExpr(ix.index);
                self.emitInst(.index, ln);
            },
            .struct_literal => |s| {
                const si = self.findStruct(s.name) orelse {
                    self.err(ln, "unknown struct '{s}'", .{s.name});
                    self.spCheck(idx, sp_before, self.nodeValueEffect(idx), "expression");
                    return;
                };
                const decl_fields = self.tree.extraSlice(s.fields);

                // Reject fields the struct does not declare.
                for (decl_fields) |f| {
                    const fname = self.tree.node(f).struct_init_field.name;
                    var found = false;
                    for (si.fields) |sf| {
                        if (std.mem.eql(u8, sf, fname)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        self.err(ln, "struct '{s}' has no field '{s}'", .{ s.name, fname });
                    }
                }

                // Values are pushed in declaration order, so the layout and the
                // stack always agree regardless of literal field order.
                const def_idx = self.addConstant(bc.vStructDef(si.def));
                self.emitInstIndex(.const_, def_idx, ln);
                for (si.fields) |sf| {
                    var vi: ?usize = null;
                    for (decl_fields, 0..) |f, j| {
                        if (std.mem.eql(u8, self.tree.node(f).struct_init_field.name, sf)) {
                            vi = j;
                            break;
                        }
                    }
                    if (vi) |j| {
                        self.emitExpr(self.tree.node(decl_fields[j]).struct_init_field.value);
                    } else {
                        self.err(ln, "missing field '{s}' in initializer of '{s}'", .{ sf, s.name });
                        const z = self.addNil();
                        self.emitInstIndex(.const_, z, ln);
                    }
                }
                self.emitInst(.new_struct, ln);
                self.spSetIndex(self.code.items.len - 1, @intCast(si.fields.len));
            },
            .field_access => |fa| {
                const obj = self.tree.node(fa.object);
                // `m.Enum.Variant` is a value, like the bare `Enum.Variant`
                // below — resolved against the exporting module's own
                // declarations here, because `m.Enum` is not a runtime global.
                if (std.meta.activeTag(obj) == .field_access) {
                    const inner = obj.field_access;
                    const iobj = self.tree.node(inner.object);
                    if (std.meta.activeTag(iobj) == .identifier) {
                        if (self.importFor(iobj.identifier)) |iref| {
                            if (iref.module_prefix.len > 0) {
                                if (self.findNamespaceEnum(iref.module_prefix, inner.field)) |ei| {
                                    if (enumVariantIndex(ei, fa.field) == null) {
                                        self.err(ln, "enum '{s}' has no variant '{s}'", .{ ei.name, fa.field });
                                    }
                                    const ci = self.addConstant(bc.vEnum(ei.name, fa.field));
                                    self.emitInstIndex(.const_, ci, ln);
                                    return;
                                }
                            }
                        }
                    }
                }
                // `alias.x` where `alias` is a module binding: a plain global
                // read of the exporting module's mangled name — or of the
                // owning module's, when `x` reaches it through a `use`.
                if (std.meta.activeTag(obj) == .identifier) {
                    if (self.importFor(obj.identifier)) |ref| {
                        if (ref.module_prefix.len > 0) {
                            for (ref.aliases) |al| {
                                if (std.mem.eql(u8, al.name, fa.field)) {
                                    const ci = self.addConstant(bc.vString(al.target));
                                    self.emitInstIndex(.get_global, ci, ln);
                                    return;
                                }
                            }
                            const gname = std.fmt.allocPrint(self.a, "{s}{s}", .{ ref.module_prefix, fa.field }) catch @panic("OOM");
                            const ci = self.addConstant(bc.vString(gname));
                            self.emitInstIndex(.get_global, ci, ln);
                            return;
                        }
                    }
                }
                // `Enum.Variant` is a value, not a field read.
                if (std.meta.activeTag(obj) == .identifier) {
                    if (self.findEnum(obj.identifier)) |ei| {
                        if (enumVariantIndex(ei, fa.field) == null) {
                            self.err(ln, "enum '{s}' has no variant '{s}'", .{ ei.name, fa.field });
                        }
                        const ci = self.addConstant(bc.vEnum(ei.name, fa.field));
                        self.emitInstIndex(.const_, ci, ln);
                        return;
                    }
                }
                // Everything else is a plain value read. A from-imported
                // constant reaches the exporting module's mangled global
                // through the binding table, so `ORIGIN.x` works across
                // modules; a struct *type* name reaches nothing and dies as
                // an undefined global at runtime — the same behaviour the
                // seed has for a single-file type-as-value.
                self.emitExpr(fa.object);
                const ci = self.addConstant(bc.vString(fa.field));
                self.emitInstIndex(.get_field, ci, ln);
            },
            .match_expr => |m| self.emitMatch(m, ln),
            .range_expr => {
                self.err(ln, "range expression is only valid as a for-loop iterator", .{});
            },
            .block => |b| {
                const saved_depth = self.scope_depth;
                self.scope_depth += 1;
                for (self.tree.extraSlice(b.stmts)) |s| self.emitStmt(s);
                if (b.tail) |t| self.emitExpr(t);
                self.popScope();
                self.scope_depth = saved_depth;
            },
            .if_expr => |i| {
                const base = self.sp;
                // Exact runtime height at entry (audit §4.7): branch `let`s
                // live in hidden locals just like the match's scrutinee, so
                // they need the same frontier treatment to stay clear of a
                // pending receiver.
                const rt0 = self.rt;
                const if_lc0 = self.local_count;
                self.padLocalsToRt(rt0);
                self.emitExpr(i.cond);
                self.emitInstOffset(.jump_if_false, 0, ln);
                const patch_false = self.code.items.len - 1;
                self.emitBranchValue(i.then_block, "if", ln);
                self.emitValueClose(rt0, ln);
                self.emitInstOffset(.jump, 0, ln);
                const patch_over = self.code.items.len - 1;
                self.code.items[patch_false].arg = .{ .offset = @intCast(self.code.items.len - patch_false) };
                // The else arm starts after JUMP_IF_FALSE popped the condition.
                self.sp = base;
                self.rt = rt0;
                if (i.else_block) |eb| {
                    self.emitBranchValue(eb, "else", ln);
                } else {
                    const z = self.addNil();
                    self.emitInstIndex(.const_, z, ln);
                }
                self.emitValueClose(rt0, ln);
                self.code.items[patch_over].arg = .{ .offset = @intCast(self.code.items.len - patch_over) };
                self.sp = base + 1;
                self.rt = rt0 + 1;
                // Reclaim the pad dummies; the branch locals were already
                // popped by their blocks.
                self.local_count = if_lc0;
            },
            .while_expr => |w| {
                const entry_rt = self.rt;
                const loop_start = self.code.items.len;
                const lp = self.loopEnter(self.tree.loc(idx));
                if (lp) |p| {
                    p.continue_target = loop_start;
                    p.head_rt = self.rt;
                    p.continue_rt = self.rt;
                }
                self.emitExpr(w.cond);
                self.emitInstOffset(.jump_if_false, 0, ln);
                const patch_exit = self.code.items.len - 1;
                self.emitLoopBody(w.body);
                self.emitBackEdgeReconcile(lp, ln);
                const back: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(self.code.items.len)));
                self.emitInstOffset(.jump, back, ln);
                const join = self.loopLeave(lp);
                // The natural exit skips the break reconcile stubs.
                self.code.items[patch_exit].arg = .{ .offset = @intCast(join - patch_exit) };
                // Every exit path (natural, break, zero iterations) lands here.
                self.emitLoopExitEnsure(entry_rt, ln);
            },
            .for_expr => |f| self.emitFor(f, self.tree.loc(idx)),
            .assignment => |asn| self.emitAssign(asn, ln),
            .return_stmt => |maybe| {
                if (maybe) |v| {
                    self.emitExpr(v);
                } else {
                    const ci = self.addNil();
                    self.emitInstIndex(.const_, ci, ln);
                }
                self.emitInst(.ret, ln);
            },
            .break_stmt => {
                if (self.loop_depth == 0) {
                    // file:line:col like every positioned route (audit §1.2).
                    self.errLoc(self.tree.loc(idx), "'break' used outside of a loop", .{});
                } else {
                    self.emitInstOffset(.jump, 0, ln);
                    const lp = &self.loops[self.loop_depth - 1];
                    // Stash this break's model height in the still-unused
                    // offset: loopLeave needs to know how far this path sits
                    // above the exit height, to drop any cells whose close
                    // the jump skips (audit §4.7).
                    self.code.items[self.code.items.len - 1].arg = .{ .offset = @intCast(self.rt) };
                    self.patchPush(&lp.breaks, self.code.items.len - 1);
                }
            },
            .continue_stmt => {
                if (self.loop_depth == 0) {
                    // file:line:col like every positioned route (audit §1.2).
                    self.errLoc(self.tree.loc(idx), "'continue' used outside of a loop", .{});
                } else {
                    self.emitInstOffset(.jump, 0, ln);
                    const lp = &self.loops[self.loop_depth - 1];
                    // Stash this continue's model height in the still-unused
                    // offset: loopLeave reconciles the path to the height the
                    // continue target runs at (audit §4.10), like break_stmt.
                    self.code.items[self.code.items.len - 1].arg = .{ .offset = @intCast(self.rt) };
                    self.patchPush(&lp.conts, self.code.items.len - 1);
                }
            },
            .some_expr => |v| {
                self.emitExpr(v);
                self.emitInst(.wrap_some, ln);
            },
            .none_expr => {
                const ci = self.addNil();
                self.emitInstIndex(.const_, ci, ln);
            },
            .ok_expr => |v| {
                self.emitExpr(v);
                self.emitInst(.wrap_ok, ln);
            },
            .err_expr => |v| {
                self.emitExpr(v);
                self.emitInst(.wrap_err, ln);
            },
            .try_expr => |v| {
                self.emitExpr(v);
                self.emitInst(.try_unwrap, ln);
            },
            .lambda_expr => |l| {
                // Free-variable analysis against the *enclosing* frame: the
                // names it yields become this lambda's env, pushed at the
                // creation site before CLOSURE clones the template around
                // them (capture-by-value, ARCHITECTURE.md §30.5).
                var fv = FreeVars{ .em = self };
                fv.pushScope();
                for (self.tree.extraSlice(l.params)) |p| {
                    fv.bind(self.tree.node(p).param.name);
                }
                fv.walk(l.body);
                fv.popScope();
                if (fv.overflow) {
                    self.err(ln, "too many captured variables (max 255)", .{});
                }

                // Push each captured value in env order. A name from the
                // enclosing function is a local slot; one the enclosing
                // lambda itself captured is read from *its* env — we are
                // still emitting the outer frame, so both resolve through
                // the outer frame's tables.
                for (0..fv.cap_count) |i| {
                    if (self.findLocal(fv.caps[i].name)) |slot| {
                        self.emitInstIndex(.get_local, @intCast(slot), ln);
                    } else if (self.findCapture(fv.caps[i].name)) |cap| {
                        self.emitInstIndex(.get_capture, @intCast(cap), ln);
                    } else {
                        // Analysis and emission must agree; a miss here would
                        // build an env with the wrong layout.
                        self.err(ln, "internal: capture '{s}' unresolved at creation site", .{fv.caps[i].name});
                        const z = self.addNil();
                        self.emitInstIndex(.const_, z, ln);
                    }
                }

                const fn_obj = self.emitFunctionBody(l.params, l.body, ln, fv.caps[0..fv.cap_count]);
                // The captured values are already on the stack (pushed above,
                // in the enclosing frame); CLOSURE pops them and pushes the
                // finished closure — the lambda expression's one value.
                const fn_idx = self.addConstant(bc.vFn(fn_obj));
                self.emitInstIndex(.closure, (fn_idx << 8) | @as(u32, @intCast(fv.cap_count)), ln);
            },
            else => {},
        }

        self.spCheck(idx, sp_before, self.nodeValueEffect(idx), "expression");
    }

    fn emitEnumConstruction(self: *Emitter, ei: *const EnumInfo, vi: usize, nf: usize, args: []const u32, ln: u32) void {
        // Pack the runtime layout shared by value_print/equality. The value
        // stack only ever sees the finished handle.
        const ed = self.a.create(bc.EnumDef) catch @panic("OOM");
        ed.name = ei.name;
        ed.variants = self.a.alloc(bc.VariantDef, ei.variants.len) catch @panic("OOM");
        for (ei.variants, 0..) |vname, v| {
            ed.variants[v] = .{
                .name = vname,
                .field_count = ei.field_counts[v],
                .field_names = ei.field_names[v],
            };
        }
        const def_idx = self.addConstant(bc.vEnumDef(ed));
        self.emitInstIndex(.const_, def_idx, ln);
        for (args) |arg| self.emitExpr(arg);
        self.emitInst(.new_enum, ln);
        self.code.items[self.code.items.len - 1].arg = .{ .index = (@as(u32, @intCast(vi)) << 16) | @as(u32, @intCast(nf)) };
        // emitInst applied stackEffect(new_enum, 0) = +1; the real effect is
        // -nf (pops nf+1, pushes 1), so correct by -(nf+1). The exact runtime
        // model needs the same correction (audit §4.7): a match after the
        // construction computes its frontier from rt.
        self.spAdvance(-@as(i32, @intCast(nf)) - 1);
        self.rt += -@as(i32, @intCast(nf)) - 1;
    }

    fn emitMatch(self: *Emitter, m: ast.MatchExpr, ln: u32) void {
        const arms = self.tree.extraSlice(m.arms);
        const base = self.sp;
        // Exact runtime height at entry (audit §4.7). Pending expression
        // values — a call's receiver — live above the local table, so the
        // declaration-count slots below cannot hold the scrutinee: the store
        // would overwrite the receiver.
        const rt0 = self.rt;

        // Snapshot the local table before the hidden local and the arm
        // bindings: the epilogue restores it wholesale. Retracting only the
        // last slot left every earlier binding name in the table, so a later
        // same-name reference resolved to the dead payload slot (audit §4.3,
        // mirror of the seed).
        const match_lc0 = self.local_count;

        // Pad past every live cell, then take the next slot: the hidden
        // local lands exactly on the frontier where the scrutinee is about
        // to be pushed, so SET_LOCAL stores it without moving it and without
        // touching the receiver (audit §4.7).
        self.padLocalsToRt(rt0);

        // The matched value lives in a hidden local; every arm tests against it.
        // addLocal already reports the limit; the 0xFF branch is recovery only.
        const slot = self.addLocal("$match_val");
        if (slot != 0xFF) {
            self.emitExpr(m.target);
            self.emitInstIndex(.set_local, slot, ln);
        }
        // Every arm is entered at this height: the store landed on the
        // frontier (slot == rt0), so it is net-zero on the frame.
        const rt_test = self.rt;

        var end_jumps: std.ArrayListUnmanaged(usize) = .empty;
        var has_wildcard = false;

        arms_loop: for (arms) |arm_idx| {
            const arm = self.tree.node(arm_idx).match_arm;
            const pat = arm.pattern;
            const body = arm.body;

            // A builtin/variant arm's guard-false stub — which pops the
            // extracted bindings so the next arm starts at arm-entry height
            // again — gets its final jump target at the end of this
            // iteration (audit §4.7/§4.11). The Zig port emits each arm
            // once (no duplicate plain copy), so the end of the iteration
            // IS the real next arm.
            var arm_stub_jump: usize = 0;

            // Each arm is entered after the previous arm's body jumped away,
            // so it starts at the height the scrutinee store left behind.
            self.sp = base;
            self.rt = rt_test;

            switch (self.tree.node(pat)) {
                .pattern_wildcard => {
                    if (arm.guard) |g| {
                        // A guarded wildcard is refutable (audit §4.8): only
                        // an unguarded one makes later arms unreachable and
                        // suppresses the MATCH_NONE backstop. Guard-false
                        // falls into the next arm's tests at arm-entry
                        // height — a wildcard extracts no bindings, so no
                        // stub is needed.
                        self.emitExpr(g);
                        self.emitInstOffset(.jump_if_false, 0, ln);
                        const guard_false = self.code.items.len - 1;
                        self.emitBranchValue(body, "match arm", ln);
                        self.emitValueClose(rt0, ln);
                        self.emitInstOffset(.jump, 0, ln);
                        self.patchPush(&end_jumps, self.code.items.len - 1);
                        self.code.items[guard_false].arg = .{ .offset = @intCast(self.code.items.len - guard_false) };
                        continue :arms_loop; // tests nothing: no plain copy either
                    }
                    has_wildcard = true;
                    self.emitBranchValue(body, "match arm", ln);
                    self.emitValueClose(rt0, ln);
                    self.emitInstOffset(.jump, 0, ln);
                    self.patchPush(&end_jumps, self.code.items.len - 1);
                    break :arms_loop; // an unguarded wildcard makes later arms unreachable
                },
                .pattern_bind => |name| {
                    const bind_slot = self.addLocal(name);
                    if (bind_slot == 0xFF) break :arms_loop;
                    self.emitInstIndex(.get_local, slot, ln);
                    self.emitInstIndex(.set_local, bind_slot, ln);
                    const bind_rt = self.rt;
                    if (arm.guard) |g| {
                        // A guarded binding is refutable (audit §4.8): the
                        // guard-false edge drops the extracted binding and
                        // falls into the next arm's tests at arm-entry
                        // height — the same reconcile the variant arms do
                        // for their payload bindings (audit §4.7). The drop
                        // covers a stale pad cell too, when a previous arm's
                        // slots pushed local_count past the frontier (audit
                        // §4.11).
                        self.emitExpr(g);
                        self.emitInstOffset(.jump_if_false, 0, ln);
                        const guard_false = self.code.items.len - 1;
                        self.emitBranchValue(body, "match arm", ln);
                        self.emitValueClose(rt0, ln);
                        self.emitInstOffset(.jump, 0, ln);
                        self.patchPush(&end_jumps, self.code.items.len - 1);
                        self.code.items[guard_false].arg = .{ .offset = @intCast(self.code.items.len - guard_false) };
                        const drop: usize = @intCast(bind_rt - rt_test);
                        self.emitInstIndex(.pop, @intCast(drop), ln);
                        self.spSetIndex(self.code.items.len - 1, @intCast(drop));
                        continue :arms_loop; // the binding slot reclaims with the match table
                    }
                    self.emitBranchValue(body, "match arm", ln);
                    self.emitValueClose(rt0, ln);
                    self.emitInstOffset(.jump, 0, ln);
                    self.patchPush(&end_jumps, self.code.items.len - 1);
                    break :arms_loop; // an unguarded binding makes later arms unreachable
                },
                .pattern_variant_bind => |vb| {
                    var hits: std.ArrayListUnmanaged(usize) = .empty;
                    self.emitPatternTests(pat, slot, ln, &hits);
                    self.emitInstOffset(.jump, 0, ln);
                    const no_match = self.code.items.len - 1;
                    const body_start = self.code.items.len;
                    for (hits.items) |h| {
                        self.code.items[h].arg = .{ .offset = @intCast(body_start - h) };
                    }

                    // Extract payload fields into binding locals. Re-fetch the
                    // enum from the match local per field: SET_LOCAL writes a
                    // fixed stack slot, which can overwrite the enum data.
                    const bind_count = self.tree.extraSlice(vb.bindings).len;
                    for (self.tree.extraSlice(vb.bindings), 0..) |b, k| {
                        self.emitInstIndex(.get_local, slot, ln);
                        self.emitInstIndex(.get_enum_field, @intCast(k), ln);
                        const bind_slot = self.addLocal(self.tree.node(b).pattern_bind);
                        if (bind_slot == 0xFF) break;
                        self.emitInstIndex(.set_local, bind_slot, ln);
                    }
                    const bind_rt = self.rt;

                    var guard_false_jump: ?usize = null;
                    if (arm.guard) |g| {
                        self.emitExpr(g);
                        self.emitInstOffset(.jump_if_false, 0, ln);
                        guard_false_jump = self.code.items.len - 1;
                    }
                    self.emitBranchValue(body, "match arm", ln);
                    self.emitValueClose(rt0, ln);
                    self.emitInstOffset(.jump, 0, ln);
                    self.patchPush(&end_jumps, self.code.items.len - 1);

                    // A failed guard jumps from *after* the bindings were
                    // extracted: drop them on that edge, so the next arm's
                    // tests start at arm-entry height again (audit §4.7). The
                    // edge's final target is patched at the end of this
                    // iteration. The drop is everything the extraction put
                    // above rt_test, not just bind_count: when a previous
                    // arm's slots pushed local_count past the frontier, each
                    // binding lands one cell higher and SET_LOCAL pads a
                    // stale cell below it (audit §4.11).
                    var guard_stub: usize = 0;
                    const has_stub = arm.guard != null and bind_count > 0;
                    if (has_stub) {
                        const drop: usize = @intCast(bind_rt - rt_test);
                        guard_stub = self.code.items.len;
                        self.emitInstIndex(.pop, @intCast(drop), ln);
                        self.spSetIndex(self.code.items.len - 1, @intCast(drop));
                        self.emitInstOffset(.jump, 0, ln);
                        arm_stub_jump = self.code.items.len - 1;
                    }

                    const next_arm = self.code.items.len;
                    self.code.items[no_match].arg = .{ .offset = @intCast(next_arm - no_match) };
                    if (guard_false_jump) |gf| {
                        if (has_stub) {
                            self.code.items[gf].arg = .{ .offset = @intCast(guard_stub - gf) };
                        } else {
                            self.code.items[gf].arg = .{ .offset = @intCast(next_arm - gf) };
                        }
                    }

                    // Re-target the guard-false *stub* onto the real next
                    // arm: this iteration ends here. Only the stub's own
                    // JUMP gets this final target — the guard-false edge
                    // must keep pointing at the stub, or it skips the POP
                    // and the extracted binding cells stay live under the
                    // next arm. Re-patching the JIF itself (the old
                    // arm_gf_patch) did exactly that: the §4.7 stub was
                    // dead code whenever the binding carried a payload
                    // (audit §4.11, mirror of the seed).
                    if (arm_stub_jump != 0) {
                        self.code.items[arm_stub_jump].arg = .{ .offset = @intCast(self.code.items.len - arm_stub_jump) };
                    }
                    continue :arms_loop;
                },
                .pattern_builtin_variant => |b| {
                    var hits: std.ArrayListUnmanaged(usize) = .empty;
                    self.emitPatternTests(pat, slot, ln, &hits);
                    self.emitInstOffset(.jump, 0, ln);
                    const no_match = self.code.items.len - 1;
                    const body_start = self.code.items.len;
                    for (hits.items) |h| {
                        self.code.items[h].arg = .{ .offset = @intCast(body_start - h) };
                    }

                    if (b.payload) |payload| {
                        switch (self.tree.node(payload)) {
                            .pattern_bind => |name| {
                                self.emitInstIndex(.get_local, slot, ln);
                                self.emitInst(.unwrap, ln);
                                const bind_slot = self.addLocal(name);
                                if (bind_slot != 0xFF) {
                                    self.emitInstIndex(.set_local, bind_slot, ln);
                                }
                            },
                            .pattern_wildcard => {
                                self.emitInstIndex(.get_local, slot, ln);
                                self.emitInst(.unwrap, ln);
                                self.emitInst(.pop, ln);
                            },
                            else => {},
                        }
                    }
                    const bind_rt = self.rt;

                    var guard_false_jump: ?usize = null;
                    if (arm.guard) |g| {
                        self.emitExpr(g);
                        self.emitInstOffset(.jump_if_false, 0, ln);
                        guard_false_jump = self.code.items.len - 1;
                    }
                    self.emitBranchValue(body, "match arm", ln);
                    self.emitValueClose(rt0, ln);
                    self.emitInstOffset(.jump, 0, ln);
                    self.patchPush(&end_jumps, self.code.items.len - 1);

                    // A failed guard jumps from *after* the payload was
                    // extracted into its binding local: drop that cell on the
                    // edge so the next arm's tests start at arm-entry height
                    // again (audit §4.7). The edge's final target is patched
                    // at the end of this iteration. Same drop formula as the
                    // variant path — everything the extraction put above
                    // rt_test (audit §4.11).
                    var guard_stub: usize = 0;
                    const has_stub = arm.guard != null and
                        if (b.payload) |payload| std.meta.activeTag(self.tree.node(payload)) == .pattern_bind else false;
                    if (has_stub) {
                        const drop: usize = @intCast(bind_rt - rt_test);
                        guard_stub = self.code.items.len;
                        self.emitInstIndex(.pop, @intCast(drop), ln);
                        self.spSetIndex(self.code.items.len - 1, @intCast(drop));
                        self.emitInstOffset(.jump, 0, ln);
                        arm_stub_jump = self.code.items.len - 1;
                    }

                    const next_arm = self.code.items.len;
                    self.code.items[no_match].arg = .{ .offset = @intCast(next_arm - no_match) };
                    if (guard_false_jump) |gf| {
                        if (has_stub) {
                            self.code.items[gf].arg = .{ .offset = @intCast(guard_stub - gf) };
                        } else {
                            self.code.items[gf].arg = .{ .offset = @intCast(next_arm - gf) };
                        }
                    }

                    // Re-target the guard-false *stub* onto the real next
                    // arm: this iteration ends here. Only the stub's own
                    // JUMP gets this final target — the guard-false edge
                    // must keep pointing at the stub, or it skips the POP
                    // and the extracted binding cells stay live under the
                    // next arm. Re-patching the JIF itself (the old
                    // arm_gf_patch) did exactly that: the §4.7 stub was
                    // dead code whenever the binding carried a payload
                    // (audit §4.11, mirror of the seed).
                    if (arm_stub_jump != 0) {
                        self.code.items[arm_stub_jump].arg = .{ .offset = @intCast(self.code.items.len - arm_stub_jump) };
                    }
                    continue :arms_loop;
                },
                else => {},
            }

            // Generic arm: literal / enum / or patterns.
            var hits: std.ArrayListUnmanaged(usize) = .empty;
            self.emitPatternTests(pat, slot, ln, &hits);
            self.emitInstOffset(.jump, 0, ln);
            const no_match = self.code.items.len - 1;
            const body_start = self.code.items.len;
            for (hits.items) |h| {
                self.code.items[h].arg = .{ .offset = @intCast(body_start - h) };
            }

            var guard_false_jump: ?usize = null;
            if (arm.guard) |g| {
                self.emitExpr(g);
                self.emitInstOffset(.jump_if_false, 0, ln);
                guard_false_jump = self.code.items.len - 1;
            }
            self.emitBranchValue(body, "match arm", ln);
            self.emitValueClose(rt0, ln);
            self.emitInstOffset(.jump, 0, ln);
            self.patchPush(&end_jumps, self.code.items.len - 1);

            // A failed guard falls into the next arm's tests from
            // arm-entry height: a plain pattern extracts no bindings, so no
            // stub is needed on this edge (audit §4.7).
            const next_arm = self.code.items.len;
            self.code.items[no_match].arg = .{ .offset = @intCast(next_arm - no_match) };
            if (guard_false_jump) |gf| {
                self.code.items[gf].arg = .{ .offset = @intCast(next_arm - gf) };
            }
        }

        if (!has_wildcard) {
            // No arm matched: trap instead of yielding a lying nil
            // (audit §3.8 backstop, mirror of the seed). The instruction
            // models the push it never delivers; control never reaches past
            // the trap.
            self.sp = base;
            self.rt = rt0;
            self.emitInst(.match_none, ln);
        }

        const end_target = self.code.items.len;
        for (end_jumps.items) |j| {
            self.code.items[j].arg = .{ .offset = @intCast(end_target - j) };
        }

        // Reclaim the hidden local AND the arm bindings by restoring the
        // whole table snapshot (no POP: the result sits on top) — audit §4.3.
        self.local_count = match_lc0;
        self.sp = base + 1;
        // Every arm path closed itself to the entry frontier: the match
        // leaves exactly one cell — its result — above where it started.
        self.rt = rt0 + 1;
    }

    fn emitFor(self: *Emitter, f: ast.ForExpr, loc: lexer.Loc) void {
        const ln = loc.line;
        const entry_rt = self.rt;
        const saved_depth = self.scope_depth;
        self.scope_depth += 1;

        const slot_idx = self.addLocal("$for_i");
        var loop_start: usize = 0;
        var patch_exit: usize = 0;
        var lp: ?*LoopPatch = null;
        var var_slot: u8 = 0xFF;

        const iter = self.tree.node(f.iter);
        if (std.meta.activeTag(iter) == .range_expr) {
            const r = iter.range_expr;
            const slot_end = self.addLocal("$for_end");
            if (r.start_node) |s| {
                self.emitExpr(s);
            } else {
                const z = self.addConstant(bc.vInt(0));
                self.emitInstIndex(.const_, z, ln);
            }
            self.emitInstIndex(.set_local, slot_idx, ln);

            if (r.end_node) |e| {
                self.emitExpr(e);
            } else {
                self.err(ln, "open-ended range is not supported in Astra-0", .{});
                const z = self.addConstant(bc.vInt(0));
                self.emitInstIndex(.const_, z, ln);
            }
            self.emitInstIndex(.set_local, slot_end, ln);

            loop_start = self.code.items.len;
            lp = self.loopEnter(loc);
            if (lp) |p| p.head_rt = self.rt;
            self.emitInstIndex(.get_local, slot_idx, ln);
            self.emitInstIndex(.get_local, slot_end, ln);
            self.emitInst(if (r.inclusive) .le else .lt, ln);
            self.emitInstOffset(.jump_if_false, 0, ln);
            patch_exit = self.code.items.len - 1;

            var_slot = self.addLocal(f.var_name);
            self.emitInstIndex(.get_local, slot_idx, ln);
            self.emitInstIndex(.set_local, var_slot, ln);
            self.emitLoopBody(f.body);
            if (lp) |p| {
                p.continue_target = self.code.items.len;
                p.continue_rt = self.rt;
            }
            self.emitInstIndex(.get_local, slot_idx, ln);
            const one = self.addConstant(bc.vInt(1));
            self.emitInstIndex(.const_, one, ln);
            self.emitInst(.add, ln);
            self.emitInstIndex(.set_local, slot_idx, ln);
        } else {
            const slot_arr = self.addLocal("$for_arr");
            self.emitExpr(f.iter);
            self.emitInstIndex(.set_local, slot_arr, ln);
            const z = self.addConstant(bc.vInt(0));
            self.emitInstIndex(.const_, z, ln);
            self.emitInstIndex(.set_local, slot_idx, ln);

            loop_start = self.code.items.len;
            lp = self.loopEnter(loc);
            if (lp) |p| p.head_rt = self.rt;
            self.emitInstIndex(.get_local, slot_idx, ln);
            self.emitInstIndex(.get_local, slot_arr, ln);
            self.emitInst(.len, ln);
            self.emitInst(.lt, ln);
            self.emitInstOffset(.jump_if_false, 0, ln);
            patch_exit = self.code.items.len - 1;

            var_slot = self.addLocal(f.var_name);
            self.emitInstIndex(.get_local, slot_arr, ln);
            self.emitInstIndex(.get_local, slot_idx, ln);
            self.emitInst(.index, ln);
            self.emitInstIndex(.set_local, var_slot, ln);
            self.emitLoopBody(f.body);
            if (lp) |p| {
                p.continue_target = self.code.items.len;
                p.continue_rt = self.rt;
            }
            self.emitInstIndex(.get_local, slot_idx, ln);
            const one = self.addConstant(bc.vInt(1));
            self.emitInstIndex(.const_, one, ln);
            self.emitInst(.add, ln);
            self.emitInstIndex(.set_local, slot_idx, ln);
        }

        self.emitBackEdgeReconcile(lp, ln);
        const back: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(self.code.items.len)));
        self.emitInstOffset(.jump, back, ln);
        const join = self.loopLeave(lp);
        // The natural exit skips the break reconcile stubs.
        self.code.items[patch_exit].arg = .{ .offset = @intCast(join - patch_exit) };
        // Every exit path (natural, break, zero iterations) lands here.
        self.emitLoopExitEnsure(entry_rt, ln);

        self.popScope();
        self.scope_depth = saved_depth;
    }

    fn emitAssign(self: *Emitter, asn: ast.Assign, ln: u32) void {
        const target = self.tree.node(asn.target);
        switch (target) {
            .identifier => |name| {
                self.emitExpr(asn.value);
                if (self.findLocal(name)) |slot| {
                    self.emitInstIndex(.set_local, @intCast(slot), ln);
                    self.emitInstIndex(.get_local, @intCast(slot), ln);
                } else if (self.findCapture(name) != null) {
                    // Closures capture by value (ARCHITECTURE.md §30.5): there
                    // is no cell to store into, and writing only the local
                    // copy would silently diverge from the enclosing frame.
                    // Refuse at compile time instead.
                    self.err(ln, "cannot assign to captured variable '{s}' (closures capture by value)", .{name});
                } else {
                    const ci = self.addConstant(bc.vString(self.globalName(name)));
                    self.emitInstIndex(.set_global, ci, ln);
                    self.emitInstIndex(.get_global, ci, ln);
                }
            },
            .index_expr, .field_access => {
                // The chain may be deeper than one link (`xs[i].f = v`): emit
                // the read of everything above the last link, then the store.
                const inner = switch (target) {
                    .index_expr => |ix| ix.object,
                    .field_access => |fa| fa.object,
                    else => unreachable,
                };
                self.emitExpr(inner);
                self.emitAssignInto(asn.target, asn.value, ln);
            },
            else => {
                self.err(ln, "invalid assignment target", .{});
            },
        }
    }

    fn emitStmt(self: *Emitter, idx: u32) void {
        const sp_before = self.sp;
        const ln = self.tree.loc(idx).line;

        switch (self.tree.node(idx)) {
            .fn_decl => |f| {
                // A generic source declaration never reaches codegen: every
                // call targets a materialized instance wrapper instead
                // (Phase 2.4 step 2b), so the shared body is emitted once
                // per instance and once here would only register an unused
                // global.
                if (f.generics.len > 0) return;
                // Phase 2.4 step 2b: while emitting an instance wrapper's
                // body the recorded callee idents resolve to the mangled
                // globals — the same body node is emitted once per instance
                // with a different name at each shared call site.
                const saved_inst = self.current_instance;
                for (self.instances) |*inst| {
                    if (inst.wrapper == idx) {
                        self.current_instance = inst;
                        break;
                    }
                }
                // Named functions do not capture: their bodies keep resolving
                // free names as globals (the callee has no env).
                const fn_obj = self.emitFunctionBody(f.params, f.body, ln, &.{});
                self.current_instance = saved_inst;
                const fn_idx = self.addConstant(bc.vFn(fn_obj));
                const name_idx = self.addConstant(bc.vString(self.globalName(f.name)));
                if (self.scope_depth == 0) {
                    self.emitInstIndex(.const_, fn_idx, ln);
                    self.emitInstIndex(.set_global, name_idx, ln);
                } else {
                    const slot = self.addLocal(f.name);
                    self.emitInstIndex(.const_, fn_idx, ln);
                    if (slot != 0xFF) {
                        self.emitInstIndex(.set_local, slot, ln);
                    } else {
                        self.emitInstIndex(.set_global, name_idx, ln);
                    }
                }
            },
            .var_decl, .const_decl => {
                const v = switch (self.tree.node(idx)) {
                    .var_decl => |v| v,
                    .const_decl => |v| v,
                    else => unreachable,
                };
                if (v.value) |val| {
                    self.emitExpr(val);
                } else {
                    const ci = self.addNil();
                    self.emitInstIndex(.const_, ci, ln);
                }
                if (self.scope_depth == 0) {
                    const name_idx = self.addConstant(bc.vString(self.globalName(v.name)));
                    self.emitInstIndex(.set_global, name_idx, ln);
                } else {
                    const slot = self.addLocal(v.name);
                    if (slot == 0xFF) {
                        const name_idx = self.addConstant(bc.vString(self.globalName(v.name)));
                        self.emitInstIndex(.set_global, name_idx, ln);
                    } else {
                        self.emitInstIndex(.set_local, slot, ln);
                    }
                }
            },
            // An impl block is pure declaration: emit its methods (Phase 2.3
            // step 4), which are fn_decls at scope 0 with mangled names.
            .impl_decl => |im| {
                if (im.generics.len > 0) return; // inert (Phase 2.4 step 1)
                for (self.tree.extraSlice(im.items)) |item| self.emitStmt(item);
            },
            .struct_decl, .enum_decl, .trait_decl, .use_decl, .import_decl, .from_decl, .import_item => {},
            .source_file => |list| {
                for (self.tree.extraSlice(list)) |item| self.emitStmt(item);
            },
            .block => |b| {
                const has_tail = b.tail != null;
                self.emitExpr(idx);
                if (has_tail) {
                    self.emitInst(.pop, ln);
                    self.spSetIndex(self.code.items.len - 1, 1);
                }
            },
            .while_expr, .for_expr, .return_stmt, .break_stmt, .continue_stmt => {
                self.emitExpr(idx);
            },
            .expr_stmt => |inner| {
                self.emitExpr(inner);
                if (self.nodeValueEffect(inner) != 0) {
                    self.emitInst(.pop, ln);
                    self.spSetIndex(self.code.items.len - 1, 1);
                }
            },
            else => {
                self.emitExpr(idx);
                if (self.nodeValueEffect(idx) != 0) {
                    self.emitInst(.pop, ln);
                    self.spSetIndex(self.code.items.len - 1, 1);
                }
            },
        }

        self.spCheck(idx, sp_before, 0, "statement");
    }

    /// Public API: emit a whole module. `module` is the `source_file` root.
    /// Emit a dependency module: its type registrations and module-level
    /// code, ending in `halt` but WITHOUT the call to `main` — only the root
    /// module gets one (the multi-module driver runs modules in graph order
    /// and calls the root's `main` last).
    pub fn emitModule(self: *Emitter, module: u32) void {
        self.collectModuleGlobals(module);
        self.registerTypes(module);
        self.emitStmt(module);
        self.emitInst(.halt, 0);
    }

    /// Emit a whole module and, if it defines main(), call it. `module` is the
    /// `source_file` root. Single-file form: the prefix is empty and globals
    /// keep their source names.
    pub fn emit(self: *Emitter, module: u32) void {
        self.collectModuleGlobals(module);
        self.registerTypes(module);
        self.emitStmt(module);

        // If the module defines main(), call it; top-level functions live in the
        // globals table, so a name lookup is enough.
        for (self.tree.extraSlice(self.tree.node(module).source_file)) |item| {
            const it = self.tree.node(item);
            if (std.meta.activeTag(it) == .fn_decl and
                it.fn_decl.generics.len == 0 and
                std.mem.eql(u8, it.fn_decl.name, "main"))
            {
                const name_idx = self.addConstant(bc.vString(self.globalName("main")));
                self.emitInstIndex(.get_global, name_idx, self.tree.loc(item).line);
                self.emitInst(.call, self.tree.loc(item).line);
                self.code.items[self.code.items.len - 1].arg = .{ .arg_count = 0 };
                break;
            }
        }

        self.emitInst(.halt, 0);
    }
};

// ── Foreign declarations ─────────────────────────────────────────

/// The struct/enum registries of one emitted module, as seen by its importers.
pub const ModuleTypes = struct {
    structs: []const StructInfo = &.{},
    enums: []const EnumInfo = &.{},
};

/// One `import` binding: the exporting module's registries under its
/// mangled prefix, for namespace-qualified paths (`m.Enum.Variant`).
pub const NamespaceTypes = struct {
    prefix: []const u8,
    types: ModuleTypes,
};

/// What this module's declarations bring in: the flat lists for `from`
/// bindings (they name types directly) and the prefix-keyed tables for
/// `import` bindings (they name types through the namespace).
pub const Foreign = struct {
    structs: []const StructInfo = &.{},
    enums: []const EnumInfo = &.{},
    namespaces: []const NamespaceTypes = &.{},
};

/// Assembled by the driver after each dependency has emitted (post-order:
/// `own[i]` is only read for i below the current module). `use` re-exports
/// are the driver's to forward (PHASE2 §7), not collected here.
pub fn collectForeign(
    a: std.mem.Allocator,
    graph: *const modules.Graph,
    decls: []const modules.Decl,
    own: []const ModuleTypes,
    mangled: []const []const u8,
) !Foreign {
    var structs: std.ArrayListUnmanaged(StructInfo) = .empty;
    var enums: std.ArrayListUnmanaged(EnumInfo) = .empty;
    var namespaces: std.ArrayListUnmanaged(NamespaceTypes) = .empty;
    errdefer structs.deinit(a);
    errdefer enums.deinit(a);
    errdefer namespaces.deinit(a);
    for (decls) |decl| {
        if (decl.kind == .use) continue;
        const dep_i = graph.find(decl.file) orelse continue;
        if (dep_i >= own.len) continue;
        const dep = own[dep_i];
        switch (decl.kind) {
            .from => for (decl.items) |item| {
                const bound = modules.itemBindingName(item);
                for (dep.structs) |si| {
                    if (!std.mem.eql(u8, si.name, item.name)) continue;
                    var cp = si;
                    if (!std.mem.eql(u8, bound, item.name)) cp.name = bound;
                    try structs.append(a, cp);
                }
                for (dep.enums) |ei| {
                    if (!std.mem.eql(u8, ei.name, item.name)) continue;
                    var cp = ei;
                    if (!std.mem.eql(u8, bound, item.name)) cp.name = bound;
                    try enums.append(a, cp);
                }
            },
            .import => try namespaces.append(a, .{ .prefix = mangled[dep_i], .types = dep }),
            else => {}, // `.use`: re-exports, forwarded by the driver.
        }
    }
    return .{ .structs = structs.items, .enums = enums.items, .namespaces = namespaces.items };
}

/// Register what a module's importers may resolve through it: its own
/// registries (already merged with its `from`/`import` types) plus what its
/// `use` declarations forward — the deps' lists are complete by then
/// (post-order). Call right after the module emits.
pub fn captureOwnTypes(
    a: std.mem.Allocator,
    graph: *const modules.Graph,
    decls: []const modules.Decl,
    mem: *const Emitter,
    own_types: []ModuleTypes,
    i: usize,
) !void {
    var structs: std.ArrayListUnmanaged(StructInfo) = .empty;
    var enums: std.ArrayListUnmanaged(EnumInfo) = .empty;
    try structs.appendSlice(a, mem.structs.items);
    try enums.appendSlice(a, mem.enums.items);
    for (decls) |decl| {
        if (decl.kind != .use) continue;
        const d = graph.find(decl.file) orelse continue;
        if (d >= own_types.len) continue;
        try structs.appendSlice(a, own_types[d].structs);
        try enums.appendSlice(a, own_types[d].enums);
    }
    own_types[i] = .{ .structs = structs.items, .enums = enums.items };
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const parser = @import("../parser/parser.zig");

fn emitSource(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var tree = ast.Tree.init(a, source);
    var p = parser.Parser.init(a, source, &tree);
    const root = p.parse() catch return error.ParseFailed;
    var e = Emitter.init(a, &tree, "test.astra");
    e.emit(root);
    try testing.expectEqual(@as(usize, 0), e.error_count);
    return std.fmt.allocPrint(a, "{any}", .{e.code.items.len});
}

test "emits a trivial program" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try emitSource(arena.allocator(),
        \\fn main() {
        \\    print(1 + 2);
        \\}
    );
}

test "emits loops, match and enum construction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try emitSource(arena.allocator(),
        \\enum Item {
        \\    First(i32)
        \\    Third
        \\}
        \\
        \\fn main() {
        \\    let items = [Item.First(1), Item.Third];
        \\    for item in items {
        \\        match item {
        \\            Item.First(x) => print(x),
        \\            Item.Third => print("third"),
        \\        }
        \\    }
        \\}
    );
}

test "rejects break outside a loop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\fn main() {
        \\    break;
        \\}
    ;
    var tree = ast.Tree.init(arena.allocator(), source);
    var p = parser.Parser.init(arena.allocator(), source, &tree);
    const root = try p.parse();
    var e = Emitter.init(arena.allocator(), &tree, "test.astra");
    e.emit(root);
    try testing.expect(e.error_count > 0);
}
