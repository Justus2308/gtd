const builtin = @import("builtin");
const std = @import("std");
const game = @import("game");
const geo = @import("geo");
const events = @import("events.zig");
const global = @import("global");
const shader = @import("shader");
const sokol = @import("sokol");

const mem = std.mem;
const audio = sokol.audio;
const gfx = sokol.gfx;

const v2f32 = geo.linalg.v2f32;
const v4f32 = geo.linalg.v4f32;
const m4f32 = geo.linalg.m4f32;

const Allocator = mem.Allocator;

const assert = std.debug.assert;
const panic = std.debug.panic;

const window_width = 1280;
const window_height = 720;
const window_title = "GTD";

const sokol_app_desc = sokol.app.Desc{
    .init_cb = &sokolInit,
    .cleanup_cb = &sokolCleanup,
    .frame_cb = &sokolFrame,
    .event_cb = &sokolEvent,
    .width = window_width,
    .height = window_height,
    .fullscreen = true,
    .window_title = window_title,
    .icon = .{ .sokol_default = true },
    .logger = .{ .func = &sokolLog },
    .win32_console_utf8 = true,
    .win32_console_attach = true,
};

pub fn main() !void {
    sokol.app.run(sokol_app_desc);
}

// TODO: For android builds
comptime {
    if (builtin.target.abi.isAndroid()) {
        @export(&sokolMain, .{ .name = "sokol_main", .linkage = .strong });
    }
}
fn sokolMain(argc: c_int, argv: [*][*]c_char) callconv(.c) sokol.app.Desc {
    _ = .{ argc, argv };
    return sokol_app_desc;
}

export fn sokolLog(
    tag: [*:0]const u8,
    log_level: u32,
    log_item_id: u32,
    message_or_null: ?[*:0]const u8,
    line_nr: u32,
    filename_or_null: ?[*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = user_data;
    const message = message_or_null orelse "No message provided";
    const filename = filename_or_null orelse "?";
    const log_item_enum_tag: ?sokol.app.LogItem = std.meta.intToEnum(sokol.app.LogItem, log_item_id) catch null;
    const log_item = if (log_item_enum_tag) @tagName(log_item_enum_tag) ++ ": " else "";
    const format = "{[{[tag]s}:{[filename]s}:{[line_nr]d}]: {[log_item]s}{[message]s}";
    const args = .{ tag, filename, line_nr, log_item, message };
    const sokol_log = std.log.scoped(.sokol);
    switch (log_level) {
        0...1 => sokol_log.err(format, args),
        2 => sokol_log.warn(format, args),
        3 => sokol_log.info(format, args),
    }
}

export fn sokolInit() callconv(.c) void {
    gfx.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = &sokolLog },
    });
    audio.setup(.{ .logger = .{ .func = &sokolLog } });

    global.render_state.bindings.vertex_buffers[0] = gfx.makeBuffer(.{
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
    global.render_state.bindings.index_buffer = gfx.makeBuffer(.{
        .type = .INDEXBUFFER,
        .data = .{ .ptr = &indices, .size = @sizeOf(indices) },
    });

    global.render_state.bindings.samplers[shader.SMP_default_sampler] = gfx.makeSampler(.{});

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

    global.render_state.pipeline = gfx.makePipeline(.{
        .shader = gfx.makeShader(shader.quadShaderDesc(gfx.queryBackend())),
        .index_type = .UINT16,
        .layout = .{ .attrs = pipe_layout_attrs },
        .colors = pipe_colors,
    });

    var pass_act_colors: @FieldType(gfx.PassAction, "colors") = @splat(.{});
    pass_act_colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } };

    global.render_state.pass_action = .{
        .colors = pass_act_colors,
    };
}

export fn sokolCleanup() callconv(.c) void {
    gfx.shutdown();
    audio.shutdown();
    global.deinit();
}

export fn sokolFrame() callconv(.c) void {
    const frame_time: f32 = @floatCast(sokol.app.frameDuration());

    @memset(@as([]u8, @ptrCast(&draw_frame)), 0);

    global.render_state.bindings.images[0] = .{}; // TODO

    gfx.updateBuffer(global.render_state.bindings.vertex_buffers[0], .{
        .ptr = &draw_frame.quads,
        .size = (@sizeOf(Quad) * draw_frame.quads.len),
    });
    gfx.beginPass(.{
        .action = global.render_state.pass_action,
        .swapchain = sokol.glue.swapchain(),
    });
    gfx.applyPipeline(global.render_state.pipeline);
    gfx.applyBindings(global.render_state.bindings);
    gfx.draw(0, (6 * draw_frame.quad_count), 1);
    gfx.endPass();
    gfx.commit();
}

export fn sokolEvent(event: *const sokol.app.Event) callconv(.c) void {
    switch (event.type) {
        .KEY_DOWN, .KEY_UP => events.handleKeyboardEvent(event.*),
        .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE, .MOUSE_SCROLL, .MOUSE_ENTER, .MOUSE_LEAVE => events.handleMouseEvent(event.*),
        .TOUCHES_BEGAN, .TOUCHES_ENDED, .TOUCHES_MOVED, .TOUCHES_CANCELLED => events.handleTouchEvent(event.*),
        .SUSPENDED, .RESUMED, .RESTORED, .QUIT_REQUESTED => events.handleProcEvent(event.*),
        .RESIZED, .FOCUSED, .UNFOCUSED => events.handleWindowEvent(event.*),
        .CHAR, .NUM, .CLIPBOARD_PASTED => events.handleDataInputEvent(event.*),
        .ICONIFIED, .FILES_DROPPED => {},

        .INVALID => event_log.info("encountered invalid event", .{}),
    }
}

const event_log = std.log.scoped(.event);

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

pub const palette = struct {
    const data = std.enums.directEnumArray(Name, gfx.Color, 0, .{
        .white = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .black = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    });
    pub const Name = enum(usize) {
        white = 0,
        black,
    };

    pub inline fn get(comptime name: palette.Name) gfx.Color {
        comptime return palette.data[@intFromEnum(name)];
    }
};
