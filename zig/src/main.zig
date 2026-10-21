//! Astra Phase 2 compiler — CLI entry point.
//!
//! At this stage the frontend can lex and parse Astra-0. The driver exposes the
//! two introspection modes the seed has (`--dump-tokens`, `--dump-ast`) so the
//! port can be compared against `seed/astra-seed` file by file, plus a default
//! parse check that exits non-zero on a syntax error.

const std = @import("std");
const build_options = @import("build_options");
const lexer = @import("lexer/lexer.zig");
const ast = @import("ast/ast.zig");
const parser = @import("parser/parser.zig");
const typechecker = @import("typechecker/typechecker.zig");
const emitter = @import("emitter/emitter.zig");
const bytecode = @import("emitter/bytecode.zig");
const vm_mod = @import("vm/vm.zig");
const modules_mod = @import("modules/modules.zig");
const diagnostics = @import("diagnostics.zig");
const dump_mod = @import("dump.zig");
// Fachata del backend LLVM (M0.3): solo existe bajo `-Dllvm`. La condición es
// comptime, así que sin el flag esta rama no se analiza y el `@cImport` de
// llvm-c jamás se traduce — `astra-zig` sin LLVM sigue compilando igual.
const llvm = if (build_options.llvm_enabled) @import("llvm.zig") else void;

const Mode = enum { parse, tokens, ast_dump, bytecode, modules, emit_llvm, emit_llvm_stdout, emit_obj };

/// Sanitizer pedido por CLI (M4.d). Vive aquí, sin el tipo del backend, para
/// que `astra-zig` sin `-Dllvm` siga compilando: `llvm` es `void` en ese build.
const Sanitize = enum {
    none,
    address,
};

