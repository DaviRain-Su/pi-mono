const std = @import("std");

/// Per-key serial operation queue with optional global concurrency limit.
/// Behavioral port of `packages/agent/src/harness/session/keyed-operation-queue.ts`.
///
/// - Operations for the same key never run concurrently (per-key ticket chain).
/// - Operations for different keys may run concurrently up to `max_concurrent_operations`.
/// - `enqueueBarrier` waits for all work accepted before it, then blocks subsequent work.
/// - `drain` waits until every accepted operation (including barrier) has finished.
///
/// API shape: each `enqueue` / `enqueueBarrier` call blocks the caller until the
/// operation completes (Zig has no Promise). Concurrent work is expressed by
/// calling these methods from different threads.
pub const KeyedOperationQueue = struct {
    pub const Options = struct {
        /// When null (default), concurrency is unlimited (matching TS).
        /// When set, must be a positive integer (>= 1).
        max_concurrent_operations: ?usize = null,
    };

    pub const Error = error{
        /// Mirrors TS `RangeError("maxConcurrentOperations must be a positive integer")`.
        InvalidMaxConcurrentOperations,
        OutOfMemory,
    };

    pub const OpFn = *const fn (ctx: *anyopaque) anyerror!void;

    allocator: std.mem.Allocator,
    io: std.Io,
    max_concurrent: ?usize,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,

    /// Ops currently inside `runOperation` (holding a permit when limited).
    active_operations: usize = 0,

    /// Barrier chain: waiters require `barrier_completed >= captured_snapshot`.
    /// `enqueueBarrier` assigns ticket `barrier_next` then increments it.
    barrier_next: u64 = 0,
    barrier_completed: u64 = 0,

    /// Per-key ticket chain. Key memory owned by the map.
    tails: std.StringHashMapUnmanaged(KeyTail) = .empty,

    const KeyTail = struct {
        next_ticket: u64 = 0,
        completed: u64 = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
    ) Error!KeyedOperationQueue {
        if (options.max_concurrent_operations) |max| {
            if (max < 1) return error.InvalidMaxConcurrentOperations;
        }
        return .{
            .allocator = allocator,
            .io = io,
            .max_concurrent = options.max_concurrent_operations,
        };
    }

    pub fn deinit(self: *KeyedOperationQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var it = self.tails.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tails.deinit(self.allocator);
    }

    /// Schedule `op` under `key` and block until it finishes.
    /// Same-key ops serialize; also waits for any barrier accepted before this call.
    pub fn enqueue(
        self: *KeyedOperationQueue,
        key: []const u8,
        ctx: *anyopaque,
        op: OpFn,
    ) anyerror!void {
        const wait = try self.beginKeyed(key);
        return self.runAfterReady(wait, ctx, op);
    }

    /// Wait for all work accepted before this call, run `op`, then release the barrier
    /// so subsequent enqueues may proceed.
    pub fn enqueueBarrier(
        self: *KeyedOperationQueue,
        ctx: *anyopaque,
        op: OpFn,
    ) anyerror!void {
        const wait = self.beginBarrier();
        return self.runAfterReady(wait, ctx, op);
    }

    /// Block until every accepted operation and barrier has finished.
    pub fn drain(self: *KeyedOperationQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (!self.isIdleLocked()) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    const WaitState = struct {
        /// For keyed ops: required key completed count before this ticket may run.
        key_required: ?u64 = null,
        key_owned: ?[]const u8 = null,
        /// Required barrier_completed before this op may run.
        barrier_required: u64,
        /// For barrier ops: the ticket this barrier will complete.
        barrier_ticket: ?u64 = null,
        /// Snapshot of per-key next_ticket values that must complete before a barrier runs.
        /// Entries are borrowed map keys (valid while mutex held / until barrier finishes).
        barrier_key_requirements: ?[]KeyRequirement = null,
    };

    const KeyRequirement = struct {
        key: []const u8,
        required_completed: u64,
    };

    fn beginKeyed(self: *KeyedOperationQueue, key: []const u8) Error!WaitState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const gop = try self.tails.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            // Replace the borrowed lookup key with an owned copy.
            gop.key_ptr.* = self.allocator.dupe(u8, key) catch {
                _ = self.tails.remove(key);
                return error.OutOfMemory;
            };
            gop.value_ptr.* = .{};
        }
        const my_ticket = gop.value_ptr.next_ticket;
        gop.value_ptr.next_ticket = my_ticket + 1;

        return .{
            .key_required = my_ticket,
            .key_owned = gop.key_ptr.*,
            .barrier_required = self.barrier_next,
            .barrier_ticket = null,
            .barrier_key_requirements = null,
        };
    }

    fn beginBarrier(self: *KeyedOperationQueue) WaitState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const my_ticket = self.barrier_next;
        self.barrier_next = my_ticket + 1;

        // Snapshot every key that still has unfinished tickets. Keys are borrowed
        // from the map (keys are never freed until deinit, so pointers stay valid).
        var reqs: std.ArrayList(KeyRequirement) = .empty;
        errdefer reqs.deinit(self.allocator);
        var it = self.tails.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.completed < entry.value_ptr.next_ticket) {
                reqs.append(self.allocator, .{
                    .key = entry.key_ptr.*,
                    .required_completed = entry.value_ptr.next_ticket,
                }) catch {
                    // Partial snapshot is still correct for the keys captured so far;
                    // missing keys with unfinished work will be covered only if they
                    // reappear as keyed deps of later work. Prefer fail-open partial
                    // over aborting an already-assigned barrier ticket.
                    break;
                };
            }
        }

        const slice = reqs.toOwnedSlice(self.allocator) catch null;

        return .{
            .key_required = null,
            .key_owned = null,
            // Wait for previous barriers (completed >= my_ticket).
            .barrier_required = my_ticket,
            .barrier_ticket = my_ticket,
            .barrier_key_requirements = slice,
        };
    }

    fn runAfterReady(
        self: *KeyedOperationQueue,
        wait: WaitState,
        ctx: *anyopaque,
        op: OpFn,
    ) anyerror!void {
        // Wait for deps + permit, then leave lock while running.
        self.mutex.lockUncancelable(self.io);
        while (!self.depsReadyLocked(wait) or !self.permitAvailableLocked()) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        self.active_operations += 1;
        self.mutex.unlock(self.io);

        const op_result = op(ctx);

        self.mutex.lockUncancelable(self.io);
        self.releasePermitLocked();
        self.completeWaitLocked(wait);
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);

        return op_result;
    }

    fn depsReadyLocked(self: *KeyedOperationQueue, wait: WaitState) bool {
        if (self.barrier_completed < wait.barrier_required) return false;

        if (wait.key_required) |required| {
            const key = wait.key_owned orelse return false;
            const tail = self.tails.get(key) orelse return false;
            if (tail.completed < required) return false;
        }

        if (wait.barrier_key_requirements) |reqs| {
            for (reqs) |req| {
                const tail = self.tails.get(req.key) orelse continue;
                if (tail.completed < req.required_completed) return false;
            }
        }

        return true;
    }

    fn permitAvailableLocked(self: *const KeyedOperationQueue) bool {
        const max = self.max_concurrent orelse return true;
        return self.active_operations < max;
    }

    fn releasePermitLocked(self: *KeyedOperationQueue) void {
        // Matching TS: when limited, active_operations counts held permits.
        // Always decrement the active counter we incremented in runAfterReady.
        if (self.active_operations > 0) {
            self.active_operations -= 1;
        }
    }

    fn completeWaitLocked(self: *KeyedOperationQueue, wait: WaitState) void {
        if (wait.key_required) |required| {
            if (wait.key_owned) |key| {
                if (self.tails.getPtr(key)) |tail| {
                    // Tickets complete in order; this op held ticket `required`.
                    std.debug.assert(tail.completed == required);
                    tail.completed = required + 1;
                    // Keep idle keys in the map so barrier snapshots that borrowed
                    // key pointers remain valid until deinit. Session backends use a
                    // bounded key set (session ids / paths).
                }
            }
        }

        if (wait.barrier_ticket) |ticket| {
            std.debug.assert(self.barrier_completed == ticket);
            self.barrier_completed = ticket + 1;
            if (wait.barrier_key_requirements) |reqs| {
                self.allocator.free(reqs);
            }
        }
    }

    fn isIdleLocked(self: *const KeyedOperationQueue) bool {
        if (self.active_operations != 0) return false;
        if (self.barrier_completed != self.barrier_next) return false;
        var it = self.tails.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.completed != entry.value_ptr.next_ticket) return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Offline tests on shipped public API
