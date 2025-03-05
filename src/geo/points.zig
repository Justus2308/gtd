const std = @import("std");
const math = std.math;
const simd = std.simd;
const assert = std.debug.assert;

pub const v2f32 = vec(2, f32);
pub const v3f32 = vec(3, f32);
pub const v4f32 = vec(4, f32);
pub const m4f32 = mat(4, f32);

pub fn vec(comptime len: comptime_int, comptime T: type) type {
    if (@typeInfo(T) != .float) {
        @compileError("only works for floats");
    }
    return struct {
        pub const V = @Vector(len, T);
        pub const S = T;

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
            const len_ = @sqrt(len_sqrd);
            const ilen = @as(S, 1.0) / len_;
            return scale(v, ilen);
        }

        pub inline fn scale(v: V, s: S) V {
            return (v * splat(s));
        }

        pub inline fn dot(v: V, w: V) S {
            return @reduce(.Add, (v * w));
        }

        pub const cross = switch (len) {
            2 => cross2,
            3 => cross3,
            else => @compileError(std.fmt.comptimePrint("cross product is not implemented for vector length {d}", .{len})),
        };
        inline fn cross2(v: V, w: V) S {
            return (v[0] * w[1]) - (v[1] * w[0]);
        }
        // https://geometrian.com/resources/cross_product/
        inline fn cross3(v: V, w: V) V {
            const mask0 = [3]i32{ 1, 2, 0 };
            const mask1 = [3]i32{ 2, 0, 1 };

            const tmp0 = @shuffle(S, v, undefined, mask0);
            const tmp1 = @shuffle(S, w, undefined, mask1);
            const tmp2 = (tmp0 * w);
            const tmp3 = (tmp0 * tmp1);
            const tmp4 = @shuffle(S, tmp2, undefined, mask0);
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

/// This implementation assumes column-major data layout.
pub fn mat(comptime dim: comptime_int, comptime T: type) type {
    return struct {
        pub const M = @Vector(dim * dim, T);
        pub const V = @Vector(dim, T);
        pub const S = T;

        const mat_as_vec = vec(dim * dim, T);

        pub const zero = splat(0);
        pub const ident = blk: {
            var res = zero;
            for (0..dim) |i| {
                res[(i * dim) + i] = 1.0;
            }
            break :blk res;
        };

        pub inline fn splat(s: S) M {
            return @splat(s);
        }

        pub inline fn diagonal(s: S) M {
            return scale(ident, s);
        }

        pub inline fn scale(m: M, s: S) M {
            return (m * splat(s));
        }

        // This actually compiles to almost identical code to `mult` in ReleaseFast mode
        // pub inline fn multNaive(m: M, n: M) M {
        //     var res = zero;
        //     for (0..dim) |row| {
        //         for (0..dim) |col| {
        //             for (0..dim) |i| {
        //                 res[(dim * row) + col] += m[(dim * row) + i] * n[(dim * i) + col];
        //             }
        //         }
        //     }
        //     return res;
        // }

        pub inline fn mult(m: M, n: M) M {
            var res: [dim]V = undefined;
            inline for (0..dim) |i| {
                const n_col = simd.extract(n, (dim * i), dim);
                res[i] = linearComb(m, n_col);
            }
            return @bitCast(res);
        }

        pub inline fn linearComb(m: M, v: V) V {
            var res: V = (simd.extract(m, 0, dim) * @as(V, @splat(v[0])));
            inline for (1..dim) |i| {
                res += (simd.extract(m, (dim * i), dim) * @as(V, @splat(v[i])));
            }
            return res;
        }

        pub inline fn transpose(m: M) M {
            const mask = comptime blk: {
                var res: [dim * dim]i32 = undefined;
                for (0..dim) |i| {
                    for (0..dim) |j| {
                        res[(dim * i) + j] = @intCast(i + (dim * j));
                    }
                }
                break :blk res;
            };
            return @shuffle(S, m, undefined, mask);
        }

        pub const eql = mat_as_vec.eql;
        pub const approxEqAbs = mat_as_vec.approxEqAbs;
        pub const approxEqRel = mat_as_vec.approxEqRel;
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
        const len_ = v.length();
        if (len_ == 0.0) {
            @branchHint(.unlikely);
            return Vec2D.zero;
        }
        const ilen = @as(f32, 1.0) / len_;
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
