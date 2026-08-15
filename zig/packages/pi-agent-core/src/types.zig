const std = @import("std");
const pi_types = @import("pi-types");

pub const AgentLoopError = error{
    MissingAssistantResult,
    PartialContentOutOfOrder,
    PartialContentIndexReused,
    ToolCallAlreadyFinalized,
};

pub const AgentMessage = pi_types.Message;
pub const AgentToolCall = pi_types.ToolCall;
pub const ToolResultMessage = pi_types.ToolResultMessage;

pub fn nowMilliseconds() i64 {
    if (std.c.getenv("PI_FIXED_NOW_MS")) |value| {
        if (std.fmt.parseInt(i64, std.mem.span(value), 10)) |fixed_now_ms| {
            return fixed_now_ms;
        } else |_| {}
    }
    var now: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&now, null);
    return @as(i64, @intCast(now.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(now.usec)), std.time.us_per_ms);
}

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

/// Configuration for how tool calls from a single assistant message are
/// executed.
///
/// - `sequential`: each tool call is prepared, executed, finalized, and
///   emitted before the next tool starts.
/// - `parallel`: tool calls are prepared sequentially, then allowed tools
///   execute concurrently. Prepared calls run `after_tool_call` and emit
///   `tool_execution_end` in completion order; tool-result message artifacts
///   are emitted later in assistant source order.
pub const ToolExecutionMode = enum {
    sequential,
    parallel,
};

pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
    /// Hint that the agent should stop after the current tool batch when this
    /// call is blocked. Early termination only happens when every finalized
    /// tool result in the batch sets this to true.
    terminate: bool = false,
};

pub const AfterToolCallResult = struct {
    content: ?[]const pi_types.ContentBlock = null,
    details: ?std.json.Value = null,
    is_error: ?bool = null,
    /// Replaces the early-termination hint when provided.
    terminate: ?bool = null,
};

pub const AgentToolResult = struct {
    content: []const pi_types.ContentBlock,
    details: ?std.json.Value = null,
    is_error: bool = false,
    terminate: bool = false,
};

pub const AgentToolSource = enum {
    builtin,
    extension,
    custom,
};

pub const AgentToolUpdateCallback = *const fn (
    context: ?*anyopaque,
    // Borrowed for the duration of the callback. Clone any owned fields before retaining them.
    partial_result: AgentToolResult,
) anyerror!void;

pub const PrepareArgumentsFn = *const fn (
    allocator: std.mem.Allocator,
    args: std.json.Value,
) anyerror!std.json.Value;

pub const ToolArgumentValidationFailure = struct {
    code: []const u8,
    message: []const u8,
    path: []const u8,
};

pub const InvalidArgumentsResultFn = *const fn (
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    failure: ToolArgumentValidationFailure,
) anyerror!AgentToolResult;

pub const ExecuteToolFn = *const fn (
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?AgentToolUpdateCallback,
) anyerror!AgentToolResult;

pub const DeinitToolContextFn = *const fn (
    allocator: std.mem.Allocator,
    tool_context: ?*anyopaque,
) void;

pub const BeforeToolCallContext = struct {
    assistant_message: pi_types.AssistantMessage,
    tool_call: AgentToolCall,
    args: *std.json.Value,
    context: AgentContext,
};

pub const AfterToolCallContext = struct {
    assistant_message: pi_types.AssistantMessage,
    tool_call: AgentToolCall,
    args: std.json.Value,
    result: AgentToolResult,
    is_error: bool,
    context: AgentContext,
};

pub const ShouldStopAfterTurnContext = struct {
    assistant_message: pi_types.AssistantMessage,
    tool_results: []const ToolResultMessage,
    context: AgentContext,
    new_messages: []const AgentMessage,
};

pub const AgentLoopTurnUpdate = struct {
    context: ?AgentContext = null,
    model: ?pi_types.Model = null,
    thinking_level: ?ThinkingLevel = null,
};

pub const PrepareNextTurnContext = ShouldStopAfterTurnContext;

pub const BeforeToolCallFn = *const fn (
    allocator: std.mem.Allocator,
    context: BeforeToolCallContext,
    signal: ?*const std.atomic.Value(bool),
) anyerror!?BeforeToolCallResult;

pub const AfterToolCallFn = *const fn (
    allocator: std.mem.Allocator,
    context: AfterToolCallContext,
    signal: ?*const std.atomic.Value(bool),
) anyerror!?AfterToolCallResult;

pub const ShouldStopAfterTurnFn = *const fn (
    allocator: std.mem.Allocator,
    context: ShouldStopAfterTurnContext,
    callback_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
) anyerror!bool;

pub const PrepareNextTurnFn = *const fn (
    allocator: std.mem.Allocator,
    context: PrepareNextTurnContext,
    callback_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
) anyerror!?AgentLoopTurnUpdate;

pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    label: []const u8,
    parameters: std.json.Value,
    source: AgentToolSource = .custom,
    prepare_arguments: ?PrepareArgumentsFn = null,
    invalid_arguments_result: ?InvalidArgumentsResultFn = null,
    execute: ?ExecuteToolFn = null,
    execute_context: ?*anyopaque = null,
    deinit_execute_context: ?DeinitToolContextFn = null,
    execution_mode: ?ToolExecutionMode = null,
};

pub const AgentState = struct {
    system_prompt: []const u8,
    model: pi_types.Model,
    thinking_level: ThinkingLevel,
    tools: []const AgentTool,
    messages: []const AgentMessage,
    is_streaming: bool,
    streaming_message: ?AgentMessage,
    pending_tool_calls: []const []const u8,
    error_message: ?[]const u8,
};

pub const AgentContext = struct {
    system_prompt: []const u8,
    messages: []const AgentMessage,
    tools: []const AgentTool = &.{},
    extension_hook_context: ?*anyopaque = null,
};

pub const StreamFn = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    context: pi_types.Context,
    options: ?pi_types.SimpleStreamOptions,
    stream_context: ?*anyopaque,
) anyerror!pi_types.event_stream.AssistantMessageEventStream;

pub const ConvertToLlmFn = *const fn (
    allocator: std.mem.Allocator,
    messages: []const AgentMessage,
    convert_context: ?*anyopaque,
) anyerror![]pi_types.Message;

pub const TransformContextFn = *const fn (
    allocator: std.mem.Allocator,
    messages: []const AgentMessage,
    signal: ?*const std.atomic.Value(bool),
    transform_context: ?*anyopaque,
) anyerror![]AgentMessage;

pub const MessageEndTransformFn = *const fn (
    allocator: std.mem.Allocator,
    message: AgentMessage,
    transform_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
) anyerror!?AgentMessage;

pub const PendingMessagesFn = *const fn (
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) anyerror![]AgentMessage;

pub const PromptAcceptedCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque) anyerror!void,
};

pub const AgentLoopConfig = struct {
    model: pi_types.Model,
    api_key: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    reasoning: ?ThinkingLevel = null,
    tool_execution: ToolExecutionMode = .parallel,
    before_tool_call: ?BeforeToolCallFn = null,
    after_tool_call: ?AfterToolCallFn = null,
    convert_to_llm: ConvertToLlmFn,
    convert_to_llm_context: ?*anyopaque = null,
    transform_context: ?TransformContextFn = null,
    transform_context_context: ?*anyopaque = null,
    extension_hook_context: ?*anyopaque = null,
    stream_context: ?*anyopaque = null,
    get_steering_messages_context: ?*anyopaque = null,
    get_steering_messages: ?PendingMessagesFn = null,
    get_follow_up_messages_context: ?*anyopaque = null,
    get_follow_up_messages: ?PendingMessagesFn = null,
    prepare_next_turn_context: ?*anyopaque = null,
    prepare_next_turn: ?PrepareNextTurnFn = null,
    should_stop_after_turn_context: ?*anyopaque = null,
    should_stop_after_turn: ?ShouldStopAfterTurnFn = null,
};

pub const AgentEventType = enum {
    agent_start,
    agent_end,
    turn_start,
    turn_end,
    message_start,
    message_update,
    message_end,
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
    before_provider_request,
    after_provider_response,
};

pub const AgentEvent = struct {
    event_type: AgentEventType,
    message: ?AgentMessage = null,
    messages: ?[]const AgentMessage = null,
    assistant_message_event: ?pi_types.AssistantMessageEvent = null,
    tool_results: ?[]const ToolResultMessage = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    args: ?std.json.Value = null,
    result: ?AgentToolResult = null,
    partial_result: ?AgentToolResult = null,
    is_error: ?bool = null,
};

/// Agent event sink invoked by the agent loop.
///
/// During parallel tool execution this callback may be invoked from worker
/// threads for `tool_execution_update` events. Callers that write shared state
/// or output streams must serialize their own access; the agent loop serializes
/// concurrent worker-thread update emits before calling the supplied callback.
pub const AgentEventCallback = *const fn (
    context: ?*anyopaque,
    event: AgentEvent,
) anyerror!void;

pub const AgentSubscriber = struct {
    context: ?*anyopaque = null,
    callback: AgentEventCallback,
};

test "thinking levels include off" {
    try std.testing.expectEqual(ThinkingLevel.off, .off);
    try std.testing.expectEqual(ToolExecutionMode.parallel, .parallel);
}

test "nowMilliseconds returns current epoch milliseconds" {
    const before = nowMilliseconds();
    const actual = nowMilliseconds();
    const after = nowMilliseconds();

    try std.testing.expect(actual > 0);
    try std.testing.expect(actual >= before - 2000);
    try std.testing.expect(actual <= after + 2000);
}

test "agent event type includes single turn lifecycle variants" {
    try std.testing.expectEqual(AgentEventType.agent_start, .agent_start);
    try std.testing.expectEqual(AgentEventType.message_update, .message_update);
    try std.testing.expectEqual(AgentEventType.agent_end, .agent_end);
}
