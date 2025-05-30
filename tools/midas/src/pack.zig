const std = @import("std");
const lz4hc = @import("lz4hc");
const zdict = @import("zdict");
const root = @import("root");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Options = struct {
    is_uncompressed: bool = false, // TODO
};

pub const Compressor = struct {
    stream: Stream,
    source_buffer: Buffer,
    dest_buffer: Buffer,

    pub const Error = Allocator.Error || error{ Zdict, Lz4hc };

    pub const Stream = struct {
        inner: *lz4hc.LZ4_streamHC_t,
        level: c_int,

        pub fn create(allocator: Allocator, level: Compressor.Level) Allocator.Error!Stream {
            const buffer = try allocator.create(lz4hc.LZ4_streamHC_t);
            const inner: *lz4hc.LZ4_streamHC_t = lz4hc.LZ4_initStreamHC(buffer, @sizeOf(lz4hc.LZ4_streamHC_t));
            assert(buffer == inner);
            return .{
                .inner = inner,
                .level = level.value(),
            };
        }

        pub fn reset(stream: Stream) void {
            lz4hc.LZ4_resetStreamHC_fast(stream.inner, stream.level);
        }

        pub fn destroy(stream: *Stream, allocator: Allocator) void {
            allocator.destroy(stream.inner);
            stream.* = undefined;
        }
    };

    pub const Buffer = std.ArrayListUnmanaged(u8);

    pub fn init(allocator: Allocator) Allocator.Error!Compressor {
        return .initWithLevel(allocator, .default);
    }

    pub fn initWithLevel(allocator: Allocator, level: Compressor.Level) Allocator.Error!Compressor {
        return .{
            .stream = try .create(allocator, level),
            .source_buffer = .empty,
            .dest_buffer = .empty,
        };
    }

    pub fn deinit(compressor: *Compressor, allocator: Allocator) void {
        compressor.stream.destroy(allocator);
        compressor.source_buffer.deinit(allocator);
        compressor.dest_buffer.deinit(allocator);
        compressor.* = undefined;
    }

    pub const Level = union(enum) {
        min,
        default,
        opt_min,
        max,
        custom: c_int,

        pub fn value(level: Level) c_int {
            return switch (level) {
                .min => lz4hc.LZ4HC_CLEVEL_MIN,
                .default => lz4hc.LZ4HC_CLEVEL_DEFAULT,
                .opt_min => lz4hc.LZ4HC_CLEVEL_OPT_MIN,
                .max => lz4hc.LZ4HC_CLEVEL_MAX,
                .custom => |val| std.math.clamp(val, lz4hc.LZ4HC_CLEVEL_MIN, lz4hc.LZ4HC_CLEVEL_MAX),
            };
        }
    };

    /// Limited to 2GiB inputs
    pub fn compress(
        compressor: *Compressor,
        allocator: Allocator,
        reader: anytype,
        writer: anytype,
        dictionary: ?Dictionary,
    ) (Compressor.Error || @TypeOf(reader).Error || @TypeOf(writer).Error)!void {
        compressor.stream.reset();
        if (dictionary) |dict| {
            lz4hc.LZ4_attach_dictionary(compressor.stream.inner, dict.stream.inner);
        }

        {
            var source_managed = compressor.source_buffer.toManaged(allocator);
            defer compressor.source_buffer = source_managed.moveToUnmanaged();

            source_managed.clearRetainingCapacity();
            try reader.readAllArrayList(&source_managed, std.math.maxInt(c_int));
        }

        const max_dest_len = lz4hc.LZ4_compressBound(@intCast(compressor.source_buffer.items.len));
        try compressor.dest_buffer.ensureTotalCapacity(allocator, @intCast(max_dest_len));
        compressor.dest_buffer.expandToCapacity();

        const compressed_len = lz4hc.LZ4_compress_HC_continue(
            compressor.stream.inner,
            compressor.source_buffer.items.ptr,
            compressor.dest_buffer.items.ptr,
            @intCast(compressor.source_buffer.items.len),
            max_dest_len,
        );
        assert(compressed_len >= 0 and compressed_len <= max_dest_len);
        compressor.dest_buffer.resize(allocator, @intCast(compressed_len)) catch unreachable;
        if (compressed_len == 0) {
            root.log.err("lz4hc: compress_HC_continue failed: produced 0 bytes", .{});
            return Error.Lz4hc;
        }
        try writer.writeAll(compressor.dest_buffer.items);
    }

    pub const Dictionary = struct {
        stream: Stream,
        buffer: Buffer,

        pub const max_size = @as(usize, lz4hc.LZ4HC_MAXD);
        pub const default_size = Dictionary.max_size;

        /// Glorified slice with data layout suitable for zdict
        pub const Sample = struct {
            ptr: [*]const u8,
            len: usize,

            pub const List = std.MultiArrayList(Sample);

            pub fn fromSlice(slice: []const u8) Sample {
                return .{
                    .ptr = slice.ptr,
                    .len = slice.len,
                };
            }
        };

        pub fn train(allocator: Allocator, samples: Sample.List.Slice) Compressor.Error!Dictionary {
            return .trainWithOptions(allocator, samples, .default, Dictionary.default_size);
        }

        pub fn trainWithOptions(
            allocator: Allocator,
            samples: Sample.List.Slice,
            compression_level: Compressor.Level,
            size: usize,
        ) Compressor.Error!Dictionary {
            assert(size <= Dictionary.max_size);

            var buffer = try Buffer.initCapacity(allocator, size);
            errdefer buffer.deinit(allocator);
            buffer.expandToCapacity();

            const zdict_retval = zdict.ZDICT_trainFromBuffer(
                buffer.items.ptr,
                buffer.items.len,
                samples.items(.ptr),
                samples.items(.len),
                @intCast(samples.len),
            );
            if (zdict.ZDICT_isError(zdict_retval)) {
                root.log.err("zdict: trainFromBuffer failed: code {d}: {s}", .{
                    zdict_retval,
                    @as(?[*:0]const u8, @ptrCast(zdict.ZDICT_getErrorName(zdict_retval))) orelse "reason unknown",
                });
                return Error.Zdict;
            }
            assert(zdict_retval <= size);
            buffer.resize(allocator, zdict_retval) catch unreachable;

            var stream = try Stream.create(allocator, compression_level);
            errdefer stream.destroy(allocator);

            const lz4hc_retval = lz4hc.LZ4_loadDictHC(
                stream.inner,
                buffer.items.ptr,
                @intCast(buffer.items.len),
            );
            if (lz4hc_retval != 0) {
                root.log.err("lz4hc: loadDictHC failed: retval {d}", .{lz4hc_retval});
                return Error.Lz4hc;
            }

            return .{
                .stream = stream,
                .buffer = buffer,
            };
        }

        pub fn deinit(dictionary: *Dictionary, allocator: Allocator) void {
            dictionary.stream.destroy(allocator);
            dictionary.buffer.deinit(allocator);
            dictionary.* = undefined;
        }
    };
};

// FORMAT SPEC
// TODO move
// all integers are stored little endian
//
// <HEADER> <REGISTRY> [DICTIONARY] [ENTRY ...]

pub const Header = extern struct {
    magic: [4]u8 = midaspack_magic,
    version: u16,
    entry_count: u16,
    size: u64,

    pub const midaspack_magic = [4]u8{ 'm', 'd', 's', 'p' };

    pub const Version = enum(u16) {
        @"0.1" = 0,
    };
};

pub const Entry = extern struct {
    offset: u64,
    comp_size: u64,
    decomp_size: u64,
    ident: u64,
    flags: Flags,

    pub const Flags = packed struct(u8) {
        kind: Kind,
        compressed: bool,
        endianness: std.builtin.Endian,
        _3: u1 = 0,
        _4: u1 = 0,
        _5: u1 = 0,
        _6: u1 = 0,
        _7: u1 = 0,

        pub const Kind = enum(u1) {
            img,
            mesh,
        };
    };
};
