const data = @import("Round/data.zig");
const Template = @import("entities").Goon.attributes.Template;
const assert = @import("std").debug.assert;


id: u64,
waves: []Wave,

pub const Wave = struct {
	start: f16,
	end: f16,
	count: u16,
	goon_template: Template,

	comptime {
		assert(@sizeOf(Wave) == @sizeOf(u64));
		assert(@alignOf(Wave) == @alignOf(u64));
	}
};

pub const normal = data.normal;
pub const alternate = data.alternate;