// ---------------------------------------------------------------------------

const TestGate = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    flag: bool = false,

    fn init(io: std.Io) TestGate {
        return .{ .io = io };
    }

    fn open(self: *TestGate) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.flag = true;
        self.condition.broadcast(self.io);
    }

    fn wait(self: *TestGate) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.flag) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }
};

const BlockingCtx = struct {
    started: *TestGate,
    release: *TestGate,
    running: *std.atomic.Value(usize),
    peak_running: *std.atomic.Value(usize),
    fail: bool = false,

    fn run(ptr: *anyopaque) anyerror!void {
        const self: *BlockingCtx = @ptrCast(@alignCast(ptr));
        const now = self.running.fetchAdd(1, .seq_cst) + 1;
        var peak = self.peak_running.load(.seq_cst);
        while (now > peak) {
            if (self.peak_running.cmpxchgWeak(peak, now, .seq_cst, .seq_cst)) |cur| {
                peak = cur;
            } else break;
        }
        self.started.open();
        self.release.wait();
        _ = self.running.fetchSub(1, .seq_cst);
        if (self.fail) return error.OperationFailed;
    }
};

const ThreadArgs = struct {
    queue: *KeyedOperationQueue,
    key: ?[]const u8,
    ctx: *anyopaque,
    op: KeyedOperationQueue.OpFn,
    result: *?anyerror,
    done: *TestGate,

    fn runKeyed(ptr: *anyopaque) void {
        const self: *ThreadArgs = @ptrCast(@alignCast(ptr));
        const r = self.queue.enqueue(self.key.?, self.ctx, self.op);
        self.result.* = if (r) |_| null else |e| e;
        self.done.open();
    }

    fn runBarrier(ptr: *anyopaque) void {
        const self: *ThreadArgs = @ptrCast(@alignCast(ptr));
        const r = self.queue.enqueueBarrier(self.ctx, self.op);
        self.result.* = if (r) |_| null else |e| e;
        self.done.open();
    }
};

