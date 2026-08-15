const std = @import("std");

const QueueEntry = struct {
    allocator: std.mem.Allocator,
    key: []u8,
    next_ticket: usize,
    serving_ticket: usize,
    next: ?*QueueEntry = null,
};

const GlobalQueue = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    head: ?*QueueEntry = null,
};

var global_queue = GlobalQueue{};

pub const FileMutationGuard = struct {
    io: std.Io,
    key: []const u8,
    released: bool = false,

    pub fn release(self: *FileMutationGuard) void {
        if (self.released) return;
        releaseUnlocked(self.io, self.key);
        self.released = true;
    }
};

pub fn acquire(io: std.Io, allocator: std.mem.Allocator, absolute_path: []const u8) !FileMutationGuard {
    const lookup_key = try canonicalizeKey(io, allocator, absolute_path);
    errdefer allocator.free(lookup_key);

    global_queue.mutex.lockUncancelable(io);
    defer global_queue.mutex.unlock(io);

    var ticket: usize = 0;
    if (findEntryLocked(lookup_key)) |entry| {
        ticket = entry.next_ticket;
        entry.next_ticket += 1;
    } else {
        const entry = try allocator.create(QueueEntry);
        errdefer allocator.destroy(entry);

        const queue_key = try allocator.dupe(u8, lookup_key);
        errdefer allocator.free(queue_key);

        entry.* = .{
            .allocator = allocator,
            .key = queue_key,
            .next_ticket = 1,
            .serving_ticket = 0,
            .next = global_queue.head,
        };
        global_queue.head = entry;
    }

    while (true) {
        const entry = findEntryLocked(lookup_key) orelse unreachable;
        if (entry.serving_ticket == ticket) {
            allocator.free(lookup_key);
            return .{
                .io = io,
                .key = entry.key,
            };
        }
        global_queue.condition.waitUncancelable(io, &global_queue.mutex);
    }
}

fn releaseUnlocked(io: std.Io, key: []const u8) void {
    global_queue.mutex.lockUncancelable(io);
    defer global_queue.mutex.unlock(io);

    const entry = findEntryLocked(key) orelse return;
    entry.serving_ticket += 1;

    if (entry.serving_ticket == entry.next_ticket) {
        removeEntryLocked(entry);
    }

    global_queue.condition.broadcast(io);
}

fn findEntryLocked(key: []const u8) ?*QueueEntry {
    var current = global_queue.head;
    while (current) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry;
        current = entry.next;
    }
    return null;
}

fn removeEntryLocked(target: *QueueEntry) void {
    var previous: ?*QueueEntry = null;
    var current = global_queue.head;
    while (current) |entry| {
        if (entry == target) {
            if (previous) |previous_entry| {
                previous_entry.next = entry.next;
            } else {
                global_queue.head = entry.next;
            }
            const allocator = entry.allocator;
            allocator.free(entry.key);
            allocator.destroy(entry);
            return;
        }
        previous = entry;
        current = entry.next;
    }
    unreachable;
}

fn canonicalizeKey(io: std.Io, allocator: std.mem.Allocator, absolute_path: []const u8) ![]u8 {
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(io, absolute_path, allocator) catch
        return try allocator.dupe(u8, absolute_path);
    defer allocator.free(real_path);
    return allocator.dupe(u8, real_path);
}

const QueueEvent = enum(u8) {
    first_start,
    first_end,
    second_start,
    second_end,
};

const QueueOrderRecorder = struct {
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    events: [4]QueueEvent = undefined,

    fn record(self: *QueueOrderRecorder, event: QueueEvent) void {
        const index = self.next_index.fetchAdd(1, .seq_cst);
        self.events[index] = event;
    }

    fn count(self: *QueueOrderRecorder) usize {
        return self.next_index.load(.seq_cst);
    }
};

const QueueThreadContext = struct {
    io: std.Io = std.testing.io,
    allocator: std.mem.Allocator = std.testing.allocator,
    path: []const u8,
    start_event: QueueEvent,
    end_event: QueueEvent,
    hold_ms: i64 = 0,
    wait_for_event_count_before_end: usize = 0,
    recorder: *QueueOrderRecorder,
};

fn runQueuedThread(context: *QueueThreadContext) void {
    var guard = acquire(context.io, context.allocator, context.path) catch unreachable;
    defer guard.release();

    context.recorder.record(context.start_event);
    if (context.wait_for_event_count_before_end > 0) {
        var elapsed_ms: usize = 0;
        while (context.recorder.count() < context.wait_for_event_count_before_end and elapsed_ms < 2000) : (elapsed_ms += 1) {
            std.Io.sleep(context.io, .fromMilliseconds(1), .awake) catch unreachable;
        }
    }
    if (context.hold_ms > 0) {
        std.Io.sleep(context.io, .fromMilliseconds(context.hold_ms), .awake) catch unreachable;
    }
    context.recorder.record(context.end_event);
}

