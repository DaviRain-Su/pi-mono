const std = @import("std");
const types = @import("types.zig");

pub const EventOrderingError = error{
    MissingContentIndex,
    ContentIndexReused,
    ContentBlockAlreadyStarted,
    ContentBlockDeltaBeforeStart,
    ContentBlockEndBeforeStart,
    ContentBlockKindMismatch,
    ContentBlockDeltaAfterEnd,
    ContentBlockEndAfterEnd,
    ContentBlockOpenAtTerminal,
    EventAfterTerminal,
};

const BlockKind = enum {
    text,
    thinking,
    tool_call,
};

const BlockState = enum {
    open,
    closed,
};

const BlockEntry = struct {
    kind: BlockKind,
    state: BlockState,
};

const BlockEventPhase = enum {
    start,
    delta,
    end,
};

const BlockEventMapping = struct {
    event_type: types.EventType,
    kind: BlockKind,
    phase: BlockEventPhase,
};

const BLOCK_EVENT_MAPPINGS = .{
    BlockEventMapping{ .event_type = .text_start, .kind = .text, .phase = .start },
    BlockEventMapping{ .event_type = .thinking_start, .kind = .thinking, .phase = .start },
    BlockEventMapping{ .event_type = .toolcall_start, .kind = .tool_call, .phase = .start },
    BlockEventMapping{ .event_type = .text_delta, .kind = .text, .phase = .delta },
    BlockEventMapping{ .event_type = .thinking_delta, .kind = .thinking, .phase = .delta },
    BlockEventMapping{ .event_type = .toolcall_delta, .kind = .tool_call, .phase = .delta },
    BlockEventMapping{ .event_type = .text_end, .kind = .text, .phase = .end },
    BlockEventMapping{ .event_type = .thinking_end, .kind = .thinking, .phase = .end },
    BlockEventMapping{ .event_type = .toolcall_end, .kind = .tool_call, .phase = .end },
};

/// Debug/test guard for ISS-504 / INV-3 assistant event streams.
///
/// The guard is intentionally standalone so tests and debug-only wrappers can
/// validate provider event sequences without changing the production queueing
/// semantics of `AssistantMessageEventStream`. It tracks each `content_index`
/// through one `_start -> _delta* -> _end` lifecycle and rejects reuse.
pub const EventOrderingGuard = struct {
    blocks: std.AutoHashMap(u32, BlockEntry),
    terminal_seen: bool = false,

    pub fn init(allocator: std.mem.Allocator) EventOrderingGuard {
        return .{
            .blocks = std.AutoHashMap(u32, BlockEntry).init(allocator),
        };
    }

    pub fn deinit(self: *EventOrderingGuard) void {
        self.blocks.deinit();
        self.* = undefined;
    }

    pub fn validate(self: *EventOrderingGuard, event: types.AssistantMessageEvent) EventOrderingError!void {
        if (self.terminal_seen) return error.EventAfterTerminal;

        switch (event.event_type) {
            .start => {},
            .done => try self.validateSuccessTerminal(),
            // INV-5: error_event terminates without requiring providers to
            // first close every open block. Stream-level provider errors
            // (throttling, service_unavailable, validation_exception, etc.)
            // can fire mid-block; downstream accumulators reset state on
            // error rather than relying on synthetic `_end` events.
            .error_event => self.terminal_seen = true,
            else => try self.dispatchBlockEvent(event),
        }
    }

    fn dispatchBlockEvent(self: *EventOrderingGuard, event: types.AssistantMessageEvent) EventOrderingError!void {
        inline for (BLOCK_EVENT_MAPPINGS) |mapping| {
            if (event.event_type == mapping.event_type) {
                switch (mapping.phase) {
                    .start => return try self.validateStart(event.content_index, mapping.kind),
                    .delta => return try self.validateDelta(event.content_index, mapping.kind),
                    .end => return try self.validateEnd(event.content_index, mapping.kind),
                }
            }
        }
    }

    fn validateStart(self: *EventOrderingGuard, maybe_index: ?u32, kind: BlockKind) EventOrderingError!void {
        const index = maybe_index orelse return error.MissingContentIndex;
        if (self.blocks.get(index)) |entry| {
            return switch (entry.state) {
                .open => error.ContentBlockAlreadyStarted,
                .closed => error.ContentIndexReused,
            };
        }
        self.blocks.put(index, .{ .kind = kind, .state = .open }) catch unreachable;
    }

    fn validateDelta(self: *EventOrderingGuard, maybe_index: ?u32, kind: BlockKind) EventOrderingError!void {
        const index = maybe_index orelse return error.MissingContentIndex;
        const entry = self.blocks.get(index) orelse return error.ContentBlockDeltaBeforeStart;
        if (entry.kind != kind) return error.ContentBlockKindMismatch;
        if (entry.state == .closed) return error.ContentBlockDeltaAfterEnd;
    }

    fn validateEnd(self: *EventOrderingGuard, maybe_index: ?u32, kind: BlockKind) EventOrderingError!void {
        const index = maybe_index orelse return error.MissingContentIndex;
        const entry = self.blocks.getPtr(index) orelse return error.ContentBlockEndBeforeStart;
        if (entry.kind != kind) return error.ContentBlockKindMismatch;
        if (entry.state == .closed) return error.ContentBlockEndAfterEnd;
        entry.state = .closed;
    }

    fn validateSuccessTerminal(self: *EventOrderingGuard) EventOrderingError!void {
        var iterator = self.blocks.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.state == .open) return error.ContentBlockOpenAtTerminal;
        }
        self.terminal_seen = true;
    }
};

