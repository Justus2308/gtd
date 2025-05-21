const std = @import("std");
const lz4hc = @import("lz4hc");
const zdict = @import("zdict");
const root = @import("root");
const Allocator = std.mem.Allocator;
const LimitedAllocator = @import("LimitedAllocator.zig");
const assert = std.debug.assert;

pub const Options = struct {
    is_uncompressed: bool = false,
};

pub fn convert(bytes: []const u8, options: Options) ![]const u8 {
    _ = bytes;
    _ = options;
    lz4hc.LZ4_createStreamHC();
    lz4hc.LZ4_compress_HC(null, null, 0, 0, lz4hc.LZ4HC_CLEVEL_OPT_MIN);
    return error.Todo;
}

pub const Dictionary = struct {
    limited_allocator: LimitedAllocator,
    bytes: std.ArrayListUnmanaged(u8),

    pub const Error = Allocator.Error || error{ Zdict, Lz4hc };

    pub const max_size = @as(usize, lz4hc.LZ4HC_MAXD);
    pub const default_size = Dictionary.max_size;

    pub fn init(allocator: Allocator) Allocator.Error!Dictionary {
        return .initWithSize(allocator, Dictionary.default_size);
    }

    pub fn initWithMaxSize(allocator: Allocator, size: usize) Allocator.Error!Dictionary {
        assert(size <= Dictionary.max_size);
        var dict = Dictionary{
            .limited_allocator = .init(allocator, root.maxRss() orelse std.math.maxInt(u64)),
            .bytes = undefined,
        };
        dict.bytes = try .initCapacity(dict.limited_allocator.allocator(), size);
        return dict;
    }

    pub fn deinit(dict: *Dictionary) void {
        dict.bytes.deinit(dict.limited_allocator.allocator());
        dict.* = undefined;
    }

    /// Glorified slice
    pub const Compressable = struct {
        ptr: [*]const u8,
        len: usize,

        pub const List = std.MultiArrayList(Compressable);
    };

    pub fn train(dict: *Dictionary, samples: Compressable.List.Slice) Dictionary.Error!void {
        dict.bytes.expandToCapacity();
        const zdict_retval = zdict.ZDICT_trainFromBuffer(
            dict.bytes.items.ptr,
            dict.bytes.items.len,
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
        dict.bytes.shrinkRetainingCapacity(zdict_retval);
    }

    pub fn get(dict: Dictionary) []const u8 {
        return dict.bytes.items;
    }

    pub const CompressionLevel = union(enum) {
        min,
        default,
        opt_min,
        max,
        custom: c_int,

        pub fn value(level: CompressionLevel) c_int {
            return switch (level) {
                .min => lz4hc.LZ4HC_CLEVEL_MIN,
                .default => lz4hc.LZ4HC_CLEVEL_DEFAULT,
                .opt_min => lz4hc.LZ4HC_CLEVEL_OPT_MIN,
                .max => lz4hc.LZ4HC_CLEVEL_MAX,
                .custom => |val| val,
            };
        }
    };

    // pub fn compress(
    //     dict: Dictionary,
    //     reader: anytype,
    //     writer: anytype,
    //     level: CompressionLevel,
    // ) (Dictionary.Error || @TypeOf(reader).Error || @TypeOf(writer).Error)!void {
    //     const allocator = dict.limited_allocator.allocator();

    //     const stream = lz4hc.LZ4_createStream() orelse {
    //         root.log.err("lz4hc: createStream failed", .{});
    //         return Error.Lz4hc;
    //     };
    //     defer assert(lz4hc.LZ4_freeStreamHC(stream) == 0);

    //     lz4hc.LZ4_resetStreamHC_fast(stream, level.value());
    //     lz4hc.LZ4_loadDictHC(stream, dict.bytes.items.ptr, @intCast(dict.bytes.items.len));

    //     const source = try reader.readAllAlloc(allocator, root.maxRss() orelse std.math.maxInt(c_int));
    //     defer allocator.free(source);

    //     const max_dest_len = lz4hc.LZ4_compressBound(@intCast(source.len));

    //     const dest = try allocator.alloc(u8, max_dest_len);

    //     var source_bytes_remaining: c_int = @intCast(source.len);
    //     while (source) {
    //         const res = lz4hc.LZ4_compress_HC_continue_destSize(stream, source.ptr, buffer.ptr, &source_bytes_remaining, @intCast(buffer.len));
    //     }

    //     // lz4hc.LZ4_compress_HC_continue(stream, src: [*c]const u8, dst: [*c]u8, srcSize: c_int, maxDstSize: c_int)
    // }
};

pub fn freeConverted(bytes: []const u8) void {
    _ = bytes;
}
