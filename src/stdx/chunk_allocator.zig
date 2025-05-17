const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Config = struct {
    /// Needs to be power of two.
    chunk_size: usize = (1 << 10),
    /// Needs to be power of two and `>= chunk_size`.
    /// Ideally `allocation_granularity > chunk_size`.
    /// If `allocation_granularity == chunk_size` this allocator degrades to a
    /// worse `std.heap.page_allocator`.
    allocation_granularity: usize = std.heap.page_size_max,
    /// If `true`, the allocator can allocate additional chunks after a initial setup.
    /// If `false`, the allocator will not allocate further after a call to `initPreheated`.
    growable: bool = true,
    /// If `true`, the allocator will free unused allocations.
    /// If `false`, the allocator will never free anything.
    shrinkable: bool = true,
    /// Uses a `std.Thread.Mutex` to ensure thread safety of `create()` and `free()`.
    thread_safe: bool = !builtin.single_threaded,
    /// It is recommended to use `std.heap.page_allocator` since it
    /// prevents any fragmentation from happening.
    /// Used mainly for testing purposes.
    backing_allocator: Allocator = std.heap.page_allocator,
};

/// Allocates power-of-two-sized chunks of memory, backed by OS pages.
/// Like a buddy allocator, but with fixed-size allocations and without
/// the fragmentation.
/// In contrast to `std.heap.MemoryPool`, this allocator keeps track of
/// all active allocations individually and frees them once they are no
/// longer in use.
/// Uses a two-level bitset to quickly find free chunks and a hash map
/// to store active allocations.
pub fn ChunkAllocator(comptime config: Config) type {
    if (std.math.isPowerOfTwo(config.chunk_size) == false) {
        @compileError("chunk_size needs to be power of two");
    }
    if (std.math.isPowerOfTwo(config.allocation_granularity) == false) {
        @compileError("allocation_granularity needs to be power of two");
    }
    if (config.chunk_size > config.allocation_granularity) {
        @compileError("allocation_granularity must be at least chunk_size");
    }
    return struct {
        gpa: Allocator,
        allocations: std.AutoArrayHashMapUnmanaged(usize, FreeSet),
        avail_set: std.DynamicBitSetUnmanaged,
        mutex: Mutex,

        const Self = @This();

        pub const chunk_size = config.chunk_size;
        const chunk_size_shift = std.math.log2(chunk_size);
        const alloc_size = @max(chunk_size, std.heap.page_size_max, config.allocation_granularity);
        const alloc_align = std.mem.Alignment.fromByteUnits(alloc_size);
        const chunks_per_alloc = @divExact(alloc_size, chunk_size);

        pub const is_growable = config.growable;
        pub const is_shrinkable = config.shrinkable;
        pub const is_thread_safe = config.thread_safe;

        const FreeSet = std.StaticBitSet(chunks_per_alloc);

        const Mutex = if (config.thread_safe) std.Thread.Mutex else struct {
            pub fn tryLock(_: *@This()) void {}
            pub fn lock(_: *@This()) void {}
            pub fn unlock(_: *@This()) void {}
        };

        pub fn init(metadata_gpa: Allocator) Self {
            return Self{
                .gpa = metadata_gpa,
                .allocations = .empty,
                .avail_set = .{},
                .mutex = .{},
            };
        }

        pub fn initPreheated(metadata_gpa: Allocator, preheat_chunk_count: usize) Allocator.Error!Self {
            var self = Self.init(metadata_gpa);
            errdefer self.deinit();

            if (preheat_chunk_count > 0) {
                const alloc_count = std.math.divCeil(usize, preheat_chunk_count, chunks_per_alloc) catch unreachable;
                try self.avail_set.resize(self.gpa, alloc_count, true);
                try self.allocations.ensureTotalCapacity(self.gpa, alloc_count);
                for (0..alloc_count) |_| {
                    const alloc_addr = try createAllocation();
                    self.allocations.putAssumeCapacityNoClobber(alloc_addr, .initFull());
                }
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.reset(.free_all);
            self.* = undefined;
        }

        pub const ResetMode = union(enum) {
            /// Releases all allocations.
            free_all,
            /// This will retain all currently allocated chunks, but mark them as free.
            retain_chunks,
            /// This is the same as `retain_chunks`, but the chunk count will
            /// be reduced to this value if it exceeds the limit.
            retain_with_limit: usize,
        };
        /// Resets the allocator and invalidates all chunks.
        /// `mode` defines how the currently allocated memory is handled.
        /// See the variant documentation for `ResetMode` for the effects of each mode.
        pub fn reset(self: *Self, mode: ResetMode) void {
            switch (mode) {
                .free_all => {
                    const alloc_addrs = self.allocations.keys();
                    for (alloc_addrs) |alloc_addr| {
                        destroyAllocation(alloc_addr);
                    }
                    self.allocations.clearAndFree(self.gpa);
                    self.avail_set.resize(self.gpa, 0, false) catch unreachable;
                },
                .retain_chunks => {
                    self.allocations.clearRetainingCapacity();
                    self.avail_set.setAll();
                },
                .retain_with_limit => |limit| {
                    const alloc_addrs = self.allocations.keys();
                    if (limit > alloc_addrs.len) {
                        for (alloc_addrs[limit..alloc_addrs.len]) |alloc_addr| {
                            destroyAllocation(alloc_addr);
                        }
                    }
                    self.allocations.shrinkAndFree(self.gpa, limit);
                    self.avail_set.resize(self.gpa, self.allocations.capacity(), false) catch unreachable;
                    self.avail_set.setAll();
                },
            }
        }

        pub fn create(self: *Self) Allocator.Error![]align(chunk_size) u8 {
            self.mutex.lock();
            defer self.mutex.unlock();

            const first_avail_idx = self.avail_set.findFirstSet() orelse new: {
                if (is_growable == false) {
                    return Allocator.Error.OutOfMemory;
                }
                try self.ensureTotalMetadataCapacity(self.allocationCount() + 1);
                const alloc_addr = try createAllocation();
                const gop = self.allocations.getOrPutAssumeCapacity(alloc_addr);
                assert(gop.found_existing == false);
                gop.value_ptr.* = .initFull();
                self.avail_set.set(gop.index);
                break :new gop.index;
            };
            const slice = self.allocations.entries.slice();
            const free_set = &slice.items(.value)[first_avail_idx];
            const chunk_index = free_set.toggleFirstSet().?;
            if (free_set.count() == 0) {
                self.avail_set.unset(first_avail_idx);
            }
            const alloc_addr = slice.items(.key)[first_avail_idx];
            const chunk_addr = (alloc_addr + (chunk_index << chunk_size_shift));
            const chunk = @as([*]align(chunk_size) u8, @ptrFromInt(chunk_addr))[0..chunk_size];
            return chunk;
        }

        pub fn destroy(self: *Self, chunk: []align(chunk_size) u8) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const chunk_addr = @intFromPtr(chunk.ptr);
            const alloc_addr = alloc_align.backward(chunk_addr);
            const chunk_index = ((chunk_addr - alloc_addr) >> chunk_size_shift);
            assert(chunk_index < chunks_per_alloc);

            const gop = self.allocations.getOrPutAssumeCapacity(alloc_addr);
            assert(gop.found_existing == true);

            const free_set = gop.value_ptr;
            assert(free_set.isSet(chunk_index) == false);
            free_set.set(chunk_index);

            const avail_idx = gop.index;
            if (is_shrinkable == true and free_set.count() == chunks_per_alloc) {
                self.allocations.swapRemoveAt(avail_idx);
                const swapped_idx = self.allocations.count();
                const swapped_avail = self.avail_set.isSet(swapped_idx);
                self.avail_set.setValue(avail_idx, swapped_avail);
                self.avail_set.unset(swapped_idx);
                destroyAllocation(alloc_addr);
            } else {
                self.avail_set.set(avail_idx);
            }
        }

        pub fn allocationCount(self: Self) usize {
            return self.allocations.count();
        }

        pub fn metadataCapacity(self: Self) usize {
            return @min(self.allocations.capacity(), self.avail_set.capacity());
        }
        pub fn ensureTotalMetadataCapacity(self: *Self, new_capacity: usize) Allocator.Error!void {
            try self.allocations.ensureTotalCapacity(self.gpa, new_capacity);
            try self.avail_set.resize(self.gpa, self.allocations.capacity(), false);
        }
        pub fn ensureUnusedMetadataCapacity(self: *Self, additional_capacity: usize) Allocator.Error!void {
            try self.allocations.ensureUnusedCapacity(self.gpa, additional_capacity);
            try self.avail_set.resize(self.gpa, self.allocations.capacity(), false);
        }

        fn createAllocation() Allocator.Error!usize {
            const raw = config.backing_allocator.rawAlloc(alloc_size, alloc_align, @returnAddress()) orelse return Allocator.Error.OutOfMemory;
            return @intFromPtr(raw);
        }
        fn destroyAllocation(alloc_addr: usize) void {
            const raw = @as([*]u8, @ptrFromInt(alloc_addr))[0..alloc_size];
            config.backing_allocator.rawFree(raw, alloc_align, @returnAddress());
        }
    };
}

