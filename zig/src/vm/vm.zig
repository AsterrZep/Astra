//! Astra-0 bytecode VM (Phase 2, Zig).
//!
//! A port of `seed/src/vm.c`. It executes the bytecode the emitter produces
//! (`emitter/bytecode.zig`) on a stack machine. The load-bearing behaviours are
//! copied from the seed on purpose, because the two backends are compared
//! byte-for-byte by the conformance suite:
//!
//! 1. **Stack under `sp` is the local frame.** A call frame records a `base`
//!    stack slot; `GET_LOCAL`/`SET_LOCAL` address `base + slot`. Slot 0 of a
//!    frame is the callee/return slot, so parameters start at slot 1.
//! 2. **Jumps are relative to the instruction that holds them.** A jump at
//!    instruction `P` with `offset` lands on `P + offset` (the seed does
//!    `ip += offset; ip--` and then the loop's `ip++`).
//! 3. **Error text is part of the contract.** `run_tests.sh` matches
//!    `EXPECT-RUNTIME-ERROR` substrings, so `"index 5 out of bounds (len 3)"`
//!    and friends are reproduced verbatim.
//!
//! One Zig-specific change: output goes through a `std.Io.Writer` instead of
//! `printf`, so the CLI can send it to stdout and the conformance tests can
//! capture it in a buffer. Float output uses C's `%g` (see
//! `bytecode.writeFloatG`) so both backends render floats identically.

const std = @import("std");
const bc = @import("../emitter/bytecode.zig");

const OpCode = bc.OpCode;
const Instruction = bc.Instruction;
const Value = bc.Value;
const FnObj = bc.FnObj;
const ArrayObj = bc.ArrayObj;
const StructObj = bc.StructObj;
const EnumObj = bc.EnumObj;
const StructDef = bc.StructDef;
const EnumDef = bc.EnumDef;

const VM_STACK_SIZE = 1024;
const VM_CALL_DEPTH = 256;
const VM_MAX_GLOBALS = 256;
const MAX_BREAKPOINTS = 64;

const Global = struct { name: []const u8, value: Value };

const CallFrame = struct {
    /// Instruction index to resume at in `saved_code` after RET.
    ip: usize,
    /// Stack slot where this frame's locals begin.
    base: usize,
    saved_code: []const Instruction,
    saved_constants: []const Value,
};

pub const VMResult = enum { ok, runtime_error };

fn tag(v: Value) bc.Kind {
    return std.meta.activeTag(v);
}

/// Runtime type name (seed `type_name`): used only in diagnostics.
fn typeName(v: Value) []const u8 {
    return tag(v).name();
}

// ── Operand access ───────────────────────────────────────────────
// `Instruction.arg` is a union; the seed reads whichever member the opcode
// uses. These helpers make the valid member explicit (and return 0 for a
// defaulted operand, matching the seed's `{0}` initialisation).

fn argIndex(inst: Instruction) u32 {
    return switch (inst.arg) {
        .index => |v| v,
        .offset => 0,
        .arg_count => 0,
        .none => 0,
    };
}

fn argOffset(inst: Instruction) i32 {
    return switch (inst.arg) {
        .offset => |v| v,
        .index => 0,
        .arg_count => 0,
        .none => 0,
    };
}

fn argCount(inst: Instruction) u8 {
    return switch (inst.arg) {
        .arg_count => |v| v,
        .index => 0,
        .offset => 0,
        .none => 0,
    };
}

// ── Value utilities ──────────────────────────────────────────────

/// `value_is_truthy`: an empty string / empty array is falsy, everything else
/// is truthy.
fn isTruthy(v: Value) bool {
    return switch (v) {
        .nil => false,
        .bool_ => |b| b,
        .int => |i| i != 0,
        .float => |f| f != 0.0,
        .string => |s| s.len > 0,
        .array => |a| a.len > 0,
        .struct_, .struct_def, .enum_, .enum_data, .enum_def, .fn_, .ok, .err, .some => true,
    };
}

/// Structural equality (seed `value_eq`). Arrays and structs compare
/// element/field-wise; enum-unit and enum-data values compare as equal when
/// they name the same variant (pattern constants are `enum_`, runtime values
/// are `enum_data`).
fn valueEq(a: Value, b: Value) bool {
    if (tag(a) == .array and tag(b) == .array) {
        const x = a.array;
        const y = b.array;
        if (x == y) return true;
        if (x.len != y.len) return false;
        var i: usize = 0;
        while (i < x.len) : (i += 1) {
            if (!valueEq(x.elems[i], y.elems[i])) return false;
        }
        return true;
    }

    if (tag(a) != tag(b)) {
        const ka = tag(a);
        const kb = tag(b);
        if ((ka == .enum_ and kb == .enum_data) or (ka == .enum_data and kb == .enum_)) {
            var an: []const u8 = undefined;
            var av: []const u8 = undefined;
            var bn: []const u8 = undefined;
            var bv: []const u8 = undefined;
            if (ka == .enum_) {
                an = a.enum_.enum_name;
                av = a.enum_.variant_name;
                const y = b.enum_data;
                const d = y.def orelse return false;
                bn = d.name;
                if (y.variant >= d.variants.len) return false;
                bv = d.variants[y.variant].name orelse return false;
            } else {
                const x = a.enum_data;
                const d = x.def orelse return false;
                an = d.name;
                if (x.variant >= d.variants.len) return false;
                av = d.variants[x.variant].name orelse return false;
                bn = b.enum_.enum_name;
                bv = b.enum_.variant_name;
            }
            return std.mem.eql(u8, an, bn) and std.mem.eql(u8, av, bv);
        }
        return false;
    }

    switch (a) {
        .nil => return true,
        .bool_ => |x| return x == b.bool_,
        .int => |x| return x == b.int,
        .float => |x| return x == b.float,
        .string => |x| return std.mem.eql(u8, x, b.string),
        .array => unreachable, // handled above
        .struct_def => |x| return x == b.struct_def,
        .enum_def => |x| return x == b.enum_def,
        .fn_ => |x| return x == b.fn_,
        .struct_ => {
            const x = a.struct_;
            const y = b.struct_;
            if (x == y) return true;
            const xd = x.def orelse return false;
            const yd = y.def orelse return false;
            if (!std.mem.eql(u8, xd.name, yd.name)) return false;
            if (xd.field_names.len != yd.field_names.len) return false;
            var i: usize = 0;
            while (i < xd.field_names.len) : (i += 1) {
                if (!valueEq(x.fields[i], y.fields[i])) return false;
            }
            return true;
        },
        .enum_ => {
            const x = a.enum_;
            const y = b.enum_;
            return std.mem.eql(u8, x.enum_name, y.enum_name) and
                std.mem.eql(u8, x.variant_name, y.variant_name);
        },
        .enum_data => {
            const x = a.enum_data;
            const y = b.enum_data;
            if (x == y) return true;
            const xd = x.def orelse return false;
            const yd = y.def orelse return false;
            if (!std.mem.eql(u8, xd.name, yd.name)) return false;
            if (x.variant != y.variant) return false;
            const nf = if (x.variant < xd.variants.len) xd.variants[x.variant].field_count else 0;
            var i: usize = 0;
            while (i < nf) : (i += 1) {
                if (!valueEq(x.fields[i], y.fields[i])) return false;
            }
            return true;
        },
        .ok => |x| return valueEq(x.*, b.ok.*),
        .err => |x| return valueEq(x.*, b.err.*),
        .some => |x| return valueEq(x.*, b.some.*),
    }
}

