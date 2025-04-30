const builtin = @import("builtin");
const std = @import("std");
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const windows = std.os.windows;
const testing = std.testing;

const assert = std.debug.assert;
const expect = std.testing.expext;

const cache_line = std.atomic.cache_line;
const target_os = builtin.target.os.tag;

pub const simd = @import("stdx/simd.zig");
pub const StaticMultiArrayList = @import("stdx/static_multi_array_list.zig").StaticMultiArrayList;

const chunk_allocator = @import("stdx/chunk_allocator.zig");
pub const ChunkAllocator = chunk_allocator.ChunkAllocator;
pub const ChunkAllocatorConfig = chunk_allocator.Config;

pub const integrate = @import("stdx/integrate.zig");
pub const concurrent = @import("stdx/concurrent.zig");

pub fn todo(comptime msg: []const u8) noreturn {
    @compileError("TODO: " ++ msg);
}

pub fn CacheLinePadded(comptime T: type) type {
    const padding_size = cache_line - (@sizeOf(T) % cache_line);
    return extern struct {
        data: T align(cache_line),
        _padding: [padding_size]u8 = undefined,

        pub fn init(data: T) @This() {
            return .{ .data = data };
        }
    };
}

/// Wrap variables (e.g. struct fields) as 'immutable'.
/// `verify_fn` will trigger an assertion if it evaluates
/// to `false`.
pub fn Immutable(comptime T: type, comptime verify_fn: fn (ok: bool) bool) type {
    return struct {
        do_not_access: T,

        pub inline fn get(self: @This()) T {
            return self.do_not_access;
        }
    };
}

/// Generate a struct that contains an array for each field in `T`.
/// Use together with `std.MultiArrayList` for efficient storage.
pub fn StructOfArrays(comptime T: type, comptime len: usize) type {
    var info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError("StructOfArrays only supports structs"),
    };
    var arrays: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, &arrays) |field, *array| {
        array.type = [len]field.type;
    }
    info.fields = &arrays;
    return @Type(.{ .@"struct" = info });
}
/// Helper function to extract contiguous element from struct of arrays.
pub fn atSoA(comptime Elem: type, soa: anytype, index: usize) Elem {
    if (std.meta.activeTag(@typeInfo(@TypeOf(soa))) != .@"struct") {
        @compileError("soa needs to be a struct");
    }
    var elem: Elem = undefined;
    inline for (@typeInfo(Elem).@"struct".fields) |field| {
        @field(elem, field.name) = @field(soa, field.name)[index];
    }
    return elem;
}

/// from `std.simd`
pub fn vectorLength(comptime VectorType: type) comptime_int {
    return switch (@typeInfo(VectorType)) {
        .vector => |info| info.len,
        .array => |info| info.len,
        else => @compileError("Invalid type " ++ @typeName(VectorType)),
    };
}

pub const CountDeclsOptions = struct {
    type: Type = .any,
    name: Name = .any,

    pub const Type = union(enum) {
        id: std.builtin.TypeId,
        exact: type,
        custom: struct {
            matchFn: fn (decl: std.builtin.Type.Declaration, arg: ?*anyopaque) bool,
            arg: ?*anyopaque = null,
        },
        any,
    };
    pub const Name = union(enum) {
        starts_with: []const u8,
        ends_with: []const u8,
        contains: []const u8,
        equals: []const u8,
        custom: struct {
            matchFn: fn (haystack: []const u8, needle: []const u8) bool,
            needle: []const u8,
        },
        any,
    };
};
pub fn countDecls(comptime T: type, comptime options: CountDeclsOptions) comptime_int {
    comptime var count = 0;
    const decls = std.meta.declarations(T);
    for (decls) |decl| {
        const is_matching_type = switch (options.type) {
            .any => true,
            .id => |type_id| blk: {
                const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
                break :blk (std.meta.activeTag(decl_info) == type_id);
            },
            .exact => |Exact| blk: {
                const DeclType = @TypeOf(@field(T, decl.name));
                break :blk (DeclType == Exact);
            },
            .custom => |custom| custom.matchFn(decl, custom.arg),
        };
        if (!is_matching_type) {
            continue;
        }
        const is_matching_name = switch (options.name) {
            .any => true,
            .starts_with => |str| mem.startsWith(u8, decl.name, str),
            .ends_with => |str| mem.endsWith(u8, decl.name, str),
            .contains => |str| mem.containsAtLeast(u8, decl.name, 1, str),
            .equals => |str| mem.eql(u8, decl.name, str),
            .custom => |custom| custom.matchFn(decl.name, custom.needle),
        };
        if (is_matching_name) {
            count += 1;
        }
    }
    return count;
}

