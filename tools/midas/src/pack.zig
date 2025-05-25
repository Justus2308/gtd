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
    dict_stream: Stream,
    working_stream: Stream,
    dict_buffer: Buffer,
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

    pub const max_size = @as(usize, lz4hc.LZ4HC_MAXD);
    pub const default_size = Compressor.max_size;

    pub fn init(allocator: Allocator, level: Compressor.Level) Allocator.Error!Compressor {
        var limited_allocator = LimitedAllocator.init(allocator, root.maxRss() orelse std.math.maxInt(u64));
        const lim_alloc = limited_allocator.allocator();

        var dict_stream = try Stream.create(lim_alloc, level);
        errdefer dict_stream.destroy(lim_alloc);
        var working_stream = try Stream.create(lim_alloc, level);
        errdefer working_stream.destroy(lim_alloc);

        return .{
            .limited_allocator = limited_allocator,
            .dict_stream = dict_stream,
            .working_stream = working_stream,
            .dict_buffer = .empty,
            .source_buffer = .empty,
            .dest_buffer = .empty,
        };
    }

    pub fn deinit(compressor: *Compressor) void {
        const allocator = compressor.limited_allocator.allocator();
        compressor.dict_stream.destroy(allocator);
        compressor.working_stream.destroy(allocator);
        compressor.dict_buffer.deinit(allocator);
        compressor.source_buffer.deinit(allocator);
        compressor.dest_buffer.deinit(allocator);
        compressor.* = undefined;
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
        try compressor.dict_buffer.ensureTotalCapacityPrecise(allocator, max_dict_size);
        compressor.dict_buffer.expandToCapacity();

        const zdict_retval = zdict.ZDICT_trainFromBuffer(
            compressor.dict_buffer.items.ptr,
            compressor.dict_buffer.items.len,
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
        assert(zdict_retval <= max_dict_size);
        compressor.dict_buffer.resize(allocator, zdict_retval) catch unreachable;

        compressor.dict_stream.reset();

        const lz4hc_retval = lz4hc.LZ4_loadDictHC(
            compressor.dict_stream.inner,
            compressor.dict_buffer.items.ptr,
            @intCast(compressor.dict_buffer.items.len),
        );
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

        compressor.working_stream.reset();
        lz4hc.LZ4_attach_dictionary(compressor.working_stream.inner, compressor.dict_stream.inner);

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
            compressor.working_stream.inner,
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
};
