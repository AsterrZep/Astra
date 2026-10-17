//! Module system — Phase 2.2, step 2 (groundwork).
//!
//! Step 1 made the parser record `use` / `import` / `from` declarations. This is
//! where they start to mean something, and it does exactly three things:
//!
//! 1. **Path → file.** `ARCHITECTURE.md` §10.4 turns an import path into a file
//!    on disk. Rules 1 and 2 ("relative" and "sub-route") resolve against the
//!    directory of the importing file: `mesh` → `mesh.astra`, `geometry.mesh`
//!    → `geometry/mesh.astra`, with `.` and `/` equivalent separators (the
//!    grammar accepts both, `ImportPath ::= ("@" "/")? …`). Rule 3 (`@/…`)
//!    anchors at the project root: the nearest directory above the entry file
//!    that contains an `astra.toml`, found by walking up from the entry
//!    (`Loader.load`). Only the manifest's existence is consulted — parsing
//!    `[package]` and dependencies is the package manager's job
//!    (`research/package-manager-design.md`). Rule 4 (`std/…`) is accepted by
//!    the grammar and rejected here with an explicit error: there is no
//!    stdlib yet, and guessing one would be inventing it.
//! 2. **Declarations per file.** `collect` turns a parsed tree plus the file it
//!    came from into a `ModuleTable`: every module declaration in that file with
//!    its resolved file path, plus the names the file marks `pub` (the export
//!    set the drivers gate imports on). Module-level only (see `collect`).
//! 3. **Explicit bindings.** `ModuleTable.explicitBindings` lists the names a
//!    file introduces, *only* where the grammar states them: the alias of
//!    `import ... as x` and the items of `from ... import a, b as c`. A bare
//!    `import a.b` binds the **last** segment (`import utils.mesh` binds
//!    `mesh`), per `ARCHITECTURE.md` §10.5; that binding is derived by the
//!    drivers (`lastSegment`), not declared here (`PHASE2_GAP_ANALYSIS.md`
//!    App. B #11, resolved 2026-10-10).
//!
//! Plus a **loader** (`Loader`, `Graph`): it reads the file each declaration
//! resolves to, recursively, keeps each file's parsed tree alive (compilation
//! will need them, not just the tables), orders the graph **dependencies first,
//! root last** so a future compiler can execute module code dep-before-user,
//! and reports the one thing no single file can show — a circular import, which
//! `ARCHITECTURE.md` §10.6 forbids and the gap analysis (§8.3) makes the
//! loader's job.
//!
//! Cross-module reference resolution and *enforcing* `pub` visibility live in
//! the drivers (`main.zig` / `link.zig`, `PHASE2_PROGRESS.md` §7): binding
//! names to the owning module's globals, type ownership through `own_types`,
//! and rejecting the import of a private name.
//!
//! The seed has none of this and is not meant to: it compiles one file
//! (`research/002` §5.2), so this is the first thing in the port with no C
//! counterpart to match. The parity gate is unaffected — it constrains which
//! programs the two compilers accept, not how the Zig one would resolve files.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const diagnostics_mod = @import("../diagnostics.zig");

/// `error.InvalidImportPath` covers both an empty path and a segment that is not
/// an identifier. It is one error because both mean the same thing at this
/// boundary: the caller passed something `ImportPath` cannot produce.
///
/// `error.Reported` is the soft-failure signal of `resolve`: the problem was
/// already turned into a user-facing diagnostic (no `astra.toml` for `@/`,
/// no stdlib for `std/…`), and the caller only has to count it.
pub const Error = error{ InvalidImportPath, Reported };

