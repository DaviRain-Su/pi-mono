const std = @import("std");
const pi_types = @import("pi-types");
const agent_loop = @import("agent_loop.zig");
const content_clone = @import("content_clone.zig");
const provider_json = pi_types.json;
const types = @import("types.zig");
const test_faux = @import("test_faux.zig");

const EMPTY_INPUT_TYPES = [_][]const u8{};

pub const QueueMode = enum {
    all,
    one_at_a_time,
};

pub const PendingMessageQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: QueueMode,
    messages: std.ArrayList(types.AgentMessage),
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, mode: QueueMode) PendingMessageQueue {
        return .{
            .allocator = allocator,
            .io = io,
            .mode = mode,
            .messages = .empty,
        };
    }

    pub fn deinit(self: *PendingMessageQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        deinitMessageSlice(self.allocator, self.messages.items);
        self.messages.deinit(self.allocator);
    }

    pub fn enqueue(self: *PendingMessageQueue, message: types.AgentMessage) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var owned_message = try cloneMessage(self.allocator, message);
        errdefer deinitMessage(self.allocator, &owned_message);
        try self.messages.append(self.allocator, owned_message);
    }

    pub fn hasItems(self: *const PendingMessageQueue) bool {
        @constCast(&self.mutex).lockUncancelable(self.io);
        defer @constCast(&self.mutex).unlock(self.io);
        return self.messages.items.len > 0;
    }

    pub fn len(self: *const PendingMessageQueue) usize {
        @constCast(&self.mutex).lockUncancelable(self.io);
        defer @constCast(&self.mutex).unlock(self.io);
        return self.messages.items.len;
    }

    pub fn clear(self: *PendingMessageQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        deinitMessageSlice(self.allocator, self.messages.items);
        self.messages.clearRetainingCapacity();
    }

    pub fn snapshot(self: *const PendingMessageQueue, allocator: std.mem.Allocator) ![]types.AgentMessage {
        @constCast(&self.mutex).lockUncancelable(self.io);
        defer @constCast(&self.mutex).unlock(self.io);

        if (self.messages.items.len == 0) {
            return try allocator.alloc(types.AgentMessage, 0);
        }

        return try cloneMessageSlice(allocator, self.messages.items);
    }

    pub fn takeAll(self: *PendingMessageQueue, allocator: std.mem.Allocator) ![]types.AgentMessage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.messages.items.len == 0) {
            return try allocator.alloc(types.AgentMessage, 0);
        }

        const drained = try cloneMessageSlice(allocator, self.messages.items);
        deinitMessageSlice(self.allocator, self.messages.items);
        self.messages.clearRetainingCapacity();
        return drained;
    }

    pub fn drain(self: *PendingMessageQueue, allocator: std.mem.Allocator) ![]types.AgentMessage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.messages.items.len == 0) {
            return try allocator.alloc(types.AgentMessage, 0);
        }

        if (self.mode == .all) {
            const drained = try cloneMessageSlice(allocator, self.messages.items);
            deinitMessageSlice(self.allocator, self.messages.items);
            self.messages.clearRetainingCapacity();
            return drained;
        }

        const first = try cloneMessageSlice(allocator, self.messages.items[0..1]);
        var removed = self.messages.orderedRemove(0);
        deinitMessage(self.allocator, &removed);
        return first;
    }
};

pub const AgentOptions = struct {
    system_prompt: []const u8 = "",
    model: ?pi_types.Model = null,
    api_key: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    thinking_level: types.ThinkingLevel = .off,
    tools: []const types.AgentTool = &.{},
    messages: []const types.AgentMessage = &.{},
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,
    tool_execution: types.ToolExecutionMode = .parallel,
    io: std.Io = std.Io.failing,
    stream_fn: ?types.StreamFn = null,
    stream_context: ?*anyopaque = null,
    convert_to_llm: ?types.ConvertToLlmFn = null,
    convert_to_llm_context: ?*anyopaque = null,
    transform_context: ?types.TransformContextFn = null,
    transform_context_context: ?*anyopaque = null,
    message_end_transform: ?types.MessageEndTransformFn = null,
    message_end_transform_context: ?*anyopaque = null,
    extension_hook_context: ?*anyopaque = null,
    before_tool_call: ?types.BeforeToolCallFn = null,
    after_tool_call: ?types.AfterToolCallFn = null,
    should_stop_after_turn: ?types.ShouldStopAfterTurnFn = null,
    should_stop_after_turn_context: ?*anyopaque = null,
    prepare_next_turn: ?types.PrepareNextTurnFn = null,
    prepare_next_turn_context: ?*anyopaque = null,
};

