const std = @import("std");
const types = @import("../types.zig");

pub const StopReasonMapping = struct {
    literal: []const u8,
    reason: types.StopReason,
};

pub const StopReasonResult = struct {
    stop_reason: types.StopReason,
    error_message: ?[]const u8 = null,
};

/// Maps a provider-specific stop-reason string to a canonical StopReason using
/// a comptime mapping table. Returns `fallback` for unmatched values.
pub fn mapStopReasonFromTable(
    comptime mappings: []const StopReasonMapping,
    reason: []const u8,
    fallback: types.StopReason,
) types.StopReason {
    inline for (mappings) |mapping| {
        if (std.mem.eql(u8, reason, mapping.literal)) return mapping.reason;
    }
    return fallback;
}

/// Like `mapStopReasonFromTable` but returns a composite result with an optional
/// error message for unknown values. Useful for providers that report unexpected
/// finish reasons to the user.
pub fn mapStopReasonFromTableWithMessage(
    comptime mappings: []const StopReasonMapping,
    reason: []const u8,
) StopReasonResult {
    inline for (mappings) |mapping| {
        if (std.mem.eql(u8, reason, mapping.literal)) return .{
            .stop_reason = mapping.reason,
            .error_message = null,
        };
    }
    return .{
        .stop_reason = .error_reason,
        .error_message = reason,
    };
}

/// Like `mapStopReasonFromTableWithMessage` but allocates a formatted error
/// message string for unknown values. The caller must free the returned
/// error_message with the same allocator.
pub fn mapStopReasonFromTableWithAllocMessage(
    allocator: std.mem.Allocator,
    comptime mappings: []const StopReasonMapping,
    reason: []const u8,
) !StopReasonResult {
    inline for (mappings) |mapping| {
        if (std.mem.eql(u8, reason, mapping.literal)) return .{
            .stop_reason = mapping.reason,
            .error_message = null,
        };
    }
    return .{
        .stop_reason = .error_reason,
        .error_message = try std.fmt.allocPrint(allocator, "Provider finish_reason: {s}", .{reason}),
    };
}

// Anthropic / Bedrock stop-reason mappings
pub const anthropic_mappings = [_]StopReasonMapping{
    .{ .literal = "end_turn", .reason = .stop },
    .{ .literal = "stop_sequence", .reason = .stop },
    .{ .literal = "pause_turn", .reason = .stop },
    .{ .literal = "max_tokens", .reason = .length },
    .{ .literal = "tool_use", .reason = .tool_use },
    .{ .literal = "refusal", .reason = .error_reason },
    .{ .literal = "sensitive", .reason = .error_reason },
};

pub const bedrock_mappings = [_]StopReasonMapping{
    .{ .literal = "end_turn", .reason = .stop },
    .{ .literal = "stop_sequence", .reason = .stop },
    .{ .literal = "max_tokens", .reason = .length },
    .{ .literal = "model_context_window_exceeded", .reason = .length },
    .{ .literal = "tool_use", .reason = .tool_use },
    .{ .literal = "guardrail_intervened", .reason = .error_reason },
    .{ .literal = "content_filtered", .reason = .error_reason },
};

// Google / Vertex / Gemini CLI stop-reason mappings
pub const google_mappings = [_]StopReasonMapping{
    .{ .literal = "STOP", .reason = .stop },
    .{ .literal = "MAX_TOKENS", .reason = .length },
};

// Mistral stop-reason mappings
pub const mistral_mappings = [_]StopReasonMapping{
    .{ .literal = "stop", .reason = .stop },
    .{ .literal = "length", .reason = .length },
    .{ .literal = "model_length", .reason = .length },
    .{ .literal = "tool_calls", .reason = .tool_use },
    .{ .literal = "error", .reason = .error_reason },
};

// OpenAI Responses / Azure OpenAI / Codex stop-reason mappings
pub const openai_responses_mappings = [_]StopReasonMapping{
    .{ .literal = "completed", .reason = .stop },
    .{ .literal = "incomplete", .reason = .length },
    .{ .literal = "failed", .reason = .error_reason },
    .{ .literal = "cancelled", .reason = .error_reason },
    .{ .literal = "queued", .reason = .stop },
    .{ .literal = "in_progress", .reason = .stop },
};

// OpenAI Chat / Kimi stop-reason mappings (shared base)
pub const openai_chat_mappings = [_]StopReasonMapping{
    .{ .literal = "stop", .reason = .stop },
    .{ .literal = "end", .reason = .stop },
    .{ .literal = "length", .reason = .length },
    .{ .literal = "tool_calls", .reason = .tool_use },
    .{ .literal = "function_call", .reason = .tool_use },
};

