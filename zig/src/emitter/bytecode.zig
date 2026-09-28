//! Astra-0 bytecode model (Phase 2, Zig).
//!
//! Opcodes, instructions and runtime values mirror `seed/include/astra/astra.h`
//! §14/§16 and the constructors in `seed/src/vm.c`. The dump format is copied
//! from `vm_dump_bytecode` so the two compilers can be compared.

const std = @import("std");

pub const OpCode = enum(u8) {
    // Stack
    const_,
    pop,
    dup,
    swap,

    // Locals / globals
    get_local,
    set_local,
    get_global,
    set_global,

    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    neg,

    // Comparison
    eq,
    neq,
    lt,
    gt,
    le,
    ge,

    // Logical
    and_,
    or_,
    not,

    // Bitwise
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    bit_not,

    // Control flow
    jump,
    jump_if_false,
    jump_if_true,

    // Aggregates
    new_array,
    index,
    len,
    new_struct,
    get_field,
    set_index,
    set_field,
    new_enum,
    get_enum_field,

    // Functions
    call,
    ret,

    // I/O
    print,

    // Option/Result
    wrap_ok,
    wrap_err,
    wrap_some,

    // Special
    halt,
    try_unwrap,
    tag_is,
    unwrap,

    /// Name as printed by `--dump-bytecode` (seed `opname()`).
    pub fn name(self: OpCode) []const u8 {
        return switch (self) {
            .const_ => "CONST",
            .pop => "POP",
            .dup => "DUP",
            .swap => "SWAP",
            .get_local => "GET_LOCAL",
            .set_local => "SET_LOCAL",
            .get_global => "GET_GLOBAL",
            .set_global => "SET_GLOBAL",
            .add => "ADD",
            .sub => "SUB",
            .mul => "MUL",
            .div => "DIV",
            .mod => "MOD",
            .neg => "NEG",
            .eq => "EQ",
            .neq => "NEQ",
            .lt => "LT",
            .gt => "GT",
            .le => "LE",
            .ge => "GE",
            .and_ => "AND",
            .or_ => "OR",
            .not => "NOT",
            .bit_and => "BIT_AND",
            .bit_or => "BIT_OR",
            .bit_xor => "BIT_XOR",
            .shl => "SHL",
            .shr => "SHR",
            .bit_not => "BIT_NOT",
            .jump => "JUMP",
            .jump_if_false => "JUMP_IF_FALSE",
            .jump_if_true => "JUMP_IF_TRUE",
            .new_array => "NEW_ARRAY",
            .index => "INDEX",
            .len => "LEN",
            .new_struct => "NEW_STRUCT",
            .get_field => "GET_FIELD",
            .set_index => "SET_INDEX",
            .set_field => "SET_FIELD",
            .new_enum => "NEW_ENUM",
            .get_enum_field => "GET_ENUM_FIELD",
            .call => "CALL",
            .ret => "RET",
            .print => "PRINT",
            .wrap_ok => "WRAP_OK",
            .wrap_err => "WRAP_ERR",
            .wrap_some => "WRAP_SOME",
            .halt => "HALT",
            .try_unwrap => "TRY_UNWRAP",
            .tag_is => "TAG_IS",
            .unwrap => "UNWRAP",
        };
    }

    /// Net effect on the VM stack height, checked against `vm.c`. The operand
    /// matters for POP, NEW_ARRAY, NEW_STRUCT and CALL.
    pub fn stackEffect(self: OpCode, operand: u32) i32 {
        return switch (self) {
            .const_, .dup, .get_local, .get_global => 1,
            .pop => -@as(i32, @intCast(if (operand != 0) operand else 1)),
            .set_local, .set_global, .jump_if_false, .jump_if_true, .index, .print, .add, .sub, .mul, .div, .mod, .eq, .neq, .lt, .gt, .le, .ge, .and_, .or_, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ret => -1,
            .new_array => 1 - @as(i32, @intCast(operand)),
            .new_struct, .call => -@as(i32, @intCast(operand)),
            .swap, .neg, .not, .bit_not, .len, .get_field, .jump, .halt => 0,
            .set_field => -1,
            .set_index => -2,
            .get_enum_field, .try_unwrap, .wrap_ok, .wrap_err, .wrap_some, .tag_is, .unwrap => 0,
            .new_enum => 1,
        };
    }
};

pub const Arg = union(enum) {
    index: u32,
    offset: i32,
    arg_count: u8,
    none: void,
};

pub const Instruction = struct {
    op: OpCode,
    line: u32 = 0,
    arg: Arg = .{ .none = {} },
};

// ── Runtime values (compile-time constants) ──────────────────────────