// TESTS

test "basic usage" {
    // Ensure multiple chunks per allocation
    const TestChunkAllocator = ChunkAllocator(.{
        .chunk_size = (1 << 4),
        .allocation_granularity = (1 << 10),
        .backing_allocator = testing.allocator,
    });
    var a = TestChunkAllocator.init(testing.allocator);
    defer a.deinit();

    const p1 = try a.create();
    const p2 = try a.create();
    const p3 = try a.create();

    // Assert uniqueness
    try std.testing.expect(p1.ptr != p2.ptr);
    try std.testing.expect(p1.ptr != p3.ptr);
    try std.testing.expect(p2.ptr != p3.ptr);

    a.destroy(p2);
    const p4 = try a.create();

    // Assert memory reuse
    try std.testing.expectEqual(p2, p4);
}

test "intended usage" {
    const gpa = std.heap.smp_allocator;
    var a = ChunkAllocator(.{}).init(gpa);
    defer a.deinit();

    const p1 = try a.create();
    const p2 = try a.create();
    const p3 = try a.create();

    try std.testing.expect(p1.ptr != p2.ptr);
    try std.testing.expect(p1.ptr != p3.ptr);
    try std.testing.expect(p2.ptr != p3.ptr);

    try testing.expect(a.allocationCount() >= 1);

    a.destroy(p1);
    a.destroy(p2);
    a.destroy(p3);

    try testing.expectEqual(0, a.allocationCount());
}

