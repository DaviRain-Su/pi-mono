const std = @import("std");
const types = @import("../types.zig");
const event_stream = @import("../event_stream.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const diagnostics_helper = @import("../shared/diagnostics.zig");
const provider_error = @import("../shared/provider_error.zig");
const provider_json = @import("../shared/provider_json.zig");
const provider_json_put = @import("../shared/provider_json_put.zig");
const provider_stream = @import("../shared/provider_stream.zig");
const resolve_api_key = @import("../shared/resolve_api_key.zig");
const sse_loop = @import("../shared/sse_loop.zig");
const test_stream_server = @import("test_stream_server.zig");

const putStringValue = provider_json_put.putStringValue;
const putIntegerValue = provider_json_put.putIntegerValue;
const putFloatValue = provider_json_put.putFloatValue;
const putBoolValue = provider_json_put.putBoolValue;
const putObjectValue = provider_json_put.putObjectValue;

pub const PiMessagesProvider = struct {
    const BaseProvider = provider_stream.DefineProvider("pi-messages", streamProduction);
    pub const api = BaseProvider.api;
    pub const stream = BaseProvider.stream;
    pub const streamSimple = BaseProvider.streamSimple;
};

pub fn buildMessagesUrl(allocator: std.mem.Allocator, base_url: []const u8, debug: bool) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (debug) return std.fmt.allocPrint(allocator, "{s}/messages?debug=1", .{trimmed});
    return std.fmt.allocPrint(allocator, "{s}/messages", .{trimmed});
}

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    var payload = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = payload });

    try putStringValue(allocator, &payload, "model", model.id);
    try putObjectValue(allocator, &payload, "context", try contextToJson(allocator, context));
    try putObjectValue(allocator, &payload, "options", try optionsToJson(allocator, options));
    return .{ .object = payload };
}

