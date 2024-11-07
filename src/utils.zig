//! DEPRECATED

const std = @import("std");
const meta = std.meta;

pub fn PackedEnumFieldStruct(
    comptime E: type,
    comptime Data: type,
    comptime field_default: ?Data,
    comptime backing_integer: ?type,
) type {
    if (backing_integer) |int| switch (@typeInfo(int)) {
        .int => |int_info| if (int_info.signedness != .unsigned)
            @compileError("backing_integer must be unsigned"),
        else => @compileError("backing_integer must be an integer"),
    };

    const Base = std.enums.EnumFieldStruct(E, Data, field_default);
    var info = @typeInfo(Base).@"struct";
    info.layout = .@"packed";
    info.backing_integer = backing_integer;
    for (info.fields) |*field| {
        field.alignment = 0;
    }
    return @Type(.{ .@"struct" = info });
}


pub const Sign = enum(u1) {
    positive = 0,
    negative = 1,
};
/// Uses the sign bit of a float to store a 1-bit-tag.
/// The sign of the stored float cannot be changed.
pub fn TaggedFloat(comptime F: type, comptime sign: Sign) type {
    const info = @typeInfo(F);
    if (info != .float)
        @compileError("need 'float', got '" ++ @tagName(meta.activeTag(info)) ++ "'");

    const float_bits: u16 = info.float.bits;
    const backing_integer = meta.Int(float_bits);

    return packed struct(backing_integer) {
        /// This field is meant to be accessed directly.
        tag: u1,
        /// Access the full float by using `getFloat` and `setFloat`.
        float_no_sign: meta.Int(float_bits-1),

        pub fn init(tag: u1, float: F) TaggedFloat {
            var tagged: TaggedFloat = @bitCast(float);
            tagged.tag = tag;
            return tagged;
        }

        pub inline fn getFloat(tagged: *const TaggedFloat) F {
            var float = tagged.*;
            float.tag = @intFromEnum(sign);
            return @bitCast(float);
        }
        pub inline fn setFloat(tagged: *TaggedFloat, float: F) void {
            tagged.float_no_sign = @truncate(@as(backing_integer, @bitCast(float)));
        }
    };
}


pub fn BitCastEnum(comptime T: type, comptime entries: []const struct{ [:0]const u8, T }) type {
    const tag_type = meta.Int(.unsigned, @bitSizeOf(T));
    var fields: [entries.len]std.builtin.Type.EnumField = undefined;
    for (&fields, &entries) |*field, *entry| {
        field.* = .{
            .name = entry.@"0",
            .value = @as(tag_type, @bitCast(entry.@"1")),
        };
    }
    return @Type(.{ .@"enum" = .{
        .tag_type = tag_type,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    }});
}
