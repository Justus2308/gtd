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
        const q0: f32 = (-1.0*tension*t*t*t) + (2.0*tension*t*t) + (-1.0*tension*t);
        const q1: f32 = ((4.0-tension)*t*t*t) + ((tension-6.0)*t*t) + 2.0;
        const q2: f32 = ((tension-4.0)*t*t*t) + ((-2.0*(tension-3.0))*t*t) + (tension*t);
        const q3: f32 = (tension*t*t*t) + (-1.0*tension*t*t);

        return .{
            .x = 0.5*((p1.x*q0) + (p2.x*q1) + (p3.x*q2) + (p4.x*q3)),
            .y = 0.5*((p1.y*q0) + (p2.y*q1) + (p3.y*q2) + (p4.y*q3)),
        };
    }

    pub fn deriv(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, t: f32, tension: f32) Vec2D {
        const q0: f32 = (-3.0*tension*t*t) + (4.0*tension*t) + (-1.0*tension);
        const q1: f32 = (3.0*(4.0-tension)*t*t) + (2.0*(tension-6.0)*t);
        const q2: f32 = (3.0*(tension-4.0)*t*t) + (-4.0*(tension-3.0)*t) + tension;
        const q3: f32 = (3.0*tension*t*t) + (-2.0*tension*t);

        return .{
            .x = 0.5*((p1.x*q0) + (p2.x*q1) + (p3.x*q2) + (p4.x*q3)),
            .y = 0.5*((p1.y*q0) + (p2.y*q1) + (p3.y*q2) + (p4.y*q3)),
        };
    }

    pub inline fn length(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, tension: f32) f32 {
        return catmull_rom.lengthAt(p1, p2, p3, p4, 1.0, tension);
    }
    pub inline fn lengthAt(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, t: f32, tension: f32) f32 {
        return stdx.integrate.simpsonAdaptive(
            catmull_rom.integrandLength,
            .{ p1, p2, p3, p4, tension },
            0.0, t,
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
            const len = catmull_rom.length(spline[i+0], spline[i+1], spline[i+2], spline[i+3], tensions[i]);
            total_len += len;
        }
        const point_count_fp = total_len / sample_dist;
        return @intFromFloat(point_count_fp);
    }

    // TODO lerp pass to guarantee exact distances if necessary
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
            const len = catmull_rom.length(spline[i+0], spline[i+1], spline[i+2], spline[i+3], tensions[i]);
            const rlen = (len - carry);
            if (rlen <= 0.0) {
                // spline segment is shorter than carried-over length, skip it
                @branchHint(.unlikely);
                carry -= len;
                continue;
            }

            const linear_t_step = (sample_dist / len);

            const toff: f32 = blk: {
                // estimate t offset based on carried-over length and total length of curve
                if (carry == 0.0) {
                    @branchHint(.cold);
                    break :blk 0.0;
                }
                const rough = (carry / len);
                const rough_len = catmull_rom.lengthAt(spline[i+0], spline[i+1], spline[i+2], spline[i+3], rough, tensions[i]);
                const estimate = 0.5 * (rough + (rough_len / carry));
                // std.debug.print("carry={e}, rough={e}, rough_len={e}, estimate={e}\n", .{ carry, rough, rough_len, estimate });
                break :blk estimate;
            };

            var t_prev: f32 = 0.0;
            var t: f32 = toff;
            var required_len = carry;
            while (t <= 1.0) : ({
                // estimate next t based on previous t and total length of curve
                const t_step = 0.5 * ((t - t_prev) + linear_t_step);
                t_prev = t;
                t += t_step;
                required_len += sample_dist;
            }) {
                for (0..max_approx_steps) |_| {
                    // Newton-Rhapson Method
                    const nom = required_len - catmull_rom.lengthAt(spline[i+0], spline[i+1], spline[i+2], spline[i+3], t, tensions[i]);
                    const denom = -1.0 * catmull_rom.integrandLength(t, spline[i+0], spline[i+1], spline[i+2], spline[i+3], tensions[i]);
                    const quot = (nom / denom);
                    t -= quot;
                    if (quot < eps) {
                        @branchHint(.unlikely);
                        break;
                    }
                }

                // std.debug.print("t={e}\n", .{ t });
                // std.debug.print("seg={d} ; len={e}\n", .{ i, stdx.integrate.simpsonAdaptive(catmull_rom.integrandLength,
                //     .{ spline[i+0], spline[i+1], spline[i+2], spline[i+3], tensions[i] }, t_prev, t, .{},) });

                const p = catmull_rom.point(spline[i+0], spline[i+1], spline[i+2], spline[i+3], t, tensions[i]);
                try samples.append(allocator, p);
            }
            carry = @rem((required_len - len), sample_dist);
            // std.debug.print("seg={d}, len={e}, required_len={e}, carry={e}\n", .{ i, len, required_len, carry });
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
        for (0..test_spline.len-3) |i| {
            const len_segment = catmull_rom.length(
                test_spline[i+0],
                test_spline[i+1],
                test_spline[i+2],
                test_spline[i+3],
                test_tensions[i],
            );
            len += len_segment;
        }
        std.debug.print("len={e}\n", .{ len });
        // try testing.expectApproxEqRel(len, 9.5670, stdx.integrate.default_epsilon*10.0);
    }

    test discretize {
        const allocator = testing.allocator;

        const sample_dist = 0.1;
        const discretized = try catmull_rom.discretize(allocator, &test_spline, &test_tensions, sample_dist);
        defer allocator.free(discretized);

        std.debug.print("{any}\n", .{ discretized });
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
