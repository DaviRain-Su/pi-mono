const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const common = @import("../tools/common.zig");

pub const protocol_version = "2025-11-25";

pub const ConfigError = error{
    InvalidMcpConfig,
};

pub const ProtocolError = error{
    UnsupportedMcpServer,
    InvalidJsonRpcResponse,
    McpJsonRpcError,
    McpToolError,
    McpTransportEof,
    McpTransportTimeout,
    McpChildExited,
};

pub const TransportKind = enum {
    stdio,
    http,
    sse,
    unknown,
};

pub const ServerStatus = enum {
    operational,
    unsupported_transport,
    unsupported_capability,
    invalid,
};

pub const EnvEntry = struct {
    key: []u8,
    value: []u8,

    fn clone(self: EnvEntry, allocator: std.mem.Allocator) !EnvEntry {
        return .{
            .key = try allocator.dupe(u8, self.key),
            .value = try allocator.dupe(u8, self.value),
        };
    }

    fn deinit(self: EnvEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const ServerDefinition = struct {
    name: []u8,
    transport: TransportKind = .stdio,
    status: ServerStatus = .operational,
    command: ?[]u8 = null,
    args: []const []u8 = &.{},
    env: []const EnvEntry = &.{},
    unsupported_detail: ?[]u8 = null,

    pub fn isOperational(self: *const ServerDefinition) bool {
        return self.transport == .stdio and self.status == .operational and self.command != null;
    }

    fn clone(self: ServerDefinition, allocator: std.mem.Allocator) !ServerDefinition {
        var args = try allocator.alloc([]u8, self.args.len);
        errdefer {
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
        }
        for (self.args, 0..) |arg, index| {
            args[index] = try allocator.dupe(u8, arg);
        }

        var env = try allocator.alloc(EnvEntry, self.env.len);
        errdefer {
            for (env) |entry| entry.deinit(allocator);
            allocator.free(env);
        }
        for (self.env, 0..) |entry, index| {
            env[index] = try entry.clone(allocator);
        }

        return .{
            .name = try allocator.dupe(u8, self.name),
            .transport = self.transport,
            .status = self.status,
            .command = if (self.command) |command| try allocator.dupe(u8, command) else null,
            .args = args,
            .env = env,
            .unsupported_detail = if (self.unsupported_detail) |detail| try allocator.dupe(u8, detail) else null,
        };
    }

    fn deinit(self: *ServerDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.command) |command| allocator.free(command);
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
        for (self.env) |entry| entry.deinit(allocator);
        allocator.free(self.env);
        if (self.unsupported_detail) |detail| allocator.free(detail);
        self.* = undefined;
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    servers: []ServerDefinition,

    pub fn deinit(self: *Config) void {
        for (self.servers) |*server| server.deinit(self.allocator);
        self.allocator.free(self.servers);
        self.* = undefined;
    }
};

pub fn parseConfigContent(allocator: std.mem.Allocator, content: []const u8) !Config {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return ConfigError.InvalidMcpConfig;
    defer parsed.deinit();
    return parseConfigValue(allocator, parsed.value);
}

pub fn parseConfigValue(allocator: std.mem.Allocator, value: std.json.Value) !Config {
    if (value != .object) return ConfigError.InvalidMcpConfig;

    const servers_value = value.object.get("mcpServers") orelse value.object.get("mcp_servers") orelse value.object.get("servers") orelse return .{
        .allocator = allocator,
        .servers = try allocator.alloc(ServerDefinition, 0),
    };
    if (servers_value != .object) return ConfigError.InvalidMcpConfig;

    var servers = std.ArrayList(ServerDefinition).empty;
    errdefer {
        for (servers.items) |*server| server.deinit(allocator);
        servers.deinit(allocator);
    }

    var iterator = servers_value.object.iterator();
    while (iterator.next()) |entry| {
        try servers.append(allocator, try parseServerDeclaration(allocator, entry.key_ptr.*, entry.value_ptr.*));
    }

    return .{
        .allocator = allocator,
        .servers = try servers.toOwnedSlice(allocator),
    };
}

fn parseServerDeclaration(
    allocator: std.mem.Allocator,
    name: []const u8,
    value: std.json.Value,
) !ServerDefinition {
    if (value != .object) {
        return .{
            .name = try allocator.dupe(u8, name),
            .status = .invalid,
            .unsupported_detail = try allocator.dupe(u8, "server declaration must be an object"),
        };
    }

    const object = value.object;
    const transport = parseTransportKind(object);
    const status = statusForDeclaration(object, transport);
    const command = getStringField(object, "command");
    const args = try parseStringArray(allocator, object.get("args"));
    errdefer freeStringArray(allocator, args);
    const env = try parseEnvObject(allocator, object.get("env"));
    errdefer {
        for (env) |entry| entry.deinit(allocator);
        allocator.free(env);
    }

    var server = ServerDefinition{
        .name = try allocator.dupe(u8, name),
        .transport = transport,
        .status = status,
        .command = if (command) |command_value| try allocator.dupe(u8, command_value) else null,
        .args = args,
        .env = env,
        .unsupported_detail = try unsupportedDetail(allocator, object, transport, status),
    };

    if (server.status == .operational and server.command == null) {
        server.status = .invalid;
        server.unsupported_detail = try allocator.dupe(u8, "stdio MCP server requires a command");
    }

    return server;
}

fn parseTransportKind(object: std.json.ObjectMap) TransportKind {
    if (getStringField(object, "transport")) |transport| {
        if (std.ascii.eqlIgnoreCase(transport, "stdio")) return .stdio;
        if (std.ascii.eqlIgnoreCase(transport, "sse")) return .sse;
        if (std.ascii.eqlIgnoreCase(transport, "http") or
            std.ascii.eqlIgnoreCase(transport, "streamable-http") or
            std.ascii.eqlIgnoreCase(transport, "http-stream"))
        {
            return .http;
        }
        return .unknown;
    }

    if (getStringField(object, "url") != null) return .http;
    return .stdio;
}

fn statusForDeclaration(object: std.json.ObjectMap, transport: TransportKind) ServerStatus {
    if (transport != .stdio) return .unsupported_transport;
    if (hasDeferredCapability(object)) return .unsupported_capability;
    return .operational;
}

fn unsupportedDetail(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    transport: TransportKind,
    status: ServerStatus,
) !?[]u8 {
    return switch (status) {
        .operational => null,
        .unsupported_transport => switch (transport) {
            .http => try allocator.dupe(u8, "HTTP MCP transport is not supported by the native stdio slice"),
            .sse => try allocator.dupe(u8, "SSE MCP transport is not supported by the native stdio slice"),
            .unknown => try allocator.dupe(u8, "unknown MCP transport is not supported by the native stdio slice"),
            .stdio => try allocator.dupe(u8, "unsupported MCP transport"),
        },
        .unsupported_capability => try allocator.dupe(u8, deferredCapabilityName(object) orelse "deferred MCP capability is not supported"),
        .invalid => try allocator.dupe(u8, "invalid MCP server declaration"),
    };
}

fn hasDeferredCapability(object: std.json.ObjectMap) bool {
    return deferredCapabilityName(object) != null;
}

fn deferredCapabilityName(object: std.json.ObjectMap) ?[]const u8 {
    const names = [_][]const u8{ "resources", "prompts", "sampling", "progress", "auth", "authorization" };
    for (names) |name| {
        if (object.get(name)) |value| {
            if (isEnabledCapabilityValue(value)) return name;
        }
    }
    return null;
}

fn isEnabledCapabilityValue(value: std.json.Value) bool {
    return switch (value) {
        .bool => |enabled| enabled,
        .object => |object| object.count() > 0,
        .array => |array| array.items.len > 0,
        .string => |string| string.len > 0,
        .null => false,
        else => true,
    };
}

fn getStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn parseStringArray(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const []u8 {
    const array_value = value orelse return try allocator.alloc([]u8, 0);
    if (array_value != .array) return try allocator.alloc([]u8, 0);
    var items = std.ArrayList([]u8).empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }
    for (array_value.array.items) |item| {
        if (item == .string) try items.append(allocator, try allocator.dupe(u8, item.string));
    }
    return try items.toOwnedSlice(allocator);
}

const freeStringArray = @import("../slice_utils.zig").freeStringSlice;

fn parseEnvObject(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const EnvEntry {
    const object_value = value orelse return try allocator.alloc(EnvEntry, 0);
    if (object_value != .object) return try allocator.alloc(EnvEntry, 0);

    var items = std.ArrayList(EnvEntry).empty;
    errdefer {
        for (items.items) |entry| entry.deinit(allocator);
        items.deinit(allocator);
    }

    var iterator = object_value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* == .string) {
            try items.append(allocator, .{
                .key = try allocator.dupe(u8, entry.key_ptr.*),
                .value = try allocator.dupe(u8, entry.value_ptr.string),
            });
        }
    }
    return try items.toOwnedSlice(allocator);
}

pub const JsonRpcTransport = struct {
    context: ?*anyopaque = null,
    send: *const fn (context: ?*anyopaque, message: []const u8) anyerror!void,
    recv: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
};

const ToolCallState = struct {
    transport: JsonRpcTransport,
    next_id: i64 = 3,
};

const McpToolContext = struct {
    state: *ToolCallState,
    tool_name: []u8,

    fn deinit(self: *McpToolContext, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.* = undefined;
    }
};

pub const AgentToolSet = struct {
    allocator: std.mem.Allocator,
    items: []agent.AgentTool,
    call_state: ?*ToolCallState = null,
    tool_contexts: []?*McpToolContext,

    pub fn deinit(self: *AgentToolSet) void {
        for (self.items) |tool| {
            self.allocator.free(tool.name);
            self.allocator.free(tool.description);
            self.allocator.free(tool.label);
            common.deinitJsonValue(self.allocator, tool.parameters);
        }
        for (self.tool_contexts) |context| {
            if (context) |tool_context| {
                tool_context.deinit(self.allocator);
                self.allocator.destroy(tool_context);
            }
        }
        self.allocator.free(self.tool_contexts);
        if (self.call_state) |state| self.allocator.destroy(state);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const StdioClientOptions = struct {
    response_timeout_ms: u64 = 1000,
    shutdown_timeout_ms: u64 = 1000,
};

pub const StdioClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    wait_thread: ?std.Thread = null,
    wait_done: std.atomic.Value(bool) = .init(false),
    term: ?std.process.Child.Term = null,
    wait_err: ?anyerror = null,
    response_timeout_ms: u64,
    shutdown_timeout_ms: u64,

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: *const ServerDefinition,
        options: StdioClientOptions,
    ) !*StdioClient {
        if (!server.isOperational()) return ProtocolError.UnsupportedMcpServer;
        const command = server.command.?;
        var argv = try allocator.alloc([]const u8, server.args.len + 1);
        defer allocator.free(argv);
        argv[0] = command;
        for (server.args, 0..) |arg, index| argv[index + 1] = arg;
        return startArgv(allocator, io, argv, options);
    }

    fn startArgv(
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        options: StdioClientOptions,
    ) !*StdioClient {
        const client = try allocator.create(StdioClient);
        errdefer allocator.destroy(client);

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = if (@import("builtin").os.tag == .windows) null else 0,
        });
        errdefer if (child.id != null) child.kill(io);

        const stdin_file = child.stdin.?;
        child.stdin = null;
        const stdout_file = child.stdout.?;
        child.stdout = null;

        client.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .response_timeout_ms = options.response_timeout_ms,
            .shutdown_timeout_ms = options.shutdown_timeout_ms,
        };
        client.wait_thread = try std.Thread.spawn(.{}, stdioWaitMain, .{client});
        return client;
    }

    pub fn deinit(self: *StdioClient) void {
        self.shutdown() catch {};
        self.allocator.destroy(self);
    }

    pub fn shutdown(self: *StdioClient) !void {
        if (self.stdin_file) |file| {
            file.close(self.io);
            self.stdin_file = null;
        }

        var elapsed: u64 = 0;
        while (!self.wait_done.load(.seq_cst) and elapsed <= self.shutdown_timeout_ms) : (elapsed += 10) {
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        }
        if (!self.wait_done.load(.seq_cst)) self.killProcessGroup();
        if (self.wait_thread) |thread| {
            thread.join();
            self.wait_thread = null;
        }
        if (self.stdout_file) |file| {
            file.close(self.io);
            self.stdout_file = null;
        }
    }

    pub fn hasExited(self: *const StdioClient) bool {
        return self.wait_done.load(.seq_cst);
    }

    pub fn transport(self: *StdioClient) JsonRpcTransport {
        return .{
            .context = self,
            .send = stdioSend,
            .recv = stdioRecv,
        };
    }

    fn killProcessGroup(self: *StdioClient) void {
        if (self.child.id) |pid| {
            if (@import("builtin").os.tag == .windows) {
                _ = std.os.windows.ntdll.NtTerminateProcess(pid, @enumFromInt(@as(u32, 1)));
            } else {
                std.posix.kill(-pid, .TERM) catch {};
                std.posix.kill(-pid, .KILL) catch {};
            }
        }
    }

    fn sendMessage(self: *StdioClient, message: []const u8) !void {
        const file = self.stdin_file orelse return ProtocolError.McpChildExited;
        try file.writeStreamingAll(self.io, message);
        try file.writeStreamingAll(self.io, "\n");
    }

    fn recvMessage(self: *StdioClient, allocator: std.mem.Allocator) ![]u8 {
        const file = self.stdout_file orelse return ProtocolError.McpTransportEof;

        if (@import("builtin").os.tag == .windows) {
            // Windows: use WaitForSingleObject for timeout + File reader for I/O
            var line = std.ArrayList(u8).empty;
            defer line.deinit(allocator);
            var elapsed: u64 = 0;
            while (elapsed <= self.response_timeout_ms) : (elapsed += 10) {
                // Check if data is available
                const timeout_us: std.os.windows.LARGE_INTEGER = -@as(i64, 10) * 10000; // 10ms
                _ = std.os.windows.ntdll.NtWaitForSingleObject(file.handle, .FALSE, &timeout_us);

                if (self.wait_done.load(.seq_cst)) return if (line.items.len == 0) ProtocolError.McpChildExited else ProtocolError.McpTransportEof;

                var buffer: [1024]u8 = undefined;
                const bytes_read = file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                    error.EndOfStream => return if (line.items.len == 0) ProtocolError.McpChildExited else ProtocolError.McpTransportEof,
                    else => |read_err| return read_err,
                };
                if (bytes_read == 0) {
                    std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
                    continue;
                }
                if (std.mem.indexOfScalar(u8, buffer[0..bytes_read], '\n')) |newline_index| {
                    try line.appendSlice(allocator, buffer[0..newline_index]);
                    const raw = line.items;
                    const trimmed = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
                    return try allocator.dupe(u8, trimmed);
                }
                try line.appendSlice(allocator, buffer[0..bytes_read]);
            }
            return ProtocolError.McpTransportTimeout;
        }

        // POSIX: use fcntl for non-blocking I/O
        const fd = file.handle;
        const previous_flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        if (previous_flags == -1) return ProtocolError.McpTransportEof;
        const nonblock_mask: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
        _ = std.c.fcntl(fd, std.c.F.SETFL, previous_flags | @as(c_int, @intCast(nonblock_mask)));
        defer _ = std.c.fcntl(fd, std.c.F.SETFL, previous_flags);

        var line = std.ArrayList(u8).empty;
        defer line.deinit(allocator);
        var elapsed: u64 = 0;
        while (elapsed <= self.response_timeout_ms) : (elapsed += 10) {
            var buffer: [1024]u8 = undefined;
            const bytes_read = std.posix.read(fd, &buffer) catch |err| switch (err) {
                error.WouldBlock => {
                    if (self.wait_done.load(.seq_cst)) return if (line.items.len == 0) ProtocolError.McpChildExited else ProtocolError.McpTransportEof;
                    std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
                    continue;
                },
                else => return err,
            };
            if (bytes_read == 0) {
                return if (line.items.len == 0) ProtocolError.McpTransportEof else ProtocolError.InvalidJsonRpcResponse;
            }
            if (std.mem.indexOfScalar(u8, buffer[0..bytes_read], '\n')) |newline_index| {
                try line.appendSlice(allocator, buffer[0..newline_index]);
                const raw = line.items;
                const trimmed = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
                return try allocator.dupe(u8, trimmed);
            }
            try line.appendSlice(allocator, buffer[0..bytes_read]);
        }
        return ProtocolError.McpTransportTimeout;
    }
};

