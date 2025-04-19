const std = @import("std");
const stdx = @import("stdx");
const linalg = @import("geo").linalg;
const shader = @import("shader");
const sokol = @import("sokol");
const gfx = sokol.gfx;
const mem = std.mem;
const Allocator = mem.Allocator;
const Render = @import("State").Render;
const assert = std.debug.assert;

const log = std.log.scoped(.glblitz);

pub const DecodeError = Allocator.Error || std.json.Error || error{
    InvalidMagicNumber,
    UnsupportedVersion,
    InvalidChunkOrder,
    EndOfStream,
    StreamTooLong,
    ReadFailed,
    SemanticError,
    UnknownError,
    Unsupported,
};

pub fn isGlb(buffer: []const u8) bool {
    if (buffer.len < header_size) {
        return false;
    }
    const length = getLengthFromHeader(buffer[0..header_size].*) catch return false;
    return (buffer.len >= length);
}

const header_size = 12;
const glb_magic: u32 = 0x46546C67;

const chunk_alignment = 4;

pub const ChunkType = enum(u32) {
    json = 0x4E4F534A,
    bin = 0x004E4942,
    _,
};

pub fn decodeBuffer(allocator: Allocator, buffer: []const u8) DecodeError!Model {
    var stream = std.io.fixedBufferStream(buffer);
    return try decodeStream(allocator, stream.reader());
}

