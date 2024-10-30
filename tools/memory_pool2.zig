const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

// IDEA:
// return handles instead of pointers to avoid pointer invalidation on compaction
// TODO: find some way to project values of handle onto indices in fixed mem/pointers to heap
// (especially after a successful compaction)
// https://github.com/godotengine/godot/blob/master/core/templates/pooled_list.h


pub fn MemoryPool(comptime T: type) type {
    return MemoryPoolAligned(T, null);
}

pub fn MemoryPoolAligned(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return MemoryPoolAligned(T, null);
        }
    }
    return struct {
        arena: std.heap.ArenaAllocator,
        fixed_mem: []align(item_alignment) u8,
        free_map: BitSet,
        ext_node_list: ?*Node = null,
        ext_free_list: ?*Node = null,


        const Pool = @This();

        pub const Handle = u32;

        pub const Item = T;
        pub const item_alignment = alignment orelse @alignOf(Item);
        const ItemPtr = *align(item_alignment) Item;

        const BitSet = std.bit_set.DynamicBitSetUnmanaged;
        const NodeList = std.ArrayListUnmanaged(Handle);

        pub fn init(allocator: Allocator, fixed: u32) Allocator.Error!Pool {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .fixed_mem = try allocator.alignedAlloc(u8, item_alignment, fixed*@sizeOf(Item)),
                .free_map = BitSet.initFull(allocator, fixed),
            };
        }
    };
}
