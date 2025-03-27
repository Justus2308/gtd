const std = @import("std");
const geo = @import("geo");
const shader = @import("shader");
const sokol = @import("sokol");
const gfx = sokol.gfx;

const v2f32 = geo.points.v2f32;
const v4f32 = geo.points.v4f32;
const m4f32 = geo.points.m4f32;

var app_state = AppState{};
var draw_frame = DrawFrame{};

const AppState = struct {
    pass_action: gfx.PassAction = .{},
    pipeline: gfx.Pipeline = .{},
    bindings: gfx.Bindings = .{},
};

pub const RunSokolAppOptions = struct {
    alloc_fn: ?fn (size: usize) ?*anyopaque = null,
    realloc_fn: ?fn (ptr: ?*anyopaque, new_size: usize) ?*anyopaque = null,
    free_fn: ?fn (ptr: ?*anyopaque) void = null,
};
pub fn runSokolApp(window_title: [:0]const u8, window_width: i32, window_height: i32) void {
    sokol.app.run(.{
        .init_cb = init,
        .cleanup_cb = cleanup,
        .frame_cb = frame,
        .width = window_width,
        .height = window_height,
        .fullscreen = true,
        .window_title = window_title,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    });
}

fn init() callconv(.c) void {
    gfx.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    app_state.bindings.vertex_buffers[0] = gfx.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = 0,
    });

    var indices: [max_quad_count]u16 = undefined;
    var i: usize = 0;
    while (i < indices.len) : (i += 6) {
        indices[i + 0] = (((i / 6) * 4) + 0);
        indices[i + 1] = (((i / 6) * 4) + 1);
        indices[i + 2] = (((i / 6) * 4) + 2);
        indices[i + 3] = (((i / 6) * 4) + 0);
        indices[i + 4] = (((i / 6) * 4) + 2);
        indices[i + 5] = (((i / 6) * 4) + 3);
    }
    app_state.bindings.index_buffer = gfx.makeBuffer(.{
        .type = .INDEXBUFFER,
        .data = .{ .ptr = &indices, .size = @sizeOf(indices) },
    });

    app_state.bindings.samplers[shader.SMP_default_sampler] = gfx.makeSampler(.{});

    var pipe_layout_attrs: @FieldType(gfx.VertexLayoutState, "attrs") = @splat(.{});
    pipe_layout_attrs[shader.ATTR_quad_position] = .{ .format = .FLOAT2 };
    pipe_layout_attrs[shader.ATTR_quad_color0] = .{ .format = .FLOAT4 };
    pipe_layout_attrs[shader.ATTR_quad_uv0] = .{ .format = .FLOAT2 };
    pipe_layout_attrs[shader.ATTR_quad_bytes0] = .{ .format = .UBYTE4N };

    var pipe_colors: @FieldType(gfx.PipelineDesc, "colors") = @splat(.{});
    pipe_colors[0] = .{ .blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .op_rgb = .ADD,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        .op_alpha = .ADD,
    } };

    app_state.pipeline = gfx.makePipeline(.{
        .shader = gfx.makeShader(shader.quadShaderDesc(gfx.queryBackend())),
        .index_type = .UINT16,
        .layout = .{ .attrs = pipe_layout_attrs },
        .colors = pipe_colors,
    });

    var pass_act_colors: @FieldType(gfx.PassAction, "colors") = @splat(.{});
    pass_act_colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } };

    app_state.pass_action = .{
        .colors = pass_act_colors,
    };
}

fn cleanup() callconv(.c) void {
    gfx.shutdown();
}

fn frame() callconv(.c) void {
    @memset(@as([]u8, @ptrCast(&draw_frame)), 0);

    app_state.bindings.images[0] = .{}; // TODO

    gfx.updateBuffer(app_state.bindings.vertex_buffers[0], .{
        .ptr = &draw_frame.quads,
        .size = (@sizeOf(Quad) * draw_frame.quads.len),
    });
    gfx.beginPass(.{
        .action = app_state.pass_action,
        .swapchain = sokol.glue.swapchain(),
    });
    gfx.applyPipeline(app_state.pipeline);
    gfx.applyBindings(app_state.bindings);
    gfx.draw(0, (6 * draw_frame.quad_count), 1);
    gfx.endPass();
    gfx.commit();
}

pub const Vertex = extern struct {
    pos: v2f32.V = v2f32.zero,
    col: v4f32.V = v4f32.zero,
    uv: v2f32.V = v2f32.zero,
    tex_index: u8 = 0,
};
pub const Quad = [4]Vertex;

pub const max_quad_count = 8 * 1024;
pub const max_vert_count = 4 * max_quad_count;

pub const DrawFrame = extern struct {
    quads: [max_quad_count]Quad = @splat(@as(Quad, @splat(.{}))),
    quad_count: c_int = 0,
    projection: m4f32.M = m4f32.zero,
};

pub const Palette = struct {
    const data = std.enums.directEnumArray(Name, gfx.Color, 0, .{
        .white = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .black = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    });
    pub const Name = enum(usize) {
        white = 0,
        black,
    };

    pub inline fn get(comptime name: Name) gfx.Color {
        comptime return Palette.data[@intFromEnum(name)];
    }
};
