//! Allocation-free data structure that acts as a fixed-size memory pool
//! for `Subpath`s and `Path.Node`s.
//! The base data structure does not contain any pointers.
//! `Subpath`s can be individually discretized to 2D coordinates.

subpaths: [max_subpath_count]Subpath,
subpath_avail_set: Subpath.AvailSet,
nodes: Node.Storage,
unused_nodes: Node.List,
unused_node_count: usize,

const Path = @This();

pub const max_subpath_count = 8;
pub const max_node_count = 64;

pub const empty = Path{
    .subpaths = undefined,
    .subpath_avail_set = .initFull(),
    .nodes = .empty,
    .unused_nodes = .empty,
    .unused_node_count = max_node_count,
};

/// Returns a pointer to a new `Subpath` or `null` if there are no
/// subpaths available.
pub fn acquireSubpath(path: *Path) ?*Subpath {
    const index = path.subpath_avail_set.toggleFirstSet() orelse return null;
    const subpath = &path.subpaths[index];
    subpath.* = .empty;
    return subpath;
}

/// Invalidates `subpath`. Accessing `subpath` after this function
/// finishes causes undefined behavior.
pub fn releaseSubpath(path: *Path, subpath: *Subpath) void {
    assert(stdx.containsPointer(Subpath, &path.subpaths, subpath));
    path.clearSubpath(subpath);
    subpath.* = undefined;
    const offset = (@intFromPtr(subpath) - @intFromPtr(&path.subpaths));
    const index = @divExact(offset, @sizeOf(Subpath));
    assert(path.subpath_avail_set.isSet(index) == false);
    path.subpath_avail_set.set(index);
}

pub fn clearSubpath(path: *Path, subpath: *Subpath) void {
    while (subpath.pop()) |node| {
        path.releaseNode(node);
    }
}

/// Returns a pointer to a new `Node` or `null` if there are no
/// nodes available.
pub fn acquireNode(path: *Path) ?*Node {
    if (path.unused_node_count == 0) {
        return null;
    } else {
        assert(path.unused_node_count <= max_node_count);
        path.unused_node_count -= 1;
    }
    return path.unused_nodes.pop(path.nodes) orelse
        path.nodes.inner.addOneAssumeCapacity();
}

/// Invalidates `node`. Accessing `node` after this function
/// finishes causes undefined behavior.
pub fn releaseNode(path: *Path, node: *Node) void {
    node.* = undefined;
    if (&path.nodes.buffer[path.nodes.inner.len - 1] == node) {
        _ = path.nodes.inner.pop().?;
    } else {
        assert(stdx.containsPointer(Node, path.nodes.inner.constSlice(), node));
        path.unused_nodes.append(path.nodes, node);
    }
    path.unused_node_count += 1;
    assert(path.unused_node_count <= max_node_count);
}

pub fn usedNodeCount(path: Path) usize {
    return (max_node_count - path.unusedNodeCount());
}
pub fn unusedNodeCount(path: Path) usize {
    assert(path.unused_node_count <= max_node_count);
    return path.unused_node_count;
}

