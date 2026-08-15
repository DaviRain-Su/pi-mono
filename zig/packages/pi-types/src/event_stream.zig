const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const event_stream_guard = @import("event_stream_guard.zig");

/// ISS-502 stream invariants for `types.AssistantMessageEvent`:
/// - INV-2: each `content_index` is stable and never reused within a stream.
/// - INV-3: per-block ordering is `_start -> _delta* -> _end`.
/// - INV-4: `done` is the final event for a successful stream.
/// - INV-5: `error_event` terminates the stream with error stop metadata.
///
/// In debug builds, `AssistantMessageEvent` streams enforce these invariants
/// via `EventOrderingGuard` on every `push()`. Violations panic so providers
/// surface ordering bugs in CI rather than reaching downstream accumulators.
/// Release builds skip the guard entirely.
/// Generic event stream for async iteration.
/// T is the event type, R is the result type.
/// `is_complete_fn` and `extract_result_fn` are comptime function parameters
/// so the streaming hot path can inline them and avoid an indirect call per
/// `push()` / result extraction.
pub fn EventStream(
    comptime T: type,
    comptime R: type,
    comptime is_complete_fn: fn (event: T) bool,
    comptime extract_result_fn: fn (event: T) R,
) type {
    const enable_guard = builtin.mode == .Debug and T == types.AssistantMessageEvent;
    const GuardField = if (enable_guard) event_stream_guard.EventOrderingGuard else void;
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        queue: std.ArrayList(T),
        read_index: usize = 0,
        done: bool = false,
        final_result: ?R = null,
        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,
        io: std.Io,
        guard: GuardField,

        pub const IteratorResult = struct {
            value: ?T,
            done: bool,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
        ) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .queue = std.ArrayList(T).empty,
                .done = false,
                .final_result = null,
                .guard = if (enable_guard) event_stream_guard.EventOrderingGuard.init(allocator) else {},
            };
        }

        pub fn deinit(self: *Self) void {
            if (enable_guard) self.guard.deinit();
            self.queue.deinit(self.allocator);
        }

        pub fn push(self: *Self, event: T) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.done) return;

            if (enable_guard) {
                self.guard.validate(event) catch |err| {
                    std.debug.panic(
                        "AssistantMessageEventStream ordering violation: {s} (event_type={s}, content_index={?})",
                        .{ @errorName(err), @tagName(event.event_type), event.content_index },
                    );
                };
            }

            if (is_complete_fn(event)) {
                self.done = true;
                self.final_result = extract_result_fn(event);
            }

            self.queue.append(self.allocator, event) catch {
                self.done = true;
                self.condition.broadcast(self.io);
                return;
            };
            self.condition.signal(self.io);
        }

        pub fn end(self: *Self, final_result: ?R) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.done = true;
            if (final_result) |r| {
                self.final_result = r;
            }

            self.condition.broadcast(self.io);
        }

        pub fn next(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            while (self.read_index >= self.queue.items.len and !self.done) {
                self.condition.waitUncancelable(self.io, &self.mutex);
            }

            if (self.read_index < self.queue.items.len) {
                const event = self.queue.items[self.read_index];
                self.read_index += 1;
                return event;
            }

            return null;
        }

        pub fn result(self: *Self) ?R {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.final_result;
        }
    };
}

/// Check if an AssistantMessageEvent indicates completion
fn isCompleteEvent(event: types.AssistantMessageEvent) bool {
    return event.event_type == .done or event.event_type == .error_event;
}

/// Extract the final result from a completion event
fn extractResult(event: types.AssistantMessageEvent) types.AssistantMessage {
    if (event.event_type == .done) {
        return event.message.?;
    } else if (event.event_type == .error_event) {
        if (event.message) |message| return message;

        // For error events, create an error message
        return .{
            .role = "assistant",
            .content = &[_]types.ContentBlock{},
            .api = "",
            .provider = "",
            .model = "",
            .usage = types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = event.error_message,
            .timestamp = 0,
        };
    }
    unreachable;
}

pub const AssistantMessageEventStream = EventStream(
    types.AssistantMessageEvent,
    types.AssistantMessage,
    isCompleteEvent,
    extractResult,
);

pub fn createAssistantMessageEventStream(allocator: std.mem.Allocator, io: std.Io) AssistantMessageEventStream {
    return AssistantMessageEventStream.init(allocator, io);
}

