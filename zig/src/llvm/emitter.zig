//! Emisor LLVM (Fase LLVM, LLVM_BACKEND_PLAN.md §6).
//!
//! Convierte el AST plano ya verificado por el typechecker en LLVM IR textual
//! para el subconjunto escalar: literales int/bool/float/string, identificadores,
//! `let`/`const` (locales y de módulo), asignación, aritmética i64 y f64 con
//! los mismos guards que el VM, `+` de strings (concat por contenido),
//! comparaciones, `&&`/`||`/`!`, `if` (sentencia y expresión vía phi), `while`,
//! funciones con recursión, `return`, `print`, Option/Result (`some`/`none`/
//! `ok`/`err`, `match` sobre variantes builtin/literales, `?`), `match` como
//! expresión (phi de brazos), closures (M1.d): lambdas `|x: i32| -> i32 { }`
//! como valores de primer orden con captura por valor, y arrays (M2.a) como
//! objetos homogéneos `{ i64 len; i32 elem_pty; i32 pad; <elems> }` con
//! identidad compartida, bounds check y lectura/escritura por índice.
//!
//! Modelo de valores: escalares sin boxing — `i64` para todos los tipos enteros
//! de Astra (el VM almacena int64 completo), `i8` 0/1 para bool, `f64` para
//! floats — más dos tipos con heap: `str_`, puntero al bloque
//! `{ i64 len; [len+1 x i8] data }` (longitud explícita como el par (str, len)
//! del VM, soporta NULs intercalados, §2.14), y `boxed_` (Option/Result),
//! puntero a `{ i32 tag; i32 ptype; i64 payload }` con `none` como NULL: tag y
//! payload se leen dinámicamente como en el VM, porque el typechecker admite
//! aliasing Tier-2 (ok/err donde se esperaba some/none).
//! El typechecker exige tipos de operandos idénticos (`type_eq`) en
//! aritmética/comparación/asignación/argumentos, así que el emisor no necesita
//! coerción int↔float: si ve operandos de distinto tipo es un bug del checker.
//! El boxing de arrays/structs/enums de usuario llega con M2. Los guards de
//! div/mod/shift se emiten en línea y delegan el error en `astra_llvm_fail`,
//! que reimprime `file:line: runtime error: msg` con el runtime compartido del
//! seed — así la ruta LLVM no deriva en un tercer formato de error.
//!
//! Todo lo que está fuera de alcance se rechaza con `diagnostics.emit` y sale
//! limpio (exit 1) sin escribir IR: el emisor nunca produce un módulo a medias.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const diagnostics = @import("../diagnostics.zig");
const c = @import("c_api.zig").c;

/// Tipos escalares que el subconjunto actual representa sin boxing, más los
/// tipos con heap: `i64` para todos los tipos enteros de Astra, `bool` como
/// `i8` 0/1, `f64` para floats, `str_` como puntero al bloque
/// `{ i64 len; [len+1 x i8] data }`, `boxed_` (Option/Result) como puntero a
/// `{ i32 tag; i32 ptype; i64 payload }` (M1), `fn_` (funciones de primer
/// orden, M1.d) como puntero al objeto `{ ptr code; ptr env }`, `arr_`
/// (M2.a) como puntero al objeto `{ i64 len; i32 elem_pty; i32 pad; <elems> }`
/// — identidad compartida, igual que el handle del VM — y `struct_` (M2.b)
/// como puntero al objeto `{ ptr def; <campos en slots de 8 bytes> }` y
/// `enum_` (M2.c) como puntero al objeto
/// `{ ptr def; i32 variant; i32 kind; <payload@16> }` (kind 0 = nombre sin
/// payload / patrón, kind 1 = data construido — los dos kinds del VM).
const Ty = enum { i64_, bool_, f64_, str_, boxed_, fn_, arr_, struct_, enum_ };

/// Un valor emitido: su representación LLVM y su tipo. Las expresiones sin
/// valor (void: `print`, `while`, `let` de módulo…) devuelven `null`.
/// `payload_ty` es el tipo estático del contenido: para un `boxed_` es el `T`
/// de `T?`/`some(x)` (bindings de `match`, `?`); para un `fn_` el tipo de
/// retorno (null = void, lo que la llamada dinámica arma en el sitio); para
/// un `arr_` el tipo de sus elementos (índices, bounds y print).
/// `sname` es el nombre del struct cuando el valor es un `struct_` (también
/// cuando un `boxed_`/`fn_`/`arr_` lo transporta como payload/retorno): los
/// campos se resuelven contra el layout con ese nombre. Límite documentado:
/// los literales de array de structs y las lambdas con retorno struct anotado
/// sólo propagan el `Ty` (sin nombre), así que el acceso a campo sobre ellos
/// se rechaza honestamente.
const Val = struct { ref: c.LLVMValueRef, ty: Ty, payload_ty: ?Ty = null, sname: ?[]const u8 = null };

const FnInfo = struct {
    val: c.LLVMValueRef,
    /// Tipo de función LLVM, cacheado para `LLVMBuildCall2`.
    fty: c.LLVMTypeRef,
    /// `true` cuando la función devuelve un escalar (falso = void).
    returns_value: bool,
    ret_ty: ?Ty,
    /// Payload del retorno `T?` (el `T`), para `?` y match sobre su resultado.
    ret_payload: ?Ty = null,
    /// Nombre de struct si el retorno es `struct_` (resultado de una
    /// llamada dinámica vía `fn_` conserva su forma para el acceso a campo).
    ret_sname: ?[]const u8 = null,
};

const GlobalInfo = struct { val: c.LLVMValueRef, ty: Ty, payload_ty: ?Ty = null, sname: ?[]const u8 = null };
const Local = struct { alloca: c.LLVMValueRef, ty: Ty, payload_ty: ?Ty = null, sname: ?[]const u8 = null };
/// Binding temporal para la inferencia de la firma de un `fn` sin `->`:
/// declareFn corre antes de emitir el cuerpo, así que los `let` de dentro no
/// están en el scope real. Se resuelven aquí solo para tipos (nunca para
/// valores), con la última declaración ganando (conservador).
const InferBinding = struct { ty: Ty, payload: ?Ty = null, sname: ?[]const u8 = null };
const InferredRet = struct { ty: Ty, payload: ?Ty = null, sname: ?[]const u8 = null };
const RetScan = struct { ty: ?Ty = null, node: ?u32 = null, conflict: bool = false, bare: bool = false };

/// Una captura de closure: su nombre, el tipo estático con el que se lee del
/// env (i64 bits) y su índice en el env de la lambda. Los closures capturan
/// por valor (ARCHITECTURE.md §30.5, audit §7.11): el sitio de creación
/// snapshota los valores actuales en un array heap que sobrevive al frame
/// que los produjo — ni el reasignar la variable después alcanza al closure,
/// ni la salida del frame rompe el env.
const CapSlot = struct { name: []const u8, ty: Ty, payload_ty: ?Ty = null, sname: ?[]const u8 = null, index: u32 = 0 };
const CaptureScope = std.ArrayListUnmanaged(CapSlot);

/// Un campo en el layout de un struct.
const StructField = struct { name: []const u8, ty: Ty, payload: ?Ty = null, sname: ?[]const u8 = null };

/// Layout de un struct (M2.b): campos en ORDEN DE DECLARACIÓN, cada uno en un
/// slot de 8 bytes desde offset 8 — offset 0 del objeto = puntero al
/// descriptor estático `AstraLLVMStructDef` del runtime, que es lo que
/// print/eq leen del propio objeto (como s->def en el VM). `def` es el
/// global LLVM del descriptor, emitido al registrar el layout.
const StructLayout = struct { fields: []StructField, def: c.LLVMValueRef, size: i64 };

/// Una variante de enum: nombre, sus slots de payload (tipos de la
/// anotación de la declaración) y la constante kind-0 de
/// `Enum.Variant` (objeto estático `{ def, idx, kind=0 }` — el VAL_ENUM del
/// VM para accesos unit y patrones de match).
const EnumVariantLayout = struct { name: []const u8, fields: []StructField, unit_const: c.LLVMValueRef };

/// Layout de un enum (M2.c): descriptor `AstraLLVMEnumDef` + variantes.
const EnumLayout = struct { name: []const u8, variants: []EnumVariantLayout, def: c.LLVMValueRef };

/// Dónde vive un nombre de variante (para el constructor pelón `Circle(x)`:
/// el seed busca en TODOS los enums y devuelve el primero — emitter.c
/// find_enum_by_variant —, así que guardamos sólo la primera aparición).
const VariantRef = struct { enum_name: []const u8, index: usize };

/// Contexto de loop activo para break/continue (M2.d): la salida y el
/// objetivo de `continue` (el incremento de un `for`, la condición de un
/// `while` — el seed: loop_start en NODE_WHILE, post-del-cuerpo en NODE_FOR).
const LoopCtx = struct { break_bb: c.LLVMBasicBlockRef, continue_bb: c.LLVMBasicBlockRef };

/// Análisis de variables libres para closures (réplica de collect_free_vars
/// del seed, emitter.c §347): recorre un cuerpo de lambda y recolecta los
/// nombres que resuelven al scope ENCLOSING (locales o capturas actuales) y
/// no están ligados dentro de la lambda. Las lambdas anidadas contribuyen
/// con sus propios nombres libres — un nombre libre a cualquier profundidad
/// debe ser alcanzable desde el env del lambda más externo, porque los
/// sitios de creación internos lo leen por GET_LOCAL/GET_CAPTURE del frame
/// que los contiene. Las `fn` declaradas se saltan: sólo las lambdas
/// capturan y un cuerpo de fn anidada resuelve sus nombres libres como
/// globales.
const FreeVars = struct {
    em: *Emitter,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    marks: std.ArrayListUnmanaged(usize) = .empty,
    caps: CaptureScope = .empty,
    overflow: bool = false,

    fn deinit(fv: *FreeVars) void {
        const a = fv.em.a;
        fv.names.deinit(a);
        fv.marks.deinit(a);
        fv.caps.deinit(a);
    }

    fn pushScope(fv: *FreeVars) void {
        fv.marks.append(fv.em.a, fv.names.items.len) catch @panic("OOM");
    }
    fn popScope(fv: *FreeVars) void {
        fv.names.items.len = fv.marks.pop().?;
    }
    fn bind(fv: *FreeVars, name: []const u8) void {
        fv.names.append(fv.em.a, name) catch @panic("OOM");
    }
    fn bound(fv: *FreeVars, name: []const u8) bool {
        var i = fv.names.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, fv.names.items[i], name)) return true;
        }
        return false;
    }
    fn ref(fv: *FreeVars, name: []const u8) void {
        if (fv.bound(name)) return;
        // Una captura iff el scope enclosing puede suministrarla (local o
        // captura propia). Cualquier otro nombre es global y se queda global.
        const em = fv.em;
        var ty: ?Ty = null;
        var pty: ?Ty = null;
        var sn: ?[]const u8 = null;
        if (em.lookupLocal(name)) |l| {
            ty = l.ty;
            pty = l.payload_ty;
            sn = l.sname;
        } else if (em.lookupCapture(name)) |cp| {
            ty = cp.ty;
            pty = cp.payload_ty;
            sn = cp.sname;
        } else return;
        for (fv.caps.items) |cp2| {
            if (std.mem.eql(u8, cp2.name, name)) return;
        }
        if (fv.caps.items.len >= 16) {
            fv.overflow = true;
            return;
        }
        fv.caps.append(em.a, .{ .name = name, .ty = ty.?, .payload_ty = pty, .sname = sn }) catch @panic("OOM");
    }

    fn walk(fv: *FreeVars, idx: u32) void {
        const em = fv.em;
        switch (em.tree.node(idx)) {
            .identifier => |nm| fv.ref(nm),
            .binary_expr => |b| {
                fv.walk(b.left);
                fv.walk(b.right);
            },
            .unary_expr => |u| fv.walk(u.operand),
            .call_expr => |cl| {
                fv.walk(cl.callee);
                for (em.tree.extraSlice(cl.args)) |ai| fv.walk(ai);
            },
            .index_expr => |ix| {
                fv.walk(ix.object);
                fv.walk(ix.index);
            },
            .array_literal => |list| for (em.tree.extraSlice(list)) |e| fv.walk(e),
            .range_expr => |r| {
                if (r.start_node) |s| fv.walk(s);
                if (r.end_node) |e| fv.walk(e);
            },
            .struct_literal => |sl| {
                for (em.tree.extraSlice(sl.fields)) |fi| fv.walk(em.tree.node(fi).struct_init_field.value);
            },
            .field_access => |fa| fv.walk(fa.object),
            .some_expr, .ok_expr, .err_expr, .try_expr => |inner| fv.walk(inner),
            .none_expr, .nil_literal, .int_literal, .float_literal, .string_literal, .bool_literal, .break_stmt, .continue_stmt => {},
            .block => |blk| {
                fv.pushScope();
                for (em.tree.extraSlice(blk.stmts)) |s| fv.walk(s);
                if (blk.tail) |t| fv.walk(t);
                fv.popScope();
            },
            .expr_stmt => |inner| fv.walk(inner),
            .if_expr => |ie| {
                fv.walk(ie.cond);
                fv.walk(ie.then_block);
                if (ie.else_block) |eb| fv.walk(eb);
            },
            .while_expr => |we| {
                fv.walk(we.cond);
                fv.walk(we.body);
            },
            .for_expr => |fe| {
                fv.walk(fe.iter);
                fv.pushScope();
                fv.bind(fe.var_name);
                fv.walk(fe.body);
                fv.popScope();
            },
            .match_expr => |me| {
                fv.walk(me.target);
                for (em.tree.extraSlice(me.arms)) |ai| {
                    const arm = em.tree.node(ai).match_arm;
                    fv.pushScope();
                    fv.walkPattern(arm.pattern);
                    if (arm.guard) |g| fv.walk(g);
                    fv.walk(arm.body);
                    fv.popScope();
                }
            },
            .return_stmt => |v| if (v) |vi| fv.walk(vi),
            .assignment => |as| {
                // El target es una escritura, pero se resuelve como lectura:
                // asignar a un nombre capturado debe diagnosticarse, y para
                // eso el body emitter lo encuentra en el set de capturas.
                switch (em.tree.node(as.target)) {
                    .identifier => |nm| fv.ref(nm),
                    else => fv.walk(as.target),
                }
                fv.walk(as.value);
            },
            .compound_assignment => |ca| {
                switch (em.tree.node(ca.target)) {
                    .identifier => |nm| fv.ref(nm),
                    else => fv.walk(ca.target),
                }
                fv.walk(ca.value);
            },
            .fn_decl => |fd| fv.bind(fd.name),
            .lambda_expr => |lm| {
                fv.pushScope();
                for (em.tree.extraSlice(lm.params)) |pi| fv.bind(em.tree.node(pi).param.name);
                fv.walk(lm.body);
                fv.popScope();
            },
            .var_decl, .const_decl => |vd| {
                if (vd.value) |v| fv.walk(v);
                fv.bind(vd.name);
            },
            else => {},
        }
    }

    fn walkPattern(fv: *FreeVars, pat: u32) void {
        const em = fv.em;
        switch (em.tree.node(pat)) {
            .pattern_bind => |nm| fv.bind(nm),
            .pattern_variant_bind => |vb| {
                for (em.tree.extraSlice(vb.bindings)) |bi| fv.bind(em.tree.node(bi).pattern_bind);
            },
            .pattern_builtin_variant => |bv| if (bv.payload) |p| fv.walkPattern(p),
            .pattern_or => |list| for (em.tree.extraSlice(list)) |sp| fv.walkPattern(sp),
            else => {},
        }
    }
};

/// Números de tag/ptype del contrato emisor↔runtime (astra_runtime_llvm.c):
/// el tag sigue la numeración de TAG_IS del VM y el `none` es NULL.
const TAG_OK: u32 = 0;
const TAG_ERR: u32 = 1;
const TAG_SOME: u32 = 2;
/// Límite de globales de la VM (vm.zig VM_MAX_GLOBALS): una 257ª
/// declaración de nivel superior aborta en runtime — emitModuleMain emite el
/// mismo trap en el mismo orden de fuente.
const VM_MAX_GLOBALS: u32 = 256;
const PTY_BOOL: u32 = 1;
const PTY_I64: u32 = 2;
const PTY_F64: u32 = 3;
const PTY_STR: u32 = 4;
const PTY_BOXED: u32 = 5;
/// Elemento/contenido de array dentro de una caja o del header de otro array
/// (contrato con el runtime: 1=bool 2=i64 3=f64 4=str 5=boxed 6=array
/// 7=struct).
const PTY_ARRAY: u32 = 6;
const PTY_STRUCT: u32 = 7;
/// Valor de enum (payload dentro de cajas, slots de payload y elementos de
/// array) — contrato con el runtime (M2.c).
const PTY_ENUM: u32 = 8;

