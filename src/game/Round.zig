const data = @import("Round/data.zig");
const Goon = @import("entities").Goon;
const Template = Goon.attributes.Template;
const assert = @import("std").debug.assert;


id: u64,
waves: []Wave,

const Round = @This();

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


pub const lategame_start = 81;


pub fn estimateGoonCount(round: *Round) usize {
	var count: usize = 0;
    for (round.waves) |wave| {
        const immutable = Goon.getImmutable(wave.goon_template.kind);
        const child_count = if (round.id > lategame_start) immutable.child_count_lategame else immutable.child_count;
        count += (wave.count * (1 + child_count + @intFromBool(wave.goon_template.extra.regrow)));
    }
    return count;
}
