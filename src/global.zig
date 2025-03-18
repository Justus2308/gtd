//! All global state is stored in this file.

const builtin = @import("builtin");
const std = @import("std");
const stdx = @import("stdx");
const options = @import("options");
const sokol = @import("sokol");

const fs = std.fs;

const assert = std.debug.assert;

pub const is_debug = (builtin.mode == .Debug);
pub const is_wasm = (builtin.target.cpu.arch.isWasm());

/// Call ASAP
pub fn init() !void {
    errdefer if (is_debug) {
        assert(debug_allocator.deinit() == .ok);
    };
    asset_dir = try fs.cwd().openDir(asset_path_rel, .{ .iterate = true });
    errdefer asset_dir.close();
    try asset_manager.discoverAssets(allocator);
    errdefer asset_manager.deinit(allocator);
}

pub fn deinit() void {
    defer if (is_debug) {
        assert(debug_allocator.deinit() == .ok);
    };
    asset_dir.close();
    asset_manager.deinit(allocator);
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

pub const asset_path_rel = if (builtin.is_test) "test/assets" else "assets";
pub var asset_dir: fs.Dir = undefined;

pub var asset_manager: stdx.Asset.Manager = .init(&asset_dir);
