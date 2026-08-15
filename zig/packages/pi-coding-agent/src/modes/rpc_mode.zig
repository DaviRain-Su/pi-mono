const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const common = @import("../tools/common.zig");
const session_mod = @import("../sessions/session.zig");

pub const RunRpcModeOptions = struct {};

const JSON_RPC_VERSION = "2.0";

const ErrorCode = struct {
    const parse_error: i64 = -32700;
    const invalid_request: i64 = -32600;
    const method_not_found: i64 = -32601;
    const invalid_params: i64 = -32602;
    const internal_error: i64 = -32603;
    const request_cancelled: i64 = -32800;
    const request_busy: i64 = -32000;
    const not_initialized: i64 = -32001;
};

/// JSON-RPC method set understood by `RpcServer.handleLine`. Each tag's
/// `@tagName` is the byte-exact on-wire method string. Adding a new method
/// requires extending both this enum and the exhaustive switch below — a
/// compile error guarantees the dispatcher stays in sync with the wire
/// protocol.
pub const RpcMethod = enum {
    @"$/cancelRequest",
    initialize,
    chat,
    complete,
    stream,
};

comptime {
    std.debug.assert(std.mem.eql(u8, @tagName(RpcMethod.@"$/cancelRequest"), "$/cancelRequest"));
    std.debug.assert(std.mem.eql(u8, @tagName(RpcMethod.initialize), "initialize"));
    std.debug.assert(std.mem.eql(u8, @tagName(RpcMethod.chat), "chat"));
    std.debug.assert(std.mem.eql(u8, @tagName(RpcMethod.complete), "complete"));
    std.debug.assert(std.mem.eql(u8, @tagName(RpcMethod.stream), "stream"));
}

const RequestId = union(enum) {
    none,
    null_id,
    string: []u8,
    integer: i64,

    fn fromOptionalValue(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) !RequestId {
        const value = maybe_value orelse return .none;
        return switch (value) {
            .null => .null_id,
            .string => |string| .{ .string = try allocator.dupe(u8, string) },
            .integer => |integer| .{ .integer = integer },
            else => error.InvalidRequestId,
        };
    }

    fn clone(self: RequestId, allocator: std.mem.Allocator) !RequestId {
        return switch (self) {
            .none => .none,
            .null_id => .null_id,
            .string => |string| .{ .string = try allocator.dupe(u8, string) },
            .integer => |integer| .{ .integer = integer },
        };
    }

    fn deinit(self: *RequestId, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |string| allocator.free(string),
            else => {},
        }
        self.* = .none;
    }

    fn hasResponse(self: RequestId) bool {
        return self != .none;
    }

    fn matches(self: RequestId, other: RequestId) bool {
        return switch (self) {
            .none => other == .none,
            .null_id => other == .null_id,
            .string => |string| switch (other) {
                .string => |other_string| std.mem.eql(u8, string, other_string),
                else => false,
            },
            .integer => |integer| switch (other) {
                .integer => |other_integer| integer == other_integer,
                else => false,
            },
        };
    }

    fn toJsonValue(self: RequestId, allocator: std.mem.Allocator) !std.json.Value {
        return switch (self) {
            .none => .null,
            .null_id => .null,
            .string => |string| .{ .string = try allocator.dupe(u8, string) },
            .integer => |integer| .{ .integer = integer },
        };
    }
};

const ActiveMethod = enum {
    chat,
    complete,
    stream,

    fn jsonName(self: ActiveMethod) []const u8 {
        return @tagName(self);
    }
};

const StreamSubscriberContext = struct {
    server: *RpcServer,
    request: *ActiveRequest,
};