// Kimi-specific additional mappings beyond the OpenAI chat base
pub const kimi_mappings = [_]StopReasonMapping{
    .{ .literal = "stop", .reason = .stop },
    .{ .literal = "end", .reason = .stop },
    .{ .literal = "length", .reason = .length },
    .{ .literal = "tool_calls", .reason = .tool_use },
    .{ .literal = "function_call", .reason = .tool_use },
    .{ .literal = "content_filter", .reason = .error_reason },
    .{ .literal = "network_error", .reason = .error_reason },
};

test "mapStopReasonFromTable matches known Anthropic stop reasons" {
    try std.testing.expectEqual(types.StopReason.stop, mapStopReasonFromTable(&anthropic_mappings, "end_turn", .error_reason));
    try std.testing.expectEqual(types.StopReason.stop, mapStopReasonFromTable(&anthropic_mappings, "stop_sequence", .error_reason));
    try std.testing.expectEqual(types.StopReason.stop, mapStopReasonFromTable(&anthropic_mappings, "pause_turn", .error_reason));
    try std.testing.expectEqual(types.StopReason.length, mapStopReasonFromTable(&anthropic_mappings, "max_tokens", .error_reason));
    try std.testing.expectEqual(types.StopReason.tool_use, mapStopReasonFromTable(&anthropic_mappings, "tool_use", .error_reason));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReasonFromTable(&anthropic_mappings, "refusal", .error_reason));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReasonFromTable(&anthropic_mappings, "sensitive", .error_reason));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReasonFromTable(&anthropic_mappings, "unknown_future", .error_reason));
}

test "mapStopReasonFromTable matches known Bedrock stop reasons" {
    try std.testing.expectEqual(types.StopReason.stop, mapStopReasonFromTable(&bedrock_mappings, "end_turn", .error_reason));
    try std.testing.expectEqual(types.StopReason.stop, mapStopReasonFromTable(&bedrock_mappings, "stop_sequence", .error_reason));
    try std.testing.expectEqual(types.StopReason.length, mapStopReasonFromTable(&bedrock_mappings, "max_tokens", .error_reason));
    try std.testing.expectEqual(types.StopReason.length, mapStopReasonFromTable(&bedrock_mappings, "model_context_window_exceeded", .error_reason));
    try std.testing.expectEqual(types.StopReason.tool_use, mapStopReasonFromTable(&bedrock_mappings, "tool_use", .error_reason));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReasonFromTable(&bedrock_mappings, "guardrail_intervened", .error_reason));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReasonFromTable(&bedrock_mappings, "content_filtered", .error_reason));
}

test "mapStopReasonFromTable matches known Google stop reasons" {
    try std.testing.expectEqual(types.StopReason.stop, mapStopReasonFromTable(&google_mappings, "STOP", .error_reason));
    try std.testing.expectEqual(types.StopReason.length, mapStopReasonFromTable(&google_mappings, "MAX_TOKENS", .error_reason));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReasonFromTable(&google_mappings, "SAFETY", .error_reason));
}

test "mapStopReasonFromTableWithMessage returns error_message for unknown" {
    const result = mapStopReasonFromTableWithMessage(&openai_chat_mappings, "stop");
    try std.testing.expectEqual(types.StopReason.stop, result.stop_reason);
    try std.testing.expect(result.error_message == null);

    const unknown = mapStopReasonFromTableWithMessage(&openai_chat_mappings, "foobar");
    try std.testing.expectEqual(types.StopReason.error_reason, unknown.stop_reason);
    try std.testing.expect(unknown.error_message != null);
    try std.testing.expectEqualStrings("foobar", unknown.error_message.?);
}

test "mapStopReasonFromTableWithAllocMessage allocates message for unknown" {
    const allocator = std.testing.allocator;
    const result = try mapStopReasonFromTableWithAllocMessage(allocator, &openai_chat_mappings, "stop");
    try std.testing.expectEqual(types.StopReason.stop, result.stop_reason);
    try std.testing.expect(result.error_message == null);

    const unknown = try mapStopReasonFromTableWithAllocMessage(allocator, &openai_chat_mappings, "foobar");
    try std.testing.expectEqual(types.StopReason.error_reason, unknown.stop_reason);
    try std.testing.expect(unknown.error_message != null);
    allocator.free(unknown.error_message.?);
}
