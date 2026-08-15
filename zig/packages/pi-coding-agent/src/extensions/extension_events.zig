const std = @import("std");

/// Extension event types mirroring TypeScript ExtensionAPI.on() events
pub const ExtensionEventType = enum {
    // Resource events
    resources_discover,
    // Session events
    session_start,
    session_before_switch,
    session_before_fork,
    session_before_compact,
    session_compact,
    session_shutdown,
    session_before_tree,
    session_tree,
    // Agent events
    before_agent_start,
    agent_start,
    agent_end,
    sub_agent_readiness,
    turn_start,
    turn_end,
    // Message events
    message_start,
    message_update,
    message_end,
    // Tool events
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
    tool_call,
    tool_result,
    user_bash,
    // Context/Provider events
    context,
    before_provider_request,
    after_provider_response,
    // Model events
    model_select,
    thinking_level_select,
    // Input events
    input,
};

/// Generic extension event
pub const ExtensionEvent = union(ExtensionEventType) {
    resources_discover: ResourcesDiscoverEvent,
    session_start: SessionStartEvent,
    session_before_switch: SessionBeforeSwitchEvent,
    session_before_fork: SessionBeforeForkEvent,
    session_before_compact: SessionBeforeCompactEvent,
    session_compact: SessionCompactEvent,
    session_shutdown: SessionShutdownEvent,
    session_before_tree: SessionBeforeTreeEvent,
    session_tree: SessionTreeEvent,
    before_agent_start: BeforeAgentStartEvent,
    agent_start: AgentStartEvent,
    agent_end: AgentEndEvent,
    sub_agent_readiness: SubAgentReadinessEvent,
    turn_start: TurnStartEvent,
    turn_end: TurnEndEvent,
    message_start: MessageStartEvent,
    message_update: MessageUpdateEvent,
    message_end: MessageEndEvent,
    tool_execution_start: ToolExecutionStartEvent,
    tool_execution_update: ToolExecutionUpdateEvent,
    tool_execution_end: ToolExecutionEndEvent,
    tool_call: ToolCallEvent,
    tool_result: ToolResultEvent,
    user_bash: UserBashEvent,
    context: ContextEvent,
    before_provider_request: BeforeProviderRequestEvent,
    after_provider_response: AfterProviderResponseEvent,
    model_select: ModelSelectEvent,
    thinking_level_select: ThinkingLevelSelectEvent,
    input: InputEvent,
};

// Resource events
pub const ResourcesDiscoverEvent = struct {
    cwd: []const u8,
    reason: []const u8, // "startup" | "reload"
};

// Session events
pub const SessionStartEvent = struct {
    reason: []const u8, // "startup" | "reload" | "new" | "resume" | "fork"
    previous_session_file: ?[]const u8 = null,
};

pub const SessionBeforeSwitchEvent = struct {
    reason: []const u8, // "new" | "resume"
    target_session_file: ?[]const u8 = null,
};

pub const SessionBeforeForkEvent = struct {
    entry_id: []const u8,
    position: []const u8, // "before" | "at"
};

pub const SessionBeforeCompactEvent = struct {
    custom_instructions: ?[]const u8 = null,
};

pub const SessionCompactEvent = struct {
    from_extension: bool = false,
};

pub const SessionShutdownEvent = struct {
    reason: []const u8, // "quit" | "reload" | "new" | "resume" | "fork"
    target_session_file: ?[]const u8 = null,
};

pub const SessionBeforeTreeEvent = struct {
    target_id: []const u8,
};

pub const SessionTreeEvent = struct {
    target_id: []const u8,
};

// Agent events
pub const BeforeAgentStartEvent = struct {
    prompt: []const u8 = "",
    images: []const []const u8 = &.{},
    system_prompt: []const u8 = "",
    messages: []const []const u8 = &.{},
};

pub const AgentStartEvent = struct {};
pub const AgentEndEvent = struct {
    stop_reason: ?[]const u8 = null,
};

pub const SubAgentReadinessEvent = struct {
    envelope: []const u8,
    phase: []const u8,
    owner: []const u8,
    read_only: bool = true,
};

pub const TurnStartEvent = struct {
    message: []const u8,
};

pub const TurnEndEvent = struct {
    message: []const u8,
};

// Message events
pub const MessageStartEvent = struct {
    message_id: []const u8,
};

pub const MessageUpdateEvent = struct {
    message_id: []const u8,
    delta: []const u8,
};

pub const MessageEndEvent = struct {
    message_id: []const u8,
    role: []const u8 = "",
    final_message: []const u8,
};

// Tool events
pub const ToolExecutionStartEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    input: []const u8,
};

pub const ToolExecutionUpdateEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    update: []const u8,
};

pub const ToolExecutionEndEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    result: []const u8,
};

pub const ToolCallEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    input: []const u8,
};

pub const ToolResultEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    result: []const u8,
    content: []const []const u8 = &.{},
    details: ?[]const u8 = null,
    is_error: bool = false,
};

pub const UserBashEvent = struct {
    command: []const u8,
    exclude_from_context: bool = false,
    cwd: []const u8 = "",
};

// Context/Provider events
pub const ContextEvent = struct {
    messages: []const []const u8,
};

pub const BeforeProviderRequestEvent = struct {
    model: []const u8,
    messages: []const []const u8,
    payload: []const u8 = "",
};