fn stdioWaitMain(client: *StdioClient) void {
    client.term = client.child.wait(client.io) catch |err| {
        client.wait_err = err;
        client.wait_done.store(true, .seq_cst);
        return;
    };
    client.wait_done.store(true, .seq_cst);
}

fn stdioSend(context: ?*anyopaque, message: []const u8) !void {
    const client: *StdioClient = @ptrCast(@alignCast(context.?));
    try client.sendMessage(message);
}

fn stdioRecv(context: ?*anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const client: *StdioClient = @ptrCast(@alignCast(context.?));
    return try client.recvMessage(allocator);
}

pub fn discoverAgentTools(
    allocator: std.mem.Allocator,
    server: *const ServerDefinition,
    transport: *JsonRpcTransport,
) !AgentToolSet {
    if (!server.isOperational()) return ProtocolError.UnsupportedMcpServer;

    try transport.send(transport.context, initialize_request);
    const initialize_response = try transport.recv(transport.context, allocator);
    defer allocator.free(initialize_response);
    try expectResponseEnvelope(allocator, initialize_response, 1);

    try transport.send(transport.context, initialized_notification);

    try transport.send(transport.context, tools_list_request);
    const tools_response = try transport.recv(transport.context, allocator);
    defer allocator.free(tools_response);
    return parseToolsListResponse(allocator, tools_response, transport);
}

