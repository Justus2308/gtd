const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const Options = struct {
    alignment: ?mem.Alignment = null,
};

/// This is essentially an implementation of Timothy L. Harris's non-blocking
/// linked list. (https://timharris.uk/papers/2001-disc.pdf)
pub fn ConcurrentMemoryPool(comptime T: type, comptime options: Options) type {
    return struct {
        /// Pointers need to be 1-aligned to make bit magic work.
        /// All pointers that the user of this API interacts with
        /// are always aligned to `alignment`.
        free_list: std.atomic.Value(?*align(1) Node) align(alignment),

        const Self = @This();

        const alignment = @max(
            @alignOf(*anyopaque),
            if (options.alignment) |a| a.toByteUnits() else @alignOf(T),
        );
        const alloc_size = @max(@sizeOf(T), @sizeOf(Node));

        const Node = struct {
            next: ?*align(1) Node,
        };
        const NodePtr = packed union {
            raw: usize,
            /// We can use the LSB to store information because all our pointers
            /// are aligned to `node_alignment` which is always >1.
            is_deleted: bool,
            /// is_deleted is part of these bits, so they are guarenteed to
            /// differ between deleted and existing NodePtrs.
            futex_bits: u32,

            pub fn fromPtr(ptr: ?*align(1) Node) NodePtr {
                return .{ .raw = @intFromPtr(ptr) };
            }
            pub fn asPtr(node_ptr: NodePtr) ?*align(1) Node {
                return @ptrFromInt(node_ptr.raw);
            }

            // We need to use bitmasks here because changing the value of is_deleted
            // directly is not guarenteed by the language spec (or in practice) to
            // not clobber all other fields.
            pub fn existing(node_ptr: NodePtr) *align(alignment) Node {
                var ex = node_ptr.raw;
                ex &= ~@as(usize, 1);
                return @ptrFromInt(ex);
            }
            pub fn deleted(node_ptr: NodePtr) *align(1) Node {
                var del = node_ptr.raw;
                del |= @as(usize, 1);
                return @ptrFromInt(del);
            }

            pub fn futexable(node_ptr: *const NodePtr) *const std.atomic.Value(u32) {
                return @ptrCast(&node_ptr.futex_bits);
            }

            pub fn isDeleted(node_ptr: NodePtr) bool {
                return node_ptr.is_deleted;
            }
            pub fn isNull(node_ptr: NodePtr) bool {
                return (node_ptr.raw == 0);
            }

            comptime {
                const deleted_node = NodePtr.fromPtr(null).deleted();
                assert(@intFromPtr(deleted_node) == @as(usize, 1));

                assert(alignment > 1);
                assert(@bitSizeOf(NodePtr) == @bitSizeOf(*anyopaque));
            }
        };

        pub const Pointer = *align(alignment) T;

        pub const empty = Self{
            .free_list = .init(null),
        };

        /// This function is NOT thread-safe.
        pub fn initCapacity(gpa: Allocator, capacity: u32) Allocator.Error!Self {
            var head: ?*align(alignment) Node = null;
            for (0..capacity) |_| {
                const item = try allocItem(gpa);
                const node: *align(alignment) Node = @ptrCast(item);
                node.next = head;
                head = node;
            }
            return Self{
                .free_list = .init(head),
            };
        }

        /// This function is NOT thread-safe.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            while (self.free_list.raw) |node| {
                self.free_list.raw = node.next;
                const item: Pointer = @ptrCast(@alignCast(node));
                freeItem(gpa, item);
                // std.debug.print("freed item: {*}\n", .{item});
            }
            self.* = undefined;
        }

        pub fn create(self: *Self, gpa: Allocator) Allocator.Error!Pointer {
            var head = NodePtr.fromPtr(self.free_list.load(.acquire));
            while (true) {
                if (head.isNull()) {
                    // We don't have any free nodes left, allocate a new one.
                    @branchHint(.unlikely);
                    const item = try allocItem(gpa);
                    // std.debug.print("allocated new item: {*}\n", .{item});
                    return item;
                }
                while (!head.isDeleted()) {
                    // Set the is_deleted bit
                    if (self.free_list.cmpxchgWeak(
                        head.asPtr(),
                        head.deleted(),
                        .release,
                        .monotonic,
                    )) |new_head| {
                        head = NodePtr.fromPtr(new_head);
                    } else {
                        head = NodePtr.fromPtr(head.deleted());
                    }
                }
                // Someone has successfully set the is_deleted bit, we can now
                // remove the node from the list.
                // Note that head cannot be null here because is_deleted is set.
                if (self.free_list.cmpxchgWeak(
                    head.asPtr(),
                    head.existing().next,
                    .release,
                    .acquire,
                )) |new_head| {
                    head = NodePtr.fromPtr(new_head);
                } else {
                    // We have successfully removed head from the list.
                    // std.debug.print("popped head: {*}\n", .{head.existing()});
                    return @ptrCast(head.existing());
                }
            }
        }

        pub fn destroy(self: *Self, ptr: Pointer) void {
            var node: *align(alignment) Node = @ptrCast(ptr);
            var head = NodePtr.fromPtr(self.free_list.load(.acquire));
            while (true) {
                while (head.isDeleted()) {
                    // We are not allowed to push onto a deleted head,
                    // so we wait until the thread removing head from
                    // the list is done.
                    @branchHint(.unlikely);
                    std.Thread.Futex.wait(head.futexable(), head.futex_bits);
                    head = NodePtr.fromPtr(self.free_list.load(.monotonic));
                }
                // We now have a head which is not currently being deleted,
                // even though it might be null.
                node.next = head.asPtr();
                if (self.free_list.cmpxchgWeak(
                    head.asPtr(),
                    node,
                    .release,
                    .acquire,
                )) |new_head| {
                    // head might have is_deleted set now, so we need to try
                    // again from the beginning.
                    head = NodePtr.fromPtr(new_head);
                } else {
                    // std.debug.print("pushed new head: {*}\n", .{node});
                    return;
                }
            }
        }

        inline fn allocItem(gpa: Allocator) Allocator.Error!Pointer {
            const bytes = try gpa.alignedAlloc(u8, alignment, alloc_size);
            return @ptrCast(@alignCast(bytes[0..@sizeOf(T)]));
        }
        inline fn freeItem(gpa: Allocator, item: Pointer) void {
            const bytes = @as([*]align(alignment) u8, @ptrCast(item))[0..alloc_size];
            gpa.free(bytes);
        }
    };
}

