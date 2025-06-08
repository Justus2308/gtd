//! Registry that takes in all kinds of asset files and spits out `Loader`s.
//! Allows code to reference assets by either a human-friendly name or a
//! computer-friendly handle.
//! The intended usage is to register all assets at once and then accessing
//! them as needed.
//! Assets packs are immediately mapped to memory and kept around for the
//! entire lifetime of this data structure, single asset files are only opened
//! if they are actually loaded into memory by their respective `Loader`.

name_to_entry: std.StringHashMapUnmanaged(Entry),
strings: stdx.StringPool,
file_mappings: std.ArrayListUnmanaged([]const u8),
mode: std.atomic.Value(Mode),

const Registry = @This();

pub const empty = Registry{
    .name_to_entry = .empty,
    .strings = .empty,
    .mode = .init(.write),
};

const String = stdx.StringPool.String;

const Extension = enum {
    @".midasimg",
    @".midasmesh",
    @".midaspack",
};

const known_extensions = std.StaticStringMap(Extension).initComptime(kvs: {
    const extensions = std.enums.values(Extension);
    var tuples: [extensions.len]struct { []const u8, Extension } = undefined;
    for (extensions, &tuples) |extension, *tuple| {
        tuple.* = .{ @tagName(extension), extension };
    }
    break :kvs tuples;
});

pub fn buildFromAssetDir(gpa: Allocator, asset_dir: std.fs.Dir) Allocator.Error!Registry {
    var registry = Registry.empty;
    errdefer registry.deinit(gpa);

    var asset_walker = try asset_dir.walk(gpa);
    defer asset_walker.deinit();

    while (try asset_walker.next()) |dir_entry| {
        if (dir_entry.kind == .file) continue;
        // We only validate the file extension here, proper file type validation
        // only happens if an asset is actually loaded.
        const dir_entry_extension = std.fs.path.extension(dir_entry.path);
        if (known_extensions.get(dir_entry_extension)) |extension| {
            const path_no_extension_len = (dir_entry.path.len - dir_entry_extension.len);
            const path_no_extension = dir_entry.path[0..path_no_extension_len];
            const name = try registry.strings.insert(gpa, path_no_extension);
            const reserved = try registry.strings.reserve(gpa, path_no_extension_len);
            var fba = std.heap.FixedBufferAllocator.init(reserved.buffer);
            std.mem.concat(fba.allocator(), u8, &.{
                dir_entry.path,
                ".",
                stripped_name,
            }) catch unreachable;
            assert(fba.end_index == name_len);
            _ = std.mem.replaceScalar(
                u8,
                reserved.buffer[0..dir_entry.path],
                std.fs.path.sep,
                '.',
            );
            assert(@as([*]u8, @ptrCast(reserved.buffer))[name_len] == 0);
            // This should result in names like this:
            // "textures.goons.red"
            switch (extension) {
                .@".midasimg", .@".midasmesh" => {},
                .@".midaspack" => {},
            }
        } else {
            log.warn(
                "Encountered file with unknown extension while building Registry {s})",
                .{dir_entry.path},
            );
        }
    }
}

pub fn deinit(registry: *Registry, gpa: Allocator) void {
    registry.map.deinit(gpa);
    registry.entries.deinit(gpa);
    registry.strings.deinit(gpa);
    registry.* = undefined;
}

pub const Mode = enum(u8) { read, write };

/// Asserts `.write` mode.
pub fn addEntryFromPath(
    registry: *Registry,
    gpa: Allocator,
    path: []const u8,
) (std.fs.File.OpenError || stdx.MapFileToMemoryError || Allocator.Error)!void {
    assert(registry.mode.load(.acquire) == .write);
    const extension_raw = std.fs.path.extension(path);
    if (known_extensions.get(extension_raw)) |extension| {
        switch (extension) {
            .@".midasimg", .@".midasmesh" => {
                // Dupe path into internal storage
                const path_owned = try registry.strings.insert(gpa, path);
                errdefer registry.strings.remove(path_owned);

                // Transform path into canonical asset name
                const path_no_extension = path[0..(path.len - extension_raw.len)];
                const trimmed = std.mem.trimStart(u8, path_no_extension, std.fs.path.sep_str);
                const reserved = try registry.strings.reserve(gpa, @intCast(trimmed.len));
                errdefer registry.strings.remove(reserved.string);
                @memcpy(reserved.buffer, trimmed);
                std.mem.replaceScalar(u8, reserved.buffer, std.fs.path.sep, '.');

                // Insert entry into registry
                const gop = try registry.name_to_entry.getOrPut(gpa, reserved.buffer);
                if (gop.found_existing) {
                    std.debug.panic("duplicate asset name detected: '{s}'", .{reserved.buffer});
                }
                gop.value_ptr.* = .{
                    .name = reserved.string,
                    .source = .{ .file = .{
                        .path = path_owned,
                        .expected_format = extension,
                    } },
                };
            },
            .@".midaspack" => {},
        }
    }
}

