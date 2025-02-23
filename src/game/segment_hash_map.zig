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
const Path = geo.path.Path;
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
        events: []const Event,

        pub const horizontal_seg_count = horizontal_segment_count;
        pub const vertical_seg_count = vertical_segment_count;
        pub const total_seg_count = horizontal_seg_count * vertical_seg_count;

        const Self = @This();

        pub const Event = struct {
            value: f32,
            id: u32,

            pub fn fromInterval(interval: Segment.Interval, id: u32) struct { Event, Event } {
                return .{
                    .{
                        .value = interval.start,
                        .id = id,
                    },
                    .{
                        .value = interval.end,
                        .id = id,
                    },
                };
            }

            pub fn lessThan(_: void, a: Event, b: Event) bool {
                return (a.value < b.value);
            }
        };

        pub const Segment = struct {
            interval: Interval,
            id: u32,

            pub const Interval = struct {
                start: f32,
                end: f32,

                pub const List = std.ArrayListUnmanaged(Interval);

                pub inline fn merge(a: Interval, b: Interval) Interval {
                    assert((a.start <= b.end and a.end >= b.start) or (b.start <= a.end and b.end >= a.start));
                    return .{
                        .start = @min(a.start, b.start),
                        .end = @max(a.end, b.end),
                    };
                }

                pub fn lessThanFn(_: void, a: Interval, b: Interval) bool {
                    return (a.start < b.start);
                }
            };

            const SortCtx = struct {
                intervals: []Segment.Interval,

                pub fn lessThan(ctx: SortCtx, a_index: usize, b_index: usize) bool {
                    return ((ctx.intervals[a_index].start < ctx.intervals[b_index].start) or ((ctx.intervals[a_index].start == ctx.intervals[b_index].start) and (ctx.intervals[a_index].end < ctx.intervals[b_index].end)));
                }
            };

            pub const List = stdx.StaticMultiArrayList(Segment);

            // TODO test
            pub fn init(allocator: Allocator, interval_lists: []Interval.List) Allocator.Error!Segment {
                const slices_size_aligned = mem.alignForward(usize, (interval_lists.len * @sizeOf([]const Interval)), @alignOf(Interval));
                var raw_size = slices_size_aligned;
                for (interval_lists) |list| {
                    sort.pdq(Interval, list.items, {}, Interval.lessThanFn);
                    var i: usize, var j: usize = .{ 0, 1 };
                    while (j < list.items.len) : ({
                        i += 1;
                        j += 1;
                    }) {
                        if (list.items[i].end >= list.items[j].start) {
                            const other = list.orderedRemove(j);
                            list.items[i] = list.items[i].merge(other);
                        }
                    }
                    assert(sort.isSorted(Interval, list.items, {}, Interval.lessThanFn));
                    raw_size += (list.items.len * @sizeOf(Interval));
                }
                const raw = try allocator.alignedAlloc(u8, @alignOf([]const Interval), raw_size);
                errdefer allocator.free(raw);

                const interval_slices = @as([*][]Interval, @ptrCast(@alignCast(raw.ptr)))[0..interval_lists.len];
                var interval_memory = std.heap.FixedBufferAllocator.init(raw[slices_size_aligned..raw.len]);
                const interval_allocator = interval_memory.allocator();

                for (interval_lists, interval_slices) |list, *slice| {
                    const interval_slice = interval_allocator.dupe(Interval, list.items) catch unreachable;
                    slice.* = interval_slice;
                }
                assert(interval_memory.end_index == interval_memory.buffer.len);

                return .{
                    .intervals = @ptrCast(interval_slices),
                };
            }

            pub fn deinit(segment: *Segment, allocator: Allocator) void {
                var raw_size = mem.alignForward(usize, (segment.intervals.len * @sizeOf([]const Interval)), @alignOf(Interval));
                for (segment.intervals) |slice| {
                    raw_size += (slice.len * @sizeOf(Interval));
                }
                const raw = @as([*]u8, @ptrCast(@constCast(segment.intervals.ptr)))[0..raw_size];
                allocator.free(raw);
                segment.* = undefined;
            }
        };

        const BitSet = std.bit_set.StaticBitSet(total_seg_count);

        const Builder = struct { // TODO rewrite without builder
            allocator: Allocator,
            can_collide: [total_seg_count]std.bit_set.DynamicBitSetUnmanaged,
            interval_lists: [total_seg_count]Segment.Interval.List,

            pub fn init(allocator: Allocator) Builder {
                return .{
                    .allocator = allocator,
                    .can_collide = [_]std.bit_set.DynamicBitSetUnmanaged{.{}} ** total_seg_count,
                    .interval_lists = [_]Segment.Interval.List{Segment.Interval.List.empty} ** total_seg_count,
                };
            }

            pub fn deinit(b: *Builder) void {
                comptime assert(b.interval_lists.len == b.can_collide.len);
                for (&b.can_collide, &b.interval_lists) |*set, *list| {
                    set.deinit(b.allocator);
                    list.deinit(b.allocator);
                }
                b.* = undefined;
            }

            pub fn analyzePaths(b: *Builder, paths: [][]Vec2D, max_entity_radius: f32) Allocator.Error!void {
                // identify all segments that can contain a part of an entity at point p
                var is_in_segment = BitSet.initEmpty();

                var total_paths_len: usize = 0;
                for (paths) |path| {
                    total_paths_len += path.len;
                }

                for (&b.can_collide) |*set| {
                    errdefer {
                        var i: usize = 0;
                        var errset = &b.can_collide[i];
                        while (errset != set) : ({
                            i += 1;
                            errset = &b.can_collide[i];
                        }) {
                            errset.deinit(b.allocator);
                        }
                    }
                    try set.initEmpty(b.allocator, total_paths_len);
                }
                errdefer for (&b.can_collide) |*set| {
                    set.deinit(b.allocator);
                };

                const min_angle = 0.9 * math.acos(@as(f32, 1.0) - @as(f32, 1.0) / max_entity_radius);

                var offset: usize = 0;
                for (paths) |subpath| {
                    defer offset += subpath.len;
                    for (subpath, 0..) |p, i| {
                        // 'draw' circle, https://stackoverflow.com/a/58629898/20378526
                        var d: Vec2D = undefined;
                        var angle: f32 = 0.0;
                        while (angle <= 360.0) : (angle += min_angle) {
                            d.x = max_entity_radius * @cos(angle);
                            d.y = max_entity_radius * @sin(angle);
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
                                for (curr..(next + 1)) |seg| {
                                    b.can_collide[seg].set(offset + i);
                                }
                            } else {
                                b.can_collide[curr].set(offset + i);
                            }
                            curr = next;
                            curr_hseg = hseg;
                        }

                        is_in_segment.unsetAll();
                    }
                }
            }

            pub fn makeIntervals2(b: *Builder, tstep: f32) Allocator.Error!void {
                for (&b.can_collide, &b.interval_lists) |*set, *list| {
                    errdefer {
                        var i: usize = 0;
                        var errlist = &b.interval_lists[i];
                        while (errlist != list) : ({
                            i += 1;
                            errlist = &b.interval_lists[i];
                        }) {
                            errlist.clearAndFree(b.allocator);
                        }
                        list.clearAndFree(b.allocator);
                    }

                    var iter = set.iterator(.{});
                    var curr = iter.next() orelse continue;
                    var start = curr;
                    while (iter.next()) |next| {
                        if ((curr + 1) != next) {
                            const interval = Segment.Interval{
                                .start = tstep * @as(f32, @floatFromInt(start)),
                                .end = tstep * @as(f32, @floatFromInt(curr)),
                            };
                            try list.append(b.allocator, interval);

                            start = next;
                        }
                        curr = next;
                    }
                }
            }

            pub fn makeIntervals(b: *Builder) Allocator.Error!void {
                // TODO:
            }

            fn addPath(b: *Builder, path: []Vec2D) Allocator.Error!void {
                // identify all segments that can contain a part of an entity at point p
                var is_in_segment = BitSet.initEmpty();

                for (&b.can_collide) |*set| {
                    errdefer {
                        var i: usize = 0;
                        var errset = &b.can_collide[i];
                        while (errset != set) : ({
                            i += 1;
                            errset = &b.can_collide[i];
                        }) {
                            errset.deinit(b.allocator);
                        }
                    }
                    try set.initEmpty(b.allocator, path.points.len);
                }
                errdefer for (&b.can_collide) |*set| {
                    set.deinit(b.allocator);
                };
                const min_angle = 0.9 * math.acos(@as(f32, 1.0) - @as(f32, 1.0) / b.max_entity_radius);

                for (path, 0..) |p, i| {
                    // 'draw' circle, https://stackoverflow.com/a/58629898/20378526
                    var d: Vec2D = undefined;
                    var angle: f32 = 0.0;
                    while (angle <= 360.0) : (angle += min_angle) {
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
                            for (curr..(next + 1)) |seg| {
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

            // PLAN
            // desired memory layout:
            // [Interval 0..a] [Interval a..b] [Interval b..c]
            // required info for each interval:
            // - start + end
            // - segment id
            //
            // EVENT SWEEP:
            // bitmap keeps track of active segments
            // alle intervalle schon gemerged also keine überlappungen
            // -> bitmap[id] = @intFromEnum(kind)
            // bzw optimization: Event hat implizite Kind, flippt einfach jedes mal bit

            /// Accessing `b` after calling this function is undefined behaviour.
            /// Reinitialize `b` if you want to reuse it.
            /// Calling `deinit` after this function is unnecessary, but allowed.
            pub fn finalize(b: *Builder) Allocator.Error!Self {
                var events = std.ArrayListUnmanaged(Event).empty;
                errdefer events.deinit(b.allocator);

                for (&b.interval_lists, 0..) |*list, id| {
                    for (list.items) |interval| {
                        const start, const end = Event.fromInterval(interval, id);
                        try events.appendSlice(b.allocator, &.{ start, end });
                    }
                    list.deinit(b.allocator);
                }
                for (&b.can_collide) |*set| {
                    set.deinit(b.allocator);
                }

                const owned_events = try events.toOwnedSlice(b.allocator);
                sort.pdq(Event, owned_events, {}, Event.lessThan);

                const self = Self{
                    .allocator = b.allocator,
                    .events = owned_events,
                };

                b.* = undefined;
                return self;
            }
        };

        pub fn init(allocator: Allocator, paths: [][]Vec2D, max_entity_radius: f32) Allocator.Error!Self {
            var b = Builder.init(allocator);
            errdefer b.deinit();

            try b.analyzePaths(paths, max_entity_radius);
            try b.makeIntervals();

            const self = try b.finalize();
            return self;
        }

        /// R x R - - > 0..horizontal_seg_count x 0..vertical_seg_count ----> 0..total_seg_count
        inline fn hash(point: Vec2D) u32 {
            const hnorm = point.x / width_normalized;
            const vnorm = point.y / height_normalized;
            const hseg: u32 = @intFromFloat(hnorm * comptime @as(f32, @floatFromInt(horizontal_seg_count)));
            const vseg: u32 = @intFromFloat(vnorm * comptime @as(f32, @floatFromInt(vertical_seg_count)));
            const hashed = hseg * vertical_seg_count + vseg;
            assert(hashed >= 0 and hashed < total_seg_count);
            return hashed;
        }

        pub fn sweep(self: Self, goons: *Goon.Block.List) void {
            for (goons.ref_list.items) |maybe_block| { // TODO dispatch every block as task
                if (maybe_block) |block| {
                    if (block.hasAlive()) {
                        block.sort();
                        self.walkEvents(block);
                    }
                }
            }
        }
        inline fn walkEvents(self: Self, block: *Goon.Block) void {
            const t_vals = block.mutable_list.items(.t);
            var idx: usize = 0;
            var is_active = BitSet.initEmpty();
            for (self.events) |event| {
                is_active.toggle(event.id);
                var iter: is_active.Iterator(.{}) = undefined;
                while (t_vals[idx] <= event.value) : (idx += 1) { // TODO: <= or < ???
                    iter = is_active.iterator(.{});
                    while (iter.next()) |i| {
                        // TODO: check collisions here
                    }
                }
            }
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
