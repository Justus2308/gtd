const std = @import("std");
const builtin = @import("builtin");
const sokol_bld = @import("sokol");

const assert = std.debug.assert;
const log = std.log.scoped(.build);

const app_name = "GoonsTD";

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

    const target_category: TargetCategory = category: {
        switch (target_os) {
            .linux => if (target.result.abi.isAndroid()) switch (target_arch) {
                .aarch64, .arm => break :category .android,
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
                => break :category .linux,
                else => {},
            },
            .macos => switch (target_arch) {
                .x86_64, .aarch64 => break :category .macos,
                else => {},
            },
            .windows => switch (target_arch) {
                .x86_64, .aarch64, .x86 => break :category .windows,
                else => {},
            },
            .ios => if (target_arch == .aarch64) break :category .ios,
            .emscripten => if (target_arch == .wasm32) break :category .web,
            else => {},
        }
        log.warn(
            "building for potentially unstable target '{s}'",
            .{target.result.linuxTriple(b.allocator) catch @panic("OOM")},
        );
        break :category .other;
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

    const is_pack_assets = b.option(
        bool,
        "pack-assets",
        "Pack all assets together with the executable (default: true for web builds)",
    ) orelse (target_category == .web);

    if (is_pack_assets and target_category != .web) {
        log.info("asset packing is only supported for web targets at the moment", .{});
    }

    const shader_lang_hint = b.option(
        ShaderLanguage,
        "slang",
        "Use a custom shader language if possible",
    );
    const sokol_backend_hint: sokol_bld.SokolBackend = if (shader_lang_hint) |hint| switch (hint) {
        .glsl410, .glsl430 => .gl,
        .glsl300es => .gles3,
        .wgsl => if (target_category == .web) .wgpu else .auto,
        else => .auto,
    } else .auto;
    const sokol_backend = sokol_bld.resolveSokolBackend(sokol_backend_hint, target.result);

    const shader_lang: ShaderLanguage = switch (sokol_backend) {
        .metal => metal: {
            if (shader_lang_hint) |hint| switch (hint) {
                .metal_macos, .metal_ios, .metal_sim => |lang| break :metal lang,
                else => {},
            };
            break :metal switch (target_category) {
                .macos => .metal_macos,
                .ios => .metal_ios,
                else => .metal_sim,
            };
        },
        .d3d11 => d3d11: {
            if (shader_lang_hint) |hint| switch (hint) {
                .hlsl4, .hlsl5 => |lang| break :d3d11 lang,
                else => {},
            };
            break :d3d11 .hlsl5;
        },
        .gles3 => .glsl300es,
        .wgpu => .wgsl,
        .gl => gl: {
            if (shader_lang_hint) |hint| switch (hint) {
                .glsl410, .glsl430 => |lang| break :gl lang,
                else => {},
            };
            break :gl .glsl430;
        },
        else => unreachable,
    };

    const is_use_compute_hint =
        b.option(bool, "use-compute", "Make use of compute shaders if possible (default: true)") orelse true;
    const is_use_compute = (is_use_compute_hint and switch (target_category) {
        .macos, .ios => (sokol_backend == .metal),
        .windows => (sokol_backend == .d3d11 or sokol_backend == .gl),
        .linux => (sokol_backend == .gl),
        .web => (sokol_backend == .wgpu),
        .android, .other => false,
    });

    if (b.verbose) log.info("target={s}, optimize={s}, packaging={s}, pack-assets={s}, slang={s}, use-compute={s}", .{
        target.result.linuxTriple(b.allocator) catch @panic("OOM"),
        @tagName(optimize),
        @tagName(packaging),
        fmtBool(is_pack_assets),
        @tagName(shader_lang),
        fmtBool(is_use_compute),
    });

    const runtime_options = b.addOptions();
    runtime_options.addOption(bool, "is_packed_assets", is_pack_assets);
    runtime_options.addOption(bool, "is_use_compute", is_use_compute);

    // Configure dependencies
    const zmesh_dep = b.dependency("zmesh", .{
        .target = target,
        .optimize = optimize,
    });
    const zmesh_mod = zmesh_dep.module("root");

    const qoi_dep = b.dependency("qoi", .{
        .target = target,
        .optimize = optimize,
    });
    const qoi_mod = qoi_dep.module("qoi");

    const s2s_dep = b.dependency("s2s", .{
        .target = target,
        .optimize = optimize,
    });
    const s2s_mod = s2s_dep.module("s2s");

    const zalgebra_dep = b.dependency("zalgebra", .{
        .target = target,
        .optimize = optimize,
    });
    const zalgebra_mod = zalgebra_dep.module("zalgebra");

    const domath_dep = b.dependency("domath", .{
        .target = target,
        .optimize = optimize,
    });
    const domath_mod = domath_dep.module("domath");

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
    const sokol_shdc_cmd = std.Build.Step.Run.create(b, "sokol-shdc");
    sokol_shdc_cmd.addFileArg(sokol_shdc_bin_path);
    sokol_shdc_cmd.addPrefixedFileArg("--input=", b.path("src/render/shaders/shader.glsl"));
    const sokol_shdc_out = sokol_shdc_cmd.addPrefixedOutputFileArg("--output=", "shader.zig");
    sokol_shdc_cmd.addArgs(&.{ b.fmt("--slang={s}", .{@tagName(shader_lang)}), "--format=sokol_zig" });

    const sokol_shdc_install_file = b.addInstallFile(
        sokol_shdc_out,
        b.pathJoin(&.{ "gen", @tagName(shader_lang), "shader.zig" }),
    );

    const sokol_shdc_step = b.step("shdc", "Compile shader to Zig code");
    sokol_shdc_step.dependOn(&sokol_shdc_cmd.step);
    sokol_shdc_step.dependOn(&sokol_shdc_install_file.step);

    // Declare modules and artifacts
    const shader_mod = b.createModule(.{
        .root_source_file = sokol_shdc_out,
        .optimize = optimize,
        .target = target,
    });
    shader_mod.addImport("sokol", sokol_mod);

    const internal_imports = [_]std.Build.Module.Import{
        createImport(b, "game", optimize, target),
        createImport(b, "render", optimize, target),
        createImport(b, "resource", optimize, target),
        createImport(b, "stdx", optimize, target),
    };
    const external_imports = [_]std.Build.Module.Import{
        .{ .name = "sokol", .module = sokol_mod },
        .{ .name = "qoi", .module = qoi_mod },
        .{ .name = "zmesh", .module = zmesh_mod },
        .{ .name = "s2s", .module = s2s_mod },
        .{ .name = "zalgebra", .module = zalgebra_mod },
        .{ .name = "domath", .module = domath_mod },
        .{ .name = "shader", .module = shader_mod },
    };
    addAllImports(&internal_imports, &external_imports);
    addImportTests(b, &internal_imports);

    const imports = std.mem.concat(
        b.allocator,
        std.Build.Module.Import,
        &.{ &internal_imports, &external_imports },
    ) catch @panic("OOM");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .imports = imports,
    });
    exe_mod.addOptions("options", runtime_options);

    b.getInstallStep().dependOn(&sokol_shdc_cmd.step);

    const run_cmd, const compile_check = if (target_category == .web) blk: {
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

    const check_step = b.step("check", "Check if the app compiles");
    check_step.dependOn(&compile_check.step);
    check_step.dependOn(&sokol_shdc_cmd.step);

    const exe_unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });

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
fn addAllImports(
    internal: []const std.Build.Module.Import,
    external: []const std.Build.Module.Import,
) void {
    for (internal) |import| {
        addImports(import.module, internal);
        addImports(import.module, external);
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

fn buildNativeExe(
    b: *std.Build,
    exe_mod: *std.Build.Module,
) struct { *std.Build.Step.Run, *std.Build.Step.Compile } {
    const optimize = exe_mod.optimize.?;
    const target = exe_mod.resolved_target.?;

    const target_os = target.result.os.tag;
    const is_android = target.result.abi.isAndroid();
    const is_mobile = (is_android or target_os == .ios or target_os == .emscripten);
    const is_safe = (optimize == .Debug or optimize == .ReleaseSafe);

    const exe_opts = std.Build.ExecutableOptions{
        .name = app_name,
        .root_module = exe_mod,
        .strip = ((optimize == .ReleaseSmall) or
            (!is_safe and is_mobile)),
        .single_threaded = false,
    };

    const exe = b.addExecutable(exe_opts);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const exe_check = b.addExecutable(exe_opts);

    return .{ run_cmd, exe_check };
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
) struct { *std.Build.Step.Run, *std.Build.Step.Compile } {
    const optimize = exe_mod.optimize.?;
    const target = exe_mod.resolved_target.?;

    const is_safe = (optimize == .Debug or optimize == .ReleaseSafe);

    const lib_opts = std.Build.StaticLibraryOptions{
        .name = app_name,
        .root_module = exe_mod,
        .strip = !is_safe,
        .single_threaded = false,
    };

    const lib = b.addStaticLibrary(lib_opts);
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

    const lib_check = b.addStaticLibrary(lib_opts);

    return .{ run_cmd, lib_check };
}

fn fmtBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}
