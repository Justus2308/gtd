const std = @import("std");
const entities = @import("entities");
const Goon = entities.Goon;

const collisions = @import("interactions/collisions.zig");
pub const CollisionMap = collisions.CollisionMap;

pub const Damage = packed struct(u4) {
	black: bool = false,
	white: bool = false,
	lead: bool = false,
	purple: bool = false,

	pub inline fn canDamage(damage: Damage, immunity: Damage) bool {
		return ((@as(u8, @bitCast(damage)) & ~@as(u8, @bitCast(immunity))) == 0);
	}

	pub const passive = Damage{
		.black = false,
		.white = false,
		.lead = false,
		.purple = false,
	};
	pub const normal = Damage{
		.black = true,
		.white = true,
		.lead = true,
		.purple = true,
	};
	pub const magic = Damage{
		.black = true,
		.white = true,
		.lead = true,
		.purple = false,
	};
	pub const explosion = Damage{
		.black = false,
		.white = true,
		.lead = true,
		.purple = true,
	};
	pub const freeze = Damage{
		.black = true,
		.white = false,
		.lead = true,
		.purple = true,
	};
	pub const cold = Damage{
		.black = true,
		.white = false,
		.lead = false,
		.purple = true,
	};
	pub const energy = Damage{
		.black = true,
		.white = true,
		.lead = false,
		.purple = false,
	};
	pub const sharp = Damage{
		.black = true,
		.white = true,
		.lead = false,
		.purple = true,
	};
};

pub const Effect = struct {
	/// interpreted based on damage_kind
	damage_amount: f32,
	/// factor applied on goon speed
	slow: f32,
	/// in seconds
	duration: f32,
	effect_kind: Effect.Kind,
	damage_kind: Damage,

	applyFn: *const fn (effect: *Effect, goon: Goon, mutable_attr_table: *Goon.Mutable.Table) void,

	pub fn applyFnUnimplemented(_: *Effect, _: Goon, _: *Goon.Mutable.Table) void {
		@compileError("effect unimplemented");
	}

	pub const Map = std.hash_map.HashMapUnmanaged(Effect, u32, hashing_ctx, std.hash_map.default_max_load_percentage);
	const hashing_ctx = struct {
		fn hash(ctx: anytype, key: Effect) u64 {
			_ = ctx;
			var hasher = std.hash.Wyhash.init(0);
			std.hash.autoHashStrat(&hasher, key, .Shallow);
		}
		fn eql(ctx: anytype, a: Effect, b: Effect) bool {
			_ = ctx;
			return std.meta.eql(a, b);
		}
	};
	pub const List = std.ArrayListUnmanaged(Effect);

	pub const Kind = enum(u8) {
		none = 0,
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
};
