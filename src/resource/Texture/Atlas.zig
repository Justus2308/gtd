//! Constructs a packed atlas from rectangular textures on the fly.
//! Based on:
//! * Exploring rectangle packing algorithms (David Colson, 2020)
//!     at https://www.david-colson.com/2020/03/10/exploring-rect-packing.html
//! * A Thousand Ways to Pack The Bin (Jukka Jylänki, 2010)
//!     at https://github.com/juj/RectangleBinPack/blob/master/RectangleBinPack.pdf

units: []Unit,

const Atlas = @This();

pub const Unit = struct {
    base: [2]f32,
    sides: [2]f32,
};

pub const Builder = struct {
    textures: std.ArrayListUnmanaged(Texture),

    pub const init = Builder{};

    pub fn update(
        b: *Builder,
        allocator: Allocator,
        texture: Texture,
    ) Allocator.Error!void {}

    pub fn final(b: Builder, allocator: Allocator) Allocator.Error!Atlas {}

    /// RGBA
    fn failColor(comptime T: type) [4]T {
        const max_value = switch (@typeInfo(T)) {
            .int => std.math.maxInt(T),
            .float => @as(T, 1.0),
            else => @compileError("invalid color type"),
        };
        return .{ max_value, 0, max_value, max_value };
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const Texture = @import("../Texture.zig");
