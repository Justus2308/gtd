const std = @import("std");
const Ape = @import("../Ape.zig");

pub const upgrades = std.enums.directEnumArray(Ape.Kind, [5]Ape.Immutable.Upgrade, 0, .{
    
});
