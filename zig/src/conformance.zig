//! Conformance: the Zig frontend must accept every Astra program the C seed
//! accepts.
//!
//! `PHASE2_KICKOFF.md` makes parity with the seed's suite the gate before new
//! features are added, so this walks `seed/tests/conformance/` and parses each
//! case. The `ui/` directory is skipped on purpose: those files are *expected*
//! to fail, but they fail in the type checker, not always in the parser, so a
//! clean parse is not the right assertion for them.

const std = @import("std");
const ast = @import("ast/ast.zig");
const parser = @import("parser/parser.zig");

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

test "parses every non-ui seed conformance file" {
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

        var tree = ast.Tree.init(arena.allocator(), source);
        defer tree.deinit();
        var p = parser.Parser.init(arena.allocator(), source, &tree);
        _ = p.parse() catch {
            std.debug.print("\nparse failed: {s}/{s}: {s}\n", .{ root, entry.path, p.err_msg });
            return error.ParseFailed;
        };
        checked += 1;
    }

    // A guard against the walk silently finding nothing (e.g. wrong cwd), which
    // would make the test a no-op that always passes.
    try std.testing.expect(checked > 40);
}