fn streamProduction(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    stream_instance: *event_stream.AssistantMessageEventStream,
) !void {
    const resolved = try resolve_api_key.resolveApiKey(allocator, model, options);
    defer if (resolved) |r| r.deinit(allocator);
    if (resolved == null) {
        try resolve_api_key.pushMissingApiKeyError(allocator, stream_instance, model);
        return;
    }

    const pi_opts = if (options) |opts| opts.providerOptions("pi_messages") else types.PiMessagesStreamOptions{};
    const url = try buildMessagesUrl(allocator, model.base_url, pi_opts.debug);
    defer allocator.free(url);

    var payload = try buildRequestPayload(allocator, model, context, options);
    try provider_stream.applyOnPayloadCallback(allocator, &payload, model, options);
    defer provider_json.freeValue(allocator, payload);

    const json_body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json_body);

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);
    if (model.headers) |model_headers| {
        var it = model_headers.iterator();
        while (it.next()) |entry| {
            try provider_stream.putOwnedHeader(allocator, &headers, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try provider_stream.putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
    try provider_stream.putOwnedHeader(allocator, &headers, "Accept", "text/event-stream");
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{resolved.?.key});
    defer allocator.free(auth_header);
    try provider_stream.putOwnedHeader(allocator, &headers, "Authorization", auth_header);
    if (options) |stream_options| {
        if (stream_options.headers) |extra_headers| {
            var it = extra_headers.iterator();
            while (it.next()) |entry| {
                try provider_stream.putOwnedHeader(allocator, &headers, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();
    var streaming = try provider_stream.executeStreamingRequest(
        &client,
        url,
        headers,
        json_body,
        options,
        model,
    );
    defer streaming.deinit();

    if (streaming.status != 200) {
        const response_body = try streaming.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
        defer allocator.free(response_body);
        try pushHttpResponseError(allocator, stream_instance, model, url, streaming.status, response_body);
        return;
    }

    var handler = SseHandler{
        .allocator = allocator,
        .model = model,
        .stream = stream_instance,
        .converter = try Converter.init(allocator, model),
    };
    defer handler.converter.deinit();

    const loop_result = try sse_loop.run(SseHandler, &handler, &streaming, options);
    if (!handler.finished) {
        if (loop_result == .completed) {
            try pushPlainError(
                allocator,
                stream_instance,
                model,
                try std.fmt.allocPrint(allocator, "{s} stream ended without a terminal event", .{model.provider}),
                .error_reason,
            );
        }
    }
}

const SseHandler = struct {
    allocator: std.mem.Allocator,
    model: types.Model,
    stream: *event_stream.AssistantMessageEventStream,
    converter: Converter,
    finished: bool = false,

    pub fn extractDataLine(_: *SseHandler, line: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, line, "data:")) {
            return std.mem.trim(u8, line["data:".len..], " \t");
        }
        return null;
    }

    pub fn isDoneData(_: *SseHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *SseHandler, data: []const u8) !bool {
        const keep_going = self.converter.handle(data, self.stream) catch |err| {
            if (err == error.OutOfMemory) return err;
            try self.handleRuntimeFailure(err);
            return false;
        };
        if (!keep_going) self.finished = true;
        return keep_going;
    }

    pub fn handleRuntimeFailure(self: *SseHandler, err: anyerror) !void {
        if (self.finished) return;
        self.finished = true;
        const aborted = err == error.RequestAborted;
        const message_text = if (aborted)
            try self.allocator.dupe(u8, "Request was aborted")
        else
            try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
        try pushPlainError(
            self.allocator,
            self.stream,
            self.model,
            message_text,
            if (aborted) .aborted else .error_reason,
        );
    }
};

const Converter = struct {
    allocator: std.mem.Allocator,
    model: types.Model,
    content: std.ArrayList(types.ContentBlock) = .empty,
    tool_json: std.AutoHashMap(u32, std.ArrayList(u8)),
    usage: types.Usage = .init(),
    stop_reason: types.StopReason = .stop,
    response_id: ?[]u8 = null,
    error_message: ?[]u8 = null,
    diagnostics: ?[]const types.AssistantMessageDiagnostic = null,
    transferred: bool = false,

    fn init(allocator: std.mem.Allocator, model: types.Model) !Converter {
        return .{
            .allocator = allocator,
            .model = model,
            .tool_json = std.AutoHashMap(u32, std.ArrayList(u8)).init(allocator),
        };
    }

    fn deinit(self: *Converter) void {
        var values = self.tool_json.valueIterator();
        while (values.next()) |list| list.deinit(self.allocator);
        self.tool_json.deinit();
        if (!self.transferred) {
            for (self.content.items) |block| types.freeContentBlock(self.allocator, block);
            if (self.response_id) |id| self.allocator.free(id);
            if (self.error_message) |message| self.allocator.free(message);
            if (self.diagnostics) |diagnostics| types.freeAssistantMessageDiagnostics(self.allocator, diagnostics);
        }
        self.content.deinit(self.allocator);
    }

    fn handle(self: *Converter, data: []const u8, stream: *event_stream.AssistantMessageEventStream) !bool {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPiMessagesEvent;
        const object = parsed.value.object;
        const event_type = jsonString(object, "type") orelse return error.InvalidPiMessagesEvent;

        if (std.mem.eql(u8, event_type, "start")) {
            stream.push(.{ .event_type = .start });
            return true;
        }
        if (std.mem.eql(u8, event_type, "text_start")) {
            const index = try requireContentIndex(object);
            try self.replaceBlock(index, .{ .text = .{ .text = try self.allocator.dupe(u8, "") } });
            stream.push(.{ .event_type = .text_start, .content_index = index });
            return true;
        }
        if (std.mem.eql(u8, event_type, "text_delta")) {
            const index = try requireContentIndex(object);
            const delta = jsonString(object, "delta") orelse "";
            try self.appendText(index, delta);
            stream.push(.{
                .event_type = .text_delta,
                .content_index = index,
                .delta = try self.allocator.dupe(u8, delta),
                .owns_delta = true,
            });
            return true;
        }
        if (std.mem.eql(u8, event_type, "text_end")) {
            const index = try requireContentIndex(object);
            if (jsonString(object, "content")) |content| {
                try self.setText(index, content, jsonString(object, "contentSignature"));
            } else if (jsonString(object, "contentSignature")) |signature| {
                try self.setTextSignature(index, signature);
            }
            const text = try self.blockText(index);
            stream.push(.{
                .event_type = .text_end,
                .content_index = index,
                .content = text,
            });
            return true;
        }
        if (std.mem.eql(u8, event_type, "thinking_start")) {
            const index = try requireContentIndex(object);
            try self.replaceBlock(index, .{ .thinking = .{ .thinking = try self.allocator.dupe(u8, "") } });
            stream.push(.{ .event_type = .thinking_start, .content_index = index });
            return true;
        }
        if (std.mem.eql(u8, event_type, "thinking_delta")) {
            const index = try requireContentIndex(object);
            const delta = jsonString(object, "delta") orelse "";
            try self.appendThinking(index, delta);
            stream.push(.{
                .event_type = .thinking_delta,
                .content_index = index,
                .delta = try self.allocator.dupe(u8, delta),
                .owns_delta = true,
            });
            return true;
        }
        if (std.mem.eql(u8, event_type, "thinking_end")) {
            const index = try requireContentIndex(object);
            if (jsonString(object, "content")) |content| {
                try self.setThinking(index, content, jsonString(object, "contentSignature"), jsonBool(object, "redacted"));
            }
            const thinking = try self.blockThinking(index);
            stream.push(.{
                .event_type = .thinking_end,
                .content_index = index,
                .content = thinking,
            });
            return true;
        }
        if (std.mem.eql(u8, event_type, "toolcall_start")) {
            const index = try requireContentIndex(object);
            const id = jsonString(object, "id") orelse "";
            const name = jsonString(object, "toolName") orelse "";
            try self.replaceBlock(index, .{
                .tool_call = .{
                    .id = try self.allocator.dupe(u8, id),
                    .name = try self.allocator.dupe(u8, name),
                    .arguments = try provider_json.emptyObjectValue(self.allocator),
                },
            });
            try self.tool_json.put(index, .empty);
            stream.push(.{ .event_type = .toolcall_start, .content_index = index });
            return true;
        }
        if (std.mem.eql(u8, event_type, "toolcall_delta")) {
            const index = try requireContentIndex(object);
            const delta = jsonString(object, "delta") orelse "";
            try self.appendToolJson(index, delta);
            try self.refreshToolArguments(index);
            stream.push(.{
                .event_type = .toolcall_delta,
                .content_index = index,
                .delta = try self.allocator.dupe(u8, delta),
                .owns_delta = true,
            });
            return true;
        }
        if (std.mem.eql(u8, event_type, "toolcall_end")) {
            const index = try requireContentIndex(object);
            if (object.get("toolCall")) |tool_call_value| {
                try self.replaceBlock(index, .{ .tool_call = try parseToolCall(self.allocator, tool_call_value) });
            }
            self.dropToolJson(index);
            const tool_call = try self.blockToolCall(index);
            stream.push(.{
                .event_type = .toolcall_end,
                .content_index = index,
                .tool_call = tool_call,
            });
            return true;
        }
        if (std.mem.eql(u8, event_type, "done") or std.mem.eql(u8, event_type, "error")) {
            if (jsonString(object, "reason")) |reason| {
                self.stop_reason = parseStopReason(reason);
            } else if (std.mem.eql(u8, event_type, "error")) {
                self.stop_reason = .error_reason;
            }
            if (object.get("usage")) |usage_value| {
                self.usage = parseUsage(usage_value);
            }
            if (jsonString(object, "responseId")) |response_id| {
                if (self.response_id) |old| self.allocator.free(old);
                self.response_id = try self.allocator.dupe(u8, response_id);
            }
            if (jsonString(object, "errorMessage")) |error_message| {
                if (self.error_message) |old| self.allocator.free(old);
                self.error_message = try self.allocator.dupe(u8, error_message);
            }
            if (object.get("rewrite")) |rewrite| {
                try self.appendRewrite(rewrite);
            }
            const message = try self.takeMessage();
            if (std.mem.eql(u8, event_type, "done")) {
                stream.push(.{
                    .event_type = .done,
                    .message = message,
                });
            } else {
                stream.push(.{
                    .event_type = .error_event,
                    .error_message = message.error_message,
                    .message = message,
                });
            }
            stream.end(message);
            return false;
        }
        return true;
    }

    fn takeMessage(self: *Converter) !types.AssistantMessage {
        const content = try self.content.toOwnedSlice(self.allocator);
        self.transferred = true;
        return .{
            .content = content,
            .api = self.model.api,
            .provider = self.model.provider,
            .model = self.model.id,
            .response_id = self.response_id,
            .diagnostics = self.diagnostics,
            .usage = self.usage,
            .stop_reason = self.stop_reason,
            .error_message = self.error_message,
            .timestamp = 0,
        };
    }

    fn ensureIndex(self: *Converter, index: u32) !void {
        while (self.content.items.len <= index) {
            try self.content.append(self.allocator, .{ .text = .{ .text = try self.allocator.dupe(u8, "") } });
        }
    }

    fn replaceBlock(self: *Converter, index: u32, block: types.ContentBlock) !void {
        try self.ensureIndex(index);
        types.freeContentBlock(self.allocator, self.content.items[index]);
        self.content.items[index] = block;
    }

    fn appendText(self: *Converter, index: u32, delta: []const u8) !void {
        try self.ensureIndex(index);
        if (self.content.items[index] != .text) {
            try self.replaceBlock(index, .{ .text = .{ .text = try self.allocator.dupe(u8, "") } });
        }
        const old = self.content.items[index].text.text;
        const next = try std.mem.concat(self.allocator, u8, &.{ old, delta });
        self.allocator.free(old);
        self.content.items[index].text.text = next;
    }

    fn setText(self: *Converter, index: u32, text: []const u8, signature: ?[]const u8) !void {
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const owned_signature = if (signature) |value| try self.allocator.dupe(u8, value) else null;
        try self.replaceBlock(index, .{
            .text = .{
                .text = owned_text,
                .text_signature = owned_signature,
            },
        });
    }

    fn setTextSignature(self: *Converter, index: u32, signature: []const u8) !void {
        try self.ensureIndex(index);
        if (self.content.items[index] != .text) return;
        if (self.content.items[index].text.text_signature) |old| self.allocator.free(old);
        self.content.items[index].text.text_signature = try self.allocator.dupe(u8, signature);
    }

    fn appendThinking(self: *Converter, index: u32, delta: []const u8) !void {
        try self.ensureIndex(index);
        if (self.content.items[index] != .thinking) {
            try self.replaceBlock(index, .{ .thinking = .{ .thinking = try self.allocator.dupe(u8, "") } });
        }
        const old = self.content.items[index].thinking.thinking;
        const next = try std.mem.concat(self.allocator, u8, &.{ old, delta });
        self.allocator.free(old);
        self.content.items[index].thinking.thinking = next;
    }

    fn setThinking(self: *Converter, index: u32, thinking: []const u8, signature: ?[]const u8, redacted: bool) !void {
        const owned_thinking = try self.allocator.dupe(u8, thinking);
        errdefer self.allocator.free(owned_thinking);
        const owned_signature = if (signature) |value| try self.allocator.dupe(u8, value) else null;
        try self.replaceBlock(index, .{
            .thinking = .{
                .thinking = owned_thinking,
                .thinking_signature = owned_signature,
                .redacted = redacted,
            },
        });
    }

    fn appendToolJson(self: *Converter, index: u32, delta: []const u8) !void {
        const entry = try self.tool_json.getOrPut(index);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.appendSlice(self.allocator, delta);
    }

    fn refreshToolArguments(self: *Converter, index: u32) !void {
        try self.ensureIndex(index);
        if (self.content.items[index] != .tool_call) return;
        const json_text = if (self.tool_json.get(index)) |list| list.items else "";
        const arguments = try parseStreamingJsonToValue(self.allocator, json_text);
        provider_json.freeValue(self.allocator, self.content.items[index].tool_call.arguments);
        self.content.items[index].tool_call.arguments = arguments;
    }

    fn dropToolJson(self: *Converter, index: u32) void {
        if (self.tool_json.fetchRemove(index)) |removed| {
            var list = removed.value;
            list.deinit(self.allocator);
        }
    }

    fn blockText(self: *Converter, index: u32) ![]const u8 {
        try self.ensureIndex(index);
        return switch (self.content.items[index]) {
            .text => |text| text.text,
            else => "",
        };
    }

    fn blockThinking(self: *Converter, index: u32) ![]const u8 {
        try self.ensureIndex(index);
        return switch (self.content.items[index]) {
            .thinking => |thinking| thinking.thinking,
            else => "",
        };
    }

    fn blockToolCall(self: *Converter, index: u32) !types.ToolCall {
        try self.ensureIndex(index);
        return switch (self.content.items[index]) {
            .tool_call => |tool_call| tool_call,
            else => error.InvalidPiMessagesEvent,
        };
    }

    fn appendRewrite(self: *Converter, rewrite: std.json.Value) !void {
        const details = try provider_json.cloneValue(self.allocator, rewrite);
        errdefer provider_json.freeValue(self.allocator, details);
        const diagnostic = types.AssistantMessageDiagnostic{
            .type = try self.allocator.dupe(u8, "pi_messages_rewrite"),
            .timestamp = 0,
            .details = details,
        };
        var message = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .api = self.model.api,
            .provider = self.model.provider,
            .model = self.model.id,
            .diagnostics = self.diagnostics,
            .usage = types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 0,
        };
        try diagnostics_helper.appendAssistantMessageDiagnostic(self.allocator, &message, diagnostic);
        self.diagnostics = message.diagnostics;
    }
};

fn contextToJson(allocator: std.mem.Allocator, context: types.Context) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });

    if (context.system_prompt) |system_prompt| {
        try putStringValue(allocator, &object, "systemPrompt", system_prompt);
    }

    var messages = std.json.Array.init(allocator);
    errdefer {
        for (messages.items) |item| provider_json.freeValue(allocator, item);
        messages.deinit();
    }
    for (context.messages) |message| {
        try messages.append(try messageToJson(allocator, message));
    }
    try putObjectValue(allocator, &object, "messages", .{ .array = messages });

    if (context.tools) |tools| {
        var tools_array = std.json.Array.init(allocator);
        errdefer {
            for (tools_array.items) |item| provider_json.freeValue(allocator, item);
            tools_array.deinit();
        }
        for (tools) |tool| {
            try tools_array.append(try toolToJson(allocator, tool));
        }
        try putObjectValue(allocator, &object, "tools", .{ .array = tools_array });
    }

    return .{ .object = object };
}

