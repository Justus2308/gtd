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

pub const immutable_attribute_table = data.immutable_attribute_table;

pub inline fn getImmutable(kind: Kind) *const attributes.Immutable {
    return &Goon.immutable_attribute_table[@intFromEnum(kind)];
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
    mutable_attr_table: Goon.Mutable.Table,
    id_offset: u32,
    alive_map: AliveMap,

    depends_on: DependencyMap,
    provides: DependencyMap,

    pub const capacity = 512;
    const size = Goon.MutableAttributeTable.capacityInBytes(Block.capacity);
    const alignment = @alignOf(Goon.MutableAttributeTable);

    pub const Attribute = Mutable.Table.Field;
    fn AttributeType(comptime attribute: Attribute) type {
        return std.meta.fieldInfo(Goon.Mutable.Table, attribute).type;
    }

    pub const AliveMap = std.bit_set.StaticBitSet(Block.capacity);

    pub const Dependency = enum(u32) {

    };
    pub const DependencyMap = packed struct(u32) {

    };
 
    pub fn create(pool: *Block.Pool, id_offset: u32) *Block {
        const block = try pool.create();
        defer pool.destroy(block);

        block.* = .{
            .mutable_attr_table = .{
                .bytes = block.memory,
                .len = 0,
                .capacity = Block.capacity,
            },
            .id_offset = id_offset,
            .alive_map = Block.AliveMap.initEmpty(),
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
        return @intCast(block.mutable_attr_table.len);
    }

    pub inline fn getAttr(
        block: *Block,
        goon: Goon,
        comptime attribute: Attribute,
    ) Block.AttributeType(attribute) {
        return block.mutable_attr_table.items(attribute)[goon.id - block.id_offset];
    }
    pub inline fn setAttr(
        block: *Block,
        goon: Goon,
        comptime attribute: Attribute,
        value: Block.AttributeType(attribute),
    ) void {
        block.mutable_attr_table.items(attribute)[goon.id - block.id_offset] = value;
    }

    pub inline fn get(block: *Block, goon: Goon) Goon.Mutable {
        return block.mutable_attr_table.get(goon.id - block.id_offset);
    }
    pub inline fn set(block: *Block, goon: Goon, mutable: Goon.Mutable) void {
        block.mutable_attr_table.set(goon.id - block.id_offset, mutable);
    }

    pub fn spawn(block: *Block, mutable: Goon.Mutable) Goon {
        const local_id = block.mutable_attr_table.addOneAssumeCapacity();
        block.mutable_attr_table.set(local_id, mutable);
        block.alive_map.set(local_id);
        return Goon{ .id = (local_id + block.id_offset) };
    }
    pub fn kill(block: *Block, goon: Goon) void {
        block.alive_map.unset(goon.id - block.id_offset);
    }
    pub inline fn isAlive(block: *Block, goon: Goon) bool {
        return block.alive_map.isSet(goon.id - block.id_offset);
    }
    pub fn hasAlive(block: *Block) bool {
        return (block.alive_map.findFirstSet() != null);
    }

    pub fn isFull(block: *Block) bool {
        return (block.mutable_attr_table.len == block.mutable_attr_table.cap);
    }

    pub fn apply(block: *Block, comptime attribute: Attribute, op: std.builtin.AtomicRmwOp, operand: AttributeType(attribute)) void {
        const T = AttributeType(attribute);
        const batch_size = simd.suggestVectorLength(T) orelse 1;
        const Vec = @Vector(batch_size, T);

        const used_ = block.used();
        const items = block.mutable_attr_table.items(attribute);

        var i: u32 = 0;
        while (i < used_) : (i += batch_size) {
            if (batch_size > 1) {
                const vec: Vec = items[i..][0..batch_size];
                
            } else {
                
            }
        }
        for ((i-batch_size)..used) |r| {

        }
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
