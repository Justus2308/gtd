const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");
const atomic = std.atomic;
const mem = std.mem;
const linalg = geo.linalg;
const Allocator = mem.Allocator;
const Dir = std.fs.Dir;
const File = std.fs.File;
const assert = std.debug.assert;
const log = std.log.scoped(.assets);

// TODO: split assets into separate arrays for each category?

/// Manages loading and caching assets from disk and lets multiple consumers
/// share cached assets safely among multiple threads.
/// Asset handles created by this manager are stable and remain valid until
/// it is deinitialized.
/// Preregister as many assets as possible to avoid exclusive locks during
/// operation.
pub const Manager = struct {
    arena: std.heap.ArenaAllocator,

    path_to_handle: stdx.ConcurrentStringHashMapUnmanaged(Handle),
    handle_to_location: stdx.ConcurrentAutoHashMapUnmanaged(Handle, Location),

    next_handle: atomic.Value(Handle),

    asset_dir: *Dir,

    pub const Error = Allocator.Error ||
        File.OpenError ||
        Dir.OpenError ||
        posix.MMapError ||
        Cached.Texture.Error ||
        Cached.Model.Error ||
        Cached.Map.Error ||
        error{ UnknownAssetHandle, TooManyAttempts, AssetAlreadyRegistered };

    /// Uniquely identifies an asset.
    pub const Handle = u32;

    /// Locations are only destroyed at manager `deinit()`
    /// so references to them remain valid once obtained.
    /// All member functions are thread-safe and lock-free.
    const Location = struct {
        /// Cache line aligned to avoid false sharing with neighbouring Locations.
        state: atomic.Value(State) align(atomic.cache_line),
        path_rel_len: u32,
        path_rel_ptr: [*]const u8,
        context: *anyopaque,

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

        pub fn init(
            comptime Context: type,
            allocator: Allocator,
            path_rel: []const u8,
        ) Allocator.Error!Location {
            const path_rel_duped = try allocator.dupe(u8, path_rel);
            errdefer allocator.free(path_rel_duped);
            const context = allocator.create(Context);
            return Location{
                .state = .init(.unloaded),
                .path_rel_len = @intCast(path_rel_duped.len),
                .path_rel_ptr = path_rel_duped.ptr,
                .context = @ptrCast(context),
            };
        }
        pub fn deinit(
            location: *Location,
            comptime Context: type,
            allocator: Allocator,
        ) void {
            const ok = location.unload();
            assert(ok);
            allocator.free(location.pathRel());
            allocator.destroy(@as(*Context, @ptrCast(location.context)));
            location.* = undefined;
        }

        pub fn load(
            location: *Location,
            comptime Context: type,
            asset_dir: Dir,
        ) Error!void {
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
                // Some other thread has preempted us, we are done.
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
            // Load from file.
            {
                const file = try asset_dir.openFile(location.getPathRel(), .{
                    .mode = .read_only,
                    .lock = .exclusive,
                });
                defer file.close();

                const mapped_file = try mapFileToMemory(file);
                defer unmapFileFromMemory(mapped_file);

                try @as(*Context, @ptrCast(location.context)).load(mapped_file);
            }
            // Signal to other threads that we are done if our load succeeds.
            location.state.store(.unreferenced, .release);
        }
        pub fn unload(location: *Location, comptime Context: type) bool {
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
                // Either we were preempted or there are still active
                // references to this asset.
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
            @as(*Context, @ptrCast(location.context)).unload();
            location.state.store(.unloaded, .release);
            return true;
        }

        pub inline fn getContext(location: Location, comptime Context: type) *const Context {
            return @as(*const Context, @ptrCast(location.context));
        }

        pub inline fn getPathRel(location: Location) []const u8 {
            return location.path_rel_ptr[0..location.path_rel_len];
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
                    log.warn("reached max reference count for location of '{s}'", .{
                        location.path_rel,
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
                    log.warn("reached max reference count for location of '{s}'", .{
                        location.path_rel,
                    });
                    return false;
                },
            }
        }
    };

    pub fn init(gpa: Allocator, asset_dir: *Dir) Manager {
        return .{
            .arena = .init(gpa),

            .path_to_handle = .empty,
            .handle_to_location = .empty,

            .next_handle = .init(0),

            .asset_dir = asset_dir,
        };
    }

    pub fn deinit(m: *Manager) void {
        // TODO unload assets?
        m.arena.deinit();
        m.* = undefined;
        log.debug("asset manager deinitialized", .{});
    }

    /// Only locks exclusively if the asset hasn't been registered yet.
    /// Exclusive locks only apply to subsets of the hash maps and do
    /// not necessarily block other concurrent accesses.
    pub fn load(
        m: *Manager,
        comptime Context: type,
        path_rel: []const u8,
    ) Error!Handle {
        validateContext(Context);
        const allocator = m.arena.allocator();
        const handle = try m.getHandle(Context, path_rel);
        const location = m.handle_to_location.getPtr(handle) orelse location: {
            const location = try Location.init(Context, allocator, path_rel);
            errdefer location.deinit(allocator);
            const ptr = try m.handle_to_location.putAndGetPtr(allocator, handle, location);
            break :location ptr;
        };
        try location.load(Context, m.asset_dir.*);
        return handle;
    }

    pub fn unload(m: *Manager, comptime Context: type, handle: Handle) bool {
        validateContext(Context);
        const location = m.handle_to_location.getPtr(handle) orelse return false;
        return location.unload(Context);
    }

    pub fn get(
        m: *Manager,
        comptime Context: type,
        handle: Handle,
    ) Error!*const Context {
        validateContext(Context);
        const location = m.handle_to_location.getPtr(handle) orelse
            return Error.UnknownAssetHandle;
        while (!location.addReference()) {
            try location.load(Context, m.asset_dir.*);
        }
        return location.getContext(Context);
    }

    /// On success this only performs one shared-locked hash table lookup
    /// and one weak CAS loop.
    /// This function will not wait for anything and return `null` instead.
    pub fn tryGet(m: *Manager, comptime Context: type, handle: Handle) ?*const Context {
        validateContext(Context);
        const location = m.handle_to_location.tryGetPtr(handle) orelse return null;
        if (location.addReferenceIfCached()) {
            return location.getContext(Context);
        } else {
            return null;
        }
    }

    pub fn getHandle(
        m: *Manager,
        comptime Context: type,
        path_rel: []const u8,
    ) Error!Handle {
        validateContext(Context);
        const allocator = m.arena.allocator();
        const handle = m.path_to_handle.get(path_rel) orelse handle: {
            const handle = m.next_handle.fetchAdd(1, .acq_rel);
            try m.path_to_handle.put(allocator, path_rel, handle);
            break :handle handle;
        };
        return handle;
    }

    pub fn unget(m: *Manager, handle: Handle) bool {
        const location = m.handle_to_location.getPtr(handle) orelse return false;
        location.removeReference();
        return true;
    }

    fn validateContext(comptime Context: type) void {
        if (!std.meta.hasMethod(Context, "load") or !std.meta.hasMethod(Context, "unload")) {
            @compileError("Context needs load and unload");
        }
    }
    pub const Cached = union(enum) {
        texture: Texture,
        model: Model,
        map: Map,

        pub const Kind = std.meta.Tag(Cached);

        pub fn init(comptime kind: Cached.Kind, memory: []const u8) Error!Cached {
            return @unionInit(Cached, @tagName(kind), .load(memory));
        }
        pub fn deinit(cached: *Cached) void {
            switch (cached) {
                inline else => |inner| inner.unload(),
            }
            cached.* = undefined;
        }
    };

    // I mainly use memory mapping here to keep things simple, using files would either mean
    // leaving file operations to the C depencencies (which is problematic because that would
    // require an absolute path to each asset which we do not have) or providing custom read
    // callbacks which have to satisfy sparsely documented specifications.
    // It's just easier to use plain memory buffers to read/parse from and for the kind of
    // data we're dealing with it probably won't make a difference in performance anyways.

    fn mapFileToMemory(file: File) Error![]align(std.heap.page_size_min) const u8 {
        const size = try file.getEndPos();
        if (size == 0) {
            return &.{};
        }
        switch (target_os) {
            .windows => {
                const map_handle = CreateFileMappingA(
                    file.handle,
                    null,
                    windows.PAGE_READONLY,
                    0,
                    0,
                    null,
                );
                if (map_handle == null) {
                    return switch (windows.GetLastError()) {
                        .ALREADY_EXISTS => Error.MappingAlreadyExists,
                        .NOT_ENOUGH_MEMORY => Error.OutOfMemory,
                        .FILE_INVALID => unreachable,
                        else => |err| windows.unexpectedError(err),
                    };
                }
                defer windows.CloseHandle(map_handle);
                const mapped = MapViewOfFile(map_handle, FILE_MAP_READ, 0, 0, 0);
                if (mapped == null) {
                    return switch (windows.GetLastError()) {
                        else => |err| windows.unexpectedError(err),
                    };
                }
                return @alignCast(@as([*]u8, @ptrCast(mapped))[0..size]);
            },
            else => {
                // This should be ok on emscripten as long
                // as we don't modify the mapped file while
                // this mapping exists.
                const mapped = try posix.mmap(
                    null,
                    size,
                    posix.PROT.READ,
                    .{ .TYPE = .PRIVATE },
                    file.handle,
                    0,
                );
                return mapped;
            },
        }
    }
    fn unmapFileFromMemory(mapped_file: []align(std.heap.page_size_min) const u8) void {
        if (mapped_file.len == 0) {
            return;
        }
        switch (target_os) {
            .windows => {
                const ok = UnmapViewOfFile(@ptrCast(mapped_file.ptr));
                assert(ok);
            },
            else => {
                posix.munmap(mapped_file);
            },
        }
    }

    const target_os = @import("builtin").target.os.tag;
    const posix = std.posix;
    const windows = std.os.windows;

    const FILE_MAP_READ: windows.DWORD = 4;

    extern "kernel32" fn CreateFileMappingA(
        hFile: windows.HANDLE,
        lpFileMappingAttributes: ?*windows.SECURITYATTRIBUTES,
        flProtect: windows.DWORD,
        dwMaximumSizeHigh: windows.DWORD,
        dwMaximumSizeLow: windows.DWORD,
        lpName: ?windows.LPCSTR,
    ) callconv(.winapi) windows.HANDLE;

    extern "kernel32" fn MapViewOfFile(
        hFileMappingObject: windows.HANDLE,
        dwDesiredAccess: windows.DWORD,
        dwFileOffsetHigh: windows.DWORD,
        dwFileOffsetLow: windows.DWORD,
        dwNumberOfBytesToMap: windows.SIZE_T,
    ) callconv(.winapi) windows.LPVOID;

    extern "kernel32" fn UnmapViewOfFile(
        lpBaseAddress: windows.LPCVOID,
    ) callconv(.winapi) windows.BOOL;
};