fn optionsToJson(allocator: std.mem.Allocator, options: ?types.StreamOptions) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });

    const stream_options = options orelse return .{ .object = object };
    const pi_opts = stream_options.providerOptions("pi_messages");

    if (stream_options.temperature) |temperature| {
        try putFloatValue(allocator, &object, "temperature", temperature);
    }
    if (stream_options.max_tokens) |max_tokens| {
        try putIntegerValue(allocator, &object, "maxTokens", max_tokens);
    }
    if (pi_opts.reasoning) |reasoning| {
        try putStringValue(allocator, &object, "reasoning", @tagName(reasoning));
    }
    if (resolveCacheRetention(stream_options)) |retention| {
        try putStringValue(allocator, &object, "cacheRetention", @tagName(retention));
    }
    if (stream_options.session_id) |session_id| {
        try putStringValue(allocator, &object, "sessionId", session_id);
    }
    if (pi_opts.tool_choice) |tool_choice| {
        try putObjectValue(allocator, &object, "toolChoice", try provider_json.cloneValue(allocator, tool_choice));
    }
    return .{ .object = object };
}

fn resolveCacheRetention(options: types.StreamOptions) ?types.CacheRetention {
    return switch (options.cache_retention) {
        .unset => blk: {
            const env_value = if (options.env) |env| env.get("PI_CACHE_RETENTION") else null;
            const process_value = env_value orelse processCacheRetentionEnv();
            break :blk if (process_value) |value|
                if (std.mem.eql(u8, value, "long")) .long else null
            else
                null;
        },
        .none, .short, .long => options.cache_retention,
    };
}

