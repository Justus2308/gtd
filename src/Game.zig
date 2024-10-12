const std = @import("std");
const raylib = @import("raylib");

const math = std.math;
const mem = std.mem;
const simd = std.simd;

const Allocator = mem.Allocator;

const assert = std.debug.assert;

const Goon = @import("Goon.zig");
const Map = @import("Map.zig");
const Round = @import("Round.zig");


allocator: Allocator,

map: *Map,
background: raylib.Texture2D,

difficulty: Difficulty,
mode: Mode,

round: u64,
pops: f64,
cash: f64,

scaling: Scaling,

goon_blocks: GoonBlock.List,


const Game = @This();


pub fn initRound(round: u64) Allocator.Error!void {
	
}


pub const Scaling = struct {
	hp: f64 = 1.0,
	speed: f32 = 1.0,
	status: f32 = 1.0,
	cash: f64 = 1.0,
};
fn scaleHp(game: *Game) void {
	const step: f64 = switch (game.round) {
		0...80 => return,
		81...100 => 0.02,
		101...124 => 0.05,
		125...150 => 0.15,
		151...250 => 0.35,
		251...300 => 1.00,
		301...400 => 1.50,
		401...500 => 2.50,
		else => 5.00,
	};
	game.scaling.hp += step;
}
fn scaleSpeed(game: *Game) void {
	const step: f32 = switch (game.round) {
		0...80 => return,
		101 => 0.2,
		151 => 0.42,
		201 => 0.52,
		252 => 0.5,
		else => 0.02,
	};
	game.scaling.speed += step;
}
fn scaleStatus(game: *Game) void {
	const step: f32 = switch (game.round) {
		150, 200, 250, 300, 350 => 0.10,
		else => return,
	};
	game.scaling.status -= step;
}
fn scaleCash(game: *Game) void {
	const abs: f64 = switch (game.round) {
		51 => 0.50,
		61 => 0.20,
		86 => 0.10,
		101 => 0.05,
		121 => 0.02,
		else => return,
	};
	game.scaling.cash = abs;
}


pub const Difficulty = enum {
	easy,
	normal,
	hard,
	impoppable,
};
pub const Mode = enum {
	standard,
	chimps,
};


