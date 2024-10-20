const std = @import("std");
const raylib = @import("raylib");
const entities = @import("entities");

const math = std.math;
const mem = std.mem;
const simd = std.simd;

const Allocator = mem.Allocator;

const assert = std.debug.assert;

const Ape = entities.Ape;
const Goon = entities.Goon;
const Effect = entities.Effect;
const Map = @import("Map.zig");
const Round = @import("Round.zig");


allocator: Allocator,

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

apes: Ape.Mutable.List,
goon_blocks: Goon.Block.List,
effects: Effect.List,


const State = @This();


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


pub fn initRound(state: *State, round_id: u64) Allocator.Error!void {
    const round = state.rounds[round_id-1];

    // Estimate how many goons need to be created this round to calculate how much memory is required.
    const goon_count: usize = blk: {
        var count = 0;
        for (round.waves) |wave| {
            const immutable = Goon.getImmutable(wave.goon_template.kind);
            const child_count = if (round_id <= 80) immutable.child_count else immutable.child_count_lategame;
            count += (wave.count * (1 + child_count + @intFromBool(wave.goon_template.extra.regrow)));
        }
        break :blk count;
    };
    const blocks_needed = math.divCeil(usize, goon_count, Goon.Block.capacity) catch unreachable;
    state.goon_blocks.reset(.{ .reset_with_limit = (blocks_needed * @sizeOf(Goon.Block)) });


    state.round = round_id;
    state.scaleHp();
    state.scaleSpeed();
    state.scaleStatus();
    state.scaleCash();
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


pub fn create(allocator: Allocator, map: *Map, difficulty: Difficulty, mode: Mode) Allocator.Error!*State {
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