test "EventStream basic operations" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    var stream = AssistantMessageEventStream.init(allocator, io);
    defer stream.deinit();

    // Push a start event
    stream.push(.{
        .event_type = .start,
    });

    // Push a text block start, delta, end
    stream.push(.{
        .event_type = .text_start,
        .content_index = 0,
    });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "Hello",
    });
    stream.push(.{
        .event_type = .text_end,
        .content_index = 0,
    });

    // Push done event
    const msg = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1234567890,
    };
    stream.push(.{
        .event_type = .done,
        .message = msg,
    });

    // Read events
    const event1 = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    _ = stream.next().?; // text_start
    const event2 = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, event2.event_type);
    try std.testing.expectEqualStrings("Hello", event2.delta.?);
    _ = stream.next().?; // text_end

    const event3 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event3.event_type);

    // Stream should be done
    try std.testing.expect(stream.next() == null);

    // Check final result
    const result = stream.result().?;
    try std.testing.expectEqualStrings("gpt-4", result.model);
}

test "AssistantMessageEventStream error event result preserves terminal message identity" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    var stream = createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const message = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .response_id = "resp_123",
        .usage = .{
            .input = 1,
            .output = 2,
            .total_tokens = 3,
        },
        .stop_reason = .error_reason,
        .error_message = "HTTP 500: upstream failed",
        .timestamp = 42,
    };

    stream.push(.{
        .event_type = .error_event,
        .message = message,
        .error_message = message.error_message,
    });

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, terminal.error_message.?);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(terminal.message.?.role, result.role);
    try std.testing.expectEqualStrings(terminal.message.?.api, result.api);
    try std.testing.expectEqualStrings(terminal.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(terminal.message.?.model, result.model);
    try std.testing.expectEqualStrings(terminal.message.?.response_id.?, result.response_id.?);
    try std.testing.expectEqual(terminal.message.?.usage.input, result.usage.input);
    try std.testing.expectEqual(terminal.message.?.usage.output, result.usage.output);
    try std.testing.expectEqual(terminal.message.?.usage.total_tokens, result.usage.total_tokens);
    try std.testing.expectEqual(terminal.message.?.stop_reason, result.stop_reason);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(terminal.message.?.timestamp, result.timestamp);
}

test "AssistantMessageEventStream ignores events after terminal error" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    var stream = createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "faux",
        .provider = "faux",
        .model = "faux-model",
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "ProviderParseFailure",
        .timestamp = 0,
    };

    stream.push(.{
        .event_type = .error_event,
        .message = message,
        .error_message = message.error_message,
    });
    stream.push(.{ .event_type = .text_delta, .delta = "late" });
    stream.push(.{
        .event_type = .done,
        .message = .{
            .content = &[_]types.ContentBlock{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-model",
            .usage = types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
    });

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("ProviderParseFailure", result.error_message.?);
}

test "EventStream end without events" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    var stream = AssistantMessageEventStream.init(allocator, io);
    defer stream.deinit();

    const msg = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1234567890,
    };

    stream.end(msg);

    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings("gpt-4", result.model);
}

test "EventStream next blocks until producer pushes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var stream = AssistantMessageEventStream.init(allocator, io);
    defer stream.deinit();

    const TestContext = struct {
        stream: *AssistantMessageEventStream,

        fn producer(ctx: *@This()) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
            ctx.stream.push(.{ .event_type = .start });
        }
    };

    var ctx = TestContext{ .stream = &stream };
    const producer_thread = try std.Thread.spawn(.{}, TestContext.producer, .{&ctx});
    defer producer_thread.join();

    const started_at = std.Io.Clock.awake.now(io);
    const event = stream.next().?;
    const elapsed_ns = started_at.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;

    try std.testing.expectEqual(types.EventType.start, event.event_type);
    try std.testing.expect(elapsed_ns >= 20 * std.time.ns_per_ms);
}

test "EventStream supports single-producer single-consumer concurrency" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const intIsComplete = struct {
        fn f(_: u32) bool {
            return false;
        }
    }.f;
    const intExtractResult = struct {
        fn f(event: u32) u32 {
            return event;
        }
    }.f;
    const IntStream = EventStream(u32, u32, intIsComplete, intExtractResult);

    var stream = IntStream.init(allocator, io);
    defer stream.deinit();

    const TestContext = struct {
        stream: *IntStream,
        count: u32,

        fn producer(ctx: *@This()) void {
            for (0..ctx.count) |index| {
                ctx.stream.push(@intCast(index));
            }
            ctx.stream.end(null);
        }
    };

    var ctx = TestContext{
        .stream = &stream,
        .count = 128,
    };

    const producer_thread = try std.Thread.spawn(.{}, TestContext.producer, .{&ctx});
    defer producer_thread.join();

    var expected: u32 = 0;
    while (stream.next()) |value| {
        try std.testing.expectEqual(expected, value);
        expected += 1;
    }

    try std.testing.expectEqual(ctx.count, expected);
}