pub const Node = struct {
    x: f32,
    y: f32,
    tension: stdx.BoundedValue(f32, 0, 1),
    next: Index,
    prev: Index,

    pub const Index = enum(u16) {
        none = std.math.maxInt(u16),
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
            assert(index.asInt() < storage.len);
            return &storage.inner.slice()[index.asInt()];
        }
        /// This compiles to a subtraction and a bitshift
        /// (as long as `@sizeOf(Node)` is a power of two).
        pub fn getIndex(storage: *const Node.Storage, node: *const Node) Node.Index {
            assert(stdx.containsPointer(Node, storage.inner.constSlice(), node));
            const offset = (@intFromPtr(node) - @intFromPtr(storage.constSlice()));
            return @enumFromInt(@as(u16, @intCast(@divExact(offset, @sizeOf(Node)))));
        }
        comptime {
            assert(std.math.isPowerOfTwo(@sizeOf(Node)));
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
                list.insertAfter(last, new_node);
            } else {
                // Empty list.
                list.prepend(new_node);
            }
        }

        pub fn prepend(list: *Node.List, storage: *Node.Storage, new_node: *Node) void {
            if (storage.getNode(list.first)) |first| {
                // Insert before first.
                list.insertBefore(first, new_node);
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
            list.remove(last);
            return last;
        }

        pub fn popFirst(list: *Node.List, storage: *Node.Storage) ?*Node {
            const first = storage.getNode(list.first) orelse return null;
            list.remove(first);
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
                next: fn (it: *Node.List.Iterator) ?*Node,
                prev: fn (it: *Node.List.Iterator) ?*Node,
            };
            pub const vtables = std.enums.EnumFieldStruct(
                Node.List.Direction,
                *const Node.List.Iterator.VTable,
                null,
            ){
                .first_to_last = &.{
                    .next = Node.List.Iterator.innerNext,
                    .prev = Node.List.Iterator.innerPrev,
                },
                .last_to_first = &.{
                    .next = Node.List.Iterator.innerPrev,
                    .prev = Node.List.Iterator.innerNext,
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

            fn innerNext(it: *Node.List.Iterator) ?*Node {
                return it.innerIter(.first_to_last);
            }
            fn innerPrev(it: *Node.List.Iterator) ?*Node {
                return it.innerIter(.last_to_first);
            }
            fn innerIter(it: *Node.List.Iterator, comptime direction: Node.List.Direction) ?*Node {
                const node = it.next_node orelse {
                    @branchHint(.unlikely);
                    return null;
                };
                it.next_node = switch (direction) {
                    .first_to_last => it.storage.getNode(node.next),
                    .last_to_first => it.storage.getNode(node.prev),
                };
                return node;
            }
        };
        pub fn iterator(
            list: Node.List,
            storage: *Node.Storage,
            direction: Node.List.Direction,
        ) Iterator {
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
    len: u8,
    direction: Node.List.Direction,

    pub const AvailSet = std.StaticBitSet(max_subpath_count);

    pub const empty = Subpath{
        .nodes = .{},
        .len = 0,
        .direction = .first_to_last,
    };

    pub fn count(subpath: *Subpath) usize {
        assert(subpath.len <= max_node_count);
        return @intCast(subpath.len);
    }

    pub fn contains(subpath: Subpath, path: *Path, node: *Node) bool {
        var it = subpath.nodes.iterator(&path.nodes, .first_to_last);
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

    pub fn append(subpath: *Subpath, path: *Path, new_node: *Node) bool {
        return subpath.innerInsert(.append, path, null, new_node);
    }
    pub fn prepend(subpath: *Subpath, path: *Path, new_node: *Node) bool {
        return subpath.innerInsert(.prepend, path, null, new_node);
    }

    pub fn insertAfter(subpath: *Subpath, path: *Path, existing_node: *Node, new_node: *Node) bool {
        return subpath.innerInsert(.insert_after, path, existing_node, new_node);
    }
    pub fn insertBefore(subpath: *Subpath, path: *Path, existing_node: *Node, new_node: *Node) bool {
        return subpath.innerInsert(.insert_before, path, existing_node, new_node);
    }

    pub fn pop(subpath: *Subpath, path: *Path) ?*Node {
        return subpath.innerPop(.last, path);
    }
    pub fn popFirst(subpath: *Subpath, path: *Path) ?*Node {
        return subpath.innerPop(.first, path);
    }

    pub fn remove(subpath: *Subpath, path: *Path, node: *Node) void {
        assert(subpath.contains(node));
        subpath.nodes.remove(path.nodes, node);
        subpath.len -= 1;
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
        path: *Path,
        existing_node: ?*Node,
        new_node: *Node,
    ) bool {
        if (subpath.len == max_node_count) {
            return false;
        } else {
            const storage = &path.nodes;
            switch (kind) {
                .insert_after => subpath.nodes.insertAfter(storage, existing_node.?, new_node),
                .insert_before => subpath.nodes.insertBefore(storage, existing_node.?, new_node),
                .append => subpath.nodes.append(storage, new_node),
                .prepend => subpath.nodes.prepend(storage, new_node),
            }
            subpath.len += 1;
            assert(subpath.len <= max_subpath_count);
            return true;
        }
    }

    const PopKind = enum {
        last,
        first,
    };
    fn innerPop(subpath: *Subpath, comptime kind: PopKind, path: *Path) ?*Node {
        const storage = &path.nodes;
        return switch (kind) {
            .last => subpath.nodes.pop(storage),
            .first => subpath.nodes.popFirst(storage),
        };
    }

    pub const Discretized = stdx.splines.CatmullRomDiscretized;

    pub fn discretizeFast(subpath: *Subpath, arena: Allocator, path: *Path) Allocator.Error!Discretized.Slice {
        return subpath.discretize(.fast, arena, path, 0.1);
    }
    pub fn discretizePrecise(subpath: *Subpath, gpa: Allocator, path: *Path) Allocator.Error!Discretized.Slice {
        return subpath.discretize(.precise, gpa, path, 0.01);
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
        gpa: Allocator,
        path: *Path,
        granularity: f32,
    ) Allocator.Error!Discretized.Slice {
        const user_node_count = subpath.count();
        if (user_node_count < 2) {
            return .empty;
        }

        // Transform linked list of nodes into a more useful data layout

        const ControlPoint = mode.getNamespace().ControlPoint;
        var control_points: [1 + max_node_count + 1]ControlPoint = undefined;

        var it = subpath.iterator(path);
        for (control_points[1..][0..user_node_count]) |*control_point| {
            const node = it.next().?;
            control_point.* = .{
                .xy = .{ node.x, node.y },
                .tension = node.tension.get(),
            };
        }
        assert(it.peek() == null);

        // Make curve actually intersect the first + last points by adding
        // additional helper control points

        const node_count = (1 + user_node_count + 1);
        assert(node_count >= 4);

        control_points[0] = .{
            .xy = Vec2
                .fromSlice(&control_points[2].xy)
                .lerp(.fromSlice(&control_points[1].xy), 2.0)
                .toArray(),
            .tension = 0.0,
        };

        control_points[node_count - 1] = .{
            .xy = Vec2
                .fromSlice(&control_points[node_count - 3].xy)
                .lerp(.fromSlice(&control_points[node_count - 2].xy), 2.0)
                .toArray(),
            .tension = 0.0,
        };

        // Calculate discrete points

        const slice = try mode.getNamespace().discretize(gpa, control_points, granularity, .{});
        return slice;
    }

    pub fn iterator(subpath: *Subpath, path: *Path) Node.List.Iterator {
        return subpath.nodes.iterator(&path.nodes, subpath.direction);
    }
};

const std = @import("std");
const stdx = @import("stdx");
const zalgebra = @import("zalgebra");

const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Vec2 = zalgebra.Vec2;

const assert = std.debug.assert;
