const builtin = @import("builtin");
const std = @import("std");
const math = std.math;
const testing = std.testing;

const assert = std.debug.assert;
const log = std.log.scoped(.integrate);

pub const default_epsilon = math.pow(f32, 10.0, -4.0);

pub const GaussLegendreQuadOptions = struct {
    /// max error tolerance
    eps: f32 = default_epsilon,
    /// number of sample points, result is exact for polynomials of degree `2*n - 1`
    n: u16 = 8,
};
pub fn gaussLegendreQuad(
    /// needs `fn (f32, ...) f32`
    comptime integrand: anytype,
    /// additional args after first one, needs to be a tuple
    integrand_extra_args: anytype,
    a: f32,
    b: f32,
    options: GaussLegendreQuadOptions,
) f32 {
    _ = .{ integrand, integrand_extra_args, a, b, options };
    @compileError("TODO");
}

pub fn SimpsonAdaptiveResult(comptime F: type) type {
    return struct { result: F, hit_limit: bool };
}
pub fn SimpsonAdaptiveOptions(comptime F: type) type {
    return struct {
        /// max error tolerance
        eps: F = math.pow(F, 10, -6),
        /// recursion depth limit
        limit: u16 = 100,
    };
}
/// https://en.wikipedia.org/wiki/Adaptive_Simpson
pub fn simpsonAdaptive(
    /// needs a floating point type
    comptime F: type,
    /// needs `fn (F, ...) F`
    comptime integrand: anytype,
    /// additional args after first one, needs to be a tuple
    integrand_extra_args: anytype,
    a: F,
    b: F,
    options: SimpsonAdaptiveOptions(F),
) SimpsonAdaptiveResult(F) {
    comptime validateIntegrand(F, @TypeOf(integrand), @TypeOf(integrand_extra_args));

    assert(a <= b);

    const h = (b - a);
    if (h == 0.0) {
        @branchHint(.unlikely);
        return .{ .result = 0.0, .hit_limit = false };
    }

    const ia = callIntegrand(integrand, a, integrand_extra_args);
    const ib = callIntegrand(integrand, b, integrand_extra_args);
    const im = callIntegrand(integrand, (a + b) / 2.0, integrand_extra_args);
    const whole = (h / 6.0) * (ia + 4.0 * im + ib);
    // zig fmt: off
    return simpsonAdaptiveAux(
        F,
        integrand,
        integrand_extra_args,
        a, b,
        options.eps,
        whole,
        ia, ib, im,
        @intCast(options.limit),
    );
    // zig fmt: on
}

// zig fmt: off
fn simpsonAdaptiveAux(
    comptime F: type,
    comptime integrand: anytype,
    integrand_extra_args: anytype,
    a: F, b: F,
    eps: F,
    whole: F,
    ia: F, ib: F, im: F,
    rec: i32,
) SimpsonAdaptiveResult(F) {
// zig fmt: on
    assert(a <= b);

    if ((b - a) < math.floatEps(F)) {
        @branchHint(.unlikely);
        return .{ .result = whole, .hit_limit = false };
    }

    const m = (a + b) / 2.0;
    const h = (b - a) / 2.0;
    const lm = (a + m) / 2.0;
    const rm = (m + b) / 2.0;

    const ilm = callIntegrand(integrand, lm, integrand_extra_args);
    const irm = callIntegrand(integrand, rm, integrand_extra_args);
    const left = ((h / 6.0) * (ia + 4.0 * ilm + im));
    const right = ((h / 6.0) * (im + 4.0 * irm + ib));
    const delta = (left + right - whole);

    if (rec <= 0 or @abs(delta) <= (15.0 * eps)) {
        @branchHint(.unlikely);
        return .{
            .result = (left + right + (delta / 15.0)),
            .hit_limit = (rec <= 0),
        };
    }
    // zig fmt: off
    const res1 = simpsonAdaptiveAux(
        F,
        integrand,
        integrand_extra_args,
        a, m,
        (eps * 0.5),
        left,
        ia, im, ilm,
        (rec - 1),
    );
    const res2 = simpsonAdaptiveAux(
        F,
        integrand,
        integrand_extra_args,
        m, b,
        (eps * 0.5),
        right,
        im, ib, irm,
        (rec - 1),
    );
    // zig fmt: on
    return .{
        .result = (res1.result + res2.result),
        .hit_limit = (res1.hit_limit or res2.hit_limit),
    };
}

