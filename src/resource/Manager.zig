//! Manages loading and caching arbitrary resources through `Loader`s and lets
//! multiple consumers share cached resources safely amongst multiple threads.

arena: std.heap.ArenaAllocator,
arena_mt: std.heap.ThreadSafeAllocator,
allocator: Allocator,

handle_to_cell: stdx.concurrent.AutoHashMapUnmanaged(Loader.Handle, Cell),

thread_pool: ThreadPool,
thread_pool_schedule_mutex: std.Thread.Mutex,

load_unload_task_pool: std.heap.MemoryPoolAligned(LoadUnloadTaskCtx, .fromByteUnits(atomic.cache_line)),
load_unload_task_pool_mutex: std.Thread.Mutex,

default_loader_context: Loader.Context,

const Manager = @This();

pub const Error = (Loader.Error || Allocator.Error);

/// `Cell`s are only destroyed at manager `deinit()`
/// so references to them remain valid once obtained.
/// All member functions are thread-safe and lock-free.
const Cell = cell: {
    // For good measure
    @setEvalBranchQuota(atomic.cache_line);
    var estimated_padding_size = atomic.cache_line;
    var Attempt = CellType(estimated_padding_size);
    const initial_size = @sizeOf(Attempt);
    assert(initial_size > atomic.cache_line);
    while (@sizeOf(Attempt) == initial_size) {
        estimated_padding_size -= 1;
        Attempt = CellType(estimated_padding_size);
    }
    assert(@alignOf(Attempt) == atomic.cache_line);
    assert(@sizeOf(Attempt) < initial_size);
    break :cell Attempt;
};

