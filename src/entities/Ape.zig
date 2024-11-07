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
        trajectory: Projectile.Trajectory,
        damage: f64,
        pierce: u32,
        lifetime: f32, // TODO implement
        extra: Projectile.Extra,

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

        pub const Trajectory = union {
            /// Doesn't move at all.
            static: void,
            /// Targets a fixed point.
            straight: Vector2,
            /// Targets a moving position (e.g. of a `Goon`).
            seeking: *Vector2,
            /// Trajectory that requires special calculations, e.g. a curve.
            special: *const fn (projectile: *Projectile) void,

            pub const Type = enum {
                straight,
                seeking,
                special,
            };
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
            const RefList = std.ArrayList(?*Projectile.Block);

            pub const List = struct {
                pool: Projectile.Block.Pool,
                ref_list: Projectile.Block.RefList,
                shared: Projectile.Block.Shared,
                current_block_idx: u32,


                pub fn init(
                    allocator: Allocator,
                    shared: Projectile.Block.Shared,
                    attack_speed: f32,
                    projectiles_per_attack: u32,
                ) Allocator.Error!Projectile.Block.List {
                    const fps: u32 = @intCast(raylib.getFPS());
                    const init_block_count =
                        Projectile.Block.List.estimateRequiredBlockCount(fps, attack_speed, projectiles_per_attack);

                    const ref_list = try Projectile.Block.RefList.initCapacity(allocator, init_block_count);
                    errdefer ref_list.deinit();

                    var pool = Projectile.Block.Pool.init(allocator);
                    errdefer pool.deinit();

                    for (ref_list.items) |*ref| {
                        ref.* = try pool.create();
                    }

                    return .{
                        .pool = pool,
                        .ref_list = ref_list,
                        .shared = shared,
                        .current_block_idx = 0,
                    };
                }

                pub fn deinit(list: *Projectile.Block.List) void {
                    list.pool.deinit();
                    list.ref_list.deinit();
                    list.* = undefined;
                }

                pub fn estimateRequiredMemInBytes(fps: u32, attack_speed: f32, projectiles_per_attack: u32) usize {
                    const required_block_count = Projectile.Block.List.estimateRequiredBlockCount(fps, attack_speed, projectiles_per_attack);
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

                pub fn spawn(
                    list: *Projectile.Block.List,
                    damage: f64,
                    max_pierce: u32,
                    positions: [*]Vector2,
                    trajectories: [*]Vector2,
                    count: usize,
                ) usize {
                    var spawned: usize = if (list.getCurrentBlock()) |current_block| blk: {
                        @branchHint(.likely);
                        break :blk current_block.spawn(damage, max_pierce, positions, trajectories, count);
                    } else 0;
                    while (spawned < count) {
                        @branchHint(.unlikely);
                        const new_block = list.createBlock(true) catch return spawned;
                        spawned += new_block.spawn(damage, max_pierce, positions[spawned..], trajectories[spawned..], count-spawned);
                    }
                    return count;
                }

                pub fn spawnOrFail(
                    list: *Projectile.Block.List,
                    damage: f64,
                    max_pierce: u32,
                    positions: [*]Vector2,
                    trajectories: [*]Vector2,
                    count: usize,
                ) Allocator.Error!void {
                    if (list.spawn(damage, max_pierce, positions, trajectories, count) != count) {
                        return Allocator.Error.OutOfMemory;
                    }
                }

                inline fn getCurrentBlock(list: *Projectile.Block.List) ?*Block {
                    return list.ref_list.items[list.current_block_idx];
                }

                fn createBlock(list: *Projectile.Block.List, is_new_current_block: bool) Allocator.Error!*Block {
                    const block = try list.pool.create();
                    errdefer list.pool.destroy(block);

                    try list.ref_list.append(block);
                    if (is_new_current_block) {
                        list.current_block_idx = list.ref_list.items.len-1;
                    }
                    return block;
                }
            };

            pub const Shared = struct {
                kind: Projectile.Kind,
                trajectory_type: Projectile.Trajectory.Type,
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
                    custom: struct {
                        *const Projectile.Block.Shared.spawnFn,
                    },
                };

                pub const spawnFn = fn (list: *Projectile.Block.List, damage: f64, max_pierce: u32, origin_pos: Vector2) usize;
            };

            const BoolSimdVec = @Vector(Projectile.Block.capacity, bool);
            const PosSimdVec = SimdVec(Projectile.Block.capacity * 2, f32);

            pub fn spawn(
                block: *Projectile.Block,
                damage: f32,
                max_pierce: u32,
                positions: [*]Vector2,
                trajectories: [*]Vector2,
                count: usize,
            ) usize {
                for (0..count) |i| {
                    const ok = block.spawnOne(damage, max_pierce, positions[i], trajectories[i]);
                    if (!ok) {
                        @branchHint(.cold);
                        return i;
                    }
                }
                return count;
            }

            pub inline fn spawnOne(
                block: *Projectile.Block,
                damage: f32,
                max_pierce: u32,
                position: Vector2,
                trajectory: Vector2,
            ) bool {
                const next_free_idx = block.is_free.toggleFirstSet() orelse {
                    @branchHint(.cold);
                    return false;
                };
                block.projectiles.set(next_free_idx, Projectile{
                    .position = position,
                    .trajectory = trajectory,
                    .damage = damage,
                    .pierce = max_pierce,
                    .extra = .{},
                });
                return true;
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

            inline fn hasNFree(block: *Projectile.Block, n: u32) bool {
                return (block.is_free.count() >= n);
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