test "basic usage" {
    const gpa = testing.allocator;

    var pool = ConcurrentMemoryPool(u32, .{}).empty;
    defer pool.deinit(gpa);

    const p1 = try pool.create(gpa);
    defer pool.destroy(p1);
    const p2 = try pool.create(gpa);
    const p3 = try pool.create(gpa);
    defer pool.destroy(p3);

    try std.testing.expect(p1 != p2);
    try std.testing.expect(p1 != p3);
    try std.testing.expect(p2 != p3);

    pool.destroy(p2);

    const p4 = try pool.create(gpa);
    defer pool.destroy(p4);

    try std.testing.expect(p2 == p4);
}

test "init with capacity" {
    const capacity = 4;
    var limited_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = capacity });
    const limited = limited_allocator.allocator();

    const Pool = ConcurrentMemoryPool(u32, .{});
    var pool = try Pool.initCapacity(limited, capacity);
    defer pool.deinit(limited);

    var created: [capacity]Pool.Pointer = undefined;
    for (0..capacity) |i| {
        created[i] = try pool.create(limited);
    }
    defer for (created) |ptr| {
        pool.destroy(ptr);
    };

    const error_union = pool.create(limited);
    try testing.expectError(Allocator.Error.OutOfMemory, error_union);
}

test "mt fuzz" {
    if (true) {
        return error.SkipZigTest;
    }

    const gpa = testing.allocator;

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = gpa, .n_jobs = 256 });
    defer thread_pool.deinit();

    const Pool = ConcurrentMemoryPool(u32, .{});
    var pool = Pool.empty;
    defer pool.deinit(gpa);

    const Runnable = struct {
        owned: std.atomic.Value(?*align(Pool.alignment) u32) = .init(null),

        pub fn create(self: *@This(), pool_: *Pool) void {
            self.owned.store(pool_.create(gpa) catch null, .release);
        }
        pub fn destroy(self: *@This(), pool_: *Pool) void {
            var owned = self.owned.load(.acquire);
            while (owned == null) : (owned = self.owned.load(.monotonic)) {}
            pool_.destroy(owned.?);
            self.owned.store(null, .release);
        }
    };

    const runnable_count = 1024;

    const runnables = try gpa.alloc(Runnable, runnable_count);
    defer gpa.free(runnables);

    @memset(runnables, .{});

    var wg = std.Thread.WaitGroup{};
    wg.reset();

    for (0..(runnable_count / 2)) |i| {
        thread_pool.spawnWg(&wg, Runnable.create, .{ &runnables[i], &pool });
        thread_pool.spawnWg(&wg, Runnable.create, .{ &runnables[i * 2], &pool });
        thread_pool.spawnWg(&wg, Runnable.destroy, .{ &runnables[i], &pool });
    }

    thread_pool.waitAndWork(&wg);
    wg.wait();

    @breakpoint();

    for (0..(runnable_count / 2)) |i| {
        try testing.expect(runnables[i].owned.raw == null);
    }
    @breakpoint();
    for ((runnable_count / 2)..runnable_count) |i| {
        try testing.expect(runnables[i].owned.raw != null);
        Pool.freeItem(gpa, runnables[i].owned.raw.?);
    }

    @breakpoint();

    var counter: usize = 0;
    var curr = pool.free_list.raw;
    while (curr) |node| : (curr = node.next) {
        counter += 1;
    }
    try testing.expect(counter == (runnable_count / 2));
}
