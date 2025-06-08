width: u32,
height: u32,
flags: Flags,
image: sokol.gfx.Image,
pixel_loader: Loader,
load_consistency: std.debug.SafetyLock,

const Texture = @This();

pub const Flags = packed struct(u8) {
    endianness: Endianness,
    _1: u1 = 0,
    channels: Channels,
    depth: Depth,
    type: Type,

    pub const Endianness = enum(u1) {
        big = 0,
        little = 1,
    };

    pub const Channels = enum(u2) {
        grayscale = 0,
        grayscale_plus_alpha = 1,
        rgb = 2,
        rgba = 3,
    };

    pub const Depth = enum(u2) {
        @"8-bit" = 0,
        @"16-bit" = 1,
        @"32-bit" = 2,

        pub fn bytesPerPixel(depth: Depth) u16 {
            return (@as(u16, 1) << @intFromEnum(depth));
        }
    };

    pub const Type = enum(u2) {
        unsigned_normalized = 0,
        signed_normalized = 1,
        float = 2,
    };
};

pub fn init(
    width: u32,
    height: u32,
    flags: Flags,
    pixel_loader: Loader,
) Texture {
    return .{
        .width = width,
        .height = height,
        .flags = flags,
        .image = .{ .id = sokol.gfx.invalid_id },
        .pixel_loader = pixel_loader,
        .state_consistency = .{},
    };
}

/// Loads a `sokol.gfx.Image`.
pub fn loader(texture: *Texture) Loader {
    texture.load_consistency.assertUnlocked();
    return .{
        .ptr = texture,
        .vtable = &.{
            .hash = hash,
            .load = load,
            .unload = unload,
        },
    };
}

fn hash(ctx: *anyopaque) u64 {
    const texture: *Texture = @ptrCast(@alignCast(ctx));
    return Loader.autoHash(texture.sub_path);
}

fn load(ctx: *anyopaque, allocator: Allocator, context: Loader.Context) ![]const u8 {
    _ = allocator;

    const texture: *Texture = @ptrCast(@alignCast(ctx));

    texture.load_consistency.lock();
    errdefer texture.load_consistency.unlock();

    const pixel_bytes = try texture.pixel_loader.rawLoad(context.scratch_arena, context);
    defer texture.pixel_loader.rawUnload(context.scratch_arena, pixel_bytes);

    const pixel_format: sokol.gfx.PixelFormat = switch (texture.flags.channels) {
        .grayscale => switch (texture.flags.depth) {
            .@"8-bit" => switch (texture.flags.type) {
                .unsigned_normalized => .R8,
                .signed_normalized => .R8SN,
                .float => return error.Unexpected,
            },
            .@"16-bit" => switch (texture.flags.type) {
                .unsigned_normalized => .R16,
                .signed_normalized => .R16SN,
                .float => .R16F,
            },
            .@"32-bit" => switch (texture.flags.type) {
                .unsigned_normalized, .signed_normalized => return error.Unexpected,
                .float => .R32F,
            },
        },
        .grayscale_plus_alpha => switch (texture.flags.depth) {
            .@"8-bit" => switch (texture.flags.type) {
                .unsigned_normalized => .RG8,
                .signed_normalized => .RG8SN,
                .float => return error.Unexpected,
            },
            .@"16-bit" => switch (texture.flags.type) {
                .unsigned_normalized => .RG16,
                .signed_normalized => .RG16SN,
                .float => .RG16F,
            },
            .@"32-bit" => switch (texture.flags.type) {
                .unsigned_normalized, .signed_normalized => return error.Unexpected,
                .float => .RG32F,
            },
        },
        .rgba => switch (texture.flags.depth) {
            .@"8-bit" => switch (texture.flags.type) {
                .unsigned_normalized => .RGBA8,
                .signed_normalized => .RGBA8SN,
                .float => return error.Unexpected,
            },
            .@"16-bit" => switch (texture.flags.type) {
                .unsigned_normalized => .RGBA16,
                .signed_normalized => .RGBA16SN,
                .float => .RGBA16F,
            },
            .@"32-bit" => switch (texture.flags.type) {
                .unsigned_normalized, .signed_normalized => return error.Unexpected,
                .float => .RGBA32F,
            },
        },
    };

    texture.image = sokol.gfx.makeImage(.{
        .type = ._2D,
        .usage = .{ .immutable = true },
        .width = @intCast(texture.width),
        .height = @intCast(texture.height),
        .num_slices = 1,
        .num_mipmaps = 1,
        .pixel_format = pixel_format,
        .sample_count = 1,
        .data = init: {
            var image_data: sokol.gfx.ImageData = undefined;
            image_data[0][0] = sokol.gfx.asRange(pixel_bytes);
            break :init image_data;
        },
    });

    return std.mem.asBytes(&texture.image);
}

fn unload(ctx: *anyopaque, allocator: Allocator, bytes: []const u8) void {
    _ = allocator;

    const texture: *Texture = @ptrCast(@alignCast(ctx));

    texture.load_consistency.assertLocked();
    defer texture.load_consistency.unlock();

    const image_supplied = std.mem.bytesToValue(sokol.gfx.Image, bytes);
    assert(image_supplied == texture.image);

    sokol.gfx.destroyImage(texture.image);

    texture.image = undefined;
    texture.width = 0;
    texture.height = 0;
}

const std = @import("std");
const stdx = @import("stdx");
const sokol = @import("sokol");
const Allocator = std.mem.Allocator;
const Loader = @import("Loader.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.texture);