fn sleepMs(ms: u64) void {
    std.Io.sleep(std.testing.io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

// Pi: packages/agent/src/harness/session/keyed-operation-queue.ts "maxConcurrentOperations must be a positive integer"
// Pi: packages/agent/test/harness/repo.test.ts "rejects invalid JSONL concurrency limit"
test "KeyedOperationQueue rejects invalid max_concurrent_operations" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.InvalidMaxConcurrentOperations,
        KeyedOperationQueue.init(allocator, io, .{ .max_concurrent_operations = 0 }),
    );

    var ok_queue = try KeyedOperationQueue.init(allocator, io, .{ .max_concurrent_operations = 1 });
    defer ok_queue.deinit();
    var unlimited = try KeyedOperationQueue.init(allocator, io, .{});
    defer unlimited.deinit();
}

// Pi: packages/agent/test/harness/repo.test.ts "serializes appends to the same session"
test "KeyedOperationQueue serializes same-key operations" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var queue = try KeyedOperationQueue.init(allocator, io, .{});
    defer queue.deinit();

    var started1 = TestGate.init(io);
    var release1 = TestGate.init(io);
    var started2 = TestGate.init(io);
    var release2 = TestGate.init(io);
    var running = std.atomic.Value(usize).init(0);
    var peak = std.atomic.Value(usize).init(0);

    var ctx1 = BlockingCtx{
        .started = &started1,
        .release = &release1,
        .running = &running,
        .peak_running = &peak,
    };
    var ctx2 = BlockingCtx{
        .started = &started2,
        .release = &release2,
        .running = &running,
        .peak_running = &peak,
    };

    var result1: ?anyerror = null;
    var result2: ?anyerror = null;
    var done1 = TestGate.init(io);
    var done2 = TestGate.init(io);

    var args1 = ThreadArgs{
        .queue = &queue,
        .key = "session-a",
        .ctx = &ctx1,
        .op = BlockingCtx.run,
        .result = &result1,
        .done = &done1,
    };
    var args2 = ThreadArgs{
        .queue = &queue,
        .key = "session-a",
        .ctx = &ctx2,
        .op = BlockingCtx.run,
        .result = &result2,
        .done = &done2,
    };

    const t1 = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args1});
    started1.wait();
    // Second same-key op must not start while first is held.
    const t2 = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args2});
    sleepMs(30);
    try std.testing.expect(!started2.flag);
    try std.testing.expectEqual(@as(usize, 1), peak.load(.seq_cst));

    release1.open();
    started2.wait();
    release2.open();
    done1.wait();
    done2.wait();
    t1.join();
    t2.join();

    try std.testing.expect(result1 == null);
    try std.testing.expect(result2 == null);
    try std.testing.expectEqual(@as(usize, 1), peak.load(.seq_cst));
}