/// Offset de los elementos inline en un objeto array (`{ i64 len; i32
/// elem_pty; i32 pad; <elems> }`, M2.a).
const ARR_HDR: i64 = 16;

/// Espejo de VM_STACK_SIZE (vm.c) / ASTRA_FRAME_SIZE (codegen_runtime.h): el
/// operand stack de la VM es único (1024 slots compartidos entre frames) y
/// un literal con más elementos que el presupuesto lo desborda.
const VM_STACK_SIZE: usize = 1024;

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
    // Option/Result boxed (M1): construcción, print, igualdad y el fallo
    // dinámico de ordenación ("cannot compare some and some").
    r_wrap: c.LLVMValueRef,
    r_print_boxed: c.LLVMValueRef,
    r_boxed_eq: c.LLVMValueRef,
    r_boxed_order_fail: c.LLVMValueRef,
    // libc malloc: los objetos de closure (env + {code, env}) y las cajas
    // viven en heap con lifetime de proceso, como el backend C.
    r_malloc: c.LLVMValueRef,
    r_print_array: c.LLVMValueRef,
    r_index_fail: c.LLVMValueRef,
    r_index_nil_fail: c.LLVMValueRef,
    r_print_struct: c.LLVMValueRef,
    r_struct_eq: c.LLVMValueRef,
    r_print_enum: c.LLVMValueRef,
    r_enum_eq: c.LLVMValueRef,
    r_array_eq: c.LLVMValueRef,

    fns: std.StringHashMap(FnInfo),
    globals: std.StringHashMap(GlobalInfo),
    /// Layouts de structs registrados (nivel superior; pasada previa al
    /// emit). Las anotaciones y los accesos a campo se resuelven aquí.
    structs: std.StringHashMap(StructLayout),
    /// Layouts de enums de usuario (M2.c): variantes, payloads y descriptores.
    enums: std.StringHashMap(EnumLayout),
    /// Nombre de variante → enum + índice (constructores pelones `Circle(x)`).
    variant_map: std.StringHashMap(VariantRef),
    /// Contextos de loop activos (break/continue).
    loops: std.ArrayListUnmanaged(LoopCtx) = .empty,
    scopes: std.ArrayListUnmanaged(std.StringHashMap(Local)) = .empty,
    /// Pila de scopes de capturas: una entrada por lambda en cuyo cuerpo se
    /// esté compilando. Los nombres de un cuerpo se resuelven primero como
    /// locales (params/lets) y luego contra esta pila (§30.5).
    captures: std.ArrayListUnmanaged(CaptureScope) = .empty,
    lambda_seq: u32 = 0,

    // Función que se emite actualmente (para allocas y bloques).
    cur_fn: c.LLVMValueRef = undefined,
    cur_returns_value: bool = false,
    /// Scope temporal de `let` para la inferencia de firma de las fn sin `->`
    /// (ver `inferFnRet`). Solo lo consultan los `infer*`; nunca la emisión.
    infer_tmp: ?*const std.StringHashMapUnmanaged(InferBinding) = null,
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
            .structs = std.StringHashMap(StructLayout).init(a),
            .enums = std.StringHashMap(EnumLayout).init(a),
            .variant_map = std.StringHashMap(VariantRef).init(a),
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
            .r_wrap = undefined,
            .r_print_boxed = undefined,
            .r_boxed_eq = undefined,
            .r_boxed_order_fail = undefined,
            .r_malloc = undefined,
            .r_print_array = undefined,
            .r_index_fail = undefined,
            .r_index_nil_fail = undefined,
            .r_print_struct = undefined,
            .r_struct_eq = undefined,
            .r_print_enum = undefined,
            .r_enum_eq = undefined,
            .r_array_eq = undefined,
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
        // wrap(line, tag, ptype, payload) → caja; eq por contenido; el fallo
        // de ordenación lleva ambos operandos para nombrarlos dinámicamente.
        self.r_wrap = self.declRet(self.t_ptr, "astra_llvm_wrap", &.{ self.t_i32, self.t_i32, self.t_i32, self.t_i64 });
        self.r_print_boxed = self.declVoid("astra_llvm_print_boxed", &.{self.t_ptr});
        self.r_boxed_eq = self.declRet(self.t_i32, "astra_llvm_boxed_eq", &.{ self.t_ptr, self.t_ptr });
        self.r_boxed_order_fail = self.declVoid("astra_llvm_boxed_order_fail", &.{ self.t_i32, self.t_ptr, self.t_ptr });
        self.r_malloc = self.declRet(self.t_ptr, "malloc", &.{self.t_i64});
        self.r_print_array = self.declVoid("astra_llvm_print_array", &.{self.t_ptr});
        self.r_index_fail = self.declVoid("astra_llvm_index_fail", &.{ self.t_i32, self.t_i64, self.t_i64 });
        self.r_index_nil_fail = self.declVoid("astra_llvm_index_nil_fail", &.{self.t_i32});
        self.r_print_struct = self.declVoid("astra_llvm_print_struct", &.{self.t_ptr});
        self.r_struct_eq = self.declRet(self.t_i32, "astra_llvm_struct_eq", &.{ self.t_ptr, self.t_ptr });
        self.r_print_enum = self.declVoid("astra_llvm_print_enum", &.{self.t_ptr});
        self.r_enum_eq = self.declRet(self.t_i32, "astra_llvm_enum_eq", &.{ self.t_ptr, self.t_ptr });
        self.r_array_eq = self.declRet(self.t_i32, "astra_llvm_array_eq", &.{ self.t_ptr, self.t_ptr });
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
        // 0: registra los layouts de structs y enums (los annotations, los
        // accesos a campo y los constructores de variantes se resuelven
        // contra estos mapas, y los descriptores del runtime se emiten aquí
        // como constantes).
        self.registerDecls(items);
        if (self.error_count > 0) return;
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
        if (param_items.len + 1 > pbuf.len) return self.unsupported(idx, "too many parameters");
        // Convención uniforme de las funciones Astra: el parámetro 0 es el
        // env del closure (las funciones nombradas no capturan y lo ignoran;
        // las lambdas leen sus capturas de ahí). Uniformidad = un objeto
        // { code, env } basta para llamar a cualquiera de las dos.
        pbuf[0] = self.t_ptr;
        for (param_items, 0..) |pi, i| {
            const p = self.tree.node(pi).param;
            const at = self.annotTy(p.type_node) orelse
                return self.unsupported(pi, "parameter without a scalar type annotation (i32/i64/u32/u64/f64/bool/string/T?)");
            pbuf[i + 1] = self.llvmTy(at.ty);
        }
        var ret_ty: c.LLVMTypeRef = self.t_void;
        var ret_m0: ?Ty = null;
        var ret_payload: ?Ty = null;
        var ret_sname: ?[]const u8 = null;
        if (fd.ret) |ri| {
            const at = self.annotTy(ri) orelse
                return self.unsupported(ri, "non-scalar return type");
            ret_ty = self.llvmTy(at.ty);
            ret_m0 = at.ty;
            ret_payload = at.payload;
            ret_sname = at.sname;
        } else if (self.inferFnRet(fd)) |inf| {
            // El checker tipa void un `fn` sin `->`, pero el VM devuelve el
            // valor de `return`/tail: la firma LLVM tiene que reflejarlo para
            // que `print(g())` reproduzca la VM.
            ret_ty = self.llvmTy(inf.ty);
            ret_m0 = inf.ty;
            ret_payload = inf.payload;
            ret_sname = inf.sname;
        }
        const fty = c.LLVMFunctionType(ret_ty, &pbuf, @intCast(param_items.len + 1), 0);
        const mangled = std.fmt.allocPrintSentinel(self.a, "astra_fn_{s}", .{fd.name}, 0) catch @panic("OOM");
        const fnv = c.LLVMAddFunction(self.mod, mangled, fty);
        self.fns.put(fd.name, .{ .val = fnv, .fty = fty, .returns_value = ret_m0 != null, .ret_ty = ret_m0, .ret_payload = ret_payload, .ret_sname = ret_sname }) catch @panic("OOM");
    }

    fn declareGlobal(self: *Emitter, idx: u32) void {
        const vd = self.varDeclOf(idx);
        const ann = self.annotTy(vd.type_node);
        const ty: Ty = if (ann) |at| at.ty else if (vd.value) |vi|
            self.inferStaticTy(vi) orelse return self.unsupported(idx, "cannot infer the scalar type of a top-level binding")
        else
            return self.unsupported(idx, "top-level binding without an initializer");
        const payload: ?Ty = if (ann) |at| at.payload else if (vd.value) |vi| self.inferBoxPayload(vi) else null;
        const sname: ?[]const u8 = if (ann) |at| at.sname else if (vd.value) |vi| self.inferStaticSName(vi) else null;
        const gname = std.fmt.allocPrintSentinel(self.a, "astra_g_{s}", .{vd.name}, 0) catch @panic("OOM");
        const gv = c.LLVMAddGlobal(self.mod, self.llvmTy(ty), gname);
        c.LLVMSetInitializer(gv, self.zeroInit(ty));
        self.globals.put(vd.name, .{ .val = gv, .ty = ty, .payload_ty = payload, .sname = sname }) catch @panic("OOM");
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
            const at = self.annotTy(p.type_node) orelse return;
            const alloca = self.buildAlloca(self.llvmTy(at.ty));
            _ = c.LLVMBuildStore(self.builder, c.LLVMGetParam(info.val, @intCast(i + 1)), alloca);
            self.addLocal(p.name, alloca, at.ty, at.payload, at.sname);
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

    // ── Closures (M1.d, §30.5) ─────────────────────────────────────────────

    /// Una lambda es un objeto heap `{ ptr code; ptr env }` cuyo `code` es una
    /// función LLVM con la convención uniforme `(env, params...) -> ret`. El
    /// env es un array de slots i64 (toBits del valor capturado) malloc'd en
    /// el SITIO DE CREACIÓN — snapshot por valor que sobrevive al frame, que
    /// es lo que separa a los closures de un préstamo de slots (audit §7.11:
    /// `saved = |x| { x + base }` debe seguir devolviendo 8 tras salir
    /// `store`, y `f(1)` tras reasignar `n` debe seguir devolviendo 6).
    fn emitLambda(self: *Emitter, idx: u32) ?Val {
        const l = self.tree.node(idx).lambda_expr;
        const params = self.tree.extraSlice(l.params);

        // 1: análisis de variables libres contra el scope ACTUAL (locales y
        //    capturas del frame que contiene la creación).
        var fv = FreeVars{ .em = self };
        defer fv.deinit();
        for (params) |pi| fv.bind(self.tree.node(pi).param.name);
        fv.walk(l.body);
        if (fv.overflow) {
            self.unsupported(idx, "too many captured variables");
            return null;
        }

        // 2: firma — env + params anotados, retorno anotado o inferido.
        var pbuf: [17]c.LLVMTypeRef = undefined;
        if (params.len + 1 > pbuf.len) {
            self.unsupported(idx, "too many parameters");
            return null;
        }
        pbuf[0] = self.t_ptr;
        for (params, 0..) |pi, i| {
            const p = self.tree.node(pi).param;
            const at = self.annotTy(p.type_node) orelse {
                self.unsupported(pi, "lambda parameter without a scalar type annotation");
                return null;
            };
            pbuf[i + 1] = self.llvmTy(at.ty);
        }
        const ret_ty = self.lambdaRetTy(l) orelse {
            self.unsupported(idx, "lambda requires a known return type");
            return null;
        };
        const fty = c.LLVMFunctionType(self.llvmTy(ret_ty), &pbuf, @intCast(params.len + 1), 0);

        // 3: función LLVM única por lambda.
        const seq = self.lambda_seq;
        self.lambda_seq += 1;
        const lname = std.fmt.allocPrintSentinel(self.a, "astra_lambda_{d}", .{seq}, 0) catch @panic("OOM");
        const fnv = c.LLVMAddFunction(self.mod, lname, fty);

        // 4: env y objeto en el sitio de creación (builder todavía aquí).
        var env_ptr = c.LLVMConstPointerNull(self.t_ptr);
        const ncaps: u32 = @intCast(fv.caps.items.len);
        if (ncaps > 0) {
            var margs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 8 * ncaps, 0)};
            env_ptr = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_malloc), self.r_malloc, &margs, 1, "");
            for (fv.caps.items, 0..) |cp, i| {
                const cv = self.captureValue(cp, idx) orelse return null;
                var sidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 8 * i, 0)};
                const slot = c.LLVMBuildGEP2(self.builder, self.t_i8, env_ptr, &sidxs, 1, "");
                _ = c.LLVMBuildStore(self.builder, self.toBits(cv.ref, cv.ty), slot);
            }
        }
        const obj = self.buildFnObject(fnv, env_ptr);

        // 5: cuerpo de la lambda, compilado con su scope de capturas. Los
        //    scopes y las capturas del frame que contiene la creación se
        //    guardan aparte: el cuerpo sólo ve sus propios params/lets y su
        //    env — resolver un nombre libre contra los allocas del frame
        //    ajeno produciría loads de otra función (IR inválido), y el
        //    análisis de free vars ya puso todo lo libre en fv.caps.
        const saved_block = c.LLVMGetInsertBlock(self.builder);
        const prev_fn = self.cur_fn;
        const prev_ret = self.cur_returns_value;
        const saved_scopes = self.scopes;
        const saved_captures = self.captures;
        self.scopes = .empty;
        self.captures = .empty;
        self.cur_fn = fnv;
        self.cur_returns_value = true;
        const entry = c.LLVMAppendBasicBlockInContext(self.ctx, fnv, "entry");
        c.LLVMPositionBuilderAtEnd(self.builder, entry);
        self.pushScope();
        self.pushCaptures(fv.caps.items);
        for (params, 0..) |pi, i| {
            const p = self.tree.node(pi).param;
            const at = self.annotTy(p.type_node) orelse return null;
            const alloca = self.buildAlloca(self.llvmTy(at.ty));
            _ = c.LLVMBuildStore(self.builder, c.LLVMGetParam(fnv, @intCast(i + 1)), alloca);
            self.addLocal(p.name, alloca, at.ty, at.payload, at.sname);
        }
        const body_val = self.emitBlockValue(l.body);
        if (!self.isTerminated()) {
            if (body_val) |v| {
                _ = c.LLVMBuildRet(self.builder, v.ref);
            } else {
                _ = c.LLVMBuildUnreachable(self.builder);
            }
        }
        self.popCaptures();
        self.popScope();
        self.cur_fn = prev_fn;
        self.cur_returns_value = prev_ret;
        self.scopes = saved_scopes;
        self.captures = saved_captures;
        c.LLVMPositionBuilderAtEnd(self.builder, saved_block);

        return .{ .ref = obj, .ty = .fn_, .payload_ty = ret_ty };
    }

    /// Tipo de retorno de una lambda: la anotación `-> T`, o inferido del
    /// tail del body (el typechecker infiere el retorno cuando no hay
    /// anotación y el body produce valor).
    fn lambdaRetTy(self: *Emitter, l: ast.Lambda) ?Ty {
        if (l.ret) |r| return (self.annotTy(r) orelse return null).ty;
        return switch (self.tree.node(l.body)) {
            .block => |blk| if (blk.tail) |t| self.inferStaticTy(t) else null,
            else => self.inferStaticTy(l.body),
        };
    }

    /// Objeto `{ ptr code; ptr env }` en heap (16 bytes, lifetime de proceso).
    fn buildFnObject(self: *Emitter, code: c.LLVMValueRef, env: c.LLVMValueRef) c.LLVMValueRef {
        var margs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 16, 0)};
        const obj = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_malloc), self.r_malloc, &margs, 1, "");
        var cidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 0, 0)};
        const codep = c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &cidxs, 1, "");
        _ = c.LLVMBuildStore(self.builder, code, codep);
        var eidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 8, 0)};
        const envp = c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &eidxs, 1, "");
        _ = c.LLVMBuildStore(self.builder, env, envp);
        return obj;
    }

    /// Carga el slot i del env actual (array de i64 bits).
    fn loadEnvSlot(self: *Emitter, env: c.LLVMValueRef, idx: u32) c.LLVMValueRef {
        var sidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 8 * idx, 0)};
        const pp = c.LLVMBuildGEP2(self.builder, self.t_i8, env, &sidxs, 1, "");
        return c.LLVMBuildLoad2(self.builder, self.t_i64, pp, "");
    }

    /// Valor ACTUAL de una captura en el sitio de creación: una local del
    /// frame (alloca) o un slot del env de la lambda que lo contiene.
    fn captureValue(self: *Emitter, cap: CapSlot, idx: u32) ?Val {
        if (self.lookupLocal(cap.name)) |l|
            return .{ .ref = c.LLVMBuildLoad2(self.builder, self.llvmTy(l.ty), l.alloca, ""), .ty = l.ty, .payload_ty = l.payload_ty, .sname = l.sname };
        if (self.lookupCapture(cap.name)) |cp| {
            const env = c.LLVMGetParam(self.cur_fn, 0);
            const bits = self.loadEnvSlot(env, cp.index);
            return .{ .ref = self.fromBits(bits, cp.ty), .ty = cp.ty, .payload_ty = cp.payload_ty, .sname = cp.sname };
        }
        self.unsupported(idx, "capture of a variable that no longer resolves");
        return null;
    }

    fn pushCaptures(self: *Emitter, slots: []const CapSlot) void {
        var scope: CaptureScope = .empty;
        for (slots, 0..) |cp, i| {
            var with_idx = cp;
            with_idx.index = @intCast(i);
            scope.append(self.a, with_idx) catch @panic("OOM");
        }
        self.captures.append(self.a, scope) catch @panic("OOM");
    }

    fn popCaptures(self: *Emitter) void {
        var scope = self.captures.pop().?;
        scope.deinit(self.a);
    }

    /// Índice de captura de un nombre en la pila de envs, o null.
    fn lookupCapture(self: *Emitter, name: []const u8) ?CapSlot {
        var s = self.captures.items.len;
        while (s > 0) {
            s -= 1;
            for (self.captures.items[s].items) |cp| {
                if (std.mem.eql(u8, cp.name, name)) return cp;
            }
        }
        return null;
    }

    // ── Arrays (M2.a) ──────────────────────────────────────────────────────

    /// Literal `[a, b, c]` → objeto heap `{ i64 len; i32 elem_pty; i32 pad;
    /// <elems> }` con elementos en su tipo LLVM estático. Homogéneo por el
    /// typechecker ("array element 2 has type string, expected …"), así que
    /// el tipo del primer elemento es el del array entero (payload_ty).
    /// Comparte identidad como el handle del VM: `let mut b = a` copia el
    /// puntero y una escritura a través de `b` se ve en `a`
    /// (arrays/alias_write — la semántica ARC/ORC de Hallazgo G).
    fn emitArrayLit(self: *Emitter, idx: u32) ?Val {
        const list = self.tree.node(idx).array_literal;
        const elems = self.tree.extraSlice(list);
        if (elems.len == 0) {
            self.unsupported(idx, "empty array literal (element type unknown)");
            return null;
        }
        // Presupuesto del operand stack (VM_STACK_SIZE / ASTRA_FRAME_SIZE,
        // 1024 compartidos): vm_push falla con `sp >= 1024` ANTES de pushar,
        // o sea en el elemento 1025 → "stack overflow" en la línea 0
        // (expressions/stack_overflow_limit, que pinza el ASTRA_PUSH del
        // backend C). El emisor no modela el sp global de la VM, así que este
        // guard es exacto en profundidad de expresión 0 — la forma que el
        // caso pinza — y no dispara en profundidades exóticas (presupuesto
        // conservador: la VM fallaría antes con menos elementos). La
        // emisión posterior sigue en el bloque inalcanzable y es IR válido.
        if (elems.len >= VM_STACK_SIZE + 1) self.emitFailMsg(0, "stack overflow");
        const ev = self.emitExpr(elems[0]) orelse return null;
        const ety = ev.ty;
        const pty = boxPTy(ety) orelse {
            self.unsupported(idx, "array of function values");
            return null;
        };
        const slot = elemSlotSize(ety);
        var margs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, @intCast(ARR_HDR + slot * @as(i64, @intCast(elems.len))), 0)};
        const obj = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_malloc), self.r_malloc, &margs, 1, "");
        // header: len @0, elem_pty @8 (los elementos en @16, 8-alineados).
        var lidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 0, 0)};
        const lp = c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &lidxs, 1, "");
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.t_i64, elems.len, 0), lp);
        var hidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 8, 0)};
        const hp = c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &hidxs, 1, "");
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.t_i32, pty, 0), hp);
        // elementos, en orden de evaluación del literal
        for (elems, 0..) |ei, i| {
            const v = if (i == 0) ev else (self.emitExpr(ei) orelse return null);
            if (v.ty != ety) {
                self.unsupported(idx, "heterogeneous array literal");
                return null;
            }
            const ep = self.elemSlotAddr(obj, c.LLVMConstInt(self.t_i64, i, 0), ety);
            _ = c.LLVMBuildStore(self.builder, v.ref, ep);
        }
        return .{ .ref = obj, .ty = .arr_, .payload_ty = ety };
    }

    /// Dirección del elemento i: `arr + ARR_HDR + i * slot_size`.
    fn elemSlotAddr(self: *Emitter, arr: c.LLVMValueRef, i: c.LLVMValueRef, ety: Ty) c.LLVMValueRef {
        const slot = elemSlotSize(ety);
        var off = i;
        if (slot != 1) off = c.LLVMBuildMul(self.builder, i, c.LLVMConstInt(self.t_i64, @intCast(slot), 0), "");
        off = c.LLVMBuildAdd(self.builder, off, c.LLVMConstInt(self.t_i64, @intCast(ARR_HDR), 0), "");
        var idxs = [_]c.LLVMValueRef{off};
        return c.LLVMBuildGEP2(self.builder, self.t_i8, arr, &idxs, 1, "");
    }

    /// `0 <= i && i < len`: el arm de fallo llama a `astra_llvm_index_fail`
    /// (noreturn — mensaje del VM OPCODE_INDEX: `index i out of bounds (len
    /// n)`) y el arm ok queda abierto para el load/store siguiente.
    fn emitBoundsCheck(self: *Emitter, i: c.LLVMValueRef, arr: c.LLVMValueRef, line: u32) void {
        // Receptor nil: el VM rechaza `a[i]` con `cannot index nil` antes de
        // mirar bounds (audit §5.3 en el backend C); un GEP sobre NULL
        // segfaultea, así que el guard va primero. `let a: [i32]` sin
        // inicializador es el nil del modelo (NULL).
        const is_nil = c.LLVMBuildIsNull(self.builder, arr, "");
        const nil_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "idx_nil");
        const arr_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "idx_arr");
        _ = c.LLVMBuildCondBr(self.builder, is_nil, nil_bb, arr_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, nil_bb);
        var nargs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i32, line, 0)};
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_index_nil_fail), self.r_index_nil_fail, &nargs, 1, "");
        _ = c.LLVMBuildUnreachable(self.builder);
        c.LLVMPositionBuilderAtEnd(self.builder, arr_bb);
        var lidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 0, 0)};
        const lp = c.LLVMBuildGEP2(self.builder, self.t_i8, arr, &lidxs, 1, "");
        const len = c.LLVMBuildLoad2(self.builder, self.t_i64, lp, "");
        const ge = c.LLVMBuildICmp(self.builder, c.LLVMIntSGE, i, c.LLVMConstInt(self.t_i64, 0, 0), "");
        const lt = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, i, len, "");
        const inb = c.LLVMBuildAnd(self.builder, ge, lt, "");
        const ok_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "idx_ok");
        const fail_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "idx_fail");
        _ = c.LLVMBuildCondBr(self.builder, inb, ok_bb, fail_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, fail_bb);
        var fargs = [_]c.LLVMValueRef{ c.LLVMConstInt(self.t_i32, line, 0), i, len };
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_index_fail), self.r_index_fail, &fargs, 3, "");
        _ = c.LLVMBuildUnreachable(self.builder);
        c.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
    }

    /// `xs[i]` — bounds check + carga GEP con el tipo del elemento.
    fn emitIndex(self: *Emitter, idx: u32) ?Val {
        const ix = self.tree.node(idx).index_expr;
        const ov = self.emitExpr(ix.object) orelse return null;
        if (ov.ty != .arr_) {
            self.unsupported(idx, "indexing a non-array value");
            return null;
        }
        const ety = ov.payload_ty orelse {
            self.unsupported(idx, "array without an element type");
            return null;
        };
        const iv = self.emitExpr(ix.index) orelse return null;
        if (iv.ty != .i64_) {
            self.unsupported(idx, "array index must be an integer");
            return null;
        }
        self.emitBoundsCheck(iv.ref, ov.ref, self.tree.loc(idx).line);
        const ep = self.elemSlotAddr(ov.ref, iv.ref, ety);
        return .{ .ref = c.LLVMBuildLoad2(self.builder, self.llvmTy(ety), ep, ""), .ty = ety, .payload_ty = null };
    }

    /// `xs[i] = v` — mismo bounds check que la lectura, luego store; la
    /// asignación produce su valor (es expresión: `let y = { xs[1] = 42 }`).
    fn emitElemAssign(self: *Emitter, idx: u32) ?Val {
        const as = self.tree.node(idx).assignment;
        const val = self.emitExpr(as.value) orelse return null;
        const ix = self.tree.node(as.target).index_expr;
        const ov = self.emitExpr(ix.object) orelse return null;
        if (ov.ty != .arr_) {
            self.unsupported(idx, "assignment into a non-array value");
            return null;
        }
        const ety = ov.payload_ty orelse {
            self.unsupported(idx, "array without an element type");
            return null;
        };
        if (val.ty != ety) {
            self.unsupported(idx, "array element type mismatch");
            return null;
        }
        const iv = self.emitExpr(ix.index) orelse return null;
        if (iv.ty != .i64_) {
            self.unsupported(idx, "array index must be an integer");
            return null;
        }
        self.emitBoundsCheck(iv.ref, ov.ref, self.tree.loc(idx).line);
        const ep = self.elemSlotAddr(ov.ref, iv.ref, ety);
        _ = c.LLVMBuildStore(self.builder, val.ref, ep);
        return val;
    }

    // ── Structs (M2.b) ─────────────────────────────────────────────────────

    /// `P { x: 1, y: 2 }` → objeto heap `{ ptr def; x@8; y@16; … }`. Los
    /// campos se guardan en ORDEN DE DECLARACIÓN (el orden del literal es
    /// irrelevante — busca por nombre) y todos en slots de 8 bytes, que es
    /// lo que el descriptor del runtime espera al recorrerlos. Manejo como
    /// el handle del VM (aliasing, Hallazgo G): `let mut q = p` copia el
    /// puntero.
    fn emitStructLit(self: *Emitter, idx: u32) ?Val {
        const sl = self.tree.node(idx).struct_literal;
        const layout = self.structs.get(sl.name) orelse {
            self.unsupported(idx, "struct literal of an undeclared struct");
            return null;
        };
        if (layout.def == null) { // placeholder sin registrar (inconsistencia interna)
            self.unsupported(idx, "struct literal of an unregistered struct");
            return null;
        }
        const init_items = self.tree.extraSlice(sl.fields);
        var margs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, @intCast(layout.size), 0)};
        const obj = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_malloc), self.r_malloc, &margs, 1, "");
        // offset 0: puntero al descriptor (lo que print/eq leen del objeto).
        var didxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 0, 0)};
        const dp = c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &didxs, 1, "");
        _ = c.LLVMBuildStore(self.builder, layout.def, dp);
        // Campos inicializados, en orden de evaluación del literal.
        for (init_items) |fi| {
            const f = self.tree.node(fi).struct_init_field;
            var slot: ?usize = null;
            for (layout.fields, 0..) |lf, i| {
                if (std.mem.eql(u8, lf.name, f.name)) slot = i;
            }
            const si = slot orelse {
                self.unsupported(idx, "struct literal field not in the declaration");
                return null;
            };
            const fv = self.emitExpr(f.value) orelse return null;
            if (fv.ty != layout.fields[si].ty) {
                self.unsupported(idx, "struct literal field type mismatch");
                return null;
            }
            var eidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 8 + 8 * si, 0)};
            const fp = c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &eidxs, 1, "");
            _ = c.LLVMBuildStore(self.builder, fv.ref, fp);
        }
        // Campos sin inicializar quedan en cero (el typechecker ya exige la
        // lista completa; esto sólo evita basura si alguien relaja esa regla).
        for (layout.fields, 0..) |lf, i| {
            var seen = false;
            for (init_items) |fi| {
                if (std.mem.eql(u8, self.tree.node(fi).struct_init_field.name, lf.name)) seen = true;
            }
            if (seen) continue;
            var zidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 8 + 8 * i, 0)};
            const zp = c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &zidxs, 1, "");
            _ = c.LLVMBuildStore(self.builder, self.zeroInit(lf.ty), zp);
        }
        return .{ .ref = obj, .ty = .struct_, .sname = sl.name };
    }

    /// Dirección de un slot a byte offset fijo (campos de struct: `obj + 8 +
    /// 8 * i`; payload de enum: `obj + 16 + 8 * i`).
    fn fieldSlotAddr(self: *Emitter, obj: c.LLVMValueRef, byte_off: usize) c.LLVMValueRef {
        var idxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, byte_off, 0)};
        return c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &idxs, 1, "");
    }

    /// `Enum.Variant` → (enum, índice de variante) si el objeto es un
    /// identificador que nombra un enum declarado.
    fn resolveVariantPath(self: *Emitter, path: u32) ?VariantRef {
        const fa = self.tree.node(path).field_access;
        switch (self.tree.node(fa.object)) {
            .identifier => |enm| {
                const el = self.enums.get(enm) orelse return null;
                for (el.variants, 0..) |v, i| {
                    if (std.mem.eql(u8, v.name, fa.field)) return .{ .enum_name = enm, .index = i };
                }
                return null;
            },
            else => return null,
        }
    }

    /// El valor `Enum.Variant` (constante kind-0) — el VAL_ENUM del VM.
    fn variantConstVal(self: *Emitter, path: u32) ?Val {
        const vr = self.resolveVariantPath(path) orelse {
            self.unsupported(path, "pattern must be a literal, `_` or Enum.Variant");
            return null;
        };
        const el = self.enums.get(vr.enum_name).?;
        return .{ .ref = el.variants[vr.index].unit_const, .ty = .enum_ };
    }

    /// `p.x` — lectura de campo contra el layout del struct (cadena anidada
    /// `p.n.x` funciona: el objeto del campo es otro struct handle).
    fn emitFieldRead(self: *Emitter, idx: u32) ?Val {
        const fa = self.tree.node(idx).field_access;
        // `Enum.Variant` como valor → constante kind-0 (el VAL_ENUM del VM:
        // nombres sin payload, sirve tanto para accesos unit como para el
        // acceso pelón de una variante con payload).
        if (self.resolveVariantPath(idx)) |_| return self.variantConstVal(idx);
        const ov = self.emitExpr(fa.object) orelse return null;
        if (ov.ty != .struct_ or ov.sname == null) {
            self.unsupported(idx, "field access on a non-struct value");
            return null;
        }
        const layout = self.structs.get(ov.sname.?) orelse {
            self.unsupported(idx, "field access on an unknown struct");
            return null;
        };
        var slot: ?usize = null;
        for (layout.fields, 0..) |lf, i| {
            if (std.mem.eql(u8, lf.name, fa.field)) slot = i;
        }
        const si = slot orelse {
            self.unsupported(idx, "unknown struct field");
            return null;
        };
        const fty = layout.fields[si].ty;
        const fp = self.fieldSlotAddr(ov.ref, 8 + 8 * si);
        return .{
            .ref = c.LLVMBuildLoad2(self.builder, self.llvmTy(fty), fp, ""),
            .ty = fty,
            .payload_ty = layout.fields[si].payload,
            .sname = layout.fields[si].sname, // struct field: cadena `p.q.x`
        };
    }

    /// `p.x = v` — escritura de campo; el objeto comparte identidad, así que
    /// la escritura se ve a través de todos los bindings (aliasing).
    fn emitFieldAssign(self: *Emitter, idx: u32) ?Val {
        const as = self.tree.node(idx).assignment;
        const val = self.emitExpr(as.value) orelse return null;
        const fa = self.tree.node(as.target).field_access;
        const ov = self.emitExpr(fa.object) orelse return null;
        if (ov.ty != .struct_ or ov.sname == null) {
            self.unsupported(idx, "field assignment on a non-struct value");
            return null;
        }
        const layout = self.structs.get(ov.sname.?) orelse {
            self.unsupported(idx, "field assignment on an unknown struct");
            return null;
        };
        var slot: ?usize = null;
        for (layout.fields, 0..) |lf, i| {
            if (std.mem.eql(u8, lf.name, fa.field)) slot = i;
        }
        const si = slot orelse {
            self.unsupported(idx, "unknown struct field");
            return null;
        };
        if (val.ty != layout.fields[si].ty) {
            self.unsupported(idx, "struct field type mismatch");
            return null;
        }
        const fp = self.fieldSlotAddr(ov.ref, 8 + 8 * si);
        _ = c.LLVMBuildStore(self.builder, val.ref, fp);
        return val;
    }

    /// `Circle(2.5)` — construcción de variante con payload (constructor
    /// pelón, como el seed): objeto data (kind 1)
    /// `{ def; variant; kind=1; <payload@16> }`. Una variante sin payload
    /// construida con `()` devuelve la constante kind-0 (el VM sólo tiene
    /// VAL_ENUM para las unitarias).
    fn emitEnumConstruct(self: *Emitter, idx: u32, vr: VariantRef) ?Val {
        const el = self.enums.get(vr.enum_name) orelse return null; // registro falló
        const vl = el.variants[vr.index];
        const args = self.tree.extraSlice(self.tree.node(idx).call_expr.args);
        if (args.len != vl.fields.len) {
            self.unsupported(idx, "wrong number of payload arguments");
            return null;
        }
        if (args.len == 0) return .{ .ref = vl.unit_const, .ty = .enum_ };
        const size: i64 = 16 + 8 * @as(i64, @intCast(args.len));
        var margs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, @intCast(size), 0)};
        const obj = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_malloc), self.r_malloc, &margs, 1, "");
        var didxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 0, 0)};
        _ = c.LLVMBuildStore(self.builder, el.def, c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &didxs, 1, ""));
        var vidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 8, 0)};
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.t_i32, @intCast(vr.index), 0), c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &vidxs, 1, ""));
        var kidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 12, 0)};
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.t_i32, 1, 0), c.LLVMBuildGEP2(self.builder, self.t_i8, obj, &kidxs, 1, ""));
        for (args, 0..) |ai, i| {
            const av = self.emitExpr(ai) orelse return null;
            if (av.ty != vl.fields[i].ty) {
                self.unsupported(idx, "enum payload type mismatch");
                return null;
            }
            const sp = self.fieldSlotAddr(obj, 16 + 8 * i);
            _ = c.LLVMBuildStore(self.builder, av.ref, sp);
        }
        return .{ .ref = obj, .ty = .enum_ };
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
        // Espejo del límite de globales del VM (vm.zig: VM_MAX_GLOBALS = 256):
        // las declaraciones fn/var/const de nivel superior consumen slot en
        // orden de fuente vía SET_GLOBAL, y definir la 257ª aborta con esa
        // línea y "too many global variables". El backend cuenta igual y emite
        // el mismo trap en runtime — los ficheros de límite casan byte a byte
        // y un programa que la VM rechaza no corre aquí en silencio.
        var vm_globals: u32 = 0;
        for (items) |it| {
            switch (self.tree.node(it)) {
                .fn_decl, .var_decl, .const_decl => {
                    if (vm_globals >= VM_MAX_GLOBALS) {
                        const linev = c.LLVMConstInt(self.t_i32, self.tree.loc(it).line, 0);
                        const msgp = c.LLVMBuildGlobalStringPtr(self.builder, "too many global variables", "");
                        var fargs = [_]c.LLVMValueRef{ linev, msgp };
                        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_fail), self.r_fail, &fargs, 2, "");
                        _ = c.LLVMBuildUnreachable(self.builder);
                        return; // el resto del módulo es inalcanzable, como en el VM
                    }
                    vm_globals += 1;
                },
                else => {},
            }
            switch (self.tree.node(it)) {
                .fn_decl => {},
                .var_decl, .const_decl => {
                    self.ensureOpenBlock();
                    self.emitGlobalDecl(it);
                },
                .struct_decl, .enum_decl => {}, // layout ya registrado en la pasada 0 (M2.b/M2.c)
                .trait_decl, .impl_decl, .use_decl, .import_decl, .from_decl => {
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
            var eargs = [_]c.LLVMValueRef{c.LLVMConstPointerNull(self.t_ptr)};
            _ = c.LLVMBuildCall2(self.builder, mi.fty, mi.val, &eargs, 1, "");
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
            .for_expr => self.emitFor(idx),
            .break_stmt => self.emitBreak(idx),
            .continue_stmt => self.emitContinue(idx),
            .return_stmt => self.emitReturn(idx),
            .block => _ = self.emitBlockValue(idx),
            .match_expr => _ = self.emitMatch(idx),
            .struct_decl, .enum_decl => {}, // sin efecto en runtime; sólo se registran layouts de nivel superior
            else => _ = self.emitExpr(idx),
        }
    }

    fn emitLocalDecl(self: *Emitter, idx: u32) void {
        const vd = self.varDeclOf(idx);
        if (vd.value == null) {
            // `let a: [i32]` sin inicializador: la VM guarda nil y falla en el
            // primer uso (`cannot index nil`, `cannot access field on nil`…).
            // Los tipos con representación puntero lo modelan como NULL; un
            // escalar no tiene nil en el modelo LLVM (i64 0 mentiría sobre el
            // tipo), así que se rechaza limpio y el caso queda skip.
            const ann = self.annotTy(vd.type_node) orelse
                return self.unsupported(idx, "let without an initializer needs a type annotation");
            switch (ann.ty) {
                .i64_, .bool_, .f64_ => return self.unsupported(idx, "let without an initializer for a scalar type"),
                else => {},
            }
            const alloca = self.buildAlloca(self.llvmTy(ann.ty));
            _ = c.LLVMBuildStore(self.builder, c.LLVMConstPointerNull(self.t_ptr), alloca);
            self.addLocal(vd.name, alloca, ann.ty, ann.payload, ann.sname);
            return;
        }
        const vi = vd.value.?;
        const val = self.emitExpr(vi) orelse {
            if (self.error_count == 0) self.unsupported(idx, "initializer produces no value");
            return;
        };
        // La anotación `T?` fija el tipo y su payload; sin anotación, el del
        // valor inferido (un `some(x)` lleva el tipo de x).
        const ann = self.annotTy(vd.type_node);
        const ty = if (ann) |at| at.ty else val.ty;
        const payload = if (ann) |at| (at.payload orelse val.payload_ty) else val.payload_ty;
        const sname = if (ann) |at| (at.sname orelse val.sname) else val.sname;
        const alloca = self.buildAlloca(self.llvmTy(ty));
        _ = c.LLVMBuildStore(self.builder, val.ref, alloca);
        self.addLocal(vd.name, alloca, ty, payload, sname);
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
        // `continue` re-evalúa la condición (loop_start del seed es el
        // continue_target de NODE_WHILE); `break` sale directo al join.
        self.loops.append(self.a, .{ .break_bb = exit_bb, .continue_bb = cond_bb }) catch @panic("OOM");
        _ = self.emitBlockValue(we.body);
        _ = self.loops.pop();
        if (!self.isTerminated()) _ = c.LLVMBuildBr(self.builder, cond_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, exit_bb);
    }

    /// `for x in 0..n` / `for x in 1..=n` / `for x in arr` — replica el
    /// lowering del seed (NODE_FOR): almacen oculto de índice + límite/arr
    /// (los hidden_local del seed), la condición al frente, `x = i` al entrar
    /// al cuerpo y el incremento como objetivo de `continue`. El iterador se
    /// evalúa una sola vez y el alcance del loop (índice, límite y `x`) es
    /// propio.
    fn emitFor(self: *Emitter, idx: u32) void {
        const fe = self.tree.node(idx).for_expr;
        const is_range = std.meta.activeTag(self.tree.node(fe.iter)) == .range_expr;
        var inclusive = false;

        const cond_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "for_cond");
        const body_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "for_body");
        const cont_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "for_next");
        const exit_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "for_exit");

        self.pushScope();
        defer self.popScope();
        const i_alloca = self.buildAlloca(self.t_i64);
        var bound_alloca: c.LLVMValueRef = undefined; // for_end (i64) o for_arr (ptr)
        var elem_ty: Ty = .i64_; // tipo de la variable del loop

        if (is_range) {
            const rg = self.tree.node(fe.iter).range_expr;
            inclusive = rg.inclusive;
            const sv = if (rg.start_node) |sn| (self.emitExpr(sn) orelse return) else Val{ .ref = c.LLVMConstInt(self.t_i64, 0, 0), .ty = .i64_ };
            const en = rg.end_node orelse return self.unsupported(idx, "open-ended range is not supported in Astra-0");
            const ev = self.emitExpr(en) orelse return;
            if (sv.ty != .i64_ or ev.ty != .i64_) {
                self.unsupported(idx, "range bounds must be integers");
                return;
            }
            bound_alloca = self.buildAlloca(self.t_i64);
            _ = c.LLVMBuildStore(self.builder, sv.ref, i_alloca);
            _ = c.LLVMBuildStore(self.builder, ev.ref, bound_alloca);
        } else {
            const av = self.emitExpr(fe.iter) orelse return;
            if (av.ty != .arr_) {
                self.unsupported(idx, "for..in expects an array or a range");
                return;
            }
            // `Val.payload_ty` del array es su tipo de elemento (M2.a): la
            // variable del loop se tipa con él (`for s in strs`, enums, …).
            const ety = av.payload_ty orelse return self.unsupported(idx, "array without an element type");
            elem_ty = ety;
            bound_alloca = self.buildAlloca(self.t_ptr);
            _ = c.LLVMBuildStore(self.builder, av.ref, bound_alloca);
            _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.t_i64, 0, 0), i_alloca);
        }
        _ = c.LLVMBuildBr(self.builder, cond_bb);

        // Condición: `i < end` (`<=` en rangos inclusivos) o `i < len(arr)`
        // — el len vive en el offset 0 del objeto (M2.a).
        c.LLVMPositionBuilderAtEnd(self.builder, cond_bb);
        const iv = c.LLVMBuildLoad2(self.builder, self.t_i64, i_alloca, "");
        const cmp = if (is_range) blk: {
            const bv = c.LLVMBuildLoad2(self.builder, self.t_i64, bound_alloca, "");
            break :blk c.LLVMBuildICmp(self.builder, if (inclusive) c.LLVMIntSLE else c.LLVMIntSLT, iv, bv, "");
        } else blk: {
            const ap = c.LLVMBuildLoad2(self.builder, self.t_ptr, bound_alloca, "");
            var lidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 0, 0)};
            const lp = c.LLVMBuildGEP2(self.builder, self.t_i8, ap, &lidxs, 1, "");
            const len = c.LLVMBuildLoad2(self.builder, self.t_i64, lp, "");
            break :blk c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, iv, len, "");
        };
        _ = c.LLVMBuildCondBr(self.builder, cmp, body_bb, exit_bb);

        // Cuerpo: la variable del loop toma el elemento actual (índice en
        // rangos, `arr[i]` sin bounds check en arrays — la condición ya
        // garantiza el rango).
        c.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const cur = if (is_range) iv else blk: {
            const ap = c.LLVMBuildLoad2(self.builder, self.t_ptr, bound_alloca, "");
            const ep = self.elemSlotAddr(ap, iv, elem_ty);
            break :blk c.LLVMBuildLoad2(self.builder, self.llvmTy(elem_ty), ep, "");
        };
        const var_alloca = self.buildAlloca(self.llvmTy(elem_ty));
        _ = c.LLVMBuildStore(self.builder, cur, var_alloca);
        self.addLocal(fe.var_name, var_alloca, elem_ty, null, null);
        self.loops.append(self.a, .{ .break_bb = exit_bb, .continue_bb = cont_bb }) catch @panic("OOM");
        _ = self.emitBlockValue(fe.body);
        _ = self.loops.pop();
        if (!self.isTerminated()) _ = c.LLVMBuildBr(self.builder, cont_bb);

        // Incremento (objetivo de `continue`) → de vuelta a la condición.
        c.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
        const inxt = c.LLVMBuildAdd(self.builder, iv, c.LLVMConstInt(self.t_i64, 1, 0), "");
        _ = c.LLVMBuildStore(self.builder, inxt, i_alloca);
        _ = c.LLVMBuildBr(self.builder, cond_bb);

        c.LLVMPositionBuilderAtEnd(self.builder, exit_bb);
    }

    fn emitBreak(self: *Emitter, idx: u32) void {
        if (self.loops.items.len == 0) return self.unsupported(idx, "`break` outside a loop");
        _ = c.LLVMBuildBr(self.builder, self.loops.items[self.loops.items.len - 1].break_bb);
    }

    fn emitContinue(self: *Emitter, idx: u32) void {
        if (self.loops.items.len == 0) return self.unsupported(idx, "`continue` outside a loop");
        _ = c.LLVMBuildBr(self.builder, self.loops.items[self.loops.items.len - 1].continue_bb);
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
            // none y nil son el mismo VAL_NIL del VM: la caja NULL, que
            // imprime "nil" (types/…, enums/option_basic).
            .none_expr, .nil_literal => return .{ .ref = c.LLVMConstPointerNull(self.t_ptr), .ty = .boxed_ },
            .some_expr => |inner| {
                const v = self.emitExpr(inner) orelse return null;
                return self.emitWrap(idx, TAG_SOME, v);
            },
            .ok_expr => |inner| {
                const v = self.emitExpr(inner) orelse return null;
                return self.emitWrap(idx, TAG_OK, v);
            },
            .err_expr => |inner| {
                const v = self.emitExpr(inner) orelse return null;
                return self.emitWrap(idx, TAG_ERR, v);
            },
            .try_expr => return self.emitTry(idx),
            .match_expr => return self.emitMatch(idx),
            .lambda_expr => return self.emitLambda(idx),
            .array_literal => return self.emitArrayLit(idx),
            .index_expr => return self.emitIndex(idx),
            .struct_literal => return self.emitStructLit(idx),
            .field_access => return self.emitFieldRead(idx),
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

    /// `expr?` — con `ok`/`some` produce el payload; con `err` o `none` (NULL)
    /// devuelve la propia caja desde la función actual. El typechecker exige
    /// que la función devuelva un opcional, así que la propagación es un `ret`
    /// local con el mismo efecto que el frame-pop del TRY_UNWRAP del VM, sin
    /// setjmp/longjmp: cada `?` cruza exactamente un nivel de marco, y el
    /// caller ve la caja como resultado de la llamada — igual que el VM.
    fn emitTry(self: *Emitter, idx: u32) ?Val {
        const v = self.emitExpr(self.tree.node(idx).try_expr) orelse return null;
        if (v.ty != .boxed_ or v.payload_ty == null) {
            self.unsupported(idx, "? operator requires a value with a known payload");
            return null;
        }
        const pty = v.payload_ty.?;
        const line = self.tree.loc(idx).line;
        const err_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "try_err");
        const tag_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "try_tag");
        const ok_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "try_ok");
        const isnull = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, v.ref, c.LLVMConstPointerNull(self.t_ptr), "");
        _ = c.LLVMBuildCondBr(self.builder, isnull, err_bb, tag_bb);

        // none (NULL) o err (tag 1) → propagar; ok/some → payload.
        c.LLVMPositionBuilderAtEnd(self.builder, tag_bb);
        const tag = self.loadBoxTag(v.ref);
        const iserr = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, tag, c.LLVMConstInt(self.t_i32, TAG_ERR, 0), "");
        _ = c.LLVMBuildCondBr(self.builder, iserr, err_bb, ok_bb);

        c.LLVMPositionBuilderAtEnd(self.builder, err_bb);
        const ret_lty = c.LLVMGetReturnType(c.LLVMGlobalGetValueType(self.cur_fn));
        if (self.cur_returns_value and ret_lty == self.t_ptr) {
            _ = c.LLVMBuildRet(self.builder, v.ref);
        } else if (!self.cur_returns_value) {
            // Módulo: el VM dice "try operator outside function" (frame_count
            // == 0); el typechecker zig lo rechaza antes, defensivo igual.
            self.emitFailMsg(line, "try operator outside function");
        } else {
            self.unsupported(idx, "? operator in a function that does not return an optional");
            return null;
        }

        c.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
        return .{ .ref = self.loadBoxPayload(v.ref, pty), .ty = pty, .payload_ty = null, .sname = v.sname };
    }

    /// Llama a `astra_llvm_fail` sin condición y deja el bloque abierto tras
    /// él (la llamada no retorna; el bloque siguiente es el camino vivo).
    fn emitFailMsg(self: *Emitter, line: u32, msg: [*:0]const u8) void {
        const fail_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "fail");
        const cont_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "fail_cont");
        _ = c.LLVMBuildBr(self.builder, fail_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, fail_bb);
        const linev = c.LLVMConstInt(self.t_i32, line, 0);
        const msgp = c.LLVMBuildGlobalStringPtr(self.builder, msg, "");
        var fargs = [_]c.LLVMValueRef{ linev, msgp };
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_fail), self.r_fail, &fargs, 2, "");
        _ = c.LLVMBuildUnreachable(self.builder);
        c.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
    }

    /// `match` sobre Option/Result, literales y booleanos (los enums de usuario
    /// llegan en M2). Réplica la bajada del emitter del seed: por brazo, test
    /// de patrón → bindings en el scope del brazo → guard → cuerpo; un guard
    /// que falla sale del scope (el binding se reclama, audit §4.3) y sigue el
    /// brazo siguiente. Sin brazo total (`_`/bind a secas), el backstop es el
    /// runtime error "no match arm matched" (OPCODE_MATCH_NONE).
    fn emitMatch(self: *Emitter, idx: u32) ?Val {
        const m = self.tree.node(idx).match_expr;
        const tv = self.emitExpr(m.target) orelse return null;
        const line = self.tree.loc(idx).line;
        const arms = self.tree.extraSlice(m.arms);
        if (arms.len > 32) {
            self.unsupported(idx, "more than 32 match arms");
            return null;
        }

        const merge_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "match_merge");
        const nomatch_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "match_none");

        var end_bbs: [32]c.LLVMBasicBlockRef = undefined;
        var end_vals: [32]c.LLVMValueRef = undefined;
        var n_ends: usize = 0; // brazos que caen en merge (no terminados)
        var all_valued = true; // todos esos brazos aportan valor
        var value_ty: ?Ty = null;

        for (arms) |ai| {
            const arm = self.tree.node(ai).match_arm;
            // Total sin guard: `_` o un bind a secas (el test no puede fallar).
            const total = if (arm.guard != null) false else switch (self.tree.node(arm.pattern)) {
                .pattern_wildcard, .pattern_bind => true,
                else => false,
            };

            var next_bb: ?c.LLVMBasicBlockRef = null;
            self.pushScope();
            if (total) {
                self.bindArmBinding(arm.pattern, tv);
                if (self.error_count > 0) return null;
            } else {
                // Brazo refutable: test → bind (sólo si coincide) → guard.
                const matched = self.patternTest(arm.pattern, tv) orelse return null;
                next_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "arm_next");
                const bind_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "arm_bind");
                const body_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "arm_body");
                _ = c.LLVMBuildCondBr(self.builder, matched, bind_bb, next_bb.?);

                c.LLVMPositionBuilderAtEnd(self.builder, bind_bb);
                self.bindArmBinding(arm.pattern, tv);
                if (self.error_count > 0) return null;

                if (arm.guard) |gi| {
                    const g = self.emitExpr(gi) orelse return null;
                    _ = c.LLVMBuildCondBr(self.builder, self.truthyI1(g), body_bb, next_bb.?);
                } else {
                    _ = c.LLVMBuildBr(self.builder, body_bb);
                }
                c.LLVMPositionBuilderAtEnd(self.builder, body_bb);
            }

            const av = self.emitExpr(arm.body);
            if (!self.isTerminated()) {
                end_bbs[n_ends] = c.LLVMGetInsertBlock(self.builder);
                _ = c.LLVMBuildBr(self.builder, merge_bb);
                if (av) |v| {
                    if (value_ty) |vt| {
                        if (vt != v.ty) {
                            self.unsupported(idx, "match arms have different types");
                            return null;
                        }
                    } else value_ty = v.ty;
                    end_vals[n_ends] = v.ref;
                } else {
                    all_valued = false;
                }
                n_ends += 1;
            }
            self.popScope();
            if (total) break; // los brazos siguientes son inalcanzables
            c.LLVMPositionBuilderAtEnd(self.builder, next_bb.?);
        }

        // El `next_bb` del último brazo refutable cae aquí (y un match sin
        // brazos entra directo): este es el backstop MATCH_NONE del VM.
        if (!self.isTerminated()) _ = c.LLVMBuildBr(self.builder, nomatch_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, nomatch_bb);
        const linev = c.LLVMConstInt(self.t_i32, line, 0);
        const msgp = c.LLVMBuildGlobalStringPtr(self.builder, "no match arm matched", "");
        var fargs = [_]c.LLVMValueRef{ linev, msgp };
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_fail), self.r_fail, &fargs, 2, "");
        _ = c.LLVMBuildUnreachable(self.builder);

        c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        if (n_ends > 0 and all_valued) {
            if (value_ty) |vt| {
                const phi = c.LLVMBuildPhi(self.builder, self.llvmTy(vt), "");
                c.LLVMAddIncoming(phi, &end_vals, &end_bbs, @intCast(n_ends));
                return .{ .ref = phi, .ty = vt };
            }
        }
        return null;
    }

    /// Vínculos del patrón en el scope del brazo: el nombre a secas (cualquier
    /// valor), o el payload de una variante builtin — `some(v)` carga los bits
    /// con el tipo estático del objetivo (sólo en el camino coincidente: la
    /// caja puede ser NULL). `_` no vincula nada; los literales no vinculan.
    fn bindArmBinding(self: *Emitter, pat: u32, tv: Val) void {
        switch (self.tree.node(pat)) {
            .pattern_bind => |name| {
                const alloca = self.buildAlloca(self.llvmTy(tv.ty));
                _ = c.LLVMBuildStore(self.builder, tv.ref, alloca);
                self.addLocal(name, alloca, tv.ty, tv.payload_ty, tv.sname);
            },
            .pattern_wildcard => {},
            .pattern_builtin_variant => |bv| {
                const pi = bv.payload orelse return;
                switch (self.tree.node(pi)) {
                    .pattern_wildcard => {},
                    .pattern_bind => |name| {
                        if (tv.ty != .boxed_) {
                            self.unsupported(pi, "payload pattern requires an Option/Result target");
                            return;
                        }
                        const pty = tv.payload_ty orelse {
                            self.unsupported(pi, "cannot infer the payload type of this pattern");
                            return;
                        };
                        const alloca = self.buildAlloca(self.llvmTy(pty));
                        _ = c.LLVMBuildStore(self.builder, self.loadBoxPayload(tv.ref, pty), alloca);
                        self.addLocal(name, alloca, pty, null, tv.sname);
                    },
                    // Literal (`some(1)`): no vincula nada — el test ya
                    // comparó el payload. Anidados siguen sin soporte.
                    else => if (!self.isLiteralPat(pi)) self.unsupported(pi, "nested payload pattern"),
                }
            },
            // Vínculos de variante de enum: slots de payload del objetivo
            // (posiciónales, como la declaración) — sólo en el camino
            // coincidente, tras el test.
            .pattern_variant_bind => |vb| {
                if (tv.ty != .enum_) {
                    self.unsupported(pat, "variant pattern requires an enum target");
                    return;
                }
                const vr = self.resolveVariantPath(vb.variant) orelse {
                    self.unsupported(pat, "pattern must be Enum.Variant");
                    return;
                };
                const vl = self.enums.get(vr.enum_name).?.variants[vr.index];
                const binds = self.tree.extraSlice(vb.bindings);
                if (binds.len != vl.fields.len) {
                    self.unsupported(pat, "wrong number of payload bindings");
                    return;
                }
                for (binds, 0..) |bn, i| {
                    switch (self.tree.node(bn)) {
                        .pattern_wildcard => {},
                        .pattern_bind => |name| {
                            const ft = vl.fields[i].ty;
                            const sp = self.fieldSlotAddr(tv.ref, 16 + 8 * i);
                            const pv = c.LLVMBuildLoad2(self.builder, self.llvmTy(ft), sp, "");
                            const alloca = self.buildAlloca(self.llvmTy(ft));
                            _ = c.LLVMBuildStore(self.builder, pv, alloca);
                            self.addLocal(name, alloca, ft, vl.fields[i].payload, vl.fields[i].sname);
                        },
                        else => {
                            self.unsupported(bn, "nested payload pattern");
                            return;
                        },
                    }
                }
            },
            else => {},
        }
    }

    /// Test de patrón puro → i1 (los bindings los hace bindArmBinding, que
    /// corre sólo en el camino coincidente). Puede partir bloques — el test de
    /// tag carga de la caja y NULL no es dereferenceable —; el i1 devuelto es
    /// válido en la posición actual del builder.
    fn patternTest(self: *Emitter, pat: u32, tv: Val) ?c.LLVMValueRef {
        switch (self.tree.node(pat)) {
            // `_` y el bind a secas siempre coinciden (el guard refina luego).
            .pattern_wildcard, .pattern_bind => return c.LLVMConstInt(self.t_i1, 1, 0),
            .pattern_builtin_variant => |bv| {
                if (tv.ty != .boxed_) {
                    self.unsupported(pat, "variant pattern requires an Option/Result target");
                    return null;
                }
                const kind: u32 = switch (bv.kind) {
                    .ok => TAG_OK,
                    .err => TAG_ERR,
                    .some => TAG_SOME,
                    .none => 3, // none es nil en el VM: la caja NULL
                };
                if (kind == 3) {
                    return c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, tv.ref, c.LLVMConstPointerNull(self.t_ptr), "");
                }
                // non-NULL && tag == k; el load del tag sólo en el camino no-NULL.
                const isnull = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, tv.ref, c.LLVMConstPointerNull(self.t_ptr), "");
                const tag_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "pat_tag");
                const null_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "pat_null");
                const join_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "pat_join");
                _ = c.LLVMBuildCondBr(self.builder, isnull, null_bb, tag_bb);
                c.LLVMPositionBuilderAtEnd(self.builder, tag_bb);
                const isk = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, self.loadBoxTag(tv.ref), c.LLVMConstInt(self.t_i32, kind, 0), "");
                // Payload literal (`some(1)`): el test exige también la
                // igualdad del payload — SÓLO aquí, en tag_bb, el único
                // camino no-NULL (en null_bb la caja es NULL y leer el
                // payload sería OOB).
                var test_v = isk;
                if (bv.payload) |pl| {
                    if (self.isLiteralPat(pl)) {
                        const pty = tv.payload_ty orelse {
                            self.unsupported(pat, "literal payload pattern without a known payload type");
                            return null;
                        };
                        const pv = Val{ .ref = self.loadBoxPayload(tv.ref, pty), .ty = pty };
                        const lit = self.emitExpr(pl) orelse return null;
                        const peq = self.emitEqI1(pl, pv, lit) orelse return null;
                        test_v = c.LLVMBuildAnd(self.builder, isk, peq, "");
                    }
                }
                _ = c.LLVMBuildBr(self.builder, join_bb);
                c.LLVMPositionBuilderAtEnd(self.builder, null_bb);
                _ = c.LLVMBuildBr(self.builder, join_bb);
                c.LLVMPositionBuilderAtEnd(self.builder, join_bb);
                const phi = c.LLVMBuildPhi(self.builder, self.t_i1, "");
                var vals = [_]c.LLVMValueRef{ test_v, c.LLVMConstInt(self.t_i1, 0, 0) };
                var bbs = [_]c.LLVMBasicBlockRef{ tag_bb, null_bb };
                c.LLVMAddIncoming(phi, &vals, &bbs, 2);
                return phi;
            },
            .pattern_or => |list| {
                var acc: ?c.LLVMValueRef = null;
                for (self.tree.extraSlice(list)) |sp| {
                    const t = self.patternTest(sp, tv) orelse return null;
                    acc = if (acc) |a| c.LLVMBuildOr(self.builder, a, t, "") else t;
                }
                return acc orelse c.LLVMConstInt(self.t_i1, 1, 0);
            },
            .pattern_variant_bind => |vb| {
                // Mismo test que el patrón unit: la constante kind-0 contra
                // el objetivo — enum_eq con un lado kind-0 compara SÓLO por
                // nombres (el OPCODE_EQ del VM entre VAL_ENUM y
                // VAL_ENUM_DATA), así que el payload no participa en el test.
                const cv = self.variantConstVal(vb.variant) orelse return null;
                return self.emitEqI1(pat, tv, cv);
            },
            else => {
                // Literales (int/float/string/bool/nil) y `Enum.Variant` unit
                // (field_access): igualdad con el objetivo, la misma máquina
                // que `==` — para enums, consciente de los kinds del VM.
                const lit = self.emitExpr(pat) orelse return null;
                return self.emitEqI1(pat, tv, lit);
            },
        }
    }

    /// ¿El nodo de un payload de patrón es un literal (`some(1)`)? El test
    /// compara el payload y el binding no vincula nada en ese caso.
    fn isLiteralPat(self: *Emitter, n: u32) bool {
        return switch (std.meta.activeTag(self.tree.node(n))) {
            .int_literal, .float_literal, .string_literal, .bool_literal, .nil_literal, .unary_expr => true,
            else => false,
        };
    }

    /// `==`/`!=` como i1, compartido con los tests de patrón del match.
    fn emitEqI1(self: *Emitter, idx: u32, a: Val, b: Val) ?c.LLVMValueRef {
        if (a.ty != b.ty) {
            self.unsupported(idx, "comparison of mixed types");
            return null;
        }
        return switch (a.ty) {
            .str_ => blk: {
                var sargs = [_]c.LLVMValueRef{ a.ref, b.ref };
                const eqv = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_str_eq), self.r_str_eq, &sargs, 2, "");
                break :blk c.LLVMBuildTrunc(self.builder, eqv, self.t_i1, "");
            },
            .boxed_ => blk: {
                var sargs = [_]c.LLVMValueRef{ a.ref, b.ref };
                const eqv = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_boxed_eq), self.r_boxed_eq, &sargs, 2, "");
                break :blk c.LLVMBuildTrunc(self.builder, eqv, self.t_i1, "");
            },
            .f64_ => c.LLVMBuildFCmp(self.builder, c.LLVMRealOEQ, a.ref, b.ref, ""),
            .i64_, .bool_ => c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, a.ref, b.ref, ""),
            // VM value_eq: estructural por elemento con el ptype del objeto
            // (la rama identidad del switch de vm.c es código muerto para dos
            // arrays; la temprana de value_eq compara elemento a elemento) —
            // en runtime, porque recursa por ptype.
            .arr_ => blk: {
                var aargs = [_]c.LLVMValueRef{ a.ref, b.ref };
                const r = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_array_eq), self.r_array_eq, &aargs, 2, "");
                break :blk c.LLVMBuildTrunc(self.builder, r, self.t_i1, "");
            },
            // VM value_eq de structs: estructural por def + campos (dos
            // objetos distintos con campos iguales son ==) — en runtime,
            // porque recorre los slots por ptype.
            .struct_ => blk: {
                var sargs = [_]c.LLVMValueRef{ a.ref, b.ref };
                const r = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_struct_eq), self.r_struct_eq, &sargs, 2, "");
                break :blk c.LLVMBuildTrunc(self.builder, r, self.t_i1, "");
            },
            // VM value_eq de enums: consciente de los dos kinds del VM
            // (VAL_ENUM por nombres, VAL_ENUM_DATA estructural) — el runtime
            // decide según el `kind` de cada objeto.
            .enum_ => blk: {
                var eargs = [_]c.LLVMValueRef{ a.ref, b.ref };
                const r = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_enum_eq), self.r_enum_eq, &eargs, 2, "");
                break :blk c.LLVMBuildTrunc(self.builder, r, self.t_i1, "");
            },
            .fn_ => {
                self.unsupported(idx, "cannot compare function values");
                return null;
            },
        };
    }
    fn emitIdent(self: *Emitter, idx: u32, name: []const u8) ?Val {
        if (self.lookupLocal(name)) |l| {
            return .{ .ref = c.LLVMBuildLoad2(self.builder, self.llvmTy(l.ty), l.alloca, ""), .ty = l.ty, .payload_ty = l.payload_ty, .sname = l.sname };
        }
        // Captura de closure: los parámetros siempre sombrean (el scope de
        // locales se busca primero), luego la pila de envs de las lambdas.
        if (self.lookupCapture(name)) |cp| {
            const env = c.LLVMGetParam(self.cur_fn, 0);
            const bits = self.loadEnvSlot(env, cp.index);
            return .{ .ref = self.fromBits(bits, cp.ty), .ty = cp.ty, .payload_ty = cp.payload_ty, .sname = cp.sname };
        }
        if (self.globals.get(name)) |g| {
            return .{ .ref = c.LLVMBuildLoad2(self.builder, self.llvmTy(g.ty), g.val, ""), .ty = g.ty, .payload_ty = g.payload_ty, .sname = g.sname };
        }
        // Función nombrada usada como valor (argumento, asignación…): se
        // empaqueta en el mismo objeto { code, env = NULL } que una lambda.
        if (self.fns.get(name)) |fi| {
            const obj = self.buildFnObject(fi.val, c.LLVMConstPointerNull(self.t_ptr));
            return .{ .ref = obj, .ty = .fn_, .payload_ty = fi.ret_ty, .sname = fi.ret_sname };
        }
        self.unsupported(idx, "unknown identifier");
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
                const e1 = self.emitEqI1(idx, lhs, rhs) orelse return null;
                var e8 = c.LLVMBuildZExt(self.builder, e1, self.t_i8, "");
                if (b.op == .neq) e8 = c.LLVMBuildXor(self.builder, e8, c.LLVMConstInt(self.t_i8, 1, 0), "");
                return .{ .ref = e8, .ty = .bool_ };
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
                if (lhs.ty == .arr_ or lhs.ty == .fn_ or lhs.ty == .struct_ or lhs.ty == .enum_) {
                    // VM value_lt: aggregates no se ordenan, message con el
                    // nombre del tipo vía type_name (vm.c:933).
                    const msg: [*:0]const u8 = switch (lhs.ty) {
                        .arr_ => "cannot compare array and array",
                        .struct_ => "cannot compare struct and struct",
                        .enum_ => "cannot compare enum and enum",
                        else => "cannot compare function and function",
                    };
                    self.emitGuardTrue(c.LLVMConstInt(self.t_i1, 1, 0), line, msg);
                    return .{ .ref = c.LLVMConstInt(self.t_i8, 0, 0), .ty = .bool_ };
                }
                if (lhs.ty == .boxed_) {
                    // Igual que con strings, pero los nombres de tipo salen de
                    // los tags en runtime: "cannot compare some and some".
                    const fail_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "cmp_fail");
                    const cont_bb = c.LLVMAppendBasicBlockInContext(self.ctx, self.cur_fn, "cmp_cont");
                    _ = c.LLVMBuildBr(self.builder, fail_bb);
                    c.LLVMPositionBuilderAtEnd(self.builder, fail_bb);
                    var sargs = [_]c.LLVMValueRef{ c.LLVMConstInt(self.t_i32, line, 0), lhs.ref, rhs.ref };
                    _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_boxed_order_fail), self.r_boxed_order_fail, &sargs, 3, "");
                    _ = c.LLVMBuildUnreachable(self.builder);
                    c.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
                    return .{ .ref = c.LLVMConstInt(self.t_i8, 0, 0), .ty = .bool_ }; // inalcanzable
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
        // Escritura en LValue más allá de los identificadores: elementos de
        // array (Hallazgo B) y campos de struct.
        switch (self.tree.node(as.target)) {
            .index_expr => return self.emitElemAssign(idx),
            .field_access => return self.emitFieldAssign(idx),
            else => {},
        }
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
        } else if (self.lookupCapture(target_name) != null) {
            // §30.5: los closures capturan por valor — no hay ninguna celda
            // a la que escribir, el env es un snapshot (el typechecker zig ya
            // lo rechaza antes; defensivo como el emitter del seed).
            self.unsupported(idx, "cannot assign to a captured variable (closures capture by value)");
            return null;
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
                    // Constructor pelón de variante de enum: `Circle(x)`
                    // (el seed resuelve la variante en cualquier enum).
                    if (self.variant_map.get(name)) |vr| return self.emitEnumConstruct(idx, vr);
                    // No es una fn nombrada: puede ser un valor de función en
                    // un local/global (lambda o referencia a fn) — llamada
                    // dinámica vía el objeto { code, env }.
                    return self.emitDynamicCall(idx, call.callee);
                };
                const args = self.tree.extraSlice(call.args);
                var abuf: [17]c.LLVMValueRef = undefined;
                if (args.len + 1 > abuf.len) {
                    self.unsupported(idx, "too many arguments");
                    return null;
                }
                // Convención uniforme: las funciones nombradas no capturan,
                // así que su env es NULL (parámetro 0 ignorado en el callee).
                abuf[0] = c.LLVMConstPointerNull(self.t_ptr);
                for (args, 0..) |ai, i| {
                    const av = self.emitExpr(ai) orelse return null;
                    abuf[i + 1] = av.ref;
                }
                const rv = c.LLVMBuildCall2(self.builder, info.fty, info.val, &abuf, @intCast(args.len + 1), "");
                if (info.returns_value) return .{ .ref = rv, .ty = info.ret_ty.?, .payload_ty = info.ret_payload, .sname = info.ret_sname };
                return null;
            },
            else => return self.emitDynamicCall(idx, call.callee),
        }
    }

    /// Llamada a un valor de función (lambda o referencia a fn pasada como
    /// argumento): `code(env, args...)` a través del objeto { code, env }.
    /// La firma LLVM se arma en el sitio de llamada con los tipos reales de
    /// los argumentos y el retorno estático del callee (payload_ty), que el
    /// typechecker garantiza compatibles.
    fn emitDynamicCall(self: *Emitter, idx: u32, callee: u32) ?Val {
        const fv = self.emitExpr(callee) orelse return null;
        if (fv.ty != .fn_) {
            self.unsupported(idx, "call of a non-function value");
            return null;
        }
        const call = self.tree.node(idx).call_expr;
        const args = self.tree.extraSlice(call.args);
        var abuf: [17]c.LLVMValueRef = undefined;
        var fbuf: [17]c.LLVMTypeRef = undefined;
        if (args.len + 1 > abuf.len) {
            self.unsupported(idx, "too many arguments");
            return null;
        }
        fbuf[0] = self.t_ptr; // env
        for (args, 0..) |ai, i| {
            const av = self.emitExpr(ai) orelse return null;
            abuf[i + 1] = av.ref;
            fbuf[i + 1] = self.llvmTy(av.ty);
        }
        // El objeto: { ptr code; ptr env } — code en el offset 0, env en 8.
        var cidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 0, 0)};
        const codep = c.LLVMBuildGEP2(self.builder, self.t_i8, fv.ref, &cidxs, 1, "");
        const code = c.LLVMBuildLoad2(self.builder, self.t_ptr, codep, "");
        var eidxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 8, 0)};
        const envp = c.LLVMBuildGEP2(self.builder, self.t_i8, fv.ref, &eidxs, 1, "");
        const env = c.LLVMBuildLoad2(self.builder, self.t_ptr, envp, "");
        abuf[0] = env;
        const ret_lty = if (fv.payload_ty) |rt| self.llvmTy(rt) else self.t_void;
        const fty = c.LLVMFunctionType(ret_lty, &fbuf, @intCast(args.len + 1), 0);
        const rv = c.LLVMBuildCall2(self.builder, fty, code, &abuf, @intCast(args.len + 1), "");
        if (fv.payload_ty) |rt| return .{ .ref = rv, .ty = rt, .sname = fv.sname };
        return null;
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
                .boxed_ => {
                    var xargs = [_]c.LLVMValueRef{av.ref};
                    _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_boxed), self.r_print_boxed, &xargs, 1, "");
                },
                .fn_ => {
                    self.unsupported(idx, "print of a function value");
                    return null;
                },
                .arr_ => {
                    var xargs = [_]c.LLVMValueRef{av.ref};
                    _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_array), self.r_print_array, &xargs, 1, "");
                },
                .struct_ => {
                    var xargs = [_]c.LLVMValueRef{av.ref};
                    _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_struct), self.r_print_struct, &xargs, 1, "");
                },
                .enum_ => {
                    var xargs = [_]c.LLVMValueRef{av.ref};
                    _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_print_enum), self.r_print_enum, &xargs, 1, "");
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
        if (v.ty == .boxed_) {
            // `if some(x)` es legal (el typechecker admite opcional en `if`):
            // some/ok/err (no NULL) → true, none (NULL) → false.
            return c.LLVMBuildICmp(self.builder, c.LLVMIntNE, v.ref, c.LLVMConstPointerNull(self.t_ptr), "");
        }
        const zero = switch (v.ty) {
            .i64_ => c.LLVMConstInt(self.t_i64, 0, 0),
            .bool_ => c.LLVMConstInt(self.t_i8, 0, 0),
            // VM truthy de VAL_ARRAY: len > 0 (vm.c value_truthy); los demás
            // heap types son un puntero y el typechecker no deja testearlos.
            .arr_ => {
                var idxs = [_]c.LLVMValueRef{c.LLVMConstInt(self.t_i64, 0, 0)};
                const pp = c.LLVMBuildGEP2(self.builder, self.t_i8, v.ref, &idxs, 1, "");
                const len = c.LLVMBuildLoad2(self.builder, self.t_i64, pp, "");
                return c.LLVMBuildICmp(self.builder, c.LLVMIntSGT, len, c.LLVMConstInt(self.t_i64, 0, 0), "");
            },
            // VAL_STRUCT es truthy iff el objeto existe — y todo objeto que
            // el emisor construye existe (vm.c value_truthy: struct_val != NULL).
            // VAL_ENUM/VAL_ENUM_DATA son truthy incondicionalmente.
            .struct_, .enum_ => return c.LLVMConstInt(self.t_i1, 1, 0),
            .f64_, .str_, .boxed_, .fn_ => unreachable,
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

    fn addLocal(self: *Emitter, name: []const u8, alloca: c.LLVMValueRef, ty: Ty, payload_ty: ?Ty, sname: ?[]const u8) void {
        self.scopes.items[self.scopes.items.len - 1].put(name, .{ .alloca = alloca, .ty = ty, .payload_ty = payload_ty, .sname = sname }) catch @panic("OOM");
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
            .str_, .boxed_, .fn_, .arr_, .struct_, .enum_ => self.t_ptr,
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
            .str_, .boxed_, .fn_, .arr_, .struct_, .enum_ => c.LLVMConstPointerNull(self.t_ptr),
        };
    }

    /// Código ptype de un payload, para guardarlo en la caja (contrato con el
    /// runtime). `null` si el tipo no puede vivir dentro de una caja: el
    /// runtime no tiene representación para funciones.
    fn boxPTy(ty: Ty) ?u32 {
        return switch (ty) {
            .bool_ => PTY_BOOL,
            .i64_ => PTY_I64,
            .f64_ => PTY_F64,
            .str_ => PTY_STR,
            .boxed_ => PTY_BOXED,
            .arr_ => PTY_ARRAY,
            .struct_ => PTY_STRUCT,
            .enum_ => PTY_ENUM,
            .fn_ => null,
        };
    }

    /// Payload → bits i64 para `wrap` (los scalares caben todos en 8 bytes).
    fn toBits(self: *Emitter, ref: c.LLVMValueRef, ty: Ty) c.LLVMValueRef {
        return switch (ty) {
            .i64_ => ref,
            .bool_ => c.LLVMBuildZExt(self.builder, ref, self.t_i64, ""),
            .f64_ => c.LLVMBuildBitCast(self.builder, ref, self.t_i64, ""),
            .str_, .boxed_, .fn_, .arr_, .struct_, .enum_ => c.LLVMBuildPtrToInt(self.builder, ref, self.t_i64, ""),
        };
    }

    /// Bits i64 del payload → valor con su tipo estático (inverse de toBits).
    fn fromBits(self: *Emitter, bits: c.LLVMValueRef, ty: Ty) c.LLVMValueRef {
        return switch (ty) {
            .i64_ => bits,
            .bool_ => c.LLVMBuildTrunc(self.builder, bits, self.t_i8, ""),
            .f64_ => c.LLVMBuildBitCast(self.builder, bits, self.t_f64, ""),
            .str_, .boxed_, .fn_, .arr_, .struct_, .enum_ => c.LLVMBuildIntToPtr(self.builder, bits, self.t_ptr, ""),
        };
    }

    /// Tamaño (en bytes) que ocupa un elemento de ese tipo dentro del objeto
    /// array: los escalares de 8 bytes y el bool 1 (su slot en el header es
    /// i32 ptype/align 8, así que los offsets 8-byte quedan alineados).
    fn elemSlotSize(ty: Ty) i64 {
        return switch (ty) {
            .bool_ => 1,
            else => 8,
        };
    }

    /// Carga el tag (i32 en el offset 0 de la caja).
    fn loadBoxTag(self: *Emitter, box: c.LLVMValueRef) c.LLVMValueRef {
        return c.LLVMBuildLoad2(self.builder, self.t_i32, box, "");
    }

    /// Carga el payload (i64 en el offset 8) y lo devuelve con su tipo.
    fn loadBoxPayload(self: *Emitter, box: c.LLVMValueRef, pty: Ty) c.LLVMValueRef {
        var idxs = [_]c.LLVMValueRef{ c.LLVMConstInt(self.t_i64, 8, 0) };
        const pp = c.LLVMBuildGEP2(self.builder, self.t_i8, box, &idxs, 1, "");
        const bits = c.LLVMBuildLoad2(self.builder, self.t_i64, pp, "");
        return self.fromBits(bits, pty);
    }

    /// `some(x)`/`ok(x)`/`err(x)`: caja con tag, ptype y payload por valor.
    fn emitWrap(self: *Emitter, idx: u32, tag: u32, inner: Val) ?Val {
        const pty = boxPTy(inner.ty) orelse return self.unsupportedBox(idx);
        const bits = self.toBits(inner.ref, inner.ty);
        const line = self.tree.loc(idx).line;
        var args = [_]c.LLVMValueRef{
            c.LLVMConstInt(self.t_i32, line, 0),
            c.LLVMConstInt(self.t_i32, tag, 0),
            c.LLVMConstInt(self.t_i32, pty, 0),
            bits,
        };
        const r = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(self.r_wrap), self.r_wrap, &args, 4, "");
        return .{ .ref = r, .ty = .boxed_, .payload_ty = inner.ty, .sname = inner.sname };
    }

    fn unsupportedBox(self: *Emitter, idx: u32) ?Val {
        self.unsupported(idx, "payload type not representable in an Option/Result box");
        return null;
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

    const Annot = struct { ty: Ty, payload: ?Ty = null, sname: ?[]const u8 = null };

    /// Anotación de un opcional `T?` → (`boxed_`, payload T). Es la única forma
    /// de anotar Option/Result: `fn increment(x: i32?) -> i32?` (try_operator).
    /// El `T` se resuelve completo (scalars, structs, arrays…) para conservar
    /// el `sname` cuando el payload es un struct.
    fn boxedM0Ty(self: *Emitter, node: ?u32) ?Annot {
        const ni = node orelse return null;
        switch (self.tree.node(ni)) {
            .type_optional => |inner| {
                if (self.scalarM0Ty(inner)) |t| return .{ .ty = .boxed_, .payload = t };
                const ia = self.annotTy(inner) orelse return null;
                return .{ .ty = .boxed_, .payload = ia.ty, .sname = ia.sname };
            },
            else => return null,
        }
    }

    /// Anotación de parámetro/retorno/let: escalar, `T?`, `fn(T, ...) -> T`,
    /// `[T]` o el nombre de un struct declarado. En un `fn(...)` el payload es
    /// el tipo de retorno (lo que la llamada dinámica necesita); los
    /// parámetros del tipo sólo validan la forma y los reales salen del sitio
    /// de llamada.
    fn annotTy(self: *Emitter, node: ?u32) ?Annot {
        if (self.scalarM0Ty(node)) |t| return .{ .ty = t, .payload = null };
        const ni = node orelse return null;
        switch (self.tree.node(ni)) {
            .type_ident => |t| {
                // Nombre de un struct declarado → su layout (M2.b); de un
                // enum declarado → valor de enum (M2.c). Nombres desconocidos
                // caen a boxedM0Ty → null → unsupported honesto (traits/struct
                // sin declarar ya rechazó el checker).
                if (self.structs.contains(t.name))
                    return .{ .ty = .struct_, .sname = t.name };
                if (self.enums.contains(t.name))
                    return .{ .ty = .enum_ };
                return null;
            },
            .type_fn => |tf| return .{
                .ty = .fn_,
                .payload = if (tf.ret) |r| (self.annotTy(r) orelse return null).ty else null,
            },
            // `[T]` — el tamaño del literal no cambia la representación
            // (objetos de longitud variable con el elem type fijo), sólo se
            // propaga el tipo de elemento para índices/bounds/print.
            .type_array => |ta| return .{
                .ty = .arr_,
                .payload = (self.annotTy(ta.elem) orelse return null).ty,
            },
            else => {},
        }
        return self.boxedM0Ty(node);
    }

    /// Tipo del payload de un `boxed_` inferido estructuralmente (los `T?`
    /// anotados pasan por annotTy; aquí sólo constructores y referencia a un
    /// valor ya tipado).
    /// Firma inferida de un `fn` sin `->`: el checker las tipa void, pero la VM
    /// es dinámica — tanto `return e` como la expresión de cola fluyen al
    /// caller (`print(g())` imprime lo que g devuelva; repro 2026-10-20:
    /// 5/7/1/2). Recorre los `return` (también anidados en if/while/for/match)
    /// y la cola, con un scope temporal de `let` para que expresiones como
    /// `a[3]` resuelvan el tipo de `a` (declareFn corre antes de emitir el
    /// cuerpo). Tipos en conflicto o no inferibles → void, como antes: el uso
    /// como valor se rechaza limpio y el caso queda skip.
    fn inferFnRet(self: *Emitter, fd: ast.FnDecl) ?InferredRet {
        var map: std.StringHashMapUnmanaged(InferBinding) = .empty;
        self.collectInferLets(fd.body, &map);
        const saved = self.infer_tmp;
        self.infer_tmp = &map;
        defer self.infer_tmp = saved;

        var ri = RetScan{};
        self.scanReturns(fd.body, &ri);
        var tail: ?u32 = null;
        if (std.meta.activeTag(self.tree.node(fd.body)) == .block) tail = self.tree.node(fd.body).block.tail;
        const tail_ty: ?Ty = if (tail) |t| self.inferStaticTy(t) else null;

        // Un `return` pelado (void) mezclado con un valor es irreproducible
        // con una sola firma; los conflictos de tipo también.
        if (ri.bare and (ri.ty != null or tail_ty != null)) return null;
        if (ri.conflict) return null;
        if (ri.ty) |rt| {
            if (tail_ty) |tt| {
                if (tt != rt) return null;
            }
            const src = ri.node.?;
            return .{
                .ty = rt,
                .payload = if (rt == .boxed_) self.inferBoxPayload(src) else null,
                .sname = if (rt == .struct_) self.inferStaticSName(src) else null,
            };
        }
        if (tail_ty) |tt| {
            const src = tail.?;
            return .{
                .ty = tt,
                .payload = if (tt == .boxed_) self.inferBoxPayload(src) else null,
                .sname = if (tt == .struct_) self.inferStaticSName(src) else null,
            };
        }
        return null;
    }

    /// Bindings `let`/`for`/parámetros de patrón visibles en cualquier punto
    /// del cuerpo, solo para tipos. Última declaración gana (conservador).
    fn collectInferLets(self: *Emitter, idx: u32, map: *std.StringHashMapUnmanaged(InferBinding)) void {
        switch (self.tree.node(idx)) {
            .block => |b| {
                for (self.tree.extraSlice(b.stmts)) |st| self.collectInferLets(st, map);
            },
            .var_decl => |vd| {
                const b: InferBinding = if (self.annotTy(vd.type_node)) |at|
                    .{ .ty = at.ty, .payload = at.payload, .sname = at.sname }
                else if (vd.value) |vi| blk: {
                    const t = self.inferStaticTy(vi) orelse return;
                    break :blk .{
                        .ty = t,
                        .payload = if (t == .boxed_ or t == .arr_) self.inferBoxPayload(vi) else null,
                        .sname = if (t == .struct_) self.inferStaticSName(vi) else null,
                    };
                } else return;
                map.put(self.a, vd.name, b) catch @panic("OOM");
            },
            .if_expr => |ie| {
                self.collectInferLets(ie.then_block, map);
                if (ie.else_block) |eb| self.collectInferLets(eb, map);
            },
            .while_expr => |we| self.collectInferLets(we.body, map),
            .for_expr => |fe| {
                // Variable del loop: i64 en rangos, tipo de elemento en arrays.
                var b = InferBinding{ .ty = .i64_ };
                if (self.inferStaticTy(fe.iter)) |it| {
                    if (it == .arr_) b = .{ .ty = self.inferBoxPayload(fe.iter) orelse .i64_ };
                }
                map.put(self.a, fe.var_name, b) catch @panic("OOM");
                self.collectInferLets(fe.body, map);
            },
            .match_expr => |mm| {
                for (self.tree.extraSlice(mm.arms)) |ai| {
                    const arm = self.tree.node(ai).match_arm;
                    self.collectInferLets(arm.body, map);
                }
            },
            else => {},
        }
    }

    /// Tipos de los `return` del cuerpo (incluidos los anidados). Los brazos
    /// de un match/if se recorren porque un `return` puede vivir dentro.
    fn scanReturns(self: *Emitter, idx: u32, ri: *RetScan) void {
        switch (self.tree.node(idx)) {
            .block => |b| {
                for (self.tree.extraSlice(b.stmts)) |st| self.scanReturns(st, ri);
            },
            .return_stmt => |rv| {
                const v = rv orelse {
                    ri.bare = true;
                    return;
                };
                const t = self.inferStaticTy(v) orelse {
                    ri.conflict = true;
                    return;
                };
                if (ri.ty) |prev| {
                    if (prev != t) ri.conflict = true;
                } else {
                    ri.ty = t;
                    ri.node = v;
                }
            },
            .if_expr => |ie| {
                self.scanReturns(ie.then_block, ri);
                if (ie.else_block) |eb| self.scanReturns(eb, ri);
            },
            .while_expr => |we| self.scanReturns(we.body, ri),
            .for_expr => |fe| self.scanReturns(fe.body, ri),
            .match_expr => |mm| {
                for (self.tree.extraSlice(mm.arms)) |ai| {
                    const arm = self.tree.node(ai).match_arm;
                    self.scanReturns(arm.body, ri);
                }
            },
            else => {},
        }
    }

    /// Consulta el scope temporal de inferencia (solo tipos; declareFn corre
    /// antes que los allocas reales).
    fn tmpBinding(self: *Emitter, name: []const u8) ?InferBinding {
        const m = self.infer_tmp orelse return null;
        return m.get(name);
    }

    fn inferBoxPayload(self: *Emitter, idx: u32) ?Ty {
        switch (self.tree.node(idx)) {
            .some_expr, .ok_expr, .err_expr => |inner| return self.inferStaticTy(inner),
            .lambda_expr => |lm| return self.lambdaRetTy(lm),
            .array_literal => |list| {
                const elems = self.tree.extraSlice(list);
                if (elems.len == 0) return null;
                return self.inferStaticTy(elems[0]);
            },
            .identifier => |name| {
                if (self.lookupLocal(name)) |l| return l.payload_ty;
                if (self.globals.get(name)) |g| return g.payload_ty;
                if (self.tmpBinding(name)) |b| return b.payload;
                return null;
            },
            .call_expr => |call| switch (self.tree.node(call.callee)) {
                .identifier => |nm| {
                    if (self.fns.get(nm)) |fi| return fi.ret_payload;
                },
                else => {},
            },
            else => {},
        }
        return null;
    }

    /// Inferencia de tipo M0 para inicializadores de globales (donde aún no hay
    /// valor emitido del cual leer el tipo). Suficiente para el subconjunto M0.
    fn inferStaticTy(self: *Emitter, idx: u32) ?Ty {
        switch (self.tree.node(idx)) {
            .int_literal => return .i64_,
            .float_literal => return .f64_,
            .string_literal => return .str_,
            .bool_literal => return .bool_,
            .none_expr, .nil_literal, .some_expr, .ok_expr, .err_expr => return .boxed_,
            .lambda_expr => return .fn_,
            .array_literal => return .arr_,
            .struct_literal => return .struct_,
            // `Enum.Variant` (acceso) o `Variant(args)` (constructor pelón):
            // el valor es de tipo enum (M2.c).
            .field_access => {
                if (self.resolveVariantPath(idx)) |_| return .enum_;
                return null;
            },
            .call_expr => |call| switch (self.tree.node(call.callee)) {
                .identifier => |nm| {
                    if (std.mem.eql(u8, nm, "print")) return null;
                    if (self.fns.get(nm)) |fi| return fi.ret_ty;
                    if (self.variant_map.contains(nm)) return .enum_;
                    return null;
                },
                else => return null,
            },
            .try_expr => |inner| return self.inferBoxPayload(inner),
            .match_expr => |mm| {
                // El valor del match: el tail del último brazo (el typechecker
                // iguala los tipos de todos los brazos).
                const arms = self.tree.extraSlice(mm.arms);
                if (arms.len == 0) return null;
                const last = self.tree.node(arms[arms.len - 1]).match_arm;
                return switch (self.tree.node(last.body)) {
                    .block => |blk| if (blk.tail) |t| self.inferStaticTy(t) else null,
                    else => self.inferStaticTy(last.body),
                };
            },
            .identifier => |name| {
                if (self.lookupLocal(name)) |l| return l.ty;
                if (self.globals.get(name)) |g| return g.ty;
                if (self.tmpBinding(name)) |b| return b.ty;
                return null;
            },
            // `xs[i]`: el tipo de elemento del array. El objeto tiene que ser
            // nominal (identificador) — un literal de array se infiere por su
            // primer elemento en los contextos donde el emitter lo necesita.
            .index_expr => |ix| switch (self.tree.node(ix.object)) {
                .identifier => |nm| {
                    if (self.lookupLocal(nm)) |l| return if (l.ty == .arr_) l.payload_ty else null;
                    if (self.globals.get(nm)) |g| return if (g.ty == .arr_) g.payload_ty else null;
                    if (self.tmpBinding(nm)) |b| return if (b.ty == .arr_) b.payload else null;
                    return null;
                },
                else => return null,
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
            .if_expr => |ie| {
                const tb = self.tree.node(ie.then_block).block;
                if (tb.tail) |t| return self.inferStaticTy(t);
                return null;
            },
            else => return null,
        }
    }

    /// Nombre del struct que transporta un valor, cuando se conoce en tiempo
    /// de compilación: los literales (`P { … }`) y los identificadores (una
    /// local/global/parámetro ya tipada) lo llevan. Las cajas y los `?`
    /// conservan el del payload vía emitWrap/emitTry/bindArmBinding.
    fn inferStaticSName(self: *Emitter, idx: u32) ?[]const u8 {
        switch (self.tree.node(idx)) {
            .struct_literal => |sl| return sl.name,
            .identifier => |nm| {
                if (self.lookupLocal(nm)) |l| return l.sname;
                if (self.globals.get(nm)) |g| return g.sname;
                if (self.tmpBinding(nm)) |b| return b.sname;
                return null;
            },
            else => return null,
        }
    }

    /// Registra las decls de nivel superior (M2.b/M2.c) en tres subpasadas:
    /// primero los NOMBRES de structs (un campo puede referenciar a un struct
    /// declarado más abajo), luego los enums completos (sus payloads de anotación
    /// ya resuelven structs y enums por nombre) y por último los offsets de
    /// los campos de struct y sus descriptores — globales constantes, así que
    /// print/eq leen el def del propio objeto igual que en el VM (s->def) y
    /// no necesita estado compilado.
    fn registerDecls(self: *Emitter, items: []const u32) void {
        // 0a: nombres — placeholder para que annotTy resuelva referencias
        // cruzadas entre structs (P { q: Q } con Q declarada después).
        for (items) |it| {
            const sd = switch (self.tree.node(it)) {
                .struct_decl => |sd| sd,
                else => continue,
            };
            if (sd.generics.len > 0) {
                self.unsupported(it, "generic struct");
                return;
            }
            self.structs.put(sd.name, .{ .fields = &.{}, .def = null, .size = 8 }) catch @panic("OOM");
        }
        // 0b: enums (variantes + payloads + descriptores + constantes kind-0).
        self.registerEnums(items);
        if (self.error_count > 0) return;
        // 0c: campos + descriptor por cada layout de struct.
        var it = self.structs.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            // Recupera el decl correspondiente por nombre (mismo nombre de
            // campo `name` en StructDecl). Re-ejecutar la scan es barato.
            var decl_idx: ?u32 = null;
            for (items) |sit| {
                const n = self.tree.node(sit);
                if (std.meta.activeTag(n) != .struct_decl) continue;
                if (std.mem.eql(u8, n.struct_decl.name, name)) decl_idx = sit;
            }
            const sd = self.tree.node(decl_idx.?).struct_decl;
            const field_items = self.tree.extraSlice(sd.fields);
            if (field_items.len > 64) { // el buffer de ptypes/nombres del descriptor
                self.unsupported(decl_idx.?, "too many struct fields");
                return;
            }
            var fields = self.a.alloc(StructField, field_items.len) catch @panic("OOM");
            var ptypes = self.a.alloc(u32, field_items.len) catch @panic("OOM");
            var off: i64 = 8; // offset 0 = puntero al descriptor
            for (field_items, 0..) |fi, i| {
                const f = self.tree.node(fi).field_decl;
                const at = self.annotTy(f.type_node) orelse {
                    self.unsupported(fi, "struct field without a supported type");
                    return;
                };
                fields[i] = .{ .name = f.name, .ty = at.ty, .payload = at.payload, .sname = at.sname };
                ptypes[i] = boxPTy(at.ty) orelse PTY_BOOL; // inalcanzable: fn ya rechazó el checker
                off += 8; // slots de 8 bytes: el bool vive como i8 en el inicio del slot
            }
            entry.value_ptr.* = .{
                .fields = fields,
                .def = self.emitStructDefGlobal(name, field_items.len, fields, ptypes),
                .size = off,
            };
        }
    }

    /// Global constante `AstraLLVMStructDef { name, nfields, ptypes, fields }`
    /// que el runtime lee para print/eq estructural. Los arrays de ptypes y
    /// de nombres son globales privados; los nombres de campo son strings
    /// con terminador (opaque pointers: el global ES su propio puntero).
    fn emitStructDefGlobal(
        self: *Emitter,
        name: []const u8,
        nfields: usize,
        fields: []const StructField,
        ptypes: []const u32,
    ) c.LLVMValueRef {
        // Array de ptypes [N x i32].
        const pty_ty = c.LLVMArrayType(self.t_i32, @intCast(nfields));
        const pty_arr = c.LLVMAddGlobal(self.mod, pty_ty, "");
        var pty_vals: [64]c.LLVMValueRef = undefined;
        for (ptypes, 0..) |p, i| pty_vals[i] = c.LLVMConstInt(self.t_i32, p, 0);
        c.LLVMSetInitializer(pty_arr, c.LLVMConstArray(self.t_i32, &pty_vals, @intCast(nfields)));
        c.LLVMSetLinkage(pty_arr, c.LLVMPrivateLinkage);
        // Array de punteros a nombres de campo [N x ptr].
        const fnm_ty = c.LLVMArrayType(self.t_ptr, @intCast(nfields));
        const fnm_arr = c.LLVMAddGlobal(self.mod, fnm_ty, "");
        var fnm_vals: [64]c.LLVMValueRef = undefined;
        for (fields, 0..) |f, i| {
            const sv = c.LLVMAddGlobal(self.mod, c.LLVMArrayType(self.t_i8, @intCast(f.name.len + 1)), "");
            c.LLVMSetInitializer(sv, c.LLVMConstStringInContext2(self.ctx, f.name.ptr, f.name.len, 0));
            c.LLVMSetLinkage(sv, c.LLVMPrivateLinkage);
            c.LLVMSetUnnamedAddress(sv, c.LLVMGlobalUnnamedAddr);
            fnm_vals[i] = sv;
        }
        c.LLVMSetInitializer(fnm_arr, c.LLVMConstArray(self.t_ptr, &fnm_vals, @intCast(nfields)));
        c.LLVMSetLinkage(fnm_arr, c.LLVMPrivateLinkage);
        // El nombre del struct.
        const nm = c.LLVMAddGlobal(self.mod, c.LLVMArrayType(self.t_i8, @intCast(name.len + 1)), "");
        c.LLVMSetInitializer(nm, c.LLVMConstStringInContext2(self.ctx, name.ptr, name.len, 0));
        c.LLVMSetLinkage(nm, c.LLVMPrivateLinkage);
        c.LLVMSetUnnamedAddress(nm, c.LLVMGlobalUnnamedAddr);
        // El descriptor: { ptr, i32, ptr, ptr } (el i32 nfields sigue con pad
        // hasta el ptr siguiente, igual que el layout del C del runtime).
        const def_ty = blk: {
            var def_fields = [_]c.LLVMTypeRef{ self.t_ptr, self.t_i32, self.t_ptr, self.t_ptr };
            break :blk c.LLVMStructTypeInContext(self.ctx, &def_fields, 4, 0);
        };
        const def = c.LLVMAddGlobal(self.mod, def_ty, "");
        var fvals = [_]c.LLVMValueRef{ nm, c.LLVMConstInt(self.t_i32, @intCast(nfields), 0), pty_arr, fnm_arr };
        c.LLVMSetInitializer(def, c.LLVMConstNamedStruct(def_ty, &fvals, 4));
        c.LLVMSetLinkage(def, c.LLVMPrivateLinkage);
        return def;
    }

    /// Enums de nivel superior (M2.c): por cada uno, el descriptor
    /// `AstraLLVMEnumDef` + una constante kind-0 por variante (el VAL_ENUM
    /// del VM para `Enum.Variant` como valor y para los patrones de match) +
    /// el índice que resuelve el constructor pelón `Circle(x)` (el seed
    /// busca la variante en CUALQUIER enum — find_enum_by_variant — y queda
    /// con la PRIMERA aparición).
    fn registerEnums(self: *Emitter, items: []const u32) void {
        // Nombres primero: los payloads anotados pueden referenciar a otros
        // enums o structs declarados más abajo.
        for (items) |it| {
            const ed = switch (self.tree.node(it)) {
                .enum_decl => |ed| ed,
                else => continue,
            };
            if (ed.generics.len > 0) {
                self.unsupported(it, "generic enum");
                return;
            }
            self.enums.put(ed.name, .{ .name = ed.name, .variants = &.{}, .def = null }) catch @panic("OOM");
        }
        for (items) |it| {
            const ed = switch (self.tree.node(it)) {
                .enum_decl => |ed| ed,
                else => continue,
            };
            const variant_items = self.tree.extraSlice(ed.variants);
            if (variant_items.len == 0 or variant_items.len > 64) {
                self.unsupported(it, "enum without variants or too many variants");
                return;
            }
            var variants = self.a.alloc(EnumVariantLayout, variant_items.len) catch @panic("OOM");
            var vdef_vals = self.a.alloc(c.LLVMValueRef, variant_items.len) catch @panic("OOM");
            const vdef_ty = blk: {
                var vf = [_]c.LLVMTypeRef{ self.t_ptr, self.t_i32, self.t_ptr };
                break :blk c.LLVMStructTypeInContext(self.ctx, &vf, 3, 0);
            };
            for (variant_items, 0..) |vip, i| {
                const v = self.tree.node(vip).enum_variant;
                var fields: []StructField = &.{};
                if (v.payload) |pl| {
                    const payload_items = self.tree.extraSlice(self.tree.node(pl).payload);
                    if (payload_items.len > 64) {
                        self.unsupported(vip, "too many payload fields");
                        return;
                    }
                    fields = self.a.alloc(StructField, payload_items.len) catch @panic("OOM");
                    for (payload_items, 0..) |pi, j| {
                        const f = self.tree.node(pi).field_decl;
                        const at = self.annotTy(f.type_node) orelse {
                            self.unsupported(pi, "enum payload without a supported type");
                            return;
                        };
                        fields[j] = .{ .name = f.name, .ty = at.ty, .payload = at.payload, .sname = at.sname };
                    }
                }
                // ptypes del payload: [N x i32], NULL constante sin payload.
                var ptypes_ptr: c.LLVMValueRef = c.LLVMConstPointerNull(self.t_ptr);
                if (fields.len > 0) {
                    const pty_arr = c.LLVMAddGlobal(self.mod, c.LLVMArrayType(self.t_i32, @intCast(fields.len)), "");
                    const pv = self.a.alloc(c.LLVMValueRef, fields.len) catch @panic("OOM");
                    for (fields, 0..) |f, j| pv[j] = c.LLVMConstInt(self.t_i32, boxPTy(f.ty) orelse PTY_BOOL, 0);
                    c.LLVMSetInitializer(pty_arr, c.LLVMConstArray(self.t_i32, pv.ptr, @intCast(fields.len)));
                    c.LLVMSetLinkage(pty_arr, c.LLVMPrivateLinkage);
                    ptypes_ptr = pty_arr;
                }
                // Nombre de la variante.
                const vn = c.LLVMAddGlobal(self.mod, c.LLVMArrayType(self.t_i8, @intCast(v.name.len + 1)), "");
                c.LLVMSetInitializer(vn, c.LLVMConstStringInContext2(self.ctx, v.name.ptr, v.name.len, 0));
                c.LLVMSetLinkage(vn, c.LLVMPrivateLinkage);
                c.LLVMSetUnnamedAddress(vn, c.LLVMGlobalUnnamedAddr);
                var vv = [_]c.LLVMValueRef{ vn, c.LLVMConstInt(self.t_i32, @intCast(fields.len), 0), ptypes_ptr };
                vdef_vals[i] = c.LLVMConstNamedStruct(vdef_ty, &vv, 3);
                variants[i] = .{ .name = v.name, .fields = fields, .unit_const = undefined };
                const gop = self.variant_map.getOrPut(v.name) catch @panic("OOM");
                if (!gop.found_existing) gop.value_ptr.* = .{ .enum_name = ed.name, .index = i };
            }
            // El descriptor: { name, nvariants, variants[] }.
            const en = c.LLVMAddGlobal(self.mod, c.LLVMArrayType(self.t_i8, @intCast(ed.name.len + 1)), "");
            c.LLVMSetInitializer(en, c.LLVMConstStringInContext2(self.ctx, ed.name.ptr, ed.name.len, 0));
            c.LLVMSetLinkage(en, c.LLVMPrivateLinkage);
            c.LLVMSetUnnamedAddress(en, c.LLVMGlobalUnnamedAddr);
            const varr = c.LLVMAddGlobal(self.mod, c.LLVMArrayType(vdef_ty, @intCast(variant_items.len)), "");
            c.LLVMSetInitializer(varr, c.LLVMConstArray(vdef_ty, vdef_vals.ptr, @intCast(variant_items.len)));
            c.LLVMSetLinkage(varr, c.LLVMPrivateLinkage);
            const def_ty = blk: {
                var df = [_]c.LLVMTypeRef{ self.t_ptr, self.t_i32, self.t_ptr };
                break :blk c.LLVMStructTypeInContext(self.ctx, &df, 3, 0);
            };
            const def = c.LLVMAddGlobal(self.mod, def_ty, "");
            var dv = [_]c.LLVMValueRef{ en, c.LLVMConstInt(self.t_i32, @intCast(variant_items.len), 0), varr };
            c.LLVMSetInitializer(def, c.LLVMConstNamedStruct(def_ty, &dv, 3));
            c.LLVMSetLinkage(def, c.LLVMPrivateLinkage);
            // Constantes kind-0: { def, índice, kind=0 } — lo que el runtime
            // lee (def@0, variant@8, kind@12). Para TODAS las variantes:
            // `Enum.Variant` es un valor del tipo enum incluso cuando la
            // variante lleva payload (el acceso pelón del VM). El objeto se
            // emite TAMBIÉN con sus slots de payload a cero del tamaño de la
            // variante: si un match con bindings cae sobre un valor kind-0
            // (el test sólo mira nombres), leer el payload da 0 en vez de
            // basura fuera del objeto.
            for (variants, 0..) |*vl, i| {
                const np: usize = vl.fields.len;
                const obj_ty = blk: {
                    var of: [4]c.LLVMTypeRef = undefined;
                    of[0] = self.t_ptr;
                    of[1] = self.t_i32;
                    of[2] = self.t_i32;
                    if (np > 0) {
                        of[3] = c.LLVMArrayType(self.t_i64, @intCast(np));
                        break :blk c.LLVMStructTypeInContext(self.ctx, &of, 4, 0);
                    }
                    break :blk c.LLVMStructTypeInContext(self.ctx, &of, 3, 0);
                };
                const cv = c.LLVMAddGlobal(self.mod, obj_ty, "");
                var ov: [4]c.LLVMValueRef = undefined;
                ov[0] = def;
                ov[1] = c.LLVMConstInt(self.t_i32, @intCast(i), 0);
                ov[2] = c.LLVMConstInt(self.t_i32, 0, 0);
                var n_init: c_uint = 3;
                if (np > 0) {
                    ov[3] = c.LLVMConstNull(c.LLVMArrayType(self.t_i64, @intCast(np)));
                    n_init = 4;
                }
                c.LLVMSetInitializer(cv, c.LLVMConstNamedStruct(obj_ty, &ov, n_init));
                c.LLVMSetLinkage(cv, c.LLVMPrivateLinkage);
                vl.unit_const = cv;
            }
            self.enums.put(ed.name, .{ .name = ed.name, .variants = variants, .def = def }) catch @panic("OOM");
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

test "emite match de Option: TAG_IS inline, bindings y backstop MATCH_NONE" {
    const parser = @import("../parser/parser.zig");
    const typechecker = @import("../typechecker/typechecker.zig");
    const src =
        \\fn half(x: i32?) -> i32? {
        \\    return match x {
        \\        some(v) if v > 0 => some(v / 2),
        \\        some(v) => some(v),
        \\        none => none,
        \\    }
        \\}
        \\fn main() {
        \\    print(half(some(8)))
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tree = ast.Tree.init(a, src);
    defer tree.deinit();
    var p = parser.Parser.init(a, src, &tree);
    p.filename = "match.astra";
    const root = p.parse() catch unreachable;
    var tc = try typechecker.TypeChecker.init(a, &tree, "match.astra");
    tc.check(root);
    try std.testing.expectEqual(@as(u32, 0), tc.error_count);

    var em = Emitter.init(a, &tree, "match.astra");
    defer em.deinit();
    em.emit(root);
    try std.testing.expectEqual(@as(u32, 0), em.error_count);

    var err: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.LLVMVerifyModule(em.mod, c.LLVMReturnStatusAction, &err));
    if (err != null) c.LLVMDisposeMessage(err);

    const ir = c.LLVMPrintModuleToString(em.mod);
    defer c.LLVMDisposeMessage(ir);
    const ir_str = std.mem.span(ir);
    // El backstop de los brazos refutables y la construcción de la caja.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "no match arm matched") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_llvm_wrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_llvm_print_boxed") != null);
}

test "emite ?: payload en ok/some y ret temprano del boxed en err/none" {
    const parser = @import("../parser/parser.zig");
    const typechecker = @import("../typechecker/typechecker.zig");
    const src =
        \\fn inc(x: i32?) -> i32? {
        \\    let v = x?
        \\    return some(v + 1)
        \\}
        \\fn main() {
        \\    print(inc(none))
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tree = ast.Tree.init(a, src);
    defer tree.deinit();
    var p = parser.Parser.init(a, src, &tree);
    p.filename = "try.astra";
    const root = p.parse() catch unreachable;
    var tc = try typechecker.TypeChecker.init(a, &tree, "try.astra");
    tc.check(root);
    try std.testing.expectEqual(@as(u32, 0), tc.error_count);

    var em = Emitter.init(a, &tree, "try.astra");
    defer em.deinit();
    em.emit(root);
    try std.testing.expectEqual(@as(u32, 0), em.error_count);

    var err: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.LLVMVerifyModule(em.mod, c.LLVMReturnStatusAction, &err));
    if (err != null) c.LLVMDisposeMessage(err);

    const ir_s = c.LLVMPrintModuleToString(em.mod);
    defer c.LLVMDisposeMessage(ir_s);
    const ir_str = std.mem.span(ir_s);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "try_err") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "try_ok") != null);
}

