pub const path = @import("geo/path.zig");
pub const linalg = @import("geo/linalg.zig");
pub const splines = @import("geo/splines.zig");

test {
    const testing = @import("std").testing;
    testing.refAllDeclsRecursive(@This());
}
