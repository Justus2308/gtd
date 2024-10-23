const std = @import("std");
const raylib = @import("raylib");
const entities = @import("entities");

const math = std.math;
const mem = std.mem;
const simd = std.simd;

const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;

const Ape = entities.Ape;
const Goon = entities.Goon;
const Effect = entities.Effect;
const Map = @import("Map.zig");
const Round = @import("Round.zig");


// game state
allocator: Allocator,
arena: ArenaAllocator,

map: *Map,
background: raylib.Texture2D,

difficulty: Difficulty,
mode: Mode,

round: u64,
hp: f64,
shield: f64,
pops: f64,
cash: f64,

scaling: Scaling,

rounds: []Round,
winning_round: u64,

goon_immutable_ptr: *const Goon.Immutable.List,

// persistent data
apes: Ape.Mutable.List,
effects: Effect.List,

// per-round and volatile data
goon_blocks: Goon.Block.List,
projectile_blocks: Ape.Attack.Projectile.Block.List,
aoe_buffer: Ape.Attack.AoE.Buffer,

// volatile data that needs to be moved to
// persistent data at the end of every round
extra_apes: Ape.Mutable.List,
extra_effects: Effect.List,



const State = @This();


// prd <-> per-round data
pub const base_prd_size = 512;

pub fn create(allocator: Allocator, mode: Mode, difficulty: Difficulty) Allocator.Error!*State {
    const state = allocator.create(State);
    errdefer allocator.destroy(state);

    state.* = .{
        .rounds = if (mode == .alternate) Round.alternate else Round.normal,
        .winning_round = switch (difficulty) {
            .easy => 40,
            .normal => 60,
            .hard => if (mode == .chimps) 100 else 80,
            .impoppable => 100,
        },
    };
}

/// The `State` returned by this should be allocated on the stack.
pub fn init(
    allocator: Allocator,
    map: *const Map,
    mode: Mode,
    difficulty: Difficulty,
) Allocator.Error!State {
    assert(mode != .chimps or difficulty == .hard);
    const arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    return State{
        .allocator = allocator,

        .map = map,
        .background = raylib.loadTextureFromImage(map.background),

        .round = switch (difficulty) {
            .easy, .normal => 1,
            .hard => if (mode == .chimps) 6 else 3,
            .impoppable => 6,
        },
        .hp = if (mode == .chimps) 1 else 100,
        .shield = if (mode == .chimps) 0 else 25,
        .pops = 0,
        .cash = switch (difficulty) {
            // ...
        },

        .scaling = .{},

        .rounds = if (mode == .alternate) Round.alternate else Round.normal,
        .winning_round = switch (difficulty) {
            .easy => 40,
            .normal => 60,
            .hard => if (mode == .chimps) 100 else 80,
            .impoppable => 100,
        },

        .goon_immutable_ptr = &Goon.immutable_earlygame,

        .apes = Ape.Mutable.List.empty,
        .goon_blocks = Goon.Block.List.init(arena.allocator(), ),
    };
}


pub fn initRound(state: *State, round_id: u64) Allocator.Error!void {
    const round = state.rounds[round_id-1];

    // Estimate how many goons need to be created this round to calculate how much memory is required.
    const goon_count = round.estimateGoonCount();
    const goon_blocks_needed = math.divCeil(usize, goon_count, Goon.Block.capacity) catch unreachable;
    const goon_mem_needed = @sizeOf(Goon.Block) * goon_blocks_needed;

    const ape_count = state.apes.len;
    const ape_mem_needed = mem.alignForward(usize, (@sizeOf(Ape.Mutable) * ape_count) + mem.page_size/4, mem.page_size);

    const effect_count = state.effects.items.len;
    const effect_mem_needed = mem.alignForward(usize, (@sizeOf(Effect) * effect_count) + mem.page_size/4, mem.page_size);

    const persistent_estimate = ape_mem_needed + effect_mem_needed;
    const per_round_estimate = goon_mem_needed;

    state.goon_blocks.reset(.{ .free_all = {} });
    state.arena;


    state.round = round_id;
    state.scaleHp();
    state.scaleSpeed();
    state.scaleStatus();
    state.scaleCash();

    if (round >= Round.lategame_start) {
        state.goon_immutable_ptr = &Goon.immutable_lategame;
    }
}