test "emite closure: objeto {code, env} por valor y env que sobrevive al frame" {
    const parser = @import("../parser/parser.zig");
    const typechecker = @import("../typechecker/typechecker.zig");
    const src =
        \\let mut saved = |x: i32| -> i32 { x }
        \\fn store() {
        \\    let base = 7
        \\    saved = |x: i32| -> i32 { x + base }
        \\}
        \\fn main() {
        \\    store()
        \\    print(saved(3))
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tree = ast.Tree.init(a, src);
    defer tree.deinit();
    var p = parser.Parser.init(a, src, &tree);
    p.filename = "closure.astra";
    const root = p.parse() catch unreachable;
    var tc = try typechecker.TypeChecker.init(a, &tree, "closure.astra");
    tc.check(root);
    try std.testing.expectEqual(@as(u32, 0), tc.error_count);

    var em = Emitter.init(a, &tree, "closure.astra");
    defer em.deinit();
    em.emit(root);
    try std.testing.expectEqual(@as(u32, 0), em.error_count);

    var err: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.LLVMVerifyModule(em.mod, c.LLVMReturnStatusAction, &err));
    if (err != null) c.LLVMDisposeMessage(err);

    const ir = c.LLVMPrintModuleToString(em.mod);
    defer c.LLVMDisposeMessage(ir);
    const ir_str = std.mem.span(ir);
    // Dos lambdas (el literal inicial y el de store) con su convención
    // uniforme (env, params…) y la llamada dinámica a través del objeto.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_lambda_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_lambda_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "define i64 @astra_lambda_1(ptr") != null);
}

