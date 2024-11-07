const std = @import("std");
const mem = std.mem;

const Allocator = mem.Allocator;
const AtomicUsize = std.atomic.Value(usize);

const assert = std.debug.assert;
const log = std.log.scoped(.allocator);

const page_allocator = std.heap.page_allocator;

const is_debug = (@import("builtin").mode == .Debug);


state: State = .{},


const TrackingPageAllocator = @This();

const State = if (is_debug) struct {
    total_alloc_count: AtomicUsize = AtomicUsize.init(0),
    total_free_count: AtomicUsize = AtomicUsize.init(0),
    total_alloc_size: AtomicUsize = AtomicUsize.init(0),
    total_free_size: AtomicUsize = AtomicUsize.init(0),
    total_failed_allocs: AtomicUsize = AtomicUsize.init(0),


    pub fn trackAlloc(state: *State, ptr: ?[*]u8, len: usize) void {
        if (ptr) |p| {
            @branchHint(.likely);
            _ = state.total_alloc_count.fetchAdd(1, .seq_cst);
            _ = state.total_alloc_size.fetchAdd(len, .seq_cst);
            log.info("alloc at {X} of size {d}\n", .{ @intFromPtr(p), len });
        } else {
            @branchHint(.cold);
            _ = state.total_failed_allocs.fetchAdd(1, .seq_cst);
            log.info("alloc failed\n", .{});
        }
    }
    pub fn trackFree(state: *State, ptr: [*]u8, len: usize) void {
        _ = state.total_free_count.fetchAdd(1, .seq_cst);
        _ = state.total_free_size.fetchAdd(len, .seq_cst);
       log.info("free at {X} of size {d}\n", .{ @intFromPtr(ptr), len });
    }
} else struct {};


pub fn allocator(tpa: *TrackingPageAllocator) Allocator {
    return if (is_debug) .{
        .ptr = tpa,
        .vtable = &.{
            .alloc = alloc,
            .resize = page_allocator.vtable.resize,
            .free = free,
        },
    } else comptime page_allocator;
}

pub fn logState(tpa: *TrackingPageAllocator) void {
    log.info("total alloc count: {d}\n", .{ tpa.state.total_alloc_count.load(.monotonic) });
    log.info("total free count: {d}\n", .{ tpa.state.total_free_count.load(.monotonic) });
    log.info("total alloc size: {d}\n", .{ tpa.state.total_alloc_size.load(.monotonic) });
    log.info("total free size: {d}\n", .{ tpa.state.total_free_size.load(.monotonic) });
    log.info("total failed allocs: {d}\n", .{ tpa.state.total_failed_allocs.load(.monotonic) });
}


fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    const tpa: *TrackingPageAllocator = @ptrCast(ctx);
    const aligned_len = mem.alignForward(usize, len, mem.page_size);
    const ptr = page_allocator.rawAlloc(aligned_len, ptr_align, ret_addr);
    tpa.state.trackAlloc(ptr, aligned_len);
    return ptr;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    const tpa: *TrackingPageAllocator = @ptrCast(ctx);
    page_allocator.rawFree(buf, buf_align, ret_addr);
    const aligned_len = mem.alignForward(usize, buf.len, mem.page_size);
    tpa.state.trackFree(buf.ptr, aligned_len);
}