pub const initialize_request =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"pi-zig\",\"version\":\"0.0.0\"}}}";

pub const initialized_notification =
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}";

pub const tools_list_request =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}";

fn buildToolsCallRequest(allocator: std.mem.Allocator, request_id: i64, tool_name: []const u8, args: std.json.Value) ![]u8 {
    const encoded_name = try std.json.Stringify.valueAlloc(allocator, tool_name, .{});
    defer allocator.free(encoded_name);
    const encoded_args = try std.json.Stringify.valueAlloc(allocator, args, .{});
    defer allocator.free(encoded_args);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"tools/call\",\"params\":{{\"name\":{s},\"arguments\":{s}}}}}",
        .{ request_id, encoded_name, encoded_args },
    );
}

fn executeMcpTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    if (signal) |abort_signal| {
        if (abort_signal.load(.seq_cst)) return error.RequestAborted;
    }

    const context: *McpToolContext = @ptrCast(@alignCast(tool_context.?));
    const request_id = context.state.next_id;
    context.state.next_id += 1;
    const request = try buildToolsCallRequest(allocator, request_id, context.tool_name, params);
    defer allocator.free(request);
    try context.state.transport.send(context.state.transport.context, request);
    const response = try context.state.transport.recv(context.state.transport.context, allocator);
    defer allocator.free(response);
    return try parseToolCallResponse(allocator, response, request_id);
}

