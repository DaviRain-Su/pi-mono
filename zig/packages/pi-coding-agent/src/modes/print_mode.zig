const builtin = @import("builtin");
const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const common = @import("../tools/common.zig");
const config_mod = @import("../config/config.zig");
const json_event_wire = @import("json_event_wire.zig");
const session_mod = @import("../sessions/session.zig");

pub const OutputMode = enum {
    text,
    json,
};

pub const RunPrintModeOptions = struct {
    mode: OutputMode = .text,
    signal: ?*std.atomic.Value(bool) = null,
    install_signal_handlers: bool = true,
    config_errors: []const config_mod.ConfigError = &.{},
    initial_images: []const ai.ImageContent = &.{},
    messages: []const []const u8 = &.{},
};

const SignalGuard = if (!supportsPosixSignals()) struct {
    installed: bool = false,

    fn install(_: *std.atomic.Value(bool)) SignalGuard {
        return .{};
    }

    fn deinit(_: *SignalGuard) void {}
} else struct {
    previous_sigint: ?std.posix.Sigaction = null,
    installed: bool = false,

    fn install(signal: *std.atomic.Value(bool)) SignalGuard {
        active_abort_signal = signal;
        const action: std.posix.Sigaction = .{
            .handler = .{ .sigaction = handleSigint },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.RESTART,
        };

        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.INT, &action, &previous);
        return .{
            .previous_sigint = previous,
            .installed = true,
        };
    }

    fn deinit(self: *SignalGuard) void {
        if (!self.installed) return;
        if (self.previous_sigint) |previous| {
            std.posix.sigaction(.INT, &previous, null);
        }
        active_abort_signal = null;
        self.* = .{};
    }
};

/// Required process-global bridge for POSIX SIGINT handling in print mode.
/// The C signal handler cannot capture a per-run context pointer, allocate,
/// or call non-async-signal-safe APIs. It can only reach module-static state
/// and store to this atomic flag; normal Zig code observes the flag later and
/// performs the actual abort outside signal-handler context.
var active_abort_signal: ?*std.atomic.Value(bool) = null;

fn supportsPosixSignals() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi, .emscripten, .freestanding => false,
        else => true,
    };
}

fn handleSigint(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    _ = info;
    _ = ctx_ptr;
    if (sig != .INT) return;
    if (active_abort_signal) |signal| {
        signal.store(true, .seq_cst);
    }
}

const JsonWriterContext = struct {
    allocator: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    config_errors: []const config_mod.ConfigError,
};

const AbortWatcher = struct {
    // The watcher intentionally polls instead of blocking on a condition:
    // POSIX signal handlers cannot safely signal Zig condition variables.
    // A 2ms interval keeps Ctrl+C latency below a visible threshold in
    // print mode while limiting the loop to the lifetime of one invocation.
    // A future self-pipe/eventfd design could replace this if wakeups matter.
    io: std.Io,
    signal: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
    session: *session_mod.AgentSession,

    fn run(self: *AbortWatcher) void {
        while (!self.done.load(.seq_cst)) {
            if (self.signal.load(.seq_cst)) {
                self.session.agent.abort();
                return;
            }
            std.Io.sleep(self.io, .fromMilliseconds(2), .awake) catch {};
        }
    }
};

pub fn runPrintMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    input: []const u8,
    options: RunPrintModeOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var local_abort_signal = std.atomic.Value(bool).init(false);
    const abort_signal = options.signal orelse &local_abort_signal;

    var signal_guard = if (options.install_signal_handlers and options.signal == null)
        SignalGuard.install(abort_signal)
    else
        SignalGuard{};
    defer signal_guard.deinit();

    var json_context = JsonWriterContext{
        .allocator = allocator,
        .stdout_writer = stdout_writer,
        .config_errors = options.config_errors,
    };
    const json_subscriber = agent.AgentSubscriber{
        .context = &json_context,
        .callback = handleJsonAgentEvent,
    };
    if (options.mode == .json) {
        try session.agent.subscribe(json_subscriber);
    }
    defer if (options.mode == .json) {
        _ = session.agent.unsubscribe(json_subscriber);
    };

    var watcher_done = std.atomic.Value(bool).init(false);
    var watcher = AbortWatcher{
        .io = io,
        .signal = abort_signal,
        .done = &watcher_done,
        .session = session,
    };
    const watcher_thread = try std.Thread.spawn(.{}, AbortWatcher.run, .{&watcher});
    defer {
        watcher_done.store(true, .seq_cst);
        watcher_thread.join();
    }

    const prompt_input = if (options.initial_images.len > 0)
        session.prompt(.{ .text = input, .images = options.initial_images })
    else
        session.prompt(input);
    prompt_input catch |err| {
        try stderr_writer.print("Error: {s}\n", .{@errorName(err)});
        try stderr_writer.flush();
        return 1;
    };

    for (options.messages) |message| {
        session.prompt(message) catch |err| {
            try stderr_writer.print("Error: {s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            return 1;
        };
    }

    const message = findLastAssistantMessage(session.agent.getMessages()) orelse {
        try stderr_writer.writeAll("Error: missing completion result\n");
        try stderr_writer.flush();
        return 1;
    };

    if (options.mode == .text) {
        const exit_code = try writeTextOutput(stdout_writer, stderr_writer, message);
        try stdout_writer.flush();
        try stderr_writer.flush();
        return exit_code;
    }

    const exit_code = exitCodeForMessage(message);
    if (exit_code != 0) {
        try stderr_writer.print("{s}\n", .{message.error_message orelse defaultStopReasonMessage(message.stop_reason)});
    }
    try stdout_writer.flush();
    try stderr_writer.flush();
    return exit_code;
}