const ActiveRequest = struct {
    allocator: std.mem.Allocator,
    server: *RpcServer,
    id: RequestId,
    method: ActiveMethod,
    message: []u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    subscriber_context: StreamSubscriberContext = undefined,
    subscriber: ?agent.AgentSubscriber = null,

    fn create(
        allocator: std.mem.Allocator,
        server: *RpcServer,
        id: RequestId,
        method: ActiveMethod,
        message: []const u8,
    ) !*ActiveRequest {
        const request = try allocator.create(ActiveRequest);
        errdefer allocator.destroy(request);

        request.* = .{
            .allocator = allocator,
            .server = server,
            .id = try id.clone(allocator),
            .method = method,
            .message = try allocator.dupe(u8, message),
        };
        errdefer {
            request.id.deinit(allocator);
            allocator.free(request.message);
        }

        request.thread = try std.Thread.spawn(.{}, runThread, .{request});
        return request;
    }

    fn joinAndDestroy(self: *ActiveRequest) void {
        if (self.thread) |thread| thread.join();
        self.id.deinit(self.allocator);
        self.allocator.free(self.message);
        self.allocator.destroy(self);
    }

    fn runThread(self: *ActiveRequest) void {
        defer self.done.store(true, .seq_cst);
        self.run() catch |err| {
            self.server.writeErrorResponse(self.id, ErrorCode.internal_error, @errorName(err)) catch {};
        };
    }

    fn run(self: *ActiveRequest) !void {
        switch (self.method) {
            .chat => try self.runChatLike(false),
            .complete => try self.runChatLike(true),
            .stream => try self.runStream(),
        }
    }

    fn runChatLike(self: *ActiveRequest, complete_only: bool) !void {
        try self.server.session.prompt(self.message);
        const assistant_message = findLastAssistantMessage(self.server.session.agent.getMessages()) orelse
            return error.MissingCompletionResult;

        if (assistant_message.stop_reason == .aborted) {
            try self.server.writeErrorResponse(self.id, ErrorCode.request_cancelled, "Request cancelled");
            return;
        }

        const result_value = if (complete_only)
            try buildCompletionResultValue(std.heap.page_allocator, assistant_message)
        else
            try buildChatResultValue(std.heap.page_allocator, assistant_message, self.server.session);
        try self.server.writeSuccessResponse(self.id, result_value);
    }

    fn runStream(self: *ActiveRequest) !void {
        self.subscriber_context = .{
            .server = self.server,
            .request = self,
        };
        self.subscriber = .{
            .context = &self.subscriber_context,
            .callback = handleStreamAgentEvent,
        };

        try self.server.session.agent.subscribe(self.subscriber.?);
        defer _ = self.server.session.agent.unsubscribe(self.subscriber.?);

        try self.server.session.prompt(self.message);
        const assistant_message = findLastAssistantMessage(self.server.session.agent.getMessages()) orelse
            return error.MissingCompletionResult;

        if (assistant_message.stop_reason == .aborted) {
            try self.server.writeErrorResponse(self.id, ErrorCode.request_cancelled, "Request cancelled");
            return;
        }

        const result_value = try buildChatResultValue(std.heap.page_allocator, assistant_message, self.server.session);
        try self.server.writeSuccessResponse(self.id, result_value);
    }
};

const RpcServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    output_mutex: std.Io.Mutex = .init,
    initialized: bool = false,
    active_request: ?*ActiveRequest = null,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        session: *session_mod.AgentSession,
        stdout_writer: *std.Io.Writer,
        stderr_writer: *std.Io.Writer,
    ) RpcServer {
        return .{
            .allocator = allocator,
            .io = io,
            .session = session,
            .stdout_writer = stdout_writer,
            .stderr_writer = stderr_writer,
        };
    }

    fn finish(self: *RpcServer) !void {
        try self.reapActiveRequest(true);
        try self.stdout_writer.flush();
        try self.stderr_writer.flush();
    }

    fn handleLine(self: *RpcServer, line: []const u8) !void {
        try self.reapActiveRequest(false);

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;

        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, trimmed, .{}) catch {
            try self.writeErrorResponse(.null_id, ErrorCode.parse_error, "Parse error");
            return;
        };
        defer parsed.deinit();

        const root_object = switch (parsed.value) {
            .object => |object| object,
            else => {
                try self.writeErrorResponse(.null_id, ErrorCode.invalid_request, "Invalid request");
                return;
            },
        };

        const version_value = root_object.get("jsonrpc") orelse {
            try self.writeErrorResponse(.null_id, ErrorCode.invalid_request, "Missing jsonrpc version");
            return;
        };
        const version = switch (version_value) {
            .string => |string| string,
            else => {
                try self.writeErrorResponse(.null_id, ErrorCode.invalid_request, "Invalid jsonrpc version");
                return;
            },
        };
        if (!std.mem.eql(u8, version, JSON_RPC_VERSION)) {
            try self.writeErrorResponse(.null_id, ErrorCode.invalid_request, "Invalid jsonrpc version");
            return;
        }

        var request_id = RequestId.fromOptionalValue(self.allocator, root_object.get("id")) catch {
            try self.writeErrorResponse(.null_id, ErrorCode.invalid_request, "Invalid request id");
            return;
        };
        defer request_id.deinit(self.allocator);

        const method_value = root_object.get("method") orelse {
            try self.writeErrorResponse(request_id, ErrorCode.invalid_request, "Missing method");
            return;
        };
        const method = switch (method_value) {
            .string => |string| string,
            else => {
                try self.writeErrorResponse(request_id, ErrorCode.invalid_request, "Method must be a string");
                return;
            },
        };

        const params = root_object.get("params");
        const maybe_method = std.meta.stringToEnum(RpcMethod, method);

        if (maybe_method) |parsed_method| {
            if (parsed_method == .@"$/cancelRequest") {
                try self.handleCancel(request_id, params);
                return;
            }
        }

        if (self.active_request != null) {
            if (request_id.hasResponse()) {
                try self.writeErrorResponse(request_id, ErrorCode.request_busy, "Another request is already running");
            }
            return;
        }

        const rpc_method = maybe_method orelse {
            if (!self.initialized) {
                if (request_id.hasResponse()) {
                    try self.writeErrorResponse(request_id, ErrorCode.not_initialized, "Server not initialized");
                }
                return;
            }
            if (request_id.hasResponse()) {
                try self.writeErrorResponse(request_id, ErrorCode.method_not_found, "Method not found");
            }
            return;
        };

        switch (rpc_method) {
            .@"$/cancelRequest" => unreachable, // handled above before active-request gate
            .initialize => {
                self.initialized = true;
                if (request_id.hasResponse()) {
                    const result_value = try buildInitializeResultValue(std.heap.page_allocator, self.session);
                    try self.writeSuccessResponse(request_id, result_value);
                }
                return;
            },
            .chat, .complete, .stream => |m| {
                if (!self.initialized) {
                    if (request_id.hasResponse()) {
                        try self.writeErrorResponse(request_id, ErrorCode.not_initialized, "Server not initialized");
                    }
                    return;
                }
                const error_message = switch (m) {
                    .chat => "chat requires params.message",
                    .complete => "complete requires params.message",
                    .stream => "stream requires params.message",
                    .initialize, .@"$/cancelRequest" => unreachable,
                };
                const active_method: ActiveMethod = switch (m) {
                    .chat => .chat,
                    .complete => .complete,
                    .stream => .stream,
                    .initialize, .@"$/cancelRequest" => unreachable,
                };
                const message = extractMessageParam(params) catch {
                    try self.writeErrorResponse(request_id, ErrorCode.invalid_params, error_message);
                    return;
                };
                self.active_request = try ActiveRequest.create(self.allocator, self, request_id, active_method, message);
                return;
            },
        }
    }

    fn handleCancel(self: *RpcServer, request_id: RequestId, params: ?std.json.Value) !void {
        var target_id = extractCancelId(self.allocator, params) catch {
            if (request_id.hasResponse()) {
                try self.writeErrorResponse(request_id, ErrorCode.invalid_params, "$/cancelRequest requires params.id");
            }
            return;
        };
        defer target_id.deinit(self.allocator);

        if (self.active_request) |active| {
            if (active.id.matches(target_id)) {
                var spins: usize = 0;
                while (!self.session.agent.isStreaming() and !active.done.load(.seq_cst) and spins < 200) : (spins += 1) {
                    std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
                }
                self.session.agent.abort();
            }
        }

        if (request_id.hasResponse()) {
            try self.writeSuccessResponse(request_id, .null);
        }
    }

    fn reapActiveRequest(self: *RpcServer, wait: bool) !void {
        if (self.active_request) |active| {
            if (wait or active.done.load(.seq_cst)) {
                active.joinAndDestroy();
                self.active_request = null;
            }
        }
    }

    fn writeSuccessResponse(self: *RpcServer, request_id: RequestId, result_value: std.json.Value) !void {
        var root = try initObject(std.heap.page_allocator);
        defer {
            const value: std.json.Value = .{ .object = root };
            common.deinitJsonValue(std.heap.page_allocator, value);
        }

        try putStringField(&root, std.heap.page_allocator, "jsonrpc", JSON_RPC_VERSION);
        try putField(&root, std.heap.page_allocator, "id", try request_id.toJsonValue(std.heap.page_allocator));
        try putField(&root, std.heap.page_allocator, "result", result_value);
        try self.writeObject(root);
    }

    fn writeErrorResponse(self: *RpcServer, request_id: RequestId, code: i64, message: []const u8) !void {
        if (!request_id.hasResponse() and request_id != .null_id) return;

        var error_object = try initObject(std.heap.page_allocator);
        errdefer {
            const value: std.json.Value = .{ .object = error_object };
            common.deinitJsonValue(std.heap.page_allocator, value);
        }
        try putIntField(&error_object, std.heap.page_allocator, "code", code);
        try putStringField(&error_object, std.heap.page_allocator, "message", message);

        var root = try initObject(std.heap.page_allocator);
        defer {
            const value: std.json.Value = .{ .object = root };
            common.deinitJsonValue(std.heap.page_allocator, value);
        }

        try putStringField(&root, std.heap.page_allocator, "jsonrpc", JSON_RPC_VERSION);
        try putField(&root, std.heap.page_allocator, "id", try request_id.toJsonValue(std.heap.page_allocator));
        try putField(&root, std.heap.page_allocator, "error", .{ .object = error_object });
        try self.writeObject(root);
    }

    fn writeNotification(self: *RpcServer, method: []const u8, params_value: std.json.Value) !void {
        var root = try initObject(std.heap.page_allocator);
        defer {
            const value: std.json.Value = .{ .object = root };
            common.deinitJsonValue(std.heap.page_allocator, value);
        }

        try putStringField(&root, std.heap.page_allocator, "jsonrpc", JSON_RPC_VERSION);
        try putStringField(&root, std.heap.page_allocator, "method", method);
        try putField(&root, std.heap.page_allocator, "params", params_value);
        try self.writeObject(root);
    }

    fn writeObject(self: *RpcServer, object: std.json.ObjectMap) !void {
        const value: std.json.Value = .{ .object = object };
        const line = try std.json.Stringify.valueAlloc(std.heap.page_allocator, value, .{});
        defer std.heap.page_allocator.free(line);

        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.print("{s}\n", .{line});
        try self.stdout_writer.flush();
    }
};

