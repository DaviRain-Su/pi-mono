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

test "wire_format_cleanup: tool_result frame carries call args as input and skips non-text blocks" {
    // Items 2 & 3: tool_result.input must contain the original call args;
    // thinking and tool_call content blocks must be skipped (not emitted as empty text).
    // Drives through the real agent loop via faux provider tool dispatch to verify that
    // emitToolCallOutcome populates .args = tool_call.arguments on the tool_execution_end
    // event, which emitExtensionToolResultEvent then serializes as "input".
    const allocator = std.testing.allocator;

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    // Faux response 1: bash tool call with args {"command":"echo hello"}.
    // Faux response 2: plain text after tool result is fed back.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"command\":\"echo hello\"}", .{});
    const args_value = parsed_args.value;
    const tool_call_block = try ai.providers.faux.fauxToolCall(arena.allocator(), "bash", args_value, .{ .id = "tc-wfc-1" });
    const response_blocks = [_]ai.providers.faux.FauxContentBlock{tool_call_block};
    const text_blocks = [_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("done")};
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&response_blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&text_blocks, .{}) },
    });

    const capture_path = "/tmp/pi-wfc-tool-result.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{capture_path},
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-wfc-tool-result" };

    // wfcBashToolExecute returns text "hello" + a thinking block.
    // The thinking block must be skipped by emitExtensionToolResultEvent.
    const bash_tool = agent.AgentTool{
        .name = "bash",
        .description = "Run bash commands",
        .label = "Bash",
        .parameters = .null,
        .execute = wfcBashToolExecute,
    };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/wfc-tool-result",
        .system_prompt = "test",
        .model = registration.getModel(),
        .tools = &[_]agent.AgentTool{bash_tool},
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-wfc-tool-result",
        .fixture = "wfc-tool-result",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    // Trigger the agent loop via a prompt; the faux provider will issue the tool call.
    try server.handleLine("{\"id\":\"p1\",\"type\":\"prompt\",\"message\":\"run a command\"}");
    try waitForNoInFlightPrompt(&server, 5000);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // The tool_result extension event must carry the original call args as "input".
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"input\":{\"command\":\"echo hello\"}") != null);
    // Text content must appear in the tool_result "content" array; thinking block must be
    // skipped (not emitted) — verify by asserting the exact content array value on the
    // tool_result line (a thinking block converted to empty text would break this match).
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]") != null);
}

// Tool execute function for the wire_format_cleanup tool_result test.
// Returns text "hello" + a thinking block to verify that thinking blocks are
// skipped (not emitted as empty text) in tool_result extension event frames.
test "wire_format_cleanup: send_custom_message nextTurn returns error without persisting message" {
    // Items 5 & 7: deliverAs="nextTurn" must be rejected; the message must NOT be persisted.
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/wfc-custom-next-turn",
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

    var req = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfc-next-1"),
        .method = try allocator.dupe(u8, "send_custom_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"customType\":\"test.msg\",\"content\":\"hello\",\"deliverAs\":\"nextTurn\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // The message must NOT be persisted — nextTurn is rejected before appendCustomMessageEntry.
    try std.testing.expectEqual(@as(usize, 0), session.session_manager.getEntries().len);
}

test "wire_format_cleanup: send_user_message nextTurn does not queue the message" {
    // Items 5 & 7: deliverAs="nextTurn" for send_user_message must return early without queuing.
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/wfc-user-next-turn",
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

    // Simulate agent busy so follow-up queuing would normally happen.
    session.agent.is_streaming = true;

    var req = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfc-user-nt"),
        .method = try allocator.dupe(u8, "send_user_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"text\":\"hello\",\"deliverAs\":\"nextTurn\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // Nothing must be queued since nextTurn is explicitly rejected.
    try std.testing.expectEqual(@as(usize, 0), session.agent.followUpQueueLen());
}

test "wire_format_cleanup: send_custom_message malformed customType returns without persisting" {
    // Item 5: when customType is a non-string value, an error frame is returned and
    // the message is NOT persisted (early return before appendCustomMessageEntry).
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/wfc-custom-badtype",
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

    // customType is a number (not a string) — malformed payload.
    var req = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "wfc-bad-type"),
        .method = try allocator.dupe(u8, "send_custom_message"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"customType\":123,\"content\":\"hello\"}"),
    };
    defer req.deinit(allocator);

    try server.writeExtensionUIRequestFromHost(req);

    // Message must NOT be persisted since the error is caught before appendCustomMessageEntry.
    try std.testing.expectEqual(@as(usize, 0), session.session_manager.getEntries().len);
}
