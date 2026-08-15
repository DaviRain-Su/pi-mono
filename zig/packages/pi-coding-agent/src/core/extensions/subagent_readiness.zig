const std = @import("std");
const extension_events = @import("../../extensions/extension_events.zig");

pub const SubAgentReadinessEnvelopeKind = extension_events.SubAgentReadinessEnvelopeKind;
pub const SubAgentReadinessDiagnostic = extension_events.SubAgentReadinessDiagnostic;
pub const SubAgentReadinessValidation = extension_events.SubAgentReadinessValidation;

pub const SUB_AGENT_TASK_INVOCATION_TYPE = "sub_agent_task_invocation";
pub const SUB_AGENT_TASK_RESULT_TYPE = "sub_agent_task_result";

pub const SubAgentTaskStatus = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,

    pub fn jsonName(self: SubAgentTaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }
};

pub const SubAgentCancellationState = enum {
    pending,
    requested,
    propagated,
    completed,

    pub fn jsonName(self: SubAgentCancellationState) []const u8 {
        return switch (self) {
            .pending => "pending",
            .requested => "requested",
            .propagated => "propagated",
            .completed => "completed",
        };
    }
};

pub const SubAgentCorrelationIds = struct {
    agent_id: []const u8,
    run_id: []const u8,
    task_id: []const u8,
    session_id: []const u8,
    tool_call_id: ?[]const u8 = null,
    parent_agent_id: ?[]const u8 = null,
    parent_run_id: ?[]const u8 = null,
    parent_task_id: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
};

pub const SubAgentResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: []const []const u8 = &.{},
};

pub const SubAgentResourceLimitDetail = struct {
    limit: f64,
    actual: ?f64 = null,
    truncated: bool,
    reason: ?[]const u8 = null,
};

pub fn validateSubAgentReadinessEnvelope(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !SubAgentReadinessValidation {
    return extension_events.validateSubAgentReadinessEnvelope(allocator, value);
}

pub fn validateSubAgentTaskInvocationEnvelope(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !SubAgentReadinessValidation {
    return extension_events.validateSubAgentTaskInvocationEnvelope(allocator, object);
}

pub fn validateSubAgentTaskResultEnvelope(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !SubAgentReadinessValidation {
    return extension_events.validateSubAgentTaskResultEnvelope(allocator, object);
}

test "sub-agent readiness validates invocation envelopes" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "sub_agent_task_invocation",
        \\  "agentId": "agent",
        \\  "runId": "run",
        \\  "taskId": "task",
        \\  "sessionId": "session",
        \\  "input": {},
        \\  "limits": { "turns": 2, "toolScopes": ["read"] }
        \\}
    , .{});
    defer parsed.deinit();

    var validation = try validateSubAgentReadinessEnvelope(allocator, parsed.value);
    defer validation.deinit(allocator);
    try std.testing.expectEqual(SubAgentReadinessEnvelopeKind.task_invocation, validation.valid);
}

test "sub-agent readiness rejects forbidden product fields" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "sub_agent_task_invocation",
        \\  "agentId": "agent",
        \\  "runId": "run",
        \\  "taskId": "task",
        \\  "sessionId": "session",
        \\  "input": { "spawn": true }
        \\}
    , .{});
    defer parsed.deinit();

    var validation = try validateSubAgentReadinessEnvelope(allocator, parsed.value);
    defer validation.deinit(allocator);
    try std.testing.expect(validation == .invalid);
    try std.testing.expectEqualStrings("$.input.spawn", validation.invalid.path);
}
