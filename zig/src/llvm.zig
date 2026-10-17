//! Fachata del backend LLVM (Fase LLVM M0.3, LLVM_BACKEND_PLAN.md §3.1).
//!
//! Expone el emisor mínimo (`llvm/emitter.zig`) y las dos operaciones de cierre
//! del pipeline: verificar el módulo antes de escribirlo y serializarlo a IR
//! textual. El objetivo es que `main.zig` solo importe este módulo (bajo
//! `build_options.llvm_enabled`) y nunca toque llvm-c directamente.

const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const c = @import("llvm/c_api.zig").c;

pub const Emitter = @import("llvm/emitter.zig").Emitter;

/// Verifica el módulo y, si el verificador falla, reporta el error a través del
/// sink de diagnósticos. Devuelve `true` cuando el módulo es válido (listo para
/// escribir). LLVMVerifyModule detecta IR mal formado antes de que llegue a
/// `llc`, que fallaría con mensajes mucho menos útiles.
pub fn verify(mod: c.LLVMModuleRef, diag: ?*diagnostics.Sink, file: []const u8) bool {
    var err: [*c]u8 = null;
    if (c.LLVMVerifyModule(mod, c.LLVMReturnStatusAction, &err) != 0) {
        const msg: []const u8 = if (err != null) std.mem.span(@as([*:0]const u8, @ptrCast(err))) else "unknown verifier error";
        diagnostics.emit(diag, file, diagnostics.no_span, "LLVM module verification failed: {s}", .{msg});
        if (err != null) c.LLVMDisposeMessage(err);
        return false;
    }
    return true;
}

/// Devuelve el IR textual del módulo como un slice arena-terminado en '\0'.
pub fn printToString(a: std.mem.Allocator, mod: c.LLVMModuleRef) []const u8 {
    const s = c.LLVMPrintModuleToString(mod);
    defer c.LLVMDisposeMessage(s);
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(s)));
    return a.dupeZ(u8, span) catch @panic("OOM");
}

/// Escribe el IR del módulo a un archivo (ruta terminada en '\0'). La misma
/// vía que usa la salida `--emit-c` del seed: un `.ll` junto al `.astra`.
pub fn writeToFile(mod: c.LLVMModuleRef, path_z: [*:0]const u8) !void {
    var err: [*c]u8 = null;
    if (c.LLVMPrintModuleToFile(mod, path_z, &err) != 0) {
        const msg: []const u8 = if (err != null) std.mem.span(@as([*:0]const u8, @ptrCast(err))) else "unknown";
        if (err != null) c.LLVMDisposeMessage(err);
        std.debug.print("error: cannot write LLVM IR: {s}\n", .{msg});
        return error.WriteFailed;
    }
}
