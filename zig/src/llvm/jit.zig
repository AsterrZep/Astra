//! M6.a — LLJIT (LLVM_BACKEND_PLAN.md §6 M6): ejecución in-process.
//!
//! `--jit` compila el módulo emitido en el propio proceso vía ORC/LLJIT y
//! ejecuta su `main` (el C entry que el emisor genera: `astra_set_file` →
//! `astra_init` → `astra_module_main` → release de globales →
//! `astra_llvm_runtime_cleanup` → return 0). Es el cimiento del REPL/eval que
//! el plan apunta: sin `cc`+enlace intermedio, y con la semántica idéntica a
//! la ruta AOT porque el mismo runtime C resuelve las llamadas.
//!
//! Resolución de símbolos: el código JITeado referencia `astra_llvm_*` (y las
//! globales del runtime) + libc. El runtime se linkea al binario `astra-zig`
//! bajo `-Dllvm` (build.zig) y se exporta con `-rdynamic`, de modo que el
//! generador de símbolos de proceso de LLJIT (`dlsym(RTLD_DEFAULT)`) los
//! encuentra. Un `?` que propague o un error de runtime llaman
//! `exit(1)`/longjmp dentro del runtime — igual que la ruta AOT (proceso sale
//! con 1), no hay estado que reiniciar entre ejecuciones (one-shot por
//! proceso).
//!
//! Propiedad del módulo: el `mod` del llamador (emisor) sigue siendo suyo. Aquí
//! se serializa a IR textual y se re-analiza en un contexto fresco *propiedad
//! del JIT* — LLJIT exige que el contexto del módulo y el ThreadSafeContext
//! coincidan, y el emisor usa el suyo propio. Re-analizar desacopla el ciclo de
//! vida del emisor del del JIT (sin use-after-free de contexto), a costa de un
//! print+parse irrelevante en un modo cuyo valor es la comodidad, no el tiempo
//! de compilación.

const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const c = @import("c_api.zig").c;
const target_mod = @import("target.zig");

/// C stdio se usa sin flush explícito en el runtime (`putchar`/`printf`, con
/// buffer). El `main` JITeado devuelve 0 y el caller sale del proceso; sin un
/// flush, lo último en el buffer podría perderse si Zig usa `_exit`. Se declara
/// aquí en vez de tocar c_api (que es solo llvm-c).
extern "c" fn fflush(stream: ?*anyopaque) c_int;

/// Compila `mod` en el proceso vía LLJIT y ejecuta su `main`. Devuelve el código
/// de salida (0 en éxito; un error de runtime llama `exit(1)` dentro del
/// runtime y nunca regresa). Reporta fallos del propio JIT (no del programa
/// Astra) por el sink de diagnósticos y devuelve 1.
pub fn run(
    mod: c.LLVMModuleRef,
    diag: ?*diagnostics.Sink,
    file: []const u8,
) i32 {
    // 1. LLJIT para el host (JTMB::detectHost por defecto). Los targets deben
    //    estar registrados antes: el camino del host del emisor no llama
    //    `target.create`, así que sin esto detectHost fallaría con "no targets
    //    are registered".
    target_mod.registerAll();
    var jit: c.LLVMOrcLLJITRef = undefined;
    const builder = c.LLVMOrcCreateLLJITBuilder();
    var err = c.LLVMOrcCreateLLJIT(&jit, builder);
    if (err != null) return fail(diag, file, err, "cannot create LLJIT");
    defer _ = c.LLVMOrcDisposeLLJIT(jit);

    // 2. Generador de símbolos de proceso: resuelve `astra_llvm_*` (linkados al
    //    binario con -rdynamic) y libc para el código JITeado. Se adjunta al
    //    JITDylib principal; es perezoso (dlsym bajo demanda).
    var gen: c.LLVMOrcDefinitionGeneratorRef = undefined;
    err = c.LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(&gen, 0, null, null);
    if (err != null) return fail(diag, file, err, "cannot create process symbol generator");
    c.LLVMOrcJITDylibAddGenerator(c.LLVMOrcLLJITGetMainJITDylib(jit), gen);

    // 3. Re-analizar el IR en un contexto fresco propiedad del JIT.
    const tsc = c.LLVMOrcCreateNewThreadSafeContext();
    defer c.LLVMOrcDisposeThreadSafeContext(tsc);
    const tsc_ctx = c.LLVMOrcThreadSafeContextGetContext(tsc);
    const jit_mod = parseInto(jit, tsc_ctx, mod, diag, file) orelse return 1;

    // 4. Envolver + transferir la propiedad al JIT (que libera el módulo y el
    //    contexto del ThreadSafeContext al disposal).
    const tsm = c.LLVMOrcCreateNewThreadSafeModule(jit_mod, tsc);
    err = c.LLVMOrcLLJITAddLLVMIRModule(jit, c.LLVMOrcLLJITGetMainJITDylib(jit), tsm);
    if (err != null) return fail(diag, file, err, "cannot add module to JIT");

    // 5. Lookup + call de `main` (el C entry autocontenido del módulo).
    var addr: c.LLVMOrcExecutorAddress = 0;
    err = c.LLVMOrcLLJITLookup(jit, &addr, "main");
    if (err != null) return fail(diag, file, err, "cannot find `main` in JIT");
    const main_fn: *const fn () callconv(.c) i32 = @ptrFromInt(addr);
    const code = main_fn();
    // El runtime imprime por stdio sin flush; el `main` JITeado devuelve 0 y
    // salimos del proceso — flush explícito para no perder el buffer final.
    _ = fflush(null);
    return code;
}

