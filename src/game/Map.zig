const GoonTrace = @import("GoonTrace.zig");

track: Track,
background: *raylib.Image,


pub const Track = struct {
	nodes: []GoonTrace.Node,
	kinds: []GoonTrace.Node.Kind,
};
