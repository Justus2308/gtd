//! Interface to load data into sokol resources.
//! Implementations are explicitly NOT required to be thread-safe.

// -----------------------------------------------------------------------------------
// PLAN:
//
// START OF ROUND:
// * alloc all handles mentioned in round manifest from main thread
// * do this through registry (generate handle if not already registered)
// * register all handles in resource manager as 'unloaded' cell
// * if handle is already in manager: increment ref count
//
// DURING ROUND:
// * dispatch handle (un)inits from mt tasks when needed, collect them in mpsc queue
// * this sets cell to 'loading'/'unloading'
// * dispatched init loads resource from disk if necessary + decompresses it
// * poll for one init/uninit in frame callback after dispatching tasks
// * init in main thread calls sokol init*() and sets cell to 'loaded'/'unloaded'
//
// AFTER ROUND:
// * decrement ref count for all handles mentioned in round manifest
// * perform cleanup sweep to unload all handles with 0 refs
//
// => THREE STEP LOAD API:
// * createHandle() - from main thread, 'optimistic' usage
// * prepare() - async
// * load() - from main thread (pipeline/sampler creation happens here)
//
// => TWO STEP UNLOAD API:
// * unload() - from main thread
// * destroyHandle() - from main thread, only called at cleanup time
//
// TODO:
// |_| rework Loader API to match new requirements
// |_| rewrite Manager.Cell to support new API
// |_| adapt Manager API to new Loader API
// |_| implement/refine Registry API
// |_| implement Texture + .loader()
// |_| implement Model + .loader()
// |_| think of solution for pipelines + samplers
// -----------------------------------------------------------------------------------

ptr: *anyopaque,
vtable: *const VTable,

const Loader = @This();

/// TODO refine
pub const Error = (Allocator.Error || error{ AccessDenied, FileNotFound, Unexpected });

pub const VTable = struct {
    kind: *const fn (*anyopaque) Handle.Kind,
    load: *const fn (*anyopaque, allocator: Allocator, handle: Handle, context: Context) anyerror!void,
    unload: *const fn (*anyopaque, allocator: Allocator, handle: Handle) void,
    queueLoad: *const fn (*anyopaque, allocator: Allocator, handle: Handle) Queueable,
    queueUnload: *const fn (*anyopaque, allocator: Allocator, handle: Handle) Queueable,
};

pub const Context = struct {
    asset_dir: std.fs.Dir,
    scratch_arena: Allocator,
};

/// Each combination of tag/payload is unique.
pub const Handle = union(enum) {
    texture: sokol.gfx.Image,
    buffer: sokol.gfx.Buffer,
    pipeline: sokol.gfx.Pipeline,
    sampler: sokol.gfx.Sampler,

    pub const Kind = std.meta.Tag(Handle);

    pub fn create(kind: Handle.Kind) Allocator.Error!Handle {
        const handle: Handle = switch (kind) {
            .texture => .{ .texture = sokol.gfx.allocImage() },
            .buffer => .{ .buffer = sokol.gfx.allocBuffer() },
            .pipeline => .{ .pipeline = sokol.gfx.allocPipeline() },
            .sampler => .{ .sampler = sokol.gfx.allocSampler() },
        };
        return switch (handle.queryState()) {
            .ALLOC => handle,
            .INVALID => error.OutOfMemory,
            else => unreachable,
        };
    }

    pub fn destroy(handle: Handle) void {
        if (handle.isInitialized()) {
            log.warn(
                "destroyed '{s}' handle without unloading first",
                .{@tagName(handle)},
            );
        }
        switch (handle) {
            .texture => |payload| sokol.gfx.destroyImage(payload),
            .buffer => |payload| sokol.gfx.destroyBuffer(payload),
            .pipeline => |payload| sokol.gfx.destroyPipeline(payload),
            .sampler => |payload| sokol.gfx.destroySampler(payload),
        }
    }

    /// Asserts that `handle` has been properly allocated.
    pub fn isInitialized(handle: Handle) bool {
        return switch (handle.queryState()) {
            .VALID => true,
            .ALLOC, .FAILED => false,
            .INITIAL, .INVALID => unreachable,
        };
    }

    inline fn queryState(handle: Handle) sokol.gfx.ResourceState {
        const state = switch (handle) {
            .texture => |payload| sokol.gfx.queryImageState(payload),
            .buffer => |payload| sokol.gfx.queryBufferState(payload),
            .pipeline => |payload| sokol.gfx.queryPipelineState(payload),
            .sampler => |payload| sokol.gfx.querySamplerState(payload),
        };
        return state;
    }
};