pub const ArrayObj = struct { elems: []Value, len: usize };
pub const StructDef = struct { name: []const u8, field_names: []const []const u8 };
pub const StructObj = struct { def: ?*const StructDef, fields: []Value };
pub const VariantDef = struct {
    name: ?[]const u8 = null,
    field_names: []const []const u8 = &.{},
    field_count: usize = 0,
};
pub const EnumDef = struct { name: []const u8, variants: []VariantDef };
pub const EnumObj = struct { def: ?*const EnumDef, variant: usize, fields: []Value };
pub const FnObj = struct {
    code: []Instruction,
    constants: []Value,
    param_count: u8 = 0,
    local_count: u8 = 0,
};

pub const Kind = enum {
    nil,
    bool_,
    int,
    float,
    string,
    array,
    struct_,
    struct_def,
    enum_,
    enum_data,
    enum_def,
    fn_,
    ok,
    err,
    some,

    /// Runtime type name (seed `type_name`).
    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .nil => "nil",
            .bool_ => "bool",
            .int => "int",
            .float => "float",
            .string => "string",
            .array => "array",
            .struct_ => "struct",
            .struct_def => "struct_def",
            .enum_, .enum_data => "enum",
            .enum_def => "enum_def",
            .fn_ => "function",
            .ok => "ok",
            .err => "err",
            .some => "some",
        };
    }
};

pub const Value = union(Kind) {
    nil: void,
    bool_: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: *ArrayObj,
    struct_: *StructObj,
    struct_def: *StructDef,
    enum_: struct { enum_name: []const u8, variant_name: []const u8 },
    enum_data: *EnumObj,
    enum_def: *EnumDef,
    fn_: *FnObj,
    ok: *Value,
    err: *Value,
    some: *Value,
};

pub fn vNil() Value {
    return .{ .nil = {} };
}
pub fn vBool(b: bool) Value {
    return .{ .bool_ = b };
}
pub fn vInt(i: i64) Value {
    return .{ .int = i };
}
pub fn vFloat(f: f64) Value {
    return .{ .float = f };
}
pub fn vString(s: []const u8) Value {
    return .{ .string = s };
}
pub fn vStructDef(d: *StructDef) Value {
    return .{ .struct_def = d };
}
pub fn vEnum(enum_name: []const u8, variant_name: []const u8) Value {
    return .{ .enum_ = .{ .enum_name = enum_name, .variant_name = variant_name } };
}
pub fn vEnumDef(d: *EnumDef) Value {
    return .{ .enum_def = d };
}
pub fn vFn(f: *FnObj) Value {
    return .{ .fn_ = f };
}

/// Strip trailing zeros (and a bare trailing '.') from an already-rendered
/// decimal mantissa. `"1.50000"` -> `"1.5"`, `"1.00000"` -> `"1"`, `"-0.0"`
/// -> `"-0"`. Only the fractional part is touched: a value with no '.' (an
/// integer literal) is returned untouched.
fn stripDecZeros(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

/// C's `printf("%g", v)` with the default precision (6). The seed prints every
/// float through `value_print`, which uses `%g`, so matching it here keeps the
/// VM, the bytecode dump and the C backend byte-identical on float output.
///
/// Zig's own `{}`/`{d}` float formatting is shortest-round-trip, not `%g`: for
/// `3.14159265358979` it prints all digits where C prints `3.14159`, and it
/// never switches to scientific notation. The rule is C99 §7.21.6.1: format
/// with style `e` to find the rounded exponent `X`; if `-4 <= X < P` use style
/// `f` with `P-1-X` fraction digits, otherwise style `e` with `P-1` digits.
/// Trailing zeros are then removed from both.
fn writeFloatG(writer: anytype, v: f64, precision: usize) !void {
    if (std.math.isNan(v)) return writer.writeAll("nan");
    if (std.math.isInf(v)) return writer.writeAll(if (v < 0) "-inf" else "inf");

    var ebuf: [64]u8 = undefined;
    const sci = try std.fmt.bufPrint(&ebuf, "{e:.[1]}", .{ v, precision - 1 });
    const epos = std.mem.indexOfScalar(u8, sci, 'e').?;
    const exp = try std.fmt.parseInt(i32, sci[epos + 1 ..], 10);

    if (exp >= -4 and exp < @as(i32, @intCast(precision))) {
        const dec: usize = @intCast(@as(i32, @intCast(precision)) - 1 - exp);
        var fbuf: [512]u8 = undefined;
        const fixed = try std.fmt.bufPrint(&fbuf, "{d:.[1]}", .{ v, dec });
        try writer.writeAll(stripDecZeros(fixed));
    } else {
        try writer.writeAll(stripDecZeros(sci[0..epos]));
        try writer.print("e{s}{d:0>2}", .{ if (exp < 0) "-" else "+", @abs(exp) });
    }
}

/// `value_print` (seed/src/vm.c): the textual form used inside a bytecode dump.
pub fn printValue(writer: anytype, v: Value) anyerror!void {
    switch (v) {
        .nil => try writer.writeAll("nil"),
        .bool_ => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writeFloatG(writer, f, 6),
        .string => |s| try writer.writeAll(s),
        .array => |a| {
            try writer.writeByte('[');
            var i: usize = 0;
            while (i < a.len) : (i += 1) {
                if (i > 0) try writer.writeAll(", ");
                try printValue(writer, a.elems[i]);
            }
            try writer.writeByte(']');
        },
        .struct_ => |s| {
            if (s.def) |d| {
                try writer.print("{s} {{ ", .{d.name});
                for (d.field_names, 0..) |fn_, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{s}: ", .{fn_});
                    try printValue(writer, s.fields[i]);
                }
                try writer.writeAll(" }");
            } else try writer.writeAll("<struct>");
        },
        .struct_def => try writer.writeAll("<struct_def>"),
        .enum_ => |e| try writer.print("{s}.{s}", .{ e.enum_name, e.variant_name }),
        .enum_data => |o| {
            if (o.def) |d| {
                try writer.print("{s}.{s}", .{ d.name, if (o.variant < d.variants.len) d.variants[o.variant].name orelse "?" else "?" });
                const nf = if (o.variant < d.variants.len) d.variants[o.variant].field_count else 0;
                if (nf >= 1) {
                    try writer.writeByte('(');
                    var i: usize = 0;
                    while (i < nf) : (i += 1) {
                        if (i > 0) try writer.writeAll(", ");
                        try printValue(writer, o.fields[i]);
                    }
                    try writer.writeByte(')');
                }
            } else try writer.writeAll("<enum>");
        },
        .enum_def => try writer.writeAll("<enum_def>"),
        .fn_ => try writer.writeAll("<fn>"),
        .ok => |p| {
            try writer.writeAll("ok(");
            try printValue(writer, p.*);
            try writer.writeByte(')');
        },
        .err => |p| {
            try writer.writeAll("err(");
            try printValue(writer, p.*);
            try writer.writeByte(')');
        },
        .some => |p| {
            try writer.writeAll("some(");
            try printValue(writer, p.*);
            try writer.writeByte(')');
        },
    }
}

