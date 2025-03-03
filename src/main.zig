const std = @import("std");
const sokol = @import("sokol");
const gfx = sokol.gfx;
const glue = sokol.glue;

const mem = std.mem;

const Allocator = mem.Allocator;

const panic = std.debug.panic;
const sokol_log = sokol.log.func;

pub fn main() !void {
    var gpa = generalPurposeAllocator();
    const allocator = gpa.allocator;
}

pub const Gpa = struct {
    ctx: Context,
    allocator: Allocator,

    pub const Context = if (std.debug.runtime_safety) std.heap.DebugAllocator(.{}) else void;
};
pub fn generalPurposeAllocator() Gpa {
    const gpa: Gpa = if (std.debug.runtime_safety) blk: {
        const ctx = std.heap.DebugAllocator(.{}){};
        break :blk .{
            .ctx = ctx,
            .allocator = ctx.allocator(),
        };
    } else .{
        .ctx = {},
        .allocator = std.heap.smp_allocator,
    };
    return gpa;
}

// pub fn mainSDL() !void {
//     // Init SDL
//     if (!(c.SDL_SetHintWithPriority(
//         c.SDL_HINT_NO_SIGNAL_HANDLERS,
//         "1",
//         c.SDL_HINT_OVERRIDE,
//     ) != c.SDL_FALSE)) {
//         panic("failed to disable sdl signal handlers\n", .{});
//     }
//     if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMECONTROLLER) != 0) {
//         panic("SDL_Init failed: {s}\n", .{ c.SDL_GetError() });
//     }
//     defer c.SDL_Quit();

//     const window = c.SDL_CreateWindow(
//         "Goons TD",
//         c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED,
//         680, 480,
//         c.SDL_WINDOW_FULLSCREEN_DESKTOP,
//     ) orelse return error.WindowCreationFailed;
//     defer c.SDL_DestroyWindow(window);

//     const renderer_flags: u32 = c.SDL_RENDERER_PRESENTVSYNC;
//     const renderer: *c.SDL_Renderer = c.SDL_CreateRenderer(window, -1, renderer_flags) orelse {
//         panic("SDL_CreateRenderer failed: {s}\n", .{ c.SDL_GetError() });
//     };
//     defer c.SDL_DestroyRenderer(renderer);
// }

// pub fn mainRaylib() !void {
//     raylib.setConfigFlags(.{
//         .borderless_windowed_mode = true,
//         // .fullscreen_mode = true,
//         .window_resizable = true,
//         .window_highdpi = true,
//     });

//     const monitor = raylib.getCurrentMonitor();
//     const refresh_rate = raylib.getMonitorRefreshRate(monitor);

//     const monitor_width = raylib.getMonitorWidth(monitor);
//     const monitor_height = raylib.getMonitorHeight(monitor);

//     raylib.initWindow(monitor_width, monitor_height, "Goons TD");
//     defer raylib.closeWindow();

//     raylib.setExitKey(.key_null);
//     raylib.setTargetFPS(refresh_rate);
//     raylib.setWindowMonitor(monitor);
//     raylib.setWindowFocused();

//     while (!raylib.windowShouldClose()) {
//         if (raylib.isWindowResized()) {
//             // const window_scaling = raylib.getWindowScaleDPI();

//         }

//         raylib.beginDrawing();

//         // --- tmp ---
//         raylib.clearBackground(raylib.Color.ray_white);

//         const scaling = raylib.getWindowScaleDPI();
//         const fps = raylib.getFPS();
//         var buf: [256]u8 = undefined;
//         const dims = try std.fmt.bufPrintZ(&buf, "resolution: {d}x{d} | scaling: {d}x{d} | fps: {d}", .{
//             raylib.getMonitorWidth(monitor), raylib.getMonitorHeight(monitor),
//             scaling.x, scaling.y,
//             fps,
//         });
//         raylib.drawText(dims, 0, 0, 40, raylib.Color.light_gray);
//         // --- tmp ---

//         raylib.endDrawing();
//     }
// }