pub const DEFAULT_MODEL = pi_types.Model{
    .id = "unknown",
    .name = "unknown",
    .api = "unknown",
    .provider = "unknown",
    .base_url = "",
    .reasoning = false,
    .input_types = EMPTY_INPUT_TYPES[0..],
    .cost = .{},
    .context_window = 0,
    .max_tokens = 0,
    .headers = null,
    .compat = null,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    model: pi_types.Model,
    api_key: ?[]const u8,
    session_id: ?[]const u8,
    thinking_level: types.ThinkingLevel,
    tools: std.ArrayList(types.AgentTool),
    messages: std.ArrayList(types.AgentMessage),
    is_streaming: bool,
    streaming_message: ?types.AgentMessage,
    pending_tool_calls: std.ArrayList([]const u8),
    error_message: ?[]const u8,
    steering_queue: PendingMessageQueue,
    follow_up_queue: PendingMessageQueue,
    tool_execution: types.ToolExecutionMode,
    io: std.Io,
    stream_fn: ?types.StreamFn,
    stream_context: ?*anyopaque,
    convert_to_llm: types.ConvertToLlmFn,
    convert_to_llm_context: ?*anyopaque,
    transform_context: ?types.TransformContextFn,
    transform_context_context: ?*anyopaque,
    message_end_transform: ?types.MessageEndTransformFn,
    message_end_transform_context: ?*anyopaque,
    extension_hook_context: ?*anyopaque,
    before_tool_call: ?types.BeforeToolCallFn,
    after_tool_call: ?types.AfterToolCallFn,
    should_stop_after_turn: ?types.ShouldStopAfterTurnFn,
    should_stop_after_turn_context: ?*anyopaque,
    prepare_next_turn: ?types.PrepareNextTurnFn,
    prepare_next_turn_context: ?*anyopaque,
    listeners: std.ArrayList(types.AgentSubscriber),
    active_abort_signal: ?*std.atomic.Value(bool),
    run_state_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, options: AgentOptions) !Agent {
        var agent = Agent{
            .allocator = allocator,
            .system_prompt = options.system_prompt,
            .model = options.model orelse DEFAULT_MODEL,
            .api_key = options.api_key,
            .session_id = options.session_id,
            .thinking_level = options.thinking_level,
            .tools = .empty,
            .messages = .empty,
            .is_streaming = false,
            .streaming_message = null,
            .pending_tool_calls = .empty,
            .error_message = null,
            .steering_queue = PendingMessageQueue.init(allocator, options.io, options.steering_mode),
            .follow_up_queue = PendingMessageQueue.init(allocator, options.io, options.follow_up_mode),
            .tool_execution = options.tool_execution,
            .io = options.io,
            .stream_fn = options.stream_fn,
            .stream_context = options.stream_context,
            .convert_to_llm = options.convert_to_llm orelse defaultConvertToLlm,
            .convert_to_llm_context = options.convert_to_llm_context,
            .transform_context = options.transform_context,
            .transform_context_context = options.transform_context_context,
            .message_end_transform = options.message_end_transform,
            .message_end_transform_context = options.message_end_transform_context,
            .extension_hook_context = options.extension_hook_context,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
            .should_stop_after_turn = options.should_stop_after_turn,
            .should_stop_after_turn_context = options.should_stop_after_turn_context,
            .prepare_next_turn = options.prepare_next_turn,
            .prepare_next_turn_context = options.prepare_next_turn_context,
            .listeners = .empty,
            .active_abort_signal = null,
        };
        errdefer agent.deinit();

        try agent.setTools(options.tools);
        try agent.setMessages(options.messages);
        return agent;
    }

    pub fn deinit(self: *Agent) void {
        self.clearOwnedMessages();
        self.tools.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.pending_tool_calls.deinit(self.allocator);
        self.steering_queue.deinit();
        self.follow_up_queue.deinit();
        self.listeners.deinit(self.allocator);
        if (self.error_message) |error_message| self.allocator.free(error_message);
    }

    pub fn state(self: *const Agent) types.AgentState {
        return .{
            .system_prompt = self.system_prompt,
            .model = self.model,
            .thinking_level = self.thinking_level,
            .tools = self.tools.items,
            .messages = self.messages.items,
            .is_streaming = self.is_streaming,
            .streaming_message = self.streaming_message,
            .pending_tool_calls = self.pending_tool_calls.items,
            .error_message = self.error_message,
        };
    }

    pub fn getSystemPrompt(self: *const Agent) []const u8 {
        return self.system_prompt;
    }

    pub fn setSystemPrompt(self: *Agent, system_prompt: []const u8) void {
        self.system_prompt = system_prompt;
    }

    pub fn getModel(self: *const Agent) pi_types.Model {
        return self.model;
    }

    pub fn setModel(self: *Agent, model: pi_types.Model) void {
        self.model = model;
    }

    pub fn getApiKey(self: *const Agent) ?[]const u8 {
        return self.api_key;
    }

    pub fn setApiKey(self: *Agent, api_key: ?[]const u8) void {
        self.api_key = api_key;
    }

    pub fn getThinkingLevel(self: *const Agent) types.ThinkingLevel {
        return self.thinking_level;
    }

    pub fn setThinkingLevel(self: *Agent, thinking_level: types.ThinkingLevel) void {
        self.thinking_level = thinking_level;
    }

    pub fn getTools(self: *const Agent) []const types.AgentTool {
        return self.tools.items;
    }

    pub fn setTools(self: *Agent, next_tools: []const types.AgentTool) !void {
        self.tools.clearRetainingCapacity();
        try self.tools.appendSlice(self.allocator, next_tools);
    }

    pub fn getMessages(self: *const Agent) []const types.AgentMessage {
        return self.messages.items;
    }

    pub fn setMessages(self: *Agent, next_messages: []const types.AgentMessage) !void {
        self.clearOwnedMessages();
        for (next_messages) |message| {
            try self.messages.append(self.allocator, try cloneMessage(self.allocator, message));
        }
    }

    pub fn appendMessage(self: *Agent, message: types.AgentMessage) !void {
        try self.messages.append(self.allocator, try cloneMessage(self.allocator, message));
    }

    pub fn removeLastMessage(self: *Agent) bool {
        if (self.messages.items.len == 0) return false;
        var removed = self.messages.pop().?;
        deinitMessage(self.allocator, &removed);
        return true;
    }

    pub fn getStreamingMessage(self: *const Agent) ?types.AgentMessage {
        return self.streaming_message;
    }

    pub fn setStreamingMessage(self: *Agent, message: ?types.AgentMessage) void {
        self.streaming_message = message;
    }

    pub fn isStreaming(self: *const Agent) bool {
        return self.is_streaming;
    }

    pub fn beginRun(self: *Agent) void {
        self.is_streaming = true;
        self.streaming_message = null;
        self.setErrorMessage(null);
    }

    pub fn finishRun(self: *Agent) void {
        self.is_streaming = false;
        self.streaming_message = null;
        self.clearPendingToolCalls();
        self.run_state_mutex.lockUncancelable(self.io);
        defer self.run_state_mutex.unlock(self.io);
        self.active_abort_signal = null;
    }

    pub fn getPendingToolCalls(self: *const Agent) []const []const u8 {
        return self.pending_tool_calls.items;
    }

    pub fn addPendingToolCall(self: *Agent, tool_call_id: []const u8) !void {
        for (self.pending_tool_calls.items) |existing| {
            if (std.mem.eql(u8, existing, tool_call_id)) return;
        }
        try self.pending_tool_calls.append(self.allocator, tool_call_id);
    }

    pub fn removePendingToolCall(self: *Agent, tool_call_id: []const u8) bool {
        for (self.pending_tool_calls.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, tool_call_id)) {
                _ = self.pending_tool_calls.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    pub fn clearPendingToolCalls(self: *Agent) void {
        self.pending_tool_calls.clearRetainingCapacity();
    }

    pub fn getErrorMessage(self: *const Agent) ?[]const u8 {
        return self.error_message;
    }

    pub fn setErrorMessage(self: *Agent, error_message: ?[]const u8) void {
        if (self.error_message) |previous| self.allocator.free(previous);
        self.error_message = if (error_message) |message|
            self.allocator.dupe(u8, message) catch @panic("out of memory while storing agent error message")
        else
            null;
    }

    pub fn steer(self: *Agent, message: types.AgentMessage) !void {
        try self.steering_queue.enqueue(message);
    }

    pub fn followUp(self: *Agent, message: types.AgentMessage) !void {
        try self.follow_up_queue.enqueue(message);
    }

    pub fn abort(self: *Agent) void {
        self.run_state_mutex.lockUncancelable(self.io);
        defer self.run_state_mutex.unlock(self.io);

        if (self.active_abort_signal) |signal| {
            signal.store(true, .seq_cst);
        }
    }

    pub fn clearSteeringQueue(self: *Agent) void {
        self.steering_queue.clear();
    }

    pub fn clearFollowUpQueue(self: *Agent) void {
        self.follow_up_queue.clear();
    }

    pub fn clearAllQueues(self: *Agent) void {
        self.clearSteeringQueue();
        self.clearFollowUpQueue();
    }

    pub fn snapshotSteeringMessages(self: *const Agent, allocator: std.mem.Allocator) ![]types.AgentMessage {
        return try self.steering_queue.snapshot(allocator);
    }

    pub fn snapshotFollowUpMessages(self: *const Agent, allocator: std.mem.Allocator) ![]types.AgentMessage {
        return try self.follow_up_queue.snapshot(allocator);
    }

    pub fn takeSteeringMessages(self: *Agent, allocator: std.mem.Allocator) ![]types.AgentMessage {
        return try self.steering_queue.takeAll(allocator);
    }

    pub fn takeFollowUpMessages(self: *Agent, allocator: std.mem.Allocator) ![]types.AgentMessage {
        return try self.follow_up_queue.takeAll(allocator);
    }

    pub fn hasQueuedMessages(self: *const Agent) bool {
        return self.steering_queue.hasItems() or self.follow_up_queue.hasItems();
    }

    pub fn steeringQueueLen(self: *const Agent) usize {
        return self.steering_queue.len();
    }

    pub fn followUpQueueLen(self: *const Agent) usize {
        return self.follow_up_queue.len();
    }

    pub fn reset(self: *Agent) error{AgentBusy}!void {
        if (self.is_streaming) return error.AgentBusy;
        self.clearOwnedMessages();
        self.streaming_message = null;
        self.clearPendingToolCalls();
        self.setErrorMessage(null);
        self.clearAllQueues();
    }

    pub fn subscribe(self: *Agent, subscriber: types.AgentSubscriber) !void {
        try self.listeners.append(self.allocator, subscriber);
    }

    pub fn unsubscribe(self: *Agent, subscriber: types.AgentSubscriber) bool {
        for (self.listeners.items, 0..) |listener, index| {
            if (listener.context == subscriber.context and listener.callback == subscriber.callback) {
                _ = self.listeners.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    pub fn prompt(self: *Agent, input: anytype) !void {
        return self.promptWithAcceptedCallback(input, null);
    }

    pub fn promptWithAcceptedCallback(
        self: *Agent,
        input: anytype,
        accepted_callback: ?types.PromptAcceptedCallback,
    ) !void {
        const Input = @TypeOf(input);
        if (comptime isStringLike(Input)) {
            return self.promptTextWithImages(input, &.{}, accepted_callback);
        }

        if (Input == types.AgentMessage) {
            return self.promptSingleMessage(input, accepted_callback);
        }

        if (comptime isAgentMessageSlice(Input)) {
            return self.runPromptMessages(input, accepted_callback);
        }

        if (comptime isTextWithImagesPrompt(Input)) {
            return self.promptTextWithImages(input.text, input.images, accepted_callback);
        }

        @compileError("Agent.prompt supports string input, AgentMessage, []const AgentMessage, or a struct with .text and .images fields.");
    }

    pub fn continueRun(self: *Agent) !void {
        const prompts = [_]types.AgentMessage{};
        try self.runPromptMessages(prompts[0..], null);
    }

    fn promptSingleMessage(
        self: *Agent,
        message: types.AgentMessage,
        accepted_callback: ?types.PromptAcceptedCallback,
    ) !void {
        const prompts = [_]types.AgentMessage{message};
        try self.runPromptMessages(prompts[0..], accepted_callback);
    }

    fn promptTextWithImages(
        self: *Agent,
        text: []const u8,
        images: []const pi_types.ImageContent,
        accepted_callback: ?types.PromptAcceptedCallback,
    ) !void {
        var prompt_message = try userMessageWithImages(self.allocator, text, images, 0);
        defer deinitBorrowedUserMessage(self.allocator, &prompt_message);
        const prompts = [_]types.AgentMessage{prompt_message};
        try self.runPromptMessages(prompts[0..], accepted_callback);
    }

    fn runPromptMessages(
        self: *Agent,
        prompts: []const types.AgentMessage,
        accepted_callback: ?types.PromptAcceptedCallback,
    ) !void {
        if (self.is_streaming) return error.AgentAlreadyProcessing;
        const context = self.createContextSnapshot();
        const config = self.createLoopConfig();
        var abort_signal = std.atomic.Value(bool).init(false);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        self.beginRun();
        self.run_state_mutex.lockUncancelable(self.io);
        self.active_abort_signal = &abort_signal;
        self.run_state_mutex.unlock(self.io);
        defer self.finishRun();

        if (accepted_callback) |callback| {
            try callback.callback(callback.context);
        }

        const added_messages = try agent_loop.runAgentLoop(
            arena.allocator(),
            self.io,
            prompts[0..],
            context,
            config,
            self,
            emitAgentEvent,
            &abort_signal,
            self.stream_fn,
        );
        _ = added_messages;
    }

    fn createContextSnapshot(self: *const Agent) types.AgentContext {
        return .{
            .system_prompt = self.system_prompt,
            .messages = self.messages.items,
            .tools = self.tools.items,
        };
    }

    fn createLoopConfig(self: *const Agent) types.AgentLoopConfig {
        return .{
            .model = self.model,
            .api_key = self.api_key,
            .session_id = self.session_id,
            .reasoning = if (self.thinking_level == .off) null else self.thinking_level,
            .tool_execution = self.tool_execution,
            .before_tool_call = self.before_tool_call,
            .after_tool_call = self.after_tool_call,
            .should_stop_after_turn = self.should_stop_after_turn,
            .should_stop_after_turn_context = self.should_stop_after_turn_context,
            .convert_to_llm = self.convert_to_llm,
            .convert_to_llm_context = self.convert_to_llm_context,
            .transform_context = self.transform_context,
            .transform_context_context = self.transform_context_context,
            .extension_hook_context = self.extension_hook_context,
            .stream_context = self.stream_context,
            .get_steering_messages_context = @constCast(self),
            .get_steering_messages = drainSteeringMessages,
            .get_follow_up_messages_context = @constCast(self),
            .get_follow_up_messages = drainFollowUpMessages,
            .prepare_next_turn_context = self.prepare_next_turn_context,
            .prepare_next_turn = self.prepare_next_turn,
        };
    }

    fn clearOwnedMessages(self: *Agent) void {
        for (self.messages.items) |*message| deinitMessage(self.allocator, message);
        self.messages.clearRetainingCapacity();
    }

    fn processEvent(self: *Agent, event: types.AgentEvent) !void {
        var event_to_emit = event;
        var transformed_message: ?types.AgentMessage = null;
        defer if (transformed_message) |*message| deinitMessage(self.allocator, message);

        switch (event_to_emit.event_type) {
            .message_start => {
                self.streaming_message = event_to_emit.message;
            },
            .message_update => {
                self.streaming_message = event_to_emit.message;
            },
            .message_end => {
                if (event_to_emit.message) |message| {
                    if (self.message_end_transform) |transform| {
                        if (try transform(self.allocator, message, self.message_end_transform_context, self.active_abort_signal)) |replacement| {
                            transformed_message = replacement;
                            event_to_emit.message = replacement;
                        }
                    }
                }
                self.streaming_message = null;
                if (event_to_emit.message) |message| {
                    try self.appendMessage(message);
                }
            },
            .tool_execution_start => {
                if (event_to_emit.tool_call_id) |tool_call_id| {
                    try self.addPendingToolCall(tool_call_id);
                }
            },
            .tool_execution_end => {
                if (event_to_emit.tool_call_id) |tool_call_id| {
                    _ = self.removePendingToolCall(tool_call_id);
                }
            },
            .turn_end => {
                if (event_to_emit.message) |message| {
                    switch (message) {
                        .assistant => |assistant| {
                            if (assistant.error_message) |error_message| {
                                self.setErrorMessage(error_message);
                            }
                        },
                        else => {},
                    }
                }
            },
            .agent_end => {
                self.streaming_message = null;
            },
            else => {},
        }

        for (self.listeners.items) |subscriber| {
            try subscriber.callback(subscriber.context, event_to_emit);
        }
    }
};

fn emitAgentEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const self: *Agent = @ptrCast(@alignCast(context.?));
    try self.processEvent(event);
}

pub fn cloneMessage(allocator: std.mem.Allocator, message: types.AgentMessage) !types.AgentMessage {
    return switch (message) {
        .user => |user| blk: {
            const role = try allocator.dupe(u8, user.role);
            errdefer allocator.free(role);
            const content = try content_clone.cloneContentBlocks(allocator, user.content);
            errdefer {
                content_clone.deinitContentBlocks(allocator, content);
                allocator.free(content);
            }

            break :blk .{ .user = .{
                .role = role,
                .content = content,
                .timestamp = user.timestamp,
            } };
        },
        .assistant => |assistant| blk: {
            const role = try allocator.dupe(u8, assistant.role);
            errdefer allocator.free(role);
            const content = try content_clone.cloneContentBlocks(allocator, assistant.content);
            errdefer {
                content_clone.deinitContentBlocks(allocator, content);
                allocator.free(content);
            }
            const tool_calls = if (assistant.tool_calls) |calls| try cloneToolCalls(allocator, calls) else null;
            errdefer if (tool_calls) |calls| deinitToolCalls(allocator, calls);
            const api = try allocator.dupe(u8, assistant.api);
            errdefer allocator.free(api);
            const provider = try allocator.dupe(u8, assistant.provider);
            errdefer allocator.free(provider);
            const model = try allocator.dupe(u8, assistant.model);
            errdefer allocator.free(model);
            const response_id = if (assistant.response_id) |value| try allocator.dupe(u8, value) else null;
            errdefer if (response_id) |value| allocator.free(value);
            const error_message = if (assistant.error_message) |value| try allocator.dupe(u8, value) else null;
            errdefer if (error_message) |value| allocator.free(value);

            break :blk .{ .assistant = .{
                .role = role,
                .content = content,
                .tool_calls = tool_calls,
                .api = api,
                .provider = provider,
                .model = model,
                .response_id = response_id,
                .usage = assistant.usage,
                .stop_reason = assistant.stop_reason,
                .error_message = error_message,
                .timestamp = assistant.timestamp,
            } };
        },
        .tool_result => |tool_result| blk: {
            const role = try allocator.dupe(u8, tool_result.role);
            errdefer allocator.free(role);
            const tool_call_id = try allocator.dupe(u8, tool_result.tool_call_id);
            errdefer allocator.free(tool_call_id);
            const tool_name = try allocator.dupe(u8, tool_result.tool_name);
            errdefer allocator.free(tool_name);
            const content = try content_clone.cloneContentBlocks(allocator, tool_result.content);
            errdefer {
                content_clone.deinitContentBlocks(allocator, content);
                allocator.free(content);
            }
            const details = if (tool_result.details) |value| try provider_json.cloneValue(allocator, value) else null;
            errdefer if (details) |value| provider_json.freeValue(allocator, value);

            break :blk .{ .tool_result = .{
                .role = role,
                .tool_call_id = tool_call_id,
                .tool_name = tool_name,
                .content = content,
                .details = details,
                .is_error = tool_result.is_error,
                .timestamp = tool_result.timestamp,
            } };
        },
    };
}

pub fn deinitMessage(allocator: std.mem.Allocator, message: *types.AgentMessage) void {
    switch (message.*) {
        .user => |*user| {
            allocator.free(user.role);
            content_clone.deinitContentBlocks(allocator, user.content);
            allocator.free(user.content);
        },
        .assistant => |*assistant| {
            allocator.free(assistant.role);
            content_clone.deinitContentBlocks(allocator, assistant.content);
            allocator.free(assistant.content);
            if (assistant.tool_calls) |tool_calls| deinitToolCalls(allocator, tool_calls);
            allocator.free(assistant.api);
            allocator.free(assistant.provider);
            allocator.free(assistant.model);
            if (assistant.response_id) |response_id| allocator.free(response_id);
            if (assistant.error_message) |error_message| allocator.free(error_message);
        },
        .tool_result => |*tool_result| {
            allocator.free(tool_result.role);
            allocator.free(tool_result.tool_call_id);
            allocator.free(tool_result.tool_name);
            content_clone.deinitContentBlocks(allocator, tool_result.content);
            allocator.free(tool_result.content);
            if (tool_result.details) |details| provider_json.freeValue(allocator, details);
        },
    }
}

pub fn cloneMessageSlice(allocator: std.mem.Allocator, messages: []const types.AgentMessage) ![]types.AgentMessage {
    const cloned = try allocator.alloc(types.AgentMessage, messages.len);
    errdefer allocator.free(cloned);

    var index: usize = 0;
    errdefer {
        for (cloned[0..index]) |*message| deinitMessage(allocator, message);
    }

    for (messages, 0..) |message, message_index| {
        cloned[message_index] = try cloneMessage(allocator, message);
        index += 1;
    }

    return cloned;
}

pub fn deinitMessageSlice(allocator: std.mem.Allocator, messages: []types.AgentMessage) void {
    for (messages) |*message| deinitMessage(allocator, message);
}

fn cloneToolCalls(allocator: std.mem.Allocator, tool_calls: []const pi_types.ToolCall) ![]const pi_types.ToolCall {
    const cloned = try allocator.alloc(pi_types.ToolCall, tool_calls.len);
    errdefer allocator.free(cloned);

    var initialized_len: usize = 0;
    errdefer deinitToolCallsPartial(allocator, cloned, initialized_len);

    for (tool_calls, 0..) |tool_call, index| {
        cloned[index] = try content_clone.cloneToolCall(allocator, tool_call);
        initialized_len += 1;
    }

    return cloned;
}

fn deinitToolCalls(allocator: std.mem.Allocator, tool_calls: []const pi_types.ToolCall) void {
    for (tool_calls) |tool_call| {
        content_clone.deinitToolCall(allocator, tool_call);
    }
    allocator.free(tool_calls);
}

fn deinitToolCallsPartial(allocator: std.mem.Allocator, tool_calls: []const pi_types.ToolCall, initialized_len: usize) void {
    for (tool_calls[0..initialized_len]) |tool_call| {
        content_clone.deinitToolCall(allocator, tool_call);
    }
}

fn defaultConvertToLlm(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
    _: ?*anyopaque,
) ![]pi_types.Message {
    return try allocator.dupe(pi_types.Message, messages);
}

fn drainSteeringMessages(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    const self: *Agent = @ptrCast(@alignCast(context.?));
    return try self.steering_queue.drain(allocator);
}

fn drainFollowUpMessages(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    const self: *Agent = @ptrCast(@alignCast(context.?));
    return try self.follow_up_queue.drain(allocator);
}

fn userMessageWithImages(
    allocator: std.mem.Allocator,
    text: []const u8,
    images: []const pi_types.ImageContent,
    timestamp: i64,
) !types.AgentMessage {
    const content = try allocator.alloc(pi_types.ContentBlock, 1 + images.len);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    for (images, 0..) |image, index| {
        content[index + 1] = .{ .image = image };
    }
    return .{ .user = .{
        .content = content,
        .timestamp = timestamp,
    } };
}

fn deinitBorrowedUserMessage(allocator: std.mem.Allocator, message: *types.AgentMessage) void {
    switch (message.*) {
        .user => |user| {
            if (user.content.len > 0) {
                switch (user.content[0]) {
                    .text => |text| {
                        allocator.free(text.text);
                        if (text.text_signature) |signature| allocator.free(signature);
                    },
                    else => {},
                }
            }
            allocator.free(user.content);
        },
        else => {},
    }
    message.* = undefined;
}

fn userTextMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    timestamp: i64,
) !types.AgentMessage {
    return try userMessageWithImages(allocator, text, &.{}, timestamp);
}

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == u8,
        else => false,
    };
}

