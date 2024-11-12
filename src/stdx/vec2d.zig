const std = @import("std");
const stdx = @import("../stdx.zig");
const math = std.math;
const simd = std.simd;
const testing = std.testing;

const Aabb = stdx.Aabb;

const assert = std.debug.assert;
const vectorLength = stdx.vectorLength;

pub const Vec2D = extern struct {
    x: f32,
    y: f32,

    pub const zero: Vec2D = .{ .x = 0, .y = 0 };

    pub fn unit(angle_in_radians: f32) Vec2D {
        return .{
            .x = @cos(angle_in_radians),
            .y = @sin(angle_in_radians),
        };
    }

    pub fn scaled(v: Vec2D, scalar: f32) Vec2D {
        return .{
            .x = v.x * scalar,
            .y = v.y * scalar,
        };
    }

    pub fn add(v: *Vec2D, other: Vec2D) void {
        v.x += other.x;
        v.y += other.y;
    }

    pub fn sub(v: *Vec2D, other: Vec2D) void {
        v.x -= other.x;
        v.y -= other.y;
    }

    pub fn plus(v: Vec2D, other: Vec2D) Vec2D {
        return .{
            .x = v.x + other.x,
            .y = v.y + other.y,
        };
    }

    pub fn minus(v: Vec2D, other: Vec2D) Vec2D {
        return .{
            .x = v.x - other.x,
            .y = v.y - other.y,
        };
    }

    pub fn floored(v: Vec2D) Vec2D {
        return .{
            .x = @floor(v.x),
            .y = @floor(v.y),
        };
    }

    pub fn angle(v: Vec2D) f32 {
        if (v.lengthSqrd() == 0) {
            return 0;
        } else {
            return math.atan2(v.y, v.x);
        }
    }

    pub fn lengthSqrd(v: Vec2D) f32 {
        return v.x * v.x + v.y * v.y;
    }

    pub fn length(v: Vec2D) f32 {
        return @sqrt(v.lengthSqrd());
    }

    pub fn lengthMulti(
        vecs: anytype,
    ) @Vector(@divExact(vectorLength(@TypeOf(vecs)), 2), f32) {
        const vecs_sqrd = vecs * vecs;
        const vecs_sqrd_x, const vecs_sqrd_y = simd.deinterlace(2, vecs_sqrd);
        const lengths_sqrd = vecs_sqrd_x + vecs_sqrd_y;
        return @sqrt(lengths_sqrd);
    }

    pub fn distanceSqrd(v: Vec2D, other: Vec2D) f32 {
        const dx = other.x - v.x;
        const dy = other.y - v.y;
        return dx * dx + dy * dy;
    }

    pub fn distance(v: Vec2D, other: Vec2D) f32 {
        return @sqrt(v.distanceSqrd(other));
    }

    pub fn distanceMulti(
        v: Vec2D,
        others: anytype,
    ) @Vector(@divExact(vectorLength(@TypeOf(others)), 2), f32) {
        const delta_count = @divExact(vectorLength(@TypeOf(others)), 2);
        const deltas = others - v.splat(delta_count);
        const deltas_sqrd = deltas * deltas;
        const deltas_sqrd_x, const deltas_sqrd_y = simd.deinterlace(2, deltas_sqrd);
        const distances_sqrd = deltas_sqrd_x + deltas_sqrd_y;
        return @sqrt(distances_sqrd);
    }

    pub fn normalized(v: Vec2D) Vec2D {
        const len = v.length();
        if (len == 0) {
            return v;
        } else {
            return v.scaled(1.0 / len);
        }
    }
    pub fn normalizeMulti(vecs: anytype) @TypeOf(vecs) {
        const lengths = Vec2D.lengthMulti(vecs);
        const lengths_pairwise = simd.interlace(.{ lengths, lengths });
        const vecs_normalized = @select(f32,
            (lengths_pairwise == @as(@TypeOf(lengths_pairwise), @splat(0.0))),
            vecs,
            vecs * (@as(@TypeOf(lengths_pairwise), @splat(1.0)) / lengths_pairwise),
        );
        return vecs_normalized;
    }

    pub fn dot(v: Vec2D, other: Vec2D) f32 {
        return v.x * other.x + v.y * other.y;
    }

    pub fn checkCollisionCircle(v: Vec2D, center: Vec2D, radius: f32) bool {
        const distance_to_center = v.distance(center);
        return (distance_to_center <= radius);
    }
    pub fn checkCollisionAabb(v: Vec2D, aabb: Aabb) bool {
        return (v.x >= aabb.pos.x and v.x < aabb.pos.x+aabb.width
            and v.y >= aabb.pos.y and v.y < aabb.pos.y+aabb.height);
    }

    /// `centers` and `radiuses` have to be `@Vector`s of `f32` and
    /// |`centers`| needs to be 2*|`radiuses`| (interlaced `Vec2D`s).
    pub fn checkCollisionCircleMulti(
        v: Vec2D,
        centers: anytype,
        radiuses: anytype,
    ) @Vector(vectorLength(@TypeOf(radiuses)), bool) {
        const center_count = comptime switch (@typeInfo(@TypeOf(centers))) {
            inline .array, .vector => |info| blk: {
                if (info.child != f32)
                    @compileError("Invalid child type " ++ @typeName(info.child));
                break :blk info.len;
            },
            else => @compileError("Invalid type " ++ @typeName(@TypeOf(centers))),
        };
        const radius_count = comptime switch (@typeInfo(@TypeOf(radiuses))) {
            inline .array, .vector => |info| blk: {
                if (info.child != f32)
                    @compileError("Invalid child type " ++ @typeName(info.child));
                break :blk info.len;
            },
            else => @compileError("Invalid type " ++ @typeName(@TypeOf(centers))),
        };
        comptime if (center_count != 2*radius_count)
            @compileError("Needs same amount of centers and radiuses");

        const distances_to_center = v.distanceMulti(centers);
        return (distances_to_center <= radiuses);
    }

    pub inline fn splat(v: Vec2D, comptime count: comptime_int) @Vector(2*count, f32) {
        return simd.repeat(2*count, @as(@Vector(2, f32), @bitCast(v)));
    }


    test checkCollisionCircleMulti {
        const centers: @Vector(6, f32) = @bitCast([_]Vec2D{
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 1.0, .y = 1.0 },
            .{ .x = 0.0, .y = 5.0 },
        });
        const radiuses: @Vector(3, f32) = [_]f32{
            2.0,
            2.0,
            4.0,
        };

        const v1 = Vec2D{ .x = 0.0, .y = 0.0 };
        const v2 = Vec2D{ .x = 1.0, .y = 2.0 };

        try testing.expectEqualSlices(
            bool,
            &v1.checkCollisionCircleMulti(centers, radiuses),
            &[_]bool{ true, true, false },
        );
        try testing.expectEqualSlices(
            bool,
            &v2.checkCollisionCircleMulti(centers, radiuses),
            &[_]bool{ false, true, true },
        );
    }

    test normalizeMulti {
        const vecs = [4]Vec2D{
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 5.3, .y = -2.2 },
            .{ .x = 1.6, .y = 671.5 },
            .{ .x = -43.8, .y = 3.1 },
        };
        const vecs_simd: @Vector(8, f32) = @bitCast(vecs);

        const normalized_simd = Vec2D.normalizeMulti(vecs_simd);
        for (vecs, 0..) |v, i| {
            const n = v.normalized();
            try testing.expect(n.x == normalized_simd[2*i]);
            try testing.expect(n.y == normalized_simd[(2*i)+1]);
        }
    }

    test distanceMulti {
        const origin = Vec2D{ .x = 1.2, .y = 3.8 };
        const vecs = [4]Vec2D{
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 5.3, .y = -2.2 },
            .{ .x = 1.6, .y = 671.5 },
            .{ .x = -43.8, .y = 3.1 },
        };
        const vecs_simd: @Vector(8, f32) = @bitCast(vecs);

        const distances_simd = Vec2D.distanceMulti(origin, vecs_simd);
        for (vecs, 0..) |v, i| {
            const dist = origin.distance(v);
            try testing.expect(dist == distances_simd[i]);
        }
    }
};