pub const AfterProviderResponseEvent = struct {
    model: []const u8,
    response: []const u8,
};

// Model events
pub const ModelSelectEvent = struct {
    model: []const u8,
    previous_model: ?[]const u8 = null,
};

pub const ThinkingLevelSelectEvent = struct {
    level: []const u8,
    previous_level: ?[]const u8 = null,
};

// Input events
pub const InputEvent = struct {
    data: []const u8,
    images: []const []const u8 = &.{},
};

/// Event handler function type
pub const EventHandler = *const fn (event: ExtensionEvent) anyerror!void;

pub const ResourcesDiscoverResult = struct {
    skill_paths: []const []const u8 = &.{},
    prompt_paths: []const []const u8 = &.{},
    theme_paths: []const []const u8 = &.{},
};

pub const ResourcePathResult = struct {
    path: []u8,
    extension_path: []u8,

    fn deinit(self: *ResourcePathResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ResourcesDiscoverCombinedResult = struct {
    skill_paths: []ResourcePathResult,
    prompt_paths: []ResourcePathResult,
    theme_paths: []ResourcePathResult,

    pub fn deinit(self: *ResourcesDiscoverCombinedResult, allocator: std.mem.Allocator) void {
        for (self.skill_paths) |*path| path.deinit(allocator);
        allocator.free(self.skill_paths);
        for (self.prompt_paths) |*path| path.deinit(allocator);
        allocator.free(self.prompt_paths);
        for (self.theme_paths) |*path| path.deinit(allocator);
        allocator.free(self.theme_paths);
        self.* = undefined;
    }
};

pub const InputAction = enum {
    @"continue",
    transform,
    handled,
};

pub const InputEventResult = struct {
    action: InputAction,
    text: ?[]const u8 = null,
    images: ?[]const []const u8 = null,
};

pub const OwnedInputEventResult = struct {
    action: InputAction,
    text: ?[]u8 = null,
    images: ?[]const []const u8 = null,

    pub fn deinit(self: *OwnedInputEventResult, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        self.* = undefined;
    }
};

pub const ToolResultPatch = struct {
    content: ?[]const []const u8 = null,
    details: ?[]const u8 = null,
    is_error: ?bool = null,
};

pub const ToolResultCombinedResult = struct {
    content: []const []const u8,
    details: ?[]const u8,
    is_error: bool,
};

pub const SessionBeforeResult = struct {
    cancel: bool = false,
};

pub const MessageEndResult = struct {
    role: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const MessageEndCombinedResult = struct {
    role: []const u8,
    message: []const u8,
};

pub const ContextEventResult = struct {
    messages: ?[]const []const u8 = null,
};

pub const BeforeProviderRequestEventResult = struct {
    payload: ?[]const u8 = null,
};

pub const BeforeAgentStartEventResult = struct {
    message: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
};

pub const BeforeAgentStartCombinedResult = struct {
    messages: []const []const u8,
    system_prompt: ?[]const u8,

    pub fn deinit(self: *BeforeAgentStartCombinedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.messages);
        self.* = undefined;
    }
};

pub const ToolCallEventResult = struct {
    input: ?[]const u8 = null,
    block: bool = false,
    reason: ?[]const u8 = null,
};

pub const ToolCallCombinedResult = struct {
    input: []const u8,
    block: bool = false,
    reason: ?[]const u8 = null,
};

pub const UserBashEventResult = struct {
    operations: ?[]const u8 = null,
    result: ?[]const u8 = null,
};

pub const SubAgentReadinessEnvelopeKind = enum {
    task_invocation,
    task_result,
};

pub const SubAgentReadinessDiagnostic = struct {
    path: []u8,
    message: []u8,

    pub fn deinit(self: *SubAgentReadinessDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const SubAgentReadinessValidation = union(enum) {
    valid: SubAgentReadinessEnvelopeKind,
    invalid: SubAgentReadinessDiagnostic,

    pub fn deinit(self: *SubAgentReadinessValidation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .invalid => |*diagnostic| diagnostic.deinit(allocator),
            .valid => {},
        }
        self.* = undefined;
    }
};

const subagent_correlation_fields = [_][]const u8{ "agentId", "runId", "taskId", "sessionId" };
const subagent_optional_id_fields = [_][]const u8{ "toolCallId", "parentAgentId", "parentRunId", "parentTaskId", "parentSessionId", "parentId" };
const subagent_limit_fields = [_][]const u8{ "maxChildren", "depth", "turns", "timeoutMs", "outputBytes", "outputLines", "toolScopes" };
const subagent_resource_summary_fields = [_][]const u8{ "turns", "outputBytes", "outputLines", "childrenStarted", "limitDetails" };
const subagent_resource_summary_number_fields = [_][]const u8{ "turns", "outputBytes", "outputLines", "childrenStarted" };
const subagent_limit_detail_fields = [_][]const u8{ "limit", "actual", "truncated", "reason" };
const subagent_forbidden_fields = [_][]const u8{ "ui", "ux", "slashCommand", "workflow", "workflowPreset", "wiki", "wikiPreset", "qa", "qaPreset", "review", "reviewPreset", "spawn", "spawnPolicy", "automaticSpawn", "orchestrationPolicy", "remoteUrl", "remoteWasmUrl", "signature", "signing", "publisher", "marketplace", "modelSelectionUi", "approvalPolicy", "approvalUi" };
const subagent_cancellation_states = [_][]const u8{ "pending", "requested", "propagated", "completed" };
const subagent_result_statuses = [_][]const u8{ "pending", "running", "completed", "failed", "cancelled" };
const MAX_SAFE_INTEGER: u64 = 9007199254740991;

pub fn validateSubAgentReadinessEnvelope(allocator: std.mem.Allocator, value: std.json.Value) !SubAgentReadinessValidation {
    const object = switch (value) {
        .object => |object| object,
        else => return invalidReadiness(allocator, "$", "expected object"),
    };
    const type_name = getString(object, "type") orelse return invalidReadiness(allocator, "$.type", "missing required field");
    if (std.mem.eql(u8, type_name, "sub_agent_task_invocation")) {
        return validateSubAgentTaskInvocationEnvelope(allocator, object);
    }
    if (std.mem.eql(u8, type_name, "sub_agent_task_result")) {
        return validateSubAgentTaskResultEnvelope(allocator, object);
    }
    const message = try std.fmt.allocPrint(allocator, "unsupported sub-agent readiness envelope \"{s}\"", .{type_name});
    defer allocator.free(message);
    return invalidReadiness(allocator, "$.type", message);
}

pub fn validateSubAgentTaskInvocationEnvelope(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SubAgentReadinessValidation {
    if (try forbiddenFieldDiagnostic(allocator, object, "$")) |diagnostic| return .{ .invalid = diagnostic };
    if (try exactTypeDiagnostic(allocator, object, "sub_agent_task_invocation")) |diagnostic| return .{ .invalid = diagnostic };
    if (try correlationDiagnostic(allocator, object)) |diagnostic| return .{ .invalid = diagnostic };
    if (try optionalIdsDiagnostic(allocator, object)) |diagnostic| return .{ .invalid = diagnostic };
    if (try optionalStringDiagnostic(allocator, object, "$", "route")) |diagnostic| return .{ .invalid = diagnostic };
    const input = object.get("input") orelse return invalidReadiness(allocator, "$.input", "missing required field");
    if (input != .object) return invalidReadiness(allocator, "$.input", "expected object");
    if (object.get("metadata")) |metadata| {
        if (metadata != .object) return invalidReadiness(allocator, "$.metadata", "expected object");
    }
    if (object.get("limits")) |limits| {
        const limits_object = switch (limits) {
            .object => |limits_object| limits_object,
            else => return invalidReadiness(allocator, "$.limits", "expected object"),
        };
        if (try limitsDiagnostic(allocator, limits_object)) |diagnostic| return .{ .invalid = diagnostic };
    }
    if (object.get("cancellation")) |cancellation| {
        const cancellation_object = switch (cancellation) {
            .object => |cancellation_object| cancellation_object,
            else => return invalidReadiness(allocator, "$.cancellation", "expected object"),
        };
        if (try cancellationDiagnostic(allocator, cancellation_object)) |diagnostic| return .{ .invalid = diagnostic };
    }
    return .{ .valid = .task_invocation };
}

pub fn validateSubAgentTaskResultEnvelope(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SubAgentReadinessValidation {
    if (try forbiddenFieldDiagnostic(allocator, object, "$")) |diagnostic| return .{ .invalid = diagnostic };
    if (try exactTypeDiagnostic(allocator, object, "sub_agent_task_result")) |diagnostic| return .{ .invalid = diagnostic };
    if (try correlationDiagnostic(allocator, object)) |diagnostic| return .{ .invalid = diagnostic };
    if (try optionalIdsDiagnostic(allocator, object)) |diagnostic| return .{ .invalid = diagnostic };

    const status = getString(object, "status") orelse return invalidReadiness(allocator, "$.status", "missing required field");
    if (!stringInComptimeTable(status, &subagent_result_statuses)) {
        const message = try std.fmt.allocPrint(allocator, "unsupported task status \"{s}\"", .{status});
        defer allocator.free(message);
        return invalidReadiness(allocator, "$.status", message);
    }
    if (try requiredNonNegativeNumberDiagnostic(allocator, object, "$", "startedAt")) |diagnostic| return .{ .invalid = diagnostic };
    if (try requiredNonNegativeNumberDiagnostic(allocator, object, "$", "completedAt")) |diagnostic| return .{ .invalid = diagnostic };
    if (object.get("details")) |details| {
        if (details != .object) return invalidReadiness(allocator, "$.details", "expected object");
    }
    if (object.get("error")) |error_value| {
        const error_object = switch (error_value) {
            .object => |error_object| error_object,
            else => return invalidReadiness(allocator, "$.error", "expected object"),
        };
        const reason = getString(error_object, "reason") orelse return invalidReadiness(allocator, "$.error.reason", "missing required field");
        if (reason.len == 0) return invalidReadiness(allocator, "$.error.reason", "must not be empty");
        if (try optionalStringDiagnostic(allocator, error_object, "$.error", "message")) |diagnostic| return .{ .invalid = diagnostic };
        if (error_object.get("details")) |details| {
            if (details != .object) return invalidReadiness(allocator, "$.error.details", "expected object");
        }
    }
    if (object.get("usage")) |usage| {
        const usage_object = switch (usage) {
            .object => |usage_object| usage_object,
            else => return invalidReadiness(allocator, "$.usage", "expected object"),
        };
        if (try numericSummaryDiagnostic(allocator, usage_object, "$.usage")) |diagnostic| return .{ .invalid = diagnostic };
    }
    if (object.get("resourceSummary")) |resource_summary| {
        const summary_object = switch (resource_summary) {
            .object => |summary_object| summary_object,
            else => return invalidReadiness(allocator, "$.resourceSummary", "expected object"),
        };
        if (try resourceSummaryDiagnostic(allocator, summary_object)) |diagnostic| return .{ .invalid = diagnostic };
    }
    return .{ .valid = .task_result };
}

fn forbiddenFieldDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8) anyerror!?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, entry.key_ptr.* });
        defer allocator.free(path);
        if (stringInComptimeTable(entry.key_ptr.*, &subagent_forbidden_fields)) {
            return (try invalidReadiness(allocator, path, "product UX/spawn policy is not allowed")).invalid;
        }
        if (try forbiddenValueDiagnostic(allocator, entry.value_ptr.*, path)) |diagnostic| return diagnostic;
    }
    return null;
}

