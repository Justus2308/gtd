t: f32,
hp: f32,
speed: f32,
kind: Kind,
extra: Extra,
effects: ?*Effect.Set = null,

const Goon = @This();

pub const t_dead = math.inf(f32);

pub const Kind = enum(u8) {
    normal,
    black,
    white,
    purple,
    lead,
    zebra,
    rainbow,
    ceramic,
    super_ceramic,
    moab,
    bfb,
    zomg,
    ddt,
    bad,
};

pub const Color = enum(u4) {
    none = 0,
    red,
    blue,
    green,
    yellow,
    pink,
};

pub const Extra = packed struct(u8) {
    color: Color,

    camo: bool,
    fortified: bool,
    regrow: bool,

    is_regrown: bool = false,
};

pub const Effect = struct {
    strength: f32,
    time_remaining: f32,
    bytes: u32,

    pub const Kind = enum(u8) {
        fire,
        glue_yellow,
        glue_green,
        glue_purple,
        freeze,
        stun,
        permafrost,
        sabotaged,
        blowback,
        radiated,
        crippled,
        acidic_red,
        acidic_purple,
        grow_blocked,
        partially_gold,
        sticky_bombed,
        trojaned,
        syphoned,
        hexed,
        laser_shocked,
    };

    pub const count = @typeInfo(Effect.Kind).@"enum".fields.len;

    pub const Set = stdx.StructOfArrays(Effect, Effect.count);
    pub const List = std.MultiArrayList(Effect.Set);
};

pub const Immutable = attributes.Immutable;

pub const immutable_earlygame = data.immutable_earlygame;
pub const immutable_lategame = data.immutable_lategame;

pub inline fn getImmutable(immutable_data_ptr: *const Immutable.List, kind: Kind) *const Immutable {
    return &immutable_data_ptr[@intFromEnum(kind)];
}

pub const base_speed_offset_table = data.base_speed_offset_table;

/// Dense fixed-size container for `Goon`s.
/// Linkable into `Block.List`.
pub const Block = struct {
    /// Array of entries. Entries do not have
    /// a persistent identity.
    entries: Entries,
    /// Intrusive node for `Block.List`.
    list_node: List.Node,
    /// Does not change during a frame.
    local_orig: stdx.Immutable(*Block),
    /// Only valid for `local_orig`.
    local_curr: stdx.Immutable(*Block),

    pub const Entries = std.MultiArrayList(Goon);
    pub const List = std.DoublyLinkedList;

    pub const size = (2 << 10);
    pub const alignment = mem.Alignment.max(.of(Block), .of(Goon));

    pub const max_entry_count = count: {
        const bytes_remaining = (size - mem.Alignment.of(Goon).forward(@sizeOf(Block)));
        const bytes_per_entry = Entries.capacityInBytes(1);
        if (bytes_remaining < bytes_per_entry) {
            @compileError("size is too low");
        }
        break :count @divExact(bytes_remaining, bytes_per_entry);
    };

    /// Lifetime of returned pointer is coupled to `buffer`.
    pub fn init(buffer: *align(alignment.toByteUnits()) [size]u8) *Block {
        var fba = heap.FixedBufferAllocator.init(buffer);
        const a = fba.allocator();

        const block = a.create(Block) catch unreachable;

        var entries = Entries.empty;
        entries.setCapacity(a, max_entry_count) catch unreachable;
        assert(fba.end_index == size);

        block.* = .{
            .entries = entries,
            .list_node = .{},
            .local_orig = block,
            .local_curr = block,
        };
        return block;
    }

    fn addLocalBlock(block: *Block, buffer: *align(alignment.toByteUnits()) [size]u8) void {
        const new = Block.init(buffer);
        const orig = block.local_orig.get();
        new.local_orig.do_not_access = orig;
        orig.local_curr.do_not_access = new;
    }

    // if entries always start in sorted state:
    // cannot have stable indices over multiple frames -> need all state locally
    // allows easy compaction -> invalid/dead ids at end of list
    // need alive state locally
    // tracking proj targets need to be recalculated each frame, no persistent tracking
    // sorting needs to happen before data becomes immutable

    pub fn sort(block: *Block) void {
        const sort_ctx: struct {
            t: []f32,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return (ctx.t[a_index] < ctx.t[b_index]);
            }
        } = .{ .t = block.mutable_list.items(.t) };
        block.mutable_list.sortUnstable(sort_ctx);
    }

    pub fn spawn(block: *Block, goon: Goon) void {
        if (block.entries.len < max_entry_count) {
            @branchHint(.likely);
            block.entries.appendAssumeCapacity(goon);
        } else {
            @branchHint(.unlikely);
        }
    }
};

const std = @import("std");
const game = @import("game");
const stdx = @import("stdx");

const attributes = @import("Goon/attributes.zig");
const data = @import("Goon/data.zig");

const heap = std.heap;
const math = std.math;
const mem = std.mem;

const Allocator = mem.Allocator;

const assert = std.debug.assert;
