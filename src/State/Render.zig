passes: struct {
    default: struct {
        pass_action: gfx.PassAction,
        pipeline: gfx.Pipeline,
        bindings: gfx.Bindings,
    },
    quad: struct {
        pass: gfx.Pass,
        pipeline: gfx.Pipeline,
        bindings: gfx.Bindings,
    },
},
pipeline_cache: PipelineCache,
sampler_cache: SamplerCache,

const Render = @This();

pub const backend = @import("Render/backend.zig");

pub const PipelineHashable = struct {
    index_type: gfx.IndexType,
    uv_format: gfx.VertexFormat,
    primitive_type: gfx.PrimitiveType,
    shader: gfx.Shader,
    winding: gfx.FaceWinding,
};
pub const PipelineCache = std.AutoHashMap(PipelineHashable, gfx.Pipeline);

pub const SamplerHashable = struct {
    min_filter: gfx.Filter,
    mag_filter: gfx.Filter,
    wrap_u: gfx.Wrap,
    wrap_v: gfx.Wrap,
    wrap_w: gfx.Wrap,
    compare: gfx.CompareFunc,
};
pub const SamplerCache = std.AutoHashMap(SamplerHashable, gfx.Sampler);

const VertexPos = v3f32.V;
const VertexInfo = extern struct {
    _: void align(4) = {},
    uv_ext: [4]u16,
    color: [4]u8,

    pub fn init(uv: v2f32.V, layer: u8, color: Color) VertexInfo {
        const uv_factor = comptime v2f32.splat(@floatFromInt(std.math.maxInt(u16)));
        const uv_denorm: @Vector(2, u16) = @intFromFloat(uv * uv_factor);
        return VertexInfo{
            .uv_ext = .{ uv_denorm[0], uv_denorm[1], layer, 0 },
            .color = color.value(),
        };
    }
    pub fn quads(color: Color) [4]VertexInfo {
        var verts: [4]VertexInfo = .{
            .init(.{ 1, 1 }, 0, color),
            .init(.{ 1, 0 }, 0, color),
            .init(.{ 0, 0 }, 0, color),
            .init(.{ 0, 1 }, 0, color),
        };
        inline for (&verts) |*info| {
            info.uv_ext[3] = 1;
        }
        return verts;
    }

    // pub const quads = blk: {
    //     var quads: [4]VertexInfo = .{
    //         .init(.{ 1, 1 }, 0, .white),
    //         .init(.{ 1, 0 }, 0, .white),
    //         .init(.{ 0, 0 }, 0, .white),
    //         .init(.{ 0, 1 }, 0, .white),
    //     };
    // };

    comptime {
        assert(@sizeOf(@This()) == 12);
    }
};

const QuadPos = [4]v2f32.V;
const QuadInfo = extern struct {
    data: [4]extern struct {
        _: void align(8) = {},
        uv: [2]u16,
        color: [4]u8,

        comptime {
            assert(@sizeOf(@This()) == 8);
        }
    },

    pub fn init(uv: [4]v2f32.V, color: Color) QuadInfo {
        const uv_factor = comptime v2f32.splat(@floatFromInt(std.math.maxInt(u16)));

        var quad_info: QuadInfo = undefined;
        inline for (0..4) |i| {
            const uv_denorm: @Vector(2, u16) = @intFromFloat(uv[i] * uv_factor);
            quad_info.data[i] = .{
                .uv = uv_denorm,
                .color = color.value(),
            };
        }
        return quad_info;
    }
};

const initial_buffer_size = 16 << 10 << 10;
const max_quad_count = 8 << 10;