test "emite arrays: objeto {len, elem_pty, elems} con bounds check y print" {
    const parser = @import("../parser/parser.zig");
    const typechecker = @import("../typechecker/typechecker.zig");
    const src =
        \\let xs = [1, 2, 3]
        \\fn main() {
        \\    let mut ys = [10, 20]
        \\    ys[0] = 9
        \\    print(ys[1])
        \\    print(xs[0])
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tree = ast.Tree.init(a, src);
    defer tree.deinit();
    var p = parser.Parser.init(a, src, &tree);
    p.filename = "arr.astra";
    const root = p.parse() catch unreachable;
    var tc = try typechecker.TypeChecker.init(a, &tree, "arr.astra");
    tc.check(root);
    try std.testing.expectEqual(@as(u32, 0), tc.error_count);

    var em = Emitter.init(a, &tree, "arr.astra");
    defer em.deinit();
    em.emit(root);
    try std.testing.expectEqual(@as(u32, 0), em.error_count);

    var err: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.LLVMVerifyModule(em.mod, c.LLVMReturnStatusAction, &err));
    if (err != null) c.LLVMDisposeMessage(err);

    const ir = c.LLVMPrintModuleToString(em.mod);
    defer c.LLVMDisposeMessage(ir);
    const ir_str = std.mem.span(ir);
    // Lectura y escritura con bounds check (arm idx_fail → index_fail), el
    // print dispatchando por elem_pty en runtime y el store del elemento.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "idx_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_llvm_index_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_llvm_print_array") != null);
}