// ── Numeric binary operations ────────────────────────────────────

const NumOp = enum { add, sub, mul };

/// The int/float coercion matrix shared by `+`, `-`, `*`: int×int stays int,
/// any other numeric pair is a float. Returns null for a non-numeric operand.
fn numOp(a: Value, b: Value, op: NumOp) ?Value {
    return switch (a) {
        .int => |x| switch (b) {
            .int => |y| bc.vInt(switch (op) {
                .add => x +% y,
                .sub => x -% y,
                .mul => x *% y,
            }),
            .float => |y| bc.vFloat(switch (op) {
                .add => @as(f64, @floatFromInt(x)) + y,
                .sub => @as(f64, @floatFromInt(x)) - y,
                .mul => @as(f64, @floatFromInt(x)) * y,
            }),
            else => null,
        },
        .float => |x| switch (b) {
            .int => |y| bc.vFloat(switch (op) {
                .add => x + @as(f64, @floatFromInt(y)),
                .sub => x - @as(f64, @floatFromInt(y)),
                .mul => x * @as(f64, @floatFromInt(y)),
            }),
            .float => |y| bc.vFloat(switch (op) {
                .add => x + y,
                .sub => x - y,
                .mul => x * y,
            }),
            else => null,
        },
        else => null,
    };
}

fn isNumeric(v: Value) bool {
    return tag(v) == .int or tag(v) == .float;
}

/// `<`, `<=`, `>`, `>=` over numbers. Returns null when either side is not
/// numeric, so the caller can word the "cannot compare" diagnostic.
fn cmpOp(a: Value, b: Value, op: Order) ?bool {
    // int/int compares as i64 so large integers keep their precision; any
    // float pair (or mixed) promotes to f64 like the seed.
    if (tag(a) == .int and tag(b) == .int) {
        const x = a.int;
        const y = b.int;
        return switch (op) {
            .lt => x < y,
            .gt => x > y,
            .le => x <= y,
            .ge => x >= y,
        };
    }
    const x: f64 = switch (a) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    const y: f64 = switch (b) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    return switch (op) {
        .lt => x < y,
        .gt => x > y,
        .le => x <= y,
        .ge => x >= y,
    };
}

const Order = enum { lt, gt, le, ge };

// ── VM ───────────────────────────────────────────────────────────

