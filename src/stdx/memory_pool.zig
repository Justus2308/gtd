//! Based on `std.heap.MemoryPool` / https://zig.news/xq/cool-zig-patterns-gotta-alloc-fast-23h
const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;


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

        pub const Item = T;
        pub const item_alignment = alignment orelse @alignOf(Item);
        const ItemPtr = *align(item_alignment) Item;

        const BitSet = std.bit_set.DynamicBitSetUnmanaged;
        const NodeList = std.SinglyLinkedList(ItemPtr);

        const node_alignment = @max(@alignOf(*anyopaque), item_alignment);
        const Node = struct {
            item: Item align(item_alignment),
            next: ?*align(node_alignment) Node,

            pub inline fn create(allocator: Allocator) Allocator.Error!NodePtr {
                const raw_mem = try allocator.alignedAlloc(u8, node_alignment, @sizeOf(Node));
                return @ptrCast(raw_mem);
            }
        };
        const NodePtr = *align(node_alignment) Node;


        /// Creates a new memory pool.
        pub fn init(allocator: Allocator) Pool {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .fixed_mem = undefined,
                .free_map = .{},
            };
        }

        /// Creates a new memory pool and pre-allocates `initial_size` items
        /// in consecutive memory.
        /// This allows the up to `initial_size` active allocations before a
        /// `OutOfMemory` error happens when calling `create()`.
        /// All further allocations will be stored in linked lists and therefore
        /// slower, use `compact()` to fix this.
        pub fn initPreheated(allocator: Allocator, initial_size: usize) Allocator.Error!Pool {
            var pool = Pool.init(allocator);
            errdefer pool.deinit();

            try pool.free_map.resize(allocator, initial_size, true);
            pool.fixed_mem = try allocator.alignedAlloc(u8, item_alignment, initial_size * @sizeOf(Item));

            return pool;
        }

        /// Destroys the memory pool and frees all allocated memory.
        pub fn deinit(pool: *Pool) void {
            if (pool.free_map.capacity() > 0) {
                const allocator = pool.arena.child_allocator;
                allocator.free(pool.fixed_mem);
                pool.free_map.deinit(allocator);
            }
            pool.arena.deinit();
            pool.* = undefined;
        }


        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

        /// Resets the memory pool and destroys all allocated items.
        /// This can be used to batch-destroy all objects without invalidating the memory pool.
        ///
        /// The function will return whether the reset operation was successful or not.
        /// If the reallocation  failed `false` is returned. The pool will still be fully
        /// functional in that case, all memory is released. Future allocations just might
        /// be slower.
        ///
        /// NOTE: If `mode` is `free_all`, the function will always return `true`.
        pub fn reset(pool: *Pool, mode: ResetMode) bool {
            const real_mode: ResetMode = switch (mode) {
                .retain_with_limit => |limit| blk: {
                    const real_limit = limit -| pool.fixed_mem.len;
                    break :blk if (limit == 0)
                        .{ .free_all = {} }
                    else
                        .{ .retain_with_limit = real_limit };
                },
                else => mode,
            };
            const reset_successful = pool.arena.reset(real_mode);

            pool.ext_free_list = .{};
            pool.ext_node_list = .{};

            return reset_successful;
        }

        /// Creates a new item and adds it to the memory pool.
        pub fn create(pool: *Pool) Allocator.Error!ItemPtr {
            const next_free = pool.free_map.toggleFirstSet() orelse if (pool.ext_free_list) |node| {
                pool.ext_free_list = node.next;

                node.next = pool.ext_node_list;
                pool.ext_node_list = node;

                const ptr = &node.item;
                ptr.* = undefined;
                return ptr;
            } else {
                const node = try Node.create(pool.arena.allocator());
                node.next = pool.ext_node_list;
                pool.ext_node_list = node;
                return &node.item;
            };
            const ptr: ItemPtr = @ptrCast(@alignCast(pool.fixed_mem[next_free*@sizeOf(Item)..][0..@sizeOf(Item)]));
            ptr.* = undefined;
            return ptr;
        }

        /// Destroys a previously created item.
        /// Only pass items to `ptr` that were previously created with `create()` of the same memory pool!
        pub fn destroy(pool: *Pool, ptr: ItemPtr) void {
            ptr.* = undefined;

            if (pool.fixed_mem.len > 0) {
                @branchHint(.likely);
                const addr = @intFromPtr(ptr);
                const start_addr = @intFromPtr(&pool.fixed_mem[0]);
                const end_addr = @intFromPtr(&pool.fixed_mem[pool.fixed_mem.len-1]);
                if (addr >= start_addr and addr <= end_addr) {
                    @branchHint(.likely);
                    // ptr is in fixed mem
                    const offset = addr - start_addr;
                    const index = @divExact(offset, @sizeOf(Item));
                    assert(!pool.free_map.isSet(index));
                    pool.free_map.set(index);
                    return;
                }
            }
            // ptr is in extended mem
            const node: NodePtr = @alignCast(@fieldParentPtr("item", ptr));
            if (pool.ext_node_list == node) {
                pool.ext_node_list = node.next;
            } else {
                var current_elm = pool.ext_node_list.?;
                while (current_elm.next != node) {
                    current_elm = current_elm.next.?;
                }
                current_elm.next = node.next;
            }
            node.next = pool.ext_free_list;
            pool.ext_free_list = node;
        }

        pub fn compact(pool: *Pool) bool {
            while (pool.free_map.findFirstSet()) |next_free| {
                if (pool.ext_node_list) |node| {
                    pool.ext_node_list = node.next;

                    const dest: ItemPtr = pool.fixed_mem[next_free*@sizeOf(Item)..][0..@sizeOf(Item)];
                    dest.* = node.item;

                    node.next = pool.ext_free_list;
                    pool.ext_free_list = node;
                } else return true;
            }
            return false;
        }
    };
}


