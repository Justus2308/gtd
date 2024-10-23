const std = @import("std");
const raylib = @import("raylib");
const game = @import("game");

const attributes = @import("Goon/attributes.zig");
const data = @import("Goon/data.zig");

const enums = std.enums;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const simd = std.simd;

const Allocator = mem.Allocator;

const assert = std.debug.assert;


/// used to index into the game's mutable goon attribute table
id: u32,


const Goon = @This();

pub const Mutable = attributes.Mutable;
pub const Immutable = attributes.Immutable;

pub const immutable_earlygame = data.immutable_earlygame;
pub const immutable_lategame = data.immutable_lategame;

pub inline fn getImmutable(immutable_data_ptr: *const Immutable.List, kind: Kind) *const Immutable {
    return &immutable_data_ptr[@intFromEnum(kind)];
}

pub const base_speed_offset_table = data.base_speed_offset_table;


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


pub const Block align(mem.page_size) = struct {
    memory: [Block.size]u8 align(alignment) = undefined,
    mutable_list: Goon.Mutable.List,
    id_offset: u32,
    is_free: BoolVec,

    due_damage: F64Vec,
    due_pierce: U32Vec,

    depends_on: DependencyMap,
    provides: DependencyMap,

    pub const capacity = 512;
    const size = Goon.Mutable.List.capacityInBytes(Block.capacity);
    const alignment = @alignOf(Goon.Mutable);

    const F64Vec = @Vector(Block.capacity, f64);
    const U32Vec = @Vector(Block.capacity, u32);
    const BoolVec = @Vector(Block.capacity, bool);

    pub const Attribute = Mutable.List.Field;
    fn AttributeType(comptime attribute: Attribute) type {
        return std.meta.fieldInfo(Goon.Mutable.Table, attribute).type;
    }

    pub const Dependency = enum(u32) {

    };
    pub const DependencyMap = packed struct(u32) {

    };
 
    pub fn create(pool: *Block.Pool, id_offset: u32) *Block {
        const block = try pool.create();
        defer pool.destroy(block);

        block.* = .{
            .mutable_list = .{
                .bytes = block.memory,
                .len = 0,
                .capacity = Block.capacity,
            },
            .id_offset = id_offset,
            .alive_map = Block.AliveMap.initEmpty(),
            .due_damage = @splat(0.0),
        };
    }
    pub fn destroy(block: *Block, pool: *Block.Pool) void {
        pool.destroy(block);
        block.* = undefined;
    }

    pub inline fn minId(block: *Block) u32 {
        return block.id_offset;
    }
    pub inline fn maxId(block: *Block) u32 {
        return block.id_offset + Block.capacity;
    }

    pub inline fn used(block: *Block) u32 {
        return @intCast(block.mutable_list.len);
    }

    pub inline fn getAttr(
        block: *Block,
        goon: Goon,
        comptime attribute: Attribute,
    ) Block.AttributeType(attribute) {
        return block.mutable_list.items(attribute)[goon.id - block.id_offset];
    }
    pub inline fn setAttr(
        block: *Block,
        goon: Goon,
        comptime attribute: Attribute,
        value: Block.AttributeType(attribute),
    ) void {
        block.mutable_list.items(attribute)[goon.id - block.id_offset] = value;
    }

    pub inline fn get(block: *Block, goon: Goon) Goon.Mutable {
        return block.mutable_list.get(goon.id - block.id_offset);
    }
    pub inline fn set(block: *Block, goon: Goon, mutable: Goon.Mutable) void {
        block.mutable_list.set(goon.id - block.id_offset, mutable);
    }

    pub fn spawn(block: *Block, mutable: Goon.Mutable) Goon {
        const local_id = block.mutable_list.addOneAssumeCapacity();
        block.mutable_list.set(local_id, mutable);
        block.alive_map.set(local_id);
        return Goon{ .id = (local_id + block.id_offset) };
    }
    pub fn damage(block: *Block, goon: Goon, dmg: f64) void {
        const hp = block.getAttr(goon, .hp);

        const kind = block.getAttr(goon, .kind);
        const immutable = Goon.getImmutable(kind);

        block.alive_map.unset(goon.id - block.id_offset);
    }
    pub fn applyDueDamage(block: *Block, immutable_data_ptr: *const Goon.Immutable.List) void {
        // 1. max(hp - dmg, 0) = hp remaining
        // 2. max(dmg - hp, 0) = dmg remaining
        // 3. check for dead goons, spawn children
        // 4. reduce(add, dmg remaining) > 0 ? go again
        // WICHTIG JEDES PROJECTILE DARF NUR MIT EINEM GOON PRO FRAME COLLIDEN
        // -> wie aoe handlen? projektile mit unendlich pierce generieren?

        // in jedem block muss immer genug platz für alle children sein
        // sonst lässt sich hier nix parallelisieren alda

        var hp_vec: F64Vec = undefined;
        @memcpy(&hp_vec, block.mutable_list.items(.hp));

        while (@reduce(.Add, block.due_damage) > 0.0) {
            const all_zeroes: F64Vec = @splat(0.0);

            const hp_remaining = (hp_vec - block.due_damage);
            const goon_is_dead = (hp_remaining > 0);
            hp_vec = @select(f64, goon_is_dead, hp_remaining, all_zeroes);

            const dmg_remaining = (block.due_damage - hp_vec);
            const dmg_source_is_done = (dmg_remaining > 0);
            block.due_damage = @select(f64, dmg_source_is_done, dmg_remaining, all_zeroes);

            if (!@reduce(.Or, (goon_is_dead or dmg_source_is_done))) {
                // There are no more known collisions to left, we check
                // for collisions with freshly spawned goons next frame.
                break;
            }

            for (0..Block.capacity) |i| {
                const kinds = block.mutable_list.items(.kind);
                if (goon_is_dead[i]) {
                    // TODO:
                    // 1. count direct children
                    // 2. if only 1: replace dead goon with child
                    // 3. if >1: replace dead goon with first child and shift position,
                    //    spawn the rest in free slots
                    // 4. apply remaining damage to children
                    // 5. if they die, repeat process for them
                    const immutable = Goon.getImmutable(immutable_data_ptr, kinds[i]);
                    inline for (meta.fields(Goon.Immutable.Children), 0..) |field, i| {
                        const child_count = @field(immutable.children, field.name);
                        for (0..child_count) |_| {
                            block.spawn(.{
                                .color = if (i == 0) .pink else .none,
                                .
                            });
                        }
                    }
                }
            }
        }

        @memcpy(block.mutable_list.items(.hp), &hp_vec);
    }

    pub fn kill(block: *Block, goon: Goon) void {
        block.is_free[goon.id - block.id_offset] = true;
    }
    fn findNextFreeIdx(block: *const Block) ?u32 {
        return simd.firstTrue(block);
    }

    pub inline fn isAlive(block: *Block, goon: Goon) bool {
        return !block.is_free[goon.id - block.id_offset];
    }
    pub fn hasAlive(block: *Block) bool {
        return @reduce(.And, block.is_free);
    }

    pub fn isFull(block: *Block) bool {
        return !@reduce(.Or, block.is_free);
    }


    pub const Pool = std.heap.MemoryPoolAligned(Block, Block.alignment);
    pub const RefList = std.ArrayList(?*Block);

    pub const List = struct {
        pool: Block.Pool,
        ref_list: Block.RefList,
        max_id: u32,
        current_block_idx: u32,


        pub fn init(arena: Allocator, expected_max_id: u32) Allocator.Error!Block.List {
            const list = Block.List{
                .pool = Block.Pool.init(arena),
                .ref_list = Block.RefList.init(arena),
                .max_id = mem.alignForward(u32, expected_max_id, Block.capacity),
                .current_block_idx = 0,
            };
            errdefer list.deinit(arena);

            const block_count = @divExact(list.max_id, Block.capacity);
            try list.ref_list.ensureTotalCapacityPrecise(block_count);
            for (0..block_count) |i| {
                const block = try list.pool.create();
                list.ref_list.insertAssumeCapacity(i, block);
            }
        }
        pub fn deinit(list: *Block.List) void {
            list.pool.deinit();
            list.ref_list.deinit();
            list.* = undefined;
        }

        pub fn reset(list: *Block.List, mode: Block.Pool.ResetMode) void {
            _ = list.pool.reset(mode);
            switch (mode) {
                .free_all => list.ref_list.clearAndFree(),
                .retain_capacity => list.ref_list.clearRetainingCapacity(),
                .retain_with_limit => |limit| {
                    if (list.ref_list.capacity > limit) {
                        list.ref_list.shrinkAndFree(limit);
                    }
                    list.ref_list.clearRetainingCapacity();
                },
            }
        }

        pub fn addOne(list: *Block.List) Allocator.Error!*Block {
            const block = try list.pool.create();
            errdefer list.pool.destroy(block);

            const ref = try list.ref_list.addOne();
            ref.* = block;
            return block;
        }

        pub fn sweep(list: *Block.List) void {
            for (list.ref_list.items) |*ref| {
                if (ref.*) |block| {
                    if (!block.hasAlive()) {
                        list.pool.destroy(block);
                        ref.* = null;
                    }
                }
            }
        }

        pub fn getGoonAttr(
            list: *Block.List,
            goon: Goon,
            comptime attribute: Attribute,
        ) ?Block.AttributeType(attribute) {
            const block = list.getBlock(goon) orelse return null;
            return block.getAttr(goon, attribute);
        }
        pub fn setGoonAttr(
            list: *Block.List,
            goon: Goon,
            comptime attribute: Attribute,
            value: Block.AttributeType(attribute),
        ) void {
            const block = list.getBlock(goon) orelse return;
            block.setAttr(goon, attribute, value);
        }

        pub fn getGoon(list: *Block.List, goon: Goon) ?Goon.Mutable {
            const block = list.getBlock(goon) orelse return null;
            return block.get(goon);
        }
        pub fn setGoon(list: *Block.List, goon: Goon, mutable: Goon.Mutable) void {
            const block = list.getBlock(goon) orelse return;
            block.set(goon, mutable);
        }

        pub fn spawn(list: *Block.List, mutable: Goon.Mutable) Allocator.Error!Goon {
            const block = try list.getCurrentBlock();
            return block.spawn(mutable);
        }
        pub fn kill(list: *Block.List, goon: Goon) void {
            const block = list.getBlock(goon) orelse return;
            block.kill(goon);
        }
        pub fn isAlive(list: *Block.List, goon: Goon) bool {
            const block = list.getBlock(goon) orelse return false;
            return block.isAlive(goon);
        }

        inline fn getBlock(list: *Block.List, goon: Goon) ?*Block {
            const block_idx = Block.List.blockCountForMaxId(goon.id);
            return list.ref_list.items[block_idx];
        }

        inline fn blockCountForMaxId(max_id: u32) u32 {
            return math.divCeil(u32, max_id, Block.capacity) catch unreachable;
        }

        inline fn getCurrentBlock(list: *Block.List) Allocator.Error!*Block {
            if (list.ref_list.items[list.current_block_idx]) |block| {
                if (!block.isFull()) return block;
            }
            const block = try list.addOne();
            list.current_block_idx += 1;
            assert(list.ref_list.items[list.current_block_idx] == block);
            return block;
        }

        fn findNextLivingBlock(list: *Block.List, starting_block_idx: u32) ?*Block {
            for (starting_block_idx..list.current_block_idx) |i| {
                if (list.ref_list.items[i]) |block| {
                    if (block.hasAlive()) return block;
                }
            } else return null;
        }
    };
};
