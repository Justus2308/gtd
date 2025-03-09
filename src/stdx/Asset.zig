ident: Ident,
kind: Kind,
path: Path,

const Asset = @This();

pub const sprite_width = 128; // TODO

pub const Name = []const u8;
pub const Id = u32;

const Ident = union(enum) {
    name: Name,
    id: Id,
};

const Kind = enum {
    @"texture/plain",
    @"texture/sprite",
    model,
    map,
};

const Path = union(enum) {
    absolute: []const u8,
    relative: []const u8,
};

pub fn resolvePath(asset: Asset, allocator: Allocator) Allocator.Error![:0]const u8 {
    return switch (asset.path) {
        .absolute => |absolute| try allocator.dupe(u8, absolute),
        .relative => |relative| std.fs.path.joinZ(allocator, &.{
            global.asset_path,
            @tagName(asset.kind),
            relative,
        }) catch return Allocator.Error,
    };
}

const std = @import("std");
const stdx = @import("stdx");
const global = @import("global");
const stbi = @import("stbi");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.assets);

// TODO: split assets into separate arrays for each category?

pub const Manager = struct {
    name_to_id: std.StringHashMapUnmanaged(Asset.Id) = .empty,
    id_to_index: std.AutoHashMapUnmanaged(Asset.Id, u32) = .empty,
    assets: std.ArrayListUnmanaged(Asset.Cached) = .empty,

    next_id: Asset.Id = 0,
    lock: std.Thread.RwLock = .{},

    pub const Error = error{Stbi} || Allocator.Error;

    pub fn deinit(m: *Manager, allocator: Allocator) void {
        m.name_to_id.deinit(allocator);
        m.id_to_index.deinit(allocator);
        for (m.assets.items) |cached| {
            switch (cached) {
                .texture => |texture| texture.unload(),
                .model => |model| model.deinit(allocator),
                .map => @panic("TODO: implement"),
                .tombstone => {},
            }
        }
        m.assets.deinit(allocator);
        log.debug("asset manager deinitialized", .{});
        m.* = undefined;
    }

    /// Tries to only lock manager exclusively when asset is not loaded yet.
    /// This comes at the cost of more locking actions and double checks in
    /// case of a load.
    pub fn get(m: *Manager, allocator: Allocator, asset: Asset) Error!Asset.Cached {
        m.lock.lockShared();
        defer m.lock.unlockShared();
        const id = switch (asset.ident) {
            .name => |name| m.name_to_id.get(name) orelse id: {
                @branchHint(.unlikely);
                m.lock.unlockShared();
                m.lock.lock();
                defer {
                    m.lock.unlock();
                    m.lock.lockShared();
                }
                // Double check, new entry could have been
                // inserted between unlockShared and lock
                if (m.name_to_id.get(name)) |id| {
                    @branchHint(.cold);
                    break :id id;
                }
                const next = m.nextId();
                try m.name_to_id.putNoClobber(allocator, name, next);
                break :id next;
            },
            .id => |id| id,
        };
        const index = m.id_to_index.get(id) orelse index: {
            @branchHint(.unlikely);
            m.lock.unlockShared();
            m.lock.lock();
            defer {
                m.lock.unlock();
                m.lock.lockShared();
            }
            if (m.id_to_index.get(id)) |index| {
                @branchHint(.cold);
                break :index index;
            }
            break :index try m.cacheAsset(allocator, asset, id);
        };
        return m.assets.items[index];
    }

    /// Guaranteed to succeed and never lock exclusively.
    /// This function will never modify the asset cache.
    pub fn getIfLoaded(m: *Manager, asset: Asset) ?Asset.Cached {
        m.lock.lockShared();
        defer m.lock.unlockShared();

        const id = switch (asset.ident) {
            .name => |name| m.name_to_id.get(name) orelse return null,
            .id => |id| id,
        };
        const index = m.id_to_index.get(id) orelse return null;
        return m.assets.items[index];
    }

    /// Locks manager exclusively right away ; faster than `get` if
    /// you know that an asset is not loaded yet.
    pub fn load(m: *Manager, allocator: Allocator, asset: Asset) Error!void {
        m.lock.lock();
        defer m.lock.unlock();

        const id = switch (asset.ident) {
            .name => |name| m.name_to_id.get(name) orelse id: {
                const next = m.nextId();
                try m.name_to_id.putNoClobber(allocator, name, next);
                break :id next;
            },
            .id => |id| id,
        };
        if (!m.id_to_index.contains(id)) {
            _ = try m.cacheAsset(allocator, asset, id);
        }
    }

    /// Locks manager exclusively ; invalidates all references to the cached asset.
    pub fn unload(m: *Manager, allocator: Allocator, asset: Asset) void {
        m.lock.lock();
        defer m.lock.unlock();

        const id = switch (asset.ident) {
            .name => |name| m.name_to_id.get(name) orelse return,
            .id => |id| id,
        };
        const id_idx = m.id_to_index.fetchRemove(id) orelse return;
        const index = id_idx.value;
        const cached = &m.assets.items[index];
        switch (cached.*) {
            .texture => |texture| texture.unload(),
            .model => |model| model.deinit(allocator),
            .map => @panic("TODO: implement"),
            .tombstone => unreachable,
        }
        log.info("unloaded asset {s}:{d}:{s} at index {d}", .{
            if (std.meta.activeTag(asset.ident) == .name) asset.ident.name else "?",
            id,
            @tagName(cached.*),
            index,
        });
        cached.* = .tombstone;
    }

    /// Asserts that asset is not in cache yet.
    /// Assumes that an exclusive lock is held.
    inline fn cacheAsset(m: *Manager, allocator: Allocator, asset: Asset, id: Asset.Id) Error!u32 {
        assert(!m.id_to_index.contains(id));

        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var path_allocator = std.heap.FixedBufferAllocator.init(&path_buffer);
        const path = try asset.resolvePath(path_allocator.allocator());
        const cached: Asset.Cached = switch (asset.kind) {
            .@"texture/plain" => .{ .texture = .load(path, .plain) },
            .@"texture/sprite" => .{ .texture = .load(path, .sprite) },
            .model, .map => @panic("TODO: implement"),
        };
        errdefer switch (cached) {
            .texture => |texture| texture.unload(),
            .model => |model| model.deinit(allocator),
            .map => @panic("TODO: implement"),
            .tombstone => unreachable,
        };
        const index = try m.nextIndex(allocator);
        try m.id_to_index.putNoClobber(allocator, id, index);
        m.assets.items[index] = cached;
        log.info("cached asset {s}:{d}:{s} at index {d}", .{
            if (std.meta.activeTag(asset.ident) == .name) asset.ident.name else "?",
            id,
            @tagName(cached.*),
            index,
        });
        return index;
    }

    /// Assumes that an exclusive lock is held.
    inline fn nextId(m: *Manager) Asset.Id {
        const id = m.next_id;
        m.next_id += 1;
        return id;
    }
    /// Assumes that an exclusive lock is held.
    inline fn nextIndex(m: *Manager, allocator: Allocator) Error!u32 {
        for (m.assets.items, 0..) |cached, i| {
            if (cached == .tombstone) {
                @branchHint(.unlikely);
                return @intCast(i);
            }
        } else {
            try m.assets.append(allocator, .tombstone);
            return @intCast(m.assets.items.len - 1);
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

        pub const Kind = enum { plain, sprite };
        pub const Error = error{Stbi};

        pub fn load(path: [:0]const u8, kind_: Texture.Kind) Error!Texture {
            var width: c_int, var height: c_int, var channels: c_int = undefined;
            const data_raw: [*]u8 = stbi.stbi_load(path, &width, &height, &channels, 0) orelse {
                @branchHint(.cold);
                std.log.scoped(.stbi).err("image load failed at {s}: {s}", .{
                    path,
                    stbi.stbi_failure_reason() orelse "no reason provided",
                });
                return Error.Stbi;
            };
            const sprite_count: u16 = switch (kind_) {
                .plain => 0,
                .sprite => @intCast(@divExact(width, Asset.sprite_width)),
            };
            const data = data_raw[0..(width * height * channels)];
            return Asset.Cached.Texture{
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
        texture: Asset.Id,
        vertices: stdx.Obj.Vertex.List.Slice,
        indices: []u32,

        /// Invalidates obj
        pub fn fromObj(allocator: Allocator, obj: *stdx.Obj, texture: Asset.Id) Model {
            allocator.free(obj);
            const vertices = obj.vertices;
            const indices = obj.indices;
            obj.* = undefined;
            return Model{
                .texture = texture,
                .vertices = vertices,
                .indices = indices,
            };
        }

        pub fn deinit(model: *Model, allocator: Allocator) void {
            model.vertices.deinit(allocator);
            allocator.free(model.indices);
            model.* = undefined;
        }
    };

    const Map = struct {
        texture: Asset.Id,
    };
};
