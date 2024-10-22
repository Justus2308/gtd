const std = @import("std");
const raylib = @import("raylib");

const enums = std.enums;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const simd = std.simd;

const assert = std.debug.assert;


const Goon = @import("Goon.zig");


pub const Immutable = extern struct {
    base_dmg: f16,
    base_pierce: f16,
    base_atk_speed_linear: f16,
    base_atk_speed_angular: f16 = 0,
    base_range: f16,
    base_price: f16,
    dimensions: Dimensions,


    pub const Dimensions = packed struct(u32) {
        shape_and_x: TaggedUf16,
        rect_and_y: TaggedUf16,

        pub const TaggedUf16 = TaggedFloat(f16, .positive);

        pub const Init = union(Shape) {
            circle: f16,
            rectangle: struct {
                x: f16,
                y: ?f16 = null,
            },
        };
        pub fn init(dim_init: Init) Dimensions {
            return switch (dim_init) {
                .circle => |diameter| .{
                    .shape_and_x = TaggedUf16.init(@intFromEnum(Shape.circle), diameter),
                    .rect_and_y = TaggedUf16.init(0, 0),
                },
                .rectangle => |sides| .{
                    .shape_and_x = TaggedUf16.init(@intFromEnum(Shape.rectangle), sides.x),
                    .rect_and_y = if (sides.y) |y_| TaggedUf16.init(1, y_) else TaggedUf16.init(0, 0),
                },
            };
        }

        pub inline fn shape(dimensions: Dimensions) Shape {
            return @enumFromInt(dimensions.shape_and_x.tag);
        }
        pub inline fn x(dimensions: Dimensions) f16 {
            return dimensions.shape_and_x.getFloat();
        }
        pub inline fn y(dimensions: Dimensions) ?f16 {
            return if (dimensions.rect_and_y.tag == 1) dimensions.rect_and_y.getFloat() else null;
        }
    };
    pub const Shape = enum(u1) {
        circle,
        rectangle,
    };
    pub const Size = enum(u32) {
        tiny = @bitCast(@as(f32, 1.0)),
        small = @bitCast(@as(f32, 2.0)),
        medium = @bitCast(@as(f32, 3.0)),
        large = @bitCast(@as(f32, 4.0)),
        _, // will be interpreted as index into "special" list

        comptime {
            const max_special_index: u32 = undefined;
            assert(max_special_index < math.maxInt(u31));
            // Make sure that raw floats and "special" indices don't overlap.
            // This will always work for ieee floats.
            // TODO: offer alternative storage method in case of overlap
            for (meta.fields(Size)) |field| {
                assert(field.value > max_special_index);
            }
        }
    };

    pub const UpgradeVTable = struct {
        top: [5]*const upgradeFn,
        middle: [5]*const upgradeFn,
        bottom: [5]*const upgradeFn,
        paragon: ?*const upgradeFn,

        pub const upgradeFn = fn (mutable_list: *Mutable.List) void;

        comptime {
            assert(@sizeOf(UpgradeVTable) == (5+5+5+1)*@sizeOf(usize));
        }
    };
};

pub const Mutable = extern struct {
    vtable: *VTable,
    upgrades: Upgrades,

    pub const Upgrades = packed struct(u16) {
        top: u5 = 0,
        middle: u5 = 0,
        bottom: u5 = 0,
        paragon: bool = false,
    };

    pub const VTable = struct {
        attack: *const fn (mutable: *Mutable, dmg: f32, pierce: f32, speed_linear: f32, speed_angular: f32, range: f32, amount: u32, tag: u32) Attack,

    };

    pub const vtable_passive: *VTable = &.{
        .attack = undefined,
    };

    pub const List = std.MultiArrayList(Mutable);

    pub const max_per_page = mem.page_size / @sizeOf(Mutable);
};