/// Asserts `.write` mode.
pub fn addEntryFromMemory(
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
    registry.name_to_entry.lockPointers();
}

/// Hard check for a desired mode that will be performed in any
/// build mode. Returns an error if the wrong mode ist set.
pub fn checkMode(registry: Registry, mode: Mode) error{WrongMode}!void {
    if (registry.mode.load(.acquire) != mode) {
        return error.WrongMode;
    }
}

/// Asserts `.read` mode.
/// The returned `Loader` is supposed to be passed to a `resource.Manager`.
pub fn getLoader(registry: *Registry, name: anytype) ?Loader {
    assert(registry.mode.load(.acquire) == .read);
    const name_str: []const u8 = str: {
        switch (@typeInfo(@TypeOf(name))) {
            .pointer => |info| switch (info.size) {
                .one => switch (@typeInfo(info.child)) {
                    .array => |array_info| if (array_info.child == u8) break :str name,
                    else => {},
                },
                .slice => if (info.child == u8) break :str name,
                .many, .c => if (info.child == u8) break :str std.mem.span(name),
            },
            .@"enum" => if (@TypeOf(name) == String)
                break :str registry.strings.get(name) orelse return null,
            else => {},
        }
        @compileError("need bytes or 'String' handle, got '" ++ @typeName(@TypeOf(name)) ++ "'");
    };
    const entry = registry.name_to_entry.getPtr(name_str) orelse return null;
    return entry.loader();
}

