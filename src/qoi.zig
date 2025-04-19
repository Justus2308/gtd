const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const DecodeError = Allocator.Error || error{
    InvalidMagic,
    InvalidChannelCount,
    InvalidColorspace,
};

const header_size = 14;
const qoi_magic = [4]u8{ 'q', 'o', 'i', 'f' };

pub fn decodeStream(allocator: Allocator, reader: anytype) (@TypeOf(reader).Error || DecodeError)!Image {
    const header_bytes = try reader.readBytes(14);
    if (@as(u32, @bitCast(header_bytes[0..4].*)) != @as(u32, @bitCast(qoi_magic))) {
        @branchHint(.unlikely);
        return DecodeError.InvalidMagic;
    }
    const width = mem.readInt(u32, header_bytes[4..8], .big);
    const height = mem.readInt(u32, header_bytes[8..12], .big);
    const has_alpha = switch (header_bytes[12]) {
        3 => false,
        4 => true,
        else => {
            @branchHint(.unlikely);
            return DecodeError.InvalidChannelCount;
        },
    };
    const colorspace = std.meta.intToEnum(
        Image.Colorspace,
        header_bytes[13],
    ) catch return DecodeError.InvalidColorspace;

    var cache: [64][4]u8 = @splat(.{ 0, 0, 0, 0 });
    var prev: @Vector(4, u8) = .{ 0, 0, 0, 255 };
}

pub const Image = struct {
    width: u32,
    height: u32,
    colorspace: Colorspace,
    has_alpha: bool,
    data: []const u8,

    pub const Colorspace = enum(u8) {
        srgb = 0,
        linear = 1,
    };
};

const Tag = enum(u8) {
    rgb = 0b11111110,
    rgba = 0b11111111,
    index = 0b00111111,
    diff = 0b01111111,
    luma = 0b10111111,
    run = 0b11111111,

    pub inline fn get(byte: u8) Tag {
        return @enumFromInt(byte | @as(u8, 0b11111100));
    }

    pub inline fn getIndex(byte: u8) u6 {
        return @truncate(byte);
    }
    pub inline fn get
};
inline fn hashIndex(rgba: [4]u8) u6 {
    return @truncate((rgba[0] *% 3 +% rgba[1] *% 5 +% rgba[2] *% 7 +% rgba[3] *% 11));
}
