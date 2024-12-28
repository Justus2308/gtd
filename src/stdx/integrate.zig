const std = @import("std");
const math = std.math;
const testing = std.testing;

const assert = std.debug.assert;


pub const GaussLegendreQuadOptions = struct {
    /// max error tolerance
    eps: f32 = math.pow(f32, 1.0, -6.0),
    /// number of sample points, result is exact for polynomials of degree `2*n - 1`
    n: u16 = 8,
};
pub fn gaussLegendreQuad(
    /// needs `fn (f32, ...) f32`
    comptime integrand: anytype,
    /// additional args after first one, needs to be a tuple
    integrand_extra_args: anytype,
    a: f32, b: f32,
    options: GaussLegendreQuadOptions,
) f32 {
    _ = .{ integrand, integrand_extra_args, a, b, options };
    @compileError("TODO");
}


pub const SimpsonAdaptiveOptions = struct {
    /// max error tolerance
    eps: f32 = math.pow(f32, 1.0, -6.0),
    /// recursion depth limit
    limit: u16 = 50,
};
/// https://en.wikipedia.org/wiki/Adaptive_Simpson
pub fn simpsonAdaptive(
    /// needs `fn (f32, ...) f32`
    comptime integrand: anytype,
    /// additional args after first one, needs to be a tuple
    integrand_extra_args: anytype,
    a: f32, b: f32,
    options: SimpsonAdaptiveOptions,
) f32 {
    comptime validateIntegrand(@TypeOf(integrand), @TypeOf(integrand_extra_args));

    assert(a <= b);

    const h = b - a;
    if (h == 0.0) return 0.0;

    const ia = callIntegrand(integrand, a, integrand_extra_args);
    const ib = callIntegrand(integrand, b, integrand_extra_args);
    const im = callIntegrand(integrand, (a+b)/2.0, integrand_extra_args);
    const whole = (h/6.0)*(ia + 4.0*im + ib);
    return simpsonAdaptiveAux(integrand, integrand_extra_args,
        a, b, options.eps, whole, ia, ib, im, @intCast(options.limit));
}
fn simpsonAdaptiveAux(
    comptime integrand: anytype,
    integrand_extra_args: anytype,
    a: f32, b: f32,
    eps: f32,
    whole: f32,
    ia: f32, ib: f32, im: f32,
    rec: i32,
) f32 {
    assert(a < b);

    const m = (a+b)/2.0;
    const h = (b-a)/2.0;
    const lm = (a+m)/2.0;
    const rm = (m+b)/2.0;

    if ((eps/2.0 == eps) or (a == lm)) return whole;

    const ilm = callIntegrand(integrand, lm, integrand_extra_args);
    const irm = callIntegrand(integrand, rm, integrand_extra_args);
    const left = (h/6.0) * (ia + 4.0*ilm + im);
    const right = (h/6.0) * (im + 4.0*irm + ib);
    const delta = left + right - whole;

    if (rec <= 0 or @abs(delta) <= 15.0*eps)
        return left + right + delta/15.0;

    return simpsonAdaptiveAux(integrand, integrand_extra_args,
            a, m, eps/2.0, left,  ia, im, ilm, rec-1)
         + simpsonAdaptiveAux(integrand, integrand_extra_args,
            m, b, eps/2.0, right, im, ib, irm, rec-1);
}

test simpsonAdaptive {
    const i = struct {
        pub fn exampleIntegrand(x: f32) f32 {
            return (math.pi * @sin(@sqrt(x)) * @exp(@sqrt(x))) / @sqrt(x);
        }
    };

    const options = SimpsonAdaptiveOptions{};

    const result = simpsonAdaptive(i.exampleIntegrand, .{}, 10.0, 20.0, options);
    const expected: f32 = -274.3517875485388;
    try testing.expect(math.approxEqAbs(f32, expected, result, options.eps));

    const result2 = simpsonAdaptive(i.exampleIntegrand, .{}, 10.0, 50.0, options);
    const expected2: f32 = -59.67134135120781;
    try testing.expect(math.approxEqAbs(f32, expected2, result2, options.eps));
}


pub const TrapezoidOptions = struct {
    subdivisions: usize = 100,
};
pub fn trapezoid(
    /// needs `fn (f32, ...) f32`
    comptime integrand: anytype,
    /// additional args after first one, needs to be a tuple
    integrand_extra_args: anytype,
    a: f32, b: f32,
    options: TrapezoidOptions,
) f32 {
    comptime validateIntegrand(@TypeOf(integrand), @TypeOf(integrand_extra_args));

    assert(a <= b);

    const h = (b - a) / @as(f32, @floatFromInt(options.subdivisions));
    if (h == 0.0) return 0.0;

    var sum: f32 = 0.0;
    for (0..options.subdivisions) |i| {
        const x0 = a + @as(f32, @floatFromInt(i)) * h;
        const x1 = x0 + h;
        const f0 = callIntegrand(integrand, x0, integrand_extra_args);
        const f1 = callIntegrand(integrand, x1, integrand_extra_args);
        sum += 0.5 * h * (f0 + f1);
    }
    return sum;
}


inline fn callIntegrand(comptime integrand: anytype, x: f32, extra_args: anytype) f32 {
    return @call(.auto, integrand, .{ x } ++ extra_args);
}

fn validateIntegrand(comptime Integrand: type, comptime ExtraArgs: type) void {
    comptime {
        const params = switch (@typeInfo(Integrand)) {
            .@"fn" => |f| blk: {
                if (f.return_type == null
                    or f.return_type.? != f32
                    or f.params.len == 0
                    or f.params[0].type == null
                    or f.params[0].type.? != f32
                ) {
                    @compileError("invalid function signature, needs 'fn (f32, ...) f32'");
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
                @compileError("needs '" ++ @typeName(params[i].type orelse void)
                    ++ "', got '" ++ @typeName(given[i].type) ++ "'");
            }
        }
    }
}