fn parseToolCallResponse(allocator: std.mem.Allocator, message: []const u8, expected_id: i64) !agent.AgentToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch return ProtocolError.InvalidJsonRpcResponse;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return ProtocolError.InvalidJsonRpcResponse,
    };
    try validateJsonRpcResponseObject(object, expected_id);

    const result = object.get("result") orelse return ProtocolError.InvalidJsonRpcResponse;
    if (result != .object) return ProtocolError.InvalidJsonRpcResponse;
    if (result.object.get("isError")) |is_error| {
        if (is_error == .bool and is_error.bool) return ProtocolError.McpToolError;
    }
    const content_value = result.object.get("content") orelse return ProtocolError.InvalidJsonRpcResponse;
    if (content_value != .array) return ProtocolError.InvalidJsonRpcResponse;

    var blocks = std.ArrayList(ai.ContentBlock).empty;
    errdefer {
        for (blocks.items) |block| {
            switch (block) {
                .text => |text| allocator.free(text.text),
                else => {},
            }
        }
        blocks.deinit(allocator);
    }

    for (content_value.array.items) |item| {
        const text = try textForMcpContentItem(allocator, item);
        errdefer allocator.free(text);
        try blocks.append(allocator, .{ .text = .{ .text = text } });
    }

    return .{
        .content = try blocks.toOwnedSlice(allocator),
        .details = null,
    };
}

fn textForMcpContentItem(allocator: std.mem.Allocator, item: std.json.Value) ![]u8 {
    if (item == .object) {
        if (getStringField(item.object, "type")) |content_type| {
            if (std.mem.eql(u8, content_type, "text")) {
                const text = getStringField(item.object, "text") orelse "";
                return try allocator.dupe(u8, text);
            }
            return try std.fmt.allocPrint(allocator, "[Unsupported MCP content type: {s}]", .{content_type});
        }
    }
    return try allocator.dupe(u8, "[Unsupported MCP content item]");
}

fn expectResponseEnvelope(allocator: std.mem.Allocator, message: []const u8, expected_id: i64) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch return ProtocolError.InvalidJsonRpcResponse;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return ProtocolError.InvalidJsonRpcResponse,
    };
    try validateJsonRpcResponseObject(object, expected_id);
    if (object.get("result") == null) return ProtocolError.InvalidJsonRpcResponse;
}