fn forbiddenValueDiagnostic(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) anyerror!?SubAgentReadinessDiagnostic {
    switch (value) {
        .object => |object| return forbiddenFieldDiagnostic(allocator, object, path),
        .array => |array| {
            for (array.items, 0..) |entry, index| {
                const item_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
                defer allocator.free(item_path);
                if (try forbiddenValueDiagnostic(allocator, entry, item_path)) |diagnostic| return diagnostic;
            }
        },
        else => {},
    }
    return null;
}

fn exactTypeDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, expected: []const u8) !?SubAgentReadinessDiagnostic {
    const type_value = object.get("type") orelse return (try invalidReadiness(allocator, "$.type", "missing required field")).invalid;
    const actual = switch (type_value) {
        .string => |text| text,
        else => return (try invalidReadiness(allocator, "$.type", "expected string")).invalid,
    };
    if (!std.mem.eql(u8, actual, expected)) {
        const message = try std.fmt.allocPrint(allocator, "expected \"{s}\"", .{expected});
        defer allocator.free(message);
        return (try invalidReadiness(allocator, "$.type", message)).invalid;
    }
    return null;
}

fn correlationDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    inline for (subagent_correlation_fields) |field| {
        const path = comptime "$." ++ field;
        const value = object.get(field) orelse return (try invalidReadiness(allocator, path, "missing required field")).invalid;
        const text = switch (value) {
            .string => |text| text,
            else => return (try invalidReadiness(allocator, path, "expected string")).invalid,
        };
        if (text.len == 0) return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
    }
    return null;
}

