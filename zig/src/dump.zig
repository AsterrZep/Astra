//! Byte-parity dump helpers for the introspection flags (PHASE2 §4 #6).
//!
//! `--dump-tokens` must print EXACTLY what `seed/astra-seed --dump-tokens`
//! prints — the parity gate (`tests/dump_parity.sh`) diffs both streams —
//! so every format quirk of the seed's `token_print` lives here:
//!
//!   printf("%u:%u  %-14s", line, col, kind_name);
//!   [INT: "  %ld"] [FLOAT: "  %g"] [STRING/IDENT: "  \"%.*s\""] "\n"
//!
//! Note the trailing spaces: kinds without a value end right after the
//! 14-wide name field, and FLOAT uses C's `%g` (6 significant digits,
//! e-style when the exponent is < -4 or >= 6), not Zig's `{d}`.

const std = @import("std");
const lexer = @import("lexer/lexer.zig");

/// One `--dump-tokens` line, seed format included (padding, quoting, `%g`).
pub fn printToken(writer: anytype, t: lexer.Token) !void {
    try writer.print("{d}:{d}  ", .{ t.loc.line, t.loc.col });
    try writer.print("{s:<14}", .{t.tag.seedName()});
    switch (t.tag) {
        .int_literal => try writer.print("  {d}", .{t.int_val}),
        .float_literal => {
            try writer.writeAll("  ");
            try writeG(writer, t.float_val);
        },
        .string_literal, .identifier => try writer.print("  \"{s}\"", .{t.text}),
        else => {},
    }
    try writer.writeByte('\n');
}

/// C `printf("%g")`: at most 6 significant digits, trailing zeros stripped,
/// `%e` style when the decimal exponent is < -4 or >= 6, exponent signed
/// with at least two digits. Values verified against gcc's `%g` (see
/// PHASE2 #6): 1.5→`1.5`, 1e20→`1e+20`, 1.2345e-5→`1.2345e-05`,
/// 1234567→`1.23457e+06`, 999999.5→`1e+06`, 0.0001→`0.0001`,
/// 0.00001→`1e-05`, 3.14159265358979→`3.14159`.
pub fn writeG(writer: anytype, x: f64) !void {
    if (std.math.isNan(x)) {
        // C prints `nan` / `-nan` following the sign bit.
        try writer.writeAll(if (std.math.signbit(x)) "-nan" else "nan");
        return;
    }
    if (std.math.isInf(x)) {
        try writer.writeAll(if (x < 0) "-inf" else "inf");
        return;
    }
    const neg = std.math.signbit(x);
    if (x == 0) {
        try writer.writeAll(if (neg) "-0" else "0");
        return;
    }

    // Shortest round-trip decimal form, all-decimal (Zig `{d}` never switches
    // to exponent style), then re-round to %g's 6 significant digits.
    var sbuf: [512]u8 = undefined;
    const s = try std.fmt.bufPrint(&sbuf, "{d}", .{@abs(x)});

    // Digits: strip the point, remember how many digits sat before it, then
    // drop leading zeros. value = 0.<ds> * 10^(exp+1), ds[0] != '0'.
    var ds: [512]u8 = undefined;
    var n: usize = 0;
    var int_len: usize = 0;
    var in_frac = false;
    for (s) |c| {
        if (c == '.') {
            in_frac = true;
        } else {
            if (!in_frac) int_len += 1;
            ds[n] = c;
            n += 1;
        }
    }
    var lz: usize = 0;
    while (lz < n and ds[lz] == '0') lz += 1;
    if (lz == n) {
        // Only reachable for values whose shortest form is all zeros, which
        // `x == 0` above already handled.
        try writer.writeAll("0");
        return;
    }
    var exp: i32 = @as(i32, @intCast(int_len)) - @as(i32, @intCast(lz)) - 1;
    n -= lz;
    std.mem.copyForwards(u8, ds[0..n], ds[lz..lz + n]);

    // Round to 6 significant digits, half-even on the 7th (C's rule for the
    // exact value; the shortest form determines the same decision for every
    // value the lexer can produce from a decimal/hex literal).
    if (n > 6) {
        const seventh = ds[6];
        var round_up = false;
        if (seventh > '5') {
            round_up = true;
        } else if (seventh == '5') {
            const sixth = ds[5];
            round_up = (sixth - '0') % 2 == 1;
        }
        n = 6;
        if (round_up) {
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                if (ds[i] == '9') {
                    ds[i] = '0';
                } else {
                    ds[i] += 1;
                    break;
                }
            }
            // Carry off the front: 999999.5 -> 1000000 -> 1.00000e6.
            if (ds[0] == '0') {
                ds[0] = '1';
                exp += 1;
            }
        }
    }
    // Trailing zeros carry no information.
    while (n > 1 and ds[n - 1] == '0') n -= 1;

    if (neg) try writer.writeByte('-');

    if (exp < -4 or exp >= 6) {
        // e-style: d[.ddd]e[+-]NN, exponent always >= 2 digits.
        try writer.writeByte(ds[0]);
        if (n > 1) try writer.print(".{s}", .{ds[1..n]});
        try writer.writeByte('e');
        if (exp < 0) {
            try writer.writeByte('-');
        } else {
            try writer.writeByte('+');
        }
        const aexp: u32 = @abs(exp);
        if (aexp < 10) {
            try writer.print("0{d}", .{aexp});
        } else {
            try writer.print("{d}", .{aexp});
        }
    } else if (exp >= 0) {
        // f-style with the point inside or just past the digits.
        const ipart_len: usize = @intCast(exp + 1);
        if (n <= ipart_len) {
            try writer.writeAll(ds[0..n]);
            var i: usize = n;
            while (i < ipart_len) : (i += 1) try writer.writeByte('0');
        } else {
            try writer.writeAll(ds[0..ipart_len]);
            try writer.writeByte('.');
            try writer.writeAll(ds[ipart_len..n]);
        }
    } else {
        // Negative exponent, not low enough for e-style: 0.000ddd.
        try writer.writeAll("0.");
        var i: i32 = -1;
        while (i > exp) : (i -= 1) try writer.writeByte('0');
        try writer.writeAll(ds[0..n]);
    }
}