test "emite structs: descriptor global, lectura/escritura de campo y print/eq en runtime" {
    const parser = @import("../parser/parser.zig");
    const typechecker = @import("../typechecker/typechecker.zig");
    const src =
        \\struct Punto {
        \\    x: i32
        \\    y: i32
        \\}
        \\fn main() {
        \\    let p = Punto { x: 3, y: 4 }
        \\    let mut q = p
        \\    q.y = 9
        \\    print(p)
        \\    print(p == q)
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tree = ast.Tree.init(a, src);
    defer tree.deinit();
    var p = parser.Parser.init(a, src, &tree);
    p.filename = "struct.astra";
    const root = p.parse() catch unreachable;
    var tc = try typechecker.TypeChecker.init(a, &tree, "struct.astra");
    tc.check(root);
    try std.testing.expectEqual(@as(u32, 0), tc.error_count);

    var em = Emitter.init(a, &tree, "struct.astra");
    defer em.deinit();
    em.emit(root);
    try std.testing.expectEqual(@as(u32, 0), em.error_count);

    var err: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.LLVMVerifyModule(em.mod, c.LLVMReturnStatusAction, &err));
    if (err != null) c.LLVMDisposeMessage(err);

    const ir = c.LLVMPrintModuleToString(em.mod);
    defer c.LLVMDisposeMessage(ir);
    const ir_str = std.mem.span(ir);
    // El descriptor constante con el nombre del struct (print/eq estructural
    // leen el def del propio objeto), el dispatch de print y la igualdad
    // estructural pasada por el truncado a i1.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "\"Punto") != null); // c"Punto\00"
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_llvm_print_struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_llvm_struct_eq") != null);
}

