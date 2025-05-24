allocator: Allocator,
sokol_allocator: *SokolAllocator,

const Self = @This();

const std = @import("std");
const stdx = @import("stdx");
const sokol = @import("sokol");
const gfx = sokol.gfx;
const mem = std.mem;
const Allocator = mem.Allocator;
const Renderer = @import("Renderer.zig");
const assert = std.debug.assert;

pub fn init(allocator: Allocator) Allocator.Error!Self {
    const sokol_allocator = try allocator.create(SokolAllocator);
    sokol_allocator.* = .init(allocator);
    gfx.setup(.{
        .allocator = .{
            .alloc_fn = &SokolAllocator.alloc,
            .free_fn = &SokolAllocator.free,
            .user_data = sokol_allocator,
        },
        .environment = sokol.glue.environment(),
        .logger = .{ .func = &log },
    });
    const self = Self{
        .allocator = allocator,
        .sokol_allocator = sokol_allocator,
    };
    return self;
}

pub fn deinit(self: *Self) void {
    gfx.shutdown();
    self.sokol_allocator.deinit();
}

fn Cache(comptime K: type, comptime V: type) type {
    return struct {
        map: std.AutoHashMapUnmanaged(K, V),
        lock: std.Thread.Mutex,

        pub const empty = @This(){
            .map = .empty,
            .lock = .{},
        };

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.lock.lock();
            self.map.deinit(allocator);
            self.lock.unlock();
            self.* = undefined;
        }
    };
}

pub const Shader = gfx.Shader;

pub const Pipeline = gfx.Pipeline;

fn attrFormatToSokol(format: Renderer.Attribute.Format) gfx.VertexFormat {
    return switch (format) {
        .f32 => .FLOAT,
        .v2f32 => .FLOAT2,
        .v3f32 => .FLOAT3,
        .v4f32 => .FLOAT4,

        .i32 => .INT,
        .v2i32 => .INT2,
        .v3i32 => .INT3,
        .v4i32 => .INT4,

        .u32 => .UINT,
        .v2u32 => .UINT2,
        .v3u32 => .UINT3,
        .v4u32 => .UINT4,

        .v4i8 => .BYTE4,
        .v4i8n => .BYTE4N,

        .v4u8 => .UBYTE4,
        .v4u8n => .UBYTE4N,

        .v2i16 => .SHORT2,
        .v2i16n => .SHORT2N,

        .v2u16 => .USHORT2,
        .v2u16n => .USHORT2N,

        .v4i16 => .SHORT4,
        .v4i16n => .SHORT4N,

        .v4u16 => .USHORT4,
        .v4u16n => .USHORT4N,
    };
}

pub fn createPipeline(
    comptime kind: Renderer.PipelineKind,
    shader: Shader,
    options: Renderer.PipelineOptions(kind),
) Pipeline {
    const desc: gfx.PipelineDesc = switch (kind) {
        .graphics => graphics: {
            var buffers: @FieldType(gfx.VertexLayoutState, "buffers") = @splat(.{});
            for (options.layout.buffers) |buffer| {
                buffers[buffer.binding] = .{
                    .stride = @intCast(buffer.stride),
                };
            }
            var attrs: @FieldType(gfx.VertexLayoutState, "attrs") = @splat(.{});
            for (options.layout.attrs) |attr| {
                attrs[attr.location] = .{
                    .buffer_index = @intCast(attr.binding),
                    .offset = @intCast(attr.offset),
                    .format = attrFormatToSokol(attr.format),
                };
            }
            break :graphics .{
                .compute = false,
                .shader = shader,
                .layout = .{
                    .buffers = buffers,
                    .attrs = attrs,
                },
                .primitive_type = switch (options.primitive) {
                    .points => .POINTS,
                    .lines => .LINES,
                    .line_strip => .LINE_STRIP,
                    .triangles => .TRIANGLES,
                    .triangle_strip => .TRIANGLE_STRIP,
                },
                .index_type = switch (options.index) {
                    .none => .NONE,
                    .u16 => .UINT16,
                    .u32 => .UINT32,
                },
            };
        },
        .compute => .{
            .compute = true,
            .shader = shader,
        },
    };

    const pipeline = gfx.makePipeline(desc);
    return pipeline;
}

pub fn destroyPipeline(pipeline: Pipeline) void {
    gfx.destroyPipeline(pipeline);
}

pub const max_attr_count = gfx.max_vertex_attributes;

pub const Sampler = gfx.Sampler;

pub fn createSampler(options: Renderer.SamplerOptions) Sampler {
    const desc = gfx.SamplerDesc{
        .min_filter = switch (options.min_filter) {
            .nearest => .NEAREST,
            .linear => .LINEAR,
        },
        .mag_filter = switch (options.mag_filter) {
            .nearest => .NEAREST,
            .linear => .LINEAR,
        },
        .wrap_u = switch (options.wrap_u) {
            .repeat => .REPEAT,
            .clamp_to_edge => .CLAMP_TO_EDGE,
            .clamp_to_border => .CLAMP_TO_BORDER,
            .mirrored_repeat => .MIRRORED_REPEAT,
        },
        .wrap_v = switch (options.wrap_v) {
            .repeat => .REPEAT,
            .clamp_to_edge => .CLAMP_TO_EDGE,
            .clamp_to_border => .CLAMP_TO_BORDER,
            .mirrored_repeat => .MIRRORED_REPEAT,
        },
        .compare = switch (options.compare) {
            .never => .NEVER,
            .lt => .LESS,
            .eq => .EQUAL,
            .le => .LESS_EQUAL,
            .gt => .GREATER,
            .ne => .NOT_EQUAL,
            .ge => .GREATER_EQUAL,
            .always => .ALWAYS,
        },
    };
    const sampler = gfx.makeSampler(desc);
    return sampler;
}

