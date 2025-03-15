//! Use this to uniquely describe assets.

name: []const u8,
kind: Kind,

const Asset = @This();

pub const Kind = enum {
    texture_plain,
    texture_sprite,
    model,
    map,

    pub fn toSubPath(kind: Kind) []const u8 {
        return switch (kind) {
            .texture_plain => "textures/plain",
            .texture_sprite => "textures/sprites",
            .model => "models",
            .map => "maps",
        };
    }
};

pub fn init(name: []const u8, kind: Kind) Asset {
    return .{ .name = name, .kind = kind };
}

pub fn getPathRel(asset: Asset, allocator: Allocator) Allocator.Error![]const u8 {
    const sub_path = asset.kind.toSubPath();
    return std.fs.path.join(allocator, &.{ sub_path, asset.name });
}

const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");
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
pub const Manager = struct {
    asset_to_handle: std.HashMapUnmanaged(
        Asset,
        Handle,
        asset_to_handle_ctx,
        std.hash_map.default_max_load_percentage,
    ),
    handle_to_location: std.AutoHashMapUnmanaged(Handle, Location),

    next_handle: Handle,
    lock: std.Thread.RwLock,

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

    const asset_to_handle_ctx = struct {
        pub fn hash(ctx: asset_to_handle_ctx, key: Asset) u64 {
            _ = ctx;
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key, .Deep);
            return hasher.final();
        }
        pub fn eql(ctx: asset_to_handle_ctx, a: Asset, b: Asset) bool {
            _ = ctx;
            return ((a.kind == b.kind) and mem.eql(u8, a.name, b.name));
        }
    };

    /// Locations are only destroyed at manager `deinit()`
    /// so references to them remain valid once obtained.
    const Location = struct {
        path_rel_ptr: [*]const u8,
        ref_count: std.atomic.Value(u32),
        metadata: Metadata,
        cached: Cached,

        pub const Metadata = packed struct(u32) {
            path_rel_len: u30,
            is_cached: bool,
            is_referenced: bool,
        };

        pub fn init(allocator: Allocator, asset: Asset) Allocator.Error!Location {
            const path_rel = try asset.getPathRel(allocator);
            const cached: Cached = switch (asset.kind) {
                .texture_plain, .texture_sprite => .{ .texture = undefined },
                .model => .{ .model = undefined },
                .map => .{ .map = undefined },
            };
            return Location{
                .path_rel_ptr = path_rel.ptr,
                .ref_count = .init(0),
                .metadata = .{
                    .path_rel_len = @intCast(path_rel.len),
                    .is_cached = false,
                    .is_referenced = false,
                },
                .cached = cached,
            };
        }
        pub fn deinit(location: *Location, allocator: Allocator) void {
            assert(!location.isReferenced());
            if (location.isCached()) {
                location.unload();
            }
            allocator.free(location.getPathRel());
            location.* = undefined;
        }

        pub fn load(location: *Location, memory: []const u8) Error!void {
            assert(!location.isCached());
            switch (location.cached) {
                inline else => |cached| try cached.load(memory),
            }
            location.metadata.is_cached = true;
        }
        pub fn unload(location: *Location) void {
            assert(location.isCached());
            assert(!location.isReferenced());
            switch (location.cached) {
                inline else => |cached| cached.unload(),
            }
            location.metadata.is_cached = false;
        }

        pub inline fn getPathRel(location: Location) []const u8 {
            return location.path_rel_ptr[0..location.metadata.path_rel_len];
        }

        pub inline fn isCached(location: Location) bool {
            return location.metadata.is_cached;
        }

        pub inline fn isReferenced(location: Location) bool {
            return location.metadata.is_referenced;
        }
        pub inline fn addReference(location: *Location) void {
            // do not check for overflow if that happens it's so over
            _ = location.ref_count.fetchAdd(1, .acq_rel);
        }
        pub inline fn removeReference(location: *Location) void {
            assert(location.isReferenced());
            const old_count = location.ref_count.fetchSub(1, .acq_rel);
            location.metadata.is_referenced = (old_count > 1);
        }
        pub inline fn addReferenceIfCached(location: *Location) ?Cached {
            const cached = location.cached orelse return null;
            location.addReference();
            return cached;
        }
    };

    pub fn init(asset_dir: *Dir) Manager {
        return .{
            .asset_to_handle = .empty,
            .handle_to_location = .empty,

            .next_handle = 0,
            .lock = .{},

            .asset_dir = asset_dir,
        };
    }

    /// Invalidates all assets. Asserts that no assets are referenced.
    pub fn deinit(m: *Manager, allocator: Allocator) void {
        var asset_iter = m.asset_to_handle.keyIterator();
        while (asset_iter.next()) |asset| {
            allocator.free(asset.name);
        }
        m.asset_to_handle.deinit(allocator);
        var location_iter = m.handle_to_location.valueIterator();
        while (location_iter.next()) |location| {
            location.deinit(allocator);
        }
        m.handle_to_location.deinit(allocator);
        log.debug("asset manager deinitialized", .{});
        m.* = undefined;
    }

    /// Generate handles for all assets in `asset_dir`.
    pub fn discoverAssets(
        m: *Manager,
        allocator: Allocator,
    ) Error!void {
        m.lock.lock();
        defer m.lock.unlock();

        inline for (std.enums.values(Asset.Kind)) |kind| {
            const sub_path = kind.toSubPath();
            const asset_kind_dir = try m.asset_dir.openDir(sub_path, .{});
            defer asset_kind_dir.close();
            var iter = asset_kind_dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .file) {
                    const asset = Asset.init(std.fs.path.stem(entry.name), kind);
                    try m.registerAsset(allocator, asset);
                }
            }
        }
    }

    const max_get_attempts = 5;

    /// Only locks manager exclusively when asset is not in cache anymore.
    /// This comes at the cost of more locking actions and double checks in
    /// case of a load.
    /// Adds a reference to the asset associated with `handle`.
    pub fn get(
        m: *Manager,
        allocator: Allocator,
        handle: Handle,
    ) Error!Cached {
        m.lock.lockShared();
        defer m.lock.unlockShared();

        const location = m.handle_to_location.getPtr(handle) orelse
            return Error.UnknownAssetHandle;
        for (0..max_get_attempts) |_| {
            if (location.addReferenceIfCached()) |cached| {
                @branchHint(.likely);
                return cached;
            } else {
                // This is the slow path anyway because we have to read from disk
                // so a couple more locking operations and double checks won't hurt
                @branchHint(.unlikely);
                m.lock.unlockShared();
                m.lock.lock();
                defer {
                    m.lock.unlock();
                    m.lock.lockShared();
                }
                if (!location.isCached()) {
                    @branchHint(.likely);
                    _ = try m.cacheAsset(allocator, location);
                }
            }
        } else {
            @branchHint(.cold);
            return Error.TooManyAttempts;
        }
    }

    /// Non-blocking.
    /// This function will never modify the asset cache.
    /// Adds a reference to the asset associated with `handle`.
    pub fn tryGet(
        m: *Manager,
        comptime kind: Cached.Kind,
        handle: Handle,
    ) ?Cached {
        if (!m.lock.tryLockShared()) return null;
        defer m.lock.unlockShared();

        const location = m.handle_to_location.getPtr(handle) orelse return null;
        return location.addReferenceIfCached(kind);
    }

    /// Does not add a reference to the asset associated with the handle.
    pub fn getHandle(m: *Manager, allocator: Allocator, asset: Asset) Error!Handle {
        m.lock.lockShared();
        defer m.lock.unlockShared();

        const handle = m.asset_to_handle.get(asset) orelse handle: {
            m.lock.unlockShared();
            m.lock.lock();
            defer {
                m.lock.unlock();
                m.lock.lockShared();
            }
            // Double check, new entry could have been
            // inserted between unlockShared and lock
            if (m.asset_to_handle.get(asset)) |handle| {
                @branchHint(.cold);
                return handle;
            }
            const handle = m.registerAsset(allocator, asset);
            break :handle handle;
        };
        return handle;
    }

    /// Call after `get()` to signal that you don't need the asset any longer.
    /// Removes a reference to the asset associated with `handle`.
    pub fn unget(m: *Manager, handle: Handle) void {
        m.lock.lockShared();
        defer m.lock.unlockShared();

        const location = m.handle_to_location.getPtr(handle) orelse return;

        assert(location.isReferenced());
        location.removeReference();
    }

    /// Possibly invalidates all references to this asset. Use with care.
    pub fn ungetAll(m: *Manager, handle: Handle) void {
        m.lock.lock();
        defer m.lock.unlock();

        const location = m.handle_to_location.getPtr(handle) orelse return;

        if (location.isReferenced()) {
            log.warn("ungetAll() called on referenced asset {s}:{d}: {d} references left", .{
                location.getPathRel(),
                handle,
                location.ref_count.load(.unordered),
            });
        }
        location.ref_count.store(0, .unordered);
    }

    /// Locks manager exclusively.
    /// Does not add a reference to the asset associated with the handle.
    pub fn load(m: *Manager, allocator: Allocator, asset: Asset) Error!Handle {
        m.lock.lock();
        defer m.lock.unlock();
        const handle, _ = try m.loadInner(allocator, asset);
        return handle;
    }

    /// Locks manager exclusively.
    /// Does not add references to the assets associated with the handles.
    pub fn loadMany(m: *Manager, allocator: Allocator, assets: []Asset) Error![]Handle {
        m.lock.lock();
        defer m.lock.unlock();

        const handles = try allocator.alloc(Handle, assets.len);
        errdefer allocator.free(handles);
        for (assets, handles) |asset, *handle| {
            handle.*, _ = try m.loadInner(allocator, asset);
        }
        return handles;
    }

    /// Locks manager exclusively.
    /// Adds a reference to the asset associated with `handle`.
    pub fn loadAndGet(
        m: *Manager,
        allocator: Allocator,
        asset: Asset,
    ) Error!struct { Handle, Cached } {
        m.lock();
        defer m.lock.unlock();
        const handle, const location = try m.loadInner(allocator, asset);
        const cached = location.addReferenceIfCached().?;
        return .{ handle, cached };
    }

    inline fn loadInner(m: *Manager, allocator: Allocator, asset: Asset) Error!struct { Handle, *Location } {
        const handle = m.asset_to_handle.get(asset) orelse handle: {
            @branchHint(.unlikely);
            const handle = m.registerAsset(allocator, asset);
            break :handle handle;
        };
        const location = m.handle_to_location.getPtr(handle) orelse location: {
            @branchHint(.unlikely);
            const location = try Location.init(allocator, asset);
            errdefer location.deinit(allocator);
            try m.handle_to_location.putNoClobber(allocator, handle, location);
            break :location m.handle_to_location.getPtr(handle).?;
        };
        if (!location.isCached()) {
            _ = try m.cacheAsset(allocator, location);
        }
        return location;
    }

    /// Locks manager exclusively ; invalidates all references to the cached asset on success.
    /// Returns `true` on success and `false` if the asset associated with `handle`
    /// is still referenced and thus cannot be unloaded yet.
    pub fn unload(m: *Manager, allocator: Allocator, handle: Handle) bool {
        m.lock.lock();
        defer m.lock.unlock();

        const location = m.handle_to_location.getPtr(handle) orelse return;
        if (location.isReferenced()) {
            @branchHint(.unlikely);
            return false;
        }
        m.uncacheAsset(allocator, location);
        return true;
    }

    /// Unload all cached assets that aren't referenced by anything.
    pub fn unloadAll(m: *Manager, allocator: Allocator) void {
        m.lock.lock();
        defer m.lock.unlock();

        const location_iter = m.handle_to_location.valueIterator();
        while (location_iter.next()) |location| {
            if (!location.isReferenced()) {
                m.uncacheAsset(allocator, location);
            }
        }
    }

    /// Assumes that an exclusive lock is held.
    /// Duplicates `asset`.
    inline fn registerAsset(m: *Manager, allocator: Allocator, asset: Asset) Error!Handle {
        const handle = m.nextHandle();
        const asset_name_duped = try allocator.dupe(u8, asset.name);
        errdefer allocator.free(asset_name_duped);
        const gop = try m.asset_to_handle.getOrPut(allocator, asset);
        assert(!gop.found_existing);
        gop.key_ptr.name = asset_name_duped;
        gop.value_ptr.* = handle;
        return handle;
    }

    /// Asserts that asset is not in cache yet.
    /// Assumes that an exclusive lock is held.
    inline fn cacheAsset(m: *Manager, allocator: Allocator, location: *Location) Error!Cached {
        _ = allocator;

        const file = try m.asset_dir.openFile(location.path_rel, .{
            .mode = .read_only,
            .lock = .exclusive,
        });
        defer file.close();

        const mapped_file = try mapFileToMemory(file);
        defer unmapFileFromMemory(mapped_file);

        try location.load(mapped_file);
        return location.cached;
    }

    /// Asserts that asset is not referenced.
    /// Assumes that an exclusive lock is held.
    inline fn uncacheAsset(
        m: *Manager,
        allocator: Allocator,
        location: *Location,
    ) void {
        _ = m;
        _ = allocator;

        location.unload();
    }

    /// Assumes that an exclusive lock is held.
    inline fn nextHandle(m: *Manager) Handle {
        const handle = m.next_handle;
        m.next_handle += 1;
        return handle;
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

        const Texture = struct {
            width: u16,
            height: u16,
            channels: u16,
            sprite_row_count: u8,
            sprite_col_count: u8,
            data: []u8,

            pub const Kind = enum { plain, sprite };
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

        const Model = struct {
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

        const Map = struct {
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

// TESTS

const testing = std.testing;

test "load/unload sprite" {
    const m = Asset.Manager.init;
    defer m.deinit(testing.allocator);
    const sprite = Asset.init("goons", .texture_sprite);
    const handle = try m.load(testing.allocator, sprite);
    defer m.unload(testing.allocator, handle);
    _ = m.tryGet(.texture, handle).?;
    defer m.unget(handle);
}

test "load/unload model" {
    const m = Asset.Manager.init;
    defer m.deinit(testing.allocator);
    const model = Asset.init("airship", .model);
    const handle = try m.load(testing.allocator, model);
    defer m.unload(testing.allocator, handle);
    _ = m.tryGet(.model, handle).?;
    defer m.unget(handle);
}

test "load/unload map" {
    return error.SkipZigTest;
}

test "load/unload any" {
    const m = Asset.Manager.init;
    defer m.deinit(testing.allocator);
    const sprite = Asset.init("goons", .texture_sprite);
    const handle = try m.load(testing.allocator, sprite);
    defer m.unload(testing.allocator, handle);
    const cached = m.tryGet(.any, handle).?;
    try testing.expect(std.meta.activeTag(cached) == .texture);
    defer m.unget(handle);
}
