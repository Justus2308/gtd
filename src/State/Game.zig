allocator: Allocator,
arena: std.heap.ArenaAllocator,

status: Status,

difficulty: Difficulty,
mode: Mode,

round: u64,
hp: f32,
shield: f32,
pops: f32,
cash: f32,

const Game = @This();

pub const Status = enum {
    /// do nothing
    unloaded,
    /// preload assets+map+rounds, prepare game state
    loading,
    /// update goons, apes, projectiles etc.
    running,
    /// show pause menu, keep everything loaded
    paused,
    /// prepare goon+projectile buffers to be repopulated
    end_of_round,
    /// show end-of-game screen
    end_of_game,
    /// unload everything
    exited,
};

pub const Difficulty = enum {
    easy,
    normal,
    hard,
    impoppable,
};
pub const Mode = enum {
    standard,
    alternate,
    chimps,
};

pub fn init(allocator: Allocator) Game {
    var game: Game = undefined;
    game.allocator = allocator;
    game.arena = std.heap.ArenaAllocator.init(allocator);
    game.status = .unloaded;
    return game;
}
pub fn deinit(game: *Game) void {
    if (game.status != .unloaded) {}
    game.arena.deinit();
}

pub fn frame(game: *Game, dt: u64) void {
    switch (game.status) {
        .unloaded => return,
        .loading => {
            // dispatch preload tasks to pool
            const thread_pool = &game.parentState().thread_pool;
            thread_pool.schedule(.from());
        },
    }
}

/// Do not dispatch multiple of these at once,
/// they will always block each other.
const PreloadAssets = struct {
    task: ThreadPool.Task,

    allocator: Allocator,
    asset_manager: *Asset.Manager,
    assets: []const Asset,
    handles: []Asset.Manager.Handle,
    err: (error{None} || Asset.Manager.Error),

    pub fn prepare(
        ctx: *PreloadAssets,
        game: *Game,
        assets: []const Asset,
        handles: []Asset.Manager.Handle,
    ) *ThreadPool.Task {
        ctx.* = .{
            .task = .{ .callback = run },
            .allocator = game.parentState().allocator,
            .asset_manager = &game.parentState().asset_manager,
            .assets = assets,
            .handles = handles,
            .err = .None,
        };
        return &ctx.task;
    }

    fn run(task: *ThreadPool.Task) void {
        const ctx: *PreloadAssets = @fieldParentPtr("task", task);
        ctx.handles = if (ctx.asset_manager.loadMany(
            ctx.allocator,
            ctx.handles,
            ctx.assets,
        )) |handles|
            handles
        else |err| blk: {
            ctx.err = err;
            break :blk ctx.handles[0..0];
        };
    }
};

pub fn nextRound(game: *Game) void {
    _ = game;
}

inline fn parentState(game: *Game) *State {
    return @fieldParentPtr("game", game);
}

const std = @import("std");
const stdx = @import("stdx");
const State = @import("State");
const Allocator = std.mem.Allocator;
const Asset = stdx.Asset;
const ThreadPool = stdx.ThreadPool;
