const std = @import("std");
const stdx = @import("stdx");
const backend = @import("../backend.zig");

const assert = std.debug.assert;

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
    shader: backend.Shader,
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
        pipeline_handle: stdx.asset.Manager.Handle,
        texture_handle: ?stdx.asset.Manager.Handle,

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

        pub fn getPipeline(
            prim: Primitive,
            shader_ctx: ShaderContext,
            winding: gfx.FaceWinding,
            label: ?[*:0]const u8,
        ) gfx.Pipeline {
            const hashable = Render.PipelineHashable{
                .index_type = prim.indices.getIndexType(),
                .uv_format = prim.uv.getVertexFormat(),
                .primitive_type = prim.type,
                .shader = shader_ctx.shader,
                .winding = winding,
            };
            if (pipeline_cache.get(hashable)) |pipeline| {
                return pipeline;
            }

            const stencil_face_alpha_mask = gfx.StencilFaceState{
                .compare = .LESS_EQUAL,
                .fail_op = .ZERO,
                .depth_fail_op = .ZERO,
                .pass_op = .REPLACE,
            };
            const pipeline = gfx.makePipeline(.{
                .compute = false,
                .shader = shader,
                .layout = .{ .attrs = stdx.zeroInitArray(@FieldType(gfx.VertexLayoutState, "attrs"), &.{
                    .{ shader_ctx.pos, .{ .format = .FLOAT3, .buffer_index = 0 } },
                    .{ shader_ctx.uv, .{ .format = prim.uv.getVertexFormat(), .buffer_index = 0 } },
                    .{ shader_ctx.color, .{ .format = .UBYTE4N, .buffer_index = 0 } },
                }) },
                .depth = .{
                    .compare = .LESS,
                    .write_enabled = true,
                },
                .stencil = .{
                    .enabled = (std.meta.activeTag(prim.material.alpha_mode) == .mask),
                    .front = if (prim.material.cull_mode == .FRONT) .{} else stencil_face_alpha_mask,
                    .back = if (prim.material.cull_mode == .BACK) .{} else stencil_face_alpha_mask,
                    .read_mask = 0xFF,
                    .write_mask = 0xFF,
                    .ref = @intFromFloat(@as(f32, std.math.maxInt(u8)) * switch (prim.material.alpha_mode) {
                        .mask => |val| val,
                        else => 1,
                    }),
                },
                .color_count = 1,
                .colors = stdx.zeroInitArray(@FieldType(gfx.PipelineDesc, "colors"), &.{
                    .{ 0, .{
                        .blend = .{
                            .enabled = (prim.material.alpha_mode == .blend),
                            .src_factor_rgb = .SRC_ALPHA,
                            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                            .op_rgb = .ADD,
                            .src_factor_alpha = .SRC_ALPHA,
                            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
                            .op_alpha = .ADD,
                        },
                    } },
                }),
                .primitive_type = prim.type,
                .index_type = prim.indices.getIndexType(),
                .cull_mode = @enumFromInt(@intFromEnum(prim.material.cull_mode)),
                .face_winding = winding,
                .label = label,
            });
            pipeline_cache.putNoClobber(hashable, pipeline) catch |err|
                log.warn("could not cache pipeline: {s}", @errorName(err));
            return pipeline;
        }
    };
};
pub const Material = struct {
    texture_handle: stdx.asset.Manager.Handle,
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
