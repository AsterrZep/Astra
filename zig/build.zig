const std = @import("std");

/// Rango de versiones LLVM soportadas por el backend (LLVM_BACKEND_PLAN.md §2:
/// suelo 19 = el de CI y el verificado en la máquina, techo 23 = latest).
const llvm_min_major: u32 = 19;
const llvm_max_major: u32 = 23;

const LlvmInfo = struct {
    /// Ruta o nombre del llvm-config usado (para el mensaje de diagnóstico).
    config: []const u8,
    /// Versión completa reportada por `llvm-config --version` (p. ej. "19.1.7").
    version: []const u8,
};

/// Descubre LLVM para el backend opt-in (§2.3 del plan, patrón Odin).
///
/// Orden: `ASTRA_LLVM_CONFIG` (explícito → si falla, fatal, sin fallback
/// silencioso) → `llvm-config` del PATH → los nombres versionados que usan
/// Debian/Ubuntu/apt.llvm.org (`llvm-config-19` … `llvm-config-23`).
/// Toda versión fuera del rango soportado es un error accionable, no un
/// fallback: un build "a medias" con la versión equivocada cuesta horas.
fn discoverLlvm(b: *std.Build) LlvmInfo {
    if (b.graph.environ_map.get("ASTRA_LLVM_CONFIG")) |cfg| {
        return probeLlvmConfig(b, cfg) orelse std.process.fatal(
            "ASTRA_LLVM_CONFIG={s} pero `{s} --version` falló: " ++
                "la ruta debe apuntar a un llvm-config ejecutable",
            .{ cfg, cfg },
        );
    }
    const candidates = [_][]const u8{
        "llvm-config",
        "llvm-config-19",
        "llvm-config-20",
        "llvm-config-21",
        "llvm-config-22",
        "llvm-config-23",
    };
    for (candidates) |cfg| {
        if (probeLlvmConfig(b, cfg)) |info| return info;
    }
    std.process.fatal(
        "no se encontró llvm-config (probados: ASTRA_LLVM_CONFIG, llvm-config, llvm-config-19..-23). " ++
            "Instala LLVM {d}..{d} (p. ej. `apt install llvm-19-dev` o https://apt.llvm.org) " ++
            "o define ASTRA_LLVM_CONFIG=/ruta/a/llvm-config",
        .{ llvm_min_major, llvm_max_major },
    );
}

/// Ejecuta `<config> --version` y valida el rango. Devuelve null si el binario
/// no existe o no es un llvm-config; fatal si existe pero la versión no está
/// soportada (error explícito > fallback silencioso).
fn probeLlvmConfig(b: *std.Build, config: []const u8) ?LlvmInfo {
    var code: u8 = undefined;
    const stdout = b.runAllowFail(&.{ config, "--version" }, &code, .ignore) catch return null;
    const version = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    var it = std.mem.splitScalar(u8, version, '.');
    const major_s = it.next() orelse return null;
    const major = std.fmt.parseInt(u32, major_s, 10) catch return null;
    if (major < llvm_min_major or major > llvm_max_major) {
        std.process.fatal(
            "{s} reporta LLVM {s}, fuera del rango soportado {d}..{d}",
            .{ config, version, llvm_min_major, llvm_max_major },
        );
    }
    return .{ .config = b.dupe(config), .version = b.dupe(version) };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Backend LLVM (opt-in, LLVM_BACKEND_PLAN.md M0) ──
    // Sin -Dllvm el build es idéntico al anterior: ni probe de llvm-config ni
    // dependencias nuevas. El descubrimiento solo ocurre bajo demanda.
    const llvm_enabled = b.option(
        bool,
        "llvm",
        "Enable the LLVM backend (requires LLVM 19..23 discovered via llvm-config)",
    ) orelse false;
    if (llvm_enabled) {
        const info = discoverLlvm(b);
        std.debug.print("llvm: usando LLVM {s} ({s})\n", .{ info.version, info.config });
    }

    // ── Astra compiler executable ──
    const exe = b.addExecutable(.{
        .name = "astra-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // ── Run command ──
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Astra compiler");
    run_step.dependOn(&run_cmd.step);

    // ── Unit tests ──
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = unit_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
