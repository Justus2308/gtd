const std = @import("std");
const simd = std.simd;

const assert = std.debug.assert;

pub fn StaticBitSet(comptime size: usize) type {
    if (size <= @bitSizeOf(usize)) {
        return IntegerBitSet(size);
    } else if (simd.suggestVectorLength(bool)) |vector_length| {
        return VectorizedBitSet(vector_length, size);
    } else {
        return ArrayBitSet(usize, size);
    }
}

pub fn VectorizedBitSet(comptime vector_length: usize, comptime size: usize) type {
    return struct {
        // bits: BitVec,

        const bit_length: usize = size;

        const vec_len = @min(size, vector_length);
        const num_full_vecs = size / vec_len;
        const last_vec_len = size % vec_len;

        const Self = @This();

        const BitVec = @Vector(vec_len, bool);
        const IndexInt = simd.VectorIndex(BitVec);
        const IndexVec = @Vector(vec_len, IndexInt);

        const LastBitVec = @Vector(last_vec_len, bool);
        const LastIndexInt = simd.VectorIndex(LastBitVec);
        const LastIndexVec = @Vector(last_vec_len, LastIndexInt);

        vecs: [num_full_vecs]BitVec,
        last: LastBitVec,


        const iota = blk: {
            @setEvalBranchQuota(5*size);
            break :blk simd.iota(IndexInt, size);
        };

        /// Creates a bit set with no elements present.
        pub fn initEmpty() Self {
            return .{
                .vecs = @as(BitVec, @splat(false)) ** num_full_vecs,
                .last = @splat(false),
            };
        }

        /// Creates a bit set with all elements present.
        pub fn initFull() Self {
            if (size == 0) {
                return .{
                    .vecs = .{},
                    .last = .{},
                };
            } else {
                return .{
                    .vecs = @as(BitVec, @splat(true)) ** num_full_vecs,
                    .last = @splat(true),
                };
            }
        }

        /// Returns the number of bits in this bit set
        pub inline fn capacity(self: Self) usize {
            _ = self;
            return bit_length;
        }

        /// Returns true if the bit at the specified index
        /// is present in the set, false otherwise.
        pub fn isSet(self: Self, index: usize) bool {
            assert(index < bit_length);
            if (size == 0) return false;

            return self.bits[index];

            // const only_index = onlyIndex(index);
            // const only_bit_at_index: BitVec = @bitCast(@intFromBool(self.bits) & @intFromBool(only_index));
            // return @reduce(.Or, only_bit_at_index);
        }

        /// Returns the total number of set bits in this bit set.
        pub fn count(self: Self) usize {
            if (size == 0) return 0;
            return simd.countTrues(self.bits);
        }

        /// Changes the value of the specified bit of the bit
        /// set to match the passed boolean.
        pub fn setValue(self: *Self, index: usize, value: bool) void {
            assert(index < bit_length);
            if (size == 0) return;

            self.bits[index] = value;

            // const only_index = onlyIndex(index);

            // const all_value: BitVec = @splat(value);
            // const only_value_at_index: BitVec = @bitCast(@intFromBool(only_index) & @intFromBool(all_value));

            // self.bits = @bitCast((@intFromBool(self.bits) & ~@intFromBool(only_index))
            //     | @intFromBool(only_value_at_index));
        }

        /// Adds a specific bit to the bit set
        pub fn set(self: *Self, index: usize) void {
            assert(index < bit_length);
            if (size == 0) return;

            self.bits[index] = true;

            // const only_index = onlyIndex(index);
            // self.bits = (self.bits | only_index);
        }

        /// Changes the value of all bits in the specified range to
        /// match the passed boolean.
        pub fn setRangeValue(self: *Self, range: Range, value: bool) void { // -> segfault
            assert(range.end <= bit_length);
            assert(range.start <= range.end);
            _ = .{ self, value };

            // const iota = simd.iota(IndexInt, bit_length);

            // const all_start: IndexVec = @splat(@as(IndexInt, @intCast(range.start)));
            // const only_ge_start: BitVec = (iota >= all_start);

            // const all_end: IndexVec = @splat(@as(IndexInt, @intCast(range.end)));
            // const only_lt_end: BitVec = (iota < all_end);

            // const only_range: BitVec = @bitCast(@intFromBool(only_ge_start) & @intFromBool(only_lt_end));

            // const all_value: BitVec = @splat(value);
            // const only_value_in_range: BitVec = @bitCast(@intFromBool(only_range) & @intFromBool(all_value));

            // self.bits = @bitCast((@intFromBool(self.bits) & ~@intFromBool(only_range))
            //     | @intFromBool(only_value_in_range));
        }

        /// Removes a specific bit from the bit set
        pub fn unset(self: *Self, index: usize) void {
            assert(index < bit_length);
            if (size == 0) return;

            self.bits[index] = false;

            // const only_index = onlyIndex(index);
            // self.bits = @bitCast(@intFromBool(self.bits) & ~@intFromBool(only_index));
        }

        /// Flips a specific bit in the bit set
        pub fn toggle(self: *Self, index: usize) void {
            assert(index < bit_length);
            
            // const iota = simd.iota(IndexInt, bit_length);
            const all_index: IndexVec = @splat(@as(IndexInt, @intCast(index)));
            const only_index: BitVec = (iota == all_index);
            self.bits = @bitCast(@intFromBool(self.bits) ^ @intFromBool(only_index));
        }

        /// Flips all bits in this bit set which are present
        /// in the toggles bit set.
        pub fn toggleSet(self: *Self, toggles: Self) void {
            self.bits = @bitCast(@intFromBool(self.bits) ^ @intFromBool(toggles.bits));
        }

        /// Flips every bit in the bit set.
        pub fn toggleAll(self: *Self) void {
            self.bits = @bitCast(~@intFromBool(self.bits));
        }

        /// Performs a union of two bit sets, and stores the
        /// result in the first one.  Bits in the result are
        /// set if the corresponding bits were set in either input.
        pub fn setUnion(self: *Self, other: Self) void {
            self.bits = @bitCast(@intFromBool(self.bits) | @intFromBool(other.bits));
        }

        /// Performs an intersection of two bit sets, and stores
        /// the result in the first one.  Bits in the result are
        /// set if the corresponding bits were set in both inputs.
        pub fn setIntersection(self: *Self, other: Self) void {
            self.bits = @bitCast(@intFromBool(self.bits) & @intFromBool(other.bits));
        }

        /// Finds the index of the first set bit.
        /// If no bits are set, returns null.
        pub fn findFirstSet(self: Self) ?usize { // -> segfault
            _ = self;
            return null;
            // if (size == 0) return null;
            // const iota = simd.iota(IndexInt, bit_length);
            // const all_max: IndexVec = @splat(~@as(IndexInt, 0));
            // const are_set = @select(IndexInt, self.bits, iota, all_max);
            // const index: IndexInt = @reduce(.Min, are_set);
            // return if (self.bits[index]) index else null;
        }

        /// Finds the index of the first set bit, and unsets it.
        /// If no bits are set, returns null.
        pub fn toggleFirstSet(self: *Self) ?usize { // -> segfault
            _ = self;
            // return null;
            const first_set_index = 0;
            // const first_set_index = self.findFirstSet() orelse return null;
            // const iota = simd.iota(IndexInt, bit_length);
            // _ = iota;
            const all_index: IndexVec = @splat(@as(IndexInt, @intCast(first_set_index))); // <- segfault
            _ = all_index;
            // const only_first_set_index: BitVec = (iota == all_index);
            // self.bits = @bitCast(@intFromBool(self.bits) ^ @intFromBool(only_first_set_index)); // <- segfault
            return first_set_index;
        }

        /// Returns true if every corresponding bit in both
        /// bit sets are the same.
        pub fn eql(self: Self, other: Self) bool {
            if (size == 0) return true;

            const only_equal = (self.bits == other.bits);
            return @reduce(.And, only_equal);
        }

        /// Returns true if the first bit set is the subset
        /// of the second one.
        pub fn subsetOf(self: Self, other: Self) bool {
            return self.intersectWith(other).eql(self);
        }

        /// Returns true if the first bit set is the superset
        /// of the second one.
        pub fn supersetOf(self: Self, other: Self) bool {
            return other.subsetOf(self);
        }

        /// Returns the complement bit sets. Bits in the result
        /// are set if the corresponding bits were not set.
        pub fn complement(self: Self) Self {
            var result = self;
            result.toggleAll();
            return result;
        }

        /// Returns the union of two bit sets. Bits in the
        /// result are set if the corresponding bits were set
        /// in either input.
        pub fn unionWith(self: Self, other: Self) Self {
            var result = self;
            result.setUnion(other);
            return result;
        }

        /// Returns the intersection of two bit sets. Bits in
        /// the result are set if the corresponding bits were
        /// set in both inputs.
        pub fn intersectWith(self: Self, other: Self) Self {
            var result = self;
            result.setIntersection(other);
            return result;
        }

        /// Returns the xor of two bit sets. Bits in the
        /// result are set if the corresponding bits were
        /// not the same in both inputs.
        pub fn xorWith(self: Self, other: Self) Self {
            var result = self;
            result.toggleSet(other);
            return result;
        }

        /// Returns the difference of two bit sets. Bits in
        /// the result are set if set in the first but not
        /// set in the second set.
        pub fn differenceWith(self: Self, other: Self) Self {
            var result = self;
            result.setIntersection(other.complement());
            return result;
        }
    };
}


