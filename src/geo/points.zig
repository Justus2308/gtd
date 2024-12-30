const std = @import("std");

const math = std.math;


pub const Vec2D = extern struct {
    x: f32,
    y: f32,

    pub const zero = Vec2D{ .x = 0.0, .y = 0.0 };
    pub const one = Vec2D{ .x = 1.0, .y = 1.0 };

    pub inline fn init(x: f32, y: f32) Vec2D {
        return .{ .x = x, .y = y };
    }

    pub inline fn length(v: Vec2D) f32 {
        return @sqrt(v.lengthSqrd());
    }
    pub inline fn lengthSqrd(v: Vec2D) f32 {
        return (v.x*v.x) + (v.y*v.y);
    }

    pub inline fn normalize(v: Vec2D) Vec2D {
        const len = v.length();
        if (len == 0.0) {
            @branchHint(.unlikely);
            return Vec2D.zero;
        }
        const ilen = @as(f32, 1.0) / len;
        return v.scale(ilen);
    }

    pub inline fn add(v: Vec2D, w: Vec2D) Vec2D {
        return .{
            .x = v.x + w.x,
            .y = v.y + w.y,
        };
    }
    pub inline fn addScalar(v: Vec2D, s: f32) Vec2D {
        return .{
            .x = v.x + s,
            .y = v.y + s,
        };
    }

    pub inline fn sub(v: Vec2D, w: Vec2D) Vec2D {
        return .{
            .x = v.x - w.x,
            .y = v.y - w.y,
        };
    }
    pub inline fn subScalar(v: Vec2D, s: f32) Vec2D {
        return .{
            .x = v.x - s,
            .y = v.y - s,
        };
    }

    pub inline fn scale(v: Vec2D, s: f32) Vec2D {
        return .{
            .x = v.x * s,
            .y = v.y * s,
        };
    }

    pub inline fn dot(v: Vec2D, w: Vec2D) f32 {
        return (v.x*w.x + v.y*w.y);
    }

    pub inline fn cross(v: Vec2D, w: Vec2D) f32 {
        return (v.x*w.y - v.y+w.x);
    }

    pub inline fn distance(v: Vec2D, w: Vec2D) f32 {
        return @sqrt(v.distanceSqrd(w));
    }
    pub inline fn distanceSqrd(v: Vec2D, w: Vec2D) f32 {
        return (v.x - w.x)*(v.x - w.x) + (v.y - w.y)*(v.y - w.y);
    }

    pub inline fn mult(v: Vec2D, w: Vec2D) Vec2D {
        return .{
            .x = v.x * w.x,
            .y = v.y * w.y,
        };
    }

    pub inline fn div(v: Vec2D, w: Vec2D) Vec2D {
        return .{
            .x = v.x / w.x,
            .y = v.y / w.y,
        };
    }

    pub inline fn negate(v: Vec2D) Vec2D {
        return .{
            .x = -v.x,
            .y = -v.y,
        };
    }

    pub inline fn invert(v: Vec2D) Vec2D {
        return .{
            .x = @as(f32, 1.0) / v.x,
            .y = @as(f32, 1.0) / v.y,
        };
    }

    pub inline fn lerp(v: Vec2D, w: Vec2D, amount: f32) Vec2D {
        return .{
            .x = v.x + amount*(w.x - v.x),
            .y = v.y + amount*(w.y - v.y),
        };
    }

    pub inline fn min(v: Vec2D, w: Vec2D) Vec2D {
        return .{
            .x = @min(v.x, w.x),
            .y = @min(v.y, w.y),
        };
    }
    pub inline fn max(v: Vec2D, w: Vec2D) Vec2D {
        return .{
            .x = @max(v.x, w.x),
            .y = @max(v.y, w.y),
        };
    }

    pub inline fn clamp(v: Vec2D, vmin: Vec2D, vmax: Vec2D) Vec2D {
        return .{
            .x = @min(vmax.x, @max(vmin.x, v.x)),
            .y = @min(vmax.y, @max(vmin.y, v.y)),
        };
    }
    pub inline fn clampLength(v: Vec2D, lmin: f32, lmax: f32) Vec2D {
        var result = v;
        var len = v.lengthSqrd();
        if (len > 0.0) {
            @branchHint(.likely);
            len = @sqrt(len);
            const s = if (len < lmin)
                (lmin / len)
            else if (len > lmax)
                (lmax / len)
            else
                1.0;
            result = result.scale(s);
        }
        return result;
    }

    pub inline fn moveTowards(v: Vec2D, target: Vec2D, max_dist: f32) Vec2D {
        const d = target.sub(v);
        const dist_sqrd = d.lengthSqrd();

        if ((dist_sqrd == 0.0) or (max_dist >= 0 and dist_sqrd <= max_dist*max_dist)) {
            return target;
        }

        const dist = @sqrt(dist_sqrd);
        return .{
            .x = v.x + d.x/dist*max_dist,
            .y = v.y + d.y/dist*max_dist,
        };
    }

    pub inline fn approxEqAbs(v: Vec2D, w: Vec2D, tolerance: f32) bool {
        return (math.approxEqAbs(f32, v.x, w.x, tolerance) and math.approxEqAbs(f32, v.y, w.y, tolerance));
    }
    pub inline fn approxEqRel(v: Vec2D, w: Vec2D, tolerance: f32) bool {
        return (math.approxEqRel(f32, v.x, w.x, tolerance) and math.approxEqRel(f32, v.y, w.y, tolerance));
    }

    // pub inline fn asRaylib(v: Vec2D) raylib.Vector2 {
    //     return @bitCast(v);
    // }
};
