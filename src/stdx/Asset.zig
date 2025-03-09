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
        .absoulte => |abs| try allocator.dupe(u8, abs),
        .relative => |rel| std.fs.path.joinZ(allocator, &.{
            global.asset_path,
            @tagName(asset.kind),
            rel,
        }) catch return Allocator.Error,
    };
}

const std = @import("std");
const global = @import("global");
const stbi = @import("stbi");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Manager = struct {
    name_to_id: std.StringHashMapUnmanaged(Asset.Id) = .empty,
    id_to_index: std.AutoHashMapUnmanaged(Asset.Id, u32) = .empty,
    assets: std.ArrayListUnmanaged(Asset.Cached) = .empty,

    next_id: Asset.Id = 0,
    lock: std.Thread.RwLock = .{},

    pub const Error = error{Stbi} || Allocator.Error;

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

    /// Locks manager exclusively ; invalidates all references to the asset.
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
        switch (cached.meta) {
            .texture => Manager.unloadTexture(cached.*),
            .tombstone => unreachable,
            else => allocator.free(cached.data),
        }
        cached.* = Asset.Cached.tombstone;
    }

    fn loadTexture(path: [:0]const u8, is_sprite: bool) Error!Asset.Cached {
        var width: c_int, var height: c_int, var channels: c_int = undefined;
        const data_raw: [*]u8 = stbi.stbi_load(path, &width, &height, &channels, 0) orelse {
            @branchHint(.cold);
            return Error.Stbi;
        };
        const data = data_raw[0..(width * height * channels)];
        return Asset.Cached{
            .meta = .{ .texture = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .channels = @intCast(channels),
                .sprite_count = if (is_sprite)
                    @intCast(@divExact(width, sprite_width))
                else
                    0,
            } },
            .data = data,
        };
    }

    fn unloadTexture(cached: Asset.Cached) void {
        assert(std.meta.activeTag(cached.meta) == .texture);
        stbi.stbi_image_free(cached.data.ptr);
    }

    /// Asserts that asset is not in cache yet.
    /// Assumes that an exclusive lock is held.
    inline fn cacheAsset(m: *Manager, allocator: Allocator, asset: Asset, id: Asset.Id) Error!u32 {
        assert(!m.id_to_index.contains(id));

        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var path_allocator = std.heap.FixedBufferAllocator.init(&path_buffer);
        const path = try asset.resolvePath(path_allocator.allocator());
        const cached: Asset.Cached = switch (asset.kind) {
            .@"texture/plain" => Manager.loadTexture(path, false),
            .@"texture/sprite" => Manager.loadTexture(path, true),
            .model, .map => @panic("TODO: implement"),
        };
        errdefer switch (asset.kind) {
            .@"texture/plain", .@"texture/sprite" => Manager.unloadTexture(cached),
            else => allocator.free(cached.data),
        };
        const index = try m.nextIndex(allocator);
        try m.id_to_index.putNoClobber(allocator, id, index);
        m.assets.items[index] = cached;
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
            if (std.meta.activeTag(cached.meta) == .tombstone) {
                @branchHint(.unlikely);
                return @intCast(i);
            }
        } else {
            _ = try m.assets.addOne(allocator);
            return @intCast(m.assets.items.len - 1);
        }
    }
};

const Cached = struct {
    meta: Meta,
    data: []u8,

    const Meta = union(enum) {
        texture: Texture,
        model: Model,
        map: Map,
        tombstone,

        const Texture = struct {
            width: u32,
            height: u32,
            channels: u16,
            sprite_count: u16,
        };

        const Model = struct {
            texture: Asset.Id,
            vert_idx: u32,
            uv_idx: u32,
            end_idx: u32,
        };

        const Map = struct {
            texture: Asset.Id,
        };
    };

    pub const tombstone = Cached{
        .meta = .tombstone,
        .data = undefined,
    };
};
