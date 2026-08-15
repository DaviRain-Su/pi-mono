const std = @import("std");
const pi_types = @import("pi-types");
const provider_json = pi_types.json;
const types = @import("types.zig");
const content_clone = @import("content_clone.zig");
const json_schema = @import("json_schema.zig");

pub const PreparedToolCall = struct {
    tool_call: pi_types.ToolCall,
    tool: types.AgentTool,
    args: std.json.Value,
    finalized: bool = false,

    pub fn deinit(self: *PreparedToolCall, allocator: std.mem.Allocator) void {
        provider_json.freeValue(allocator, self.args);
    }
};

pub const ImmediateToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

pub const ExecutedToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

pub const FinalizedToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

pub const ExecutedToolCallBatch = struct {
    messages: []const types.ToolResultMessage,
    terminate: bool = false,
};

/// Partial tool-call UX policy:
/// - Every toolcall_start/toolcall_delta/toolcall_end still emits a
///   message_update so RPC/streaming clients can observe argument
///   accumulation and finalization order.
/// - Partial arguments are exposed in the callback-scoped partial assistant
///   message only when another assistant block anchors the transcript row.
///   A standalone leading tool call is hidden from message.content until the
const UpdateEmitterContext = struct {
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    tool_call: pi_types.ToolCall,
};

const ParallelToolEmitter = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,

    fn emitUpdate(self: *ParallelToolEmitter, event: types.AgentEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.emit(self.emit_context, event);
    }
};

const ParallelToolTask = struct {
    arena: std.heap.ArenaAllocator,
    prepared: PreparedToolCall,
    source_index: usize,
    completion_counter: *std.atomic.Value(usize),
    completion_order: usize = std.math.maxInt(usize),
    signal: ?*const std.atomic.Value(bool),
    emitter: *ParallelToolEmitter,
    result: ?types.AgentToolResult = null,
    is_error: bool = false,

    fn init(
        parent_allocator: std.mem.Allocator,
        prepared: PreparedToolCall,
        source_index: usize,
        completion_counter: *std.atomic.Value(usize),
        signal: ?*const std.atomic.Value(bool),
        emitter: *ParallelToolEmitter,
    ) ParallelToolTask {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .prepared = prepared,
            .source_index = source_index,
            .completion_counter = completion_counter,
            .signal = signal,
            .emitter = emitter,
        };
    }

    fn deinit(self: *ParallelToolTask) void {
        self.arena.deinit();
    }
};

const PreparedToolCallEntry = struct {
    prepared: PreparedToolCall,
    source_index: usize,
};

const ImmediateToolCallEntry = struct {
    tool_call: pi_types.ToolCall,
    outcome: ImmediateToolCallOutcome,
    source_index: usize,
};

pub const PreparedToolCallOrImmediate = union(enum) {
    prepared: PreparedToolCall,
    immediate: ImmediateToolCallOutcome,
};

pub fn executeToolCalls(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_context: types.AgentContext,
    assistant_message: pi_types.AssistantMessage,
    tool_calls: []const pi_types.ToolCall,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) !ExecutedToolCallBatch {
    var has_sequential_tool = false;
    for (tool_calls) |tool_call| {
        if (findTool(current_context.tools, tool_call.name)) |tool| {
            if (tool.execution_mode == .sequential) {
                has_sequential_tool = true;
                break;
            }
        }
    }

    if (config.tool_execution == .sequential or has_sequential_tool) {
        return executeToolCallsSequential(
            allocator,
            io,
            current_context,
            assistant_message,
            tool_calls,
            config,
            emit_context,
            emit,
            signal,
        );
    }

    return executeToolCallsParallel(
        allocator,
        io,
        current_context,
        assistant_message,
        tool_calls,
        config,
        emit_context,
        emit,
        signal,
    );
}

