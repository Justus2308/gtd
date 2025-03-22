const builtin = @import("builtin");
const std = @import("std");
const sokol = @import("sokol");

const mem = std.mem;
const audio = sokol.audio;
const gfx = sokol.gfx;

const Allocator = mem.Allocator;
const State = @import("State");

const assert = std.debug.assert;
const panic = std.debug.panic;

const window_width = 1280;
const window_height = 720;
const window_title = "GTD";

pub fn main() !void {
    const desc = makeSokolDesc() catch @panic("OOM");
    sokol.app.run(desc);
}

// TODO: For android builds
comptime {
    if (builtin.target.abi.isAndroid()) {
        @export(&sokolMain, .{ .name = "sokol_main", .linkage = .strong });
    }
}
fn sokolMain(argc: c_int, argv: [*][*]c_char) callconv(.c) sokol.app.Desc {
    _ = .{ argc, argv };
    const desc = makeSokolDesc() catch @panic("OOM");
    return desc;
}

fn makeSokolDesc() Allocator.Error!sokol.app.Desc {
    const state = try State.preinit();
    return sokol.app.Desc{
        .init_userdata_cb = &init,
        .cleanup_userdata_cb = &cleanup,
        .frame_userdata_cb = &frame,
        .event_userdata_cb = &event,
        .width = window_width,
        .height = window_height,
        .fullscreen = true,
        .window_title = window_title,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = &State.Render.sokolLog },
        .win32_console_utf8 = true,
        .win32_console_attach = true,
        .user_data = state,
    };
}

pub fn init(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(userdata);
    state.init() catch @panic("OOM");
}

pub fn cleanup(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(userdata);
    state.deinit();
}

pub fn frame(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(userdata);
    const dt = sokol.app.frameDuration();
    state.update(dt);
}

pub fn event(event_: *const sokol.app.Event, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(userdata);
    _ = .{ state, event_ };
    // switch (event_.type) {
    //     .KEY_DOWN, .KEY_UP => events.handleKeyboardEvent(event.*),
    //     .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE, .MOUSE_SCROLL, .MOUSE_ENTER, .MOUSE_LEAVE => events.handleMouseEvent(event.*),
    //     .TOUCHES_BEGAN, .TOUCHES_ENDED, .TOUCHES_MOVED, .TOUCHES_CANCELLED => events.handleTouchEvent(event.*),
    //     .SUSPENDED, .RESUMED, .RESTORED, .QUIT_REQUESTED => events.handleProcEvent(event.*),
    //     .RESIZED, .FOCUSED, .UNFOCUSED => events.handleWindowEvent(event.*),
    //     .CHAR, .NUM, .CLIPBOARD_PASTED => events.handleDataInputEvent(event.*),
    //     .ICONIFIED, .FILES_DROPPED => {},

    //     .INVALID => event_log.info("encountered invalid event", .{}),
    // }
}

// TODO move
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
