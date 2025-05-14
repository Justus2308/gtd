//! Allocation-free data structure that acts as a fixed-size memory pool
//! for `Subpath`s and `Node`s.
//! The base data structure does not contain any pointers.
//! `Subpath`s can be individually discretized to 2D coordinates.

subpaths: [max_subpath_count]Subpath,
subpath_avail_set: Subpath.BitSet,
node_storage: Node.Storage,
unused_nodes: Node.List,
unused_node_count: usize,

const PathBuilder = @This();

pub const max_subpath_count = 8;
pub const max_node_count = 64;

pub const init = PathBuilder{
    .subpaths = undefined,
    .subpath_avail_set = .initFull(),
    .node_storage = .empty,
    .unused_nodes = .empty,
    .unused_node_count = max_node_count,
};

pub fn reset(pb: *PathBuilder) void {
    pb.* = .init;
}

/// Returns a pointer to a new `Subpath` or `null` if there are no
/// subpaths available.
pub fn acquireSubpath(pb: *PathBuilder) ?*Subpath {
    const index = pb.subpath_avail_set.toggleFirstSet() orelse return null;
    const subpath = &pb.subpaths[index];
    subpath.* = .empty;
    return subpath;
}

/// Invalidates `subpath`. Accessing `subpath` after calling this
/// function causes undefined behavior.
/// Releases all `Node`s in `subpath`.
pub fn releaseSubpath(pb: *PathBuilder, subpath: *Subpath) void {
    assert(stdx.containsPointer(Subpath, &pb.subpaths, subpath));
    subpath.clear(pb);
    subpath.* = undefined;
    const offset = (@intFromPtr(subpath) - @intFromPtr(&pb.subpaths));
    const index = @divExact(offset, @sizeOf(Subpath));
    assert(pb.subpath_avail_set.isSet(index) == false);
    pb.subpath_avail_set.set(index);
}

/// Returns a pointer to a new `Node` or `null` if there are no
/// nodes available.
fn acquireNode(pb: *PathBuilder) ?*Node {
    if (pb.unused_node_count == 0) {
        return null;
    } else {
        assert(pb.unused_node_count <= max_node_count);
        pb.unused_node_count -= 1;
    }
    return pb.unused_nodes.pop(&pb.node_storage) orelse
        pb.node_storage.inner.addOneAssumeCapacity();
}

/// Invalidates `node`. Accessing `node` after calling this
/// function causes undefined behavior.
fn releaseNode(pb: *PathBuilder, node: *Node) void {
    node.* = undefined;
    if (&pb.node_storage.inner.buffer[pb.node_storage.inner.len - 1] == node) {
        _ = pb.node_storage.inner.pop().?;
    } else {
        assert(stdx.containsPointer(Node, pb.node_storage.inner.constSlice(), node));
        pb.unused_nodes.append(&pb.node_storage, node);
    }
    pb.unused_node_count += 1;
    assert(pb.unused_node_count <= max_node_count);
}

pub fn usedSubpathCount(pb: PathBuilder) usize {
    return (max_subpath_count - pb.unusedSubpathCount());
}
pub fn unusedSubpathCount(pb: PathBuilder) usize {
    return pb.subpath_avail_set.count();
}

pub fn usedNodeCount(pb: PathBuilder) usize {
    return (max_node_count - pb.unusedNodeCount());
}
pub fn unusedNodeCount(pb: PathBuilder) usize {
    assert(pb.unused_node_count <= max_node_count);
    return pb.unused_node_count;
}

pub const Iterator = struct {
    subpaths: *[max_subpath_count]Subpath,
    active_set: Subpath.BitSet,

    pub fn next(it: *Iterator) ?*Subpath {
        const index = it.active_set.toggleFirstSet() orelse return null;
        return &it.subpaths[index];
    }

    pub fn peek(it: *Iterator) ?*Subpath {
        const index = it.active_set.findFirstSet() orelse return null;
        return &it.subpaths[index];
    }
};

/// Iterate over all `Subpath`s that are active at
/// the time this function is called.
pub fn iterator(pb: *PathBuilder) Iterator {
    return Iterator{
        .subpaths = &pb.subpaths,
        .active_set = pb.subpath_avail_set.complement(),
    };
}