test "basic" {
    var pool = MemoryPool(u32).init(std.testing.allocator);
    defer pool.deinit();

    const p1 = try pool.create();
    const p2 = try pool.create();
    const p3 = try pool.create();

    // Assert uniqueness
    try std.testing.expect(p1 != p2);
    try std.testing.expect(p1 != p3);
    try std.testing.expect(p2 != p3);

    pool.destroy(p2);
    const p4 = try pool.create();

    // Assert memory reuse
    try std.testing.expect(p2 == p4);
}

test "preheating (success)" {
    var pool = try MemoryPool(u32).initPreheated(std.testing.allocator, 4);
    defer pool.deinit();

    _ = try pool.create();
    _ = try pool.create();
    _ = try pool.create();
}

test "preheating (failure)" {
    const failer = std.testing.failing_allocator;
    try std.testing.expectError(Allocator.Error.OutOfMemory, MemoryPool(u32).initPreheated(failer, 5));
}

test "greater than pointer default alignment" {
    const Foo = struct {
        item: u64 align(16),
    };

    var pool = MemoryPool(Foo).init(std.testing.allocator);
    defer pool.deinit();

    const foo: *Foo = try pool.create();
    _ = foo;
}

test "greater than pointer manual alignment" {
    const Foo = struct {
        item: u64,
    };

    var pool = MemoryPoolAligned(Foo, 16).init(std.testing.allocator);
    defer pool.deinit();

    const foo: *align(16) Foo = try pool.create();
    _ = foo;
}

test "compaction" {
    var pool = MemoryPool(u64).initPreheated(std.testing.allocator, 4);
    defer pool.deinit();

    const p1 = try pool.create();
    _ = try pool.create();
    const p3 = try pool.create();
    _ = try pool.create();
    _ = try pool.create();
    _ = try pool.create();

    pool.destroy(p1);
    pool.destroy(p3);

    const ok = pool.compact();
    try std.testing.expect(ok);
}

test "fail" {
    try std.testing.expect(false);
}
