pass_action: gfx.PassAction,
pipelines: std.enums.EnumFieldStruct(enum {
    sprite,
}, gfx.Pipeline, null),
bindings: gfx.Bindings,

const Render = @This();

const Vertex = extern struct {
    pos: v2f32.V,
    uv: v2f32.V,
    color: gfx.Color,
};

const initial_buffer_size = 16 << 10 << 10;

// BUFFER LAYOUT:
// 0: DYNAMIC, large
// 1: DYNAMIC, large
// 2: STREAM, large

pub fn init(allocator: Allocator) Render {
    _ = allocator;
    gfx.setup(.{
        .shader_pool_size = stdx.countDecls(shader, .{
            .type = .{ .id = .@"fn" },
            .name = .{ .ends_with = "ShaderDesc" },
        }),
        .pipeline_pool_size = std.meta.fields(@FieldType(Render, "pipelines")).len,
        .environment = sokol.glue.environment(),
        .logger = .{ .func = &sokolLog },
    });
    audio.setup(.{
        .logger = .{ .func = &sokolLog },
    });

    var render = Render{};

    const sprite_vertices = [_]Vertex{};
    const sprite_buffer = gfx.makeBuffer(.{
        .usage = .IMMUTABLE,
        .data = gfx.asRange(sprite_vertices),
        .label = @as([*:0]u8, "sprite-vertices"),
    });
    render.bindings.vertex_buffers[0] = sprite_buffer;

    const sprite_inst_buffer = gfx.makeBuffer(.{
        .usage = .STREAM,
        .size = initial_buffer_size,
        .label = @as([*:0]u8, "sprite-instances"),
    });
    render.bindings.vertex_buffers[1] = sprite_inst_buffer;

    const sprite_indices = [_]u16{};
    const sprite_index_buffer = gfx.makeBuffer(.{
        .type = .INDEXBUFFER,
        .data = gfx.asRange(sprite_indices),
    });
    render.bindings.index_buffer = sprite_index_buffer;

    const sprite_shader = gfx.makeShader(shader.spriteShaderDesc(gfx.queryBackend()));
    const sprite_pipeline = gfx.makePipeline(.{
        .layout = .{
            .buffers = blk: {
                var buffers: @FieldType(gfx.VertexLayoutState, "buffers") = @splat(.{});
                buffers[1].step_func = .PER_INSTANCE;
                break :blk buffers;
            },
            .attrs = blk: {
                var attrs: @FieldType(gfx.VertexLayoutState, "attrs") = @splat(.{});
                attrs[shader.ATTR_sprite_in_pos] = .{ .format = .FLOAT2, .buffer_index = 0 };
                attrs[shader.ATTR_sprite_in_inst_pos] = .{ .format = .FLOAT2, .buffer_index = 0 };
                attrs[shader.ATTR_sprite_in_color] = .{ .format = .FLOAT4, .buffer_index = 1 };
                attrs[shader.ATTR_sprite_in_uv] = .{ .format = .FLOAT2, .buffer_index = 1 };
                attrs[shader.ATTR_sprite_in_scale] = .{ .format = .FLOAT2, .buffer_index = 1 };
                break :blk attrs;
            },
        },
        .shader = sprite_shader,
        .index_type = .UINT16,
        .cull_mode = .BACK,
        .depth = .{
            .compare = .ALWAYS,
            .write_enabled = false,
        },
        .label = @as([*:0]u8, "sprite-pipeline"),
    });
    render.pipeline = sprite_pipeline;

    return render;
}

pub fn deinit(render: *Render) void {
    sokol.gfx.shutdown();
    sokol.audio.shutdown();
    render.* = undefined;
}

pub fn update(render: *Render, dt: u64) void {
    const asset_manager = &render.parentState().asset_manager;
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
    const format = "{[{[tag_nonnull]s}:{[filename]s}:{[line_nr]d}]: {[log_item]s}: {[message]s}";
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
