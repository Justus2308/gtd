const std = @import("std");
const stbi = @import("stbi");
const root = @import("root");
const assert = std.debug.assert;
const log = root.log;

pub const Error = error{Stbi};

pub const Data = struct {
    width: u32,
    height: u32,
    channels: u32,
    pixels: []const u8,

    pub fn deinit(data: *Data) void {
        stbi.stbi_image_free(data.pixels.ptr);
        data.* = undefined;
    }
};

pub fn load(file: std.fs.File) Error!Data {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;
    const pixels_ptr: [*]u8 = stbi.stbi_load_from_callbacks(
        stbi_io_callbacks,
        @constCast(&file),
        &width,
        &height,
        &channels,
        0,
    ) orelse {
        log.err(
            "stbi: failed to load image: {s}",
            .{@as(?[*:0]const u8, stbi.stbi_failure_reason()) orelse "reason unknown"},
        );
        return Error.Stbi;
    };
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = @intCast(channels),
        .pixels = pixels_ptr[0..@intCast(width * height)],
    };
}

pub fn isLoadable(file: std.fs.File) bool {
    var x: c_int = undefined;
    var y: c_int = undefined;
    var comp: c_int = undefined;
    const ok_int = stbi.stbi_info_from_callbacks(stbi_io_callbacks, @constCast(&file), &x, &y, &comp);
    return (ok_int != 0);
}

const stbi_io_callbacks = &stbi.stbi_io_callbacks{
    .read = &stbiReadCb,
    .skip = &stbiSkipCb,
    .eof = &stbiEofCb,
};

fn stbiReadCb(user: ?*anyopaque, data: ?[*]u8, size: c_int) callconv(.c) c_int {
    const file = @as(*const std.fs.File, @ptrCast(@alignCast(user orelse return 0))).*;
    if (data) |d| {
        if (file.read(d[0..@intCast(@max(size, 0))])) |bytes_read| {
            return @intCast(bytes_read);
        } else |err| {
            root.log.warn("stbi: read callback failed: handle={any}, size={d}, err={s}", .{
                file.handle,
                size,
                @errorName(err),
            });
        }
    }
    return 0;
}

fn stbiSkipCb(user: ?*anyopaque, n: c_int) callconv(.c) void {
    const file = @as(*const std.fs.File, @ptrCast(@alignCast(user orelse return))).*;
    file.seekBy(n) catch |err| {
        root.log.warn("stbi: skip callback failed: handle={any}, n={d}, err={s}", .{
            file.handle,
            n,
            @errorName(err),
        });
    };
}

fn stbiEofCb(user: ?*anyopaque) callconv(.c) c_int {
    const file = @as(*const std.fs.File, @ptrCast(@alignCast(user orelse return @intFromBool(true)))).*;
    // Warning: enterprise-level code
    return try_blk: {
        const cur_pos = file.getPos() catch |err| break :try_blk err;
        const end_pos = file.getEndPos() catch |err| break :try_blk err;
        break :try_blk @intFromBool(cur_pos == end_pos);
    } catch |err| catch_blk: {
        root.log.warn("stbi: EOF callback failed: handle={any}, err={s}", .{
            file.handle,
            @errorName(err),
        });
        break :catch_blk @intFromBool(true);
    };
}