test "emite enums: descriptor + constantes kind-0, constructor y match con payload" {
    const parser = @import("../parser/parser.zig");
    const typechecker = @import("../typechecker/typechecker.zig");
    const src =
        \\enum Color {
        \\    Rojo
        \\    Verde(i32)
        \\}
        \\fn main() {
        \\    let c = Color.Rojo
        \\    let v = Verde(7)
        \\    match v {
        \\        Color.Verde(n) => print(n),
        \\        Color.Rojo => print("rojo"),
        \\    }
        \\    print(c == v)
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tree = ast.Tree.init(a, src);
    defer tree.deinit();
    var p = parser.Parser.init(a, src, &tree);
    p.filename = "enum.astra";
    const root = p.parse() catch unreachable;
    var tc = try typechecker.TypeChecker.init(a, &tree, "enum.astra");
    tc.check(root);
    try std.testing.expectEqual(@as(u32, 0), tc.error_count);

    var em = Emitter.init(a, &tree, "enum.astra");
    defer em.deinit();
    em.emit(root);
    try std.testing.expectEqual(@as(u32, 0), em.error_count);

    var err: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.LLVMVerifyModule(em.mod, c.LLVMReturnStatusAction, &err));
    if (err != null) c.LLVMDisposeMessage(err);

    const ir = c.LLVMPrintModuleToString(em.mod);
    defer c.LLVMDisposeMessage(ir);
    const ir_str = std.mem.span(ir);
    // Descriptor del enum (print/eq por def del objeto) y dispatch por
    // kind — la igualdad consciente de los dos kinds del VM.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "\"Color") != null); // c"Color\00"
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_llvm_print_enum") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "astra_llvm_enum_eq") != null);
}