fn handleStreamAgentEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const subscriber_context: *StreamSubscriberContext = @ptrCast(@alignCast(context.?));
    const params_value = try buildStreamEventValue(std.heap.page_allocator, subscriber_context.request.id, event);
    try subscriber_context.server.writeNotification("pi/event", params_value);
}

pub fn runRpcMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    _: RunRpcModeOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var server = RpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    defer server.finish() catch {};

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);

    while (true) {
        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n') {
            try server.handleLine(line_buffer.items);
            line_buffer.clearRetainingCapacity();
            continue;
        }
        try line_buffer.append(allocator, byte);
    }

    if (line_buffer.items.len > 0) {
        try server.handleLine(line_buffer.items);
    }

    try server.finish();
    return 0;
}

fn runRpcModeScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    lines: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !void {
    var server = RpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    defer server.finish() catch {};

    for (lines) |line| {
        try server.handleLine(line);
    }

    try server.finish();
}

fn extractMessageParam(params: ?std.json.Value) ![]const u8 {
    const params_value = params orelse return error.InvalidParams;
    const object = switch (params_value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };

    const message_value = object.get("message") orelse return error.InvalidParams;
    return switch (message_value) {
        .string => |string| string,
        else => return error.InvalidParams,
    };
}

fn extractCancelId(allocator: std.mem.Allocator, params: ?std.json.Value) !RequestId {
    const params_value = params orelse return error.InvalidParams;
    const object = switch (params_value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    return RequestId.fromOptionalValue(allocator, object.get("id"));
}

fn buildInitializeResultValue(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) !std.json.Value {
    var capabilities = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = capabilities };
        common.deinitJsonValue(allocator, value);
    }
    try putBoolField(&capabilities, allocator, "chat", true);
    try putBoolField(&capabilities, allocator, "complete", true);
    try putBoolField(&capabilities, allocator, "stream", true);
    try putBoolField(&capabilities, allocator, "cancel", true);

    var result = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = result };
        common.deinitJsonValue(allocator, value);
    }

    try putIntField(&result, allocator, "protocolVersion", 1);
    try putField(&result, allocator, "capabilities", .{ .object = capabilities });
    try putField(&result, allocator, "session", try buildSessionInfoValue(allocator, session));
    try putField(&result, allocator, "model", try buildModelValue(allocator, session.agent.getModel()));
    return .{ .object = result };
}

