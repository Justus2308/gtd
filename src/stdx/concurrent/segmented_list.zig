const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// Thread-safe and lock-free version of the one in `std` as suggested in [issue #20491](https://github.com/ziglang/zig/issues/20491).
///
/// This is a stack data structure where pointers to indexes have the same lifetime as the data structure
/// itself, unlike ArrayList where append() invalidates all existing element pointers.
/// The tradeoff is that elements are not guaranteed to be contiguous. For that, use ArrayList.
/// Note however that most elements are contiguous, making this data structure cache-friendly.
///
/// Because it never has to copy elements from an old location to a new location, it does not require
/// its elements to be copyable, and it avoids wasting memory when backed by an ArenaAllocator.
/// Note that the append() and pop() convenience methods perform a copy, but you can instead use
/// addOne(), at(), setCapacity(), and shrinkCapacity() to avoid copying items.
///
/// This data structure has O(1) append and O(1) pop.
pub fn SegmentedList(comptime Elem: type, comptime Len: type) type {
    switch (@typeInfo(Len)) {
        .int => |info| {
            if (info.bits == 0) @compileError("need to be able to represent 1");
            if (info.bits > @typeInfo(usize).int.bits) @compileError("cannot have more bits than 'usize'");
        },
        else => |info| @compileError("need 'int', got '" ++ @tagName(info) ++ "'"),
    }
    return struct {
        segments: [max_segment_count]std.atomic.Value(?[*]Elem),
        len: std.atomic.Value(AtomicLen),

        const Self = @This();

        /// Atomics only work with C ABI compatible integer types.
        const AtomicLen = std.meta.Int(.unsigned, std.math.ceilPowerOfTwoAssert(u16, @typeInfo(Len).int.bits));
        const SegmentIndex = std.math.Log2Int(Len);
        const SegmentCount = std.math.Log2IntCeil(Len);

        const first_segment_count: Len = @max(1, std.math.floorPowerOfTwo(Len, (std.atomic.cache_line / @sizeOf(Elem))));
        const first_segment_shift = std.math.log2_int(Len, first_segment_count);
        pub const max_segment_count: SegmentCount = (@typeInfo(Len).int.bits - first_segment_shift);
        pub const max_elem_count = (std.math.maxInt(Len) - first_segment_count + 1);

        pub const empty = Self{
            .segments = @splat(.init(null)),
            .len = .init(0),
        };

        fn AtType(comptime SelfType: type) type {
            if (@typeInfo(SelfType).pointer.is_const) {
                return *const Elem;
            } else {
                return *Elem;
            }
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (&self.segments, 0..) |*segment, i| {
                const ptr = segment.raw;
                if (ptr) |p| {
                    const segment_size = segmentSize(@intCast(i));
                    gpa.free(p[0..segment_size]);
                } else {
                    break;
                }
            }
            self.* = undefined;
        }

        pub fn at(self: anytype, index: Len) AtType(@TypeOf(self)) {
            assert(index < self.count());
            return self.uncheckedAt(index);
        }

        pub fn uncheckedAt(self: anytype, index: Len) AtType(@TypeOf(self)) {
            const segment_index = segmentIndex(index);
            const elem_index = elemIndex(index, segment_index);
            return &self.segments[segment_index].load(.acquire).?[elem_index];
        }

        pub fn count(self: *Self) Len {
            return @intCast(self.len.load(.acquire));
        }
        /// Caution: This might be a non-trivial calculation since capacity doesn't get tracked explicitly.
        pub fn capacity(self: *Self) Len {
            const guaranteed_segment_count = segmentCount(self.count());
            var total_segment_count = guaranteed_segment_count;
            for (self.segments[guaranteed_segment_count..max_segment_count]) |*segment| {
                if (segment.load(.acquire) != null) {
                    total_segment_count += 1;
                } else {
                    break;
                }
            }
            // We shift in two steps and perform a wrapping subtraction because of what happens
            // when all segments are allocated:
            // @as(Len, 1) << @bitSizeOf(Len) = 0;
            // 0 -% first_segment_count = max_elem_count;
            return ((@as(Len, 1) << total_segment_count << first_segment_shift) -% first_segment_count);
        }

        pub fn append(self: *Self, gpa: Allocator, elem: Elem) Allocator.Error!void {
            const new_elem_ptr = try self.addOne(gpa);
            new_elem_ptr.* = elem;
        }

        pub fn appendSlice(self: *Self, gpa: Allocator, elems: []const Elem) Allocator.Error!void {
            const elem_count: Len = @intCast(elems.len);
            try self.ensureUnusedCapacity(gpa, elem_count);

            var cur_len = self.len.load(.acquire);
            var first_elem_ptr = self.uncheckedAt(@intCast(cur_len));
            while (self.len.cmpxchgWeak(cur_len, (cur_len + elem_count), .acq_rel, .acquire)) |new_len| {
                cur_len = new_len;
                first_elem_ptr = self.uncheckedAt(@intCast(cur_len));
            }

            const slice = @as([*]Elem, @ptrCast(first_elem_ptr))[0..elem_count];
            @memcpy(slice, elems);
        }

        pub fn pop(self: *Self) ?Elem {
            var cur_len = self.len.load(.acquire);
            if (cur_len == 0) {
                return null;
            }
            var elem = self.uncheckedAt(@intCast(cur_len - 1)).*;
            while (self.len.cmpxchgWeak(cur_len, (cur_len - 1), .acq_rel, .acquire)) |new_len| {
                cur_len = new_len;
                if (cur_len == 0) {
                    return null;
                }
                elem = self.uncheckedAt(@intCast(cur_len - 1)).*;
            }
            return elem;
        }

        pub fn addOne(self: *Self, gpa: Allocator) Allocator.Error!*Elem {
            try self.ensureUnusedCapacity(gpa, 1);
            return self.addOneAssumeCapacity();
        }

        pub fn addOneAssumeCapacity(self: *Self) *Elem {
            var cur_len = self.len.load(.acquire);
            assert(self.segments[segmentIndex(@intCast(cur_len))].load(.acquire) != null);
            var elem_ptr = self.uncheckedAt(@intCast(cur_len));
            while (self.len.cmpxchgWeak(cur_len, (cur_len + 1), .acq_rel, .acquire)) |new_len| {
                cur_len = new_len;
                elem_ptr = self.uncheckedAt(@intCast(cur_len));
            }
            return elem_ptr;
        }

        /// Reduce length to `new_len`.
        /// Invalidates pointers for the elements at index new_len and beyond.
        pub fn shrinkRetainingCapacity(self: *Self, new_len: Len) void {
            assert(new_len <= self.count());
            self.len.store(new_len, .release);
        }

        /// Invalidates all element pointers.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.len.store(0, .release);
        }

        /// Invalidates all element pointers.
        // pub fn clearAndFree(self: *Self, allocator: Allocator) void {
        //     self.setCapacity(allocator, 0) catch unreachable;
        //     self.len.store(0, .release);
        // }

        pub fn ensureTotalCapacity(self: *Self, gpa: Allocator, new_capacity: Len) Allocator.Error!void {
            const min_segment_count = segmentCount(new_capacity);
            try self.ensureSegmentCount(gpa, min_segment_count);
        }

        pub fn ensureUnusedCapacity(self: *Self, gpa: Allocator, additional_count: Len) Allocator.Error!void {
            const min_segment_count = segmentCount(self.count() + additional_count);
            try self.ensureSegmentCount(gpa, min_segment_count);
        }

        fn ensureSegmentCount(self: *Self, gpa: Allocator, min_segment_count: SegmentCount) Allocator.Error!void {
            const guaranteed_segment_count = segmentCount(self.count());
            if (guaranteed_segment_count >= min_segment_count) {
                return;
            }
            for (self.segments[guaranteed_segment_count..min_segment_count], guaranteed_segment_count..) |*segment, i| {
                if (segment.load(.acquire) == null) {
                    const segment_index: SegmentIndex = @intCast(i);
                    const segment_size = segmentSize(segment_index);
                    const new_segment = try gpa.alloc(Elem, segment_size);

                    if (segment.cmpxchgStrong(
                        null,
                        new_segment.ptr,
                        .release,
                        .monotonic,
                    ) != null) {
                        gpa.free(new_segment);
                    }
                }
            }
        }

        /// Only shrinks capacity or retains current capacity.
        /// It may fail to reduce the capacity in which case the capacity will remain unchanged.
        // pub fn shrinkCapacity(self: *Self, allocator: Allocator, new_capacity: usize) void {
        //     if (new_capacity <= prealloc_item_count) {
        //         const len = @as(ShelfIndex, @intCast(self.dynamic_segments.len));
        //         self.freeShelves(allocator, len, 0);
        //         allocator.free(self.dynamic_segments);
        //         self.dynamic_segments = &[_][*]T{};
        //         return;
        //     }

        //     const new_cap_shelf_count = shelfCount(new_capacity);
        //     const old_shelf_count = @as(ShelfIndex, @intCast(self.dynamic_segments.len));
        //     assert(new_cap_shelf_count <= old_shelf_count);
        //     if (new_cap_shelf_count == old_shelf_count) return;

        //     // freeShelves() must be called before resizing the dynamic
        //     // segments, but we don't know if resizing the dynamic segments
        //     // will work until we try it. So we must allocate a fresh memory
        //     // buffer in order to reduce capacity.
        //     const new_dynamic_segments = allocator.alloc([*]T, new_cap_shelf_count) catch return;
        //     self.freeShelves(allocator, old_shelf_count, new_cap_shelf_count);
        //     if (allocator.resize(self.dynamic_segments, new_cap_shelf_count)) {
        //         // We didn't need the new memory allocation after all.
        //         self.dynamic_segments = self.dynamic_segments[0..new_cap_shelf_count];
        //         allocator.free(new_dynamic_segments);
        //     } else {
        //         // Good thing we allocated that new memory slice.
        //         @memcpy(new_dynamic_segments, self.dynamic_segments[0..new_cap_shelf_count]);
        //         allocator.free(self.dynamic_segments);
        //         self.dynamic_segments = new_dynamic_segments;
        //     }
        // }

        // pub fn shrink(self: *Self, new_len: usize) void {
        //     assert(new_len <= self.len);
        //     // TODO take advantage of the new realloc semantics
        //     self.len = new_len;
        // }

        fn segmentCount(elem_count: Len) SegmentCount {
            return (std.math.log2_int_ceil(Len, (elem_count + first_segment_count)) - first_segment_shift);
        }

        fn segmentSize(segment_index: SegmentIndex) Len {
            return (@as(Len, 1) << (segment_index + first_segment_shift));
        }

        fn segmentIndex(list_index: Len) SegmentIndex {
            return (std.math.log2_int(Len, (list_index + first_segment_count)) - first_segment_shift);
        }

        fn elemIndex(list_index: Len, segment_index: SegmentIndex) Len {
            return (list_index + first_segment_count - (@as(Len, 1) << (segment_index + first_segment_shift)));
        }

        // Example for Elem=i32, Len=u8:
        // cache_line = 128
        // first_segment_count = (128 / 4) = 32
        // first_segment_shift = log2(32) = 5
        // max_segment_count = 8 - 5 = 3 => 32, 64, 128
        // max_elem_count = 255 - 32 + 1 = 224
        //
        // segmentCount(elem_count):
        // 0: log2ceil(0 + 32) - 5 = 5 - 5 = 0
        // 1: log2ceil(1 + 32) - 5 = 6 - 5 = 1
        // 32: log2ceil(32 + 32) - 5 = 6 - 5 = 1
        // 33: log2ceil(33 + 32) - 5 = 7 - 5 = 2
        // 224: log2ceil(224 + 32) - 5 = 8 - 5 = 3
        // 255: log2ceil(255 + 32) - 5 = 9 - 5 = 4 (OOB)
        //
        // segmentSize(segment_index):
        // 0: 1 << (0 + 5) = 32
        // 1: 1 << (1 + 5) = 64
        // 2: 1 << (2 + 5) = 128
        //
        // segmentIndex(list_index):
        // 0: log2(0 + 32) - 5 = 5 - 5 = 0
        // 1: log2(1 + 32) - 5 = 5 - 5 = 0
        // 32: log2(32 + 32) - 5 = 6 - 5 = 1
        // 33: log2(33 + 32) - 5 = 6 - 5 = 1
        // 96: log2(96 + 32) - 5 = 7 - 5 = 2
        // 223: log2(223 + 32) - 5 = 7 - 5 = 2
        // 224: log2(224 + 32) - 5 = 8 - 5 = 3 (OOB)
        //
        // elemIndex(list_index, segment_index):
        // 0, 0: 0 + 32 - (1 << (0 + 5)) = 32 - 32 = 0

        // comptime {
        //     @compileLog(max_segment_count);
        //     for (0..max_segment_count) |i| {
        //         @compileLog(segmentSize(i));
        //     }
        // }

        // comptime {
        //     for (0..32) |i| {
        //         @compileLog(segmentCount(i));
        //     }
        // }
    };
}

