const std = @import("std");
const cgltf = @import("cgltf");
const root = @import("root");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = root.log;

pub fn convert(bytes: []const u8, options: void) ![]const u8 {
    _ = options;

    const cgltf_opts = cgltf.cgltf_options{};
    var data: *cgltf.cgltf_data = undefined;
    const res = cgltf.cgltf_parse(&cgltf_opts, bytes.ptr, bytes.len, @ptrCast(&data));
    if (res != cgltf.cgltf_result_success) {
        root.log.err("failed to parse glTF: error code {d}", .{res});
        return error.CgltfParseFailed;
    }
    defer cgltf.cgltf_free(data);
    return error.Todo;
}

pub fn freeConverted(bytes: []const u8) void {
    _ = bytes;
}
