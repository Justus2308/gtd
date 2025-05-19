const std = @import("std");
const stbi = @import("stbi");
const qoi = @import("qoi");
const root = @import("root");
const assert = std.debug.assert;
const log = root.log;

pub fn convert(bytes: []const u8) ![]const u8 {
    var width: c_int, var height: c_int, var channels: c_int = undefined;
    const pixels: [*]u8 = stbi.stbi_load_from_memory(bytes.ptr, bytes.len, &width, &height, &channels, 0) orelse {
        log.err("stbi: failed to load image: {s}", .{stbi.stbi_failure_reason() orelse "unknown"});
        return error.StbImageLoadFailed;
    };
    defer stbi.stbi_image_free(pixels);

    const qoi_desc = qoi.qoi_desc{
        .width = width,
        .height = height,
        .channels = channels,
        .colorspace = qoi.QOI_SRGB,
    };
    var qoi_len: c_int = undefined;
    const converted: [*]u8 = qoi.qoi_encode(pixels, &qoi_desc, &qoi_len) orelse {
        log.err("qoi: failed to encode image", .{});
        return error.QoiImageEncodeFailed;
    };
    assert(qoi_len > 0);
    return converted[0..qoi_len];
}

pub fn freeConverted(bytes: []const u8) void {
    std.c.free(bytes.ptr);
}
