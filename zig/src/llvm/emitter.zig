//! Emisor LLVM (Fase LLVM, LLVM_BACKEND_PLAN.md §6).
//!
//! Convierte el AST plano ya verificado por el typechecker en LLVM IR textual
//! para el subconjunto escalar: literales int/bool/float/string, identificadores,
//! `let`/`const` (locales y de módulo), asignación, aritmética i64 y f64 con
//! los mismos guards que el VM, `+` de strings (concat por contenido),
//! comparaciones, `&&`/`||`/`!`, `if` (sentencia y expresión vía phi), `while`,
//! funciones con recursión, `return` y `print`.
//!
//! Modelo de valores: escalares sin boxing — `i64` para todos los tipos enteros
//! de Astra (el VM almacena int64 completo), `i8` 0/1 para bool, `f64` para
//! floats — más `str_`, el primer tipo con heap: puntero al bloque
//! `{ i64 len; [len+1 x i8] data }` que el runtime lee directamente (longitud
//! explícita como el par (str, len) del VM, soporta NULs intercalados, §2.14).
//! El typechecker exige tipos de operandos idénticos (`type_eq`) en
//! aritmética/comparación/asignación/argumentos, así que el emisor no necesita
//! coerción int↔float: si ve operandos de distinto tipo es un bug del checker.
//! El boxing de Option/Result/arrays llega con M1–M2. Los guards de div/mod/shift
//! se emiten en línea y delegan el error en `astra_llvm_fail`, que reimprime
//! `file:line: runtime error: msg` con el runtime compartido del seed — así la
//! ruta LLVM no deriva en un tercer formato de error.
//!
//! Todo lo que está fuera de alcance se rechaza con `diagnostics.emit` y sale
//! limpio (exit 1) sin escribir IR: el emisor nunca produce un módulo a medias.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const diagnostics = @import("../diagnostics.zig");
const c = @import("c_api.zig").c;

/// Tipos escalares que el subconjunto actual representa sin boxing, más el
/// primer tipo con representación en heap: `i64` para todos los tipos enteros
/// de Astra, `bool` como `i8` 0/1, `f64` para floats y `str_` como puntero al
/// bloque `{ i64 len; [len+1 x i8] data }` del runtime (M1).
const Ty = enum { i64_, bool_, f64_, str_ };

/// Un valor emitido: su representación LLVM y su tipo. Las expresiones sin
/// valor (void: `print`, `while`, `let` de módulo…) devuelven `null`.
const Val = struct { ref: c.LLVMValueRef, ty: Ty };

const FnInfo = struct {
    val: c.LLVMValueRef,
    /// Tipo de función LLVM, cacheado para `LLVMBuildCall2`.
    fty: c.LLVMTypeRef,
    /// `true` cuando la función devuelve un escalar (falso = void).
    returns_value: bool,
    ret_ty: ?Ty,
};

const GlobalInfo = struct { val: c.LLVMValueRef, ty: Ty };
const Local = struct { alloca: c.LLVMValueRef, ty: Ty };