fn isAgentMessageSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == types.AgentMessage,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == types.AgentMessage,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == types.AgentMessage,
        else => false,
    };
}

fn isTextWithImagesPrompt(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, "text") and @hasField(T, "images"),
        else => false,
    };
}

fn makeTool(name: []const u8, label: []const u8) types.AgentTool {
    return .{
        .name = name,
        .description = "test tool",
        .label = label,
        .parameters = .null,
    };
}

test "agent initializes with default state" {
    var agent = try Agent.init(std.testing.allocator, .{});
    defer agent.deinit();

    const state = agent.state();
    try std.testing.expectEqualStrings("", state.system_prompt);
    try std.testing.expectEqualStrings("unknown", state.model.id);
    try std.testing.expectEqual(types.ThinkingLevel.off, state.thinking_level);
    try std.testing.expectEqual(@as(usize, 0), state.tools.len);
    try std.testing.expectEqual(@as(usize, 0), state.messages.len);
    try std.testing.expect(!state.is_streaming);
    try std.testing.expect(state.streaming_message == null);
    try std.testing.expectEqual(@as(usize, 0), state.pending_tool_calls.len);
    try std.testing.expect(state.error_message == null);
    try std.testing.expectEqual(types.ToolExecutionMode.parallel, agent.tool_execution);
    try std.testing.expectEqual(QueueMode.one_at_a_time, agent.steering_queue.mode);
    try std.testing.expectEqual(QueueMode.one_at_a_time, agent.follow_up_queue.mode);
}

