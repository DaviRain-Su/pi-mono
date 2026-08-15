const std = @import("std");
const json_utils = @import("../../json_utils.zig");
const common = @import("../../tools/common.zig");
const readiness = @import("subagent_readiness.zig");

pub const BoundedSubAgentToolResult = struct {
    ok: bool,
    output: ?std.json.Value = null,
    reason: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const BoundedSubAgentAdmissionDenial = struct {
    reason: []const u8,
    message: []const u8,
    details: ?std.json.Value = null,
};

pub const RuntimeAccounting = struct {
    turns: u64 = 0,
    children_started: u64 = 1,
    denied_tool: ?[]const u8 = null,
};

pub const ResourceLimitError = struct {
    limit_name: []const u8,
    limit: ?u64 = null,
    actual: ?u64 = null,
};

pub const BoundedSubAgentExecutor = *const fn (
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    runtime: *RuntimeAccounting,
    now_ms: i64,
) anyerror!std.json.Value;

pub const ExecuteBoundedSubAgentTaskOptions = struct {
    executor: ?BoundedSubAgentExecutor = null,
    now_ms: i64 = 0,
    admission_denial: ?BoundedSubAgentAdmissionDenial = null,
};

pub const BoundedSubAgentExecutionError = error{
    InvalidSubAgentInvocation,
    InvalidSubAgentResult,
    ExpectedObject,
};

pub fn executeBoundedSubAgentTask(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    options: ExecuteBoundedSubAgentTaskOptions,
) !std.json.Value {
    var invocation_validation = try readiness.validateSubAgentReadinessEnvelope(allocator, invocation);
    defer invocation_validation.deinit(allocator);
    if (invocation_validation != .valid or invocation_validation.valid != .task_invocation) {
        return error.InvalidSubAgentInvocation;
    }

    if (isCancellationRequested(invocation)) {
        return buildCancelledResult(allocator, invocation, now(options));
    }
    if (options.admission_denial) |denial| {
        return buildFailedResult(allocator, invocation, now(options), .{
            .reason = denial.reason,
            .message = denial.message,
            .resource_limit = null,
        });
    }
    if (exhaustedAdmissionLimit(invocation)) |limit_error| {
        return buildResourceLimitResult(allocator, invocation, now(options), limit_error);
    }

    var runtime: RuntimeAccounting = .{};
    const executor = options.executor orelse defaultBoundedSubAgentExecutor;
    var result = try executor(allocator, invocation, &runtime, now(options));
    errdefer common.deinitJsonValue(allocator, result);

    var result_validation = try readiness.validateSubAgentReadinessEnvelope(allocator, result);
    defer result_validation.deinit(allocator);
    if (result_validation != .valid or result_validation.valid != .task_result) {
        return error.InvalidSubAgentResult;
    }

    try normalizeResultIdentity(allocator, invocation, &result);
    try enforceRuntimeBoundaries(allocator, invocation, &result, runtime, now(options));
    return result;
}

pub fn defaultBoundedSubAgentExecutor(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    runtime: *RuntimeAccounting,
    now_ms: i64,
) !std.json.Value {
    runtime.turns = @max(runtime.turns, 1);
    const invocation_object = try requireObject(invocation);
    const input_json = if (invocation_object.get("input")) |input|
        try std.json.Stringify.valueAlloc(allocator, input, .{})
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(input_json);
    const route = optionalString(invocation_object, "route") orelse "default";
    const text = try std.fmt.allocPrint(allocator, "delegated:{s}:{s}", .{ route, input_json });
    defer allocator.free(text);
    return buildCompletedResult(allocator, invocation, now_ms, text, runtime.*);
}

pub fn consumeTurn(invocation: std.json.Value, runtime: *RuntimeAccounting, count: u64) !void {
    const next = runtime.turns + count;
    const limit = optionalLimit(invocation, "turns");
    if (limit) |max_turns| {
        if (next > max_turns) {
            runtime.turns = max_turns;
            return error.ResourceLimitExceeded;
        }
    }
    runtime.turns = next;
}

fn buildCompletedResult(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    timestamp: i64,
    text: []const u8,
    runtime: RuntimeAccounting,
) !std.json.Value {
    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = root });
    try putCorrelation(allocator, invocation, &root);
    try json_utils.putString(allocator, &root, "type", readiness.SUB_AGENT_TASK_RESULT_TYPE);
    try json_utils.putString(allocator, &root, "status", "completed");
    try json_utils.putInt(allocator, &root, "startedAt", timestamp);
    try json_utils.putInt(allocator, &root, "completedAt", timestamp);

    var block = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = block });
    try json_utils.putString(allocator, &block, "type", "text");
    try json_utils.putString(allocator, &block, "text", text);
    var content = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = content });
    try content.append(.{ .object = block });
    try json_utils.putValue(allocator, &root, "content", .{ .array = content });

    try json_utils.putValue(allocator, &root, "resourceSummary", try resourceSummaryValue(allocator, invocation, .{
        .turns = @max(runtime.turns, 1),
        .children_started = @max(runtime.children_started, 1),
        .output_bytes = text.len,
        .output_lines = countLines(text),
    }));
    try json_utils.putValue(allocator, &root, "details", try delegateDetailsValue(allocator, invocation));
    return .{ .object = root };
}