fn parseToolsListResponse(allocator: std.mem.Allocator, message: []const u8, transport: *JsonRpcTransport) !AgentToolSet {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch return ProtocolError.InvalidJsonRpcResponse;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return ProtocolError.InvalidJsonRpcResponse,
    };
    try validateJsonRpcResponseObject(object, 2);

    const result = object.get("result") orelse return ProtocolError.InvalidJsonRpcResponse;
    if (result != .object) return ProtocolError.InvalidJsonRpcResponse;
    const tools_value = result.object.get("tools") orelse return ProtocolError.InvalidJsonRpcResponse;
    if (tools_value != .array) return ProtocolError.InvalidJsonRpcResponse;

    var tools = std.ArrayList(agent.AgentTool).empty;
    var tool_contexts = std.ArrayList(?*McpToolContext).empty;
    const call_state = try allocator.create(ToolCallState);
    call_state.* = .{ .transport = transport.* };
    errdefer {
        for (tools.items) |tool| {
            allocator.free(tool.name);
            allocator.free(tool.description);
            allocator.free(tool.label);
            common.deinitJsonValue(allocator, tool.parameters);
        }
        tools.deinit(allocator);
        for (tool_contexts.items) |context| {
            if (context) |tool_context| {
                tool_context.deinit(allocator);
                allocator.destroy(tool_context);
            }
        }
        tool_contexts.deinit(allocator);
        allocator.destroy(call_state);
    }

    for (tools_value.array.items) |tool_value| {
        if (tool_value != .object) return ProtocolError.InvalidJsonRpcResponse;
        const name = getStringField(tool_value.object, "name") orelse return ProtocolError.InvalidJsonRpcResponse;
        const description = getStringField(tool_value.object, "description") orelse "";
        const schema = if (tool_value.object.get("inputSchema") orelse tool_value.object.get("input_schema")) |input_schema|
            try common.cloneJsonValue(allocator, input_schema)
        else
            try defaultInputSchema(allocator);
        errdefer common.deinitJsonValue(allocator, schema);
        const context = try allocator.create(McpToolContext);
        errdefer allocator.destroy(context);
        context.* = .{
            .state = call_state,
            .tool_name = try allocator.dupe(u8, name),
        };
        errdefer context.deinit(allocator);
        try tools.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .label = try allocator.dupe(u8, name),
            .parameters = schema,
            .execute = executeMcpTool,
            .execute_context = context,
            .execution_mode = .sequential,
        });
        try tool_contexts.append(allocator, context);
    }

    return .{
        .allocator = allocator,
        .items = try tools.toOwnedSlice(allocator),
        .call_state = call_state,
        .tool_contexts = try tool_contexts.toOwnedSlice(allocator),
    };
}

fn validateJsonRpcResponseObject(object: std.json.ObjectMap, expected_id: i64) !void {
    if (object.get("error") != null) return ProtocolError.McpJsonRpcError;
    const jsonrpc = getStringField(object, "jsonrpc") orelse return ProtocolError.InvalidJsonRpcResponse;
    if (!std.mem.eql(u8, jsonrpc, "2.0")) return ProtocolError.InvalidJsonRpcResponse;
    const id = object.get("id") orelse return ProtocolError.InvalidJsonRpcResponse;
    if (id != .integer or id.integer != expected_id) return ProtocolError.InvalidJsonRpcResponse;
}

fn defaultInputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = object };
        common.deinitJsonValue(allocator, cleanup_value);
    }
    try common.putString(allocator, &object, "type", "object");
    return .{ .object = object };
}

fn findServer(config: *const Config, name: []const u8) ?*const ServerDefinition {
    for (config.servers) |*server| {
        if (std.mem.eql(u8, server.name, name)) return server;
    }
    return null;
}

fn findTool(tool_set: *const AgentToolSet, name: []const u8) ?agent.AgentTool {
    for (tool_set.items) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

const FakeTransport = struct {
    allocator: std.mem.Allocator,
    responses: []const []const u8,
    response_index: usize = 0,
    sent_methods: std.ArrayList([]u8) = .empty,
    sent_messages: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator, responses: []const []const u8) FakeTransport {
        return .{
            .allocator = allocator,
            .responses = responses,
        };
    }

    fn deinit(self: *FakeTransport) void {
        for (self.sent_methods.items) |method| self.allocator.free(method);
        self.sent_methods.deinit(self.allocator);
        for (self.sent_messages.items) |message| self.allocator.free(message);
        self.sent_messages.deinit(self.allocator);
        self.* = undefined;
    }

    fn transport(self: *FakeTransport) JsonRpcTransport {
        return .{
            .context = self,
            .send = send,
            .recv = recv,
        };
    }

    fn send(context: ?*anyopaque, message: []const u8) !void {
        const self: *FakeTransport = @ptrCast(@alignCast(context.?));
        try self.sent_messages.append(self.allocator, try self.allocator.dupe(u8, message));
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return ProtocolError.InvalidJsonRpcResponse,
        };
        const method = getStringField(object, "method") orelse return ProtocolError.InvalidJsonRpcResponse;
        try self.sent_methods.append(self.allocator, try self.allocator.dupe(u8, method));
    }

    fn recv(context: ?*anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *FakeTransport = @ptrCast(@alignCast(context.?));
        if (self.response_index >= self.responses.len) return ProtocolError.McpTransportEof;
        defer self.response_index += 1;
        return allocator.dupe(u8, self.responses[self.response_index]);
    }
};