fn CellType(comptime padding_size: usize) type {
    return struct {
        _: void align(atomic.cache_line) = {},
        state: atomic.Value(State),
        loader: Loader,
        padding_bytes: [padding_size]u8 = undefined,

        pub const State = enum(u32) {
            /// Loaded but unreferenced.
            unreferenced = 0,
            /// Loaded and cannot be referenced any more often.
            max_ref_count = (std.math.maxInt(u32) - 3),
            /// Currently unloading.
            unloading, // max-2,
            /// Unloaded.
            unloaded, // max-1
            /// Currently loading.
            loading, // max-0
            /// Loaded and referenced n times.
            _, // n

            pub inline fn incr(state: State) State {
                assert(state != .max_ref_count);
                return @enumFromInt(@intFromEnum(state) + 1);
            }

            pub inline fn decr(state: State) State {
                assert(state != .unreferenced);
                return @enumFromInt(@intFromEnum(state) - 1);
            }

            /// Compares raw integer values of `a` and `b`.
            pub inline fn cmp(a: State, b: State) std.math.Order {
                return std.math.order(@intFromEnum(a), @intFromEnum(b));
            }
        };

        pub fn init(loader: Loader) Cell {
            return .{
                .state = .init(.unloaded),
                .loader = loader,
            };
        }

        fn bufferFallback(cell: *Cell, allocator: Allocator) stdx.BufferFallbackAllocator {
            return .init(&cell.padding_bytes, allocator);
        }

        /// May unblock spuriously.
        inline fn waitWhile(cell: *Cell, expected_state: State) void {
            std.Thread.Futex.wait(@ptrCast(&cell.state), @intFromEnum(expected_state));
        }

        pub fn load(cell: *Cell, allocator: Allocator, context: Loader.Context) Loader.Error!void {
            var state = cell.state.load(.monotonic);
            loop: switch (state) {
                // Try to switch to loading state. If we aren't unloaded
                // anymore, reenter the switch with the new state.
                .unloaded => {
                    @branchHint(.likely);
                    state = cell.state.cmpxchgWeak(
                        state,
                        .loading,
                        .acquire,
                        .monotonic,
                    ) orelse break :loop;
                    continue :loop state;
                },
                // Some other thread is unloading our asset right now.
                // This is unfortunate, but we can't interrupt it safely
                // so we just wait for it to finish and reload the asset.
                .unloading => {
                    @branchHint(.unlikely);
                    cell.waitWhile(.unloading);
                    state = cell.state.load(.monotonic);
                    continue :loop state;
                },
                // Our job is being/has been done already.
                else => return,
            }
            // We are now the only thread operating on this cell's cache,
            // so we are responsible for 'unlocking' it if our load fails.
            assert(cell.state.load(.monotonic) == .loading);
            errdefer cell.state.store(.unloaded, .release);

            var bfa = cell.bufferFallback(allocator);
            try cell.loader.load(bfa.get(), context);

            // Signal to other threads that we are done if our load succeeds.
            cell.state.store(.unreferenced, .release);
        }

        pub fn unload(cell: *Cell, allocator: Allocator) bool {
            // Similiar structure to load(), but unload() cannot fail.
            var state = cell.state.load(.monotonic);
            loop: switch (state) {
                // We can only unload if ref count is 0.
                .unreferenced => {
                    @branchHint(.likely);
                    state = cell.state.cmpxchgWeak(
                        state,
                        .unloading,
                        .acquire,
                        .monotonic,
                    ) orelse break :loop;
                    continue :loop state;
                },
                // Wait for asset to load and immediately try to unload it.
                .loading => {
                    @branchHint(.unlikely);
                    cell.waitWhile(.loading);
                    state = cell.state.load(.monotonic);
                    continue :loop state;
                },
                // Either our job is being/has been done already or
                // there are still active references to this asset.
                else => return false,
            }
            assert(cell.state.load(.monotonic) == .unloading);

            var bfa = cell.bufferFallback(allocator);
            var foa = stdx.FreeOnlyAllocator.init(bfa.get());
            cell.loader.unload(foa.allocator());

            cell.state.store(.unloaded, .release);
            return true;
        }

        pub inline fn isLoaded(cell: Cell) bool {
            const state = cell.state.load(.acquire);
            return (state.cmp(.max_ref_count) != .gt);
        }

        pub inline fn isReferenced(cell: Cell) bool {
            const state = cell.state.load(.acquire);
            return (state.cmp(.unreferenced) == .gt) and (state.cmp(.max_ref_count) != .gt);
        }

        pub fn addReference(cell: *Cell) bool {
            var state = cell.state.load(.monotonic);
            loop: switch (state) {
                _ => {
                    @branchHint(.likely);
                    state = cell.state.cmpxchgWeak(
                        state,
                        state.incr(),
                        .acquire,
                        .monotonic,
                    ) orelse return true;
                    continue :loop state;
                },
                .unloading, .unloaded => return false,
                .loading => {
                    @branchHint(.unlikely);
                    cell.waitWhile(.loading);
                    state = cell.state.load(.monotonic);
                    continue :loop state;
                },
                // Cannot add any more references or we will mess up our state.
                .max_ref_count => {
                    @branchHint(.cold);
                    log.warn("reached max reference count for cell (handle={x})", .{
                        cell.loader.generateHandle(),
                    });
                    return false;
                },
            }
        }

        pub fn removeReference(cell: *Cell) void {
            var state = cell.state.load(.monotonic);
            loop: switch (state) {
                else => {
                    @branchHint(.likely);
                    state = cell.state.cmpxchgWeak(
                        state,
                        state.decr(),
                        .acquire,
                        .monotonic,
                    ) orelse return;
                    continue :loop state;
                },
                // We can ignore those because the asset is already
                // unreferenced anyways.
                .unreferenced, .unloading, .unloaded, .loading => return,
            }
        }

        /// Like `addReference()`, but will not wait for assets to finish loading.
        pub fn addReferenceIfCached(cell: *Cell) bool {
            var state = cell.state.load(.monotonic);
            loop: switch (state) {
                _ => {
                    @branchHint(.likely);
                    state = cell.state.cmpxchgWeak(
                        state,
                        state.incr(),
                        .acquire,
                        .monotonic,
                    ) orelse return true;
                    continue :loop state;
                },
                .unloading, .unloaded, .loading => return false,
                // Cannot add any more references or we will mess up our state.
                .max_ref_count => {
                    @branchHint(.cold);
                    log.warn("reached max reference count for cell (handle={x})", .{
                        cell.loader.generateHandle(),
                    });
                    return false;
                },
            }
        }
    };
}