// Contexts

pub const Texture = struct {
    width: u16,
    height: u16,
    channels: u16,
    sprite_row_count: u8,
    sprite_col_count: u8,
    data: []u8,

    pub const Error = error{Stbi};

    const stbi = @import("stbi");

    pub fn load(memory: []const u8) Texture.Error!Texture {
        var width: c_int, var height: c_int, var channels: c_int = undefined;
        const data_raw: [*]u8 = stbi.stbi_load_from_memory(
            memory.ptr,
            @intCast(memory.len),
            &width,
            &height,
            &channels,
            0,
        ) orelse {
            @branchHint(.cold);
            std.log.scoped(.stbi).err("image load failed: {s}", .{
                stbi.stbi_failure_reason() orelse "no reason provided",
            });
            return Texture.Error.Stbi;
        };
        const data = data_raw[0..(width * height * channels)];
        return Texture{
            .width = @intCast(width),
            .height = @intCast(height),
            .channels = @intCast(channels),
            .data = data,
        };
    }
    pub fn unload(texture: *Texture) void {
        stbi.stbi_image_free(texture.data.ptr);
        texture.* = undefined;
    }
};

pub const Model = struct {
    texture_name: [*:0]const u8,
    data: *cgltf.cgltf_data,

    pub const Error = error{Ufbx};

    const cgltf = @import("cgltf");

    pub fn load(memory: []const u8) Model.Error!Model {
        const out_data_ptr: *cgltf.cgltf_data = undefined;
        const res = cgltf.cgltf_parse(null, memory.len, memory.size, &out_data_ptr);
        if (res != cgltf.cgltf_result_success) {
            std.log.scoped(.cgltf).err("model load failed: code {d}", .{res});
        }
        return Model{ .data = out_data_ptr };
    }
    pub fn unload(model: *Model) void {
        cgltf.cgltf_free(model.data);
        model.* = undefined;
    }
};

pub const Map = struct {
    display_name: [*:0]const u8,
    texture_name: [*:0]const u8,
    control_points: []linalg.v2f32.V,

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
        @import("global").asset_path_rel,
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
