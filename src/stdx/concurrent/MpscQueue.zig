//! Intrusive DV-MPSC. Use by embedding `Node` into your container.
//! * https://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
//! * https://int08h.com/post/ode-to-a-vyukov-queue/

head: std.atomic.Value(*Node),
tail: std.atomic.Value(*Node),
stub: Node,

const MpscQueue = @This();

pub const Node = struct {
    next: std.atomic.Value(?*Node) = .init(null),
};

pub fn initInstance(queue: *MpscQueue) void {
    queue.head = &queue.stub;
    queue.tail = &queue.stub;
    queue.stub = .{};
}

pub fn push(queue: *MpscQueue, node: *Node) void {
    node.next.store(null, .monotonic);
    const prev = queue.head.swap(node, .acq_rel);
    prev.next.store(node, .release);
}

pub fn pop(queue: *MpscQueue) ?*Node {
    var tail = queue.tail.load(.monotonic);
    var next_maybe = tail.next.load(.acquire);

    if (tail == &queue.stub) {
        if (next_maybe) |next| {
            queue.tail.store(next, .monotonic);
            tail = next;
            next_maybe = next.next.load(.acquire);
        } else {
            return null;
        }
    }
    if (next_maybe) |next| {
        queue.tail.store(next, .monotonic);
        return tail;
    }

    const head = queue.head.load(.acquire);
    if (tail != head) {
        return null;
    }

    queue.push(&queue.stub);
    next_maybe = tail.next.load(.acquire);
    if (next_maybe) |next| {
        queue.tail.store(.monotonic, next);
        return tail;
    }
    return null;
}

const std = @import("std");
