bytes: std.ArrayListUnmanaged(u8),
last_string: String = .invalid,

const Self = @This();

pub const String = stdx.Handle(u32, .max_int, Self);

pub const empty = Self{ .bytes = .empty };

pub fn initCapacity(allocator: Allocator, capacity_in_bytes: u32) Allocator.Error!Self {
    return .{ .bytes = try .initCapacity(allocator, capacity_in_bytes) };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.bytes.deinit(allocator);
    self.* = undefined;
}

pub fn create(self: *Self, allocator: Allocator, bytes: []const u8) Allocator.Error!String {
    const string = String.fromInt(@intCast(self.bytes.items.len));
    const buffer = try self.bytes.addManyAsSlice(allocator, (bytes.len + 1));
    @memcpy(buffer[0..bytes.len], bytes);
    buffer[bytes.len] = 0;
    self.last_string = string;
    return string;
}

pub fn destroy(self: *Self, string: String) void {
    if (string != .invalid and string == self.last_string) {
        self.bytes.items.len = self.last_string.asInt();
    }
}

pub fn get(self: Self, string: String) ?[]const u8 {
    if (string == .invalid or string.asInt() >= self.bytes.items.len) {
        return null;
    }
    return self.getUnchecked(string);
}

pub fn getUnchecked(self: Self, string: String) []const u8 {
    assert(self.bytes.items[self.bytes.items.len - 1] == 0);
    const bytes_ptr: [*:0]const u8 = @ptrCast(&self.bytes.items[string.asInt()]);
    const bytes = std.mem.span(bytes_ptr);
    assert((@as(usize, string.asInt()) + bytes.len) <= self.bytes.items.len);
    return bytes;
}

const std = @import("std");
const stdx = @import("../stdx.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
