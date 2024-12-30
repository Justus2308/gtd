const std = @import("std");
const stdx = @import("stdx");
const entities = @import("entities");
const geo = @import("geo");

const math = std.math;
const mem = std.mem;
const sort = std.sort;

const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Goon = entities.Goon;
const Vec2D = geo.points.Vec2D;

const assert = std.debug.assert;


pub fn SegmentHashMap(
    comptime width_normalized: f32,
    comptime height_normalized: f32,
    comptime horizontal_segment_count: u32,
    comptime vertical_segment_count: u32,
) type {
    comptime {
        if (horizontal_segment_count <= 0 or vertical_segment_count <= 0) {
            @compileError("segment counts need to be >0");
        }
    }
    return struct {
        allocator: Allocator,
        segments: [total_seg_count]Segment,
        entities: Entity.List,


        pub const horizontal_seg_count = horizontal_segment_count;
        pub const vertical_seg_count = vertical_segment_count;
        pub const total_seg_count = horizontal_seg_count * vertical_seg_count;

        const Self = @This();

        const Entity = struct {
            idx: u32,
            t: f32,

            pub const List = std.ArrayListUnmanaged(Entity);
        };

        pub const Segment = struct {
            intervals: []Interval,

            pub const Interval = struct {
                start: f32,
                end: f32,

                pub const List = std.ArrayListUnmanaged(Interval);

                pub inline fn merge(a: Interval, b: Interval) Interval {
                    assert((a.start <= b.end and a.end >= b.start)
                        or (b.start <= a.end and b.end >= a.start));
                    return .{
                        .start = @min(a.start, b.start),
                        .end = @max(a.end, b.end),
                    };
                }

                pub fn lessThanFn(_: void, a: Interval, b: Interval) bool {
                    return (a.start < b.start);
                }
            };

            pub fn init(allocator: Allocator, interval_list: Interval.List) Allocator.Error!Segment {
                const intervals = interval_list.items;
                sort.pdq(Interval, intervals, {}, Interval.lessThanFn);
                for (0..intervals.len-1, 1..) |i, j| {
                    if (intervals[i].end >= intervals[j].start) {
                        const other = interval_list.orderedRemove(j);
                        intervals[i] = intervals[i].merge(other);
                    }
                }
                const owned = interval_list.toOwnedSlice(allocator);
                assert(sort.isSorted(Interval, owned, {}, Interval.lessThanFn));
                return .{
                    .intervals = owned,
                };
            }

            pub fn deinit(segment: *Segment, allocator: Allocator) void {
                allocator.free(segment.intervals);
                segment.* = undefined;
            }
        };

        const BitSet = std.bit_set.StaticBitSet(total_seg_count);

        const Builder = struct {
            allocator: Allocator,
            can_collide: [total_seg_count]std.bit_set.DynamicBitSetUnmanaged,
            interval_lists: [total_seg_count]Segment.Interval.List,
            max_entity_radius: f32,
            min_angle: f32,

            pub fn init(allocator: Allocator, max_entity_radius: f32) Builder {
                return .{
                    .allocator = allocator,
                    .can_collide = [_]std.bit_set.DynamicBitSetUnmanaged{.{}}**total_seg_count,
                    .interval_lists = [_]Segment.Interval.List{Segment.Interval.List.empty}**total_seg_count,
                    .max_entity_radius = max_entity_radius,
                    .min_angle = 0.9 * math.acos(@as(f32, 1.0) - @as(f32, 1.0)/max_entity_radius),
                };
            }

            pub fn deinit(b: *Builder) void {
                comptime assert(b.interval_lists.len == b.can_collide.len);
                for (&b.can_collide, &b.interval_lists) |*cset, *ilist| {
                    cset.deinit(b.allocator);
                    ilist.deinit(b.allocator);
                }
                b.* = undefined;
            }

            pub fn analyzePath(b: *Builder, path: Path) Allocator.Error!void {
                // identify all segments that can contain a part of an entity at point p
                var is_in_segment = BitSet.initEmpty();

                for (&b.can_collide) |*cset| {
                    errdefer {
                        var i: usize = 0;
                        var errset = &b.can_collide[i];
                        while (errset != cset) : ({
                            i += 1;
                            errset = &b.can_collide[i];
                        }) {
                            errset.deinit(b.allocator);
                        }
                    }
                    try cset.initEmpty(b.allocator, path.points.len);
                }
                errdefer for (&b.can_collide) |*cset| {
                    cset.deinit(b.allocator);
                };

                for (path.points, 0..) |p, i| {
                    // 'draw' circle, https://stackoverflow.com/a/58629898/20378526
                    var d: Vec2D = undefined;
                    var angle: f32 = 0.0;
                    while (angle <= 360.0) : (angle += b.min_angle) {
                        d.x = b.max_entity_radius * @cos(angle);
                        d.y = b.max_entity_radius * @sin(angle);
                        const hashed = hash(d.add(p));
                        is_in_segment.set(hashed);
                    }

                    // 'fill' circle and register identified segments
                    var iter = is_in_segment.iterator(.{});

                    var curr = iter.next() orelse continue;
                    var curr_hseg: usize = curr % vertical_seg_count;

                    while (iter.next()) |next| {
                        const hseg = next % vertical_seg_count;
                        if (curr_hseg == hseg) {
                            for (curr..(next+1)) |seg| {
                                b.can_collide[seg].set(i);
                            }
                        } else {
                            b.can_collide[curr].set(i);
                        }
                        curr = next;
                        curr_hseg = hseg;
                    }

                    is_in_segment.unsetAll();
                }
            }

            pub fn makeIntervals(b: *Builder, tstep: f32) Allocator.Error!void {
                for (&b.can_collide, &b.interval_lists) |*cset, *ilist| {
                    errdefer {
                        var i: usize = 0;
                        var errlist = &b.interval_lists[i];
                        while (errlist != ilist) : ({
                            i += 1;
                            errlist = &b.interval_lists[i];
                        }) {
                            errlist.clearAndFree(b.allocator);
                        }
                        ilist.clearAndFree(b.allocator);
                    }

                    var iter = cset.iterator(.{});
                    var curr = iter.next() orelse continue;
                    var start = curr;
                    while (iter.next()) |next| {
                        if ((curr+1) != next) {
                            const interval = Segment.Interval{
                                .start = tstep * @as(f32, @floatFromInt(start)),
                                .end = tstep * @as(f32, @floatFromInt(curr)),
                            };
                            try ilist.append(b.allocator, interval);

                            start = next;
                        }
                        curr = next;
                    }
                }
            }

            /// Accessing `b` after calling this function is undefined behaviour.
            /// Reinitialize `b` if you want to reuse it.
            /// Calling `deinit` after this function is unnecessary, but allowed.
            pub fn finalize(b: *Builder) Allocator.Error!Self {
                var self = Self{
                    .allocator = b.allocator,
                    .entities = Entity.List.empty,
                    .segments = undefined,
                };
                for (&b.interval_lists, 0..) |*ilist, i| {
                    errdefer for (0..i) |e| {
                        b.interval_lists[e] = Segment.Interval.List.fromOwnedSlice(self.segments[e].intervals);
                        self.segments[e].intervals = undefined;
                    };
                    self.segments[i] = .{
                        .intervals = try ilist.toOwnedSlice(b.allocator),
                    };
                }
                for (&b.can_collide) |*cset| {
                    cset.deinit(b.allocator);
                }
                b.* = undefined;
                return self;
            }
        };


        //tmp
        const Path = struct {
            points: []Vec2D,
            tstep: f32,
        };

        pub fn init(allocator: Allocator, path: Path, max_entity_radius: f32) Allocator.Error!Self {
            var b = Builder.init(allocator, max_entity_radius);
            errdefer b.deinit();

            try b.analyzePath(path);
            try b.makeIntervals(path.tstep);

            const self = try b.finalize();
            return self;
        }


        /// R x R - - > 0..horizontal_seg_count x 0..vertical_seg_count ----> 0..total_seg_count
        inline fn hash(point: Vec2D) u32 {
            const hnorm = point.x / width_normalized;
            const vnorm = point.y / height_normalized;
            const hseg: u32 = @intFromFloat(hnorm * comptime @as(f32, @floatFromInt(horizontal_seg_count)));
            const vseg: u32 = @intFromFloat(vnorm * comptime @as(f32, @floatFromInt(vertical_seg_count)));
            const hashed = hseg*vertical_seg_count + vseg;
            assert(hashed >= 0 and hashed < total_seg_count);
            return hashed;
        }

        pub fn update(self: *Self, goons: *Goon.Block.List) void {
            // TODO get all entities from game_state
            for (self.entities.items) |*entity| {
                entity.*.t = goons.getGoonAttr(entity.idx, .t);
            }
            sort.pdq(Entity, self.entities.items, {}, entityLessThanFn);
        }
        fn entityLessThanFn(_: void, a: Entity, b: Entity) bool {
            return (a.t < b.t);
        }
    };
}