pub const Emitter = struct {
    a: std.mem.Allocator,
    tree: *const ast.Tree,
    file: []const u8,
    /// Nombre de archivo terminado en '\0', para `LLVMBuildGlobalStringPtr`.
    file_z: [*:0]const u8,
    diag: ?*diagnostics.Sink = null,
    error_count: u32 = 0,

    ctx: c.LLVMContextRef,
    mod: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,

    t_i1: c.LLVMTypeRef,
    t_i8: c.LLVMTypeRef,
    t_i32: c.LLVMTypeRef,
    t_i64: c.LLVMTypeRef,
    t_f64: c.LLVMTypeRef,
    t_ptr: c.LLVMTypeRef,
    t_void: c.LLVMTypeRef,

    // Externos del runtime (astra_runtime_llvm.c).
    r_set_file: c.LLVMValueRef,
    r_init: c.LLVMValueRef,
    r_cleanup: c.LLVMValueRef,
    r_fail: c.LLVMValueRef,
    r_print_begin: c.LLVMValueRef,
    r_print_i64: c.LLVMValueRef,
    r_print_f64: c.LLVMValueRef,
    r_print_bool: c.LLVMValueRef,
    r_print_str: c.LLVMValueRef,
    r_print_end: c.LLVMValueRef,
    // Operaciones de string (M1): concat con `+` e igualdad por contenido.
    r_str_concat: c.LLVMValueRef,
    r_str_eq: c.LLVMValueRef,

    fns: std.StringHashMap(FnInfo),
    globals: std.StringHashMap(GlobalInfo),
    scopes: std.ArrayListUnmanaged(std.StringHashMap(Local)) = .empty,

    // Función que se emite actualmente (para allocas y bloques).
    cur_fn: c.LLVMValueRef = undefined,
    cur_returns_value: bool = false,
    /// Contador para nombrar los globales de literales de string únicos.
    str_seq: u32 = 0,
    // `astra_module_main`: el código de nivel superior, invocado desde @main.
    module_main: c.LLVMValueRef = undefined,

    pub fn init(a: std.mem.Allocator, tree: *const ast.Tree, file: []const u8) *Emitter {
        const self = a.create(Emitter) catch @panic("OOM");
        const ctx = c.LLVMContextCreate();
        const mod = c.LLVMModuleCreateWithNameInContext("astra_llvm", ctx);
        const builder = c.LLVMCreateBuilderInContext(ctx);
        const t_i1 = c.LLVMInt1TypeInContext(ctx);
        const t_i8 = c.LLVMInt8TypeInContext(ctx);
        const t_i32 = c.LLVMInt32TypeInContext(ctx);
        const t_i64 = c.LLVMInt64TypeInContext(ctx);
        const t_f64 = c.LLVMDoubleTypeInContext(ctx);
        const t_ptr = c.LLVMPointerTypeInContext(ctx, 0);
        const t_void = c.LLVMVoidTypeInContext(ctx);
        const file_z = a.allocSentinel(u8, file.len, 0) catch @panic("OOM");
        @memcpy(file_z[0..file.len], file);
        self.* = .{
            .a = a,
            .tree = tree,
            .file = file,
            .file_z = file_z.ptr,
            .ctx = ctx,
            .mod = mod,
            .builder = builder,
            .t_i1 = t_i1,
            .t_i8 = t_i8,
            .t_i32 = t_i32,
            .t_i64 = t_i64,
            .t_f64 = t_f64,
            .t_ptr = t_ptr,
            .t_void = t_void,
            .fns = std.StringHashMap(FnInfo).init(a),
            .globals = std.StringHashMap(GlobalInfo).init(a),
            .r_set_file = undefined,
            .r_init = undefined,
            .r_cleanup = undefined,
            .r_fail = undefined,
            .r_print_begin = undefined,
            .r_print_i64 = undefined,
            .r_print_f64 = undefined,
            .r_print_bool = undefined,
            .r_print_str = undefined,
            .r_print_end = undefined,
            .r_str_concat = undefined,
            .r_str_eq = undefined,
        };
        self.declareRuntime();
        return self;
    }

    pub fn deinit(self: *Emitter) void {
        c.LLVMDisposeBuilder(self.builder);
        c.LLVMDisposeModule(self.mod);
        c.LLVMContextDispose(self.ctx);
        self.fns.deinit();
        self.globals.deinit();
        for (self.scopes.items) |*s| s.deinit();
        self.scopes.deinit(self.a);
    }

    fn declareRuntime(self: *Emitter) void {
        self.r_set_file = self.declVoid("astra_llvm_set_file", &.{self.t_ptr});
        self.r_init = self.declVoid("astra_llvm_runtime_init", &.{});
        self.r_cleanup = self.declVoid("astra_llvm_runtime_cleanup", &.{});
        self.r_fail = self.declVoid("astra_llvm_fail", &.{ self.t_i32, self.t_ptr });
        self.r_print_begin = self.declVoid("astra_llvm_print_begin", &.{});
        self.r_print_i64 = self.declVoid("astra_llvm_print_i64", &.{self.t_i64});
        self.r_print_f64 = self.declVoid("astra_llvm_print_f64", &.{self.t_f64});
        self.r_print_bool = self.declVoid("astra_llvm_print_bool", &.{self.t_i32});
        self.r_print_str = self.declVoid("astra_llvm_print_str", &.{self.t_ptr});
        self.r_print_end = self.declVoid("astra_llvm_print_end", &.{});
        // concat(line, a, b) devuelve el bloque nuevo; eq(a, b) → i32 0/1.
        self.r_str_concat = self.declRet(self.t_ptr, "astra_llvm_str_concat", &.{ self.t_i32, self.t_ptr, self.t_ptr });
        self.r_str_eq = self.declRet(self.t_i32, "astra_llvm_str_eq", &.{ self.t_ptr, self.t_ptr });
    }

    fn declRet(self: *Emitter, ret: c.LLVMTypeRef, name: [*:0]const u8, params: []const c.LLVMTypeRef) c.LLVMValueRef {
        var pbuf: [8]c.LLVMTypeRef = undefined;
        for (params, 0..) |p, i| pbuf[i] = p;
        const fty = c.LLVMFunctionType(ret, if (params.len > 0) &pbuf else null, @intCast(params.len), 0);
        return c.LLVMAddFunction(self.mod, name, fty);
    }

    fn declVoid(self: *Emitter, name: [*:0]const u8, params: []const c.LLVMTypeRef) c.LLVMValueRef {
        return self.declRet(self.t_void, name, params);
    }

    // ── Punto de entrada público ────────────────────────────────────────────

    pub fn emit(self: *Emitter, root: u32) void {
        const items = self.tree.extraSlice(self.tree.node(root).source_file);
        // 1: declara todas las funciones (recursión y mutua recursión).
        for (items) |it| {
            switch (self.tree.node(it)) {
                .fn_decl => self.declareFn(it),
                else => {},
            }
            if (self.error_count > 0) return;
        }
        // 2: crea los globales de módulo (los tipos ya se pueden inferir).
        for (items) |it| {
            switch (self.tree.node(it)) {
                .var_decl, .const_decl => self.declareGlobal(it),
                else => {},
            }
            if (self.error_count > 0) return;
        }
        // 3: emite los cuerpos de las funciones.
        for (items) |it| {
            switch (self.tree.node(it)) {
                .fn_decl => self.emitFn(it),
                else => {},
            }
            if (self.error_count > 0) return;
        }
        // 4: el código de módulo (sentencias de nivel superior + llama a main).
        self.emitModuleMain(items);
        if (self.error_count > 0) return;
        // 5: el entry point C (`@main`) que fija el archivo y llama a módulo+init.
        self.emitCMain();
        // 6: triple y datalayout del host (024 §2).
        self.setTarget();
    }

    // ── Firma de funciones y globales ───────────────────────────────────────

    fn declareFn(self: *Emitter, idx: u32) void {
        const fd = self.tree.node(idx).fn_decl;
        if (fd.generics.len > 0) return self.unsupported(idx, "generic function");
        const param_items = self.tree.extraSlice(fd.params);
        var pbuf: [16]c.LLVMTypeRef = undefined;
        if (param_items.len > pbuf.len) return self.unsupported(idx, "too many parameters");
        for (param_items, 0..) |pi, i| {
            const p = self.tree.node(pi).param;
            const mt = self.scalarM0Ty(p.type_node) orelse
                return self.unsupported(pi, "parameter without a scalar type annotation (i32/i64/u32/u64/f64/bool/string)");
            pbuf[i] = self.llvmTy(mt);
        }
        var ret_ty: c.LLVMTypeRef = self.t_void;
        var ret_m0: ?Ty = null;
        if (fd.ret) |ri| {
            const mt = self.scalarM0Ty(ri) orelse
                return self.unsupported(ri, "non-scalar return type");
            ret_ty = self.llvmTy(mt);
            ret_m0 = mt;
        }
        const fty = c.LLVMFunctionType(ret_ty, if (param_items.len > 0) &pbuf else null, @intCast(param_items.len), 0);
        const mangled = std.fmt.allocPrintSentinel(self.a, "astra_fn_{s}", .{fd.name}, 0) catch @panic("OOM");
        const fnv = c.LLVMAddFunction(self.mod, mangled, fty);
        self.fns.put(fd.name, .{ .val = fnv, .fty = fty, .returns_value = ret_m0 != null, .ret_ty = ret_m0 }) catch @panic("OOM");
    }

    fn declareGlobal(self: *Emitter, idx: u32) void {
        const vd = self.varDeclOf(idx);
        const ty = if (self.scalarM0Ty(vd.type_node)) |mt|
            mt
        else if (vd.value) |vi|
            self.inferStaticTy(vi) orelse return self.unsupported(idx, "cannot infer the scalar type of a top-level binding")
        else
            return self.unsupported(idx, "top-level binding without an initializer");
        const gname = std.fmt.allocPrintSentinel(self.a, "astra_g_{s}", .{vd.name}, 0) catch @panic("OOM");
        const gv = c.LLVMAddGlobal(self.mod, self.llvmTy(ty), gname);
        c.LLVMSetInitializer(gv, self.zeroInit(ty));
        self.globals.put(vd.name, .{ .val = gv, .ty = ty }) catch @panic("OOM");
    }

    fn emitFn(self: *Emitter, idx: u32) void {
        const fd = self.tree.node(idx).fn_decl;
        const info = self.fns.get(fd.name) orelse return; // la firma ya falló
        self.cur_fn = info.val;
        self.cur_returns_value = info.returns_value;
        const entry = c.LLVMAppendBasicBlockInContext(self.ctx, info.val, "entry");
        c.LLVMPositionBuilderAtEnd(self.builder, entry);
        self.pushScope();
        defer self.popScope();
        const param_items = self.tree.extraSlice(fd.params);
        for (param_items, 0..) |pi, i| {
            const p = self.tree.node(pi).param;
            const mt = self.scalarM0Ty(p.type_node) orelse return;
            const alloca = self.buildAlloca(self.llvmTy(mt));
            _ = c.LLVMBuildStore(self.builder, c.LLVMGetParam(info.val, @intCast(i)), alloca);
            self.addLocal(p.name, alloca, mt);
        }
        const body_val = self.emitBlockValue(fd.body);
        if (!self.isTerminated()) {
            if (info.returns_value) {
                if (body_val) |v| {
                    _ = c.LLVMBuildRet(self.builder, v.ref);
                } else {
                    _ = c.LLVMBuildUnreachable(self.builder);
                }
            } else {
                _ = c.LLVMBuildRetVoid(self.builder);
            }
        }
    }

    fn emitModuleMain(self: *Emitter, items: []const u32) void {
        const mty = c.LLVMFunctionType(self.t_void, null, 0, 0);
        const mm = c.LLVMAddFunction(self.mod, "astra_module_main", mty);
        self.module_main = mm;
        const entry = c.LLVMAppendBasicBlockInContext(self.ctx, mm, "entry");
        self.cur_fn = mm;
        self.cur_returns_value = false;
        c.LLVMPositionBuilderAtEnd(self.builder, entry);
        self.pushScope();
        defer self.popScope();
        for (items) |it| {
            switch (self.tree.node(it)) {
                .fn_decl => {},
                .var_decl, .const_decl => {
                    self.ensureOpenBlock();
                    self.emitGlobalDecl(it);
                },
                .use_decl, .import_decl, .from_decl, .struct_decl, .enum_decl, .trait_decl, .impl_decl => {
                    self.unsupported(it, "module-level declaration");
                    return;
                },
                else => {
                    self.ensureOpenBlock();
                    _ = self.emitExpr(it);
                },
            }
            if (self.error_count > 0) return;
        }
        if (self.fns.get("main")) |mi| {
            self.ensureOpenBlock();
            _ = c.LLVMBuildCall2(self.builder, mi.fty, mi.val, null, 0, "");
        }
        self.ensureOpenBlock();
        _ = c.LLVMBuildRetVoid(self.builder);
    }

    fn emitCMain(self: *Emitter) void {
        const imty = c.LLVMFunctionType(c.LLVMInt32TypeInContext(self.ctx), null, 0, 0);
        const mf = c.LLVMAddFunction(self.mod, "main", imty);
        const entry = c.LLVMAppendBasicBlockInContext(self.ctx, mf, "entry");
        self.cur_fn = mf;
        c.LLVMPositionBuilderAtEnd(self.builder, entry);
        const fp = c.LLVMBuildGlobalStringPtr(self.builder, self.file_z, "");
        var fargs = [_]c.LLVMValueRef{fp};
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_set_file), self.r_set_file, &fargs, 1, "");
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_init), self.r_init, null, 0, "");
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.module_main), self.module_main, null, 0, "");
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_cleanup), self.r_cleanup, null, 0, "");
        _ = c.LLVMBuildRet(self.builder, c.LLVMConstInt(c.LLVMInt32TypeInContext(self.ctx), 0, 0));
    }

    fn emitGlobalDecl(self: *Emitter, idx: u32) void {
        const vd = self.varDeclOf(idx);
        const vi = vd.value orelse return self.unsupported(idx, "top-level binding without an initializer");
        const val = self.emitExpr(vi) orelse {
            if (self.error_count == 0) self.unsupported(idx, "initializer produces no value");
            return;
        };
        const g = self.globals.get(vd.name) orelse return self.unsupported(idx, "unknown top-level binding");
        _ = c.LLVMBuildStore(self.builder, val.ref, g.val);
    }

    // ── Bloques y sentencias ────────────────────────────────────────────────

    fn emitBlockValue(self: *Emitter, idx: u32) ?Val {
        const blk = self.tree.node(idx).block;
        self.pushScope();
        defer self.popScope();
        const stmts = self.tree.extraSlice(blk.stmts);
        for (stmts) |si| {
            self.ensureOpenBlock();
            self.emitStmt(si);
            if (self.error_count > 0) return null;
        }
        if (blk.tail) |ti| {
            self.ensureOpenBlock();
            return self.emitExpr(ti);
        }
        return null;
    }

    fn emitStmt(self: *Emitter, idx: u32) void {
        switch (self.tree.node(idx)) {
            .expr_stmt => |e| _ = self.emitExpr(e),
            .var_decl, .const_decl => self.emitLocalDecl(idx),
            .if_expr => _ = self.emitIf(idx),
            .while_expr => self.emitWhile(idx),
            .return_stmt => self.emitReturn(idx),
            .block => _ = self.emitBlockValue(idx),
            .for_expr, .match_expr => self.unsupported(idx, "this expression form"),
            else => _ = self.emitExpr(idx),
        }
    }

    fn emitLocalDecl(self: *Emitter, idx: u32) void {
        const vd = self.varDeclOf(idx);
        const vi = vd.value orelse return self.unsupported(idx, "let without an initializer");
        const val = self.emitExpr(vi) orelse {
            if (self.error_count == 0) self.unsupported(idx, "initializer produces no value");
            return;
        };
        const ty = if (self.scalarM0Ty(vd.type_node)) |mt| mt else val.ty;
        const alloca = self.buildAlloca(self.llvmTy(ty));
        _ = c.LLVMBuildStore(self.builder, val.ref, alloca);
        self.addLocal(vd.name, alloca, ty);
    }

    fn emitReturn(self: *Emitter, idx: u32) void {
        const rv = self.tree.node(idx).return_stmt;
        if (self.cur_returns_value) {
            const vi = rv orelse return self.unsupported(idx, "return without a value");
            const v = self.emitExpr(vi) orelse return;
            _ = c.LLVMBuildRet(self.builder, v.ref);
        } else {
            if (rv) |vi| _ = self.emitExpr(vi); // evalúa por efectos y descarta
            _ = c.LLVMBuildRetVoid(self.builder);
        }
    }

    fn emitWhile(self: *Emitter, idx: u32) void {
        const we = self.tree.node(idx).while_expr;
        const cond_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "wh_cond");
        const body_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "wh_body");
        const exit_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "wh_exit");
        _ = c.LLVMBuildBr(self.builder, cond_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, cond_bb);
        const cond = self.emitExpr(we.cond) orelse return;
        _ = c.LLVMBuildCondBr(self.builder, self.truthyI1(cond), body_bb, exit_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        _ = self.emitBlockValue(we.body);
        if (!self.isTerminated()) _ = c.LLVMBuildBr(self.builder, cond_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, exit_bb);
    }

    fn emitIf(self: *Emitter, idx: u32) ?Val {
        const ie = self.tree.node(idx).if_expr;
        const cond = self.emitExpr(ie.cond) orelse return null;
        const has_else = ie.else_block != null;
        const then_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "if_then");
        const merge_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "if_merge");
        const else_bb: ?c.LLVMBasicBlockRef = if (has_else) c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "if_else") else null;
        _ = c.LLVMBuildCondBr(self.builder, self.truthyI1(cond), then_bb, else_bb orelse merge_bb);

        c.LLVMPositionBuilderAtEnd(self.builder, then_bb);
        const tval = self.emitBlockValue(ie.then_block);
        const t_term = self.isTerminated();
        const t_end = c.LLVMGetInsertBlock(self.builder);
        if (!t_term) _ = c.LLVMBuildBr(self.builder, merge_bb);

        var eval: ?Val = null;
        var e_term = true;
        var e_end = then_bb;
        if (has_else) {
            c.LLVMPositionBuilderAtEnd(self.builder, else_bb.?);
            eval = self.emitBlockValue(ie.else_block.?);
            e_term = self.isTerminated();
            e_end = c.LLVMGetInsertBlock(self.builder);
            if (!e_term) _ = c.LLVMBuildBr(self.builder, merge_bb);
        }

        c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        if (tval != null and eval != null and !t_term and !e_term) {
            const tv = tval.?;
            const ev = eval.?;
            if (tv.ty != ev.ty) {
                self.unsupported(idx, "if branches have different types");
                return null;
            }
            const phi = c.LLVMBuildPhi(self.builder, self.llvmTy(tv.ty), "");
            var vals = [_]c.LLVMValueRef{ tv.ref, ev.ref };
            var bbs = [_]c.LLVMBasicBlockRef{ t_end, e_end };
            c.LLVMAddIncoming(phi, &vals, &bbs, 2);
            return .{ .ref = phi, .ty = tv.ty };
        }
        return null;
    }

    // ── Expresiones ─────────────────────────────────────────────────────────

    fn emitExpr(self: *Emitter, idx: u32) ?Val {
        switch (self.tree.node(idx)) {
            .int_literal => |v| return .{ .ref = c.LLVMConstInt(self.t_i64, @as(u64, @bitCast(v)), 0), .ty = .i64_ },
            .float_literal => |v| return .{ .ref = c.LLVMConstReal(self.t_f64, v), .ty = .f64_ },
            .string_literal => |s| return self.emitStringLit(s),
            .bool_literal => |b| return .{ .ref = c.LLVMConstInt(self.t_i8, @intFromBool(b), 0), .ty = .bool_ },
            .identifier => |name| return self.emitIdent(idx, name),
            .binary_expr => return self.emitBinary(idx),
            .unary_expr => return self.emitUnary(idx),
            .call_expr => return self.emitCall(idx),
            .if_expr => return self.emitIf(idx),
            .assignment => return self.emitAssign(idx),
            .while_expr => {
                self.emitWhile(idx);
                return null;
            },
            .block => return self.emitBlockValue(idx),
            else => {
                self.unsupported(idx, "this expression form");
                return null;
            },
        }
    }

    /// Literal de string → global constante `{ i64 len; [len+1 x i8] data }`
    /// y su puntero como valor. La longitud va explícita (no un string C):
    /// el literal puede llevar NULs intercalados — `"a\0b"` del caso
    /// types/string_nul — y un puntero a C truncaría en el NUL (audit §2.14).
    fn emitStringLit(self: *Emitter, bytes: []const u8) Val {
        const len: u64 = bytes.len;
        const data_ty = c.LLVMArrayType(self.t_i8, @intCast(len + 1));
        var ftypes = [_]c.LLVMTypeRef{ self.t_i64, data_ty };
        const s_ty = c.LLVMStructTypeInContext(self.ctx, &ftypes, 2, 0);
        const data_c = c.LLVMConstStringInContext2(self.ctx, bytes.ptr, len, 0);
        var elts = [_]c.LLVMValueRef{ c.LLVMConstInt(self.t_i64, len, 0), data_c };
        const sinit = c.LLVMConstNamedStruct(s_ty, &elts, 2);
        self.str_seq += 1;
        const name = std.fmt.allocPrintSentinel(self.a, "astrstr.{d}", .{self.str_seq}, 0) catch @panic("OOM");
        const g = c.LLVMAddGlobal(self.mod, s_ty, name);
        c.LLVMSetInitializer(g, sinit);
        c.LLVMSetLinkage(g, c.LLVMPrivateLinkage);
        c.LLVMSetUnnamedAddress(g, c.LLVMGlobalUnnamedAddr);
        return .{ .ref = g, .ty = .str_ };
    }

    fn emitIdent(self: *Emitter, idx: u32, name: []const u8) ?Val {
        if (self.lookupLocal(name)) |l| {
            return .{ .ref = c.LLVMBuildLoad2(self.builder, self.llvmTy(l.ty), l.alloca, ""), .ty = l.ty };
        }
        if (self.globals.get(name)) |g| {
            return .{ .ref = c.LLVMBuildLoad2(self.builder, self.llvmTy(g.ty), g.val, ""), .ty = g.ty };
        }
        self.unsupported(idx, "reference to a function as a value");
        return null;
    }

    fn emitBinary(self: *Emitter, idx: u32) ?Val {
        const b = self.tree.node(idx).binary_expr;
        if (b.op == .and_and) return self.emitShortCircuit(idx, true);
        if (b.op == .or_or) return self.emitShortCircuit(idx, false);
        const lhs = self.emitExpr(b.left) orelse return null;
        const rhs = self.emitExpr(b.right) orelse return null;
        const line = self.tree.loc(idx).line;
        switch (b.op) {
            .eq_eq, .neq => {
                if (lhs.ty != rhs.ty) {
                    self.unsupported(idx, "comparison of mixed types");
                    return null;
                }
                if (lhs.ty == .str_) {
                    // Igualdad por contenido (value_eq del VM): len + memcmp,
                    // que es lo que resuelve los NULs intercalados (§2.14).
                    var sargs = [_]c.LLVMValueRef{ lhs.ref, rhs.ref };
                    const eqv = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_str_eq), self.r_str_eq, &sargs, 2, "");
                    var e8 = c.LLVMBuildTrunc(self.builder, eqv, self.t_i8, ""); // i32 0/1 → i8 0/1
                    if (b.op == .neq) e8 = c.LLVMBuildXor(self.builder, e8, c.LLVMConstInt(self.t_i8, 1, 0), "");
                    return .{ .ref = e8, .ty = .bool_ };
                }
                const cmp = if (lhs.ty == .f64_)
                    c.LLVMBuildFCmp(self.builder, if (b.op == .eq_eq) c.LLVMRealOEQ else c.LLVMRealUNE, lhs.ref, rhs.ref, "")
                else
                    c.LLVMBuildICmp(self.builder, if (b.op == .eq_eq) c.LLVMIntEQ else c.LLVMIntNE, lhs.ref, rhs.ref, "");
                return .{ .ref = c.LLVMBuildZExt(self.builder, cmp, self.t_i8, ""), .ty = .bool_ };
            },
            .lt, .gt, .le, .ge => {
                if (lhs.ty != rhs.ty) {
                    self.unsupported(idx, "comparison of mixed types");
                    return null;
                }
                if (lhs.ty == .str_) {
                    // Sólo los números se ordenan; `type_eq` deja pasar el caso
                    // y el runtime dice no (types/string_order_rejected).
                    self.emitGuardTrue(c.LLVMConstInt(self.t_i1, 1, 0), line, "cannot compare string and string");
                    return .{ .ref = c.LLVMConstInt(self.t_i8, 0, 0), .ty = .bool_ }; // inalcanzable: fail es noreturn
                }
                if (lhs.ty == .f64_) {
                    const pred: c.LLVMRealPredicate = switch (b.op) {
                        .lt => c.LLVMRealOLT,
                        .gt => c.LLVMRealOGT,
                        .le => c.LLVMRealOLE,
                        .ge => c.LLVMRealOGE,
                        else => unreachable,
                    };
                    const cmp = c.LLVMBuildFCmp(self.builder, pred, lhs.ref, rhs.ref, "");
                    return .{ .ref = c.LLVMBuildZExt(self.builder, cmp, self.t_i8, ""), .ty = .bool_ };
                }
                if (lhs.ty != .i64_) {
                    self.unsupported(idx, "ordered comparison requires numbers");
                    return null;
                }
                const pred: c.LLVMIntPredicate = switch (b.op) {
                    .lt => c.LLVMIntSLT,
                    .gt => c.LLVMIntSGT,
                    .le => c.LLVMIntSLE,
                    .ge => c.LLVMIntSGE,
                    else => unreachable,
                };
                const cmp = c.LLVMBuildICmp(self.builder, pred, lhs.ref, rhs.ref, "");
                return .{ .ref = c.LLVMBuildZExt(self.builder, cmp, self.t_i8, ""), .ty = .bool_ };
            },
            .plus, .minus, .star, .slash, .percent => {
                if (lhs.ty != rhs.ty) {
                    self.unsupported(idx, "arithmetic of mixed types");
                    return null;
                }
                if (lhs.ty == .str_ and b.op == .plus) {
                    // Concatenación (typechecker: string + string -> string).
                    var sargs = [_]c.LLVMValueRef{ c.LLVMConstInt(self.t_i32, line, 0), lhs.ref, rhs.ref };
                    const rp = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_str_concat), self.r_str_concat, &sargs, 3, "");
                    return .{ .ref = rp, .ty = .str_ };
                }
                if (lhs.ty == .f64_) {
                    const r = switch (b.op) {
                        .plus => c.LLVMBuildFAdd(self.builder, lhs.ref, rhs.ref, ""),
                        .minus => c.LLVMBuildFSub(self.builder, lhs.ref, rhs.ref, ""),
                        .star => c.LLVMBuildFMul(self.builder, lhs.ref, rhs.ref, ""),
                        .slash => self.emitDivRem(lhs.ref, rhs.ref, line, false, .f64_),
                        .percent => self.emitDivRem(lhs.ref, rhs.ref, line, true, .f64_),
                        else => unreachable,
                    };
                    return .{ .ref = r, .ty = .f64_ };
                }
                if (lhs.ty != .i64_) {
                    self.unsupported(idx, "arithmetic requires numbers");
                    return null;
                }
                const r = switch (b.op) {
                    .plus => c.LLVMBuildAdd(self.builder, lhs.ref, rhs.ref, ""),
                    .minus => c.LLVMBuildSub(self.builder, lhs.ref, rhs.ref, ""),
                    .star => c.LLVMBuildMul(self.builder, lhs.ref, rhs.ref, ""),
                    .slash => self.emitDivRem(lhs.ref, rhs.ref, line, false, .i64_),
                    .percent => self.emitDivRem(lhs.ref, rhs.ref, line, true, .i64_),
                    else => unreachable,
                };
                return .{ .ref = r, .ty = .i64_ };
            },
            .amp, .pipe, .caret, .shl, .shr => {
                if (lhs.ty != .i64_ or rhs.ty != .i64_) {
                    self.unsupported(idx, "bitwise operation requires integers");
                    return null;
                }
                const r = switch (b.op) {
                    .amp => c.LLVMBuildAnd(self.builder, lhs.ref, rhs.ref, ""),
                    .pipe => c.LLVMBuildOr(self.builder, lhs.ref, rhs.ref, ""),
                    .caret => c.LLVMBuildXor(self.builder, lhs.ref, rhs.ref, ""),
                    .shl => self.emitShift(lhs.ref, rhs.ref, line, true),
                    .shr => self.emitShift(lhs.ref, rhs.ref, line, false),
                    else => unreachable,
                };
                return .{ .ref = r, .ty = .i64_ };
            },
            else => {
                self.unsupported(idx, "binary operator");
                return null;
            },
        }
    }

    fn emitUnary(self: *Emitter, idx: u32) ?Val {
        const u = self.tree.node(idx).unary_expr;
        const v = self.emitExpr(u.operand) orelse return null;
        switch (u.op) {
            .minus => {
                if (v.ty == .f64_) {
                    return .{ .ref = c.LLVMBuildFNeg(self.builder, v.ref, ""), .ty = .f64_ };
                }
                if (v.ty != .i64_) {
                    self.unsupported(idx, "negation requires a number");
                    return null;
                }
                const zero = c.LLVMConstInt(self.t_i64, 0, 0);
                return .{ .ref = c.LLVMBuildSub(self.builder, zero, v.ref, ""), .ty = .i64_ };
            },
            .tilde => {
                if (v.ty != .i64_) {
                    self.unsupported(idx, "bitwise not requires an integer");
                    return null;
                }
                const allones = c.LLVMConstInt(self.t_i64, std.math.maxInt(u64), 0);
                return .{ .ref = c.LLVMBuildXor(self.builder, v.ref, allones, ""), .ty = .i64_ };
            },
            .bang => {
                const t = self.truthyI1(v);
                const f = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, t, c.LLVMConstInt(self.t_i1, 0, 0), "");
                return .{ .ref = c.LLVMBuildZExt(self.builder, f, self.t_i8, ""), .ty = .bool_ };
            },
            else => {
                self.unsupported(idx, "unary operator");
                return null;
            },
        }
    }

    fn emitShortCircuit(self: *Emitter, idx: u32, is_and: bool) ?Val {
        const b = self.tree.node(idx).binary_expr;
        const lhs = self.emitExpr(b.left) orelse return null;
        const lcond = self.truthyI1(lhs);
        const rhs_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "sc_rhs");
        const short_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "sc_short");
        const merge_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "sc_merge");
        if (is_and) {
            _ = c.LLVMBuildCondBr(self.builder, lcond, rhs_bb, short_bb);
            c.LLVMPositionBuilderAtEnd(self.builder, rhs_bb);
            const rhs = self.emitExpr(b.right) orelse return null;
            const rcond = self.truthyI1(rhs);
            const rhs_end = c.LLVMGetInsertBlock(self.builder);
            _ = c.LLVMBuildBr(self.builder, merge_bb);
            c.LLVMPositionBuilderAtEnd(self.builder, short_bb);
            _ = c.LLVMBuildBr(self.builder, merge_bb);
            c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
            const phi = c.LLVMBuildPhi(self.builder, self.t_i1, "");
            var vals = [_]c.LLVMValueRef{ c.LLVMConstInt(self.t_i1, 0, 0), rcond };
            var bbs = [_]c.LLVMBasicBlockRef{ short_bb, rhs_end };
            c.LLVMAddIncoming(phi, &vals, &bbs, 2);
            return .{ .ref = c.LLVMBuildZExt(self.builder, phi, self.t_i8, ""), .ty = .bool_ };
        } else {
            _ = c.LLVMBuildCondBr(self.builder, lcond, short_bb, rhs_bb);
            c.LLVMPositionBuilderAtEnd(self.builder, short_bb);
            _ = c.LLVMBuildBr(self.builder, merge_bb);
            c.LLVMPositionBuilderAtEnd(self.builder, rhs_bb);
            const rhs = self.emitExpr(b.right) orelse return null;
            const rcond = self.truthyI1(rhs);
            const rhs_end = c.LLVMGetInsertBlock(self.builder);
            _ = c.LLVMBuildBr(self.builder, merge_bb);
            c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
            const phi = c.LLVMBuildPhi(self.builder, self.t_i1, "");
            var vals = [_]c.LLVMValueRef{ c.LLVMConstInt(self.t_i1, 1, 0), rcond };
            var bbs = [_]c.LLVMBasicBlockRef{ short_bb, rhs_end };
            c.LLVMAddIncoming(phi, &vals, &bbs, 2);
            return .{ .ref = c.LLVMBuildZExt(self.builder, phi, self.t_i8, ""), .ty = .bool_ };
        }
    }

    fn emitAssign(self: *Emitter, idx: u32) ?Val {
        const as = self.tree.node(idx).assignment;
        const val = self.emitExpr(as.value) orelse return null;
        const target_name = switch (self.tree.node(as.target)) {
            .identifier => |nm| nm,
            else => {
                self.unsupported(idx, "assignment target must be a variable");
                return null;
            },
        };
        if (self.lookupLocal(target_name)) |l| {
            _ = c.LLVMBuildStore(self.builder, val.ref, l.alloca);
        } else if (self.globals.get(target_name)) |g| {
            _ = c.LLVMBuildStore(self.builder, val.ref, g.val);
        } else {
            self.unsupported(idx, "assignment to an unknown variable");
            return null;
        }
        return val; // la asignación produce su valor
    }

    fn emitCall(self: *Emitter, idx: u32) ?Val {
        const call = self.tree.node(idx).call_expr;
        switch (self.tree.node(call.callee)) {
            .identifier => |name| {
                if (std.mem.eql(u8, name, "print")) return self.emitPrint(idx);
                const info = self.fns.get(name) orelse {
                    self.unsupported(idx, "call to an unknown function");
                    return null;
                };
                const args = self.tree.extraSlice(call.args);
                var abuf: [16]c.LLVMValueRef = undefined;
                if (args.len > abuf.len) {
                    self.unsupported(idx, "too many arguments");
                    return null;
                }
                for (args, 0..) |ai, i| {
                    const av = self.emitExpr(ai) orelse return null;
                    abuf[i] = av.ref;
                }
                const rv = c.LLVMBuildCall2(self.builder, info.fty, info.val, if (args.len > 0) &abuf else null, @intCast(args.len), "");
                if (info.returns_value) return .{ .ref = rv, .ty = info.ret_ty.? };
                return null;
            },
            else => {
                self.unsupported(idx, "only direct calls to named functions");
                return null;
            },
        }
    }

    fn emitPrint(self: *Emitter, idx: u32) ?Val {
        const call = self.tree.node(idx).call_expr;
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_begin), self.r_print_begin, null, 0, "");
        const args = self.tree.extraSlice(call.args);
        for (args) |ai| {
            const av = self.emitExpr(ai) orelse {
                if (self.error_count == 0) self.unsupported(idx, "print argument without a scalar value");
                return null;
            };
            switch (av.ty) {
                .i64_ => {
                    var iargs = [_]c.LLVMValueRef{av.ref};
                    _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_i64), self.r_print_i64, &iargs, 1, "");
                },
                .f64_ => {
                    var fargs = [_]c.LLVMValueRef{av.ref};
                    _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_f64), self.r_print_f64, &fargs, 1, "");
                },
                .bool_ => {
                    const ext = c.LLVMBuildZExt(self.builder, av.ref, self.t_i32, "");
                    var bargs = [_]c.LLVMValueRef{ext};
                    _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_bool), self.r_print_bool, &bargs, 1, "");
                },
                .str_ => {
                    var sargs = [_]c.LLVMValueRef{av.ref};
                    _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_str), self.r_print_str, &sargs, 1, "");
                },
            }
        }
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_end), self.r_print_end, null, 0, "");
        return null; // print es void
    }

    // ── Guards de aritmética (idénticos al VM) ──────────────────────────────

    fn emitDivRem(self: *Emitter, a: c.LLVMValueRef, b: c.LLVMValueRef, line: u32, is_rem: bool, ty: Ty) c.LLVMValueRef {
        if (ty == .f64_) {
            // Float: divisor cero es error (no inf) con el mismo texto que el VM
            // (S14); sin guard de INT64_MIN (no aplica), `%` = fmod.
            const fzero = c.LLVMConstReal(self.t_f64, 0.0);
            const b_fzero = c.LLVMBuildFCmp(self.builder, c.LLVMRealOEQ, b, fzero, "");
            self.emitGuardTrue(b_fzero, line, if (is_rem) "modulo by zero" else "division by zero");
            if (is_rem) return c.LLVMBuildFRem(self.builder, a, b, "");
            return c.LLVMBuildFDiv(self.builder, a, b, "");
        }
        const zero = c.LLVMConstInt(self.t_i64, 0, 0);
        const b_zero = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, b, zero, "");
        self.emitGuardTrue(b_zero, line, if (is_rem) "modulo by zero" else "division by zero");
        // INT64_MIN / -1 desborda en ambos backends.
        const min = c.LLVMConstInt(self.t_i64, 1 << 63, 0);
        const neg1 = c.LLVMConstInt(self.t_i64, std.math.maxInt(u64), 0);
        const a_min = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, a, min, "");
        const b_neg1 = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, b, neg1, "");
        const ovf = c.LLVMBuildAnd(self.builder, a_min, b_neg1, "");
        self.emitGuardTrue(ovf, line, "integer overflow");
        if (is_rem) return c.LLVMBuildSRem(self.builder, a, b, "");
        return c.LLVMBuildSDiv(self.builder, a, b, "");
    }

    fn emitShift(self: *Emitter, a: c.LLVMValueRef, b: c.LLVMValueRef, line: u32, is_shl: bool) c.LLVMValueRef {
        const zero = c.LLVMConstInt(self.t_i64, 0, 0);
        const sixtyfour = c.LLVMConstInt(self.t_i64, 64, 0);
        const b_neg = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, b, zero, "");
        const b_big = c.LLVMBuildICmp(self.builder, c.LLVMIntSGE, b, sixtyfour, "");
        const bad = c.LLVMBuildOr(self.builder, b_neg, b_big, "");
        self.emitGuardTrue(bad, line, "shift amount out of range (must be 0..63)");
        if (is_shl) return c.LLVMBuildShl(self.builder, a, b, "");
        return c.LLVMBuildAShr(self.builder, a, b, "");
    }

    /// Si `cond` es true, salta a un bloque que llama a `astra_llvm_fail` y
    /// termina con `unreachable`; si no, continúa en el bloque siguiente.
    fn emitGuardTrue(self: *Emitter, cond: c.LLVMValueRef, line: u32, msg: [*:0]const u8) void {
        const fail_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "guard_fail");
        const cont_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "guard_cont");
        _ = c.LLVMBuildCondBr(self.builder, cond, fail_bb, cont_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, fail_bb);
        const linev = c.LLVMConstInt(self.t_i32, line, 0);
        const msgp = c.LLVMBuildGlobalStringPtr(self.builder, msg, "");
        var fargs = [_]c.LLVMValueRef{ linev, msgp };
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_fail), self.r_fail, &fargs, 2, "");
        _ = c.LLVMBuildUnreachable(self.builder);
        c.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
    }

    // ── Utilidades ──────────────────────────────────────────────────────────

    fn buildAlloca(self: *Emitter, ty: c.LLVMTypeRef) c.LLVMValueRef {
        const cur_bb = c.LLVMGetInsertBlock(self.builder);
        const entry = c.LLVMGetEntryBasicBlock(self.cur_fn);
        const first = c.LLVMGetFirstInstruction(entry);
        if (first != null) {
            c.LLVMPositionBuilderBefore(self.builder, first);
        } else {
            c.LLVMPositionBuilderAtEnd(self.builder, entry);
        }
        const a = c.LLVMBuildAlloca(self.builder, ty, "");
        c.LLVMPositionBuilderAtEnd(self.builder, cur_bb);
        return a;
    }

    fn truthyI1(self: *Emitter, v: Val) c.LLVMValueRef {
        // Las condiciones son bool por el typechecker; el caso f64 es defensivo
        // y replica `!= 0.0` de C (true también para NaN → UNE).
        if (v.ty == .f64_) {
            const fzero = c.LLVMConstReal(self.t_f64, 0.0);
            return c.LLVMBuildFCmp(self.builder, c.LLVMRealUNE, v.ref, fzero, "");
        }
        if (v.ty == .str_) {
            // VM: `str != NULL && len > 0`; en este modelo los strings nunca
            // son NULL, así que basta len > 0.
            const len = c.LLVMBuildLoad2(self.builder, self.t_i64, v.ref, "");
            return c.LLVMBuildICmp(self.builder, c.LLVMIntNE, len, c.LLVMConstInt(self.t_i64, 0, 0), "");
        }
        const zero = switch (v.ty) {
            .i64_ => c.LLVMConstInt(self.t_i64, 0, 0),
            .bool_ => c.LLVMConstInt(self.t_i8, 0, 0),
            .f64_, .str_ => unreachable,
        };
        return c.LLVMBuildICmp(self.builder, c.LLVMIntNE, v.ref, zero, "");
    }

    fn isTerminated(self: *Emitter) bool {
        const bb = c.LLVMGetInsertBlock(self.builder);
        const last = c.LLVMGetLastInstruction(bb);
        if (last == null) return false;
        return c.LLVMIsATerminatorInst(last) != null;
    }

    fn ensureOpenBlock(self: *Emitter) void {
        if (self.isTerminated()) {
            const dead = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "dead");
            c.LLVMPositionBuilderAtEnd(self.builder, dead);
        }
    }

    fn pushScope(self: *Emitter) void {
        self.scopes.append(self.a, std.StringHashMap(Local).init(self.a)) catch @panic("OOM");
    }

    fn popScope(self: *Emitter) void {
        const idx = self.scopes.items.len - 1;
        self.scopes.items[idx].deinit();
        self.scopes.items.len = idx;
    }

    fn lookupLocal(self: *Emitter, name: []const u8) ?Local {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |l| return l;
        }
        return null;
    }

    fn addLocal(self: *Emitter, name: []const u8, alloca: c.LLVMValueRef, ty: Ty) void {
        self.scopes.items[self.scopes.items.len - 1].put(name, .{ .alloca = alloca, .ty = ty }) catch @panic("OOM");
    }

    fn varDeclOf(self: *Emitter, idx: u32) ast.VarDecl {
        return switch (self.tree.node(idx)) {
            .var_decl => |v| v,
            .const_decl => |v| v,
            else => unreachable,
        };
    }

    fn llvmTy(self: *Emitter, ty: Ty) c.LLVMTypeRef {
        return switch (ty) {
            .i64_ => self.t_i64,
            .bool_ => self.t_i8,
            .f64_ => self.t_f64,
            .str_ => self.t_ptr,
        };
    }

    /// Inicializador cero de un global, con la forma correcta para cada tipo:
    /// `LLVMConstInt` sobre un tipo no entero (f64/ptr) es inválido y rompía
    /// `let g = 1.5` o `let g = "x"` a nivel de módulo.
    fn zeroInit(self: *Emitter, ty: Ty) c.LLVMValueRef {
        return switch (ty) {
            .i64_ => c.LLVMConstInt(self.t_i64, 0, 0),
            .bool_ => c.LLVMConstInt(self.t_i8, 0, 0),
            .f64_ => c.LLVMConstReal(self.t_f64, 0.0),
            .str_ => c.LLVMConstPointerNull(self.t_ptr),
        };
    }

    fn scalarM0Ty(self: *Emitter, node: ?u32) ?Ty {
        const ni = node orelse return null;
        switch (self.tree.node(ni)) {
            .type_ident => |t| {
                if (std.mem.eql(u8, t.name, "i32") or std.mem.eql(u8, t.name, "i64") or
                    std.mem.eql(u8, t.name, "u32") or std.mem.eql(u8, t.name, "u64")) return .i64_;
                if (std.mem.eql(u8, t.name, "bool")) return .bool_;
                if (std.mem.eql(u8, t.name, "f64")) return .f64_;
                if (std.mem.eql(u8, t.name, "string")) return .str_;
                return null;
            },
            else => return null,
        }
    }

    /// Inferencia de tipo M0 para inicializadores de globales (donde aún no hay
    /// valor emitido del cual leer el tipo). Suficiente para el subconjunto M0.
    fn inferStaticTy(self: *Emitter, idx: u32) ?Ty {
        switch (self.tree.node(idx)) {
            .int_literal => return .i64_,
            .float_literal => return .f64_,
            .string_literal => return .str_,
            .bool_literal => return .bool_,
            .identifier => |name| {
                if (self.lookupLocal(name)) |l| return l.ty;
                if (self.globals.get(name)) |g| return g.ty;
                return null;
            },
            .unary_expr => |u| switch (u.op) {
                .bang => return .bool_,
                .tilde => return .i64_,
                .minus => {
                    // `-1.5` es f64 pero `-1` es i64: el operando decide.
                    if (self.inferStaticTy(u.operand)) |ot| {
                        if (ot == .f64_) return .f64_;
                    }
                    return .i64_;
                },
                else => return null,
            },
            .binary_expr => |b| switch (b.op) {
                .eq_eq, .neq, .lt, .gt, .le, .ge, .and_and, .or_or => return .bool_,
                else => {
                    // Aritmética: f64 si alguno de los operandos es float, si no i64.
                    if (self.inferStaticTy(b.left)) |lt| {
                        if (lt == .f64_) return .f64_;
                    }
                    if (self.inferStaticTy(b.right)) |rt| {
                        if (rt == .f64_) return .f64_;
                    }
                    return .i64_;
                },
            },
            .call_expr => |call| switch (self.tree.node(call.callee)) {
                .identifier => |nm| {
                    if (std.mem.eql(u8, nm, "print")) return null;
                    if (self.fns.get(nm)) |fi| return fi.ret_ty;
                    return null;
                },
                else => return null,
            },
            .if_expr => |ie| {
                const tb = self.tree.node(ie.then_block).block;
                if (tb.tail) |t| return self.inferStaticTy(t);
                return null;
            },
            else => return null,
        }
    }

    fn setTarget(self: *Emitter) void {
        const triple = c.LLVMGetDefaultTargetTriple();
        defer c.LLVMDisposeMessage(triple);
        c.LLVMSetTarget(self.mod, triple);
        const td = c.LLVMCreateTargetData("");
        defer c.LLVMDisposeTargetData(td);
        const dl = c.LLVMCopyStringRepOfTargetData(td);
        defer c.LLVMDisposeMessage(dl);
        c.LLVMSetDataLayout(self.mod, dl);
    }

    fn unsupported(self: *Emitter, idx: u32, what: []const u8) void {
        self.error_count += 1;
        diagnostics.emit(self.diag, self.file, self.tree.loc(idx), "not supported by the LLVM backend: {s}", .{what});
    }
};