test "basic usage" {
    try testSegmentedList(u8);
    try testSegmentedList(u12);
    try testSegmentedList(u16);
    try testSegmentedList(u24);
    try testSegmentedList(u32);
    try testSegmentedList(usize);
}

fn testSegmentedList(comptime Len: type) !void {
    const allocator = testing.allocator;

    var list = SegmentedList(i32, Len).empty;
    defer list.deinit(allocator);

    {
        var i: Len = 0;
        while (i < 100) : (i += 1) {
            try list.append(allocator, @as(i32, @intCast(i + 1)));
            try testing.expect(list.count() == i + 1);
        }
    }

    {
        var i: Len = 0;
        while (i < 100) : (i += 1) {
            try testing.expect(list.at(i).* == @as(i32, @intCast(i + 1)));
        }
    }

    // {
    //     var it = list.iterator(0);
    //     var x: i32 = 0;
    //     while (it.next()) |item| {
    //         x += 1;
    //         try testing.expect(item.* == x);
    //     }
    //     try testing.expect(x == 100);
    //     while (it.prev()) |item| : (x -= 1) {
    //         try testing.expect(item.* == x);
    //     }
    //     try testing.expect(x == 0);
    // }

    // {
    //     var it = list.constIterator(0);
    //     var x: i32 = 0;
    //     while (it.next()) |item| {
    //         x += 1;
    //         try testing.expect(item.* == x);
    //     }
    //     try testing.expect(x == 100);
    //     while (it.prev()) |item| : (x -= 1) {
    //         try testing.expect(item.* == x);
    //     }
    //     try testing.expect(x == 0);
    // }

    try testing.expect(list.pop().? == 100);
    try testing.expect(list.count() == 99);

    try list.appendSlice(allocator, &[_]i32{ 1, 2, 3 });
    try testing.expect(list.count() == 102);
    try testing.expect(list.pop().? == 3);
    try testing.expect(list.pop().? == 2);
    try testing.expect(list.pop().? == 1);
    try testing.expect(list.count() == 99);

    try list.appendSlice(allocator, &[_]i32{});
    try testing.expect(list.count() == 99);

    // {
    //     var i: i32 = 99;
    //     while (list.pop()) |item| : (i -= 1) {
    //         try testing.expect(item == i);
    //         list.shrinkCapacity(testing.allocator, list.len);
    //     }
    // }

    // {
    //     var control: [100]i32 = undefined;
    //     var dest: [100]i32 = undefined;

    //     var i: i32 = 0;
    //     while (i < 100) : (i += 1) {
    //         try list.append(testing.allocator, i + 1);
    //         control[@as(usize, @intCast(i))] = i + 1;
    //     }

    //     @memset(dest[0..], 0);
    //     list.writeToSlice(dest[0..], 0);
    //     try testing.expect(mem.eql(i32, control[0..], dest[0..]));

    //     @memset(dest[0..], 0);
    //     list.writeToSlice(dest[50..], 50);
    //     try testing.expect(mem.eql(i32, control[50..], dest[50..]));
    // }

    // try list.setCapacity(testing.allocator, 0);
}

test "clearRetainingCapacity" {
    var list = SegmentedList(i32, u32).empty;
    defer list.deinit(testing.allocator);

    try list.appendSlice(testing.allocator, &[_]i32{ 4, 5 });
    list.clearRetainingCapacity();
    try list.append(testing.allocator, 6);
    try testing.expect(list.at(0).* == 6);
    try testing.expect(list.count() == 1);
    list.clearRetainingCapacity();
    try testing.expect(list.count() == 0);
}