pub const VM = struct {
    a: std.mem.Allocator,
    w: *std.Io.Writer,

    stack: [VM_STACK_SIZE]Value = undefined,
    sp: usize = 0,

    frames: [VM_CALL_DEPTH]CallFrame = undefined,
    frame_count: usize = 0,

    code: []const Instruction = &.{},
    constants: []const Value = &.{},

    globals: [VM_MAX_GLOBALS]Global = undefined,
    global_count: usize = 0,

    builtin_print_fn: *FnObj = undefined,

    error_msg: []const u8 = "",
    error_line: u32 = 0,

    /// Debug switches, mirroring the seed's environment variables. Set by the
    /// CLI from `ASTRA_DUMP_VM` / `ASTRA_TRACE`; off in tests and conformance.
    dump_vm: bool = false,
    trace: bool = false,

    // ── Bytecode debugger (`--debug`) ─────────────────────────────
    debug: bool = false,
    /// Pause before every instruction (single-step) vs. only at breakpoints.
    stepping: bool = false,
    /// After `continue`, suppress further stops on the line we resumed from so
    /// a multi-instruction statement does not stop once per instruction. Cleared
    /// as soon as execution moves to another line.
    suppress_line: ?u32 = null,
    /// Command stream. Null disables the debugger (never prompted).
    in: ?*std.Io.Reader = null,
    /// Where debugger output goes. Null means stderr, like the trace/dump.
    /// Tests pass a buffer to capture it.
    dbg_out: ?*std.Io.Writer = null,
    /// Source text, for showing the current line.
    source: ?[]const u8 = null,
    /// Instruction the VM is about to execute (for `bt`).
    cur_ip: usize = 0,
    breakpoints: [MAX_BREAKPOINTS]u32 = undefined,
    bp_count: usize = 0,

    pub fn init(a: std.mem.Allocator, w: *std.Io.Writer) !VM {
        var vm = VM{ .a = a, .w = w };
        // The builtin print function is recognised by the same marker the seed
        // uses: param_count == 255 and no code.
        const f = try a.create(FnObj);
        f.* = .{ .code = &.{}, .constants = &.{}, .param_count = 255, .local_count = 0 };
        vm.builtin_print_fn = f;
        return vm;
    }

    fn rt(self: *VM, line: u32, comptime fmt: []const u8, args: anytype) VMResult {
        self.error_line = line;
        self.error_msg = std.fmt.allocPrint(self.a, fmt, args) catch "out of memory";
        return .runtime_error;
    }

    fn push(self: *VM, v: Value) bool {
        if (self.sp >= VM_STACK_SIZE) {
            self.error_msg = "stack overflow";
            self.error_line = 0;
            return false;
        }
        self.stack[self.sp] = v;
        self.sp += 1;
        return true;
    }

    fn pop(self: *VM) Value {
        if (self.sp == 0) {
            self.error_msg = "stack underflow";
            self.error_line = 0;
            return bc.vNil();
        }
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn frameBase(self: *const VM) usize {
        return if (self.frame_count > 0) self.frames[self.frame_count - 1].base else 0;
    }

    // ── Debug output (ASTRA_DUMP_VM / ASTRA_TRACE) ────────────────
    // Diagnostics go to stderr like the seed, so they never pollute the
    // program's stdout (which the conformance suite compares).

    /// Dump a module or function body in the shared `vm_dump_bytecode` format.
    fn dumpCode(code: []const Instruction, constants: []const Value) void {
        var buf: [4096]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();
        bc.dump(&stderr.file_writer.interface, code, constants) catch {};
    }

    /// `>> CALL fn (...)` plus the callee's instructions, the seed's per-call
    /// echo when `ASTRA_DUMP_VM` is set.
    fn dumpCall(fn_obj: *FnObj, base: usize) void {
        var buf: [4096]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();
        const w = &stderr.file_writer.interface;
        w.print("  >> CALL fn (base={d}, {d} instructions, {d} constants)\n", .{
            base, fn_obj.code.len, fn_obj.constants.len,
        }) catch {};
        for (fn_obj.code, 0..) |inst, i| {
            w.print("     [{d: >3}] {s: <16}", .{ i, inst.op.name() }) catch {};
            switch (inst.op) {
                .const_, .get_global, .set_global => {
                    w.print(" {d}", .{argIndex(inst)}) catch {};
                    if (inst.op == .const_ and argIndex(inst) < fn_obj.constants.len) {
                        w.writeAll(" (") catch {};
                        bc.printValue(w, fn_obj.constants[argIndex(inst)]) catch {};
                        w.writeByte(')') catch {};
                    }
                },
                .get_local, .set_local => w.print(" slot={d}", .{argIndex(inst)}) catch {},
                .call => w.print(" argc={d}", .{argCount(inst)}) catch {},
                .jump, .jump_if_false, .jump_if_true => w.print(" offset={d}", .{argOffset(inst)}) catch {},
                else => {},
            }
            w.writeByte('\n') catch {};
        }
    }

    // ── Bytecode debugger ─────────────────────────────────────────

    /// Enable interactive debugging. `stepping` starts true so the debugger
    /// stops at the first instruction, like `gdb` stopping at entry.
    pub fn enableDebug(self: *VM, in: *std.Io.Reader, source: []const u8) void {
        self.debug = true;
        self.stepping = true;
        self.suppress_line = null;
        self.in = in;
        self.source = source;
    }

    const DbgLock = struct { w: *std.Io.Writer, unlock: bool };

    /// Resolve where debugger output goes: the test-captured writer when set,
    /// otherwise the process's stderr.
    fn dbgLock(self: *VM, buf: []u8) DbgLock {
        if (self.dbg_out) |dw| return .{ .w = dw, .unlock = false };
        const stderr = std.debug.lockStderr(buf);
        return .{ .w = &stderr.file_writer.interface, .unlock = true };
    }

    fn dbgLine(self: *VM, comptime fmt: []const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        const l = self.dbgLock(&buf);
        defer if (l.unlock) std.debug.unlockStderr();
        l.w.print(fmt, args) catch {};
    }

    /// Decide whether to pause before executing `ip`.
    fn shouldStop(self: *VM, ip: usize) bool {
        // Single-step stops before every instruction.
        if (self.stepping) return true;

        const line = self.code[ip].line;
        if (line == 0) return false;
        if (!self.hasBreakpoint(line)) {
            // Moved off the resumed line: the one-shot suppression is spent.
            self.suppress_line = null;
            return false;
        }
        if (self.suppress_line) |sl| {
            if (sl == line) {
                self.suppress_line = null;
                return false;
            }
        }
        return true;
    }

    fn hasBreakpoint(self: *const VM, line: u32) bool {
        for (self.breakpoints[0..self.bp_count]) |b| {
            if (b == line) return true;
        }
        return false;
    }

    /// Source text of a 1-based line, or "" when unavailable.
    fn lineText(self: *const VM, ln: u32) []const u8 {
        const src = self.source orelse return "";
        if (ln == 0) return "";
        var it = std.mem.splitScalar(u8, src, '\n');
        var n: u32 = 1;
        while (it.next()) |l| : (n += 1) {
            if (n == ln) return std.mem.trimEnd(u8, l, " \t\r");
        }
        return "";
    }

    fn printStop(self: *VM, ip: usize) void {
        var buf: [4096]u8 = undefined;
        const l = self.dbgLock(&buf);
        defer if (l.unlock) std.debug.unlockStderr();
        const inst = self.code[ip];
        const src = self.lineText(inst.line);
        if (src.len > 0) {
            l.w.print("-- line {d}: {s}\n", .{ inst.line, src }) catch {};
        } else {
            l.w.print("-- line {d}\n", .{inst.line}) catch {};
        }
        l.w.print("[pc={d}] {s}\n", .{ ip, inst.op.name() }) catch {};
    }

    fn printStack(self: *VM) void {
        var buf: [4096]u8 = undefined;
        const l = self.dbgLock(&buf);
        defer if (l.unlock) std.debug.unlockStderr();
        const w = l.w;
        w.print("stack ({d}):", .{self.sp}) catch {};
        var i: usize = 0;
        while (i < self.sp) : (i += 1) {
            w.writeAll(" [") catch {};
            bc.printValue(w, self.stack[i]) catch {};
            w.writeAll("]") catch {};
        }
        w.writeByte('\n') catch {};
    }

    fn printLocals(self: *VM) void {
        var buf: [4096]u8 = undefined;
        const l = self.dbgLock(&buf);
        defer if (l.unlock) std.debug.unlockStderr();
        const w = l.w;
        const base = self.frameBase();
        w.print("locals (base={d}, sp={d}):\n", .{ base, self.sp }) catch {};
        var s = base;
        while (s < self.sp) : (s += 1) {
            w.print("  [{d}] ", .{s}) catch {};
            bc.printValue(w, self.stack[s]) catch {};
            w.writeByte('\n') catch {};
        }
    }

    fn printFrames(self: *VM) void {
        var buf: [4096]u8 = undefined;
        const l = self.dbgLock(&buf);
        defer if (l.unlock) std.debug.unlockStderr();
        const w = l.w;
        w.print("call stack ({d} frame(s)):\n", .{self.frame_count}) catch {};
        w.print("  #0  base={d} pc={d} (current)\n", .{ self.frameBase(), self.cur_ip }) catch {};
        var i = self.frame_count;
        var depth: usize = 1;
        while (i > 0) : (i -= 1) {
            const fr = self.frames[i - 1];
            w.print("  #{d}  base={d} ret_pc={d}\n", .{ depth, fr.base, fr.ip }) catch {};
            depth += 1;
        }
    }

    fn printBreakpoints(self: *VM) void {
        var buf: [2048]u8 = undefined;
        const l = self.dbgLock(&buf);
        defer if (l.unlock) std.debug.unlockStderr();
        if (self.bp_count == 0) {
            l.w.writeAll("no breakpoints set\n") catch {};
            return;
        }
        l.w.writeAll("breakpoints: ") catch {};
        for (self.breakpoints[0..self.bp_count], 0..) |b, i| {
            if (i > 0) l.w.writeAll(", ") catch {};
            l.w.print("{d}", .{b}) catch {};
        }
        l.w.writeByte('\n') catch {};
    }

    fn addBreakpoint(self: *VM, ln: u32) void {
        if (ln == 0) {
            self.dbgLine("line 0 is not a source line\n", .{});
            return;
        }
        if (self.hasBreakpoint(ln)) {
            self.dbgLine("breakpoint already set on line {d}\n", .{ln});
            return;
        }
        if (self.bp_count >= MAX_BREAKPOINTS) {
            self.dbgLine("too many breakpoints (max {d})\n", .{MAX_BREAKPOINTS});
            return;
        }
        self.breakpoints[self.bp_count] = ln;
        self.bp_count += 1;
        self.dbgLine("breakpoint set on line {d}\n", .{ln});
    }

    fn removeBreakpoint(self: *VM, ln: u32) void {
        for (self.breakpoints[0..self.bp_count], 0..) |b, i| {
            if (b == ln) {
                var j = i;
                while (j + 1 < self.bp_count) : (j += 1) self.breakpoints[j] = self.breakpoints[j + 1];
                self.bp_count -= 1;
                self.dbgLine("breakpoint removed from line {d}\n", .{ln});
                return;
            }
        }
        self.dbgLine("no breakpoint on line {d}\n", .{ln});
    }

    fn printHelp(self: *VM) void {
        var buf: [2048]u8 = undefined;
        const l = self.dbgLock(&buf);
        defer if (l.unlock) std.debug.unlockStderr();
        l.w.writeAll(
            \\commands:
            \\  c | continue        run to the next breakpoint (or halt)
            \\  s | step            execute one instruction
            \\  b | break           list breakpoints
            \\  b | break <line>    set a breakpoint on an Astra source line
            \\  d <line>            remove a breakpoint
            \\  stack | p           print the operand stack
            \\  locals | l          print the current frame's slots
            \\  bt                  print the call frames
            \\  h | help            this help
            \\  q | quit            exit
            \\
        ) catch {};
    }

    fn eqAny(s: []const u8, comptime opts: []const []const u8) bool {
        inline for (opts) |o| {
            if (std.mem.eql(u8, s, o)) return true;
        }
        return false;
    }

    fn parseLineArg(rest: []const u8) ?u32 {
        const t = std.mem.trim(u8, rest, " \t");
        if (t.len == 0) return null;
        return std.fmt.parseInt(u32, t, 10) catch null;
    }

    /// Block until the user resumes, quits, or the command stream ends.
    /// Returns false when the debugger should end the program.
    fn debugPrompt(self: *VM, ip: usize) !bool {
        while (true) {
            self.printStop(ip);
            const raw = self.in.?.takeDelimiter('\n') catch return false;
            const line = raw orelse return false; // EOF
            const cmd = std.mem.trim(u8, line, " \t\r");
            if (cmd.len == 0) continue;

            if (eqAny(cmd, &.{ "c", "cont", "continue" })) {
                self.stepping = false;
                // Do not re-stop on the other instructions of this statement.
                self.suppress_line = self.code[ip].line;
                return true;
            }
            if (eqAny(cmd, &.{ "s", "step" })) {
                self.stepping = true;
                self.suppress_line = null;
                return true;
            }
            if (eqAny(cmd, &.{ "q", "quit", "exit" })) return false;
            if (eqAny(cmd, &.{ "h", "help", "?" })) {
                self.printHelp();
                continue;
            }
            if (eqAny(cmd, &.{ "stack", "p", "st" })) {
                self.printStack();
                continue;
            }
            if (eqAny(cmd, &.{ "locals", "l" })) {
                self.printLocals();
                continue;
            }
            if (eqAny(cmd, &.{ "bt", "backtrace" })) {
                self.printFrames();
                continue;
            }
            if (eqAny(cmd, &.{ "b", "break" })) {
                self.printBreakpoints();
                continue;
            }
            if (std.mem.startsWith(u8, cmd, "b ")) {
                if (parseLineArg(cmd[2..])) |ln| self.addBreakpoint(ln) else self.dbgLine("usage: b <line>\n", .{});
                continue;
            }
            if (std.mem.startsWith(u8, cmd, "break ")) {
                if (parseLineArg(cmd[6..])) |ln| self.addBreakpoint(ln) else self.dbgLine("usage: break <line>\n", .{});
                continue;
            }
            if (std.mem.startsWith(u8, cmd, "d ")) {
                if (parseLineArg(cmd[2..])) |ln| self.removeBreakpoint(ln) else self.dbgLine("usage: d <line>\n", .{});
                continue;
            }
            self.dbgLine("unknown command: {s} (try `h`)\n", .{cmd});
        }
    }

    /// One `sp=N base=N frame=N | [v][v]...` line, the seed's `ASTRA_TRACE`.
    fn traceState(self: *VM) void {
        var buf: [4096]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();
        const w = &stderr.file_writer.interface;
        w.print("  sp={d} base={d} frame={d} | ", .{ self.sp, self.frameBase(), self.frame_count }) catch {};
        var s: usize = 0;
        while (s < self.sp and s < 20) : (s += 1) {
            w.writeAll("[") catch {};
            bc.printValue(w, self.stack[s]) catch {};
            w.writeAll("]") catch {};
        }
        w.writeByte('\n') catch {};
    }

    // ── Value constructors that need allocation ───────────────────

    fn newArray(self: *VM, n: usize) !*ArrayObj {
        const obj = try self.a.create(ArrayObj);
        obj.* = .{ .elems = try self.a.alloc(Value, n), .len = n };
        return obj;
    }

    fn newStruct(self: *VM, def: *const StructDef) !*StructObj {
        const obj = try self.a.create(StructObj);
        obj.* = .{ .def = def, .fields = try self.a.alloc(Value, def.field_names.len) };
        return obj;
    }

    fn newEnum(self: *VM, def: *const EnumDef, variant: usize, fields: []const Value) !*EnumObj {
        const obj = try self.a.create(EnumObj);
        const n = if (variant < def.variants.len) def.variants[variant].field_count else 0;
        const copy = try self.a.alloc(Value, n);
        for (0..n) |i| copy[i] = fields[i];
        obj.* = .{ .def = def, .variant = variant, .fields = copy };
        return obj;
    }

    fn wrap(self: *VM, v: Value, comptime kind: enum { ok, err, some }) anyerror!Value {
        const inner = try self.a.create(Value);
        inner.* = v;
        return switch (kind) {
            .ok => Value{ .ok = inner },
            .err => Value{ .err = inner },
            .some => Value{ .some = inner },
        };
    }

    // ── Execution ─────────────────────────────────────────────────

    pub fn run(self: *VM, code: []const Instruction, constants: []const Value) anyerror!VMResult {
        self.code = code;
        self.constants = constants;

        if (self.dump_vm) dumpCode(code, constants);

        var ip: usize = 0;
        while (ip < self.code.len) {
            if (self.debug) {
                self.cur_ip = ip;
                if (self.shouldStop(ip)) {
                    if (!try self.debugPrompt(ip)) return .ok; // user quit
                }
            }

            const inst = self.code[ip];
            const line = inst.line;
            var next: usize = ip + 1;

            switch (inst.op) {
                // ---- Stack ----
                .const_ => {
                    const idx = argIndex(inst);
                    if (idx >= self.constants.len) {
                        return self.rt(line, "constant index {d} out of range (have {d})", .{ idx, self.constants.len });
                    }
                    if (!self.push(self.constants[idx])) return .runtime_error;
                },
                .pop => {
                    var count: usize = argIndex(inst);
                    if (count == 0) count = 1;
                    if (self.sp < count) {
                        return self.rt(line, "stack underflow: tried to pop {d} but only {d} values", .{ count, self.sp });
                    }
                    self.sp -= count;
                },
                .dup => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on dup", .{});
                    if (!self.push(self.stack[self.sp - 1])) return .runtime_error;
                },
                .swap => {
                    if (self.sp < 2) return self.rt(line, "stack underflow on swap", .{});
                    const tmp = self.stack[self.sp - 1];
                    self.stack[self.sp - 1] = self.stack[self.sp - 2];
                    self.stack[self.sp - 2] = tmp;
                },

                // ---- Locals ----
                .get_local => {
                    const slot: usize = argIndex(inst);
                    const base = self.frameBase();
                    if (base + slot >= self.sp) {
                        return self.rt(line, "local variable at slot {d} not initialized", .{slot});
                    }
                    if (!self.push(self.stack[base + slot])) return .runtime_error;
                },
                .set_local => {
                    const slot: usize = argIndex(inst);
                    const base = self.frameBase();
                    if (self.sp == 0) return self.rt(line, "stack underflow on set_local", .{});
                    const val = self.pop();
                    // Pad with nil so the target slot exists, matching the seed.
                    while (base + slot >= self.sp) {
                        if (!self.push(bc.vNil())) return .runtime_error;
                    }
                    self.stack[base + slot] = val;
                },

                // ---- Globals ----
                .get_global => {
                    const idx = argIndex(inst);
                    if (idx >= self.constants.len) {
                        return self.rt(line, "global name index {d} out of range", .{idx});
                    }
                    const name = switch (self.constants[idx]) {
                        .string => |s| s,
                        else => "",
                    };
                    if (std.mem.eql(u8, name, "print")) {
                        if (!self.push(bc.vFn(self.builtin_print_fn))) return .runtime_error;
                    } else {
                        var found = false;
                        var i: usize = 0;
                        while (i < self.global_count) : (i += 1) {
                            if (std.mem.eql(u8, self.globals[i].name, name)) {
                                if (!self.push(self.globals[i].value)) return .runtime_error;
                                found = true;
                                break;
                            }
                        }
                        if (!found) return self.rt(line, "undefined global variable '{s}'", .{name});
                    }
                },
                .set_global => {
                    const idx = argIndex(inst);
                    if (idx >= self.constants.len) {
                        return self.rt(line, "global name index {d} out of range", .{idx});
                    }
                    if (self.sp == 0) return self.rt(line, "stack underflow on set_global", .{});
                    const name = switch (self.constants[idx]) {
                        .string => |s| s,
                        else => "",
                    };
                    const val = self.pop();
                    var found = false;
                    var i: usize = 0;
                    while (i < self.global_count) : (i += 1) {
                        if (std.mem.eql(u8, self.globals[i].name, name)) {
                            self.globals[i].value = val;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        if (self.global_count >= VM_MAX_GLOBALS) {
                            return self.rt(line, "too many global variables", .{});
                        }
                        self.globals[self.global_count] = .{ .name = name, .value = val };
                        self.global_count += 1;
                    }
                },

                // ---- Arithmetic ----
                .add => {
                    if (self.sp < 2) return self.rt(line, "stack underflow on add", .{});
                    const b = self.pop();
                    const a = self.pop();
                    if (tag(a) == .string and tag(b) == .string) {
                        const s = try std.mem.concat(self.a, u8, &.{ a.string, b.string });
                        if (!self.push(bc.vString(s))) return .runtime_error;
                    } else if (numOp(a, b, .add)) |v| {
                        if (!self.push(v)) return .runtime_error;
                    } else {
                        return self.rt(line, "cannot add {s} and {s}", .{ typeName(a), typeName(b) });
                    }
                },
                .sub, .mul => {
                    const name = if (inst.op == .sub) "sub" else "mul";
                    if (self.sp < 2) return self.rt(line, "stack underflow on {s}", .{name});
                    const b = self.pop();
                    const a = self.pop();
                    const op: NumOp = if (inst.op == .sub) .sub else .mul;
                    if (numOp(a, b, op)) |v| {
                        if (!self.push(v)) return .runtime_error;
                    } else if (inst.op == .sub) {
                        return self.rt(line, "cannot subtract {s} from {s}", .{ typeName(b), typeName(a) });
                    } else {
                        return self.rt(line, "cannot multiply {s} and {s}", .{ typeName(a), typeName(b) });
                    }
                },
                .div => {
                    if (self.sp < 2) return self.rt(line, "stack underflow on div", .{});
                    const b = self.pop();
                    const a = self.pop();
                    if ((tag(b) == .int and b.int == 0) or (tag(b) == .float and b.float == 0.0)) {
                        return self.rt(line, "division by zero", .{});
                    }
                    const v: ?Value = switch (a) {
                        .int => |x| switch (b) {
                            .int => |y| bc.vInt(@divTrunc(x, y)),
                            .float => |y| bc.vFloat(@as(f64, @floatFromInt(x)) / y),
                            else => null,
                        },
                        .float => |x| switch (b) {
                            .int => |y| bc.vFloat(x / @as(f64, @floatFromInt(y))),
                            .float => |y| bc.vFloat(x / y),
                            else => null,
                        },
                        else => null,
                    };
                    if (v) |val| {
                        if (!self.push(val)) return .runtime_error;
                    } else {
                        return self.rt(line, "cannot divide {s} by {s}", .{ typeName(a), typeName(b) });
                    }
                },
                .mod => {
                    if (self.sp < 2) return self.rt(line, "stack underflow on mod", .{});
                    const b = self.pop();
                    const a = self.pop();
                    if ((tag(b) == .int and b.int == 0) or (tag(b) == .float and b.float == 0.0)) {
                        return self.rt(line, "modulo by zero", .{});
                    }
                    const v: ?Value = switch (a) {
                        .int => |x| switch (b) {
                            .int => |y| bc.vInt(@rem(x, y)),
                            else => null,
                        },
                        .float => |x| switch (b) {
                            .float => |y| bc.vFloat(@rem(x, y)),
                            else => null,
                        },
                        else => null,
                    };
                    if (v) |val| {
                        if (!self.push(val)) return .runtime_error;
                    } else {
                        return self.rt(line, "cannot apply modulo to {s} and {s}", .{ typeName(a), typeName(b) });
                    }
                },
                .neg => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on neg", .{});
                    const a = self.pop();
                    const v: ?Value = switch (a) {
                        .int => |x| bc.vInt(-%x),
                        .float => |x| bc.vFloat(-x),
                        else => null,
                    };
                    if (v) |val| {
                        if (!self.push(val)) return .runtime_error;
                    } else {
                        return self.rt(line, "cannot negate {s}", .{typeName(a)});
                    }
                },

                // ---- Comparison ----
                .eq, .neq => {
                    if (self.sp < 2) return self.rt(line, "stack underflow on {s}", .{if (inst.op == .eq) "eq" else "neq"});
                    const b = self.pop();
                    const a = self.pop();
                    const equal = valueEq(a, b);
                    if (!self.push(bc.vBool(if (inst.op == .eq) equal else !equal))) return .runtime_error;
                },
                .lt, .gt, .le, .ge => {
                    const name = switch (inst.op) {
                        .lt => "lt",
                        .gt => "gt",
                        .le => "le",
                        else => "ge",
                    };
                    if (self.sp < 2) return self.rt(line, "stack underflow on {s}", .{name});
                    const b = self.pop();
                    const a = self.pop();
                    const op: Order = switch (inst.op) {
                        .lt => .lt,
                        .gt => .gt,
                        .le => .le,
                        else => .ge,
                    };
                    if (cmpOp(a, b, op)) |result| {
                        if (!self.push(bc.vBool(result))) return .runtime_error;
                    } else {
                        return self.rt(line, "cannot compare {s} and {s}", .{ typeName(a), typeName(b) });
                    }
                },

                // ---- Logical ----
                .and_, .or_ => {
                    if (self.sp < 2) {
                        return self.rt(line, "stack underflow on {s}", .{if (inst.op == .and_) "and" else "or"});
                    }
                    const b = self.pop();
                    const a = self.pop();
                    const result = if (inst.op == .and_) (isTruthy(a) and isTruthy(b)) else (isTruthy(a) or isTruthy(b));
                    if (!self.push(bc.vBool(result))) return .runtime_error;
                },
                .not => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on not", .{});
                    const a = self.pop();
                    if (!self.push(bc.vBool(!isTruthy(a)))) return .runtime_error;
                },

                // ---- Bitwise ----
                .bit_and, .bit_or, .bit_xor => {
                    const sym = switch (inst.op) {
                        .bit_and => "&",
                        .bit_or => "|",
                        else => "^",
                    };
                    if (self.sp < 2) return self.rt(line, "stack underflow on bitwise {s}", .{sym});
                    const b = self.pop();
                    const a = self.pop();
                    if (tag(a) == .int and tag(b) == .int) {
                        const x = a.int;
                        const y = b.int;
                        const r = switch (inst.op) {
                            .bit_and => x & y,
                            .bit_or => x | y,
                            else => x ^ y,
                        };
                        if (!self.push(bc.vInt(r))) return .runtime_error;
                    } else {
                        return self.rt(line, "bitwise {s} requires integer operands", .{sym});
                    }
                },
                .shl, .shr => {
                    const sym = if (inst.op == .shl) "<<" else ">>";
                    if (self.sp < 2) return self.rt(line, "stack underflow on bitwise {s}", .{sym});
                    const b = self.pop();
                    const a = self.pop();
                    if (tag(a) == .int and tag(b) == .int) {
                        if (b.int < 0 or b.int >= 64) {
                            return self.rt(line, "shift amount out of range (must be 0..63)", .{});
                        }
                        const sh: u6 = @intCast(b.int);
                        const r = if (inst.op == .shl)
                            @as(i64, @bitCast(@as(u64, @bitCast(a.int)) << sh))
                        else
                            a.int >> sh;
                        if (!self.push(bc.vInt(r))) return .runtime_error;
                    } else {
                        return self.rt(line, "bitwise {s} requires integer operands", .{sym});
                    }
                },
                .bit_not => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on bitwise ~", .{});
                    const a = self.pop();
                    if (tag(a) == .int) {
                        if (!self.push(bc.vInt(~a.int))) return .runtime_error;
                    } else {
                        return self.rt(line, "bitwise ~ requires integer operand", .{});
                    }
                },

                // ---- Aggregates ----
                .new_array => {
                    const n: usize = argIndex(inst);
                    if (self.sp < n) return self.rt(line, "stack underflow building array of {d}", .{n});
                    const arr = self.newArray(n) catch return self.rt(line, "out of memory building array", .{});
                    for (0..n) |i| arr.elems[i] = self.stack[self.sp - n + i];
                    self.sp -= n;
                    if (!self.push(.{ .array = arr })) return .runtime_error;
                },
                .index => {
                    if (self.sp < 2) return self.rt(line, "stack underflow on index", .{});
                    const idx = self.pop();
                    const obj = self.pop();
                    if (tag(obj) != .array) return self.rt(line, "cannot index {s}", .{typeName(obj)});
                    if (tag(idx) != .int) return self.rt(line, "array index must be int, got {s}", .{typeName(idx)});
                    const arr = obj.array;
                    if (idx.int < 0 or @as(u64, @intCast(idx.int)) >= arr.len) {
                        return self.rt(line, "index {d} out of bounds (len {d})", .{ idx.int, arr.len });
                    }
                    if (!self.push(arr.elems[@intCast(idx.int)])) return .runtime_error;
                },
                .len => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on len", .{});
                    const obj = self.pop();
                    const n: usize = switch (obj) {
                        .array => |a| a.len,
                        .string => |s| s.len,
                        else => return self.rt(line, "cannot take length of {s}", .{typeName(obj)}),
                    };
                    if (!self.push(bc.vInt(@intCast(n)))) return .runtime_error;
                },
                .new_struct => {
                    const n: usize = argIndex(inst);
                    if (self.sp < n + 1) return self.rt(line, "stack underflow building struct", .{});
                    const def_val = self.stack[self.sp - n - 1];
                    if (tag(def_val) != .struct_def) return self.rt(line, "invalid struct layout on stack", .{});
                    const def = def_val.struct_def;
                    if (n != def.field_names.len) {
                        return self.rt(line, "struct '{s}' expects {d} fields, got {d}", .{ def.name, def.field_names.len, n });
                    }
                    const obj = self.newStruct(def) catch return self.rt(line, "out of memory building struct", .{});
                    for (0..n) |i| obj.fields[i] = self.stack[self.sp - n + i];
                    self.sp -= n + 1;
                    if (!self.push(.{ .struct_ = obj })) return .runtime_error;
                },
                .set_index => {
                    if (self.sp < 3) return self.rt(line, "stack underflow on set_index", .{});
                    const val = self.pop();
                    const idx = self.pop();
                    const obj = self.pop();
                    if (tag(obj) != .array) return self.rt(line, "cannot index {s}", .{typeName(obj)});
                    if (tag(idx) != .int) return self.rt(line, "array index must be int, got {s}", .{typeName(idx)});
                    const arr = obj.array;
                    if (idx.int < 0 or @as(u64, @intCast(idx.int)) >= arr.len) {
                        return self.rt(line, "index {d} out of bounds (len {d})", .{ idx.int, arr.len });
                    }
                    arr.elems[@intCast(idx.int)] = val;
                    if (!self.push(val)) return .runtime_error;
                },
                .set_field, .get_field => {
                    const idx = argIndex(inst);
                    if (idx >= self.constants.len) return self.rt(line, "field name index {d} out of range", .{idx});
                    const field = switch (self.constants[idx]) {
                        .string => |s| s,
                        else => "",
                    };
                    if (inst.op == .set_field) {
                        if (self.sp < 2) return self.rt(line, "stack underflow on set_field", .{});
                        const val = self.pop();
                        const obj = self.pop();
                        if (tag(obj) != .struct_) return self.rt(line, "cannot access field on {s}", .{typeName(obj)});
                        const s = obj.struct_;
                        const d = s.def orelse return self.rt(line, "struct value has no layout", .{});
                        const found = fieldIndex(d, field) orelse
                            return self.rt(line, "struct '{s}' has no field '{s}'", .{ d.name, field });
                        s.fields[found] = val;
                        if (!self.push(val)) return .runtime_error;
                    } else {
                        if (self.sp == 0) return self.rt(line, "stack underflow on get_field", .{});
                        const obj = self.pop();
                        if (tag(obj) != .struct_) return self.rt(line, "cannot access field on {s}", .{typeName(obj)});
                        const s = obj.struct_;
                        const d = s.def orelse return self.rt(line, "struct value has no layout", .{});
                        const found = fieldIndex(d, field) orelse
                            return self.rt(line, "struct '{s}' has no field '{s}'", .{ d.name, field });
                        if (!self.push(s.fields[found])) return .runtime_error;
                    }
                },
                .new_enum => {
                    const operand = argIndex(inst);
                    const n: usize = operand & 0xFFFF;
                    const variant: usize = operand >> 16;
                    if (self.sp < n + 1) return self.rt(line, "stack underflow building enum", .{});
                    const def_val = self.stack[self.sp - n - 1];
                    if (tag(def_val) != .enum_def) return self.rt(line, "invalid enum layout on stack", .{});
                    const def = def_val.enum_def;
                    if (variant >= def.variants.len) {
                        return self.rt(line, "enum '{s}' has no variant {d}", .{ def.name, variant });
                    }
                    const want = def.variants[variant].field_count;
                    if (n != want) {
                        return self.rt(line, "variant '{s}.{s}' expects {d} fields, got {d}", .{
                            def.name,
                            def.variants[variant].name orelse "?",
                            want,
                            n,
                        });
                    }
                    const obj = self.newEnum(def, variant, self.stack[self.sp - n .. self.sp]) catch
                        return self.rt(line, "out of memory building enum", .{});
                    self.sp -= n + 1;
                    if (!self.push(.{ .enum_data = obj })) return .runtime_error;
                },
                .get_enum_field => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on get_enum_field", .{});
                    const obj = self.pop();
                    if (tag(obj) != .enum_data) return self.rt(line, "cannot extract field from {s}", .{typeName(obj)});
                    const eo = obj.enum_data;
                    const fi: usize = argIndex(inst);
                    const nf = if (eo.def) |d|
                        (if (eo.variant < d.variants.len) d.variants[eo.variant].field_count else 0)
                    else
                        0;
                    if (fi >= nf) return self.rt(line, "enum field index {d} out of range (have {d})", .{ fi, nf });
                    if (!self.push(eo.fields[fi])) return .runtime_error;
                },

                // ---- Control flow ----
                .jump => {
                    next = jumpTarget(ip, argOffset(inst)) orelse
                        return self.rt(line, "jump target out of range", .{});
                },
                .jump_if_false, .jump_if_true => {
                    if (self.sp == 0) {
                        return self.rt(line, "stack underflow on {s}", .{if (inst.op == .jump_if_false) "jump_if_false" else "jump_if_true"});
                    }
                    const cond = self.pop();
                    const take = if (inst.op == .jump_if_false) !isTruthy(cond) else isTruthy(cond);
                    if (take) {
                        next = jumpTarget(ip, argOffset(inst)) orelse
                            return self.rt(line, "jump target out of range", .{});
                    }
                },

                // ---- Functions ----
                .call => {
                    const argc: usize = argCount(inst);
                    if (self.sp < argc + 1) return self.rt(line, "not enough arguments on stack for call", .{});
                    const fn_idx = self.sp - 1 - argc;
                    const fn_val = self.stack[fn_idx];
                    if (tag(fn_val) != .fn_) return self.rt(line, "cannot call non-function value", .{});
                    const fn_obj = fn_val.fn_;

                    // Builtin: param_count == 255 and no code.
                    if (fn_obj.param_count == 255 and fn_obj.code.len == 0) {
                        const result = try self.builtinPrint(self.stack[fn_idx + 1 .. fn_idx + 1 + argc]);
                        self.sp = fn_idx;
                        if (!self.push(result)) return .runtime_error;
                    } else {
                        if (argc != fn_obj.param_count) {
                            return self.rt(line, "expected {d} arguments but got {d}", .{ fn_obj.param_count, argc });
                        }
                        if (self.frame_count >= VM_CALL_DEPTH) {
                            // Report the call site: the frame layer only sees line 0.
                            return self.rt(line, "call depth exceeded", .{});
                        }
                        if (self.dump_vm) dumpCall(fn_obj, fn_idx);
                        self.frames[self.frame_count] = .{
                            .ip = ip + 1,
                            .base = fn_idx,
                            .saved_code = self.code,
                            .saved_constants = self.constants,
                        };
                        self.frame_count += 1;
                        self.code = fn_obj.code;
                        self.constants = fn_obj.constants;
                        next = 0;
                    }
                },
                .ret => {
                    var return_val = bc.vNil();
                    if (self.sp > 0) return_val = self.pop();
                    if (self.frame_count == 0) return .ok; // top-level return
                    self.frame_count -= 1;
                    const fr = self.frames[self.frame_count];
                    self.sp = fr.base;
                    self.code = fr.saved_code;
                    self.constants = fr.saved_constants;
                    if (!self.push(return_val)) return .runtime_error;
                    next = fr.ip;
                },

                // ---- I/O ----
                .print => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on print", .{});
                    const val = self.pop();
                    try bc.printValue(self.w, val);
                    try self.w.writeByte('\n');
                },

                // ---- Option/Result ----
                .wrap_ok => {
                    const inner = self.pop();
                    const v = try self.wrap(inner, .ok);
                    if (!self.push(v)) return .runtime_error;
                },
                .wrap_err => {
                    const inner = self.pop();
                    const v = try self.wrap(inner, .err);
                    if (!self.push(v)) return .runtime_error;
                },
                .wrap_some => {
                    const inner = self.pop();
                    const v = try self.wrap(inner, .some);
                    if (!self.push(v)) return .runtime_error;
                },
                .try_unwrap => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on try unwrap", .{});
                    const val = self.stack[self.sp - 1];
                    switch (val) {
                        .ok => self.stack[self.sp - 1] = val.ok.*,
                        .some => self.stack[self.sp - 1] = val.some.*,
                        .err, .nil => {
                            if (self.frame_count == 0) {
                                return self.rt(line, "try operator outside function", .{});
                            }
                            self.frame_count -= 1;
                            const fr = self.frames[self.frame_count];
                            self.sp = fr.base;
                            self.code = fr.saved_code;
                            self.constants = fr.saved_constants;
                            if (!self.push(val)) return .runtime_error;
                            next = fr.ip;
                        },
                        else => return self.rt(line, "? operator requires Result or Option, got {s}", .{typeName(val)}),
                    }
                },

                // ---- Special ----
                .halt => return .ok,
                .tag_is => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on tag_is", .{});
                    const val = self.stack[self.sp - 1];
                    const t = argIndex(inst);
                    const matched = switch (t) {
                        0 => tag(val) == .ok,
                        1 => tag(val) == .err,
                        2 => tag(val) == .some,
                        3 => tag(val) == .nil,
                        else => false,
                    };
                    self.stack[self.sp - 1] = bc.vBool(matched);
                },
                .unwrap => {
                    if (self.sp == 0) return self.rt(line, "stack underflow on unwrap", .{});
                    const val = self.stack[self.sp - 1];
                    self.stack[self.sp - 1] = switch (val) {
                        .ok => val.ok.*,
                        .err => val.err.*,
                        .some => val.some.*,
                        else => return self.rt(line, "unwrap requires ok, err, or some, got {s}", .{typeName(val)}),
                    };
                },
            }

            if (self.trace) self.traceState();
            ip = next;
        }

        return .ok;
    }

    /// `builtin_print`: space-separated values, then a newline. Returns nil.
    fn builtinPrint(self: *VM, args: []const Value) !Value {
        for (args, 0..) |arg, i| {
            if (i > 0) try self.w.writeByte(' ');
            try bc.printValue(self.w, arg);
        }
        try self.w.writeByte('\n');
        return bc.vNil();
    }
};