const testing = std.testing;

// Every expectation below is gcc's actual `%g` output for the same double.
test "writeG matches C printf %g" {
    const Case = struct { x: f64, want: []const u8 };
    const cases = [_]Case{
        .{ .x = 1.5, .want = "1.5" },
        .{ .x = 1e20, .want = "1e+20" },
        .{ .x = 1.2345e-5, .want = "1.2345e-05" },
        .{ .x = 1.23457, .want = "1.23457" },
        .{ .x = 1234567.0, .want = "1.23457e+06" },
        .{ .x = 100000.0, .want = "100000" },
        .{ .x = 0.0, .want = "0" },
        .{ .x = 0.1, .want = "0.1" },
        .{ .x = 1e-10, .want = "1e-10" },
        .{ .x = 2.5, .want = "2.5" },
        .{ .x = 999999.5, .want = "1e+06" },
        .{ .x = 1e6, .want = "1e+06" },
        .{ .x = 0.0001, .want = "0.0001" },
        .{ .x = 0.00001, .want = "1e-05" },
        .{ .x = 3.14159265358979, .want = "3.14159" },
        .{ .x = 1e300, .want = "1e+300" },
        .{ .x = 2.2250738585072014e-308, .want = "2.22507e-308" },
        .{ .x = -0.0, .want = "-0" },
        .{ .x = -1.5, .want = "-1.5" },
        .{ .x = std.math.inf(f64), .want = "inf" },
        .{ .x = -std.math.inf(f64), .want = "-inf" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeG(&w, c.x);
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}

test "printToken matches the seed's token_print format" {
    const t = lexer.Token{
        .tag = .identifier,
        .loc = .{ .line = 5, .col = 4, .start = 0, .end = 0 },
        .text = "main",
    };
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printToken(&w, t);
    try testing.expectEqualStrings("5:4  IDENT           \"main\"\n", w.buffered());
}