pub fn ArrayInitType(comptime Array: type) type {
    const array_info = switch (@typeInfo(Array)) {
        .array => |array| array,
        else => |info| @compileError(std.fmt.comptimePrint(
            "needs 'Array', got '{s}'",
            @typeName(info),
        )),
    };
    return []const struct { usize, array_info.child };
}
pub fn zeroInitArray(comptime Array: type, init: ArrayInitType(Array)) Array {
    var array: Array = std.mem.zeroes(Array);
    for (init) |val| {
        array[val.@"0"] = val.@"1";
    }
    return array;
}

test zeroInitArray {
    const Array = [8]u8;
    const array = zeroInitArray(Array, &.{
        .{ 4, 128 },
        .{ 2, 16 },
        .{ 7, 255 },
    });
    const expected = Array{
        0, 0, 16, 0, 128, 0, 0, 255,
    };
    try testing.expectEqualSlices(u8, &expected, &array);
}

pub fn EnumSubset(comptime E: type, comptime members: []const E) type {
    const tag_type = switch (@typeInfo(E)) {
        .@"enum" => |info| info.tag_type,
        else => |info| @compileError("need 'enum', got '" ++ @tagName(info) ++ "'"),
    };
    var fields: [members.len]std.builtin.Type.EnumField = undefined;
    for (members, &fields) |member, *field| {
        field.* = .{
            .name = @tagName(member),
            .value = @intFromEnum(member),
        };
    }
    return @Type(.{ .@"enum" = .{
        .tag_type = tag_type,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
}

// I mainly use memory mapping here to keep things simple, using files would either mean
// leaving file operations to the C depencencies (which is problematic because that would
// require an absolute path to each asset which we do not have) or providing custom read
// callbacks which have to satisfy sparsely documented specifications.
// It's just easier to use plain memory buffers to read/parse from and for the kind of
// data we're dealing with it probably won't make a difference in performance anyways.

pub const MapFileToMemoryError = std.fs.File.GetSeekPosError || posix.MMapError || std.posix.UnexpectedError;
pub fn mapFileToMemory(file: std.fs.File) MapFileToMemoryError![]align(std.heap.page_size_min) const u8 {
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
                    .ALREADY_EXISTS => MapFileToMemoryError.MappingAlreadyExists,
                    .NOT_ENOUGH_MEMORY => MapFileToMemoryError.OutOfMemory,
                    .FILE_INVALID => unreachable,
                    else => |err| windows.unexpectedError(err),
                };
            }
            defer windows.CloseHandle(map_handle);
            const mapped = MapViewOfFile(map_handle, windows_FILE_MAP_READ, 0, 0, 0);
            if (mapped == null) {
                return switch (windows.GetLastError()) {
                    else => |err| windows.unexpectedError(err),
                };
            }
            return @alignCast(@as([*]u8, @ptrCast(mapped))[0..size]);
        },
        else => {
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
pub fn unmapFileFromMemory(mapped_file: []align(std.heap.page_size_min) const u8) void {
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

const windows_FILE_MAP_READ: windows.DWORD = 4;

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

test mapFileToMemory {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = try tmp_dir.dir.createFile("tmp_file", .{ .read = true });
    defer tmp_file.close();

    // The mapping should contain the same data as the
    // underlying file.
    const expected = "All your mapped memory are belong to us!";

    try tmp_file.writeAll(expected);

    const mapped = try mapFileToMemory(tmp_file);
    defer unmapFileFromMemory(mapped);

    try testing.expectEqualSlices(u8, expected, mapped);

    // Modifications to the underlying file should not
    // affect the content of the mapping.
    try tmp_file.seekTo(0);
    try tmp_file.writeAll("Out of my way!");
    try tmp_file.sync();

    try testing.expectEqualSlices(u8, expected, mapped);
}

test {
    testing.refAllDeclsRecursive(@This());
}
