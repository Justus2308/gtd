pass_action: sokol.gfx.PassAction,
pipeline: sokol.gfx.Pipeline,
bindings: sokol.gfx.Bindings,
buffers: Buffers,

const Render = @This();

const Buffers = struct {};

pub fn init(allocator: Allocator) Render {
    _ = allocator;
    return Render{
        .pass_action = .{},
        .pipeline = .{},
        .bindings = .{},
    };
}

const std = @import("std");
const sokol = @import("sokol");
const Allocator = std.mem.Allocator;