// Pi: packages/agent/src/harness/session/keyed-operation-queue.ts "different keys concurrent"
test "KeyedOperationQueue allows concurrent different keys when unlimited" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var queue = try KeyedOperationQueue.init(allocator, io, .{});
    defer queue.deinit();

    var started1 = TestGate.init(io);
    var release1 = TestGate.init(io);
    var started2 = TestGate.init(io);
    var release2 = TestGate.init(io);
    var running = std.atomic.Value(usize).init(0);
    var peak = std.atomic.Value(usize).init(0);

    var ctx1 = BlockingCtx{
        .started = &started1,
        .release = &release1,
        .running = &running,
        .peak_running = &peak,
    };
    var ctx2 = BlockingCtx{
        .started = &started2,
        .release = &release2,
        .running = &running,
        .peak_running = &peak,
    };

    var result1: ?anyerror = null;
    var result2: ?anyerror = null;
    var done1 = TestGate.init(io);
    var done2 = TestGate.init(io);

    var args1 = ThreadArgs{
        .queue = &queue,
        .key = "a",
        .ctx = &ctx1,
        .op = BlockingCtx.run,
        .result = &result1,
        .done = &done1,
    };
    var args2 = ThreadArgs{
        .queue = &queue,
        .key = "b",
        .ctx = &ctx2,
        .op = BlockingCtx.run,
        .result = &result2,
        .done = &done2,
    };

    const t1 = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args1});
    const t2 = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args2});
    started1.wait();
    started2.wait();
    try std.testing.expectEqual(@as(usize, 2), peak.load(.seq_cst));

    release1.open();
    release2.open();
    done1.wait();
    done2.wait();
    t1.join();
    t2.join();
}