pub fn decodeStream(allocator: Allocator, reader: anytype) (DecodeError || @TypeOf(reader).Error)!Model {
    const total_length = total_length: {
        const bytes = try reader.readBytesNoEof(header_size);
        const total_length = getLengthFromHeader(bytes);
        break :total_length total_length;
    };

    var limited_reader = std.io.limitedReader(reader, total_length);
    const r = limited_reader.reader();

    const parsed = parsed: {
        var chunk_reader = try chunkReader(r, .json);

        var json_reader = std.json.reader(allocator, chunk_reader.reader());
        defer json_reader.deinit();

        const parsed = std.json.parseFromTokenSource(Json, allocator, &json_reader, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = true,
            .parse_numbers = true,
        }) catch |err| {
            log.err("decode: failed to parse json chunk: {s}", @errorName(err));
            return switch (err) {
                std.json.Error.SyntaxError,
                std.json.Error.UnexpectedEndOfInput,
                Allocator.Error,
                => return @errorCast(err),
                else => return DecodeError.UnknownError,
            };
        };
        try chunk_reader.skipToEnd();
        break :parsed parsed;
    };
    defer parsed.deinit();

    const data = data: {
        var chunk_reader = try chunkReader(r, .bin);

        const buffer = try allocator.alignedAlloc(u8, chunk_alignment, chunk_reader.chunk_length);
        errdefer allocator.free(buffer);

        const bytes_read = try chunk_reader.reader().readAll(buffer);
        if (bytes_read != chunk_reader.chunk_length) {
            return DecodeError.EndOfStream;
        }
        try chunk_reader.skipToEnd();
        break :data buffer;
    };
    errdefer allocator.free(data);

    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch_allocator = scratch_arena.allocator();

    var matrices = std.ArrayListUnmanaged(*const [16]f32).empty;

    var referenced_meshes = try std.DynamicBitSetUnmanaged.initEmpty(scratch_allocator, parsed.value.meshes.len);
    for (parsed.value.scenes) |scene| {
        for (scene.nodes) |node_idx| {
            if (node_idx >= parsed.value.nodes.len) {
                @branchHint(.unlikely);
                return DecodeError.SemanticError;
            }
            const node = parsed.value.nodes[node_idx];
            if (node.mesh) |mesh_idx| {
                if (mesh_idx >= parsed.value.meshes.len) {
                    @branchHint(.unlikely);
                    return DecodeError.SemanticError;
                }
                referenced_meshes.set(mesh_idx);
                try matrices.append(scratch_allocator, &node.matrix);
            }
        }
    }

    const mesh_count = referenced_meshes.count();
    const meshes = try allocator.alloc(Model.Mesh, mesh_count);
    errdefer allocator.free(meshes);

    var material_cache = std.ArrayHashMapUnmanaged(u32, Model.Material, std.hash_map.AutoContext(u32), false).empty;
    var mesh_iter = referenced_meshes.iterator();
    var i: usize = 0;
    errdefer for (0..i) |j| {
        allocator.free(meshes[j].primitives);
    };
    while (mesh_iter.next()) |mesh_idx| : (i += 1) {
        const mesh = parsed.value.meshes[mesh_idx];
        const primitives_list = try std.ArrayListUnmanaged(Model.Mesh.Primitive).initCapacity(scratch_allocator, mesh.primitives.len);
        for (mesh.primitives) |prim| {
            const pos_acc_idx = prim.attributes.map.get("POSITION") orelse continue;
            if (pos_acc_idx >= parsed.value.accessors.len) {
                @branchHint(.unlikely);
                return DecodeError.SemanticError;
            }
            const pos_acc = parsed.value.accessors[pos_acc_idx];
            if (pos_acc.type != .VEC3 or pos_acc.componentType != .FLOAT) {
                @branchHint(.unlikely);
                return DecodeError.SemanticError;
            }
            const positions = try parsed.value.getData(.VEC3, .FLOAT, data, pos_acc_idx);

            const uv_acc_idx = prim.attributes.map.get("TEXCOORD_0") orelse continue;
            if (uv_acc_idx >= parsed.value.accessors.len) {
                @branchHint(.unlikely);
                return DecodeError.SemanticError;
            }
            const uv_acc = parsed.value.accessors[uv_acc_idx];
            if (uv_acc.type != .VEC2) {
                @branchHint(.unlikely);
                return DecodeError.SemanticError;
            }
            const uv: Model.Mesh.Primitive.Uv = switch (uv_acc.componentType) {
                .FLOAT => .{ .texcoords = .{ .FLOAT2 = try parsed.value.getData(.VEC2, .FLOAT, data, uv_acc_idx) } },
                .UNSIGNED_SHORT => .{ .texcoords = .{ .USHORT2N = try parsed.value.getData(.VEC2, .UNSIGNED_SHORT, data, uv_acc_idx) } },
                .UNSIGNED_BYTE => return DecodeError.Unsupported,
                else => {
                    @branchHint(.unlikely);
                    return DecodeError.SemanticError;
                },
            };

            const indices: Model.Mesh.Primitive.Indices = if (prim.indices) |indices_acc_idx| blk: {
                if (indices_acc_idx >= parsed.value.accessors.len) {
                    @branchHint(.unlikely);
                    return DecodeError.SemanticError;
                }
                const indices_acc = parsed.value.accessors[indices_acc_idx];
                if (indices_acc.type != .SCALAR) {
                    @branchHint(.unlikely);
                    return DecodeError.SemanticError;
                }
                break :blk switch (indices_acc.componentType) {
                    .UNSIGNED_SHORT => .{ .UINT16 = parsed.value.getData(.SCALAR, .UNSIGNED_SHORT, data, indices_acc_idx) },
                    .UNSIGNED_INT => .{ .UINT32 = parsed.value.getData(.SCALAR, .UNSIGNED_INT, data, indices_acc_idx) },
                    else => {
                        @branchHint(.unlikely);
                        return DecodeError.SemanticError;
                    },
                };
            } else .NONE;

            const primitive_type: gfx.PrimitiveType = switch (prim.mode) {
                .POINTS => .POINTS,
                .LINES => .LINES,
                .LINE_STRIP => .LINE_STRIP,
                .TRIANGLES => .TRIANGLES,
                .TRIANGLE_STRIP => .TRIANGLE_STRIP,
                .TRIANGLE_FAN => return DecodeError.Unsupported,
            };

            const material_index: ?u32 = if (prim.material) |mat_idx| index: {
                if (mat_idx >= parsed.value.materials.len) {
                    @branchHint(.unlikely);
                    return DecodeError.SemanticError;
                }
                const mat = parsed.value.materials[mat_idx];
                const gop = try material_cache.getOrPut(allocator, mat_idx);
                if (!gop.found_existing) {
                    const material = Model.Material{
                        .texture_handle = 0, // TODO
                        .alpha_mode = switch (mat.alphaMode) {
                            .OPAQUE => .none,
                            .BLEND => .blend,
                            .MASK => .{ .mask = mat.alphaCutoff },
                        },
                        .cull_mode = if (mat.doubleSided) .NONE else .BACK,
                    };
                    gop.value_ptr.* = material;
                }
                break :index @intCast(gop.index);
            } else null;

            const primitive = Model.Mesh.Primitive{
                .positions = positions,
                .uv = uv,
                .indices = indices,
                .type = primitive_type,
                .material_index = material_index,
            };
            try primitives_list.append(scratch_allocator, primitive);
        }
        const primitives_cloned = try primitives_list.clone(allocator);
        const primitives = try primitives_cloned.toOwnedSlice(allocator);
        meshes[i] = Model.Mesh{
            .matrix = matrices.items[i].*,
            .primitives = primitives,
        };
    }
    const materials = try allocator.dupe(Model.Material, material_cache.values());
    errdefer allocator.free(materials);

    const model = Model{
        .meshes = meshes,
        .materials = materials,
        .data = data,
    };
    return model;
}