/// Serializa `mod` a IR y lo re-analiza en `ctx` (contexto del JIT), alineando
/// datalayout/triple al del LLJIT (host) — LLJIT es estricto con la coincidencia
/// de datalayout. Devuelve el módulo (propiedad del caller/JIT) o null si el
/// parse falla (ya reportado).
fn parseInto(
    jit: c.LLVMOrcLLJITRef,
    ctx: c.LLVMContextRef,
    mod: c.LLVMModuleRef,
    diag: ?*diagnostics.Sink,
    file: []const u8,
) ?c.LLVMModuleRef {
    const ir = c.LLVMPrintModuleToString(mod);
    defer c.LLVMDisposeMessage(ir);
    // LLVMParseIRInContext consume el buffer (posee su copia) — no disposal.
    const buf = c.LLVMCreateMemoryBufferWithMemoryRangeCopy(ir, std.mem.len(ir), "astra_jit");
    var jit_mod: c.LLVMModuleRef = undefined;
    var perr: [*c]u8 = null;
    if (c.LLVMParseIRInContext(ctx, buf, &jit_mod, &perr) != 0) {
        const msg: []const u8 = if (perr != null) std.mem.span(@as([*:0]const u8, @ptrCast(perr))) else "unknown";
        diagnostics.emit(diag, file, diagnostics.no_span, "JIT IR parse failed: {s}", .{msg});
        if (perr != null) c.LLVMDisposeMessage(perr);
        return null;
    }
    // Alinear datalayout/triple al del LLJIT (host) para que el JIT acepte el
    // módulo sin quejas de layout.
    c.LLVMSetDataLayout(jit_mod, c.LLVMOrcLLJITGetDataLayoutStr(jit));
    const triple = c.LLVMGetDefaultTargetTriple();
    defer c.LLVMDisposeMessage(triple);
    c.LLVMSetTarget(jit_mod, triple);
    return jit_mod;
}

/// Consume un LLVMErrorRef reportándolo por el sink; devuelve 1 (fallo JIT).
fn fail(
    diag: ?*diagnostics.Sink,
    file: []const u8,
    err: c.LLVMErrorRef,
    what: []const u8,
) i32 {
    const raw = c.LLVMGetErrorMessage(err);
    defer c.LLVMDisposeErrorMessage(raw);
    const msg: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    diagnostics.emit(diag, file, diagnostics.no_span, "{s}: {s}", .{ what, msg });
    return 1;
}

test "M6.a: LLJIT compila y ejecuta un módulo i64 add(i64,i64)" {
    // Plumbing del JIT sin runtime Astra: `add(2,3)` no referencia externos, así
    // que el generador de proceso nunca se consulta y no hace falta -rdynamic
    // ni el runtime enlazado en los tests unitarios. Cubre create → add →
    // lookup → call.
    const mod = c.LLVMModuleCreateWithName("astra_jit_smoke");
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
    try std.testing.expect(verifySmoke(mod));

    // Reutiliza la vía JIT: crear LLJIT, parsear `add` en su contexto, llamar.
    target_mod.registerAll();
    var jit: c.LLVMOrcLLJITRef = undefined;
    const jb = c.LLVMOrcCreateLLJITBuilder();
    var err = c.LLVMOrcCreateLLJIT(&jit, jb);
    try std.testing.expect(err == null);
    defer _ = c.LLVMOrcDisposeLLJIT(jit);
    const tsc = c.LLVMOrcCreateNewThreadSafeContext();
    defer c.LLVMOrcDisposeThreadSafeContext(tsc);
    const tsc_ctx = c.LLVMOrcThreadSafeContextGetContext(tsc);
    const jit_mod = parseInto(jit, tsc_ctx, mod, null, "jit_smoke.astra") orelse return error.ParseFailed;
    const tsm = c.LLVMOrcCreateNewThreadSafeModule(jit_mod, tsc);
    err = c.LLVMOrcLLJITAddLLVMIRModule(jit, c.LLVMOrcLLJITGetMainJITDylib(jit), tsm);
    try std.testing.expect(err == null);
    var addr: c.LLVMOrcExecutorAddress = 0;
    err = c.LLVMOrcLLJITLookup(jit, &addr, "add");
    try std.testing.expect(err == null);
    const add_fn: *const fn (i64, i64) callconv(.c) i64 = @ptrFromInt(addr);
    try std.testing.expectEqual(@as(i64, 5), add_fn(2, 3));
}

/// verify() mínimo para el test (evita importar la fachata y su ciclo).
fn verifySmoke(mod: c.LLVMModuleRef) bool {
    return c.LLVMVerifyModule(mod, c.LLVMReturnStatusAction, null) == 0;
}
