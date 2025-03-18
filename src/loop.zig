const std = @import("std");
const sokol = @import("sokol");
const audio = sokol.audio;
const gfx = sokol.gfx;

pub fn init(userdata: ?*anyopaque) callconv(.c) void {
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

pub fn cleanup(userdata: ?*anyopaque) callconv(.c) void {
    gfx.shutdown();
    audio.shutdown();
    global.deinit();
}

pub fn frame(userdata: ?*anyopaque) callconv(.c) void {
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

pub fn event(event_: *const sokol.app.Event, userdata: ?*anyopaque) callconv(.c) void {
    switch (event_.type) {
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
