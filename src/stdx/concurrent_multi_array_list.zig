const std = @import("std");
const builtin = @import("builtin");
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const cache_line = std.atomic.cache_line;

/// A thread-safe, append-only version of `std.MultiArrayList`.
/// This implementation is not opimized for iteration but rather
/// for a small memory footprint, although an iterator does exist.
/// A `Len` (unsigned integer) type needs to be specified to allow
/// for thread-safe allocation of additional segments.
/// Note that only `log2(maxInt(Len))` pointers need to be
/// statically allocated to satisfy the requested limit.
///
/// A MultiArrayList stores a list of a struct or tagged union type.
/// Instead of storing a single list of items, MultiArrayList
/// stores separate lists for each field of the struct or
/// lists of tags and bare unions.
/// This allows for memory savings if the struct or union has padding,
/// and also improves cache usage if only some fields or just tags
/// are needed for a computation.  The primary API for accessing fields is
/// the `slice()` function, which computes the start pointers
/// for the array of each field.  From the slice you can call
/// `.items(.<field_name>)` to obtain a slice of field values.
/// For unions you can call `.items(.tags)` or `.items(.data)`.
pub fn ConcurrentMultiArrayList(comptime T: type, comptime Len: type, comptime init_capacity: Len) type {
    if (@sizeOf(T) == 0) {
        @compileError("does not support zero-sized types");
    }
    switch (@typeInfo(Len)) {
        .int => |info| if (info.signedness != .unsigned) {
            @compileError("'Len' needs to be unsigned");
        },
        else => @compileError("'Len': need unsigned int, got '" ++ @typeName(Len) ++ "'"),
    }
    return struct {
        segments: [max_segment_count]?Segment,
        len: std.atomic.Value(Len),

        const Self = @This();

        const ShelfIndex = math.Log2Int(Len);
        const Segment = [*]align(segment_alignment) u8;

        const elem_bytes = blk: {
            var total_size = 0;
            for (sizes.bytes) |size| total_size += size;
            break :blk total_size;
        };

        const segment_alignment = @max(@alignOf(T), cache_line);
        const first_segment_len: Len = blk: {
            const max_in_cache_line = @min(
                math.floorPowerOfTwo(usize, (cache_line / elem_bytes)),
                math.ceilPowerOfTwoAssert(usize, math.maxInt(Len)),
            );
            const min_to_fit_init_capacity =
                if (init_capacity == 0) 0 else math.ceilPowerOfTwoAssert(Len, init_capacity);
            break :blk @max(1, max_in_cache_line, min_to_fit_init_capacity);
        };
        const segment_index_offset: ShelfIndex = math.log2_int(Len, first_segment_len);
        const max_segment_count = @typeInfo(Len).int.bits - segment_index_offset - 1;

        pub const empty: Self = .{
            .segments = @splat(null),
            .len = .init(0),
        };

        const Elem = switch (@typeInfo(T)) {
            .@"struct" => T,
            .@"union" => |u| struct {
                tags: Tag,
                data: Bare,

                pub const Tag =
                    u.tag_type orelse @compileError("does not support untagged unions");
                pub const Bare = @Type(.{ .@"union" = .{
                    .layout = u.layout,
                    .tag_type = null,
                    .fields = u.fields,
                    .decls = &.{},
                } });

                pub fn fromT(outer: T) @This() {
                    const tag = meta.activeTag(outer);
                    return .{
                        .tags = tag,
                        .data = switch (tag) {
                            inline else => |t| @unionInit(Bare, @tagName(t), @field(outer, @tagName(t))),
                        },
                    };
                }
                pub fn toT(tag: Tag, bare: Bare) T {
                    return switch (tag) {
                        inline else => |t| @unionInit(T, @tagName(t), @field(bare, @tagName(t))),
                    };
                }
            },
            else => @compileError("only supports structs and tagged unions"),
        };

        pub const Field = meta.FieldEnum(Elem);

        const fields = meta.fields(Elem);

        /// `sizes.bytes` is an array of @sizeOf each T field. Sorted by alignment, descending.
        /// `sizes.fields` is an array mapping from `sizes.bytes` array index to field index.
        const sizes = blk: {
            const Data = struct {
                size: usize,
                size_index: usize,
                alignment: usize,
            };
            var data: [fields.len]Data = undefined;
            for (fields, 0..) |field_info, i| {
                data[i] = .{
                    .size = @sizeOf(field_info.type),
                    .size_index = i,
                    .alignment = if (@sizeOf(field_info.type) == 0) 1 else field_info.alignment,
                };
            }
            const Sort = struct {
                fn lessThan(context: void, lhs: Data, rhs: Data) bool {
                    _ = context;
                    return lhs.alignment > rhs.alignment;
                }
            };
            @setEvalBranchQuota(3 * fields.len * math.log2(fields.len));
            mem.sort(Data, &data, {}, Sort.lessThan);
            var sizes_bytes: [fields.len]usize = undefined;
            var field_indexes: [fields.len]usize = undefined;
            for (data, 0..) |elem, i| {
                sizes_bytes[i] = elem.size;
                field_indexes[i] = elem.size_index;
            }
            break :blk .{
                .bytes = sizes_bytes,
                .fields = field_indexes,
            };
        };

        /// Release all allocated memory.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.freeShelves(gpa, @as(ShelfIndex, @intCast(self.segments.len)), 0);
            gpa.free(self.segments);
            self.* = undefined;
        }

        /// Get the slice of values for a specified field.
        /// If you need multiple fields, consider calling slice()
        /// instead.
        pub fn items(self: Self, comptime field: Field) []FieldType(field) {
            return self.slice().items(field);
        }

        /// Overwrite one array element with new data.
        pub fn set(self: *Self, index: usize, elem: T) void {
            var slices = self.slice();
            slices.set(index, elem);
        }

        /// Obtain all the data for one array element.
        pub fn get(self: Self, index: usize) T {
            assert(index < self.len.load(.monotonic));
            return self.slice().get(index);
        }

        fn ItemAtType(comptime SelfType: type, comptime field: Field) type {
            if (@typeInfo(SelfType).pointer.is_const) {
                return *const FieldType(field);
            } else {
                return *FieldType(field);
            }
        }

        /// Obtain a pointer to a specific field at `index`.
        pub fn itemAt(self: anytype, comptime field: Field, index: usize) ItemAtType(@TypeOf(self), field) {
            assert(index <= self.len.load(.monotonic));
            return self.uncheckedItemAt(field, index);
        }

        pub fn uncheckedItemAt(self: anytype, comptime field: Field, index: usize) ItemAtType(@TypeOf(self), field) {
            const shelf_index = shelfIndex(index);
            const box_index = boxIndex(field, index, shelf_index);
            const byte_ptr = &self.segments[shelf_index][box_index];
            return @ptrCast(@alignCast(byte_ptr));
        }

        /// Extend the list by 1 element. Allocates more memory as necessary.
        pub fn append(self: *Self, gpa: Allocator, elem: T) !void {
            try self.ensureUnusedCapacity(gpa, 1);
            self.appendAssumeCapacity(elem);
        }

        /// Extend the list by 1 element, but asserting `self.capacity`
        /// is sufficient to hold an additional item.
        pub fn appendAssumeCapacity(self: *Self, elem: T) void {
            assert(self.len < self.capacity);
            self.len += 1;
            self.set(self.len - 1, elem);
        }

        /// Extend the list by 1 element, returning the newly reserved
        /// index with uninitialized data.
        /// Allocates more memory as necesasry.
        pub fn addOne(self: *Self, gpa: Allocator) Allocator.Error!usize {
            try self.ensureUnusedCapacity(gpa, 1);
            return self.addOneAssumeCapacity();
        }

        /// Extend the list by 1 element, asserting `self.capacity`
        /// is sufficient to hold an additional item.  Returns the
        /// newly reserved index with uninitialized data.
        pub fn addOneAssumeCapacity(self: *Self) usize {
            assert(self.len < self.capacity);
            const index = self.len;
            self.len += 1;
            return index;
        }

        /// Remove and return the last element from the list, or return `null` if list is empty.
        /// Invalidates pointers to fields of the removed element.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const val = self.get(self.len - 1);
            self.len -= 1;
            return val;
        }

        pub fn clearAndFree(self: *Self, gpa: Allocator) void {
            gpa.free(self.allocatedBytes());
            self.* = .{};
        }

        /// Invalidates all element pointers.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        /// Modify the list so that it can hold at least `minimum` items.
        fn ensureTotalCapacity(self: Self, gpa: Allocator, minimum: usize) Allocator.Error!void {
            const new_cap_shelf_count = shelfCount(minimum);
            if (new_cap_shelf_count > max_segment_count) {
                @branchHint(.cold);
                return Allocator.Error.OutOfMemory;
            }

            const old_shelf_count = @as(ShelfIndex, @intCast(self.segments.len));
            const required_shelf_count = @max(old_shelf_count, new_cap_shelf_count);

            for (old_shelf_count..required_shelf_count) |i| {
                // We do not free anything if this fails, the newly
                // allocated segments could already be in use.
                const new_segment_slice = try gpa.alloc(T, shelfSize(@intCast(i)));
                if (@cmpxchgStrong(Segment, &self.segments[i], null, new_segment_slice.ptr, .release, .monotonic) != null) {
                    // another thread won the race
                    @branchHint(.unlikely);
                    gpa.free(new_segment_slice);
                }
            }
        }

        /// Modify the array so that it can hold at least `additional_count` **more** items.
        /// Invalidates pointers if additional memory is needed.
        pub fn ensureUnusedCapacity(self: *Self, gpa: Allocator, additional_count: usize) !void {
            return self.ensureTotalCapacity(gpa, self.len + additional_count);
        }

        /// Modify the array so that it can hold exactly `new_capacity` items.
        /// Invalidates pointers if additional memory is needed.
        /// `new_capacity` must be greater or equal to `len`.
        pub fn setCapacity(self: *Self, gpa: Allocator, new_capacity: usize) !void {
            assert(new_capacity >= self.len);
            const new_bytes = try gpa.alignedAlloc(
                u8,
                @alignOf(Elem),
                capacityInBytes(new_capacity),
            );
            if (self.len == 0) {
                gpa.free(self.allocatedBytes());
                self.bytes = new_bytes.ptr;
                self.capacity = new_capacity;
                return;
            }
            var other = Self{
                .bytes = new_bytes.ptr,
                .capacity = new_capacity,
                .len = self.len,
            };
            const self_slice = self.slice();
            const other_slice = other.slice();
            inline for (fields, 0..) |field_info, i| {
                if (@sizeOf(field_info.type) != 0) {
                    const field = @as(Field, @enumFromInt(i));
                    @memcpy(other_slice.items(field), self_slice.items(field));
                }
            }
            gpa.free(self.allocatedBytes());
            self.* = other;
        }

        /// Create a copy of this list with a new backing store,
        /// using the specified allocator.
        pub fn clone(self: Self, gpa: Allocator) !Self {
            var result = Self{};
            errdefer result.deinit(gpa);
            try result.ensureTotalCapacity(gpa, self.len);
            result.len = self.len;
            const self_slice = self.slice();
            const result_slice = result.slice();
            inline for (fields, 0..) |field_info, i| {
                if (@sizeOf(field_info.type) != 0) {
                    const field = @as(Field, @enumFromInt(i));
                    @memcpy(result_slice.items(field), self_slice.items(field));
                }
            }
            return result;
        }

        pub fn capacityInBytes(capacity: usize) usize {
            comptime var elem_bytes: usize = 0;
            inline for (sizes.bytes) |size| elem_bytes += size;
            return elem_bytes * capacity;
        }

        fn FieldType(comptime field: Field) type {
            return @FieldType(Elem, @tagName(field));
        }

        fn maxElemsInShelf(shelf_index: ShelfIndex) usize {
            comptime assert(@sizeOf(FieldType(field)) > 0);
            const shelf_size = shelfSize(shelf_index);
            return (shelf_size / @sizeOf(FieldType(field)));
        }

        fn shelfCount(box_count: usize) ShelfIndex {
            return log2IntCeil(usize, box_count) - prealloc_exp - 1;
        }

        fn shelfSize(shelf_index: ShelfIndex) usize {
            return @as(usize, 1) << shelf_index;
        }

        fn shelfIndex(list_index: usize) ShelfIndex {
            return math.log2_int(usize, list_index + 1);
        }

        fn boxIndex(comptime field: Field, list_index: usize, shelf_index: ShelfIndex) usize {
            const offset_in_segment = (@as(usize, 1) << shelf_index);
            return (list_index + 1) - (@as(usize, 1) << shelf_index);
        }

        const Entry = entry: {
            var entry_fields: [fields.len]std.builtin.Type.StructField = undefined;
            for (&entry_fields, sizes.fields) |*entry_field, i| entry_field.* = .{
                .name = fields[i].name ++ "_ptr",
                .type = *fields[i].type,
                .default_value_ptr = null,
                .is_comptime = fields[i].is_comptime,
                .alignment = fields[i].alignment,
            };
            break :entry @Type(.{ .@"struct" = .{
                .layout = .@"extern",
                .fields = &entry_fields,
                .decls = &.{},
                .is_tuple = false,
            } });
        };
    };
}

fn log2IntCeil(comptime T: type, x: T) math.Log2Int(T) {
    assert(x != 0);
    const log2_val = math.log2_int(T, x);
    if (@as(T, 1) << log2_val == x)
        return log2_val;
    return log2_val + 1;
}
