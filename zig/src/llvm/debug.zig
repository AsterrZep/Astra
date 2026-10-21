//! DWARF (M4.c): metadatos de depuración para que lldb/gdb paren por línea
//! Astra y muestren el nombre de la función.
//!
//! Un `DICompileUnit` por módulo, un `DISubprogram` por función LLVM (también
//! las lambdas y el `astra_module_main`) y una `DILocation` por nodo del AST.
//! El truco que evita tocar las ~250 llamadas a `LLVMBuild*`: el IRBuilder
//! adjunta su "current debug location" a CADA instrucción que crea, así que
//! basta con fijarla (`LLVMSetCurrentDebugLocation2`) antes de emitir cada
//! sentencia/expresión y con registrar cada función (`LLVMSetSubprogram`).
//!
//! Todo es opt-in (`--debug-info`): sin el flag no se crea el DIBuilder y el
//! IR es byte-idéntico al de antes (los FileCheck dependen de esa forma).
const std = @import("std");
const c = @import("c_api.zig").c;

pub const DebugInfo = struct {
    builder: c.LLVMDIBuilderRef,
    file: c.LLVMMetadataRef,
    cu: c.LLVMMetadataRef,
    /// Tipo de subrutina vacío: el C API exige un `DISubroutineType` para el
    /// `DISubprogram` y no modelamos firmas en DWARF (lldb no las necesita
    /// para `break file:line`; los tipos v1 son i64/i8/f64/ptr de todos modos).
    sub_ty: c.LLVMMetadataRef,
    ctx: c.LLVMContextRef,
    optimized: bool,

    pub fn init(ctx: c.LLVMContextRef, mod: c.LLVMModuleRef, path: []const u8, optimized: bool) DebugInfo {
        const b = c.LLVMCreateDIBuilder(mod);
        // DW_AT_name es el basename y DW_AT_comp_dir el directorio: así lldb
        // resuelve el fuente con el CWD que tenía el compilador, igual que gcc.
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const dir = if (slash) |s| path[0..s] else ".";
        const base = if (slash) |s| path[s + 1 ..] else path;
        const f = c.LLVMDIBuilderCreateFile(b, base.ptr, base.len, dir.ptr, dir.len);
        const producer = "astra-zig";
        const cu = c.LLVMDIBuilderCreateCompileUnit(
            b,
            c.LLVMDWARFSourceLanguageC,
            f,
            producer.ptr,
            producer.len,
            @intFromBool(optimized),
            "".ptr,
            0, // flags
            0, // DWARF runtime version (0 = la del target)
            "".ptr,
            0, // split name
            c.LLVMDWARFEmissionFull,
            0, // DWO id
            0, // split debug inlining
            0, // debug info for profiling
            "".ptr,
            0, // sysroot
            "".ptr,
            0, // sdk
        );
        const sub_ty = c.LLVMDIBuilderCreateSubroutineType(b, f, null, 0, c.LLVMDIFlagZero);
        return .{ .builder = b, .file = f, .cu = cu, .sub_ty = sub_ty, .ctx = ctx, .optimized = optimized };
    }

    /// Crea el `DISubprogram` de una función LLVM y lo asocia a ella. El
    /// valor devuelto es el scope con el que se construyen las `DILocation`
    /// de su cuerpo (una location con el scope de otra función es DWARF
    /// incorrecto y lldb atribuye la línea a la función equivocada).
    pub fn subprogram(self: *DebugInfo, fn_val: c.LLVMValueRef, name: []const u8, line: u32) c.LLVMMetadataRef {
        const sp = c.LLVMDIBuilderCreateFunction(
            self.builder,
            self.cu,
            name.ptr,
            name.len,
            name.ptr,
            name.len,
            self.file,
            line,
            self.sub_ty,
            0, // isLocalToUnit (enlazado estático, como el binario)
            1, // isDefinition
            line, // scope line: el `{` de la firma
            c.LLVMDIFlagZero,
            @intFromBool(self.optimized),
        );
        c.LLVMSetSubprogram(fn_val, sp);
        return sp;
    }

    pub fn location(self: *DebugInfo, line: u32, col: u32, scope: c.LLVMMetadataRef) c.LLVMMetadataRef {
        return c.LLVMDIBuilderCreateDebugLocation(self.ctx, line, col, scope, null);
    }

    /// `LLVMDIBuilderFinalize` añade el CU a `!llvm.dbg.cu` y los module flags
    /// (`Dwarf Version`, `Debug Info Version`). Sin esto el objeto no lleva
    /// sección `.debug_info` y el enlazador no encuentra nada.
    pub fn finalize(self: *DebugInfo) void {
        c.LLVMDIBuilderFinalize(self.builder);
    }

    pub fn deinit(self: *DebugInfo) void {
        c.LLVMDisposeDIBuilder(self.builder);
    }
};
