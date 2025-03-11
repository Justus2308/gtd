name: []const u8,
vertices: Vertex.List.Slice,
indices: []u32,

const Obj = @This();

// TODO move to geo module
pub const Vertex = struct {
    position: Vec3,
    uv: Vec2,
    normal: Vec3,

    pub const List = std.MultiArrayList(Vertex);
};

const Parsed = struct {
    name: []const u8,
    positions: std.ArrayListUnmanaged(Vec3) = .empty,
    uv: std.ArrayListUnmanaged(Vec2) = .empty,
    normals: std.ArrayListUnmanaged(Vec3) = .empty,

    /// maps `Index` structs parsed directly from .obj faces
    /// to indices in vertex list
    index_to_vertex: std.AutoHashMapUnmanaged(Index, u32) = .empty,
    vertices: Vertex.List = .empty,
    indices: std.ArrayListUnmanaged(u32) = .empty,

    section: Section = .vertices,

    pub const Index = struct {
        position: u32,
        uv: u32,
        normal: u32,
    };
    pub const Section = enum { vertices, faces };

    pub fn deinit(parsed: *Parsed, allocator: Allocator) void {
        allocator.free(parsed.name);
        parsed.positions.deinit(allocator);
        parsed.uv.deinit(allocator);
        parsed.normals.deinit(allocator);
        parsed.index_to_vertex.deinit(allocator);
        parsed.vertices.deinit(allocator);
        parsed.indices.deinit(allocator);
        parsed.* = undefined;
    }

    pub fn toObj(parsed: *Parsed, allocator: Allocator) Allocator.Error!Obj {
        parsed.positions.deinit(allocator);
        parsed.uv.deinit(allocator);
        parsed.normals.deinit(allocator);
        parsed.index_to_vertex.deinit(allocator);

        const name = parsed.name;
        const vertices = parsed.vertices.toOwnedSlice();
        const indices = try parsed.indices.toOwnedSlice(allocator);

        parsed.* = undefined;
        return Obj{
            .name = name,
            .vertices = vertices,
            .indices = indices,
        };
    }
};

pub const ParseError = std.fs.File.OpenError || std.fs.File.ReadError || Allocator.Error || error{ Malformed, Unsupported, StreamTooLong };

