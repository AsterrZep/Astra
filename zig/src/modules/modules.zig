//! Module system — Phase 2.2, step 2 (groundwork).
//!
//! Step 1 made the parser record `use` / `import` / `from` declarations. This is
//! where they start to mean something, and it does exactly three things:
//!
//! 1. **Path → file.** `ARCHITECTURE.md` §10.4 turns an import path into a file
//!    on disk. Only rules 1 and 2 ("relative" and "sub-route") are implemented:
//!    `mesh` → `mesh.astra`, `geometry.mesh` → `geometry/mesh.astra`, relative to
//!    the directory of the importing file. Rules 3 and 4 (`@/utils/logger` from
//!    the `astra.toml` root, `std/io` from the stdlib) are deferred on purpose:
//!    neither `astra.toml` nor a stdlib exists yet, and both spell those roots
//!    with `/`, a separator the language no longer uses (`research/010` §12.1,
//!    decided in `PHASE2_GAP_ANALYSIS.md` App. B #6). Guessing a dotted spelling
//!    for a root nobody has defined would be inventing language.
//! 2. **Declarations per file.** `collect` turns a parsed tree plus the file it
//!    came from into a `ModuleTable`: every module declaration in that file with
//!    its resolved file path. Module-level only (see `collect`).
//! 3. **Explicit bindings.** `ModuleTable.explicitBindings` lists the names a
//!    file introduces, *only* where the grammar states them: the alias of
//!    `import ... as x` and the items of `from ... import a, b as c`. A bare
//!    `import a.b` binds *something* — `ARCHITECTURE.md` §10.5 writes
//!    `import utils` and then `utils.Logger.info(…)` — but which segment it binds
//!    is not specified anywhere, so this file does not guess. That is an open
//!    question for the resolution step, recorded in `PHASE2_GAP_ANALYSIS.md`.
//!
//! Deliberately absent, because they need the loader and the package manifest:
//! reading source files, a symbol table per module, cross-module reference
//! resolution, `pub` visibility and circular-dependency detection
//! (`ARCHITECTURE.md` §10.5–§10.6, `PHASE2_GAP_ANALYSIS.md` §8.3).
//!
//! The seed has none of this and is not meant to: it compiles one file
//! (`research/011` §5.2), so this is the first thing in the port with no C
//! counterpart to match. The parity gate is unaffected — it constrains which
//! programs the two compilers accept, not how the Zig one would resolve files.

const std = @import("std");
const ast = @import("../ast/ast.zig");

/// `error.InvalidImportPath` covers both an empty path and a segment that is not
/// an identifier. It is one error because both mean the same thing at this
/// boundary: the caller passed something `ImportPath` cannot produce.
pub const Error = error{InvalidImportPath};

/// A module path as written (`geometry.mesh`) resolved to a file path relative
/// to the importing file's directory (`geometry/mesh.astra`).
///
/// `.astra` is only appended to the last segment: `a.b.c` is the file `a/b/c.astra`,
/// not the directory `a/b/c`.
///
/// The segments are re-validated even though the parser guarantees them, because
/// this is where a module path becomes a filesystem path: `a/b` and `..` reaching
/// the loader from anywhere else would be a path-traversal bug, and the check is
/// the only thing standing between a source-level identifier and a file name.
/// Mirrors the lexer's rule (`isAlpha`/`isDigit` in `lexer/lexer.zig`): letters
/// and `_` to start, plus digits after.
pub fn pathToFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return Error.InvalidImportPath;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var segments = std.mem.splitScalar(u8, path, '.');
    var first = true;
    while (segments.next()) |segment| {
        if (!isPathSegment(segment)) return Error.InvalidImportPath;
        // `/` is the internal spelling of a module path. It is not a separator
        // the language ever sees; it is what `ARCHITECTURE.md` §10.4 writes and
        // what the loader will hand to `std.fs` (which accepts it on every
        // platform Zig targets).
        if (!first) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
        first = false;
    }

    try out.appendSlice(allocator, ".astra");
    return out.toOwnedSlice(allocator);
}

/// Where a declaration inside `importing_file` points. `main.astra` + `a.b`
/// → `a/b.astra`; `src/main.astra` + `a.b` → `src/a/b.astra`. A file with no
/// directory (the common `astra-seed file.astra` case) has no base of its own,
/// so the result is the relative path unchanged.
pub fn resolveFromFile(
    allocator: std.mem.Allocator,
    importing_file: []const u8,
    path: []const u8,
) ![]u8 {
    const relative = try pathToFile(allocator, path);
    defer allocator.free(relative);

    // `orelse` must copy, not return `relative`: the defer above frees it.
    const dir = std.fs.path.dirname(importing_file) orelse return allocator.dupe(u8, relative);
    return std.mem.concat(allocator, u8, &.{ dir, "/", relative });
}

fn isPathSegment(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!isAlpha(text[0])) return false;
    for (text[1..]) |c| {
        if (!isAlpha(c) and !isDigit(c)) return false;
    }
    return true;
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// `ImportItem ::= Identifier ("as" Identifier)?` (research/010 §12.1).
pub const Item = struct { name: []const u8, alias: ?[]const u8 = null };