const FailedResultOptions = struct {
    reason: []const u8,
    message: []const u8,
    resource_limit: ?ResourceLimitError,
};

fn buildFailedResult(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    timestamp: i64,
    options: FailedResultOptions,
) !std.json.Value {
    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = root });
    try putCorrelation(allocator, invocation, &root);
    try json_utils.putString(allocator, &root, "type", readiness.SUB_AGENT_TASK_RESULT_TYPE);
    try json_utils.putString(allocator, &root, "status", "failed");
    try json_utils.putInt(allocator, &root, "startedAt", timestamp);
    try json_utils.putInt(allocator, &root, "completedAt", timestamp);

    var error_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = error_object });
    try json_utils.putString(allocator, &error_object, "reason", options.reason);
    try json_utils.putString(allocator, &error_object, "message", options.message);
    try json_utils.putValue(allocator, &root, "error", .{ .object = error_object });

    var summary: ResourceSummaryInput = .{};
    if (options.resource_limit) |limit| {
        if (limit.actual) |actual| {
            if (std.mem.eql(u8, limit.limit_name, "turns")) summary.turns = actual;
            if (std.mem.eql(u8, limit.limit_name, "maxChildren")) summary.children_started = actual;
        }
    }
    try json_utils.putValue(allocator, &root, "resourceSummary", try resourceSummaryValue(allocator, invocation, summary));
    try json_utils.putValue(allocator, &root, "details", try delegateDetailsValue(allocator, invocation));
    return .{ .object = root };
}

fn buildCancelledResult(allocator: std.mem.Allocator, invocation: std.json.Value, timestamp: i64) !std.json.Value {
    var result = try buildFailedResult(allocator, invocation, timestamp, .{
        .reason = "cancelled",
        .message = "delegation cancelled",
        .resource_limit = null,
    });
    const status = result.object.getPtr("status").?;
    allocator.free(status.string);
    status.* = .{ .string = try allocator.dupe(u8, "cancelled") };
    return result;
}

fn buildResourceLimitResult(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    timestamp: i64,
    limit_error: ResourceLimitError,
) !std.json.Value {
    const message = try std.fmt.allocPrint(allocator, "resource limit exceeded: {s}", .{limit_error.limit_name});
    defer allocator.free(message);
    return buildFailedResult(allocator, invocation, timestamp, .{
        .reason = "resource_limit_exceeded",
        .message = message,
        .resource_limit = limit_error,
    });
}

fn enforceRuntimeBoundaries(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    result: *std.json.Value,
    runtime: RuntimeAccounting,
    timestamp: i64,
) !void {
    if (runtime.denied_tool != null) {
        common.deinitJsonValue(allocator, result.*);
        result.* = try buildResourceLimitResult(allocator, invocation, timestamp, .{ .limit_name = "toolScopes" });
        return;
    }
    const turn_limit = optionalLimit(invocation, "turns");
    if (turn_limit) |limit| {
        if (runtime.turns > limit) {
            common.deinitJsonValue(allocator, result.*);
            result.* = try buildResourceLimitResult(allocator, invocation, timestamp, .{ .limit_name = "turns", .limit = limit, .actual = runtime.turns });
            return;
        }
    }
    try boundResultContent(allocator, invocation, result);
}

