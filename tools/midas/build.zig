const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_zig_zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });

    const qoi_dep = b.dependency("qoi", .{});
    const qoi_h_path = qoi_dep.path("qoi.h");
    const qoi_tc = b.addTranslateC(.{
        .root_source_file = qoi_h_path,
        .target = target,
        .optimize = optimize,
    });
    const qoi_mod = qoi_tc.createModule();
    qoi_mod.addCSourceFile(.{
        .file = qoi_h_path,
        .flags = &.{ "-std=c99", "-DQOI_IMPLEMENTATION" },
        .language = .c,
    });

    const stb_dep = b.dependency("stb", .{});
    const stbi_h_path = stb_dep.path("stb_image.h");
    const stbi_tc = b.addTranslateC(.{
        .root_source_file = stbi_h_path,
        .target = target,
        .optimize = optimize,
    });
    const stbi_mod = stbi_tc.createModule();
    stbi_mod.addCSourceFile(.{
        .file = stbi_h_path,
        .flags = &.{ "-std=c99", "-DSTB_IMAGE_IMPLEMENTATION" },
        .language = .c,
    });

    const zmesh_dep = b.dependency("zmesh", .{
        .target = target,
        .optimize = optimize,
    });
    const zmesh_mod = zmesh_dep.module("root");
    const zmesh_lib = zmesh_dep.artifact("zmesh");

    const midas_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    midas_mod.addImport("build.zig.zon", build_zig_zon_mod);
    midas_mod.addImport("qoi", qoi_mod);
    midas_mod.addImport("stbi", stbi_mod);
    midas_mod.addImport("zmesh", zmesh_mod);
    midas_mod.linkLibrary(zmesh_lib);

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
