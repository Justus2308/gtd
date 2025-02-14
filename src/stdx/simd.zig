const std = @import("std");
const stdx = @import("stdx");

const math = std.math;
const mem = std.mem;
const simd = std.simd;

const assert = std.debug.assert;
const expect = std.testing.expext;

const cache_line = std.atomic.cache_line;



pub const max_ops_per_batch = 8;


pub fn AutoVector(comptime length: comptime_int, comptime T: type) type {
    return switch (T) {
        bool, u1 => BitVector(length),
        else => Vector(length, T),
    };
}


/// Thin wrapper around basic SIMD vector functionality to
/// make it easier to work with enums and slices.
/// Currently only works for C-ABI-compatible element sizes.
pub fn Vector(comptime length: comptime_int, comptime T: type) type {
    // Check for unwanted padding in array representation
    assert(@bitSizeOf(T) >= mem.byte_size_in_bits);
    assert(math.isPowerOfTwo(@bitSizeOf(T)));

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
        pub const suggested_len = simd.suggestVectorLength(VectorElem) orelse 1;


        pub inline fn splat(value: ScalarElem) Self {
            return .{ .vector = @splat(@as(VectorElem, @bitCast(value))) };
        }

        pub inline fn fromSlice(slice: []ScalarElem) *Self {
            assert(slice.len == Self.len);
            return @ptrCast(@alignCast(slice));
        }
        pub inline fn toSlice(self: *Self) []ScalarElem {
            return @as([*]ScalarElem, @ptrCast(@alignCast(self)))[0..Self.len];
        }

        pub inline fn batchSize() comptime_int {
            return (max_ops_per_batch * Self.suggested_len);
        }


        comptime {
            assert(@bitSizeOf(ScalarType) == @bitSizeOf(VectorType));
        }
    };
}

pub fn BitVector(comptime length: comptime_int) type {
    comptime if (length % @bitSizeOf(usize) != 0) {
        @compileError(std.fmt.comptimePrint("length needs to be a multiple of {d}", .{ @bitSizeOf(usize) }));
    };
    return extern union {
        set: BitSet,
        bits: BitVecType,
        bools: BoolVecType,

        pub const len = length;

        pub const BitSet = std.bit_set.StaticBitSet(length);
        pub const BitVecType = @Vector(length, u1);
        pub const BoolVecType = @Vector(length, bool);

        const Self = @This();

        pub inline fn splat(value: bool) Self {
            return .{ .bools = @splat(value) };
        }

        pub inline fn batchSize() comptime_int {
            return (max_ops_per_batch * Self.suggested_len);
        }


        comptime {
            assert(@bitSizeOf(Self) == length);
        }
    };
}

pub const Batches = struct {
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
pub fn calculateBatches(comptime Element: type, comptime element_count: usize) Batches {
    assert(element_count > 0);

    const elem_size = @sizeOf(Element);
    if (!math.isPowerOfTwo(elem_size))
        @compileError("needs power-of-two element size");

    const simd_vec_byte_length = simd.suggestVectorLength(u8);
    if (!math.isPowerOfTwo(simd_vec_byte_length))
        stdx.todo("support non-power-of-two SIMD vector sizes");

    const max_simd_bytes_per_batch = max_ops_per_batch * simd_vec_byte_length;
    const max_batch_size = @max(cache_line, max_simd_bytes_per_batch);
    const max_elems_per_batch = max_batch_size / elem_size;

    const size = @max(1, @min(max_elems_per_batch, element_count));
    const count = element_count / size;
    const remaining = element_count % size;
    return .{
        .batch_size = size,
        .batch_count = count,
        .remaining_elem_count = remaining,
        .simd_vec = Vector(size, Element),
    };
}