/// Embed an `extra_allocation.Node` as a field into an extra allocation.
/// Access your data via `@fieldParentPtr`.
pub const extra_allocation = struct {
    pub const List = std.SinglyLinkedList(extra_allocation.DataTag);
    pub const Node = List.Node;

    /// To access the actual `type` this encodes use `DataType([DataTag])`.
    pub const DataTag = enum(usize) {
        // per-round
        goon_block,
        projectile_block,
        aoe,

        // persistent
        ape,
        effect,
    };

    pub fn create(
        allocator: Allocator,
        comptime data_tag: extra_allocation.DataTag,
        data: DataType(data_tag)
    ) *extra_allocation.Node {
        const ExtraAllocation = extra_allocation.Type(data_tag);
        const extra_alloc = try allocator.create(ExtraAllocation);
        extra_alloc.data = data;
        return extra_alloc.node;
    }

    pub fn Type(comptime data_tag: extra_allocation.DataTag) type {
        return struct {
            node: extra_allocation.Node = .{ .data = data_tag },
            data: Data,

            pub const Data = DataType(data_tag);
        };
    }
    fn DataType(comptime data_tag: extra_allocation.DataTag) type {
        return switch (data_tag) {
            .goon_block => *Goon.Block,
            .projectile_block => *Ape.Attack.Projectile.Block,
            .aoe => Ape.Attack.AoE,

            .ape => Ape.Mutable,
            .effect => Effect,
        };
    }
};

fn consumeExtraAllocations(state: *State) Allocator.Error!void {
    var current = state.extra_allocs.first;
    while (current) |node| : (current = node.next) {
        switch (node.data) {
            .goon_block,
            .projectile_block,
            .aoe,
            => {}, // per-round data, will be discarded by arena reset

            .ape => {
                const full: *extra_allocation.Type(.ape) = @fieldParentPtr("node", node);
                try state.apes.append(state.allocator, full.data);
            },
            .effect => {
                const full: *extra_allocation.Type(.effect) = @fieldParentPtr("node", node);
                try state.effects.append(state.allocator, full.data);
            }
        }
    }
    // we don't need to do anything else since all the memory we just 
    // traversed is inside our arena which we will reset soon.
}


/// !!! DEPRECATED !!!
/// Basically a makeshift VLA with a couple of fixed sizes.
/// I am absolutely positive that this is best practice,
/// you should definitely copy this for your own project!
pub const extra_allocation2 = struct {
    pub const Type = enum(usize) {
        /// For internal use.
        dummy,

        // per-round
        goon_block,
        projectile_block,
        aoe,

        // persistent
        ape,
        effect,
    };
    pub fn CreateType(comptime data_type: extra_allocation2.Type) type {
        return extern struct {
            type: extra_allocation.Type = data_type,
            next: ?*anyopaque = null,
            data: Data,

            pub const Data = DataType(data_type);
        };
    }
    fn DataType(comptime data_type: extra_allocation2.Type) type {
        return switch (data_type) {
            .dummy => void,

            .goon_block => *Goon.Block,
            .projectile_block => *Ape.Attack.Projectile.Block,
            .aoe => Ape.Attack.AoE,

            .ape => Ape.Mutable,
            .effect => Effect,
        };
    }

    pub fn create(
        allocator: Allocator,
        comptime data_type: extra_allocation2.Type,
        data: DataType(data_type),
    ) Allocator.Error!*anyopaque {
        const T = CreateType(data_type);
        const ptr = try allocator.create(T);
        ptr.data = data;
        return ptr;
    }

    // We can do this because the field order is fixed (`extern`).
    pub inline fn getNext(node: *anyopaque) ?*anyopaque {
        const not_a_dummy: *extra_allocation2.CreateType(.dummy) = @ptrCast(@alignCast(node));
        assert(not_a_dummy.type != .dummy);
        return not_a_dummy.next;
    }
    pub inline fn setNext(node: *anyopaque, next: ?*anyopaque) void {
        const not_a_dummy: *extra_allocation2.CreateType(.dummy) = @ptrCast(@alignCast(node));
        assert(not_a_dummy.type != .dummy);
        not_a_dummy.next = next;
    }

    pub fn insert(head: *?*anyopaque, node: *anyopaque) void {
        if (head.*) |h| {
            var current = h;
            while (extra_allocation2.getNext(current)) |next| : (current = next) {}
            extra_allocation2.setNext(current, node);
        } else {
            head.* = node;
        }
    }
};

/// !!! DEPRECATED !!!
/// This will free all extra allocations.
/// Their data will either be discarded or moved to the appropriate place.
/// This operation may result in an expansion of the persistent data segment.
fn consumeExtraAllocations2(state: *State) Allocator.Error!void {
    var current = state.extra_allocs;
    while (current) |curr| : (current = extra_allocation2.getNext(curr)) {
        const not_a_dummy: *extra_allocation2.CreateType(.dummy) = @ptrCast(@alignCast(curr));
        switch (not_a_dummy.type) {
            .dummy => unreachable,

            .goon_block,
            .projectile_block,
            .aoe,
            => {}, // per-round data, will be discarded by arena reset

            // We need to commit some C-style crimes...
            .ape => {
                const ape_ptr: *Ape = @ptrCast(@alignCast(&not_a_dummy.data));
                state.apes.append(state.allocator, ape_ptr.*);
            },
            .effect => {
                const effect_ptr: *Effect = @ptrCast(@alignCast(&not_a_dummy.data));
                state.effects.append(state.allocator, effect_ptr.*);
            }
        }
    }
    // we don't need to do anything else since all the memory we just 
    // traversed is inside our arena which we will reset soon.
}


