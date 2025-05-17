kind: Kind,
x: f32,
y: f32,
accel_x: Acceleration,
accel_y: Acceleration,
damage: f32,
pierce: u32,
lifetime: f32,

const Projectile = @This();

pub const Kind = enum(u8) {};
pub const Acceleration = union {
    none: void,
    seeking: Seeking,
    straight: f32,

    pub const Seeking = enum {
        weak,
        moderate,
        aggressive,
        instant,
    };

    pub const Kind = enum(u4) {
        none,
        straight,
        seeking_weak,
        seeking_moderate,
        seeking_aggressive,
        seeking_instant,
    };
};

pub const Block = struct {
    entries: Entries,
    avail_set: EntrySet,
    in_segment: [local_segment_count]EntrySet,
    segment_borders: [local_segment_count]f32,
    list_node: List.Node,

    /// TODO link with actual segments
    const segment_count = 1024;
    const local_segment_count = 128;

    pub const Entries = std.MultiArrayList(Projectile);
    pub const EntrySet = std.StaticBitSet(max_entry_count);
    pub const List = std.DoublyLinkedList;

    pub const size = (8 << 10);
    pub const alignment = mem.Alignment.max(.of(Block), .of(Projectile));

    pub const max_entry_count = count: {
        const bytes_remaining = (size - mem.Alignment.of(Projectile).forward(@sizeOf(Block)));
        const bytes_per_entry = Entries.capacityInBytes(1);
        if (bytes_remaining < bytes_per_entry) {
            @compileError("size is too low");
        }
        break :count @divExact(bytes_remaining, bytes_per_entry);
    };

    /// Lifetime of returned pointer is coupled to `buffer`.
    pub fn create(buffer: *align(alignment.toByteUnits()) [size]u8) *Block {
        var fba = std.heap.FixedBufferAllocator.init(buffer);
        const a = fba.allocator();

        const block = a.create(Block) catch unreachable;

        var entries = Entries.empty;
        entries.setCapacity(a, max_entry_count) catch unreachable;
        assert(fba.end_index == size);
        entries.len = max_entry_count;

        block.* = .{
            .entries = entries,
            .avail_set = .initFull(),
            .in_segment = @splat(.initEmpty()),
            .segment_borders = undefined, // TODO replace with iota(128, max_t)
            .list_node = .{},
        };
        return block;
    }

    pub fn clear(block: *Block) void {
        block.avail_set.setAll();
        for (&block.in_segment) |set| {
            set.unsetAll();
        }
        // TODO reset segment borders to default
        block.segment_borders = undefined;
    }

    fn calculateLocalSegments(
        noalias block: *Block,
        noalias old: *const Block,
        global_segments: *const Segment.Map,
    ) void {
        var counters: [Block.local_segment_count]u32 = undefined;
        var indices: [Block.local_segment_count]u16 = undefined;

        const SortCtx = struct {
            counters: *[Block.local_segment_count]u32,
            indices: *[Block.local_segment_count]u16,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return (ctx.counters[a] < ctx.counters[b]);
            }

            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                mem.swap(u32, &ctx.counters[a], &ctx.counters[b]);
                mem.swap(u16, &ctx.indices[a], &ctx.indices[b]);
            }
        };
        std.sort.pdqContext(0, Block.local_segment_count, SortCtx{
            .counters = &counters,
            .indices = &indices,
        });

        const old_slice = old.entries.slice();
        for (old_slice.items(.x), old_slice.items(.y)) |x, y| {
            if (global_segments.get(x, y))
        }
    }
};

const std = @import("std");
const game = @import("game");
const mem = std.mem;
const Segment = game.Segment;
const assert = std.debug.assert;