fn expectTextBlock(blocks: []const ai.ContentBlock, index: usize, expected: []const u8) !void {
    try std.testing.expect(index < blocks.len);
    switch (blocks[index]) {
        .text => |text| try std.testing.expectEqualStrings(expected, text.text),
        else => return error.UnexpectedContentBlock,
    }
}

fn testOperationalServer(allocator: std.mem.Allocator) !ServerDefinition {
    return .{
        .name = try allocator.dupe(u8, "fixture"),
        .transport = .stdio,
        .status = .operational,
        .command = try allocator.dupe(u8, "fake-mcp-server"),
        .args = try allocator.alloc([]u8, 0),
        .env = try allocator.alloc(EnvEntry, 0),
        .unsupported_detail = null,
    };
}

const stdio_fixture_script =
    \\import json, sys, time
    \\mode = sys.argv[1]
    \\def send(value):
    \\    print(json.dumps(value, separators=(",", ":")), flush=True)
    \\line = sys.stdin.readline()
    \\if not line:
    \\    sys.exit(0)
    \\if mode == "eof-init":
    \\    sys.exit(0)
    \\if mode == "timeout":
    \\    time.sleep(30)
    \\    sys.exit(0)
    \\if mode == "malformed":
    \\    print("not-json", flush=True)
    \\    sys.exit(0)
    \\json.loads(line)
    \\send({"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2025-11-25", "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": "fake", "version": "1.0.0"}}})
    \\line = sys.stdin.readline()
    \\if not line:
    \\    sys.exit(0)
    \\line = sys.stdin.readline()
    \\if not line:
    \\    sys.exit(0)
    \\json.loads(line)
    \\send({"jsonrpc": "2.0", "id": 2, "result": {"tools": [{"name": "child_echo", "description": "Echo from child", "inputSchema": {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]}}]}})
    \\line = sys.stdin.readline()
    \\if not line:
    \\    sys.exit(0)
    \\if mode == "eof-call":
    \\    sys.exit(0)
    \\call = json.loads(line)
    \\send({"jsonrpc": "2.0", "id": call["id"], "result": {"content": [{"type": "text", "text": call["params"]["name"]}, {"type": "image", "data": "redacted"}, {"type": "text", "text": json.dumps(call["params"]["arguments"], sort_keys=True, separators=(",", ":"))}]}})
    \\for line in sys.stdin:
    \\    pass
;

fn startFixtureClient(allocator: std.mem.Allocator, mode: []const u8, options: StdioClientOptions) !*StdioClient {
    return try StdioClient.startArgv(
        allocator,
        std.testing.io,
        &.{ "python3", "-u", "-c", stdio_fixture_script, mode },
        options,
    );
}

test "parseConfigContent loads stdio servers and marks unsupported MCP declarations" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "mcpServers": {
        \\    "local-tools": {
        \\      "transport": "stdio",
        \\      "command": "node",
        \\      "args": ["fake-server.mjs", "--stdio"],
        \\      "env": {"MODE": "test"}
        \\    },
        \\    "remote-sse": {"transport": "sse", "url": "https://example.test/sse"},
        \\    "remote-http": {"url": "https://example.test/mcp"},
        \\    "resourceful": {"command": "fake", "resources": {"listChanged": true}},
        \\    "prompt-disabled": {"command": "fake", "prompts": false}
        \\  }
        \\}
    ;

    var config = try parseConfigContent(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 5), config.servers.len);

    const local = findServer(&config, "local-tools").?;
    try std.testing.expect(local.isOperational());
    try std.testing.expectEqual(.stdio, local.transport);
    try std.testing.expectEqualStrings("node", local.command.?);
    try std.testing.expectEqual(@as(usize, 2), local.args.len);
    try std.testing.expectEqualStrings("fake-server.mjs", local.args[0]);
    try std.testing.expectEqualStrings("--stdio", local.args[1]);
    try std.testing.expectEqual(@as(usize, 1), local.env.len);
    try std.testing.expectEqualStrings("MODE", local.env[0].key);
    try std.testing.expectEqualStrings("test", local.env[0].value);

    const sse = findServer(&config, "remote-sse").?;
    try std.testing.expectEqual(.sse, sse.transport);
    try std.testing.expectEqual(.unsupported_transport, sse.status);
    try std.testing.expect(!sse.isOperational());

    const http = findServer(&config, "remote-http").?;
    try std.testing.expectEqual(.http, http.transport);
    try std.testing.expectEqual(.unsupported_transport, http.status);
    try std.testing.expect(!http.isOperational());

    const resourceful = findServer(&config, "resourceful").?;
    try std.testing.expectEqual(.unsupported_capability, resourceful.status);
    try std.testing.expect(!resourceful.isOperational());

    const prompt_disabled = findServer(&config, "prompt-disabled").?;
    try std.testing.expect(prompt_disabled.isOperational());
}

