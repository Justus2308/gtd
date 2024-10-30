const std = @import("std");


pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib-zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_mod = raylib_dep.module("raylib"); // main raylib module
    const raygui_mod = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    // const sdl_dep = b.dependency("sdl-zig", .{
    //     .target = target,
    //     .optimize = .ReleaseFast,
    // });
    // const sdl_artifact = sdl_dep.artifact("SDL2");

    const entities_mod = b.createModule(.{
        .root_source_file = b.path("src/entities.zig"),
    });
    const game_mod = b.createModule(.{
        .root_source_file = b.path("src/game.zig"),
    });
    const stdx_mod = b.createModule(.{
        .root_source_file = b.path("src/stdx.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "gtd",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibrary(raylib_artifact);   
    // exe.linkLibrary(sdl_artifact);


    exe.root_module.addImport("raylib", raylib_mod);
    exe.root_module.addImport("raygui", raygui_mod);

    exe.root_module.addImport("entities", entities_mod);
    exe.root_module.addImport("game", game_mod);
    exe.root_module.addImport("stdx", stdx_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const memory_pool_benchmark = b.addExecutable(.{
        .name = "memory_pool_benchmark",
        .root_source_file = b.path("tools/memory_pool_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    memory_pool_benchmark.root_module.addImport("stdx", stdx_mod);

    const memory_pool_benchmark_install = b.addInstallArtifact(memory_pool_benchmark, .{});

    const memory_pool_benchmark_cmd = b.addRunArtifact(memory_pool_benchmark);
    memory_pool_benchmark_cmd.step.dependOn(&memory_pool_benchmark_install.step);

    const memory_pool_benchmark_step = b.step("benchmark-mem-pool", "Run memory pool benchmark");
    memory_pool_benchmark_step.dependOn(&memory_pool_benchmark_cmd.step);
}
