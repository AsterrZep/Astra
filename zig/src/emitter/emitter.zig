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

/// Compile-time view of a struct declaration.
const StructInfo = struct {
    name: []const u8,
    fields: []const []const u8,
    def: *bc.StructDef,
};

/// Compile-time view of an enum declaration. `field_names[v]` is parallel to
/// the variant's payload; an unnamed field keeps an empty name.
const EnumInfo = struct {
    name: []const u8,
    variants: []const []const u8,
    field_names: []const []const []const u8,
    field_counts: []const u32,
};

const VariantEntry = struct { variant: []const u8, enum_idx: usize };
const FnName = struct { name: []const u8 };

/// Pending jump sites for the enclosing loop, patched once the exit / continue
/// targets are known.
const LoopPatch = struct {
    breaks: std.ArrayListUnmanaged(usize) = .empty,
    conts: std.ArrayListUnmanaged(usize) = .empty,
    continue_target: usize = 0,
};

pub const Emitter = struct {
    a: std.mem.Allocator,
    tree: *ast.Tree,
    filename: []const u8,

    code: std.ArrayListUnmanaged(Instruction) = .empty,
    constants: std.ArrayListUnmanaged(Value) = .empty,

    locals: [MAX_LOCALS]Local = undefined,
    local_count: usize = 0,
    scope_depth: u8 = 0,

    loops: [MAX_LOOP_DEPTH]LoopPatch = undefined,
    loop_depth: usize = 0,

    structs: std.ArrayListUnmanaged(StructInfo) = .empty,
    enums: std.ArrayListUnmanaged(EnumInfo) = .empty,
    variant_index: std.ArrayListUnmanaged(VariantEntry) = .empty,
    fns: std.ArrayListUnmanaged(FnName) = .empty,

    sp: i32 = 0,
    sp_high: i32 = 0,

    error_count: usize = 0,

    pub fn init(a: std.mem.Allocator, tree: *ast.Tree, filename: []const u8) Emitter {
        return .{ .a = a, .tree = tree, .filename = filename };
    }

    fn err(self: *Emitter, comptime fmt: []const u8, args: anytype) void {
        self.error_count += 1;
        std.debug.print(fmt, args);
    }

    fn line(self: *const Emitter, idx: u32) u32 {
        return self.tree.loc(idx).line;
    }

    // ── Stack-height model ────────────────────────────────────────

    fn spAdvance(self: *Emitter, delta: i32) void {
        self.sp += delta;
        if (self.sp > self.sp_high) self.sp_high = self.sp;
    }

    fn emitInst(self: *Emitter, op: OpCode, ln: u32) void {
        if (self.code.items.len >= MAX_CODE) return;
        self.code.append(self.a, .{ .op = op, .line = ln }) catch @panic("OOM");
        self.spAdvance(op.stackEffect(0));
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
        if (self.constants.items.len >= MAX_CONSTS) return 0;
        const idx: u32 = @intCast(self.constants.items.len);
        self.constants.append(self.a, val) catch @panic("OOM");
        return idx;
    }

    fn addNil(self: *Emitter) u32 {
        return self.addConstant(bc.vNil());
    }

    // ── Locals ────────────────────────────────────────────────────

    fn addLocal(self: *Emitter, name: []const u8) u8 {
        if (self.local_count >= MAX_LOCALS) return 0xFF;
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

    /// Collect struct/enum/function declarations before emitting code so that
    /// literals, field accesses and variants resolve without a type table.
    fn registerTypes(self: *Emitter, module: u32) void {
        for (self.tree.extraSlice(self.tree.node(module).source_file)) |item| {
            switch (self.tree.node(item)) {
                .fn_decl => |f| {
                    if (self.fns.items.len >= MAX_FNS) {
                        self.err("error: too many functions (max {d})\n", .{MAX_FNS});
                        continue;
                    }
                    self.fns.append(self.a, .{ .name = f.name }) catch @panic("OOM");
                },
                .enum_decl => |e| {
                    if (self.enums.items.len >= MAX_ENUMS) {
                        self.err("error: too many enum declarations (max {d})\n", .{MAX_ENUMS});
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
                            self.err("error: too many enum variants (max {d})\n", .{MAX_VARIANTS});
                            break;
                        }
                        self.variant_index.append(self.a, .{ .variant = vname, .enum_idx = enum_idx }) catch @panic("OOM");
                    }
                },
                .struct_decl => |s| {
                    if (self.structs.items.len >= MAX_STRUCTS) {
                        self.err("error: too many struct declarations (max {d})\n", .{MAX_STRUCTS});
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
    }

    // ── Loop patch lists ──────────────────────────────────────────

    fn loopEnter(self: *Emitter) ?*LoopPatch {
        if (self.loop_depth >= MAX_LOOP_DEPTH) {
            self.err("error: loop nesting too deep (max {d})\n", .{MAX_LOOP_DEPTH});
            return null;
        }
        const lp = &self.loops[self.loop_depth];
        lp.* = .{};
        self.loop_depth += 1;
        return lp;
    }

    fn loopLeave(self: *Emitter, lp: ?*LoopPatch, exit_target: usize) void {
        const p = lp orelse return;
        for (p.breaks.items) |b| {
            const off: i32 = @intCast(@as(i64, @intCast(exit_target)) - @as(i64, @intCast(b)));
            self.code.items[b].arg = .{ .offset = off };
        }
        // `continue` jumps *back* to the continue target, so the offset is
        // negative; compute it signed rather than wrapping unsigned arithmetic.
        for (p.conts.items) |c| {
            const off: i32 = @intCast(@as(i64, @intCast(p.continue_target)) - @as(i64, @intCast(c)));
            self.code.items[c].arg = .{ .offset = off };
        }
        self.loop_depth -= 1;
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
            self.err("error:{d}: internal: {s} body left {d} values, expected 1\n", .{ ln, where, self.sp - before });
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
                    self.err("error: pattern must be a literal, `_` or Enum.Variant\n", .{});
                } else if (enumVariantIndex(ei.?, fa.field) == null) {
                    self.err("error: enum '{s}' has no variant '{s}'\n", .{ ei.?.name, fa.field });
                }
                const idx = self.addConstant(bc.vEnum(if (ei) |e| e.name else "", fa.field));
                self.emitInstIndex(.const_, idx, ln);
            },
            else => {
                self.err("error: unsupported pattern in match arm\n", .{});
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
                    self.err("error: pattern must be a literal, `_` or Enum.Variant\n", .{});
                    return;
                }
                const fa = var_path.field_access;
                const obj = self.tree.node(fa.object);
                const ei = if (std.meta.activeTag(obj) == .identifier)
                    self.findEnum(obj.identifier)
                else
                    null;
                if (ei == null) {
                    self.err("error: pattern must be a literal, `_` or Enum.Variant\n", .{});
                    return;
                }
                if (enumVariantIndex(ei.?, fa.field) == null) {
                    self.err("error: enum '{s}' has no variant '{s}'\n", .{ ei.?.name, fa.field });
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
            .while_expr, .for_expr, .return_stmt, .break_stmt, .continue_stmt, .fn_decl, .struct_decl, .enum_decl, .const_decl, .var_decl, .use_decl, .import_decl, .from_decl, .import_item, .range_expr, .source_file => 0,
            .block => |b| if (b.tail != null) 1 else 0,
            else => 1,
        };
    }

    fn spCheck(self: *Emitter, idx: u32, before: i32, expected: i32, where: []const u8) void {
        const want = before + expected;
        if (self.sp == want) return;
        const n = self.tree.node(idx);
        self.err("error:{s}:{d}: internal: stack imbalance in {s} {s}: expected height {d}, emitter computed {d}\n", .{
            self.filename, self.line(idx), where, @tagName(n), want, self.sp,
        });
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
                self.err("error: invalid assignment target\n", .{});
            },
        }
    }

    /// Emit a function or lambda body into a fresh code/constant pool, matching
    /// the seed's save/swap/restore. Slot 0 is reserved for the return value, so
    /// parameters start at slot 1.
    fn emitFunctionBody(self: *Emitter, params: ast.List, body: u32, ln: u32) *bc.FnObj {
        const fn_obj = self.a.create(bc.FnObj) catch @panic("OOM");
        fn_obj.* = .{ .code = &.{}, .constants = &.{} };

        const saved_code = self.code;
        const saved_consts = self.constants;
        const saved_local_count = self.local_count;
        const saved_scope_depth = self.scope_depth;
        const saved_sp = self.sp;
        var saved_locals: [MAX_LOCALS]Local = undefined;
        var i: usize = 0;
        while (i < saved_local_count) : (i += 1) saved_locals[i] = self.locals[i];

        self.code = .empty;
        self.constants = .empty;
        self.scope_depth = 1;
        self.local_count = 0;
        self.sp = 0;

        _ = self.addLocal("$ret");
        const plist = self.tree.extraSlice(params);
        for (plist) |p| _ = self.addLocal(self.tree.node(p).param.name);
        fn_obj.param_count = @truncate(plist.len);

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
            self.err("error:{s}:{d}: internal: function leaves {d} value(s) on the stack at return\n", .{
                self.filename, ln, self.sp,
            });
        }

        fn_obj.local_count = @truncate(self.local_count);
        fn_obj.code = self.code.toOwnedSlice(self.a) catch @panic("OOM");
        fn_obj.constants = self.constants.toOwnedSlice(self.a) catch @panic("OOM");

        self.code = saved_code;
        self.constants = saved_consts;
        self.local_count = saved_local_count;
        self.scope_depth = saved_scope_depth;
        self.sp = saved_sp;
        i = 0;
        while (i < saved_local_count) : (i += 1) self.locals[i] = saved_locals[i];
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
                } else {
                    const ci = self.addConstant(bc.vString(name));
                    self.emitInstIndex(.get_global, ci, ln);
                }
            },
            .binary_expr => |b| {
                if (b.op == .and_and) {
                    // Short-circuit AND: each skip target is entered right after
                    // a JUMP_IF_FALSE popped its condition, so both rejoin at
                    // the same height.
                    const base = self.sp;
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
                    const false_idx = self.addConstant(bc.vBool(false));
                    self.emitInstIndex(.const_, false_idx, ln);

                    self.code.items[patch_right_false].arg = .{ .offset = @intCast(self.code.items.len - patch_right_false) };
                    self.sp = base;
                    self.emitInstIndex(.const_, false_idx, ln);

                    self.code.items[patch_end].arg = .{ .offset = @intCast(self.code.items.len - patch_end) };
                    self.sp = base + 1;
                } else if (b.op == .or_or) {
                    const base = self.sp;
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
                    const true_idx = self.addConstant(bc.vBool(true));
                    self.emitInstIndex(.const_, true_idx, ln);

                    self.code.items[patch_right_true].arg = .{ .offset = @intCast(self.code.items.len - patch_right_true) };
                    self.sp = base;
                    self.emitInstIndex(.const_, true_idx, ln);

                    self.code.items[patch_end].arg = .{ .offset = @intCast(self.code.items.len - patch_end) };
                    self.sp = base + 1;
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
                // A bare-identifier callee may name a data-carrying enum variant
                // (`Paso(x)`); mirror the checker's rule: variant, else call.
                const callee = self.tree.node(c.callee);
                if (std.meta.activeTag(callee) == .identifier and !self.isKnownFn(callee.identifier)) {
                    const vname = callee.identifier;
                    if (self.findEnumByVariant(vname)) |ei| {
                        if (enumVariantIndex(ei, vname)) |vi| {
                            const nf: usize = ei.field_counts[vi];
                            const args = self.tree.extraSlice(c.args);
                            if (args.len != nf) {
                                self.err("error: variant '{s}.{s}' expects {d} field(s), got {d}\n", .{ ei.name, vname, nf, args.len });
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
                    self.err("error: unknown struct '{s}'\n", .{s.name});
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
                        self.err("error: struct '{s}' has no field '{s}'\n", .{ s.name, fname });
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
                        self.err("error: missing field '{s}' in initializer of '{s}'\n", .{ sf, s.name });
                        const z = self.addNil();
                        self.emitInstIndex(.const_, z, ln);
                    }
                }
                self.emitInst(.new_struct, ln);
                self.spSetIndex(self.code.items.len - 1, @intCast(si.fields.len));
            },
            .field_access => |fa| {
                const obj = self.tree.node(fa.object);
                // `Enum.Variant` is a value, not a field read.
                if (std.meta.activeTag(obj) == .identifier) {
                    if (self.findEnum(obj.identifier)) |ei| {
                        if (enumVariantIndex(ei, fa.field) == null) {
                            self.err("error: enum '{s}' has no variant '{s}'\n", .{ ei.name, fa.field });
                        }
                        const ci = self.addConstant(bc.vEnum(ei.name, fa.field));
                        self.emitInstIndex(.const_, ci, ln);
                    } else {
                        self.emitExpr(fa.object);
                        const ci = self.addConstant(bc.vString(fa.field));
                        self.emitInstIndex(.get_field, ci, ln);
                    }
                } else {
                    self.emitExpr(fa.object);
                    const ci = self.addConstant(bc.vString(fa.field));
                    self.emitInstIndex(.get_field, ci, ln);
                }
            },
            .match_expr => |m| self.emitMatch(m, ln),
            .range_expr => {
                self.err("error: range expression is only valid as a for-loop iterator\n", .{});
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
                self.emitExpr(i.cond);
                self.emitInstOffset(.jump_if_false, 0, ln);
                const patch_false = self.code.items.len - 1;
                self.emitBranchValue(i.then_block, "if", ln);
                self.emitInstOffset(.jump, 0, ln);
                const patch_over = self.code.items.len - 1;
                self.code.items[patch_false].arg = .{ .offset = @intCast(self.code.items.len - patch_false) };
                // The else arm starts after JUMP_IF_FALSE popped the condition.
                self.sp = base;
                if (i.else_block) |eb| {
                    self.emitBranchValue(eb, "else", ln);
                } else {
                    const z = self.addNil();
                    self.emitInstIndex(.const_, z, ln);
                }
                self.code.items[patch_over].arg = .{ .offset = @intCast(self.code.items.len - patch_over) };
                self.sp = base + 1;
            },
            .while_expr => |w| {
                const loop_start = self.code.items.len;
                const lp = self.loopEnter();
                if (lp) |p| p.continue_target = loop_start;
                self.emitExpr(w.cond);
                self.emitInstOffset(.jump_if_false, 0, ln);
                const patch_exit = self.code.items.len - 1;
                self.emitLoopBody(w.body);
                const back: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(self.code.items.len)));
                self.emitInstOffset(.jump, back, ln);
                const exit_target = self.code.items.len;
                self.code.items[patch_exit].arg = .{ .offset = @intCast(exit_target - patch_exit) };
                self.loopLeave(lp, exit_target);
            },
            .for_expr => |f| self.emitFor(f, ln),
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
                    self.err("error: 'break' used outside of a loop\n", .{});
                } else {
                    self.emitInstOffset(.jump, 0, ln);
                    const lp = &self.loops[self.loop_depth - 1];
                    self.patchPush(&lp.breaks, self.code.items.len - 1);
                }
            },
            .continue_stmt => {
                if (self.loop_depth == 0) {
                    self.err("error: 'continue' used outside of a loop\n", .{});
                } else {
                    self.emitInstOffset(.jump, 0, ln);
                    const lp = &self.loops[self.loop_depth - 1];
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
                const fn_obj = self.emitFunctionBody(l.params, l.body, ln);
                const ci = self.addConstant(bc.vFn(fn_obj));
                self.emitInstIndex(.const_, ci, ln);
            },
            else => {},
        }

        self.spCheck(idx, sp_before, self.nodeValueEffect(idx), "expression");
    }

    fn emitEnumConstruction(self: *Emitter, ei: *EnumInfo, vi: usize, nf: usize, args: []const u32, ln: u32) void {
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
        // -nf (pops nf+1, pushes 1), so correct by -(nf+1).
        self.spAdvance(-@as(i32, @intCast(nf)) - 1);
    }

    fn emitMatch(self: *Emitter, m: ast.MatchExpr, ln: u32) void {
        const arms = self.tree.extraSlice(m.arms);
        const base = self.sp;

        // The matched value lives in a hidden local; every arm tests against it.
        const slot = self.addLocal("$match_val");
        if (slot == 0xFF) {
            self.err("error: too many locals for match\n", .{});
        } else {
            self.emitExpr(m.target);
            self.emitInstIndex(.set_local, slot, ln);
        }

        var end_jumps: std.ArrayListUnmanaged(usize) = .empty;
        var has_wildcard = false;

        arms_loop: for (arms) |arm_idx| {
            const arm = self.tree.node(arm_idx).match_arm;
            const pat = arm.pattern;
            const body = arm.body;
            self.sp = base;

            switch (self.tree.node(pat)) {
                .pattern_wildcard => {
                    has_wildcard = true;
                    if (arm.guard) |g| {
                        self.emitExpr(g);
                        self.emitInstOffset(.jump_if_false, 0, ln);
                        const guard_false = self.code.items.len - 1;
                        self.emitBranchValue(body, "match arm", ln);
                        self.emitInstOffset(.jump, 0, ln);
                        self.patchPush(&end_jumps, self.code.items.len - 1);
                        const z = self.addNil();
                        self.emitInstIndex(.const_, z, ln);
                        self.code.items[guard_false].arg = .{ .offset = @intCast(self.code.items.len - guard_false) };
                    } else {
                        self.emitBranchValue(body, "match arm", ln);
                        self.emitInstOffset(.jump, 0, ln);
                        self.patchPush(&end_jumps, self.code.items.len - 1);
                    }
                    break :arms_loop; // a wildcard makes later arms unreachable
                },
                .pattern_bind => |name| {
                    const bind_slot = self.addLocal(name);
                    if (bind_slot == 0xFF) {
                        self.err("error: too many locals for match\n", .{});
                        break :arms_loop;
                    }
                    self.emitInstIndex(.get_local, slot, ln);
                    self.emitInstIndex(.set_local, bind_slot, ln);
                    if (arm.guard) |g| {
                        self.emitExpr(g);
                        self.emitInstOffset(.jump_if_false, 0, ln);
                        const guard_false = self.code.items.len - 1;
                        self.emitBranchValue(body, "match arm", ln);
                        self.emitInstOffset(.jump, 0, ln);
                        self.patchPush(&end_jumps, self.code.items.len - 1);
                        const z = self.addNil();
                        self.emitInstIndex(.const_, z, ln);
                        self.code.items[guard_false].arg = .{ .offset = @intCast(self.code.items.len - guard_false) };
                    } else {
                        self.emitBranchValue(body, "match arm", ln);
                        self.emitInstOffset(.jump, 0, ln);
                        self.patchPush(&end_jumps, self.code.items.len - 1);
                    }
                    break :arms_loop; // binding makes later arms unreachable
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
                    for (self.tree.extraSlice(vb.bindings), 0..) |b, k| {
                        self.emitInstIndex(.get_local, slot, ln);
                        self.emitInstIndex(.get_enum_field, @intCast(k), ln);
                        const bind_slot = self.addLocal(self.tree.node(b).pattern_bind);
                        if (bind_slot == 0xFF) {
                            self.err("error: too many locals for match\n", .{});
                            break;
                        }
                        self.emitInstIndex(.set_local, bind_slot, ln);
                    }

                    var guard_false_jump: ?usize = null;
                    if (arm.guard) |g| {
                        self.emitExpr(g);
                        self.emitInstOffset(.jump_if_false, 0, ln);
                        guard_false_jump = self.code.items.len - 1;
                    }
                    self.emitBranchValue(body, "match arm", ln);
                    self.emitInstOffset(.jump, 0, ln);
                    self.patchPush(&end_jumps, self.code.items.len - 1);

                    const next_arm = self.code.items.len;
                    self.code.items[no_match].arg = .{ .offset = @intCast(next_arm - no_match) };
                    if (guard_false_jump) |gf| {
                        self.code.items[gf].arg = .{ .offset = @intCast(next_arm - gf) };
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
                                if (bind_slot == 0xFF) {
                                    self.err("error: too many locals for match\n", .{});
                                } else {
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

                    var guard_false_jump: ?usize = null;
                    if (arm.guard) |g| {
                        self.emitExpr(g);
                        self.emitInstOffset(.jump_if_false, 0, ln);
                        guard_false_jump = self.code.items.len - 1;
                    }
                    self.emitBranchValue(body, "match arm", ln);
                    self.emitInstOffset(.jump, 0, ln);
                    self.patchPush(&end_jumps, self.code.items.len - 1);

                    const next_arm = self.code.items.len;
                    self.code.items[no_match].arg = .{ .offset = @intCast(next_arm - no_match) };
                    if (guard_false_jump) |gf| {
                        self.code.items[gf].arg = .{ .offset = @intCast(next_arm - gf) };
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
            self.emitInstOffset(.jump, 0, ln);
            self.patchPush(&end_jumps, self.code.items.len - 1);

            const next_arm = self.code.items.len;
            self.code.items[no_match].arg = .{ .offset = @intCast(next_arm - no_match) };
            if (guard_false_jump) |gf| {
                self.code.items[gf].arg = .{ .offset = @intCast(next_arm - gf) };
            }
        }

        if (!has_wildcard) {
            // No arm matched: yield nil so a match always produces a value.
            self.sp = base;
            const z = self.addNil();
            self.emitInstIndex(.const_, z, ln);
        }

        const end_target = self.code.items.len;
        for (end_jumps.items) |j| {
            self.code.items[j].arg = .{ .offset = @intCast(end_target - j) };
        }

        // Drop the hidden local's slot index (no POP: the result sits on top).
        self.local_count -%= 1;
        self.sp = base + 1;
    }

    fn emitFor(self: *Emitter, f: ast.ForExpr, ln: u32) void {
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
                self.err("error: open-ended range is not supported in Astra-0\n", .{});
                const z = self.addConstant(bc.vInt(0));
                self.emitInstIndex(.const_, z, ln);
            }
            self.emitInstIndex(.set_local, slot_end, ln);

            loop_start = self.code.items.len;
            lp = self.loopEnter();
            self.emitInstIndex(.get_local, slot_idx, ln);
            self.emitInstIndex(.get_local, slot_end, ln);
            self.emitInst(if (r.inclusive) .le else .lt, ln);
            self.emitInstOffset(.jump_if_false, 0, ln);
            patch_exit = self.code.items.len - 1;

            var_slot = self.addLocal(f.var_name);
            self.emitInstIndex(.get_local, slot_idx, ln);
            self.emitInstIndex(.set_local, var_slot, ln);
            self.emitLoopBody(f.body);
            if (lp) |p| p.continue_target = self.code.items.len;
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
            lp = self.loopEnter();
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
            if (lp) |p| p.continue_target = self.code.items.len;
            self.emitInstIndex(.get_local, slot_idx, ln);
            const one = self.addConstant(bc.vInt(1));
            self.emitInstIndex(.const_, one, ln);
            self.emitInst(.add, ln);
            self.emitInstIndex(.set_local, slot_idx, ln);
        }

        const back: i32 = @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(self.code.items.len)));
        self.emitInstOffset(.jump, back, ln);
        const exit_target = self.code.items.len;
        self.code.items[patch_exit].arg = .{ .offset = @intCast(exit_target - patch_exit) };
        self.loopLeave(lp, exit_target);

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
                } else {
                    const ci = self.addConstant(bc.vString(name));
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
                self.err("error: invalid assignment target\n", .{});
            },
        }
    }

    fn emitStmt(self: *Emitter, idx: u32) void {
        const sp_before = self.sp;
        const ln = self.tree.loc(idx).line;

        switch (self.tree.node(idx)) {
            .fn_decl => |f| {
                const fn_obj = self.emitFunctionBody(f.params, f.body, ln);
                const fn_idx = self.addConstant(bc.vFn(fn_obj));
                const name_idx = self.addConstant(bc.vString(f.name));
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
                    const name_idx = self.addConstant(bc.vString(v.name));
                    self.emitInstIndex(.set_global, name_idx, ln);
                } else {
                    const slot = self.addLocal(v.name);
                    if (slot == 0xFF) {
                        const name_idx = self.addConstant(bc.vString(v.name));
                        self.emitInstIndex(.set_global, name_idx, ln);
                    } else {
                        self.emitInstIndex(.set_local, slot, ln);
                    }
                }
            },
            .struct_decl, .enum_decl, .use_decl, .import_decl, .from_decl, .import_item => {},
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
    pub fn emit(self: *Emitter, module: u32) void {
        self.registerTypes(module);
        self.emitStmt(module);

        // If the module defines main(), call it; top-level functions live in the
        // globals table, so a name lookup is enough.
        for (self.tree.extraSlice(self.tree.node(module).source_file)) |item| {
            const it = self.tree.node(item);
            if (std.meta.activeTag(it) == .fn_decl and std.mem.eql(u8, it.fn_decl.name, "main")) {
                const name_idx = self.addConstant(bc.vString("main"));
                self.emitInstIndex(.get_global, name_idx, self.tree.loc(item).line);
                self.emitInst(.call, self.tree.loc(item).line);
                self.code.items[self.code.items.len - 1].arg = .{ .arg_count = 0 };
                break;
            }
        }

        self.emitInst(.halt, 0);
    }
};

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
        \\    let items = [First(1), Item.Third];
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
