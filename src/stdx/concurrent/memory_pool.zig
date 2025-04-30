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
pub fn MemoryPool(comptime T: type, comptime options: Options) type {
    return struct {
        free_list: std.atomic.Value(Pointer) align(alignment),

        const Self = @This();

        const alignment = @max(
            @alignOf(*anyopaque),
            if (options.alignment) |a| a.toByteUnits() else @alignOf(T),
        );
        const alloc_size = @max(@sizeOf(T), @sizeOf(Node));

        const Node = struct {
            next: Pointer,
        };

        /// Uses the LSB to store information.
        const Pointer = packed struct(usize) {
            is_deleted: bool,
            _: std.meta.Int(.unsigned, (@bitSizeOf(usize) - 1)),

            pub const nullptr: Pointer = @bitCast(@intFromPtr(@as(?*anyopaque, null)));

            pub fn init(ptr: anytype) Pointer {
                return @bitCast(@intFromPtr(ptr));
            }

            pub fn asNode(pointer: Pointer) *align(alignment) Node {
                return @ptrFromInt(pointer.asAddr());
            }
            pub fn asItem(pointer: Pointer) Item {
                assert(!pointer.isNull());
                return @ptrFromInt(pointer.asAddr());
            }
            pub fn asAddr(pointer: Pointer) usize {
                return @bitCast(pointer);
            }

            pub fn existing(pointer: Pointer) Pointer {
                var ex = pointer;
                ex.is_deleted = false;
                return ex;
            }
            pub fn deleted(pointer: Pointer) Pointer {
                var del = pointer;
                del.is_deleted = true;
                return del;
            }

            pub fn futexable(pointer: *const Pointer) *const std.atomic.Value(u32) {
                return @ptrCast(@as(*const u32, @ptrCast(@alignCast(pointer))));
            }
            pub fn futexBits(pointer: Pointer) u32 {
                return @truncate(pointer.asAddr());
            }

            pub fn isDeleted(pointer: Pointer) bool {
                return pointer.is_deleted;
            }
            pub fn isNull(pointer: Pointer) bool {
                return (pointer == nullptr);
            }
        };

        pub const Item = *align(alignment) T;

        pub const empty = Self{
            .free_list = .init(.nullptr),
        };

        /// This function is NOT thread-safe.
        pub fn initCapacity(gpa: Allocator, capacity: u32) Allocator.Error!Self {
            var head: ?*align(alignment) Node = null;
            for (0..capacity) |_| {
                const item = try allocItem(gpa);
                const node: *align(alignment) Node = @ptrCast(item);
                node.next = .init(head);
                head = node;
            }
            return Self{
                .free_list = .init(.init(head)),
            };
        }

        /// This function is NOT thread-safe.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            while (self.free_list.raw.isNull() == false) {
                const node = self.free_list.raw.asNode();
                self.free_list.raw = node.next;
                const item: Item = @ptrCast(@alignCast(node));
                freeItem(gpa, item);
                // std.debug.print("freed item: {*}\n", .{item});
            }
            self.* = undefined;
        }

        pub fn create(self: *Self, gpa: Allocator) Allocator.Error!Item {
            var head = self.free_list.load(.acquire);
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
                        head,
                        head.deleted(),
                        .release,
                        .monotonic,
                    )) |new_head| {
                        head = new_head;
                    } else {
                        // Reload head to ensure that head.next is valid
                        head = self.free_list.load(.acquire);
                    }
                }
                // Someone has successfully set the is_deleted bit, we can now
                // remove the node from the list.
                // Note that head cannot be null here because is_deleted is set.
                const head_next = head.existing().asNode().next;
                if (self.free_list.cmpxchgWeak(
                    head,
                    head_next,
                    .release,
                    .acquire,
                )) |new_head| {
                    head = new_head;
                } else {
                    // We have successfully removed head from the list.
                    // std.debug.print("popped head: {*}\n", .{head.existing()});
                    return head.existing().asItem();
                }
            }
        }

        pub fn destroy(self: *Self, item: Item) void {
            var node: *align(alignment) Node = @ptrCast(item);
            var head = self.free_list.load(.acquire);
            while (true) {
                while (head.isDeleted()) {
                    // We are not allowed to push onto a deleted head,
                    // so we try to help in removing the current head
                    // from the free list.
                    @branchHint(.unlikely);
                    const head_next = head.existing().asNode().next;
                    if (self.free_list.cmpxchgWeak(head, head_next, .release, .monotonic)) |new_head| {
                        head = new_head;
                    } else {
                        head = self.free_list.load(.acquire);
                    }
                }
                // We now have a head which is not currently being deleted,
                // even though it might be null.
                node.next = head;
                if (self.free_list.cmpxchgWeak(
                    head,
                    .init(node),
                    .release,
                    .acquire,
                )) |new_head| {
                    // head might have is_deleted set now, so we need to try
                    // again from the beginning.
                    head = new_head;
                } else {
                    // std.debug.print("pushed new head: {*}\n", .{node});
                    return;
                }
            }
        }

        fn allocItem(gpa: Allocator) Allocator.Error!Item {
            const bytes = try gpa.alignedAlloc(u8, .fromByteUnits(alignment), alloc_size);
            return @ptrCast(@alignCast(bytes[0..@sizeOf(T)]));
        }
        fn freeItem(gpa: Allocator, item: Item) void {
            const bytes = @as([*]align(alignment) u8, @ptrCast(item))[0..alloc_size];
            gpa.free(bytes);
        }
    };
}

test "basic usage" {
    const gpa = testing.allocator;

    var pool = MemoryPool(u32, .{}).empty;
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

    const Pool = MemoryPool(u32, .{});
    var pool = try Pool.initCapacity(limited, capacity);
    defer pool.deinit(limited);

    var created: [capacity]Pool.Item = undefined;
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

    const Pool = MemoryPool(u32, .{});
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
