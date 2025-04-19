impl: Impl,

const Renderer = @This();
const Impl = @import("Renderer/Sokol.zig");

pub fn init(allocator: Allocator) Renderer {}

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
