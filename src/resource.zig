//! Assets need to satisfy the following interface:
//! `pub const Key = [type]`
//! `pub const Error = error{...}`
//! `pub fn load(context: Manager.Context) Asset.Error!Asset`
//! `pub fn unload(asset: *Asset, context: Manager.Context) void`
//! `pub fn toOwnedBytes(key: Key) Allocator.Error![]const u8`

const builtin = @import("builtin");
const std = @import("std");
const stdx = @import("stdx");
const s2s = @import("s2s");
const atomic = std.atomic;
const mem = std.mem;
const Allocator = mem.Allocator;
const Dir = std.fs.Dir;
const File = std.fs.File;
const Render = @import("State").Render;
const assert = std.debug.assert;
const log = std.log.scoped(.assets);

const is_debug = (builtin.mode == .Debug);
const is_safe_build = (builtin.mode == .Debug or builtin.mode == .ReleaseSafe);

pub const Manager = @import("resource/Manager.zig");
pub const Descriptor = @import("resource/Descriptor.zig");

// Prevent accidental key collisions
const Magic = enum(u32) {
    path = 0x9A769A76,
    pipeline = 0x919E714E,
    sampler = 0x5AAA97E5,

    pub fn asBytes(magic: Magic) [@sizeOf(Magic)]u8 {
        return @as([@sizeOf(Magic)]u8, @bitCast(@intFromEnum(magic)));
    }
};

inline fn noMagic(bytes: []const u8) []const u8 {
    assert(bytes.len >= @sizeOf(Magic));
    return bytes[@sizeOf(Magic)..bytes.len];
}

inline fn hasMagic(comptime magic: Magic, bytes: []const u8) bool {
    assert(bytes.len >= @sizeOf(Magic));
    const magic_bytes = comptime magic.asBytes();
    return mem.eql(u8, &magic_bytes, bytes[0..@sizeOf(Magic)]);
}

pub const Texture = struct {
    width: u32,
    height: u32,
    image: Render.backend.Image,

    pub const Key = []const u8;
    pub const Error = File.OpenError || zigimg.ImageUnmanaged.ReadError || zigimg.ImageUnmanaged.ConvertError;

    const zigimg = @import("zigimg");

    pub fn load(context: Manager.Context) Texture.Error!Texture {
        assert(hasMagic(.path, context.bytes));

        const asset_dir = context.asset_manager.asset_dir;
        const path = noMagic(context.bytes);
        const file = try asset_dir.openFile(path, .{ .mode = .read_only });
        defer file.close();

        var arena = std.heap.ArenaAllocator.init(context.allocator);
        defer arena.deinit();

        var stream = zigimg.ImageUnmanaged.Stream{ .file = file };
        const options = zigimg.formats.png.DefaultOptions.init(.{});
        const image = try zigimg.formats.png.load(&stream, arena.allocator(), options.get());
        defer image.deinit(arena.allocator());

        const pixel_format = image.pixelFormat();
        if (pixel_format.bitsPerChannel() != 8 or pixel_format.channelCount() != 4) {
            try image.convert(arena.allocator(), .rgba32);
            log.warn("had to convert image to RGBA32 ({s})", .{path});
        }

        const pixels = image.rawBytes();

        const render_image = Render.backend.createTexture(image.width, image.height, pixels);

        log.info("loaded texture from '{s}'", .{path});
        return Texture{
            .width = @intCast(image.width),
            .height = @intCast(image.height),
            .image = render_image,
        };
    }

    pub fn unload(texture: *Texture, context: Manager.Context) void {
        assert(hasMagic(.path, context.bytes));

        Render.backend.destroyTexture(texture.image);
        texture.* = undefined;

        log.info("unloaded texture from '{s}'", .{noMagic(context.bytes)});
    }
};

