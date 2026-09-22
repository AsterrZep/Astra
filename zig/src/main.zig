const std = @import("std");
const ast = @import("ast/ast.zig");
const parser_mod = @import("parser/parser.zig");

pub fn main() !void {
    std.debug.print("Astra-Zig Compiler v0.2.0\n", .{});
    std.debug.print("Phase 2: Self-hosting compiler\n", .{});
}
