sub_path: [:0]const u8,
width: u32,
height: u32,
image: render.Renderer.Image,

const Texture = @This();

pub const default_sub_path = "textures/";
pub const default_suffix = ".qoi";

pub fn init(comptime name: [:0]const u8) Texture {
    const sub_path: [:0]const u8 = comptime (default_sub_path ++ name ++ default_suffix);
    return .{
        .sub_path = sub_path,
        .width = 0,
        .height = 0,
        .image = undefined,
    };
}

pub fn loader(texture: *Texture) Loader {
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

fn load(ctx: *anyopaque, allocator: Allocator, context: Loader.Context) !void {
    const texture: *Texture = @ptrCast(@alignCast(ctx));
    const file = try context.asset_dir.openFile(texture.sub_path, .{ .mode = .read_only });
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());

    const image = try qoi.decodeStream(allocator, buf_reader.reader());
    defer image.deinit(allocator);

    const render_image = Renderer.createTexture(image.width, image.height, image.pixels);

    log.info("loaded texture from '{s}'", .{texture.sub_path});
    texture.width = image.width;
    texture.height = image.height;
    texture.image = render_image;
}

fn unload(ctx: *anyopaque, allocator: Allocator) void {
    _ = allocator;
    const texture: *Texture = @ptrCast(@alignCast(ctx));
    Renderer.destroyTexture(texture.image);
    texture.width = 0;
    texture.height = 0;
    texture.image = undefined;
    log.info("unloaded texture from '{s}'", .{texture.sub_path});
}

const std = @import("std");
const render = @import("render");
const qoi = @import("qoi");

const Allocator = std.mem.Allocator;
const Loader = @import("Loader.zig");
const Renderer = render.Renderer;

const log = std.log.scoped(.texture);