pub fn initInstance(
    m: *Manager,
    gpa: Allocator,
    default_loader_context: Loader.Context,
    max_thread_count: usize,
) void {
    m.* = .{
        .arena = .init(gpa),
        .arena_mt = undefined,
        .allocator = undefined,

        .handle_to_cell = .empty,

        .thread_pool = .init(max_thread_count),
        .thread_pool_schedule_mutex = .{},

        .load_unload_task_pool = undefined,
        .load_unload_task_pool_mutex = .{},

        .default_loader_context = default_loader_context,
    };
    m.arena_mt = .{ .child_allocator = m.arena.allocator() };
    m.allocator = m.arena_mt.allocator();
    m.load_unload_task_pool = .init(m.allocator);
}

pub fn deinit(m: *Manager) void {
    // TODO unload assets?
    m.thread_pool.deinit();
    {
        m.arena_mt.mutex.lock();
        defer m.arena_mt.mutex.unlock();
        m.arena.deinit();
    }
    m.* = undefined;
    log.debug("asset manager deinitialized", .{});
}

pub fn load(m: *Manager, gpa: Allocator, loader: Loader) Error!Loader.Handle {
    return m.loadWithContext(gpa, loader, m.default_loader_context);
}

pub fn loadWithContext(m: *Manager, gpa: Allocator, loader: Loader, context: Loader.Context) Error!Loader.Handle {
    const handle = loader.generateHandle();
    const cell = try m.handle_to_cell.getPtrOrPutAndGetPtr(gpa, handle, .init(loader));
    try cell.load(gpa, context);
    return handle;
}

pub fn unload(m: *Manager, gpa: Allocator, handle: Loader.Handle) bool {
    const cell = m.handle_to_cell.getPtr(handle) orelse return false;
    return cell.unload(gpa);
}

pub fn get(
    m: *Manager,
    comptime T: type,
    gpa: Allocator,
    handle: Loader.Handle,
) Error!?*const T {
    return m.getWithContext(T, gpa, handle, m.default_loader_context);
}

pub fn getWithContext(
    m: *Manager,
    comptime T: type,
    gpa: Allocator,
    handle: Loader.Handle,
    context: Loader.Context,
) Error!?*const T {
    const allocatable = m.handle_to_cell.getPtr(handle) orelse return null;
    while (allocatable.cell.addReference() == false) {
        try allocatable.cell.load(gpa, context);
    }
    return allocatable.cell.loader.casted(T);
}

pub fn tryGet(
    m: *Manager,
    comptime T: type,
    handle: Loader.Handle,
) Error!?*const T {
    const allocatable = m.handle_to_cell.getPtr(handle) orelse return null;
    if (allocatable.cell.addReferenceIfCached()) {
        return allocatable.cell.loader.casted(T);
    } else {
        return null;
    }
    unreachable;
}

pub fn unget(m: *Manager, handle: Loader.Handle) bool {
    const allocatable = m.handle_to_cell.getPtr(handle) orelse return false;
    allocatable.cell.removeReference();
    return true;
}

pub const LoadUnloadTaskCtx = struct {
    task: ThreadPool.Task,
    manager: *Manager,
    allocator: Allocator,
    data: union {
        loader: Loader,
        handle: Loader.Handle,
    },

    pub const Mode = union(enum) {
        load: Loader,
        unload: Loader.Handle,
    };

    pub fn load(task: *ThreadPool.Task) void {
        const ctx: *LoadUnloadTaskCtx = @fieldParentPtr("task", task);
        _ = ctx.manager.load(ctx.allocator, ctx.data.loader, ctx.manager.default_loader_context) catch {};
        ctx.manager.destroyLoadUnloadTaskCtx(@alignCast(ctx));
    }

    pub fn unload(task: *ThreadPool.Task) void {
        const ctx: *LoadUnloadTaskCtx = @fieldParentPtr("task", task);
        _ = ctx.manager.unload(ctx.allocator, ctx.data.handle);
        ctx.manager.destroyLoadUnloadTaskCtx(@alignCast(ctx));
    }
};