pub const Scaling = struct {
    hp: f64 = 1.0,
    speed: f32 = 1.0,
    status: f32 = 1.0,
    cash: f64 = 1.0,
};
fn scaleHp(state: *State) void {
    const step: f64 = switch (state.round) {
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
    state.scaling.hp += step;
}
fn scaleSpeed(state: *State) void {
    const step: f32 = switch (state.round) {
        0...80 => return,
        101 => 0.2,
        151 => 0.42,
        201 => 0.52,
        252 => 0.5,
        else => 0.02,
    };
    state.scaling.speed += step;
}
fn scaleStatus(state: *State) void {
    const step: f32 = switch (state.round) {
        150, 200, 250, 300, 350 => 0.10,
        else => return,
    };
    state.scaling.status -= step;
}
fn scaleCash(state: *State) void {
    const abs: f64 = switch (state.round) {
        51 => 0.50,
        61 => 0.20,
        86 => 0.10,
        101 => 0.05,
        121 => 0.02,
        else => return,
    };
    state.scaling.cash = abs;
}


pub const Difficulty = enum {
    easy,
    normal,
    hard,
    impoppable,
};
pub const Mode = enum {
    standard,
    alternate,
    chimps,
};



pub const SpawnApeOptions = struct {
    upgrades: Ape.Mutable.Upgrades = .{},
    vtable: *Ape.Mutable.VTable = Ape.Mutable.vtable_passive,
};
pub fn spawnApe(
    state: *State,
    id: u32,
    position: raylib.Vector2,
    kind: Ape.Kind,
    options: SpawnApeOptions,
) Ape {

}




pub const SpawnGoonOptions = struct {
    color: Goon.attributes.Mutable.Color = .none,
    extra: Goon.attributes.Mutable.Extra = .{},
};
pub fn spawnGoon(
    state: *State,
    mutable_attr_list: *Goon.MutableAttributeTable,
    id: u32,
    position: raylib.Vector2,
    kind: Goon.Kind,
    options: SpawnGoonOptions,
) Goon {
    assert(kind != .normal or options.color != .none);
    assert(kind != .ddt or (options.extra.camo and options.extra.regrow));
    assert(state.round >= 81 or kind != .super_ceramic);

    const immutable = Goon.getImmutable(kind);

    const base_speed: f32 = @floatFromInt(immutable.base.speed + Goon.base_speed_offset_table.get(kind));

    const hp = immutable.base.hp * state.scaling.hp;
    const speed = base_speed * state.scaling.speed;

    const mutable = Goon.attributes.Mutable{
        .position = position,
        .hp = hp,
        .speed = speed,
        .kind = kind,
        .color = options.color,
        .extra = options.extra,
    };
    mutable_attr_list.set(id, mutable);

    return Goon{ .id = id };
}


pub fn create2(allocator: Allocator, map: *Map, difficulty: Difficulty, mode: Mode) Allocator.Error!*State {
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);

    const goon_mutable_attr_lists = try GoonMutableAttrList.initCapacity(allocator, 1);
    errdefer goon_mutable_attr_lists.deinit(allocator);

    state.* = State{
        .allocator = allocator,

        .map = map,
        .background = raylib.loadTextureFromImage(map.background),

        .difficulty = difficulty,
        .mode = mode,

        .round = 0,
        .pops = 0,
        .cash = 0,

        .scaling = .{},

        .goon_mutable_attr_lists = goon_mutable_attr_lists,
    };

    const window_scale_factor = raylib.getWindowScaleDPI();
    // state.background.drawEx(.{ 0, 0 }, 0.0, scale: f32, tint: Color);
}

pub fn destroy(state: *State) void {
    state.allocator.destroy(state);
    state.* = undefined;
}


pub fn updateGoonBlock2(state: *State, block: *Goon.Block) void {
    const batch_size = simd.suggestVectorLength(f64) orelse 1;
    const VecF64 = @Vector(batch_size, f64);

    const used = block.used();

    var i: u32 = 0;
    while (i < used) : (i += batch_size) {
        if (batch_size > 1) {
            const slice = block.mutable_attr_list.slice();
            const vec: VecF64 = slice.items(.hp)[i..][0..batch_size];

        } else {

        }
    }
}