const usage =
    \\usage: astra-zig [--single-file] [--dump-tokens | --dump-ast | --dump-modules | --dump-bytecode | --emit-llvm | --emit-llvm-stdout | --emit-obj | --debug] <file.astra>
    \\
    \\  (no flag)              compile and run, exit 1 on a compile or runtime error
    \\  --single-file          ignore `import`/`from`/`use` and compile only the entry
    \\                         file (seed semantics; needed for module-decl fixtures)
    \\  --dump-tokens          print the token stream
    \\  --dump-ast             print the parsed AST
    \\  --dump-modules         load and print the module graph (files reached, cycles reported)
    \\  --dump-bytecode        print the emitted bytecode
    \\  --emit-llvm            write LLVM IR to <file>.ll (requires -Dllvm)
    \\  --emit-llvm-stdout     print LLVM IR to stdout (requires -Dllvm)
    \\  --emit-obj             compile to a native object <file>.o via TargetMachine (requires -Dllvm)
    \\  --opt-level=N          optimize the LLVM module before emitting (N = 0..3; 0 default)
    \\  --debug-info           emit DWARF line tables (lldb/gdb stop on Astra lines)
    \\  --sanitize=address     instrument the module with AddressSanitizer
    \\                         (needs an LLVM output mode; link with -fsanitize=address)
    \\  --debug                run under the interactive bytecode debugger (stdin)
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var mode: Mode = .parse;
    var debug = false;
    var single_file = false;
    var opt_level: u8 = 0;
    var debug_info = false;
    var sanitize: Sanitize = .none;
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
        } else if (std.mem.eql(u8, arg, "--emit-llvm")) {
            mode = .emit_llvm;
        } else if (std.mem.eql(u8, arg, "--emit-llvm-stdout")) {
            mode = .emit_llvm_stdout;
        } else if (std.mem.eql(u8, arg, "--emit-obj")) {
            mode = .emit_obj;
        } else if (std.mem.eql(u8, arg, "--single-file")) {
            single_file = true;
        } else if (std.mem.eql(u8, arg, "--debug-info")) {
            debug_info = true;
        } else if (std.mem.startsWith(u8, arg, "--sanitize=")) {
            const val = arg["--sanitize=".len..];
            if (std.mem.eql(u8, val, "address")) {
                sanitize = .address;
            } else {
                std.debug.print("error: --sanitize expects 'address', got {s}\n{s}", .{ val, usage });
                std.process.exit(2);
            }
        } else if (std.mem.startsWith(u8, arg, "--opt-level=")) {
            opt_level = std.fmt.parseInt(u8, arg["--opt-level=".len..], 10) catch {
                std.debug.print("error: --opt-level expects 0..3, got {s}\n{s}", .{ arg, usage });
                std.process.exit(2);
            };
            if (opt_level > 3) {
                std.debug.print("error: --opt-level expects 0..3, got {d}\n{s}", .{ opt_level, usage });
                std.process.exit(2);
            }
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

    // Un sanitizer sólo tiene sentido sobre un artefacto del backend LLVM; con
    // el modo por defecto (VM) o los dumps se ignora en silencio, así que se
    // rechaza explícitamente en vez de aparentar que instrumenta.
    if (sanitize != .none and mode != .emit_llvm and mode != .emit_llvm_stdout and mode != .emit_obj) {
        std.debug.print("error: --sanitize requires an LLVM output mode (--emit-llvm, --emit-llvm-stdout or --emit-obj)\n{s}", .{usage});
        std.process.exit(2);
    }

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

    // Output is assembled in a buffer and flushed at once; the dump flags
    // write to stdout like the seed's (parity-gated), other debug output to
    // stderr.
    const out = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(out);
    var w = std.Io.Writer.fixed(out);

    if (mode == .tokens) {
        // The seed's --dump-tokens prints to stdout (driver.c token_print);
        // the parity gate diffs both streams byte for byte.
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(io, &stdout_buf);
        var tk = lexer.Tokenizer.init(a, source);
        while (true) {
            const t = tk.next();
            try dump_mod.printToken(&stdout_writer.interface, t);
            if (t.tag == .eof) break;
            if (t.tag == .lex_err) {
                stdout_writer.interface.flush() catch {};
                std.process.exit(1);
            }
        }
        stdout_writer.interface.flush() catch {};
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
        // Same stdout destination as the seed's driver.c run_dump_ast.
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(io, &stdout_buf);
        try tree.dump(&stdout_writer.interface, root);
        stdout_writer.interface.flush() catch {};
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
    // unchanged path below. `--single-file` forces the seed's semantics
    // (module declarations parsed and discarded), which is what the module
    // conformance fixtures assert: they name imports that must NOT be
    // resolved, and the LLVM emitter is single-file by construction.
    const entry_items = tree.extraSlice(tree.node(root).source_file);
    var has_module_decls = false;
    for (entry_items) |it| {
        switch (tree.node(it)) {
            .use_decl, .import_decl, .from_decl => has_module_decls = true,
            else => {},
        }
    }

    if (has_module_decls and !single_file) {
        try compileAndRunMulti(a, io, dir, file, source, out, mode, debug, init, &diag);
        return;
    }

    var tc = try typechecker.TypeChecker.init(a, &tree, file);
    tc.diag = &diag;
    tc.check(root);
    if (tc.error_count > 0) std.process.exit(1);

    // Backend LLVM (opt-in, M0.3): tras el typecheck, genera IR u objeto y
    // sale. No necesita el emisor de bytecode ni la VM — el emisor LLVM
    // camina el AST.
    if (mode == .emit_llvm or mode == .emit_llvm_stdout or mode == .emit_obj) {
        emitLlvm(a, io, file, &tree, root, mode, &diag, &tc, opt_level, debug_info, sanitize);
        return;
    }

    var em = emitter.Emitter.init(a, &tree, file);
    em.diag = &diag;
    // Phase 2.4 step 2b: hand the materialized generic instances to the
    // emitter (the checker already appended each wrapper to the module).
    if (tc.instances.items.len > 0) {
        var em_inst = try a.alloc(emitter.Instance, tc.instances.items.len);
        for (tc.instances.items, 0..) |inst, i| {
            const rws = try a.alloc(emitter.Rewrite, inst.rewrites.items.len);
            for (inst.rewrites.items, 0..) |rw, j| {
                rws[j] = .{ .callee = rw.callee, .name = rw.name };
            }
            em_inst[i] = .{ .wrapper = inst.wrapper, .rewrites = rws };
        }
        em.setInstances(em_inst);
    }
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

/// Genera LLVM IR para el subconjunto M0 (Fase LLVM M0.3). Requiere el build
/// `-Dllvm`; sin él sale con un error accionable. Con él, emite, verifica el
/// módulo y escribe `<file>.ll` (o lo imprime por stdout con la variante
/// `--emit-llvm-stdout`). Todo lo fuera de M0 lo rechaza el emisor con un
/// diagnóstico limpio (exit 1) sin escribir IR.
fn emitLlvm(
    a: std.mem.Allocator,
    io: std.Io,
    file: []const u8,
    tree: *ast.Tree,
    root: u32,
    mode: Mode,
    diag: *diagnostics.Sink,
    tc: *typechecker.TypeChecker,
    opt_level: u8,
    debug_info: bool,
    sanitize: Sanitize,
) void {
    // `build_options.llvm_enabled` es comptime: sin -Dllvm solo se analiza esta
    // rama y `llvm.Emitter` (que sería `void`) jamás se referencia.
    if (build_options.llvm_enabled) {
        var em = llvm.Emitter.init(a, tree, file);
        defer em.deinit();
        em.diag = diag;
        if (debug_info) em.enableDebugInfo(opt_level);
        const san_kind: ?llvm.Sanitizer = switch (sanitize) {
            .none => null,
            .address => .address,
        };
        if (san_kind) |kind| em.enableSanitizer(kind);
        // Instancias genéricas materializadas por el checker (Phase 2.4
        // steps 2b/3b): wrappers de fn con sus rewrites y un layout por
        // instancia de struct (los ptypes de print/eq difieren).
        if (tc.instances.items.len > 0) {
            const inst = a.alloc(llvm.Instance, tc.instances.items.len) catch @panic("OOM");
            for (tc.instances.items, 0..) |src, i| {
                const rws = a.alloc(llvm.Rewrite, src.rewrites.items.len) catch @panic("OOM");
                for (src.rewrites.items, 0..) |rw, j| rws[j] = .{ .callee = rw.callee, .name = rw.name };
                inst[i] = .{ .wrapper = src.wrapper, .rewrites = rws };
            }
            em.setInstances(inst);
        }
        if (tc.struct_instances.items.len > 0) {
            const si = a.alloc(llvm.StructInstance, tc.struct_instances.items.len) catch @panic("OOM");
            for (tc.struct_instances.items, 0..) |src, i| {
                si[i] = .{ .name = src.name, .source_name = src.source_name, .decl = src.decl, .fields = src.fields };
            }
            em.setStructInstances(si);
        }
        em.emit(root);
        if (em.error_count > 0) std.process.exit(1);
        // M4.d: instrumentación antes del pipeline de optimización (el orden de
        // clang) para que las pasadas vean los accesos que el asan/ubsan marca.
        if (san_kind) |kind| {
            if (!llvm.instrumentSanitizer(em.mod, diag, file, kind)) std.process.exit(1);
        }
        // M4: pipeline del new PM antes de verificar/emitir. Nivel 0 (default)
        // deja el módulo intacto: los gates de IR y paridad no cambian.
        if (!llvm.runPasses(em.mod, diag, file, opt_level)) std.process.exit(1);
        if (!llvm.verify(em.mod, diag, file)) std.process.exit(1);
        if (mode == .emit_llvm_stdout) {
            const ir = llvm.printToString(a, em.mod);
            var stdout_buf: [4096]u8 = undefined;
            const stdout_file = std.Io.File.stdout();
            var stdout_writer = stdout_file.writer(io, &stdout_buf);
            stdout_writer.interface.writeAll(ir) catch {};
            stdout_writer.interface.flush() catch {};
        } else {
            const base = if (std.mem.endsWith(u8, file, ".astra")) file[0 .. file.len - ".astra".len] else file;
            if (mode == .emit_obj) {
                // M2.e: TargetMachineEmitToFile produce el .o directamente —
                // la ruta LLVM ya no subprocesa `llc`.
                const out_path = std.fmt.allocPrintSentinel(a, "{s}.o", .{base}, 0) catch @panic("OOM");
                if (!llvm.emitObjectFile(em.mod, diag, file, out_path)) std.process.exit(1);
            } else {
                const out_path = std.fmt.allocPrintSentinel(a, "{s}.ll", .{base}, 0) catch @panic("OOM");
                llvm.writeToFile(em.mod, out_path) catch std.process.exit(1);
            }
        }
    } else {
        std.debug.print(
            "error: the LLVM backend output modes (--emit-llvm / --emit-llvm-stdout / --emit-obj) require the compiler to be built with `-Dllvm` (LLVM 19..23 via llvm-config)\n",
            .{},
        );
        std.process.exit(2);
    }
}

/// Last segment of an import path: `import geometry.mesh` (no `as`) binds
/// `mesh`, `import @/utils/logger` binds `logger` — both separators of
/// `ImportPath` count (decision recorded in `PHASE2_GAP_ANALYSIS.md` App. B
/// #11, per `ARCHITECTURE.md` §10.1 file-as-module).
fn lastSegment(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfAny(u8, path, "./")) |i| return path[i + 1 ..];
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
    // M0.3: el emisor LLVM aún no resuelve varios módulos. Se rechaza limpio
    // (como cualquier otra limitación de M0) en vez de emitir IR incompleto.
    if (mode == .emit_llvm or mode == .emit_llvm_stdout or mode == .emit_obj) {
        std.debug.print("error: the LLVM backend output modes do not yet support multi-module programs (LLVM M0)\n", .{});
        std.process.exit(2);
    }
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
    // Per-module generic instances (Phase 2.4 step 2b), converted for each
    // emitter once the module is checked.
    const module_instances = try a.alloc([]emitter.Instance, n);
    for (module_instances) |*mi| mi.* = &.{};

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

        // Phase 2.4 step 2b: convert this module's materialized instances
        // for its emitter (the checker already appended the wrappers).
        if (mtc.instances.items.len > 0) {
            const em_inst = try a.alloc(emitter.Instance, mtc.instances.items.len);
            for (mtc.instances.items, 0..) |inst, k| {
                const rws = try a.alloc(emitter.Rewrite, inst.rewrites.items.len);
                for (inst.rewrites.items, 0..) |rw, j| {
                    rws[j] = .{ .callee = rw.callee, .name = rw.name };
                }
                em_inst[k] = .{ .wrapper = inst.wrapper, .rewrites = rws };
            }
            module_instances[i] = em_inst;
        }

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
            mem.setInstances(module_instances[i]);
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
        mem.setInstances(module_instances[i]);
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
