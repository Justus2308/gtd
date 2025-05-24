//! Naive implementation strictly following https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md

// TODO/NOTE: if the target is 32-bit (e.g. wasm32) and the asset pack is >4GiB this
//            implementation doesn't work anymore and we need a streaming decoder.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.lz4);

const is_debug = (builtin.mode == .Debug);

pub const Error = InStream.ReadError || InStream.Reader.NoEofError || OutStream.WriteError || error{ Overflow, InvalidStream };
pub const InStream = std.io.FixedBufferStream([]const u8);
pub const OutStream = std.io.FixedBufferStream([]u8);

pub fn decompress(noalias dest: []u8, noalias source: []const u8) Error!void {
    return decompressWithDict(dest, source, &.{});
}

pub fn decompressWithDict(
    noalias dest: []u8,
    noalias source: []const u8,
    noalias dict: []const u8,
) Error!void {
    errdefer if (is_debug) @memset(dest, undefined);

    var in_stream: InStream = std.io.fixedBufferStream(source);
    const in = in_stream.reader();

    var out_stream: OutStream = std.io.fixedBufferStream(dest);
    const out = out_stream.writer();

    while (true) {
        const token = try in.readStruct(Token);

        // identify and copy literals

        const literals_len = try token.readTotalLiteralLength(in);
        const literals_start = in_stream.pos;
        const literals_end = try std.math.add(usize, in_stream.pos, literals_len);
        if (literals_end > source.len) {
            @branchHint(.cold);
            log.err("decompress failed: literals would overflow source (literals_len={d}, source_len={d}, stream_pos={d})", .{
                literals_len,
                source.len,
                in_stream.pos,
            });
            return Error.InvalidStream;
        } else {
            in_stream.pos = literals_end;
        }
        const literals = source[literals_start..literals_end];

        try out.writeAll(literals);

        // match copy operation

        var offset = in.readInt(u16, .little) catch {
            // Reached end of input
            @branchHint(.cold);
            break;
        };
        var match_len = try token.readTotalMatchLength(in);

        if (offset > out_stream.pos) {
            // match starts inside dict
            const dict_offset = (offset - out_stream.pos);
            const dict_match_start = std.math.sub(usize, dict.len, dict_offset) catch {
                @branchHint(.cold);
                log.err("decompress failed: match offset would underflow dict (offset={d}, dict_len={d})", .{
                    offset,
                    dict.len,
                });
                return Error.InvalidStream;
            };
            const dict_match_len = @max(dict_offset, match_len);
            const dict_match = dict[dict_match_start..][0..dict_match_len];

            try out.writeAll(dict_match);

            offset -= dict_offset;
            match_len -= dict_match_len;
        } else if (offset == 0) {
            // invalid input
            @branchHint(.cold);
            log.err("decompress failed: invalid offset '0' encountered (source_len={d}, stream_pos={d})", .{
                source.len,
                in_stream.pos,
            });
            return Error.InvalidStream;
        }

        // offset < out_stream.pos
        // (remaining) match is fully inside dest
        // offset might be 0 here if match was fully inside dict

        const match_start = std.math.sub(usize, out_stream.pos, offset) catch {
            @branchHint(.cold);
            log.err("decompress failed: match offset would underflow dest (offset={d}, dest_len={d}, stream_pos={d})", .{
                offset,
                dest.len,
                out_stream.pos,
            });
            return Error.InvalidStream;
        };
        const match = dest[match_start..][0..match_len];

        try writeAllOverlapping(&out_stream, match); // TODO
    }
}

const Token = packed struct(u8) {
    match_length_biased: Field,
    literal_length: Field,

    pub const minmatch = 4;

    pub const Field = enum(u4) {
        more_bytes_required = 0xF,
        _,
    };

    pub inline fn readTotalLiteralLength(token: Token, reader: InStream.Reader) Error!usize {
        const initial_value: usize = @intFromEnum(token.literal_length);
        if (token.literal_length == .more_bytes_required) {
            @branchHint(.unlikely);
            return readAdditionalBytes(reader, initial_value);
        }
        return initial_value;
    }

    pub inline fn readTotalMatchLength(token: Token, reader: InStream.Reader) Error!usize {
        const initial_value = (@as(usize, @intFromEnum(token.match_length_biased)) + minmatch);
        if (token.match_length_biased == .more_bytes_required) {
            @branchHint(.unlikely);
            return readAdditionalBytes(reader, initial_value);
        }
        return initial_value;
    }

    fn readAdditionalBytes(reader: InStream.Reader, initial_value: usize) Error!usize {
        var result: usize = initial_value;
        while (true) {
            const additional_byte = try reader.readByte();
            result = try std.math.add(usize, result, additional_byte);
            if (additional_byte != 0xFF) break;
        }
    }
};

inline fn writeAllOverlapping(stream: *OutStream, bytes: []const u8) Error!void {
    if (bytes.len == 0) return;
    if ((stream.buffer.len - stream.pos) < bytes.len) {
        return Error.NoSpaceLeft;
    }
    @memmove(stream.buffer[stream.pos..][0..bytes.len], bytes);
    stream.pos += bytes.len;
}