pub const GoonBlock = struct {
	memory: [GoonBlock.size]u8 align(alignment) = undefined,
	mutable_attr_table: Goon.MutableAttributeTable,
	id_offset: u32,
	alive_map: AliveMap,

	pub const capacity = 512;
	const size = Goon.MutableAttributeTable.capacityInBytes(GoonBlock.capacity);
	const alignment = @alignOf(Goon.MutableAttributeTable);

	pub const Attribute = Goon.MutableAttributeTable.Field;
	fn AttributeType(comptime attribute: Attribute) type {
		return std.meta.fieldInfo(Goon.MutableAttributeTable, Attribute).type;
	}

	pub const AliveMap = std.bit_set.StaticBitSet(GoonBlock.capacity);

	pub fn create(pool: *GoonBlock.Pool, id_offset: u32) *GoonBlock {
		const bb = try pool.create();
		defer pool.destroy(bb);

		bb.* = .{
			.mutable_attr_table = .{
				.bytes = bb.memory,
				.len = 0,
				.capacity = GoonBlock.capacity,
			},
			.id_offset = id_offset,
			.alive_map = GoonBlock.AliveMap.initEmpty(),
		};
	}
	pub fn destroy(bb: *GoonBlock, pool: *GoonBlock.Pool) void {
		pool.destroy(bb);
		bb.* = undefined;
	}

	pub inline fn minId(bb: *GoonBlock) u32 {
		return bb.id_offset;
	}
	pub inline fn maxId(bb: *GoonBlock) u32 {
		return bb.id_offset + GoonBlock.capacity;
	}

	pub inline fn getAttr(
		bb: *GoonBlock,
		goon: Goon,
		comptime attribute: Attribute,
	) GoonBlock.AttributeType(attribute) {
		return bb.mutable_attr_table.items(attribute)[goon.id - bb.id_offset];
	}
	pub inline fn setAttr(
		bb: *GoonBlock,
		goon: Goon,
		comptime attribute: Attribute,
		value: GoonBlock.AttributeType(attribute),
	) void {
		bb.mutable_attr_table.items(attribute)[goon.id - bb.id_offset] = value;
	}

	pub inline fn get(bb: *GoonBlock, goon: Goon) Goon.attributes.Mutable {
		return bb.mutable_attr_table.get(goon.id - bb.id_offset);
	}
	pub inline fn set(bb: *GoonBlock, goon: Goon, mutable: Goon.attributes.Mutable) void {
		bb.mutable_attr_table.set(goon.id - bb.id_offset, mutable);
	}

	pub fn spawn(bb: *GoonBlock, mutable: Goon.attributes.Mutable) Goon {
		const local_id = bb.mutable_attr_table.addOneAssumeCapacity();
		bb.mutable_attr_table.set(local_id, mutable);
		bb.alive_map.set(local_id);
		return Goon{ .id = (local_id + bb.id_offset) };
	}
	pub fn kill(bb: *GoonBlock, goon: Goon) void {
		bb.alive_map.unset(goon.id - bb.id_offset);
	}
	pub inline fn isAlive(bb: *GoonBlock, goon: Goon) bool {
		return bb.alive_map.isSet(goon.id - bb.id_offset);
	}
	pub fn hasAlive(bb: *GoonBlock) bool {
		return (bb.alive_map.findFirstSet() != null);
	}

	pub fn isFull(bb: *GoonBlock) bool {
		return (bb.mutable_attr_table.len == bb.mutable_attr_table.cap);
	}


	pub const Pool = std.heap.MemoryPoolAligned(GoonBlock, GoonBlock.alignment);
	pub const RefList = std.ArrayList(?*GoonBlock);

	pub const List = struct {
		pool: GoonBlock.Pool,
		ref_list: GoonBlock.RefList,
		max_id: u32,
		current_block_idx: u32,


		pub fn init(arena: Allocator, expected_max_id: u32) Allocator.Error!GoonBlock.List {
			const list = GoonBlock.List{
				.pool = GoonBlock.Pool.init(arena),
				.ref_list = GoonBlock.RefList.init(arena),
				.max_id = mem.alignForward(u32, expected_max_id, GoonBlock.capacity),
				.current_block_idx = 0,
			};
			errdefer list.deinit(arena);

			const block_count = @divExact(list.max_id, GoonBlock.capacity);
			try list.ref_list.ensureTotalCapacityPrecise(block_count);
			for (0..block_count) |i| {
				const bb = try list.pool.create();
				list.ref_list.insertAssumeCapacity(i, bb);
			}
		}
		pub fn deinit(list: *GoonBlock.List, arena: Allocator) void {
			list.pool.deinit();
			list.ref_list.deinit();
			list.* = undefined;
		}

		pub fn addOne(list: *GoonBlock.List) Allocator.Error!*GoonBlock {
			const bb = try list.pool.create();
			errdefer list.pool.destroy(bb);

			const ref = try list.ref_list.addOne();
			ref.* = bb;
			return bb;
		}

		pub fn sweep(list: *GoonBlock.List) void {
			for (list.ref_list.items) |*ref| {
				if (ref.*) |bb| {
					if (!bb.hasAlive()) {
						list.pool.destroy(bb);
						ref.* = null;
					}
				}
			}
		}

		pub fn getGoonAttr(
			list: *GoonBlock.List,
			goon: Goon,
			comptime attribute: Attribute,
		) ?GoonBlock.AttributeType(attribute) {
			const bb = list.getGoonBlock(goon) orelse return null;
			return bb.getAttr(goon, attribute);
		}
		pub fn setGoonAttr(
			list: *GoonBlock.List,
			goon: Goon,
			comptime attribute: Attribute,
			value: GoonBlock.AttributeType(attribute),
		) void {
			const bb = list.getGoonBlock(goon) orelse return;
			bb.setAttr(goon, attribute, value);
		}

		pub fn getGoon(list: *GoonBlock.List, goon: Goon) ?Goon.attributes.Mutable {
			const bb = list.getGoonBlock(goon) orelse return null;
			return bb.get(goon);
		}
		pub fn setGoon(list: *GoonBlock.List, goon: Goon, mutable: Goon.attributes.Mutable) void {
			const bb = list.getGoonBlock(goon) orelse return;
			bb.set(goon, mutable);
		}

		pub fn spawn(list: *GoonBlock.List, mutable: Goon.attributes.Mutable) Allocator.Error!Goon {
			const bb = try list.getCurrentBlock();
			return bb.spawn(mutable);
		}
		pub fn kill(list: *GoonBlock.List, goon: Goon) void {
			const bb = list.getGoonBlock(goon) orelse return;
			bb.kill(goon);
		}
		pub fn isAlive(list: *GoonBlock.List, goon: Goon) bool {
			const bb = list.getGoonBlock(goon) orelse return false;
			return bb.isAlive(goon);
		}

		inline fn getGoonBlock(list: *GoonBlock.List, goon: Goon) ?*GoonBlock {
			const block_idx = GoonBlock.List.blockCountForMaxId(goon.id);
			return list.ref_list.items[block_idx];
		}

		inline fn blockCountForMaxId(max_id: u32) u32 {
			return math.divCeil(u32, max_id, GoonBlock.capacity) catch unreachable;
		}

		inline fn getCurrentBlock(list: *GoonBlock.List) Allocator.Error!*GoonBlock {
			if (list.ref_list.items[list.current_block_idx]) |bb| {
				if (!bb.isFull()) return bb;
			}
			const bb = try list.addOne();
			list.current_block_idx += 1;
			assert(list.ref_list.items[list.current_block_idx] == bb);
			return bb;
		}
	};
};