test "agent state accessors expose configured values" {
    const configured_model = pi_types.Model{
        .id = "faux-1",
        .name = "Faux 1",
        .api = "faux",
        .provider = "faux",
        .base_url = "http://localhost:0",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var agent = try Agent.init(std.testing.allocator, .{
        .system_prompt = "system",
        .model = configured_model,
        .thinking_level = .medium,
        .tool_execution = .sequential,
    });
    defer agent.deinit();

    try std.testing.expectEqualStrings("system", agent.getSystemPrompt());
    try std.testing.expectEqualStrings("faux-1", agent.getModel().id);
    try std.testing.expectEqual(types.ThinkingLevel.medium, agent.getThinkingLevel());
    try std.testing.expectEqual(types.ToolExecutionMode.sequential, agent.tool_execution);

    agent.setSystemPrompt("changed");
    agent.setThinkingLevel(.high);
    try std.testing.expectEqualStrings("changed", agent.state().system_prompt);
    try std.testing.expectEqual(types.ThinkingLevel.high, agent.state().thinking_level);
}

test "agent copies tool and message arrays on assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var agent = try Agent.init(std.testing.allocator, .{});
    defer agent.deinit();

    var tools = [_]types.AgentTool{
        makeTool("tool-a", "Tool A"),
        makeTool("tool-b", "Tool B"),
    };
    try agent.setTools(tools[0..]);
    tools[0] = makeTool("tool-c", "Tool C");

    var messages = [_]types.AgentMessage{
        try userTextMessage(arena.allocator(), "first", 1),
        try userTextMessage(arena.allocator(), "second", 2),
    };
    try agent.setMessages(messages[0..]);
    messages[0] = try userTextMessage(arena.allocator(), "changed", 3);

    try std.testing.expectEqual(@as(usize, 2), agent.getTools().len);
    try std.testing.expectEqualStrings("tool-a", agent.getTools()[0].name);
    try std.testing.expectEqual(@as(usize, 2), agent.getMessages().len);
    try std.testing.expectEqualStrings("first", agent.getMessages()[0].user.content[0].text.text);
}

test "agent reset clears transcript runtime state and queues without removing tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var agent = try Agent.init(std.testing.allocator, .{});
    defer agent.deinit();

    const tool = makeTool("tool-a", "Tool A");
    try agent.setTools(&[_]types.AgentTool{tool});
    try agent.setMessages(&[_]types.AgentMessage{try userTextMessage(arena.allocator(), "hello", 1)});
    agent.setStreamingMessage(try userTextMessage(arena.allocator(), "streaming", 2));
    try agent.addPendingToolCall("tool-call-1");
    agent.setErrorMessage("boom");
    try agent.steer(try userTextMessage(arena.allocator(), "steer", 3));
    try agent.followUp(try userTextMessage(arena.allocator(), "follow", 4));

    try agent.reset();

    const state = agent.state();
    try std.testing.expectEqual(@as(usize, 1), state.tools.len);
    try std.testing.expectEqual(@as(usize, 0), state.messages.len);
    try std.testing.expect(!state.is_streaming);
    try std.testing.expect(state.streaming_message == null);
    try std.testing.expectEqual(@as(usize, 0), state.pending_tool_calls.len);
    try std.testing.expect(state.error_message == null);
    try std.testing.expectEqual(@as(usize, 0), agent.steeringQueueLen());
    try std.testing.expectEqual(@as(usize, 0), agent.followUpQueueLen());
    try std.testing.expect(!agent.hasQueuedMessages());
}

test "agent reset rejects while a run is active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var agent = try Agent.init(std.testing.allocator, .{});
    defer agent.deinit();

    try agent.setMessages(&[_]types.AgentMessage{try userTextMessage(arena.allocator(), "hello", 1)});
    agent.beginRun();
    try std.testing.expectError(error.AgentBusy, agent.reset());
    try std.testing.expectEqual(@as(usize, 1), agent.getMessages().len);
    try std.testing.expect(agent.state().is_streaming);

    agent.finishRun();
    try agent.reset();
    try std.testing.expectEqual(@as(usize, 0), agent.getMessages().len);
    try std.testing.expect(!agent.state().is_streaming);
}

test "agent streaming lifecycle toggles flags and clears runtime state on finish" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var agent = try Agent.init(std.testing.allocator, .{
        .messages = &[_]types.AgentMessage{try userTextMessage(arena.allocator(), "hello", 1)},
    });
    defer agent.deinit();

    try std.testing.expect(!agent.isStreaming());
    agent.setErrorMessage("old error");
    agent.beginRun();
    try std.testing.expect(agent.isStreaming());
    try std.testing.expect(agent.getErrorMessage() == null);

    const streaming_message = try userTextMessage(arena.allocator(), "partial", 2);
    agent.setStreamingMessage(streaming_message);
    try agent.addPendingToolCall("tool-1");
    try agent.addPendingToolCall("tool-1");
    try std.testing.expectEqual(@as(usize, 1), agent.getPendingToolCalls().len);
    try std.testing.expect(agent.getStreamingMessage() != null);

    agent.finishRun();
    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(agent.getStreamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 0), agent.getPendingToolCalls().len);
    try std.testing.expectEqual(@as(usize, 1), agent.getMessages().len);
}