/// Modifying `next` or `prev` manually causes undefined behavior,
/// use `get()`/`set()` and the `Subpath` API to interact with `Node`s.
pub const Node = struct {
    x: f32,
    y: f32,
    tension: stdx.BoundedValue(f32, 0, 1),
    next: Index,
    prev: Index,

    pub inline fn get(node: Node) Node {
        var copy = node;
        copy.next = undefined;
        copy.prev = undefined;
        return copy;
    }
    pub inline fn set(node: *Node, x: ?f32, y: ?f32, tension: ?f32) void {
        if (x) |x_val| node.x = x_val;
        if (y) |y_val| node.y = y_val;
        if (tension) |tension_val| node.tension.set(tension_val);
    }

    pub const Index = enum(u16) {
        none = math.maxInt(u16),
        _,

        pub inline fn from(val: u16) Node.Index {
            const index: Node.Index = @enumFromInt(val);
            assert(index != .none);
            return index;
        }
        pub inline fn asInt(index: Node.Index) u16 {
            assert(index != .none);
            return @intFromEnum(index);
        }
    };

    pub const Storage = struct {
        inner: std.BoundedArray(Node, max_node_count),

        pub const empty = Storage{ .inner = .{} };

        pub fn getNode(storage: *Storage, index: Index) ?*Node {
            if (index == .none) {
                return null;
            }
            assert(index.asInt() < storage.inner.len);
            return &storage.inner.slice()[index.asInt()];
        }
        /// This compiles to a subtraction and a bitshift
        /// (as long as `@sizeOf(Node)` is a power of two).
        pub fn getIndex(storage: *const Node.Storage, node: *const Node) Node.Index {
            assert(stdx.containsPointer(Node, storage.inner.constSlice(), node));
            const offset = (@intFromPtr(node) - @intFromPtr(&storage.inner.buffer));
            return @enumFromInt(@as(u16, @intCast(@divExact(offset, @sizeOf(Node)))));
        }
        comptime {
            assert(math.isPowerOfTwo(@sizeOf(Node)));
        }
    };

    pub const List = struct {
        first: Node.Index,
        last: Node.Index,

        pub const empty = Node.List{
            .first = .none,
            .last = .none,
        };

        pub fn insertAfter(list: *Node.List, storage: *Node.Storage, existing_node: *Node, new_node: *Node) void {
            const new_node_index = storage.getIndex(new_node);
            new_node.prev = storage.getIndex(existing_node);
            if (storage.getNode(existing_node.next)) |next_node| {
                // Intermediate node.
                new_node.next = existing_node.next;
                next_node.prev = new_node_index;
            } else {
                // Last element of the list.
                new_node.next = .none;
                list.last = new_node_index;
            }
            existing_node.next = new_node_index;
        }

        pub fn insertBefore(list: *Node.List, storage: *Node.Storage, existing_node: *Node, new_node: *Node) void {
            const new_node_index = storage.getIndex(new_node);
            new_node.next = storage.getIndex(existing_node);
            if (storage.getNode(existing_node.prev)) |prev_node| {
                // Intermediate node.
                new_node.prev = existing_node.prev;
                prev_node.next = new_node_index;
            } else {
                // First element of the list.
                new_node.prev = .none;
                list.first = new_node_index;
            }
            existing_node.prev = new_node_index;
        }

        pub fn append(list: *Node.List, storage: *Node.Storage, new_node: *Node) void {
            if (storage.getNode(list.last)) |last| {
                // Insert after last.
                list.insertAfter(storage, last, new_node);
            } else {
                // Empty list.
                list.prepend(storage, new_node);
            }
        }

        pub fn prepend(list: *Node.List, storage: *Node.Storage, new_node: *Node) void {
            if (storage.getNode(list.first)) |first| {
                // Insert before first.
                list.insertBefore(storage, first, new_node);
            } else {
                // Empty list.
                const new_node_index = storage.getIndex(new_node);
                list.first = new_node_index;
                list.last = new_node_index;
                new_node.prev = .none;
                new_node.next = .none;
            }
        }

        pub fn remove(list: *Node.List, storage: *Node.Storage, node: *Node) void {
            if (storage.getNode(node.prev)) |prev_node| {
                // Intermediate node.
                prev_node.next = node.next;
            } else {
                // First element of the list.
                list.first = node.next;
            }

            if (storage.getNode(node.next)) |next_node| {
                // Intermediate node.
                next_node.prev = node.prev;
            } else {
                // Last element of the list.
                list.last = node.prev;
            }
        }

        pub fn pop(list: *Node.List, storage: *Node.Storage) ?*Node {
            const last = storage.getNode(list.last) orelse return null;
            list.remove(storage, last);
            return last;
        }

        pub fn popFirst(list: *Node.List, storage: *Node.Storage) ?*Node {
            const first = storage.getNode(list.first) orelse return null;
            list.remove(storage, first);
            return first;
        }

        pub fn len(list: Node.List, storage: *Node.Storage) usize {
            var count: usize = 0;
            var it = list.iterator(.first_to_last, storage);
            while (it.next()) |_| {
                count += 1;
            }
            return count;
        }

        pub const Direction = enum(u1) {
            first_to_last = 0,
            last_to_first = 1,

            pub fn flipped(direction: Node.List.Direction) Node.List.Direction {
                comptime assert(@typeInfo(Node.List.Direction).@"enum".tag_type == u1);
                return @enumFromInt(~@intFromEnum(direction));
            }
        };

        pub const Iterator = struct {
            next_node: ?*Node,
            storage: *Node.Storage,
            vtable: *const VTable,

            pub const VTable = struct {
                next: *const fn (it: *Node.List.Iterator) ?*Node,
                prev: *const fn (it: *Node.List.Iterator) ?*Node,
            };
            pub const vtables = std.enums.EnumFieldStruct(
                Node.List.Direction,
                *const Node.List.Iterator.VTable,
                null,
            ){
                .first_to_last = &.{
                    .next = &Node.List.Iterator.innerNodeNext,
                    .prev = &Node.List.Iterator.innerNodePrev,
                },
                .last_to_first = &.{
                    .next = &Node.List.Iterator.innerNodePrev,
                    .prev = &Node.List.Iterator.innerNodeNext,
                },
            };

            pub fn next(it: *Node.List.Iterator) ?*Node {
                return it.vtable.next(it);
            }

            pub fn prev(it: *Node.List.Iterator) ?*Node {
                return it.vtable.prev(it);
            }

            pub fn peek(it: Node.List.Iterator) ?*Node {
                return it.next_node;
            }

            fn innerNodeNext(it: *Node.List.Iterator) ?*Node {
                if (it.next_node) |node| {
                    it.next_node = it.storage.getNode(node.next);
                    return node;
                } else {
                    @branchHint(.unlikely);
                    return null;
                }
            }
            fn innerNodePrev(it: *Node.List.Iterator) ?*Node {
                if (it.next_node) |node| {
                    it.next_node = it.storage.getNode(node.prev);
                    return node;
                } else {
                    @branchHint(.unlikely);
                    return null;
                }
            }
        };

        /// Iterate over all nodes in this `Subpath`.
        /// The state of this iterator is affected by
        /// changes to the underlying `Subpath`.
        pub fn iterator(
            list: Node.List,
            storage: *Node.Storage,
            direction: Node.List.Direction,
        ) Node.List.Iterator {
            return switch (direction) {
                .first_to_last => .{
                    .next_node = storage.getNode(list.first),
                    .storage = storage,
                    .vtable = Node.List.Iterator.vtables.first_to_last,
                },
                .last_to_first => .{
                    .next_node = storage.getNode(list.last),
                    .storage = storage,
                    .vtable = Node.List.Iterator.vtables.last_to_first,
                },
            };
        }
    };
};

