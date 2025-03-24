passes: std.enums.EnumArray(enum {
    default,
    inst,
}, Pass),

const Render = @This();

const Pass = struct {
    action: gfx.PassAction,
    pipeline: gfx.Pipeline,
    bindings: gfx.Bindings,
};

const Vertex = extern struct {
    pos: v2f32.V,
    uv: v2f32.V,
    color: gfx.Color,
};

const initial_buffer_size = 16 << 10 << 10;

pub fn init(allocator: Allocator) Render {
    _ = allocator;
    gfx.setup(.{
        .shader_pool_size = stdx.countDecls(shader, .{
            .type = .{ .id = .@"fn" },
            .name = .{ .ends_with = "ShaderDesc" },
        }),
        .pipeline_pool_size = @FieldType(Render, "passes").len,
        .environment = sokol.glue.environment(),
        .logger = .{ .func = &sokolLog },
    });
    audio.setup(.{
        .logger = .{ .func = &sokolLog },
    });

    var render = Render{ .passes = .initUndefined() };

    // default pass (renders single objects, can handle 2d and 3d)

    const default_pass = render.passes.getPtr(.default);

    const default_position_buffer = gfx.makeBuffer(.{
        .usage = .STREAM,
        .size = initial_buffer_size,
        .label = "default-positions",
    });
    default_pass.bindings.vertex_buffers[0] = default_position_buffer;

    const default_color_buffer = gfx.makeBuffer(.{
        .usage = .STREAM,
        .size = initial_buffer_size,
        .label = "default-colors",
    });
    default_pass.bindings.vertex_buffers[1] = default_color_buffer;

    const default_index_buffer = gfx.makeBuffer(.{
        .type = .INDEXBUFFER,
        .usage = .DYNAMIC,
        .size = initial_buffer_size,
        .label = "default-indices",
    });
    default_pass.bindings.index_buffer = default_index_buffer;

    const default_shader = gfx.makeShader(shader.defaultShaderDesc(gfx.queryBackend()));
    const default_pipeline = gfx.makePipeline(.{
        .layout = .{ .attrs = blk: {
            var attrs: @FieldType(gfx.VertexLayoutState, "attrs") = @splat(.{});
            attrs[shader.ATTR_default_in_pos] = .{
                .format = .FLOAT3,
                .buffer_index = 0,
            };
            attrs[shader.ATTR_default_in_color] = .{
                .format = .FLOAT4,
                .buffer_index = 1,
            };
            attrs[shader.ATTR_default_in_uv] = .{
                .format = .FLOAT2,
                .buffer_index = 1,
            };
            attrs[shader.ATTR_default_in_uv_offset] = .{
                .format = .FLOAT2,
                .buffer_index = 1,
            };
            attrs[shader.ATTR_default_in_bytes] = .{
                .format = .FLOAT2,
                .buffer_index = 1,
            };
            break :blk attrs;
        } },
        .shader = default_shader,
        .index_type = .UINT16,
        .cull_mode = .BACK,
        .depth = .{
            .compare = .LESS,
            .write_enabled = true,
        },
        .label = "default-pipeline",
    });
    default_pass.pipeline = default_pipeline;

    // instancing pass (renders many 2d objects with one draw call)

    const inst_pass = render.passes.getPtr(.inst);

    const inst_template_buffer = gfx.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = initial_buffer_size,
        .label = "inst-templates",
    });
    inst_pass.bindings.vertex_buffers[0] = inst_template_buffer;

    const inst_position_buffer = gfx.makeBuffer(.{
        .usage = .STREAM,
        .size = initial_buffer_size,
        .label = "inst-positions",
    });
    inst_pass.bindings.vertex_buffers[1] = inst_position_buffer;

    const inst_index_buffer = gfx.makeBuffer(.{
        .type = .INDEXBUFFER,
        .usage = .DYNAMIC,
        .size = initial_buffer_size,
        .label = "inst-indices",
    });
    inst_pass.bindings.index_buffer = inst_index_buffer;

    const inst_shader = gfx.makeShader(shader.instShaderDesc(gfx.queryBackend()));
    const inst_pipeline = gfx.makePipeline(.{
        .layout = .{
            .buffers = blk: {
                var buffers: @FieldType(gfx.VertexLayoutState, "buffers") = @splat(.{});
                buffers[1].step_func = .PER_INSTANCE;
                break :blk buffers;
            },
            .attrs = blk: {
                var attrs: @FieldType(gfx.VertexLayoutState, "attrs") = @splat(.{});
                attrs[shader.ATTR_inst_in_pos] = .{ .format = .FLOAT2, .buffer_index = 0 };
                attrs[shader.ATTR_inst_in_pos_offset] = .{ .format = .FLOAT2, .buffer_index = 1 };
                attrs[shader.ATTR_inst_in_scale] = .{ .format = .FLOAT2, .buffer_index = 1 };
                attrs[shader.ATTR_inst_in_color] = .{ .format = .FLOAT4, .buffer_index = 2 };
                attrs[shader.ATTR_inst_in_uv] = .{ .format = .FLOAT2, .buffer_index = 2 };
                break :blk attrs;
            },
        },
        .shader = inst_shader,
        .index_type = .UINT16,
        .cull_mode = .BACK,
        .depth = .{
            .compare = .ALWAYS,
            .write_enabled = false,
        },
        .label = "inst-pipeline",
    });
    inst_pass.pipeline = inst_pipeline;

    return render;
}

pub fn deinit(render: *Render) void {
    sokol.gfx.shutdown();
    sokol.audio.shutdown();
    render.* = undefined;
}

pub fn update(render: *Render, dt: u64) void {
    _ = .{ render, dt };
    // const asset_manager = &render.parentState().asset_manager;
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
const Allocator = std.mem.Allocator;
const State = @import("State");
