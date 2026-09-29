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
//! Plus a **loader** (`Loader`, `Graph`): it reads the file each declaration
//! resolves to, recursively, and reports the one thing no single file can show —
//! a circular import, which `ARCHITECTURE.md` §10.6 forbids and the gap analysis
//! (§8.3) makes the loader's job.
//!
//! Deliberately absent, because they need the package manifest and the resolver:
//! a symbol table per module, cross-module reference resolution and `pub`
//! visibility (`ARCHITECTURE.md` §10.5, `PHASE2_GAP_ANALYSIS.md` §8.3).
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

// ── Loading ──────────────────────────────────────────────────────

/// Largest module the loader will read. A module is input like any other, so it
/// gets the same ceiling `main.zig` applies to the program itself (64 MiB) rather
/// than trusting the filesystem.
const source_limit = 1 << 26;

/// One module in the graph: the file, its source text and its declarations.
pub const LoadedModule = struct {
    file: []const u8,
    source: []const u8,
    table: ModuleTable,
};

pub const Graph = struct {
    /// Load order, root first. Each file appears exactly once, however many
    /// declarations point at it.
    modules: []const LoadedModule,

    pub fn find(self: Graph, file: []const u8) ?usize {
        for (self.modules, 0..) |m, i| {
            if (std.mem.eql(u8, m.file, file)) return i;
        }
        return null;
    }
};

/// Reads modules and follows their imports.
///
/// A cycle is the one error that cannot be found one file at a time: every file
/// in it is fine on its own and only the chain is wrong. So the loader keeps the
/// chain of files it is currently inside (`visiting`) and reports a cycle when a
/// resolution lands on one of them (`ARCHITECTURE.md` §10.6).
///
/// Failures are reported and counted, not returned — `error_count` is the
/// caller's signal, the same contract the type checker and the emitter use —
/// except allocation failures, which still propagate.
pub const Loader = struct {
    a: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    error_count: usize = 0,
    modules: std.ArrayListUnmanaged(LoadedModule) = .empty,
    /// Files being loaded right now, outermost first.
    visiting: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) Loader {
        return .{ .a = a, .io = io, .dir = dir };
    }

    /// Load `root_file` and everything it imports, transitively. Returns the
    /// graph even when `error_count > 0`: the caller decides whether a partial
    /// graph is worth looking at, exactly as with a file that has type errors.
    pub fn load(self: *Loader, root_file: []const u8) !Graph {
        try self.loadFile(root_file);
        return .{ .modules = try self.modules.toOwnedSlice(self.a) };
    }

    fn loadFile(self: *Loader, file: []const u8) !void {
        // Order matters: a file on the stack is already in `modules`, so asking
        // "already loaded?" first would turn every cycle into a silent no-op.
        if (self.visitingIndex(file)) |at| {
            self.reportCycle(at, file);
            return;
        }
        if (self.loadedIndex(file) != null) return;

        const source = self.dir.readFileAlloc(self.io, file, self.a, .limited(source_limit)) catch |err| {
            std.debug.print("error: cannot read module {s}: {s}\n", .{ file, @errorName(err) });
            self.error_count += 1;
            return;
        };

        var tree = ast.Tree.init(self.a, source);
        defer tree.deinit();
        var p = parser.Parser.init(self.a, source, &tree);
        const root = p.parse() catch {
            std.debug.print("error: {s}: module did not parse\n", .{file});
            self.error_count += 1;
            return;
        };

        const table = try collect(self.a, &tree, root, file);
        try self.modules.append(self.a, .{ .file = file, .source = source, .table = table });

        try self.visiting.append(self.a, file);
        for (table.decls) |decl| try self.loadFile(decl.file);
        _ = self.visiting.pop();
    }

    fn visitingIndex(self: *const Loader, file: []const u8) ?usize {
        for (self.visiting.items, 0..) |v, i| {
            if (std.mem.eql(u8, v, file)) return i;
        }
        return null;
    }

    fn loadedIndex(self: *const Loader, file: []const u8) ?usize {
        for (self.modules.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.file, file)) return i;
        }
        return null;
    }

    fn reportCycle(self: *Loader, at: usize, file: []const u8) void {
        std.debug.print("error: circular import: ", .{});
        for (self.visiting.items[at..]) |step| std.debug.print("{s} -> ", .{step});
        std.debug.print("{s}\n", .{file});
        self.error_count += 1;
    }
};

// ── Dumps ────────────────────────────────────────────────────────