/// A module path as written (`geometry.mesh` or `geometry/mesh`) resolved to a
/// file path relative to the base directory the caller chose (`geometry/mesh.astra`).
///
/// `.astra` is only appended to the last segment: `a.b.c` is the file `a/b/c.astra`,
/// not the directory `a/b/c`.
///
/// The segments are re-validated even though the parser guarantees them, because
/// this is where a module path becomes a filesystem path: `..` reaching the
/// loader from anywhere else would be a path-traversal bug, and the check is the
/// only thing standing between a source-level identifier and a file name.
/// Mirrors the lexer's rule (`isAlpha`/`isDigit` in `lexer/lexer.zig`): letters
/// and `_` to start, plus digits after. Both source separators (`.`, `/`) are
/// accepted and `/` is always what comes out — the spelling `std.fs` and the
/// loader work with on every platform Zig targets.
pub fn pathToFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return Error.InvalidImportPath;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var segments = std.mem.splitAny(u8, path, "./");
    var first = true;
    while (segments.next()) |segment| {
        if (!isPathSegment(segment)) return Error.InvalidImportPath;
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

/// Full resolution of one `ImportPath` — every rule of `ARCHITECTURE.md`
/// §10.4 that Astra-0 implements:
///
/// - `@/…` (rule 3) anchors at `project_root`, the directory containing
///   `astra.toml`. Without one the path cannot mean anything, so a diagnostic
///   is emitted (naming the path and the file it was written in) and
///   `error.Reported` is returned — soft, already user-visible.
/// - `std/…` (rule 4) is rejected the same way: the grammar accepts the
///   spelling, but no stdlib exists yet to resolve it against. The dotted
///   `std.io` form is *not* special-cased — as a rule-2 path it resolves
///   relative like any other, which is what lets a project ship its own
///   `std/io.astra` (`use_paths.astra` depends on that).
/// - anything else is rule 1-2, relative to the importing file.
pub fn resolve(
    allocator: std.mem.Allocator,
    importing_file: []const u8,
    path: []const u8,
    project_root: ?[]const u8,
    diag: ?*diagnostics_mod.Sink,
) ![]u8 {
    if (std.mem.startsWith(u8, path, "std/")) {
        diagnostics_mod.emit(diag, importing_file, diagnostics_mod.no_span,
            "cannot resolve '{s}': no standard library exists yet", .{path});
        return error.Reported;
    }
    if (std.mem.startsWith(u8, path, "@/")) {
        const root = project_root orelse {
            diagnostics_mod.emit(diag, importing_file, diagnostics_mod.no_span,
                "cannot resolve '{s}': no astra.toml found (project root)", .{path});
            return error.Reported;
        };
        const relative = try pathToFile(allocator, path[2..]);
        defer allocator.free(relative);
        // `""` means the manifest sits at the cwd: joining "" and "/" would
        // forge an absolute path from the filesystem root.
        if (root.len == 0) return allocator.dupe(u8, relative);
        return std.mem.concat(allocator, u8, &.{ root, "/", relative });
    }
    return resolveFromFile(allocator, importing_file, path);
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

/// `ImportItem ::= Identifier ("as" Identifier)?` (research/001 §12.1).
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
    /// Top-level names the file marks `pub` (fn/struct/enum/const), in source
    /// order. The drivers gate imports on it and reject a private name
    /// (`ARCHITECTURE.md` §10.2; `link.zig` "importing a private name").
    exports: []const []const u8 = &.{},

    /// Index of the first declaration naming `path`, or null.
    ///
    /// Answers "does this file declare this module twice?"; the drivers order
    /// and resolve files through `Graph.find`, not this table.
    pub fn find(self: ModuleTable, path: []const u8) ?usize {
        for (self.decls, 0..) |d, i| {
            if (std.mem.eql(u8, d.path, path)) return i;
        }
        return null;
    }

    /// Every name the file binds *explicitly*: item names (or their alias) from
    /// `from`, and the alias of `import ... as`. A bare `import a.b` contributes
    /// nothing here — its binding (the last segment, App. B #11) is derived by
    /// the drivers, not declared by the grammar.
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

/// Extra resolution context for `collect`.
///
/// `project_root` is the directory holding `astra.toml` (rule 3), discovered
/// once per build by `Loader.load`. `diag` lets `resolve` report its soft
/// failures (`@/` without a manifest, `std/…` without a stdlib) with the
/// importing file's name; with no sink the message goes straight to stderr,
/// which is what the CLI does.
pub const CollectOptions = struct {
    project_root: ?[]const u8 = null,
    diag: ?*diagnostics_mod.Sink = null,
};

/// Collect the module declarations of `file` from a parsed tree.
///
/// Module-level items only, which is what `research/001` §12.1 makes them
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
    opts: CollectOptions,
) !ModuleTable {
    var decls: std.ArrayListUnmanaged(Decl) = .empty;
    var exports: std.ArrayListUnmanaged([]const u8) = .empty;

    const items = switch (tree.node(root)) {
        .source_file => |list| tree.extraSlice(list),
        // A tree whose root is not a file is a caller bug, not a module; an
        // empty table keeps the caller's error handling in one place.
        else => return .{ .file = file, .decls = &.{} },
    };

    for (items) |item| {
        switch (tree.node(item)) {
            // A generic declaration is inert (Phase 2.4 step 1): it never
            // binds a name, so it cannot be imported either.
            .fn_decl => |f| if (f.is_pub and f.generics.len == 0) try exports.append(allocator, f.name),
            .struct_decl => |s| if (s.is_pub and s.generics.len == 0) try exports.append(allocator, s.name),
            .enum_decl => |e| if (e.is_pub and e.generics.len == 0) try exports.append(allocator, e.name),
            .const_decl => |c| if (c.is_pub) try exports.append(allocator, c.name),
            else => {},
        }
        const decl: Decl = switch (tree.node(item)) {
            .use_decl => |path| .{
                .kind = .use,
                .path = path,
                .file = try resolve(allocator, file, path, opts.project_root, opts.diag),
            },
            .import_decl => |d| .{
                .kind = .import,
                .path = d.path,
                .file = try resolve(allocator, file, d.path, opts.project_root, opts.diag),
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
                    .file = try resolve(allocator, file, d.path, opts.project_root, opts.diag),
                    .items = parsed,
                };
            },
            else => continue,
        };
        try decls.append(allocator, decl);
    }

    return .{
        .file = file,
        .decls = try decls.toOwnedSlice(allocator),
        .exports = try exports.toOwnedSlice(allocator),
    };
}

