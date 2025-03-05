const builtin = @import("builtin");
const std = @import("std");
const game = @import("game");
const sokol = @import("sokol");
const gfx = sokol.gfx;
const glue = sokol.glue;

const mem = std.mem;

const Allocator = mem.Allocator;

const assert = std.debug.assert;
const panic = std.debug.panic;
const sokol_log = sokol.log.func;

const MainState = struct {
    timer: std.time.Timer,
    game_state: game.State,
    render_state: @import("render.zig").AppState,
};

pub fn main() !void {
    const allocator = Gpa.allocator_instance;
    defer Gpa.deinit();

    _ = allocator;
}

pub const Gpa = struct {
    ctx: Context,
    allocator: Allocator,

    external_allocs: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    external_mutex: std.Thread.Mutex = .{},

    var global: Gpa = if (Gpa.is_debug) blk: {
        const ctx = std.heap.DebugAllocator(.{}){};
        break :blk .{
            .ctx = ctx,
            .allocator = ctx.allocator(),
        };
    } else .{
        .ctx = {},
        .allocator = std.heap.smp_allocator,
    };

    var deinit_once = std.once(Gpa.deinitImpl);

    pub const allocator_instance = Gpa.global.allocator;

    const external_alignment = @divExact(builtin.target.ptrBitWidth(), 4);
    const is_debug = (builtin.mode == .Debug);

    pub const Context = if (Gpa.is_debug) std.heap.DebugAllocator(.{}) else void;

    pub fn deinit() void {
        Gpa.deinit_once.call();
    }
    fn deinitImpl() void {
        Gpa.global.external_mutex.lock();
        defer Gpa.global.external_mutex.unlock();
        if (Gpa.is_debug) {
            assert(Gpa.global.ctx.deinit() == .ok);
        }
        assert(Gpa.global.external_allocs.size == 0);
    }

    pub fn externalAlloc(size: usize) callconv(.c) ?*anyopaque {
        const ptr = Gpa.global.allocator.rawAlloc(size, Gpa.external_alignment, @returnAddress());
        if (ptr) |p| {
            @branchHint(.likely);
            const addr = @intFromPtr(p);
            Gpa.global.external_mutex.lock();
            defer Gpa.global.external_mutex.unlock();
            Gpa.global.external_allocs.putNoClobber(Gpa.global.allocator, addr, size) catch {
                @branchHint(.cold);
                Gpa.global.allocator.rawFree(p[0..size], Gpa.external_alignment, @returnAddress());
                return null;
            };
        }
        return @ptrCast(ptr);
    }
    pub fn externalRealloc(ptr: ?*anyopaque, new_size: usize) callconv(.c) ?*anyopaque {
        if (ptr) |p| {
            @branchHint(.likely);
            const addr = @intFromPtr(p);
            Gpa.global.external_mutex.lock();
            defer global.external_mutex.unlock();
            const size = Gpa.global.external_allocs.get(addr) orelse @panic("unregistered allocation");
            const new_ptr = if (Gpa.global.allocator.rawResize(p[0..size], Gpa.external_alignment, new_size, @returnAddress()))
                ptr
            else blk: {
                const remapped = Gpa.global.allocator.rawAlloc(size, Gpa.external_alignment, new_size, @returnAddress());
                if (remapped) |r| {
                    @branchHint(.likely);
                    const ok = Gpa.global.external_allocs.remove(addr);
                    if (!ok) {
                        @branchHint(.cold);
                        @panic("unreachable but unrecoverable");
                    }
                    const new_addr = @intFromPtr(r);
                    Gpa.global.external_allocs.putNoClobber(Gpa.global.allocator, new_addr, new_size) catch {
                        @branchHint(.cold);
                        Gpa.global.allocator.rawFree(r[0..new_size], Gpa.external_alignment, @returnAddress());
                        return null;
                    };
                    const copy_size = @min(size, new_size);
                    @memcpy(r[0..copy_size], p[0..copy_size]);
                    Gpa.global.allocator.rawFree(p[0..size], Gpa.external_alignment, @returnAddress());
                }
                break :blk remapped;
            };
            return new_ptr;
        } else {
            @branchHint(.unlikely);
            return Gpa.externalAlloc(new_size);
        }
    }
    pub fn externalFree(ptr: ?*anyopaque) callconv(.c) void {
        if (ptr) |p| {
            @branchHint(.likely);
            const addr = @intFromPtr(p);
            Gpa.global.external_mutex.lock();
            defer Gpa.global.external_mutex.unlock();
            const size_entry = Gpa.global.external_allocs.fetchRemove(addr) orelse @panic("unregistered allocation");
            Gpa.global.allocator.rawFree(p[0..size_entry.value], Gpa.external_alignment, @returnAddress());
        }
    }
};

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
