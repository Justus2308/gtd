const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");

const mem = std.mem;

const Allocator = mem.Allocator;
const Vec2D = geo.points.Vec2D;

const assert = std.debug.assert;


pub const catmull_rom = struct {
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

    pub fn length(p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D) f32 {
        return stdx.integrate.simpsonAdaptive(
            catmull_rom.integrandLength,
            .{ p1, p2, p3, p4 },
            0.0, 1.0,
            .{},
        );
    }
    fn integrandLength(t: f32, p1: Vec2D, p2: Vec2D, p3: Vec2D, p4: Vec2D) f32 {
        return catmull_rom.point(p1, p2, p3, p4, t);
    }

    pub fn discretize(
        allocator: Allocator,
        spline: []Vec2D,
        sample_dist: f32,
    ) Allocator.Error![]Vec2D {
        assert(sample_dist > 0.0);

        const samples = std.ArrayListUnmanaged(Vec2D).empty;
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

            var t: f32 = toff;
            while (rlen > 0.0) : ({
                rlen -= sample_dist;
                t += tstep;
            }) {
                const p = catmull_rom.point(spline[i+0], spline[i+1], spline[i+2], spline[i+3], t);
                try samples.append(allocator, p);
            }
            assert(std.math.approxEqAbs(f32, t, 1.0, (tstep + std.math.floatEps(f32))));
            offset = -rlen;
        }

        const slice = try samples.toOwnedSlice(allocator);
        return slice;
    }
};