pub fn executeToolCallsSequential(
    allocator: std.mem.Allocator,
    _: std.Io,
    current_context: types.AgentContext,
    assistant_message: pi_types.AssistantMessage,
    tool_calls: []const pi_types.ToolCall,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) !ExecutedToolCallBatch {
    var results = std.ArrayList(types.ToolResultMessage).empty;
    errdefer results.deinit(allocator);
    var terminate_flags = try std.ArrayList(bool).initCapacity(allocator, tool_calls.len);
    defer terminate_flags.deinit(allocator);

    for (tool_calls) |tool_call| {
        try emit(emit_context, .{
            .event_type = .tool_execution_start,
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args = tool_call.arguments,
        });

        const prepared = try prepareToolCall(
            allocator,
            current_context,
            assistant_message,
            tool_call,
            config,
            signal,
        );

        var terminate = false;
        const tool_result = switch (prepared) {
            .prepared => |prepared_tool| blk: {
                var owned_prepared_tool = prepared_tool;
                defer owned_prepared_tool.deinit(allocator);
                const executed = try executePreparedToolCallSequential(
                    allocator,
                    owned_prepared_tool,
                    emit_context,
                    emit,
                    signal,
                );
                const finalized = try finalizeExecutedToolCall(
                    allocator,
                    current_context,
                    assistant_message,
                    &owned_prepared_tool,
                    executed,
                    false,
                    config,
                    emit_context,
                    emit,
                    signal,
                );
                terminate = finalized.result.terminate;
                break :blk try emitToolResultMessageForToolCall(
                    owned_prepared_tool.tool_call,
                    finalized.result,
                    finalized.is_error,
                    emit_context,
                    emit,
                );
            },
            .immediate => |immediate| blk: {
                terminate = immediate.result.terminate;
                break :blk try emitToolCallOutcome(
                    allocator,
                    tool_call,
                    immediate.result,
                    immediate.is_error,
                    emit_context,
                    emit,
                );
            },
        };

        try results.append(allocator, tool_result);
        try terminate_flags.append(allocator, terminate);
    }

    return .{
        .messages = try results.toOwnedSlice(allocator),
        .terminate = shouldTerminateToolBatch(terminate_flags.items),
    };
}

pub fn executeToolCallsParallel(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_context: types.AgentContext,
    assistant_message: pi_types.AssistantMessage,
    tool_calls: []const pi_types.ToolCall,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) !ExecutedToolCallBatch {
    const result_slots = try allocator.alloc(?types.ToolResultMessage, tool_calls.len);
    @memset(result_slots, null);
    defer allocator.free(result_slots);
    const terminate_flags = try allocator.alloc(bool, tool_calls.len);
    @memset(terminate_flags, false);
    defer allocator.free(terminate_flags);

    var prepared_calls = std.ArrayList(PreparedToolCallEntry).empty;
    defer {
        for (prepared_calls.items) |*entry| {
            entry.prepared.deinit(allocator);
        }
        prepared_calls.deinit(allocator);
    }
    var immediate_calls = std.ArrayList(ImmediateToolCallEntry).empty;
    defer immediate_calls.deinit(allocator);

    for (tool_calls, 0..) |tool_call, source_index| {
        try emit(emit_context, .{
            .event_type = .tool_execution_start,
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args = tool_call.arguments,
        });

        const prepared = try prepareToolCall(
            allocator,
            current_context,
            assistant_message,
            tool_call,
            config,
            signal,
        );

        switch (prepared) {
            .prepared => |prepared_tool| try prepared_calls.append(allocator, .{
                .prepared = prepared_tool,
                .source_index = source_index,
            }),
            .immediate => |immediate| {
                terminate_flags[source_index] = immediate.result.terminate;
                try immediate_calls.append(allocator, .{
                    .tool_call = tool_call,
                    .outcome = immediate,
                    .source_index = source_index,
                });
            },
        }
    }

    try finalizeImmediateToolCallsInSourceOrder(
        immediate_calls.items,
        result_slots,
        emit_context,
        emit,
    );

    if (prepared_calls.items.len == 0) {
        try emitParallelToolResultMessagesInSourceOrder(result_slots, emit_context, emit);
        return .{
            .messages = try collectParallelToolResultsInSourceOrder(allocator, result_slots),
            .terminate = shouldTerminateToolBatch(terminate_flags),
        };
    }

    const task_count = prepared_calls.items.len;
    const tasks = try allocator.alloc(ParallelToolTask, task_count);
    defer allocator.free(tasks);
    const threads = try allocator.alloc(std.Thread, task_count);
    defer allocator.free(threads);

    var parallel_emitter = ParallelToolEmitter{
        .io = io,
        .emit_context = emit_context,
        .emit = emit,
    };
    var completion_counter = std.atomic.Value(usize).init(0);

    for (prepared_calls.items, 0..) |entry, index| {
        tasks[index] = ParallelToolTask.init(
            allocator,
            entry.prepared,
            entry.source_index,
            &completion_counter,
            signal,
            &parallel_emitter,
        );
        threads[index] = try std.Thread.spawn(.{}, runParallelToolTask, .{&tasks[index]});
    }

    for (threads) |thread| {
        thread.join();
    }
    defer {
        for (tasks) |*task| task.deinit();
    }

    const completion_order = try allocator.alloc(usize, task_count);
    defer allocator.free(completion_order);
    fillTaskCompletionOrder(completion_order, tasks);

    for (completion_order) |task_index| {
        const task = &tasks[task_index];
        const executed = ExecutedToolCallOutcome{
            .result = if (task.result) |result|
                try content_clone.cloneToolResult(result, allocator)
            else
                try createErrorToolResult(allocator, "Parallel tool execution failed"),
            .is_error = task.is_error,
        };
        const finalized = try finalizeExecutedToolCall(
            allocator,
            current_context,
            assistant_message,
            &task.prepared,
            executed,
            true,
            config,
            emit_context,
            emit,
            signal,
        );
        result_slots[task.source_index] = createToolResultMessage(
            task.prepared.tool_call,
            finalized.result,
            finalized.is_error,
        );
        terminate_flags[task.source_index] = finalized.result.terminate;
    }

    try emitParallelToolResultMessagesInSourceOrder(result_slots, emit_context, emit);
    return .{
        .messages = try collectParallelToolResultsInSourceOrder(allocator, result_slots),
        .terminate = shouldTerminateToolBatch(terminate_flags),
    };
}

