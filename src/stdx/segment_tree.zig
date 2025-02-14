const std = @import("std");

const mem = std.mem;

const Allocator = mem.Allocator;

/// 1-indexed to enable efficient child/parent calculation.
pub fn SegmentTree(
    comptime Bound: type,
    comptime Data: type,
    comptime lessThanFn: fn (a: Bound, b: Bound) bool,
) type {
    return struct {
        segments: []Segment,

        const Self = @This();


        pub const Segment = struct {
            start: Bound,
            end: Bound,
            data: Data,

            pub fn lessThan(a: Segment, b: Segment) bool {
                return @call(.always_inline, lessThanFn, .{ a, b });
            }
        };

        pub const empty = Self{
            .segments = &.{},
            .capacity = 0,
        };

        pub const BuildOptions = struct {
            reorder: bool = true,
        };
        pub fn build(allocator: Allocator, source: []Interval, options: BuildOptions) Allocator.Error!Self {
            const max_size = (4 * capacity);
            const segments = try allocator.alloc(Segment, max_size);
            const self =  Self{
                .segments = segments,
            };
            self.buildHelper(source, 1, 0, source.len-1);
            if (options.reorder) {
                self.reorder();
            }
            return self;
        }

        fn buildHelper(self: Self, source: []Segment, i: usize, tl: Bound, tr: Bound) void {
            const t = self.segments;
            if (tl != tr) {
                const tm = (tl + tr) >> 1;
                self.buildHelper(source, lhs(i), tl, tm);
                self.buildHelper(source, rhs(i), tm+1, tr);
            }
            t[v] = a[tl];
        }

        pub fn query(comptime kind: Query)

        pub fn reorder(self: *Self) Allocator.Error!void {

        }

        inline fn lhs(i: usize) usize {
            return (2 * i);
        }
        inline fn rhs(i: usize) usize {
            return ((2 * i) + 1);
        }
        inline fn parent(i: usize) usize {
            return (i >> 1);
        }
    };
}