pub fn init(allocator: Allocator) Render {
    gfx.setup(.{
        .shader_pool_size = stdx.countDecls(shader, .{
            .type = .{ .id = .@"fn" },
            .name = .{ .ends_with = "ShaderDesc" },
        }),
        .pipeline_pool_size = std.meta.fields(@FieldType(Render, "passes")).len,
        .environment = sokol.glue.environment(),
        .logger = .{ .func = &sokolLog },
    });
    audio.setup(.{
        .logger = .{ .func = &sokolLog },
    });

    var render: Render = std.mem.zeroes(Render);

    const sampler = gfx.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .wrap_u = .REPEAT,
        .wrap_v = .REPEAT,
        .label = "sampler",
    });

    // quad pass

    const quad_sample_count = 1;
    const quad_pixel_format = gfx.PixelFormat.RGBA8;

    const image_array = gfx.makeImage(.{
        .type = .ARRAY,
    });

    var quad_offscreen_desc = gfx.ImageDesc{
        .render_target = true,
        .width = 1024,
        .height = 1024,
        .pixel_format = quad_pixel_format,
        .sample_count = quad_sample_count,
        .label = "quad-offscreen-target",
    };
    const quad_offscreen_target = gfx.makeImage(quad_offscreen_desc);

    quad_offscreen_desc.pixel_format = .DEPTH;
    quad_offscreen_desc.label = "quad-offscreen-depth";
    const quad_offscreen_depth = gfx.makeImage(quad_offscreen_desc);

    render.passes.quad.pass = .{
        .attachments = gfx.makeAttachments(.{
            .colors = stdx.zeroInitArray(@FieldType(gfx.AttachmentsDesc, "colors"), &.{
                .{ 0, .{ .image = quad_offscreen_target } },
            }),
            .depth_stencil = .{ .image = quad_offscreen_depth },
            .label = "quad-attachments",
        }),
        .action = .{ .colors = stdx.zeroInitArray(@FieldType(gfx.PassAction, "colors"), &.{
            .{ 0, .{
                .load_action = .CLEAR,
                .clear_value = Color.green.fp(),
            } },
        }) },
        .label = "quad-pass",
    };

    const quad_position_buffer = gfx.makeBuffer(.{
        .usage = .STREAM,
        .size = (max_quad_count * @sizeOf(QuadPos)),
        .label = "quad-positions",
    });
    render.passes.quad.bindings.vertex_buffers[0] = quad_position_buffer;

    const quad_color_buffer = gfx.makeBuffer(.{
        .usage = .STREAM,
        .size = (max_quad_count * @sizeOf(QuadInfo)),
        .label = "quad-info",
    });
    render.passes.quad.bindings.vertex_buffers[1] = quad_color_buffer;

    var quad_indices: [max_quad_count * 6]u16 = undefined;
    var i: usize = 0;
    while (i < quad_indices.len) : (i += 6) {
        quad_indices[i + 0] = @intCast((i / 6) * 4 + 0);
        quad_indices[i + 1] = @intCast((i / 6) * 4 + 1);
        quad_indices[i + 2] = @intCast((i / 6) * 4 + 3);
        quad_indices[i + 3] = @intCast((i / 6) * 4 + 1);
        quad_indices[i + 4] = @intCast((i / 6) * 4 + 2);
        quad_indices[i + 5] = @intCast((i / 6) * 4 + 3);
    }
    const quad_index_buffer = gfx.makeBuffer(.{
        .type = .INDEXBUFFER,
        .usage = .IMMUTABLE,
        .data = gfx.asRange(&quad_indices),
        .label = "quad-indices",
    });
    render.passes.quad.bindings.index_buffer = quad_index_buffer;

    const quad_shader = gfx.makeShader(shader.quadShaderDesc(gfx.queryBackend()));
    const quad_pipeline = gfx.makePipeline(.{
        .layout = .{ .attrs = stdx.zeroInitArray(@FieldType(gfx.VertexLayoutState, "attrs"), &.{
            .{ shader.ATTR_quad_in_pos, .{ .format = .FLOAT2, .buffer_index = 0 } },
            .{ shader.ATTR_quad_in_uv, .{ .format = .USHORT2N, .buffer_index = 1 } },
            .{ shader.ATTR_quad_in_color, .{ .format = .UBYTE4N, .buffer_index = 1 } },
        }) },
        .shader = quad_shader,
        .index_type = .UINT16,
        .cull_mode = .BACK,
        .depth = .{
            .pixel_format = .DEPTH,
            .compare = .ALWAYS,
            .write_enabled = false,
        },
        .sample_count = quad_sample_count,
        .colors = stdx.zeroInitArray(@FieldType(gfx.PipelineDesc, "colors"), &.{
            .{ 0, .{ .pixel_format = quad_pixel_format } },
        }),
        .label = "quad-pipeline",
    });
    render.passes.quad.pipeline = quad_pipeline;

    // default pass

    render.passes.default.pass_action = gfx.PassAction{
        .colors = stdx.zeroInitArray(@FieldType(gfx.PassAction, "colors"), &.{
            .{ 0, .{
                .load_action = .CLEAR,
                .clear_value = Color.blue.fp(),
            } },
        }),
    };

    const default_position_buffer = gfx.makeBuffer(.{
        .usage = .STREAM,
        .size = initial_buffer_size,
        .label = "default-positions",
    });
    render.passes.default.bindings.vertex_buffers[0] = default_position_buffer;

    const default_color_buffer = gfx.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = initial_buffer_size,
        .label = "default-colors",
    });
    render.passes.default.bindings.vertex_buffers[1] = default_color_buffer;

    const default_index_buffer = gfx.makeBuffer(.{
        .type = .INDEXBUFFER,
        .usage = .DYNAMIC,
        .size = initial_buffer_size,
        .label = "default-indices",
    });
    render.passes.default.bindings.index_buffer = default_index_buffer;

    render.passes.default.bindings.images[shader.IMG_tex_quads] = quad_offscreen_target;
    render.passes.default.bindings.samplers[shader.SMP_smp] = sampler;

    const default_shader = gfx.makeShader(shader.defaultShaderDesc(gfx.queryBackend()));
    const default_pipeline = gfx.makePipeline(.{
        .layout = .{ .attrs = stdx.zeroInitArray(@FieldType(gfx.VertexLayoutState, "attrs"), &.{
            .{ shader.ATTR_default_in_pos, .{ .format = .FLOAT3, .buffer_index = 0 } },
            .{ shader.ATTR_default_in_uv_ext, .{ .format = .USHORT4N, .buffer_index = 1 } },
            .{ shader.ATTR_default_in_color, .{ .format = .UBYTE4N, .buffer_index = 1 } },
        }) },
        .shader = default_shader,
        .index_type = .UINT16,
        .cull_mode = .BACK,
        .depth = .{
            .compare = .LESS,
            .write_enabled = true,
        },
        .label = "default-pipeline",
    });
    render.passes.default.pipeline = default_pipeline;

    render.pipeline_cache = .init(allocator);
    render.sampler_cache = .init(allocator);
    return render;
}

