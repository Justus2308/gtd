const std = @import("std");
const Goon = @import("../Goon.zig");
const cache_line = std.atomic.cache_line;


const immutable_templates = std.enums.directEnumArray(
    Goon.attributes.Kind,
    Goon.attributes.Immutable.Template,
    0,
    .{
        .normal = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 1.0,
            .base_speed = 100.0,
            .children = .{},
            .children_lategame = .{},
            .size = .small,
        }),
        .black = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 1.0,
            .base_speed = 180.0,
            .children = .{ .normal = 2 },
            .children_lategame = .{ .normal = 1 },
            .size = .small,

            .immunity = .{ .black = true },
        }),
        .white = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 1.0,
            .base_speed = 200.0,
            .children = .{ .normal = 2 },
            .children_lategame = .{ .normal = 1 },
            .size = .small,

            .immunity = .{ .white = true },
        }),
        .purple = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 1.0,
            .base_speed = 300.0,
            .children = .{ .normal = 2 },
            .children_lategame = .{ .normal = 1 },
            .size = .small,

            .immunity = .{ .purple = true },
        }),
        .lead = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 1.0,
            .base_speed = 100.0,
            .children = .{ .black = 2 },
            .children_lategame = .{ .black = 1 },
            .size = .small,

            .immunity = .{ .lead = true },
            .fortified_factor = 4.0,
        }),
        .zebra = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 1.0,
            .base_speed = 180.0,
            .children = .{
                .black = 1,
                .white = 1,
            },
            .children_lategame = .{ .black = 1 },
            .size = .small,

            .immunity = .{
                .black = true,
                .white = true,
            },
        }),
        .rainbow = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 1.0,
            .base_speed = 220.0,
            .children = .{ .zebra = 2 },
            .children_lategame = .{ .zebra = 1 },
            .size = .small,
        }),
        .ceramic = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 10.0,
            .base_speed = 250.0,
            .children = .{ .rainbow = 2 },
            .children_lategame = .{ .rainbow = 1 },
            .size = .small,
        }),
        .super_ceramic = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 60.0,
            .base_speed = 250.0,
            .children = .{ .rainbow = 1 },
            .children_lategame = .{ .rainbow = 1 },
            .size = .small,
        }),
        .moab = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 200.0,
            .base_speed = 100.0,
            .children = .{ .ceramic = 4 },
            .children_lategame = .{ .super_ceramic = 4 },
            .size = .large,

            .inherits_fortified = true,
        }),
        .bfb = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 700.0,
            .base_speed = 25.0,
            .children = .{ .moab = 4 },
            .children_lategame = .{ .moab = 4 },
            .size = .large,

            .inherits_fortified = true,
        }),
        .zomg = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 4000.0,
            .base_speed = 18.0,
            .children = .{ .bfb = 4 },
            .children_lategame = .{ .bfb = 4 },
            .size = .large,

            .inherits_fortified = true,
        }),
        .ddt = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 400.0,
            .base_speed = 275.0,
            .children = .{ .ceramic = 4 },
            .children_lategame = .{ .super_ceramic = 4 },
            .size = .large,

            .immunity = .{
                .black = true,
                .lead = true,
            },
            .inherits_fortified = true,
        }),
        .bad = Goon.attributes.Immutable.makeTemplate(.{
            .base_hp = 20000.0,
            .base_speed = 18.0,
            .children = .{
                .zomg = 2,
                .ddt = 3,
            },
            .children_lategame = .{
                .zomg = 2,
                .ddt = 3,
            },
            .size = .large,

            .inherits_fortified = true, // TODO rename
        }),
    },
);

pub const immutable_earlygame align(cache_line) = Goon.attributes.Immutable.Template.resolve(&immutable_templates, false);
pub const immutable_lategame align(cache_line) = Goon.attributes.Immutable.Template.resolve(&immutable_templates, true);

/// Add this to the base speed depending on color before converting to float.
pub const base_speed_offset_table = std.enums.directEnumArray(Goon.attributes.Mutable.Color, f32, 0, .{
    .none = 0.0,
    .red = 0.0,
    .blue = 40.0,
    .green = 80.0,
    .yellow = 220.0,
    .pink = 250.0,
});
