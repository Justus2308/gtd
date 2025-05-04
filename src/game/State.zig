gpa: Allocator,

goon_block_allocator: stdx.ChunkAllocator(.{
    .chunk_size = Goon.Block.size,
    .allocation_granularity = (Goon.Block.size << 2),
    .thread_safe = true,
}),
/// Used to lock the list for operations modifying its nodes.
goon_blocks_cur_lock: std.Thread.Mutex,
/// Chunks of current frame.
goon_blocks_cur: Goon.Block.List,
/// Chunks from last frame
goon_blocks_old: Goon.Block.List,
/// Persistend immutable chunk state
goon_immut_chunks: Goon.Immutable.List,

const std = @import("std");
const stdx = @import("stdx");
const entities = @import("entities.zig");
const Allocator = std.mem.Allocator;
const Ape = entities.Ape;
const Goon = entities.Goon;