pub fn prepareToolCall(
    allocator: std.mem.Allocator,
    current_context: types.AgentContext,
    assistant_message: pi_types.AssistantMessage,
    tool_call: pi_types.ToolCall,
    config: types.AgentLoopConfig,
    signal: ?*const std.atomic.Value(bool),
) !PreparedToolCallOrImmediate {
    const tool = findTool(current_context.tools, tool_call.name) orelse {
        return .{ .immediate = .{
            .result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "Tool {s} not found", .{tool_call.name})),
            .is_error = true,
        } };
    };

    var args = prepareToolCallArguments(allocator, tool, tool_call.arguments) catch |err| {
        return .{ .immediate = .{
            .result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)})),
            .is_error = true,
        } };
    };
    if (try json_schema.validateToolArguments(allocator, tool.parameters, args)) |failure| {
        defer failure.deinit(allocator);
        const result = if (tool.invalid_arguments_result) |invalid_arguments_result|
            try invalid_arguments_result(
                allocator,
                tool_call.id,
                args,
                tool.execute_context,
                .{
                    .code = failure.code,
                    .message = failure.message,
                    .path = failure.path,
                },
            )
        else
            try createErrorToolResult(allocator, "InvalidToolArguments");
        provider_json.freeValue(allocator, args);
        return .{ .immediate = .{
            .result = result,
            .is_error = true,
        } };
    }

    if (config.before_tool_call) |before_tool_call| {
        const before_result = before_tool_call(allocator, .{
            .assistant_message = assistant_message,
            .tool_call = tool_call,
            .args = &args,
            .context = current_context,
        }, signal) catch |err| {
            provider_json.freeValue(allocator, args);
            return .{ .immediate = .{
                .result = try createErrorToolResult(allocator, @errorName(err)),
                .is_error = true,
            } };
        };

        if (before_result) |result| {
            if (result.block) {
                provider_json.freeValue(allocator, args);
                var blocked = try createErrorToolResult(
                    allocator,
                    result.reason orelse "Tool execution was blocked",
                );
                blocked.terminate = result.terminate;
                return .{ .immediate = .{
                    .result = blocked,
                    .is_error = true,
                } };
            }
        }
    }

    return .{ .prepared = .{
        .tool_call = tool_call,
        .tool = tool,
        .args = args,
    } };
}

fn prepareToolCallArguments(
    allocator: std.mem.Allocator,
    tool: types.AgentTool,
    args: std.json.Value,
) !std.json.Value {
    if (tool.prepare_arguments) |prepare_arguments| {
        return try prepare_arguments(allocator, args);
    }
    return try provider_json.cloneValue(allocator, args);
}

pub fn findTool(tools: []const types.AgentTool, name: []const u8) ?types.AgentTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn executePreparedToolCallSequential(
    allocator: std.mem.Allocator,
    prepared: PreparedToolCall,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) !ExecutedToolCallOutcome {
    var update_context = UpdateEmitterContext{
        .emit_context = emit_context,
        .emit = emit,
        .tool_call = prepared.tool_call,
    };
    return try executePreparedToolCallInternal(
        allocator,
        prepared,
        signal,
        &update_context,
        emitToolExecutionUpdate,
    );
}

fn executePreparedToolCallInternal(
    allocator: std.mem.Allocator,
    prepared: PreparedToolCall,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !ExecutedToolCallOutcome {
    const execute_tool = prepared.tool.execute orelse {
        return .{
            .result = try createErrorToolResult(allocator, "Tool has no execute function"),
            .is_error = true,
        };
    };

    const result = execute_tool(
        allocator,
        prepared.tool_call.id,
        prepared.args,
        prepared.tool.execute_context,
        signal,
        on_update_context,
        on_update,
    ) catch |err| {
        return .{
            .result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)})),
            .is_error = true,
        };
    };

    return .{
        .result = result,
        .is_error = result.is_error,
    };
}

fn emitToolExecutionUpdate(context: ?*anyopaque, partial_result: types.AgentToolResult) !void {
    const update_context: *UpdateEmitterContext = @ptrCast(@alignCast(context.?));
    try update_context.emit(update_context.emit_context, .{
        .event_type = .tool_execution_update,
        .tool_call_id = update_context.tool_call.id,
        .tool_name = update_context.tool_call.name,
        .args = update_context.tool_call.arguments,
        .partial_result = partial_result,
    });
}

