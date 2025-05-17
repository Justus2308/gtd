ptr: *anyopaque,
vtable: *const VTable,

const Loader = @This();

pub const Error = (Allocator.Error || File.OpenError.AccessDenied || File.OpenError.FileNotFound || error{Unexpected});

pub const VTable = struct {
    /// Should use `Loader.autoHash()` to produce its final result to make
    /// hash collisions as unlikely as possible.
    hash: *const fn (*anyopaque) u64,
    load: *const fn (*anyopaque, allocator: Allocator) anyerror!void,
    unload: *const fn (*anyopaque, allocator: Allocator) void,
};

/// Hashes `key` following pointers recursively.
pub fn autoHash(key: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
    return hasher.final();
}

pub inline fn rawHash(loader: Loader) u64 {
    return loader.vtable.hash(loader.ptr);
}

pub inline fn rawLoad(loader: Loader, allocator: Allocator) !void {
    return loader.vtable.load(loader.ptr, allocator);
}

pub inline fn rawUnload(loader: Loader, allocator: Allocator) void {
    loader.vtable.unload(loader.ptr, allocator);
}

pub const Handle = stdx.Handle(u64, autoHash(""), Loader);

pub fn generateHandle(loader: Loader) Handle {
    const hash = loader.rawHash();
    return .fromInt(hash);
}

pub fn load(loader: Loader, allocator: Allocator) Error!void {
    loader.rawLoad(allocator) catch |err| switch (err) {
        inline else => |e| {
            if (@hasField(std.meta.FieldEnum(Error), @errorName(e))) {
                return @as(Error, @errorCast(e));
            } else {
                log.err("failed to load resource: unexpected error: {s}", .{@errorName(e)});
                return Error.Unexpected;
            }
            unreachable;
        },
    };
}

pub fn unload(loader: Loader, allocator: Allocator) void {
    loader.rawUnload(allocator);
}

pub fn casted(loader: Loader, comptime T: type) *const T {
    return @ptrCast(@alignCast(loader.ptr));
}

const std = @import("std");
const stdx = @import("stdx");
const asset = @import("asset");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Manager = @import("Manager.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.resource_loader);