// ── Loading ──────────────────────────────────────────────────────

/// Largest module the loader will read. A module is input like any other, so it
/// gets the same ceiling `main.zig` applies to the program itself (64 MiB) rather
/// than trusting the filesystem.
const source_limit = 1 << 26;

/// One module in the graph: the file, its source text, its declarations, and
/// the parsed tree they came from. The tree stays alive because compilation
/// will emit from it; `Loader.deinit` destroys it.
pub const LoadedModule = struct {
    file: []const u8,
    source: []const u8,
    table: ModuleTable,
    tree: ast.Tree,
    root: u32,
};

pub const Graph = struct {
    /// Load order, **dependencies first, root last** (post-order). Each file
    /// appears exactly once, however many declarations point at it. A compiler
    /// executes module code in this order so a module's top-level statements
    /// run after everything it imports (`ARCHITECTURE.md` §10.5).
    modules: []LoadedModule,

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
    /// The directory holding `astra.toml`, or null when there is none — the
    /// anchor of `@/…` paths (`ARCHITECTURE.md` §10.4 rule 3). Discovered once
    /// per `load` by walking up from the entry file's directory.
    project_root: ?[]const u8 = null,
    /// Optional sink: when wired, errors are recorded there (and echoed to
    /// stderr); when null, they print directly. Both paths share one format.
    diag: ?*diagnostics_mod.Sink = null,

    pub fn init(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) Loader {
        return .{ .a = a, .io = io, .dir = dir };
    }

    /// Destroy the loaded trees. Sources and paths are arena memory (the
    /// compilation arena) and are left to it; the trees hold state of their
    /// own, so they are torn down here. Call after the `Graph` is done.
    pub fn deinit(self: *Loader) void {
        for (self.modules.items) |*m| m.tree.deinit();
    }

    /// Load `root_file` and everything it imports, transitively. The returned
    /// graph borrows from the loader and stays valid until `deinit`; it is
    /// returned even when `error_count > 0`: the caller decides whether a
    /// partial graph is worth looking at, exactly as with a file that has type
    /// errors.
    pub fn load(self: *Loader, root_file: []const u8) !Graph {
        self.project_root = self.findProjectRoot(root_file);
        try self.loadFile(root_file);
        return .{ .modules = self.modules.items };
    }

    /// Nearest directory at or above `entry_file` containing an `astra.toml`
    /// (rule 3's anchor), or null. Existence only: the manifest's contents are
    /// the package manager's to read. The walk climbs the *string* parents of
    /// the entry path (all CLI paths are cwd-relative), stops at the top of the
    /// relative tree, and is bounded — a runaway prefix cannot loop.
    fn findProjectRoot(self: *Loader, entry_file: []const u8) ?[]const u8 {
        var dir_name = std.fs.path.dirname(entry_file);
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            const dir = dir_name orelse ""; // "" = the cwd itself
            const manifest = if (dir.len == 0)
                "astra.toml"
            else
                std.fmt.allocPrint(self.a, "{s}/astra.toml", .{dir}) catch return null;
            if (self.dir.access(self.io, manifest, .{})) |_| {
                return if (dir.len == 0) "" else dir;
            } else |_| {}
            if (dir_name == null) return null; // reached the cwd, nothing above
            dir_name = std.fs.path.dirname(dir_name.?);
        }
        return null;
    }

    fn loadFile(self: *Loader, file: []const u8) !void {
        // Cycle check first: a file on the stack is not in `modules` yet
        // (post-order append), so without this a cycle would re-enter the file
        // forever. The already-loaded check only follows it, for diamonds.
        if (self.visitingIndex(file)) |at| {
            self.reportCycle(at, file);
            return;
        }
        if (self.loadedIndex(file) != null) return;

        const source = self.dir.readFileAlloc(self.io, file, self.a, .limited(source_limit)) catch |err| {
            diagnostics_mod.emit(self.diag, file, diagnostics_mod.no_span, "cannot read module: {s}", .{@errorName(err)});
            self.error_count += 1;
            return;
        };

        var tree = ast.Tree.init(self.a, source);
        // Disarmed once the tree is moved into `modules`; until then every
        // failure path (parse error, OOM) tears it down.
        var tree_owned = false;
        defer if (!tree_owned) tree.deinit();
        var p = parser.Parser.init(self.a, source, &tree);
        p.filename = file;
        p.diag = self.diag;
        const root = p.parse() catch {
            // The parser already reported each syntax error with this file's
            // name through the sink; count the module as failed, nothing more.
            self.error_count += 1;
            return;
        };

        const table = collect(self.a, &tree, root, file, .{
            .project_root = self.project_root,
            .diag = self.diag,
        }) catch |err| switch (err) {
            // `resolve` already emitted the diagnostic naming the path and
            // this file; the module cannot be graphed (its decls have no
            // file to follow), so it fails exactly like a parse error.
            error.Reported => {
                self.error_count += 1;
                return;
            },
            else => return err,
        };

        // Post-order: dependencies (and their trees) are complete before this
        // module is appended, so the graph is executable dep-before-user.
        try self.visiting.append(self.a, file);
        for (table.decls) |decl| try self.loadFile(decl.file);
        _ = self.visiting.pop();

        try self.modules.append(self.a, .{
            .file = file,
            .source = source,
            .table = table,
            .tree = tree,
            .root = root,
        });
        tree_owned = true;
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
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.writeAll("circular import: ") catch {};
        for (self.visiting.items[at..]) |step| {
            w.print("{s} -> ", .{step}) catch break;
        }
        w.print("{s}", .{file}) catch {};
        diagnostics_mod.emit(self.diag, file, diagnostics_mod.no_span, "{s}", .{w.buffered()});
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

fn writeExports(writer: anytype, table: ModuleTable) !void {
    if (table.exports.len == 0) return;
    try writer.writeAll("  exports:");
    for (table.exports, 0..) |name, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print(" {s}", .{name});
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
    try writeExports(writer, table);
}

/// Human-readable rendering of a loaded graph, for `--dump-modules`: every file
/// that would take part in the build, in load order (dependencies first), with
/// what each one imports and exports.
pub fn dumpGraph(writer: anytype, graph: Graph) !void {
    try writer.print("module graph: {d} module(s)\n", .{graph.modules.len});
    for (graph.modules) |m| {
        try writer.print("  {s}\n", .{m.file});
        for (m.table.decls) |d| {
            try writer.writeAll("    ");
            try writeDecl(writer, d);
        }
        if (m.table.exports.len > 0) {
            try writer.writeAll("    exports:");
            for (m.table.exports, 0..) |name, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print(" {s}", .{name});
            }
            try writer.writeAll("\n");
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
        // `/` and `.` are equivalent separators (the grammar accepts both).
        .{ "geometry/mesh", "geometry/mesh.astra" },
        .{ "a/b/c", "a/b/c.astra" },
        // Rule 4 rejects the *slash* spelling in `resolve`; as a plain rule-2
        // path `std.io` still maps to a file, which is what a project that
        // ships its own `std/io.astra` wants (and what `use_paths.astra`
        // relies on).
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
        "..", "../etc/passwd", ".hidden", // traversal
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
        .{ "src/main.astra", "lib/util", "src/lib/util.astra" },
    };
    for (cases) |case| {
        const got = try resolveFromFile(a, case[0], case[1]);
        defer a.free(got);
        try std.testing.expectEqualStrings(case[2], got);
    }
}

test "rule 3: @/ anchors at the project root, not the importing file" {
    const a = std.testing.allocator;
    const cases = [_][4][]const u8{
        // importing file, project root, path, expected file
        .{ "src/nested/main.astra", "proj", "@/utils/logger", "proj/utils/logger.astra" },
        .{ "main.astra", "proj", "@/lib", "proj/lib.astra" },
        // The manifest at the cwd keeps the result relative: "" must not
        // forge a leading "/" out of root + "/" + file.
        .{ "src/main.astra", "", "@/lib", "lib.astra" },
    };
    for (cases) |case| {
        const got = try resolve(a, case[0], case[2], case[1], null);
        defer a.free(got);
        try std.testing.expectEqualStrings(case[3], got);
    }
}

test "rule 3 without an astra.toml is reported, not guessed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink = diagnostics_mod.Sink.init(a);
    sink.echo = false;
    defer sink.deinit();

    try std.testing.expectError(
        error.Reported,
        resolve(a, "src/main.astra", "@/lib", null, &sink),
    );
    try std.testing.expectEqual(@as(usize, 1), sink.count());
    try std.testing.expect(sink.items.items[0].msg.len != 0);
    try std.testing.expect(
        std.mem.indexOf(u8, sink.items.items[0].msg, "astra.toml") != null,
    );
    // The diagnostic names the file the bad import was written in.
    try std.testing.expectEqualStrings("src/main.astra", sink.items.items[0].file);
}