fn getLengthFromHeader(bytes: [header_size]u8) DecodeError!u32 {
    const magic = mem.readInt(u32, bytes[0..4], .little);
    if (magic != glb_magic) {
        return DecodeError.InvalidMagicNumber;
    }
    const version = mem.readInt(u32, bytes[4..8], .little);
    if (version != 2) {
        return DecodeError.UnsupportedVersion;
    }
    const length = mem.readInt(u32, bytes[8..12], .little);
    return length;
}

fn ChunkReader(comptime ReaderType: type) type {
    return struct {
        limited_reader: std.io.LimitedReader(ReaderType),
        chunk_length: u32,

        pub const Error = ReaderType.Error;
        pub const Reader = std.io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn read(self: *Self, dest: []u8) Error!usize {
            return self.limited_reader.read(dest);
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        pub fn skipToEnd(self: *Self) Error!void {
            try self.limited_reader.reader().skipBytes(self.limited_reader.bytes_left, .{});
        }
    };
}
fn chunkReader(
    inner_reader: anytype,
    expected_type: ChunkType,
) (@TypeOf(inner_reader).Error || DecodeError)!ChunkReader(@TypeOf(inner_reader)) {
    const bytes = try inner_reader.readBytesNoEof(2 * @sizeOf(u32));
    const chunk_type: ChunkType = @enumFromInt(mem.readInt(u32, bytes[4..8], .little));
    if (chunk_type != expected_type) {
        return DecodeError.InvalidChunkOrder;
    }
    const chunk_length = mem.readInt(u32, bytes[0..4], .little);
    const length_aligned = mem.alignForward(u32, chunk_length, chunk_alignment);
    const limited_reader = std.io.limitedReader(inner_reader, length_aligned);
    return .{
        .limited_reader = limited_reader,
        .chunk_length = chunk_length,
    };
}

inline fn toDecodeError(err: anyerror) DecodeError {
    switch (err) {
        inline DecodeError => return @errorCast(err),
        else => {
            log.err("unexpected read error while decoding: {s}", @errorName(err));
            return DecodeError.ReadFailed;
        },
    }
}

const Json = struct {
    asset: struct {
        version: Version,
        min_version: ?Version = null,
    },

    scenes: []const struct {
        nodes: []const u32 = &.{},
        name: ?[]const u8 = null,
    } = &.{},

    nodes: []const struct {
        mesh: ?u32 = null,
        children: []const u32 = &.{},
        matrix: [16]f32 = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        },
        rotation: [4]f32 = .{ 0, 0, 0, 1 },
        scale: [3]f32 = .{ 1, 1, 1 },
        translation: [3]f32 = .{ 0, 0, 0 },
        name: ?[]const u8 = null,
    } = &.{},

    meshes: []const struct {
        primitives: []const struct {
            attributes: std.json.ArrayHashMap(u32),
            indices: ?u32 = null,
            material: ?u32 = null,
            mode: Mode = .TRIANGLES,
        },
        name: ?[]const u8 = null,
    } = &.{},

    accessors: []const struct {
        componentType: ComponentType,
        count: u32,
        type: AccessorType,
        bufferView: ?u32 = null,
        byteOffset: u32 = 0,
        normalized: bool = false,
        max: ?[]const f32 = null,
        min: ?[]const f32 = null,
        sparse: ?struct {
            count: u32,
            indices: []const struct {
                componentType: IndexComponentType,
                bufferView: u32,
                byteOffset: u32 = 0,
            },
            values: []const struct {
                bufferView: u32,
                byteOffset: u32 = 0,
            },
        } = null,
        name: ?[]const u8,
    } = &.{},

    buffers: []const struct {
        byteLength: u32,
        uri: ?JsonUri = null,
        name: ?[]const u8 = null,
    } = &.{},
    bufferViews: []const struct {
        buffer: u32,
        byteLength: u32,
        byteOffset: u32 = 0,
        byteStride: ?u32 = null,
        name: ?[]const u8 = null,
    } = &.{},

    materials: []const struct {
        pbrMetallicRoughness: ?struct {
            baseColorTexture: ?struct {
                index: u32,
                texCoord: u32 = 0,
            } = null,
            baseColorFactor: [4]f32 = .{ 1, 1, 1, 1 },
            metallicFactor: f32 = 1,
            roughnessFactor: f32 = 1,
        } = null,
        alphaMode: AlphaMode = .OPAQUE,
        alphaCutoff: f32 = 0.5,
        doubleSided: bool = false,
        name: ?[]const u8,
    } = &.{},

    textures: []const struct {
        sampler: ?u32 = null,
        source: ?u32 = null,
        name: ?[]const u8 = null,
    } = &.{},

    samplers: []const struct {
        magFilter: ?MagFilter = null,
        minFilter: ?MinFilter = null,
        wrapS: WrappingMode = .REPEAT,
        wrapT: WrappingMode = .REPEAT,
        name: ?[]const u8,
    } = &.{},

    images: []const struct {
        uri: ?JsonUri = null,
        name: ?[]const u8 = null,
    } = &.{},

    const Version = struct {
        semver: std.SemanticVersion,

        pub inline fn order(version: Version, semver: std.SemanticVersion) std.math.Order {
            return version.semver.order(semver);
        }

        pub fn jsonParse(
            allocator: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !@This() {
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            defer switch (token) {
                .allocated_number, .allocated_string => |slice| allocator.free(slice),
                else => {},
            };
            switch (token) {
                .string, .allocated_string => |slice| return .{
                    .semver = .parse(slice) catch return error.InvalidVersion,
                },
                else => return std.json.ParseFromValueError.UnexpectedToken,
            }
        }
    };
    const Mode = enum(u32) {
        POINTS = 0,
        LINES = 1,
        LINE_LOOP = 2,
        LINE_STRIP = 3,
        TRIANGLES = 4,
        TRIANGLE_STRIP = 5,
        TRIANGLE_FAN = 6,

        pub usingnamespace json_int_to_enum_mixin(@This());
    };
    const JsonUri = struct {
        uri: std.Uri,

        pub fn jsonParse(
            allocator: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !@This() {
            // Keep slice, std.Uri is only a view and doesn't allocate.
            const slice = try std.json.innerParse([]const u8, allocator, source, options);
            return .{ .uri = .parse(slice) catch return error.InvalidUri };
        }
    };
    const ComponentType = enum(u32) {
        BYTE = 5120,
        UNSIGNED_BYTE = 5121,
        SHORT = 5122,
        UNSIGNED_SHORT = 5123,
        UNSIGNED_INT = 5125,
        FLOAT = 5126,

        pub usingnamespace json_int_to_enum_mixin(@This());
    };
    const IndexComponentType = enum(u32) {
        UNSIGNED_BYTE = 5121,
        UNSIGNED_SHORT = 5123,
        UNSIGNED_INT = 5125,

        pub usingnamespace json_int_to_enum_mixin(@This());
    };
    const AccessorType = enum {
        SCALAR,
        VEC2,
        VEC3,
        VEC4,
        MAT2,
        MAT3,
        MAT4,
    };
    const MagFilter = enum(u32) {
        NEAREST = 9728,
        LINEAR = 9729,

        pub usingnamespace json_int_to_enum_mixin(@This());
    };
    const MinFilter = enum(u32) {
        NEAREST = 9728,
        LINEAR = 9729,
        NEAREST_MIPMAP_NEAREST = 9984,
        LINEAR_MIPMAP_NEAREST = 9985,
        NEAREST_MIPMAP_LINEAR = 9986,
        LINEAR_MIPMAP_LINEAR = 9987,

        pub usingnamespace json_int_to_enum_mixin(@This());
    };
    const WrappingMode = enum(u32) {
        CLAMP_TO_EDGE = 33071,
        MIRRORED_REPEAT = 33648,
        REPEAT = 10497,

        pub usingnamespace json_int_to_enum_mixin(@This());
    };
    const AlphaMode = enum {
        OPAQUE,
        MASK,
        BLEND,
    };

    fn DataType(comptime acc_type: AccessorType, comptime comp_type: ComponentType) type {
        const zig_type = switch (comp_type) {
            .BYTE => i8,
            .UNSIGNED_BYTE => u8,
            .SHORT => i16,
            .UNSIGNED_SHORT => u16,
            .UNSIGNED_INT => u32,
            .FLOAT => f32,
        };
        const num_comps = switch (acc_type) {
            .SCALAR => 1,
            .VEC2 => 2,
            .VEC3 => 3,
            .VEC4 => 4,
            .MAT2 => switch (@sizeOf(zig_type)) {
                1 => 8,
                else => 4,
            },
            .MAT3 => switch (@sizeOf(zig_type)) {
                1...2 => 12,
                else => 9,
            },
            .MAT4 => 16,
        };
        const data_type = [num_comps]zig_type;
        return data_type;
    }
    pub fn getData(
        self: Json,
        comptime acc_type: AccessorType,
        comptime comp_type: ComponentType,
        data: []align(4) const u8,
        accessor_idx: u32,
    ) DecodeError![]const DataType(acc_type, comp_type) {
        const accessor = self.accessors[accessor_idx];
        assert(accessor.type == acc_type and accessor.componentType == comp_type);

        const buffer_view_idx = accessor.bufferView orelse return if (accessor.count > 0)
            DecodeError.SemanticError
        else
            &.{};
        if (buffer_view_idx >= self.bufferViews.len) {
            @branchHint(.unlikely);
            return DecodeError.SemanticError;
        }
        const buffer_view = self.bufferViews[buffer_view_idx];

        const buffer_idx = buffer_view.buffer;
        if (buffer_idx != 0) {
            return DecodeError.Unsupported;
        }

        if ((buffer_view.byteOffset + buffer_view.byteLength) > self.buffers[0].byteLength) {
            @branchHint(.unlikely);
            return DecodeError.SemanticError;
        }
        if (accessor.byteOffset >= buffer_view.byteLength) {
            @branchHint(.unlikely);
            return DecodeError.SemanticError;
        }

        const view = @as(
            []const DataType(acc_type, comp_type),
            @alignCast(@ptrCast(data[buffer_view.byteOffset..][accessor.byteOffset..buffer_view.byteLength])),
        );
        if (view.len < accessor.count) {
            @branchHint(.unlikely);
            return DecodeError.SemanticError;
        }
        return view[0..accessor.count];
    }

    fn jsonIntToEnum(
        comptime E: type,
        allocator: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !E {
        const raw = try std.json.innerParse(u32, allocator, source, options);
        return std.meta.intToEnum(E, raw) catch error.InvalidEnumValue;
    }
    fn json_int_to_enum_mixin(comptime E: type) type {
        return struct {
            pub fn jsonParse(
                allocator: Allocator,
                source: anytype,
                options: std.json.ParseOptions,
            ) !E {
                return jsonIntToEnum(E, allocator, source, options);
            }
        };
    }
};