fn fieldIndex(def: *const StructDef, field: []const u8) ?usize {
    for (def.field_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, field)) return i;
    }
    return null;
}

/// Resolve a jump's absolute target: `P + offset`. Returns null only when the
/// result is negative (never for emitter-produced code) so the caller can emit
/// a diagnostic instead of a panic.
fn jumpTarget(ip: usize, offset: i32) ?usize {
    const target = @as(i64, @intCast(ip)) + offset;
    if (target < 0) return null;
    return @intCast(target);
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const ast_mod = @import("../ast/ast.zig");
const parser_mod = @import("../parser/parser.zig");
const typechecker_mod = @import("../typechecker/typechecker.zig");
const emitter_mod = @import("../emitter/emitter.zig");

const RunOut = struct { res: VMResult, out: []const u8, err: []const u8, dbg: []const u8 = "" };

/// Compile `source` and run it, capturing stdout into `buf`.
fn runSource(a: std.mem.Allocator, source: []const u8, buf: []u8) !RunOut {
    var tree = ast_mod.Tree.init(a, source);
    var p = parser_mod.Parser.init(a, source, &tree);
    const root = try p.parse();
    var tc = try typechecker_mod.TypeChecker.init(a, &tree, "test.astra");
    tc.check(root);
    try testing.expectEqual(@as(usize, 0), tc.error_count);
    var em = emitter_mod.Emitter.init(a, &tree, "test.astra");
    em.emit(root);
    try testing.expectEqual(@as(usize, 0), em.error_count);
    var w = std.Io.Writer.fixed(buf);
    var machine = try VM.init(a, &w);
    const res = try machine.run(em.code.items, em.constants.items);
    return .{ .res = res, .out = w.buffered(), .err = machine.error_msg };
}

test "runs a program and prints its output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    const r = try runSource(arena.allocator(),
        \\fn main() {
        \\    print(2 + 3 * 4);
        \\    print("hi");
        \\}
    , &buf);
    try testing.expectEqual(VMResult.ok, r.res);
    try testing.expectEqualStrings("14\nhi\n", r.out);
}

