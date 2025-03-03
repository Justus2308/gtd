const std = @import("std");
const math = std.math;
const assert = std.debug.assert;

pub const v2f32 = namespace(@Vector(2, f32));
pub const v3f32 = namespace(@Vector(3, f32));
pub const v4f32 = namespace(@Vector(4, f32));

pub fn namespace(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .vector => |i| i,
        else => @compileError("only works for vector types"),
    };
    switch (info.child) {
        .comptime_float, .float => {},
        else => @compileError("only works for float vectors"),
    }
    return struct {
        pub const V = T;
        pub const S = info.child;

        pub const zero = splat(0.0);
        pub const one = splat(1.0);

        pub inline fn splat(s: S) V {
            return @splat(s);
        }

        pub inline fn length(v: V) S {
            return @sqrt(lengthSqrd(v));
        }
        pub inline fn lengthSqrd(v: V) S {
            return @reduce(.Add, (v * v));
        }

        pub inline fn normalize(v: V) V {
            const len_sqrd = lengthSqrd(v);
            if (len_sqrd == 0.0) {
                @branchHint(.unlikely);
                return zero;
            }
            const len = @sqrt(len_sqrd);
            const ilen = @as(S, 1.0) / len;
            return scale(v, ilen);
        }

        pub inline fn scale(v: V, s: S) V {
            return (v * splat(s));
        }

        pub inline fn dot(v: V, w: V) S {
            return @reduce(.Add, (v * w));
        }

        pub const cross = switch (info.len) {
            2 => cross2,
            3 => cross3,
            else => @compileError(std.fmt.comptimePrint("cross product is not implemented for vector length {d}", .{info.len})),
        };
        inline fn cross2(v: V, w: V) S {
            return (v[0] * w[1]) - (v[1] * w[0]);
        }
        // https://geometrian.com/resources/cross_product/
        inline fn cross3(v: V, w: V) V {
            const mask0 = [3]i32{ 1, 2, 0 };
            const mask1 = [3]i32{ 2, 0, 1 };

            const tmp0 = @shuffle(S, v, v, mask0);
            const tmp1 = @shuffle(S, w, w, mask1);
            const tmp2 = (tmp0 * w);
            const tmp3 = (tmp0 * tmp1);
            const tmp4 = @shuffle(S, tmp2, tmp2, mask0);
            return (tmp3 - tmp4);
        }

        pub inline fn distance(v: V, w: V) S {
            return @sqrt(distanceSqrd(v, w));
        }
        pub inline fn distanceSqrd(v: V, w: V) S {
            const tmp = (v - w);
            return @reduce(.Add, (tmp * tmp));
        }

        pub inline fn invert(v: V) V {
            return (one / v);
        }

        pub inline fn lerp(v: V, w: V, amount: S) V {
            return (v + scale((w - v), amount));
        }

        pub inline fn clamp(v: V, vmin: V, vmax: V) V {
            return @min(vmax, @max(vmin, v));
        }

        pub inline fn moveTowards(v: V, target: V, max_dist: S) V {
            const d = target - v;
            const dist_sqrd = lengthSqrd(d);

            if ((dist_sqrd == 0.0) or (max_dist >= 0 and dist_sqrd <= max_dist * max_dist)) {
                return target;
            }

            const dist = @sqrt(dist_sqrd);
            return (v + scale((d / splat(dist)), max_dist));
        }

        pub inline fn eql(v: V, w: V) bool {
            return @reduce(.And, (v == w));
        }

        pub inline fn approxEqAbs(v: V, w: V, tolerance: S) bool {
            assert(tolerance >= 0.0);

            if (eql(v, w)) {
                return true;
            }
            return (@reduce(.Max, @abs(v - w)) <= tolerance);
        }
        pub inline fn approxEqRel(v: V, w: V, tolerance: S) bool {
            assert(tolerance > 0.0);

            if (eql(v, w)) {
                return true;
            }

            const pred = (@abs(v - w) <= scale(@max(@abs(v), @abs(w)), tolerance));
            return @reduce(.And, pred);
        }
    };
}

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
        return (v.x * v.x) + (v.y * v.y);
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
        return (v.x * w.x) + (v.y * w.y);
    }

    pub inline fn cross(v: Vec2D, w: Vec2D) f32 {
        return (v.x * w.y) - (v.y * w.x);
    }

    pub inline fn distance(v: Vec2D, w: Vec2D) f32 {
        return @sqrt(v.distanceSqrd(w));
    }
    pub inline fn distanceSqrd(v: Vec2D, w: Vec2D) f32 {
        return (v.x - w.x) * (v.x - w.x) + (v.y - w.y) * (v.y - w.y);
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
        return Vec2D.one.div(v);
    }

    pub inline fn lerp(v: Vec2D, w: Vec2D, amount: f32) Vec2D {
        return v.add(w.sub(v).scale(amount));
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
        return vmax.min(vmin.max(v));
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

        if ((dist_sqrd == 0.0) or (max_dist >= 0 and dist_sqrd <= max_dist * max_dist)) {
            return target;
        }

        const dist = @sqrt(dist_sqrd);
        return .{
            .x = v.x + d.x / dist * max_dist,
            .y = v.y + d.y / dist * max_dist,
        };
    }

    pub inline fn eql(v: Vec2D, w: Vec2D) bool {
        return (v.x == v.y and w.x == w.y);
    }
    pub inline fn approxEqAbs(v: Vec2D, w: Vec2D, tolerance: f32) bool {
        return (math.approxEqAbs(f32, v.x, w.x, tolerance) and math.approxEqAbs(f32, v.y, w.y, tolerance));
    }
    pub inline fn approxEqRel(v: Vec2D, w: Vec2D, tolerance: f32) bool {
        return (math.approxEqRel(f32, v.x, w.x, tolerance) and math.approxEqRel(f32, v.y, w.y, tolerance));
    }
};
