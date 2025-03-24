const std = @import("std");
const builtin = @import("builtin");
const sokol_bld = @import("sokol");

const log = std.log.scoped(.build);

const app_name = "GoonsTD";

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

const TargetCategory = enum {
    other,
    linux,
    macos,
    windows,
    android,
    ios,
    web,
};

const Packaging = enum {
    none,
    snap,
    macos_app,
    ios_app,
    msix,
    apk,
    emcc,
};

pub fn build(b: *std.Build) void {
    // Resolve compilation options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const host_os = b.graph.host.result.os.tag;
    const host_arch = b.graph.host.result.cpu.arch;

    const target_os = target.result.os.tag;
    const target_arch = target.result.cpu.arch;

    if (!switch (host_os) {
        .linux, .macos => switch (host_arch) {
            .x86_64, .aarch64 => true,
            else => false,
        },
        .windows => (host_arch == .x86_64),
        else => false,
    }) @panic("unsupported host");

    if (!switch (target_arch) {
        .wasm32 => (target_os == .emscripten),
        .wasm64 => false,
        else => true,
    }) @panic("unsupported target: use 'wasm32-emscripten' to target web");

    const target_category: TargetCategory = cat: {
        switch (target_os) {
            .linux => if (target.result.abi.isAndroid()) switch (target_arch) {
                .aarch64, .arm => break :cat .android,
                else => {},
            } else switch (target_arch) {
                .x86_64,
                .x86,
                .aarch64,
                .aarch64_be,
                .arm,
                .armeb,
                .powerpc64,
                .powerpc64le,
                .powerpc,
                => break :cat .linux,
                else => {},
            },
            .macos => switch (target_arch) {
                .x86_64, .aarch64 => break :cat .macos,
                else => {},
            },
            .windows => switch (target_arch) {
                .x86_64, .aarch64, .x86 => break :cat .windows,
                else => {},
            },
            .ios => if (target_arch == .aarch64) break :cat .ios,
            .emscripten => if (target_arch == .wasm32) break :cat .web,
            else => {},
        }
        log.warn(
            "building for potentially unstable target '{s}'",
            .{target.result.zigTriple(b.allocator) catch @panic("OOM")},
        );
        break :cat .other;
    };

    if (target_category == .android) {
        @panic("TODO: support android");
    }

    const packaging: Packaging = b.option(
        Packaging,
        "packaging",
        "Use a custom packaging format",
    ) orelse switch (target_category) {
        .linux => .snap,
        .macos => .macos_app,
        .windows => .msix,
        .android => .apk,
        .ios => .ios_app,
        .web => .emcc,
        .other => .none,
    };
    _ = packaging;

    const pack_assets = b.option(
        bool,
        "pack-assets",
        "Pack all assets together with the executable (default: true for web builds)",
    ) orelse (target_category == .web);

    if (pack_assets and target_category != .web) {
        log.info("asset packing is only supported for web targets at the moment", .{});
    }

    const shader_lang_hint = b.option(
        ShaderLanguage,
        "slang",
        "Use a custom shader language if possible",
    ) orelse .auto;
    const sokol_backend_hint: sokol_bld.SokolBackend = switch (shader_lang_hint) {
        .glsl410, .glsl430 => .gl,
        .glsl300es => .gles3,
        .wgsl => if (target_category == .web) .wgpu else .auto,
        else => .auto,
    };

    const runtime_options = b.addOptions();
    runtime_options.addOption(bool, "is_packed_assets", pack_assets);

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

    const hmm_dep = b.dependency("hmm", .{});
    const hmm_h_path = hmm_dep.path("HandmadeMath.h");
    const hmm_tc = b.addTranslateC(.{
        .root_source_file = hmm_h_path,
        .target = target,
        .optimize = optimize,
    });
    const hmm_mod = hmm_tc.createModule();
    hmm_mod.addCSourceFile(.{
        .file = hmm_h_path,
        .flags = &.{
            "-std=c11",
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
    const sokol_shdc_bin_subpath = std.mem.concat(b.allocator, u8, &.{ "bin/", switch (host_os) {
        .linux => "linux",
        .macos => "osx",
        .windows => "win32",
        else => unreachable,
    }, switch (host_arch) {
        .x86_64 => "",
        .aarch64 => "_arm64",
        else => unreachable,
    }, "/sokol-shdc", if (host_os == .windows) ".exe" else "" }) catch @panic("OOM");
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
    const shader_mod = b.createModule(.{
        .root_source_file = sokol_shdc_out,
        .optimize = optimize,
        .target = target,
    });
    shader_mod.addImport("sokol", sokol_mod);

    const dep_imports = [_]std.Build.Module.Import{
        .{ .name = "sokol", .module = sokol_mod },
        .{ .name = "stbi", .module = stbi_mod },
        .{ .name = "cgltf", .module = cgltf_mod },
        .{ .name = "shader", .module = shader_mod },
    };
    const internal_imports = [_]std.Build.Module.Import{
        createImport(b, "State", optimize, target),
        // createImport(b, "entities", optimize, target),
        // createImport(b, "game", optimize, target),
        createImport(b, "stdx", optimize, target),
        createImport(b, "geo", optimize, target),
    };
    crossAddImports(&dep_imports, &internal_imports);

    addImportTests(b, &internal_imports);

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
    exe_mod.addImport("hmm", hmm_mod);

    b.getInstallStep().dependOn(&sokol_shdc_cmd.step);

    const run_cmd = if (target_category == .web) blk: {
        const backend: WebBackend = switch (sokol_backend) {
            .gles3 => .webgl2,
            .wgpu => .webgpu,
            else => unreachable,
        };
        break :blk buildWebExe(b, exe_mod, backend, sokol_dep);
    } else buildNativeExe(b, exe_mod);

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
    exe_mod.addImport("hmm", hmm_mod);

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

fn addImports(
    module: *std.Build.Module,
    imports: []const std.Build.Module.Import,
) void {
    for (imports) |import| {
        module.addImport(import.name, import.module);
    }
}

fn crossAddImports(
    lhs: []const std.Build.Module.Import,
    rhs: []const std.Build.Module.Import,
) void {
    for (lhs) |limp| {
        addImports(limp.module, lhs);
        addImports(limp.module, rhs);
    }
    for (rhs) |rimp| {
        addImports(rimp.module, lhs);
        addImports(rimp.module, rhs);
    }
}

fn addImportTests(b: *std.Build, imports: []const std.Build.Module.Import) void {
    for (imports) |import| {
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

fn buildNativeExe(b: *std.Build, exe_mod: *std.Build.Module) *std.Build.Step.Run {
    const optimize = exe_mod.optimize.?;
    const target = exe_mod.resolved_target.?;

    const target_os = target.result.os.tag;
    const target_is_android = target.result.abi.isAndroid();
    const target_is_mobile = (target_is_android or target_os == .ios or target_os == .emscripten);
    const optimize_is_safe = (optimize == .Debug or optimize == .ReleaseSafe);

    const exe = b.addExecutable(.{
        .name = app_name,
        .root_module = exe_mod,
        .strip = ((optimize == .ReleaseSmall) or
            (!optimize_is_safe and target_is_mobile)),
        .single_threaded = false,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    return run_cmd;
}
const WebBackend = enum {
    webgl2,
    webgpu,
};
fn buildWebExe(
    b: *std.Build,
    exe_mod: *std.Build.Module,
    backend: WebBackend,
    sokol_dep: *std.Build.Dependency,
) *std.Build.Step.Run {
    const optimize = exe_mod.optimize.?;
    const target = exe_mod.resolved_target.?;

    const optimize_is_safe = (optimize == .Debug or optimize == .ReleaseSafe);

    const lib = b.addStaticLibrary(.{
        .name = app_name,
        .root_module = exe_mod,
        .strip = !optimize_is_safe,
        .single_threaded = false,
    });
    const emsdk = sokol_dep.builder.dependency("emsdk", .{});
    const link_step = sokol_bld.emLinkStep(b, .{
        .lib_main = lib,
        .target = target,
        .optimize = optimize,
        .emsdk = emsdk,
        .use_webgl2 = (backend == .webgl2),
        .use_webgpu = (backend == .webgpu),
        .use_emmalloc = true,
        .use_filesystem = true,
        .shell_file_path = sokol_dep.path("src/sokol/web/shell.html"),
    }) catch @panic("emscripten: creating link step failed");

    const run_cmd = sokol_bld.emRunStep(b, .{ .name = app_name, .emsdk = emsdk });
    run_cmd.step.dependOn(&link_step.step);

    return run_cmd;
}