/// `vm_dump_bytecode` (seed/src/vm.c). Note the seed writes the surrounding
/// lines to stderr but the constant values through `value_print` to stdout;
/// this renders everything to the given writer, which the caller decides how
/// to present.
pub fn dump(writer: anytype, code: []const Instruction, constants: []const Value) anyerror!void {
    try writer.print("=== Bytecode ({d} instructions, {d} constants) ===\n", .{ code.len, constants.len });
    for (code, 0..) |inst, i| {
        try writer.print("  [{d: >3}] {s: <16}", .{ i, inst.op.name() });
        switch (inst.op) {
            .const_, .get_global, .set_global => {
                try writer.print(" {d}", .{inst.arg.index});
                if (inst.op == .const_ and inst.arg.index < constants.len) {
                    try writer.writeAll(" (");
                    try printValue(writer, constants[inst.arg.index]);
                    try writer.writeByte(')');
                }
            },
            .get_local, .set_local => try writer.print(" slot={d}", .{inst.arg.index}),
            .call => try writer.print(" argc={d}", .{inst.arg.arg_count}),
            .jump, .jump_if_false, .jump_if_true => try writer.print(" offset={d}", .{inst.arg.offset}),
            else => {},
        }
        try writer.writeByte('\n');
    }
    try writer.writeAll("=== End bytecode ===\n");
}

const testing = std.testing;

test "opcode stack effects" {
    try testing.expectEqual(@as(i32, -1), OpCode.add.stackEffect(0));
    try testing.expectEqual(@as(i32, 1), OpCode.const_.stackEffect(0));
    try testing.expectEqual(@as(i32, -2), OpCode.new_array.stackEffect(3));
    try testing.expectEqual(@as(i32, -3), OpCode.new_struct.stackEffect(3));
    try testing.expectEqual(@as(i32, -2), OpCode.call.stackEffect(2));
}

test "float formatting matches C %g" {
    const cases = [_]struct { v: f64, want: []const u8 }{
        .{ .v = 1.5, .want = "1.5" },
        .{ .v = -1.5, .want = "-1.5" },
        .{ .v = 5.0, .want = "5" },
        .{ .v = 0.5, .want = "0.5" },
        .{ .v = 1e20, .want = "1e+20" },
        .{ .v = 0.0001, .want = "0.0001" },
        .{ .v = 3.14159265358979, .want = "3.14159" },
        .{ .v = 1234567.0, .want = "1.23457e+06" },
        .{ .v = 0.0, .want = "0" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeFloatG(&w, c.v, 6);
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}

test "bytecode dump format" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const code = [_]Instruction{
        .{ .op = .const_, .line = 1, .arg = .{ .index = 0 } },
        .{ .op = .halt, .line = 1 },
    };
    const consts = [_]Value{vInt(42)};
    try dump(&w, &code, &consts);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "[  0] CONST            0 (42)") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "=== End bytecode ===") != null);
}