pub const Subpath = struct {
    nodes: Node.List,
    len: u16,
    direction: Node.List.Direction,

    pub const BitSet = std.bit_set.IntegerBitSet(max_subpath_count);

    pub const empty = Subpath{
        .nodes = .empty,
        .len = 0,
        .direction = .first_to_last,
    };

    pub fn count(subpath: *Subpath) usize {
        assert(subpath.len <= max_node_count);
        return @intCast(subpath.len);
    }

    pub fn contains(subpath: Subpath, pb: *PathBuilder, node: *Node) bool {
        var it = subpath.nodes.iterator(&pb.node_storage, .first_to_last);
        while (it.next()) |path_node| {
            if (node == path_node) {
                return true;
            }
        } else {
            return false;
        }
    }

    /// Only affects iteration/discretization order, list order remains unchanged.
    pub fn flipDirection(subpath: *Subpath) void {
        subpath.direction = subpath.direction.flipped();
    }

    pub fn clear(subpath: *Subpath, pb: *PathBuilder) void {
        while (subpath.pop(pb)) {}
    }

    pub fn append(subpath: *Subpath, pb: *PathBuilder) ?*Node {
        return subpath.innerInsert(.append, pb, null);
    }
    pub fn prepend(subpath: *Subpath, pb: *PathBuilder) ?*Node {
        return subpath.innerInsert(.prepend, pb, null);
    }

    pub fn insertAfter(subpath: *Subpath, pb: *PathBuilder, existing_node: *Node) ?*Node {
        return subpath.innerInsert(.insert_after, pb, existing_node);
    }
    pub fn insertBefore(subpath: *Subpath, pb: *PathBuilder, existing_node: *Node) ?*Node {
        return subpath.innerInsert(.insert_before, pb, existing_node);
    }

    pub fn pop(subpath: *Subpath, pb: *PathBuilder) bool {
        return subpath.innerPop(.last, pb);
    }
    pub fn popFirst(subpath: *Subpath, pb: *PathBuilder) bool {
        return subpath.innerPop(.first, pb);
    }

    pub fn remove(subpath: *Subpath, pb: *PathBuilder, node: *Node) void {
        assert(subpath.contains(pb, node));
        subpath.nodes.remove(&pb.node_storage, node);
        subpath.len -= 1;
        pb.releaseNode(node);
    }

    const InsertKind = enum {
        insert_after,
        insert_before,
        append,
        prepend,
    };
    fn innerInsert(
        subpath: *Subpath,
        comptime kind: InsertKind,
        pb: *PathBuilder,
        existing_node: ?*Node,
    ) ?*Node {
        const new_node = pb.acquireNode() orelse return null;
        assert(subpath.len < max_node_count);

        const storage = &pb.node_storage;
        switch (kind) {
            .insert_after => subpath.nodes.insertAfter(storage, existing_node.?, new_node),
            .insert_before => subpath.nodes.insertBefore(storage, existing_node.?, new_node),
            .append => subpath.nodes.append(storage, new_node),
            .prepend => subpath.nodes.prepend(storage, new_node),
        }
        subpath.len += 1;
        assert(subpath.len <= max_node_count);
        return new_node;
    }

    const PopKind = enum {
        last,
        first,
    };
    fn innerPop(subpath: *Subpath, comptime kind: PopKind, pb: *PathBuilder) bool {
        const storage = &pb.node_storage;
        const popped = switch (kind) {
            .last => subpath.nodes.pop(storage),
            .first => subpath.nodes.popFirst(storage),
        };
        if (popped) |node| {
            assert(subpath.len >= 1);
            subpath.len -= 1;
            pb.releaseNode(node);
            return true;
        } else {
            return false;
        }
    }

    pub const Discretized = stdx.splines.CatmullRomDiscretized;

    /// For per-frame calculations.
    pub fn discretizeFast(subpath: *Subpath, arena: Allocator, pb: *PathBuilder) Allocator.Error!Discretized.Slice {
        return subpath.discretize(.fast, arena, pb, 0.1, .{
            .max_approx_steps = 50,
            .eps = 10e-3,
        });
    }
    /// For precise calculations.
    pub fn discretizePrecise(subpath: *Subpath, gpa: Allocator, pb: *PathBuilder) Allocator.Error!Discretized.Slice {
        return subpath.discretize(.precise, gpa, pb, 0.01, .{
            .max_approx_steps = 100,
            .eps = 10e-6,
        });
    }

    pub const DiscretizeMode = enum {
        fast,
        precise,

        pub fn getNamespace(mode: DiscretizeMode) type {
            return switch (mode) {
                .fast => stdx.splines.catmull_rom(f32, .{ .trapezoid = .{ .subdivisions = 100 } }),
                // TODO test simpson_adaptive in realistic scenarios
                .precise => stdx.splines.catmull_rom(f32, .{ .trapezoid = .{ .subdivisions = 500 } }),
            };
        }
    };

    /// Caller owns returned `Slice`.
    pub fn discretize(
        subpath: *Subpath,
        comptime mode: DiscretizeMode,
        allocator: Allocator,
        pb: *PathBuilder,
        granularity: f32,
        options: mode.getNamespace().DiscretizeOptions,
    ) Allocator.Error!Discretized.Slice {
        var control_point_buffer: [1 + max_node_count + 1]mode.getNamespace().ControlPoint = undefined;
        const control_points = subpath.nodesToContolPoints(mode, pb, &control_point_buffer);
        if (control_points.len == 0) {
            @branchHint(.unlikely);
            return .empty;
        }
        const disc = try discretizeFromControlPoints(mode, allocator, control_points, granularity, options);
        assert(disc.len != 0);
        if (builtin.mode == .Debug) {
            for (disc.items(.coords)) |coords| assert(math.isFinite(coords.x) and math.isFinite(coords.y));
            for (disc.items(.t)) |t| assert(math.isFinite(t));
        }
        return disc;
    }

    fn nodesToContolPoints(
        subpath: *Subpath,
        comptime mode: DiscretizeMode,
        pb: *PathBuilder,
        dest: *[1 + max_node_count + 1]mode.getNamespace().ControlPoint,
    ) []const mode.getNamespace().ControlPoint {
        const orig_node_count = subpath.count();
        if (orig_node_count < 2) {
            return &.{};
        }

        // Transform linked list of nodes into a more useful data layout

        var it = subpath.iterator(pb);
        for (dest[1..][0..orig_node_count]) |*control_point| {
            const node = it.next().?;
            control_point.* = .{
                .xy = .{ node.x, node.y },
                .tension = node.tension.get(),
            };
        }
        assert(it.peek() == null);

        // Make curve actually intersect the first + last points by adding
        // additional helper control points

        const node_count = (1 + orig_node_count + 1);
        assert(node_count >= 4);
        dest[0] = .{
            .xy = Vec2
                .fromSlice(&dest[2].xy)
                .lerp(.fromSlice(&dest[1].xy), 2.0)
                .toArray(),
            .tension = 0.0,
        };

        dest[node_count - 1] = .{
            .xy = Vec2
                .fromSlice(&dest[node_count - 3].xy)
                .lerp(.fromSlice(&dest[node_count - 2].xy), 2.0)
                .toArray(),
            .tension = 0.0,
        };

        return dest[0..node_count];
    }

    fn discretizeFromControlPoints(
        comptime mode: DiscretizeMode,
        allocator: Allocator,
        control_points: []const mode.getNamespace().ControlPoint,
        granularity: f32,
        options: mode.getNamespace().DiscretizeOptions,
    ) Allocator.Error!Discretized.Slice {
        assert(control_points.len >= 4);
        assert(granularity > 0.0);
        const slice = try mode.getNamespace()
            .discretize(allocator, control_points, granularity, options);
        return slice;
    }

    fn vec2ClampDistance(first_vector: Vec2, second_vector: Vec2, max_distance: f32) Vec2 {
        const diff = second_vector.sub(first_vector);
        return second_vector.add(diff.scale(@min(diff.length(), max_distance)));
    }

    pub fn iterator(subpath: *Subpath, pb: *PathBuilder) Node.List.Iterator {
        return subpath.nodes.iterator(&pb.node_storage, subpath.direction);
    }
};