pub const SpawnGoonOptions = struct {
	color: Goon.attributes.Mutable.Color = .none,
	extra: Goon.attributes.Mutable.Extra = .{},
};
pub fn spawnGoon(
	game: *Game,
	mutable_attr_table: *Goon.MutableAttributeTable,
	id: u32,
	position: raylib.Vector2,
	kind: Goon.Kind,
	options: SpawnGoonOptions,
) Goon {
	assert(kind != .normal or options.color != .none);
	assert(kind != .ddt or (options.extra.camo and options.extra.regrow));
	assert(game.round >= 81 or kind != .super_ceramic);

	const immutable = Goon.immutable_attribute_table.getPtrConst(kind);

	const base_speed: f32 = @floatFromInt(immutable.base.speed + Goon.base_speed_offset_table.get(kind));

	const hp = immutable.base.hp * game.scaling.hp;
	const speed = base_speed * game.scaling.speed;

	const mutable = Goon.attributes.Mutable{
		.position = position,
		.hp = hp,
		.speed = speed,
		.kind = kind,
		.color = options.color,
		.extra = options.extra,
	};
	mutable_attr_table.set(id, mutable);

	return Goon{ .id = id };
}


pub fn create(allocator: Allocator, map: *Map, difficulty: Difficulty, mode: Mode) Allocator.Error!*Game {
	const game = try allocator.create(Game);
	errdefer allocator.destroy(game);

	const goon_mutable_attr_tables = try GoonMutableAttrList.initCapacity(allocator, 1);
	errdefer goon_mutable_attr_tables.deinit(allocator);

	game.* = Game{
		.allocator = allocator,

		.map = map,
		.background = raylib.loadTextureFromImage(map.background),

		.difficulty = difficulty,
		.mode = mode,

		.round = 0,
		.pops = 0,
		.cash = 0,

		.scaling = .{},

		.goon_mutable_attr_tables = goon_mutable_attr_tables,
	};

	const window_scale_factor = raylib.getWindowScaleDPI();
	game.background.drawEx(.{ 0, 0 }, 0.0, scale: f32, tint: Color);
}

pub fn destroy(game: *Game) void {
	game.allocator.destroy(game);
	game.* = undefined;
}



// REIHENFOLGE
// liste von möglichen statuseffekten führen
// immer wenn affe geupgraded/platziert wird liste updaten
// für jeden goon liste mit statuseffekten führen, jwls pointer auf effekt und timestamp
// jeden gametick schauen ob irgendein statuseffekt ausgeführt werden muss (vllt effektpointer einfach auf null)
// einfach in array unterbringen der so lang ist wie anzahl v mögl statuseffekten
// ist nie besonders lang also einfach nach nächstem slot bei dem effekt null ist suchen
// ODER: jedem effekt einen index zuweisen (vllt besser)

// Pass 1: Hintergrund rendern, scaling anwenden, Affenangriffe auswerten,
//         Goons zerstören/neue spawnen, Statuseffekte aktualisieren, Cash+Pops aktualisieren
// Pass 2: Affen rendern
// Pass 3: Goonpositionen aktualisieren, Projektilpositionen aktualisieren, Goons rendern
// Pass 4: Projektile rendern, Statuseffekte rendern, sonstige Effekte rendern (first come first serve)
