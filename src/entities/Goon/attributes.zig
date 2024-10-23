const std = @import("std");
const raylib = @import("raylib");
const entities = @import("entities");

const enums = std.enums;
const math = std.math;
const mem = std.mem;
const meta = std.meta;

const Goon = entities.Goon;
const Kind = Goon.Kind;

const Damage = entities.Damage;
const Effect = entities.Effect;

const assert = std.debug.assert;


pub const Immutable = extern struct {
    base_hp: f16,
    base_speed: f16,

    child_count: u16,
    children: Children,

    rbe: u16,

    extra: Extra,

    comptime {
        // depending on architecture 1-2 of these should fit into a single cache line
        assert(mem.isAligned(@sizeOf(Immutable), std.atomic.cache_line));
    }

    pub const Children = blk: {
        const Base = enums.EnumFieldStruct(Kind, u4, 0);
        var info = @typeInfo(Base).@"struct";
        info.layout = .@"packed";
        info.backing_integer = u64;
        for (info.fields) |*field| {
            field.alignment = 0;
        }
        break :blk @Type(.{ .@"struct" = info });
    };

    pub const Extra = packed struct(u32) {
        fortified_factor: f16 = 2.0,
        immunity: Damage = .{},
        size: Size,
        inherits_fortified: bool = false,
    };

    pub const Size = enum(u1) {
        /// for small goons, spritesheet includes overlays for all extras
        small,
        /// for large goons, spritesheet only includes extra `fortified` overlay
        large,
    };

    pub const List = [enums.directEnumArrayLen(Kind, 0)]Immutable;

    pub const Template = struct {
        base_hp: f16,
        base_speed: f16,

        child_count: u16,
        child_count_lategame: u16,

        children: Children,
        children_lategame: Children,

        rbe: u16,
        rbe_lategame: u16,

        extra: Extra,

        pub const Config = struct {
            base_hp: f16,
            base_speed: f16,
            children: Immutable.Children,
            children_lategame: Immutable.Children,
            size: Immutable.Size,

            immunity: Damage = .{},
            fortified_factor: u8 = 2,
            inherits_fortified: bool = false,
        };

        pub fn countChildren(immutable: *Immutable, comptime lategame: bool) u16 {
            var count: u16 = 0;
            const children = if (lategame) immutable.children_lategame else immutable.children;
            for (meta.fields(Immutable.Children)) |field| {
                const n = @field(children, field.name);
                if (n > 0) {
                    const child_kind = meta.stringToEnum(Kind, field.name).?;
                    const child = Goon.getImmutable(child_kind);
                    count += n * (1 + (if (lategame) child.child_count_lategame else child.child_count));
                }
            }
            return count;
        }
        pub fn countRbe(immutable: *Immutable, comptime lategame: bool) u32 {
            var rbe: u32 = immutable.base_hp;
            const children = if (lategame) immutable.children_lategame else immutable.children;
            for (meta.fields(Immutable.Children)) |field| {
                const n = @field(children, field.name);
                if (n > 0) {
                    const child_kind = meta.stringToEnum(Kind, field.name).?;
                    const child = Goon.getImmutable(child_kind);
                    rbe += n * (if (lategame) child.rbe_lategame else child.rbe);
                }
            }
            return rbe;
        }

        pub fn resolve(
            comptime templates: *const [enums.directEnumArrayLen(Kind, 0)]Immutable.Template,
            comptime lategame: bool,
        ) *const Immutable.List {
            var resolved: Immutable.List = undefined;
            for (0..templates.len) |i| {
                const t = templates[i];
                resolved[i] = if (lategame) .{
                    .base_hp = t.base_hp,
                    .base_speed = t.base_speed,

                    .child_count = t.child_count_lategame,
                    .children = t.children_lategame,
                    .rbe = t.rbe_lategame,

                    .extra = t.extra,
                } else .{
                    .base_hp = t.base_hp,
                    .base_speed = t.base_speed,

                    .child_count = t.child_count,
                    .children = t.children,
                    .rbe = t.rbe,

                    .extra = t.extra,
                };
            }
            return &resolved;
        }
    };

    pub fn makeTemplate(comptime config: Immutable.Template.Config) Immutable.Template {
        var template: Immutable.Template = undefined;
        template.base_hp = config.base_hp;
        template.base_speed = config.base_speed;
        template.children = config.children;
        template.children_lategame = config.children_lategame;
        template.extra.size = config.size;

        template.extra.immunity = config.immunity;
        template.extra.fortified_factor = config.fortified_factor;
        template.extra.inherits_fortified = config.inherits_fortified;

        template.child_count = comptime template.countChildren(false);
        template.child_count_lategame = comptime template.countChildren(true);

        template.rbe = comptime template.countRbe(false);
        template.rbe_lategame = comptime template.countRbe(true);

        return template;
    }
};

pub const Mutable = struct {
    position: raylib.Vector2,
    hp: f64,
    speed: f32,
    kind: Kind,
    color: Color,
    extra: Extra,


    pub const List = std.MultiArrayList(Mutable);


    pub const Color = enum(u4) {
        none = 0,
        red,
        blue,
        green,
        yellow,
        pink,
    };

    pub const Extra = packed struct(u4) {
        camo: bool,
        fortified: bool,
        regrow: bool,

        is_regrown: bool = false,
    };

    pub const AppliedEffect = extern struct {
        effect: *Effect,
        /// time elapsed since application in seconds
        time_elapsed: f64,
    };
};


pub const Template = packed struct(u16) {
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

    pub inline fn resolve(
        template: Template,
        position: raylib.Vector2,
        hp_scaling: f64,
        speed_scaling: f32,
    ) Mutable {
        const immutable = Goon.getImmutable(template.kind);
        const real_base_hp: f16 = if (template.extra.fortified)
            immutable.base_hp * immutable.extra.fortified_factor
        else
            immutable.base_hp;
        return Mutable{
            .position = position,
            .hp = hp_scaling * @as(u64, @floatCast(real_base_hp)),
            .speed = speed_scaling * @as(u32, @floatCast(immutable.base_speed)),
            .kind = template.kind,
            .color = template.color,
            .extra = template.extra,
        };
    }
};
