const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const log = std.log.scoped(.midas);

// global options
var is_verbose = false;

pub inline fn isVerbose() bool {
    return is_verbose;
}

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
    defer parsed_args.deinit(gpa);

    const command = parsed_args.command;
    const inputs = parsed_args.inputs;
    const outputs = parsed_args.outputs;

    if (isVerbose()) {
        const inputs_string = try std.mem.join(gpa, ", ", inputs);
        defer gpa.free(inputs_string);
        const outputs_string = try std.mem.join(gpa, ", ", outputs);
        defer gpa.free(outputs_string);

        log.info("command: {s}", .{@tagName(command)});
        log.info("inputs: {s}", .{inputs_string});
        log.info("outputs: {s}", .{outputs_string});
    }
}

const ParsedArgs = struct {
    arena_state: std.heap.ArenaAllocator.State,
    command: Command,
    inputs: []const [:0]const u8,
    outputs: []const [:0]const u8,

    pub const Command = enum {
        img,
        mesh,
        pack,
        help,

        pub const map = std.StaticStringMap(Command).initComptime(kvs: {
            const commands = std.enums.values(Command);
            var tuples: [2 * commands.len]struct { []const u8, Command } = undefined;
            for (commands, 0..) |command, i| {
                const str = @tagName(command);
                tuples[(2 * i) + 0] = .{ str, command };
                tuples[(2 * i) + 1] = .{ str[0..1], command };
            }
            break :kvs tuples;
        });

        pub fn outFileExtension(command: Command) [:0]const u8 {
            return switch (command) {
                .img => ".qoi",
                .mesh => ".zon",
                .pack => ".midaspack",
                .help => unreachable,
            };
        }
    };

    pub const Flag = enum {
        @"-o",
        @"-h",
        @"-H",
        @"-v",
        @"-V",
        @"--",
    };

    pub const Option = enum {
        help,
        version,
        verbose,

        pub const map = std.StaticStringMap(Option).initComptime(kvs: {
            const options = std.enums.values(Option);
            var tuples: [options.len]struct { []const u8, Option } = undefined;
            for (options, &tuples) |option, *tuple| {
                tuple.* = .{ @tagName(option), option };
            }
            break :kvs tuples;
        });
    };

    pub fn deinit(parsed_args: *ParsedArgs, allocator: Allocator) void {
        parsed_args.arena_state.promote(allocator).deinit();
        parsed_args.* = undefined;
    }
};

/// May have side effects on global options.
fn parseArgs(allocator: Allocator, writer: anytype) !ParsedArgs {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    assert(std.mem.endsWith(u8, args.next().?, "midas"));

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();

    var command: ?ParsedArgs.Command = null;
    var inputs = try std.ArrayListUnmanaged([:0]const u8).initCapacity(arena_allocator, 8);
    var outputs = try std.ArrayListUnmanaged([:0]const u8).initCapacity(arena_allocator, 8);

    loop: while (args.next()) |arg| {
        if (arg.len >= 2) {
            if (std.meta.stringToEnum(ParsedArgs.Flag, arg[0..2])) |flag| {
                const body = arg[2..];
                sw: switch (flag) {
                    .@"-h", .@"-H" => try printHelpAndExit(writer, command),
                    .@"-v", .@"-V" => try printVersionAndExit(writer),
                    .@"-o" => {
                        if (command) |cmd| {
                            const value = try parseArgValue(body, &args);
                            const extension = cmd.outFileExtension();
                            const output = if (std.mem.eql(u8, extension, std.fs.path.extension(value)))
                                try arena_allocator.dupeZ(u8, value)
                            else
                                try std.mem.concatWithSentinel(arena_allocator, u8, &.{ value, extension }, 0);
                            try outputs.append(arena_allocator, output);
                        } else {
                            log.err("encountered command option before command: {s}", .{arg});
                            return error.InvalidCommandOptionPosition;
                        }
                    },
                    .@"--" => switch (try parseArgOption(body)) {
                        .help => continue :sw .@"-h",
                        .version => continue :sw .@"-v",
                        .verbose => is_verbose = true,
                    },
                }
                continue :loop;
            }
        }
        if (ParsedArgs.Command.map.get(arg)) |cmd| {
            switch (cmd) {
                .help => try printHelpAndExit(writer, command),
                else => {
                    if (inputs.items.len != 0) {
                        log.err("encountered command after inputs: {s}", .{arg});
                        return error.InvalidCommandPosition;
                    }
                    if (command != null) return error.ClashingCommands;
                    command = cmd;
                },
            }
            continue :loop;
        }
        if (command != null) {
            const duped = try arena_allocator.dupeZ(u8, arg);
            try inputs.append(arena_allocator, duped);
            continue :loop;
        }
        log.err("encountered invalid argument '{s}'", .{arg});
        return error.InvalidArg;
    }

    const command_resolved = command orelse return error.MissingCommand;

    if (inputs.items.len == 0) return error.MissingInputs;
    if (outputs.items.len > inputs.items.len or (command_resolved == .pack and outputs.items.len > 1))
        return error.TooManyOutputs;

    const inputs_resolved = try inputs.toOwnedSlice(arena_allocator);

    if (command_resolved == .pack) {
        if (outputs.items.len == 0) {
            const extension = ParsedArgs.Command.pack.outFileExtension();
            const output = try ensureFileExtension(arena_allocator, extension, inputs_resolved[0]);
            try outputs.append(arena_allocator, output);
        }
        assert(outputs.items.len == 1);
    } else if (inputs_resolved.len > outputs.items.len) {
        const extension = command_resolved.outFileExtension();
        for (inputs_resolved[outputs.items.len..inputs_resolved.len]) |input| {
            const output = try ensureFileExtension(arena_allocator, extension, input);
            try outputs.append(arena_allocator, output);
        }
    }

    const outputs_resolved = try outputs.toOwnedSlice(arena_allocator);

    assert(inputs_resolved.len == outputs_resolved.len or (command_resolved == .pack and outputs_resolved.len == 1));

    return .{
        .arena_state = arena.state,
        .command = command_resolved,
        .inputs = inputs_resolved,
        .outputs = outputs_resolved,
    };
}

