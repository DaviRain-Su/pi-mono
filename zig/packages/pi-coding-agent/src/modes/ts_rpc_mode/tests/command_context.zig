const common = @import("common.zig");
const std = common.std;
const ai = common.ai;
const agent = common.agent;
const ts_rpc_mode = common.ts_rpc_mode;
const ts_rpc_bash = common.ts_rpc_bash;
const ts_rpc_state_json = common.ts_rpc_state_json;
const ts_rpc_wire = common.ts_rpc_wire;
const truncate = common.truncate;
const session_mod = common.session_mod;
const extension_runtime = common.extension_runtime;
const TsRpcServer = common.TsRpcServer;
const ExtensionUIDialogMethod = common.ExtensionUIDialogMethod;
const ExtensionUIResolution = common.ExtensionUIResolution;
const EXTENSION_HOST_EVENT_LOOP_TICK_MS = common.EXTENSION_HOST_EVENT_LOOP_TICK_MS;
const command_types = common.command_types;
const isKnownCommandType = common.isKnownCommandType;
const writeJsonString = common.writeJsonString;
const runTsRpcModeScript = common.runTsRpcModeScript;
const runTsRpcModeBytes = common.runTsRpcModeBytes;
const readFixture = common.readFixture;
const expectContains = common.expectContains;
const expectOutputOrder = common.expectOutputOrder;
const waitForOutputContains = common.waitForOutputContains;
const waitForAbsoluteFile = common.waitForAbsoluteFile;
const waitForAbsoluteFileContains = common.waitForAbsoluteFileContains;
const waitForNoActiveBashTask = common.waitForNoActiveBashTask;
const waitForNoInFlightPrompt = common.waitForNoInFlightPrompt;
const waitForSessionRetrying = common.waitForSessionRetrying;
const expectNewOutput = common.expectNewOutput;
const expectPromptConcurrencyQueueInvariant = common.expectPromptConcurrencyQueueInvariant;
const TS_RPC_EXTENSION_UI_PROTOCOL_FUZZ_SMOKE_SEED = common.TS_RPC_EXTENSION_UI_PROTOCOL_FUZZ_SMOKE_SEED;
const reportTsRpcExtensionUiFuzzFailure = common.reportTsRpcExtensionUiFuzzFailure;
const expectPromptLineTypeOrder = common.expectPromptLineTypeOrder;
const waitForSessionStreaming = common.waitForSessionStreaming;
const waitForActiveBashStarted = common.waitForActiveBashStarted;
const waitForServerOutputContains = common.waitForServerOutputContains;
const blockingUntilAbortStream = common.blockingUntilAbortStream;
const sessionLifecycleCaptureScript = common.sessionLifecycleCaptureScript;
const countCapturedEvents = common.countCapturedEvents;
const findEventLine = common.findEventLine;
const expectEventOrder = common.expectEventOrder;
const wfcBashToolExecute = common.wfcBashToolExecute;

test "command_context: waitForIdle does not queue when agent is idle" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-wfi-idle",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // Agent is idle (not streaming). The request should be handled immediately
    // without being queued into pending_wait_for_idle_ids.
    var req = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfi-1"),
        .method = try allocator.dupe(u8, "wait_for_idle"),
        .response_required = true,
        .payload_json = try allocator.dupe(u8, "{}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);
    try std.testing.expectEqual(@as(usize, 0), server.pending_wait_for_idle_ids.items.len);
}

test "command_context: waitForIdle queues when streaming and resolves after idle" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-wfi-stream",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // Simulate the agent being busy.
    session.agent.is_streaming = true;

    var req = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfi-2"),
        .method = try allocator.dupe(u8, "wait_for_idle"),
        .response_required = true,
        .payload_json = try allocator.dupe(u8, "{}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);
    // Must be queued because the agent is busy.
    try std.testing.expectEqual(@as(usize, 1), server.pending_wait_for_idle_ids.items.len);

    // Agent becomes idle.
    session.agent.is_streaming = false;

    // The idle-tick resolves all pending wait_for_idle requests.
    try server.serviceExtensionHostIdleTick(0);
    try std.testing.expectEqual(@as(usize, 0), server.pending_wait_for_idle_ids.items.len);
}

test "command_context: sendCustomMessage creates session entry with correct fields" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-custom-msg",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    const payload = "{\"customType\":\"ext.test\",\"content\":\"hello from extension\",\"display\":true}";
    var req = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "scm-1"),
        .method = try allocator.dupe(u8, "send_custom_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, payload),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // Session must contain a custom_message entry with the correct customType and content.
    const entries = session.session_manager.getEntries();
    var found = false;
    for (entries) |entry| {
        switch (entry) {
            .custom_message => |cm| {
                if (!std.mem.eql(u8, cm.custom_type, "ext.test")) continue;
                found = true;
                switch (cm.content) {
                    .text => |t| try std.testing.expectEqualStrings("hello from extension", t),
                    .blocks => return error.UnexpectedContentType,
                }
                try std.testing.expect(cm.display);
            },
            else => {},
        }
    }
    try std.testing.expect(found);
}

test "command_context: sendCustomMessage respects deliverAs followUp when streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-custom-follow",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // Simulate agent streaming.
    session.agent.is_streaming = true;

    const payload = "{\"customType\":\"ext.note\",\"content\":\"follow-up note\",\"display\":false,\"deliverAs\":\"followUp\"}";
    var req = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "scm-fu"),
        .method = try allocator.dupe(u8, "send_custom_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, payload),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // The session entry must be present.
    const entries = session.session_manager.getEntries();
    var found = false;
    for (entries) |entry| {
        switch (entry) {
            .custom_message => |cm| {
                if (std.mem.eql(u8, cm.custom_type, "ext.note")) {
                    found = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found);
    // deliverAs followUp must have enqueued a message in the follow-up queue.
    try std.testing.expectEqual(@as(usize, 1), session.agent.followUpQueueLen());
}

test "command_context: sendUserMessage queues followUp when agent is streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-user-stream",
        .system_prompt = "test",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    // Simulate agent busy.
    session.agent.is_streaming = true;

    var req = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "sum-1"),
        .method = try allocator.dupe(u8, "send_user_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"text\":\"hello agent\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);
    // No deliverAs → defaults to followUp when streaming.
    try std.testing.expectEqual(@as(usize, 1), session.agent.followUpQueueLen());
}

test "command_context: sendUserMessage starts background prompt when agent is idle" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("response from extension"),
        }, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/cmd-ctx-user-idle",
        .system_prompt = "test",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    var req = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "sum-idle"),
        .method = try allocator.dupe(u8, "send_user_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"text\":\"trigger a turn\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // A background prompt task must have been spawned.
    try std.testing.expectEqual(@as(usize, 1), server.prompt_tasks.items.len);

    // Wait for the task to complete.
    try waitForNoInFlightPrompt(&server, 2000);

    // Session must now have a user message and an assistant response.
    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expect(messages[0] == .user);
    try std.testing.expect(messages[1] == .assistant);
}

// ---------------------------------------------------------------------------
// Wire-format cleanup regression tests (items 1-7).
// All test names begin with "wire_format_cleanup" for --test-filter matching.
// ---------------------------------------------------------------------------
