map: std.AutoArrayHashMapUnmanaged(void, void),
entries: Entry.List,
strings: stdx.StringPool,
mode: std.atomic.Value(Mode),

const Registry = @This();

pub const empty = Registry{
    .map = .empty,
    .entries = .empty,
    .strings = .empty,
    .mode = .init(.write),
};

pub fn deinit(registry: *Registry, gpa: Allocator) void {
    registry.map.deinit(gpa);
    registry.entries.deinit(gpa);
    registry.strings.deinit(gpa);
    registry.* = undefined;
}

pub const Mode = enum(u8) { read, write };

/// Asserts `.write` mode.
pub fn addFromPath(
    registry: *Registry,
    gpa: Allocator,
    path: []const u8,
) Allocator.Error!void {
    assert(registry.mode.load(.acquire) == .write);
    const string = try registry.strings.create(gpa, path);
    errdefer registry.strings.destroy(string);
    const entry = Entry{ .path = string };
    try registry.entries.append(gpa, entry);
}

/// Asserts `.write` mode.
pub fn addFromMemory(
    registry: *Registry,
    gpa: Allocator,
    bytes: []const u8,
) Allocator.Error!void {
    assert(registry.mode.load(.acquire) == .write);
    const entry = Entry{ .slice = bytes };
    try registry.entries.append(gpa, entry);
}

/// To ensure thread safety, this type is either in `.read` or in
/// `.write` mode. Functions assert that the correct mode is set.
/// Once `.read` mode is set via this function, it is undefined
/// behaviour to change the mode back to `.write` mode.
pub fn setReadOnly(registry: *Registry) void {
    registry.mode.store(.read, .seq_cst);
}

/// Hard check for a desired mode that will be performed in any
/// build mode. Returns an error if the wrong mode ist set.
pub fn checkMode(registry: Registry, mode: Mode) error{WrongMode}!void {
    if (registry.mode.load(.acquire) != mode) {
        return error.WrongMode;
    }
}

/// Asserts `.read` mode.
pub fn get(registry: *Registry, handle: Loader.Handle) Loader {
    assert(registry.mode.load(.acquire) == .read);

    const GetCtx = struct {
        raw_handle: u64,

        pub fn hash(self: @This(), _: void) u64 {
            return self.raw_handle;
        }

        pub fn eql(self: @This(), _: void, _: void) bool {
            _ = self;
            return true;
        }
    };
    const entry_index = registry.map.getIndexAdapted({}, GetCtx{
        .raw_handle = handle.asInt(),
    }).?;
    const entry = registry.entries.get(entry_index);
}

pub const Entry = union(enum) {
    from_memory: FromMemory,
    from_file: FromFile,

    pub const FromMemory = struct {
        bytes: []const u8,

        pub fn loader(self: *FromMemory) Loader {
            return .{
                .ptr = self,
                .vtable = &.{
                    .load = load,
                    .unload = unload,
                },
            };
        }

        fn hash(ptr: *anyopaque) u64 {
            const self: *FromMemory = @ptrCast(@alignCast(ptr));
        }

        fn load(
            ptr: *anyopaque,
            allocator: Allocator,
            context: Loader.Context,
        ) !void {
            const self: *FromMemory = @ptrCast(@alignCast(ptr));
        }

        fn unload(ptr: *anyopaque, allocator: Allocator) void {
            const self: *FromMemory = @ptrCast(@alignCast(ptr));
        }
    };

    pub const FromFile = struct {
        /// File pointer position is undefined at all times.
        file: std.fs.File,
        content_hash: u64,

        pub fn init(
            scratch_arena: Allocator,
            asset_dir: std.fs.Dir,
            sub_path: []const u8,
        ) (std.fs.File.GetSeekPosError || std.fs.File.PReadError || Allocator.Error)!FromFile {
            const file = try asset_dir.openFile(sub_path, .{
                .mode = .read_only,
            });
            errdefer file.close();

            const max_size = (1 << 10 << 10); // 1 MiB
            const scratch = try scratch_arena.alloc(u8, max_size);
            defer scratch_arena.free(scratch);

            const file_size = try file.getEndPos();

            var hasher = Loader.hasher_init;

            var offset: u64 = 0;
            while (offset < file_size) {
                const bytes_read = try file.pread(scratch, offset);
                if (bytes_read == 0) {
                    // Shouldn't ever happen, but avoids infinite loop
                    @branchHint(.cold);
                    break;
                }
                offset += bytes_read;

                hasher.update(scratch[0..bytes_read]);
            }

            const content_hash = hasher.final();

            return .{
                .file = file,
                .content_hash = content_hash,
            };
        }

        pub fn deinit(self: *FromFile) void {
            self.file.close();
            self.* = undefined;
        }

        pub fn loader(self: *FromFile) Loader {
            return .{
                .ptr = self,
                .vtable = &.{
                    .hash = hash,
                    .load = load,
                    .unload = unload,
                },
            };
        }

        fn hash(ptr: *anyopaque) u64 {
            const self: *FromFile = @ptrCast(@alignCast(ptr));
            return self.content_hash;
        }

        fn load(
            ptr: *anyopaque,
            allocator: Allocator,
            context: Loader.Context,
        ) !void {
            const self: *FromFile = @ptrCast(@alignCast(ptr));
        }

        fn unload(ptr: *anyopaque, allocator: Allocator) void {
            const self: *FromFile = @ptrCast(@alignCast(ptr));
        }
    };

    pub const List = std.MultiArrayList(Entry);
};

const std = @import("std");
const stdx = @import("stdx");
const Allocator = std.mem.Allocator;
const Loader = @import("Loader.zig");
const assert = std.debug.assert;