/// A range of indices within a bitset.
pub const Range = struct {
    /// The index of the first bit of interest.
    start: usize,
    /// The index immediately after the last bit of interest.
    end: usize,
};


// ---------------- Tests -----------------

const testing = std.testing;

fn testEql(empty: anytype, full: anytype, len: usize) !void {
    try testing.expect(empty.eql(empty));
    try testing.expect(full.eql(full));
    switch (len) {
        0 => {
            try testing.expect(empty.eql(full));
            try testing.expect(full.eql(empty));
        },
        else => {
            try testing.expect(!empty.eql(full));
            try testing.expect(!full.eql(empty));
        },
    }
}

fn testSubsetOf(empty: anytype, full: anytype, even: anytype, odd: anytype, len: usize) !void {
    try testing.expect(empty.subsetOf(empty));
    try testing.expect(empty.subsetOf(full));
    try testing.expect(full.subsetOf(full));
    switch (len) {
        0 => {
            try testing.expect(even.subsetOf(odd));
            try testing.expect(odd.subsetOf(even));
        },
        1 => {
            try testing.expect(!even.subsetOf(odd));
            try testing.expect(odd.subsetOf(even));
        },
        else => {
            try testing.expect(!even.subsetOf(odd));
            try testing.expect(!odd.subsetOf(even));
        },
    }
}

