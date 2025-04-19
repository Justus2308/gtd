//! Assets need to satisfy the following interface:
//! `pub const Key = [type]`
//! `pub const Error = error{...}`
//! `pub fn load(context: Manager.Context) Asset.Error!Asset`
//! `pub fn unload(asset: *Asset, context: Manager.Context) void`
//! `pub fn toOwnedBytes(key: Key) Allocator.Error![]const u8`

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

/// Manages loading and caching assets from disk and lets multiple consumers
/// share cached assets safely among multiple threads.
/// Asset handles created by this manager are stable and remain valid until
/// it is deinitialized.
/// Preregister as many assets as possible to avoid exclusive locks during
/// operation.
pub const Manager = struct {
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
};

// Assets

// Prevent accidental key collisions
const AssetMagic = enum(u32) {
    path = 0x9A769A76,
    pipeline = 0x919E714E,
    sampler = 0x5AAA97E5,

    pub fn asBytes(magic: AssetMagic) [@sizeOf(AssetMagic)]u8 {
        return @as([@sizeOf(AssetMagic)]u8, @bitCast(@intFromEnum(magic)));
    }
};

inline fn noMagic(bytes: []const u8) []const u8 {
    assert(bytes.len >= @sizeOf(AssetMagic));
    return bytes[@sizeOf(AssetMagic)..bytes.len];
}

inline fn hasMagic(comptime magic: AssetMagic, bytes: []const u8) bool {
    assert(bytes.len >= @sizeOf(AssetMagic));
    const magic_bytes = comptime magic.asBytes();
    return mem.eql(u8, &magic_bytes, bytes[0..@sizeOf(AssetMagic)]);
}

pub const Texture = struct {
    width: u32,
    height: u32,
    image: Render.backend.Image,

    pub const Key = []const u8;
    pub const Error = File.OpenError || zigimg.ImageUnmanaged.ReadError || zigimg.ImageUnmanaged.ConvertError;

    const zigimg = @import("zigimg");

    pub fn load(context: Manager.Context) Texture.Error!Texture {
        assert(hasMagic(.path, context.bytes));

        const asset_dir = context.asset_manager.asset_dir;
        const path = noMagic(context.bytes);
        const file = try asset_dir.openFile(path, .{ .mode = .read_only });
        defer file.close();

        var arena = std.heap.ArenaAllocator.init(context.allocator);
        defer arena.deinit();

        var stream = zigimg.ImageUnmanaged.Stream{ .file = file };
        const options = zigimg.formats.png.DefaultOptions.init(.{});
        const image = try zigimg.formats.png.load(&stream, arena.allocator(), options.get());
        defer image.deinit(arena.allocator());

        const pixel_format = image.pixelFormat();
        if (pixel_format.bitsPerChannel() != 8 or pixel_format.channelCount() != 4) {
            try image.convert(arena.allocator(), .rgba32);
            log.warn("had to convert image to RGBA32 ({s})", .{path});
        }

        const pixels = image.rawBytes();

        const render_image = Render.backend.createTexture(image.width, image.height, pixels);

        log.info("loaded texture from '{s}'", .{path});
        return Texture{
            .width = @intCast(image.width),
            .height = @intCast(image.height),
            .image = render_image,
        };
    }

    pub fn unload(texture: *Texture, context: Manager.Context) void {
        assert(hasMagic(.path, context.bytes));

        Render.backend.destroyTexture(texture.image);
        texture.* = undefined;

        log.info("unloaded texture from '{s}'", .{noMagic(context.bytes)});
    }

    pub fn toOwnedBytes(allocator: Allocator, key: Key) Allocator.Error![]const u8 {
        const magic_bytes = AssetMagic.path.asBytes();
        const bytes = try mem.concat(allocator, u8, &.{ &magic_bytes, key });
        return bytes;
    }
};