fn runParallelToolTask(task: *ParallelToolTask) void {
    const outcome = executePreparedToolCallInternal(
        task.arena.allocator(),
        task.prepared,
        task.signal,
        task,
        emitParallelToolUpdate,
    ) catch {
        task.result = createErrorToolResult(task.arena.allocator(), "Parallel tool execution failed") catch
            // Arena allocation failed in worker thread — produce a minimal
            // static error result so the parallel task still reports failure
            // to the agent loop without crashing.
            @as(?types.AgentToolResult, .{
                .content = &.{.{ .text = .{ .text = "Parallel tool execution failed" } }},
                .is_error = true,
            });
        task.is_error = true;
        task.completion_order = task.completion_counter.fetchAdd(1, .seq_cst);
        return;
    };

    task.result = outcome.result;
    task.is_error = outcome.is_error;
    task.completion_order = task.completion_counter.fetchAdd(1, .seq_cst);
}

fn emitParallelToolUpdate(context: ?*anyopaque, partial_result: types.AgentToolResult) !void {
    const task: *ParallelToolTask = @ptrCast(@alignCast(context.?));
    try task.emitter.emitUpdate(.{
        .event_type = .tool_execution_update,
        .tool_call_id = task.prepared.tool_call.id,
        .tool_name = task.prepared.tool_call.name,
        .args = task.prepared.tool_call.arguments,
        .partial_result = partial_result,
    });
}

pub fn finalizeExecutedToolCall(
    allocator: std.mem.Allocator,
    current_context: types.AgentContext,
    assistant_message: pi_types.AssistantMessage,
    prepared: *PreparedToolCall,
    executed: ExecutedToolCallOutcome,
    owns_result_content: bool,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) !FinalizedToolCallOutcome {
    if (prepared.finalized) return types.AgentLoopError.ToolCallAlreadyFinalized;
    prepared.finalized = true;

    var result = executed.result;
    var is_error = executed.is_error;
    var result_content_owned = owns_result_content;

    if (config.after_tool_call) |after_tool_call| {
        const after_result = after_tool_call(allocator, .{
            .assistant_message = assistant_message,
            .tool_call = prepared.tool_call,
            .args = prepared.args,
            .result = result,
            .is_error = is_error,
            .context = current_context,
        }, signal) catch |err| {
            if (result_content_owned) content_clone.deinitContentBlocks(allocator, result.content);
            result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}));
            is_error = true;
            try emitToolExecutionEnd(
                prepared.tool_call,
                result,
                is_error,
                emit_context,
                emit,
            );
            return .{ .result = result, .is_error = is_error };
        };

        if (after_result) |override| {
            if (override.content) |content| {
                const replaced_content = !content_clone.sameContentBlocks(result.content, content);
                if (result_content_owned and replaced_content) {
                    content_clone.deinitContentBlocks(allocator, result.content);
                }
                result.content = content;
                if (replaced_content) result_content_owned = false;
            }
            if (override.details) |details| result.details = details;
            if (override.is_error) |next_is_error| is_error = next_is_error;
            if (override.terminate) |terminate| result.terminate = terminate;
        }
    }

    result.is_error = is_error;
    try emitToolExecutionEnd(
        prepared.tool_call,
        result,
        is_error,
        emit_context,
        emit,
    );
    return .{ .result = result, .is_error = is_error };
}

fn shouldTerminateToolBatch(flags: []const bool) bool {
    if (flags.len == 0) return false;
    for (flags) |flag| {
        if (!flag) return false;
    }
    return true;
}

fn createErrorToolResult(allocator: std.mem.Allocator, message: []const u8) !types.AgentToolResult {
    const content = try allocator.alloc(pi_types.ContentBlock, 1);
    content[0] = .{
        .text = .{
            .text = try allocator.dupe(u8, message),
        },
    };
    return .{
        .content = content,
        .details = null,
        .is_error = true,
    };
}