test "emite for..in con break/continue: cond al frente e incremento en continue" {
    const parser = @import("../parser/parser.zig");
    const typechecker = @import("../typechecker/typechecker.zig");
    const src =
        \\fn main() {
        \\    let mut acc = 0
        \\    for i in 0..10 {
        \\        if i == 3 { continue }
        \\        if i > 7 { break }
        \\        acc = acc + i
        \\    }
        \\    let xs = [1, 2, 3]
        \\    for x in xs {
        \\        acc = acc + x
        \\    }
        \\    while acc < 0 { break }
        \\    print(acc)
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tree = ast.Tree.init(a, src);
    defer tree.deinit();
    var p = parser.Parser.init(a, src, &tree);
    p.filename = "loop.astra";
    const root = p.parse() catch unreachable;
    var tc = try typechecker.TypeChecker.init(a, &tree, "loop.astra");
    tc.check(root);
    try std.testing.expectEqual(@as(u32, 0), tc.error_count);

    var em = Emitter.init(a, &tree, "loop.astra");
    defer em.deinit();
    em.emit(root);
    try std.testing.expectEqual(@as(u32, 0), em.error_count);

    var err: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.LLVMVerifyModule(em.mod, c.LLVMReturnStatusAction, &err));
    if (err != null) c.LLVMDisposeMessage(err);

    const ir = c.LLVMPrintModuleToString(em.mod);
    defer c.LLVMDisposeMessage(ir);
    const ir_str = std.mem.span(ir);
    // Los bloques del for (cond al frente, incremento como objetivo de
    // continue, salida para break) y del while (cond como continue).
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "for_cond") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "for_next") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "for_exit") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "wh_cond") != null);
}
