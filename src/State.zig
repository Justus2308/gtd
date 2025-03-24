_: void align(alignment),

allocator: Allocator,
allocator_ctx: if (is_debug) DebugAllocator else void,

thread_pool: ThreadPool,

render: Render,
game: Game,

asset_manager: asset.Manager,
asset_dir: Dir,

const State = @This();

// we don't want to potentially waste 64KiB on WASM
// and we can't predict the host OS page size anyways
const alignment = if (builtin.cpu.arch.isWasm())
    std.atomic.cache_line
else
    std.heap.page_size_min;

pub fn preinit() Allocator.Error!*State {
    // init allocator (this needs to happen before sokol init
    // because we have to have a pointer to `State` by then)
    var allocator_ctx = if (is_debug) DebugAllocator{} else {};
    const allocator = if (is_debug)
        allocator_ctx.allocator()
    else if (is_wasm)
        std.heap.wasm_allocator
    else
        std.heap.smp_allocator;

    // transfer allocator context to state if necessary
    const state = try allocator.create(State);
    state.allocator_ctx = allocator_ctx;
    state.allocator = if (is_debug) state.allocator_ctx.allocator() else allocator;
    allocator_ctx = undefined;
    errdefer state.allocator.destroy(state);

    return state;
}
pub fn init(state: *State) !void {
    state.thread_pool = .init(.{});
    errdefer state.thread_pool.deinit();
    state.render = .init(state.allocator);
    errdefer state.render.deinit();
    state.game = .init(state.allocator);
    errdefer state.game.deinit();
    state.asset_dir = try fs.cwd().openDir(asset_sub_path, .{ .iterate = true });
    errdefer state.asset_dir.close();
    state.asset_manager = .init(state.allocator, &state.asset_dir);
    errdefer state.asset_manager.deinit();
}
pub fn deinit(state: *State) void {
    state.asset_manager.deinit();
    state.asset_dir.close();
    state.game.deinit();
    state.render.deinit();
    if (is_debug) {
        assert(state.allocator_ctx.deinit() == .ok);
    }
}

pub fn update(state: *State, dt: f64) !void {
    _ = .{ state, dt };
}

const asset_sub_path = if (builtin.is_test) "test/assets" else "assets";

pub const Render = @import("State/Render.zig");
pub const Game = @import("State/Game.zig");

const builtin = @import("builtin");
const std = @import("std");
const stdx = @import("stdx");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const asset = stdx.asset;
const DebugAllocator = std.heap.DebugAllocator(.{ .thread_safe = true });
const Dir = fs.Dir;
const ThreadPool = stdx.ThreadPool;
const assert = std.debug.assert;

const is_debug = (builtin.mode == .Debug);
const is_wasm = builtin.target.cpu.arch.isWasm();