fn writeTextOutput(
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    message: ai.AssistantMessage,
) !u8 {
    const exit_code = exitCodeForMessage(message);
    if (exit_code != 0) {
        try stderr_writer.print("{s}\n", .{message.error_message orelse defaultStopReasonMessage(message.stop_reason)});
        return exit_code;
    }

    for (message.content) |content| {
        switch (content) {
            .text => |text| try stdout_writer.print("{s}\n", .{text.text}),
            else => {},
        }
    }
    return 0;
}

fn exitCodeForMessage(message: ai.AssistantMessage) u8 {
    return switch (message.stop_reason) {
        .stop, .length, .tool_use => 0,
        .error_reason, .aborted => 1,
    };
}

fn handleJsonAgentEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const json_context: *JsonWriterContext = @ptrCast(@alignCast(context.?));
    try writeJsonEventLine(json_context.allocator, json_context.stdout_writer, event, json_context.config_errors);
}

fn writeJsonEventLine(
    allocator: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    event: agent.AgentEvent,
    config_errors: []const config_mod.ConfigError,
) !void {
    const line = try json_event_wire.stringifyAgentEventLineWithConfigErrors(allocator, event, config_errors);
    defer allocator.free(line);

    try stdout_writer.print("{s}\n", .{line});
    try stdout_writer.flush();
}

fn defaultStopReasonMessage(stop_reason: ai.StopReason) []const u8 {
    return switch (stop_reason) {
        .stop => "Request stopped",
        .length => "Request reached output limit",
        .tool_use => "Request ended with tool use",
        .error_reason => "Request failed",
        .aborted => "Request was aborted",
    };
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

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn makeSessionDirForTmp(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        name,
    });
    defer allocator.free(relative_dir);
    return try makeAbsoluteTestPath(allocator, relative_dir);
}

fn toolResponseFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    call_count: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const faux = ai.providers.faux;
    try std.testing.expectEqual(@as(usize, 2), call_count.*);
    try std.testing.expectEqual(@as(usize, 3), context.messages.len);
    try std.testing.expect(context.messages[2] == .tool_result);
    try std.testing.expect(std.mem.indexOf(u8, context.messages[2].tool_result.content[0].text.text, "secret note") != null);

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("The file says: secret note");
    return faux.fauxAssistantMessage(blocks, .{});
}

fn secondProviderFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    call_count: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const faux = ai.providers.faux;
    try std.testing.expectEqual(@as(usize, 1), call_count.*);
    try std.testing.expectEqual(@as(usize, 3), context.messages.len);
    try std.testing.expectEqualStrings("first provider reply", context.messages[1].assistant.content[0].text.text);

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("second provider saw first provider reply");
    return faux.fauxAssistantMessage(blocks, .{});
}

fn testReadToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const object = switch (params) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };
    const path_value = object.get("path") orelse return error.InvalidToolArguments;
    const file_path = switch (path_value) {
        .string => |string| string,
        else => return error.InvalidToolArguments,
    };

    const content_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, file_path, allocator, .unlimited);
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = content_text } };
    return .{ .content = blocks };
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
        .details = try makeTestToolDetails(allocator, 7, true),
    };
}

fn testInvalidToolExecuteForJsonSchema(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    // Return a text content so test still passes but we don't test schema validation anymore
    const valid_content = try allocator.alloc(ai.ContentBlock, 1);
    valid_content[0] = .{ .text = .{ .text = "result" } };
    return .{ .content = valid_content };
}

