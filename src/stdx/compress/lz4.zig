//! Naive implementation strictly following https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md

// TODO/NOTE: if the target is 32-bit (e.g. wasm32) and any block is >4GiB this
//            implementation doesn't work anymore and we need a streaming decoder.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.lz4);

const is_debug = (@import("builtin").mode == .Debug);

pub const Error = InStream.ReadError || InStream.Reader.NoEofError || OutStream.WriteError || error{ Overflow, InvalidStream };
pub const InStream = std.io.FixedBufferStream([]const u8);
pub const OutStream = std.io.FixedBufferStream([]u8);

pub const max_dict_size = (@as(usize, 1) << 16);

pub inline fn decompress(noalias dest: []u8, noalias source: []const u8) Error!void {
    return innerDecompress(dest, source, .any, &.{});
}

/// If `dict.len > max_dict_size` only the last `max_dict_size` bytes of `dict` are used.
pub inline fn decompressWithDict(
    noalias dest: []u8,
    noalias source: []const u8,
    noalias dict: []const u8,
) Error!void {
    if (dict.len < max_dict_size) {
        return innerDecompress(dest, source, .any, dict);
    } else {
        const dict_truncated = dict[(dict.len - max_dict_size)..][0..max_dict_size];
        return innerDecompress(dest, source, .exact, dict_truncated);
    }
    unreachable;
}

const DictKind = enum {
    any,
    exact,

    pub fn Type(comptime dict_kind: DictKind) type {
        return switch (dict_kind) {
            .any => []const u8,
            .exact => *const [max_dict_size]u8,
        };
    }

    pub inline fn getMatchStart(
        comptime dict_kind: DictKind,
        noalias dict: dict_kind.Type(),
        offset: u16,
    ) Error!usize {
        return switch (dict_kind) {
            .any => std.math.sub(usize, dict.len, offset),
            .exact => (max_dict_size - offset),
        };
    }
};

fn innerDecompress(
    noalias dest: []u8,
    noalias source: []const u8,
    comptime dict_kind: DictKind,
    noalias dict: dict_kind.Type(),
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
        const literals_end = try std.math.add(usize, literals_start, literals_len);
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

        var offset = in.readInt(u16, .little) catch |err| {
            // Reached end of input
            @branchHint(.cold);
            assert(err == Error.EndOfStream);
            break;
        };
        var match_len = try token.readTotalMatchLength(in);

        if (offset > out_stream.pos) {
            // match starts inside dict
            const dict_offset = (offset - @as(u16, @truncate(out_stream.pos)));
            const dict_match_start = dict_kind.getMatchStart(dict, dict_offset) catch {
                @branchHint(.cold);
                log.err("decompress failed: match offset would underflow dict (offset={d}, dict_len={d})", .{
                    offset,
                    dict.len,
                });
                return Error.InvalidStream;
            };
            const dict_match_len = @min(dict_offset, match_len);
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

        if (match_len > offset) {
            // overlap copy
            try out.writeAll(match[0..offset]);
            while (offset < match_len) : (offset += 1) {
                try out.writeByte(match[offset]);
            }
        } else {
            try out.writeAll(match);
        }
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
        assert(result >= initial_value);
        return result;
    }
};

// TESTS

const Lz4FrameHeader = extern struct {
    magic: [4]u8,
    flg: FLG,
    bd: BD,
    hc: u8,

    pub const lz4frame_magic = @as(u32, 0x184D2204);
    pub const lz4frame_version = @as(u2, 0b01);

    pub const FLG = packed struct(u8) {
        dict_id: bool,
        _1: u1 = 0,
        content_checksum: bool,
        content_size: bool,
        block_checksum: bool,
        block_indep: bool,
        version: u2,
    };

    pub const BD = packed struct(u8) {
        _0: u1 = 0,
        _1: u1 = 0,
        _2: u1 = 0,
        _3: u1 = 0,
        block_max_size: BlockMaxSize,
        _7: u1 = 0,

        pub const BlockMaxSize = enum(u3) {
            @"64KiB" = 4,
            @"256KiB" = 5,
            @"1MiB" = 6,
            @"4MiB" = 7,
            _,

            pub fn inBytes(block_max_size: BlockMaxSize) ?usize {
                return switch (block_max_size) {
                    .@"64KiB" => (64 << 10),
                    .@"256KiB" => (256 << 10),
                    .@"1MiB" => (1 << 10 << 10),
                    .@"4MiB" => (4 << 10 << 10),
                    _ => null,
                };
            }
        };
    };

    pub fn checkMagic(header: Lz4FrameHeader) bool {
        const magic = std.mem.readInt(u32, &header.magic, .little);
        return (magic == lz4frame_magic);
    }
};

/// compressed inputs have to be generated with:
///     lz4 -9zf -BI7 --no-frame-crc [input] [output]
fn testDecompress(comptime compressed_path: []const u8, comptime expected_path: []const u8) !void {
    const compressed = @embedFile(compressed_path);
    const expected = @embedFile(expected_path);

    const header: Lz4FrameHeader = @bitCast(compressed[0..@sizeOf(Lz4FrameHeader)].*);
    comptime {
        const expected_flg = Lz4FrameHeader.FLG{
            .dict_id = false,
            .content_checksum = false,
            .content_size = false,
            .block_checksum = false,
            .block_indep = true,
            .version = Lz4FrameHeader.lz4frame_version,
        };
        assert(header.flg == expected_flg);

        // const expected_bd = Lz4FrameHeader.BD{
        //     .block_max_size = .@"4MiB",
        // };
        // assert(header.bd == expected_bd);
    }
    const block_size = std.mem.readInt(u32, compressed[@sizeOf(Lz4FrameHeader)..][0..@sizeOf(u32)], .little);
    const data = compressed[(@sizeOf(Lz4FrameHeader) + @sizeOf(u32))..][0..block_size];

    var decompressed: [expected.len]u8 = undefined;
    try decompress(&decompressed, data);
    try testing.expectEqualSlices(u8, expected, &decompressed);
}

test "lz4 decomp lorem ipsum" {
    try testDecompress("lz4/test_1k_comp.lz4", "lz4/test_1k_raw.txt");
    try testDecompress("lz4/test_10k_comp.lz4", "lz4/test_10k_raw.txt");
}

// dictionaries have to be generated with:
//     zstd --train --maxdict=65536 [input...] [-o output]
