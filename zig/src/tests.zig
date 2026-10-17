//! Test root. Importing a module here also runs its `test` blocks, so this file
//! is the single entry point for `zig build test`.

const build_options = @import("build_options");

pub const lexer = @import("lexer/lexer.zig");
pub const ast = @import("ast/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const typechecker = @import("typechecker/typechecker.zig");
pub const emitter = @import("emitter/emitter.zig");
pub const bytecode = @import("emitter/bytecode.zig");
pub const vm = @import("vm/vm.zig");
pub const modules = @import("modules/modules.zig");
pub const conformance = @import("conformance.zig");
pub const link = @import("link.zig");
pub const diagnostics = @import("diagnostics.zig");
/// Binding llvm-c (Fase LLVM M0.2): solo existe bajo `-Dllvm`. La condición es
/// comptime, así que sin el flag esta rama no se analiza y el `@cImport` de
/// llvm-c jamás se traduce — `zig build test` sin LLVM sigue funcionando.
pub const llvm_c_api = if (build_options.llvm_enabled) @import("llvm/c_api.zig") else void;

test {
    _ = lexer;
    _ = ast;
    _ = parser;
    _ = typechecker;
    _ = emitter;
    _ = bytecode;
    _ = vm;
    _ = modules;
    _ = conformance;
    _ = link;
    _ = diagnostics;
    _ = llvm_c_api;
}
