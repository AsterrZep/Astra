//! Conformance: the Zig frontend must accept every Astra program the C seed
//! accepts, and reject the ones it rejects.
//!
//! `PHASE2_KICKOFF.md` makes parity with the seed's suite the gate before new
//! features are added. Two assertions:
//!
//! - every non-`ui/` case parses **and** type-checks cleanly;
//! - every `ui/` case is rejected. The parser owns six of them (nesting,
//!   comma-in-body, bad literal, unterminated string) and the type checker owns
//!   the rest; `break_outside_loop` is checked by the emitter in the seed, so it
//!   is the one expected to still pass here.

const std = @import("std");
const ast = @import("ast/ast.zig");
const parser = @import("parser/parser.zig");
const typechecker = @import("typechecker/typechecker.zig");

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

const Outcome = struct { parsed: bool, type_ok: bool };

fn check(arena: std.mem.Allocator, source: []const u8, name: []const u8) Outcome {
    var tree = ast.Tree.init(arena, source);
    var p = parser.Parser.init(arena, source, &tree);
    const root = p.parse() catch return .{ .parsed = false, .type_ok = false };
    var tc = typechecker.TypeChecker.init(arena, &tree, name) catch return .{ .parsed = false, .type_ok = false };
    tc.check(root);
    return .{ .parsed = true, .type_ok = tc.error_count == 0 };
}

test "parses and type-checks every non-ui seed conformance file" {
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

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const out = check(arena.allocator(), source, entry.path);
        if (!out.type_ok) {
            std.debug.print("\nfrontend rejected valid program: {s}/{s}\n", .{ root, entry.path });
            return error.ValidProgramRejected;
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
        // The seed checks `break`/`continue` outside a loop in the emitter.
        if (std.mem.endsWith(u8, entry.path, "break_outside_loop.astra")) continue;

        const source = try dir.readFileAlloc(io, entry.path, std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(source);

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const out = check(arena.allocator(), source, entry.path);
        if (out.type_ok) {
            std.debug.print("\nfrontend accepted invalid program: {s}/{s}\n", .{ root, entry.path });
            return error.InvalidProgramAccepted;
        }
        checked += 1;
    }
    try std.testing.expect(checked > 15);
}