fn testIntegrand(comptime F: type) type {
    return struct {
        pub fn integrand(x: F) F {
            return ((math.pi * @sin(@sqrt(x)) * @exp(@sqrt(x))) / @sqrt(x));
        }
    };
}

test simpsonAdaptive {
    const F = f64;
    const i = testIntegrand(F);

    const options = SimpsonAdaptiveOptions(F){};
    {
        const result = simpsonAdaptive(F, i.integrand, .{}, 10.0, 20.0, options);
        try testing.expect(result.hit_limit == false);
        const expected: F = -274.3517875485388;
        try testing.expectApproxEqAbs(expected, result.result, options.eps);
    }
    {
        const result = simpsonAdaptive(F, i.integrand, .{}, 10.0, 50.0, options);
        try testing.expect(result.hit_limit == false);
        const expected: F = -59.67134135120781;
        try testing.expectApproxEqAbs(expected, result.result, options.eps);
    }
}

pub const TrapezoidOptions = struct {
    subdivisions: usize = 100,
};
pub fn trapezoid(
    /// needs a float
    comptime F: type,
    /// needs `fn (F, ...) F`
    comptime integrand: anytype,
    /// additional args after first one, needs to be a tuple
    integrand_extra_args: anytype,
    a: F,
    b: F,
    options: TrapezoidOptions,
) F {
    comptime validateIntegrand(F, @TypeOf(integrand), @TypeOf(integrand_extra_args));

    assert(a <= b);

    const h = ((b - a) / @as(F, @floatFromInt(options.subdivisions)));
    if (h == 0.0) return 0.0;

    var sum: F = 0.0;
    for (0..options.subdivisions) |i| {
        const x0 = (a + (@as(F, @floatFromInt(i)) * h));
        const x1 = (x0 + h);
        const f0 = callIntegrand(integrand, x0, integrand_extra_args);
        const f1 = callIntegrand(integrand, x1, integrand_extra_args);
        sum += (0.5 * h * (f0 + f1));
    }
    return sum;
}

test trapezoid {
    const F = f64;
    const i = testIntegrand(F);

    const eps = math.pow(F, 10.0, -3.0);
    {
        const result = trapezoid(F, i.integrand, .{}, 10.0, 20.0, .{});
        const expected: F = -274.3517875485388;
        try testing.expectApproxEqRel(expected, result, eps);
    }
    {
        const result = trapezoid(F, i.integrand, .{}, 10.0, 50.0, .{ .subdivisions = 500 });
        const expected: F = -59.67134135120781;
        try testing.expectApproxEqRel(expected, result, eps);
    }
}

inline fn callIntegrand(comptime integrand: anytype, x: anytype, extra_args: anytype) @TypeOf(x) {
    return @call(.auto, integrand, .{x} ++ extra_args);
}

fn validateIntegrand(comptime F: type, comptime Integrand: type, comptime ExtraArgs: type) void {
    comptime {
        const params = switch (@typeInfo(Integrand)) {
            .@"fn" => |f| blk: {
                if (f.return_type == null or f.return_type.? != F or f.params.len == 0 or f.params[0].type == null or f.params[0].type.? != F) {
                    @compileError("invalid function signature, needs 'fn (" ++ @typeName(F) ++ ", ...) " ++ @typeName(F) ++ "'");
                }
                break :blk f.params[1..];
            },
            else => @compileError("needs function, got '" ++ @typeName(Integrand) ++ "'"),
        };

        const given = switch (@typeInfo(ExtraArgs)) {
            .@"struct" => |s| blk: {
                if (!s.is_tuple) {
                    @compileError("needs tuple, got struct");
                }
                if (s.fields.len != params.len) {
                    @compileError("tuple has incorrect amount of members");
                }
                break :blk s.fields;
            },
            else => @compileError("needs tuple, got '" ++ @typeName(ExtraArgs) ++ "'"),
        };

        for (0..params.len) |i| {
            if (params[i].type == null or params[i].type.? != given[i].type) {
                @compileError("needs '" ++ @typeName(params[i].type orelse void) ++ "', got '" ++ @typeName(given[i].type) ++ "'");
            }
        }
    }
}