fn buildChatResultValue(
    allocator: std.mem.Allocator,
    assistant_message: ai.AssistantMessage,
    session: *const session_mod.AgentSession,
) !std.json.Value {
    var result = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = result };
        common.deinitJsonValue(allocator, value);
    }

    try putField(&result, allocator, "message", try buildAssistantSummaryValue(allocator, assistant_message));
    try putField(&result, allocator, "session", try buildSessionInfoValue(allocator, session));
    return .{ .object = result };
}

fn buildCompletionResultValue(allocator: std.mem.Allocator, assistant_message: ai.AssistantMessage) !std.json.Value {
    var result = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = result };
        common.deinitJsonValue(allocator, value);
    }

    const text = try blocksToText(allocator, assistant_message.content);
    defer allocator.free(text);

    try putStringField(&result, allocator, "text", text);
    try putStringField(&result, allocator, "stopReason", @tagName(assistant_message.stop_reason));
    try putStringField(&result, allocator, "provider", assistant_message.provider);
    try putStringField(&result, allocator, "model", assistant_message.model);
    if (assistant_message.response_id) |response_id| {
        try putStringField(&result, allocator, "responseId", response_id);
    }
    if (assistant_message.response_model) |response_model| {
        try putStringField(&result, allocator, "responseModel", response_model);
    }
    if (assistant_message.error_message) |error_message| {
        try putStringField(&result, allocator, "error", error_message);
    }
    try putField(&result, allocator, "usage", try buildUsageValue(allocator, assistant_message.usage));
    return .{ .object = result };
}

fn buildAssistantSummaryValue(allocator: std.mem.Allocator, assistant_message: ai.AssistantMessage) !std.json.Value {
    var result = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = result };
        common.deinitJsonValue(allocator, value);
    }

    const text = try blocksToText(allocator, assistant_message.content);
    defer allocator.free(text);

    try putStringField(&result, allocator, "role", assistant_message.role);
    try putStringField(&result, allocator, "text", text);
    try putStringField(&result, allocator, "stopReason", @tagName(assistant_message.stop_reason));
    try putStringField(&result, allocator, "provider", assistant_message.provider);
    try putStringField(&result, allocator, "model", assistant_message.model);
    if (assistant_message.response_id) |response_id| {
        try putStringField(&result, allocator, "responseId", response_id);
    }
    if (assistant_message.response_model) |response_model| {
        try putStringField(&result, allocator, "responseModel", response_model);
    }
    if (assistant_message.error_message) |error_message| {
        try putStringField(&result, allocator, "error", error_message);
    }
    try putField(&result, allocator, "usage", try buildUsageValue(allocator, assistant_message.usage));
    return .{ .object = result };
}

fn buildSessionInfoValue(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) !std.json.Value {
    var result = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = result };
        common.deinitJsonValue(allocator, value);
    }

    try putStringField(&result, allocator, "id", session.session_manager.getSessionId());
    if (session.session_manager.getSessionFile()) |session_file| {
        try putStringField(&result, allocator, "file", session_file);
    }
    try putStringField(&result, allocator, "cwd", session.cwd);
    try putIntField(&result, allocator, "messageCount", session.agent.getMessages().len);
    return .{ .object = result };
}

fn buildModelValue(allocator: std.mem.Allocator, model: ai.Model) !std.json.Value {
    var result = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = result };
        common.deinitJsonValue(allocator, value);
    }

    try putStringField(&result, allocator, "id", model.id);
    try putStringField(&result, allocator, "name", model.name);
    try putStringField(&result, allocator, "provider", model.provider);
    try putStringField(&result, allocator, "api", model.api);
    if (model.thinking_level_map) |map| {
        try putField(&result, allocator, "thinkingLevelMap", try buildThinkingLevelMapValue(allocator, map));
    }
    return .{ .object = result };
}

