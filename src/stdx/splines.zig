const std = @import("std");
const stdx = @import("stdx");
const zalgebra = @import("zalgebra");

const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;

const assert = std.debug.assert;
const log = std.log.scoped(.splines);

pub const PathBuilder = @import("splines/PathBuilder.zig");

pub fn Integrator(comptime F: type) type {
    return union(enum) {
        trapezoid: stdx.integrate.TrapezoidOptions,
        simpson_adaptive: stdx.integrate.SimpsonAdaptiveOptions(F),
    };
}

pub const Point = struct {
    coords: Coords,
    t: f32,

    pub const Coords = extern struct {
        _: void align(8) = {},
        x: f32,
        y: f32,

        pub inline fn asVec(coords: Coords) zalgebra.Vec2 {
            return .new(coords.x, coords.y);
        }

        comptime {
            assert(@alignOf(Coords) == 8);
            assert(@sizeOf(Coords) == 8);
        }
    };
};

pub const CatmullRomDiscretized = std.MultiArrayList(Point);

/// Uniform Catmull-Rom-Splines with variable tension (𝜏)
pub fn catmull_rom(comptime F: type, comptime integrator: Integrator(F)) type {
    return struct {
        const Vec2 = zalgebra.GenericVector(2, F);

        pub const ControlPoint = struct {
            xy: [2]F,
            tension: F,
        };

        pub fn point(p1: Vec2, p2: Vec2, p3: Vec2, p4: Vec2, t: F, tension: F) Vec2 {
            const q0: F = (-1.0 * tension * t * t * t) + (2.0 * tension * t * t) + (-1.0 * tension * t);
            const q1: F = ((4.0 - tension) * t * t * t) + ((tension - 6.0) * t * t) + 2.0;
            const q2: F = ((tension - 4.0) * t * t * t) + ((-2.0 * (tension - 3.0)) * t * t) + (tension * t);
            const q3: F = (tension * t * t * t) + (-1.0 * tension * t * t);

            return p1.scale(q0).add(p2.scale(q1)).add(p3.scale(q2)).add(p4.scale(q3)).scale(0.5);
        }

        pub fn deriv(p1: Vec2, p2: Vec2, p3: Vec2, p4: Vec2, t: F, tension: F) Vec2 {
            const q0: F = (-3.0 * tension * t * t) + (4.0 * tension * t) + (-1.0 * tension);
            const q1: F = (3.0 * (4.0 - tension) * t * t) + (2.0 * (tension - 6.0) * t);
            const q2: F = (3.0 * (tension - 4.0) * t * t) + (-4.0 * (tension - 3.0) * t) + tension;
            const q3: F = (3.0 * tension * t * t) + (-2.0 * tension * t);

            return p1.scale(q0).add(p2.scale(q1)).add(p3.scale(q2)).add(p4.scale(q3)).scale(0.5);
        }

        pub inline fn length(p1: Vec2, p2: Vec2, p3: Vec2, p4: Vec2, tension: F) F {
            return lengthAt(p1, p2, p3, p4, 1.0, tension);
        }
        pub inline fn lengthAt(p1: Vec2, p2: Vec2, p3: Vec2, p4: Vec2, t: F, tension: F) F {
            const t_clamped = std.math.clamp(t, 0.0, 1.0);
            return switch (integrator) {
                .trapezoid => |options| stdx.integrate.trapezoid(
                    F,
                    integrandLength,
                    .{ p1, p2, p3, p4, tension },
                    0.0,
                    t_clamped,
                    options,
                ),
                .simpson_adaptive => |options| blk: {
                    const res = stdx.integrate.simpsonAdaptive(
                        F,
                        integrandLength,
                        .{ p1, p2, p3, p4, tension },
                        0.0,
                        t_clamped,
                        options,
                    );
                    assert(res.hit_limit == false);
                    break :blk res.result;
                },
            };
        }
        fn integrandLength(t: F, p1: Vec2, p2: Vec2, p3: Vec2, p4: Vec2, tension: F) F {
            const dt = deriv(p1, p2, p3, p4, t, tension);
            const dt_norm = dt.length();
            return dt_norm;
        }

        pub fn totalLength(control_points: []const ControlPoint) F {
            var total_len: F = 0.0;
            for (0..(control_points.len -| 3)) |i| {
                const len = length(
                    .fromSlice(&control_points[i + 0].xy),
                    .fromSlice(&control_points[i + 1].xy),
                    .fromSlice(&control_points[i + 2].xy),
                    .fromSlice(&control_points[i + 3].xy),
                    control_points[i].tension,
                );
                total_len += len;
            }
            return total_len;
        }

        pub fn estimateDiscretePointCount(control_points: []const ControlPoint, sample_dist: F) usize {
            assert(sample_dist > 0.0);
            const total_len = totalLength(control_points);
            const point_count_fp = (total_len / sample_dist);
            return @intFromFloat(@ceil(point_count_fp));
        }

        pub const DiscretizeOptions = struct {
            max_approx_steps: usize = 100,
            eps: F = 10e-6,
        };

        // TODO lerp pass to smooth out inaccuracies caused by unsteady curves at segment transition points?
        pub fn discretize(
            gpa: Allocator,
            control_points: []const ControlPoint,
            sample_dist: F,
            options: DiscretizeOptions,
        ) Allocator.Error!CatmullRomDiscretized.Slice {
            assert(sample_dist > 0.0);

            var samples = CatmullRomDiscretized.empty;
            errdefer samples.deinit(gpa);

            // This is almost always a perfect estimation if our
            // integration is accurate enough.
            const estimated_sample_count = estimateDiscretePointCount(control_points, sample_dist);
            try samples.setCapacity(gpa, estimated_sample_count);

            var carry: F = 0.0;
            for (0..(control_points.len -| 3)) |i| {
                const len = length(
                    .fromSlice(&control_points[i + 0].xy),
                    .fromSlice(&control_points[i + 1].xy),
                    .fromSlice(&control_points[i + 2].xy),
                    .fromSlice(&control_points[i + 3].xy),
                    control_points[i].tension,
                );
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
                var t_prev = @max(0.0, (t - linear_t_step));

                var required_len = carry;

                outer: while (t < 1.0) : ({
                    // estimate next t based on previous t and total length of curve
                    const t_step = (0.5 * ((t - t_prev) + linear_t_step));
                    t_prev = t;
                    t += t_step;

                    required_len += sample_dist;
                }) {
                    // Newton-Rhapson method

                    // f(x) = (required_len - lengthAt(t))
                    // -> converge towards f(x) = 0

                    // f'(x) = -integrandLength(t)

                    var approx_step_count: usize = 0;
                    while (approx_step_count < options.max_approx_steps) : (approx_step_count += 1) {
                        // Calculate f(x)
                        const nom: F = (required_len - lengthAt(
                            .fromSlice(&control_points[i + 0].xy),
                            .fromSlice(&control_points[i + 1].xy),
                            .fromSlice(&control_points[i + 2].xy),
                            .fromSlice(&control_points[i + 3].xy),
                            t,
                            control_points[i].tension,
                        ));
                        // Calculate f'(x)
                        const denom = -integrandLength(
                            t,
                            .fromSlice(&control_points[i + 0].xy),
                            .fromSlice(&control_points[i + 1].xy),
                            .fromSlice(&control_points[i + 2].xy),
                            .fromSlice(&control_points[i + 3].xy),
                            control_points[i].tension,
                        );
                        // avoid dividing by zero
                        if (@abs(denom) < options.eps) {
                            @branchHint(.unlikely);
                            break;
                        }

                        // Calculate f(x) / f'(x) and update t
                        const quot = (nom / denom);
                        if (@abs(quot) < options.eps) {
                            @branchHint(.unlikely);
                            break;
                        }
                        t -= quot;
                        if (t < 0.0 or t > 1.0) {
                            @branchHint(.unlikely);
                            t = std.math.clamp(t, 0.0, 1.0);
                            continue :outer;
                        }
                    } else {
                        @branchHint(.cold);
                        log.debug(
                            "catmull_rom.discretize: newton method reached max approx steps! (seg:{d}, idx:{d})\n",
                            .{ i, samples.len },
                        );
                    }

                    // std.debug.print("t={e}\n", .{ t });
                    // std.debug.print("seg={d} ; len={e}\n", .{ i, stdx.integrate.simpsonAdaptive(catmull_rom.integrandLength,
                    //     .{ spline[i+0], spline[i+1], spline[i+2], spline[i+3], tensions[i] }, t_prev, t, .{},) });

                    const p = point(
                        .fromSlice(&control_points[i + 0].xy),
                        .fromSlice(&control_points[i + 1].xy),
                        .fromSlice(&control_points[i + 2].xy),
                        .fromSlice(&control_points[i + 3].xy),
                        t,
                        control_points[i].tension,
                    );
                    try samples.append(gpa, .{
                        .coords = .{
                            .x = @floatCast(p.x()),
                            .y = @floatCast(p.y()),
                        },
                        .t = @floatCast(t),
                    });
                }
                carry = @rem((required_len - len), sample_dist);
                // std.debug.print("seg={d}, idx={d}, len={d}, required_len={d}, carry={d}\n", .{ i, samples.items.len -| 1, len, required_len, carry });
            }

            const slice = samples.toOwnedSlice();
            return slice;
        }

        const test_spline = [_]ControlPoint{
            .{ .xy = .{ 0.0, 0.0 }, .tension = 1.0 },
            .{ .xy = .{ 1.0, 2.0 }, .tension = 0.2 },
            .{ .xy = .{ 3.0, 3.0 }, .tension = 0.7 },
            .{ .xy = .{ 5.0, 0.0 }, .tension = undefined },
            .{ .xy = .{ 7.0, 2.0 }, .tension = undefined },
            .{ .xy = .{ 9.0, 0.0 }, .tension = undefined },
        };

        test length {
            var len: F = 0.0;
            for (0..test_spline.len - 3) |i| {
                const len_segment = length(
                    .fromSlice(&test_spline[i + 0].xy),
                    .fromSlice(&test_spline[i + 1].xy),
                    .fromSlice(&test_spline[i + 2].xy),
                    .fromSlice(&test_spline[i + 3].xy),
                    test_spline[i].tension,
                );
                len += len_segment;
            }
            std.debug.print("len={e}\n", .{len});
            // try testing.expectApproxEqRel(len, 9.5670, stdx.integrate.default_epsilon*10.0);
        }

        test discretize {
            const allocator = testing.allocator;

            const sample_dist = 0.1;

            std.debug.print("F={s},integrator={s}\n", .{ @typeName(F), @tagName(integrator) });

            var discretized = try discretize(allocator, &test_spline, sample_dist, .{});
            defer discretized.deinit(allocator);

            std.debug.print("{any}\n", .{discretized});
            const cumulative_error, const cumulative_error_abs, const max_error, const max_error_idx = blk: {
                var sum: F = 0.0;
                var sum_abs: F = 0.0;
                var max: F = 0.0;
                var max_idx: usize = 0;
                for (
                    discretized.items(.coords)[0..(discretized.len - 1)],
                    discretized.items(.coords)[1..],
                    discretized.items(.t)[0..(discretized.len - 1)],
                    0..,
                ) |disc, next, t, i| {
                    const dist = disc.asVec().distance(next.asVec());
                    const diff = (dist - sample_dist);
                    sum += diff;
                    const abs_diff = @abs(diff);
                    sum_abs += abs_diff;
                    if (abs_diff > max) {
                        max = abs_diff;
                        max_idx = i;
                    }

                    const diff_sign_char: u8 = if (diff < 0) '-' else '+';
                    std.debug.print("{d:3}: t={d:1.10} d={d:2.10} ({c}{d:.15})\n", .{ i, t, dist, diff_sign_char, abs_diff });
                }
                const last_idx = (discretized.len - 1);
                std.debug.print("{d:3}: t={d:1.10}\n", .{ last_idx, discretized.items(.t)[last_idx] });
                break :blk .{ sum, sum_abs, max, max_idx };
            };
            const average_error = (cumulative_error_abs / @as(F, @floatFromInt(discretized.len)));

            std.debug.print("point count: {d}\n", .{discretized.len});
            std.debug.print("cumulative error: {d}\n", .{cumulative_error});
            std.debug.print("absolute cumulative error: {d}\n", .{cumulative_error_abs});
            std.debug.print("average error per point: {d}\n", .{average_error});
            std.debug.print("max error: {d} ({d}/{d})\n", .{ max_error, max_error_idx, max_error_idx + 1 });
            std.debug.print("\n", .{});
        }
    };
}

test {
    testing.refAllDecls(@This());

    testing.refAllDeclsRecursive(catmull_rom(f32, .{ .trapezoid = .{} }));
    testing.refAllDeclsRecursive(catmull_rom(f64, .{ .trapezoid = .{} }));
    testing.refAllDeclsRecursive(catmull_rom(f32, .{ .simpson_adaptive = .{} }));
    testing.refAllDeclsRecursive(catmull_rom(f64, .{ .simpson_adaptive = .{} }));
}
