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
pub const Instance = @import("llvm/emitter.zig").Instance;
pub const Rewrite = @import("llvm/emitter.zig").Rewrite;
pub const StructInstance = @import("llvm/emitter.zig").StructInstance;

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

/// Crea el TargetMachine del host (triple y features por defecto, PIC) que
/// comparten la emisión de objeto y el pipeline de optimización. Devuelve null
/// (y reporta por el sink) si el target no existe. El llamador lo libera.
fn createTargetMachine(diag: ?*diagnostics.Sink, file: []const u8) ?c.LLVMTargetMachineRef {
    // El target del host debe estar registrado en libLLVM antes de crear un
    // TargetMachine. Los init son un static inline de llvm-c/Target.h que
    // translate-c sí traduce (llvm-config.h los expande al target nativo).
    _ = c.LLVMInitializeNativeTarget();
    _ = c.LLVMInitializeNativeAsmPrinter();

    const triple = c.LLVMGetDefaultTargetTriple();
    defer c.LLVMDisposeMessage(triple);
    var target: c.LLVMTargetRef = undefined;
    var err: [*c]u8 = null;
    if (c.LLVMGetTargetFromTriple(triple, &target, &err) != 0) {
        const msg: []const u8 = if (err != null) std.mem.span(@as([*:0]const u8, @ptrCast(err))) else "unknown target";
        diagnostics.emit(diag, file, diagnostics.no_span, "cannot find target for '{s}': {s}", .{ std.mem.span(@as([*:0]const u8, @ptrCast(triple))), msg });
        if (err != null) c.LLVMDisposeMessage(err);
        return null;
    }
    const tm = c.LLVMCreateTargetMachine(
        target,
        triple,
        "", // CPU: el default del triple
        "", // features: las del default del triple
        c.LLVMCodeGenLevelDefault,
        c.LLVMRelocPIC,
        c.LLVMCodeModelDefault,
    );
    if (tm == null) {
        diagnostics.emit(diag, file, diagnostics.no_span, "cannot create target machine", .{});
        return null;
    }
    return tm;
}

/// Compila el módulo a un objeto nativo vía TargetMachineEmitToFile
/// (LLVM_BACKEND_PLAN.md §6 M2.e): el backend deja de depender del subproceso
/// `llc` — mismo TargetMachine del host, PIC como pide el enlazador por
/// defecto (sin `-relocation-model=pic` el default-PIE `cc` rechaza el
/// objeto). Devuelve `false` y reporta el motivo cuando LLVM no puede.
pub fn emitObjectFile(
    mod: c.LLVMModuleRef,
    diag: ?*diagnostics.Sink,
    file: []const u8,
    path_z: [*:0]const u8,
) bool {
    const tm = createTargetMachine(diag, file) orelse return false;
    defer c.LLVMDisposeTargetMachine(tm);
    var err: [*c]u8 = null;
    if (c.LLVMTargetMachineEmitToFile(tm, mod, path_z, c.LLVMObjectFile, &err) != 0) {
        const msg: []const u8 = if (err != null) std.mem.span(@as([*:0]const u8, @ptrCast(err))) else "unknown";
        diagnostics.emit(diag, file, diagnostics.no_span, "cannot emit object file: {s}", .{msg});
        if (err != null) c.LLVMDisposeMessage(err);
        return false;
    }
    return true;
}

/// Pipeline de optimización por nivel (LLVM_BACKEND_PLAN.md §6 M4). El nivel 2
/// añade las pasadas que el plan pide explícitamente sobre `default<O2>`:
/// LICM (que exige el adaptador `loop-mssa`), loop-unswitch (en LLVM 19 se
/// llama `simple-loop-unswitch`) e IRCE, todas de función, de ahí el
/// envoltorio `function(...)`. El 3 usa el pipeline completo del new PM.
/// Nivel 0 (default) no toca el módulo: el IR de los gates no cambia.
pub fn pipelineForLevel(level: u8) ?[:0]const u8 {
    return switch (level) {
        0 => null,
        1 => "default<O1>",
        2 => "default<O2>,function(loop-mssa(licm)),function(simple-loop-unswitch),function(irce)",
        3 => "default<O3>",
        else => null,
    };
}