test "EventOrderingGuard accepts interleaved provider block lifecycles" {
    var guard = EventOrderingGuard.init(std.testing.allocator);
    defer guard.deinit();

    try guard.validate(.{ .event_type = .start });
    try guard.validate(.{ .event_type = .text_start, .content_index = 0 });
    try guard.validate(.{ .event_type = .text_delta, .content_index = 0, .delta = "hello" });
    try guard.validate(.{ .event_type = .thinking_start, .content_index = 1 });
    try guard.validate(.{ .event_type = .thinking_delta, .content_index = 1, .delta = "thinking" });
    try guard.validate(.{ .event_type = .text_end, .content_index = 0, .content = "hello" });
    try guard.validate(.{ .event_type = .thinking_end, .content_index = 1, .content = "thinking" });
    try guard.validate(.{ .event_type = .toolcall_start, .content_index = 2 });
    try guard.validate(.{ .event_type = .toolcall_delta, .content_index = 2, .delta = "{\"city\":" });
    try guard.validate(.{ .event_type = .toolcall_delta, .content_index = 2, .delta = "\"Berlin\"}" });
    try guard.validate(.{ .event_type = .toolcall_end, .content_index = 2 });
    try guard.validate(.{ .event_type = .done });
}

test "EventOrderingGuard rejects delta and end before start" {
    var delta_guard = EventOrderingGuard.init(std.testing.allocator);
    defer delta_guard.deinit();
    try std.testing.expectError(
        error.ContentBlockDeltaBeforeStart,
        delta_guard.validate(.{ .event_type = .text_delta, .content_index = 0, .delta = "late" }),
    );

    var end_guard = EventOrderingGuard.init(std.testing.allocator);
    defer end_guard.deinit();
    try std.testing.expectError(
        error.ContentBlockEndBeforeStart,
        end_guard.validate(.{ .event_type = .toolcall_end, .content_index = 0 }),
    );
}

test "EventOrderingGuard rejects duplicate starts and content_index reuse" {
    var duplicate_guard = EventOrderingGuard.init(std.testing.allocator);
    defer duplicate_guard.deinit();
    try duplicate_guard.validate(.{ .event_type = .text_start, .content_index = 4 });
    try std.testing.expectError(
        error.ContentBlockAlreadyStarted,
        duplicate_guard.validate(.{ .event_type = .text_start, .content_index = 4 }),
    );

    var reuse_guard = EventOrderingGuard.init(std.testing.allocator);
    defer reuse_guard.deinit();
    try reuse_guard.validate(.{ .event_type = .thinking_start, .content_index = 7 });
    try reuse_guard.validate(.{ .event_type = .thinking_end, .content_index = 7 });
    try std.testing.expectError(
        error.ContentIndexReused,
        reuse_guard.validate(.{ .event_type = .toolcall_start, .content_index = 7 }),
    );
}

test "EventOrderingGuard rejects deltas after end, kind drift, and terminal order violations" {
    var closed_guard = EventOrderingGuard.init(std.testing.allocator);
    defer closed_guard.deinit();
    try closed_guard.validate(.{ .event_type = .text_start, .content_index = 1 });
    try closed_guard.validate(.{ .event_type = .text_end, .content_index = 1 });
    try std.testing.expectError(
        error.ContentBlockDeltaAfterEnd,
        closed_guard.validate(.{ .event_type = .text_delta, .content_index = 1, .delta = "late" }),
    );

    var kind_guard = EventOrderingGuard.init(std.testing.allocator);
    defer kind_guard.deinit();
    try kind_guard.validate(.{ .event_type = .thinking_start, .content_index = 2 });
    try std.testing.expectError(
        error.ContentBlockKindMismatch,
        kind_guard.validate(.{ .event_type = .text_delta, .content_index = 2, .delta = "wrong" }),
    );

    var terminal_guard = EventOrderingGuard.init(std.testing.allocator);
    defer terminal_guard.deinit();
    try terminal_guard.validate(.{ .event_type = .toolcall_start, .content_index = 3 });
    try std.testing.expectError(
        error.ContentBlockOpenAtTerminal,
        terminal_guard.validate(.{ .event_type = .done }),
    );

    var after_terminal_guard = EventOrderingGuard.init(std.testing.allocator);
    defer after_terminal_guard.deinit();
    try after_terminal_guard.validate(.{ .event_type = .error_event });
    try std.testing.expectError(
        error.EventAfterTerminal,
        after_terminal_guard.validate(.{ .event_type = .text_start, .content_index = 9 }),
    );
}
