/// Do not access this field directly, use `getFirst()`
first: std.atomic.Value(Pointer),

const SinglyLinkedList = @This();

/// This struct contains only a next pointer and not any data payload. The
/// intended usage is to embed it intrusively into another data structure and
/// access the data with `@fieldParentPtr`.
pub const Node = struct {
    /// Do not access this field directly, use the parent list.
    next: Pointer,
};

/// Uses the LSB to store information.
const Pointer = packed struct(usize) {
    is_deleted: bool,
    _: std.meta.Int(.unsigned, (@bitSizeOf(usize) - 1)),

    pub const nullptr: Pointer = @bitCast(@intFromPtr(@as(?*Node, null)));

    pub fn init(ptr: anytype) Pointer {
        return @bitCast(@intFromPtr(ptr));
    }

    pub fn asNode(pointer: Pointer) *Node {
        assert(pointer.isNull() == false);
        return @ptrFromInt(pointer.asAddr());
    }
    pub fn asAddr(pointer: Pointer) usize {
        return @bitCast(pointer);
    }

    pub fn existing(pointer: Pointer) Pointer {
        var ex = pointer;
        ex.is_deleted = false;
        return ex;
    }
    pub fn deleted(pointer: Pointer) Pointer {
        var del = pointer;
        del.is_deleted = true;
        return del;
    }

    pub fn futexable(pointer: *const Pointer) *const std.atomic.Value(u32) {
        return @ptrCast(@as(*const u32, @ptrCast(@alignCast(pointer))));
    }
    pub fn futexBits(pointer: Pointer) u32 {
        return @truncate(pointer.asAddr());
    }

    pub fn isDeleted(pointer: Pointer) bool {
        return pointer.is_deleted;
    }
    pub fn isNull(pointer: Pointer) bool {
        return (pointer == nullptr);
    }
};

pub const empty = SinglyLinkedList{ .first = .init(.nullptr) };

pub fn getFirst(list: *SinglyLinkedList) ?*Node {
    return list.first.load(.acquire);
}

pub fn prepend(list: *SinglyLinkedList, new_node: *Node) void {
    var first = list.first.load(.acquire);
    while (true) {
        while (first.isDeleted()) {
            // We are not allowed to push onto a deleted head,
            // so we try to help in removing the current head
            // from the free list.
            @branchHint(.unlikely);
            const next = first.existing().asNode().next;
            if (list.first.cmpxchgWeak(first, next, .acq_rel, .monotonic)) |new_first| {
                first = new_first;
            } else {
                first = list.first.load(.acquire);
            }
        }
        // We now have a head which is not currently being deleted,
        // even though it might be null.
        new_node.next = first;
        if (list.first.cmpxchgWeak(
            first,
            .init(new_node),
            .release,
            .acquire,
        )) |new_first| {
            // head might have is_deleted set now, so we need to try
            // again from the beginning.
            first = new_first;
        } else {
            // std.debug.print("pushed new head: {*}\n", .{node});
            return;
        }
    }
}

pub fn popFirst(list: *SinglyLinkedList) ?*Node {
    var first = list.first.load(.acquire);
    while (true) {
        if (first.isNull()) {
            return null;
        }
        while (first.isDeleted() == false) {
            // Set the is_deleted bit
            if (list.first.cmpxchgWeak(
                first,
                first.deleted(),
                .acq_rel,
                .monotonic,
            )) |new_first| {
                first = new_first;
            } else {
                // Reload head to ensure that head.next is valid
                first = list.first.load(.acquire);
            }
        }
        // Someone has successfully set the is_deleted bit, we can now
        // remove the node from the list.
        // Note that head cannot be null here because is_deleted is set.
        const next = first.existing().asNode().next;
        if (list.first.cmpxchgWeak(
            first,
            next,
            .release,
            .acquire,
        )) |new_first| {
            first = new_first;
        } else {
            // We have successfully removed head from the list.
            // std.debug.print("popped head: {*}\n", .{head.existing()});
            return first.existing().asNode();
        }
    }
}

const std = @import("std");
const assert = std.debug.assert;