fn optionalIdsDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    inline for (subagent_optional_id_fields) |field| {
        if (object.get(field)) |value| {
            const path = comptime "$." ++ field;
            const text = switch (value) {
                .string => |text| text,
                else => return (try invalidReadiness(allocator, path, "expected string")).invalid,
            };
            if (text.len == 0) return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
        }
    }
    return null;
}

fn limitsDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!stringInComptimeTable(entry.key_ptr.*, &subagent_limit_fields)) {
            const path = try std.fmt.allocPrint(allocator, "$.limits.{s}", .{entry.key_ptr.*});
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "unsupported resource limit")).invalid;
        }
    }
    inline for (subagent_limit_fields[0..6]) |field| {
        if (try optionalNonNegativeIntegerDiagnostic(allocator, object, "$.limits", field)) |diagnostic| return diagnostic;
    }
    if (object.get("toolScopes")) |tool_scopes| {
        const array = switch (tool_scopes) {
            .array => |array| array,
            else => return (try invalidReadiness(allocator, "$.limits.toolScopes", "expected array")).invalid,
        };
        for (array.items, 0..) |scope, index| {
            const path = try std.fmt.allocPrint(allocator, "$.limits.toolScopes[{d}]", .{index});
            defer allocator.free(path);
            const text = switch (scope) {
                .string => |text| text,
                else => return (try invalidReadiness(allocator, path, "expected string")).invalid,
            };
            if (text.len == 0) return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
        }
    }
    return null;
}

fn resourceSummaryDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!stringInComptimeTable(entry.key_ptr.*, &subagent_resource_summary_fields)) {
            const path = try std.fmt.allocPrint(allocator, "$.resourceSummary.{s}", .{entry.key_ptr.*});
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "unsupported resource summary field")).invalid;
        }
    }
    inline for (subagent_resource_summary_number_fields) |field| {
        if (object.get(field)) |value| {
            if (try nonNegativeNumberValueDiagnostic(allocator, value, "$.resourceSummary", field)) |diagnostic| return diagnostic;
        }
    }
    if (object.get("limitDetails")) |limit_details| {
        const details_object = switch (limit_details) {
            .object => |details_object| details_object,
            else => return (try invalidReadiness(allocator, "$.resourceSummary.limitDetails", "expected object")).invalid,
        };
        if (try limitDetailsDiagnostic(allocator, details_object)) |diagnostic| return diagnostic;
    }
    return null;
}

