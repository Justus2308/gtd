const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");

const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Vec2D = geo.points.Vec2D;

const assert = std.debug.assert;

/// Uniform Catmull-Rom-Splines with variable tension (𝜏)
pub const catmull_rom = struct {
    pub fn point(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, t: f32, tension: f32) Vec2D {
        const q0: f32 = (-1.0 * tension * t * t * t) + (2.0 * tension * t * t) + (-1.0 * tension * t);
        const q1: f32 = ((4.0 - tension) * t * t * t) + ((tension - 6.0) * t * t) + 2.0;
        const q2: f32 = ((tension - 4.0) * t * t * t) + ((-2.0 * (tension - 3.0)) * t * t) + (tension * t);
        const q3: f32 = (tension * t * t * t) + (-1.0 * tension * t * t);

        return .{
            .x = 0.5 * ((p1.x * q0) + (p2.x * q1) + (p3.x * q2) + (p4.x * q3)),
            .y = 0.5 * ((p1.y * q0) + (p2.y * q1) + (p3.y * q2) + (p4.y * q3)),
        };
    }

    pub fn deriv(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, t: f32, tension: f32) Vec2D {
        const q0: f32 = (-3.0 * tension * t * t) + (4.0 * tension * t) + (-1.0 * tension);
        const q1: f32 = (3.0 * (4.0 - tension) * t * t) + (2.0 * (tension - 6.0) * t);
        const q2: f32 = (3.0 * (tension - 4.0) * t * t) + (-4.0 * (tension - 3.0) * t) + tension;
        const q3: f32 = (3.0 * tension * t * t) + (-2.0 * tension * t);

        return .{
            .x = 0.5 * ((p1.x * q0) + (p2.x * q1) + (p3.x * q2) + (p4.x * q3)),
            .y = 0.5 * ((p1.y * q0) + (p2.y * q1) + (p3.y * q2) + (p4.y * q3)),
        };
    }

    pub inline fn length(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, tension: f32) f32 {
        return catmull_rom.lengthAt(p1, p2, p3, p4, 1.0, tension);
    }
    pub inline fn lengthAt(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, t: f32, tension: f32) f32 {
        return stdx.integrate.simpsonAdaptive(
            catmull_rom.integrandLength,
            .{ p1, p2, p3, p4, tension },
            0.0,
            t,
            .{},
        );
    }
    fn integrandLength(t: f32, p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, tension: f32) f32 {
        const dt = catmull_rom.deriv(p1, p2, p3, p4, t, tension);
        const dt_norm = dt.length();
        return dt_norm;
    }

    pub fn estimateDiscretePointCount(spline: []const Vec2D, tensions: []const f32, sample_dist: f32) usize {
        assert(sample_dist > 0.0);

        var total_len: f32 = 0.0;
        for (0..(spline.len -| 3)) |i| {
            const len = catmull_rom.length(spline[i + 0], spline[i + 1], spline[i + 2], spline[i + 3], tensions[i]);
            total_len += len;
        }
        const point_count_fp = total_len / sample_dist;
        var point_count: usize = @intFromFloat(point_count_fp);
        point_count += @max(1, (point_count >> 10));
        return point_count;
    }

    // TODO lerp pass to smooth out inaccuracies caused by unsteady curves at segment transition points?
    pub fn discretize(
        allocator: Allocator,
        spline: []const Vec2D,
        tensions: []const f32,
        sample_dist: f32,
    ) Allocator.Error![]Vec2D {
        assert(sample_dist > 0.0);

        const max_approx_steps = 50;
        const eps = stdx.integrate.default_epsilon;

        var samples = std.ArrayListUnmanaged(Vec2D).empty;
        errdefer samples.deinit(allocator);

        var carry: f32 = 0.0;
        for (0..(spline.len -| 3)) |i| {
            const len = catmull_rom.length(spline[i + 0], spline[i + 1], spline[i + 2], spline[i + 3], tensions[i]);
            const rlen = (len - carry);
            if (rlen <= 0.0) {
                // spline segment is shorter than carried-over length, skip it
                @branchHint(.unlikely);
                carry -= len;
                continue;
            }

            const linear_t_step = (sample_dist / len);
            const t_offset = (carry / len);

            var t = t_offset;
            var t_prev = (t - linear_t_step);
            var required_len = carry;
            while (true) : ({
                // estimate next t based on previous t and total length of curve
                const t_step = 0.5 * ((t - t_prev) + linear_t_step);
                t_prev = t;
                t += t_step;
                required_len += sample_dist;
            }) {
                // Newton-Rhapson Method
                for (0..max_approx_steps) |_| {
                    const nom = required_len - catmull_rom.lengthAt(spline[i + 0], spline[i + 1], spline[i + 2], spline[i + 3], t, tensions[i]);
                    const denom = -1.0 * catmull_rom.integrandLength(t, spline[i + 0], spline[i + 1], spline[i + 2], spline[i + 3], tensions[i]);
                    const quot = (nom / denom);
                    t -= quot;
                    if (@abs(quot) < eps) {
                        @branchHint(.unlikely);
                        break;
                    }
                } else {
                    @branchHint(.cold);
                    std.debug.print("discretize: newton method reached max approx steps! (seg:{d}, idx:{d})\n", .{ i, samples.items.len }); // TODO replace with proper log
                }

                if (t > 1.0) {
                    @branchHint(.unlikely);
                    break;
                }

                // std.debug.print("t={e}\n", .{ t });
                // std.debug.print("seg={d} ; len={e}\n", .{ i, stdx.integrate.simpsonAdaptive(catmull_rom.integrandLength,
                //     .{ spline[i+0], spline[i+1], spline[i+2], spline[i+3], tensions[i] }, t_prev, t, .{},) });

                const p = catmull_rom.point(spline[i + 0], spline[i + 1], spline[i + 2], spline[i + 3], t, tensions[i]);
                try samples.append(allocator, p);
            }
            carry = @rem((required_len - len), sample_dist);
            // std.debug.print("seg={d}, idx={d}, len={d}, required_len={d}, carry={d}\n", .{ i, samples.items.len -| 1, len, required_len, carry });
        }

        const slice = try samples.toOwnedSlice(allocator);
        return slice;
    }

    const test_spline = [_]Vec2D{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 1.0, .y = 2.0 },
        .{ .x = 3.0, .y = 3.0 },
        .{ .x = 5.0, .y = 0.0 },
        .{ .x = 7.0, .y = 2.0 },
        .{ .x = 9.0, .y = 0.0 },
    };
    const test_tensions = [_]f32{
        1.0,
        0.2,
        0.7,
    };

    test length {
        var len: f32 = 0.0;
        for (0..test_spline.len - 3) |i| {
            const len_segment = catmull_rom.length(
                test_spline[i + 0],
                test_spline[i + 1],
                test_spline[i + 2],
                test_spline[i + 3],
                test_tensions[i],
            );
            len += len_segment;
        }
        std.debug.print("len={e}\n", .{len});
        // try testing.expectApproxEqRel(len, 9.5670, stdx.integrate.default_epsilon*10.0);
    }

    test discretize {
        const allocator = testing.allocator;

        const sample_dist = 0.1;
        const discretized = try catmull_rom.discretize(allocator, &test_spline, &test_tensions, sample_dist);
        defer allocator.free(discretized);

        std.debug.print("{any}\n", .{discretized});
        const cumulative_error, const cumulative_error_abs, const max_error, const max_error_idx = blk: {
            var sum: f32 = 0.0;
            var sum_abs: f32 = 0.0;
            var max: f32 = 0.0;
            var max_idx: usize = 0;
            for (discretized[0..(discretized.len - 1)], discretized[1..], 0..) |disc, next, i| {
                const dist = disc.distance(next);
                const diff = (dist - sample_dist);
                sum += diff;
                const abs_diff = @abs(diff);
                sum_abs += abs_diff;
                if (abs_diff > max) {
                    max = abs_diff;
                    max_idx = i;
                }

                std.debug.print("{d}: {d} ({d})\n", .{ i, dist, diff });
            }
            break :blk .{ sum, sum_abs, max, max_idx };
        };
        const average_error = cumulative_error_abs / @as(f32, @floatFromInt(discretized.len));

        std.debug.print("point count: {d}\n", .{discretized.len});
        std.debug.print("cumulative error: {d}\n", .{cumulative_error});
        std.debug.print("absolute cumulative error: {d}\n", .{cumulative_error_abs});
        std.debug.print("average error per point: {d}\n", .{average_error});
        std.debug.print("max error: {d} ({d}/{d})\n", .{ max_error, max_error_idx, max_error_idx + 1 });

        // const expected = [_]Vec2D{
        //     .{ .x = 1.000000, .y = 2.000000 },
        //     .{ .x = 1.771103, .y = 2.696569 },
        //     .{ .x = 2.672819, .y = 3.076544 },
        //     .{ .x = 3.348697, .y = 2.651917 },
        //     .{ .x = 3.909820, .y = 1.623593 },
        //     .{ .x = 4.474950, .y = 0.532280 },
        //     .{ .x = 5.032064, .y = -0.006235 },
        //     .{ .x = 5.585170, .y = 0.340238 },
        //     .{ .x = 6.134269, .y = 1.147060 },
        //     .{ .x = 6.687375, .y = 1.858368 },
        // };
        // for (expected, discretized) |e, d| {
        //     try testing.expectApproxEqRel(e.x, d.x, stdx.integrate.default_epsilon*10);
        //     try testing.expectApproxEqRel(e.y, d.y, stdx.integrate.default_epsilon*10);
        // }
    }
};