pub fn destroySampler(sampler: Sampler) void {
    gfx.destroySampler(sampler);
}

pub const Image = gfx.Image;
pub fn createTexture(width: u32, height: u32, pixels: []const u8) Image {
    const image_data: gfx.ImageData = .{};
    image_data[0][0] = gfx.asRange(pixels);
    const desc = gfx.ImageDesc{
        .type = ._2D,
        .render_target = false,
        .width = @intCast(width),
        .height = @intCast(height),
        .usage = .DYNAMIC,
        .pixel_format = .RGBA8,
        .sample_count = 1,
        .data = image_data,
    };
    const image = gfx.makeImage(desc);
    return image;
}

pub fn destroyTexture(image: Image) void {
    gfx.destroyImage(image);
}

pub const Buffer = gfx.Buffer;

pub fn createBuffer(kind: Renderer.BufferKind, content: Renderer.BufferContent) Buffer {
    const size: usize, const data: gfx.Range, const usage: gfx.Usage = switch (content) {
        .static => |bytes| .{ 0, gfx.asRange(bytes), .IMMUTABLE },
        .dynamic => |size| .{ size, .{}, .DYNAMIC },
        .stream => |size| .{ size, .{}, .STREAM },
    };
    const buffer = gfx.makeBuffer(.{
        .size = size,
        .data = data,
        .type = switch (kind) {
            .vertex => .VERTEXBUFFER,
            .index => .INDEXBUFFER,
            .storage => .STORAGEBUFFER,
        },
        .usage = usage,
    });
    return buffer;
}

pub fn destroyBuffer(buffer: Buffer) void {
    gfx.destroyBuffer(buffer);
}

/// Should be passed as `user_data`
const SokolAllocator = struct {
    allocator: Allocator,
    tracked_allocs: Cache(usize, usize),

    pub fn init(allocator: Allocator) SokolAllocator {
        return .{
            .allocator = allocator,
            .tracked = .empty,
        };
    }

    pub fn deinit(sokol_allocator: *SokolAllocator) void {
        assert(sokol_allocator.tracked_allocs.map.size == 0);
        sokol_allocator.tracked_allocs.deinit(sokol_allocator.allocator);
        sokol_allocator.* = undefined;
    }

    fn alloc(size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
        if (size == 0) {
            return null;
        }

        const sokol_allocator: *SokolAllocator = @alignCast(@ptrCast(user_data));

        const alignment = mem.Alignment.fromByteUnits(
            @min(std.math.ceilPowerOfTwoAssert(usize, size), @alignOf(*anyopaque)),
        );

        sokol_allocator.tracked_allocs.lock.lock();
        defer sokol_allocator.tracked_allocs.lock.unlock();

        sokol_allocator.tracked_allocs.map.ensureUnusedCapacity(sokol_allocator.allocator, 1) catch return null;
        const ptr = sokol_allocator.allocator.rawAlloc(size, alignment, @returnAddress());
        if (ptr) |p| {
            sokol_allocator.tracked_allocs.map.putAssumeCapacityNoClobber(@intFromPtr(p), size);
        }
        return @ptrCast(ptr);
    }
    fn free(ptr: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
        if (ptr) |p| {
            const sokol_allocator: *SokolAllocator = @alignCast(@ptrCast(user_data));

            const size = size: {
                sokol_allocator.tracked_allocs.lock.lock();
                defer sokol_allocator.tracked_allocs.lock.unlock();

                const kv = sokol_allocator.tracked_allocs.map.fetchRemove(@intFromPtr(p)) orelse
                    @panic("tried to free untracked allocation");
                break :size kv.value;
            };
            const alignment = mem.Alignment.fromByteUnits(
                @min(std.math.ceilPowerOfTwoAssert(usize, size), @alignOf(*anyopaque)),
            );
            sokol_allocator.allocator.rawFree(ptr[0..size], alignment, @returnAddress());
        }
    }
};

const AllocUserData = struct {
    allocator: Allocator,
    tracked: Cache(usize, usize),
};

fn log(
    tag: ?[*:0]const u8,
    log_level: u32,
    log_item_id: u32,
    message_or_null: ?[*:0]const u8,
    line_nr: u32,
    filename_or_null: ?[*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = user_data;
    const tag_nonnull = tag orelse "?";
    const log_item = if (std.meta.intToEnum(sokol.app.LogItem, log_item_id)) |item|
        @tagName(item)
    else |_|
        "UNKNOWN";
    const message = message_or_null orelse "No message provided";
    const filename = filename_or_null orelse "?";
    const format = "[{s}:{s}:{d}]: {s}: {s}";
    const args = .{ tag_nonnull, filename, line_nr, log_item, message };
    const sokol_log = std.log.scoped(.sokol);
    switch (log_level) {
        0 => stdx.fatal(.dependency, "(sokol): " ++ format, args),
        1 => sokol_log.err(format, args),
        2 => sokol_log.warn(format, args),
        else => sokol_log.info(format, args),
    }
}