pub const Model = struct {
    meshes: []const Render.backend.Mesh,
    primitives: []const Render.backend.Mesh.Primitive,

    pub const Key = []const u8;
    pub const Error = File.OpenError || stdx.MapFileToMemoryError || std.Uri.ParseError || std.base64.Error;

    const zgltf = @import("zgltf");
    const zigimg = @import("zigimg");
    const zalgebra = @import("zalgebra");

    pub fn load(context: Manager.Context) Model.Error!Model {
        assert(hasMagic(.path, context.bytes));

        const asset_dir = context.asset_manager.asset_dir;
        const path = noMagic(context.bytes);
        const file = try asset_dir.openFile(path, .{ .mode = .read_only });
        defer file.close();

        const mapped = try stdx.mapFileToMemory(file);
        defer stdx.unmapFileFromMemory(mapped);

        var gltf = zgltf.init(context.allocator);
        defer gltf.deinit();
        try gltf.parse(mapped);

        var mesh_count: usize = 0;
        var prim_count: usize = 0;
        for (gltf.data.nodes.items) |node| {
            if (node.mesh) |mesh_idx| {
                mesh_count += 1;
                prim_count += gltf.data.meshes.items[mesh_idx].primitives.items.len;
            }
        }

        // Currently only glb files with embedded mesh data are supported
        const bin = gltf.glb_binary orelse return Model{
            .meshes = &.{},
            .primitives = &.{},
        };

        const meshes = try context.allocator.alloc(Render.backend.Mesh, mesh_count);
        errdefer context.allocator.free(meshes);
        const primitives = try context.allocator.alloc(Render.backend.Mesh.Primitive, prim_count);
        errdefer context.allocator.free(primitives);
        const pipeline_keys = try context.allocator.alloc(Pipeline.Key, prim_count);
        defer context.allocator.free(pipeline_keys);
        const texture_keys = try context.allocator.alloc(Texture.Key, prim_count);
        defer context.allocator.free(texture_keys);

        var mesh_alloc = std.heap.FixedBufferAllocator.init(mem.sliceAsBytes(meshes));
        var prim_alloc = std.heap.FixedBufferAllocator.init(mem.sliceAsBytes(primitives));
        var pip_key_alloc = std.heap.FixedBufferAllocator.init(mem.sliceAsBytes(pipeline_keys));
        var tex_key_alloc = std.heap.FixedBufferAllocator.init(mem.sliceAsBytes(texture_keys));

        var mesh_list = std.ArrayList(Render.backend.Mesh).initCapacity(mesh_alloc.allocator(), mesh_count) catch unreachable;
        var prim_list = std.ArrayList(Render.backend.Mesh.Primitive).initCapacity(prim_alloc.allocator(), prim_count) catch unreachable;
        var pip_key_list = std.ArrayList(Pipeline.Key).initCapacity(pip_key_alloc.allocator(), prim_count) catch unreachable;
        var tex_key_list = std.ArrayList(Texture.Key).initCapacity(tex_key_alloc.allocator(), prim_count) catch unreachable;

        for (gltf.data.nodes.items) |node| {
            const mesh_idx = node.mesh orelse continue;
            const prim_start_idx = prim_list.items.len;

            // gltf is colummn-major and zalgebra is row-major, we transpose here to avoid silly mistakes down the line.
            const matrix = if (node.matrix) |mat| zalgebra.Mat4.transpose(@bitCast(mat)) else zalgebra.Mat4.identity();
            const determinant = matrix.det();

            // https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#instantiation
            // Whether or not 0 is a positive number is up for debate...
            const winding: Render.backend.Winding = if (determinant > 0) .ccw else .cw;

            for (gltf.data.meshes.items[mesh_idx].primitives.items) |prim| {
                var primitive = Render.backend.Mesh.Primitive{
                    .positions = &.{},
                    .uv = .{ .v2u16 = &.{} },
                    .indices = .none,
                    .texture_handle = null,
                    .type = switch (prim.mode) {
                        .points => .points,
                        .lines => .lines,
                        .line_strip => .line_strip,
                        .triangles => .triangles,
                        .triangle_strip => .triangle_strip,
                        else => .triangle,
                    },
                };

                var is_missing_texcoords = true;
                for (prim.attributes.items) |attr| {
                    switch (attr) {
                        .position => |acc_idx| {
                            const acc = gltf.data.accessors.items[acc_idx];
                            if (acc.type != .vec3 or acc.component_type != .float) continue;

                            if (acc.buffer_view == null) continue;

                            var positions_list = std.ArrayList(f32).init(context.allocator);
                            errdefer positions_list.deinit();
                            gltf.getDataFromBufferView(f32, &positions_list, acc, bin);
                            primitive.positions = @ptrCast(try positions_list.toOwnedSlice());
                        },
                        .texcoord => |acc_idx| {
                            if (!is_missing_texcoords) continue; // TODO support multiple sets?

                            const acc = gltf.data.accessors.items[acc_idx];
                            if (acc.type != .vec2) continue;

                            if (acc.buffer_view == null) continue;

                            primitive.uv = switch (acc.component_type) {
                                .unsigned_byte => continue, // TODO support?
                                .unsigned_short => blk: {
                                    var uv_list = std.ArrayList(u16).init(context.allocator);
                                    errdefer uv_list.deinit();
                                    gltf.getDataFromBufferView(u16, &uv_list, acc, bin);
                                    break :blk .{ .v2u16 = @ptrCast(try uv_list.toOwnedSlice()) };
                                },
                                .float => blk: {
                                    var uv_list = std.ArrayList(f32).init(context.allocator);
                                    errdefer uv_list.deinit();
                                    gltf.getDataFromBufferView(f32, &uv_list, acc, bin);
                                    break :blk .{ .v2f32 = @ptrCast(try uv_list.toOwnedSlice()) };
                                },
                                else => continue,
                            };
                            is_missing_texcoords = false;
                        },
                        else => continue,
                    }
                }
                if (prim.indices) |indices_idx| indices: {
                    const acc = gltf.data.accessors.items[indices_idx];
                    if (acc.type != .scalar) break :indices;

                    if (acc.buffer_view == null) break :indices;

                    primitive.indices = switch (acc.component_type) {
                        .unsigned_byte => .none, // TODO: support u8 indices?
                        .unsigned_short => blk: {
                            var indices_list = std.ArrayList(u16).init(context.allocator);
                            errdefer indices_list.deinit();
                            gltf.getDataFromBufferView(u16, &indices_list, acc, bin);
                            break :blk .{ .u16 = indices_list.toOwnedSlice() };
                        },
                        .unsigned_integer => blk: {
                            var indices_list = std.ArrayList(u32).init(context.allocator);
                            errdefer indices_list.deinit();
                            gltf.getDataFromBufferView(u32, &indices_list, acc, bin);
                            break :blk .{ .u32 = indices_list.toOwnedSlice() };
                        },
                        else => .none,
                    };
                }

                var cull = Render.backend.Cull.back;

                if (prim.material) |mat_idx| {
                    const material = gltf.data.materials.items[mat_idx];
                    if (material.is_double_sided) {
                        cull = .none;
                    }
                    var texture: union(enum) {
                        none,
                        key: Texture.Key,
                        image: zigimg.ImageUnmanaged,
                    } = .none;
                    var sampler = Sampler.default_key;

                    if (material.metallic_roughness.base_color_texture) |tex_info| {
                        const tex = gltf.data.textures.items[tex_info.index];
                        if (tex.source) |img_idx| source: {
                            const img = gltf.data.images.items[img_idx];
                            if (img.uri) |raw_uri| {
                                if (!mem.containsAtLeastScalar(u8, raw_uri, 1, ':')) {
                                    // Relative path. We interpret relative paths as being
                                    // relative to the assets/textures dir.
                                    try context.asset_manager.dispatchLoad(Texture, context.allocator, raw_uri);
                                    texture = .{ .key = raw_uri };
                                } else {
                                    const uri = try std.Uri.parse(raw_uri);
                                    if (mem.eql(uri.scheme, "data")) {
                                        // Image is embedded directly into the URI
                                        const raw_data: []const u8 = switch (uri.path) {
                                            // There shouldn't be any percent encoded data here,
                                            // if there is we will ignore it as it's malformed.
                                            inline else => |p| p,
                                        };
                                        const data_start = (mem.indexOfScalar(u8, raw_data, ',') orelse break :source) + 1;
                                        const is_base64 = mem.endsWith(u8, raw_data[0..data_start], ";base64,");
                                        if (is_base64) {
                                            const base64_data = raw_data[data_start..raw_data.len];
                                            const base64_dec = std.base64.standard.Decoder.init(std.base64.standard_alphabet_chars, '=');
                                            const img_data_len = base64_dec.calcSizeForSlice(base64_data);
                                            const img_data = try gltf.arena.allocator().alloc(u8, img_data_len);
                                            defer gltf.arena.allocator().free(img_data);

                                            try base64_dec.decode(img_data, base64_data);
                                            const image = try zigimg.ImageUnmanaged.fromMemory(context.allocator, img_data);
                                            texture = .{ .image = image };
                                        }
                                    }
                                }
                            } else if (img.data) |raw_data| {
                                // Image is embedded into GLB binary chunk
                                const image = try zigimg.ImageUnmanaged.fromMemory(context.allocator, raw_data);
                                texture = .{ .image = image };
                            }
                        }
                        if (tex.sampler) |smp_idx| {
                            const smp = gltf.data.samplers.items[smp_idx];
                            if (smp.min_filter) |min_filter| sampler.min_filter = switch (min_filter) {
                                .linear => .linear,
                                else => .nearest,
                            };
                            if (smp.mag_filter) |mag_filter| sampler.mag_filter = switch (mag_filter) {
                                .linear => .linear,
                                else => .nearest,
                            };
                            if (smp.wrap_s) |wrap_s| sampler.wrap_u = switch (wrap_s) {
                                .clamp_to_edge => .clamp_to_edge,
                                .mirrored => .mirrored_repeat,
                                else => .repeat,
                            };
                            if (smp.wrap_t) |wrap_t| sampler.wrap_v = switch (wrap_t) {
                                .clamp_to_edge => .clamp_to_edge,
                                .mirrored => .mirrored_repeat,
                                else => .repeat,
                            };
                        }
                    }
                }

                const tex_key = &.{};

                const pip_key = Pipeline.Key{
                    .shader = context.asset_manager.default_shader_context.shader,
                    .options = .{
                        .graphics = .{
                            .buffers = .{},
                            .attrs = .{
                                .{ // positions
                                    .location = 0,
                                    .binding = context.asset_manager.default_shader_context.bind_pos,
                                    .format = .v3f32,
                                    .offset = 0,
                                },
                                .{ // uv
                                    .location = 1,
                                    .binding = context.asset_manager.default_shader_context.bind_uv,
                                    .format = switch (primitive.uv) {
                                        .v2u16 => .v2u16,
                                        .v2f32 => .v2f32,
                                    },
                                    .offset = 0,
                                },
                                .{ // color
                                    .location = 2,
                                    .binding = context.asset_manager.default_shader_context.bind_color,
                                    .format = .v4u8,
                                },
                            },
                            .primitive = primitive.type,
                            .index = std.meta.activeTag(primitive.indices),
                            .cull = cull,
                        },
                    },
                };

                tex_key_list.append(tex_key) catch unreachable;
                pip_key_list.append(pip_key) catch unreachable;
                prim_list.append(primitive) catch unreachable;
            }
            var matrix: [16]f32 = undefined;
            if (node.has_matrix) matrix = node.matrix else cgltf.cgltf_node_transform_local(node, &matrix);
            const mesh = Render.backend.Mesh{
                .matrix = matrix,
                .primitives = prim_list.items[prim_start_idx..prim_list.items.len],
            };
            mesh_list.append(mesh) catch unreachable;
            gltf.nodes[0].mesh.*.primitives[0].material.*.extensions;
        }

        return Model{
            .arena_state = arena.state,
        };
    }

    pub fn unload(model: *Model, context: Manager.Context) void {
        var arena = model.arena_state.promote(context.allocator);
        arena.deinit();
        model.* = undefined;
    }

    pub fn toOwnedBytes(allocator: Allocator, key: Key) Allocator.Error![]const u8 {
        const magic_bytes = AssetMagic.path.asBytes();
        const bytes = try mem.concat(allocator, u8, &.{ &magic_bytes, key });
        return bytes;
    }

    fn cgltfAlloc(user_data: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        if (size == 0) {
            return null;
        }
        const arena_allocator: *const Allocator = @alignCast(@ptrCast(user_data));

        const alignment = mem.Alignment.fromByteUnits(
            @min(std.math.ceilPowerOfTwoAssert(usize, size), @alignOf(*anyopaque)),
        );
        const ptr = arena_allocator.rawAlloc(size, alignment, @returnAddress());
        return @ptrCast(ptr);
    }
    fn cgltfFree(user_data: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        _ = .{ user_data, ptr };
    }
};

