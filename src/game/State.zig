goon_block_allocator: stdx.ChunkAllocator(.{ .chunk_size = Goon.Block.size }),
/// Chunks of current frame.
goon_blocks_cur: Goon.Block.List,
/// Chunks from last frame
goon_blocks_old: Goon.Block.List,
/// Persistend immutable chunk state
goon_immut_chunks: Goon.Immutable.List,

goon_effect_set_allocator: stdx.concurrent.MemoryPool(Goon.Effect.Set, .{}),
goon_effect_sets: Goon.Effect.Set.List,

const std = @import("std");
const stdx = @import("stdx");
const entities = @import("entities.zig");
const Ape = entities.Ape;
const Goon = entities.Goon;
