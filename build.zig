const std = @import("std");
const builtin = @import("builtin");
const sokol_bld = @import("sokol");

const app_name = "GoonsTD";

const host_os = builtin.os.tag;
const host_arch = builtin.cpu.arch;

const ShaderLanguage = enum {
    auto,
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
    // Resolve compilation options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_os = target.result.os.tag;
    const target_arch = target.result.cpu.arch;
    const target_is_android = target.result.abi.isAndroid();
    const target_is_mobile = (target_is_android or target_os == .ios or target_os == .emscripten);

    const optimize_is_safe = (optimize == .Debug or optimize == .ReleaseSafe);

    if (target_is_android) {
        @panic("TODO: support android");
    }
    if (target_os == .emscripten) {
        @panic("TODO: support web");
    }
    switch (target_os) {
        .windows, .macos, .linux, .ios, .emscripten => {},
        else => @panic("unsupported target OS"),
    }
    if (switch (target_arch) {
        .x86_64 => (target_os != .linux and target_os != .macos and target_os != .windows),
        .aarch64 => (target_os == .emscripten),
        .wasm64 => (target_os != .emscripten),
        else => true,
    }) @panic("unsupported target");

    const data_path_abs: []const u8 = b.option([]const u8, "data-path", "Absolute path to the desired game data directory") orelse
        std.fs.getAppDataDir(b.allocator, "GoonsTD") catch @panic("Cannot find default application data directory");

    const shader_lang_hint = b.option(ShaderLanguage, "slang", "Use a custom shader language if possible") orelse .auto;
    const sokol_backend_hint: sokol_bld.SokolBackend = switch (shader_lang_hint) {
        .glsl410, .glsl430 => .gl,
        .glsl300es => .gles3,
        .wgsl => if (sokol_bld.isPlatform(target.result, .web)) .wgpu else .auto,
        else => .auto,
    };

    const runtime_options = b.addOptions();
    runtime_options.addOption([]const u8, "data_path", data_path_abs);

    // Configure dependencies
    const stb_dep = b.dependency("stb", .{});
    const stbi_h_path = stb_dep.path("stb_image.h");
    const stbi_tc = b.addTranslateC(.{
        .root_source_file = stbi_h_path,
        .target = target,
        .optimize = optimize,
    });
    stbi_tc.defineCMacro("STBI_ONLY_PNG", null);
    const stbi_mod = stbi_tc.createModule();
    stbi_mod.addCSourceFile(.{
        .file = stbi_h_path,
        .flags = &.{
            "-std=c11",
            "-DSTB_IMAGE_IMPLEMENTATION",
            "-DSTBI_ONLY_PNG",
        },
        .language = .c,
    });

    const cgltf_dep = b.dependency("cgltf", .{});
    const cgltf_h_path = cgltf_dep.path("cgltf.h");
    const cgltf_tc = b.addTranslateC(.{
        .root_source_file = cgltf_h_path,
        .target = target,
        .optimize = optimize,
    });
    const cgltf_mod = cgltf_tc.createModule();
    cgltf_mod.addCSourceFile(.{
        .file = cgltf_h_path,
        .flags = &.{
            "-std=c11",
            "-DCGLTF_IMPLEMENTATION",
        },
        .language = .c,
    });

    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,

        .gl = (sokol_backend_hint == .gl),
        .gles3 = (sokol_backend_hint == .gles3),
        .wgpu = (sokol_backend_hint == .wgpu),
    });
    const sokol_mod = sokol_dep.module("sokol");

    const sokol_tools_bin_dep = b.dependency("sokol_tools_bin", .{});
    const sokol_shdc_bin_subpath = "bin/" ++ switch (host_os) {
        .linux => "linux",
        .macos => "osx",
        .windows => "win32",
        else => @compileError("unsupported host OS"),
    } ++ switch (host_arch) {
        .x86_64 => "",
        .aarch64 => if (host_os == .windows)
            @compileError("unsupported host arch")
        else
            "_arm64",
        else => @compileError("unsupported host arch"),
    } ++ "/sokol-shdc" ++ if (host_os == .windows) ".exe" else "";
    const sokol_shdc_bin_path = sokol_tools_bin_dep.path(sokol_shdc_bin_subpath);

    // Compile shader
    const sokol_backend = sokol_bld.resolveSokolBackend(sokol_backend_hint, target.result);
    const shader_lang: ShaderLanguage = switch (sokol_backend) {
        .metal => switch (shader_lang_hint) {
            .metal_macos, .metal_ios, .metal_sim => |lang| lang,
            else => if (target_os == .macos) .metal_macos else .metal_ios,
        },
        .d3d11 => switch (shader_lang_hint) {
            .hlsl4, .hlsl5 => |lang| lang,
            else => .hlsl5,
        },
        .gles3 => .glsl300es,
        .wgpu => .wgsl,
        .gl => switch (shader_lang_hint) {
            .glsl410, .glsl430 => |lang| lang,
            else => .glsl430,
        },
        else => unreachable,
    };

    const sokol_shdc_cmd = std.Build.Step.Run.create(b, "sokol-shdc");
    sokol_shdc_cmd.addFileArg(sokol_shdc_bin_path);
    sokol_shdc_cmd.addPrefixedFileArg("--input=", b.path("src/render/shader.glsl"));
    const sokol_shdc_out = sokol_shdc_cmd.addPrefixedOutputFileArg("--output=", "shader.zig");
    sokol_shdc_cmd.addArgs(&.{ b.fmt("--slang={s}", .{@tagName(shader_lang)}), "--format=sokol_zig" });

    const sokol_shdc_install_file = b.addInstallFile(
        sokol_shdc_out,
        b.pathJoin(&.{ "gen", @tagName(shader_lang), "shader.zig" }),
    );

    const sokol_shdc_step = b.step("sokol-shdc", "Compile shader to Zig code");
    sokol_shdc_step.dependOn(&sokol_shdc_cmd.step);
    sokol_shdc_step.dependOn(&sokol_shdc_install_file.step);

    // Install game data
    // const data_dir = std.fs.openDirAbsolute(data_path_abs, .{}) catch
    //     @panic("cannot open data directory");
    // defer data_dir.close();

    // Declare modules and artifacts
    const internal_imports = [_]std.Build.Module.Import{
        createImport(b, "entities", optimize, target),
        createImport(b, "game", optimize, target),
        createImport(b, "stdx", optimize, target),
        createImport(b, "geo", optimize, target),
        createImport(b, "global", optimize, target),
    };
    addImportTests(b, &internal_imports);

    const shader_mod = b.createModule(.{
        .root_source_file = sokol_shdc_out,
        .optimize = optimize,
        .target = target,
    });
    shader_mod.addImport("sokol", sokol_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .imports = &internal_imports,
    });
    exe_mod.addOptions("options", runtime_options);
    exe_mod.addImport("stbi", stbi_mod);
    exe_mod.addImport("cgltf", cgltf_mod);
    exe_mod.addImport("sokol", sokol_mod);
    exe_mod.addImport("shader", shader_mod);

    const exe = b.addExecutable(.{
        .name = app_name,
        .root_module = exe_mod,
        .strip = ((optimize == .ReleaseSmall) or
            (!optimize_is_safe and target_is_mobile)),
        .single_threaded = false,
    });

    b.installArtifact(exe);
    b.getInstallStep().dependOn(&sokol_shdc_cmd.step);

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
        .imports = &internal_imports,
    });
    exe_unit_tests_mod.addImport("stbi", stbi_mod);
    exe_unit_tests_mod.addImport("cgltf", cgltf_mod);
    exe_unit_tests_mod.addImport("sokol", sokol_mod);
    exe_unit_tests_mod.addImport("shader", shader_mod);

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
        const test_name = b.fmt("test-{s}", .{import.name});
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