test "discoverAgentTools performs MCP initialize initialized tools list and preserves schema metadata" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "mcpServers": {
        \\    "fixture": {"command": "fake-mcp-server", "args": ["--mode", "tools-list"]}
        \\  }
        \\}
    ;

    var config = try parseConfigContent(allocator, content);
    defer config.deinit();
    const fixture = findServer(&config, "fixture").?;

    var fake = FakeTransport.init(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1.0.0\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"read_fixture\",\"description\":\"Read deterministic fixture data\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Fixture path\"}},\"required\":[\"path\"],\"additionalProperties\":false}},{\"name\":\"echo_fixture\",\"description\":\"Echo deterministic input\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}}]}}",
    });
    defer fake.deinit();
    var transport = fake.transport();

    var tool_set = try discoverAgentTools(allocator, fixture, &transport);
    defer tool_set.deinit();

    try std.testing.expectEqual(@as(usize, 3), fake.sent_methods.items.len);
    try std.testing.expectEqualStrings("initialize", fake.sent_methods.items[0]);
    try std.testing.expectEqualStrings("notifications/initialized", fake.sent_methods.items[1]);
    try std.testing.expectEqualStrings("tools/list", fake.sent_methods.items[2]);
    try std.testing.expect(std.mem.indexOf(u8, fake.sent_messages.items[0], "\"protocolVersion\":\"2025-11-25\"") != null);

    try std.testing.expectEqual(@as(usize, 2), tool_set.items.len);
    const read_tool = findTool(&tool_set, "read_fixture").?;
    try std.testing.expectEqualStrings("Read deterministic fixture data", read_tool.description);
    try std.testing.expect(read_tool.execute != null);
    try std.testing.expectEqual(agent.ToolExecutionMode.sequential, read_tool.execution_mode.?);
    const read_schema = read_tool.parameters.object;
    try std.testing.expectEqualStrings("object", read_schema.get("type").?.string);
    const properties = read_schema.get("properties").?.object;
    const path_schema = properties.get("path").?.object;
    try std.testing.expectEqualStrings("string", path_schema.get("type").?.string);
    try std.testing.expectEqualStrings("Fixture path", path_schema.get("description").?.string);
    const required = read_schema.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("path", required.items[0].string);
    try std.testing.expectEqual(false, read_schema.get("additionalProperties").?.bool);

    const echo_tool = findTool(&tool_set, "echo_fixture").?;
    try std.testing.expectEqualStrings("Echo deterministic input", echo_tool.description);
    try std.testing.expect(echo_tool.execute != null);
    const echo_schema = echo_tool.parameters.object;
    const echo_required = echo_schema.get("required").?.array;
    try std.testing.expectEqualStrings("message", echo_required.items[0].string);
}

test "execute MCP tools call preserves text order and safe unsupported fallbacks" {
    const allocator = std.testing.allocator;
    var server = try testOperationalServer(allocator);
    defer server.deinit(allocator);

    var fake = FakeTransport.init(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1.0.0\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo_fixture\",\"description\":\"Echo deterministic input\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"first\"},{\"type\":\"image\",\"data\":\"redacted\"},{\"type\":\"text\",\"text\":\"second\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"content\":[{\"type\":\"resource\",\"uri\":\"file:///redacted\"}]}}",
    });
    defer fake.deinit();
    var transport = fake.transport();
    var tool_set = try discoverAgentTools(allocator, &server, &transport);
    defer tool_set.deinit();

    const echo_tool = findTool(&tool_set, "echo_fixture").?;
    var args_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"hello\"}", .{});
    defer args_parsed.deinit();
    const result = try echo_tool.execute.?(
        allocator,
        "tool-call-1",
        args_parsed.value,
        echo_tool.execute_context,
        null,
        null,
        null,
    );
    defer common.deinitContentBlocks(allocator, result.content);

    try std.testing.expectEqual(@as(usize, 3), result.content.len);
    try expectTextBlock(result.content, 0, "first");
    try expectTextBlock(result.content, 1, "[Unsupported MCP content type: image]");
    try expectTextBlock(result.content, 2, "second");

    try std.testing.expectEqual(@as(usize, 4), fake.sent_methods.items.len);
    try std.testing.expectEqualStrings("tools/call", fake.sent_methods.items[3]);
    try std.testing.expect(std.mem.indexOf(u8, fake.sent_messages.items[3], "\"id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.sent_messages.items[3], "\"method\":\"tools/call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.sent_messages.items[3], "\"name\":\"echo_fixture\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.sent_messages.items[3], "\"arguments\":{\"message\":\"hello\"}") != null);

    const unsupported_only = try echo_tool.execute.?(
        allocator,
        "tool-call-2",
        args_parsed.value,
        echo_tool.execute_context,
        null,
        null,
        null,
    );
    defer common.deinitContentBlocks(allocator, unsupported_only.content);
    try std.testing.expectEqual(@as(usize, 1), unsupported_only.content.len);
    try expectTextBlock(unsupported_only.content, 0, "[Unsupported MCP content type: resource]");
    try std.testing.expect(std.mem.indexOf(u8, fake.sent_messages.items[4], "\"id\":4") != null);
}

test "execute MCP tools call reports MCP tool errors distinctly" {
    const allocator = std.testing.allocator;
    var server = try testOperationalServer(allocator);
    defer server.deinit(allocator);

    var fake = FakeTransport.init(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1.0.0\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"failing_fixture\",\"description\":\"Fail deterministically\",\"inputSchema\":{\"type\":\"object\"}}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"fixture failure\"}]}}",
    });
    defer fake.deinit();
    var transport = fake.transport();
    var tool_set = try discoverAgentTools(allocator, &server, &transport);
    defer tool_set.deinit();

    const failing_tool = findTool(&tool_set, "failing_fixture").?;
    var args_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer args_parsed.deinit();
    try std.testing.expectError(ProtocolError.McpToolError, failing_tool.execute.?(
        allocator,
        "tool-call-error",
        args_parsed.value,
        failing_tool.execute_context,
        null,
        null,
        null,
    ));
    try std.testing.expectEqualStrings("tools/call", fake.sent_methods.items[3]);
}