pub const Model = struct {
    meshes: []const Render.backend.Mesh,
    primitives: []const Render.backend.Mesh.Primitive,

    pub const Key = []const u8;
    pub const Error = File.OpenError || stdx.MapFileToMemoryError || std.Uri.ParseError || std.base64.Error;

    const zgltf = @import("zgltf");
    const zigimg = @import("zigimg");
    const zalgebra = @import("zalgebra");

    pub fn load(context: Manager.Context) Model.Error!Model {
        assert(hasMagic(.path, context.bytes));

        const asset_dir = context.asset_manager.asset_dir;
        const path = noMagic(context.bytes);
        const file = try asset_dir.openFile(path, .{ .mode = .read_only });
        defer file.close();

        const mapped = try stdx.mapFileToMemory(file);
        defer stdx.unmapFileFromMemory(mapped);

        var gltf = zgltf.init(context.allocator);
        defer gltf.deinit();
        try gltf.parse(mapped);

        var mesh_count: usize = 0;
        var prim_count: usize = 0;
        for (gltf.data.nodes.items) |node| {
            if (node.mesh) |mesh_idx| {
                mesh_count += 1;
                prim_count += gltf.data.meshes.items[mesh_idx].primitives.items.len;
            }
        }

        // Currently only glb files with embedded mesh data are supported
        const bin = gltf.glb_binary orelse return Model{
            .meshes = &.{},
            .primitives = &.{},
        };

        const meshes = try context.allocator.alloc(Render.backend.Mesh, mesh_count);
        errdefer context.allocator.free(meshes);
        const primitives = try context.allocator.alloc(Render.backend.Mesh.Primitive, prim_count);
        errdefer context.allocator.free(primitives);
        const pipeline_keys = try context.allocator.alloc(Pipeline.Key, prim_count);
        defer context.allocator.free(pipeline_keys);
        const texture_keys = try context.allocator.alloc(Texture.Key, prim_count);
        defer context.allocator.free(texture_keys);

        var mesh_alloc = std.heap.FixedBufferAllocator.init(mem.sliceAsBytes(meshes));
        var prim_alloc = std.heap.FixedBufferAllocator.init(mem.sliceAsBytes(primitives));
        var pip_key_alloc = std.heap.FixedBufferAllocator.init(mem.sliceAsBytes(pipeline_keys));
        var tex_key_alloc = std.heap.FixedBufferAllocator.init(mem.sliceAsBytes(texture_keys));

        var mesh_list = std.ArrayList(Render.backend.Mesh).initCapacity(mesh_alloc.allocator(), mesh_count) catch unreachable;
        var prim_list = std.ArrayList(Render.backend.Mesh.Primitive).initCapacity(prim_alloc.allocator(), prim_count) catch unreachable;
        var pip_key_list = std.ArrayList(Pipeline.Key).initCapacity(pip_key_alloc.allocator(), prim_count) catch unreachable;
        var tex_key_list = std.ArrayList(Texture.Key).initCapacity(tex_key_alloc.allocator(), prim_count) catch unreachable;

        for (gltf.data.nodes.items) |node| {
            const mesh_idx = node.mesh orelse continue;
            const prim_start_idx = prim_list.items.len;

            // gltf is colummn-major and zalgebra is row-major, we transpose here to avoid silly mistakes down the line.
            const matrix = if (node.matrix) |mat| zalgebra.Mat4.transpose(@bitCast(mat)) else zalgebra.Mat4.identity();
            const determinant = matrix.det();

            // https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#instantiation
            // Whether or not 0 is a positive number is up for debate...
            const winding: Render.backend.Winding = if (determinant > 0) .ccw else .cw;

            for (gltf.data.meshes.items[mesh_idx].primitives.items) |prim| {
                var primitive = Render.backend.Mesh.Primitive{
                    .positions = &.{},
                    .uv = .{ .v2u16 = &.{} },
                    .indices = .none,
                    .texture_handle = null,
                    .type = switch (prim.mode) {
                        .points => .points,
                        .lines => .lines,
                        .line_strip => .line_strip,
                        .triangles => .triangles,
                        .triangle_strip => .triangle_strip,
                        else => .triangle,
                    },
                };

                var is_missing_texcoords = true;
                for (prim.attributes.items) |attr| {
                    switch (attr) {
                        .position => |acc_idx| {
                            const acc = gltf.data.accessors.items[acc_idx];
                            if (acc.type != .vec3 or acc.component_type != .float) continue;

                            if (acc.buffer_view == null) continue;

                            var positions_list = std.ArrayList(f32).init(context.allocator);
                            errdefer positions_list.deinit();
                            gltf.getDataFromBufferView(f32, &positions_list, acc, bin);
                            primitive.positions = @ptrCast(try positions_list.toOwnedSlice());
                        },
                        .texcoord => |acc_idx| {
                            if (!is_missing_texcoords) continue; // TODO support multiple sets?

                            const acc = gltf.data.accessors.items[acc_idx];
                            if (acc.type != .vec2) continue;

                            if (acc.buffer_view == null) continue;

                            primitive.uv = switch (acc.component_type) {
                                .unsigned_byte => continue, // TODO support?
                                .unsigned_short => blk: {
                                    var uv_list = std.ArrayList(u16).init(context.allocator);
                                    errdefer uv_list.deinit();
                                    gltf.getDataFromBufferView(u16, &uv_list, acc, bin);
                                    break :blk .{ .v2u16 = @ptrCast(try uv_list.toOwnedSlice()) };
                                },
                                .float => blk: {
                                    var uv_list = std.ArrayList(f32).init(context.allocator);
                                    errdefer uv_list.deinit();
                                    gltf.getDataFromBufferView(f32, &uv_list, acc, bin);
                                    break :blk .{ .v2f32 = @ptrCast(try uv_list.toOwnedSlice()) };
                                },
                                else => continue,
                            };
                            is_missing_texcoords = false;
                        },
                        else => continue,
                    }
                }
                if (prim.indices) |indices_idx| indices: {
                    const acc = gltf.data.accessors.items[indices_idx];
                    if (acc.type != .scalar) break :indices;

                    if (acc.buffer_view == null) break :indices;

                    primitive.indices = switch (acc.component_type) {
                        .unsigned_byte => .none, // TODO: support u8 indices?
                        .unsigned_short => blk: {
                            var indices_list = std.ArrayList(u16).init(context.allocator);
                            errdefer indices_list.deinit();
                            gltf.getDataFromBufferView(u16, &indices_list, acc, bin);
                            break :blk .{ .u16 = indices_list.toOwnedSlice() };
                        },
                        .unsigned_integer => blk: {
                            var indices_list = std.ArrayList(u32).init(context.allocator);
                            errdefer indices_list.deinit();
                            gltf.getDataFromBufferView(u32, &indices_list, acc, bin);
                            break :blk .{ .u32 = indices_list.toOwnedSlice() };
                        },
                        else => .none,
                    };
                }

                var cull = Render.backend.Cull.back;

                if (prim.material) |mat_idx| {
                    const material = gltf.data.materials.items[mat_idx];
                    if (material.is_double_sided) {
                        cull = .none;
                    }
                    var texture: union(enum) {
                        none,
                        key: Texture.Key,
                        image: zigimg.ImageUnmanaged,
                    } = .none;
                    var sampler = Sampler.default_key;

                    if (material.metallic_roughness.base_color_texture) |tex_info| {
                        const tex = gltf.data.textures.items[tex_info.index];
                        if (tex.source) |img_idx| source: {
                            const img = gltf.data.images.items[img_idx];
                            if (img.uri) |raw_uri| {
                                if (!mem.containsAtLeastScalar(u8, raw_uri, 1, ':')) {
                                    // Relative path. We interpret relative paths as being
                                    // relative to the assets/textures dir.
                                    try context.asset_manager.dispatchLoad(Texture, context.allocator, raw_uri);
                                    texture = .{ .key = raw_uri };
                                } else {
                                    const uri = try std.Uri.parse(raw_uri);
                                    if (mem.eql(uri.scheme, "data")) {
                                        // Image is embedded directly into the URI
                                        const raw_data: []const u8 = switch (uri.path) {
                                            // There shouldn't be any percent encoded data here,
                                            // if there is we will ignore it as it's malformed.
                                            inline else => |p| p,
                                        };
                                        const data_start = (mem.indexOfScalar(u8, raw_data, ',') orelse break :source) + 1;
                                        const is_base64 = mem.endsWith(u8, raw_data[0..data_start], ";base64,");
                                        if (is_base64) {
                                            const base64_data = raw_data[data_start..raw_data.len];
                                            const base64_dec = std.base64.standard.Decoder.init(std.base64.standard_alphabet_chars, '=');
                                            const img_data_len = base64_dec.calcSizeForSlice(base64_data);
                                            const img_data = try gltf.arena.allocator().alloc(u8, img_data_len);
                                            defer gltf.arena.allocator().free(img_data);

                                            try base64_dec.decode(img_data, base64_data);
                                            const image = try zigimg.ImageUnmanaged.fromMemory(context.allocator, img_data);
                                            texture = .{ .image = image };
                                        }
                                    }
                                }
                            } else if (img.data) |raw_data| {
                                // Image is embedded into GLB binary chunk
                                const image = try zigimg.ImageUnmanaged.fromMemory(context.allocator, raw_data);
                                texture = .{ .image = image };
                            }
                        }
                        if (tex.sampler) |smp_idx| {
                            const smp = gltf.data.samplers.items[smp_idx];
                            if (smp.min_filter) |min_filter| sampler.min_filter = switch (min_filter) {
                                .linear => .linear,
                                else => .nearest,
                            };
                            if (smp.mag_filter) |mag_filter| sampler.mag_filter = switch (mag_filter) {
                                .linear => .linear,
                                else => .nearest,
                            };
                            if (smp.wrap_s) |wrap_s| sampler.wrap_u = switch (wrap_s) {
                                .clamp_to_edge => .clamp_to_edge,
                                .mirrored => .mirrored_repeat,
                                else => .repeat,
                            };
                            if (smp.wrap_t) |wrap_t| sampler.wrap_v = switch (wrap_t) {
                                .clamp_to_edge => .clamp_to_edge,
                                .mirrored => .mirrored_repeat,
                                else => .repeat,
                            };
                        }
                    }
                }

                const tex_key = &.{};

                const pip_key = Pipeline.Key{
                    .shader = context.asset_manager.default_shader_context.shader,
                    .options = .{
                        .graphics = .{
                            .buffers = .{},
                            .attrs = .{
                                .{ // positions
                                    .location = 0,
                                    .binding = context.asset_manager.default_shader_context.bind_pos,
                                    .format = .v3f32,
                                    .offset = 0,
                                },
                                .{ // uv
                                    .location = 1,
                                    .binding = context.asset_manager.default_shader_context.bind_uv,
                                    .format = switch (primitive.uv) {
                                        .v2u16 => .v2u16,
                                        .v2f32 => .v2f32,
                                    },
                                    .offset = 0,
                                },
                                .{ // color
                                    .location = 2,
                                    .binding = context.asset_manager.default_shader_context.bind_color,
                                    .format = .v4u8,
                                },
                            },
                            .primitive = primitive.type,
                            .index = std.meta.activeTag(primitive.indices),
                            .cull = cull,
                        },
                    },
                };

                tex_key_list.append(tex_key) catch unreachable;
                pip_key_list.append(pip_key) catch unreachable;
                prim_list.append(primitive) catch unreachable;
            }
            var matrix: [16]f32 = undefined;
            if (node.has_matrix) matrix = node.matrix else cgltf.cgltf_node_transform_local(node, &matrix);
            const mesh = Render.backend.Mesh{
                .matrix = matrix,
                .primitives = prim_list.items[prim_start_idx..prim_list.items.len],
            };
            mesh_list.append(mesh) catch unreachable;
            gltf.nodes[0].mesh.*.primitives[0].material.*.extensions;
        }

        return Model{
            .arena_state = arena.state,
        };
    }

    pub fn unload(model: *Model, context: Manager.Context) void {
        var arena = model.arena_state.promote(context.allocator);
        arena.deinit();
        model.* = undefined;
    }

    pub fn toOwnedBytes(allocator: Allocator, key: Key) Allocator.Error![]const u8 {
        const magic_bytes = Magic.path.asBytes();
        const bytes = try mem.concat(allocator, u8, &.{ &magic_bytes, key });
        return bytes;
    }

    fn cgltfAlloc(user_data: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        if (size == 0) {
            return null;
        }
        const arena_allocator: *const Allocator = @alignCast(@ptrCast(user_data));

        const alignment = mem.Alignment.fromByteUnits(
            @min(std.math.ceilPowerOfTwoAssert(usize, size), @alignOf(*anyopaque)),
        );
        const ptr = arena_allocator.rawAlloc(size, alignment, @returnAddress());
        return @ptrCast(ptr);
    }
    fn cgltfFree(user_data: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        _ = .{ user_data, ptr };
    }
};