test "pending message queue drains according to mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var queue_all = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .all);
    defer queue_all.deinit();
    try queue_all.enqueue(try userTextMessage(arena.allocator(), "one", 1));
    try queue_all.enqueue(try userTextMessage(arena.allocator(), "two", 2));

    const drained_all = try queue_all.drain(std.testing.allocator);
    defer {
        deinitMessageSlice(std.testing.allocator, drained_all);
        std.testing.allocator.free(drained_all);
    }
    try std.testing.expectEqual(@as(usize, 2), drained_all.len);
    try std.testing.expect(!queue_all.hasItems());

    var queue_one = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .one_at_a_time);
    defer queue_one.deinit();
    try queue_one.enqueue(try userTextMessage(arena.allocator(), "first", 1));
    try queue_one.enqueue(try userTextMessage(arena.allocator(), "second", 2));

    const first = try queue_one.drain(std.testing.allocator);
    defer {
        deinitMessageSlice(std.testing.allocator, first);
        std.testing.allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("first", first[0].user.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), queue_one.len());
}

fn complexAssistantMessage(
    allocator: std.mem.Allocator,
    label: []const u8,
    timestamp: i64,
) !types.AgentMessage {
    const text = try std.fmt.allocPrint(allocator, "{s} text", .{label});
    const thinking = try std.fmt.allocPrint(allocator, "{s} thinking", .{label});
    const signature = try std.fmt.allocPrint(allocator, "sig-{s}", .{label});
    const response_id = try std.fmt.allocPrint(allocator, "resp-{s}", .{label});
    const error_message = try std.fmt.allocPrint(allocator, "error-{s}", .{label});
    const tool_call_id = try std.fmt.allocPrint(allocator, "tool-{s}", .{label});

    const content = try allocator.alloc(pi_types.ContentBlock, 2);
    content[0] = .{ .text = .{ .text = text } };
    content[1] = .{ .thinking = .{
        .thinking = thinking,
        .signature = signature,
    } };

    var items = std.json.Array.init(allocator);
    try items.append(.{ .integer = 1 });
    try items.append(.{ .string = try allocator.dupe(u8, "nested") });

    var arguments = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try arguments.put(allocator, try allocator.dupe(u8, "label"), .{ .string = try allocator.dupe(u8, label) });
    try arguments.put(allocator, try allocator.dupe(u8, "items"), .{ .array = items });

    const tool_calls = try allocator.alloc(pi_types.ToolCall, 1);
    tool_calls[0] = .{
        .id = tool_call_id,
        .name = try allocator.dupe(u8, "echo"),
        .arguments = .{ .object = arguments },
    };

    return .{ .assistant = .{
        .content = content,
        .tool_calls = tool_calls,
        .api = try allocator.dupe(u8, "faux"),
        .provider = try allocator.dupe(u8, "faux"),
        .model = try allocator.dupe(u8, "faux-model"),
        .response_id = response_id,
        .usage = .{
            .input = 1,
            .output = 2,
            .total_tokens = 3,
        },
        .stop_reason = .tool_use,
        .error_message = error_message,
        .timestamp = timestamp,
    } };
}

test "pending message queue drains queue-owned copies after source allocations are released" {
    var queue = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .all);
    defer queue.deinit();

    {
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();

        try queue.enqueue(try complexAssistantMessage(source_arena.allocator(), "copied", 7));
    }

    const drained = try queue.drain(std.testing.allocator);
    defer {
        deinitMessageSlice(std.testing.allocator, drained);
        std.testing.allocator.free(drained);
    }

    try std.testing.expectEqual(@as(usize, 1), drained.len);
    const assistant = drained[0].assistant;
    try std.testing.expectEqualStrings("copied text", assistant.content[0].text.text);
    try std.testing.expectEqualStrings("copied thinking", assistant.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("sig-copied", assistant.content[1].thinking.signature.?);
    try std.testing.expectEqualStrings("tool-copied", assistant.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("copied", assistant.tool_calls.?[0].arguments.object.get("label").?.string);
    try std.testing.expectEqualStrings("nested", assistant.tool_calls.?[0].arguments.object.get("items").?.array.items[1].string);
    try std.testing.expect(!queue.hasItems());
}

test "pending message queue clear and deinit release nested queue-owned allocations" {
    {
        var clear_queue = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .all);
        defer clear_queue.deinit();

        {
            var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer source_arena.deinit();

            try clear_queue.enqueue(try complexAssistantMessage(source_arena.allocator(), "clear", 9));
        }

        clear_queue.clear();
        try std.testing.expectEqual(@as(usize, 0), clear_queue.len());
    }

    {
        var deinit_queue = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .all);
        defer deinit_queue.deinit();

        {
            var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer source_arena.deinit();

            try deinit_queue.enqueue(try complexAssistantMessage(source_arena.allocator(), "deinit", 10));
        }
    }
}

test "VAL-AGENT-FACADE-001 cloneMessage allocation failures release prompt-message ownership" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();

    const source_message = try complexAssistantMessage(source_arena.allocator(), "facade-oom", 11);

    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_state.allocator();

        if (cloneMessage(failing_allocator, source_message)) |cloned| {
            var owned = cloned;
            deinitMessage(failing_allocator, &owned);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
}

const PromptEventCapture = struct {
    agent: *Agent,
    allocator: std.mem.Allocator,
    event_types: std.ArrayList(types.AgentEventType),
    saw_assistant_message_start: bool = false,
    saw_assistant_message_update: bool = false,
    assistant_message_end_cleared_streaming: bool = false,

    fn init(agent: *Agent, allocator: std.mem.Allocator) PromptEventCapture {
        return .{
            .agent = agent,
            .allocator = allocator,
            .event_types = .empty,
        };
    }

    fn deinit(self: *PromptEventCapture) void {
        self.event_types.deinit(self.allocator);
    }
};

fn capturePromptEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *PromptEventCapture = @ptrCast(@alignCast(context.?));
    try capture.event_types.append(capture.allocator, event.event_type);

    switch (event.event_type) {
        .message_start => {
            if (event.message) |message| switch (message) {
                .assistant => {
                    capture.saw_assistant_message_start = true;
                    try std.testing.expect(capture.agent.getStreamingMessage() != null);
                    try std.testing.expect(capture.agent.isStreaming());
                },
                else => {},
            };
        },
        .message_update => {
            if (event.message) |message| switch (message) {
                .assistant => {
                    capture.saw_assistant_message_update = true;
                    try std.testing.expect(capture.agent.getStreamingMessage() != null);
                },
                else => {},
            };
        },
        .message_end => {
            if (event.message) |message| switch (message) {
                .assistant => {
                    capture.assistant_message_end_cleared_streaming = capture.agent.getStreamingMessage() == null;
                },
                else => {},
            };
        },
        else => {},
    }
}

test "agent prompt records transcript and clears streaming state for single-turn text responses" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 1, .max = 1 },
    });
    defer registration.unregister();

    const blocks = [_]faux.FauxContentBlock{faux.fauxText("hello there")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks[0..], .{}) },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .system_prompt = "You are helpful.",
        .model = registration.getModel(),
        .stream_fn = test_faux.stream,
    });
    defer agent.deinit();

    var capture = PromptEventCapture.init(&agent, std.testing.allocator);
    defer capture.deinit();
    try agent.subscribe(.{
        .context = &capture,
        .callback = capturePromptEvent,
    });

    try agent.prompt("hello");

    try std.testing.expect(capture.saw_assistant_message_start);
    try std.testing.expect(capture.saw_assistant_message_update);
    try std.testing.expect(capture.assistant_message_end_cleared_streaming);

    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(agent.getStreamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 2), agent.getMessages().len);
    try std.testing.expectEqualStrings("hello", agent.getMessages()[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("hello there", agent.getMessages()[1].assistant.content[0].text.text);

    const event_types = capture.event_types.items;
    try std.testing.expectEqual(types.AgentEventType.agent_start, event_types[0]);
    try std.testing.expectEqual(types.AgentEventType.turn_start, event_types[1]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[2]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[3]);
    try std.testing.expectEqual(types.AgentEventType.before_provider_request, event_types[4]);
    try std.testing.expectEqual(types.AgentEventType.after_provider_response, event_types[5]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[6]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[event_types.len - 3]);
    try std.testing.expectEqual(types.AgentEventType.turn_end, event_types[event_types.len - 2]);
    try std.testing.expectEqual(types.AgentEventType.agent_end, event_types[event_types.len - 1]);

    for (event_types[7 .. event_types.len - 3]) |event_type| {
        try std.testing.expectEqual(types.AgentEventType.message_update, event_type);
    }
}

fn expectUserText(message: types.AgentMessage, expected: []const u8) !void {
    switch (message) {
        .user => |user| {
            try std.testing.expectEqual(@as(usize, 1), user.content.len);
            try std.testing.expectEqualStrings(expected, user.content[0].text.text);
        },
        else => return error.UnexpectedMessageRole,
    }
}

fn multiTurnFactory(
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    _: ?pi_types.StreamOptions,
    call_count: *usize,
    _: pi_types.Model,
) !test_faux.FauxAssistantMessage {
    const faux = test_faux;

    switch (call_count.*) {
        1 => {
            try std.testing.expectEqual(@as(usize, 1), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText("First response");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        2 => {
            try std.testing.expectEqual(@as(usize, 3), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            try std.testing.expectEqualStrings("First response", context.messages[1].assistant.content[0].text.text);
            try expectUserText(context.messages[2], "what did I say?");
            const prior_text = context.messages[0].user.content[0].text.text;
            const answer = try std.fmt.allocPrint(allocator, "You said: {s}", .{prior_text});
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText(answer);
            return faux.fauxAssistantMessage(blocks, .{});
        },
        else => unreachable,
    }
}

test "agent prompt preserves prior transcript across multiple turns" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = multiTurnFactory },
        .{ .factory = multiTurnFactory },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .system_prompt = "You are helpful.",
        .model = registration.getModel(),
        .stream_fn = test_faux.stream,
    });
    defer agent.deinit();

    try agent.prompt("hello");
    try agent.prompt("what did I say?");

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try expectUserText(messages[0], "hello");
    try std.testing.expectEqualStrings("First response", messages[1].assistant.content[0].text.text);
    try expectUserText(messages[2], "what did I say?");
    try std.testing.expectEqualStrings("You said: hello", messages[3].assistant.content[0].text.text);
}