fn boundResultContent(allocator: std.mem.Allocator, invocation: std.json.Value, result: *std.json.Value) !void {
    if (result.* != .object) return;
    const content_ptr = result.object.getPtr("content") orelse return;
    const text_ptr = singleTextPtr(content_ptr) orelse return;
    const original = text_ptr.*;
    const line_limit = optionalLimit(invocation, "outputLines");
    const byte_limit = optionalLimit(invocation, "outputBytes");
    const line_bounded = try truncateLinesAlloc(allocator, original, line_limit);
    defer allocator.free(line_bounded);
    const byte_bounded = try truncateUtf8Alloc(allocator, line_bounded, byte_limit);
    errdefer allocator.free(byte_bounded);
    if (std.mem.eql(u8, original, byte_bounded)) {
        allocator.free(byte_bounded);
        return;
    }
    allocator.free(original);
    text_ptr.* = byte_bounded;
}

fn normalizeResultIdentity(allocator: std.mem.Allocator, invocation: std.json.Value, result: *std.json.Value) !void {
    if (result.* != .object) return error.ExpectedObject;
    try putCorrelation(allocator, invocation, &result.object);
}

fn putCorrelation(allocator: std.mem.Allocator, invocation: std.json.Value, target: *std.json.ObjectMap) !void {
    const source = try requireObject(invocation);
    inline for (.{ "agentId", "runId", "taskId", "sessionId", "toolCallId", "parentAgentId", "parentRunId", "parentTaskId", "parentSessionId", "parentId" }) |field| {
        if (target.get(field) == null) {
            if (optionalString(source, field)) |text| try json_utils.putString(allocator, target, field, text);
        }
    }
}

const ResourceSummaryInput = struct {
    turns: u64 = 0,
    output_bytes: u64 = 0,
    output_lines: u64 = 0,
    children_started: u64 = 0,
};

fn resourceSummaryValue(allocator: std.mem.Allocator, invocation: std.json.Value, summary: ResourceSummaryInput) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try json_utils.putInt(allocator, &object, "turns", @intCast(summary.turns));
    try json_utils.putInt(allocator, &object, "outputBytes", @intCast(summary.output_bytes));
    try json_utils.putInt(allocator, &object, "outputLines", @intCast(summary.output_lines));
    try json_utils.putInt(allocator, &object, "childrenStarted", @intCast(summary.children_started));
    if (try limitDetailsValue(allocator, invocation, summary)) |details| {
        try json_utils.putValue(allocator, &object, "limitDetails", details);
    }
    return .{ .object = object };
}

fn limitDetailsValue(allocator: std.mem.Allocator, invocation: std.json.Value, summary: ResourceSummaryInput) !?std.json.Value {
    var details = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = details });
    var added = false;
    inline for (.{ "turns", "outputBytes", "outputLines", "maxChildren" }) |field| {
        const limit = optionalLimit(invocation, field);
        if (limit) |value| {
            const actual = if (std.mem.eql(u8, field, "turns"))
                summary.turns
            else if (std.mem.eql(u8, field, "outputBytes"))
                summary.output_bytes
            else if (std.mem.eql(u8, field, "outputLines"))
                summary.output_lines
            else
                summary.children_started;
            try json_utils.putValue(allocator, &details, field, try limitDetailValue(allocator, value, actual));
            added = true;
        }
    }
    if (!added) {
        details.deinit(allocator);
        return null;
    }
    return .{ .object = details };
}

fn limitDetailValue(allocator: std.mem.Allocator, limit: u64, actual: u64) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try json_utils.putInt(allocator, &object, "limit", @intCast(limit));
    try json_utils.putInt(allocator, &object, "actual", @intCast(actual));
    try json_utils.putBool(allocator, &object, "truncated", actual > limit);
    if (actual > limit) try json_utils.putString(allocator, &object, "reason", "resource limit exceeded");
    return .{ .object = object };
}

fn delegateDetailsValue(allocator: std.mem.Allocator, invocation: std.json.Value) !std.json.Value {
    const invocation_object = try requireObject(invocation);
    var details = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = details });
    try json_utils.putString(allocator, &details, "capability", "agent.delegate");
    try json_utils.putString(allocator, &details, "operation", "agent.delegate");
    if (optionalString(invocation_object, "route")) |route| try json_utils.putString(allocator, &details, "route", route);
    return .{ .object = details };
}

