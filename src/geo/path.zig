const std = @import("std");
const geo = @import("geo");

const mem = std.mem;

const Allocator = mem.Allocator;
const Vec2D = geo.points.Vec2D;

const assert = std.debug.assert;


pub const Path = struct {
    subpaths_raw: [max_subpath_count][]Segment,
    subpath_count: usize,


    pub const max_subpath_count = 8;
    pub const max_segment_count = 64;


    pub inline fn build(allocator: Allocator) Path.Builder {
        return Path.Builder.init(allocator);
    }

    /// Invalidates `path`.
    pub inline fn edit(path: *Path, allocator: Allocator) Path.Builder {
        return Path.Builder.initFromPath(allocator, path);
    }

    pub fn deinit(path: *Path, allocator: Allocator) void {
        var segment_count = 0;
        for (path.subpaths()) |subpath| {
            segment_count += subpath.len;
        }
        const raw = path.subpaths_raw[0].ptr[0..segment_count];
        allocator.free(raw);
    }

    pub inline fn subpaths(path: *const Path) [][]Segment {
        return path.subpaths_raw[0..path.subpath_count];
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
            };
        };

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
                        .list_id = id,
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
                        .list_id = id,
                    },
                };
                list.inner.append(last);
            }

            b.segment_count = 0;
            return b;
        }

        pub fn initFromPath(allocator: Allocator, path: *Path) Allocator.Error!Path.Builder {
            var b: Path.Builder = undefined;
            b.pool = Path.Builder.Pool.init(allocator);
            errdefer b.pool.deinit();

            b.segment_count = 0;

            for (path.subpaths(), 0..) |subpath, id| {
                b.segment_lists[id] = .{
                    .inner = .{},
                    .direction = .natural,
                };
                for (subpath) |segment| {
                    const node = try b.pool.create();
                    node.* = .{
                        .data = .{
                            .segment = segment,
                            .list_id = id,
                        },
                    };
                    b.segment_lists[id].inner.append(node);
                }
                b.segment_count += (subpath.len-2);
            }

            for (path.subpaths().len..Path.max_subpath_count) |id| {
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
                        .list_id = id,
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
                        .list_id = id,
                    },
                };
                list.inner.append(last);
            }

            path.deinit(allocator);
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

        pub fn finalize(b: *Path.Builder) Allocator.Error!Path {
            assert(b.segment_count == b.countSegments());

            var real_segment_count = b.segment_count;
            for (&b.segment_lists) |*list| {
                if (list.inner.len > 2) {
                    real_segment_count += 2;
                }
            }

            const allocator = b.pool.arena.child_allocator;
            const raw = try allocator.alloc(Segment, real_segment_count);
            errdefer allocator.free(raw);

            var path = Path{
                .subpaths_raw = undefined,
                .subpath_count = 0,
            };

            var raw_idx: usize = 0;
            for (&b.segment_lists) |*list| {
                const count = list.inner.len;
                if (count > 2) {
                    path.subpaths_raw[path.subpath_count] = raw[raw_idx..][0..count];
                    path.subpath_count += 1;
                    raw_idx += count;
                }
            }
            assert(raw_idx == real_segment_count);

            b.deinit();
            return path;
        }

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
            if (lhs.next == rhs) {
                b.segment_lists[list_id].inner.insertAfter(lhs, node);
            } else {
                assert(rhs.next == lhs);
                b.segment_lists[list_id].inner.insertBefore(lhs, node);
            }
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

        pub fn moveSegment(b: *Path.Builder, node: *SegmentNode, new_start: Vec2D) void {
            node.data.segment.start = new_start;
            b.fixEnds(node.data.list_id);
        }

        pub fn retensionSegment(b: *Path.Builder, node: *SegmentNode, new_tension: f32) void {
            _ = b;
            node.data.segment.setTension(new_tension);
        }

        fn fixEnds(b: *Path.Builder, list_id: u32) void {
            if (b.segment_lists[list_id].inner.len < 4) {
                return;
            }

            const first = b.segment_lists[list_id].inner.first.?;
            const f_to = first.next.?;
            const f_from = f_to.next.?;

            first.data.segment = Path.Builder.extrapolate(f_from, f_to);

            const last = b.segment_lists[list_id].inner.last.?;
            const l_to = last.prev.?;
            const l_from = l_to.prev.?;

            last.data.segment = Path.Builder.extrapolate(l_from, l_to);
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
