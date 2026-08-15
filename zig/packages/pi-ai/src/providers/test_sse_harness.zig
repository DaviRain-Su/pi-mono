//! Lightweight scaffolding for `parseSseStreamLines` provider tests.
//!
//! The Chat / Responses / Anthropic / Mistral / Kimi / Google providers
//! each have their own SSE parser, but tests almost always share the same
//! boilerplate:
//!
//! 1. allocate the SSE body bytes,
//! 2. wrap them in a `http_client.StreamingResponse`,
//! 3. construct an empty `event_stream.AssistantMessageEventStream`,
//! 4. construct an empty `types.Context`,
//! 5. call the provider's `parseSseStreamLines`,
//! 6. iterate the resulting stream and assert on event kinds / payloads.
//!
//! `ParseSseFixture` collapses steps 1–4 (and their `defer` chains) into a
//! single value the test can hold; provider-specific tests still call their
//! own parseSseStreamLines because each parser takes a different argument
//! list. `collectStreamEvents` covers step 6 — it drains a stream into an
//! `ArrayList` of events with their transient ownership taken so tests can
//! match on event type and message fields without manual deinit pairing.

const std = @import("std");
const http_client = @import("../http_client.zig");
const event_stream = @import("../event_stream.zig");
const types = @import("../types.zig");

/// Reusable scaffolding for parseSseStreamLines tests. The fixture owns
/// `body` (a dup of the caller's SSE bytes) and the `streaming` /
/// `stream` instances. Free order: deinit() drops the stream, then
/// streaming.deinit() frees the body.
pub const ParseSseFixture = struct {
    allocator: std.mem.Allocator,
    streaming: http_client.StreamingResponse,
    stream: event_stream.AssistantMessageEventStream,
    context: types.Context,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, body_bytes: []const u8) !ParseSseFixture {
        const body = try allocator.dupe(u8, body_bytes);
        return .{
            .allocator = allocator,
            .streaming = .{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator },
            .stream = event_stream.createAssistantMessageEventStream(allocator, io),
            .context = .{ .messages = &[_]types.Message{} },
        };
    }

    /// Same as `init` but for the rare cases that need a non-200 status
    /// (e.g. exercising the provider's error-mapping path).
    pub fn initWithStatus(allocator: std.mem.Allocator, io: std.Io, status: u16, body_bytes: []const u8) !ParseSseFixture {
        var fixture = try init(allocator, io, body_bytes);
        fixture.streaming.status = status;
        return fixture;
    }

    pub fn deinit(self: *ParseSseFixture) void {
        self.stream.deinit();
        self.streaming.deinit();
    }
};

/// Drain a producer-side `AssistantMessageEventStream` into an owned slice
/// of events. Each event's transient ownership is acquired via
/// `deinitTransient` after the test inspects it; the returned slice itself
/// holds copies of the event structs (the inner content blocks are still
/// owned by the stream until the caller drains them — same semantics as
/// pulling events one at a time in a `while (stream.next()) |event|` loop).
///
/// Use this when a test only wants to assert on the *shape* of the event
/// sequence (kinds, ordering, message field presence) without bookkeeping
/// the deinit on each one individually.
pub fn collectStreamEvents(
    allocator: std.mem.Allocator,
    stream: *event_stream.AssistantMessageEventStream,
) ![]types.AssistantMessageEvent {
    var events = std.ArrayList(types.AssistantMessageEvent).empty;
    errdefer events.deinit(allocator);
    while (stream.next()) |event| {
        try events.append(allocator, event);
    }
    return try events.toOwnedSlice(allocator);
}

const testing = std.testing;

test "ParseSseFixture wraps body in a StreamingResponse with status 200" {
    const allocator = testing.allocator;
    const io = std.Io.failing;
    var fixture = try ParseSseFixture.init(allocator, io, "data: hello\n\n");
    defer fixture.deinit();
    try testing.expectEqual(@as(u16, 200), fixture.streaming.status);
    try testing.expect(std.mem.indexOf(u8, fixture.streaming.body, "hello") != null);
    try testing.expectEqual(@as(usize, 0), fixture.context.messages.len);
}

test "ParseSseFixture honors a non-200 status override" {
    const allocator = testing.allocator;
    const io = std.Io.failing;
    var fixture = try ParseSseFixture.initWithStatus(allocator, io, 429, "data: throttled\n\n");
    defer fixture.deinit();
    try testing.expectEqual(@as(u16, 429), fixture.streaming.status);
}
