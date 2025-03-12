//! Use this to describe assets at comptime and `Handle`
//! to reference them at runtime.

name: []const u8,
kind: Kind,

const Asset = @This();

pub const Handle = u32;

pub const Kind = enum {
    texture_plain,
    texture_sprite,
    model,
    map,
};

pub fn init(name: []const u8, kind: Kind) Asset {
    return .{ .name = name, .kind = kind };
}

pub fn getPathRel(asset: Asset, allocator: Allocator) Allocator.Error![]const u8 {
    const sub_path = switch (asset.kind) {
        .texture_plain => "texture/plain",
        .texture_sprite => "texture/sprite",
        .model => "model",
        .map => "map",
    };
    return std.fs.path.join(allocator, &.{ sub_path, asset.name });
}

const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");
const global = @import("global");
const stbi = @import("stbi");
const cgltf = @import("cgltf");
const linalg = geo.linalg;
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const assert = std.debug.assert;
const log = std.log.scoped(.assets);

// TODO: split assets into separate arrays for each category?

/// Manages loading and caching assets from disk and lets multiple consumers
/// share cached assets safely among multiple threads.
/// Asset handles created by this manager are stable and remain valid until
/// it is deinitialized.
pub const Manager = struct {
    name_to_handle: std.StringHashMapUnmanaged(Asset.Handle),
    handle_to_location: std.AutoHashMapUnmanaged(Asset.Handle, Location),
    cache: std.ArrayListUnmanaged(Asset.Cached),

    next_handle: Asset.Handle,
    lock: std.Thread.RwLock,

    pub const Error = Allocator.Error ||
        File.OpenError ||
        MappedFile.Error ||
        Asset.Cached.Texture.Error ||
        Asset.Cached.Model.Error ||
        error{ UnknownAssetHandle, TooManyAttempts };

    /// Locations are only destroyed at manager `deinit()`
    /// so references to them remain valid once obtained.
    const Location = struct {
        index: Index,
        ref_count: std.atomic.Value(u32),
        path_rel: []const u8,
        asset_kind: Asset.Kind,

        pub const Index = enum(u32) {
            none = std.math.maxInt(u32),
            _,

            pub inline fn at(value_: u32) Index {
                assert(value_ != @intFromEnum(Index.none));
                return @enumFromInt(value_);
            }
            pub inline fn value(index: Index) ?u32 {
                return if (index == .none) null else @intFromEnum(index);
            }
        };

        pub inline fn addReference(location: *Location) void {
            // do not check for overflow if that happens it's so over
            location.ref_count.fetchAdd(1, .acq_rel);
        }
        pub inline fn removeReference(location: *Location) void {
            assert(location.isReferenced());
            location.ref_count.fetchSub(1, .acq_rel);
        }
        pub inline fn isReferenced(location: *const Location) bool {
            return (location.ref_count.load(.acquire) > 0);
        }
    };

    pub const init = Manager{
        .name_to_handle = .empty,
        .handle_to_location = .empty,
        .cache = .empty,

        .next_handle = 0,
        .lock = .{},
    };

    /// Invalidated all assets. Asserts that no assets are referenced.
    pub fn deinit(m: *Manager, allocator: Allocator) void {
        m.name_to_handle.deinit(allocator);
        var location_iter = m.handle_to_location.valueIterator();
        while (location_iter.next()) |location| {
            assert(!location.isReferenced());
            allocator.free(location.path_rel);
        }
        m.handle_to_location.deinit(allocator);
        for (m.cache.items) |cached| {
            switch (cached) {
                .texture => |texture| texture.unload(),
                .model => |model| model.unload(allocator),
                .map => @panic("TODO: implement"),
                .tombstone => {},
            }
        }
        m.cache.deinit(allocator);
        log.debug("asset manager deinitialized", .{});
        m.* = undefined;
    }

    const max_get_attempts = 5;

    /// Only locks manager exclusively when asset is not in cache anymore.
    /// This comes at the cost of more locking actions and double checks in
    /// case of a load.
    /// Adds a reference to the asset associated with `handle`.
    pub fn get(
        m: *Manager,
        allocator: Allocator,
        handle: Asset.Handle,
    ) Error!Asset.Cached {
        m.lock.lockShared();
        defer m.lock.unlockShared();

        const location = m.handle_to_location.getPtr(handle) orelse
            return Error.UnknownAssetHandle;
        const idx = location.index.value() orelse for (0..max_get_attempts) |_| {
            // This is the slow path anyway because we have to read from disk
            // so a couple more locking operations and double checks won't hurt
            @branchHint(.unlikely);
            {
                m.lock.unlockShared();
                m.lock.lock();
                defer {
                    m.lock.unlock();
                    m.lock.lockShared();
                }
                if (location.index == .none) {
                    @branchHint(.likely);
                    _ = try m.cacheAsset(allocator, handle, location);
                }
            }
            if (location.index.value()) |idx| {
                @branchHint(.likely);
                break idx;
            }
        } else {
            @branchHint(.cold);
            return Error.TooManyAttempts;
        };
        const cached = m.cache.items[idx];
        assert(cached != .tombstone);
        location.addReference();
        return cached;
    }

    /// Guaranteed to succeed and never lock exclusively.
    /// This function will never modify the asset cache.
    /// Adds a reference to the asset associated with `handle`.
    pub fn getIfCached(m: *Manager, handle: Handle) ?Asset.Cached {
        m.lock.lockShared();
        defer m.lock.unlockShared();

        const location = m.handle_to_location.getPtr(handle) orelse return null;
        const idx = location.index.value() orelse return null;
        const cached = m.cache.items[idx];
        assert(cached != .tombstone);
        location.addReference();
        return cached;
    }

    /// Does not add a reference to the asset associated with the handle.
    pub fn getHandle(m: *Manager, allocator: Allocator, asset: Asset) Error!Handle {
        m.lock.lockShared();
        defer m.lock.unlockShared();

        const handle = m.name_to_handle.get(asset.name) orelse handle: {
            m.lock.unlockShared();
            m.lock.lock();
            defer {
                m.lock.unlock();
                m.lock.lockShared();
            }
            // Double check, new entry could have been
            // inserted between unlockShared and lock
            if (m.name_to_handle.get(asset.name)) |handle| {
                @branchHint(.cold);
                return handle;
            }
            const handle = m.nextHandle();
            try m.name_to_handle.putNoClobber(allocator, asset.name, handle);
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
                location.path_rel,
                handle,
                location.ref_count.load(.unordered),
            });
        }
        location.ref_count.store(0, .unordered);
    }

    /// Locks manager exclusively.
    /// Does not add a reference to the asset associated with the handle.
    pub fn load(m: *Manager, allocator: Allocator, asset: Asset) Error!void {
        m.lock.lock();
        defer m.lock.unlock();
        _ = try m.loadInner(allocator, asset);
    }

    /// Locks manager exclusively.
    /// Adds a reference to the asset associated with `handle`.
    pub fn loadAndGet(m: *Manager, allocator: Allocator, asset: Asset) Error!Asset.Cached {
        m.lock();
        defer m.lock.unlock();
        const location = try m.loadInner(allocator, asset);
        location.addReference();
        return m.cache.items[location.index.value().?];
    }

    inline fn loadInner(m: *Manager, allocator: Allocator, asset: Asset) Error!*Location {
        const handle = m.name_to_handle.get(asset.name) orelse handle: {
            @branchHint(.unlikely);
            const handle = m.nextHandle();
            try m.name_to_handle.putNoClobber(allocator, asset.name, handle);
            break :handle handle;
        };
        const location = m.handle_to_location.getPtr(handle) orelse location: {
            @branchHint(.unlikely);
            const location = Location{
                .index = .none,
                .ref_count = .init(0),
                .path_rel = try asset.getPathRel(allocator),
                .asset_kind = asset.kind,
            };
            try m.handle_to_location.putNoClobber(allocator, handle, location);
            break :location m.handle_to_location.getPtr(handle).?;
        };
        if (location.index == .none) {
            const idx = try m.cacheAsset(allocator, location);
            location.index = .at(idx);
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

    pub fn countCachedAssets(m: *Manager) usize {
        m.lock.lockShared();
        defer m.lock.unlockShared();
        const count = m.cache.items.len - m.countTombstones();
        return count;
    }
    pub fn countWastedCacheSlots(m: *Manager) usize {
        m.lock.lockShared();
        defer m.lock.unlockShared();
        const count = m.countTombstones();
        return count;
    }
    pub fn wastedCacheSlotPercentage(m: *Manager) std.math.IntFittingRange(0, 100) {
        m.lock.lockShared();
        defer m.lock.unlockShared();

        const tombstone_count = m.countTombstones();
        const percentage = ((100 * tombstone_count) / m.cache.items.len);
        assert(percentage <= 100);
        return @intCast(percentage);
    }
    /// Assumes that a shared lock is held.
    inline fn countTombstones(m: *Manager) usize {
        return std.mem.count(Asset.Cached, m.cache.items, &.{.tombstone});
    }

    /// Defragment and consolidate the cache array. Handles remain valid.
    pub fn defragment(m: *Manager, allocator: Allocator) void {
        m.lock.lock();
        defer m.lock.unlock();

        const location_iter = m.handle_to_location.valueIterator();
        outer: while (location_iter.next()) |location| {
            if (location.index.value()) |idx| {
                const free_idx = inner: for (0..idx) |i| {
                    if (m.cache.items[i] == .tombstone) {
                        @branchHint(.unlikely);
                        break :inner i;
                    }
                } else {
                    @branchHint(.unlikely);
                    break :outer;
                };
                m.cache.items[free_idx] = m.cache.items[idx];
                m.cache.items[idx] = .tombstone;
                location.index = .at(free_idx);
            }
        }
        const new_len = std.mem.trimRight(Asset.Cached, m.cache.items, &.{.tombstone}).len;
        m.cache.shrinkAndFree(allocator, new_len);
    }

    /// Asserts that asset is not in cache yet.
    /// Assumes that an exclusive lock is held.
    inline fn cacheAsset(
        m: *Manager,
        allocator: Allocator,
        location: *Location,
    ) Error!u32 {
        assert(location.index == .none);

        const file = try global.asset_dir.openFile(location.path_rel, .{
            .mode = .read_only,
            .lock = .exclusive,
        });
        defer file.close();

        const mapped_file = try MappedFile.map(file);
        defer mapped_file.unmap();

        const cached: Asset.Cached = switch (location.asset_kind) {
            .texture_plain => .{ .texture = .load(mapped_file, .plain) },
            .texture_sprite => .{ .texture = .load(mapped_file, .sprite) },
            .model => .{ .model = .load(mapped_file) },
            .map => @panic("TODO: implement"),
        };
        errdefer switch (cached) {
            .texture => |texture| texture.unload(),
            .model => |model| model.unload(),
            .map => @panic("TODO: implement"),
            .tombstone => unreachable,
        };
        const idx = try m.nextIndex(allocator);
        m.cache.items[idx] = cached;
        location.index = .at(idx);
        log.info("cached asset {s}:{s} at index {d}", .{
            location.path_rel,
            @tagName(cached.*),
            idx,
        });
        return idx;
    }

    /// Asserts that asset is not referenced.
    /// Assumes that an exclusive lock is held.
    inline fn uncacheAsset(
        m: *Manager,
        allocator: Allocator,
        location: *Location,
    ) void {
        _ = allocator;
        assert(!location.isReferenced());

        const idx = location.index.value() orelse return;
        const cached = &m.cache.items[idx];
        switch (cached.*) {
            .texture => |texture| texture.unload(),
            .model => |model| model.unload(),
            .map => @panic("TODO: implement"),
            .tombstone => unreachable,
        }
        log.info("uncached asset {s}:{s} at index {d}", .{
            location.path_rel,
            @tagName(cached.*),
            idx,
        });
        location.index = .none;
        cached.* = .tombstone;
    }

    /// Assumes that an exclusive lock is held.
    inline fn nextHandle(m: *Manager) Asset.Handle {
        const handle = m.next_handle;
        m.next_handle += 1;
        return handle;
    }
    /// Assumes that an exclusive lock is held.
    inline fn nextIndex(m: *Manager, allocator: Allocator) Error!u32 {
        for (m.cache.items, 0..) |cached, i| {
            if (cached == .tombstone) {
                @branchHint(.unlikely);
                return @intCast(i);
            }
        } else {
            try m.cache.append(allocator, .tombstone);
            return @intCast(m.cache.items.len - 1);
        }
    }
};

const Cached = union(enum) {
    texture: Texture,
    model: Model,
    map: Map,
    tombstone,

    const Texture = struct {
        width: u32,
        height: u32,
        channels: u16,
        sprite_count: u16,
        data: []u8,

        pub const sprite_width = 128;

        pub const Kind = enum { plain, sprite };
        pub const Error = error{Stbi};

        pub fn load(memory: []const u8, kind_: Texture.Kind) Error!Texture {
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
                return Error.Stbi;
            };
            const sprite_count: u16 = switch (kind_) {
                .plain => 0,
                .sprite => @intCast(@divExact(width, Texture.sprite_width)),
            };
            const data = data_raw[0..(width * height * channels)];
            return Texture{
                .width = @intCast(width),
                .height = @intCast(height),
                .channels = @intCast(channels),
                .sprite_count = sprite_count,
                .data = data,
            };
        }
        pub fn unload(texture: *Texture) void {
            stbi.stbi_image_free(texture.data.ptr);
            texture.* = undefined;
        }

        pub inline fn kind(texture: Texture) Texture.Kind {
            return if (texture.sprite_count > 0) .sprite else .plain;
        }
    };

    const Model = struct {
        data: *cgltf.cgltf_data,

        pub const Error = error{Ufbx};

        pub fn load(memory: []const u8) Error!Model {
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
        display_name: []const u8,
        texture_name: []const u8,
        control_points: []linalg.v2f32.V,
    };
};

// I mainly use memory mapping here to keep things simple, using files would either mean
// leaving file operations to the C depencencies (which is problematic because that would
// require an absolute path to each asset which we do not have) or providing custom read
// callbacks which have to satisfy sparsely documented specifications.
// It's just easier to use plain memory buffers to read/parse from and for the kinds of
// files we're dealing with it probably won't make a difference in performance anyways.

const MappedFile = struct {
    data: []const u8,
    handle: if (target_os == .windows) windows.HANDLE else void,

    pub const Error = posix.MMapError || error{ CreateFileMapping, MapViewOfFile };

    pub fn map(file: File) Error!MappedFile {
        const size = try file.getEndPos();
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
                    log.err("CreateFileMapping failed: {s}", .{
                        @tagName(windows.GetLastError()),
                    });
                    return Error.CreateFileMapping;
                }
                errdefer windows.CloseHandle(map_handle);
                const mapped = MapViewOfFile(map_handle, FILE_MAP_READ, 0, 0, 0);
                if (mapped == null) {
                    log.err("MapViewOfFile failed: {s}", .{
                        @tagName(windows.GetLastError()),
                    });
                    return Error.MapViewOfFile;
                }
                return .{
                    .data = @as([*]u8, @ptrCast(mapped))[0..size],
                    .handle = map_handle,
                };
            },
            .emscripten => @compileError("TOOD: implement"),
            else => {
                const mapped = try posix.mmap(
                    null,
                    size,
                    posix.PROT.READ,
                    .{ .TYPE = .SHARED },
                    file.handle,
                    0,
                );
                return .{
                    .data = mapped,
                    .handle = {},
                };
            },
        }
    }
    pub fn unmap(mapped_file: MappedFile) void {
        switch (target_os) {
            .windows => {
                const ok = UnmapViewOfFile(@ptrCast(mapped_file.data.ptr));
                assert(ok);
                windows.CloseHandle(mapped_file.handle);
            },
            .emscripten => @compileError("TODO: implement"),
            else => {
                posix.munmap(@alignCast(mapped_file.data));
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
