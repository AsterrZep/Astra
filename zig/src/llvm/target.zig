//! M5 (LLVM_BACKEND_PLAN.md §6): creación de TargetMachine para cualquier
//! triple — el del host o uno cruzado fijado con `--target=<triple>`.
//!
//! Antes de M5 el backend sólo conocía el host: `LLVMInitializeNativeTarget`
//! + `LLVMGetDefaultTargetTriple`. Cruzar a aarch64 exige registrar *todos*
//! los targets de la lib LLVM (la monolítica trae todos; los `init` los ponen
//! en el TargetRegistry) y resolver el triple pedido, no el nativo.
//!
//! Este módulo lo comparten `emitter.zig` (datalayout del módulo) y la fachada
//! `llvm.zig` (emitir objeto / correr pasadas) para no duplicar la lógica; no
//! importa al emisor, así que no hay ciclo.

const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const c = @import("c_api.zig").c;

/// Crea el TargetMachine para `triple` (o el del host si es null), en modo PIC
/// (lo pide el `cc` default-PIE de la distro al enlazar) y con CPU/features por
/// defecto del triple. Devuelve null (y reporta por el sink) si el triple no
/// corresponde a ningún target registrado. El llamador libera el TM.
pub fn create(
    diag: ?*diagnostics.Sink,
    file: []const u8,
    triple: ?[:0]const u8,
) ?c.LLVMTargetMachineRef {
    // Registra todos los targets de la lib LLVM (M5). Los init son idempotentes
    // (re-registrar no duplica); sin ellos el TargetRegistry sólo contiene el
    // host y `LLVMGetTargetFromTriple` rechazaría `aarch64-linux-gnu`.
    c.LLVMInitializeAllTargetInfos();
    c.LLVMInitializeAllTargets();
    c.LLVMInitializeAllTargetMCs();
    c.LLVMInitializeAllAsmPrinters();
    c.LLVMInitializeAllAsmParsers();

    // El triple pedido, o el del host si no hay `--target`. El default viene de
    // LLVM (liberarlo); el pedido es del llamador (no liberar).
    var host_msg: ?[*c]u8 = null;
    defer if (host_msg) |m| c.LLVMDisposeMessage(m);
    const triple_z: [*:0]const u8 = if (triple) |t| t.ptr else blk: {
        host_msg = c.LLVMGetDefaultTargetTriple();
        break :blk @as([*:0]const u8, @ptrCast(host_msg.?));
    };

    var target: c.LLVMTargetRef = undefined;
    var err: [*c]u8 = null;
    if (c.LLVMGetTargetFromTriple(triple_z, &target, &err) != 0) {
        const msg: []const u8 = if (err != null) std.mem.span(@as([*:0]const u8, @ptrCast(err))) else "unknown target";
        diagnostics.emit(diag, file, diagnostics.no_span, "cannot find target for '{s}': {s}", .{ std.mem.span(triple_z), msg });
        if (err != null) c.LLVMDisposeMessage(err);
        return null;
    }
    const tm = c.LLVMCreateTargetMachine(
        target,
        triple_z,
        "", // CPU: el default del triple
        "", // features: las del default del triple
        c.LLVMCodeGenLevelDefault,
        c.LLVMRelocPIC,
        c.LLVMCodeModelDefault,
    );
    if (tm == null) {
        diagnostics.emit(diag, file, diagnostics.no_span, "cannot create target machine for '{s}'", .{std.mem.span(triple_z)});
        return null;
    }
    return tm;
}

test "M5: create resuelve el host y un triple cruzado aarch64" {
    // Host: como antes de M5.
    const host = create(null, "t.astra", null);
    try std.testing.expect(host != null);
    c.LLVMDisposeTargetMachine(host.?);

    // Cruzado: el TargetMachine de aarch64 existe y su triple es el pedido.
    const aarch64 = create(null, "t.astra", "aarch64-linux-gnu");
    try std.testing.expect(aarch64 != null);
    defer c.LLVMDisposeTargetMachine(aarch64.?);
    const t3 = c.LLVMGetTargetMachineTriple(aarch64.?);
    defer c.LLVMDisposeMessage(t3);
    const t3_str = std.mem.span(@as([*:0]const u8, @ptrCast(t3)));
    try std.testing.expect(std.mem.startsWith(u8, t3_str, "aarch64"));

    // Un triple inventado se rechaza limpio (null), no un crash.
    try std.testing.expect(create(null, "t.astra", "nosuch-target-os") == null);
}
