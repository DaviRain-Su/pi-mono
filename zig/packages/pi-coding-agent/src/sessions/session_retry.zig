const std = @import("std");
const ai = @import("ai");
const string_utils = ai.shared.string_utils;
const session_compaction = @import("session_compaction.zig");

pub const RetrySettings = struct {
    enabled: bool = false,
    max_retries: u32 = 2,
    base_delay_ms: u64 = 1000,
};

pub const RetryLifecycleEvent = union(enum) {
    start: struct {
        attempt: u32,
        max_attempts: u32,
        delay_ms: u64,
        error_message: []const u8,
    },
    end: struct {
        success: bool,
        attempt: u32,
        final_error: ?[]const u8 = null,
    },
};

pub const RetryLifecycleCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, event: RetryLifecycleEvent) anyerror!void,
};

pub fn isRetryableError(message: ai.AssistantMessage, context_window: u32) bool {
    if (message.stop_reason != .error_reason) return false;
    const error_message = message.error_message orelse return false;
    if (session_compaction.isContextOverflow(message, context_window)) return false;

    return string_utils.containsIgnoreCase(error_message, "overloaded") or
        string_utils.containsIgnoreCase(error_message, "rate limit") or
        string_utils.containsIgnoreCase(error_message, "too many requests") or
        string_utils.containsIgnoreCase(error_message, "service unavailable") or
        string_utils.containsIgnoreCase(error_message, "server error") or
        string_utils.containsIgnoreCase(error_message, "internal error") or
        string_utils.containsIgnoreCase(error_message, "network error") or
        string_utils.containsIgnoreCase(error_message, "connection error") or
        string_utils.containsIgnoreCase(error_message, "connection refused") or
        string_utils.containsIgnoreCase(error_message, "connection lost") or
        string_utils.containsIgnoreCase(error_message, "socket hang up") or
        string_utils.containsIgnoreCase(error_message, "fetch failed") or
        string_utils.containsIgnoreCase(error_message, "stream ended before message_stop") or
        string_utils.containsIgnoreCase(error_message, "timeout") or
        string_utils.containsIgnoreCase(error_message, "timed out") or
        string_utils.containsIgnoreCase(error_message, "429") or
        string_utils.containsIgnoreCase(error_message, "500") or
        string_utils.containsIgnoreCase(error_message, "502") or
        string_utils.containsIgnoreCase(error_message, "503") or
        string_utils.containsIgnoreCase(error_message, "504");
}

pub fn exponentialBackoffMs(base_delay_ms: u64, attempt: u32) u64 {
    const exponent = if (attempt == 0) 0 else attempt - 1;
    if (exponent >= 63) return std.math.maxInt(u64);
    const multiplier = @as(u64, 1) << @intCast(exponent);
    const product, const overflowed = @mulWithOverflow(base_delay_ms, multiplier);
    return if (overflowed != 0) std.math.maxInt(u64) else product;
}

pub fn sleepMilliseconds(io: std.Io, delay_ms: u64) !void {
    const clamped = @min(delay_ms, @as(u64, std.math.maxInt(i64)));
    try std.Io.sleep(io, .fromMilliseconds(@intCast(clamped)), .awake);
}

fn retryTestMessage(error_message: ?[]const u8, stop_reason: ai.StopReason) ai.AssistantMessage {
    return .{
        .content = &.{},
        .api = "anthropic",
        .provider = "anthropic",
        .model = "claude-sonnet-4-20250514",
        .usage = ai.Usage.init(),
        .stop_reason = stop_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
}

test "retry classifier treats Anthropic message_stop stream endings as retryable" {
    const message = retryTestMessage("Anthropic STREAM ENDED BEFORE MESSAGE_STOP", .error_reason);
    try std.testing.expect(isRetryableError(message, 200000));
}

test "retry classifier keeps non retryable errors false" {
    const plain_error = retryTestMessage("invalid request", .error_reason);
    try std.testing.expect(!isRetryableError(plain_error, 200000));

    const successful_message = retryTestMessage("stream ended before message_stop", .stop);
    try std.testing.expect(!isRetryableError(successful_message, 200000));

    const missing_error_message = retryTestMessage(null, .error_reason);
    try std.testing.expect(!isRetryableError(missing_error_message, 200000));
}
