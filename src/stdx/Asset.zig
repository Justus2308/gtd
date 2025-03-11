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
const ufbx = @import("ufbx");
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

    /// Set to 0 for unlimited attempts
    const max_get_attempts = 5;

    /// Only locks manager exclusively when asset is not in cache anymore.
    /// This comes at the cost of more locking actions and double checks in
    /// case of a load.
    /// Adds a reference to the asset associated with `handle`.
    pub fn get(m: *Manager, allocator: Allocator, handle: Handle) Error!Asset.Cached {
        m.lock.lockShared();
        defer m.lock.unlockShared();
        try m.getInner(allocator, handle, 0);
    }
    fn getInner(
        m: *Manager,
        allocator: Allocator,
        handle: Asset.Handle,
        attempt: isize,
    ) Error!Asset.Cached {
        const location = m.handle_to_location.getPtr(handle) orelse
            return Error.UnknownAssetHandle;
        const idx = location.index.value() orelse idx: {
            // This is the slow path anyway because we have to read from disk
            // so a couple more locking operations and double checks won't hurt
            @branchHint(.cold);
            m.lock.unlockShared();
            m.lock.lock();
            defer {
                m.lock.unlock();
                m.lock.lockShared();
            }
            const idx = location.index.value() orelse blk: {
                @branchHint(.likely);
                break :blk m.cacheAsset(allocator, handle, location);
            };
            break :idx idx;
        };
        return switch (m.cache.items[idx]) {
            .tombstone => cached: {
                // Another thread unloaded our asset while we weren't looking
                @branchHint(.cold);
                if (attempt == (max_get_attempts - 1)) {
                    return Error.TooManyAttempts;
                }
                const cached = try @call(
                    .always_tail,
                    getInner,
                    .{ m, allocator, handle, (attempt + 1) },
                );
                break :cached cached;
            },
            else => |cached| blk: {
                @branchHint(.likely);
                location.addReference();
                break :blk cached;
            },
        };
    }

    /// Guaranteed to succeed and never lock exclusively.
    /// This function will never modify the asset cache.
    /// Adds a reference to the asset associated with `handle`.
    pub fn getIfCached(m: *Manager, handle: Handle) ?Asset.Cached {
        m.lock.lockShared();
        defer m.lock.unlockShared();

        const location = m.handle_to_location.getPtr(handle) orelse return null;
        const idx = location.index.value() orelse return null;
        location.addReference();
        return m.cache.items[idx];
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
    /// Consolidated cache array.
    pub fn unloadAll(m: *Manager, allocator: Allocator) void {
        m.lock.lock();
        defer m.lock.unlock();

        const location_iter = m.handle_to_location.valueIterator();
        while (location_iter.next()) |location| {
            if (!location.isReferenced()) {
                m.uncacheAsset(allocator, location);
            }
        }
        const used_len = std.mem.trimRight(Asset.Cached, m.cache.items, &.{.tombstone}).len;
        m.cache.shrinkRetainingCapacity(used_len);
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

        const cached: Asset.Cached = switch (location.asset_kind) {
            .texture_plain => .{ .texture = .load(file, .plain) },
            .texture_sprite => .{ .texture = .load(file, .sprite) },
            .model => .{ .model = .load(allocator, file) },
            .map => @panic("TODO: implement"),
        };
        errdefer switch (cached) {
            .texture => |texture| texture.unload(),
            .model => |model| model.unload(allocator),
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
        assert(!location.isReferenced());

        const idx = location.index.value() orelse return;
        const cached = &m.cache.items[idx];
        switch (cached.*) {
            .texture => |texture| texture.unload(),
            .model => |model| model.unload(allocator),
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

        pub fn load(file: File, kind_: Texture.Kind) Error!Texture {
            var width: c_int, var height: c_int, var channels: c_int = undefined;
            const data_raw: [*]u8 = stbi.stbi_load_from_callbacks(
                &Texture.io_callbacks,
                &file,
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

        const io_callbacks = stbi.stbi_io_callbacks{
            .read = &wrappedRead,
            .skip = &wrappedSkip,
            .eof = &wrappedEof,
        };
        fn wrappedRead(user: *anyopaque, data: [*]u8, size: c_int) callconv(.c) c_int {
            const f: *const File = @ptrCast(user);
            const buffer = data[0..@as(usize, @intCast(size))];
            const bytes_read = f.readAll(buffer) catch 0;
            return @intCast(bytes_read);
        }
        fn wrappedSkip(user: *anyopaque, n: c_int) callconv(.c) void {
            const f: *const File = @ptrCast(user);
            f.seekBy(n) catch {};
        }
        fn wrappedEof(user: *anyopaque) callconv(.c) c_int {
            const f: *const File = @ptrCast(user);
            const pos = f.getPos() catch 0;
            const end_pos = f.getEndPos() catch 0;
            return @intFromBool(pos == end_pos);
        }
    };

    const Model = struct {
        objs: []stdx.Obj,

        pub const Error = error{Ufbx};

        pub fn load2(allocator: Allocator, file: File) Error!Model {
            const objs = try stdx.Obj.parse(allocator, file);
            return Model{ .objs = objs };
        }

        pub fn unload2(model: *Model, allocator: Allocator) void {
            for (model.objs) |*obj| {
                obj.deinit(allocator);
            }
            allocator.free(model.objs);
            model.* = undefined;
        }

        pub fn load(file: *File) Error!Model {
            const stream = ufbx.ufbx_stream{
                .read_fn = &wrappedRead,
                .skip_fn = &wrappedSkip,
                .size_fn = &wrappedSize,
                .close_fn = null,
                .user = @ptrCast(file),
            };
            var err: ufbx.ufbx_error = undefined;
            const scene: *ufbx.ufbx_scene = ufbx.ufbx_load_stream(&stream, null, &err) orelse {
                var err_buf: [ufbx.UFBX_ERROR_INFO_LENGTH]u8 = undefined;
                const err_len = ufbx.ufbx_format_error(&err_buf, err_buf.len, &err);
                const err_desc = err_buf[0..err_len];
                std.log.scoped(.ufbx).err("model load failed: {s}", .{err_desc});
                return Error.Ufbx;
            };
            // TODO
        }
        pub fn unload(model: *Model) void {}

        fn wrappedRead(user: *anyopaque, data: *anyopaque, size: usize) callconv(.c) usize {
            const f: *const File = @ptrCast(user);
            const buffer = @as([*]u8, @ptrCast(data))[0..size];
            const bytes_read = f.readAll(buffer) catch std.math.maxInt(usize);
            return bytes_read;
        }
        fn wrappedSkip(user: *anyopaque, size: usize) callconv(.c) bool {
            const f: *const File = @ptrCast(user);
            f.seekBy(@intCast(size)) catch return false;
            return true;
        }
        fn wrappedSize(user: *anyopaque) callconv(.c) u64 {
            const f: *const File = @ptrCast(user);
            const size = f.getEndPos() catch std.math.maxInt(u64);
            return size;
        }
    };

    const Map = struct {
        display_name: []const u8,
        texture_name: []const u8,
        control_points: []linalg.v2f32.V,
    };
};