fn limitDetailsDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!stringInComptimeTable(entry.key_ptr.*, &subagent_limit_fields)) {
            const path = try std.fmt.allocPrint(allocator, "$.resourceSummary.limitDetails.{s}", .{entry.key_ptr.*});
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "unsupported resource limit detail")).invalid;
        }
    }
    inline for (subagent_limit_fields[0..6]) |field| {
        if (object.get(field)) |value| {
            const detail_object = switch (value) {
                .object => |detail_object| detail_object,
                else => {
                    const path = comptime "$.resourceSummary.limitDetails." ++ field;
                    return (try invalidReadiness(allocator, path, "expected object")).invalid;
                },
            };
            if (try limitDetailObjectDiagnostic(allocator, detail_object, field)) |diagnostic| return diagnostic;
        }
    }
    if (object.get("toolScopes")) |tool_scopes| {
        const array = switch (tool_scopes) {
            .array => |array| array,
            else => return (try invalidReadiness(allocator, "$.resourceSummary.limitDetails.toolScopes", "expected array")).invalid,
        };
        for (array.items, 0..) |scope, index| {
            const path = try std.fmt.allocPrint(allocator, "$.resourceSummary.limitDetails.toolScopes[{d}]", .{index});
            defer allocator.free(path);
            const text = switch (scope) {
                .string => |text| text,
                else => return (try invalidReadiness(allocator, path, "expected string")).invalid,
            };
            if (text.len == 0) return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
        }
    }
    return null;
}

fn limitDetailObjectDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8) !?SubAgentReadinessDiagnostic {
    const parent_path = try std.fmt.allocPrint(allocator, "$.resourceSummary.limitDetails.{s}", .{field});
    defer allocator.free(parent_path);

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!stringInComptimeTable(entry.key_ptr.*, &subagent_limit_detail_fields)) {
            const path = try std.fmt.allocPrint(allocator, "$.resourceSummary.limitDetails.{s}.{s}", .{ field, entry.key_ptr.* });
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "unsupported limit detail field")).invalid;
        }
    }
    if (try requiredNonNegativeNumberDiagnostic(allocator, object, parent_path, "limit")) |diagnostic| return diagnostic;
    if (try optionalNonNegativeNumberDiagnostic(allocator, object, parent_path, "actual")) |diagnostic| return diagnostic;
    if (try requiredBooleanDiagnostic(allocator, object, parent_path, "truncated")) |diagnostic| return diagnostic;
    if (try optionalStringDiagnostic(allocator, object, parent_path, "reason")) |diagnostic| return diagnostic;
    return null;
}

fn cancellationDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    const state = getString(object, "state") orelse return (try invalidReadiness(allocator, "$.cancellation.state", "missing required field")).invalid;
    if (!stringInComptimeTable(state, &subagent_cancellation_states)) {
        const message = try std.fmt.allocPrint(allocator, "unsupported cancellation state \"{s}\"", .{state});
        defer allocator.free(message);
        return (try invalidReadiness(allocator, "$.cancellation.state", message)).invalid;
    }
    inline for ([_][]const u8{ "signalId", "reason", "parentRunId", "parentTaskId", "propagatedFrom" }) |field| {
        if (try optionalStringDiagnostic(allocator, object, "$.cancellation", field)) |diagnostic| return diagnostic;
    }
    return null;
}

fn numericSummaryDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8) !?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (try nonNegativeNumberValueDiagnostic(allocator, entry.value_ptr.*, parent_path, entry.key_ptr.*)) |diagnostic| return diagnostic;
    }
    return null;
}

fn requiredNonNegativeNumberDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse {
        const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
        defer allocator.free(path);
        return (try invalidReadiness(allocator, path, "missing required field")).invalid;
    };
    return nonNegativeNumberValueDiagnostic(allocator, value, parent_path, field);
}

fn optionalNonNegativeIntegerDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse return null;
    const valid = switch (value) {
        .integer => |number| number >= 0 and @as(u64, @intCast(number)) <= MAX_SAFE_INTEGER,
        else => false,
    };
    if (valid) return null;
    const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
    defer allocator.free(path);
    return (try invalidReadiness(allocator, path, "expected non-negative integer")).invalid;
}

fn optionalNonNegativeNumberDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse return null;
    return nonNegativeNumberValueDiagnostic(allocator, value, parent_path, field);
}

fn nonNegativeNumberValueDiagnostic(allocator: std.mem.Allocator, value: std.json.Value, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const valid = switch (value) {
        .integer => |number| number >= 0,
        .float => |number| number >= 0,
        else => false,
    };
    if (valid) return null;
    const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
    defer allocator.free(path);
    return (try invalidReadiness(allocator, path, "expected non-negative number")).invalid;
}

fn requiredBooleanDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse {
        const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
        defer allocator.free(path);
        return (try invalidReadiness(allocator, path, "missing required field")).invalid;
    };
    switch (value) {
        .bool => return null,
        else => {},
    }
    const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
    defer allocator.free(path);
    return (try invalidReadiness(allocator, path, "expected boolean")).invalid;
}

fn optionalStringDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => {
            const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "expected string")).invalid;
        },
    };
    if (text.len != 0) return null;
    const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
    defer allocator.free(path);
    return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
}