fn writeDecl(writer: anytype, d: Decl) !void {
    try writer.print("{s} {s} -> {s}", .{ @tagName(d.kind), d.path, d.file });
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

/// Human-readable rendering of one file's declarations.
pub fn dump(writer: anytype, table: ModuleTable) !void {
    try writer.print("modules ({s}): {d} declaration(s)\n", .{ table.file, table.decls.len });
    for (table.decls) |d| {
        try writer.writeAll("  ");
        try writeDecl(writer, d);
    }
}

/// Human-readable rendering of a loaded graph, for `--dump-modules`: every file
/// that would take part in the build, in load order, with what each one imports.
pub fn dumpGraph(writer: anytype, graph: Graph) !void {
    try writer.print("module graph: {d} module(s)\n", .{graph.modules.len});
    for (graph.modules) |m| {
        try writer.print("  {s}\n", .{m.file});
        for (m.table.decls) |d| {
            try writer.writeAll("    ");
            try writeDecl(writer, d);
        }
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

// ── Loader tests ──────────────────────────────────────────────────
//
// These are the only tests in the port that read files of their own: loading
// *is* the filesystem, so the fixtures live in `zig/tests/modules/<scenario>/`
// and are located relative to whichever directory the test binary was started
// in (the same two candidates `conformance.zig` tries).

const fixture_candidates = [_][]const u8{ "tests/modules", "../tests/modules" };

fn fixtureRoot(io: std.Io, cwd: std.Io.Dir) ![]const u8 {
    for (fixture_candidates) |candidate| {
        cwd.access(io, candidate, .{}) catch continue;
        return candidate;
    }
    // Not `error.SkipZigTest`: a loader test that silently does not run is the
    // "marked supported, never exercised" gap this suite exists to catch.
    return error.ModuleFixturesNotFound;
}

fn fixture(a: std.mem.Allocator, root: []const u8, relative: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ root, relative });
}

test "the loader follows imports transitively, resolving each path" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try fixtureRoot(io, cwd);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loader = Loader.init(a, io, cwd);
    const entry = try fixture(a, root, "tree/main.astra");
    const graph = try loader.load(entry);

    try std.testing.expectEqual(@as(usize, 0), loader.error_count);
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);

    // Load order is depth-first from the root, and every file is resolved
    // relative to the file that imported it: root → geometry/mesh → geometry/vector.
    try std.testing.expectEqualStrings(entry, graph.modules[0].file);
    const mesh = try std.fs.path.join(a, &.{ root, "tree", "geometry", "mesh.astra" });
    const vector = try std.fs.path.join(a, &.{ root, "tree", "geometry", "vector.astra" });
    try std.testing.expectEqualStrings(mesh, graph.modules[1].file);
    try std.testing.expectEqualStrings(vector, graph.modules[2].file);

    try std.testing.expectEqual(Kind.import, graph.modules[0].table.decls[0].kind);
    try std.testing.expectEqual(Kind.from, graph.modules[1].table.decls[0].kind);
    try std.testing.expectEqualStrings("Vec2", itemBindingName(graph.modules[1].table.decls[0].items[0]));
    try std.testing.expectEqual(@as(usize, 0), graph.modules[2].table.decls.len);

    try std.testing.expectEqual(@as(?usize, 2), graph.find(vector));
    try std.testing.expectEqual(@as(?usize, null), graph.find("nowhere.astra"));
}

test "a module reached twice is loaded once" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try fixtureRoot(io, cwd);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loader = Loader.init(a, io, cwd);
    const graph = try loader.load(try fixture(a, root, "diamond/main.astra"));

    try std.testing.expectEqual(@as(usize, 0), loader.error_count);
    // main → one → shared, then two (whose `shared` is already loaded).
    try std.testing.expectEqual(@as(usize, 4), graph.modules.len);
    const shared = try std.fs.path.join(a, &.{ root, "diamond", "shared.astra" });
    try std.testing.expectEqual(@as(?usize, 2), graph.find(shared));
}

test "a circular import is reported instead of loading forever" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try fixtureRoot(io, cwd);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loader = Loader.init(a, io, cwd);
    const graph = try loader.load(try fixture(a, root, "cycle/a.astra"));

    // One reported edge (b → a) and a graph that stops there: no runaway walk.
    try std.testing.expectEqual(@as(usize, 1), loader.error_count);
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
}

test "a module that is not on disk is reported, not fatal" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try fixtureRoot(io, cwd);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loader = Loader.init(a, io, cwd);
    const entry = try fixture(a, root, "missing/main.astra");
    const graph = try loader.load(entry);

    try std.testing.expectEqual(@as(usize, 1), loader.error_count);
    // The root is still in the graph: one unresolvable import does not throw
    // away the file that was fine.
    try std.testing.expectEqual(@as(usize, 1), graph.modules.len);
    try std.testing.expectEqualStrings(entry, graph.modules[0].file);
}