fn buildThinkingLevelMapValue(allocator: std.mem.Allocator, map: ai.types.ModelThinkingLevelMap) !std.json.Value {
    var result = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = result };
        common.deinitJsonValue(allocator, value);
    }

    try putThinkingLevelMapField(&result, allocator, "off", map.off);
    try putThinkingLevelMapField(&result, allocator, "minimal", map.minimal);
    try putThinkingLevelMapField(&result, allocator, "low", map.low);
    try putThinkingLevelMapField(&result, allocator, "medium", map.medium);
    try putThinkingLevelMapField(&result, allocator, "high", map.high);
    try putThinkingLevelMapField(&result, allocator, "xhigh", map.xhigh);
    return .{ .object = result };
}

fn putThinkingLevelMapField(
    object: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    key: []const u8,
    mapping: ?ai.types.ThinkingLevelMapping,
) !void {
    const value = mapping orelse return;
    switch (value) {
        .unsupported => try putField(object, allocator, key, .null),
        .mapped => |mapped| try putStringField(object, allocator, key, mapped),
    }
}

fn buildUsageValue(allocator: std.mem.Allocator, usage: ai.Usage) !std.json.Value {
    var result = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = result };
        common.deinitJsonValue(allocator, value);
    }

    try putIntField(&result, allocator, "input", usage.input);
    try putIntField(&result, allocator, "output", usage.output);
    try putIntField(&result, allocator, "cacheRead", usage.cache_read);
    try putIntField(&result, allocator, "cacheWrite", usage.cache_write);
    try putIntField(&result, allocator, "totalTokens", usage.total_tokens);
    return .{ .object = result };
}

fn buildStreamEventValue(
    allocator: std.mem.Allocator,
    request_id: RequestId,
    event: agent.AgentEvent,
) !std.json.Value {
    var result = try initObject(allocator);
    errdefer {
        const value: std.json.Value = .{ .object = result };
        common.deinitJsonValue(allocator, value);
    }

    if (request_id.hasResponse()) {
        try putField(&result, allocator, "requestId", try request_id.toJsonValue(allocator));
    }
    try putStringField(&result, allocator, "eventType", @tagName(event.event_type));

    if (event.message) |message| {
        switch (message) {
            .user => {
                try putStringField(&result, allocator, "role", "user");
                const text = try blocksToText(allocator, message.user.content);
                defer allocator.free(text);
                try putStringField(&result, allocator, "text", text);
            },
            .assistant => {
                try putStringField(&result, allocator, "role", "assistant");
                const text = try blocksToText(allocator, message.assistant.content);
                defer allocator.free(text);
                try putStringField(&result, allocator, "text", text);
            },
            .tool_result => {
                try putStringField(&result, allocator, "role", "toolResult");
                const text = try blocksToText(allocator, message.tool_result.content);
                defer allocator.free(text);
                try putStringField(&result, allocator, "text", text);
                if (message.tool_result.details) |details| {
                    try putField(&result, allocator, "details", try common.cloneJsonValue(allocator, details));
                }
            },
        }
    } else if (event.result) |tool_result| {
        const text = try blocksToText(allocator, tool_result.content);
        defer allocator.free(text);
        try putStringField(&result, allocator, "text", text);
        if (tool_result.details) |details| {
            try putField(&result, allocator, "details", try common.cloneJsonValue(allocator, details));
        }
    } else if (event.partial_result) |partial_result| {
        const text = try blocksToText(allocator, partial_result.content);
        defer allocator.free(text);
        try putStringField(&result, allocator, "text", text);
        if (partial_result.details) |details| {
            try putField(&result, allocator, "details", try common.cloneJsonValue(allocator, details));
        }
    }

    if (event.tool_name) |tool_name| try putStringField(&result, allocator, "toolName", tool_name);
    if (event.tool_call_id) |tool_call_id| try putStringField(&result, allocator, "toolCallId", tool_call_id);
    if (event.is_error) |is_error| try putBoolField(&result, allocator, "isError", is_error);

    return .{ .object = result };
}

fn blocksToText(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (blocks, 0..) |block, index| {
        if (index > 0) try out.appendSlice(allocator, "\n");
        switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            .thinking => |thinking| try out.appendSlice(allocator, thinking.thinking),
            .image => |image| {
                const placeholder = try std.fmt.allocPrint(allocator, "[image:{s}:{d}]", .{ image.mime_type, image.data.len });
                defer allocator.free(placeholder);
                try out.appendSlice(allocator, placeholder);
            },
            .tool_call => |tool_call| try out.appendSlice(allocator, tool_call.name),
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn findLastAssistantMessage(messages: []const agent.AgentMessage) ?ai.AssistantMessage {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .assistant => |assistant_message| return assistant_message,
            else => {},
        }
    }
    return null;
}

