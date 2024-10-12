const std = @import("std");

const fs = std.fs;
const hash = std.hash;
const io = std.io;
const math = std.math;
const mem = std.mem;

const Allocator = mem.Allocator;
const Endian = std.builtin.Endian;
const File = fs.File;

const assert = std.debug.assert;


header: Header = undefined,
nodes: [*]Node = undefined,
kinds: [*]Node.Kind = undefined,

header_is_init: bool = false,
data_is_init: bool = false,


const GoonTrace = @This();


pub fn init(aspect_ratio: Header.AspectRatio, nodes: [*]Node, kinds: [*]Node.Kind, node_count: u16) GoonTrace {
	var bt = GoonTrace{
		.header = .{
			.magic_number = Header.expected_magic_number,
			.aspect_ratio = aspect_ratio,
			.node_count = node_count,
			.checksum = undefined,
		},
		.nodes = nodes,
		.kinds = kinds,

		.header_is_init = true,
		.data_is_init = true,
	};
	bt.header.aspect_ratio.normalize();

	return bt;
}

pub fn fromFile(allocator: Allocator, file: File) !GoonTrace {
	const reader = file.reader();
	errdefer file.seekTo(0) catch unreachable;

	assert(file.getPos() catch unreachable == 0);

	var bt = GoonTrace{};
	errdefer bt.deinit(allocator);

	try bt.read(allocator, reader, .big);
}

pub fn deinit(bt: *GoonTrace, allocator: Allocator) void {
	if (bt.data_is_init) {
		allocator.free(bt.nodes[0..bt.header.node_count]);
		allocator.free(bt.kinds[0..bt.header.node_count]);
	}
	bt.* = undefined;
}

pub fn read(
	bt: *GoonTrace,
	allocator: Allocator,
	reader: anytype,
	source_endian: Endian,
) !void {
	bt.header = try reader.readStructEndian(Header, source_endian);
	if (bt.header.magic_number != Header.expected_magic_number)
		return error.WrongMagicNumber;

	bt.header_is_init = true;


	errdefer { bt.data_is_init = false; }

	const node_count = bt.header.node_count;
	const nodes = try allocator.alloc(Node, node_count);
	errdefer allocator.free(nodes);

	var last_node: Node = undefined;

	for (nodes) |*node| {
		node.* = try reader.readStructEndian(Node, source_endian);
	}
	last_node = try reader.readStructEndian(Node, source_endian);
	if (last_node.x != Node.Eod.x or last_node.y != Node.Eod.y)
		return error.MissingEodNode;

	bt.nodes = nodes.ptr;

	const kinds = try allocator.alloc(Node.Kind, node_count);
	errdefer allocator.free(kinds);

	var last_kind: u8 = undefined;

	try reader.read(mem.sliceAsBytes(kinds));
	last_kind = try reader.readByte();
	if (last_kind != Node.Kind.Eod)
		return error.MissingEodKind;

	bt.kinds = kinds.ptr;

	bt.data_is_init = true;

	if (!bt.validateChecksum()) {
		bt.header_is_init = false;
		return error.InvalidChecksum;
	}

	bt.header.aspect_ratio.normalize();
}

pub fn write(bt: *GoonTrace, writer: anytype, target_endian: Endian) !void {
	if (!bt.header_is_init)
		return error.UninitializedHeader;

	if (!bt.data_is_init)
		return error.UninitializedData;

	bt.updateChecksum();

	try writer.writeStructEndian(bt.header, target_endian);

	for (bt.header.node_count) |i| {
		try writer.writeStructEndian(bt.nodes[i], target_endian);
	}
	try writer.writeStructEndian(Node.Eod, target_endian);

	try writer.write(mem.sliceAsBytes(bt.kinds[0..bt.header.node_count]));
	try writer.writeByte(Node.Kind.Eod);
}

pub fn calculateChecksum(bt: *GoonTrace) Header.Checksum {
	var checksum: Header.Checksum = undefined;

	checksum.header = hash.uint32(
		@as(u32, @intFromEnum(bt.header.aspect_ratio) << 16) & @as(u32, bt.header.node_count));

	checksum.data = blk: {
		const gen = hash.crc.Crc32.init();
		gen.update(mem.sliceAsBytes(bt.nodes[0..bt.header.node_count]));
		gen.update(mem.sliceAsBytes(bt.kinds[0..bt.header.node_count]));
		break :blk gen.final();
	};

	return checksum;
}

pub inline fn validateChecksum(bt: *GoonTrace) bool {
	return (bt.calculateChecksum() == bt.header.checksum);
}

pub inline fn updateChecksum(bt: *GoonTrace) void {
	bt.header.checksum = bt.calculateChecksum();
}

pub const Header = extern struct {
	magic_number: u32 = expected_magic_number,
	aspect_ratio: AspectRatio,
	node_count: u16,

	/// checksum: hash(aspect_ratio ++ node_count) ++ crc(nodes)
	checksum: Checksum,


	pub const expected_magic_number: u32 = 0x0B100712;

	pub const Checksum = packed struct(u64) {
		header: u32,
		data: u32,
	};

	pub const AspectRatio = packed union {
		tag: Tag,
		x: X,

		pub const Tag = enum(u16) {
			@"1:1" = 0x01_01,
			@"4:3" = 0x04_03,
			@"16:9" = 0x10_09,
			@"16:10" = 0x10_0A,
			_,
		};
		pub const X = packed struct(u16) {
			w: u8,
			h: u8,
		};

		const known_quotients = blk: {
			const fields = @typeInfo(Tag).@"enum".fields;
			var quotients: [fields.len]comptime_float = undefined;
			for (&quotients, fields) |q, field| {
				q.* = AspectRatio.quotient(@enumFromInt(field.value));
			}
			break :blk quotients;
		};

		pub fn normalize(aspect_ratio: *AspectRatio) void {
			if (aspect_ratio == ._) {
				const q = aspect_ratio.quotient();
				for (known_quotients, 0..) |known, i| {
					if (math.approxEqRel(f64, known, q, 0.1))
						aspect_ratio.tag = @enumFromInt(@typeInfo(Tag).@"enum".fields[i].value);
				}
			}
		}

		pub inline fn quotient(aspect_ratio: AspectRatio) f64 {
			return @as(f64, @floatFromInt(aspect_ratio.x.w)) / @as(f64, @floatFromInt(aspect_ratio.x.h));
		}
	};
};

pub const Node = extern struct {
	x: f32,
	y: f32,

	pub const Eod = Node{
		.x = @bitCast(math.maxInt(u64)),
		.y = @bitCast(math.maxInt(u64)),
	};

	pub const Kind = enum(u8) {
		angular = 0,
		bezier = 1,

		pub const Eod: u8 = math.maxInt(u8);
	};
};
