//! Test root. Importing a module here also runs its `test` blocks, so this file
//! is the single entry point for `zig build test`.

pub const lexer = @import("lexer/lexer.zig");
pub const ast = @import("ast/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const typechecker = @import("typechecker/typechecker.zig");
pub const emitter = @import("emitter/emitter.zig");
pub const bytecode = @import("emitter/bytecode.zig");
pub const vm = @import("vm/vm.zig");
pub const conformance = @import("conformance.zig");

test {
    _ = lexer;
    _ = ast;
    _ = parser;
    _ = typechecker;
    _ = emitter;
    _ = bytecode;
    _ = vm;
    _ = conformance;
}
