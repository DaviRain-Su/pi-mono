pub const std = @import("std");
pub const ai = @import("ai");
pub const agent = @import("agent");
pub const ts_rpc_mode = @import("../../ts_rpc_mode.zig");
pub const ts_rpc_bash = @import("../../ts_rpc_bash.zig");
pub const ts_rpc_state_json = @import("../../ts_rpc_state_json.zig");
pub const ts_rpc_wire = @import("../../ts_rpc_wire.zig");
pub const truncate = @import("../../../tools/truncate.zig");
pub const session_mod = @import("../../../sessions/session.zig");
pub const extension_runtime = @import("../../../extensions/extension_runtime.zig");

pub const TsRpcServer = ts_rpc_mode.testing.TsRpcServer;
pub const ExtensionUIDialogMethod = ts_rpc_mode.testing.ExtensionUIDialogMethod;
pub const ExtensionUIResolution = ts_rpc_mode.testing.ExtensionUIResolution;
pub const EXTENSION_HOST_EVENT_LOOP_TICK_MS = ts_rpc_mode.testing.extension_host_event_loop_tick_ms;
pub const command_types = ts_rpc_mode.command_types;
pub const isKnownCommandType = ts_rpc_mode.isKnownCommandType;
pub const writeJsonString = ts_rpc_wire.writeJsonString;

pub fn runTsRpcModeScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ?*session_mod.AgentSession,
    lines: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !void {
    var server = TsRpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    try server.start();
    defer server.finish() catch {};
    server.setDeferredFlushInputBacklog(lines.len > 0);
    defer server.setDeferredFlushInputBacklog(false);

    for (lines) |line| {
        try server.handleLine(line);
    }

    server.setDeferredFlushInputBacklog(false);
    try waitForNoInFlightPrompt(&server, 30_000);
    try waitForNoActiveBashTask(&server, 30_000);
    try server.finish();
}

pub fn runTsRpcModeBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ?*session_mod.AgentSession,
    bytes: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !void {
    var server = TsRpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    try server.start();
    defer server.finish() catch {};
    server.setDeferredFlushInputBacklog(bytes.len > 0);
    defer server.setDeferredFlushInputBacklog(false);
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);

    for (bytes, 0..) |byte, index| {
        server.setDeferredFlushInputBacklog(index + 1 < bytes.len);
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

    server.setDeferredFlushInputBacklog(false);
    if (server.hasInFlightPrompt()) {
        server.suppress_events = true;
        server.abortActivePromptWork();
    }
    try server.flushDeferredResponses();
    try server.finish();
}

pub fn readFixture(comptime name: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        "test/golden/ts-rpc/" ++ name,
        std.testing.allocator,
        .unlimited,
    );
}

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

pub fn expectOutputOrder(haystack: []const u8, before: []const u8, after: []const u8) !void {
    const before_index = std.mem.indexOf(u8, haystack, before) orelse {
        try expectContains(haystack, before);
        unreachable;
    };
    const after_index = std.mem.indexOf(u8, haystack, after) orelse {
        try expectContains(haystack, after);
        unreachable;
    };
    try std.testing.expect(before_index < after_index);
}

pub fn waitForOutputContains(
    server: *TsRpcServer,
    writer: *std.Io.Writer,
    needle: []const u8,
    timeout_ms: u64,
) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        server.output_mutex.lockUncancelable(server.io);
        const found = std.mem.indexOf(u8, writer.buffered(), needle) != null;
        server.output_mutex.unlock(server.io);
        if (found) return;
        std.Io.sleep(server.io, .fromMilliseconds(5), .awake) catch {};
    }
    try expectContains(writer.buffered(), needle);
}

pub fn waitForAbsoluteFile(path: []const u8, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        if (std.Io.Dir.openFileAbsolute(std.testing.io, path, .{})) |file| {
            file.close(std.testing.io);
            return;
        } else |_| {}
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    _ = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
}

pub fn waitForAbsoluteFileContains(allocator: std.mem.Allocator, path: []const u8, needle: []const u8, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        if (std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .unlimited)) |bytes| {
            defer allocator.free(bytes);
            if (std.mem.indexOf(u8, bytes, needle) != null) return;
        } else |_| {}
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    try expectContains(bytes, needle);
}