fn processCacheRetentionEnv() ?[]const u8 {
    const value = std.c.getenv("PI_CACHE_RETENTION") orelse return null;
    return std.mem.span(value);
}

fn messageToJson(allocator: std.mem.Allocator, message: types.Message) !std.json.Value {
    return switch (message) {
        .user => |user| try userMessageToJson(allocator, user),
        .assistant => |assistant| try assistantMessageToJson(allocator, assistant),
        .tool_result => |tool_result| try toolResultToJson(allocator, tool_result),
    };
}

fn userMessageToJson(allocator: std.mem.Allocator, user: types.UserMessage) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putStringValue(allocator, &object, "role", "user");
    if (user.content.len == 1 and user.content[0] == .text) {
        try putStringValue(allocator, &object, "content", user.content[0].text.text);
    } else {
        try putObjectValue(allocator, &object, "content", try contentBlocksToJson(allocator, user.content));
    }
    try putIntegerValue(allocator, &object, "timestamp", user.timestamp);
    return .{ .object = object };
}

fn assistantMessageToJson(allocator: std.mem.Allocator, assistant: types.AssistantMessage) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putStringValue(allocator, &object, "role", "assistant");
    try putObjectValue(allocator, &object, "content", try contentBlocksToJson(allocator, assistant.content));
    try putStringValue(allocator, &object, "api", assistant.api);
    try putStringValue(allocator, &object, "provider", assistant.provider);
    try putStringValue(allocator, &object, "model", assistant.model);
    if (assistant.response_id) |response_id| {
        try putStringValue(allocator, &object, "responseId", response_id);
    }
    if (assistant.response_model) |response_model| {
        try putStringValue(allocator, &object, "responseModel", response_model);
    }
    try putObjectValue(allocator, &object, "usage", try usageToJson(allocator, assistant.usage));
    try putStringValue(allocator, &object, "stopReason", stopReasonToString(assistant.stop_reason));
    if (assistant.error_message) |error_message| {
        try putStringValue(allocator, &object, "errorMessage", error_message);
    }
    try putIntegerValue(allocator, &object, "timestamp", assistant.timestamp);
    return .{ .object = object };
}

