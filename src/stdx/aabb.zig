const std = @import("std");
const stdx = @import("../stdx.zig");
const math = std.math;
const simd = std.simd;
const testing = std.testing;

const Vec2D = stdx.Vec2D;

const assert = std.debug.assert;
const vectorLength = stdx.vectorLength;


pub const Aabb = extern struct {
    pos: Vec2D,
    width: f32,
    height: f32,

    pub fn checkCollisionCircle(aabb: Aabb, center: Vec2D, radius: f32) bool {
        const aabb_center_relative = Vec2D{
            .x = (aabb.width/2.0),
            .y = (aabb.height/2.0),
        };
        const inner_bounding_radius = @min(aabb_center_relative.x, aabb_center_relative.y);
        const outer_bounding_radius = aabb_center_relative.length();

        const aabb_center = aabb.pos.plus(aabb_center_relative);
        const center_distance = center.distance(aabb_center);

        if (center_distance > outer_bounding_radius) return false;
        if (center_distance < inner_bounding_radius) return true;

        const centers_connection_vec = center.minus(aabb_center).normalized();
        const circle_closest_point = center.plus(centers_connection_vec.scaled(radius));
        return circle_closest_point.checkCollisionAabb(aabb);
    }

    pub fn checkCollisionCircleMulti(
        aabb: Aabb,
        centers: anytype,
        radiuses: anytype,
    ) @Vector(vectorLength(@TypeOf(radiuses)), bool) {
        const aabb_center_relative = Vec2D{
            .x = (aabb.width/2.0),
            .y = (aabb.height/2.0),
        };
        const inner_bounding_radius = @min(aabb_center_relative.x, aabb_center_relative.y);
        const outer_bounding_radius = aabb_center_relative.length();

        const aabb_center = aabb.pos.plus(aabb_center_relative);
        const center_distances = aabb_center.distanceMulti(centers);

        const RadiusVec = @TypeOf(radiuses);

        // TODO remove these checks if they don't succeed frequently enough and just use slow path every time
        const are_not_colliding = (center_distances > @as(RadiusVec, @splat(outer_bounding_radius)));
        if (@reduce(are_not_colliding, .And)) return @splat(false);

        const are_colliding = (center_distances < @as(RadiusVec, @splat(inner_bounding_radius)));
        if (@reduce(are_colliding, .And)) return @splat(true);

        const centers_connection_vecs = blk: {
            const circle_count = vectorLength(RadiusVec);
            const unnormalized = centers - aabb_center.splat(circle_count);
            break :blk Vec2D.normalizeMulti(unnormalized);
        };
        const circles_closest_points = centers + (centers_connection_vecs * simd.interlace(.{ radiuses, radiuses }));
        return aabb.checkCollisionPointMulti(circles_closest_points);
    }

    pub fn checkCollisionPoint(aabb: Aabb, point: Vec2D) bool {
        return point.checkCollisionAabb(aabb);
    }

    pub fn checkCollisionPointMulti(
        aabb: Aabb,
        points: anytype,
    ) @Vector(@divExact(vectorLength(@TypeOf(points)), 2), bool) {
        const point_count = @divExact(vectorLength(@TypeOf(points)), 2);
        const NumVec = @Vector(point_count, f32);

        const points_x, const points_y = simd.deinterlace(2, points);
        const aabb_x: NumVec = @splat(aabb.pos.x);
        const aabb_y: NumVec = @splat(aabb.pos.y);
        const aabb_w: NumVec = @splat(aabb.width);
        const aabb_h: NumVec = @splat(aabb.height);

        return (points_x >= aabb_x and points_x < aabb_x+aabb_w
            and points_y >= aabb_y and points_y < aabb_y+aabb_h);
    }
};