const builtin = @import("builtin");
const std = @import("std");
const stdx = @import("stdx");
const zalgebra = @import("zalgebra");

const math = std.math;
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Vec2 = zalgebra.Vec2;

const assert = std.debug.assert;

// TESTS

fn expectExisting(optional: anytype) !@typeInfo(@TypeOf(optional)).optional.child {
    return optional orelse error.TestExpectedExisting;
}

test "basic usage" {
    var pb = PathBuilder.init;

    // acquire subpaths

    const s1: *Subpath = try expectExisting(pb.acquireSubpath());
    const s2: *Subpath = try expectExisting(pb.acquireSubpath());
    const s3: *Subpath = try expectExisting(pb.acquireSubpath());

    // check for uniqueness

    try testing.expect(s1 != s2);
    try testing.expect(s2 != s3);
    try testing.expect(s3 != s1);

    // iterate existing subpaths

    var sub_it = pb.iterator();
    try testing.expectEqual(s1, try expectExisting(sub_it.peek()));
    try testing.expectEqual(s1, try expectExisting(sub_it.next()));
    try testing.expectEqual(s2, try expectExisting(sub_it.next()));
    try testing.expectEqual(s3, try expectExisting(sub_it.next()));
    try testing.expectEqual(null, sub_it.next());
    try testing.expectEqual(null, sub_it.next());

    // insert nodes into subpath

    const n11: *Node = try expectExisting(s1.append(&pb));
    const n12: *Node = try expectExisting(s1.prepend(&pb));
    const n13: *Node = try expectExisting(s1.insertAfter(&pb, n12));

    // check for uniqueness

    try testing.expect(n11 != n12);
    try testing.expect(n12 != n13);
    try testing.expect(n13 != n11);

    // iterate subpath nodes

    var it1 = s1.iterator(&pb);
    try testing.expectEqual(n12, try expectExisting(it1.peek()));
    try testing.expectEqual(n12, try expectExisting(it1.next()));
    try testing.expectEqual(n13, try expectExisting(it1.next()));
    try testing.expectEqual(n11, try expectExisting(it1.next()));
    try testing.expectEqual(null, it1.next());
    try testing.expectEqual(null, it1.next());

    // reuse removed nodes

    const n21: *Node = try expectExisting(s2.append(&pb));
    const n22: *Node = try expectExisting(s2.append(&pb));
    try testing.expect(s2.pop(&pb));
    const n23: *Node = try expectExisting(s2.append(&pb));
    try testing.expectEqual(n22, n23);

    // iterate subpath nodes with flipped direction

    s2.flipDirection();
    var it2 = s2.iterator(&pb);
    try testing.expectEqual(n23, try expectExisting(it2.next()));
    try testing.expectEqual(n21, try expectExisting(it2.next()));
    try testing.expectEqual(null, it2.next());

    // clear all nodes in subpath on release

    const prev_count = pb.usedNodeCount();
    _ = try expectExisting(s3.append(&pb));
    pb.releaseSubpath(s3);
    try testing.expectEqual(prev_count, pb.usedNodeCount());
}