fn toolResultToJson(allocator: std.mem.Allocator, tool_result: types.ToolResultMessage) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putStringValue(allocator, &object, "role", "toolResult");
    try putStringValue(allocator, &object, "toolCallId", tool_result.tool_call_id);
    try putStringValue(allocator, &object, "toolName", tool_result.tool_name);
    try putObjectValue(allocator, &object, "content", try contentBlocksToJson(allocator, tool_result.content));
    if (tool_result.details) |details| {
        try putObjectValue(allocator, &object, "details", try provider_json.cloneValue(allocator, details));
    }
    if (tool_result.added_tool_names) |names| {
        var names_array = std.json.Array.init(allocator);
        errdefer {
            for (names_array.items) |item| provider_json.freeValue(allocator, item);
            names_array.deinit();
        }
        for (names) |name| {
            try names_array.append(.{ .string = try allocator.dupe(u8, name) });
        }
        try putObjectValue(allocator, &object, "addedToolNames", .{ .array = names_array });
    }
    try putBoolValue(allocator, &object, "isError", tool_result.is_error);
    try putIntegerValue(allocator, &object, "timestamp", tool_result.timestamp);
    return .{ .object = object };
}

fn contentBlocksToJson(allocator: std.mem.Allocator, content: []const types.ContentBlock) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |item| provider_json.freeValue(allocator, item);
        array.deinit();
    }
    for (content) |block| {
        try array.append(try contentBlockToJson(allocator, block));
    }
    return .{ .array = array };
}

fn contentBlockToJson(allocator: std.mem.Allocator, block: types.ContentBlock) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    switch (block) {
        .text => |text| {
            try putStringValue(allocator, &object, "type", "text");
            try putStringValue(allocator, &object, "text", text.text);
            if (text.text_signature) |signature| {
                try putStringValue(allocator, &object, "textSignature", signature);
            }
        },
        .image => |image| {
            try putStringValue(allocator, &object, "type", "image");
            try putStringValue(allocator, &object, "data", image.data);
            try putStringValue(allocator, &object, "mimeType", image.mime_type);
        },
        .thinking => |thinking| {
            try putStringValue(allocator, &object, "type", "thinking");
            try putStringValue(allocator, &object, "thinking", thinking.thinking);
            if (types.thinkingSignature(thinking)) |signature| {
                try putStringValue(allocator, &object, "thinkingSignature", signature);
            }
            if (thinking.redacted) {
                try putBoolValue(allocator, &object, "redacted", true);
            }
        },
        .tool_call => |tool_call| {
            provider_json.freeValue(allocator, .{ .object = object });
            return try toolCallToJson(allocator, tool_call);
        },
    }
    return .{ .object = object };
}

fn toolCallToJson(allocator: std.mem.Allocator, tool_call: types.ToolCall) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putStringValue(allocator, &object, "type", "toolCall");
    try putStringValue(allocator, &object, "id", tool_call.id);
    try putStringValue(allocator, &object, "name", tool_call.name);
    try putObjectValue(allocator, &object, "arguments", try provider_json.cloneValue(allocator, tool_call.arguments));
    if (tool_call.thought_signature) |signature| {
        try putStringValue(allocator, &object, "thoughtSignature", signature);
    }
    if (tool_call.namespace) |namespace| {
        try putStringValue(allocator, &object, "namespace", namespace);
    }
    return .{ .object = object };
}

fn toolToJson(allocator: std.mem.Allocator, tool: types.Tool) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putStringValue(allocator, &object, "name", tool.name);
    try putStringValue(allocator, &object, "description", tool.description);
    try putObjectValue(allocator, &object, "parameters", try provider_json.cloneValue(allocator, tool.parameters));
    if (tool.constrained_sampling) |sampling| {
        try putObjectValue(allocator, &object, "constrainedSampling", try constrainedSamplingToJson(allocator, sampling));
    }
    return .{ .object = object };
}

fn constrainedSamplingToJson(allocator: std.mem.Allocator, sampling: types.ConstrainedSamplingConfig) !std.json.Value {
    return switch (sampling) {
        .disabled => .{ .bool = false },
        .json_schema => |config| blk: {
            var object = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = object });
            try putStringValue(allocator, &object, "type", "json_schema");
            try putStringValue(allocator, &object, "strict", @tagName(config.strict));
            break :blk .{ .object = object };
        },
        .grammar => |config| blk: {
            var variants = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = variants });
            if (config.openai_lark) |value| try putStringValue(allocator, &variants, "openai_lark", value);
            if (config.openai_regex) |value| try putStringValue(allocator, &variants, "openai_regex", value);
            var object = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = object });
            try putStringValue(allocator, &object, "type", "grammar");
            try putObjectValue(allocator, &object, "variants", .{ .object = variants });
            break :blk .{ .object = object };
        },
    };
}

fn usageToJson(allocator: std.mem.Allocator, usage: types.Usage) !std.json.Value {
    var cost = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = cost });
    try putFloatValue(allocator, &cost, "input", usage.cost.input);
    try putFloatValue(allocator, &cost, "output", usage.cost.output);
    try putFloatValue(allocator, &cost, "cacheRead", usage.cost.cache_read);
    try putFloatValue(allocator, &cost, "cacheWrite", usage.cost.cache_write);
    try putFloatValue(allocator, &cost, "total", usage.cost.total);

    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putIntegerValue(allocator, &object, "input", usage.input);
    try putIntegerValue(allocator, &object, "output", usage.output);
    try putIntegerValue(allocator, &object, "cacheRead", usage.cache_read);
    try putIntegerValue(allocator, &object, "cacheWrite", usage.cache_write);
    try putIntegerValue(allocator, &object, "totalTokens", usage.total_tokens);
    try putObjectValue(allocator, &object, "cost", .{ .object = cost });
    return .{ .object = object };
}