pub const TaskCtx = struct {
    state: *State,
    task: Task,
};
pub fn initTask(state: *State, comptime function: Task.callbackFn) TaskCtx {
    return .{
        .state = state,
        .task = .{
            .next = null,
            .callback = function,
        },
    };
}

pub fn updateGoonBlock(task: *Task) void {
    const ctx: *TaskCtx = @fieldParentPtr("task", task);
}



// REIHENFOLGE
// liste von möglichen statuseffekten führen
// immer wenn affe geupgraded/platziert wird liste updaten
// für jeden goon liste mit statuseffekten führen, jwls pointer auf effekt und timestamp
// jeden statetick schauen ob irgendein statuseffekt ausgeführt werden muss (vllt effektpointer einfach auf null)
// einfach in array unterbringen der so lang ist wie anzahl v mögl statuseffekten
// ist nie besonders lang also einfach nach nächstem slot bei dem effekt null ist suchen
// ODER: jedem effekt einen index zuweisen (vllt besser)

// Pass 1: Hintergrund rendern, scaling anwenden, Affenangriffe auswerten,
//         Goons zerstören/neue spawnen, Statuseffekte aktualisieren, Cash+Pops aktualisieren
// Pass 2: Affen rendern
// Pass 3: Goonpositionen aktualisieren, Projektilpositionen aktualisieren, Goons rendern
// Pass 4: Projektile rendern, Statuseffekte rendern, sonstige Effekte rendern (first come first serve)

// CONCURRENCY LAYOUT
// Main thread: macht alle raylib calls (weil OpenGL nur single threaded funktioniert)
// und startet+beendet spiele, runden usw. ; macht wait-calls an thread pool
// Thread pool:
// für goons: jeder block wird einem thread zugewiesen

// goon block dependeny chain:
// rundenstart -> projektilpositionen/aoe updaten
// geupdatete projektilpositionen/aoe (nach collisions checken, effekte updaten) -> mutable updaten
// geupdatete mutables -> rendern


// MEMORY LAYOUT
// heap:
// [ State ] [ persistent data ] [ per-round data ] [ volatile data ]
// -> wie stack behandeln um fragmentation zu vermeiden
// Um layout zu erhalten:
// - State wird als erstes geallocated und als letztes gefreed (oder auf stack erstellt?)
// - memory für per-round data wird danach in arena allocated (mit best guess wie viel mem nötig ist)
// - prd arena wird zu beginn einer runde ggf erweitert wenn erwartet wird dass mehr benötigt wird
// - falls mehr als geplant benötigt wird wird mem während runde aus arena (von backing allocator)
//   geallocated und am ende der runde als erstes wieder gefreed
// - prd arena wird gecleared und auf erwartete prd grösse für nächste runde geshrinkt

// allocators:
// allocator ist page_allocator
// arena ist von allocator gebackt

// stack: state
// allocator: persistent data
// arena: per-round data, volatile data

// persistent data: apes, effects
//     Besteht über mehrere runden hinweg. Kann sich verändern, aber nicht unbedingt jede runde.

// per-round data: goons, attacks
//     Ist auf eine runde beschränkt, Größe ist im vorraus schon ungefähr bekannt.
//     Wird zu Beginn jeder Runde invalidated.

// volatile data: ggf. regrow goons, ggf. projectiles
//     "slow path" für per-round data
//     Alles, was über geschätzte Größe v. prd hinausgeht -> arena muss backing allocator benutzen.
//     -> möglichst vermeiden durch gute Abschätzungen und prd garbage collection

// POP QUIZ: dürfen diese pointer während einer runde invalidated werden (durch realloc o.ä.)?
// Goons?       -> Positionen werden als target für seeking projectiles benutzt, also: NEIN!
// Apes?        -> Alles was von apes gespawned wird hat keine back references, goons sind apes sowieso egal,
//                 also: JA!
// Projectiles? -> kommt drauf an, wenn pointer nicht invalidated werden dann concurrency vllt besser
//                 da: projectiles können gleichzeitig gespawned und geupdated werden, also: NEIN!
// Effects?     -> ka

// ALSO:

// Goons:
// werden blockweise allocated, blocks haben fixe größe und werden wenn dann komplett gefreed
// das einzige was hier hin und wieder reallocated wird ist die ref_list auf die blocks das ist aber
// egal weil die nur für lookups von goon ids benutzt wird. Die goon mutable data selber ist stabil.

// Apes:
// werden in arraylist geallocated, passt schon weil is ja egal

// Projectiles:
// Eigentlich genau so wie bei goons