pub const Pipeline = struct {
    pip: Render.backend.Pipeline,
    buffer: Render.backend.Buffer,
    used: usize,

    pub const Key = struct {
        shader: Render.backend.Shader,
        options: union(Render.backend.PipelineKind) {
            graphics: Render.backend.PipelineOptions(.graphics),
            compute: Render.backend.PipelineOptions(.compute),
        },
    };
    pub const Error = Allocator.Error;

    pub fn load(context: Manager.Context) Pipeline.Error!Pipeline {
        assert(hasMagic(.pipeline, context.bytes));

        const bytes = noMagic(context.bytes);
        var stream = std.io.fixedBufferStream(bytes);
        const reader = stream.reader();
        const key = s2s.deserializeAlloc(reader, Key, context.allocator) catch |err| switch (err) {
            .OutOfMemory => return Pipeline.Error.OutOfMemory,
            else => unreachable,
        };
        defer s2s.free(context.allocator, Key, &key);

        const kind = std.meta.activeTag(key.options);
        const pipeline = switch (kind) {
            inline else => |tag| Render.backend.createPipeline(tag, key.shader, @field(key.op, @tagName(tag))),
        };
        log.info("created {s} pipeline ({s})", .{ @tagName(kind), bytes });
        return .{ .pip = pipeline };
    }

    pub fn unload(pipeline: *Pipeline, context: Manager.Context) void {
        assert(hasMagic(.pipeline, context.bytes));

        Render.backend.destroyPipeline(pipeline.pip);
        log.info("destroyed pipeline ({s})", .{noMagic(context.bytes)});
    }

    pub fn toOwnedBytes(allocator: Allocator, key: Key) Allocator.Error![]const u8 {
        const min_cap = @sizeOf(AssetMagic) + @sizeOf(Key);
        var bytes = try std.ArrayList(u8).initCapacity(allocator, min_cap);
        errdefer bytes.deinit();
        bytes.append(AssetMagic.pipeline.asBytes()) catch unreachable;
        const writer = bytes.writer();
        try s2s.serialize(writer, Key, key);
        const owned = try bytes.toOwnedSlice();
        return owned;
    }
};

