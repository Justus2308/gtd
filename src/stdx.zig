const std = @import("std");
const math = std.math;
const mem = std.mem;

const assert = std.debug.assert;
const expect = std.testing.expext;

const cache_line = std.atomic.cache_line;

pub const Asset = @import("stdx/Asset.zig");
pub const ThreadPool = @import("stdx/ThreadPool.zig");
pub const integrate = @import("stdx/integrate.zig");
pub const Obj = @import("stdx/Obj.zig");
pub const simd = @import("stdx/simd.zig");
pub const StaticMultiArrayList = @import("stdx/static_multi_array_list.zig").StaticMultiArrayList;

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

test {
    std.testing.refAllDeclsRecursive(@This());
}