pub fn deinit(render: *Render) void {
    gfx.shutdown();
    audio.shutdown();
    render.* = undefined;
}

pub fn update(render: *Render, dt: u64) void {
    _ = dt;
    // const asset_manager = &render.parentState().asset_manager;

    gfx.updateBuffer(render.passes.quad.bindings.vertex_buffers[0], gfx.asRange(&[_][2]f32{
        .{ 0.5, 0.5 },
        .{ 0.5, -0.5 },
        .{ -0.5, -0.5 },
        .{ -0.5, 0.5 },
    }));
    gfx.updateBuffer(render.passes.quad.bindings.vertex_buffers[1], gfx.asRange(&[_]QuadInfo{
        .init(.{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } }, .red),
    }));

    {
        gfx.beginPass(render.passes.quad.pass);
        defer gfx.endPass();

        gfx.applyPipeline(render.passes.quad.pipeline);
        gfx.applyBindings(render.passes.quad.bindings);
        gfx.draw(0, 6, 1);
    }

    gfx.updateBuffer(render.passes.default.bindings.vertex_buffers[0], gfx.asRange(&[_][3]f32{
        .{ 0.5, 0.5, 0.5 },
        .{ 0.5, -0.5, 0.5 },
        .{ -0.5, -0.5, 0.5 },
        .{ -0.5, 0.5, 0.5 },
    }));
    gfx.updateBuffer(render.passes.default.bindings.vertex_buffers[1], gfx.asRange(&[_]VertexInfo{
        .init(.{ 1, 1 }, 0, .{}),
        .init(.{ 1, 0 }, 0, .{}),
        .init(.{ 0, 0 }, 0, .{}),
        .init(.{ 0, 1 }, 0, .{}),
    }));
    gfx.updateBuffer(render.passes.default.bindings.index_buffer, gfx.asRange(&[_]u16{
        0, 1, 3, 1, 2, 3,
    }));

    {
        gfx.beginPass(.{
            .action = render.passes.default.pass_action,
            .swapchain = sokol.glue.swapchain(),
            .label = "default-pass",
        });
        defer gfx.endPass();

        gfx.applyPipeline(render.passes.default.pipeline);
        gfx.applyBindings(render.passes.default.bindings);
        gfx.applyUniforms(shader.UB_vs_params, gfx.asRange(&m4f32.ident));
        gfx.draw(0, 6, 1);
    }
    gfx.commit();
}

pub fn sokolLog(
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
        0 => std.debug.panic("(sokol): " ++ format, args),
        1 => sokol_log.err(format, args),
        2 => sokol_log.warn(format, args),
        else => sokol_log.info(format, args),
    }
}

inline fn parentState(render: *Render) *State {
    return @fieldParentPtr("render", render);
}

pub const Color = enum(u32) {
    white = colorCast(255, 255, 255, 255),
    black = colorCast(0, 0, 0, 255),

    red = colorCast(255, 0, 0, 255),
    green = colorCast(0, 255, 0, 255),
    blue = colorCast(0, 0, 255, 255),

    pub inline fn init(r: u8, g: u8, b: u8, a: u8) Color {
        return @enumFromInt(colorCast(r, g, b, a));
    }

    pub inline fn value(color: Color) [4]u8 {
        return @bitCast(@intFromEnum(color));
    }
    pub inline fn fp(color: Color) gfx.Color {
        const vec: @Vector(4, u8) = color.value();
        var vec_fp: v4f32.V = @floatFromInt(vec);
        vec_fp /= v4f32.splat(255);
        return @bitCast(vec_fp);
    }
};
inline fn colorCast(r: u8, g: u8, b: u8, a: u8) u32 {
    const val = [4]u8{ r, g, b, a };
    return @bitCast(val);
}

const builtin = @import("builtin");
const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");
const hmm = @import("hmm");
const sokol = @import("sokol");
const shader = @import("shader");
const audio = sokol.audio;
const gfx = sokol.gfx;
const mem = std.mem;
const v2f32 = geo.linalg.v2f32;
const v3f32 = geo.linalg.v3f32;
const v4f32 = geo.linalg.v4f32;
const m4f32 = geo.linalg.m4f32;
const Allocator = std.mem.Allocator;
const State = @import("State");
const assert = std.debug.assert;
const is_test = builtin.is_test;
const is_debug = (builtin.mode == .Debug);