fn createLoadUnloadTaskCtx(
    m: *Manager,
    allocator: Allocator,
    mode: LoadUnloadTaskCtx.Mode,
) Allocator.Error!*align(atomic.cache_line) LoadUnloadTaskCtx {
    m.load_unload_task_pool_mutex.lock();
    defer m.load_unload_task_pool_mutex.unlock();
    const ctx = try m.load_unload_task_pool.create();
    ctx.* = .{
        .task = .{ .callback = switch (mode) {
            .load => &LoadUnloadTaskCtx.load,
            .unload => &LoadUnloadTaskCtx.unload,
        } },
        .manager = m,
        .allocator = allocator,
        .data = switch (mode) {
            .load => |loader| .{ .loader = loader },
            .unload => |handle| .{ .handle = handle },
        },
    };
    return ctx;
}

fn destroyLoadUnloadTaskCtx(m: *Manager, ctx: *align(atomic.cache_line) LoadUnloadTaskCtx) void {
    m.load_unload_task_pool_mutex.lock();
    defer m.load_unload_task_pool_mutex.unlock();
    m.load_unload_task_pool.destroy(ctx);
}

/// Load resource asynchronously using the thread pool.
/// Returns as soon as possible.
pub fn scheduleLoad(
    m: *Manager,
    gpa: Allocator,
    loader: Loader,
) Allocator.Error!void {
    const load_task_ctx = try m.createLoadUnloadTaskCtx(gpa, .{ .load = loader });
    m.scheduleLoadUnloadTask(&load_task_ctx);
}

/// Unload resource asynchronously using the thread pool.
/// Returns as soon as possible.
pub fn scheduleUnload(
    m: *Manager,
    gpa: Allocator,
    handle: Loader.Handle,
) Allocator.Error!void {
    const unload_task_ctx = try m.createLoadUnloadTaskCtx(gpa, .{ .unload = handle });
    m.scheduleLoadUnloadTask(&unload_task_ctx);
}

fn scheduleLoadUnloadTask(m: *Manager, noalias load_unload_task_ctx: *LoadUnloadTaskCtx) void {
    m.thread_pool_schedule_mutex.lock();
    defer m.thread_pool_schedule_mutex.unlock();
    m.thread_pool.schedule(&load_unload_task_ctx.task);
}

const builtin = @import("builtin");
const std = @import("std");
const stdx = @import("stdx");
const render = @import("render");
const atomic = std.atomic;
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Dir = std.fs.Dir;
const File = std.fs.File;
const Loader = @import("Loader.zig");
const ThreadPool = stdx.concurrent.ThreadPool;

const assert = std.debug.assert;
const log = std.log.scoped(.resource_manager);

const is_debug = (builtin.mode == .Debug);
const is_safe_build = (builtin.mode == .Debug or builtin.mode == .ReleaseSafe);

fn openTestAssetDir() !Dir {
    const asset_dir = try std.fs.cwd().openDir(
        "test/assets",
        .{ .iterate = true },
    );
    return asset_dir;
}

test "load/unload texture" {
    const Texture = @import("Texture.zig");

    var test_asset_dir = try openTestAssetDir();
    defer test_asset_dir.close();

    var manager: Manager = undefined;
    manager.initInstance(testing.allocator, .{
        .asset_dir = test_asset_dir,
        .shader_context = undefined,
    }, 2);
    defer manager.deinit();

    var texture = Texture.init("goons");
    const handle = try manager.load(testing.allocator, texture.loader());
    try testing.expectEqual(true, manager.unload(testing.allocator, handle));
}