fn eventIndex(events: [4]QueueEvent, target: QueueEvent) usize {
    for (events, 0..) |event, index| {
        if (event == target) return index;
    }
    unreachable;
}

fn makeAbsoluteTestPath(
    allocator: std.mem.Allocator,
    tmp: anytype,
    relative_path: []const u8,
) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        relative_path,
    });
}

test "file mutation queue serializes operations for the same file" {
    var recorder = QueueOrderRecorder{};
    var first = QueueThreadContext{
        .path = "/tmp/pi-file-mutation-queue-same",
        .start_event = .first_start,
        .end_event = .first_end,
        .hold_ms = 30,
        .recorder = &recorder,
    };
    var second = QueueThreadContext{
        .path = "/tmp/pi-file-mutation-queue-same",
        .start_event = .second_start,
        .end_event = .second_end,
        .recorder = &recorder,
    };

    const first_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&first});
    try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    const second_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&second});

    first_thread.join();
    second_thread.join();

    try std.testing.expectEqualSlices(
        QueueEvent,
        &[_]QueueEvent{ .first_start, .first_end, .second_start, .second_end },
        recorder.events[0..],
    );
}

test "file mutation queue releases keys when callers use different allocators" {
    var first_allocator: std.heap.DebugAllocator(.{}) = .init;
    var second_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expectEqual(.ok, first_allocator.deinit()) catch unreachable;
    defer std.testing.expectEqual(.ok, second_allocator.deinit()) catch unreachable;

    var recorder = QueueOrderRecorder{};
    var first_guard = try acquire(std.testing.io, first_allocator.allocator(), "/tmp/pi-file-mutation-queue-mixed-allocators");

    var second = QueueThreadContext{
        .allocator = second_allocator.allocator(),
        .path = "/tmp/pi-file-mutation-queue-mixed-allocators",
        .start_event = .second_start,
        .end_event = .second_end,
        .recorder = &recorder,
    };
    const second_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&second});

    try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    try std.testing.expectEqual(@as(usize, 0), recorder.count());

    first_guard.release();
    second_thread.join();

    try std.testing.expectEqualSlices(
        QueueEvent,
        &[_]QueueEvent{ .second_start, .second_end },
        recorder.events[0..2],
    );
}

test "file mutation queue allows different files to proceed in parallel" {
    var recorder = QueueOrderRecorder{};
    var first = QueueThreadContext{
        .path = "/tmp/pi-file-mutation-queue-a",
        .start_event = .first_start,
        .end_event = .first_end,
        .wait_for_event_count_before_end = 2,
        .recorder = &recorder,
    };
    var second = QueueThreadContext{
        .path = "/tmp/pi-file-mutation-queue-b",
        .start_event = .second_start,
        .end_event = .second_end,
        .recorder = &recorder,
    };

    const first_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&first});
    try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    const second_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&second});

    first_thread.join();
    second_thread.join();

    const first_start = eventIndex(recorder.events, .first_start);
    const first_end = eventIndex(recorder.events, .first_end);
    const second_start = eventIndex(recorder.events, .second_start);
    const second_end = eventIndex(recorder.events, .second_end);

    try std.testing.expect(first_start < first_end);
    try std.testing.expect(second_start < second_end);
    try std.testing.expect(second_start < first_end);
}

test "file mutation queue uses the same key for symlink aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "target.txt",
        .data = "hello\n",
    });

    const target_path = try makeAbsoluteTestPath(std.testing.allocator, tmp, "target.txt");
    defer std.testing.allocator.free(target_path);
    const symlink_path = try makeAbsoluteTestPath(std.testing.allocator, tmp, "alias.txt");
    defer std.testing.allocator.free(symlink_path);

    try std.Io.Dir.symLinkAbsolute(std.testing.io, target_path, symlink_path, .{});

    var recorder = QueueOrderRecorder{};
    var first = QueueThreadContext{
        .path = target_path,
        .start_event = .first_start,
        .end_event = .first_end,
        .hold_ms = 30,
        .recorder = &recorder,
    };
    var second = QueueThreadContext{
        .path = symlink_path,
        .start_event = .second_start,
        .end_event = .second_end,
        .recorder = &recorder,
    };

    const first_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&first});
    try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    const second_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&second});

    first_thread.join();
    second_thread.join();

    try std.testing.expectEqualSlices(
        QueueEvent,
        &[_]QueueEvent{ .first_start, .first_end, .second_start, .second_end },
        recorder.events[0..],
    );
}