fn getString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn stringInComptimeTable(value: []const u8, comptime table: []const []const u8) bool {
    inline for (table) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn invalidReadiness(allocator: std.mem.Allocator, path: []const u8, message: []const u8) !SubAgentReadinessValidation {
    return .{ .invalid = .{
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    } };
}

pub const EventHandlerResult = union(enum) {
    none,
    resources_discover: ResourcesDiscoverResult,
    input: InputEventResult,
    tool_result: ToolResultPatch,
    session_before: SessionBeforeResult,
    message_end: MessageEndResult,
    context: ContextEventResult,
    before_provider_request: BeforeProviderRequestEventResult,
    before_agent_start: BeforeAgentStartEventResult,
    tool_call: ToolCallEventResult,
    user_bash: UserBashEventResult,
};

pub const ExtensionError = struct {
    extension_path: []u8,
    event: []u8,
    @"error": []u8,

    fn deinit(self: *ExtensionError, allocator: std.mem.Allocator) void {
        allocator.free(self.extension_path);
        allocator.free(self.event);
        allocator.free(self.@"error");
        self.* = undefined;
    }
};

pub const ResultEventHandler = *const fn (event: ExtensionEvent) anyerror!EventHandlerResult;

/// Event bus for extension event handling
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayList(HandlerEntry),

    const HandlerEntry = struct {
        event_type: ExtensionEventType,
        handler: EventHandler,
        extension_path: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .handlers = std.ArrayList(HandlerEntry).empty,
        };
    }

    pub fn deinit(self: *EventBus) void {
        for (self.handlers.items) |*entry| {
            self.allocator.free(entry.extension_path);
        }
        self.handlers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Subscribe to an event type
    pub fn on(self: *EventBus, event_type: ExtensionEventType, handler: EventHandler, extension_path: []const u8) !void {
        try self.handlers.append(self.allocator, .{
            .event_type = event_type,
            .handler = handler,
            .extension_path = try self.allocator.dupe(u8, extension_path),
        });
    }

    /// Remove all handlers for a given extension path
    pub fn clearExtensionHandlers(self: *EventBus, extension_path: []const u8) void {
        var i: usize = self.handlers.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.handlers.items[i].extension_path, extension_path)) {
                self.allocator.free(self.handlers.items[i].extension_path);
                _ = self.handlers.orderedRemove(i);
            }
        }
    }

    /// Emit an event to all subscribed handlers
    pub fn emit(self: *EventBus, event: ExtensionEvent) !void {
        const event_type = std.meta.activeTag(event);
        for (self.handlers.items) |entry| {
            if (entry.event_type == event_type) {
                try entry.handler(event);
            }
        }
    }

    /// Check if there are any handlers for a given event type
    pub fn hasHandlers(self: *const EventBus, event_type: ExtensionEventType) bool {
        for (self.handlers.items) |entry| {
            if (entry.event_type == event_type) return true;
        }
        return false;
    }
};

