//! Handles in-game entities and their interactions.

pub const Ape = @import("entities/Ape.zig");
pub const Goon = @import("entities/Goon.zig");

const interactions = @import("entities/interactions.zig");
pub const Damage = interactions.Damage;
pub const Effect = interactions.Effect;
pub const CollisionMap = interactions.CollisionMap;
