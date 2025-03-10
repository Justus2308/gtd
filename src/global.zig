//! All global state is stored in this file.

const builtin = @import("builtin");
const std = @import("std");
const options = @import("options");
const sokol = @import("sokol");

const fs = std.fs;

const assert = std.debug.assert;

pub const is_debug = (builtin.mode == .Debug);
pub const is_wasm = (builtin.target.cpu.arch.isWasm());

/// Call ASAP
pub fn init() void {
    asset_dir = if (options.asset_path) |absolute|
        fs.openDirAbsolute(absolute, .{ .iterate = true }) catch @panic("could not access asset directory")
    else switch (builtin.target.os.tag) {
        .emscripten => {},
        .ios => {},
        else => blk: {
            const asset_path = fs.getAppDataDir(allocator, "GoonsTD/assets") catch @panic("could not find app data directory");
            defer allocator.free(asset_path);
            break :blk fs.openDirAbsolute(asset_path, .{ .iterate = true }) catch @panic("could not access asset directory");
        },
    }
}

pub fn deinit() void {
    if (is_debug) {
        assert(debug_allocator.deinit() == .ok);
    }
}

var debug_allocator = if (is_debug) std.heap.DebugAllocator(.{ .thread_safe = true }).init else {};
pub const allocator = if (is_debug)
    debug_allocator.allocator()
else if (is_wasm)
    std.heap.wasm_allocator
else
    std.heap.smp_allocator;

pub var render_state = RenderState{};

const RenderState = struct {
    pass_action: sokol.gfx.PassAction = .{},
    pipeline: sokol.gfx.Pipeline = .{},
    bindings: sokol.gfx.Bindings = .{},
    buffers: Buffers = .{},
};

const Buffers = struct {};

pub var game_state = @import("game").State{};

pub var asset_dir: fs.Dir = undefined;