fn parseToolCall(allocator: std.mem.Allocator, value: std.json.Value) !types.ToolCall {
    if (value != .object) return error.InvalidPiMessagesEvent;
    const object = value.object;
    return .{
        .id = try allocator.dupe(u8, jsonString(object, "id") orelse ""),
        .name = try allocator.dupe(u8, jsonString(object, "name") orelse ""),
        .arguments = if (object.get("arguments")) |arguments|
            try provider_json.cloneValue(allocator, arguments)
        else
            try provider_json.emptyObjectValue(allocator),
        .thought_signature = if (jsonString(object, "thoughtSignature")) |signature|
            try allocator.dupe(u8, signature)
        else
            null,
        .namespace = if (jsonString(object, "namespace")) |namespace|
            try allocator.dupe(u8, namespace)
        else
            null,
    };
}

fn parseUsage(value: std.json.Value) types.Usage {
    var usage = types.Usage.init();
    if (value != .object) return usage;
    usage.input = jsonU32(value.object, "input");
    usage.output = jsonU32(value.object, "output");
    usage.cache_read = jsonU32(value.object, "cacheRead");
    usage.cache_write = jsonU32(value.object, "cacheWrite");
    usage.total_tokens = jsonU32(value.object, "totalTokens");
    if (value.object.get("cost")) |cost_value| {
        if (cost_value == .object) {
            usage.cost.input = jsonF64(cost_value.object, "input");
            usage.cost.output = jsonF64(cost_value.object, "output");
            usage.cost.cache_read = jsonF64(cost_value.object, "cacheRead");
            usage.cost.cache_write = jsonF64(cost_value.object, "cacheWrite");
            usage.cost.total = jsonF64(cost_value.object, "total");
        }
    }
    return usage;
}

fn parseStopReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "toolUse")) return .tool_use;
    if (std.mem.eql(u8, reason, "aborted")) return .aborted;
    return .error_reason;
}

fn stopReasonToString(reason: types.StopReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .error_reason => "error",
        .aborted => "aborted",
    };
}

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (input.len == 0) return provider_json.emptyObjectValue(allocator);
    var parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return provider_json.emptyObjectValue(allocator);
    };
    defer parsed.deinit();
    return try provider_json.cloneValue(allocator, parsed.value);
}

fn requireContentIndex(object: std.json.ObjectMap) !u32 {
    return jsonU32Optional(object, "contentIndex") orelse error.InvalidPiMessagesEvent;
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |flag| flag,
        else => false,
    };
}

fn jsonU32(object: std.json.ObjectMap, key: []const u8) u32 {
    return jsonU32Optional(object, key) orelse 0;
}

fn jsonU32Optional(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| std.math.cast(u32, number),
        .float => |number| std.math.cast(u32, @as(i64, @intFromFloat(number))),
        else => null,
    };
}

fn jsonF64(object: std.json.ObjectMap, key: []const u8) f64 {
    const value = object.get(key) orelse return 0;
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => 0,
    };
}

fn httpStatusText(status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Error",
    };
}

fn pushPlainError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    error_message: []u8,
    stop_reason: types.StopReason,
) !void {
    _ = allocator;
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = stop_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = message,
    });
    stream_ptr.end(message);
}

fn pushHttpResponseError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    url: []const u8,
    status: u16,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch null;
    defer if (parsed) |*value| value.deinit();

    const error_object = if (parsed) |value|
        if (value.value == .object) value.value.object.get("error") else null
    else
        null;
    const error_fields = if (error_object) |value|
        if (value == .object) value.object else null
    else
        null;
    const parsed_message = if (error_fields) |object| jsonString(object, "message") else null;
    const parsed_code = if (error_fields) |object| jsonString(object, "code") else null;
    const message_text = parsed_message orelse body;
    const truncated = if (message_text.len > 8192) message_text[0..8192] else message_text;
    const error_message = if (parsed_code) |code|
        try std.fmt.allocPrint(allocator, "{d} {s}: {s} ({s})", .{ status, httpStatusText(status), truncated, code })
    else
        try std.fmt.allocPrint(allocator, "{d} {s}: {s}", .{ status, httpStatusText(status), truncated });
    errdefer allocator.free(error_message);

    var details = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = details });
    try putIntegerValue(allocator, &details, "version", @as(i64, 1));
    try putStringValue(allocator, &details, "provider", model.provider);
    try putStringValue(allocator, &details, "model", model.id);
    try putStringValue(allocator, &details, "url", url);
    try putIntegerValue(allocator, &details, "status", status);
    try putStringValue(allocator, &details, "statusText", httpStatusText(status));
    if (error_object) |raw| {
        try putObjectValue(allocator, &details, "error", try provider_json.cloneValue(allocator, raw));
    } else {
        try putStringValue(allocator, &details, "body", truncated);
    }

    var message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
    const diagnostic = types.AssistantMessageDiagnostic{
        .type = try allocator.dupe(u8, "pi_messages_response_failure"),
        .timestamp = 0,
        .error_info = .{
            .name = try allocator.dupe(u8, "PiMessagesResponseError"),
            .message = try allocator.dupe(u8, error_message),
        },
        .details = .{ .object = details },
    };
    try diagnostics_helper.appendAssistantMessageDiagnostic(allocator, &message, diagnostic);

    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = message,
    });
    stream_ptr.end(message);
}

