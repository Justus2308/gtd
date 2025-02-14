const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");

const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Vec2D = geo.points.Vec2D;

const assert = std.debug.assert;


pub const Path = struct {
    subpaths: []const Subpath,


    const Subpath = stdx.StaticMultiArrayList(Path.Segment);

    pub const max_subpath_count = 8;
    pub const max_segment_count = 64;

    const mem_align = @alignOf(*anyopaque);


    pub inline fn build(allocator: Allocator) Allocator.Error!Path.Builder {
        return Path.Builder.init(allocator);
    }

    pub inline fn edit(path: Path, allocator: Allocator) Allocator.Error!Path.Builder {
        return Path.Builder.initFromPath(allocator, path);
    }

    pub fn deinit(path: *Path, allocator: Allocator) void {
        var segment_count: usize = 0;
        for (path.subpaths) |subpath| {
            segment_count += subpath.len;
        }
        const subpath_size = (path.subpaths.len * @sizeOf(Subpath));
        const segment_size = Subpath.requiredByteSize(segment_count);
        const size = subpath_size + segment_size;
        const raw = @as([*]align(Path.mem_align) u8, @ptrCast(@constCast(@alignCast(path.subpaths.ptr))))[0..size];
        allocator.free(raw);
        path.* = undefined;
    }

    pub fn discretize(path: Path, allocator: Allocator, granularity: f32) Allocator.Error![][]Vec2D {
        const subpath_point_count_safety_margin = 8;

        var total_point_size: usize = 0;
        var subpath_sizes_buffer: [Path.max_subpath_count]usize = undefined;
        const subpath_sizes = subpath_sizes_buffer[0..path.subpaths.len];
        for (path.subpaths, subpath_sizes) |subpath, *size| {
            const point_count = geo.splines.catmull_rom.estimateDiscretePointCount(
                subpath.items(.start),
                subpath.items(.tension),
                granularity,
            ) + subpath_point_count_safety_margin;
            const point_size = (point_count * @sizeOf(Vec2D));
            // Every subpath should be cache line aligned to avoid false sharing
            // when processing subpaths in parallel.
            const point_size_aligned = mem.alignForward(usize, point_size, std.atomic.cache_line);
            total_point_size += point_size_aligned;
            size.* = point_size_aligned;
        }

        const discretized = try allocator.alloc([]Vec2D, path.subpaths.len);
        errdefer allocator.free(discretized);

        for (path.subpaths, discretized) |subpath, *disc| {
            errdefer {
                const end = @intFromPtr(disc) - @intFromPtr(&discretized[0]);
                for (discretized[0..end]) |d| {
                    allocator.free(d);
                }
            }
            disc.* = try geo.splines.catmull_rom.discretize(
                allocator,
                subpath.items(.start),
                subpath.items(.tension),
                granularity,
            );
        }
        errdefer for (discretized) |d| {
            allocator.free(d);
        };
        // TODO transform into more cache-friendly mem layout
        return discretized;
    }

    pub const Segment = struct {
        start: Vec2D,
        /// [0,1]
        tension: f32,

        pub const List = struct {
            inner: Inner,
            direction: Direction,

            pub const Elem = struct {
                segment: Path.Segment,
                list_id: u32,
            };
            pub const Inner = std.DoublyLinkedList(Elem);

            pub const Direction = enum {
                natural,
                reverse,

                pub inline fn flip(direction: *Direction) void {
                    direction.* = switch (direction.*) {
                        .natural => .reverse,
                        .reverse => .natural,
                    };
                }
            };
        };

        pub const Field = std.meta.FieldEnum(Segment);

        /// Use this instead of accessing the `tension` field directly
        /// to ensure the value stays within its bounds.
        pub fn setTension(segment: *Segment, tension: f32) void {
            segment.tension = std.math.clamp(tension, 0.0, 1.0);
        }
    };

    pub const Builder = struct {
        pool: Path.Builder.Pool,
        segment_lists: [Path.max_subpath_count]Path.Segment.List,
        segment_count: usize,


        const SegmentNode = Path.Segment.List.Inner.Node;
        const Pool = std.heap.MemoryPool(SegmentNode);


        pub fn init(allocator: Allocator) Allocator.Error!Path.Builder {
            var b: Path.Builder = undefined;
            b.pool = Path.Builder.Pool.init(allocator);
            errdefer b.pool.deinit();

            for (&b.segment_lists, 0..) |*list, id| {
                list.* = .{
                    .inner = .{},
                    .direction = .natural,
                };

                const first = try b.pool.create();
                first.* = .{
                    .data = .{
                        .segment = .{
                            .start = Vec2D.zero,
                            .tension = 0.0,
                        },
                        .list_id = @intCast(id),
                    },
                };
                list.inner.prepend(first);

                const last = try b.pool.create();
                last.* = .{
                    .data = .{
                        .segment = .{
                            .start = Vec2D.zero,
                            .tension = 0.0,
                        },
                        .list_id = @intCast(id),
                    },
                };
                list.inner.append(last);
            }

            b.segment_count = 0;
            return b;
        }

        pub fn initFromPath(allocator: Allocator, path: Path) Allocator.Error!Path.Builder {
            var b: Path.Builder = undefined;
            b.pool = Path.Builder.Pool.init(allocator);
            errdefer b.pool.deinit();

            b.segment_count = 0;

            for (path.subpaths, 0..) |subpath, id| {
                b.segment_lists[id] = .{
                    .inner = .{},
                    .direction = .natural,
                };
                const slc = subpath.slice();
                for (0..slc.len) |i| {
                    const node = try b.pool.create();
                    node.* = .{
                        .data = .{
                            .segment = slc.get(i),
                            .list_id = @intCast(id),
                        },
                    };
                    b.segment_lists[id].inner.append(node);
                }
                b.segment_count += (subpath.len-2);
            }

            for (path.subpaths.len..Path.max_subpath_count) |id| {
                const list = &b.segment_lists[id];
                list.* = .{
                    .inner = .{},
                    .direction = .natural,
                };

                const first = try b.pool.create();
                first.* = .{
                    .data = .{
                        .segment = .{
                            .start = Vec2D.zero,
                            .tension = 0.0,
                        },
                        .list_id = @intCast(id),
                    },
                };
                list.inner.prepend(first);

                const last = try b.pool.create();
                last.* = .{
                    .data = .{
                        .segment = .{
                            .start = Vec2D.zero,
                            .tension = 0.0,
                        },
                        .list_id = @intCast(id),
                    },
                };
                list.inner.append(last);
            }

            return b;
        }

        pub fn reset(b: *Path.Builder) void {
            for (&b.segment_lists) |*list| {
                var node = list.inner.first.?.next;
                while (node != list.inner.last) {
                    const to_be_destroyed = node.?;
                    node = to_be_destroyed.next;
                    b.pool.destroy(to_be_destroyed);
                }
                list.inner.first.?.next = list.inner.last;
                list.inner.last.?.prev = list.inner.first;
            }
            b.segment_count = 0;
        }

        pub fn resetSubpath(b: *Path.Builder, path_id: u32) void {
            const list = &b.segment_lists[path_id];
            var node = list.inner.first.?.next;
            while (node != list.inner.last) {
                const to_be_destroyed = node.?;
                node = to_be_destroyed.next;
                b.pool.destroy(to_be_destroyed);
                b.segment_count -= 1;
            }
            list.inner.first.?.next = list.inner.last;
            list.inner.last.?.prev = list.inner.first;
        }

        pub fn deinit(b: *Path.Builder) void {
            b.pool.deinit();
            b.* = undefined;
        }

        pub fn finalize(b: *Path.Builder, allocator: Allocator) Allocator.Error!Path {
            assert(b.segment_count == b.countSegments());

            var subpath_count: usize = 0;
            var subpath_buffer_size: usize = 0;
            for (&b.segment_lists) |*list| {
                if (list.inner.len > 2) {
                    subpath_count += 1;
                    const local_segment_count = Path.Subpath.requiredByteSize(list.inner.len);
                    subpath_buffer_size += mem.alignForward(usize, local_segment_count, @alignOf(Path.Segment));
                }
            }

            const subpath_size = (subpath_count * @sizeOf(Path.Subpath));
            const subpath_size_aligned = mem.alignForward(usize, subpath_size, @alignOf(Path.Segment));
            const raw_size = subpath_size_aligned + subpath_buffer_size;

            const raw = try allocator.alignedAlloc(u8, Path.mem_align, raw_size);
            errdefer allocator.free(raw);

            const subpaths = @as([*]Path.Subpath, @ptrCast(@alignCast(raw.ptr)))[0..subpath_count];
            var buffer_memory = std.heap.FixedBufferAllocator.init(raw[subpath_size_aligned..raw.len]);
            const buffer_allocator = buffer_memory.allocator();

            var subpath_idx: usize = 0;
            for (&b.segment_lists) |*list| {
                const count = list.inner.len;
                if (count > 2) {
                    const required = Path.Subpath.requiredByteSize(count);
                    const buffer = buffer_allocator.alignedAlloc(u8, @alignOf(Path.Segment), required) catch unreachable;
                    subpaths[subpath_idx] = Path.Subpath.init(buffer);
                    defer subpath_idx += 1;

                    var i: usize = 0;
                    var node: ?*SegmentNode, const next_offset: usize = switch (list.direction) {
                        .natural => .{ list.inner.first, @offsetOf(SegmentNode, "next") },
                        .reverse => .{ list.inner.last, @offsetOf(SegmentNode, "prev") },
                    };
                    while (node) |n| : ({
                        node = @as(*?*SegmentNode, @ptrFromInt(@intFromPtr(n) + next_offset)).*;
                        i += 1;
                    }) {
                        subpaths[subpath_idx].set(i, n.data.segment);
                    }
                    assert(i == count);
                }
            }
            assert(buffer_memory.end_index == buffer_memory.buffer.len);

            const path = Path{
                .subpaths = @ptrCast(subpaths),
            };

            b.deinit();
            return path;
        }

        pub fn reverseSubpath(b: *Path.Builder, path_id: u32) void {
            b.segment_lists[path_id].direction.flip();
        }

        // TODO find better way to address segments (tree?)
        pub fn addSegment(
            b: *Path.Builder,
            start: Vec2D,
            lhs: *SegmentNode,
            rhs: *SegmentNode,
        ) Allocator.Error!void {
            assert(b.segment_count < Path.max_segment_count);
            assert(lhs.data.list_id == rhs.data.list_id);

            const list_id = lhs.data.list_id;

            const node = try b.pool.create();
            node.data = .{
                .segment = .{
                    .start = start,
                    .tension = 0.0,
                },
                .list_id = list_id,
            };

            const prev = if (lhs.next == rhs)
                lhs
            else if (rhs.next == lhs)
                rhs
            else
                unreachable;

            b.segment_lists[list_id].inner.insertAfter(prev, node);
            b.segment_count += 1;

            b.fixEnds(list_id);
        }

        pub fn removeSegment(b: *Path.Builder, node: *SegmentNode) void {
            const list_id = node.data.list_id;
            b.segment_lists[list_id].inner.remove(node);
            b.segment_count -= 1;
            b.pool.destroy(node);
            b.fixEnds(list_id);
        }

        pub fn editSegment(
            b: *Path.Builder,
            node: *SegmentNode,
            comptime field: Path.Segment.Field,
            new_value: @FieldType(Path.Segment, @tagName(field)),
        ) void {
            comptime switch (field) {
                .start => {
                    node.data.segment.start = new_value;
                    b.fixEnds(node.data.list_id);
                },
                .tension => {
                    node.data.segment.setTension(new_value);
                },
            };
        }

        fn fixEnds(b: *Path.Builder, list_id: u32) void {
            if (b.segment_lists[list_id].inner.len < 4) {
                return;
            }

            const first = b.segment_lists[list_id].inner.first.?;
            const f_to = first.next.?;
            const f_from = f_to.next.?;

            first.data.segment = Path.Builder.extrapolate(f_from.data.segment, f_to.data.segment);

            const last = b.segment_lists[list_id].inner.last.?;
            const l_to = last.prev.?;
            const l_from = l_to.prev.?;

            last.data.segment = Path.Builder.extrapolate(l_from.data.segment, l_to.data.segment);
        }

        fn extrapolate(from: Path.Segment, to: Path.Segment) Path.Segment {
            const p = from.start;
            const q = to.start;
            const ext = p.lerp(q, 2.0);
            return .{
                .start = ext,
                .tension = 0.0,
            };
        }

        fn countSegments(b: *const Path.Builder) usize {
            var count: usize = 0;
            for (&b.segment_lists) |*list| {
                count += (list.inner.len-2);
            }
            return count;
        }
    };
};


test "build Path" {
    const allocator = testing.allocator;
    var b = try Path.build(allocator);
    errdefer b.deinit();

    const p1 = Vec2D{ .x = 5.0, .y = 5.0 };
    const p2 = Vec2D{ .x = 2.0, .y = 3.0 };

    try b.addSegment(p1, b.segment_lists[0].inner.last.?, b.segment_lists[0].inner.first.?);
    try b.addSegment(p2, b.segment_lists[0].inner.first.?, b.segment_lists[0].inner.first.?.next.?);
    b.removeSegment(b.segment_lists[0].inner.last.?.prev.?);

    var path = try b.finalize(testing.allocator);
    defer path.deinit(testing.allocator);

    const points = path.subpaths[0].items(.start);
    try testing.expectEqual(p2, points[1]);
}