fn promptWithImagesFactory(
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    _: ?pi_types.StreamOptions,
    call_count: *usize,
    _: pi_types.Model,
) !test_faux.FauxAssistantMessage {
    const faux = test_faux;
    try std.testing.expectEqual(@as(usize, 1), call_count.*);
    try std.testing.expectEqual(@as(usize, 1), context.messages.len);

    const user = context.messages[0].user;
    try std.testing.expectEqual(@as(usize, 3), user.content.len);
    try std.testing.expectEqualStrings("describe this", user.content[0].text.text);
    try std.testing.expectEqualStrings("aGVsbG8=", user.content[1].image.data);
    try std.testing.expectEqualStrings("image/png", user.content[1].image.mime_type);
    try std.testing.expectEqualStrings("d29ybGQ=", user.content[2].image.data);
    try std.testing.expectEqualStrings("image/jpeg", user.content[2].image.mime_type);

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("saw images");
    return faux.fauxAssistantMessage(blocks, .{});
}

test "agent prompt supports text with images" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = promptWithImagesFactory },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
        .stream_fn = test_faux.stream,
    });
    defer agent.deinit();

    const images = [_]pi_types.ImageContent{
        .{ .data = "aGVsbG8=", .mime_type = "image/png" },
        .{ .data = "d29ybGQ=", .mime_type = "image/jpeg" },
    };

    try agent.prompt(.{
        .text = "describe this",
        .images = images[0..],
    });

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(@as(usize, 3), messages[0].user.content.len);
    try std.testing.expectEqualStrings("describe this", messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("aGVsbG8=", messages[0].user.content[1].image.data);
    try std.testing.expectEqualStrings("d29ybGQ=", messages[0].user.content[2].image.data);
    try std.testing.expectEqualStrings("saw images", messages[1].assistant.content[0].text.text);
}

fn promptMessageArrayFactory(
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    _: ?pi_types.StreamOptions,
    call_count: *usize,
    _: pi_types.Model,
) !test_faux.FauxAssistantMessage {
    const faux = test_faux;
    try std.testing.expectEqual(@as(usize, 1), call_count.*);
    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try expectUserText(context.messages[0], "first");
    try expectUserText(context.messages[1], "second");

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("combined");
    return faux.fauxAssistantMessage(blocks, .{});
}

test "agent prompt supports AgentMessage arrays and emits prompt events for each message" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = promptMessageArrayFactory },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
        .stream_fn = test_faux.stream,
    });
    defer agent.deinit();

    var capture = PromptEventCapture.init(&agent, std.testing.allocator);
    defer capture.deinit();
    try agent.subscribe(.{
        .context = &capture,
        .callback = capturePromptEvent,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompts = [_]types.AgentMessage{
        try userTextMessage(arena.allocator(), "first", 1),
        try userTextMessage(arena.allocator(), "second", 2),
    };

    try agent.prompt(prompts[0..]);

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try expectUserText(messages[0], "first");
    try expectUserText(messages[1], "second");
    try std.testing.expectEqualStrings("combined", messages[2].assistant.content[0].text.text);

    const event_types = capture.event_types.items;
    try std.testing.expectEqual(types.AgentEventType.agent_start, event_types[0]);
    try std.testing.expectEqual(types.AgentEventType.turn_start, event_types[1]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[2]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[3]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[4]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[5]);
    try std.testing.expectEqual(types.AgentEventType.before_provider_request, event_types[6]);
    try std.testing.expectEqual(types.AgentEventType.after_provider_response, event_types[7]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[8]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[event_types.len - 3]);
    try std.testing.expectEqual(types.AgentEventType.turn_end, event_types[event_types.len - 2]);
    try std.testing.expectEqual(types.AgentEventType.agent_end, event_types[event_types.len - 1]);
}

const SubscriberCapture = struct {
    allocator: std.mem.Allocator,
    event_types: std.ArrayList(types.AgentEventType),

    fn init(allocator: std.mem.Allocator) SubscriberCapture {
        return .{
            .allocator = allocator,
            .event_types = .empty,
        };
    }

    fn deinit(self: *SubscriberCapture) void {
        self.event_types.deinit(self.allocator);
    }
};

fn captureSubscriberEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *SubscriberCapture = @ptrCast(@alignCast(context.?));
    try capture.event_types.append(capture.allocator, event.event_type);
}

test "agent subscribers receive identical event sequences and can be removed dynamically" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    const first_blocks = [_]faux.FauxContentBlock{faux.fauxText("first reply")};
    const second_blocks = [_]faux.FauxContentBlock{faux.fauxText("second reply")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(first_blocks[0..], .{}) },
        .{ .message = faux.fauxAssistantMessage(second_blocks[0..], .{}) },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
        .stream_fn = test_faux.stream,
    });
    defer agent.deinit();

    var first_capture = SubscriberCapture.init(std.testing.allocator);
    defer first_capture.deinit();
    var second_capture = SubscriberCapture.init(std.testing.allocator);
    defer second_capture.deinit();

    const first_subscriber = types.AgentSubscriber{
        .context = &first_capture,
        .callback = captureSubscriberEvent,
    };
    const second_subscriber = types.AgentSubscriber{
        .context = &second_capture,
        .callback = captureSubscriberEvent,
    };

    try agent.subscribe(first_subscriber);
    try agent.subscribe(second_subscriber);

    try agent.prompt("hello");

    try std.testing.expect(first_capture.event_types.items.len > 0);
    try std.testing.expectEqual(first_capture.event_types.items.len, second_capture.event_types.items.len);
    for (first_capture.event_types.items, second_capture.event_types.items) |lhs, rhs| {
        try std.testing.expectEqual(lhs, rhs);
    }

    const second_count_after_first_prompt = second_capture.event_types.items.len;
    try std.testing.expect(agent.unsubscribe(second_subscriber));
    try std.testing.expect(!agent.unsubscribe(second_subscriber));

    try agent.prompt("again");

    try std.testing.expect(first_capture.event_types.items.len > second_count_after_first_prompt);
    try std.testing.expectEqual(second_count_after_first_prompt, second_capture.event_types.items.len);
}

const HookObservation = struct {
    transform_calls: usize = 0,
    convert_calls: usize = 0,
};

const HookObservationFixture = struct {
    observation: HookObservation = .{},
};

fn transformContextForTest(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
    _: ?*const std.atomic.Value(bool),
    transform_context: ?*anyopaque,
) ![]types.AgentMessage {
    const fixture: *HookObservationFixture = @ptrCast(@alignCast(transform_context orelse return error.MissingHookObservation));
    const observation = &fixture.observation;
    observation.transform_calls += 1;

    const transformed = try allocator.alloc(types.AgentMessage, messages.len + 1);
    @memcpy(transformed[0..messages.len], messages);
    transformed[messages.len] = try userTextMessage(allocator, "hooked context", 42);
    return transformed;
}

fn prefixedUserMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    timestamp: i64,
) !pi_types.Message {
    const prefixed_text = try std.fmt.allocPrint(allocator, "converted: {s}", .{text});
    return .{ .user = .{
        .content = try allocator.dupe(pi_types.ContentBlock, &[_]pi_types.ContentBlock{
            .{ .text = .{ .text = prefixed_text } },
        }),
        .timestamp = timestamp,
    } };
}

