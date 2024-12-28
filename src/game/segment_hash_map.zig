const std = @import("std");
const raylib = @import("raylib");
const entities = @import("entities");
const game = @import("game");

const math = std.math;
const mem = std.mem;
const sort = std.sort;

const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Goon = entities.Goon;
const Vector2 = raylib.Vector2;

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
                start: f32, // TODO save indices here?
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
            can_collide: [total_seg_count]Path.BitSet,
            interval_lists: [total_seg_count]Segment.Interval.List,
            max_entity_radius: f32,
            min_angle: f32,

            pub fn init(allocator: Allocator, max_entity_radius: f32) Builder {
                return .{
                    .allocator = allocator,
                    .can_collide = [_]Path.BitSet{comptime BitSet.initEmpty()}**total_seg_count,
                    .interval_lists = [_]Segment.Interval.List{Segment.Interval.List.empty}**total_seg_count,
                    .max_entity_radius = max_entity_radius,
                    .min_angle = 0.9 * math.acos(@as(f32, 1.0) - @as(f32, 1.0)/max_entity_radius),
                };
            }

            pub fn deinit(b: *Builder) void {
                for (b.interval_lists) |list| {
                    list.deinit(b.allocator);
                }
                b.* = undefined;
            }

            pub fn analyzePath(b: *Builder, path: Path) void {
                // identify all segments that can contain a part of an entity at point p
                var is_in_segment = BitSet.initEmpty();

                for (path.points, 0..) |p, i| {
                    // 'draw' circle, https://stackoverflow.com/a/58629898/20378526
                    var d: Vector2 = undefined;
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
                for (&b.can_collide, &b.interval_lists) |*coll, *ilist| {
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

                    var iter = coll.iterator(.{});
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
                    errdefer for (0..i) |j| {
                        b.interval_lists[j] = Segment.Interval.List.fromOwnedSlice(self.segments[j].intervals);
                        self.segments[j].intervals = undefined;
                    };
                    self.segments[i] = .{
                        .intervals = try ilist.toOwnedSlice(b.allocator),
                    };
                }
                b.* = undefined;
                return self;
            }
        };


        //tmp
        const Path = struct {
            points: []Vector2,
            tstep: f32,

            pub const sample_count = 1024;
            pub const BitSet = std.bit_set.StaticBitSet(sample_count);
        };
        // pub fn init2(allocator: Allocator, path: Path) Self {
        //     const tstep = {};

        //     var interval_lists = [_]Segment.Interval.List{Segment.Interval.List.empty}**total_seg_count;

        //     var interval: Segment.Interval = .{
        //         .start = path.points[0],
        //         .end = path.points[0],
        //     };
        //     var is_in_segment = BitSet.initEmpty();
        //     var last_hash = hash(interval.start);

        //     for (path.points[1..path.points.len]) |point| {
        //         const hashed = hash(point);
        //         if (hashed != last_hash) { // TODO expand segment
        //             var iter = is_in_segment.iterator();
        //             while (iter.next(.{})) |idx| {
        //                 interval_lists[idx].append(allocator, interval);
        //             }
        //             interval.start = point;
        //             is_in_segment.unsetAll();
        //         }
        //         is_in_segment.set(hashed);
        //         interval.end = point;
        //         last_hash = hashed;
        //     }
        // }
        pub fn init(allocator: Allocator, path: Path, max_entity_radius: f32) Allocator.Error!Self {
            var b = Builder.init(allocator, max_entity_radius);
            errdefer b.deinit();

            b.analyzePath(path);
            try b.makeIntervals(path.tstep);

            const self = try b.finalize();
            return self;
        }


        /// R x R - - > 0..horizontal_seg_count x 0..vertical_seg_count ----> 0..total_seg_count
        inline fn hash(point: Vector2) u32 {
            const hnorm = point.x / width_normalized;
            const vnorm = point.y / height_normalized;
            const hseg: u32 = @intFromFloat(hnorm * comptime @as(f32, @floatFromInt(horizontal_seg_count)));
            const vseg: u32 = @intFromFloat(vnorm * comptime @as(f32, @floatFromInt(vertical_seg_count)));
            const hashed = hseg*vertical_seg_count + vseg;
            assert(hashed >= 0 and hashed < total_seg_count);
            return hashed;
        }

        pub fn update(self: *Self, game_state: *game.State) void {
            // TODO get all entities from game_state
            for (self.entities.items) |*entity| {
                entity.*.t = game_state.goon_blocks.getGoonAttr(entity.idx, .t);
            }
            sort.pdq(Entity, self.entities.items, {}, entityLessThanFn);
        }
        fn entityLessThanFn(_: void, a: Entity, b: Entity) bool {
            return (a.t < b.t);
        }
    };
}