// Pi: packages/agent/test/harness/repo.test.ts "allows overriding the JSONL concurrency limit"
test "KeyedOperationQueue respects max_concurrent_operations across keys" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var queue = try KeyedOperationQueue.init(allocator, io, .{ .max_concurrent_operations = 1 });
    defer queue.deinit();

    var started1 = TestGate.init(io);
    var release1 = TestGate.init(io);
    var started2 = TestGate.init(io);
    var release2 = TestGate.init(io);
    var running = std.atomic.Value(usize).init(0);
    var peak = std.atomic.Value(usize).init(0);

    var ctx1 = BlockingCtx{
        .started = &started1,
        .release = &release1,
        .running = &running,
        .peak_running = &peak,
    };
    var ctx2 = BlockingCtx{
        .started = &started2,
        .release = &release2,
        .running = &running,
        .peak_running = &peak,
    };

    var result1: ?anyerror = null;
    var result2: ?anyerror = null;
    var done1 = TestGate.init(io);
    var done2 = TestGate.init(io);

    var args1 = ThreadArgs{
        .queue = &queue,
        .key = "first",
        .ctx = &ctx1,
        .op = BlockingCtx.run,
        .result = &result1,
        .done = &done1,
    };
    var args2 = ThreadArgs{
        .queue = &queue,
        .key = "second",
        .ctx = &ctx2,
        .op = BlockingCtx.run,
        .result = &result2,
        .done = &done2,
    };

    const t1 = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args1});
    started1.wait();
    const t2 = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args2});
    sleepMs(30);
    try std.testing.expect(!started2.flag);
    try std.testing.expectEqual(@as(usize, 1), peak.load(.seq_cst));

    release1.open();
    started2.wait();
    release2.open();
    done1.wait();
    done2.wait();
    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(usize, 1), peak.load(.seq_cst));
}

// Pi: packages/agent/test/harness/repo.test.ts "releases JSONL concurrency capacity after an operation fails"
test "KeyedOperationQueue releases permit after operation failure" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var queue = try KeyedOperationQueue.init(allocator, io, .{ .max_concurrent_operations = 1 });
    defer queue.deinit();

    var started1 = TestGate.init(io);
    var release1 = TestGate.init(io);
    var started2 = TestGate.init(io);
    var release2 = TestGate.init(io);
    var running = std.atomic.Value(usize).init(0);
    var peak = std.atomic.Value(usize).init(0);

    var ctx1 = BlockingCtx{
        .started = &started1,
        .release = &release1,
        .running = &running,
        .peak_running = &peak,
        .fail = true,
    };
    var ctx2 = BlockingCtx{
        .started = &started2,
        .release = &release2,
        .running = &running,
        .peak_running = &peak,
    };

    var result1: ?anyerror = null;
    var result2: ?anyerror = null;
    var done1 = TestGate.init(io);
    var done2 = TestGate.init(io);

    var args1 = ThreadArgs{
        .queue = &queue,
        .key = "first",
        .ctx = &ctx1,
        .op = BlockingCtx.run,
        .result = &result1,
        .done = &done1,
    };
    var args2 = ThreadArgs{
        .queue = &queue,
        .key = "second",
        .ctx = &ctx2,
        .op = BlockingCtx.run,
        .result = &result2,
        .done = &done2,
    };

    const t1 = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args1});
    started1.wait();
    const t2 = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args2});
    sleepMs(20);
    try std.testing.expect(!started2.flag);

    release1.open();
    done1.wait();
    try std.testing.expect(result1 != null);

    started2.wait();
    release2.open();
    done2.wait();
    t1.join();
    t2.join();
    try std.testing.expect(result2 == null);
}