pub fn parse(allocator: Allocator, file: std.fs.File) ParseError![]Obj {
    @setFloatMode(.strict); // preserve NaN floats

    var objs = std.StringHashMapUnmanaged(Parsed).empty;
    defer objs.deinit(allocator);
    errdefer {
        var iter = objs.valueIterator();
        while (iter.next()) |parsed| {
            parsed.deinit(allocator);
        }
    }

    var buffered_reader = std.io.bufferedReader(file.reader());
    const r = buffered_reader.reader();

    var prefix_buf: [6]u8 = undefined;
    var line_buf: [1024]u8 = undefined;
    var parsed: ?*Parsed = null;
    while (r.readUntilDelimiterOrEof(&prefix_buf, ' ') catch |err| switch (err) {
        .StreamTooLong => return ParseError.Malformed,
        else => return err,
    }) |read| {
        if (read.len == 0) {
            return ParseError.Malformed;
        }
        sw: switch (read[0]) {
            '#' => {
                try r.skipUntilDelimiterOrEof('\n');
                continue;
            },
            'm' => {
                if (!mem.eql(u8, "mg", read)) {
                    try Obj.verifyEql("mtllib", read);
                }
                continue :sw '#';
            },
            'u' => {
                if (parsed == null) {
                    return ParseError.Malformed;
                }
                try Obj.verifyEql("usemtl", read);
                continue :sw '#';
            },
            'o', 'g' => |tag| {
                if (read.len != 1) {
                    return ParseError.Malformed;
                }
                const name_quoted = try r.readUntilDelimiterOrEof(&line_buf, '\n');
                if (name_quoted[0] != '"' or name_quoted[name_quoted.len - 1] != '"') {
                    return ParseError.Malformed;
                }
                const name = name_quoted[1..(name_quoted.len - 1)];
                if (objs.getPtr(name)) |existing| switch (tag) {
                    // Having two objects with the same name is
                    // not supported by this parser
                    'o' => return ParseError.Unsupported,
                    // Group data is merged (https://github.com/Twinklebear/tobj/issues/15#issue-493994182)
                    'g' => parsed = existing,
                    else => unreachable,
                } else {
                    const new = Parsed{ .name = try allocator.dupe(u8, name) };
                    try objs.putNoClobber(allocator, name, new);
                    parsed = objs.getPtr(name).?;
                }
            },
            's' => {
                const p = parsed orelse return ParseError.Malformed;
                if (p.section != .faces) return ParseError.Malformed;
                const val = try r.readUntilDelimiterOrEof(&line_buf, '\n');
                // TODO: interpolate normals according to smoothing
                if (!mem.eql(u8, "off", val)) return ParseError.Unsupported;
            },
            'v' => {
                const p = parsed orelse return ParseError.Malformed;
                if (p.section != .vertices) return ParseError.Malformed;
                const data = try r.readUntilDelimiterOrEof(&line_buf, '\n');
                var split = mem.splitScalar(u8, data, ' ');
                var i: usize = 0;
                var vals: [3]f32 = undefined;
                while (split.next()) |raw| : (i += 1) {
                    if (i == vals.len) {
                        return ParseError.Malformed;
                    }
                    vals[i] = std.fmt.parseFloat(f32, raw) catch return ParseError.Malformed;
                }
                if (read.len == 1) {
                    if (i != 3) return ParseError.Malformed;
                    const position = Vec3{ vals[0], vals[1], vals[2] };
                    try p.positions.append(allocator, position);
                } else if (read.len == 2) switch (read[1]) {
                    't' => {
                        if (i != 2) return ParseError.Malformed;
                        const uv_coord = Vec2{ vals[0], vals[1] };
                        try p.uv.append(allocator, uv_coord);
                    },
                    'n' => {
                        if (i != 3) return ParseError.Malformed;
                        const normal = Vec3{ vals[0], vals[1], vals[2] };
                        try p.normals.append(allocator, normal);
                    },
                    else => return ParseError.Malformed,
                } else return ParseError.Malformed;
            },
            'f' => {
                const p = parsed orelse return ParseError.Malformed;
                p.section = .faces;
                if (read.len != 1) {
                    return ParseError.Malformed;
                }
                const data = try r.readUntilDelimiterOrEof(&line_buf, '\n');
                var split = mem.splitScalar(u8, data, ' ');

                var i: usize = 0;
                while (split.next()) |raw| : (i += 1) {
                    var vals = mem.splitScalar(u8, raw, '/');
                    const position_idx = if (vals.next()) |val|
                        std.fmt.parseInt(u32, val, 10) catch return ParseError.Malformed
                    else
                        return ParseError.Malformed;
                    const uv_idx: ?u32 = if (vals.next()) |val|
                        std.fmt.parseInt(u32, val, 10) catch return ParseError.Malformed
                    else
                        null;
                    const normal_idx: ?u32 = if (vals.next()) |val|
                        std.fmt.parseInt(u32, val, 10) catch return ParseError.Malformed
                    else
                        null;
                    if (vals.peek() != null) {
                        return ParseError.Malformed;
                    }
                    const index = Parsed.Index{
                        .position = position_idx,
                        .uv = uv_idx,
                        .normal = normal_idx,
                    };
                    const vertex_gop = try p.index_to_vertex.getOrPut(allocator, index);
                    const vertex_idx = if (vertex_gop.found_existing)
                        vertex_gop.value_ptr.*
                    else blk: {
                        // obj indices are 1-based
                        const vertex = Vertex{
                            .position = p.positions.items[index.position - 1],
                            .uv = p.uv.items[index.uv - 1],
                            .normal = p.normals.items[index.normal - 1],
                        };
                        try p.vertices.append(allocator, vertex);
                        const vertex_idx = (p.vertices.len - 1);
                        vertex_gop.value_ptr.* = vertex_idx;
                        break :blk vertex_idx;
                    };
                    try p.indices.append(allocator, vertex_idx);
                }
                if (i != 3) return ParseError.Malformed;
            },
            else => return ParseError.Malformed,
        }
    }

    const res = try allocator.alloc(Obj, objs.size);
    errdefer allocator.free(res);

    var i: usize = 0;
    var iter = objs.valueIterator();
    errdefer for (res[0..i]) |*obj| {
        obj.deinit(allocator);
    };
    while (iter.next()) |p| : (i += 1) {
        assert(p.indices.len % 3 == 0);
        res[i] = try p.toObj(allocator);
    }
    assert(i == res.len);
    return res;
}

inline fn verifyEql(expected: []const u8, actual: []const u8) ParseError!void {
    if (!mem.eql(u8, expected, actual)) {
        return ParseError.Malformed;
    }
}

pub fn deinit(obj: *Obj, allocator: Allocator) void {
    allocator.free(obj.name);
    obj.vertices.deinit(allocator);
    allocator.free(obj.indices);
    obj.* = undefined;
}

const std = @import("std");
const geo = @import("geo");

const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;

const vec2 = geo.linalg.v2f32;
const Vec2 = vec2.V;

const vec3 = geo.linalg.v3f32;
const Vec3 = vec3.V;

const assert = std.debug.assert;

// tests

fn testPrintObj(obj: Obj) void {
    assert(@import("builtin").is_test);
    std.debug.print("name={s}\n", .{obj.name});
    std.debug.print("vertices:\n", .{});
    for (0..obj.vertices.len) |i| {
        const vertex = obj.vertices.get(i);
        std.debug.print("{any}\n", .{vertex});
    }
    std.debug.print("indices:\n", .{});
    var i: usize = 0;
    while (i < obj.indices.len) : (i += 3) {
        std.debug.print("{d}, {d}, {d}\n", .{
            obj.indices[i + 0],
            obj.indices[i + 1],
            obj.indices[i + 2],
        });
    }
    assert(i == obj.indices.len);
    std.debug.print("----------------------------\n", .{});
}

test parse {
    const cwd = std.fs.cwd();
    const obj_dir = cwd.openDir("test/obj", .{ .iterate = true }) catch
        return error.SkipZigTest;

    std.debug.print("===== parse .obj files =====\n", .{});

    var iter = obj_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and mem.endsWith(u8, entry.name, ".obj")) {
            const obj_file = try obj_dir.openFile(entry.name, .{ .mode = .read_only, .lock = .exclusive });
            defer obj_file.close();

            std.debug.print("----- parse {s}:", .{entry.name});

            const objs = Obj.parse(testing.allocator, obj_file);
            for (objs) |obj| {
                testPrintObj(obj);
                obj.deinit(testing.allocator);
            }
        }
    }
    std.debug.print("============================\n", .{});
}
