const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");

const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Vec2D = geo.points.Vec2D;

const assert = std.debug.assert;


pub const catmull_rom = struct {
    /// Produces centripetal splines
    pub const Parametrization = enum(u32) {
        uniform = @bitCast(@as(f32, 0.0)),
        centripetal = @bitCast(@as(f32, 0.5)),
        chordal = @bitCast(@as(f32, 1.0)),
        _,

        pub inline fn custom(value: f32) Parametrization {
            return @enumFromInt(@as(u32, @bitCast(value)));
        }
    };

    pub fn point(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, t: f32) Vec2D {
        const q0: f32 = (-1.0*t*t*t) + (2.0*t*t) + (-1.0*t);
        const q1: f32 = (3.0*t*t*t) + (-5.0*t*t) + 2.0;
        const q2: f32 = (-3.0*t*t*t) + (4.0*t*t) + t;
        const q3: f32 = t*t*t - t*t;

        return .{
            .x = 0.5*((p1.x*q0) + (p2.x*q1) + (p3.x*q2) + (p4.x*q3)),
            .y = 0.5*((p1.y*q0) + (p2.y*q1) + (p3.y*q2) + (p4.y*q3)),
        };
    }

    pub fn deriv(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D, t: f32) Vec2D {
        const q0: f32 = (-2.0*t*t) + (4.0*t) + (-1.0);
        const q1: f32 = (9.0*t*t) + (-10.0*t);
        const q2: f32 = (-9.0*t*t) + (8.0*t) + 1.0;
        const q3: f32 = (3.0*t*t) + (-2.0*t);

        return .{
            .x = 0.5*((p1.x*q0) + (p2.x*q1) + (p3.x*q2) + (p4.x*q3)),
            .y = 0.5*((p1.y*q0) + (p2.y*q1) + (p3.y*q2) + (p4.y*q3)),
        };
    }

    pub fn length(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D) f32 {
        return stdx.integrate.simpsonAdaptive(
            catmull_rom.integrandLength,
            .{ p1, p2, p3, p4 },
            0.0, 1.0,
            .{},
        );
    }
    fn integrandLength(t: f32, p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D) f32 {
        const dt = catmull_rom.deriv(p1, p2, p3, p4, t);
        const dt_norm = dt.length();
        return dt_norm;
    }

    // TODO falsch
    fn integrandT(len: f32, p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D) f32 {
        const dt = catmull_rom.deriv(p1, p2, p3, p4, len);
        const dt_norm = dt.length();
        if (dt_norm < stdx.integrate.default_epsilon) {
            @branchHint(.unlikely);
            return stdx.integrate.default_epsilon;
        }
        return @as(f32, 1.0) / dt_norm;
    }
    // TODO falsch
    pub fn discretize(
        allocator: Allocator,
        spline: []const Vec2D,
        sample_dist: f32,
    ) Allocator.Error![]Vec2D {
        assert(sample_dist > 0.0);

        var samples = std.ArrayListUnmanaged(Vec2D).empty;
        errdefer samples.deinit(allocator);

        var offset: f32 = 0.0;
        for (0..(spline.len -| 3)) |i| {
            const len = catmull_rom.length(spline[i+0], spline[i+1], spline[i+2], spline[i+3]);

            var covered: f32 = 0.0;
            var next: f32 = if (offset == 0.0) sample_dist else offset;
            while (next <= len) : ({
                covered = next;
                next += sample_dist;
            }) {
                const t = stdx.integrate.simpsonAdaptive(
                    catmull_rom.integrandT,
                    .{ spline[i+0], spline[i+1], spline[i+2], spline[i+3] },
                    covered, next,
                    .{},
                );
                const p = catmull_rom.point(spline[i+0], spline[i+1], spline[i+2], spline[i+3], t);
                try samples.append(allocator, p);
            }
            offset = next - len;
        }

        const slice = try samples.toOwnedSlice(allocator);
        return slice;
    }

    pub fn discretize2(
        allocator: Allocator,
        spline: []const Vec2D,
        sample_dist: f32,
    ) Allocator.Error![]Vec2D {
        assert(sample_dist > 0.0);

        var samples = std.ArrayListUnmanaged(Vec2D).empty;
        errdefer samples.deinit(allocator);

        var offset: f32 = 0.0;
        for (0..(spline.len -| 3)) |i| {
            const len = catmull_rom.length(spline[i+0], spline[i+1], spline[i+2], spline[i+3]);
            var rlen = len - offset;
            if (rlen <= 0.0) {
                // spline segment is shorter than our step size, skip it
                @branchHint(.unlikely);
                offset -= len;
                continue;
            }
            const max_sample_count = @divFloor(rlen, sample_dist);
            const rem = @rem(rlen, sample_dist);

            const toff = offset / len;
            const trem = rem / len;
            const tstep = (@as(f32, 1.0) - toff - trem) / max_sample_count;

            std.debug.print("seg={d} ; offset={e}\n", .{ i, stdx.integrate.simpsonAdaptive(
                catmull_rom.integrandLength,
                .{ spline[i+0], spline[i+1], spline[i+2], spline[i+3] },
                0.0, toff,
                .{},
            ) });

            var t: f32 = toff;
            while (rlen > 0.0) : ({
                rlen -= sample_dist;
                t += tstep;
            }) {
                std.debug.print("seg={d} ; len={e}\n", .{ i, stdx.integrate.simpsonAdaptive(
                    catmull_rom.integrandLength,
                    .{ spline[i+0], spline[i+1], spline[i+2], spline[i+3] },
                    t, @min(1.0, t+tstep),
                    .{},
                ) });
                const p = catmull_rom.point(spline[i+0], spline[i+1], spline[i+2], spline[i+3], t);
                try samples.append(allocator, p);
            }
            assert(std.math.approxEqAbs(f32, t, 1.0, (tstep + std.math.floatEps(f32))));
            offset = -rlen;
        }

        const slice = try samples.toOwnedSlice(allocator);
        return slice;
    }


    // /\
    //   \  /
    //    \/
    const test_spline = [_]Vec2D{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 1.0, .y = 2.0 },
        .{ .x = 3.0, .y = 3.0 },
        .{ .x = 5.0, .y = 0.0 },
        .{ .x = 7.0, .y = 2.0 },
        .{ .x = 9.0, .y = 0.0 },
    };

    test length {
        var len: f32 = 0.0;
        for (0..test_spline.len-3) |i| {
            const len_segment = catmull_rom.length(
                test_spline[i+0],
                test_spline[i+1],
                test_spline[i+2],
                test_spline[i+3],
            );
            len += len_segment;
        }
        try testing.expectApproxEqRel(len, 9.5670, stdx.integrate.default_epsilon*10.0);
    }

    test discretize {
        const allocator = testing.allocator;

        const sample_dist = 1.0;
        const discretized = try catmull_rom.discretize(allocator, &test_spline, sample_dist);
        defer allocator.free(discretized);

        std.debug.print("{any}\n", .{ discretized });
        const expected = [_]Vec2D{
            .{ .x = 1.000000, .y = 2.000000 },
            .{ .x = 1.771103, .y = 2.696569 },
            .{ .x = 2.672819, .y = 3.076544 },
            .{ .x = 3.348697, .y = 2.651917 },
            .{ .x = 3.909820, .y = 1.623593 },
            .{ .x = 4.474950, .y = 0.532280 },
            .{ .x = 5.032064, .y = -0.006235 },
            .{ .x = 5.585170, .y = 0.340238 },
            .{ .x = 6.134269, .y = 1.147060 },
            .{ .x = 6.687375, .y = 1.858368 },
        };
        for (expected, discretized) |e, d| {
            try testing.expectApproxEqRel(e.x, d.x, stdx.integrate.default_epsilon*10);
            try testing.expectApproxEqRel(e.y, d.y, stdx.integrate.default_epsilon*10);
        }
    }
};