// ── Pruebas unitarias (solo bajo -Dllvm, vía tests.zig) ────────────────────

test "emite fib, verifica el módulo y rotula la firma" {
    const parser = @import("../parser/parser.zig");
    const typechecker = @import("../typechecker/typechecker.zig");
    const src =
        \\fn fib(n: i64) -> i64 {
        \\    if n < 2 { return n }
        \\    return fib(n - 1) + fib(n - 2)
        \\}
        \\fn main() {
        \\    print(fib(20))
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tree = ast.Tree.init(a, src);
    defer tree.deinit();
    var p = parser.Parser.init(a, src, &tree);
    p.filename = "fib.astra";
    const root = p.parse() catch unreachable;
    var tc = try typechecker.TypeChecker.init(a, &tree, "fib.astra");
    tc.check(root);
    try std.testing.expectEqual(@as(u32, 0), tc.error_count);

    var em = Emitter.init(a, &tree, "fib.astra");
    defer em.deinit();
    em.emit(root);
    try std.testing.expectEqual(@as(u32, 0), em.error_count);

    // El módulo debe pasar el verificador de LLVM sin errores.
    var err: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.LLVMVerifyModule(em.mod, c.LLVMReturnStatusAction, &err));
    if (err != null) c.LLVMDisposeMessage(err);

    // La firma de fib lleva su nombre mangulado y tipo i64.
    const ir = c.LLVMPrintModuleToString(em.mod);
    defer c.LLVMDisposeMessage(ir);
    const ir_str = std.mem.span(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "define i64 @astra_fn_fib") != null);
}

test "emite el guard de división entre cero con astra_llvm_fail" {
    const parser = @import("../parser/parser.zig");
    const typechecker = @import("../typechecker/typechecker.zig");
    const src =
        \\fn div(a: i64, b: i64) -> i64 {
        \\    return a / b
        \\}
        \\fn main() {
        \\    print(div(10, 2))
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tree = ast.Tree.init(a, src);
    defer tree.deinit();
    var p = parser.Parser.init(a, src, &tree);
    p.filename = "div.astra";
    const root = p.parse() catch unreachable;
    var tc = try typechecker.TypeChecker.init(a, &tree, "div.astra");
    tc.check(root);
    try std.testing.expectEqual(@as(u32, 0), tc.error_count);

    var em = Emitter.init(a, &tree, "div.astra");
    defer em.deinit();
    em.emit(root);
    try std.testing.expectEqual(@as(u32, 0), em.error_count);

    const ir = c.LLVMPrintModuleToString(em.mod);
    defer c.LLVMDisposeMessage(ir);
    const ir_str = std.mem.span(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_llvm_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "division by zero") != null);
}
