const std = @import("std");
const raylib = @import("raylib");

const enums = std.enums;
const mem = std.mem;
const meta = std.meta;

const assert = std.debug.assert;


/// used to index into the game's mutable goon attribute table
id: u32,


const Goon = @This();


pub const MutableAttributeTable = std.MultiArrayList(attributes.Mutable);
pub const ImmutableAttributeTable = enums.EnumArray(attributes.Kind, attributes.Immutable);

pub const immutable_attribute_table = ImmutableAttributeTable.init(.{
	.normal = .{
		.base = .{
			.hp = 1.0,
			.speed = 100,
		},
		.x = .{
			.children = .{},
			.immunity = .{},
		},
	},
	.black = .{
		.base = .{
			.hp = 1.0,
			.speed = 180,
		},
		.x = .{
			.children = .{ .normal = 2 },
			.immunity = .{ .black = true },
		},
	},
	.white = .{
		.base = .{
			.hp = 1.0,
			.speed = 200,
		},
		.x = .{
			.children = .{ .normal = 2 },
			.immunity = .{ .white = true },
		},
	},
	.purple = .{
		.base = .{
			.hp = 1.0,
			.speed = 300,
		},
		.x = .{
			.children = .{ .normal = 2 },
			.immunity = .{ .purple = true },
		},
	},
	.lead = .{
		.base = .{
			.hp = 1.0,
			.speed = 100,
		},
		.x = .{
			.children = .{ .black = 2 },
			.immunity = .{ .lead = true },
		},
	},
	.zebra = .{
		.base = .{
			.hp = 1.0,
			.speed = 180,
		},
		.x = .{
			.children = .{
				.black = 1,
				.white = 1,
			},
			.immunity = .{
				.black = true,
				.white = true,
			},
		},
	},
	.rainbow = .{
		.base = .{
			.hp = 1.0,
			.speed = 220,
		},
		.x = .{
			.children = .{ .zebra = 2 },
			.immunity = .{},
		},
	},
	.ceramic = .{
		.base = .{
			.hp = 10.0,
			.speed = 250,
		},
		.x = .{
			.children = .{ .rainbow = 2 },
			.immunity = .{},
		},
	},
	.super_white = .{
		.base = .{
			.hp = 1.0,
			.speed = 200,
		},
		.x = .{
			.children = .{ .normal = 1 },
			.immunity = .{ .white = true },
		},
	},
	.super_zebra = .{
		.base = .{
			.hp = 1.0,
			.speed = 180,
		},
		.x = .{
			.children = .{ .super_white = 1 },
			.immunity = .{
				.black = true,
				.white = true,
			},
		},
	},
	.super_rainbow = .{
		.base = .{
			.hp = 1.0,
			.speed = 220,
		},
		.x = .{
			.children = .{ .super_zebra = 1 },
			.immunity = .{},
		},
	},
	.super_ceramic = .{
		.base = .{
			.hp = 60.0,
			.speed = 250,
		},
		.x = .{
			.children = .{ .super_rainbow = 1 },
			.immunity = .{},
		},
	},
	.moab = .{
		.base = .{
			.hp = 200.0,
			.speed = 100,
		},
		.x = .{
			.children = .{ .ceramic = 4 },
			.immunity = .{},
		},
	},
	.bfb = .{
		.base = .{
			.hp = 700.0,
			.speed = 25,
		},
		.x = .{
			.children = .{ .moab = 4 },
			.immunity = .{},
		},
	},
	.zomg = .{
		.base = .{
			.hp = 4000,
			.speed = 18,
		},
		.x = .{
			.children = .{ .bfb = 4 },
			.immunity = .{},
		},
	},
	.ddt = .{
		.base = .{
			.hp = 400,
			.speed = 275,
		},
		.x = .{
			.children = .{ .ceramic = 4 },
			.immunity = .{
				.black = true,
				.lead = true,
			},
		},
	},
	.bad = .{
		.base = .{
			.hp = 20000,
			.speed = 18,
		},
		.x = .{
			.children = .{
				.zomg = 2,
				.ddt = 3,
			},
			.immunity = .{},
		},
	},
});

/// Add this to the base speed depending on color before converting to float
pub const base_speed_offset_table = enums.EnumArray(attributes.Mutable.Color, u16).init(.{
	.red = 0,
	.blue = 40,
	.green = 80,
	.yellow = 220,
	.pink = 250,
	.none = 0,
});