fn initObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

fn putField(object: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try common.putValue(allocator, &object, key, value);
}

fn putStringField(object: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try putField(object, allocator, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putBoolField(object: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: bool) !void {
    try putField(object, allocator, key, .{ .bool = value });
}

fn putIntField(object: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: anytype) !void {
    try putField(object, allocator, key, .{ .integer = @as(i64, @intCast(value)) });
}

fn parseJsonLine(allocator: std.mem.Allocator, line: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
}

fn makeTestToolDetails(allocator: std.mem.Allocator, exit_code: i64, timed_out: bool) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const value: std.json.Value = .{ .object = object };
        common.deinitJsonValue(allocator, value);
    }
    try common.putInt(allocator, &object, "exit_code", exit_code);
    try common.putBool(allocator, &object, "timed_out", timed_out);

    var truncation = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const value: std.json.Value = .{ .object = truncation };
        common.deinitJsonValue(allocator, value);
    }
    try common.putString(allocator, &truncation, "content", "tail output");
    try common.putBool(allocator, &truncation, "truncated", true);
    try common.putString(allocator, &truncation, "truncated_by", "bytes");
    try common.putInt(allocator, &truncation, "total_lines", 3000);
    try common.putInt(allocator, &truncation, "output_lines", 42);

    try common.putString(allocator, &object, "full_output_path", "/tmp/pi-bash-test.log");
    try common.putValue(allocator, &object, "truncation", .{ .object = truncation });
    return .{ .object = object };
}

fn testBashToolExecuteWithDetails(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    return .{
        .content = try common.makeTextContent(allocator, "bash output"),
        .details = try makeTestToolDetails(allocator, 9, false),
    };
}

test "rpc initialize reports capabilities and session state" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"jsonrpc\":\"2.0\",\"id\":\"init-1\",\"method\":\"initialize\",\"params\":{}}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const output = std.mem.trim(u8, stdout_capture.writer.buffered(), "\n");
    var parsed = try parseJsonLine(allocator, output);
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("init-1", root.get("id").?.string);
    try std.testing.expect(root.get("result").?.object.get("capabilities").?.object.get("stream").?.bool);
    try std.testing.expectEqualStrings(session.session_manager.getSessionId(), root.get("result").?.object.get("session").?.object.get("id").?.string);
}

test "rpc chat returns assistant message after initialize" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(blocks);
    blocks[0] = ai.providers.faux.fauxText("chat reply");
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(blocks, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":\"chat-1\",\"method\":\"chat\",\"params\":{\"message\":\"hello\"}}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, stdout_capture.writer.buffered(), "\n"), '\n');
    _ = lines.next().?;
    const chat_line = lines.next().?;
    var parsed = try parseJsonLine(allocator, chat_line);
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("chat reply", result.get("message").?.object.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 2), result.get("session").?.object.get("messageCount").?.integer);
}

test "rpc complete returns plain text result" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(blocks);
    blocks[0] = ai.providers.faux.fauxText("complete reply");
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(blocks, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":\"complete-1\",\"method\":\"complete\",\"params\":{\"message\":\"hello\"}}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, stdout_capture.writer.buffered(), "\n"), '\n');
    _ = lines.next().?;
    const complete_line = lines.next().?;
    var parsed = try parseJsonLine(allocator, complete_line);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("complete reply", parsed.value.object.get("result").?.object.get("text").?.string);
}

test "rpc stream emits notifications and final response" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(blocks);
    blocks[0] = ai.providers.faux.fauxText("stream reply");
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(blocks, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":\"stream-1\",\"method\":\"stream\",\"params\":{\"message\":\"hello\"}}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, stdout_capture.writer.buffered(), "\n"), '\n');
    _ = lines.next().?;

    var saw_event = false;
    var saw_response = false;
    while (lines.next()) |line| {
        var parsed = try parseJsonLine(allocator, line);
        defer parsed.deinit();

        const root = parsed.value.object;
        if (root.get("method")) |method| {
            try std.testing.expectEqualStrings("pi/event", method.string);
            saw_event = true;
        }
        if (root.get("result")) |result| {
            try std.testing.expectEqualStrings("stream reply", result.object.get("message").?.object.get("text").?.string);
            saw_response = true;
        }
    }

    try std.testing.expect(saw_event);
    try std.testing.expect(saw_response);
}

