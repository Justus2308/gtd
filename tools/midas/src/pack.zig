const std = @import("std");
const lz4hc = @import("lz4hc");
const zdict = @import("zdict");
const root = @import("root");
const Allocator = std.mem.Allocator;
const LimitedAllocator = @import("LimitedAllocator.zig");
const assert = std.debug.assert;

pub const Options = struct {
    is_uncompressed: bool = false, // TODO
};

pub const Compressor = struct {
    limited_allocator: LimitedAllocator,
    level: c_int,
    dict_stream: *lz4hc.LZ4_streamHC_t,
    working_stream: *lz4hc.LZ4_streamHC_t,
    source_buffer: Buffer,
    dest_buffer: Buffer,

    pub const Error = Allocator.Error || error{ Zdict, Lz4hc };

    pub const Buffer = std.ArrayListUnmanaged(u8);

    pub const max_size = @as(usize, lz4hc.LZ4HC_MAXD);
    pub const default_size = Compressor.max_size;

    pub fn init(allocator: Allocator, level: Compressor.Level) Compressor.Error!Compressor {
        const dict_stream = try Compressor.createStream();
        errdefer Compressor.destroyStream(dict_stream);
        const working_stream = try Compressor.createStream();
        errdefer Compressor.destroyStream(working_stream);

        return .{
            .limited_allocator = .init(allocator, root.maxRss() orelse std.math.maxInt(u64)),
            .level = level.value(),
            .dict_stream = dict_stream,
            .working_stream = working_stream,
            .source_buffer = .empty,
            .dest_buffer = .empty,
        };
    }

    pub fn deinit(compressor: *Compressor) void {
        Compressor.destroyStream(compressor.dict_stream);
        Compressor.destroyStream(compressor.working_stream);

        const allocator = compressor.limited_allocator.allocator();
        compressor.source_buffer.deinit(allocator);
        compressor.dest_buffer.deinit(allocator);

        compressor.* = undefined;
    }

    fn createStream() Compressor.Error!*lz4hc.LZ4_streamHC_t {
        const stream: *lz4hc.LZ4_streamHC_t = lz4hc.LZ4_createStreamHC() orelse {
            root.log.err("lz4hc: createStream failed", .{});
            return Error.Lz4hc;
        };
        return stream;
    }
    fn resetStream(compressor: Compressor, stream: *lz4hc.LZ4_streamHC_t) void {
        lz4hc.LZ4_resetStreamHC_fast(stream, compressor.level);
    }
    fn destroyStream(stream: *lz4hc.LZ4_streamHC_t) void {
        assert(lz4hc.LZ4_freeStreamHC(stream) == 0);
    }

    /// Glorified slice with data layout suitable for zdict
    pub const Compressable = struct {
        ptr: [*]const u8,
        len: usize,

        pub const List = std.MultiArrayList(Compressable);

        pub fn fromSlice(slice: []const u8) Compressable {
            return .{
                .ptr = slice.ptr,
                .len = slice.len,
            };
        }
    };

    pub fn train(compressor: *Compressor, samples: Compressable.List.Slice) Compressor.Error!void {
        return compressor.trainMaxSize(samples, Compressor.default_size);
    }

    pub fn trainMaxSize(
        compressor: *Compressor,
        samples: Compressable.List.Slice,
        max_dict_size: usize,
    ) Compressor.Error!void {
        assert(max_dict_size <= Compressor.max_size);

        const allocator = compressor.limited_allocator.allocator();
        const dict_buffer = try allocator.alloc(u8, default_size);
        defer allocator.free(dict_buffer);

        const zdict_retval = zdict.ZDICT_trainFromBuffer(
            dict_buffer.ptr,
            dict_buffer.len,
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

        compressor.resetStream(compressor.dict_stream);

        const lz4hc_retval = lz4hc.LZ4_loadDictHC(compressor.dict_stream, dict_buffer.ptr, @intCast(dict_buffer.len));
        if (lz4hc_retval != 0) {
            root.log.err("lz4hc: loadDictHC failed: retval {d}", .{lz4hc_retval});
            return Error.Lz4hc;
        }
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

    pub fn compress(
        compressor: *Compressor,
        reader: anytype,
        writer: anytype,
    ) (Compressor.Error || @TypeOf(reader).Error || @TypeOf(writer).Error)!void {
        const allocator = compressor.limited_allocator.allocator();

        compressor.resetStream(compressor.working_stream);
        lz4hc.LZ4_attach_dictionary(compressor.working_stream, compressor.dict_stream);

        {
            var source_managed = compressor.source_buffer.toManaged(allocator);
            defer compressor.source_buffer = source_managed.moveToUnmanaged();

            source_managed.clearRetainingCapacity();
            try reader.readAllArrayList(&source_managed, @truncate(compressor.limited_allocator.bytes_remaining));
        }

        const max_dest_len = lz4hc.LZ4_compressBound(@intCast(compressor.source_buffer.items.len));
        try compressor.dest_buffer.ensureTotalCapacity(allocator, @intCast(max_dest_len));
        compressor.dest_buffer.expandToCapacity();

        const compressed_len = lz4hc.LZ4_compress_HC_continue(
            compressor.working_stream,
            compressor.source_buffer.items.ptr,
            compressor.dest_buffer.items.ptr,
            @intCast(compressor.source_buffer.items.len),
            max_dest_len,
        );
        compressor.dest_buffer.resize(allocator, compressed_len) catch unreachable;

        try writer.writeAll(compressor.dest_buffer.items);
    }
};