pub const Pipeline = struct {
    pip: Render.backend.Pipeline,
    buffer: Render.backend.Buffer,
    used: usize,

    pub const Key = struct {
        shader: Render.backend.Shader,
        options: union(Render.backend.PipelineKind) {
            graphics: Render.backend.PipelineOptions(.graphics),
            compute: Render.backend.PipelineOptions(.compute),
        },
    };
    pub const Error = Allocator.Error;

    pub fn load(context: Manager.Context) Pipeline.Error!Pipeline {
        assert(hasMagic(.pipeline, context.bytes));

        const bytes = noMagic(context.bytes);
        var stream = std.io.fixedBufferStream(bytes);
        const reader = stream.reader();
        const key = s2s.deserializeAlloc(reader, Key, context.allocator) catch |err| switch (err) {
            .OutOfMemory => return Pipeline.Error.OutOfMemory,
            else => unreachable,
        };
        defer s2s.free(context.allocator, Key, &key);

        const kind = std.meta.activeTag(key.options);
        const pipeline = switch (kind) {
            inline else => |tag| Render.backend.createPipeline(tag, key.shader, @field(key.op, @tagName(tag))),
        };
        log.info("created {s} pipeline ({s})", .{ @tagName(kind), bytes });
        return .{ .pip = pipeline };
    }

    pub fn unload(pipeline: *Pipeline, context: Manager.Context) void {
        assert(hasMagic(.pipeline, context.bytes));

        Render.backend.destroyPipeline(pipeline.pip);
        log.info("destroyed pipeline ({s})", .{noMagic(context.bytes)});
    }

    pub fn toOwnedBytes(allocator: Allocator, key: Key) Allocator.Error![]const u8 {
        const min_cap = @sizeOf(Magic) + @sizeOf(Key);
        var bytes = try std.ArrayList(u8).initCapacity(allocator, min_cap);
        errdefer bytes.deinit();
        bytes.append(Magic.pipeline.asBytes()) catch unreachable;
        const writer = bytes.writer();
        try s2s.serialize(writer, Key, key);
        const owned = try bytes.toOwnedSlice();
        return owned;
    }
};