/// Result-returning event bus used by low-architecture parity tests and
/// host bridges that need the same observable aggregation contract as the
/// TypeScript extension runner. Handler order is extension registration
/// order, errors are recorded with TypeScript-compatible fields, and
/// successful handlers continue after non-terminal failures.
pub const ResultEventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayList(HandlerEntry),
    errors: std.ArrayList(ExtensionError),

    const HandlerEntry = struct {
        event_type: ExtensionEventType,
        handler: ResultEventHandler,
        extension_path: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) ResultEventBus {
        return .{
            .allocator = allocator,
            .handlers = std.ArrayList(HandlerEntry).empty,
            .errors = std.ArrayList(ExtensionError).empty,
        };
    }

    pub fn deinit(self: *ResultEventBus) void {
        for (self.handlers.items) |*entry| {
            self.allocator.free(entry.extension_path);
        }
        self.handlers.deinit(self.allocator);
        for (self.errors.items) |*err| err.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn on(self: *ResultEventBus, event_type: ExtensionEventType, handler: ResultEventHandler, extension_path: []const u8) !void {
        try self.handlers.append(self.allocator, .{
            .event_type = event_type,
            .handler = handler,
            .extension_path = try self.allocator.dupe(u8, extension_path),
        });
    }

    pub fn emitLifecycle(self: *ResultEventBus, event: ExtensionEvent) !void {
        const event_type = std.meta.activeTag(event);
        for (self.handlers.items) |entry| {
            if (entry.event_type != event_type) continue;
            _ = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, event_type, err);
                continue;
            };
        }
    }

    pub fn emitSessionBefore(self: *ResultEventBus, event: ExtensionEvent) !?SessionBeforeResult {
        const event_type = std.meta.activeTag(event);
        switch (event_type) {
            .session_before_switch, .session_before_fork, .session_before_compact, .session_before_tree => {},
            else => return null,
        }

        var result: ?SessionBeforeResult = null;
        for (self.handlers.items) |entry| {
            if (entry.event_type != event_type) continue;
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, event_type, err);
                continue;
            };
            switch (handler_result) {
                .session_before => |session_result| {
                    result = session_result;
                    if (session_result.cancel) return session_result;
                },
                else => {},
            }
        }
        return result;
    }

    pub fn emitResourcesDiscover(self: *ResultEventBus, cwd: []const u8, reason: []const u8) !ResourcesDiscoverCombinedResult {
        var skill_paths = std.ArrayList(ResourcePathResult).empty;
        errdefer deinitResourcePathList(self.allocator, &skill_paths);
        var prompt_paths = std.ArrayList(ResourcePathResult).empty;
        errdefer deinitResourcePathList(self.allocator, &prompt_paths);
        var theme_paths = std.ArrayList(ResourcePathResult).empty;
        errdefer deinitResourcePathList(self.allocator, &theme_paths);

        const event = ExtensionEvent{ .resources_discover = .{ .cwd = cwd, .reason = reason } };
        for (self.handlers.items) |entry| {
            if (entry.event_type != .resources_discover) continue;
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .resources_discover, err);
                continue;
            };
            switch (handler_result) {
                .resources_discover => |result| {
                    try appendResourcePaths(self.allocator, &skill_paths, result.skill_paths, entry.extension_path);
                    try appendResourcePaths(self.allocator, &prompt_paths, result.prompt_paths, entry.extension_path);
                    try appendResourcePaths(self.allocator, &theme_paths, result.theme_paths, entry.extension_path);
                },
                else => {},
            }
        }

        return .{
            .skill_paths = try skill_paths.toOwnedSlice(self.allocator),
            .prompt_paths = try prompt_paths.toOwnedSlice(self.allocator),
            .theme_paths = try theme_paths.toOwnedSlice(self.allocator),
        };
    }

    pub fn emitInput(self: *ResultEventBus, data: []const u8) !OwnedInputEventResult {
        return self.emitInputWithImages(data, &.{});
    }

    pub fn emitInputWithImages(self: *ResultEventBus, data: []const u8, images: []const []const u8) !OwnedInputEventResult {
        var current = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(current);
        var current_images = images;
        var modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .input) continue;
            const event = ExtensionEvent{ .input = .{ .data = current, .images = current_images } };
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .input, err);
                continue;
            };
            switch (handler_result) {
                .input => |result| switch (result.action) {
                    .handled => {
                        self.allocator.free(current);
                        return .{ .action = .handled };
                    },
                    .transform => {
                        if (result.text) |text| {
                            const next = try self.allocator.dupe(u8, text);
                            self.allocator.free(current);
                            current = next;
                            modified = true;
                        }
                        if (result.images) |next_images| {
                            current_images = next_images;
                            modified = true;
                        }
                    },
                    .@"continue" => {},
                },
                else => {},
            }
        }

        if (modified) {
            return .{ .action = .transform, .text = current, .images = current_images };
        }
        self.allocator.free(current);
        return .{ .action = .@"continue" };
    }

    pub fn emitMessageEnd(self: *ResultEventBus, event: MessageEndEvent) !?MessageEndCombinedResult {
        var current_role = event.role;
        var current_message = event.final_message;
        var modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .message_end) continue;
            const current_event = ExtensionEvent{ .message_end = .{
                .message_id = event.message_id,
                .role = current_role,
                .final_message = current_message,
            } };
            const handler_result = entry.handler(current_event) catch |err| {
                try self.recordError(entry.extension_path, .message_end, err);
                continue;
            };
            switch (handler_result) {
                .message_end => |replacement| {
                    if (replacement.message) |message| {
                        const replacement_role = replacement.role orelse current_role;
                        if (!std.mem.eql(u8, replacement_role, current_role)) {
                            try self.recordErrorMessage(entry.extension_path, .message_end, "message_end handlers must return a message with the same role");
                            continue;
                        }
                        current_role = replacement_role;
                        current_message = message;
                        modified = true;
                    }
                },
                else => {},
            }
        }

        if (!modified) return null;
        return .{ .role = current_role, .message = current_message };
    }

    pub fn emitContext(self: *ResultEventBus, messages: []const []const u8) ![]const []const u8 {
        var current_messages = messages;
        for (self.handlers.items) |entry| {
            if (entry.event_type != .context) continue;
            const event = ExtensionEvent{ .context = .{ .messages = current_messages } };
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .context, err);
                continue;
            };
            switch (handler_result) {
                .context => |result| {
                    if (result.messages) |next| current_messages = next;
                },
                else => {},
            }
        }
        return current_messages;
    }

    pub fn emitBeforeProviderRequest(self: *ResultEventBus, payload: []const u8) ![]const u8 {
        var current_payload = payload;
        for (self.handlers.items) |entry| {
            if (entry.event_type != .before_provider_request) continue;
            const event = ExtensionEvent{ .before_provider_request = .{
                .model = "",
                .messages = &.{},
                .payload = current_payload,
            } };
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .before_provider_request, err);
                continue;
            };
            switch (handler_result) {
                .before_provider_request => |result| {
                    if (result.payload) |next| current_payload = next;
                },
                else => {},
            }
        }
        return current_payload;
    }

    pub fn emitBeforeAgentStart(
        self: *ResultEventBus,
        prompt: []const u8,
        images: []const []const u8,
        system_prompt: []const u8,
    ) !?BeforeAgentStartCombinedResult {
        var current_system_prompt = system_prompt;
        var messages = std.ArrayList([]const u8).empty;
        errdefer messages.deinit(self.allocator);
        var system_prompt_modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .before_agent_start) continue;
            const event = ExtensionEvent{ .before_agent_start = .{
                .prompt = prompt,
                .images = images,
                .system_prompt = current_system_prompt,
                .messages = messages.items,
            } };
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .before_agent_start, err);
                continue;
            };
            switch (handler_result) {
                .before_agent_start => |result| {
                    if (result.message) |message| try messages.append(self.allocator, message);
                    if (result.system_prompt) |next| {
                        current_system_prompt = next;
                        system_prompt_modified = true;
                    }
                },
                else => {},
            }
        }

        if (messages.items.len == 0 and !system_prompt_modified) {
            messages.deinit(self.allocator);
            return null;
        }
        return .{
            .messages = try messages.toOwnedSlice(self.allocator),
            .system_prompt = if (system_prompt_modified) current_system_prompt else null,
        };
    }

    pub fn emitToolCall(self: *ResultEventBus, event: ToolCallEvent) !?ToolCallCombinedResult {
        var current_input = event.input;
        var modified = false;
        var result_seen = false;
        var last_reason: ?[]const u8 = null;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .tool_call) continue;
            const current_event = ExtensionEvent{ .tool_call = .{
                .tool_name = event.tool_name,
                .tool_call_id = event.tool_call_id,
                .input = current_input,
            } };
            const handler_result = entry.handler(current_event) catch |err| {
                try self.recordError(entry.extension_path, .tool_call, err);
                continue;
            };
            switch (handler_result) {
                .tool_call => |result| {
                    result_seen = true;
                    if (result.input) |next_input| {
                        current_input = next_input;
                        modified = true;
                    }
                    last_reason = result.reason;
                    if (result.block) {
                        return .{
                            .input = current_input,
                            .block = true,
                            .reason = result.reason,
                        };
                    }
                },
                else => {},
            }
        }

        if (!modified and !result_seen) return null;
        return .{ .input = current_input, .reason = last_reason };
    }

    pub fn emitToolResult(self: *ResultEventBus, event: ToolResultEvent) !?ToolResultCombinedResult {
        var current_content = event.content;
        var current_details = event.details;
        var current_is_error = event.is_error;
        var modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .tool_result) continue;
            const current_event = ExtensionEvent{ .tool_result = .{
                .tool_name = event.tool_name,
                .tool_call_id = event.tool_call_id,
                .result = event.result,
                .content = current_content,
                .details = current_details,
                .is_error = current_is_error,
            } };
            const handler_result = entry.handler(current_event) catch |err| {
                try self.recordError(entry.extension_path, .tool_result, err);
                continue;
            };
            switch (handler_result) {
                .tool_result => |patch| {
                    if (patch.content) |content| {
                        current_content = content;
                        modified = true;
                    }
                    if (patch.details) |details| {
                        current_details = details;
                        modified = true;
                    }
                    if (patch.is_error) |is_error| {
                        current_is_error = is_error;
                        modified = true;
                    }
                },
                else => {},
            }
        }

        if (!modified) return null;
        return .{
            .content = current_content,
            .details = current_details,
            .is_error = current_is_error,
        };
    }

    pub fn emitUserBash(self: *ResultEventBus, event: UserBashEvent) !?UserBashEventResult {
        for (self.handlers.items) |entry| {
            if (entry.event_type != .user_bash) continue;
            const handler_result = entry.handler(.{ .user_bash = event }) catch |err| {
                try self.recordError(entry.extension_path, .user_bash, err);
                continue;
            };
            switch (handler_result) {
                .user_bash => |result| return result,
                else => {},
            }
        }
        return null;
    }

    fn recordError(self: *ResultEventBus, extension_path: []const u8, event_type: ExtensionEventType, err: anyerror) !void {
        try self.recordErrorMessage(extension_path, event_type, @errorName(err));
    }

    fn recordErrorMessage(self: *ResultEventBus, extension_path: []const u8, event_type: ExtensionEventType, message: []const u8) !void {
        const path_dup = try self.allocator.dupe(u8, extension_path);
        errdefer self.allocator.free(path_dup);
        const event_name_value = eventName(event_type);
        const event_dup = try self.allocator.dupe(u8, event_name_value);
        errdefer self.allocator.free(event_dup);
        const error_dup = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(error_dup);
        try self.errors.append(self.allocator, .{
            .extension_path = path_dup,
            .event = event_dup,
            .@"error" = error_dup,
        });
    }
};

