//! `astraea` — la CLI unificada (DEC-021, implementación de la propuesta).
//!
//! Patrón Cargo: el *tool* tiene nombre propio (`astraea`), el lenguaje no.
//! La CLI es un **driver** que invoca al compilador `astra-zig` como
//! subproceso (igual que Cargo invoca a rustc): no compila nada por sí misma.
//!
//! Subcomandos (mínimo viable de DEC-021):
//!
//!   astraea run <file.astra>       compile y ejecute (astra-zig <file>)
//!   astraea build <file.astra>     --emit-obj + link con cc → binario nativo
//!                                  (requiere astra-zig construido con -Dllvm)
//!   astraea init [dir]             cree astraea.toml ([package] plantilla)
//!   astraea version | help
//!
//! El marcador de raíz del proyecto es `astraea.toml` (DEC-021: el rename
//! desde `astra.toml` llega de una vez con la CLI). El resolver de
//! `zig/src/modules/modules.zig` lo busca al subir desde el fichero de
//! entrada para anclar `@/…`.
const std = @import("std");
const Io = std.Io;

const usage =
    \\astraea — CLI unificada de Astra (DEC-021)
    \\
    \\Uso:
    \\  astraea run <file.astra> [args…]   compile y ejecute con astra-zig
    \\  astraea build <file.astra> [--out <name>]
    \\                                    emita objeto (--emit-obj, -Dllvm) y
    \\                                    enlace con cc → ./<name>
    \\  astraea init [dir]                cree un astraea.toml ([package])
    \\  astraea version                   versión
    \\  astraea help                      esta ayuda
    \\
;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("astraea: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Ruta absoluta del directorio propio (del ejecutable) — de ahí salen
/// `astra-zig` y el runtime instalados como hermanos. `/proc/self/exe`
/// (Linux; el tool es de este repo y su gate corre aquí).
fn selfDir(io: Io, buf: []u8) ![]const u8 {
    const n = try Io.Dir.readLinkAbsolute(io, "/proc/self/exe", buf);
    const exe = buf[0..n];
    return std.fs.path.dirname(exe) orelse return error.NoDir;
}

/// `astraea init [dir]` — crea `astraea.toml` con la plantilla [package].
fn cmdInit(io: Io, gpa: std.mem.Allocator, args: []const []const u8) !void {
    const dir = if (args.len > 0) args[0] else ".";
    const toml_path = try std.fs.path.join(gpa, &.{ dir, "astraea.toml" });
    defer gpa.free(toml_path);
    var file = Io.Dir.cwd().createFile(io, toml_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("astraea: {s} ya existe (no se pisa)\n", .{toml_path});
            std.process.exit(1);
        },
        else => return err,
    };
    defer file.close(io);
    try file.writePositionalAll(io,
        \\# astraea.toml — marcador de raíz del proyecto (DEC-021)
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\
    , 0);
    std.debug.print("creado {s}\n", .{toml_path});
}

/// Ejecuta el compilador como subproceso con los argumentos dados y sale
/// con su código de salida (la CLI no filtra ni traduce: la semántica de
/// error es la del compilador).
fn execCompiler(io: Io, gpa: std.mem.Allocator, compiler: []const u8, argv: []const []const u8) !void {
    _ = gpa;
    if (argv.len > 60) die("demasiados argumentos (max 60)", .{});
    var full: [61][]const u8 = undefined;
    full[0] = compiler;
    @memcpy(full[1..][0..argv.len], argv);
    var child = try std.process.spawn(io, .{ .argv = full[0 .. argv.len + 1] });
    const term = try child.wait(io);
    std.process.exit(switch (term) {
        .exited => |c| c,
        else => 1,
    });
}

/// `astraea build <file.astra> [--out name]` — `--emit-obj` + link con cc
/// contra el runtime LLVM (hermano `astraea_runtime.c` + `codegen_runtime.h`).
/// Requiere astra-zig construido con -Dllvm; si no lo está, el mensaje y el
/// exit son los del propio compilador (no se duplican).
fn cmdBuild(io: Io, gpa: std.mem.Allocator, compiler: []const u8, cc: []const u8, args: []const []const u8) !void {
    if (args.len == 0) die("build necesita un fichero .astra", .{});
    const src = args[0];
    var out_name: []const u8 = "a.out";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            i += 1;
            if (i >= args.len) die("--out necesita un nombre", .{});
            out_name = args[i];
        } else die("argumento desconocido para build: {s}", .{args[i]});
    }

    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const self = selfDir(io, &dir_buf) catch die("no se pudo resolver el directorio del ejecutable", .{});

    // --emit-obj <src> → <base>.o en la cwd.
    {
        const argv = [_][]const u8{ compiler, "--emit-obj", src };
        var child = try std.process.spawn(io, .{ .argv = &argv });
        const term = try child.wait(io);
        switch (term) {
            .exited => |c| if (c != 0) std.process.exit(c),
            else => std.process.exit(1),
        }
    }
    var obj_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = std.fs.path.basename(src);
    const stem = if (std.mem.endsWith(u8, base, ".astra")) base[0 .. base.len - ".astra".len] else base;
    const obj = try std.fmt.bufPrint(&obj_buf, "{s}.o", .{stem});

    // Runtime LLVM — hermano instalado junto al binario.
    const runtime_c = try std.fs.path.join(gpa, &.{ self, "astraea_runtime.c" });
    defer gpa.free(runtime_c);
    const runtime_o = "astraea_runtime.o";
    {
        const argv = [_][]const u8{ cc, "-c", "-O2", "-std=c11", "-I", self, runtime_c, "-o", runtime_o };
        var child = try std.process.spawn(io, .{ .argv = &argv });
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0)
            die("no se pudo compilar el runtime LLVM ({s} falta; `zig build` lo instala)", .{runtime_c});
    }
    {
        const argv = [_][]const u8{ cc, obj, runtime_o, "-o", out_name, "-lm" };
        var child = try std.process.spawn(io, .{ .argv = &argv });
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) die("el enlace falló", .{});
    }
    std.debug.print("astraea: {s} → ./{s}\n", .{ src, out_name });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const raw = try init.minimal.args.toSlice(init.arena.allocator());
    // raw[0] = argv0; el resto = argumentos de la CLI.
    const args = raw[1..];

    if (args.len == 0) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const cmd = args[0];

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        std.debug.print("astraea 0.1.0 (DEC-021) · driver de astra-zig\n", .{});
        return;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(io, gpa, args[1..]);
        return;
    }

    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const self = try selfDir(io, &dir_buf);
    const compiler = try std.fs.path.join(gpa, &.{ self, "astra-zig" });
    defer gpa.free(compiler);

    if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 2) die("run necesita un fichero .astra", .{});
        try execCompiler(io, gpa, compiler, args[1..]);
        return; // unreachable: execCompiler sale con el código del hijo
    }
    if (std.mem.eql(u8, cmd, "build")) {
        const cc = init.environ_map.get("CC") orelse "cc";
        try cmdBuild(io, gpa, compiler, cc, args[1..]);
        return;
    }
    die("comando desconocido '{s}' — pruebe `astraea help`", .{cmd});
}