test "acquire/release subpaths/nodes" {
    var pb = PathBuilder.init;

    // acquire

    var subpaths: [max_subpath_count]*Subpath = undefined;
    for (&subpaths) |*subpath| {
        subpath.* = try expectExisting(pb.acquireSubpath());
    }
    try testing.expectEqual(null, pb.acquireSubpath());
    try testing.expectEqual(0, pb.unusedSubpathCount());

    var nodes: [max_node_count]*Node = undefined;
    for (&nodes) |*node| {
        node.* = try expectExisting(pb.acquireNode());
    }
    try testing.expectEqual(null, pb.acquireNode());
    try testing.expectEqual(0, pb.unusedNodeCount());

    // release

    for (subpaths) |subpath| {
        pb.releaseSubpath(subpath);
    }
    try testing.expectEqual(0, pb.usedSubpathCount());
    try testing.expect(pb.acquireSubpath() != null);

    for (nodes) |node| {
        pb.releaseNode(node);
    }
    try testing.expectEqual(0, pb.usedNodeCount());
    try testing.expect(pb.acquireNode() != null);
}

test "resource exhaustion" {
    var pb = PathBuilder.init;

    // exahaust subpath pool

    for (0..max_subpath_count) |_| {
        _ = pb.acquireSubpath();
    }
    try testing.expectEqual(null, pb.acquireSubpath());

    // check subpath reuse

    var it = pb.iterator();
    var s1: *Subpath = try expectExisting(it.next());
    const s2: *Subpath = try expectExisting(it.next());
    pb.releaseSubpath(s1);

    s1 = try expectExisting(pb.acquireSubpath());
    try testing.expectEqual(null, pb.acquireSubpath());

    // exhaust node pool

    for (0..max_node_count) |_| {
        _ = s1.append(&pb);
    }
    try testing.expectEqual(null, s1.append(&pb));
    try testing.expectEqual(max_node_count, s1.count());
    try testing.expectEqual(0, pb.unusedNodeCount());

    // check node reuse

    try testing.expect(s1.pop(&pb));
    try testing.expectEqual(1, pb.unusedNodeCount());

    _ = try expectExisting(s2.append(&pb));
    try testing.expectEqual(null, s2.append(&pb));
}

