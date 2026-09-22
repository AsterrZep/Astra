pub const lexer = @import("lexer/lexer.zig");
pub const ast = @import("ast/ast.zig");
pub const parser = @import("parser/parser.zig");

test {
    _ = lexer;
    _ = ast;
    _ = parser;
}