pub const Kind = enum(u8) {
	normal,
	black,
	white,
	purple,
	lead,
	zebra,
	rainbow,
	ceramic,
	super_white,
	super_zebra,
	super_rainbow,
	super_ceramic,
	moab,
	bfb,
	zomg,
	ddt,
	bad,
};


pub const attributes = struct {
	pub const Immutable = struct {
		texture: raylib.Texture2D,
		base: Base,
		x: X,

		pub const Base = struct {
			hp: f64,
			speed: u16,
		};

		pub const X = packed struct(u64) {
			children: Children,
			immunity: Damage,

			pub const Children = blk: {
				const Templ = enums.EnumFieldStruct(Kind, u3, 0);
				var info = @typeInfo(Templ).@"struct";
				info.layout = .@"packed";
				info.backing_integer = meta.Int(.unsigned, mem.alignForward(u16, 3*info.fields.len, 8));
				for (info.fields) |*field| {
					field.alignment = 0;
				}
				break :blk @Type(.{ .@"struct" = info });
			};
		};
	};

	pub const Mutable = struct {
		position: raylib.Vector2,
		hp: f64,
		speed: f32,
		kind: Kind,
		color: Color,
		extra: Extra,


		pub const Color = enum(u4) {
			red,
			blue,
			green,
			yellow,
			pink,
			none,
		};

		pub const Extra = packed struct(u4) {
			camo: bool,
			fortified: bool,
			regrow: bool,
		};

		pub const AppliedStatusEffect = extern struct {
			effect: *StatusEffect,
			timestamp: u64,
		};

		pub const StatusEffect = extern struct {
			/// interpreted based on damage_kind
			damage: f64,
			/// factor applied on goon speed
			slow: f32,
			/// in game ticks
			duration: u16,
			effect_kind: EffectKind,
			damage_kind: DamageKind,

			applyFn: *const fn (
				status_effect: *StatusEffect,
				goon: Goon,
				mutable_attr_table: *MutableAttributeTable,
			) void,

			pub const EffectKind = enum(u8) {
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
	};


	pub const Template = struct {
		kind: Kind,
		color: Mutable.Color,
		extra: Mutable.Extra,

		pub inline fn normal(color: Mutable.Color, extra: Mutable.Extra) Template {
			assert(color != .none);
			return .{
				.kind = .normal,
				.color = color,
				.extra = extra
			};
		}
		pub inline fn special(kind: Kind, extra: Mutable.Extra) Template {
			assert(kind != .normal);
			assert(kind != .ddt or (extra.camo and extra.regrow));
			return .{
				.kind = kind,
				.color = .none,
				.extra = extra,
			};
		}
	};


	pub const DamageKind = enum(u8) {
		normal = Damage{
			.black = true,
			.white = true,
			.lead = true,
			.purple = true,
		},
		magic = Damage{
			.black = true,
			.white = true,
			.lead = true,
			.purple = false,
		},
		explosion = Damage{
			.black = false,
			.white = true,
			.lead = true,
			.purple = true,
		},
		freeze = Damage{
			.black = true,
			.white = false,
			.lead = true,
			.purple = true,
		},
		glacier = Damage{
			.black = true,
			.white = false,
			.lead = false,
			.purple = true,
		},
		energy = Damage{
			.black = true,
			.white = true,
			.lead = false,
			.purple = false,
		},
		sharp = Damage{
			.black = true,
			.white = true,
			.lead = false,
			.purple = true,
		},
		cold = Damage{
			.black = true,
			.white = false,
			.lead = false,
			.purple = true,
		},
		passive = Damage{
			.black = false,
			.white = false,
			.lead = false,
			.purple = false,
		},

		pub inline fn canDamage(damage_kind: DamageKind, immunity: Damage) bool {
			return @as(Damage, @truncate(@intFromEnum(damage_kind))).canDamage(immunity);
		}
	};

	const Damage = packed struct(u4) {
		black: bool = false,
		white: bool = false,
		lead: bool = false,
		purple: bool = false,

		pub inline fn canDamage(damage: Damage, immunity: Damage) bool {
			return ((damage & ~immunity) == 0);
		}
	};
};