/// Corre el pipeline del new PM sobre el módulo antes de verificar/emitir.
/// Devuelve `false` (y reporta por el sink) si LLVM rechaza el pipeline o una
/// pasada falla; el llamador sale sin escribir IR ni objeto.
pub fn runPasses(
    mod: c.LLVMModuleRef,
    diag: ?*diagnostics.Sink,
    file: []const u8,
    level: u8,
) bool {
    const pipeline = pipelineForLevel(level) orelse return true;
    // El TargetMachine aporta el target de las pasadas (vectorización, costes);
    // no se usa para emitir, sólo para correr el pipeline.
    const tm = createTargetMachine(diag, file) orelse return false;
    defer c.LLVMDisposeTargetMachine(tm);
    const opts = c.LLVMCreatePassBuilderOptions();
    defer c.LLVMDisposePassBuilderOptions(opts);
    const err = c.LLVMRunPasses(mod, pipeline.ptr, tm, opts);
    if (err != null) {
        const raw = c.LLVMGetErrorMessage(err);
        defer c.LLVMDisposeErrorMessage(raw);
        const msg: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        diagnostics.emit(diag, file, diagnostics.no_span, "LLVM optimization pipeline '{s}' failed: {s}", .{ pipeline, msg });
        return false;
    }
    return true;
}

test "emit-obj: TargetMachineEmitToFile produce un ELF de host" {
    // Módulo mínimo `i64 add(i64,i64)` (el smoke de c_api) compilado a
    // objeto: el .o empieza por el magic ELF y pesa más que vacío.
    const mod = c.LLVMModuleCreateWithName("astra_obj_smoke");
    defer c.LLVMDisposeModule(mod);
    const i64t = c.LLVMInt64Type();
    var params = [_]c.LLVMTypeRef{ i64t, i64t };
    const fty = c.LLVMFunctionType(i64t, &params, 2, 0);
    const fnv = c.LLVMAddFunction(mod, "add", fty);
    const bb = c.LLVMAppendBasicBlock(fnv, "entry");
    const builder = c.LLVMCreateBuilder();
    defer c.LLVMDisposeBuilder(builder);
    c.LLVMPositionBuilderAtEnd(builder, bb);
    _ = c.LLVMBuildRet(builder, c.LLVMBuildAdd(builder, c.LLVMGetParam(fnv, 0), c.LLVMGetParam(fnv, 1), "sum"));
    try std.testing.expect(verify(mod, null, "obj_smoke"));

    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // El C API escribe por ruta fopen(2)-resoluble desde el CWD del test:
    // tmpDir vive en .zig-cache/tmp/<aleatorio> (std.testing.tmpDir).
    const out = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/smoke.o", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expect(emitObjectFile(mod, null, "obj_smoke.astra", out));

    const data = try std.Io.Dir.cwd().readFileAlloc(io, out, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(data);
    try std.testing.expect(data.len > 16);
    try std.testing.expectEqualStrings("\x7fELF", data[0..4]);
}

test "M4: runPasses aplica el pipeline y el módulo sigue verificando" {
    // `i64 add(i64,i64)` con un bucle no hace falta para el plumbing: el nivel
    // 2 parsea `default<O2>,function(loop-mssa(licm)),…` y corre las pasadas
    // sobre una función trivial. Lo que se fija aquí es que LLVMRunPasses
    // acepta el pipeline (LICM con su adaptador incluido) y que el módulo
    // resultante sigue pasando LLVMVerifyModule.
    const mod = c.LLVMModuleCreateWithName("astra_opt_smoke");
    defer c.LLVMDisposeModule(mod);
    const i64t = c.LLVMInt64Type();
    var params = [_]c.LLVMTypeRef{ i64t, i64t };
    const fty = c.LLVMFunctionType(i64t, &params, 2, 0);
    const fnv = c.LLVMAddFunction(mod, "add", fty);
    const bb = c.LLVMAppendBasicBlock(fnv, "entry");
    const builder = c.LLVMCreateBuilder();
    defer c.LLVMDisposeBuilder(builder);
    c.LLVMPositionBuilderAtEnd(builder, bb);
    _ = c.LLVMBuildRet(builder, c.LLVMBuildAdd(builder, c.LLVMGetParam(fnv, 0), c.LLVMGetParam(fnv, 1), "sum"));
    try std.testing.expect(runPasses(mod, null, "opt_smoke.astra", 2));
    try std.testing.expect(verify(mod, null, "opt_smoke.astra"));
    // Nivel 0 no toca nada (el IR de los FileCheck depende de ello).
    try std.testing.expect(pipelineForLevel(0) == null);
    try std.testing.expect(runPasses(mod, null, "opt_smoke.astra", 0));
}
