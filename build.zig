const std = @import("std");


pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // const raylib_dep = b.dependency("raylib-zig", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const raylib_mod = raylib_dep.module("raylib"); // main raylib module
    // const raygui_mod = raylib_dep.module("raygui"); // raygui module
    // const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    // const sdl_dep = b.dependency("sdl-zig", .{
    //     .target = target,
    //     .optimize = .ReleaseFast,
    // });
    // const sdl_artifact = sdl_dep.artifact("SDL2");

    const imports = [_]std.Build.Module.Import{
        createImport(b, "entities", optimize, target),
        createImport(b, "game", optimize, target),
        createImport(b, "stdx", optimize, target),
        createImport(b, "geo", optimize, target),
        // createImport(b, "c", optimize, target),
    };
    addImportTests(b, &imports);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .imports = &imports,
    });
    const exe = b.addExecutable(.{
        .name = "gtd",
        .root_module = exe_mod,
    });

    // exe.linkLibrary(raylib_artifact);
    // exe.linkLibrary(sdl_artifact);


    // exe.root_module.addImport("raylib", raylib_mod);
    // exe.root_module.addImport("raygui", raygui_mod);

    b.installArtifact(exe);

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
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_unit_tests_mod,
    });

    // exe_unit_tests.linkLibrary(sdl_artifact);

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
    const source_path = b.path(b.fmt("src/{s}.zig", .{ name }));
    const module = b.createModule(.{
        .root_source_file = source_path,
        .optimize = optimize,
        .target = target
    });
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
        const test_name = b.fmt("test_{s}", .{ import.name });
        const module_test = b.addTest(.{
            .name = test_name,
            .root_module = import.module,
        });
        const run_module_test = b.addRunArtifact(module_test);

        const test_description = b.fmt("Run unit tests of module '{s}'", .{ import.name });
        const test_step = b.step(test_name, test_description);
        test_step.dependOn(&run_module_test.step);
    }
}
