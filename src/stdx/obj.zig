const std = @import("std");
const stdx = @import("stdx");
const geo = @import("geo");

const mem = std.mem;

const Allocator = mem.Allocator;

const vec2 = geo.linalg.v2f32;
const Vec2 = vec2.V;

const vec3 = geo.linalg.v3f32;
const Vec3 = vec3.V;

const assert = std.debug.assert;

pub const Obj = struct {
    name: []const u8,
    vertices: Vertex.List,
    indices: []u32,

    pub const Vertex = struct {
        position: Vec3,
        uv: Vec2,
        normal: Vec3,

        pub const List = stdx.StaticMultiArrayList(Vertex);
    };

    const Parsed = struct {
        name: []const u8,
        positions: std.ArrayListUnmanaged(Vec3) = .empty,
        uv: std.ArrayListUnmanaged(Vec2) = .empty,
        normals: std.ArrayListUnmanaged(Vec3) = .empty,
        indices: std.ArrayListUnmanaged(u32) = .empty,

        pub fn deinit(parsed: *Parsed, allocator: Allocator) void {
            allocator.free(parsed.name);
            parsed.positions.deinit(allocator);
            parsed.uv.deinit(allocator);
            parsed.normals.deinit(allocator);
            parsed.indices.deinit(allocator);
            parsed.* = undefined;
        }

        pub fn toObj(parsed: *Parsed, allocator: Allocator) (ParseError.Malformed || Allocator.Error)!Obj {
            if (parsed.positions.len != parsed.uv.len or parsed.uv.len != parsed.normals.len) {
                return ParseError.Malformed;
            }

            const name = parsed.name;

            const required_size = Vertex.List.requiredByteSize(parsed.positions.len);
            const buffer = try allocator.alignedAlloc(u8, @alignOf(Vertex), required_size);
            var vertices = Vertex.List.init(buffer);

            @memcpy(vertices.items(.position), parsed.positions.items);
            @memcpy(vertices.items(.uv), parsed.uv.items);
            @memcpy(vertices.items(.normal), parsed.normals.items);

            parsed.positions.deinit(allocator);
            parsed.uv.deinit(allocator);
            parsed.normals.deinit(allocator);

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

    pub fn parse(allocator: Allocator, path: [:0]const u8) []Obj {
        var objs = std.StringHashMapUnmanaged(Parsed).empty;
        defer objs.deinit(allocator);
        errdefer {
            var iter = objs.valueIterator();
            while (iter.next()) |parsed| {
                parsed.deinit(allocator);
            }
        }

        const f = try std.fs.openFileAbsoluteZ(path, .{ .mode = .read_only, .lock = .exclusive });
        var buffered_reader = std.io.bufferedReader(f.reader());
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
                    const val = try r.readUntilDelimiterOrEof(&line_buf, '\n');
                    // TODO: interpolate normals according to smoothing
                    if (!mem.eql(u8, "off", val)) return ParseError.Unsupported;
                },
                'v' => {
                    const p = parsed orelse return ParseError.Malformed;
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
                    if (read.len != 1) {
                        return ParseError.Malformed;
                    }
                    const data = try r.readUntilDelimiterOrEof(&line_buf, '\n');
                    var split = mem.splitScalar(u8, data, ' ');

                    var i: usize = 0;
                    while (split.next()) |raw| : (i += 1) {
                        if (i == 3) {
                            return ParseError.Malformed;
                        }
                        const end = mem.indexOfScalar(u8, raw, '/') orelse raw.len;
                        const index = std.fmt.parseInt(u32, raw[0..end], 10) catch return ParseError.Malformed;
                        try p.indices.append(allocator, index);
                    }
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
        allocator.free(obj.vertices.bytes);
        allocator.free(obj.indices);
        obj.* = undefined;
    }
};
