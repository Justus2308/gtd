const std = @import("std");
const geo = @import("geo");

const mem = std.mem;

const Allocator = mem.Allocator;
const Vec2D = geo.points.Vec2D;

pub const Spline = struct {
    points: []Vec2D,
    length: f32,

    pub fn discretize(spline: Spline, allocator: Allocator, sample_count: usize) Allocator.Error![]Vec2D {
        const tstep = spline.length / @as(f32, @floatFromInt(sample_count));
        const dest = try allocator.alloc(Vec2D, sample_count);
        errdefer allocator.free(dest);

        var t: f32 = 0.0;
        for (0..sample_count) |i| {
            t += tstep;

            var p: Vec2D = undefined;

            const q0: f32 = (-1.0*t*t*t) + (2.0*t*t) + (-1.0*t);
            const q1: f32 = (3.0*t*t*t) + (-5.0*t*t) + 2.0;
            const q2: f32 = (-3.0*t*t*t) + (4.0*t*t) + t;
            const q3: f32 = t*t*t - t*t;

            point.x = 0.5*((p1.x*q0) + (p2.x*q1) + (p3.x*q2) + (p4.x*q3));
            point.y = 0.5*((p1.y*q0) + (p2.y*q1) + (p3.y*q2) + (p4.y*q3));
        }
    }
};
