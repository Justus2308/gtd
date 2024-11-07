const std = @import("std");
const raylib = @import("raylib");
const raymath = raylib.math;

const Rectangle = raylib.Rectangle;
const Vector2 = raylib.Vector2;


/// `BitSet` layout: `[h0v0,h0v1,...,h0vn, h1v0,h1v1,...,h1vn, ..., hnv0,hnv1,...,hnvn]`
pub const CollisionMap = struct {
    bits: BitSet,
    h_pps: f32,
    v_pps: f32,
    

    pub const horizontal_seg_count = 16;
    pub const vertical_seg_count = 8;
    pub const total_seg_count = horizontal_seg_count * vertical_seg_count;

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

    pub fn mapPositions(map: *CollisionMap, positions: []Vector2, radius: f32) void {
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
                        map.bits.set((h_seg * vertical_seg_count) + v_seg);
                    }
                }
            }
        }
    }

    pub fn merge(map: *CollisionMap, with: CollisionMap) void {
        map.bits.setUnion(with);
    }

    pub fn needsCollisionCheck(map: *const CollisionMap, collider: Rectangle) bool {
        const h_seg_min: usize = @intFromFloat(@divFloor(collider.x, horizontal_seg_count));
        const h_seg_max: usize = @intFromFloat(std.math.divCeil(collider.x + collider.width, horizontal_seg_count) catch unreachable);

        const v_seg_min: usize = @intFromFloat(@divFloor(collider.y, vertical_seg_count));
        const v_seg_max: usize = @intFromFloat(std.math.divCeil(collider.y + collider.height, vertical_seg_count) catch unreachable);

        var collisions = BitSet.initEmpty();
        for (h_seg_min..h_seg_max) |h_seg| {
            const offset = (h_seg * vertical_seg_count);
            collisions.setRangeValue(.{ offset+v_seg_min, offset+v_seg_max+1 }, true);
        }
        return (map.bits.intersectWith(collisions).count() > 0);
    }
};