fn testModel(base_url: []const u8) types.Model {
    return .{
        .id = "auto",
        .name = "Radius Auto",
        .api = "pi-messages",
        .provider = "radius",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 16384,
    };
}

fn testContext() types.Context {
    return .{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
}

const usage_sse =
    \\{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"cost":{"input":0.1,"output":0.2,"cacheRead":0,"cacheWrite":0,"total":0.3}}
;

fn drainTerminal(allocator: std.mem.Allocator, stream: *event_stream.AssistantMessageEventStream) !types.AssistantMessage {
    var last: ?types.AssistantMessage = null;
    while (stream.next()) |event| {
        event.deinitTransient(allocator);
        if (event.event_type == .done or event.event_type == .error_event) {
            last = event.message;
        }
    }
    return last orelse error.MissingTerminalEvent;
}

test "buildMessagesUrl strips trailing slashes and appends debug" {
    const allocator = std.testing.allocator;
    const plain = try buildMessagesUrl(allocator, "http://127.0.0.1:1/v1/", false);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/v1/messages", plain);

    const debug = try buildMessagesUrl(allocator, "http://127.0.0.1:1/v1", true);
    defer allocator.free(debug);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/v1/messages?debug=1", debug);
}

test "buildRequestPayload serializes context and camelCase options" {
    const allocator = std.testing.allocator;
    var payload = try buildRequestPayload(
        allocator,
        testModel("http://127.0.0.1:1/v1"),
        testContext(),
        .{
            .max_tokens = 100,
            .session_id = "session-1",
            .provider = .{
                .pi_messages = .{
                    .tool_choice = .{ .string = "auto" },
                },
            },
        },
    );
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expectEqualStrings("auto", payload.object.get("model").?.string);
    const context_value = payload.object.get("context").?.object;
    try std.testing.expectEqual(@as(usize, 1), context_value.get("messages").?.array.items.len);
    try std.testing.expectEqualStrings("Hello", context_value.get("messages").?.array.items[0].object.get("content").?.string);
    const options_value = payload.object.get("options").?.object;
    try std.testing.expectEqual(@as(i64, 100), options_value.get("maxTokens").?.integer);
    try std.testing.expectEqualStrings("session-1", options_value.get("sessionId").?.string);
    try std.testing.expectEqualStrings("auto", options_value.get("toolChoice").?.string);
}

test "stream text and tool calls and resolve the terminal message" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sse =
        "data: {\"type\":\"start\"}\n\n" ++
        "data: {\"type\":\"text_start\",\"contentIndex\":0}\n\n" ++
        "data: {\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"Hel\"}\n\n" ++
        "data: {\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"lo\"}\n\n" ++
        "data: {\"type\":\"text_end\",\"contentIndex\":0,\"content\":\"Hello\"}\n\n" ++
        "data: {\"type\":\"toolcall_start\",\"contentIndex\":1,\"id\":\"call_1\",\"toolName\":\"read\"}\n\n" ++
        "data: {\"type\":\"toolcall_delta\",\"contentIndex\":1,\"delta\":\"{\\\"path\\\":\"}\n\n" ++
        "data: {\"type\":\"toolcall_delta\",\"contentIndex\":1,\"delta\":\"\\\"a.txt\\\"}\"}\n\n" ++
        "data: {\"type\":\"toolcall_end\",\"contentIndex\":1,\"toolCall\":{\"type\":\"toolCall\",\"id\":\"call_1\",\"name\":\"read\",\"arguments\":{\"path\":\"a.txt\"}}}\n\n" ++
        "data: {\"type\":\"done\",\"reason\":\"toolUse\",\"usage\":" ++ usage_sse ++ ",\"responseId\":\"resp_1\"}\n\n";

    var server = try test_stream_server.DelayedChunkServer.init(io, &.{.{ .bytes = sse }});
    defer server.deinit();
    try server.start();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var extra_headers = std.StringHashMap([]const u8).init(allocator);
    defer extra_headers.deinit();
    try extra_headers.put("x-custom", "1");

    var stream = try PiMessagesProvider.stream(
        allocator,
        io,
        testModel(base_url),
        testContext(),
        .{
            .api_key = "test-key",
            .session_id = "session-1",
            .max_tokens = 100,
            .headers = extra_headers,
            .provider = .{ .pi_messages = .{ .tool_choice = .{ .string = "auto" } } },
        },
    );
    defer stream.deinit();

    var saw_text_delta = false;
    var toolcall_ends: usize = 0;
    var message: ?types.AssistantMessage = null;
    while (stream.next()) |event| {
        event.deinitTransient(allocator);
        if (event.event_type == .text_delta) saw_text_delta = true;
        if (event.event_type == .toolcall_end) toolcall_ends += 1;
        if (event.event_type == .done) message = event.message;
    }

    const result = message orelse return error.MissingTerminalEvent;
    defer types.freeAssistantMessage(allocator, result);
    try std.testing.expect(saw_text_delta);
    try std.testing.expectEqual(@as(usize, 1), toolcall_ends);
    try std.testing.expectEqual(types.StopReason.tool_use, result.stop_reason);
    try std.testing.expectEqualStrings("resp_1", result.response_id.?);
    try std.testing.expectEqualStrings("auto", result.model);
    try std.testing.expectEqualStrings("radius", result.provider);
    try std.testing.expectEqual(@as(usize, 2), result.content.len);
    try std.testing.expectEqualStrings("Hello", result.content[0].text.text);
    try std.testing.expectEqualStrings("call_1", result.content[1].tool_call.id);
    try std.testing.expectEqualStrings("read", result.content[1].tool_call.name);
    try std.testing.expectEqualStrings("a.txt", result.content[1].tool_call.arguments.object.get("path").?.string);
    try std.testing.expectEqual(@as(u32, 10), result.usage.input);
    try std.testing.expectEqual(@as(u32, 5), result.usage.output);
}