fn emitToolCallOutcome(
    allocator: std.mem.Allocator,
    tool_call: pi_types.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !types.ToolResultMessage {
    _ = allocator;
    const tool_result = try finalizeImmediateToolCall(
        tool_call,
        result,
        is_error,
        emit_context,
        emit,
    );
    try emitToolResultMessage(tool_result, emit_context, emit);
    return tool_result;
}

fn finalizeImmediateToolCall(
    tool_call: pi_types.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !types.ToolResultMessage {
    try emitToolExecutionEnd(tool_call, result, is_error, emit_context, emit);
    return createToolResultMessage(tool_call, result, is_error);
}

fn finalizeImmediateToolCallsInSourceOrder(
    immediate_calls: []const ImmediateToolCallEntry,
    result_slots: []?types.ToolResultMessage,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !void {
    for (immediate_calls) |entry| {
        result_slots[entry.source_index] = try finalizeImmediateToolCall(
            entry.tool_call,
            entry.outcome.result,
            entry.outcome.is_error,
            emit_context,
            emit,
        );
    }
}

fn emitToolExecutionEnd(
    tool_call: pi_types.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !void {
    var emitted_result = result;
    emitted_result.is_error = is_error;
    try emit(emit_context, .{
        .event_type = .tool_execution_end,
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .args = tool_call.arguments,
        .result = emitted_result,
        .is_error = is_error,
    });
}

fn createToolResultMessage(
    tool_call: pi_types.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
) types.ToolResultMessage {
    var emitted_result = result;
    emitted_result.is_error = is_error;
    return .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .content = emitted_result.content,
        .details = emitted_result.details,
        .is_error = is_error,
        .timestamp = types.nowMilliseconds(),
    };
}

fn emitToolResultMessage(
    tool_result: types.ToolResultMessage,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !void {
    try emit(emit_context, .{
        .event_type = .message_start,
        .message = .{ .tool_result = tool_result },
    });
    try emit(emit_context, .{
        .event_type = .message_end,
        .message = .{ .tool_result = tool_result },
    });
}

fn emitToolResultMessageForToolCall(
    tool_call: pi_types.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !types.ToolResultMessage {
    const tool_result = createToolResultMessage(tool_call, result, is_error);
    try emitToolResultMessage(tool_result, emit_context, emit);
    return tool_result;
}

fn collectParallelToolResultsInSourceOrder(
    allocator: std.mem.Allocator,
    result_slots: []const ?types.ToolResultMessage,
) ![]const types.ToolResultMessage {
    var results = try std.ArrayList(types.ToolResultMessage).initCapacity(allocator, result_slots.len);
    errdefer results.deinit(allocator);

    for (result_slots) |slot| {
        const tool_result = slot orelse return error.MissingToolResult;
        try results.append(allocator, tool_result);
    }

    return try results.toOwnedSlice(allocator);
}

fn emitParallelToolResultMessagesInSourceOrder(
    result_slots: []const ?types.ToolResultMessage,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !void {
    for (result_slots) |slot| {
        const tool_result = slot orelse return error.MissingToolResult;
        try emitToolResultMessage(tool_result, emit_context, emit);
    }
}

fn fillTaskCompletionOrder(order: []usize, tasks: []const ParallelToolTask) void {
    for (order, 0..) |*slot, index| slot.* = index;

    var index: usize = 1;
    while (index < order.len) : (index += 1) {
        const task_index = order[index];
        const task_completion = tasks[task_index].completion_order;
        var cursor = index;
        while (cursor > 0 and tasks[order[cursor - 1]].completion_order > task_completion) : (cursor -= 1) {
            order[cursor] = order[cursor - 1];
        }
        order[cursor] = task_index;
    }
}

fn testModel() pi_types.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = "test",
        .provider = "test",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
}

fn testAssistantMessage() pi_types.AssistantMessage {
    return .{
        .content = &.{},
        .api = "test",
        .provider = "test",
        .model = "test-model",
        .usage = pi_types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };
}

fn testConvertToLlm(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
    _: ?*anyopaque,
) ![]pi_types.Message {
    return try allocator.dupe(pi_types.Message, messages);
}

fn testConfig() types.AgentLoopConfig {
    return .{
        .model = testModel(),
        .convert_to_llm = testConvertToLlm,
    };
}

fn testJsonObjectWithString(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(
        allocator,
        try allocator.dupe(u8, key),
        .{ .string = try allocator.dupe(u8, value) },
    );
    return .{ .object = object };
}

fn testParseJson(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, source, .{});
}

fn testStringArg(args: std.json.Value, key: []const u8) ![]const u8 {
    if (args != .object) return error.InvalidToolArguments;
    const value = args.object.get(key) orelse return error.InvalidToolArguments;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

fn testTextToolResult(
    allocator: std.mem.Allocator,
    text: []const u8,
    is_error: bool,
) !types.AgentToolResult {
    const content = try allocator.alloc(pi_types.ContentBlock, 1);
    content[0] = .{
        .text = .{
            .text = try allocator.dupe(u8, text),
        },
    };
    return .{
        .content = content,
        .details = null,
        .is_error = is_error,
    };
}

fn testDeinitToolResults(allocator: std.mem.Allocator, results: []const types.ToolResultMessage) void {
    for (results) |result| {
        content_clone.deinitContentBlocks(allocator, result.content);
        allocator.free(result.content);
    }
    allocator.free(results);
}

const TestEventCapture = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(types.AgentEvent) = .empty,

    fn init(allocator: std.mem.Allocator) TestEventCapture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestEventCapture) void {
        self.events.deinit(self.allocator);
    }
};

fn testCaptureEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *TestEventCapture = @ptrCast(@alignCast(context.?));
    try capture.events.append(capture.allocator, event);
}

fn testIgnoreEvent(_: ?*anyopaque, _: types.AgentEvent) !void {}

fn testToolResultOfEvent(event: types.AgentEvent) ?types.ToolResultMessage {
    const message = event.message orelse return null;
    return switch (message) {
        .tool_result => |tool_result| tool_result,
        else => null,
    };
}

fn testEchoToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const value = try testStringArg(params, "value");
    return try testTextToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "echoed: {s}", .{value}),
        false,
    );
}

