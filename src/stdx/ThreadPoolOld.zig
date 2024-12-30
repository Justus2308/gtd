const std = @import("std");

const mem = std.mem;

const Allocator = mem.Allocator;
const Atomic = std.atomic.Value;
const Thread = std.Thread;

const assert = std.debug.assert;

const cache_line = std.atomic.cache_line;


sync: Sync align(cache_line),

allocator: Allocator,
threads: []Thread,


const ThreadPool = @This();


pub const Options = struct {
    thread_count: ?usize = null,
};
pub fn init(allocator: Allocator, options: Options) Allocator.Error!ThreadPool {
    const thread_count = options.thread_count orelse std.Thread.getCpuCount() catch 1;
    return ThreadPool{
        .sync = Sync.none,
        .allocator = allocator,
        .threads = try allocator.alloc(Thread, thread_count),
    };
}

pub const Task = struct {
    next: ?*Task,
    callback: *const fn (task: *Task) void,
};

/// This is aligned and padded to a cache line
/// as it will be invalidated very frequently.
const Sync = extern struct {
    state: Atomic(State) align(cache_line),
    _1: [cache_line -| @sizeOf(State)]u8,

    pub const State = packed struct(u32) {
        counter: u16,
        counting: Counting,

        pub const Counting = enum(u16) {
            none = 0,
        };
    };

    pub const none = Sync{
        .state = Atomic(State).init(.{
            .counter = 0,
            .counting = .none,
        }),
        ._1 = undefined,
    };

    comptime {
        assert(@sizeOf(Sync) % cache_line == 0);
    }
};
