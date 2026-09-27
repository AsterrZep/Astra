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

const Mode = enum { parse, tokens, ast_dump };

const usage =
    \\usage: astra-zig [--dump-tokens | --dump-ast] <file.astra>
    \\
    \\  (no flag)      parse the file, report syntax errors, exit 1 on failure
    \\  --dump-tokens  print the token stream
    \\  --dump-ast     print the parsed AST
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var mode: Mode = .parse;
    var path: ?[]const u8 = null;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dump-tokens")) {
            mode = .tokens;
        } else if (std.mem.eql(u8, arg, "--dump-ast")) {
            mode = .ast_dump;
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

    var tc = try typechecker.TypeChecker.init(a, &tree, file);
    tc.check(root);
    if (tc.error_count > 0) std.process.exit(1);

    std.debug.print("ok: {s} ({d} items)\n", .{ file, tree.extraSlice(tree.node(root).source_file).len });
}
