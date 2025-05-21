const std = @import("std");
const lz4hc = @import("lz4hc");
const zdict = @import("zdict");

pub const Options = struct {
    is_uncompressed: bool = false,
};

pub fn convert(bytes: []const u8, options: Options) ![]const u8 {
    _ = bytes;
    _ = options;
    lz4hc.LZ4_compress_HC(null, null, 0, 0, 9);
    return error.Todo;
}

pub fn freeConverted(bytes: []const u8) void {
    _ = bytes;
}