test "node removal" {
    var pb = PathBuilder.init;

    var s1: *Subpath = try expectExisting(pb.acquireSubpath());

    const n11: *Node = try expectExisting(s1.append(&pb));
    const n12: *Node = try expectExisting(s1.append(&pb));
    const n13: *Node = try expectExisting(s1.append(&pb));
    const n14: *Node = try expectExisting(s1.append(&pb));

    // test different removal methods

    s1.remove(&pb, n12);
    try testing.expect(!s1.contains(&pb, n12));

    try testing.expect(s1.popFirst(&pb));
    try testing.expect(!s1.contains(&pb, n11));

    try testing.expect(s1.pop(&pb));
    try testing.expect(!s1.contains(&pb, n14));

    try testing.expectEqual(1, s1.count());
    var it = s1.iterator(&pb);
    try testing.expectEqual(n13, try expectExisting(it.next()));
    try testing.expectEqual(null, it.peek());
}

fn testCheckDiscretizedPath(disc: Subpath.Discretized.Slice, granularity: f32) !void {
    try testing.expect(math.isFinite(disc.items(.coords)[0].x));
    try testing.expect(math.isFinite(disc.items(.coords)[0].y));

    var total_dist: f32 = 0;
    for (
        disc.items(.coords)[0..(disc.len - 1)],
        disc.items(.coords)[1..],
    ) |c0, c1| {
        try testing.expect(math.isFinite(c1.x));
        try testing.expect(math.isFinite(c1.y));

        const dist = c0.asVec().distance(c1.asVec());
        try testing.expectApproxEqAbs(granularity, dist, 10e-2);
        total_dist += dist;
    }
    const average_dist = (total_dist / @as(f32, @floatFromInt(disc.len - 1)));
    try testing.expectApproxEqAbs(granularity, average_dist, 10e-4);
}

