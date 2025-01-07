pub const path = @import("geo/path.zig");
pub const points = @import("geo/points.zig");
pub const splines = @import("geo/splines.zig");

test {
    const testing = @import("std").testing;
    testing.refAllDeclsRecursive(@This());
}
