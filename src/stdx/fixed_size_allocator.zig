const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

pub fn FixedSizeAllocator(comptime size: usize) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const Self = @This();

        pub const VTable = struct {
            create: *const fn (*anyopaque, alignment: Alignment, ret_addr: usize) ?*[size]u8,
            destroy: *const fn (*anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void,
        };

        pub inline fn rawCreate(self: Self, alignment: Alignment, ret_addr: usize) ?*[size]u8 {
            return self.vtable.create(self.ptr, alignment, ret_addr);
        }

        pub inline fn rawDestroy(self: Self, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            return self.vtable.destroy(self.ptr, memory, alignment, ret_addr);
        }

        pub fn create(self: Self) Allocator.Error!*align(size) [size]u8 {
            return self.createWithOptions([size]u8, null);
        }

        pub fn createTyped(self: Self, comptime T: type) Allocator.Error!*T {
            if (@sizeOf(T) != size) {
                @compileError("T needs to be size bytes large");
            }
            return self.createWithOptions(T, .of(T));
        }

        fn CreateWithOptionsPayload(comptime T: type, comptime alignment: ?Alignment) type {
            if (alignment) |a| {
                if (a.order(.fromByteUnits(size)) == .lt) {
                    @compileError("alignment needs to be a multiple of size");
                } else {
                    return *align(a.toByteUnits()) T;
                }
            } else {
                return *align(size) T;
            }
            unreachable;
        }
        pub fn createWithOptions(
            self: Self,
            comptime T: type,
            comptime alignment: ?Alignment,
        ) Allocator.Error!CreateWithOptionsPayload(T, alignment) {
            const bytes = self.rawCreate(alignment orelse .fromByteUnits(size), @returnAddress()) orelse Allocator.Error.OutOfMemory;
            return @ptrCast(bytes);
        }

        pub fn destroy(self: Self, ptr: anytype) void {
            const info = @typeInfo(@TypeOf(ptr)).pointer;
            if (info.size != .one) {
                @compileError("ptr must be a single item pointer");
            } else if (info.child != [size]u8 and @sizeOf(info.child) != size) {
                @compileError("ptr must point to a chunk of size bytes");
            }
            const non_const_ptr = @as([*]u8, @ptrCast(@constCast(ptr)));
            self.rawDestroy(non_const_ptr[0..size], .fromByteUnits(info.alignment), @returnAddress());
        }
    };
}
