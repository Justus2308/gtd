impl: Impl,

const Renderer = @This();
const Impl = @import("Sokol.zig");

pub fn init(gpa: Allocator) Allocator.Error!Renderer {
    return .{ .impl = try .init(gpa) };
}
pub fn deinit(self: *Renderer) void {
    self.impl.deinit();
}

pub const Shader = Impl.Shader;
pub const Pipeline = Impl.Pipeline;
pub const Image = Impl.Image;
pub const Sampler = Impl.Sampler;
pub const Buffer = Impl.Buffer;

pub const max_attr_count = Impl.max_attr_count;

pub fn createTexture(width: u32, height: u32, pixels: []const u8) Image {
    assert(pixels.len == (width * height));
    return Impl.createTexture(width, height, pixels);
}
pub fn destroyTexture(image: Image) void {
    Impl.destroyTexture(image);
}

pub fn createPipeline(
    comptime kind: PipelineKind,
    shader: Shader,
    options: PipelineOptions(kind),
) Pipeline {
    Impl.createPipeline(kind, shader, options);
}
pub fn destroyPipeline(pipeline: Pipeline) void {
    Impl.destroyPipeline(pipeline);
}

pub fn createSampler(options: SamplerOptions) Sampler {
    return Impl.createSampler(options);
}
pub fn destroySampler(sampler: Sampler) void {
    Impl.destroySampler(sampler);
}

pub fn createBuffer(kind: BufferKind, content: BufferContent) Buffer {
    return Impl.createBuffer(kind, content);
}
pub fn destroyBuffer(buffer: Buffer) void {
    Impl.destroyBuffer(buffer);
}

pub const PipelineKind = enum {
    graphics,
    compute,
};
pub const PipelineGraphicsOptions = struct {
    layout: struct {
        buffers: []BufferLayout = &.{},
        attrs: []Attribute = &.{},
    },
    primitive: Mesh.Primitive.Type = .triangles,
    index: Index = .none,
    cull: Cull = .none,
    alpha: bool = false,
};
pub const PipelineComputeOptions = struct {};

pub fn PipelineOptions(comptime kind: PipelineKind) type {
    return switch (kind) {
        .graphics => PipelineGraphicsOptions,
        .compute => PipelineComputeOptions,
    };
}

pub const ShaderContext = struct {
    shader: Shader,
    bind_pos: u32,
    bind_uv: u32,
    bind_color: u32,
};

pub const BufferLayout = struct {
    binding: u32,
    stride: u32,
};

pub const Attribute = struct {
    location: u32,
    binding: u32,
    format: Format,
    offset: u32 = 0,

    pub const Format = enum {
        f32,
        v2f32,
        v3f32,
        v4f32,

        i32,
        v2i32,
        v3i32,
        v4i32,

        u32,
        v2u32,
        v3u32,
        v4u32,

        v4i8,
        v4i8n,
        v4u8,
        v4u8n,

        v2i16,
        v2i16n,
        v2u16,
        v2u16n,
        v4i16,
        v4i16n,
        v4u16,
        v4u16n,
    };

    pub fn computeOffsets(comptime T: type) std.enums.EnumArray(std.meta.FieldEnum(T), u32) {
        comptime {
            const E = std.meta.FieldEnum(T);
            var offsets = std.enums.EnumArray(E, u32).initUndefined();
            for (std.enums.values(E)) |tag| {
                const offset = @offsetOf(T, @tagName(tag));
                offsets.set(tag, offset);
            }
            return offsets;
        }
    }
};

pub const Index = enum {
    none,
    u16,
    u32,
};
pub const Cull = enum {
    none,
    front,
    back,
};
pub const Winding = enum {
    cw,
    ccw,
};

pub const SamplerOptions = struct {
    min_filter: Filter,
    mag_filter: Filter,
    wrap_u: Wrap,
    wrap_v: Wrap,
    compare: Compare,
};

pub const Filter = enum {
    nearest,
    linear,
};
pub const Wrap = enum {
    repeat,
    clamp_to_edge,
    clamp_to_border,
    mirrored_repeat,
};
pub const Compare = enum {
    never,
    lt,
    eq,
    le,
    gt,
    ne,
    ge,
    always,
};

pub const Mesh = struct {
    matrix: [16]f32,
    primitives: []Primitive,

    pub const Primitive = struct {
        positions: []const [3]f32,
        indices: Indices,
        uv: Uv,
        type: Primitive.Type,
        pipeline_handle: asset.Manager.Handle,
        texture_handle: ?asset.Manager.Handle,

        pub const Type = enum {
            points,
            lines,
            line_strip,
            triangles,
            triangle_strip,
        };

        pub const Indices = union(Index) {
            none,
            u16: []const u16,
            u32: []const u32,
        };
        pub const Uv = union(enum) {
            v2u16: []const [2]u16,
            v2f32: []const [2]f32,
        };
    };
};

pub const Material = struct {
    texture_handle: asset.Manager.Handle,
    alpha_mode: AlphaMode,
    cull_mode: Cull,

    pub const AlphaMode = union(enum) {
        none,
        blend,
        mask: f32,
    };
};

pub const BufferKind = enum {
    vertex,
    index,
    storage,
};

pub const BufferContent = union(enum) {
    static: []const u8,
    dynamic: usize,
    stream: usize,
};

const std = @import("std");
const asset = @import("asset");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