pub const Queueable = struct {
    loader: Loader,
    allocator: Allocator,
    handle: Handle,
    node: stdx.concurrent.MpscQueue.Node,

    pub fn fromNode(node: *stdx.concurrent.MpscQueue.Node) *Queueable {
        return @fieldParentPtr("node", node);
    }

    pub fn enqueue(queueable: *Queueable, queue: *stdx.concurrent.MpscQueue) void {
        queue.push(&queueable.node);
    }
};

pub inline fn rawKind(loader: Loader) Handle.Kind {
    return loader.vtable.kind(loader.ptr);
}

pub inline fn rawLoad(loader: Loader, allocator: Allocator, handle: Handle, context: Context) !void {
    return loader.vtable.load(loader.ptr, allocator, handle, context);
}

pub inline fn rawUnload(loader: Loader, allocator: Allocator, handle: Handle) void {
    return loader.vtable.unload(loader.ptr, allocator, handle);
}

pub inline fn rawQueueLoad(loader: Loader, allocator: Allocator, handle: Handle) *stdx.concurrent.MpscQueue.Node {
    return loader.vtable.queueLoad(loader.ptr, allocator, handle);
}

pub inline fn rawQueueUnload(loader: Loader, allocator: Allocator, handle: Handle) *stdx.concurrent.MpscQueue.Node {
    return loader.vtable.queueLoad(loader.ptr, allocator, handle);
}

pub fn createHandle(loader: Loader) Allocator.Error!Handle {
    const kind = loader.rawKind();
    const handle = try Handle.create(kind);
    return handle;
}

pub fn load(loader: Loader, allocator: Allocator, handle: Handle, context: Context) Error!void {
    loader.rawLoad(allocator, handle, context) catch |err| switch (err) {
        Error.OutOfMemory, Error.AccessDenied, Error.FileNotFound, Error.Unexpected => return @errorCast(err),
        else => {
            log.err("failed to load resource: unexpected error: {s}", .{@errorName(err)});
            return Error.Unexpected;
        },
    };
}

pub fn unload(loader: Loader, allocator: Allocator, handle: Handle) void {
    assert(loader.rawKind() == std.meta.activeTag(handle));
    return loader.rawUnload(allocator, handle);
}

pub fn loadFull(loader: Loader, allocator: Allocator, context: Context) Error!Handle {
    const handle = try loader.createHandle();
    errdefer handle.destroy();
    try loader.load(allocator, handle, context);
    return handle;
}

/// Invalidates `handle`.
pub fn unloadFull(loader: Loader, allocator: Allocator, handle: Handle) void {
    loader.unload(allocator, handle);
    return handle.destroy();
}

pub fn loadDeferred(
    loader: Loader,
    allocator: Allocator,
    handle: Handle,
    queue: *stdx.concurrent.MpscQueue,
) void {
    const node = loader.rawQueueLoad(allocator, handle);
    queue.push(node);
}

pub fn unloadDeferred(
    loader: Loader,
    allocator: Allocator,
    handle: Handle,
    queue: *stdx.concurrent.MpscQueue,
) void {
    const node = loader.rawQueueUnload(allocator, handle);
    queue.push(node);
}

const std = @import("std");
const stdx = @import("stdx");
const sokol = @import("sokol");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Manager = @import("Manager.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.resource_loader);