const ParallelOrderFixture = struct {
    second_completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    first_waited_for_second: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    execute_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn testOutOfOrderToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const fixture: *ParallelOrderFixture = @ptrCast(@alignCast(tool_context orelse return error.MissingParallelOrderFixture));
    _ = fixture.execute_count.fetchAdd(1, .seq_cst);

    const value = try testStringArg(params, "value");
    if (std.mem.eql(u8, value, "first")) {
        var spins: usize = 0;
        while (!fixture.second_completed.load(.seq_cst)) : (spins += 1) {
            if (spins > 1_000_000) return error.SecondToolNeverCompleted;
            std.Thread.yield() catch {};
        }
        fixture.first_waited_for_second.store(true, .seq_cst);
    } else if (std.mem.eql(u8, value, "second")) {
        defer fixture.second_completed.store(true, .seq_cst);
    }

    return try testTextToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "completed: {s}", .{value}),
        false,
    );
}

fn testErrorResultToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    return try testTextToolResult(allocator, "tool reported failure", true);
}

const AbortFixture = struct {
    execute_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    saw_aborted_signal: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn testAbortAwareToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const fixture: *AbortFixture = @ptrCast(@alignCast(tool_context orelse return error.MissingAbortFixture));
    _ = fixture.execute_count.fetchAdd(1, .seq_cst);

    if (signal) |abort_signal| {
        if (abort_signal.load(.seq_cst)) {
            fixture.saw_aborted_signal.store(true, .seq_cst);
            return try testTextToolResult(allocator, "aborted before run", true);
        }
    }

    return try testTextToolResult(allocator, "not aborted", false);
}

test "findTool returns registered tool and null for unknown names" {
    const tools = [_]types.AgentTool{
        .{
            .name = "read",
            .description = "Read",
            .label = "Read",
            .parameters = .null,
        },
        .{
            .name = "write",
            .description = "Write",
            .label = "Write",
            .parameters = .null,
        },
    };

    const found = findTool(tools[0..], "write") orelse return error.ExpectedTool;
    try std.testing.expectEqualStrings("write", found.name);
    try std.testing.expect(findTool(tools[0..], "missing") == null);
}

test "prepareToolCall validates tool existence and JSON arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const schema = try testParseJson(allocator,
        \\{"type":"object","required":["value"],"properties":{"value":{"type":"string"}}}
    );
    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo",
        .label = "Echo",
        .parameters = schema.value,
        .execute = testEchoToolExecute,
    };
    const context = types.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &[_]types.AgentTool{tool},
    };

    var valid = try prepareToolCall(
        allocator,
        context,
        testAssistantMessage(),
        .{
            .id = "tool-valid",
            .name = "echo",
            .arguments = try testJsonObjectWithString(allocator, "value", "ok"),
        },
        testConfig(),
        null,
    );
    switch (valid) {
        .prepared => |*prepared| {
            defer prepared.deinit(allocator);
            try std.testing.expectEqualStrings("echo", prepared.tool.name);
            try std.testing.expectEqualStrings("ok", try testStringArg(prepared.args, "value"));
        },
        .immediate => return error.ExpectedPreparedToolCall,
    }

    const missing = try prepareToolCall(
        allocator,
        context,
        testAssistantMessage(),
        .{
            .id = "tool-missing",
            .name = "missing",
            .arguments = .null,
        },
        testConfig(),
        null,
    );
    switch (missing) {
        .prepared => return error.ExpectedImmediateMissingTool,
        .immediate => |immediate| {
            try std.testing.expect(immediate.is_error);
            try std.testing.expectEqualStrings("Tool missing not found", immediate.result.content[0].text.text);
        },
    }

    const invalid = try prepareToolCall(
        allocator,
        context,
        testAssistantMessage(),
        .{
            .id = "tool-invalid",
            .name = "echo",
            .arguments = .{ .string = "not an object" },
        },
        testConfig(),
        null,
    );
    switch (invalid) {
        .prepared => return error.ExpectedImmediateInvalidArguments,
        .immediate => |immediate| {
            try std.testing.expect(immediate.is_error);
            try std.testing.expectEqualStrings("InvalidToolArguments", immediate.result.content[0].text.text);
        },
    }
}

