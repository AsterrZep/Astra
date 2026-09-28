//! Conformance: the Zig compiler must accept every Astra program the C seed
//! accepts, reject the ones it rejects, and — now that the VM is ported — run
//! every program to the same stdout the seed produces.
//!
//! `PHASE2_KICKOFF.md` makes parity with the seed's suite the gate before new
//! features are added. The runner mirrors `seed/tests/run_tests.sh`:
//!
//! - every non-`ui/` case compiles, then either runs and matches its `EXPECT:`
//!   lines, or fails at run time with a message containing its
//!   `EXPECT-RUNTIME-ERROR:` text;
//! - every `ui/` case is rejected at compile time. The parser owns six of them
//!   (nesting, comma-in-body, bad literal, unterminated string), the type
//!   checker most of the rest, and the emitter `break_outside_loop`.

const std = @import("std");
const ast = @import("ast/ast.zig");
const parser = @import("parser/parser.zig");
const typechecker = @import("typechecker/typechecker.zig");
const emitter = @import("emitter/emitter.zig");
const vm = @import("vm/vm.zig");

/// The seed suite lives outside the Zig package; resolve it relative to the
/// build root. Candidates cover `zig build test` (cwd = zig/) and a direct
/// `zig test` from the repository root.
const candidates = [_][]const u8{
    "../seed/tests/conformance",
    "seed/tests/conformance",
    "tests/conformance",
};

fn findRoot(io: std.Io, cwd: std.Io.Dir) ?[]const u8 {
    for (candidates) |c| {
        cwd.access(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

/// Extract the value of a `// EXPECT...:` directive from a source line, or null
/// if the line is not that directive. `prefix` includes the trailing colon so
/// `EXPECT:` never matches `EXPECT-ERROR:`.
fn directive(line: []const u8, comptime prefix: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "//")) return null;
    var rest = std.mem.trimStart(u8, trimmed[2..], " \t");
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    rest = std.mem.trimStart(u8, rest[prefix.len..], " \t");
    return std.mem.trimEnd(u8, rest, " \t\r");
}

const Outcome = struct { parsed: bool, type_ok: bool, emit_ok: bool, ran: bool, output: []const u8, runtime_error: ?[]const u8 };

/// Compile and, if it compiles, run the program, capturing its stdout. An
/// allocated `out_buf` receives the output; the VM writes through a fixed
/// writer so nothing escapes to the test process's stdout.
fn runProgram(arena: std.mem.Allocator, source: []const u8, name: []const u8, out_buf: []u8) Outcome {
    var tree = ast.Tree.init(arena, source);
    var p = parser.Parser.init(arena, source, &tree);
    const root = p.parse() catch return .{ .parsed = false, .type_ok = false, .emit_ok = false, .ran = false, .output = "", .runtime_error = null };
    var tc = typechecker.TypeChecker.init(arena, &tree, name) catch return .{ .parsed = true, .type_ok = false, .emit_ok = false, .ran = false, .output = "", .runtime_error = null };
    tc.check(root);
    if (tc.error_count != 0) return .{ .parsed = true, .type_ok = false, .emit_ok = true, .ran = false, .output = "", .runtime_error = null };
    var em = emitter.Emitter.init(arena, &tree, name);
    em.emit(root);
    if (em.error_count != 0) return .{ .parsed = true, .type_ok = true, .emit_ok = false, .ran = false, .output = "", .runtime_error = null };

    var w = std.Io.Writer.fixed(out_buf);
    var machine = vm.VM.init(arena, &w) catch return .{ .parsed = true, .type_ok = true, .emit_ok = true, .ran = false, .output = "", .runtime_error = null };
    const res = machine.run(em.code.items, em.constants.items) catch
        return .{ .parsed = true, .type_ok = true, .emit_ok = true, .ran = false, .output = w.buffered(), .runtime_error = null };
    return .{
        .parsed = true,
        .type_ok = true,
        .emit_ok = true,
        .ran = res == .ok,
        .output = w.buffered(),
        .runtime_error = if (res == .runtime_error) machine.error_msg else null,
    };
}

test "runs every non-ui seed conformance file and matches its expectations" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = findRoot(io, cwd) orelse return error.SkipZigTest;

    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();

    var checked: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".astra")) continue;
        if (std.mem.startsWith(u8, entry.path, "ui/")) continue;

        const source = try dir.readFileAlloc(io, entry.path, std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(source);

        // Collect the directives. Expected stdout is a newline-joined list; a
        // runtime-error case carries only the required message substring.
        var expected = std.ArrayList(u8).empty;
        defer expected.deinit(std.testing.allocator);
        var want_runtime_error: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (directive(line, "EXPECT-RUNTIME-ERROR:")) |text| {
                want_runtime_error = text;
            } else if (directive(line, "EXPECT:")) |text| {
                try expected.appendSlice(std.testing.allocator, text);
                try expected.append(std.testing.allocator, '\n');
            }
        }

        var file_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer file_arena.deinit();
        const buf = try file_arena.allocator().alloc(u8, 1 << 20);
        const out = runProgram(file_arena.allocator(), source, entry.path, buf);

        if (!out.type_ok or !out.emit_ok) {
            std.debug.print("\ncompiler rejected valid program: {s}/{s}\n", .{ root, entry.path });
            return error.ValidProgramRejected;
        }

        if (want_runtime_error) |text| {
            if (out.ran) {
                std.debug.print("\nexpected runtime error '{s}' in {s}/{s}, but it ran to completion\n", .{ text, root, entry.path });
                return error.ExpectedRuntimeError;
            }
            const msg = out.runtime_error orelse "";
            if (!std.mem.containsAtLeast(u8, msg, 1, text)) {
                std.debug.print("\nruntime error mismatch in {s}/{s}: wanted '{s}', got '{s}'\n", .{ root, entry.path, text, msg });
                return error.RuntimeErrorMismatch;
            }
        } else {
            if (!out.ran) {
                std.debug.print("\n{s}/{s} failed at run time: {s}\n", .{ root, entry.path, out.runtime_error orelse "?" });
                return error.ValidProgramFailed;
            }
            const want = std.mem.trimEnd(u8, expected.items, "\n");
            const got = std.mem.trimEnd(u8, out.output, "\n");
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("\noutput mismatch in {s}/{s}\n--- expected ---\n{s}\n--- got ---\n{s}\n", .{ root, entry.path, want, got });
                return error.OutputMismatch;
            }
        }
        checked += 1;
    }
    try std.testing.expect(checked > 40);
}

test "rejects every ui seed conformance file" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = findRoot(io, cwd) orelse return error.SkipZigTest;

    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();

    var checked: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".astra")) continue;
        if (!std.mem.startsWith(u8, entry.path, "ui/")) continue;

        const source = try dir.readFileAlloc(io, entry.path, std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(source);

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const buf = try arena.allocator().alloc(u8, 1 << 20);
        const out = runProgram(arena.allocator(), source, entry.path, buf);
        if (out.parsed and out.type_ok and out.emit_ok) {
            std.debug.print("\ncompiler accepted invalid program: {s}/{s}\n", .{ root, entry.path });
            return error.InvalidProgramAccepted;
        }
        checked += 1;
    }
    try std.testing.expect(checked > 15);
}