test "rule 4: std/ is rejected until a stdlib exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink = diagnostics_mod.Sink.init(a);
    sink.echo = false;
    defer sink.deinit();

    try std.testing.expectError(
        error.Reported,
        resolve(a, "main.astra", "std/io", "proj", &sink),
    );
    try std.testing.expectEqual(@as(usize, 1), sink.count());
    try std.testing.expect(
        std.mem.indexOf(u8, sink.items.items[0].msg, "standard library") != null,
    );
}

test "collect: declarations, resolved files, explicit bindings and exports" {
    const source =
        \\import std.io
        \\import geometry.mesh as mesh
        \\from geometry.vector import Vec2, add as sum
        \\use a.b.c
        \\pub fn helper() -> i32 { 1 }
        \\fn private_fn() -> i32 { 2 }
        \\pub struct Point { x: i32 }
        \\pub enum Shape { Circle }
        \\pub const LIMIT = 5
        \\const SECRET = 6
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

    const table = try collect(a, &tree, root, "src/main.astra", .{});
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

    // Exports: exactly the `pub` top-level declarations, in source order.
    // Private fn/const and non-declaration items contribute nothing.
    try std.testing.expectEqual(@as(usize, 4), table.exports.len);
    try std.testing.expectEqualStrings("helper", table.exports[0]);
    try std.testing.expectEqualStrings("Point", table.exports[1]);
    try std.testing.expectEqualStrings("Shape", table.exports[2]);
    try std.testing.expectEqualStrings("LIMIT", table.exports[3]);
}

