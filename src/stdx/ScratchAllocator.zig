//! This type is a singleton; it uses global state and only one should be
//! instantiated for the entire process.
//!
//! Inspired by `std.heap.SmpAllocator`.

backing_allocator: Allocator,
bumpables: []Bumpable,
is_initialized: std.atomic.Value(bool),

const ScratchAllocator = @This();

var global = uninitialized;
threadlocal var bumpable_index: u32 = 0;

const uninitialized = ScratchAllocator{
    .backing_allocator = undefined,
    .bumpables = undefined,
    .is_initialized = .init(false),
};

const max_thread_count = 128;

pub const vtable = Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = Allocator.noRemap,
    .free = free,
};

const Bumpable = struct {
    _: void align(std.atomic.cache_line) = {},
    bytes: std.heap.FixedBufferAllocator,
    mutex: std.Thread.Mutex,

    pub const init = Bumpable{
        .bytes = .init(&.{}),
        .mutex = .{},
    };

    pub fn initCapacity(capacity_in_bytes: usize) Allocator.Error!Bumpable {
        const buffer = try global.backing_allocator.alloc(u8, capacity_in_bytes);
        return .{
            .bytes = .init(buffer),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Bumpable) void {
        global.backing_allocator.free(self.bytes.buffer);
        self.* = undefined;
    }

    pub fn lock() *Bumpable {
        var index = bumpable_index;
        {
            const bumpable = &global.bumpables[index];
            if (bumpable.mutex.tryLock()) {
                @branchHint(.likely);
                return bumpable;
            }
        }
        const cpu_count: u32 = @intCast(global.bumpables.len);
        while (true) {
            index = ((index + 1) % cpu_count);
            const bumpable = &global.bumpables[index];
            if (bumpable.mutex.tryLock()) {
                bumpable_index = index;
                return bumpable;
            }
        }
    }

    pub fn unlock(self: *Bumpable) void {
        self.mutex.unlock();
    }

    pub fn reset(self: *Bumpable) void {
        self.bytes.reset();
    }

    fn growCapacity(current: usize, minimum: usize) usize {
        var new = current;
        while (new < minimum) {
            new +|= ((new / 2) + std.atomic.cache_line);
        }
        return new;
    }
};

/// `backing_allocator` has to be thread safe.
pub fn init(backing_allocator: Allocator) Allocator.Error!void {
    try ScratchAllocator.innerInit(backing_allocator);
    global.is_initialized.store(true, .release);
}

pub const InitCapacity = union(enum) {
    total: usize,
    per_thread: usize,
};

/// `backing_allocator` has to be thread safe.
pub fn initCapacity(backing_allocator: Allocator, capacity_in_bytes: InitCapacity) Allocator.Error!void {
    try ScratchAllocator.innerInit(backing_allocator);
    errdefer ScratchAllocator.deinit();

    const capacity_per_thread = switch (capacity_in_bytes) {
        .total => |total| (total / global.bumpables.len),
        .per_thread => |per_thread| per_thread,
    };
    for (global.bumpables) |*bumpable| {
        bumpable.* = .initCapacity(capacity_per_thread);
    }
    global.is_initialized.store(true, .release);
}

fn innerInit(backing_allocator: Allocator) Allocator.Error!void {
    const thread_count = std.Thread.getCpuCount() catch max_thread_count;
    global.backing_allocator = backing_allocator;
    global.bumpables = try global.backing_allocator.alloc(Bumpable, thread_count);
    @memset(global.bumpables, .init);
}

pub fn deinit() void {
    assertInitialized();
    for (global.bumpables) |*bumpable| {
        bumpable.deinit();
    }
    global = uninitialized;
}

/// Resets all `Bumpable`s.
pub fn reset() void {
    for (global.bumpables) |*bumpable| {
        bumpable.mutex.lock();
        defer bumpable.mutex.unlock();

        bumpable.reset();
    }
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    assertInitialized();
    _ = ctx;
    const self = Bumpable.lock();
    defer self.unlock();

    const ptr = std.heap.FixedBufferAllocator.alloc(&self.bytes, len, alignment, ret_addr) orelse ptr: {
        const required_capacity = (self.bytes.end_index + alignment.forward(len));
        const new_capacity = Bumpable.growCapacity(self.bytes.buffer.len, required_capacity);
        self.bytes.buffer = global.backing_allocator.reallocAdvanced(
            self.bytes.buffer,
            new_capacity,
            ret_addr,
        ) catch return null;
        break :ptr std.heap.FixedBufferAllocator.alloc(&self.bytes, len, alignment, ret_addr).?;
    };
    return ptr;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    assertInitialized();
    _ = ctx;
    const self = Bumpable.lock();
    defer self.unlock();

    if (std.heap.FixedBufferAllocator.resize(&self.bytes, memory, alignment, new_len, ret_addr)) {
        return true;
    } else {
        assert(new_len > memory.len);
        if (self.bytes.isLastAllocation(memory)) {
            const required_capacity = (self.bytes.end_index + (new_len - memory.len));
            const new_capacity = Bumpable.growCapacity(self.bytes.buffer.len, required_capacity);
            if (global.backing_allocator.rawResize(self.bytes.buffer, alignment, new_capacity, ret_addr)) {
                self.bytes.buffer.len = new_capacity;
                return std.heap.FixedBufferAllocator.resize(&self.bytes, memory, alignment, new_len, ret_addr);
            }
        }
        return false;
    }
    unreachable;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    assertInitialized();
    _ = ctx;
    const self = Bumpable.lock();
    defer self.unlock();

    return std.heap.FixedBufferAllocator.free(&self.bytes, memory, alignment, ret_addr);
}

inline fn assertInitialized() void {
    assert(global.is_initialized.load(.acquire));
}

const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
