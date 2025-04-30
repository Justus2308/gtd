//! Manages loading and caching assets from disk and lets multiple consumers
//! share cached assets safely among multiple threads.
//! Asset handles created by this manager are stable and remain valid until
//! it is deinitialized.
//! Preregister as many assets as possible to avoid exclusive locks during
//! operation.

arena: std.heap.ArenaAllocator,
arena_ts: std.heap.ThreadSafeAllocator,
allocator: Allocator,

// TODO make this lock-free by backing the hash map with a segmented list
bytes_to_location: std.StringArrayHashMapUnmanaged(Location),
map_lock: std.Thread.RwLock,

// a little questionable, will work for now
default_shader_context: Render.backend.ShaderContext,
asset_dir: Dir,
thread_pool: *stdx.ThreadPool,

task_pool: stdx.ConcurrentMemoryPool(TaskWithContext(DummyAsset), .{}),

const Manager = @This();

pub const Error = Allocator.Error;

/// Uniquely identifies an asset.
pub const Handle = u32;

/// Passed to `Asset` `load()` and `unload()` functions.
pub const Context = struct {
    allocator: Allocator,
    bytes: []const u8,
    asset_manager: *Manager,
};

const DummyAsset = struct {
    pub const Key = void;
    pub const Error = error{};

    pub fn load(context: Manager.Context) DummyAsset.Error!DummyAsset {
        _ = context;
        return .{};
    }
    pub fn unload(dummy: *DummyAsset, context: Manager.Context) void {
        _ = .{ dummy, context };
    }
    pub fn toOwnedBytes(allocator: Allocator, key: DummyAsset.Key) Allocator.Error![]const u8 {
        _ = .{ allocator, key };
        return &.{};
    }
};

/// Semi-type-erased, is the same size for every `Asset`
fn TaskWithContext(comptime Asset: type) type {
    return struct {
        task: stdx.ThreadPool.Task,
        manager: *Manager,
        allocator: Allocator,
        data: union {
            _: [max_local_size]u8,
            local: Local,
            ptr: *Asset.Key,
            handle: Manager.Handle,
        },

        const Self = @This();

        const max_local_size = 256;
        const is_local_key = (@sizeOf(Asset.Key) <= max_local_size);
        const Local = if (is_local_key) Asset.Key else void;

        comptime {
            assert(@sizeOf(@FieldType(Self, "data")) == max_local_size);
            assert(@sizeOf(TaskWithContext(DummyAsset)) == @sizeOf(TaskWithContext(Texture)));
        }

        inline fn getKey(self: Self) Asset.Key {
            return if (is_local_key)
                self.data.local
            else
                self.data.ptr.*;
        }
        inline fn getHandle(self: Self) Manager.Handle {
            return self.data.handle;
        }

        pub fn dispatch(self: *Self) void {
            self.manager.thread_pool.schedule(.from(&self.task));
        }
        pub fn addToBatch(self: *Self, batch: *stdx.ThreadPool.Batch) void {
            batch.push(.from(&self.task));
        }

        pub fn load(task: *stdx.ThreadPool.Task) void {
            const ctx: *Self = @fieldParentPtr("task", task);
            const key = ctx.getKey();
            ctx.manager.load(Asset, ctx.allocator, key) catch {};
            if (!is_local_key) {
                ctx.allocator.destroy(ctx.data.ptr);
            }
            ctx.manager.destroyTaskWithContext(ctx);
        }
        pub fn unload(task: *stdx.ThreadPool.Task) void {
            const ctx: *Self = @fieldParentPtr("task", task);
            const handle = ctx.getHandle();
            _ = ctx.manager.unload(Asset, ctx.allocator, handle);
            ctx.manager.destroyTaskWithContext(ctx);
        }
    };
}
pub fn createLoadTaskWithContext(
    m: *Manager,
    comptime Asset: type,
    allocator: Allocator,
    key: Asset.Key,
) Allocator.Error!*TaskWithContext(Asset) {
    const slot = slot: {
        m.task_pool_lock.lock();
        defer m.task_pool_lock.unlock();
        break :slot try m.task_pool.create(m.allocator);
    };
    const T = TaskWithContext(Asset);
    const ctx: *T = @ptrCast(slot);
    ctx.* = .{
        .task = .{ .callback = T.load },
        .manager = m,
        .allocator = allocator,
        .data = if (T.is_local_key)
            .{ .local = key }
        else
            .{ .ptr = try allocator.create(Asset.Key) },
    };
    return ctx;
}
pub fn createUnloadTaskWithContext(
    m: *Manager,
    comptime Asset: type,
    allocator: Allocator,
    handle: Manager.Handle,
) Allocator.Error!*TaskWithContext(Asset) {
    const slot = slot: {
        m.task_pool_lock.lock();
        defer m.task_pool_lock.unlock();
        break :slot try m.task_pool.create(m.allocator);
    };
    const T = TaskWithContext(Asset);
    const ctx: *T = @ptrCast(slot);
    ctx.* = .{
        .task = .{ .callback = T.unload },
        .manager = m,
        .allocator = allocator,
        .data = .{ .handle = handle },
    };
    return ctx;
}
pub fn destroyTaskWithContext(m: *Manager, task_with_context: anytype) void {
    const slot: *TaskWithContext(void) = @alignCast(@ptrCast(task_with_context));
    m.task_pool_lock.lock();
    defer m.task_pool_lock.unlock();
    m.task_pool.destroy(m.allocator, slot);
}