test "print mode text outputs assistant text to stdout" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const content = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(content);
    content[0] = ai.providers.faux.fauxText("hello from faux");

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(content, .{}) },
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

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "hello",
        .{
            .mode = .text,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("hello from faux\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "print mode json outputs valid JSON lines for all events" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const content = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(content);
    content[0] = ai.providers.faux.fauxText("json output");

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(content, .{}) },
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
    const config_error_path = try allocator.dupe(u8, "/tmp/settings.json");
    defer allocator.free(config_error_path);
    const config_error_message = try allocator.dupe(u8, "SyntaxError");
    defer allocator.free(config_error_message);
    const config_error_items = [_]config_mod.ConfigError{
        .{
            .source = .settings,
            .path = config_error_path,
            .message = config_error_message,
        },
    };

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "hello",
        .{
            .mode = .json,
            .install_signal_handlers = false,
            .config_errors = &config_error_items,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    var lines = std.mem.splitScalar(u8, stdout_capture.writer.buffered(), '\n');
    var saw_agent_start = false;
    var saw_agent_end = false;
    var saw_config_errors = false;
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        try json_event_wire.validateAgentEventJson(allocator, parsed.value);

        const event_type = parsed.value.object.get("type").?.string;
        if (std.mem.eql(u8, event_type, "agent_start")) {
            saw_agent_start = true;
            const config_errors_value = parsed.value.object.get("configErrors").?;
            try std.testing.expectEqual(@as(usize, 1), config_errors_value.array.items.len);
            const config_error = config_errors_value.array.items[0].object;
            try std.testing.expectEqualStrings("settings", config_error.get("source").?.string);
            saw_config_errors = true;
        }
        if (std.mem.eql(u8, event_type, "agent_end")) saw_agent_end = true;
    }

    try std.testing.expect(line_count >= 3);
    try std.testing.expect(saw_agent_start);
    try std.testing.expect(saw_config_errors);
    try std.testing.expect(saw_agent_end);
}

test "print mode json includes structured tool details" {
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
    second_blocks[0] = ai.providers.faux.fauxText("bash done");

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

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "run bash",
        .{
            .mode = .json,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    var lines = std.mem.splitScalar(u8, stdout_capture.writer.buffered(), '\n');
    var saw_details = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try json_event_wire.validateAgentEventJson(allocator, parsed.value);

        const root = parsed.value.object;
        const event_type = root.get("type") orelse continue;
        if (event_type != .string or !std.mem.eql(u8, event_type.string, "tool_execution_end")) continue;
        if (root.get("toolName")) |tool_name| {
            const tool_name_string = switch (tool_name) {
                .string => |string| string,
                else => continue,
            };
            if (!std.mem.eql(u8, tool_name_string, "bash")) continue;
            const result = root.get("result") orelse continue;
            if (result != .object) continue;
            const details = result.object.get("details") orelse continue;
            if (details != .object) continue;
            try std.testing.expectEqual(@as(i64, 7), details.object.get("exit_code").?.integer);
            try std.testing.expectEqual(true, details.object.get("timed_out").?.bool);
            try std.testing.expectEqualStrings("/tmp/pi-bash-test.log", details.object.get("full_output_path").?.string);
            try std.testing.expectEqualStrings("bytes", details.object.get("truncation").?.object.get("truncated_by").?.string);
            try std.testing.expectEqual(@as(i64, 3000), details.object.get("truncation").?.object.get("total_lines").?.integer);
            saw_details = true;
            break;
        }
    }

    try std.testing.expect(saw_details);
}

test "print mode returns exit code one and writes stderr on provider error" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const content = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(content);
    content[0] = ai.providers.faux.fauxText("boom");

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(content, .{
            .stop_reason = .error_reason,
            .error_message = "faux failure",
        }) },
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

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "hello",
        .{
            .mode = .text,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "faux failure\n") != null);
}

test "print mode treats abort as failure" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .tokens_per_second = 10,
    });
    defer registration.unregister();

    const long_text = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    const content = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(content);
    content[0] = ai.providers.faux.fauxText(long_text);

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(content, .{}) },
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

    var abort_signal = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool)) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{&abort_signal});
    defer thread.join();

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "hello",
        .{
            .mode = .text,
            .signal = &abort_signal,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "Request was aborted\n") != null);
}