pub fn waitForNoActiveBashTask(server: *TsRpcServer, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        if (!server.hasActiveBashTask()) return;
        std.Io.sleep(server.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(!server.hasActiveBashTask());
}

pub fn waitForNoInFlightPrompt(server: *const TsRpcServer, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        if (!server.hasInFlightPrompt()) return;
        std.Io.sleep(server.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(!server.hasInFlightPrompt());
}

pub fn waitForSessionRetrying(session: *const session_mod.AgentSession, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 5) {
        if (session.isRetrying()) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(session.isRetrying());
}

pub fn expectNewOutput(
    writer: *std.Io.Writer,
    cursor: *usize,
    expected: []const u8,
) !void {
    const bytes = writer.buffered();
    try std.testing.expect(bytes.len >= cursor.*);
    try std.testing.expectEqualStrings(expected, bytes[cursor.*..]);
    cursor.* = bytes.len;
}

pub fn expectPromptConcurrencyQueueInvariant(bytes: []const u8) !void {
    const agent_start = "{\"type\":\"agent_start\"}\n";
    const steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\"],\"followUp\":[]}\n";
    const follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\"],\"followUp\":[\"follow while prompt running\"]}\n";
    const prompt_steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\",\"prompt as steer\"],\"followUp\":[\"follow while prompt running\"]}\n";
    const prompt_follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\",\"prompt as steer\"],\"followUp\":[\"follow while prompt running\",\"prompt as follow\"]}\n";
    const steer_response = "{\"id\":\"pc_steer\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n";
    const follow_response = "{\"id\":\"pc_follow\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n";
    const prompt_steer_response = "{\"id\":\"pc_prompt_steer\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n";
    const prompt_follow_response = "{\"id\":\"pc_prompt_follow\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n";

    try expectOutputOrder(bytes, steer_queue_update, steer_response);
    try expectOutputOrder(bytes, follow_queue_update, follow_response);
    try expectOutputOrder(bytes, prompt_steer_queue_update, prompt_steer_response);
    try expectOutputOrder(bytes, prompt_follow_queue_update, prompt_follow_response);
    try std.testing.expect(std.mem.indexOf(u8, bytes, agent_start) == null);
}

pub const TS_RPC_EXTENSION_UI_PROTOCOL_FUZZ_SMOKE_SEED: u64 = 0x5eed_7570_4350_0006;

pub fn reportTsRpcExtensionUiFuzzFailure(seed: u64, label: []const u8, input: []const u8) void {
    std.debug.print("TS RPC extension UI protocol fuzz smoke failure seed=0x{x} case={s} minimized_input={s}", .{
        seed,
        label,
        input,
    });
}

pub fn expectPromptLineTypeOrder(bytes: []const u8) !void {
    const allocator = std.testing.allocator;
    var actual = std.ArrayList([]const u8).empty;
    defer {
        for (actual.items) |item| allocator.free(item);
        actual.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, bytes, "\n"), '\n');
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try actual.append(allocator, try allocator.dupe(u8, parsed.value.object.get("type").?.string));
    }

    try std.testing.expect(actual.items.len >= 10);
    const prefix = [_][]const u8{
        "response",
        "agent_start",
        "turn_start",
        "message_start",
        "message_end",
        "before_provider_request",
        "after_provider_response",
        "message_start",
    };
    for (prefix, 0..) |expected, index| {
        try std.testing.expectEqualStrings(expected, actual.items[index]);
    }
    var index: usize = prefix.len;
    var update_count: usize = 0;
    while (index < actual.items.len and std.mem.eql(u8, actual.items[index], "message_update")) : (index += 1) {
        update_count += 1;
    }
    try std.testing.expect(update_count > 0);
    try std.testing.expectEqualStrings("message_end", actual.items[index]);
    try std.testing.expectEqualStrings("turn_end", actual.items[index + 1]);
    try std.testing.expectEqualStrings("agent_end", actual.items[index + 2]);
    try std.testing.expectEqual(actual.items.len, index + 3);
}

pub fn waitForSessionStreaming(session: *const session_mod.AgentSession) !void {
    var spins: usize = 0;
    while (!session.isStreaming() and spins < 1000) : (spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(session.isStreaming());
}

pub fn waitForActiveBashStarted(server: *TsRpcServer) !void {
    var spins: usize = 0;
    while (!server.activeBashTaskStarted() and spins < 1000) : (spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(server.activeBashTaskStarted());
}

pub fn waitForServerOutputContains(
    server: *TsRpcServer,
    writer: *std.Io.Writer,
    needle: []const u8,
) !void {
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        server.output_mutex.lockUncancelable(std.testing.io);
        const found = std.mem.indexOf(u8, writer.buffered(), needle) != null;
        server.output_mutex.unlock(std.testing.io);
        if (found) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    server.output_mutex.lockUncancelable(std.testing.io);
    defer server.output_mutex.unlock(std.testing.io);
    try expectContains(writer.buffered(), needle);
}

pub fn blockingUntilAbortStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    context: ai.Context,
    options: ?ai.types.SimpleStreamOptions,
    stream_context: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    _ = context;
    _ = stream_context;
    const signal = if (options) |some| some.signal else null;
    while (signal == null or !signal.?.load(.seq_cst)) {
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }

    var stream = ai.event_stream.createAssistantMessageEventStream(std.heap.page_allocator, io);
    const message = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .aborted,
        .error_message = "Aborted by user",
        .timestamp = 0,
    };
    stream.push(.{
        .event_type = .done,
        .message = message,
    });
    _ = allocator;
    return stream;
}

pub fn sessionLifecycleCaptureScript(allocator: std.mem.Allocator, capture_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"type\":\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{capture_path},
    );
}

pub fn countCapturedEvents(capture: []const u8, event_type: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, capture, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":") == null) continue;
        if (std.mem.indexOf(u8, line, event_type) != null) count += 1;
    }
    return count;
}

pub fn findEventLine(capture: []const u8, event_type: []const u8, reason: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, capture, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, event_type) == null) continue;
        const reason_fragment = std.fmt.allocPrint(std.testing.allocator, "\"reason\":\"{s}\"", .{reason}) catch return null;
        defer std.testing.allocator.free(reason_fragment);
        if (std.mem.indexOf(u8, line, reason_fragment) != null) return line;
    }
    return null;
}

pub fn expectEventOrder(capture: []const u8, before: []const u8, after: []const u8) !void {
    const before_index = std.mem.indexOf(u8, capture, before) orelse return error.ExpectedEventNotFound;
    const after_index = std.mem.indexOf(u8, capture, after) orelse return error.ExpectedEventNotFound;
    try std.testing.expect(before_index < after_index);
}

pub fn wfcBashToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) anyerror!agent.AgentToolResult {
    const content = try allocator.alloc(ai.ContentBlock, 2);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "hello") } };
    content[1] = .{ .thinking = .{ .thinking = try allocator.dupe(u8, "internal reasoning") } };
    return .{ .content = content, .details = null };
}
