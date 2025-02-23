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

// Data flow:
// raw points on path -> calc segment for every point, create event for every segment change

pub const Event = struct {
    value: f32,
    id: u32,

    pub fn lessThan(_: void, a: Event, b: Event) bool {
        return (a.value < b.value);
    }
};

// TODO move
pub const Window = struct {
    width: f32,
    height: f32,

    width_normalized: f32,
    height_normalized: f32,

    horizontal_segment_count: u32,
    vertical_segment_count: u32,

    total_segment_count: u32,

    pub fn init(width: f32, height: f32, horizontal_segment_count: f32, vertical_segment_count: f32) Window {}

    // consider passing arena as allocator and reusing arena for every subpath
    pub fn createEvents(self: Window, allocator: Allocator, path: []const Vec2D, max_entity_radius: f32) Allocator.Error![]const Event {
        var active_segments = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(allocator, self.total_segment_count);
        defer active_segments.deinit(allocator);

        var events = std.ArrayListUnmanaged(Event).empty;
        errdefer events.deinit(allocator);

        var event_starts = try allocator.alloc(f32, self.total_segment_count);
        defer allocator.free(event_starts);
        @memset(event_starts, -1.0);

        // PLAN: populate new bitset for every point, cmp to current bitset, create events for all diffs, set current bitset to new bitset
        // solve with single iteration?

        const min_angle = 0.9 * math.acos(@as(f32, 1.0) - @as(f32, 1.0) / max_entity_radius);

        for (path, 0..) |p, i| {
            // 'draw' circle, https://stackoverflow.com/a/58629898/20378526
            var d: Vec2D = undefined;
            var angle: f32 = 0.0;
            while (angle <= 360.0) : (angle += min_angle) {
                d.x = max_entity_radius * @cos(angle);
                d.y = max_entity_radius * @sin(angle);
                const hashed = self.hash(d.add(p));
                active_segments.set(hashed);
            }

            // 'fill' circle and register identified segments
            var iter = active_segments.iterator(.{});

            var curr = iter.next() orelse continue;
            var curr_hseg: usize = curr % self.vertical_segment_count;

            while (iter.next()) |next| {
                const hseg = next % self.vertical_segment_count;
                // TODO rewrite logic to directly generate events
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
        }

        const owned = try events.toOwnedSlice(allocator);
        return owned;
    }

    /// R x R - - > 0..horizontal_seg_count x 0..vertical_seg_count ----> 0..total_seg_count
    inline fn hash(self: Window, point: Vec2D) u32 {
        const hnorm = point.x / self.width_normalized;
        const vnorm = point.y / self.height_normalized;
        const hseg: u32 = @intFromFloat(hnorm * comptime @as(f32, @floatFromInt(self.horizontal_segment_count)));
        const vseg: u32 = @intFromFloat(vnorm * comptime @as(f32, @floatFromInt(self.vertical_segment_count)));
        const hashed = hseg * self.vertical_segment_count + vseg;
        assert(hashed >= 0 and hashed < self.total_segment_count);
        return hashed;
    }
};