test "streamSimple debug query and on_response headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sse = "data: {\"type\":\"done\",\"reason\":\"stop\",\"usage\":" ++ usage_sse ++ "}\n\n";
    var server = try provider_error.TestCaptureServer.init(
        io,
        200,
        "OK",
        "x-pi-gateway-upstream-provider: anthropic\r\n",
        sse,
    );
    defer server.deinit();
    try server.start();
    const host = try server.url(allocator);
    defer allocator.free(host);
    const base_url = try std.fmt.allocPrint(allocator, "{s}/v1", .{host});
    defer allocator.free(base_url);

    const Observe = struct {
        var seen: bool = false;
        fn callback(_: u16, headers: std.StringHashMap([]const u8), _: types.Model) anyerror!void {
            seen = headers.get("x-pi-gateway-upstream-provider") != null and
                std.mem.eql(u8, headers.get("x-pi-gateway-upstream-provider").?, "anthropic");
        }
    };
    Observe.seen = false;

    var stream = try PiMessagesProvider.streamSimple(
        allocator,
        io,
        testModel(base_url),
        testContext(),
        .{
            .api_key = "test-key",
            .on_response = &Observe.callback,
            .provider = .{ .pi_messages = .{ .debug = true } },
        },
    );
    defer stream.deinit();
    const message = try drainTerminal(allocator, &stream);
    defer types.freeAssistantMessage(allocator, message);
    try std.testing.expectEqual(types.StopReason.stop, message.stop_reason);
    try std.testing.expect(Observe.seen);
    try std.testing.expect(std.mem.indexOf(u8, server.requestHead(), "/v1/messages?debug=1") != null);
}

test "HTTP error responses attach pi_messages_response_failure diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var server = try provider_error.TestStatusServer.init(
        io,
        401,
        "Unauthorized",
        "",
        "{\"error\":{\"message\":\"Token expired\",\"code\":\"unauthorized\"}}",
    );
    defer server.deinit();
    try server.start();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var stream = try PiMessagesProvider.stream(
        allocator,
        io,
        testModel(base_url),
        testContext(),
        .{ .api_key = "stale" },
    );
    defer stream.deinit();
    const message = try drainTerminal(allocator, &stream);
    defer types.freeAssistantMessage(allocator, message);
    try std.testing.expectEqual(types.StopReason.error_reason, message.stop_reason);
    try std.testing.expect(std.mem.indexOf(u8, message.error_message.?, "401") != null);
    try std.testing.expect(std.mem.indexOf(u8, message.error_message.?, "Token expired") != null);
    try std.testing.expect(std.mem.indexOf(u8, message.error_message.?, "unauthorized") != null);
    try std.testing.expectEqualStrings("pi_messages_response_failure", message.diagnostics.?[0].type);
    try std.testing.expectEqual(@as(i64, 401), message.diagnostics.?[0].details.?.object.get("status").?.integer);
}

test "server-sent error events become terminal errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sse =
        "data: {\"type\":\"start\"}\n\n" ++
        "data: {\"type\":\"error\",\"reason\":\"error\",\"usage\":" ++ usage_sse ++ ",\"errorMessage\":\"Upstream failed\"}\n\n";
    var server = try test_stream_server.DelayedChunkServer.init(io, &.{.{ .bytes = sse }});
    defer server.deinit();
    try server.start();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var stream = try PiMessagesProvider.stream(
        allocator,
        io,
        testModel(base_url),
        testContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();
    const message = try drainTerminal(allocator, &stream);
    defer types.freeAssistantMessage(allocator, message);
    try std.testing.expectEqual(types.StopReason.error_reason, message.stop_reason);
    try std.testing.expectEqualStrings("Upstream failed", message.error_message.?);
    try std.testing.expectEqual(@as(u32, 10), message.usage.input);
}

test "VAL-M9-STREAM-006 missing api key returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    var stream = try PiMessagesProvider.stream(
        allocator,
        std.Io.failing,
        testModel("http://127.0.0.1:1/v1"),
        testContext(),
        null,
    );
    defer stream.deinit();
    const message = try drainTerminal(allocator, &stream);
    defer types.freeAssistantMessage(allocator, message);
    try std.testing.expectEqual(types.StopReason.error_reason, message.stop_reason);
    try std.testing.expect(std.mem.indexOf(u8, message.error_message.?, "No API key for provider: radius") != null);
}

test "stream ended without a terminal event becomes an error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sse =
        "data: {\"type\":\"start\"}\n\n" ++
        "data: {\"type\":\"text_start\",\"contentIndex\":0}\n\n" ++
        "data: {\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"partial\"}\n\n";
    var server = try test_stream_server.DelayedChunkServer.init(io, &.{.{ .bytes = sse }});
    defer server.deinit();
    try server.start();
    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    var stream = try PiMessagesProvider.stream(
        allocator,
        io,
        testModel(base_url),
        testContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();
    const message = try drainTerminal(allocator, &stream);
    defer types.freeAssistantMessage(allocator, message);
    try std.testing.expectEqual(types.StopReason.error_reason, message.stop_reason);
    try std.testing.expect(std.mem.indexOf(u8, message.error_message.?, "stream ended without a terminal event") != null);
}