test "runs recursion and string concatenation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    const r = try runSource(arena.allocator(),
        \\fn fact(n: i32) -> i32 {
        \\    if n <= 1 { return 1 }
        \\    return n * fact(n - 1)
        \\}
        \\fn main() {
        \\    print("fact=" + "120");
        \\    print(fact(5));
        \\}
    , &buf);
    try testing.expectEqual(VMResult.ok, r.res);
    try testing.expectEqualStrings("fact=120\n120\n", r.out);
}

/// Like `runSource`, but drives the interactive debugger from `commands` and
/// captures debugger output into `dbg_buf`.
fn runDebug(a: std.mem.Allocator, source: []const u8, out_buf: []u8, dbg_buf: []u8, commands: []const u8) !RunOut {
    var tree = ast_mod.Tree.init(a, source);
    var p = parser_mod.Parser.init(a, source, &tree);
    const root = try p.parse();
    var tc = try typechecker_mod.TypeChecker.init(a, &tree, "test.astra");
    tc.check(root);
    try testing.expectEqual(@as(usize, 0), tc.error_count);
    var em = emitter_mod.Emitter.init(a, &tree, "test.astra");
    em.emit(root);
    try testing.expectEqual(@as(usize, 0), em.error_count);
    var w = std.Io.Writer.fixed(out_buf);
    var machine = try VM.init(a, &w);
    var rdr = std.Io.Reader.fixed(commands);
    var dw = std.Io.Writer.fixed(dbg_buf);
    machine.enableDebug(&rdr, source);
    machine.dbg_out = &dw;
    const res = try machine.run(em.code.items, em.constants.items);
    return .{ .res = res, .out = w.buffered(), .err = machine.error_msg, .dbg = dw.buffered() };
}

