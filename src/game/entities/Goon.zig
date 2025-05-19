t: f32,
hp: f32,
speed: f32,
kind: Kind,
extra: Extra,
effect_index: Effect.List.Index = .none,
active_effects: Effect.Active = .initEmpty(),

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
    bytes: Effect.Bytes,

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

    pub const Bytes = extern union {
        fire: extern struct {
            application_rate: ApplicationRate,
        },
        glue_yellow: extern struct {
            is_strong: bool,
            is_corrosive: bool,
            corrosive_application_rate: ApplicationRate,
        },
        glue_green: extern struct {
            is_strong: bool,
            application_rate: ApplicationRate,
        },
        glue_purple: extern struct {
            is_corrosive: bool,
            corrosive_application_rate: ApplicationRate,
            damage: f16,
        },
        freeze: void,
        stun: void,
        permafrost: void,
        sabotaged: void,
        blowback: void,
        radiated: void,
        crippled: void,
        acidic_red: void,
        acidic_purple: void,
        grow_blocked: void,
        partially_gold: void,
        sticky_bombed: void,
        trojaned: void,
        syphoned: void,
        hexed: void,
        laser_shocked: void,

        comptime {
            if (@sizeOf(Effect.Bytes) != 4) {
                @compileError("Bytes needs to have size 4");
            }

            // Perform the same checks the compiler would for a tagged union
            const enum_fields = @typeInfo(Effect.Kind).@"enum".fields;
            const union_fields = @typeInfo(Effect.Bytes).@"union".fields;
            if (union_fields.len > enum_fields.len) {
                @compileError("Bytes has too many fields, should only have exactly one for each Kind");
            }
            @setEvalBranchQuota(enum_fields.len * union_fields.len);
            for (enum_fields) |e_field| {
                for (union_fields) |u_field| {
                    if (mem.eql([:0]const u8, e_field.name, u_field.name)) break;
                } else {
                    @compileError("Bytes is missing a field for Kind '" ++ e_field.name ++ "'");
                }
            }
        }
    };

    pub const ApplicationRate = enum(u8) {
        two,
        one,
        point_five,
        point_one,

        pub fn toFloat(application_rate: ApplicationRate) f32 {
            return switch (application_rate) {
                .two => 2.0,
                .one => 1.0,
                .point_five => 0.5,
                .point_one => 0.1,
            };
        }
    };

    pub const ApplyResult = struct {
        hp_diff: f32,
        speed_diff: f32,
        is_still_active: bool,
    };
    /// Mutates effect.
    /// Returns whether effect is still active after application.
    pub fn apply(
        noalias effect: *Effect,
        kind: Effect.Kind,
        dt: f32,
    ) ApplyResult {
        const time_remaining = (effect.time_remaining - dt);
        const hp_diff, const speed_diff = switch (kind) {
            .fire => diff: {
                if (@ceil(time_remaining) < @ceil(effect.time_remaining)) {
                    // crossed second border, apply damage
                    @branchHint(.unlikely);
                    break :diff .{ -effect.strength, 0 };
                } else {
                    @branchHint(.likely);
                    break :diff .{ 0, 0 };
                }
            },
            .glue_yellow => {},
        };
        effect.time_remaining = time_remaining;
        return ApplyResult{
            .hp_diff = hp_diff,
            .speed_diff = speed_diff,
            .is_still_active = (time_remaining > 0),
        };
    }

    pub const count = @typeInfo(Effect.Kind).@"enum".fields.len;
    pub const Active = std.EnumSet(Effect.Kind);
    pub const Set = std.EnumArray(Effect.Kind, Effect);

    /// Guarantees stable indices, but not stable pointers.
    pub const List = struct {
        entries: Effect.List.Entries,
        avail_set: Effect.List.AvailSet,

        pub const Entries = std.ArrayListUnmanaged(Effect.Set);
        pub const AvailSet = std.DynamicBitSetUnmanaged;

        pub const Index = enum(u32) {
            none = math.maxInt(u32),
            _,

            pub inline fn from(val: u32) Index {
                const index: Index = @enumFromInt(val);
                assert(index != .none);
                return index;
            }
            pub inline fn asInt(index: Index) u32 {
                assert(index != .none);
                return @intFromEnum(index);
            }
        };

        pub const empty = Effect.List{
            .entries = .empty,
            .avail_set = .{},
        };

        pub fn initCapacity(gpa: Allocator, min_capacity: u32) Allocator.Error!Effect.List {
            var list = Effect.List.empty;
            try list.ensureTotalCapacity(gpa, min_capacity);
            return list;
        }

        pub fn deinit(list: *Effect.List, gpa: Allocator) void {
            list.entries.deinit(gpa);
            list.avail_set.deinit(gpa);
            list.* = undefined;
        }

        fn AtType(comptime SelfType: type) type {
            if (@typeInfo(SelfType).pointer.is_const) {
                return *const Effect.Set;
            } else {
                return *Effect.Set;
            }
        }
        pub fn at(list: anytype, index: Index) AtType(@TypeOf(list)) {
            assert(index < list.capacity() and list.avail_set.isSet(index.asInt()) == false);
            return list.entries.items[index.asInt()];
        }

        pub fn usedCount(list: *Effect.List) u32 {
            return @intCast(list.entries.capacity - list.avail_set.count());
        }
        pub fn unusedCount(list: *Effect.List) u32 {
            return @intCast(list.avail_set.count());
        }

        pub fn capacity(list: *Effect.List) u32 {
            return list.entries.capacity;
        }

        /// Reserves slot for use by caller, allocating as necessary.
        /// Returned index is guaranteed to not be `.none`.
        pub fn acquireOne(list: *Effect.List, gpa: Allocator) Allocator.Error!Index {
            list.ensureUnusedCapacity(gpa, 1);
            return list.acquireOneAssumeCapacity();
        }

        /// Reserves slot for use by caller.
        /// Returned index is guaranteed to not be `.none`.
        pub fn acquireOneAssumeCapacity(list: *Effect.List) Index {
            const avail_idx = list.avail_set.toggleFirstSet().?;
            return .from(@intCast(avail_idx));
        }

        pub fn release(list: *Effect.List, index: Index) void {
            const idx = index.asInt();
            assert(list.avail_set.isSet(idx) == false);
            list.avail_set.set(index);
        }

        pub fn ensureTotalCapacity(list: *Effect.List, gpa: Allocator, new_capacity: u32) Allocator.Error!void {
            try list.entries.ensureTotalCapacity(gpa, new_capacity);
            list.entries.len = list.entries.capacity;
            try list.avail_set.resize(gpa, list.entries.capacity, true);
        }
        pub fn ensureUnusedCapacity(list: *Effect.List, gpa: Allocator, additional_count: u32) Allocator.Error!void {
            const unused_count = list.unusedCount();
            if (unused_count < additional_count) {
                const required_count = (additional_count - unused_count);
                const new_capacity = (list.entries.capacity + required_count);
                try list.ensureTotalCapacity(gpa, new_capacity);
            }
        }

        pub fn shrink(list: *Effect.List, gpa: Allocator, new_capacity: u32) void {
            list.entries.shrinkAndFree(gpa, new_capacity);
            list.entries.len = list.entries.capacity;
            list.avail_set.resize(gpa, list.entries.capacity, true) catch unreachable;
        }

        pub fn clearAndFree(list: *Effect.List, gpa: Allocator) void {
            list.entries.clearAndFree(gpa);
            list.avail_set.resize(gpa, 0, false) catch unreachable;
        }
        pub fn clearRetainingCapacity(list: *Effect.List) void {
            list.avail_set.setAll();
        }
    };
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
    /// Used for `effects`.
    gpa: Allocator,
    /// Array of entries. Entries do not have a persistent identity.
    entries: Entries,
    /// Per-block effect storage for every entry that needs it.
    effects: Effect.List,
    /// Intrusive node for `Block.List`.
    list_node: List.Node,

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
    pub fn create(effect_gpa: Allocator, buffer: *align(alignment.toByteUnits()) [size]u8) *Block {
        var fba = heap.FixedBufferAllocator.init(buffer);
        const a = fba.allocator();

        const block = a.create(Block) catch unreachable;

        var entries = Entries.empty;
        entries.setCapacity(a, max_entry_count) catch unreachable;
        assert(fba.end_index == size);

        block.* = .{
            .gpa = effect_gpa,
            .entries = entries,
            .effects = .empty,
            .list_node = .{},
        };
        return block;
    }

    pub fn clear(block: *Block) void {
        block.entries.clearRetainingCapacity();
        assert(block.entries.capacity == max_entry_count);
    }

    const default_batch_size = 4;

    pub const GpuWriteTaskCtx = struct {
        block: *Block,
        dest: []u8,
        task: Task,
        wg: *WaitGroup,
    };
    pub fn makeGpuWriteTask(block: *Block, dest: []u8, wg: *WaitGroup) GpuWriteTaskCtx {
        return .{
            .block = block,
            .dest = dest,
            .task = .{ .callback = &gpuWrite },
            .wg = wg,
        };
    }
    fn gpuWrite(task: *Task) void {
        const ctx: *GpuWriteTaskCtx = @fieldParentPtr("task", task);
        _ = ctx;
    }

    pub const UpdateTaskCtx = struct {
        cur_block: *Block,
        old_block: *const Block,
        new_block_fn: *const newBlockFn,
        dt: f32,

        task: Task,
        wg: *WaitGroup,

        /// Has to be thread safe.
        pub const newBlockFn = fn (ctx: *anyopaque) *Block;
    };
    pub fn makeUpdateTask(
        cur_block: *Block,
        old_block: *const Block,
        new_block_fn: *const UpdateTaskCtx.newBlockFn,
        dt: f32,
        wg: *WaitGroup,
    ) UpdateTaskCtx {
        return .{
            .cur_block = cur_block,
            .old_block = old_block,
            .new_block_fn = new_block_fn,
            .dt = dt,
            .task = .{ .callback = &update },
            .wg = wg,
        };
    }
    fn update(task: *Task) void {
        const ctx: *UpdateTaskCtx = @fieldParentPtr("task", task);

        const fpv = domath.vector(1, f32);

        // APPLY OLD EFFECTS

        // Effect sets are always mutable since they are only used from within their respective block.
        // All external accessors of the old block may only use the per-entry `active_effects` field.
        ctx.cur_block.effects = ctx.old_block.effects;
        const effects = &ctx.cur_block.effects;

        const old = ctx.old_block.entries.slice();
        const cur = ctx.cur_block.entries.slice();

        for (
            old.items(.effect_index),
            cur.items(.effect_index),
            old.items(.active_effects),
            cur.items(.active_effects),
            0..,
        ) |old_idx, *cur_idx, old_active, *cur_active, i| {
            if (old_idx != .none) {
                const effect_set = effects.at(old_idx);
                var active_it = old_active.iterator();
                while (active_it.next()) |kind| {
                    const is_still_active = effect_set.getPtr(kind).apply(kind, &old, &cur, i, ctx.dt);
                    cur_active.setPresent(kind, is_still_active);
                }
                if (cur_active.count() == 0) {
                    effects.release(old_idx);
                    cur_idx.* = .none;
                } else {
                    cur_idx.* = old_idx;
                }
            }
        }

        // SCAN FOR PROJECTILE HITS AND APPLY DAMAGE + NEW EFFECTS

        var i: usize = 0;
        while (i < old.capacity) : (i += batch_size) {}

        const remaining = (i - old.capacity);
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
const stdx = @import("stdx");
const game = @import("game");
const domath = @import("domath");

const attributes = @import("Goon/attributes.zig");
const data = @import("Goon/data.zig");

const heap = std.heap;
const math = std.math;
const mem = std.mem;

const Allocator = mem.Allocator;
const Task = stdx.concurrent.ThreadPool.Task;
const WaitGroup = std.Thread.WaitGroup;

const assert = std.debug.assert;
