const std = @import("std");
const mem = std.mem;

const Allocator = mem.Allocator;

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
        fixed_allocator: Allocator,
        extra_allocator: Allocator,

        active_allocator: Allocator,

        fixed_mem: []align(item_alignment) u8,

        item_map: HandleList,
        item_list: ItemList,

        free_list: HandleList,
        free_list_is_dirty: bool,

        item_map_fixed_items: ?[*]Handle = null,
        item_list_fixed_items: ?[*]?ItemPtr = null,
        free_list_fixed_items: ?[*]Handle = null,


        const Pool = @This();

        pub const Handle = u32;
        pub const invalid_handle = std.math.maxInt(Handle);

        const null_item: Handle = 0;

        pub const Item = T;
        pub const item_alignment = alignment orelse @alignOf(Item);
        const ItemPtr = *align(item_alignment) Item;

        const BitSet = std.bit_set.DynamicBitSetUnmanaged;
        const HandleList = std.ArrayListUnmanaged(Handle);
        const ItemList = std.ArrayListUnmanaged(?ItemPtr);



        /// Initialize a memory pool with a `fixed` preallocated size.
        /// Any allocations beyond this fixed size will be slower.
        /// This can be fixed with `compact()` and `resize()`.
        pub fn init(fixed_allocator: Allocator, extra_allocator: Allocator, fixed: u32) Allocator.Error!Pool {
            const fixed_mem = try fixed_allocator.alignedAlloc(u8, item_alignment, fixed*@sizeOf(Item));
            errdefer allocator.free(fixed_mem);

            const item_map = try HandleList.initCapacity(allocator, fixed);
            errdefer item_map.deinit(allocator);

            const item_list = try ItemList.initCapacity(allocator, 1+fixed);
            errdefer item_list.deinit(allocator);

            const free_list = try HandleList.initCapacity(allocator, fixed);
            errdefer free_list.deinit(allocator);

            item_list.items[null_item] = null;
            for (0..fixed) |i| {
                item_map[i] = @intCast(i);
                item_list.items[i+1] = @ptrCast(@alignCast(fixed_mem[i..][0..@sizeOf(Item)]));
                free_list.items[fixed-1-i] = @intCast(i);
            }
            return .{
                .allocator = allocator,
                .fixed_mem = fixed_mem,
                .item_map = item_map,
                .item_list = item_list,
                .free_list = free_list,
                .free_list_is_dirty = false,
            };
        }

        /// Frees underlying memory. Invalidates all `Handle`s associated with this pool.
        pub fn deinit(pool: *Pool) void {
            pool.allocator.free(pool.fixed_mem);
            pool.item_map.deinit(pool.allocator);
            pool.item_list.deinit(pool.allocator);
            pool.free_list.deinit(pool.allocator);
            pool.* = undefined;
        }


        /// Create a single item. The returned `Handle` is guaranteed
        /// to be valid for the entire lifetime of this pool.
        pub fn create(pool: *Pool) Allocator.Error!Handle {
            if (pool.fixed_free_map.toggleFirstSet()) |fixed_free| {
                pool.fixed_mem[fixed_free] = undefined;
                return @intCast(fixed_free); 
            } else if (pool.ext_free_map.popOrNull()) |ext_free| {
                assert(ext_free >= pool.fixed_mem.len);
                // 1. get index from free list
                // 2. create new handle
                // 3. map handle to index
                return ext_free;
            } else {
                @branchHint(.unlikely);
                // 1. alloc new item
                // 2. append new item to used list and get index
                // 3. create new handle
                // 4. map handle to index
            }

            const free_handle = pool.popFree();
            if (free_handle != invalid_handle) {
                pool.registerExtItem(idx: Handle)
            }
        }

        /// Destroy a single item. Checks for double frees in safe builds.
        pub fn destroy(pool: *Pool, handle: Handle) void {

        }


        /// Tries to fit all active allocations into fixed memory.
        /// Returns `true` on success and `false` if not all of them fit.
        pub fn compact(pool: *Pool) bool {

        }

        /// Resize fixed memory of the pool. Handles remain valid
        /// and fixed memory remains continuous.
        /// Asserts that `new size >= used fixed slots`.
        /// This function does not perform any compaction.
        pub fn resizeFixed(pool: *Pool, new_size: u32) Allocator.Error!void {

        }


        /// If more allocations than fixed slots available are requested
        /// we need to expand our metadata lists.
        /// This is not allowed in fixed memory so we have to move them
        /// to extra memory.
        /// They will be moved back in the event of a successful compaction.
        fn moveListsToExtraAllocator(pool: *Pool) Allocator.Error!void {
            pool.free_list_fixed_items = pool.free_list.items.ptr;
            pool.free_list.items = try pool.extra_allocator.dupe(Handle, pool.free_list.items);

            pool.item_map_fixed_items = pool.item_map.items.ptr;
            pool.item_map.items = try pool.extra_allocator.dupe(Handle, pool.item_map.items);

            pool.item_list_fixed_items = pool.item_list.items.ptr;
            pool.item_list.items = try pool.extra_allocator.dupe(ItemPtr, pool.item_list.items);

            pool.active_allocator = pool.extra_allocator;
        }


        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

        /// Reset the memory pool. Invalidates all `Handle`s associated with this pool.
        pub fn reset(pool: *Pool, mode: ResetMode) void {

        }


        inline fn registerItem(pool: *Pool, handle: Handle) Allocator.Error!void {
            
        }

        inline fn freeHandle(pool: *Pool, handle: Handle) Allocator.Error!void {
            const lowest_free_handle = pool.free_list.getLastOrNull();
            try pool.free_list.append(pool.arena.allocator(), handle);
            if (lowest_free_handle) |prev_handle| {
                pool.free_list_is_dirty = (prev_handle < handle);
            }
            pool.item_map.items[handle] = null_item;
        }

        inline fn popFree(pool: *Pool) Handle {
            if (pool.free_list.items.len == 0) {
                return invalid_handle;
            }
            // We need to ensure that popping from the free list always yields the
            // numerically smallest handle available to enable efficacious compaction.
            if (pool.free_list_is_dirty) {
                std.sort.pdq(Handle, pool.ext_free_map.items, {}, std.sort.desc(Handle));
            }
            return pool.free_list.pop();
        }

        inline fn allocNew(pool: *Pool) Allocator.Error!ItemPtr {
            const raw_mem = try pool.arena.allocator().alignedAlloc(u8, item_alignment, @sizeOf(Item));
            return @ptrCast(raw_mem);
        }
    };
}


pub fn MemoryPoolCompactable(comptime T: type) type {
    return MemoryPoolCompactableAligned(T, null);
}

pub fn MemoryPoolCompactableAligned(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return MemoryPoolCompactableAligned(T, null);
        }
    }
    return struct {
        pool: MemoryPoolAligned(T, alignment),
    };
}

// PROCESS:
// init: fixed_mem is allocated, lists are allocated, item_list is filled
// with pointers to fixed_mem in ascending order, item_map is filled with
// ascending indices (first fixed_mem.len handles map directly to fixed_mem),
// free list is filled with handles in descending order to make popping from it
// return the lowest handle available

// create: handle in free_list?
// yes -> pop handle from free_list and return it
// no -> alloc from extra_allocator and append ptr to item_list,
//       
