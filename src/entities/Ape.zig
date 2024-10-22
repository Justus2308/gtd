const std = @import("std");
const raylib = @import("raylib");

const enums = std.enums;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const simd = std.simd;

const Allocator = mem.Allocator;

const assert = std.debug.assert;


const attributes = @import("Ape/attributes.zig");
const interactions = @import("interactions.zig");
const Goon = @import("Goon.zig");

const Damage = interactions.Damage;
const Effect = interactions.Effect;


id: u32,


pub const Mutable = attributes.Mutable;
pub const Immutable = attributes.Immutable;

pub const immutable_attribute_table align(std.atomic.cache_line) = enums.directEnumArray(
    attributes.Kind,
    attributes.Immutable,
    0,
    .{
        .dart = .{
            .base_dmg = 1.0,
            .base_pierce = 2.0,
            .base_atk_speed = 950.0,
            .base_range = 32,
            .base_price = 200,
            .dimensions = attributes.Immutable.Dimensions.init(.tiny, .circle),
        },
    },
);


pub const Kind = enum(u8) {

};


pub const Attack = union {
    projectile: Projectile,
    aoe: AoE,
    none: void,

    pub const Projectile = struct {
        position: raylib.Vector2,
        trajectory: Trajectory,
        damage: f32,
        pierce: u32,
        speed_linear: f32,
        speed_angular: f32,
        aoe_on_hit_radius: f32,
        extra: Extra,

        pub const Extra = packed struct(u32) {
            kind: Projectile.Kind,
            effect_kind: interactions.Effect.Kind = .none,
            damage_kind: interactions.Damage,
            special_trajectory: bool = false,
        };

        pub const Trajectory = union {
            /// Targets a fixed point
            straight: raylib.Vector2,
            /// Targets a moving position (e.g. of a `Goon`)
            seeking: *raylib.Vector2,
            /// Special trajectory, e.g. a curve.
            special: *anyopaque,
        };


        pub inline fn seekingRadius(projectile: *Projectile) f32 {
            return (projectile.speed_linear / projectile.speed_angular) * (180.0 / math.pi);
        }

        /// Determines projectile size and sprites, stored separately
        pub const Kind = enum(u8) {
            dart,
            
        };


        pub const Block = struct {
            pub const List = struct {
                
            };
        };
    };

    pub const AoE = struct {
        center: raylib.Vector2,
        radius: f32,
        damage: f32,
        pierce: u32,
        extra: Extra,

        pub const Extra = packed struct(u32) {
            effect_kind: Effect.Kind = .none,
            damage_kind: Damage,
            _1: meta.Int(.unsigned, 32-@bitSizeOf(Effect.Kind)-@bitSizeOf(Damage)),
        };
    };
};

// Apes einfach als array speichern