fn ensureFileExtension(allocator: Allocator, extension: [:0]const u8, path: [:0]const u8) Allocator.Error![:0]const u8 {
    // TODO find a better solution for this
    const path_without_extension_len = (@intFromPtr(std.fs.path.extension(path).ptr) - @intFromPtr(path.ptr));
    const path_without_extension = path[0..path_without_extension_len];
    const result = try std.mem.concatWithSentinel(allocator, u8, &.{ path_without_extension, extension }, 0);
    return result;
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
    return ParsedArgs.Option.map.get(body) orelse {
        log.err("invalid option encountered: '--{s}'", .{body});
        return error.InvalidOption;
    };
}

const version_string =
    "v" ++ @import("build.zig.zon").version ++
    " " ++ @tagName(builtin.target.os.tag) ++
    "/" ++ @tagName(builtin.target.cpu.arch);

fn printVersionAndExit(writer: anytype) !noreturn {
    const version_string_ext = "midas version " ++ version_string ++ "\n";
    try writer.writeAll(version_string_ext);
    std.process.exit(0);
}

fn printHelpAndExit(writer: anytype, command: ?ParsedArgs.Command) !noreturn {
    switch (command orelse .help) {
        .img => try printImgHelpAndExit(writer),
        .mesh => try printMeshHelpAndExit(writer),
        .pack => try printPackHelpAndExit(writer),
        .help => try printGlobalHelpAndExit(writer),
    }
}

fn printGlobalHelpAndExit(writer: anytype) !noreturn {
    const help_string =
        \\NAME:
        \\    midas - Midas Asset Converter
        \\
        \\USAGE:
        \\    midas [global options] <command> {[command options] <input> ...|help|h}
        \\
        \\VERSION:
    ++ "\n    " ++ version_string ++ "\n" ++
        \\
        \\DESCRIPTION:
        \\    midas lets you convert gltf/png assets into formats used by GTD.
        \\
        \\COMMANDS:
        \\    img, i              Convert images to QOI
        \\    mesh, m             Convert glTF meshes to a custom format
        \\    pack, p             Pack multiple assets into one blob
        \\    help, h             Show this message or help for another command
        \\
        \\GLOBAL OPTIONS:
        \\    --verbose           Enable verbose logging (default: disabled)
        \\    --help, -h, -H      Show this message
        \\    --version, -V, -v   Print the version
    ++ "\n";
    try writer.writeAll(help_string);
    std.process.exit(0);
}

fn printImgHelpAndExit(writer: anytype) !noreturn {
    const help_string =
        \\NAME:
        \\    midas img - Convert images to QOI
        \\
        \\USAGE:
        \\    midas [global options] img [command options] <file> ...
        \\
        \\OPTIONS:
        \\    -o                  Provide a custom output location
        \\    --help, -h, -H      Show this message
        \\    
        \\GLOBAL OPTIONS:
        \\    --verbose           Enable verbose logging (default: disabled)
    ++ "\n";
    try writer.writeAll(help_string);
    std.process.exit(0);
}

fn printMeshHelpAndExit(writer: anytype) !noreturn {
    const help_string =
        \\NAME:
        \\    midas mesh - Convert glTF meshes to a custom format
        \\
        \\USAGE:
        \\    midas [global options] mesh [command options] <file> ...
        \\
        \\OPTIONS:
        \\    -o                  Provide a custom output location
        \\    --help, -h, -H      Show this message
        \\    
        \\GLOBAL OPTIONS:
        \\    --verbose           Enable verbose logging (default: disabled)
    ++ "\n";
    try writer.writeAll(help_string);
    std.process.exit(0);
}

fn printPackHelpAndExit(writer: anytype) !noreturn {
    const help_string =
        \\NAME:
        \\    midas pack - Pack multiple assets into one blob
        \\
        \\USAGE:
        \\    midas [global options] pack [command options] {<file>|<directory>} ...
        \\
        \\OPTIONS:
        \\    -o                  Provide a custom output location.
        \\    --help, -h, -H      Show this message
        \\    
        \\GLOBAL OPTIONS:
        \\    --verbose           Enable verbose logging (default: disabled)
    ++ "\n";
    try writer.writeAll(help_string);
    std.process.exit(0);
}
