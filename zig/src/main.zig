//! Astra Phase 2 compiler — CLI entry point.
//!
//! At this stage the frontend can lex and parse Astra-0. The driver exposes the
//! two introspection modes the seed has (`--dump-tokens`, `--dump-ast`) so the
//! port can be compared against `seed/astra-seed` file by file, plus a default
//! parse check that exits non-zero on a syntax error.

const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const ast = @import("ast/ast.zig");
const parser = @import("parser/parser.zig");
const typechecker = @import("typechecker/typechecker.zig");
const emitter = @import("emitter/emitter.zig");
const bytecode = @import("emitter/bytecode.zig");
const vm_mod = @import("vm/vm.zig");
const modules_mod = @import("modules/modules.zig");
const diagnostics = @import("diagnostics.zig");

const Mode = enum { parse, tokens, ast_dump, bytecode, modules };

const usage =
    \\usage: astra-zig [--dump-tokens | --dump-ast | --dump-modules | --dump-bytecode | --debug] <file.astra>
    \\
    \\  (no flag)        compile and run, exit 1 on a compile or runtime error
    \\  --dump-tokens    print the token stream
    \\  --dump-ast       print the parsed AST
    \\  --dump-modules   load and print the module graph (files reached, cycles reported)
    \\  --dump-bytecode  print the emitted bytecode
    \\  --debug          run under the interactive bytecode debugger (stdin)
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var mode: Mode = .parse;
    var debug = false;
    var path: ?[]const u8 = null;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dump-tokens")) {
            mode = .tokens;
        } else if (std.mem.eql(u8, arg, "--dump-ast")) {
            mode = .ast_dump;
        } else if (std.mem.eql(u8, arg, "--dump-modules")) {
            mode = .modules;
        } else if (std.mem.eql(u8, arg, "--dump-bytecode")) {
            mode = .bytecode;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("error: unknown flag {s}\n{s}", .{ arg, usage });
            std.process.exit(2);
        } else {
            path = arg;
        }
    }

    const file = path orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };

    const dir = std.Io.Dir.cwd();
    const source = dir.readFileAlloc(io, file, allocator, .limited(1 << 26)) catch |err| {
        std.debug.print("error: cannot read {s}: {s}\n", .{ file, @errorName(err) });
        std.process.exit(2);
    };
    defer allocator.free(source);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every compiler phase reports through this one sink: one record shape
    // (`Diagnostic{file, span, msg}`), one format, and — when the CLI exits
    // on a compile error — one place that has seen every message.
    var diag = diagnostics.Sink.init(a);
    defer diag.deinit();

    // Output is assembled in a buffer and flushed at once; the dumps go to
    // stderr like `std.debug.print`, matching the seed's introspection flags.
    const out = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(out);
    var w = std.Io.Writer.fixed(out);

    if (mode == .tokens) {
        var tk = lexer.Tokenizer.init(a, source);
        while (true) {
            const t = tk.next();
            try w.print("{d}:{d}\t{s}\t{s}\n", .{ t.loc.line, t.loc.col, t.tag.name(), t.text });
            if (t.tag == .eof) break;
            if (t.tag == .lex_err) {
                std.debug.print("{s}", .{w.buffered()});
                std.process.exit(1);
            }
        }
        std.debug.print("{s}", .{w.buffered()});
        return;
    }

    var tree = ast.Tree.init(a, source);
    defer tree.deinit();
    var p = parser.Parser.init(a, source, &tree);
    p.filename = file;
    p.diag = &diag;
    const root = p.parse() catch {
        std.process.exit(1);
    };

    if (mode == .ast_dump) {
        try tree.dump(&w, root);
        std.debug.print("{s}", .{w.buffered()});
        return;
    }

    // Module resolution is groundwork (modules/modules.zig): the declarations
    // become a graph of files, but nothing links them yet — the type checker
    // still sees one file. It runs before the type checker because loading
    // belongs to the frontend, not to the stages that assume a single file.
    if (mode == .modules) {
        var loader = modules_mod.Loader.init(a, io, dir);
        defer loader.deinit();
        loader.diag = &diag;
        const graph = try loader.load(file);
        try modules_mod.dumpGraph(&w, graph);
        std.debug.print("{s}", .{w.buffered()});
        // A module that cannot be read, does not parse, or takes part in a
        // cycle is a failed build — the same exit status it will have once
        // files are actually linked.
        if (loader.error_count > 0) std.process.exit(1);
        return;
    }

    // Multi-module: the entry file declares imports, so the loader builds the
    // graph and every module is checked (shared type pool, `pub` gating) and
    // executed in dependency order on one VM. A single-file program takes the
    // unchanged path below.
    const entry_items = tree.extraSlice(tree.node(root).source_file);
    var has_module_decls = false;
    for (entry_items) |it| {
        switch (tree.node(it)) {
            .use_decl, .import_decl, .from_decl => has_module_decls = true,
            else => {},
        }
    }

    if (has_module_decls) {
        try compileAndRunMulti(a, io, dir, file, source, out, mode, debug, init, &diag);
        return;
    }

    var tc = try typechecker.TypeChecker.init(a, &tree, file);
    tc.diag = &diag;
    tc.check(root);
    if (tc.error_count > 0) std.process.exit(1);

    var em = emitter.Emitter.init(a, &tree, file);
    em.diag = &diag;
    em.emit(root);
    if (em.error_count > 0) std.process.exit(1);

    if (mode == .bytecode) {
        var bw = std.Io.Writer.fixed(out);
        try bytecode.dump(&bw, em.code.items, em.constants.items);
        std.debug.print("{s}", .{bw.buffered()});
        return;
    }

    // Default mode runs the program. Its output goes to stdout; diagnostics
    // go to stderr, so a caller can compare the program's stdout alone
    // (which is exactly what the conformance runner does).
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);

    var machine = try vm_mod.VM.init(a, &stdout_writer.interface);
    // Low-level debug switches, the seed's environment variables: dump the
    // bytecode (and each called function) and/or trace the stack per
    // instruction. Both write to stderr, never to the program's stdout.
    machine.dump_vm = init.environ_map.contains("ASTRA_DUMP_VM");
    machine.trace = init.environ_map.contains("ASTRA_TRACE");

    // The stdin reader must outlive the run: `enableDebug` keeps a pointer.
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    if (debug) machine.enableDebug(&stdin_reader.interface, source);

    const res = machine.run(em.code.items, em.constants.items) catch |e| {
        std.debug.print("error: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    stdout_writer.interface.flush() catch {};

    if (res != .ok) {
        std.debug.print("{s}:{d}: runtime error: {s}\n", .{ file, machine.error_line, machine.error_msg });
        std.process.exit(1);
    }
}

/// Last segment of a dotted import path: `import geometry.mesh` (no `as`)
/// binds `mesh` (decision recorded in `PHASE2_GAP_ANALYSIS.md` App. B #11,
/// per `ARCHITECTURE.md` §10.1 file-as-module).
fn lastSegment(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |i| return path[i + 1 ..];
    return path;
}

/// Compile and run a program whose entry file declares imports: load the
/// module graph, typecheck every module against a shared type pool (imports
/// resolve to the exporting module's `pub` declarations), then emit and run
/// each module's top-level code in dependency order — the root's `main` runs
/// last. The loader re-reads the entry from disk like every other module
/// (one parse per module, one owner).
fn compileAndRunMulti(
    a: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    file: []const u8,
    source: []const u8,
    out: []u8,
    mode: Mode,
    debug: bool,
    init: std.process.Init,
    diag: *diagnostics.Sink,
) !void {
    var loader = modules_mod.Loader.init(a, io, dir);
    defer loader.deinit();
    loader.diag = diag;
    const graph = try loader.load(file);
    if (loader.error_count > 0) std.process.exit(1);

    const n = graph.modules.len;
    const pool = try a.create(typechecker.TypePool);
    pool.* = try typechecker.TypePool.init(a);

    // `m{i}.` mangles module i's globals; graph order is post-order, so the
    // root is the last module.
    const mangled = try a.alloc([]const u8, n);
    for (mangled, 0..) |*slot, i| {
        slot.* = std.fmt.allocPrint(a, "m{d}.", .{i}) catch @panic("OOM");
    }

    const exports = try a.alloc([]typechecker.Export, n);
    const module_imports = try a.alloc([]emitter.ImportRef, n);
    // Re-export bookkeeping per module: which module actually declares each
    // exported name (`use` forwards it), and the alias table an `import`er of
    // this module needs for `m.x` reads of forwarded names.
    const OwnedExport = struct { ex: typechecker.Export, module: usize };
    const owners = try a.alloc(std.ArrayListUnmanaged(OwnedExport), n);
    const aliases = try a.alloc(std.ArrayListUnmanaged(emitter.NameAlias), n);
    for (owners, aliases) |*os, *als| {
        os.* = .empty;
        als.* = .empty;
    }

    var errors: usize = 0;
    for (graph.modules, 0..) |*m, i| {
        var mtc = try typechecker.TypeChecker.initWithPool(a, &m.tree, m.file, pool);
        mtc.diag = diag;

        var bindings: std.ArrayListUnmanaged(typechecker.ImportBinding) = .empty;
        var em_imports: std.ArrayListUnmanaged(emitter.ImportRef) = .empty;
        for (m.table.decls) |decl| {
            const dep_i = graph.find(decl.file) orelse continue; // loader guarantees it
            const dep_exports = exports[dep_i];
            switch (decl.kind) {
                .from => {
                    for (decl.items) |item| {
                        const bound = modules_mod.itemBindingName(item);
                        var found: ?typechecker.Export = null;
                        for (dep_exports) |ex| {
                            if (std.mem.eql(u8, ex.name, item.name)) {
                                found = ex;
                                break;
                            }
                        }
                        if (found == null) {
                            diagnostics.emit(diag, m.file, diagnostics.no_span, "module '{s}' does not export '{s}'", .{ decl.path, item.name });
                            errors += 1;
                            continue;
                        }
                        // A forwarded name's global lives in its owner, not in
                        // the module the `from` names.
                        var owner = dep_i;
                        for (owners[dep_i].items) |ow| {
                            if (std.mem.eql(u8, ow.ex.name, item.name)) {
                                owner = ow.module;
                                break;
                            }
                        }
                        try bindings.append(a, .{ .local = bound, .type_ = found.?.type_ });
                        try em_imports.append(a, .{
                            .local = bound,
                            .target = std.fmt.allocPrint(a, "{s}{s}", .{ mangled[owner], item.name }) catch @panic("OOM"),
                        });
                    }
                },
                .import => {
                    const local = decl.alias orelse lastSegment(decl.path);
                    try bindings.append(a, .{ .local = local, .type_ = undefined, .module_exports = dep_exports });
                    try em_imports.append(a, .{ .local = local, .module_prefix = mangled[dep_i], .aliases = aliases[dep_i].items });
                },
                .use => {}, // merged into this module's exports below
            }
        }
        mtc.injectImports(bindings.items);
        mtc.check(m.root);
        errors += mtc.error_count;

        // Exports: this module's own `pub` decls first (a local name wins any
        // collision), then each `use` dep's exports it doesn't already name.
        // `owners` records where each name really lives, post-order so a dep's
        // list is already complete.
        const own = mtc.collectExports(m.tree.extraSlice(m.tree.node(m.root).source_file));
        var merged: std.ArrayListUnmanaged(typechecker.Export) = .empty;
        for (own) |ex| {
            try merged.append(a, ex);
            try owners[i].append(a, .{ .ex = ex, .module = i });
        }
        for (m.table.decls) |decl| {
            if (decl.kind != .use) continue;
            const d = graph.find(decl.file) orelse continue;
            for (exports[d]) |ex| {
                var dup = false;
                for (owners[i].items) |ow| {
                    if (std.mem.eql(u8, ow.ex.name, ex.name)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                var real = d;
                for (owners[d].items) |ow| {
                    if (std.mem.eql(u8, ow.ex.name, ex.name)) {
                        real = ow.module;
                        break;
                    }
                }
                try merged.append(a, ex);
                try owners[i].append(a, .{ .ex = ex, .module = real });
            }
        }
        exports[i] = merged.items;

        // Alias table for `import`ers: forwarded names are globals of their
        // owner. Struct/enum exports are types, not globals — consumers
        // resolve them through the registries (and a type read stays the
        // shared single-file runtime error).
        for (owners[i].items) |ow| {
            if (ow.module == i) continue;
            if (ow.ex.type_.kind == .struct_ or ow.ex.type_.kind == .enum_) continue;
            try aliases[i].append(a, .{
                .name = ow.ex.name,
                .target = std.fmt.allocPrint(a, "{s}{s}", .{ mangled[ow.module], ow.ex.name }) catch @panic("OOM"),
            });
        }
        module_imports[i] = em_imports.items;
    }
    if (errors > 0) std.process.exit(1);

    // Each module's struct/enum registries, filled as modules emit (the
    // loader's post-order guarantees a dependency is done before an importer
    // asks for it) so literals and patterns can cross module boundaries.
    const own_types = try a.alloc(emitter.ModuleTypes, n);
    for (own_types) |*t| t.* = .{};

    if (mode == .bytecode) {
        var bw = std.Io.Writer.fixed(out);
        for (graph.modules, 0..) |*m, i| {
            var mem = emitter.Emitter.initWithModules(a, &m.tree, m.file, mangled[i], module_imports[i]);
            mem.diag = diag;
            const ft = try emitter.collectForeign(a, &graph, m.table.decls, own_types, mangled);
            mem.setForeignTypes(ft.structs, ft.enums, ft.namespaces);
            if (i == n - 1) {
                mem.emit(m.root);
            } else {
                mem.emitModule(m.root);
            }
            if (mem.error_count > 0) std.process.exit(1);
            try emitter.captureOwnTypes(a, &graph, m.table.decls, &mem, own_types, i);
            try bw.print("== {s} ==\n", .{m.file});
            try bytecode.dump(&bw, mem.code.items, mem.constants.items);
        }
        std.debug.print("{s}", .{bw.buffered()});
        return;
    }

    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);

    var machine = try vm_mod.VM.init(a, &stdout_writer.interface);
    machine.dump_vm = init.environ_map.contains("ASTRA_DUMP_VM");
    machine.trace = init.environ_map.contains("ASTRA_TRACE");

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    // The debugger maps lines against one source; on a multi-module program
    // it shows the entry file's lines for every module (known limitation).
    if (debug) machine.enableDebug(&stdin_reader.interface, source);

    for (graph.modules, 0..) |*m, i| {
        var mem = emitter.Emitter.initWithModules(a, &m.tree, m.file, mangled[i], module_imports[i]);
        mem.diag = diag;
        const ft = try emitter.collectForeign(a, &graph, m.table.decls, own_types, mangled);
        mem.setForeignTypes(ft.structs, ft.enums, ft.namespaces);
        if (i == n - 1) {
            mem.emit(m.root);
        } else {
            mem.emitModule(m.root);
        }
        if (mem.error_count > 0) std.process.exit(1);
        try emitter.captureOwnTypes(a, &graph, m.table.decls, &mem, own_types, i);

        // Each module's code is arena-owned and stays valid: `run` only keeps
        // pointers into it, and the globals table carries across calls, so
        // dependencies' bindings are still there when the importer runs.
        const res = machine.run(mem.code.items, mem.constants.items) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        if (res != .ok) {
            stdout_writer.interface.flush() catch {};
            std.debug.print("{s}:{d}: runtime error: {s}\n", .{ m.file, machine.error_line, machine.error_msg });
            std.process.exit(1);
        }
    }
    stdout_writer.interface.flush() catch {};
}