pub const Sampler = struct {
    smp: Render.backend.Sampler,

    pub const Key = Render.backend.SamplerOptions;
    pub const Error = error{};

    pub const default_key = Key{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .wrap_u = .repeat,
        .wrap_v = .repeat,
        .compare = .never,
    };

    pub fn load(context: Manager.Context) Sampler.Error!Sampler {
        assert(hasMagic(.sampler, context.bytes));

        const bytes = noMagic(context.bytes);
        var stream = std.io.fixedBufferStream(bytes);
        const reader = stream.reader();
        const options = s2s.deserialize(reader, Key) catch unreachable;

        const sampler = Render.backend.createSampler(options);
        log.info("created sampler ({s})", .{bytes});
        return .{ .smp = sampler };
    }

    pub fn unload(sampler: *Sampler, context: Manager.Context) void {
        assert(hasMagic(.sampler, context.bytes));

        Render.backend.destroySampler(sampler.smp);
        log.info("destroyed sampler ({s})", .{noMagic(context.bytes)});
    }

    pub fn toOwnedBytes(allocator: Allocator, key: Key) Allocator.Error![]const u8 {
        const min_cap = @sizeOf(AssetMagic) + @sizeOf(Key);
        var bytes = try std.ArrayList(u8).initCapacity(allocator, min_cap);
        errdefer bytes.deinit();
        bytes.append(AssetMagic.sampler.asBytes()) catch unreachable;
        const writer = bytes.writer();
        try s2s.serialize(writer, Key, key);
        const owned = try bytes.toOwnedSlice();
        return owned;
    }
};

pub const Map = struct {
    display_name: [*:0]const u8,
    texture_name: [*:0]const u8,
    control_points: []const [2]f32,

    pub const Error = error{};

    pub fn load(memory: []const u8) Map.Error!void {
        _ = memory;
    }
    pub fn unload(map: *Map) void {
        _ = map;
    }
};

// TESTS

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
