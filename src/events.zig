const std = @import("std");
const sokol = @import("sokol");

const SokolEvent = sokol.app.Event;

pub const Event = union(enum) {
    input: Input,

    pub const Input = enum {
        up,
        down,
        left,
        right,
        action,
        pause,
        stop,
    };
};

pub inline fn handleKeyboardEvent(sokol_event: SokolEvent) void {
    const key = sokol_event.key_code;
    const event: Event = switch (sokol_event.type) {
        .KEY_DOWN => .stop,
        .KEY_UP => switch (key) {
            .W, .UP => .up,
            .A, .LEFT => .left,
            .S, .DOWN => .down,
            .D, .RIGHT => .right,
            .SPACE => .action,
            .ESCAPE => .pause,
            .INVALID => unreachable,
            else => return,
        },
    };
    _ = event;
}

pub inline fn handleMouseEvent(sokol_event: SokolEvent) void {
    _ = sokol_event;
}

pub inline fn handleTouchEvent(sokol_event: SokolEvent) void {
    _ = sokol_event;
}

pub inline fn handleProcEvent(sokol_event: SokolEvent) void {
    _ = sokol_event;
}

pub inline fn handleWindowEvent(sokol_event: SokolEvent) void {
    _ = sokol_event;
}

pub inline fn handleDataInputEvent(sokol_event: SokolEvent) void {
    _ = sokol_event;
}