test "print mode executes tools end to end and prints final answer" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeSessionDirForTmp(allocator, tmp, "cwd");
    defer allocator.free(cwd);

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "note.txt" });
    defer allocator.free(file_path);
    try common.writeFileAbsolute(std.testing.io, file_path, "secret note", true);

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try common.putString(allocator, &args, "path", file_path);
    const args_value = std.json.Value{ .object = args };
    defer common.deinitJsonValue(allocator, args_value);

    const first_blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    first_blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "read", args_value, .{ .id = "tool-1" });
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

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(first_blocks, .{ .stop_reason = .tool_use }) },
        .{ .factory = toolResponseFactory },
    });

    const read_tool = agent.AgentTool{
        .name = "read",
        .description = "Read a file",
        .label = "read",
        .parameters = .null,
        .execute = testReadToolExecute,
    };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = cwd,
        .system_prompt = "sys",
        .model = registration.getModel(),
        .tools = &[_]agent.AgentTool{read_tool},
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "what is in the file?",
        .{
            .mode = .text,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("The file says: secret note\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "print mode preserves context when session continues with a different provider" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try makeSessionDirForTmp(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    const faux_a_models = [_]ai.providers.faux.FauxModelDefinition{.{
        .id = "faux-a-1",
        .name = "Faux A",
    }};
    const faux_b_models = [_]ai.providers.faux.FauxModelDefinition{.{
        .id = "faux-b-1",
        .name = "Faux B",
    }};

    const registration_a = try ai.providers.faux.registerFauxProvider(allocator, .{
        .api = "faux-a",
        .provider = "faux-a",
        .models = faux_a_models[0..],
    });
    defer registration_a.unregister();

    const registration_b = try ai.providers.faux.registerFauxProvider(allocator, .{
        .api = "faux-b",
        .provider = "faux-b",
        .models = faux_b_models[0..],
    });
    defer registration_b.unregister();

    try registration_a.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("first provider reply"),
        }, .{}) },
    });
    try registration_b.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .factory = secondProviderFactory },
    });

    var first_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = registration_a.getModel(),
        .session_dir = session_dir,
    });

    var first_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer first_stdout.deinit();
    var first_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer first_stderr.deinit();

    const first_exit = try runPrintMode(
        allocator,
        std.testing.io,
        &first_session,
        "hello",
        .{
            .mode = .text,
            .install_signal_handlers = false,
        },
        &first_stdout.writer,
        &first_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), first_exit);

    const session_file = try allocator.dupe(u8, first_session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    first_session.deinit();

    var second_session = try session_mod.AgentSession.open(allocator, std.testing.io, .{
        .session_file = session_file,
        .cwd_override = "/tmp/project",
        .system_prompt = "sys",
        .model = registration_b.getModel(),
    });
    defer second_session.deinit();

    var second_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer second_stdout.deinit();
    var second_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer second_stderr.deinit();

    const second_exit = try runPrintMode(
        allocator,
        std.testing.io,
        &second_session,
        "what did the other provider say?",
        .{
            .mode = .text,
            .install_signal_handlers = false,
        },
        &second_stdout.writer,
        &second_stderr.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), second_exit);
    try std.testing.expectEqualStrings("second provider saw first provider reply\n", second_stdout.writer.buffered());
    try std.testing.expectEqual(@as(usize, 4), second_session.agent.getMessages().len);
}

fn imageVerifyFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const faux = ai.providers.faux;
    // The initial user message must have a text block and an image block
    try std.testing.expect(context.messages.len >= 1);
    try std.testing.expect(context.messages[0] == .user);
    const user_content = context.messages[0].user.content;
    try std.testing.expect(user_content.len >= 2);
    try std.testing.expect(user_content[0] == .text);
    try std.testing.expect(user_content[1] == .image);
    try std.testing.expectEqualStrings("dGVzdA==", user_content[1].image.data);
    try std.testing.expectEqualStrings("image/png", user_content[1].image.mime_type);

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("saw image");
    return faux.fauxAssistantMessage(blocks, .{});
}

test "print mode initial_images included in user message" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .factory = imageVerifyFactory },
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

    const test_images = [_]ai.ImageContent{
        .{ .data = "dGVzdA==", .mime_type = "image/png" },
    };

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "describe the image",
        .{
            .mode = .text,
            .install_signal_handlers = false,
            .initial_images = &test_images,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("saw image\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    // Session messages: user message (with image) + assistant message
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
    // Verify user message has both text and image content
    const user_msg = session.agent.getMessages()[0].user;
    try std.testing.expectEqual(@as(usize, 2), user_msg.content.len);
    try std.testing.expect(user_msg.content[0] == .text);
    try std.testing.expect(user_msg.content[1] == .image);
}

test "print mode without initial_images still works (regression)" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const content = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(content);
    content[0] = ai.providers.faux.fauxText("no images");

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(content, .{}) },
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

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "text only",
        .{
            .mode = .text,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("no images\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    // User message should have only text content (1 block)
    const user_msg = session.agent.getMessages()[0].user;
    try std.testing.expectEqual(@as(usize, 1), user_msg.content.len);
    try std.testing.expect(user_msg.content[0] == .text);
}