test "collect ignores module declarations nested in a function body" {
    // Both frontends accept a module declaration in statement position (the
    // seed reaches `parse_import` from there too), even though research/001
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

    const table = try collect(a, &tree, root, "main.astra", .{});
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

    const table = try collect(a, &tree, root, "main.astra", .{});
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
    defer loader.deinit();
    const entry = try fixture(a, root, "tree/main.astra");
    const graph = try loader.load(entry);

    try std.testing.expectEqual(@as(usize, 0), loader.error_count);
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);

    // Load order is post-order (dependencies first, root last), and every file
    // is resolved relative to the file that imported it:
    // geometry/vector → geometry/mesh → main.
    const mesh = try std.fs.path.join(a, &.{ root, "tree", "geometry", "mesh.astra" });
    const vector = try std.fs.path.join(a, &.{ root, "tree", "geometry", "vector.astra" });
    try std.testing.expectEqualStrings(vector, graph.modules[0].file);
    try std.testing.expectEqualStrings(mesh, graph.modules[1].file);
    try std.testing.expectEqualStrings(entry, graph.modules[2].file);

    // The trees survive loading: the root node of each module is usable.
    for (graph.modules) |m| {
        try std.testing.expectEqual(ast.Tag.source_file, std.meta.activeTag(m.tree.node(m.root)));
    }
    // The leaf's `pub fn leaf` is in its export set.
    try std.testing.expectEqual(@as(usize, 1), graph.modules[0].table.exports.len);
    try std.testing.expectEqualStrings("leaf", graph.modules[0].table.exports[0]);

    try std.testing.expectEqual(Kind.from, graph.modules[1].table.decls[0].kind);
    try std.testing.expectEqualStrings("Vec2", itemBindingName(graph.modules[1].table.decls[0].items[0]));
    try std.testing.expectEqual(Kind.import, graph.modules[2].table.decls[0].kind);
    try std.testing.expectEqual(@as(usize, 0), graph.modules[2].table.exports.len);

    try std.testing.expectEqual(@as(?usize, 0), graph.find(vector));
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
    defer loader.deinit();
    const graph = try loader.load(try fixture(a, root, "diamond/main.astra"));

    try std.testing.expectEqual(@as(usize, 0), loader.error_count);
    // Post-order: shared (reached from one) completes first, then one, two
    // (whose `shared` is already loaded), then main.
    try std.testing.expectEqual(@as(usize, 4), graph.modules.len);
    const shared = try std.fs.path.join(a, &.{ root, "diamond", "shared.astra" });
    try std.testing.expectEqual(@as(?usize, 0), graph.find(shared));
}

