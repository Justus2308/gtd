const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");

const Vec2D = geo.points.Vec2D;

const assert = std.debug.assert;


/// `BitSet` layout: `[h0v0,h0v1,...,h0vn, h1v0,h1v1,...,h1vn, ..., hnv0,hnv1,...,hnvn]`
pub const CollisionMap = struct {
    bits: BitSet,
    h_pps: f32,
    v_pps: f32,

    // pps ~ pixels per segment


    pub const horizontal_seg_count = 16;
    pub const vertical_seg_count = 8;
    pub const total_seg_count = horizontal_seg_count * vertical_seg_count;

    comptime {
        assert(total_seg_count > 0);
    }

    const BitSet = std.bit_set.StaticBitSet(total_seg_count);


    pub fn init(screen_width: u32, screen_height: u32) CollisionMap {
        const h_pps: f32 = @as(f32, @floatFromInt(screen_width)) / @as(f32, @floatFromInt(horizontal_seg_count));
        const v_pps: f32 = @as(f32, @floatFromInt(screen_height)) / @as(f32, @floatFromInt(vertical_seg_count));
        return .{
            .bits = BitSet.initEmpty(),
            .h_pps = h_pps,
            .v_pps = v_pps,
        };
    }

    pub fn updateScreenDims(map: *CollisionMap, screen_width: u32, screen_height: u32) void {
        map.h_pps = @as(f32, @floatFromInt(screen_width)) / @as(f32, @floatFromInt(horizontal_seg_count));
        map.v_pps = @as(f32, @floatFromInt(screen_height)) / @as(f32, @floatFromInt(vertical_seg_count));
    }

    pub fn mapPositions(map: *CollisionMap, positions: []Vec2D, radius: f32) void {
        for (positions) |position| {
            for (0..horizontal_seg_count) |h_seg| {
                const h_seg_fp: f32 = @floatFromInt(h_seg);
                for (0..vertical_seg_count) |v_seg| {
                    const v_seg_fp: f32 = @floatFromInt(v_seg);
                    const segment = Rectangle{
                        .x = h_seg_fp * map.h_pps,
                        .y = v_seg_fp * map.v_pps,
                        .width = map.h_pps,
                        .height = map.v_pps,
                    };
                    if (raylib.checkCollisionCircleRec(position, radius, segment)) {
                        map.bits.set(segmentIdx(h_seg, v_seg));
                    }
                }
            }
        }
    }

    pub fn merge(map: *CollisionMap, with: CollisionMap) void {
        map.bits.setUnion(with);
    }

    /// Check whether there are any registered goons in segment of pos
    pub fn needsCollisionCheck(map: *const CollisionMap, pos: Vec2D) bool {
        // const h_seg: usize = @intFromFloat(@divFloor(pos.x, @as(f32, @floatFromInt(horizontal_seg_count))));
        // const v_seg: usize = @intFromFloat(@divFloor(pos.y, @as(f32, @floatFromInt(vertical_seg_count))));
        const h_seg, const v_seg = segmentOfPosition(pos);
        return map.bits.isSet(segmentIdx(h_seg, v_seg));
    }

    inline fn segmentOfPosition(pos: Vec2D) struct {
        h_seg: usize,
        v_seg: usize,
    } {
        return .{
            .h_seg = @as(usize, @intFromFloat(pos.x)) / horizontal_seg_count,
            .v_seg = @as(usize, @intFromFloat(pos.y)) / vertical_seg_count,
        };
    }

    inline fn segmentIdx(h_seg: usize, v_seg: usize) usize {
        return (h_seg * vertical_seg_count) + v_seg;
    }
};
