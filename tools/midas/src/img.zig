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
    var ctx = StbiIoCtx.init(file);
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;
    const pixels_ptr: [*]u8 = stbi.stbi_load_from_callbacks(
        stbi_io_callbacks,
        &ctx,
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
    var ctx = StbiIoCtx.init(file);
    var x: c_int = undefined;
    var y: c_int = undefined;
    var comp: c_int = undefined;
    const ok_int = stbi.stbi_info_from_callbacks(stbi_io_callbacks, &ctx, &x, &y, &comp);
    return (ok_int != 0);
}

const StbiIoCtx = extern struct {
    handle: std.fs.File.Handle,
    is_eof: bool,

    pub fn init(file_: std.fs.File) StbiIoCtx {
        return .{
            .handle = file_.handle,
            .is_eof = false,
        };
    }

    pub fn file(ctx: StbiIoCtx) std.fs.File {
        return .{ .handle = ctx.handle };
    }

    pub fn read(ctx: StbiIoCtx, buffer: []u8) std.fs.File.ReadError!c_int {
        if (buffer.len == 0) return 0;
        const bytes_read = try ctx.file().read(buffer);
        ctx.is_eof = (bytes_read == 0);
        return @intCast(bytes_read);
    }

    pub fn skip(ctx: StbiIoCtx, n: c_int) std.fs.File.SeekError!void {
        return ctx.file().seekBy(n);
    }

    pub fn eof(ctx: StbiIoCtx) c_int {
        return @intFromBool(ctx.is_eof);
    }
};

const stbi_io_callbacks = &stbi.stbi_io_callbacks{
    .read = &stbiReadCb,
    .skip = &stbiSkipCb,
    .eof = &stbiEofCb,
};

fn stbiReadCb(user: ?*anyopaque, data: ?[*]u8, size: c_int) callconv(.c) c_int {
    if (data) |d| {
        const ctx: *StbiIoCtx = @ptrCast(@alignCast(user orelse return 0));
        const bytes_read = ctx.read(d[0..@intCast(@max(size, 0))]) catch |err| {
            root.log.warn("stbi: read callback failed: handle={any}, size={d}, err={s}", .{
                ctx.handle,
                size,
                @errorName(err),
            });
            return 0;
        };
        return bytes_read;
    }
    return 0;
}

fn stbiSkipCb(user: ?*anyopaque, n: c_int) callconv(.c) void {
    const ctx: *StbiIoCtx = @ptrCast(@alignCast(user orelse return));
    ctx.skip(n) catch |err| {
        root.log.warn("stbi: skip callback failed: handle={any}, n={d}, err={s}", .{
            ctx.handle,
            n,
            @errorName(err),
        });
    };
}

fn stbiEofCb(user: ?*anyopaque) callconv(.c) c_int {
    const ctx: *StbiIoCtx = @ptrCast(@alignCast(user orelse return ~0));
    return ctx.eof();
}
