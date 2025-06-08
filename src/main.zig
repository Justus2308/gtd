const builtin = @import("builtin");
const std = @import("std");
const stdx = @import("stdx");
const game = @import("game");
const render = @import("render");
const resource = @import("resource");
const sokol = @import("sokol");

const mem = std.mem;
const audio = sokol.audio;
const gfx = sokol.gfx;

const Allocator = mem.Allocator;

const assert = std.debug.assert;
const panic = std.debug.panic;

const window_width = 1280;
const window_height = 720;
const window_title = "Goons TD";

var sokol_state: struct {
    /// sokol_gfx can only be used from the main thread,
    /// so we need to collect all loads/unloads requested
    /// by other threads in MPSC queues here.
    load_queue: stdx.concurrent.MpscQueue = undefined,
    unload_queue: stdx.concurrent.MpscQueue = undefined,
} = .{};
comptime {
    sokol_state.load_queue.initInstance();
    sokol_state.unload_queue.initInstance();
}

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
    const state = try game.State.preinit();
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
        .logger = .{ .func = &render.Sokol.sokolLog },
        .win32_console_utf8 = true,
        .win32_console_attach = true,
        .html5_ask_leave_site = true,
        .user_data = state,
    };
}

pub fn init(userdata: ?*anyopaque) callconv(.c) void {
    stdx.ScratchAllocator.init(std.heap.c_allocator);

    const state: *game.State = @alignCast(@ptrCast(userdata));
    state.init() catch @panic("OOM");

    const asset_pack = loadAssetPack() catch |err| switch (err) {
        .FileNotFound => &.{},
        else => stdx.fatal(
            .fs,
            "failed to load asset pack (assets.midaspack): {s}",
            .{@errorName(err)},
        ),
    };
}

pub fn cleanup(userdata: ?*anyopaque) callconv(.c) void {
    const state: *game.State = @alignCast(@ptrCast(userdata));
    state.deinit();

    stdx.ScratchAllocator.deinit();
}

pub fn frame(userdata: ?*anyopaque) callconv(.c) void {
    const state: *game.State = @alignCast(@ptrCast(userdata));

    // Process one sokol load/unload node on this thread.
    // Only one per frame to prevent/reduce stuttering.
    if (sokol_state.load_queue.pop()) |node| {
        const queueable: *resource.Loader.Queueable = @fieldParentPtr("node", node);
    } else if (sokol_state.unload_queue.pop()) |node| {
        const queueable: *resource.Loader.Queueable = @fieldParentPtr("node", node);
    }

    const dt = sokol.app.frameDuration();
    state.update(dt) catch {};

    stdx.ScratchAllocator.reset();
}

pub fn event(event_: ?*const sokol.app.Event, userdata: ?*anyopaque) callconv(.c) void {
    const state: *game.State = @alignCast(@ptrCast(userdata));
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

fn loadAssetPack() (std.fs.File.OpenError || stdx.MapFileToMemoryError)![]const u8 {
    const asset_pack_path = "assets/assets.midaspack";

    const mapped = mapped: {
        const file = try std.fs.cwd().openFile(asset_pack_path, .{
            .mode = .read_only,
            .lock = .exclusive,
        });
        defer file.close();

        // TODO read file header here

        const mapped = try stdx.mapFileToMemory(file);
        break :mapped mapped;
    };
    errdefer stdx.unmapFileFromMemory(mapped);

    // TODO verify file type + correctness, extract registry

    return mapped;
}

fn unloadAssetPack(memory: []const u8) void {
    stdx.unmapFileFromMemory(memory);
}