fn convertToLlmForTest(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
    convert_context: ?*anyopaque,
) ![]pi_types.Message {
    const fixture: *HookObservationFixture = @ptrCast(@alignCast(convert_context orelse return error.MissingHookObservation));
    const observation = &fixture.observation;
    observation.convert_calls += 1;

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try expectUserText(messages[0], "hello");
    try expectUserText(messages[1], "hooked context");

    const converted = try allocator.alloc(pi_types.Message, messages.len);
    for (messages, 0..) |message, index| {
        converted[index] = switch (message) {
            .user => |user| try prefixedUserMessage(allocator, user.content[0].text.text, user.timestamp),
            else => message,
        };
    }
    return converted;
}

fn transformedContextFactory(
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    _: ?pi_types.StreamOptions,
    call_count: *usize,
    _: pi_types.Model,
) !test_faux.FauxAssistantMessage {
    const faux = test_faux;
    try std.testing.expectEqual(@as(usize, 1), call_count.*);
    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try expectUserText(context.messages[0], "converted: hello");
    try expectUserText(context.messages[1], "converted: hooked context");

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("hooks applied");
    return faux.fauxAssistantMessage(blocks, .{});
}

test "agent applies transformContext before convertToLlm for streaming context only" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = transformedContextFactory },
    });

    const fixture = try std.testing.allocator.create(HookObservationFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
        .stream_fn = test_faux.stream,
        .transform_context = transformContextForTest,
        .transform_context_context = fixture,
        .convert_to_llm = convertToLlmForTest,
        .convert_to_llm_context = fixture,
    });
    defer agent.deinit();

    try agent.prompt("hello");

    try std.testing.expectEqual(@as(usize, 1), fixture.observation.transform_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.observation.convert_calls);
    try std.testing.expectEqual(@as(usize, 2), agent.getMessages().len);
    try expectUserText(agent.getMessages()[0], "hello");
    try std.testing.expectEqualStrings("hooks applied", agent.getMessages()[1].assistant.content[0].text.text);
}

const AbortEventCapture = struct {
    assistant_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tool_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_tool_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_agent_end: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn captureAbortEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *AbortEventCapture = @ptrCast(@alignCast(context.?));
    switch (event.event_type) {
        .message_update => {
            if (event.message) |message| switch (message) {
                .assistant => capture.assistant_started.store(true, .seq_cst),
                else => {},
            };
        },
        .tool_execution_start => {
            capture.tool_started.store(true, .seq_cst);
        },
        .tool_execution_end => {
            if (event.is_error) |is_error| {
                if (is_error) capture.saw_tool_error.store(true, .seq_cst);
            }
        },
        .agent_end => {
            capture.saw_agent_end.store(true, .seq_cst);
        },
        else => {},
    }
}

const PromptThreadRunner = struct {
    agent: *Agent,
    input: []const u8,
    err: ?anyerror = null,
};

fn runPromptThread(runner: *PromptThreadRunner) void {
    runner.agent.prompt(runner.input) catch |err| {
        runner.err = err;
    };
}

const RunPromptHandle = struct {
    runner: PromptThreadRunner,
    thread: std.Thread,
    joined: bool = false,

    fn start(agent: *Agent, input: []const u8) !RunPromptHandle {
        var handle = RunPromptHandle{
            .runner = .{
                .agent = agent,
                .input = input,
            },
            .thread = undefined,
        };
        handle.thread = try std.Thread.spawn(.{}, runPromptThread, .{&handle.runner});
        return handle;
    }

    fn join(self: *RunPromptHandle) !void {
        if (self.joined) return;
        self.thread.join();
        self.joined = true;
        if (self.runner.err) |err| return err;
    }
};

fn waitForAtomicTrue(flag: *const std.atomic.Value(bool)) !void {
    var iteration: usize = 0;
    while (iteration < 50_000 and !flag.load(.seq_cst)) : (iteration += 1) {
        std.Thread.yield() catch {};
    }
    if (!flag.load(.seq_cst)) return error.TestTimeout;
}

fn abortableToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    _ = allocator;

    const capture: *AbortEventCapture = @ptrCast(@alignCast(tool_context orelse return error.MissingAbortableToolObserver));
    capture.tool_started.store(true, .seq_cst);

    var iteration: usize = 0;
    while (iteration < 5_000) : (iteration += 1) {
        if (signal) |abort_signal| {
            if (abort_signal.load(.seq_cst)) {
                return error.ToolAborted;
            }
        }
        std.Thread.yield() catch {};
    }

    return error.ToolDidNotAbort;
}

fn buildAbortToolCallMessage(allocator: std.mem.Allocator) !test_faux.FauxAssistantMessage {
    const faux = test_faux;
    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = try faux.fauxToolCall(allocator, "wait", .null, .{ .id = "tool-1" });
    return faux.fauxAssistantMessage(blocks, .{
        .stop_reason = .tool_use,
    });
}

fn makeAssistantTextMessage(
    allocator: std.mem.Allocator,
    model: pi_types.Model,
    text: []const u8,
    stop_reason: pi_types.StopReason,
    error_message: ?[]const u8,
) !pi_types.AssistantMessage {
    const content = try allocator.alloc(pi_types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{
        .content = content,
        .tool_calls = null,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = stop_reason,
        .error_message = if (error_message) |message| try allocator.dupe(u8, message) else null,
        .timestamp = 0,
    };
}

fn blockingAbortStreamFn(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    _: pi_types.Context,
    options: ?pi_types.SimpleStreamOptions,
    stream_context: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    const capture: *AbortEventCapture = @ptrCast(@alignCast(stream_context orelse return error.MissingMidStreamObserver));
    capture.assistant_started.store(true, .seq_cst);

    const partial = try makeAssistantTextMessage(allocator, model, "", .stop, null);
    stream.push(.{
        .event_type = .start,
        .message = partial,
    });
    stream.push(.{
        .event_type = .text_start,
        .content_index = 0,
    });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "partial",
    });

    var iteration: usize = 0;
    while (iteration < 50_000) : (iteration += 1) {
        if (options) |stream_options| {
            if (stream_options.signal) |signal| {
                if (signal.load(.seq_cst)) {
                    const aborted = try makeAssistantTextMessage(
                        allocator,
                        model,
                        "partial",
                        .aborted,
                        "Request was aborted",
                    );
                    stream.push(.{
                        .event_type = .error_event,
                        .error_message = aborted.error_message,
                        .message = aborted,
                    });
                    stream.end(aborted);
                    return stream;
                }
            }
        }
        std.Thread.yield() catch {};
    }

    const fallback = try makeAssistantTextMessage(allocator, model, "partial", .stop, null);
    stream.push(.{
        .event_type = .done,
        .message = fallback,
    });
    stream.end(fallback);
    return stream;
}

const FacadeLifecycleStreamContext = struct {
    call_count: usize = 0,
};

fn allocFacadeTextAssistant(
    allocator: std.mem.Allocator,
    model: pi_types.Model,
    text: []const u8,
    stop_reason: pi_types.StopReason,
    error_message: ?[]const u8,
) !pi_types.AssistantMessage {
    const content = try allocator.alloc(pi_types.ContentBlock, 1);
    errdefer allocator.free(content);
    const text_copy = try allocator.dupe(u8, text);
    errdefer allocator.free(text_copy);
    const error_copy = if (error_message) |message| try allocator.dupe(u8, message) else null;
    errdefer if (error_copy) |message| allocator.free(message);

    content[0] = .{ .text = .{ .text = text_copy } };
    return .{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = stop_reason,
        .error_message = error_copy,
        .timestamp = 0,
    };
}

fn allocFacadeToolCallAssistant(
    allocator: std.mem.Allocator,
    model: pi_types.Model,
) !pi_types.AssistantMessage {
    const content = try allocator.alloc(pi_types.ContentBlock, 1);
    errdefer allocator.free(content);
    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer provider_json.freeValue(allocator, .{ .object = args });
    const arg_key = try allocator.dupe(u8, "value");
    var arg_key_moved = false;
    errdefer if (!arg_key_moved) allocator.free(arg_key);
    const arg_value = try allocator.dupe(u8, "fail");
    var arg_value_moved = false;
    errdefer if (!arg_value_moved) allocator.free(arg_value);
    try args.put(allocator, arg_key, .{ .string = arg_value });
    arg_key_moved = true;
    arg_value_moved = true;
    const id = try allocator.dupe(u8, "facade-tool-1");
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, "facade_fail");
    errdefer allocator.free(name);

    content[0] = .{ .tool_call = .{
        .id = id,
        .name = name,
        .arguments = .{ .object = args },
    } };
    return .{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 0,
    };
}