test "a circular import is reported instead of loading forever" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try fixtureRoot(io, cwd);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loader = Loader.init(a, io, cwd);
    defer loader.deinit();
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
    defer loader.deinit();
    const entry = try fixture(a, root, "missing/main.astra");
    const graph = try loader.load(entry);

    try std.testing.expectEqual(@as(usize, 1), loader.error_count);
    // The root is still in the graph: one unresolvable import does not throw
    // away the file that was fine.
    try std.testing.expectEqual(@as(usize, 1), graph.modules.len);
    try std.testing.expectEqualStrings(entry, graph.modules[0].file);
}

test "the project root anchors @/ imports (rule 3)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try fixtureRoot(io, cwd);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loader = Loader.init(a, io, cwd);
    defer loader.deinit();
    const entry = try fixture(a, root, "rootproj/main.astra");
    const graph = try loader.load(entry);

    try std.testing.expectEqual(@as(usize, 0), loader.error_count);
    // The walk up from main.astra stopped at rootproj/ — its astra.toml.
    const proj = try fixture(a, root, "rootproj");
    try std.testing.expectEqualStrings(proj, loader.project_root.?);
    // lib/leaf (post-order), then main: `@/lib.leaf` resolved from the root,
    // not from the importing file's directory.
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    const leaf = try fixture(a, root, "rootproj/lib/leaf.astra");
    try std.testing.expectEqualStrings(leaf, graph.modules[0].file);
    try std.testing.expectEqualStrings(entry, graph.modules[1].file);
}

test "@/ without an astra.toml anywhere is reported, not guessed" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try fixtureRoot(io, cwd);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sink = diagnostics_mod.Sink.init(a);
    sink.echo = false;
    defer sink.deinit();

    var loader = Loader.init(a, io, cwd);
    defer loader.deinit();
    loader.diag = &sink;
    const entry = try fixture(a, root, "noroot/main.astra");
    const graph = try loader.load(entry);

    try std.testing.expectEqual(@as(usize, 1), loader.error_count);
    // The file with the bad import cannot be graphed at all.
    try std.testing.expectEqual(@as(usize, 0), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 1), sink.count());
    const msg = sink.items.items[0].msg;
    try std.testing.expect(std.mem.indexOf(u8, msg, "astra.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "@/lib") != null);
}

test "std/ is rejected until a stdlib exists (rule 4)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try fixtureRoot(io, cwd);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sink = diagnostics_mod.Sink.init(a);
    sink.echo = false;
    defer sink.deinit();

    var loader = Loader.init(a, io, cwd);
    defer loader.deinit();
    loader.diag = &sink;
    const entry = try fixture(a, root, "stdlib/main.astra");
    const graph = try loader.load(entry);

    try std.testing.expectEqual(@as(usize, 1), loader.error_count);
    try std.testing.expectEqual(@as(usize, 0), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 1), sink.count());
    const msg = sink.items.items[0].msg;
    try std.testing.expect(std.mem.indexOf(u8, msg, "standard library") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "std/io") != null);
}
