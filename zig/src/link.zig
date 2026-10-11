//! Multi-module link — the end-to-end counterpart of `main.zig`'s
//! multi-module path: load the `tests/link` fixture project, typecheck every
//! module against one shared type pool with `pub` gating, emit each module
//! with mangled globals and import maps, and run them in dependency order on
//! one VM. The fixture output is the regression net for the whole chain
//! (loader → exports → typechecker imports → emitter mangling → VM globals).

const std = @import("std");
const ast = @import("ast/ast.zig");
const parser = @import("parser/parser.zig");
const typechecker = @import("typechecker/typechecker.zig");
const emitter = @import("emitter/emitter.zig");
const vm = @import("vm/vm.zig");
const modules = @import("modules/modules.zig");

const fixture_candidates = [_][]const u8{ "tests/link", "../tests/link" };

fn fixtureRoot(io: std.Io, cwd: std.Io.Dir) ![]const u8 {
    for (fixture_candidates) |candidate| {
        cwd.access(io, candidate, .{}) catch continue;
        return candidate;
    }
    return error.LinkFixturesNotFound;
}

fn lastSegment(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |i| return path[i + 1 ..];
    return path;
}

test "multi-module program compiles and runs" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try fixtureRoot(io, cwd);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loader = modules.Loader.init(a, io, cwd);
    defer loader.deinit();
    const entry = try std.fs.path.join(a, &.{ root, "main.astra" });
    const graph = try loader.load(entry);
    try std.testing.expectEqual(@as(usize, 0), loader.error_count);
    // mathx, shape, then main (post-order).
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expectEqual(@as(?usize, 2), graph.find(entry));

    const pool = try a.create(typechecker.TypePool);
    pool.* = try typechecker.TypePool.init(a);

    const n = graph.modules.len;
    const mangled = try a.alloc([]const u8, n);
    for (mangled, 0..) |*slot, i| {
        slot.* = std.fmt.allocPrint(a, "m{d}.", .{i}) catch @panic("OOM");
    }
    const exports = try a.alloc([]typechecker.Export, n);
    const module_imports = try a.alloc([]emitter.ImportRef, n);

    var errors: usize = 0;
    for (graph.modules, 0..) |*m, i| {
        var mtc = try typechecker.TypeChecker.initWithPool(a, &m.tree, m.file, pool);
        var bindings: std.ArrayListUnmanaged(typechecker.ImportBinding) = .empty;
        var em_imports: std.ArrayListUnmanaged(emitter.ImportRef) = .empty;
        for (m.table.decls) |decl| {
            const dep_i = graph.find(decl.file).?;
            const dep_exports = exports[dep_i];
            switch (decl.kind) {
                .from => {
                    for (decl.items) |item| {
                        const bound = modules.itemBindingName(item);
                        var found: ?typechecker.Export = null;
                        for (dep_exports) |ex| {
                            if (std.mem.eql(u8, ex.name, item.name)) {
                                found = ex;
                                break;
                            }
                        }
                        if (found == null) {
                            errors += 1;
                            continue;
                        }
                        try bindings.append(a, .{ .local = bound, .type_ = found.?.type_ });
                        try em_imports.append(a, .{
                            .local = bound,
                            .target = std.fmt.allocPrint(a, "{s}{s}", .{ mangled[dep_i], item.name }) catch @panic("OOM"),
                        });
                    }
                },
                .import => {
                    const local = decl.alias orelse lastSegment(decl.path);
                    try bindings.append(a, .{ .local = local, .type_ = undefined, .module_exports = dep_exports });
                    try em_imports.append(a, .{ .local = local, .module_prefix = mangled[dep_i] });
                },
                .use => errors += 1,
            }
        }
        mtc.injectImports(bindings.items);
        mtc.check(m.root);
        errors += mtc.error_count;
        exports[i] = mtc.collectExports(m.tree.extraSlice(m.tree.node(m.root).source_file));
        module_imports[i] = em_imports.items;
    }
    try std.testing.expectEqual(@as(usize, 0), errors);

    // mathx exports exactly the two `pub` declarations; shape and main export
    // what their sources mark (main: none).
    try std.testing.expectEqual(@as(usize, 2), exports[0].len);
    try std.testing.expectEqualStrings("PI2", exports[0][0].name);
    try std.testing.expectEqualStrings("add", exports[0][1].name);
    try std.testing.expectEqual(@as(usize, 0), exports[2].len);

    var out_buf: [4096]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var machine = try vm.VM.init(a, &out_w);
    for (graph.modules, 0..) |*m, i| {
        var mem = emitter.Emitter.initWithModules(a, &m.tree, m.file, mangled[i], module_imports[i]);
        if (i == n - 1) {
            mem.emit(m.root);
        } else {
            mem.emitModule(m.root);
        }
        try std.testing.expectEqual(@as(usize, 0), mem.error_count);
        const res = try machine.run(mem.code.items, mem.constants.items);
        try std.testing.expectEqual(vm.VMResult.ok, res);
    }
    try std.testing.expectEqualStrings("5\n6\n8\n20\n30\n", out_w.buffered());
}

test "importing a private name is rejected" {
    const source =
        \\pub const V = 1
        \\fn hidden() -> i32 { 2 }
    ;
    const user =
        \\from dep import hidden
        \\fn main() { print(hidden()) }
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dep_tree = ast.Tree.init(a, source);
    defer dep_tree.deinit();
    var dp = parser.Parser.init(a, source, &dep_tree);
    const dep_root = try dp.parse();

    var user_tree = ast.Tree.init(a, user);
    defer user_tree.deinit();
    var up = parser.Parser.init(a, user, &user_tree);
    const user_root = try up.parse();

    const pool = try a.create(typechecker.TypePool);
    pool.* = try typechecker.TypePool.init(a);

    var dep_tc = try typechecker.TypeChecker.initWithPool(a, &dep_tree, "dep.astra", pool);
    dep_tc.check(dep_root);
    try std.testing.expectEqual(@as(usize, 0), dep_tc.error_count);
    const dep_items = dep_tree.extraSlice(dep_tree.node(dep_root).source_file);
    const dep_exports = dep_tc.collectExports(dep_items);
    // Only `V` is exported — the driver looks a `from` item up in this list
    // and never injects a name that is absent (pub gating), so the importer
    // sees `hidden` as undefined.
    try std.testing.expectEqual(@as(usize, 1), dep_exports.len);
    try std.testing.expectEqualStrings("V", dep_exports[0].name);
    for (dep_exports) |ex| {
        try std.testing.expect(!std.mem.eql(u8, ex.name, "hidden"));
    }

    var user_tc = try typechecker.TypeChecker.initWithPool(a, &user_tree, "main.astra", pool);
    user_tc.check(user_root);
    try std.testing.expect(user_tc.error_count > 0);
}