fn appendResourcePaths(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ResourcePathResult),
    paths: []const []const u8,
    extension_path: []const u8,
) !void {
    for (paths) |path| {
        const path_dup = try allocator.dupe(u8, path);
        errdefer allocator.free(path_dup);
        const extension_path_dup = try allocator.dupe(u8, extension_path);
        errdefer allocator.free(extension_path_dup);
        try out.append(allocator, .{ .path = path_dup, .extension_path = extension_path_dup });
    }
}

fn deinitResourcePathList(allocator: std.mem.Allocator, list: *std.ArrayList(ResourcePathResult)) void {
    for (list.items) |*path| path.deinit(allocator);
    list.deinit(allocator);
}

const event_surface_name_table: [@typeInfo(ExtensionEventType).@"enum".fields.len][]const u8 = blk: {
    const fields = @typeInfo(ExtensionEventType).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, index| names[index] = field.name;
    break :blk names;
};

pub fn eventSurfaceNames() []const []const u8 {
    return &event_surface_name_table;
}

pub fn eventName(event_type: ExtensionEventType) []const u8 {
    return @tagName(event_type);
}

pub const testing = struct {
    pub fn subagentForbiddenFields() []const []const u8 {
        return &subagent_forbidden_fields;
    }
};

test {
    _ = @import("extension_events/tests.zig");
}