pub const Sampler = struct {
    smp: Render.backend.Sampler,

    pub const Key = Render.backend.SamplerOptions;
    pub const Error = error{};

    pub const default_key = Key{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .wrap_u = .repeat,
        .wrap_v = .repeat,
        .compare = .never,
    };

    pub fn load(context: Manager.Context) Sampler.Error!Sampler {
        assert(hasMagic(.sampler, context.bytes));

        const bytes = noMagic(context.bytes);
        var stream = std.io.fixedBufferStream(bytes);
        const reader = stream.reader();
        const options = s2s.deserialize(reader, Key) catch unreachable;

        const sampler = Render.backend.createSampler(options);
        log.info("created sampler ({s})", .{bytes});
        return .{ .smp = sampler };
    }

    pub fn unload(sampler: *Sampler, context: Manager.Context) void {
        assert(hasMagic(.sampler, context.bytes));

        Render.backend.destroySampler(sampler.smp);
        log.info("destroyed sampler ({s})", .{noMagic(context.bytes)});
    }

    pub fn toOwnedBytes(allocator: Allocator, key: Key) Allocator.Error![]const u8 {
        const min_cap = @sizeOf(Magic) + @sizeOf(Key);
        var bytes = try std.ArrayList(u8).initCapacity(allocator, min_cap);
        errdefer bytes.deinit();
        bytes.append(Magic.sampler.asBytes()) catch unreachable;
        const writer = bytes.writer();
        try s2s.serialize(writer, Key, key);
        const owned = try bytes.toOwnedSlice();
        return owned;
    }
};

pub const Map = struct {
    display_name: [*:0]const u8,
    texture_name: [*:0]const u8,
    control_points: []const [2]f32,

    pub const Error = error{};

    pub fn load(memory: []const u8) Map.Error!void {
        _ = memory;
    }
    pub fn unload(map: *Map) void {
        _ = map;
    }
};