fn facadeLifecycleStreamFn(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    context: pi_types.Context,
    _: ?pi_types.SimpleStreamOptions,
    stream_context: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    const state: *FacadeLifecycleStreamContext = @ptrCast(@alignCast(stream_context orelse return error.MissingFacadeLifecycleContext));
    state.call_count += 1;

    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    const assistant = switch (state.call_count) {
        1 => blk: {
            try std.testing.expectEqual(@as(usize, 2), context.messages.len);
            try expectUserText(context.messages[0], "normal prompt");
            try expectUserText(context.messages[1], "steer once");
            break :blk try allocFacadeTextAssistant(allocator, model, "normal reply", .stop, null);
        },
        2 => blk: {
            try std.testing.expectEqual(@as(usize, 4), context.messages.len);
            try expectUserText(context.messages[3], "follow once");
            break :blk try allocFacadeTextAssistant(allocator, model, "follow reply", .stop, null);
        },
        3 => blk: {
            try expectUserText(context.messages[context.messages.len - 1], "provider error prompt");
            break :blk try allocFacadeTextAssistant(allocator, model, "provider failed", .error_reason, "provider failed");
        },
        4 => blk: {
            try expectUserText(context.messages[context.messages.len - 1], "tool error prompt");
            break :blk try allocFacadeToolCallAssistant(allocator, model);
        },
        5 => blk: {
            try std.testing.expectEqualStrings("facade_fail", context.messages[context.messages.len - 1].tool_result.tool_name);
            try std.testing.expect(context.messages[context.messages.len - 1].tool_result.is_error);
            break :blk try allocFacadeTextAssistant(allocator, model, "tool failure handled", .stop, null);
        },
        6 => blk: {
            try expectUserText(context.messages[context.messages.len - 1], "after failures");
            break :blk try allocFacadeTextAssistant(allocator, model, "still usable", .stop, null);
        },
        else => return error.UnexpectedFacadeLifecycleCall,
    };

    stream.push(.{
        .event_type = if (assistant.stop_reason == .error_reason) .error_event else .done,
        .message = assistant,
        .error_message = assistant.error_message,
    });
    stream.end(assistant);
    return stream;
}

fn facadeFailingToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    _ = allocator;
    return error.FacadeToolFailed;
}

fn expectFacadeIdle(agent: *const Agent) !void {
    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(agent.getStreamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 0), agent.getPendingToolCalls().len);
    try std.testing.expect(agent.active_abort_signal == null);
}

test "VAL-AGENT-FACADE-001 stateful Agent facade survives normal abort provider and tool errors" {
    const model = pi_types.Model{
        .id = "facade-lifecycle",
        .name = "Facade Lifecycle",
        .api = "facade-lifecycle",
        .provider = "facade-lifecycle",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 4096,
        .max_tokens = 256,
    };

    var stream_state = FacadeLifecycleStreamContext{};
    var prompt_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer prompt_arena.deinit();
    const tool = types.AgentTool{
        .name = "facade_fail",
        .description = "Fails for lifecycle coverage",
        .label = "Facade fail",
        .parameters = .null,
        .execute = facadeFailingToolExecute,
    };
    var agent = try Agent.init(std.testing.allocator, .{
        .model = model,
        .tools = &[_]types.AgentTool{tool},
        .stream_fn = facadeLifecycleStreamFn,
        .stream_context = &stream_state,
        .steering_mode = .one_at_a_time,
        .follow_up_mode = .one_at_a_time,
    });
    defer agent.deinit();

    var removed_capture = SubscriberCapture.init(std.testing.allocator);
    defer removed_capture.deinit();
    const removed_subscriber = types.AgentSubscriber{
        .context = &removed_capture,
        .callback = captureSubscriberEvent,
    };
    try agent.subscribe(removed_subscriber);
    try agent.steer(try userTextMessage(prompt_arena.allocator(), "steer once", 1));
    try agent.followUp(try userTextMessage(prompt_arena.allocator(), "follow once", 2));
    try agent.prompt("normal prompt");
    try expectFacadeIdle(&agent);
    try std.testing.expectEqual(@as(usize, 0), agent.steeringQueueLen());
    try std.testing.expectEqual(@as(usize, 0), agent.followUpQueueLen());
    try std.testing.expectEqual(@as(usize, 5), agent.getMessages().len);

    const removed_count_after_normal = removed_capture.event_types.items.len;
    try std.testing.expect(agent.unsubscribe(removed_subscriber));
    try std.testing.expect(!agent.unsubscribe(removed_subscriber));

    var active_capture = SubscriberCapture.init(std.testing.allocator);
    defer active_capture.deinit();
    try agent.subscribe(.{
        .context = &active_capture,
        .callback = captureSubscriberEvent,
    });

    try agent.prompt("provider error prompt");
    try expectFacadeIdle(&agent);
    try std.testing.expectEqualStrings("provider failed", agent.getErrorMessage().?);
    try std.testing.expectEqual(@as(usize, 7), agent.getMessages().len);
    try std.testing.expectEqual(removed_count_after_normal, removed_capture.event_types.items.len);

    const abort_capture = try std.testing.allocator.create(AbortEventCapture);
    defer std.testing.allocator.destroy(abort_capture);
    abort_capture.* = .{};
    agent.stream_fn = blockingAbortStreamFn;
    agent.stream_context = abort_capture;
    var handle = try RunPromptHandle.start(&agent, "abort prompt");
    defer handle.join() catch {};
    try waitForAtomicTrue(&abort_capture.assistant_started);
    agent.abort();
    try handle.join();
    try expectFacadeIdle(&agent);
    try std.testing.expectEqualStrings("Request was aborted", agent.getErrorMessage().?);
    try std.testing.expectEqual(@as(usize, 9), agent.getMessages().len);

    agent.stream_fn = facadeLifecycleStreamFn;
    agent.stream_context = &stream_state;
    try agent.prompt("tool error prompt");
    try expectFacadeIdle(&agent);
    try std.testing.expect(agent.getErrorMessage() == null);
    try std.testing.expectEqual(@as(usize, 13), agent.getMessages().len);
    try std.testing.expectEqualStrings("tool failure handled", agent.getMessages()[12].assistant.content[0].text.text);

    try agent.prompt("after failures");
    try expectFacadeIdle(&agent);
    try std.testing.expectEqual(@as(usize, 15), agent.getMessages().len);
    try expectUserText(agent.getMessages()[13], "after failures");
    try std.testing.expectEqualStrings("still usable", agent.getMessages()[14].assistant.content[0].text.text);
    try std.testing.expect(active_capture.event_types.items.len > 0);
    try std.testing.expectEqual(@as(usize, 6), stream_state.call_count);
}

test "agent abort stops an in-flight stream and clears runtime state" {
    const model = pi_types.Model{
        .id = "blocking-test",
        .name = "Blocking Test",
        .api = "blocking-test",
        .provider = "blocking-test",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const capture = try std.testing.allocator.create(AbortEventCapture);
    defer std.testing.allocator.destroy(capture);
    capture.* = .{};

    var agent = try Agent.init(std.testing.allocator, .{
        .model = model,
        .stream_fn = blockingAbortStreamFn,
        .stream_context = capture,
    });
    defer agent.deinit();

    try agent.subscribe(.{
        .context = capture,
        .callback = captureAbortEvent,
    });

    var handle = try RunPromptHandle.start(&agent, "hello");
    defer handle.join() catch {};

    try waitForAtomicTrue(&capture.assistant_started);
    agent.abort();
    try handle.join();

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(agent.getStreamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 0), agent.getPendingToolCalls().len);
    try std.testing.expect(capture.saw_agent_end.load(.seq_cst));

    switch (messages[1]) {
        .assistant => |assistant| {
            try std.testing.expectEqual(pi_types.StopReason.aborted, assistant.stop_reason);
            try std.testing.expectEqualStrings("Request was aborted", assistant.error_message.?);
        },
        else => return error.UnexpectedMessageRole,
    }
}

test "agent abort during tool execution cancels the tool and stops the run" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildAbortToolCallMessage(arena.allocator()) },
    });

    const capture = try std.testing.allocator.create(AbortEventCapture);
    defer std.testing.allocator.destroy(capture);
    capture.* = .{};

    const tool = types.AgentTool{
        .name = "wait",
        .description = "Wait for abort",
        .label = "Wait",
        .parameters = .null,
        .execute_context = capture,
        .execute = abortableToolExecute,
    };

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
        .stream_fn = test_faux.stream,
        .tools = &[_]types.AgentTool{tool},
    });
    defer agent.deinit();

    try agent.subscribe(.{
        .context = capture,
        .callback = captureAbortEvent,
    });

    var handle = try RunPromptHandle.start(&agent, "hello");
    defer handle.join() catch {};

    try waitForAtomicTrue(&capture.tool_started);
    agent.abort();
    try handle.join();

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(agent.getStreamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 0), agent.getPendingToolCalls().len);
    try std.testing.expect(capture.saw_tool_error.load(.seq_cst));
    try std.testing.expect(capture.saw_agent_end.load(.seq_cst));

    switch (messages[2]) {
        .tool_result => |tool_result| {
            try std.testing.expect(tool_result.is_error);
        },
        else => return error.UnexpectedMessageRole,
    }
}

test "agent prompt minimal" {
    _ = test_faux;
}
