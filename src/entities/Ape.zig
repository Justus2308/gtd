const std = @import("std");
const raylib = @import("raylib");
const stdx = @import("stdx");

const enums = std.enums;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const simd = std.simd;

const raymath = raylib.math;

const Allocator = mem.Allocator;
const SimdVec = stdx.SimdVec;
const ThreadPool = stdx.ThreadPool;
const Vector2 = raylib.Vector2;

const assert = std.debug.assert;

const cache_line = std.atomic.cache_line;


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
        position: Vector2,
        damage: f64,
        pierce: u32,
        extra: Extra,

        pub const kinds = enums.directEnumArray(
            Projectile.Kind,
            Projectile.Kind.Data,
            0,
            .{
                .dart = .{

                },
            },
        );

        pub const Extra = packed struct(u32) {
            kind: Projectile.Kind,
            effect_kind: interactions.Effect.Kind = .none,
            damage_kind: interactions.Damage,
            secondary_damage_kind: interactions.Damage,
        };

        pub const Trajectory = union(enum) {
            /// Targets a fixed point
            straight: Vector2,
            /// Targets a moving position (e.g. of a `Goon`)
            seeking: *Vector2,
            /// Special trajectory that requires extra calculations, e.g. a curve.
            special: *const fn (projectile: *Projectile) void,
        };

        pub inline fn seekingRadius(speed_linear: f32, speed_angular: f32) f32 {
            const radius = (speed_linear / speed_angular) * (180.0 / math.pi);
            assert(math.isNormal(radius));
            return radius;
        }

        /// Determines projectile size and sprites, stored separately
        pub const Kind = enum(u8) {
            dart,
            
            pub const Data = struct {
                /// Sprite must contain fixed part and recolorable part.
                sprite_path: []const u8,
            };
        };

        pub const List = std.MultiArrayList(Projectile);


        /// A projectile block only contains projectiles of the same type.
        pub const Block = struct {
            /// Memory used by `projectiles`, do not touch directly.
            memory: [Block.mem_size]u8 align(alignment) = undefined,
            /// Struct-of-arrays holding projectiles in this block.
            projectiles: Projectile.List,

            /// Bitmap of free slots in this block.
            is_free: BitSet,

            /// Block list that is exclusively used
            /// to store projectiles created by this block.
            linked: ?*Block.List,


            pub const capacity = 64;
            const mem_size = Projectile.List.capacityInBytes(Block.capacity);
            const alignment = @max(cache_line, @alignOf(Projectile));

            const BitSet = std.bit_set.IntegerBitSet(Projectile.Block.capacity);

            pub const Pool = std.heap.MemoryPoolAligned(Projectile.Block, Projectile.Block.alignment);
            const RefList = std.DoublyLinkedList(?*Projectile.Block);

            pub const List = struct {
                pool: Projectile.Block.Pool,
                ref_list: Projectile.Block.RefList,
                shared: Projectile.Block.Shared,

                pub fn init(
                    allocator: Allocator,
                    shared: Projectile.Block.Shared,
                    attack_speed: f32,
                    projectiles_per_attack: u32,
                ) Allocator.Error!Projectile.Block.List {
                    const fps: u32 = @intCast(raylib.getFPS());
                    const init_block_count =
                        Projectile.Block.List.estimateRequiredBlockCount(fps, attack_speed, projectiles_per_attack);
                    const pool = try Projectile.Block.Pool.initPreheated(allocator, init_block_count);
                    return .{
                        .pool = pool,
                        .ref_list = .{},
                        .shared = shared,
                    };
                }

                pub fn estimateRequiredMemInBytes(fps: u32, attack_speed: f32, projectiles_per_attack: u32) usize {
                    const required_block_count = Projectile.Block.List.estimateRequiredBlockCount(fps);
                    return required_block_count * @sizeOf(Projectile.Block);
                }
                fn estimateRequiredBlockCount(fps: u32, attack_speed: f32, projectiles_per_attack: u32) usize {
                    const fps_fp: f32 = @floatFromInt(fps);
                    // 1 / (s/atk * frames/s) = 1 / (frames/atk) = atks/frame
                    const attacks_per_frame = attack_speed * fps_fp;
                    const lifespan_in_frames = fps_fp * 3.0; // TODO: find proper heuristic for this
                    const expected_projectile_count =
                        @as(usize, @intFromFloat(attacks_per_frame * lifespan_in_frames)) * projectiles_per_attack;
                    return (expected_projectile_count / Projectile.Block.capacity) + 1;
                }
            };

            pub const Shared = struct {
                kind: Projectile.Kind,
                trajectory: Projectile.Trajectory,
                speed_linear: f32,
                speed_angular: f32,
                aoe_on_hit_radius: f32,
                color: raylib.Color,

                spawn_pattern: SpawnPattern,

                pub const SpawnPattern = union(enum) {
                    none,
                    linear: u32,
                    circular: u32,
                    cone: u32,
                };
            };

            const BoolSimdVec = @Vector(Projectile.Block.capacity, bool);
            const PosSimdVec = SimdVec(Projectile.Block.capacity * 2, f32);

            pub fn spawn(
                block: *Projectile.Block,
                damage: f32,
                max_pierce: u32,
                positions: [*]Vector2,
                trajectories: [*]Projectile.Trajectory,
                count: u32,
            ) ?*Projectile.Block {
                if (block)
            }

            pub inline fn reserveFirstConsecutiveFree(block: *Projectile.Block, required: u32) ?u32 {
                const mask: Block.BitSet.MaskInt = (1 << required) - 1;
                const bits = block.is_free.mask;
                for (0..Projectile.Block.capacity-required) |i| {
                    if ((bits >> i) & mask == mask) {
                        block.is_free.setRangeValue(.{
                            .start = i,
                            .end = i+required,
                        }, false);
                        return @intCast(i);
                    }
                } else return null;
            }

            /// Assumes that all targets are normalized vectors.
            pub fn moveTowardsStraight(block: *Projectile.Block) void {
                assert(block.shared.trajectory_type == .straight);

                const positions_slice = block.projectiles.items(.position);
                const positions = PosSimdVec.fromSlice(@as([*]f32, @ptrCast(positions_slice.ptr))[0..PosSimdVec.len]);

                const targets_slice = block.projectiles.items(.trajectory);
                const targets = PosSimdVec.fromSlice(@as([*]f32, @ptrCast(targets_slice.ptr))[0..PosSimdVec.len]);

                const delta: PosSimdVec = (targets.vector - positions.vector);
            }
        };
    };

    pub const AoE = struct {
        center: Vector2,
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
