//! One sink for every compiler diagnostic.
//!
//! Each phase used to print its own message in its own format: the parser
//! wrote `error:3:1: …` with no file at all (unusable in a multi-module
//! build), the type checker wrote `file:3:1: error: …`, the emitter embedded
//! `error: …` inside its own format strings, the loader invented a third
//! shape. `Diagnostic{file, span, msg}` is the single record, `format` the
//! single formatter, and `Sink` where a whole compilation's diagnostics
//! accumulate.
//!
//! Phases report through `emit`: with a sink wired they are recorded (and
//! echoed to stderr, the CLI's behaviour); without one they go straight
//! through the same formatter, so unit tests and the conformance runner need
//! no wiring at all.

const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("lexer/lexer.zig");

/// Audit §6.6: in a *test* build the unwired diagnostic path (`emit(null, …)`,
/// a phase with no `Sink`) is dropped instead of echoed to stderr. The zig
/// build runner renders failure-style formatting for any step with a
/// non-empty `result_stderr`, so a green `zig build test` whose unit tests
/// printed their own *expected* errors still showed a misleading
/// `failed command: …/test --listen=-`. Tests that need the messages wire a
/// `Sink` (`echo = false`, read `items`); flip this to `false` temporarily to
/// see the unwired ones again while debugging. The CLI build is unaffected —
/// `builtin.is_test` is false for the executable.
pub var quiet_in_tests: bool = true;

/// A single compiler diagnostic. `span` carries what the reporting phase
/// actually knows: the parser and the type checker have a full `Loc`, the
/// emitter only an instruction line (`col` stays 0), the loader just a file
/// (`line` stays 0).
pub const Diagnostic = struct {
    file: []const u8,
    span: lexer.Loc,
    msg: []const u8,
};

/// A span that says "no location": loader- and driver-level reports.
pub const no_span = lexer.Loc{ .start = 0, .end = 0, .line = 0, .col = 0 };

/// Where a compilation's diagnostics accumulate. Owned by the driver (or by
/// a test); phases hold an optional pointer to it.
///
/// `a` must be an arena (the compilation arena): recorded messages are
/// arena-owned and released in bulk with it. `deinit` tears down only the
/// list and is optional under an arena.
pub const Sink = struct {
    a: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Diagnostic) = .empty,
    /// Print each diagnostic as it is recorded (the CLI's behaviour —
    /// messages reach stderr as they are found). Tests turn this off and
    /// read `items` instead.
    echo: bool = true,

    pub fn init(a: std.mem.Allocator) Sink {
        return .{ .a = a };
    }

    pub fn deinit(self: *Sink) void {
        self.items.deinit(self.a);
    }

    pub fn count(self: *const Sink) usize {
        return self.items.items.len;
    }

    pub fn add(self: *Sink, file: []const u8, span: lexer.Loc, comptime fmt: []const u8, args: anytype) void {
        // OOM while formatting a diagnostic is not worth dying for: a fixed
        // fallback message keeps the report (and its location) alive.
        const msg = std.fmt.allocPrint(self.a, fmt, args) catch "diagnostic (out of memory)";
        self.items.append(self.a, .{ .file = file, .span = span, .msg = msg }) catch {
            // Losing the record is bad enough; losing the diagnostic too
            // would be worse — print it even when `echo` is off.
            printOne(file, span, msg);
            return;
        };
        if (self.echo) printOne(file, span, msg);
    }
};

/// Report one diagnostic: into `sink` when one is wired (recorded + echoed),
/// straight through the same formatter when not.
pub fn emit(sink: ?*Sink, file: []const u8, span: lexer.Loc, comptime fmt: []const u8, args: anytype) void {
    if (sink) |s| {
        s.add(file, span, fmt, args);
        return;
    }
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "diagnostic (message too long)";
    printOne(file, span, msg);
}

/// The one diagnostic format: `file:line:col: error: msg`, degrading to
/// `file:line: error: msg`, `file: error: msg` and `error: msg` as location
/// information runs out. Writes what fits and truncates the tail rather than
/// dropping the location.
pub fn format(buf: []u8, file: []const u8, span: lexer.Loc, msg: []const u8) []u8 {
    var w = std.Io.Writer.fixed(buf);
    if (file.len > 0) w.print("{s}:", .{file}) catch {};
    if (span.line > 0) {
        if (span.col > 0) {
            w.print("{d}:{d}: ", .{ span.line, span.col }) catch {};
        } else {
            w.print("{d}: ", .{span.line}) catch {};
        }
    } else if (file.len > 0) {
        // `file: error: msg` — the colon after the file still needs its space.
        w.print(" ", .{}) catch {};
    }
    w.print("error: {s}", .{msg}) catch {};
    return w.buffered();
}

fn printOne(file: []const u8, span: lexer.Loc, msg: []const u8) void {
    if (builtin.is_test and quiet_in_tests) return;
    var buf: [4096]u8 = undefined;
    std.debug.print("{s}\n", .{format(&buf, file, span, msg)});
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn loc(line: u32, col: u32) lexer.Loc {
    return .{ .start = 0, .end = 0, .line = line, .col = col };
}

test "format degrades as location information runs out" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "mod.astra:3:5: error: expected ;",
        format(&buf, "mod.astra", loc(3, 5), "expected ;"),
    );
    // The emitter knows a line but no column.
    try testing.expectEqualStrings(
        "mod.astra:3: error: too many locals (max 256)",
        format(&buf, "mod.astra", loc(3, 0), "too many locals (max 256)"),
    );
    // The loader knows a file but no line.
    try testing.expectEqualStrings(
        "dep.astra: error: cannot read: FileNotFound",
        format(&buf, "dep.astra", no_span, "cannot read: FileNotFound"),
    );
    // No file, no line: a bare driver message.
    try testing.expectEqualStrings(
        "error: unknown flag --wat",
        format(&buf, "", no_span, "unknown flag --wat"),
    );
    // A line without a file still shows the position.
    try testing.expectEqualStrings(
        "3:1: error: nesting too deep (max 256)",
        format(&buf, "", loc(3, 1), "nesting too deep (max 256)"),
    );
}

test "format truncates the tail instead of losing the location" {
    var buf: [32]u8 = undefined;
    const out = format(&buf, "some/long/file.astra", loc(10, 2), "a very long message that will not fit");
    try testing.expect(std.mem.startsWith(u8, out, "some/long/file.astra:10:2: error"));
    try testing.expect(out.len <= buf.len);
}

test "a sink records diagnostics for the caller" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sink = Sink.init(arena.allocator());
    sink.echo = false;
    defer sink.deinit();

    sink.add("m.astra", loc(2, 7), "undefined variable '{s}'", .{"x"});
    sink.add("m.astra", no_span, "unsupported import", .{});

    try testing.expectEqual(@as(usize, 2), sink.count());
    const d = sink.items.items[0];
    try testing.expectEqualStrings("m.astra", d.file);
    try testing.expectEqual(@as(u32, 2), d.span.line);
    try testing.expectEqual(@as(u32, 7), d.span.col);
    try testing.expectEqualStrings("undefined variable 'x'", d.msg);
    try testing.expectEqual(@as(u32, 0), sink.items.items[1].span.line);
}
