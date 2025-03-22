const std = @import("std");
const math = std.math;
const mem = std.mem;

const assert = std.debug.assert;
const expect = std.testing.expext;

const cache_line = std.atomic.cache_line;

pub const asset = @import("stdx/asset.zig");
pub const ThreadPool = @import("stdx/ThreadPool.zig");
pub const integrate = @import("stdx/integrate.zig");
pub const simd = @import("stdx/simd.zig");
pub const StaticMultiArrayList = @import("stdx/static_multi_array_list.zig").StaticMultiArrayList;

const memory_pool = @import("stdx/memory_pool.zig");
pub const MemoryPoolUnmanaged = memory_pool.MemoryPoolUnmanaged;
pub const MemoryPoolAlignedUnmanaged = memory_pool.MemoryPoolAlignedUnmanaged;
pub const MemoryPoolExtraUnmanaged = memory_pool.MemoryPoolExtraUnmanaged;

pub const concurrent_hash_map = @import("stdx/concurrent_hash_map.zig");
pub const ConcurrentStringHashMapUnmanaged = concurrent_hash_map.ConcurrentStringHashMapUnmanaged;
pub const ConcurrentAutoHashMapUnmanaged = concurrent_hash_map.ConcurrentAutoHashMapUnmanaged;
pub const ConcurrentHashMapUnmanaged = concurrent_hash_map.ConcurrentHashMapUnmanaged;

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

test {
    std.testing.refAllDeclsRecursive(@This());
}
