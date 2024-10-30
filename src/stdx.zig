const std = @import("std");
const math = std.math;
const mem = std.mem;
const simd = std.simd;

const assert = std.debug.assert;
const expect = std.testing.expext;

const cache_line = std.atomic.cache_line;


const memory_pool = @import("stdx/memory_pool.zig");
pub const MemoryPool = memory_pool.MemoryPool;
pub const MemoryPoolAligned = memory_pool.MemoryPoolAligned;

pub const ThreadPool = @import("stdx/ThreadPool.zig");

/// Thin wrapper around basic SIMD vector functionality to
/// make it easier to work with enums and slices.
/// Currently only works for C-ABI-compatible element sizes.
pub fn SimdVec(comptime length: comptime_int, comptime T: type) type {
    // Check for unwanted padding in array representation
    assert(@bitSizeOf(T) >= mem.byte_size_in_bits);
    assert(math.isPowerOfTwo(@bitSizeOf(T)));
    assert(@sizeOf(T) <= @alignOf(T));
    return extern union {
        scalar: ScalarType,
        vector: VectorType,

        const Self = @This();

        pub const ScalarType = [Self.len]ScalarElem;
        pub const VectorType = @Vector(Self.len, VectorElem);

        pub const ScalarElem = T;
        pub const VectorElem = switch (@typeInfo(T)) {
            .@"enum" => |info| info.tag_type,
            else => T,
        };
        pub const len = length;
        pub const len2 = simd.suggestVectorLength(VectorElem) orelse 1;


        pub fn splat(value: ScalarElem) Self {
            return .{ .vector = @splat(@as(VectorElem, @bitCast(value))) };
        }

        pub inline fn fromSlice(slice: []ScalarElem) *Self {
            assert(slice.len == Self.len);
            return @ptrCast(@alignCast(slice));
        }
        pub inline fn toSlice(self: *Self) []ScalarElem {
            return @as([*]ScalarElem, @ptrCast(@alignCast(self)))[0..Self.len];
        }


        comptime {
            assert(@bitSizeOf(ScalarType) == @bitSizeOf(VectorType));
        }
    };
}


const max_simd_ops_per_batch = 8;

pub const SimdBatches = struct {
    /// Size of every batch in elements.
    batch_size: comptime_int,
    /// Number of batches needed.
    batch_count: comptime_int,
    /// Number of remaining elements (< `batch_size`).
    remaining_elem_count: comptime_int,
    /// SIMD vector type that can hold a single batch.
    simd_vec: type,
};
/// Calculates optimal SIMD batching parameters.
/// Tries to align batch sizes to a cache line.
pub fn calculateSimdBatches(comptime Element: type, comptime element_count: usize) SimdBatches {
    assert(element_count > 0);

    const elem_size = @sizeOf(Element);
    if (!math.isPowerOfTwo(elem_size))
        @compileError("needs power-of-two element size");

    const simd_vec_byte_length = simd.suggestVectorLength(u8);
    if (!math.isPowerOfTwo(simd_vec_byte_length))
        todo("support non-power-of-two SIMD vector sizes");

    const max_simd_bytes_per_batch = max_simd_ops_per_batch * simd_vec_byte_length;
    const max_batch_size = @max(cache_line, max_simd_bytes_per_batch);
    const max_elems_per_batch = max_batch_size / elem_size;

    const size = @max(1, @min(max_elems_per_batch, element_count));
    const count = element_count / size;
    const remaining = element_count % size;
    return .{
        .batch_size = size,
        .batch_count = count,
        .remaining_elem_count = remaining,
        .simd_vec = SimdVec(size, Element),
    };
}

pub fn todo(comptime msg: []const u8) noreturn {
    @compileError("TODO: " ++ msg);
}