// Pi: packages/agent/test/harness/repo.test.ts "uses listing as a barrier between accepted session operations"
test "KeyedOperationQueue barrier orders around keyed operations" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var queue = try KeyedOperationQueue.init(allocator, io, .{});
    defer queue.deinit();

    var started_a = TestGate.init(io);
    var release_a = TestGate.init(io);
    var started_barrier = TestGate.init(io);
    var release_barrier = TestGate.init(io);
    var started_b = TestGate.init(io);
    var release_b = TestGate.init(io);
    var running = std.atomic.Value(usize).init(0);
    var peak = std.atomic.Value(usize).init(0);

    var ctx_a = BlockingCtx{
        .started = &started_a,
        .release = &release_a,
        .running = &running,
        .peak_running = &peak,
    };
    var ctx_barrier = BlockingCtx{
        .started = &started_barrier,
        .release = &release_barrier,
        .running = &running,
        .peak_running = &peak,
    };
    var ctx_b = BlockingCtx{
        .started = &started_b,
        .release = &release_b,
        .running = &running,
        .peak_running = &peak,
    };

    var result_a: ?anyerror = null;
    var result_barrier: ?anyerror = null;
    var result_b: ?anyerror = null;
    var done_a = TestGate.init(io);
    var done_barrier = TestGate.init(io);
    var done_b = TestGate.init(io);

    var args_a = ThreadArgs{
        .queue = &queue,
        .key = "first",
        .ctx = &ctx_a,
        .op = BlockingCtx.run,
        .result = &result_a,
        .done = &done_a,
    };
    var args_barrier = ThreadArgs{
        .queue = &queue,
        .key = null,
        .ctx = &ctx_barrier,
        .op = BlockingCtx.run,
        .result = &result_barrier,
        .done = &done_barrier,
    };
    var args_b = ThreadArgs{
        .queue = &queue,
        .key = "second",
        .ctx = &ctx_b,
        .op = BlockingCtx.run,
        .result = &result_b,
        .done = &done_b,
    };

    const t_a = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args_a});
    started_a.wait();

    const t_barrier = try std.Thread.spawn(.{}, ThreadArgs.runBarrier, .{&args_barrier});
    sleepMs(20);
    // Barrier must not start while A is still running.
    try std.testing.expect(!started_barrier.flag);

    const t_b = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args_b});
    sleepMs(20);
    // B was accepted after the barrier, so it waits for the barrier.
    try std.testing.expect(!started_b.flag);

    release_a.open();
    started_barrier.wait();
    sleepMs(20);
    try std.testing.expect(!started_b.flag);

    release_barrier.open();
    started_b.wait();
    release_b.open();

    done_a.wait();
    done_barrier.wait();
    done_b.wait();
    t_a.join();
    t_barrier.join();
    t_b.join();

    try std.testing.expect(result_a == null);
    try std.testing.expect(result_barrier == null);
    try std.testing.expect(result_b == null);
}

// Pi: packages/agent/test/harness/repo.test.ts "waits for every accepted session operation during disposal"
test "KeyedOperationQueue drain waits for in-flight work" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var queue = try KeyedOperationQueue.init(allocator, io, .{});
    defer queue.deinit();

    var started = TestGate.init(io);
    var release = TestGate.init(io);
    var running = std.atomic.Value(usize).init(0);
    var peak = std.atomic.Value(usize).init(0);
    var ctx = BlockingCtx{
        .started = &started,
        .release = &release,
        .running = &running,
        .peak_running = &peak,
    };

    var result: ?anyerror = null;
    var done = TestGate.init(io);
    var args = ThreadArgs{
        .queue = &queue,
        .key = "session",
        .ctx = &ctx,
        .op = BlockingCtx.run,
        .result = &result,
        .done = &done,
    };

    const t = try std.Thread.spawn(.{}, ThreadArgs.runKeyed, .{&args});
    started.wait();

    var drain_done = TestGate.init(io);
    const DrainArgs = struct {
        queue: *KeyedOperationQueue,
        done: *TestGate,
        fn run(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.queue.drain();
            self.done.open();
        }
    };
    var drain_args = DrainArgs{ .queue = &queue, .done = &drain_done };
    const drain_thread = try std.Thread.spawn(.{}, DrainArgs.run, .{&drain_args});
    sleepMs(30);
    try std.testing.expect(!drain_done.flag);

    release.open();
    done.wait();
    drain_done.wait();
    t.join();
    drain_thread.join();
    try std.testing.expect(result == null);
}
