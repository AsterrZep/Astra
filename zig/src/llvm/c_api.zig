//! Único punto de `@cImport` de llvm-c (LLVM_BACKEND_PLAN.md §3.1): el coste
//! frío de translate-c de Core.h (~2:17 la primera vez, cacheado después,
//! 023 §4.3) se paga en este solo módulo y queda encapsulado tras un binding
//! idiomático. El resto del compilador nunca importa llvm-c directamente.
//!
//! Solo se analiza con `-Dllvm`: tests.zig cuelga este import del flag de
//! build, así que `zig build test` sin el flag no toca headers de LLVM.

pub const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
});

test "smoke: módulo i64 add(i64,i64) verifica e imprime IR" {
    const std = @import("std");
    const mod = c.LLVMModuleCreateWithName("astra_smoke");
    defer c.LLVMDisposeModule(mod);
    const i64t = c.LLVMInt64Type();
    var params = [_]c.LLVMTypeRef{ i64t, i64t };
    const fty = c.LLVMFunctionType(i64t, &params, 2, 0);
    const fnv = c.LLVMAddFunction(mod, "add", fty);
    const bb = c.LLVMAppendBasicBlock(fnv, "entry");
    const builder = c.LLVMCreateBuilder();
    defer c.LLVMDisposeBuilder(builder);
    c.LLVMPositionBuilderAtEnd(builder, bb);
    const a = c.LLVMGetParam(fnv, 0);
    const b = c.LLVMGetParam(fnv, 1);
    const sum = c.LLVMBuildAdd(builder, a, b, "sum");
    _ = c.LLVMBuildRet(builder, sum);

    // Todo módulo emitido pasa por verify (024 §2): un módulo inválido es un
    // fallo del emisor, no algo que descubra llc/lli después.
    try std.testing.expect(c.LLVMVerifyModule(mod, c.LLVMReturnStatusAction, null) == 0);
    const ir = c.LLVMPrintModuleToString(mod);
    defer c.LLVMDisposeMessage(ir);
    try std.testing.expect(
        std.mem.indexOf(u8, std.mem.span(ir), "add i64") != null,
    );
}