test "preheating" {
    const static = struct {
        const test_fail_index = 4;
        var test_failer = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = test_fail_index });
    };
    // Ensure one chunk per allocation
    const FailingChunkAllocator = ChunkAllocator(.{
        .chunk_size = std.heap.page_size_max,
        .allocation_granularity = std.heap.page_size_max,
        .backing_allocator = static.test_failer.allocator(),
    });
    var a = try FailingChunkAllocator.initPreheated(std.testing.allocator, static.test_fail_index);
    defer a.deinit();

    try testing.expect(a.metadataCapacity() >= static.test_fail_index);

    for (0..static.test_fail_index) |_| {
        _ = try a.create();
    }
    const oom = a.create();
    try testing.expectError(Allocator.Error.OutOfMemory, oom);
}

test "not growable" {
    // Ensure one chunk per allocation
    const NoGrowChunkAllocator = ChunkAllocator(.{
        .chunk_size = std.heap.page_size_max,
        .allocation_granularity = std.heap.page_size_max,
        .growable = false,
        .backing_allocator = testing.allocator,
    });
    const preheat_count = 4;
    var a = try NoGrowChunkAllocator.initPreheated(testing.allocator, preheat_count);
    defer a.deinit();

    for (0..preheat_count) |_| {
        _ = try a.create();
    }
    const oom = a.create();
    try std.testing.expectError(Allocator.Error.OutOfMemory, oom);
}

test "not shrinkable" {
    // Ensure one chunk per allocation
    const NoShrinkChunkAllocator = ChunkAllocator(.{
        .chunk_size = std.heap.page_size_max,
        .allocation_granularity = std.heap.page_size_max,
        .shrinkable = false,
        .backing_allocator = testing.allocator,
    });
    const alloc_count = 4;
    var a = NoShrinkChunkAllocator.init(testing.allocator);
    defer a.deinit();

    var chunks: [alloc_count][]u8 = undefined;
    for (&chunks) |*chunk| {
        chunk.* = try a.create();
    }
    for (chunks) |chunk| {
        a.destroy(@alignCast(chunk));
    }
    try testing.expectEqual(alloc_count, a.allocationCount());
}
