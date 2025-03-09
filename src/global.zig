//! All global state is stored in this file.

const builtin = @import("builtin");
const std = @import("std");
const sokol = @import("sokol");

const assert = std.debug.assert;

pub const is_debug = (builtin.mode == .Debug);
pub const is_wasm = (builtin.target.cpu.arch.isWasm());

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

pub var asset_path: []const u8 = "../assets/";
