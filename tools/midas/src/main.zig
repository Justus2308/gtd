const builtin = @import("builtin");
const std = @import("std");
const img = @import("img.zig");
const mesh = @import("mesh.zig");
const pack = @import("pack.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const log = std.log.scoped(.midas);

var global_opts: struct {
    is_verbose: bool = false,
    is_dry_run: bool = false,
} = .{};

pub inline fn isVerbose() bool {
    return global_opts.is_verbose;
}

pub inline fn isDryRun() bool {
    return global_opts.is_dry_run;
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer assert(debug_allocator.deinit() == .ok);
    const gpa = debug_allocator.allocator();

    var parsed_args = parseArgs(gpa) catch |err| {
        log.err("failed to parse args: {s}", .{@errorName(err)});
        return err;
    };
    defer parsed_args.deinit(gpa);

    const command_opts = parsed_args.command_opts;
    const inputs = parsed_args.inputs;
    const outputs = parsed_args.outputs;

    if (isVerbose()) {
        log.info("global options: {}", .{std.json.fmt(global_opts, .{})});
        log.info("command: {s}", .{@tagName(command_opts)});
        switch (command_opts) {
            inline else => |payload| if (@TypeOf(payload) != void) {
                log.info("command options: {}", .{std.json.fmt(payload, .{})});
            },
        }
        log.info("inputs: {}", .{std.json.fmt(inputs, .{})});
        log.info("outputs: {}", .{std.json.fmt(outputs, .{})});
    }

    if (command_opts.activeTag() == .img) {
        const in_file = try std.fs.cwd().openFile(inputs[0], .{ .mode = .read_only });
        defer in_file.close();
        assert(img.isConvertible(in_file));
    }

    switch (command_opts.activeTag()) {
        inline .img, .mesh => |command| {
            const opts = @field(command_opts, @tagName(command));
            for (inputs, outputs) |in_path, out_path| {
                try convertSingle(command, opts, gpa, in_path, out_path);
                if (isVerbose()) {
                    log.info("converted from {s} to {s}", .{ in_path, out_path });
                }
            }
        },
        .pack => {},
        .help => unreachable,
    }
}

fn convertSingle(
    comptime command: ParsedArgs.Command,
    opts: @FieldType(ParsedArgs.Command.Options, @tagName(command)),
    allocator: Allocator,
    in_path: [:0]const u8,
    out_path: [:0]const u8,
) !void {
    const in_file = try std.fs.cwd().openFile(in_path, .{ .mode = .read_only });
    defer in_file.close();

    const bytes = try in_file.readToEndAlloc(allocator, (4 << 10 << 10));
    defer allocator.free(bytes);

    const converted = switch (command) {
        .img => try img.convert(bytes, opts),
        .mesh => try mesh.convert(bytes, opts),
        .pack, .help => unreachable,
    };
    defer switch (command) {
        .img => img.freeConverted(converted),
        .mesh => mesh.freeConverted(converted),
        .pack, .help => unreachable,
    };

    if (isDryRun() == false) {
        const out_file = try std.fs.cwd().createFile(out_path, .{
            .read = false,
            .truncate = true,
        });
        defer out_file.close();

        var buf_writer = std.io.bufferedWriter(out_file.writer());
        const writer = buf_writer.writer();
        try writer.writeAll(converted);
        try buf_writer.flush();
    }
}

fn convertMany(
    comptime command: ParsedArgs.Command,
    opts: @FieldType(ParsedArgs.Command.Options, @tagName(command)),
    allocator: Allocator,
    in_paths: []const [:0]const u8,
    out_path: [:0]const u8,
) !void {
    _ = .{ opts, allocator, in_paths, out_path };
}

const ParsedArgs = struct {
    arena_state: std.heap.ArenaAllocator.State,
    command_opts: Command.Options,
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

        const output_file_extension = std.enums.EnumFieldStruct(Command, [:0]const u8, null){
            .img = ".qoi",
            .mesh = ".zon",
            .pack = ".midaspack",
            .help = undefined,
        };

        pub fn outputFileExtension(command: Command) [:0]const u8 {
            return switch (command) {
                .help => unreachable,
                inline else => |cmd| @field(output_file_extension, @tagName(cmd)),
            };
        }

        pub const Options = union(Command) {
            img,
            mesh,
            pack: pack.Options,
            help,

            pub fn activeTag(opts: Command.Options) Command {
                return std.meta.activeTag(opts);
            }

            pub fn defaultInit(command: Command) Command.Options {
                return switch (command) {
                    inline .img, .mesh, .help => |cmd| @unionInit(Command.Options, @tagName(cmd), {}),
                    inline .pack => |cmd| @unionInit(Command.Options, @tagName(cmd), .{}),
                };
            }
        };
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
        semver,
        verbose,
        @"dry-run",
        uncompressed,

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
fn parseArgs(allocator: Allocator) !ParsedArgs {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    assert(std.mem.endsWith(u8, args.next().?, "midas"));

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();

    var command_opts: ?ParsedArgs.Command.Options = null;
    var inputs = try std.ArrayListUnmanaged([:0]const u8).initCapacity(arena_allocator, 8);
    var outputs = try std.ArrayListUnmanaged([:0]const u8).initCapacity(arena_allocator, 8);

    loop: while (args.next()) |arg| {
        if (arg.len >= 2) {
            if (std.meta.stringToEnum(ParsedArgs.Flag, arg[0..2])) |flag| {
                const body = arg[2..];
                sw: switch (flag) {
                    .@"-h", .@"-H" => try printHelpAndExit(command_opts),
                    .@"-v", .@"-V" => try printVersionAndExit(),
                    .@"-o" => {
                        if (command_opts) |opts| {
                            const value = try parseArgValue(body, &args);
                            const extension = opts.activeTag().outputFileExtension();
                            const output = if (std.mem.eql(u8, extension, std.fs.path.extension(value)))
                                try arena_allocator.dupeZ(u8, value)
                            else
                                try std.mem.concatWithSentinel(arena_allocator, u8, &.{ value, extension }, 0);
                            try outputs.append(arena_allocator, output);
                        } else {
                            log.err("encountered command option before command: '{s}'", .{arg});
                            return error.InvalidCommandOptionPosition;
                        }
                    },
                    .@"--" => switch (try parseArgOption(body)) {
                        .help => continue :sw .@"-h",
                        .version => continue :sw .@"-v",
                        .semver => try printSemVerAndExit(),
                        .verbose => global_opts.is_verbose = true,
                        .@"dry-run" => global_opts.is_dry_run = true,
                        .uncompressed => {
                            if (command_opts) |opts| {
                                if (opts.activeTag() == .pack) {
                                    command_opts.?.pack.is_uncompressed = true;
                                } else {
                                    log.warn("ignoring command option '{s}'", .{arg});
                                }
                            } else {
                                log.err("encountered command option before command: '{s}'", .{arg});
                                return error.InvalidCommandOptionPosition;
                            }
                        },
                    },
                }
                continue :loop;
            }
        }
        if (ParsedArgs.Command.map.get(arg)) |cmd| {
            switch (cmd) {
                .help => try printHelpAndExit(command_opts),
                else => {
                    if (inputs.items.len != 0) {
                        log.err("encountered command after inputs: {s}", .{arg});
                        return error.InvalidCommandPosition;
                    }
                    if (command_opts != null) return error.ClashingCommands;
                    command_opts = .defaultInit(cmd);
                },
            }
            continue :loop;
        }
        if (command_opts != null) {
            const duped = try arena_allocator.dupeZ(u8, arg);
            try inputs.append(arena_allocator, duped);
            continue :loop;
        }
        log.err("encountered invalid argument '{s}'", .{arg});
        return error.InvalidArg;
    }

    const command_opts_resolved = command_opts orelse return error.MissingCommand;

    if (inputs.items.len == 0) return error.MissingInputs;
    if (outputs.items.len > inputs.items.len or (command_opts_resolved.activeTag() == .pack and outputs.items.len > 1))
        return error.TooManyOutputs;

    const inputs_resolved = try inputs.toOwnedSlice(arena_allocator);

    if (command_opts_resolved.activeTag() == .pack) {
        if (outputs.items.len == 0) {
            const extension = comptime ParsedArgs.Command.pack.outputFileExtension();
            const output = try ensureFileExtension(arena_allocator, extension, inputs_resolved[0]);
            try outputs.append(arena_allocator, output);
        }
        assert(outputs.items.len == 1);
    } else if (inputs_resolved.len > outputs.items.len) {
        const extension = command_opts_resolved.activeTag().outputFileExtension();
        for (inputs_resolved[outputs.items.len..inputs_resolved.len]) |input| {
            const output = try ensureFileExtension(arena_allocator, extension, input);
            try outputs.append(arena_allocator, output);
        }
    }

    const outputs_resolved = try outputs.toOwnedSlice(arena_allocator);

    assert(inputs_resolved.len == outputs_resolved.len or (command_opts_resolved.activeTag() == .pack and outputs_resolved.len == 1));

    return .{
        .arena_state = arena.state,
        .command_opts = command_opts_resolved,
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

fn printAndExit(string: []const u8) !noreturn {
    const stdout = std.io.getStdOut();
    var buf_writer = std.io.bufferedWriter(stdout.writer());
    const writer = buf_writer.writer();
    try writer.writeAll(string);
    try buf_writer.flush();
    std.process.exit(0);
}

fn printVersionAndExit() !noreturn {
    try printAndExit("midas " ++ version_string ++ "\n");
}

fn printSemVerAndExit() !noreturn {
    try printAndExit(semver_string ++ "\n");
}

fn printHelpAndExit(command_opts: ?ParsedArgs.Command.Options) !noreturn {
    try printAndExit(switch (command_opts orelse .help) {
        .img => img_help_string,
        .mesh => mesh_help_string,
        .pack => pack_help_string,
        .help => global_help_string,
    });
}

const semver_string = @import("build.zig.zon").version;
comptime {
    assert(std.meta.isError(std.SemanticVersion.parse(semver_string)) == false);
}

const version_string =
    "v" ++ semver_string ++
    " " ++ @tagName(builtin.target.os.tag) ++
    "/" ++ @tagName(builtin.target.cpu.arch);

const global_help_string =
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
    \\    --verbose           Enable verbose logging
    \\    --dry-run           Ensure that all inputs are valid but do not produce any output
    \\    --help, -h, -H      Show this message
    \\    --version, -V, -v   Print the installed version
    \\    --semver            Print the installed version as a clean semantic version
    \\
;

const img_help_string =
    \\NAME:
    \\    midas img - Convert images to QOI
    \\
    \\USAGE:
    \\    midas [global options] img [command options] <file> ...
    \\
    \\OPTIONS:
    \\    -o <file>           Provide a custom output location
    \\    --help, -h, -H      Show this message
    \\    
    \\GLOBAL OPTIONS:
    \\    --verbose           Enable verbose logging
    \\    --dry-run           Ensure that all inputs are valid but do not produce any output
    \\
;

const mesh_help_string =
    \\NAME:
    \\    midas mesh - Convert glTF meshes to a custom format
    \\
    \\USAGE:
    \\    midas [global options] mesh [command options] <file> ...
    \\
    \\OPTIONS:
    \\    -o <file>           Provide a custom output location
    \\    --help, -h, -H      Show this message
    \\    
    \\GLOBAL OPTIONS:
    \\    --verbose           Enable verbose logging
    \\    --dry-run           Ensure that all inputs are valid but do not produce any output
    \\
;

const pack_help_string =
    \\NAME:
    \\    midas pack - Pack multiple assets into one blob
    \\
    \\USAGE:
    \\    midas [global options] pack [command options] {<file>|<directory>} ...
    \\
    \\OPTIONS:
    \\    -o <file>           Provide a custom output location
    \\    --uncompressed      Disable packed data compression
    \\    --help, -h, -H      Show this message
    \\    
    \\GLOBAL OPTIONS:
    \\    --verbose           Enable verbose logging
    \\    --dry-run           Ensure that all inputs are valid but do not produce any output
    \\
;
