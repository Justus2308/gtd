child_allocator: Allocator,
bytes_remaining: u64,

const LimitedAllocator = @This();

pub fn init(child_allocator: Allocator, limit: u64) LimitedAllocator {
    return .{
        .child_allocator = child_allocator,
        .bytes_remaining = limit,
    };
}

pub fn allocator(self: *LimitedAllocator) Allocator {
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
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
    if (self.bytes_remaining >= len) {
        if (self.child_allocator.rawAlloc(len, alignment, ret_addr)) |ptr| {
            self.bytes_remaining -= len;
            return ptr;
        }
    }
    return null;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
    const diff = (@as(isize, @intCast(memory.len)) - @as(isize, @intCast(new_len)));
    if (-diff > self.bytes_remaining) {
        return false;
    }
    if (self.child_allocator.rawResize(memory, alignment, new_len, ret_addr)) {
        self.bytes_remaining += diff;
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
    const diff = (@as(isize, @intCast(memory.len)) - @as(isize, @intCast(new_len)));
    if (-diff > self.bytes_remaining) {
        return null;
    }
    if (self.child_allocator.rawRemap(memory, alignment, new_len, ret_addr)) |ptr| {
        self.bytes_remaining += diff;
        return ptr;
    }
    return null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
    self.child_allocator.rawFree(memory, alignment, ret_addr);
    self.bytes_remaining += memory.len;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