/// Locations are only destroyed at manager `deinit()`
/// so references to them remain valid once obtained.
/// All member functions are thread-safe and lock-free.
const Location = extern struct {
    /// Cache line aligned to avoid false sharing with neighbouring Locations.
    state: atomic.Value(State) align(atomic.cache_line),
    bytes_len: u32,
    bytes: Bytes,
    tag: Tag,
    asset: *anyopaque,

    /// Unique identifier of the `Asset` this location has
    /// been initialized with. Only included in safe builds.
    fingerprint: Fingerprint,

    const bytes_remaining_in_cache_line = (atomic.cache_line - @mod(
        (@sizeOf(State) + @sizeOf(u32) + @sizeOf(Tag) + @sizeOf(*anyopaque) + @sizeOf(Fingerprint)),
        atomic.cache_line,
    ));
    comptime {
        assert(@alignOf(Location) == atomic.cache_line);
        assert(@sizeOf(Location) == atomic.cache_line);
    }

    pub const State = enum(u32) {
        /// Loaded but unreferenced.
        unreferenced = 0,
        /// Loaded and cannot be referenced any more often.
        max_ref_count = std.math.maxInt(u32) - 3,
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

        pub inline fn cmp(a: State, b: State) std.math.Order {
            return std.math.order(@intFromEnum(a), @intFromEnum(b));
        }
    };

    const Bytes = union {
        // Use local bytes since we are likely to be
        // pretty over-aligned anyways.
        local: [bytes_remaining_in_cache_line]u8,
        ptr: [*]const u8,
    };
    const Tag = enum(u8) {
        local,
        ptr,
    };

    pub fn init(
        comptime Asset: type,
        allocator: Allocator,
        bytes: []const u8,
    ) Allocator.Error!Location {
        const bytes_duped, const tag = if (bytes.len <= Location.bytes_remaining_in_cache_line) duped: {
            var duped = Bytes{ .local = undefined };
            @memcpy(duped.local[0..bytes.len], bytes);
            break :duped .{ duped, Tag.local };
        } else duped: {
            const duped = Bytes{ .ptr = (try allocator.dupe(u8, bytes)).ptr };
            break :duped .{ duped, Tag.ptr };
        };
        errdefer if (tag == .ptr) allocator.free(bytes_duped.ptr[0..bytes.len]);
        const asset = try allocator.create(Asset);
        return Location{
            .state = .init(.unloaded),
            .bytes_len = bytes.len,
            .bytes = bytes_duped,
            .tag = tag,
            .asset = @ptrCast(asset),

            .fingerprint = Fingerprint.take(Asset),
        };
    }
    pub fn deinit(
        location: *Location,
        comptime Asset: type,
        allocator: Allocator,
    ) void {
        location.verifyFingerprint(Asset);

        const ok = location.unload();
        assert(ok);
        allocator.free(location.getIdentBytes());
        allocator.destroy(@as(*Asset, @alignCast(@ptrCast(location.asset))));
        location.* = undefined;
    }

    pub fn load(
        location: *Location,
        comptime Asset: type,
        allocator: Allocator,
        asset_manager: *Manager,
    ) Asset.Error!void {
        location.verifyFingerprint(Asset);

        var state = location.state.load(.monotonic);
        loop: switch (state) {
            // Try to switch to loading state. If we aren't unloaded
            // anymore, reenter the switch with the new state.
            .unloaded => {
                @branchHint(.likely);
                state = location.state.cmpxchgWeak(
                    state,
                    .loading,
                    .acquire,
                    .monotonic,
                ) orelse break :loop;
                continue :loop state;
            },
            // Our job is being/has been done already.
            else => return,
            // Some other thread is unloading our asset right now.
            // This is unfortunate, but we can't interrupt it safely
            // so we just wait for it to finish and reload the asset.
            .unloading => {
                @branchHint(.unlikely);
                std.Thread.Futex.wait(&location.state, .unloading);
                state = location.state.load(.monotonic);
                continue :loop state;
            },
        }
        // We are now the only thread operating on this location's cache,
        // so we are responsible for 'unlocking' it if our load fails.
        assert(location.state.load(.monotonic) == .loading);
        errdefer location.state.store(.unloaded, .release);

        const context = Context{
            .allocator = allocator,
            .bytes = location.getBytes(),
            .asset_manager = asset_manager,
        };
        const asset: *Asset = @alignCast(@ptrCast(location.asset));
        asset.* = try Asset.load(context);

        // Signal to other threads that we are done if our load succeeds.
        location.state.store(.unreferenced, .release);
    }

    pub fn unload(
        location: *Location,
        comptime Asset: type,
        allocator: Allocator,
        asset_manager: *Manager,
    ) bool {
        location.verifyFingerprint(Asset);

        // Similiar structure to load(), but unload() cannot fail.
        var state = location.state.load(.monotonic);
        loop: switch (state) {
            // We can only unload if ref count is 0.
            .unreferenced => {
                @branchHint(.likely);
                state = location.state.cmpxchgWeak(
                    state,
                    .unloading,
                    .acquire,
                    .monotonic,
                ) orelse break :loop;
                continue :loop state;
            },
            // Either our job is being/has been done already or
            // there are still active references to this asset.
            else => return false,
            // Wait for asset to load and immediately try to unload it.
            .loading => {
                @branchHint(.unlikely);
                std.Thread.Futex.wait(&location.state, .loading);
                state = location.state.load(.monotonic);
                continue :loop state;
            },
        }
        assert(location.state.load(.monotonic) == .unloading);

        const context = Context{
            .allocator = allocator,
            .bytes = location.getBytes(),
            .asset_manager = asset_manager,
        };
        const asset: *Asset = @alignCast(@ptrCast(location.asset));
        asset.unload(context);

        location.state.store(.unloaded, .release);
        return true;
    }

    pub inline fn getAsset(location: Location, comptime Asset: type) *const Asset {
        location.verifyFingerprint(Asset);
        return @alignCast(@ptrCast(location.asset));
    }

    pub inline fn getBytes(location: Location) []const u8 {
        return switch (location.tag) {
            .local => location.bytes.local[0..location.bytes_len],
            .slice => location.bytes.ptr[0..location.bytes_len],
        };
    }

    pub inline fn isLoaded(location: Location) bool {
        const state = location.state.load(.acquire);
        return (state.cmp(.max_ref_count) != .gt);
    }

    pub inline fn isReferenced(location: Location) bool {
        const state = location.state.load(.acquire);
        return (state.cmp(.unreferenced) == .gt) and (state.cmp(.max_ref_count) != .gt);
    }
    pub fn addReference(location: *Location) bool {
        var state = location.state.load(.monotonic);
        loop: switch (state) {
            else => {
                @branchHint(.likely);
                state = location.state.cmpxchgWeak(
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
                std.Thread.Futex.wait(&location.state, .loading);
                state = location.state.load(.monotonic);
                continue :loop state;
            },
            // Cannot add any more references or we will mess up our state.
            .max_ref_count => {
                @branchHint(.cold);
                log.warn("reached max reference count for location ({s})", .{
                    location.getBytes(),
                });
                return false;
            },
        }
    }
    pub fn removeReference(location: *Location) void {
        var state = location.state.load(.monotonic);
        loop: switch (state) {
            else => {
                @branchHint(.likely);
                state = location.state.cmpxchgWeak(
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
    pub fn addReferenceIfCached(location: *Location) bool {
        var state = location.state.load(.monotonic);
        loop: switch (state) {
            else => {
                @branchHint(.likely);
                state = location.state.cmpxchgWeak(
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
                log.warn("reached max reference count for location ({s})", .{
                    location.bytes,
                });
                return false;
            },
        }
    }

    fn verifyFingerprint(location: *Location, comptime T: type) void {
        if (is_safe_build) {
            const fingerprint = Fingerprint.take(T);
            if (!location.fingerprint.eql(fingerprint)) {
                @branchHint(.cold);
                std.debug.panic(
                    "Wrong 'Asset' fingerprint: Expected {d}('{s}'), got {d}('{s}')",
                    location.fingerprint.getId(),
                    location.fingerprint.getName(),
                    fingerprint.getId(),
                    fingerprint.getName(),
                );
            }
        }
    }

    const Fingerprint = struct {
        name: if (is_debug) [*:0]const u8 else void,
        id: TypeId,

        pub inline fn take(comptime T: type) Fingerprint {
            if (is_safe_build) {
                return Fingerprint{
                    .name = if (is_debug) @typeName(T) else {},
                    .id = typeId(T),
                };
            } else {
                return {};
            }
        }
        /// Runtime-only, to compare `Fingerprint`s at comptime use `eql()`.
        pub inline fn getId(fingerprint: Fingerprint) usize {
            return if (is_safe_build) @intFromPtr(fingerprint.id) else undefined;
        }
        pub inline fn getName(fingerprint: Fingerprint) [*:0]const u8 {
            return if (is_debug) fingerprint.name else "?";
        }
        pub inline fn eql(a: Fingerprint, b: Fingerprint) bool {
            return (a.id == b.id);
        }
    };

    // https://github.com/ziglang/zig/issues/19858#issuecomment-2369861301
    const TypeId = if (is_safe_build) *const struct { _: u8 } else void;
    inline fn typeId(comptime T: type) TypeId {
        if (is_safe_build) {
            return &struct {
                comptime {
                    _ = T;
                }
                var id: @typeInfo(TypeId).pointer.child = undefined;
            }.id;
        } else {
            return {};
        }
    }
};

pub fn init(
    gpa: Allocator,
    asset_dir: Dir,
    default_shader: Render.backend.Shader,
    thread_pool: *stdx.ThreadPool,
) Manager {
    var m = Manager{
        .arena = .init(gpa),
        .arena_ts = undefined,
        .allocator = undefined,

        .bytes_to_handle = .empty,
        .handle_to_location = .empty,

        .next_handle = .init(0),

        .default_shader = default_shader,
        .asset_dir = asset_dir,
        .thread_pool = thread_pool,

        .task_pool = .init,
        .task_pool_lock = .{},
    };
    // Should work because of RLS (?)
    m.arena_ts = std.heap.ThreadSafeAllocator(m.arena.allocator());
    m.allocator = m.arena_ts.allocator();
    return m;
}

pub fn deinit(m: *Manager) void {
    // TODO unload assets?
    m.arena_ts.mutex.lock();
    m.arena.deinit();
    m.arena_ts.mutex.unlock();
    m.* = undefined;
    log.debug("asset manager deinitialized", .{});
}

pub fn load(
    m: *Manager,
    comptime Asset: type,
    gpa: Allocator,
    key: Asset.Key,
) (Asset.Error || Error)!Handle {
    validateAsset(Asset);

    const stack_fallback_allocator = std.heap.stackFallback(256, gpa);
    const sfa = stack_fallback_allocator.get();
    const bytes = try Asset.toOwnedBytes(sfa, key);
    defer sfa.free(bytes);

    const gop = gop: {
        m.map_lock.lock();
        m.map_lock.unlock();
        const gop = try m.bytes_to_location.getOrPut(m.allocator, bytes);
        if (!gop.found_existing) {
            gop.value_ptr.* = try Location.init(Asset, m.allocator, bytes);
            gop.key_ptr.* = gop.value_ptr.getBytes();
        }
        break :gop gop;
    };

    const location = gop.value_ptr;
    try location.load(Asset, gpa, m);

    const handle: Handle = @intCast(gop.index);
    return handle;
}

pub fn unload(m: *Manager, comptime Asset: type, gpa: Allocator, handle: Handle) bool {
    validateAsset(Asset);

    const location = m.getLocationFromHandle(handle) orelse return false;
    return location.unload(Asset, gpa, m);
}

/// Load asset asynchronously using the thread pool.
/// Returns as soon as possible.
pub fn dispatchLoad(
    m: *Manager,
    comptime Asset: type,
    gpa: Allocator,
    key: Asset.Key,
) Allocator.Error!void {
    const load_task = try m.createLoadTaskWithContext(Asset, gpa, key);
    load_task.dispatch();
}

/// Unload asset asynchronously using the thread pool.
/// Returns as soon as possible.
pub fn dispatchUnload(
    m: *Manager,
    comptime Asset: type,
    gpa: Allocator,
    handle: Handle,
) Allocator.Error!void {
    const unload_task = try m.createUnloadTaskWithContext(Asset, gpa, handle);
    unload_task.dispatch();
}

pub fn get(
    m: *Manager,
    comptime Asset: type,
    gpa: Allocator,
    handle: Handle,
) Error!?*const Asset {
    validateAsset(Asset);

    const location = m.getLocationFromHandle(handle) orelse return null;
    while (!location.addReference()) {
        try location.load(Asset, gpa, m);
    }
    return location.getAsset(Asset);
}

/// On success this only performs one threadlocal cache/shared-locked
/// hash table lookup and one weak CAS loop.
/// This function will not wait for anything and return `null` instead.
pub fn tryGet(m: *Manager, comptime Asset: type, handle: Handle) ?*const Asset {
    validateAsset(Asset);

    const location = m.getLocationFromHandle(handle) orelse return null;
    if (location.addReferenceIfCached()) {
        return location.getAsset(Asset);
    } else {
        return null;
    }
}

pub fn getHandle(
    m: *Manager,
    comptime Asset: type,
    key: Asset.Key,
) Error!Handle {
    validateAsset(Asset);

    const stack_fallback_allocator = std.heap.stackFallback(256, m.allocator);
    const sfa = stack_fallback_allocator.get();
    const bytes = try Asset.toOwnedBytes(sfa, key);
    defer sfa.free(bytes);

    const handle: Handle = @intCast(handle: {
        m.map_lock.lockShared();
        defer m.map_lock.unlockShared();

        break :handle m.bytes_to_location.getIndex(bytes);
    } orelse handle: {
        m.map_lock.lock();
        defer m.map_lock.unlock();

        const gop = try m.bytes_to_location.getOrPut(m.allocator, bytes);
        if (!gop.found_existing) {
            gop.value_ptr.* = try Location.init(Asset, m.allocator, bytes);
            gop.key_ptr.* = gop.value_ptr.getBytes();
        }
        break :handle gop.index;
    });
    return handle;
}

pub fn unget(m: *Manager, handle: Handle) bool {
    const location = m.getLocationFromHandle(handle) orelse return false;
    location.removeReference();
    return true;
}

fn getLocationFromHandle(m: *Manager, handle: Handle) ?*Location {
    if (handle >= @atomicLoad(usize, &m.bytes_to_location.entries.len, .acquire)) {
        return null;
    }
    // TODO make this lock free
    const location = location: {
        m.map_lock.lockShared();
        defer m.map_lock.unlockShared();
        break :location m.bytes_to_location.values()[handle];
    };
    return location;
}

fn validateAsset(comptime Asset: type) void {
    if (!@hasDecl(Asset, "Key") or
        !@hasDecl(Asset, "Error") or
        !std.meta.hasFn(Asset, "load") or
        !std.meta.hasMethod(Asset, "unload") or
        !std.meta.hasFn(Asset, "toOwnedBytes"))
    {
        @compileError("'" ++ @typeName(Asset) ++ "' doesn't satisfy 'Asset' interface");
    }
}

const builtin = @import("builtin");
const std = @import("std");
const stdx = @import("stdx");
const s2s = @import("s2s");
const atomic = std.atomic;
const mem = std.mem;
const Allocator = mem.Allocator;
const Dir = std.fs.Dir;
const File = std.fs.File;
const Render = @import("State").Render;
const assert = std.debug.assert;
const log = std.log.scoped(.assets);

const is_debug = (builtin.mode == .Debug);
const is_safe_build = (builtin.mode == .Debug or builtin.mode == .ReleaseSafe);

const testing = std.testing;

fn openTestAssetDir() !Dir {
    const asset_dir = try std.fs.cwd().openDir(
        "test/assets",
        .{ .iterate = true },
    );
    return asset_dir;
}

test "load/unload sprite" {
    const asset_dir = try openTestAssetDir();
    defer asset_dir.close();
    const m = Manager.init(testing.allocator, asset_dir);
    defer m.deinit();
    const handle = try m.load(Texture, "textures/sprites/goons.png");
    defer m.unload(Texture, handle);
    _ = m.tryGet(Texture, handle).?;
    defer m.unget(handle);
}

test "load/unload model" {
    const asset_dir = try openTestAssetDir();
    defer asset_dir.close();
    const m = Manager.init(testing.allocator, asset_dir);
    defer m.deinit();
    const handle = try m.load(Model, "models/airship.glb");
    defer m.unload(Model, handle);
    _ = m.tryGet(Model, handle).?;
    defer m.unget(handle);
}

test "load/unload map" {
    return error.SkipZigTest;
}
