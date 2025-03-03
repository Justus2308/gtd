const std = @import("std");
const builtin = @import("builtin");

const ShaderLanguage = enum {
    glsl410,
    glsl430,
    glsl300es,
    hlsl4,
    hlsl5,
    metal_macos,
    metal_ios,
    metal_sim,
    wgsl,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,

        // ensure `sokol_backend = .auto`
        .gl = false,
        .gles3 = false,
        .wgpu = false,
    });
    const sokol_mod = sokol_dep.module("sokol");

    // const sokol_tools_dep = b.dependency("sokol_tools", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const sokol_shdc_exe = sokol_tools_dep.artifact("sokol-shdc");

    const sokol_tools_bin_dep = b.dependency("sokol_tools_bin", .{});
    const sokol_shdc_bin_subpath = "bin/" ++ switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "osx",
        .windows => "win32",
        else => @compileError("unsupported host OS"),
    } ++ switch (builtin.cpu.arch) {
        .x86_64 => "",
        .aarch64 => if (builtin.os.tag == .windows) @compileError("unsupported host arch") else "_arm64",
        else => @compileError("unsupported host arch"),
    } ++ "/sokol-shdc" ++ if (builtin.os.tag == .windows) ".exe" else "";
    const sokol_shdc_bin_path = sokol_tools_bin_dep.path(sokol_shdc_bin_subpath);

    // const shader_lang: ShaderLanguage =
    //     b.option(ShaderLanguage, "slang", "Choose a custom shader language/GPU API") orelse
    //     if (target.result.cpu.arch.isWasm())
    //         .glsl300es
    //     else switch (target.result.os.tag) {
    //         .macos => .metal_macos,
    //         .ios => .metal_ios,
    //         .windows => .hlsl5,
    //         else => .glsl430, // TODO ???
    //     };
    const sokol_backend = @import("sokol").resolveSokolBackend(.auto, target.result);
    const shader_lang: ShaderLanguage = switch (sokol_backend) {
        .auto => unreachable,
        .metal => if (target.result.os.tag == .macos) .metal_macos else .metal_ios,
        .d3d11 => .hlsl5,
        .gles3 => .glsl300es,
        else => .glsl430,
    };

    // const sokol_shdc_step = b.addRunArtifact(sokol_shdc_exe);
    const sokol_shdc_step = std.Build.Step.Run.create(b, "run sokol shdc");
    sokol_shdc_step.addFileArg(sokol_shdc_bin_path);
    sokol_shdc_step.addPrefixedFileArg("--input=", b.path("src/render/shader.glsl"));
    const sokol_shdc_out = sokol_shdc_step.addPrefixedOutputFileArg("--output=", "shader.zig");
    sokol_shdc_step.addArgs(&.{ b.fmt("--slang={s}", .{@tagName(shader_lang)}), "--format=sokol_zig" });

    const imports = [_]std.Build.Module.Import{
        createImport(b, "entities", optimize, target),
        createImport(b, "game", optimize, target),
        createImport(b, "stdx", optimize, target),
        createImport(b, "geo", optimize, target),
    };
    addImportTests(b, &imports);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .imports = &imports,
    });
    exe_mod.addImport("sokol", sokol_mod);
    exe_mod.addAnonymousImport("shader", .{ .root_source_file = sokol_shdc_out });

    const exe = b.addExecutable(.{
        .name = "gtd",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);
    b.getInstallStep().dependOn(&sokol_shdc_step.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    exe_unit_tests_mod.addImport("sokol", sokol_mod);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_unit_tests_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn createImport(
    b: *std.Build,
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) std.Build.Module.Import {
    const source_path = b.path(b.fmt("src/{s}.zig", .{name}));
    const module = b.createModule(.{ .root_source_file = source_path, .optimize = optimize, .target = target });
    const import = std.Build.Module.Import{
        .name = b.dupe(name),
        .module = module,
    };
    return import;
}

fn addImportTests(b: *std.Build, imports: []const std.Build.Module.Import) void {
    for (imports) |import| {
        for (imports) |imp| {
            import.module.addImport(imp.name, imp.module);
        }
        const test_name = b.fmt("test_{s}", .{import.name});
        const module_test = b.addTest(.{
            .name = test_name,
            .root_module = import.module,
        });
        const run_module_test = b.addRunArtifact(module_test);

        const test_description = b.fmt("Run unit tests of module '{s}'", .{import.name});
        const test_step = b.step(test_name, test_description);
        test_step.dependOn(&run_module_test.step);
    }
}