/// The name an item binds: its alias when it has one, else its own name.
pub fn itemBindingName(item: Item) []const u8 {
    return item.alias orelse item.name;
}

pub const Kind = enum { use, import, from };

/// One module declaration of a file, with the file it refers to.
pub const Decl = struct {
    kind: Kind,
    /// The path exactly as written (`geometry.mesh`).
    path: []const u8,
    /// Resolved relative to the declaring file (`geometry/mesh.astra`).
    file: []const u8,
    /// `import a.b as c` / `from a.b import x as y`.
    alias: ?[]const u8 = null,
    /// `from a.b import …`: the items, in source order. Empty for `use`/`import`.
    items: []const Item = &.{},
};

/// A name a file introduces, pointing at the declaration that introduces it.
pub const Binding = struct { name: []const u8, decl: usize };

/// The module declarations of one file. All memory comes from the allocator the
/// table was built with (the compilation arena), so there is no `deinit`.
pub const ModuleTable = struct {
    /// The file the declarations were collected from.
    file: []const u8,
    decls: []const Decl,

    /// Index of the first declaration naming `path`, or null.
    ///
    /// This is the lookup the resolver will use once files are loaded; today it
    /// answers "does this file declare this module twice?".
    pub fn find(self: ModuleTable, path: []const u8) ?usize {
        for (self.decls, 0..) |d, i| {
            if (std.mem.eql(u8, d.path, path)) return i;
        }
        return null;
    }

    /// Every name the file binds *explicitly*: item names (or their alias) from
    /// `from`, and the alias of `import ... as`. A bare `import a.b` contributes
    /// nothing — what it binds is unspecified, so it is not guessed here.
    pub fn explicitBindings(self: ModuleTable, allocator: std.mem.Allocator) ![]Binding {
        var list: std.ArrayListUnmanaged(Binding) = .empty;
        errdefer list.deinit(allocator);
        for (self.decls, 0..) |d, i| {
            if (d.alias) |alias| try list.append(allocator, .{ .name = alias, .decl = i });
            if (d.kind == .from) {
                for (d.items) |item| {
                    try list.append(allocator, .{ .name = itemBindingName(item), .decl = i });
                }
            }
        }
        return list.toOwnedSlice(allocator);
    }
};

/// Collect the module declarations of `file` from a parsed tree.
///
/// Module-level items only, which is what `research/010` §12.1 makes them
/// (`Item ::= … | ImportStmt | ExportStmt`). Both frontends nonetheless accept a
/// module declaration in statement position, so one nested in a function body is
/// ignored here rather than silently bound at module scope; whether it should be
/// rejected instead is the resolution step's call, not this one's
/// (`PHASE1_PROGRESS.md` §6.7).
pub fn collect(
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,
    root: u32,
    file: []const u8,
) !ModuleTable {
    var decls: std.ArrayListUnmanaged(Decl) = .empty;

    const items = switch (tree.node(root)) {
        .source_file => |list| tree.extraSlice(list),
        // A tree whose root is not a file is a caller bug, not a module; an
        // empty table keeps the caller's error handling in one place.
        else => return .{ .file = file, .decls = &.{} },
    };

    for (items) |item| {
        const decl: Decl = switch (tree.node(item)) {
            .use_decl => |path| .{ .kind = .use, .path = path, .file = try resolveFromFile(allocator, file, path) },
            .import_decl => |d| .{
                .kind = .import,
                .path = d.path,
                .file = try resolveFromFile(allocator, file, d.path),
                .alias = d.alias,
            },
            .from_decl => |d| blk: {
                const node = tree.extraSlice(d.items);
                const parsed = try allocator.alloc(Item, node.len);
                for (node, 0..) |child, i| {
                    const it = tree.node(child).import_item;
                    parsed[i] = .{ .name = it.name, .alias = it.alias };
                }
                break :blk .{
                    .kind = .from,
                    .path = d.path,
                    .file = try resolveFromFile(allocator, file, d.path),
                    .items = parsed,
                };
            },
            else => continue,
        };
        try decls.append(allocator, decl);
    }

    return .{ .file = file, .decls = try decls.toOwnedSlice(allocator) };
}

/// Human-readable rendering of a table, for the `--dump-modules` flag.
pub fn dump(writer: anytype, table: ModuleTable) !void {
    try writer.print("modules ({s}): {d} declaration(s)\n", .{ table.file, table.decls.len });
    for (table.decls) |d| {
        try writer.print("  {s} {s} -> {s}", .{ @tagName(d.kind), d.path, d.file });
        if (d.alias) |alias| try writer.print(" as {s}", .{alias});
        if (d.kind == .from) {
            try writer.writeAll(" [binds");
            for (d.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(",");
                if (item.alias) |alias| {
                    try writer.print(" {s} as {s}", .{ item.name, alias });
                } else {
                    try writer.print(" {s}", .{item.name});
                }
            }
            try writer.writeAll("]");
        }
        try writer.writeAll("\n");
    }
}

// ── Tests ─────────────────────────────────────────────────────────

const parser = @import("../parser/parser.zig");