test "executeToolCallsParallel preserves result order when tools complete out of order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tool_calls = [_]pi_types.ToolCall{
        .{
            .id = "tool-1",
            .name = "ordered",
            .arguments = try testJsonObjectWithString(allocator, "value", "first"),
        },
        .{
            .id = "tool-2",
            .name = "ordered",
            .arguments = try testJsonObjectWithString(allocator, "value", "second"),
        },
    };
    var fixture = ParallelOrderFixture{};
    const tool = types.AgentTool{
        .name = "ordered",
        .description = "Ordered",
        .label = "Ordered",
        .parameters = .null,
        .execute_context = &fixture,
        .execute = testOutOfOrderToolExecute,
    };
    var capture = TestEventCapture.init(std.testing.allocator);
    defer capture.deinit();

    const results = (try executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        testAssistantMessage(),
        tool_calls[0..],
        testConfig(),
        &capture,
        testCaptureEvent,
        null,
    )).messages;
    defer testDeinitToolResults(std.testing.allocator, results);

    try std.testing.expect(fixture.first_waited_for_second.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.execute_count.load(.seq_cst));
    try std.testing.expectEqualStrings("tool-1", results[0].tool_call_id);
    try std.testing.expectEqualStrings("tool-2", results[1].tool_call_id);
    try std.testing.expectEqualStrings("completed: first", results[0].content[0].text.text);
    try std.testing.expectEqualStrings("completed: second", results[1].content[0].text.text);

    var tool_end_ids = std.ArrayList([]const u8).empty;
    defer tool_end_ids.deinit(std.testing.allocator);
    var tool_message_ids = std.ArrayList([]const u8).empty;
    defer tool_message_ids.deinit(std.testing.allocator);

    for (capture.events.items) |event| {
        switch (event.event_type) {
            .tool_execution_end => try tool_end_ids.append(std.testing.allocator, event.tool_call_id orelse return error.MissingToolCallId),
            .message_end => if (testToolResultOfEvent(event)) |tool_result| {
                try tool_message_ids.append(std.testing.allocator, tool_result.tool_call_id);
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), tool_end_ids.items.len);
    var saw_tool_1_end = false;
    var saw_tool_2_end = false;
    for (tool_end_ids.items) |tool_end_id| {
        if (std.mem.eql(u8, tool_end_id, "tool-1")) saw_tool_1_end = true;
        if (std.mem.eql(u8, tool_end_id, "tool-2")) saw_tool_2_end = true;
    }
    try std.testing.expect(saw_tool_1_end);
    try std.testing.expect(saw_tool_2_end);
    try std.testing.expectEqual(@as(usize, 2), tool_message_ids.items.len);
    try std.testing.expectEqualStrings("tool-1", tool_message_ids.items[0]);
    try std.testing.expectEqualStrings("tool-2", tool_message_ids.items[1]);
}

test "executeToolCallsParallel represents tool error results without crashing" {
    const tool_calls = [_]pi_types.ToolCall{.{
        .id = "tool-error",
        .name = "erroring",
        .arguments = .null,
    }};
    const tool = types.AgentTool{
        .name = "erroring",
        .description = "Returns an error result",
        .label = "Erroring",
        .parameters = .null,
        .execute = testErrorResultToolExecute,
    };
    var capture = TestEventCapture.init(std.testing.allocator);
    defer capture.deinit();

    const results = (try executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        testAssistantMessage(),
        tool_calls[0..],
        testConfig(),
        &capture,
        testCaptureEvent,
        null,
    )).messages;
    defer testDeinitToolResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].is_error);
    try std.testing.expectEqualStrings("tool reported failure", results[0].content[0].text.text);

    var saw_end = false;
    var saw_message = false;
    for (capture.events.items) |event| {
        if (event.event_type == .tool_execution_end) {
            saw_end = true;
            try std.testing.expectEqual(true, event.is_error.?);
            try std.testing.expectEqualStrings("tool reported failure", event.result.?.content[0].text.text);
        }
        if (event.event_type == .message_end) {
            if (testToolResultOfEvent(event)) |tool_result| {
                saw_message = true;
                try std.testing.expect(tool_result.is_error);
                try std.testing.expectEqualStrings("tool-error", tool_result.tool_call_id);
            }
        }
    }
    try std.testing.expect(saw_end);
    try std.testing.expect(saw_message);
}

