const std = @import("std");
const stdx = @import("stdx");
const stbi = @import("stbi");

track: Track,
background: stdx.Asset.Name,

pub const Name = []const u8;
pub const Id = u32;

pub const Track = struct {
    nodes: []GoonTrace.Node,
    kinds: []GoonTrace.Node.Kind,
};
