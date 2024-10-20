const std = @import("std");

const mem = std.mem;

const Allocator = mem.Allocator;
const Atomic = std.atomic.Value;
const Worker = std.Thread;

const assert = std.debug.assert;


allocator: Allocator,
task_pool: TaskPool,

threads: Atomic(*Thread),
workers: []Worker,
tasks: TaskQueue,

sync: Atomic(Sync) = Atomic(Sync).init(.{}),
idle_event: Event,



const ThreadPool = @This();

const TaskPool = std.heap.MemoryPool(Task);

const Sync = packed struct(u32) {
	idle: u10 = 0,
	spawned: u10 = 0,
	stealing: u10 = 0,
	_1: u1,
	shutdown: bool = false,

	pub inline fn atomicShutdown(atomic_sync: *Atomic(Sync)) void {
		const shutdown_bit_pos = @bitOffsetOf(Sync, "shutdown");
		atomic_sync.bitSet(shutdown_bit_pos, .acq_rel);
	}
};

const Event = struct {
	state: Atomic(Event.State),

	pub const State = enum(u32) {
		empty,
		waiting,
		notified,
		shutdown,
	};

	const Futex = std.Thread.Futex;

	noinline fn wait(event: *Event) void {
		var acquire_with: Event.State = .empty;
		var state = event.state.load(.monotonic);

		while (true) {
			switch (state) {
				.shutdown => {
					_ = event.state.load(.acquire);
					return;
				},
				.notified => if (event.state.cmpxchgWeak(
					state,
					acquire_with,
					.acquire,
					.monotonic,
				)) |s| {
					state = s;
					continue;
				} else {
					return;
				},
				.empty => if (event.state.cmpxchgWeak(
					state,
					.waiting,
					.monotonic,
					.monotonic,
				)) |s| {
					state = s;
					continue;
				},
				.waiting => {},
			}

			Futex.wait(@ptrCast(&event.state), @intFromEnum(Event.State.waiting));
			state = event.state.load(.monotonic);
			acquire_with = .waiting;
		}
	}

	noinline fn wake(event: *Event, release_with: Event.State, wake_threads: u32) void {
		const state = event.state.swap(release_with, .release);
		if (state == .waiting) {
			Futex.wake(@ptrCast(&event.state), wake_threads);
		}
	}

	pub fn notify(event: *Event) void {
		event.wake(.notified, 1);
	}

	pub fn shutdown(event: *Event) void {
		event.wake(.shutdown, std.math.maxInt(u32));
	}
};


pub const Task = struct {
	next: ?*Task,
	callback: Task.callbackFn,
	context: *anyopaque,

	pub const callbackFn = fn (context: *anyopaque) void;

	pub const Batch = struct {
		size: usize,
		head: ?*Task,
		tail: ?*Task,

		pub fn from(task: *Task) Batch {
			return .{
				.size = 1,
				.head = task,
				.tail = task,
			};
		}

		pub fn absorb(self: *Batch, batch: Batch) void {
			if (batch.len == 0) return;
			if (self.len == 0) {
				self.* = batch;
			} else {
				self.tail.?.next = batch.head.?.next;
				self.tail = batch.tail;
				self.size += batch.size;
			}
		}
	};
};

pub const Thread = struct {
	next: ?*Thread,

};


pub const Options = struct {
	max_thread_count: usize = 16,
};
pub fn init(allocator: Allocator, options: Options) Allocator.Error!ThreadPool {
	const workers = allocator.alloc(Worker, options.thread_count);
	errdefer allocator.free(workers);


}


pub fn createTask(tp: *ThreadPool, comptime function: Task.callbackFn, context: *anyopaque) *Task {

}

pub fn destroyTask(tp: *ThreadPool, task: *Task) void {
	
}

pub noinline fn schedule(tp: *ThreadPool, batch: Task.Batch) Allocator.Error!void {
	assert(batch.size > 0);
}

pub fn run(tp: *ThreadPool) void {
	while (tp.tasks.pop()) |task| {
		(task.callback())(task);
	}
}

pub fn shutdown(tp: *ThreadPool) void {
	var sync = tp.sync.load(.monotonic);
	while (!sync.shutdown) {
		var new_sync = sync;
		new_sync.shutdown = true;

		sync = tp.sync.cmpxchgWeak(sync, new_sync, .acq_rel, .monotonic) orelse {
			tp.idle_event.shutdown();
			return;
		};
	}
}

pub const TaskQueue = struct {
	head: u32 = 0,
	tail: u32 = 0,
	buffer: [capacity]*Task = undefined,

	pub const capacity = 256;

	pub fn push(tq: *TaskQueue, task: *Task) bool {
		const h = @atomicLoad(u32, &tq.head, .monotonic);
		if (tq.tail -% h >= TaskQueue.capacity)
			return false;
		@atomicStore(*Task, &tq.buffer[tq.tail % TaskQueue.capacity], task, .unordered);
		@atomicStore(u32, &tq.tail, tq.tail +% 1, .release);
		return true;
	}

	pub fn pop(tq: *TaskQueue) ?*Task {
		var h = @atomicLoad(u32, &tq.head, .monotonic);
		while (h != tq.tail) {
			h = @cmpxchgStrong(u32, &tq.head, h, h +% 1, .acquire, .acquire)
				orelse return tq.buffer[tq.head % TaskQueue.capacity];
		}
		return null;
	}

	pub fn steal(tq: *TaskQueue, into: *TaskQueue) ?*Task {
		while (true) {
			const h = @atomicLoad(u32, &tq.head, .acquire);
			const t = @atomicLoad(u32, &tq.tail, .acquire);
			const diff = (t -% h);
			if (diff > TaskQueue.capacity) continue;
			if (t == h) return null;

			const half = diff - (diff / 2);
			for (0..half) |i| {
				const task = @atomicLoad(*Task, &tq.buffer[(h +% i) % TaskQueue.capacity], .unordered);
				@atomicStore(*Task, &into.buffer[(into.tail +% i) % TaskQueue.capacity], task, .unordered);

				_ = @cmpxchgStrong(u32, &tq.head, h, h +% half, .acq_rel, .acquire) orelse {
					const new_tail = into.tail +% half;
					@atomicStore(u32, &into.tail, new_tail -% 1, .release);
					return into.buffer[new_tail % TaskQueue.capacity];
				};
			}
		}
	}
};