/// Possible data sources:
/// - embedded/mmapped midaspack (mapping is externally managed so they behave the same)
/// - file (ident via rel path in asset_dir, can be pack/img/mesh, format should be resolved asap)
pub const Entry = struct {
    info: Info,
    flags: Flags,
    /// Must be equal to `source.data.len`/`source.data_len`
    /// if data is uncompressed. Data is only considered
    /// compressed if it actually takes up less space in
    /// compressed form according to midas spec.
    decomp_size: u64,
    actual_size: u64,
    source: Source,
    checksum: u64,

    pub const Source = union {
        /// Assumes that correct file offset is already set.
        /// Assumes no padding.
        file: std.fs.File,
        memory: [*]const u8,
    };

    pub const Info = packed struct(u8) {
        data_kind: DataKind,
        source_kind: SourceKind,
        _: u6,

        pub const DataKind = enum(u1) { img, mesh };
        pub const SourceKind = enum(u1) { file, memory };
    };

    pub const Flags = packed union {
        img: Texture.Flags,
        mesh: packed struct(u8) {},

        comptime {
            assert(@sizeOf(Flags) == 1);
            assert(@bitSizeOf(Flags) == 8);
        }
    };

    pub fn loader(entry: *Entry) Loader {
        return .{
            .ptr = entry,
            .vtable = &.{
                .hash = hash,
                .load = load,
                .unload = unload,
            },
        };
    }

    fn hash(ptr: *anyopaque) u64 {
        const entry: *Entry = @ptrCast(@alignCast(ptr));
        return entry.checksum;
    }

    // TODO split into smaller fns
    fn load(ptr: *anyopaque, allocator: Allocator, context: Loader.Context) !void {
        const entry: *Entry = @ptrCast(@alignCast(ptr));
        const is_compressed = entry.isCompressed();

        switch (entry.info.source_kind) {
            .file => {
                const file = entry.source.file;
                const file_buffer_allocator = if (is_compressed) context.scratch_arena else allocator;

                const header_size = switch (entry.info.data_kind) {
                    .img => 24,
                    .mesh => unreachable, // TODO
                };
                const alignment = std.mem.Alignment.@"8";
                const offset = std.mem.alignForward(u64, header_size, alignment.toByteUnits());
                // DATA + CHECKSUM
                const bytes_to_read = (std.mem.alignForward(u64, entry.actual_size) + @as(u64, @sizeOf(u64)));

                if (bytes_to_read > std.math.maxInt(usize)) {
                    log.err("TODO: support asset files >4GiB (handle={any})", .{file.handle});
                    return error.Unexpected;
                }
                const buffer = try file_buffer_allocator.alignedAlloc(u8, .@"8", @intCast(bytes_to_read));
                errdefer file_buffer_allocator.free(buffer);

                const bytes_read = try file.preadAll(buffer, offset);
                if (@as(u64, bytes_read) != bytes_to_read) {
                    log.err(
                        "asset file (handle={any}) corrupted: wrong data length (actual_size={d}, bytes_read={d})",
                        .{ file.handle, entry.actual_size, bytes_read },
                    );
                    return error.Unexpected;
                }

                const data_segment = buffer[0..entry.actual_size];

                const checksum_from_file = std.mem.readInt(u64, buffer[buffer.len - @sizeOf(u64)][0..@sizeOf(u64)], .little);

                // TODO calculate during decompression to avoid reading data twice?
                const checksum_calculated = hash: {
                    var hasher = std.hash.XxHash3.init(0);
                    hasher.update(data_segment);
                    break :hash hasher.final();
                };

                if (checksum_from_file != checksum_calculated) {
                    log.err(
                        "asset file (handle={any}) corrupted: invalid checksum (stated={d}, actual={d})",
                        .{ checksum_from_file, checksum_calculated },
                    );
                    return error.Unexpected;
                }

                const result_bytes = if (is_compressed) decomp: {
                    const result_buffer = try allocator.alignedAlloc(u8, .@"8", entry.decomp_size);
                    errdefer allocator.free(result_buffer);

                    const result = try stdx.compress.lz4.decompress(result_buffer, buffer);
                    if (result.len != entry.decomp_size) {
                        log.err(
                            "asset file (handle={any}) corrupted: wrong decompressed data length (stated={d}, actual={d})",
                            .{ file.handle, entry.decomp_size, result.len },
                        );
                        return error.Unexpected;
                    }
                    break :decomp result;
                } else buffer;

                return result_bytes;
            },
            .memory => {},
        }

        const bytes = switch (entry.source_kind) {
            .bytes => entry.source.bytes,
            .file => bytes: {
                const buffer_allocator = if (entry.isCompressed())
                    context.scratch_arena
                else
                    allocator;

                const source = entry.source.file;
                const buffer = try buffer_allocator.alloc(u8, source.data_len);
                errdefer buffer_allocator.free(buffer);

                const file = source.inner;

                var offset: u64 = file.data_offset;
                while (offset < (@as(u64, source.data_offset) + @as(u64, source.data_len))) {
                    const bytes_read = file.pread(buffer[offset..], offset) catch |err| {
                        return switch (err) {
                            .AccessDenied => error.AccessDenied,
                            else => error.Unexpected,
                        };
                    };
                    if (bytes_read == 0) {
                        @branchHint(.cold);
                        return error.Unexpected;
                    }
                    offset += bytes_read;
                }

                if (entry.isCompressed()) {
                    break :bytes decomp;
                } else {
                    break :bytes buffer[0..offset];
                }
                unreachable;
            },
        };

        if (entry.isCompressed()) {
            const dest = {};
        } else {
            return bytes;
        }
        unreachable;
    }

    fn unload(ptr: *anyopaque, allocator: Allocator) void {
        const entry: *Entry = @ptrCast(@alignCast(ptr));
    }

    inline fn isCompressed(entry: Entry) bool {
        return (entry.decomp_size > entry.actual_size);
    }
};

pub const Entry2 = union(enum) {
    from_memory: FromMemory,
    from_file: FromFile,

    pub const List = std.MultiArrayList(Entry);

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
};

const std = @import("std");
const stdx = @import("stdx");
const sokol = @import("sokol");
const Allocator = std.mem.Allocator;
const Loader = @import("Loader.zig");
const Texture = @import("Texture.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.resource);