fn testSupersetOf(empty: anytype, full: anytype, even: anytype, odd: anytype, len: usize) !void {
    try testing.expect(full.supersetOf(full));
    try testing.expect(full.supersetOf(empty));
    try testing.expect(empty.supersetOf(empty));
    switch (len) {
        0 => {
            try testing.expect(even.supersetOf(odd));
            try testing.expect(odd.supersetOf(even));
        },
        1 => {
            try testing.expect(even.supersetOf(odd));
            try testing.expect(!odd.supersetOf(even));
        },
        else => {
            try testing.expect(!even.supersetOf(odd));
            try testing.expect(!odd.supersetOf(even));
        },
    }
}

fn testBitSet(a: anytype, b: anytype, len: usize) !void {
    try testing.expectEqual(len, a.capacity());
    try testing.expectEqual(len, b.capacity());

    {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            a.setValue(i, i & 1 == 0);
            b.setValue(i, i & 2 == 0);
        }
    }

    try testing.expectEqual((len + 1) / 2, a.count());
    try testing.expectEqual((len + 3) / 4 + (len + 2) / 4, b.count());

    // {
    //     var iter = a.iterator(.{});
    //     var i: usize = 0;
    //     while (i < len) : (i += 2) {
    //         try testing.expectEqual(@as(?usize, i), iter.next());
    //     }
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    // }
    a.toggleAll();
    // {
    //     var iter = a.iterator(.{});
    //     var i: usize = 1;
    //     while (i < len) : (i += 2) {
    //         try testing.expectEqual(@as(?usize, i), iter.next());
    //     }
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    // }

    // {
    //     var iter = b.iterator(.{ .kind = .unset });
    //     var i: usize = 2;
    //     while (i < len) : (i += 4) {
    //         try testing.expectEqual(@as(?usize, i), iter.next());
    //         if (i + 1 < len) {
    //             try testing.expectEqual(@as(?usize, i + 1), iter.next());
    //         }
    //     }
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    // }

    {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            try testing.expectEqual(i & 1 != 0, a.isSet(i));
            try testing.expectEqual(i & 2 == 0, b.isSet(i));
        }
    }

    a.setUnion(b.*);
    {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            try testing.expectEqual(i & 1 != 0 or i & 2 == 0, a.isSet(i));
            try testing.expectEqual(i & 2 == 0, b.isSet(i));
        }

        // i = len;
        // var set = a.iterator(.{ .direction = .reverse });
        // var unset = a.iterator(.{ .kind = .unset, .direction = .reverse });
        // while (i > 0) {
        //     i -= 1;
        //     if (i & 1 != 0 or i & 2 == 0) {
        //         try testing.expectEqual(@as(?usize, i), set.next());
        //     } else {
        //         try testing.expectEqual(@as(?usize, i), unset.next());
        //     }
        // }
        // try testing.expectEqual(@as(?usize, null), set.next());
        // try testing.expectEqual(@as(?usize, null), set.next());
        // try testing.expectEqual(@as(?usize, null), set.next());
        // try testing.expectEqual(@as(?usize, null), unset.next());
        // try testing.expectEqual(@as(?usize, null), unset.next());
        // try testing.expectEqual(@as(?usize, null), unset.next());
    }

    a.toggleSet(b.*);
    {
        try testing.expectEqual(len / 4, a.count());

        var i: usize = 0;
        while (i < len) : (i += 1) {
            try testing.expectEqual(i & 1 != 0 and i & 2 != 0, a.isSet(i));
            try testing.expectEqual(i & 2 == 0, b.isSet(i));
            if (i & 1 == 0) {
                a.set(i);
            } else {
                a.unset(i);
            }
        }
    }

    a.setIntersection(b.*);
    {
        try testing.expectEqual((len + 3) / 4, a.count());

        var i: usize = 0;
        while (i < len) : (i += 1) {
            try testing.expectEqual(i & 1 == 0 and i & 2 == 0, a.isSet(i));
            try testing.expectEqual(i & 2 == 0, b.isSet(i));
        }
    }

    // toggleSet, isSet, set, unset, setIntersection, findFirstSet, toggleFirstSet

    a.toggleSet(a.*);
    // {
    //     var iter = a.iterator(.{});
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(usize, 0), a.count());
    // }
    // {
    //     var iter = a.iterator(.{ .direction = .reverse });
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(?usize, null), iter.next());
    //     try testing.expectEqual(@as(usize, 0), a.count());
    // }

    const test_bits = [_]usize{
        0,  1,  2,   3,   4,   5,    6, 7, 9, 10, 11, 22, 31, 32, 63, 64,
        66, 95, 127, 160, 192, 1000,
    };
    for (test_bits) |i| {
        if (i < a.capacity()) {
            a.set(i);
        }
    }

    for (test_bits) |i| {
        if (i < a.capacity()) {
            try testing.expectEqual(@as(?usize, i), a.findFirstSet());
            try testing.expectEqual(@as(?usize, i), a.toggleFirstSet());
        }
    }
    try testing.expectEqual(@as(?usize, null), a.findFirstSet());
    try testing.expectEqual(@as(?usize, null), a.toggleFirstSet());
    try testing.expectEqual(@as(?usize, null), a.findFirstSet());
    try testing.expectEqual(@as(?usize, null), a.toggleFirstSet());
    try testing.expectEqual(@as(usize, 0), a.count());

    a.setRangeValue(.{ .start = 0, .end = len }, false);
    try testing.expectEqual(@as(usize, 0), a.count());

    a.setRangeValue(.{ .start = 0, .end = len }, true);
    try testing.expectEqual(len, a.count());

    a.setRangeValue(.{ .start = 0, .end = len }, false);
    a.setRangeValue(.{ .start = 0, .end = 0 }, true);
    try testing.expectEqual(@as(usize, 0), a.count());

    a.setRangeValue(.{ .start = len, .end = len }, true);
    try testing.expectEqual(@as(usize, 0), a.count());

    if (len >= 1) {
        a.setRangeValue(.{ .start = 0, .end = len }, false);
        a.setRangeValue(.{ .start = 0, .end = 1 }, true);
        try testing.expectEqual(@as(usize, 1), a.count());
        try testing.expect(a.isSet(0));

        a.setRangeValue(.{ .start = 0, .end = len }, false);
        a.setRangeValue(.{ .start = 0, .end = len - 1 }, true);
        try testing.expectEqual(len - 1, a.count());
        try testing.expect(!a.isSet(len - 1));

        a.setRangeValue(.{ .start = 0, .end = len }, false);
        a.setRangeValue(.{ .start = 1, .end = len }, true);
        try testing.expectEqual(@as(usize, len - 1), a.count());
        try testing.expect(!a.isSet(0));

        a.setRangeValue(.{ .start = 0, .end = len }, false);
        a.setRangeValue(.{ .start = len - 1, .end = len }, true);
        try testing.expectEqual(@as(usize, 1), a.count());
        try testing.expect(a.isSet(len - 1));

        if (len >= 4) {
            a.setRangeValue(.{ .start = 0, .end = len }, false);
            a.setRangeValue(.{ .start = 1, .end = len - 2 }, true);
            try testing.expectEqual(@as(usize, len - 3), a.count());
            try testing.expect(!a.isSet(0));
            try testing.expect(a.isSet(1));
            try testing.expect(a.isSet(len - 3));
            try testing.expect(!a.isSet(len - 2));
            try testing.expect(!a.isSet(len - 1));
        }
    }
}

