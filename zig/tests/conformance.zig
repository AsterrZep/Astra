test "integration lexer+parser" {
    const source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b;
        \\}
        \\
        \\fn main() {
        \\    print(add(3, 4));
        \\}
    ;

    var tree = @import("ast/ast.zig").Tree.init(std.testing.allocator, source);
    defer tree.deinit();

    var par = @import("parser/parser.zig").Parser.init(std.testing.allocator, source, &tree);
    const root = try par.parse();
    try std.testing.expect(root < tree.nodes.items.len);
}
