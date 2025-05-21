//! Naive implementation strictly following https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

fn lsp() !void {
    const r = std.io.AnyReader{};
    _ = decompressor(r).readSequence(&.{});
}

pub fn Decompressor(comptime ReaderType: type) type {
    return struct {
        source: std.io.CountingReader(ReaderType),
        state: State,
        literals_buffer: Buffer,

        const Self = @This();

        pub const Error = ReaderType.Error || error{Overflow};

        const State = enum { new_block, in_block };
        const Buffer = struct {
            pub const empty = Buffer{};
        };

        pub const Reader = std.io.Reader(*Self, Error, read);

        pub fn init(source: ReaderType) Self {
            return .{
                .source = std.io.countingReader(source),
                .state = .new_block,
                .literals_buffer = .empty,
            };
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        pub fn read(self: *Self, buffer: []u8) Error!usize {
            if (buffer.len == 0) {
                return 0;
            }

            var size: usize = 0;
        }

        inline fn readSequence(self: *Self, buffer: []u8) Error!usize {
            const source_reader = self.source.reader();

            var buffer_stream = std.io.fixedBufferStream(buffer);
            const buffer_writer = buffer_stream.writer();

            const token = source_reader.readStruct(Token) catch {
                self.state = .new_block;
                return;
            };
            self.state = .in_block;

            const literal_len = try token.readTotalLiteralLength(source_reader);

            for (0..literal_len) |_| {
                const b = try reader.readByte();
                try writer.writeByte(b);
            }

            const offset = try reader.readInt(u16, .little);

            const match_len = try token.readTotalMatchLength(source_reader);
            if (i == bytes.len and match_len == 0) {
                break;
            } else if (i >= bytes.len) {
                return error.InvalidInput;
            }
            match_len += min_match;

            const offset = std.mem.readInt(u16, bytes[i..][0..2], .little);
        }

        const Token = packed struct(u8) {
            match_length_biased: Field,
            literal_length: Field,

            pub const minmatch = 4;

            pub const Field = enum(u4) {
                more_bytes_required = 0xF,
                _,

                inline fn readTotalValue(field: Token.Field, source_reader: @FieldType(Self, "source").Reader) Error!u32 {
                    var total_value: u32 = @intFromEnum(field);
                    if (field == .more_bytes_required) {
                        while (true) {
                            const additional_byte = try source_reader.readByte();
                            total_value, const overflow = @addWithOverflow(total_value, additional_byte);
                            if (overflow == 1) {
                                @branchHint(.cold);
                                return Error.Overflow;
                            }
                            if (additional_byte != 0xFF) break;
                        }
                    }
                    return total_value;
                }
            };

            pub inline fn readTotalLiteralLength(token: Token, source_reader: @FieldType(Self, "source").Reader) Error!u32 {
                const total_literal_length = try token.literal_length.readTotalValue(source_reader);
                return total_literal_length;
            }

            pub inline fn readTotalMatchLength(token: Token, source_reader: @FieldType(Self, "source").Reader) Error!u32 {
                const total_match_length = try token.match_length_biased.readTotalValue(source_reader);
                return (total_match_length + minmatch);
            }
        };
    };
}

/// This implementation limits literal and match length to `std.math.maxInt(u32)` and will safely return
/// `Error.Overflow` in case of a longer length.
pub fn decompressor(reader: anytype) Decompressor(@TypeOf(reader)) {
    return .init(reader);
}

pub fn decompress(reader: anytype, writer: anytype) (Error || @TypeOf(reader).Error || @TypeOf(writer).Error)!void {
    while (true) {
        const token = reader.readStruct(Token) catch break;

        const literal_len = try token.readTotalLiteralLength(reader);

        for (0..literal_len) |_| {
            const b = try reader.readByte();
            try writer.writeByte(b);
        }

        const offset = try reader.readInt(u16, .little);

        const match_len = try token.readTotalMatchLength(reader);
        if (i == bytes.len and match_len == 0) {
            break;
        } else if (i >= bytes.len) {
            return error.InvalidInput;
        }
        match_len += min_match;

        const offset = std.mem.readInt(u16, bytes[i..][0..2], .little);
    }
}
