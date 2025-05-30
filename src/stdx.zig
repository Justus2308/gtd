const builtin = @import("builtin");
const std = @import("std");
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const windows = std.os.windows;
const testing = std.testing;

const Alignment = mem.Alignment;
const Allocator = mem.Allocator;

const assert = std.debug.assert;
const expect = std.testing.expext;

const cache_line = std.atomic.cache_line;
const target_os = builtin.target.os.tag;
const is_debug = (builtin.mode == .Debug);
const is_safe_build = (is_debug or builtin.mode == .ReleaseSafe);

const chunk_allocator = @import("stdx/chunk_allocator.zig");
pub const ChunkAllocator = chunk_allocator.ChunkAllocator;
pub const ChunkAllocatorConfig = chunk_allocator.Config;

pub const StringPool = @import("stdx/StringPool.zig");

pub const splines = @import("stdx/splines.zig");
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
pub fn Immutable(comptime T: type) type {
    return struct {
        do_not_access: T,

        pub inline fn get(self: @This()) T {
            return self.do_not_access;
        }

        pub inline fn getAssertEq(self: @This(), expected: T) T {
            const value = self.get();
            assert(expected == value);
            return value;
        }
    };
}

/// Ensures that inner value stays within inclusive range [lower, upper].
pub fn BoundedValue(comptime T: type, comptime lower: T, comptime upper: T) type {
    switch (@typeInfo(T)) {
        .comptime_int, .comptime_float, .int, .float => {},
        else => @compileError("only supports ints and floats"),
    }
    if (lower > upper) {
        @compileError("lower <= upper required");
    }
    return struct {
        inner: T,

        /// Asserts that returned value is within bounds.
        pub inline fn get(self: @This()) T {
            assert(self.inner >= lower and self.inner <= upper);
            return self.inner;
        }

        /// Clamps `value` to specified bounds.
        pub inline fn set(self: *@This(), value: T) void {
            self.inner = std.math.clamp(value, lower, upper);
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

/// Checks whether pointer is within memory region.
pub fn containsPointer(comptime T: type, haystack: []const T, needle: *const T) bool {
    const addr = @intFromPtr(needle);
    return (addr >= @intFromPtr(&haystack[0]) and addr <= @intFromPtr(&haystack[haystack.len - 1]));
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

fn InvalidValue(comptime Int: type) type {
    switch (@typeInfo(Int)) {
        .int => {},
        else => |info| @compileError("need 'int', got '" ++ @tagName(info) ++ "'"),
    }
    return union(enum) {
        zero,
        max_int,
        min_int,
        custom: Int,

        pub fn resolve(invalid_value: @This()) Int {
            return switch (invalid_value) {
                .zero => 0,
                .max_int => std.math.maxInt(Int),
                .min_int => std.math.minInt(Int),
                .custom => |value| value,
            };
        }
    };
}
pub fn Handle(
    comptime Int: type,
    comptime invalid_value: InvalidValue(Int),
    comptime UniqueContext: ?type,
) type {
    switch (@typeInfo(Int)) {
        .int => {},
        else => |info| @compileError("need 'int', got '" ++ @tagName(info) ++ "'"),
    }
    return enum(Int) {
        invalid = invalid_value.resolve(),
        _,

        const Self = @This();

        /// Asserts that the returned handle is not `.invalid`.
        pub fn fromInt(int: Int) Self {
            assert(int != invalid_value);
            return @enumFromInt(int);
        }

        /// Asserts that `handle` is not `.invalid`.
        pub fn asInt(handle: Self) Int {
            assert(handle != .invalid);
            return @intFromEnum(handle);
        }

        // Ensure that this type has a unique identity to
        // make the compiler catch improper handle usage.
        comptime {
            const Unique = UniqueContext orelse void;
            _ = Unique;
        }
    };
}

test "Handle type uniqueness" {
    comptime {
        const H1 = Handle(u32, .zero, void);
        const H2 = Handle(u32, .zero, struct {});
        const H3 = Handle(u32, .zero, struct { a: f32, b: u16 });

        try testing.expect(H1 != H2);
        try testing.expect(H2 != H3);
        try testing.expect(H3 != H1);

        const H1Dupe = Handle(u32, .zero, void);
        try testing.expectEqual(H1, H1Dupe);

        const HGeneric1 = Handle(u32, .zero, null);
        const HGeneric2 = Handle(u32, .zero, null);
        try testing.expectEqual(HGeneric1, HGeneric2);
    }
}

pub const Fingerprint = struct {
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
    pub inline fn getName(fingerprint: Fingerprint) []const u8 {
        return if (is_debug) fingerprint.name[0..std.mem.indexOfSentinel(u8, 0, fingerprint.name)] else "?";
    }
    pub inline fn eql(a: Fingerprint, b: Fingerprint) bool {
        return (a.id == b.id);
    }
};

// https://github.com/ziglang/zig/issues/19858#issuecomment-2369861301
pub const TypeId = if (is_safe_build) *const struct { _: u8 } else void;
pub inline fn typeId(comptime T: type) TypeId {
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

test "take and verify Fingerprint" {
    const A = u64;
    const B = struct { a: f32, b: u32 };
    const C = enum { x, y, z };

    const a = Fingerprint.take(A);
    const b = Fingerprint.take(B);
    const c = Fingerprint.take(C);

    comptime {
        try testing.expectEqual(true, a.eql(a));
        try testing.expectEqual(true, b.eql(b));
        try testing.expectEqual(true, c.eql(c));

        try testing.expectEqual(false, a.eql(b));
        try testing.expectEqual(false, b.eql(c));
        try testing.expectEqual(false, c.eql(a));
    }

    if (is_debug) {
        try testing.expectEqualStrings(@typeName(A), a.getName());
        try testing.expectEqualStrings(@typeName(B), b.getName());
        try testing.expectEqualStrings(@typeName(C), c.getName());
    }

    var id1: usize = undefined;
    var id2: usize = undefined;

    id1 = a.getId();
    id2 = b.getId();
    try testing.expect(id1 != id2);

    id1 = b.getId();
    id2 = c.getId();
    try testing.expect(id1 != id2);

    id1 = c.getId();
    id2 = a.getId();
    try testing.expect(id1 != id2);
}

/// Wraps an allocator and only forwards `free`s/shrinking `resize`s to it.
/// New/growing allocations always fail.
pub const FreeOnlyAllocator = struct {
    child_allocator: Allocator,

    pub fn init(child_allocator: Allocator) FreeOnlyAllocator {
        return .{ .child_allocator = child_allocator };
    }

    pub fn allocator(foa: *FreeOnlyAllocator) Allocator {
        return .{
            .ptr = foa,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = Allocator.noRemap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = .{ ctx, len, alignment, ret_addr };
        return null;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const foa: *FreeOnlyAllocator = @ptrCast(@alignCast(ctx));
        return if (new_len <= memory.len) foa.child_allocator.rawResize(memory, alignment, new_len, ret_addr) else false;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const foa: *FreeOnlyAllocator = @ptrCast(@alignCast(ctx));
        return foa.child_allocator.rawFree(memory, alignment, ret_addr);
    }
};

/// Like `std.heap.StackFallbackAllocator` but with an external buffer.
pub const BufferFallbackAllocator = struct {
    fallback_allocator: Allocator,
    fixed_buffer_allocator: std.heap.FixedBufferAllocator,

    pub fn init(buffer: []u8, fallback_allocator: Allocator) BufferFallbackAllocator {
        return .{
            .fallback_allocator = fallback_allocator,
            .fixed_buffer_allocator = .init(buffer),
        };
    }

    /// This function both fetches a `Allocator` interface to this
    /// allocator *and* resets the internal buffer allocator.
    pub fn get(self: *BufferFallbackAllocator) Allocator {
        self.fixed_buffer_allocator.end_index = 0;
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BufferFallbackAllocator = @ptrCast(@alignCast(ctx));
        return std.heap.FixedBufferAllocator.alloc(&self.fixed_buffer_allocator, len, alignment, ret_addr) orelse
            self.fallback_allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *BufferFallbackAllocator = @ptrCast(@alignCast(ctx));
        if (self.fixed_buffer_allocator.ownsPtr(memory.ptr)) {
            assert(self.fixed_buffer_allocator.ownsSlice(memory));
            return std.heap.FixedBufferAllocator.resize(&self.fixed_buffer_allocator, memory, alignment, new_len, ret_addr);
        } else {
            return self.fallback_allocator.rawResize(memory, alignment, new_len, ret_addr);
        }
        unreachable;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *BufferFallbackAllocator = @ptrCast(@alignCast(ctx));
        if (self.fixed_buffer_allocator.ownsPtr(memory.ptr)) {
            assert(self.fixed_buffer_allocator.ownsSlice(memory));
            return std.heap.FixedBufferAllocator.remap(&self.fixed_buffer_allocator, memory, alignment, new_len, ret_addr);
        } else {
            return self.fallback_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        }
        unreachable;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *BufferFallbackAllocator = @ptrCast(@alignCast(ctx));
        if (self.fixed_buffer_allocator.ownsPtr(memory.ptr)) {
            assert(self.fixed_buffer_allocator.ownsSlice(memory));
            return std.heap.FixedBufferAllocator.free(&self.fixed_buffer_allocator, memory, alignment, ret_addr);
        } else {
            return self.fallback_allocator.rawFree(memory, alignment, ret_addr);
        }
        unreachable;
    }
};

pub const FatalReason = enum(u8) {
    oom = 1,
    fs = 2,
    dependency = 3,

    pub fn exitStatus(reason: FatalReason) u8 {
        return @intFromEnum(reason);
    }

    comptime {
        for (std.enums.values(FatalReason)) |reason| assert(reason.exitStatus() != 0);
    }
};
pub fn fatal(
    comptime reason: FatalReason,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    std.log.scoped(.fatal).err("[" ++ @tagName(reason) ++ "]: " ++ fmt, args);
    const status = reason.exitStatus();
    std.process.exit(status);
}

pub const MapFileToMemoryError = std.fs.File.GetSeekPosError || posix.MMapError || std.posix.UnexpectedError;

/// Create a read-only memory mapping of `file`. `file` needs to have
/// been opened with `read` access. This mapping will remain valid until
/// it is unmapped with `unmapFileFromMemory()`, even if `file` is closed.
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
    testing.refAllDecls(@This());
}