test "debugger continue runs the program normally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var dbg_buf: [8192]u8 = undefined;
    const source =
        \\fn main() {
        \\    print(1 + 1)
        \\}
    ;
    const r = try runDebug(arena.allocator(), source, &out_buf, &dbg_buf, "c\n");
    try testing.expectEqual(VMResult.ok, r.res);
    try testing.expectEqualStrings("2\n", r.out);
}

test "debugger stops at a breakpoint before running the statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var dbg_buf: [8192]u8 = undefined;
    const source =
        \\fn main() {
        \\    print(1 + 1)
        \\}
    ;
    const r = try runDebug(arena.allocator(), source, &out_buf, &dbg_buf, "b 2\nc\nq\n");
    try testing.expectEqual(VMResult.ok, r.res);
    try testing.expectEqualStrings("", r.out); // stopped before the print
    try testing.expect(std.mem.indexOf(u8, r.dbg, "breakpoint set on line 2") != null);
    try testing.expect(std.mem.indexOf(u8, r.dbg, "line 2:     print(1 + 1)") != null);
}

test "debugger quit ends the program early" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var dbg_buf: [8192]u8 = undefined;
    const source =
        \\fn main() {
        \\    print("never")
        \\}
    ;
    const r = try runDebug(arena.allocator(), source, &out_buf, &dbg_buf, "q\n");
    try testing.expectEqual(VMResult.ok, r.res);
    try testing.expectEqualStrings("", r.out);
}

test "reports an out-of-bounds index as a runtime error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    const r = try runSource(arena.allocator(),
        \\fn main() {
        \\    let a = [1, 2, 3]
        \\    print(a[5])
        \\}
    , &buf);
    try testing.expectEqual(VMResult.runtime_error, r.res);
    try testing.expect(std.mem.indexOf(u8, r.err, "index 5 out of bounds (len 3)") != null);
}
