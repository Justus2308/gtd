subpaths: [max_subpath_count]Subpath,
nodes: Node.Storage,
unused_nodes: Node.List,
unused_node_count: usize,

const Path = @This();

pub const max_subpath_count = 8;
pub const max_node_count = 64;

pub const Node = struct {
    x: f32,
    y: f32,
    tension: stdx.BoundedValue(f32, 0, 1),
    ll_node: Node.List.Node = .{},

    pub const Storage = std.BoundedArray(Node, max_node_count);
    pub const List = std.DoublyLinkedList;
};

pub const Subpath = struct {
    nodes: Node.List,
    len: u8,
    is_used: bool,
    direction: Direction,

    pub const Direction = enum(u1) {
        first_to_last = 0,
        last_to_first = 1,

        pub fn flipped(direction: Direction) Direction {
            comptime assert(@typeInfo(Direction).@"enum".tag_type == u1);
            return @enumFromInt(~@intFromEnum(direction));
        }
    };

    pub const empty = Subpath{
        .nodes = .{},
        .is_used = false,
        .direction = .first_to_last,
    };

    pub fn count(subpath: *Subpath) usize {
        assert(subpath.is_used or subpath.len == 0);
        assert(subpath.len <= max_node_count);
        return @intCast(subpath.len);
    }

    pub fn append(subpath: *Subpath, new_node: *Node) bool {
        return subpath.innerInsert(.append, null, new_node);
    }
    pub fn prepend(subpath: *Subpath, new_node: *Node) bool {
        return subpath.innerInsert(.prepend, null, new_node);
    }

    pub fn insertAfter(subpath: *Subpath, existing_node: *Node, new_node: *Node) bool {
        return subpath.innerInsert(.insert_after, existing_node, new_node);
    }
    pub fn insertBefore(subpath: *Subpath, existing_node: *Node, new_node: *Node) bool {
        return subpath.innerInsert(.insert_before, existing_node, new_node);
    }

    pub fn pop(subpath: *Subpath) ?*Node {
        return subpath.innerPop(.last);
    }
    pub fn popFirst(subpath: *Subpath) ?*Node {
        return subpath.innerPop(.first);
    }

    pub fn remove(subpath: *Subpath, node: *Node) void {
        assert(subpath.is_used);
        assert(subpath.contains(node));
        subpath.nodes.remove(node.ll_node);
        subpath.len -= 1;
    }

    pub fn contains(subpath: Subpath, node: *Node) bool {
        assert(subpath.is_used);
        var ll_node_maybe = subpath.nodes.first;
        while (ll_node_maybe) |ll_node| : (ll_node_maybe = ll_node.next) {
            const path_node: *Node = @fieldParentPtr("ll_node", ll_node);
            if (node == path_node) {
                return true;
            }
        } else {
            return false;
        }
    }

    /// Only affects iteration/discretization order, list order remains unchanged.
    pub fn flipDirection(subpath: *Subpath) void {
        assert(subpath.is_used);
        subpath.direction = subpath.direction.flipped();
    }

    pub const Discretized = stdx.splines.CatmullRomDiscretized;

    pub fn discretizeFast(subpath: *Subpath, gpa: Allocator) Allocator.Error!Discretized.Slice {
        return subpath.discretize(.fast, gpa, 0.1);
    }
    pub fn discretizePrecise(subpath: *Subpath, gpa: Allocator) Allocator.Error!Discretized.Slice {
        return subpath.discretize(.precise, gpa, 0.01);
    }

    pub const DiscretizeMode = enum {
        fast,
        precise,

        pub fn getNamespace(mode: DiscretizeMode) type {
            return switch (mode) {
                .fast => stdx.splines.catmull_rom(f32, .{ .trapezoid = .{ .subdivisions = 100 } }),
                .precise => stdx.splines.catmull_rom(f32, .{ .trapezoid = .{ .subdivisions = 500 } }),
            };
        }
    };
    pub fn discretize(
        subpath: *Subpath,
        comptime mode: DiscretizeMode,
        gpa: Allocator,
        granularity: f32,
    ) Allocator.Error!Discretized.Slice {
        const user_node_count = subpath.count();
        if (user_node_count < 2) {
            return .empty;
        }

        // Transform linked list of nodes into a more useful data layout

        const ControlPoint = mode.getNamespace().ControlPoint;
        var control_points: [1 + max_node_count + 1]ControlPoint = undefined;

        var it = subpath.iterator();
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

    pub const Iterator = struct {
        ll_node: ?*Node.List.Node,
        direction: Direction,

        pub fn next(it: *Iterator) ?*Node {
            if (it.ll_node) |ll_node| {
                it.ll_node = switch (it.direction) {
                    .first_to_last => ll_node.next,
                    .last_to_first => ll_node.prev,
                };
                const node: *Node = @fieldParentPtr("ll_node", ll_node);
                return node;
            } else {
                @branchHint(.unlikely);
                return null;
            }
        }

        pub fn peek(it: *Iterator) ?*Node {
            if (it.ll_node) |ll_node| {
                const node: *Node = @fieldParentPtr("ll_node", ll_node);
                return node;
            } else {
                @branchHint(.unlikely);
                return null;
            }
        }
    };
    pub fn iterator(subpath: *Subpath) Iterator {
        return switch (subpath.direction) {
            .first_to_last => Iterator{
                .ll_node = subpath.nodes.first,
                .direction = .first_to_last,
            },
            .last_to_first => Iterator{
                .ll_node = subpath.nodes.last,
                .direction = .last_to_first,
            },
        };
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
        existing_node: ?*Node,
        new_node: *Node,
    ) bool {
        assert(subpath.is_used);
        if (subpath.len == max_subpath_count) {
            return false;
        } else {
            switch (kind) {
                .insert_after => subpath.nodes.insertAfter(existing_node.?.ll_node, new_node.ll_node),
                .insert_before => subpath.nodes.insertBefore(existing_node.?.ll_node, new_node.ll_node),
                .append => subpath.nodes.append(new_node.ll_node),
                .prepend => subpath.nodes.prepend(new_node.ll_node),
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
    fn innerPop(subpath: *Subpath, comptime kind: PopKind) ?*Node {
        assert(subpath.is_used);
        const popped = switch (kind) {
            .last => subpath.nodes.pop(),
            .first => subpath.nodes.popFirst(),
        };
        if (popped) |ll_node| {
            const node: *Node = @fieldParentPtr("ll_node", ll_node);
            subpath.len -= 1;
            return node;
        } else {
            return null;
        }
    }
};

pub const empty = Path{
    .subpaths = @splat(.empty),
    .nodes = .{},
    .unused_nodes = .{},
    .unused_node_count = max_node_count,
};

pub fn acquireSubpath(path: *Path) ?*Subpath {
    for (&path.subpaths) |*subpath| {
        if (subpath.is_used == false) {
            assert(subpath.nodes.len() == 0);
            subpath.is_used = true;
            return subpath;
        }
    } else {
        return null;
    }
}
pub fn releaseSubpath(path: *Path, subpath: *Subpath) void {
    assert(subpath.is_used);
    assert(stdx.containsPointer(Subpath, &path.subpaths, subpath));
    while (subpath.nodes.pop()) |ll_node| {
        const node: *Node = @fieldParentPtr("ll_node", ll_node);
        path.releaseNode(node);
    }
    subpath.is_used = false;
}

pub fn acquireNode(path: *Path) ?*Node {
    if (path.unused_node_count == 0) {
        return null;
    } else {
        assert(path.unused_node_count <= max_node_count);
        path.unused_node_count -= 1;
    }
    if (path.unused_nodes.pop()) |ll_node| {
        const node: *Node = @fieldParentPtr("ll_node", ll_node);
        assert(stdx.containsPointer(Node, path.nodes.constSlice(), node));
        return node;
    } else {
        return path.nodes.addOneAssumeCapacity();
    }
}
pub fn releaseNode(path: *Path, node: *Node) void {
    if (&path.nodes.buffer[path.nodes.len - 1] == node) {
        _ = path.nodes.pop().?;
    } else {
        assert(stdx.containsPointer(Node, path.nodes.constSlice(), node));
        path.unused_nodes.append(node.ll_node);
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

const std = @import("std");
const stdx = @import("stdx");
const zalgebra = @import("zalgebra");

const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Vec2 = zalgebra.Vec2;

const assert = std.debug.assert;
