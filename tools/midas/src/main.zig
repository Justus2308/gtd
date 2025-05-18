const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.midas);

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer assert(debug_allocator.deinit() == .ok);
    const gpa = debug_allocator.allocator();

    const stdout = std.io.getStdOut();
    const writer = stdout.writer();

    var parsed_args = parseArgs(gpa, writer) catch |err| {
        log.err("failed to parse args: {s}", .{@errorName(err)});
        return err;
    };
    defer parsed_args.deinit();

    std.debug.print("{any}\n", .{parsed_args});
}

const ParsedArgs = struct {
    arena: std.heap.ArenaAllocator,
    inputs: []const [:0]const u8,
    output: ?[:0]const u8,

    pub const Flag = enum {
        @"-i",
        @"-o",
        @"-H",
        @"-V",
        @"--",
    };

    pub const Option = enum {
        help,
        version,
        verbose,

        pub const Map = std.StaticStringMap(Option).initComptime(kvs: {
            var tuples: [@typeInfo(Option).@"enum".fields.len]struct { []const u8, Option } = undefined;
            for (std.enums.values(Option), &tuples) |option, *tuple| {
                tuple.* = .{ @tagName(option), option };
            }
            break :kvs tuples;
        });
    };

    pub fn deinit(parsed_args: *ParsedArgs) void {
        parsed_args.arena.deinit();
        parsed_args.* = undefined;
    }
};

fn parseArgs(allocator: Allocator, writer: anytype) !ParsedArgs {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    assert(std.mem.endsWith(u8, args.next().?, "midas"));

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();

    var inputs = try std.ArrayListUnmanaged([:0]const u8).initCapacity(arena_allocator, 8);
    var output: ?[:0]const u8 = null;

    while (args.next()) |arg| {
        if (arg.len < 2) {
            log.err("encountered invalid argument '{s}'", .{arg});
            return error.InvalidArg;
        }
        const flag = std.meta.stringToEnum(ParsedArgs.Flag, arg[0..2]) orelse {
            log.err("encountered invalid flag '{s}' in argument '{s}'", .{ arg[0..2], arg });
            return error.InvalidFlag;
        };
        const body = arg[2..];
        sw: switch (flag) {
            .@"-H" => try printHelpAndExit(writer),
            .@"-V" => try printVersionAndExit(writer),
            .@"-i" => {
                const value = try parseArgValue(body, &args);
                const duped = try arena_allocator.dupeZ(u8, value);
                try inputs.append(arena_allocator, duped);
            },
            .@"-o" => {
                if (output != null) return error.MultipleOutputs;
                const value = try parseArgValue(body, &args);
                output = try arena_allocator.dupeZ(u8, value);
            },
            .@"--" => switch (try parseArgOption(body)) {
                .help => continue :sw .@"-H",
                .version => continue :sw .@"-V",
                .verbose => {},
            },
        }
    }

    if (inputs.items.len == 0) return error.MissingInputs;

    return .{
        .arena = arena,
        .inputs = try inputs.toOwnedSlice(arena_allocator),
        .output = output,
    };
}

fn parseArgValue(body: [:0]const u8, args: *std.process.ArgIterator) ![:0]const u8 {
    const value: [:0]const u8 = if (body.len == 0)
        args.next() orelse &.{}
    else if (body[0] == '=')
        body[1..]
    else
        body;

    return if (value.len == 0) error.MissingArgValue else value;
}

fn parseArgOption(body: [:0]const u8) !ParsedArgs.Option {
    return ParsedArgs.Option.Map.get(body) orelse {
        log.err("invalid option encountered: '--{s}'", .{body});
        return error.InvalidOption;
    };
}

fn printVersionAndExit(writer: anytype) !noreturn {
    const version_string = @import("build.zig.zon").version;
    try writer.print("{s}\n", .{version_string});
    std.process.exit(0);
}

fn printHelpAndExit(writer: anytype) !noreturn {
    const help_string = "not helpful...\n";
    try writer.writeAll(help_string);
    std.process.exit(0);
}