fn fillEven(set: anytype, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        set.setValue(i, i & 1 == 0);
    }
}

fn fillOdd(set: anytype, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        set.setValue(i, i & 1 == 1);
    }
}

fn testPureBitSet(comptime Set: type) !void {
    const empty = Set.initEmpty();
    const full = Set.initFull();

    const even = even: {
        var bit_set = Set.initEmpty();
        fillEven(&bit_set, Set.bit_length);
        break :even bit_set;
    };

    const odd = odd: {
        var bit_set = Set.initEmpty();
        fillOdd(&bit_set, Set.bit_length);
        break :odd bit_set;
    };

    try testSubsetOf(empty, full, even, odd, Set.bit_length);
    try testSupersetOf(empty, full, even, odd, Set.bit_length);

    try testing.expect(empty.complement().eql(full));
    try testing.expect(full.complement().eql(empty));
    try testing.expect(even.complement().eql(odd));
    try testing.expect(odd.complement().eql(even));

    try testing.expect(empty.unionWith(empty).eql(empty));
    try testing.expect(empty.unionWith(full).eql(full));
    try testing.expect(full.unionWith(full).eql(full));
    try testing.expect(full.unionWith(empty).eql(full));
    try testing.expect(even.unionWith(odd).eql(full));
    try testing.expect(odd.unionWith(even).eql(full));

    try testing.expect(empty.intersectWith(empty).eql(empty));
    try testing.expect(empty.intersectWith(full).eql(empty));
    try testing.expect(full.intersectWith(full).eql(full));
    try testing.expect(full.intersectWith(empty).eql(empty));
    try testing.expect(even.intersectWith(odd).eql(empty));
    try testing.expect(odd.intersectWith(even).eql(empty));

    try testing.expect(empty.xorWith(empty).eql(empty));
    try testing.expect(empty.xorWith(full).eql(full));
    try testing.expect(full.xorWith(full).eql(empty));
    try testing.expect(full.xorWith(empty).eql(full));
    try testing.expect(even.xorWith(odd).eql(full));
    try testing.expect(odd.xorWith(even).eql(full));

    try testing.expect(empty.differenceWith(empty).eql(empty));
    try testing.expect(empty.differenceWith(full).eql(empty));
    try testing.expect(full.differenceWith(full).eql(empty));
    try testing.expect(full.differenceWith(empty).eql(full));
    try testing.expect(full.differenceWith(odd).eql(even));
    try testing.expect(full.differenceWith(even).eql(odd));
}

fn testStaticBitSet(comptime Set: type) !void {
    var a = Set.initEmpty();
    var b = Set.initFull();
    try testing.expectEqual(@as(usize, 0), a.count());
    try testing.expectEqual(@as(usize, Set.bit_length), b.count());

    try testEql(a, b, Set.bit_length);
    try testBitSet(&a, &b, Set.bit_length);

    try testPureBitSet(Set);
}


test VectorizedBitSet {
    inline for (.{ 0, 1, 2, 31, 32, 33, 63, 64, 65, 254, 500, 3000 }) |size| {
        try testStaticBitSet(VectorizedBitSet(size));
    }
}