test "rpc stream notification includes structured tool details" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try common.putString(allocator, &args, "command", "echo hello");
    const args_value = std.json.Value{ .object = args };
    defer common.deinitJsonValue(allocator, args_value);

    const first_blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    first_blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "bash", args_value, .{ .id = "tool-1" });
    defer {
        switch (first_blocks[0]) {
            .tool_call => |tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.name);
                common.deinitJsonValue(allocator, tool_call.arguments);
            },
            else => {},
        }
        allocator.free(first_blocks);
    }

    const second_blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(second_blocks);
    second_blocks[0] = ai.providers.faux.fauxText("bash reply");
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(first_blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(second_blocks, .{}) },
    });

    const bash_tool = agent.AgentTool{
        .name = "bash",
        .description = "Run bash",
        .label = "bash",
        .parameters = .null,
        .execute = testBashToolExecuteWithDetails,
    };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = registration.getModel(),
        .tools = &[_]agent.AgentTool{bash_tool},
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":\"stream-1\",\"method\":\"stream\",\"params\":{\"message\":\"run bash\"}}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, stdout_capture.writer.buffered(), "\n"), '\n');
    _ = lines.next().?;

    var saw_details = false;
    while (lines.next()) |line| {
        var parsed = try parseJsonLine(allocator, line);
        defer parsed.deinit();

        const root = parsed.value.object;
        if (root.get("params")) |params| {
            const event = params.object;
            if (event.get("toolName")) |tool_name| {
                const tool_name_string = switch (tool_name) {
                    .string => |string| string,
                    else => continue,
                };
                if (!std.mem.eql(u8, tool_name_string, "bash")) continue;
                const details = event.get("details") orelse continue;
                if (details != .object) continue;
                try std.testing.expectEqual(@as(i64, 9), details.object.get("exit_code").?.integer);
                try std.testing.expectEqual(false, details.object.get("timed_out").?.bool);
                try std.testing.expectEqualStrings("/tmp/pi-bash-test.log", details.object.get("full_output_path").?.string);
                try std.testing.expectEqualStrings("bytes", details.object.get("truncation").?.object.get("truncated_by").?.string);
                try std.testing.expectEqual(@as(i64, 3000), details.object.get("truncation").?.object.get("total_lines").?.integer);
                saw_details = true;
                break;
            }
        }
    }

    try std.testing.expect(saw_details);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "rpc supports cancellation with json-rpc cancel requests" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .tokens_per_second = 4,
    });
    defer registration.unregister();

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(blocks);
    blocks[0] = ai.providers.faux.fauxText("this is a deliberately slow streaming reply used for cancellation");
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(blocks, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = RpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    defer server.finish() catch {};

    try server.handleLine("{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{}}");
    try server.handleLine("{\"jsonrpc\":\"2.0\",\"id\":\"stream-2\",\"method\":\"stream\",\"params\":{\"message\":\"hello\"}}");

    var spins: usize = 0;
    while (!session.agent.isStreaming() and server.active_request != null and !server.active_request.?.done.load(.seq_cst) and spins < 1000) : (spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }

    try server.handleLine("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":\"stream-2\"}}");
    try server.finish();

    var saw_cancel_error = false;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, stdout_capture.writer.buffered(), "\n"), '\n');
    while (lines.next()) |line| {
        var parsed = try parseJsonLine(allocator, line);
        defer parsed.deinit();

        const root = parsed.value.object;
        if (root.get("error")) |error_value| {
            const error_object = error_value.object;
            if (error_object.get("code").?.integer == ErrorCode.request_cancelled) {
                saw_cancel_error = true;
            }
        }
    }

    try std.testing.expect(saw_cancel_error);
}

test "rpc rejects requests before initialize with proper errors" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"jsonrpc\":\"2.0\",\"id\":\"chat-0\",\"method\":\"chat\",\"params\":{\"message\":\"hello\"}}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const output = std.mem.trim(u8, stdout_capture.writer.buffered(), "\n");
    var parsed = try parseJsonLine(allocator, output);
    defer parsed.deinit();

    try std.testing.expectEqual(ErrorCode.not_initialized, parsed.value.object.get("error").?.object.get("code").?.integer);
}