test "import path to file: relative (rule 1) and sub-route (rule 2)" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "mesh", "mesh.astra" },
        .{ "geometry.mesh", "geometry/mesh.astra" },
        .{ "a.b.c", "a/b/c.astra" },
        // Rule 4 is not implemented: with no stdlib yet, `std` is a plain
        // segment and `std.io` is just a file, which is what a project that
        // ships its own `std/io.astra` would want.
        .{ "std.io", "std/io.astra" },
    };
    for (cases) |case| {
        const got = try pathToFile(a, case[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "import path refuses anything that could escape the module directory" {
    const a = std.testing.allocator;
    const bad = [_][]const u8{
        "", ".", "a.", ".a", "a..b", // empty segments
        "a/b", "..", "../etc/passwd", ".hidden", // traversal / separators
        "a. b", "a.\u{e9}", "1a", "-x", // not identifiers
    };
    for (bad) |path| {
        try std.testing.expectError(Error.InvalidImportPath, pathToFile(a, path));
    }
}

test "the importing file's directory is the base for resolution" {
    const a = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "main.astra", "geometry.mesh", "geometry/mesh.astra" },
        .{ "src/main.astra", "mesh", "src/mesh.astra" },
        .{ "src/main.astra", "geometry.mesh", "src/geometry/mesh.astra" },
    };
    for (cases) |case| {
        const got = try resolveFromFile(a, case[0], case[1]);
        defer a.free(got);
        try std.testing.expectEqualStrings(case[2], got);
    }
}

test "collect: declarations, resolved files and explicit bindings" {
    const source =
        \\import std.io
        \\import geometry.mesh as mesh
        \\from geometry.vector import Vec2, add as sum
        \\use a.b.c
        \\fn main() { print(1) }
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tree = ast.Tree.init(a, source);
    defer tree.deinit();
    var p = parser.Parser.init(a, source, &tree);
    const root = try p.parse();

    const table = try collect(a, &tree, root, "src/main.astra");
    try std.testing.expectEqualStrings("src/main.astra", table.file);
    try std.testing.expectEqual(@as(usize, 4), table.decls.len);

    try std.testing.expectEqual(Kind.use, table.decls[3].kind);
    try std.testing.expectEqualStrings("a.b.c", table.decls[3].path);
    try std.testing.expectEqualStrings("src/a/b/c.astra", table.decls[3].file);

    try std.testing.expectEqual(Kind.import, table.decls[1].kind);
    try std.testing.expectEqualStrings("mesh", table.decls[1].alias.?);
    try std.testing.expectEqualStrings("src/geometry/mesh.astra", table.decls[1].file);

    const from = table.decls[2];
    try std.testing.expectEqual(Kind.from, from.kind);
    try std.testing.expectEqualStrings("src/geometry/vector.astra", from.file);
    try std.testing.expectEqual(@as(usize, 2), from.items.len);
    try std.testing.expectEqualStrings("Vec2", itemBindingName(from.items[0]));
    try std.testing.expectEqualStrings("add", from.items[1].name);
    try std.testing.expectEqualStrings("sum", itemBindingName(from.items[1]));

    // The table is keyed by the path as written.
    try std.testing.expectEqual(@as(?usize, 2), table.find("geometry.vector"));
    try std.testing.expectEqual(@as(?usize, null), table.find("geometry.mesh.x"));

    // Explicit bindings only: `std.io` (no alias) contributes nothing, `a.b.c`
    // is a re-export and contributes nothing, the alias and the two items do.
    const binds = try table.explicitBindings(a);
    try std.testing.expectEqual(@as(usize, 3), binds.len);
    try std.testing.expectEqualStrings("mesh", binds[0].name);
    try std.testing.expectEqualStrings("Vec2", binds[1].name);
    try std.testing.expectEqualStrings("sum", binds[2].name);
}

test "collect ignores module declarations nested in a function body" {
    // Both frontends accept a module declaration in statement position (the
    // seed reaches `parse_import` from there too), even though research/010
    // §12.1 makes it an `Item`. Nothing binds a name at function scope here, so
    // `collect` sees only the module level.
    const source =
        \\fn main() {
        \\    import inner.thing
        \\    print(1)
        \\}
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tree = ast.Tree.init(a, source);
    defer tree.deinit();
    var p = parser.Parser.init(a, source, &tree);
    const root = try p.parse();

    const table = try collect(a, &tree, root, "main.astra");
    try std.testing.expectEqual(@as(usize, 0), table.decls.len);
}

test "a file with no module declarations has an empty table" {
    const source =
        \\fn main() { print(1) }
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tree = ast.Tree.init(a, source);
    defer tree.deinit();
    var p = parser.Parser.init(a, source, &tree);
    const root = try p.parse();

    const table = try collect(a, &tree, root, "main.astra");
    try std.testing.expectEqual(@as(usize, 0), table.decls.len);
    try std.testing.expectEqual(@as(?usize, null), table.find("mesh"));

    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try dump(&w, table);
    try std.testing.expectEqualStrings("modules (main.astra): 0 declaration(s)\n", w.buffered());
}