test "stdio MCP child transport executes tools call and shuts down without leaking fixture process" {
    const allocator = std.testing.allocator;
    var server = try testOperationalServer(allocator);
    defer server.deinit(allocator);
    var client = try startFixtureClient(allocator, "normal", .{ .response_timeout_ms = 1000, .shutdown_timeout_ms = 500 });
    defer client.deinit();
    var transport = client.transport();

    var tool_set = try discoverAgentTools(allocator, &server, &transport);
    defer tool_set.deinit();
    const child_tool = findTool(&tool_set, "child_echo").?;

    var args_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"from-child\"}", .{});
    defer args_parsed.deinit();
    const result = try child_tool.execute.?(
        allocator,
        "tool-call-child",
        args_parsed.value,
        child_tool.execute_context,
        null,
        null,
        null,
    );
    defer common.deinitContentBlocks(allocator, result.content);

    try std.testing.expectEqual(@as(usize, 3), result.content.len);
    try expectTextBlock(result.content, 0, "child_echo");
    try expectTextBlock(result.content, 1, "[Unsupported MCP content type: image]");
    try expectTextBlock(result.content, 2, "{\"message\":\"from-child\"}");

    try client.shutdown();
    try std.testing.expect(client.hasExited());
}

test "stdio MCP child lifecycle handles timeout malformed EOF and call exit without leaks" {
    const allocator = std.testing.allocator;
    var server = try testOperationalServer(allocator);
    defer server.deinit(allocator);

    var timeout_client = try startFixtureClient(allocator, "timeout", .{ .response_timeout_ms = 50, .shutdown_timeout_ms = 100 });
    var timeout_transport = timeout_client.transport();
    try std.testing.expectError(ProtocolError.McpTransportTimeout, discoverAgentTools(allocator, &server, &timeout_transport));
    try timeout_client.shutdown();
    try std.testing.expect(timeout_client.hasExited());
    timeout_client.deinit();

    var malformed_client = try startFixtureClient(allocator, "malformed", .{ .response_timeout_ms = 500, .shutdown_timeout_ms = 100 });
    var malformed_transport = malformed_client.transport();
    try std.testing.expectError(ProtocolError.InvalidJsonRpcResponse, discoverAgentTools(allocator, &server, &malformed_transport));
    try malformed_client.shutdown();
    try std.testing.expect(malformed_client.hasExited());
    malformed_client.deinit();

    var eof_client = try startFixtureClient(allocator, "eof-init", .{ .response_timeout_ms = 500, .shutdown_timeout_ms = 100 });
    var eof_transport = eof_client.transport();
    try std.testing.expectError(ProtocolError.McpTransportEof, discoverAgentTools(allocator, &server, &eof_transport));
    try eof_client.shutdown();
    try std.testing.expect(eof_client.hasExited());
    eof_client.deinit();

    var call_exit_client = try startFixtureClient(allocator, "eof-call", .{ .response_timeout_ms = 500, .shutdown_timeout_ms = 100 });
    var call_exit_transport = call_exit_client.transport();
    var tool_set = try discoverAgentTools(allocator, &server, &call_exit_transport);
    defer tool_set.deinit();
    const child_tool = findTool(&tool_set, "child_echo").?;
    var args_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer args_parsed.deinit();
    try std.testing.expectError(ProtocolError.McpTransportEof, child_tool.execute.?(
        allocator,
        "tool-call-eof",
        args_parsed.value,
        child_tool.execute_context,
        null,
        null,
        null,
    ));
    try call_exit_client.shutdown();
    try std.testing.expect(call_exit_client.hasExited());
    call_exit_client.deinit();
}

test "discoverAgentTools refuses unsupported transports before sending protocol messages" {
    const allocator = std.testing.allocator;
    var config = try parseConfigContent(allocator,
        \\{
        \\  "mcpServers": {
        \\    "remote": {"transport": "sse", "url": "https://example.test/sse"}
        \\  }
        \\}
    );
    defer config.deinit();
    const remote = findServer(&config, "remote").?;

    var fake = FakeTransport.init(allocator, &.{});
    defer fake.deinit();
    var transport = fake.transport();

    try std.testing.expectError(ProtocolError.UnsupportedMcpServer, discoverAgentTools(allocator, remote, &transport));
    try std.testing.expectEqual(@as(usize, 0), fake.sent_methods.items.len);
}

test "discoverAgentTools reports malformed or missing fixture responses terminally" {
    const allocator = std.testing.allocator;
    var config = try parseConfigContent(allocator,
        \\{
        \\  "mcpServers": {
        \\    "fixture": {"command": "fake-mcp-server"}
        \\  }
        \\}
    );
    defer config.deinit();
    const fixture = findServer(&config, "fixture").?;

    var malformed = FakeTransport.init(allocator, &.{"not-json"});
    defer malformed.deinit();
    var malformed_transport = malformed.transport();
    try std.testing.expectError(ProtocolError.InvalidJsonRpcResponse, discoverAgentTools(allocator, fixture, &malformed_transport));

    var eof = FakeTransport.init(allocator, &.{});
    defer eof.deinit();
    var eof_transport = eof.transport();
    try std.testing.expectError(ProtocolError.McpTransportEof, discoverAgentTools(allocator, fixture, &eof_transport));
}
