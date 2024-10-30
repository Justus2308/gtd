//! Results until now: slower for tiny objects, faster for >medium objects if preheated, way slower if not.
//! TODO test more realistic scenarios (memory fragmentation/compaction, resets...)

const std = @import("std");
const stdx = @import("stdx");

const Allocator = std.mem.Allocator;
const Timer = std.time.Timer;

const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const StdMemoryPool = std.heap.MemoryPoolExtra;
const MyMemoryPool = stdx.MemoryPoolAligned;


const Tiny = struct {
    data: [1]u8,

    pub const rounds = 2_500_000;
};
const Small = struct {
    data: [1024]u8,

    pub const rounds = 2_000_000;
};
const Medium = struct {
    data: [8*1024]u8,

    pub const rounds = 1_000_000;
};
const Large = struct {
    data: [1024*1024]u8,

    pub const rounds = 25_000;
};

const Result = struct {
    time: u64,
    create_count: u64,
    destroy_count: u64,
    max_consecutive_obj_count: usize,

    pub fn print(result: Result) void {
        const fmt_str = "time: {d}µs\ncreated {d} objects\ndestroyed {d} objects\nat most {d} objects\n";
        std.debug.print(fmt_str, .{
            result.time,
            result.create_count,
            result.destroy_count,
            result.max_consecutive_obj_count,
        });
    }
};
fn benchmark(
    comptime T: type,
    allocator: anytype,
    seed: u64,
) Allocator.Error!Result {
    const page = try std.heap.page_allocator.alignedAlloc(u8, std.mem.page_size, std.mem.page_size);
    defer std.heap.page_allocator.free(page);

    var buf_allocator = std.heap.FixedBufferAllocator.init(page);
    var buf_arena = std.heap.ArenaAllocator.init(buf_allocator.allocator());

    var open = try std.ArrayList(*anyopaque).initCapacity(buf_arena.allocator(), 256);
    var random_ctx = std.Random.DefaultPrng.init(seed);
    var random = random_ctx.random();

    var create_count: u64 = 0;
    var destroy_count: u64 = 0;
    var max_consecutive_obj_count: usize = 0;

    var time: u64 = 0;
    var timer = Timer.start() catch unreachable;

    for (0..T.rounds) |_| {
        const len_fp: f64 = @floatFromInt(open.items.len);
        const fill_rate: f64 = len_fp / 256.0;
        if (random.float(f64) <= fill_rate) {
            const idx: usize = @intFromFloat(random.float(f64) * len_fp);
            const ptr = open.orderedRemove(idx);

            timer.reset();
            allocator.destroy(@ptrCast(@alignCast(ptr)));
            time += (timer.read() / 1000);

            destroy_count += 1;
        }
        if (random.float(f64) >= fill_rate) {
            timer.reset();
            const ptr = try allocator.create();
            time += (timer.read() / 1000);

            try open.append(@ptrCast(ptr));
            create_count += 1;
        }
        max_consecutive_obj_count = @max(open.items.len, max_consecutive_obj_count);
    }

    return Result{
        .time = time,
        .create_count = create_count,
        .destroy_count = destroy_count,
        .max_consecutive_obj_count = max_consecutive_obj_count,
    };
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    var args = std.process.args();
    std.debug.assert(args.skip());
    const seed: u64 = if (args.next()) |str|
        try std.fmt.parseInt(u64, str, 0)
    else
        0x12c897aff78d713e;


    inline for (&[_]type{ Tiny, Small, Medium, Large }) |T| {
        std.debug.print("\n{s}:\n", .{ @typeName(T) });

        const StdPool = StdMemoryPool(T, .{});
        const MyPool = MyMemoryPool(T, null);

        for (&[_]usize{ 0, 64, 256 }) |preheat| {
            var std_pool = try StdPool.initPreheated(gpa, preheat);
            defer std_pool.deinit();
            std.debug.print("std MemoryPool (preheat={d}):\n", .{ preheat });
            var std_res = try benchmark(T, &std_pool, seed);
            std_res.print();

            var my_pool = try MyPool.initPreheated(gpa, preheat);
            defer my_pool.deinit();
            std.debug.print("my MemoryPool (preheat={d}):\n", .{ preheat });
            var my_res = try benchmark(T, &my_pool, seed);
            my_res.print();

            std.debug.print("\n", .{});
        }
    }
}
