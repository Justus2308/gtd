const std = @import("std");
const geo = @import("geo");
const sokol = @import("sokol");
const gfx = sokol.gfx;

const v2f32 = geo.points.v2f32;
const v4f32 = geo.points.v4f32;

const sokol_log = sokol.log.func;

pub const max_quad_count = 8 * 1024;
pub const max_vert_count = 4 * max_quad_count;

var app_state = AppState{};

const AppState = struct {
    pass_action: gfx.PassAction = .{},
    pipeline: gfx.Pipeline = .{},
    bindings: gfx.Bindings = .{},
};

pub fn runApp(window_title: [:0]const u8, window_width: i32, window_height: i32) void {
    sokol.app.run(.{
        .init_cb = init,
        .cleanup_cb = cleanup,
        .frame_cb = frame,
        .width = window_width,
        .height = window_height,
        .window_title = window_title,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol_log },
    });
}

fn init() callconv(.c) void {
    gfx.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol_log },
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
        .data = .{ .ptr = &indices, .size = indices.len },
    });

    app_state.bindings.samplers[0] = gfx.makeSampler(.{});

    var pieline_desc = gfx.PipelineDesc{ .shader = gfx.makeShader() };
}

fn cleanup() callconv(.c) void {
    gfx.shutdown();
}

fn frame() callconv(.c) void {}
