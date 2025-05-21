const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_zig_zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });

    const qoi_mod = stbStyleModule(b, "qoi", "qoi.h", target, optimize, &.{
        "-std=c99",
        "-DQOI_IMPLEMENTATION",
        "-DQOI_NO_STDIO",
    });

    const stbi_mod = stbStyleModule(b, "stb", "stb_image.h", target, optimize, &.{
        "-std=c99",
        "-DSTB_IMAGE_IMPLEMENTATION",
        "-DSTBI_FAILURE_USERMSG",
        "-DSTBI_NO_STDIO",
    });

    const cgltf_mod = stbStyleModule(b, "cgltf", "cgltf.h", target, optimize, &.{
        "-std=c99",
        "-DCGLTF_IMPLEMENTATION",
    });

    const lz4hc_mod = lz4hc: {
        const dep = b.dependency("lz4", .{});
        const tc = b.addTranslateC(.{
            .root_source_file = dep.path("lib/lz4hc.h"),
            .target = target,
            .optimize = optimize,
        });
        const mod = tc.createModule();
        const lib_path = dep.path("lib");
        mod.addIncludePath(lib_path);
        mod.addCSourceFiles(.{
            .root = lib_path,
            .files = &.{
                "lz4.c",
                "lz4hc.c",
            },
            .flags = &.{
                "-std=c99",
            },
            .language = .c,
        });
        break :lz4hc mod;
    };

    // Only used to build a dictionary for lz4hc
    // https://github.com/facebook/zstd/blob/dev/lib/README.md
    const zdict_mod = zdict: {
        const dep = b.dependency("zstd", .{});
        const tc = b.addTranslateC(.{
            .root_source_file = dep.path("lib/zdict.h"),
            .target = target,
            .optimize = optimize,
        });
        const mod = tc.createModule();
        mod.addIncludePath(dep.path("lib/common"));
        mod.addIncludePath(dep.path("lib/compress"));
        mod.addIncludePath(dep.path("lib/dictBuilder"));
        mod.addCSourceFiles(.{
            .root = dep.path("lib"),
            .files = &.{
                "common/debug.c",
                "common/entropy_common.c",
                "common/error_private.c",
                "common/fse_decompress.c",
                "common/pool.c",
                "common/threading.c",
                "common/xxhash.c",
                "common/zstd_common.c",

                "compress/fse_compress.c",
                "compress/hist.c",
                "compress/huf_compress.c",
                "compress/zstd_compress.c",
                "compress/zstd_compress_literals.c",
                "compress/zstd_compress_sequences.c",
                "compress/zstd_compress_superblock.c",
                "compress/zstd_double_fast.c",
                "compress/zstd_fast.c",
                "compress/zstd_lazy.c",
                "compress/zstd_ldm.c",
                "compress/zstd_opt.c",
                "compress/zstd_preSplit.c",
                "compress/zstdmt_compress.c",

                "dictBuilder/cover.c",
                "dictBuilder/divsufsort.c",
                "dictBuilder/fastcover.c",
                "dictBuilder/zdict.c",
            },
            .flags = &.{
                "-std=c99",
            },
            .language = .c,
        });
        break :zdict mod;
    };

    const midas_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    midas_mod.addImport("build.zig.zon", build_zig_zon_mod);
    midas_mod.addImport("qoi", qoi_mod);
    midas_mod.addImport("stbi", stbi_mod);
    midas_mod.addImport("cgltf", cgltf_mod);
    midas_mod.addImport("lz4hc", lz4hc_mod);
    midas_mod.addImport("zdict", zdict_mod);

    const midas_exe = b.addExecutable(.{
        .name = "midas",
        .root_module = midas_mod,
    });
    b.installArtifact(midas_exe);

    const run_cmd = b.addRunArtifact(midas_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const midas_unit_tests = b.addTest(.{
        .root_module = midas_mod,
    });

    const run_midas_unit_tests = b.addRunArtifact(midas_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_midas_unit_tests.step);
}

fn stbStyleModule(
    b: *std.Build,
    dependency_name: []const u8,
    header_subpath: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flags: []const []const u8,
) *std.Build.Module {
    const dep = b.dependency(dependency_name, .{});
    const h_path = dep.path(header_subpath);
    const tc = b.addTranslateC(.{
        .root_source_file = h_path,
        .target = target,
        .optimize = optimize,
    });
    const mod = tc.createModule();
    mod.addCSourceFile(.{
        .file = h_path,
        .flags = flags,
        .language = .c,
    });
    return mod;
}