test "subpath discretization" {
    // if (true) return error.SkipZigTest;
    var pb = PathBuilder.init;

    const s1: *Subpath = try expectExisting(pb.acquireSubpath());

    const n1: *Node = try expectExisting(s1.append(&pb));
    const n2: *Node = try expectExisting(s1.append(&pb));
    const n3: *Node = try expectExisting(s1.append(&pb));

    n1.set(1, 1, 0.7);
    n2.set(3, 5, 0.2);
    n3.set(5, 4, 0.4);

    try testing.expectEqual(3, s1.count());

    // check accuracy of discrete points

    const granularity = 0.1;
    var disc = try s1.discretize(.precise, testing.allocator, &pb, granularity, .{});
    defer disc.deinit(testing.allocator);

    try testCheckDiscretizedPath(disc, granularity);
}

test "fuzz subpath discretization" {
    if (builtin.os.tag == .macos) {
        // blocked by [#20986](https://github.com/ziglang/zig/issues/20986)
        return error.SkipZigTest;
    }
    const Context = struct {
        pb: PathBuilder,

        fn testOne(context: @This(), input: []const u8) !void {
            var in_stream = std.io.fixedBufferStream(input);
            const in = in_stream.reader();
            const prng_seed = in.readInt(u64, .little) orelse return;
            var prng = std.Random.DefaultPrng.init(prng_seed);
            const rand = prng.random();

            const pb = &context.pb;

            const subpath, var node = init: {
                const sp = pb.acquireSubpath() orelse blk: {
                    pb.reset();
                    break :blk try expectExisting(pb.acquireSubpath());
                };
                const node = sp.append(pb) orelse {
                    pb.reset();
                    const new_sp = try expectExisting(pb.acquireSubpath());
                    const new_node = try expectExisting(new_sp.append(pb));
                    break :init .{ new_sp, new_node };
                };
                break :init .{ sp, node };
            };

            // We need at least two nodes
            const node_count = rand.intRangeLessThan(u8, 1, (max_node_count - 1));
            for (0..node_count) |_| {
                const insert_kind = rand.enumValue(Subpath.InsertKind);
                node = switch (insert_kind) {
                    inline else => |kind| subpath.innerInsert(kind, pb, node) orelse break,
                };
            }

            const disc_mode = Subpath.DiscretizeMode.precise;
            var control_point_buffer: [1 + max_node_count + 1]disc_mode.getNamespace().ControlPoint = undefined;
            const control_points = subpath.nodesToContolPoints(disc_mode, pb, &control_point_buffer);
            const subpath_len = disc_mode.getNamespace().totalLength(control_points);

            const granularity = ((rand.floatNorm(f32) * subpath_len) + math.floatEpsAt(f32, 0.0));
            const disc = try Subpath.discretizeFromControlPoints(.precise, testing.allocator, control_points, granularity, .{});
            defer disc.deinit(testing.allocator);

            try testCheckDiscretizedPath(disc, granularity);
        }
    };
    try testing.fuzz(Context{ .pb = .init }, Context.testOne, .{});
}