test "executeToolCallsParallel forwards pre-set abort signal and terminates gracefully" {
    const tool_calls = [_]pi_types.ToolCall{.{
        .id = "tool-abort",
        .name = "abort-aware",
        .arguments = .null,
    }};
    var fixture = AbortFixture{};
    const tool = types.AgentTool{
        .name = "abort-aware",
        .description = "Observes abort signal",
        .label = "Abort",
        .parameters = .null,
        .execute_context = &fixture,
        .execute = testAbortAwareToolExecute,
    };
    var signal = std.atomic.Value(bool).init(true);

    const results = (try executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        testAssistantMessage(),
        tool_calls[0..],
        testConfig(),
        null,
        testIgnoreEvent,
        &signal,
    )).messages;
    defer testDeinitToolResults(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), fixture.execute_count.load(.seq_cst));
    try std.testing.expect(fixture.saw_aborted_signal.load(.seq_cst));
    try std.testing.expect(results[0].is_error);
    try std.testing.expectEqualStrings("aborted before run", results[0].content[0].text.text);
}

test "finalizeExecutedToolCall emits finalized tool execution event shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try testJsonObjectWithString(allocator, "value", "done");
    const tool = types.AgentTool{
        .name = "finalize",
        .description = "Finalize",
        .label = "Finalize",
        .parameters = .null,
    };
    var prepared = PreparedToolCall{
        .tool_call = .{
            .id = "tool-final",
            .name = "finalize",
            .arguments = args,
        },
        .tool = tool,
        .args = try provider_json.cloneValue(allocator, args),
    };
    defer prepared.deinit(allocator);

    const executed = ExecutedToolCallOutcome{
        .result = try testTextToolResult(allocator, "final output", false),
        .is_error = false,
    };
    var capture = TestEventCapture.init(std.testing.allocator);
    defer capture.deinit();

    const finalized = try finalizeExecutedToolCall(
        allocator,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        testAssistantMessage(),
        &prepared,
        executed,
        false,
        testConfig(),
        &capture,
        testCaptureEvent,
        null,
    );

    try std.testing.expect(prepared.finalized);
    try std.testing.expect(!finalized.is_error);
    try std.testing.expectEqualStrings("final output", finalized.result.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);

    const event = capture.events.items[0];
    try std.testing.expectEqual(types.AgentEventType.tool_execution_end, event.event_type);
    try std.testing.expectEqualStrings("tool-final", event.tool_call_id.?);
    try std.testing.expectEqualStrings("finalize", event.tool_name.?);
    try std.testing.expectEqualStrings("done", try testStringArg(event.args.?, "value"));
    try std.testing.expectEqual(false, event.is_error.?);
    try std.testing.expectEqual(false, event.result.?.is_error);
    try std.testing.expectEqualStrings("final output", event.result.?.content[0].text.text);
}

fn testBlockAndTerminate(
    _: std.mem.Allocator,
    _: types.BeforeToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.BeforeToolCallResult {
    return .{
        .block = true,
        .reason = "blocked by test",
        .terminate = true,
    };
}

fn testBlockWithoutTerminate(
    _: std.mem.Allocator,
    _: types.BeforeToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.BeforeToolCallResult {
    return .{
        .block = true,
        .reason = "blocked by test",
    };
}

test "blocked tool calls with terminate stop the batch" {
    const tool_calls = [_]pi_types.ToolCall{
        .{ .id = "tool-1", .name = "echo", .arguments = .null },
        .{ .id = "tool-2", .name = "echo", .arguments = .null },
    };
    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo",
        .label = "Echo",
        .parameters = .null,
        .execute = testEchoToolExecute,
    };
    var config = testConfig();
    config.before_tool_call = testBlockAndTerminate;

    const batch = try executeToolCalls(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        testAssistantMessage(),
        tool_calls[0..],
        config,
        null,
        testIgnoreEvent,
        null,
    );
    defer testDeinitToolResults(std.testing.allocator, batch.messages);

    try std.testing.expect(batch.terminate);
    try std.testing.expectEqual(@as(usize, 2), batch.messages.len);
    try std.testing.expect(batch.messages[0].is_error);
    try std.testing.expectEqualStrings("blocked by test", batch.messages[0].content[0].text.text);
}

test "blocked tool calls without terminate keep the batch running" {
    const tool_calls = [_]pi_types.ToolCall{
        .{ .id = "tool-1", .name = "echo", .arguments = .null },
    };
    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo",
        .label = "Echo",
        .parameters = .null,
        .execute = testEchoToolExecute,
    };
    var config = testConfig();
    config.before_tool_call = testBlockWithoutTerminate;

    const batch = try executeToolCalls(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        testAssistantMessage(),
        tool_calls[0..],
        config,
        null,
        testIgnoreEvent,
        null,
    );
    defer testDeinitToolResults(std.testing.allocator, batch.messages);

    try std.testing.expect(!batch.terminate);
    try std.testing.expectEqual(@as(usize, 1), batch.messages.len);
    try std.testing.expect(batch.messages[0].is_error);
}