fn exhaustedAdmissionLimit(invocation: std.json.Value) ?ResourceLimitError {
    inline for (.{ "maxChildren", "depth", "turns", "timeoutMs" }) |field| {
        if (optionalLimit(invocation, field)) |limit| {
            if (limit < 1) return .{ .limit_name = field, .limit = limit, .actual = 0 };
        }
    }
    return null;
}

fn optionalLimit(invocation: std.json.Value, field: []const u8) ?u64 {
    if (invocation != .object) return null;
    const limits_value = invocation.object.get("limits") orelse return null;
    if (limits_value != .object) return null;
    const value = limits_value.object.get(field) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn isCancellationRequested(invocation: std.json.Value) bool {
    if (invocation != .object) return false;
    const cancellation = invocation.object.get("cancellation") orelse return false;
    if (cancellation != .object) return false;
    const state = optionalString(cancellation.object, "state") orelse return false;
    return std.mem.eql(u8, state, "requested");
}

fn singleTextPtr(content: *std.json.Value) ?*[]const u8 {
    switch (content.*) {
        .string => return &content.string,
        .array => {
            var found: ?*[]const u8 = null;
            for (content.array.items) |*item| {
                if (item.* != .object) continue;
                const text = item.object.getPtr("text") orelse continue;
                if (text.* != .string) continue;
                if (found != null) return null;
                found = &text.string;
            }
            return found;
        },
        else => return null,
    }
}

fn truncateLinesAlloc(allocator: std.mem.Allocator, text: []const u8, maybe_limit: ?u64) ![]u8 {
    const limit = maybe_limit orelse return allocator.dupe(u8, text);
    if (countLines(text) <= limit) return allocator.dupe(u8, text);
    if (limit == 0) return allocator.dupe(u8, "");
    var lines_seen: u64 = 1;
    for (text, 0..) |byte, index| {
        if (byte == '\n') {
            lines_seen += 1;
            if (lines_seen > limit) return allocator.dupe(u8, text[0..index]);
        }
    }
    return allocator.dupe(u8, text);
}

fn truncateUtf8Alloc(allocator: std.mem.Allocator, text: []const u8, maybe_limit: ?u64) ![]u8 {
    const limit = maybe_limit orelse return allocator.dupe(u8, text);
    if (text.len <= limit) return allocator.dupe(u8, text);
    var end: usize = @intCast(limit);
    while (end > 0 and (text[end] & 0b1100_0000) == 0b1000_0000) {
        end -= 1;
    }
    return allocator.dupe(u8, text[0..end]);
}

fn countLines(text: []const u8) u64 {
    if (text.len == 0) return 0;
    var count: u64 = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn requireObject(value: std.json.Value) BoundedSubAgentExecutionError!std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn optionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn now(options: ExecuteBoundedSubAgentTaskOptions) i64 {
    if (options.now_ms != 0) return options.now_ms;
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(tv.usec)), std.time.us_per_ms);
}

test "bounded sub-agent default executor returns completed result" {
    const allocator = std.testing.allocator;
    var invocation = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "sub_agent_task_invocation",
        \\  "agentId": "agent",
        \\  "runId": "run",
        \\  "taskId": "task",
        \\  "sessionId": "session",
        \\  "input": {"value":"alpha"}
        \\}
    , .{});
    defer invocation.deinit();

    var result = try executeBoundedSubAgentTask(allocator, invocation.value, .{ .now_ms = 1 });
    defer common.deinitJsonValue(allocator, result);
    try std.testing.expectEqualStrings("completed", result.object.get("status").?.string);
    try std.testing.expectEqualStrings("agent", result.object.get("agentId").?.string);
}

test "bounded sub-agent enforces admission limits" {
    const allocator = std.testing.allocator;
    var invocation = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "sub_agent_task_invocation",
        \\  "agentId": "agent",
        \\  "runId": "run",
        \\  "taskId": "task",
        \\  "sessionId": "session",
        \\  "input": {},
        \\  "limits": {"turns":0}
        \\}
    , .{});
    defer invocation.deinit();

    var result = try executeBoundedSubAgentTask(allocator, invocation.value, .{ .now_ms = 1 });
    defer common.deinitJsonValue(allocator, result);
    try std.testing.expectEqualStrings("failed", result.object.get("status").?.string);
    try std.testing.expectEqualStrings("resource_limit_exceeded", result.object.get("error").?.object.get("reason").?.string);
}
