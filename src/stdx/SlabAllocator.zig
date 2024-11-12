//! A simple slab allocator that allocates large contiguous segments of memory
//! (usually multiple pages) and maintains minimal metadata about them.
//! Supports freeing the most recent allocation of each slab and automatically
//! frees empty slabs. Allocations larger than a single slab will result in a
//! custom-sized slab being created for them.
//!
//! Warning: frees and resizes tend to be significantly more expensive than
//! allocs even if they don't succeed. It is recommended to only use them when
//! a stack-like allocation/free pattern is being used.

const std = @import("std");
const mem = std.mem;

const Allocator = mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const assert = std.debug.assert;


backing_allocator: Allocator,
slabs: SlabList,
slab_size: usize,


const SlabAllocator = @This();

const SlabList = std.DoublyLinkedList(Slab);
const SlabNode = SlabList.Node;

const Slab = struct {
    fba: FixedBufferAllocator,

    pub const memory_offset = mem.alignForward(usize, @sizeOf(SlabNode), std.atomic.cache_line);
};


pub fn allocator(self: *SlabAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        },
    };
}


pub fn init(backing_allocator: Allocator, slab_size: usize) SlabAllocator {
    const real_slab_size = mem.alignForward(usize, slab_size, mem.page_size);
    return .{
        .backing_allocator = backing_allocator,
        .slabs = .{},
        .slab_size = real_slab_size,
    };
}

pub fn deinit(self: *SlabAllocator) void {
    var current_node = self.slabs.first;
    while (current_node) |node| {
        current_node = node.next;
        self.destroyNode(node);
    }
    self.* = undefined;
}


fn createNode(self: *SlabAllocator, size: usize) Allocator.Error!*SlabNode {
    const real_size = mem.alignForward(usize, size, mem.page_size);
    const raw_mem = try self.backing_allocator.alignedAlloc(u8, mem.page_size, real_size);
    const node: *SlabNode = @ptrCast(raw_mem[0..@sizeOf(SlabNode)]);
    @memset(raw_mem[@sizeOf(SlabNode)..Slab.memory_offset], undefined);
    const free_mem = raw_mem[Slab.memory_offset..real_size];
    node.* = .{ .data = .{ .fba = FixedBufferAllocator.init(free_mem) } };
    self.slabs.prepend(node);
    return node;
}

fn destroyNode(self: *SlabAllocator, node: *SlabNode) void {
    self.slabs.remove(node);
    const raw_mem = @as([*]u8, @ptrCast(node))[0..Slab.memory_offset+node.data.fba.buffer.len];
    self.backing_allocator.free(raw_mem);
    node.* = undefined;
}

fn getNode(self: *SlabAllocator, slice: []u8) ?*SlabNode {
    var current_node = self.slabs.first;
    while (current_node) |node| : (current_node = node.next) {
        if (node.data.fba.ownsSlice(slice)) return node;
    } else return null;
}


fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
    var current_node = self.slabs.first;
    while (current_node) |node| : (current_node = node.next) {
        const ptr = node.data.fba.allocator().rawAlloc(len, ptr_align, ret_addr) orelse continue;
        return ptr;
    } else {
        const size = @max(self.slab_size, Slab.memory_offset+len);
        const new_node = self.createNode(size) catch return null;
        return new_node.data.fba.allocator().rawAlloc(len, ptr_align, ret_addr);
    }
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
    const node = self.getNode(buf) orelse return false;
    const ok = node.data.fba.allocator().rawResize(buf, buf_align, new_len, ret_addr);
    if (ok and node.data.fba.end_index == 0) {
        @branchHint(.unlikely);
        self.destroyNode(node);
    }
    return ok;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
    const node = self.getNode(buf) orelse return;
    node.data.fba.allocator().rawFree(buf, buf_align, ret_addr);
    if (node.data.fba.end_index == 0) {
        self.destroyNode(node);
    }
}


test SlabAllocator {
    var slab_allocator = SlabAllocator.init(std.testing.allocator, 2*mem.page_size);
    defer slab_allocator.deinit();

    const a = slab_allocator.allocator();

    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorAlignedShrink(a);
    try std.heap.testAllocatorLargeAlignment(a);
}
