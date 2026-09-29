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

const Mode = enum { parse, tokens, ast_dump, bytecode, modules };

const usage =
    \\usage: astra-zig [--dump-tokens | --dump-ast | --dump-modules | --dump-bytecode | --debug] <file.astra>
    \\
    \\  (no flag)        compile and run, exit 1 on a compile or runtime error
    \\  --dump-tokens    print the token stream
    \\  --dump-ast       print the parsed AST
    \\  --dump-modules   list the module declarations and the files they resolve to
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
    const root = p.parse() catch {
        std.process.exit(1);
    };

    if (mode == .ast_dump) {
        try tree.dump(&w, root);
        std.debug.print("{s}", .{w.buffered()});
        return;
    }

    // Module resolution is groundwork (modules/modules.zig): nothing links
    // files yet, so this reports what *would* be loaded and where each
    // declaration points. It runs before the type checker because resolution
    // belongs to the frontend, not to the stages that assume one file.
    if (mode == .modules) {
        const table = try modules_mod.collect(a, &tree, root, file);
        try modules_mod.dump(&w, table);
        std.debug.print("{s}", .{w.buffered()});
        return;
    }

    var tc = try typechecker.TypeChecker.init(a, &tree, file);
    tc.check(root);
    if (tc.error_count > 0) std.process.exit(1);

    var em = emitter.Emitter.init(a, &tree, file);
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
