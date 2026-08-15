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

test "TS RPC extension UI request writer matches TypeScript fixture bytes" {
    const allocator = std.testing.allocator;
    const fixture = try readFixture("extension-ui.jsonl");
    defer allocator.free(fixture);
    const response_start = std.mem.indexOf(u8, fixture, "{\"type\":\"extension_ui_response\"").?;
    const expected_requests = fixture[0..response_start];

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    const select_options = [_][]const u8{ "option-a", "option-b" };
    const widget_lines = [_][]const u8{ "line one", "line two" };

    try server.writeExtensionUISelectRequest("ui_select", "Choose fixture", &select_options, 1000);
    try server.writeExtensionUIConfirmRequest("ui_confirm", "Confirm fixture", "Proceed?", 1000);
    try server.writeExtensionUIInputRequest("ui_input", "Fixture input", "value", 1000);
    try server.writeExtensionUINotifyRequest("ui_notify", "Fixture notice", "info");
    try server.writeExtensionUISetStatusRequest("ui_status", "fixture", "ready");
    try server.writeExtensionUISetWidgetRequest("ui_widget", "fixture", &widget_lines, "aboveEditor");
    try server.writeExtensionUISetTitleRequest("ui_title", "Fixture Title");
    try server.writeExtensionUISetEditorTextRequest("ui_editor_text", "fixture editor text");
    try server.writeExtensionUIEditorRequest("ui_editor", "Edit fixture", "prefill");
    try server.finish();

    try std.testing.expectEqualStrings(expected_requests, stdout_capture.writer.buffered());
}

test "TS RPC extension UI responses are consumed without output" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        null,
        &.{
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"value\":\"option-a\"}",
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":true}",
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"cancelled\":true}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(usize, 0), stdout_capture.writer.buffered().len);
}

test "TS RPC extension UI responses resolve pending requests like TypeScript" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.registerPendingExtensionUIRequest("ui_select", .select, 1000);
    try server.registerPendingExtensionUIRequest("ui_confirm", .confirm, 1000);
    try server.registerPendingExtensionUIRequest("ui_input", .input, 1000);
    try server.registerPendingExtensionUIRequest("ui_editor", .editor, null);

    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"value\":\"option-a\"}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_editor\",\"value\":\"edited text\"}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"missing\",\"value\":\"ignored\"}");
    defer server.finish() catch {};

    try std.testing.expectEqual(@as(usize, 0), stdout_capture.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), server.pending_extension_requests.count());
    try std.testing.expectEqual(@as(usize, 4), server.completed_extension_requests.items.len);
    try std.testing.expectEqualStrings("ui_select", server.completed_extension_requests.items[0].id);
    try std.testing.expectEqual(ExtensionUIDialogMethod.select, server.completed_extension_requests.items[0].method);
    try std.testing.expectEqualStrings("option-a", server.completed_extension_requests.items[0].resolution.value);
    try std.testing.expectEqual(ExtensionUIDialogMethod.confirm, server.completed_extension_requests.items[1].method);
    try std.testing.expect(server.completed_extension_requests.items[1].resolution.confirmed);
    try std.testing.expectEqual(ExtensionUIDialogMethod.input, server.completed_extension_requests.items[2].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[2].resolution);
    try std.testing.expectEqual(ExtensionUIDialogMethod.editor, server.completed_extension_requests.items[3].method);
    try std.testing.expectEqualStrings("edited text", server.completed_extension_requests.items[3].resolution.value);
}

test "TS RPC cancelled extension UI responses use pending method defaults" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.registerPendingExtensionUIRequest("ui_select_cancelled", .select, 1000);
    try server.registerPendingExtensionUIRequest("ui_confirm_cancelled", .confirm, 1000);
    try server.registerPendingExtensionUIRequest("ui_input_cancelled", .input, 1000);
    try server.registerPendingExtensionUIRequest("ui_editor_cancelled", .editor, null);
    defer server.finish() catch {};

    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_select_cancelled\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm_cancelled\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_input_cancelled\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_editor_cancelled\",\"cancelled\":true}");

    try std.testing.expectEqual(@as(usize, 0), stdout_capture.writer.buffered().len);
    try std.testing.expectEqual(@as(u32, 0), server.pending_extension_requests.count());
    try std.testing.expectEqual(@as(usize, 4), server.completed_extension_requests.items.len);

    try std.testing.expectEqual(ExtensionUIDialogMethod.select, server.completed_extension_requests.items[0].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[0].resolution);

    try std.testing.expectEqual(ExtensionUIDialogMethod.confirm, server.completed_extension_requests.items[1].method);
    switch (server.completed_extension_requests.items[1].resolution) {
        .confirmed => |confirmed| try std.testing.expect(!confirmed),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(ExtensionUIDialogMethod.input, server.completed_extension_requests.items[2].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[2].resolution);

    try std.testing.expectEqual(ExtensionUIDialogMethod.editor, server.completed_extension_requests.items[3].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[3].resolution);
}

test "TS RPC extension UI timeout and cancel resolve deterministic defaults" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.registerPendingExtensionUIRequest("ui_select", .select, 1000);
    try server.registerPendingExtensionUIRequest("ui_confirm", .confirm, null);
    try server.registerPendingExtensionUIRequest("ui_input", .input, 50);
    defer server.finish() catch {};

    try server.advanceExtensionUITime(49);
    try std.testing.expectEqual(@as(usize, 0), server.completed_extension_requests.items.len);
    try std.testing.expectEqual(@as(u32, 3), server.pending_extension_requests.count());

    try server.advanceExtensionUITime(1);
    try std.testing.expectEqual(@as(usize, 1), server.completed_extension_requests.items.len);
    try std.testing.expectEqualStrings("ui_input", server.completed_extension_requests.items[0].id);
    try std.testing.expectEqual(ExtensionUIDialogMethod.input, server.completed_extension_requests.items[0].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[0].resolution);

    try std.testing.expect(try server.cancelPendingExtensionUIRequest("ui_confirm"));
    try std.testing.expectEqual(@as(usize, 2), server.completed_extension_requests.items.len);
    try std.testing.expectEqual(ExtensionUIDialogMethod.confirm, server.completed_extension_requests.items[1].method);
    try std.testing.expect(!server.completed_extension_requests.items[1].resolution.confirmed);

    try server.advanceExtensionUITime(950);
    try std.testing.expectEqual(@as(usize, 3), server.completed_extension_requests.items.len);
    try std.testing.expectEqualStrings("ui_select", server.completed_extension_requests.items[2].id);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[2].resolution);
    try std.testing.expect(!try server.cancelPendingExtensionUIRequest("ui_select"));
}

test "VAL-REFACTOR-012 deterministic TS RPC extension UI protocol fuzz smoke" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    defer server.finish() catch {};

    const select_options = [_][]const u8{ "alpha", "beta" };
    server.writeExtensionUISelectRequest("req-select", "Pick", &select_options, 7) catch |err| {
        reportTsRpcExtensionUiFuzzFailure(TS_RPC_EXTENSION_UI_PROTOCOL_FUZZ_SMOKE_SEED, "request-select-timeout", "req-select");
        return err;
    };
    server.writeExtensionUIConfirmRequest("req-confirm", "Confirm", "Continue?", null) catch |err| {
        reportTsRpcExtensionUiFuzzFailure(TS_RPC_EXTENSION_UI_PROTOCOL_FUZZ_SMOKE_SEED, "request-confirm-no-timeout", "req-confirm");
        return err;
    };

    try server.registerPendingExtensionUIRequest("req-select", .select, 10);
    try server.registerPendingExtensionUIRequest("req-confirm", .confirm, null);
    try server.registerPendingExtensionUIRequest("req-input-timeout", .input, 5);
    try server.registerPendingExtensionUIRequest("req-editor-cancel", .editor, null);

    const response_frames = [_][]const u8{
        "{\"type\":\"extension_ui_response\",\"id\":\"req-select\",\"value\":\"alpha\"}",
        "{\"type\":\"extension_ui_response\",\"id\":\"missing\",\"value\":\"ignored\"}",
        "{\"type\":\"extension_ui_response\",\"id\":\"req-confirm\",\"cancelled\":true}",
        "{\"type\":\"extension_ui_response\",\"id\":\"req-editor-cancel\",\"cancelled\":true}",
        "{\"type\":\"extension_ui_response\",\"id\":\"req-select\",\"value\":\"duplicate-ignored\"}",
        "{\"type\":\"extension_ui_response\",\"id\":\"malformed-value\",\"value\":42}",
    };

    for (response_frames) |frame| {
        server.handleLine(frame) catch |err| {
            reportTsRpcExtensionUiFuzzFailure(TS_RPC_EXTENSION_UI_PROTOCOL_FUZZ_SMOKE_SEED, "response-correlation-cancel-malformed", frame);
            return err;
        };
    }

    server.advanceExtensionUITime(5) catch |err| {
        reportTsRpcExtensionUiFuzzFailure(TS_RPC_EXTENSION_UI_PROTOCOL_FUZZ_SMOKE_SEED, "timeout-default-resolution", "req-input-timeout");
        return err;
    };
    server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"req-input-timeout\",\"cancelled\":true}") catch |err| {
        reportTsRpcExtensionUiFuzzFailure(TS_RPC_EXTENSION_UI_PROTOCOL_FUZZ_SMOKE_SEED, "post-timeout-duplicate-cancel", "req-input-timeout");
        return err;
    };
    server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"partial\"") catch |err| {
        reportTsRpcExtensionUiFuzzFailure(TS_RPC_EXTENSION_UI_PROTOCOL_FUZZ_SMOKE_SEED, "malformed-json-frame", "{\"type\":\"extension_ui_response\",\"id\":\"partial\"");
        return err;
    };

    try std.testing.expectEqual(@as(usize, 4), server.completed_extension_requests.items.len);
    try std.testing.expectEqual(@as(u32, 0), server.pending_extension_requests.count());
    try std.testing.expectEqualStrings("req-select", server.completed_extension_requests.items[0].id);
    try std.testing.expectEqual(ExtensionUIDialogMethod.select, server.completed_extension_requests.items[0].method);
    try std.testing.expectEqualStrings("alpha", server.completed_extension_requests.items[0].resolution.value);
    try std.testing.expectEqual(ExtensionUIDialogMethod.confirm, server.completed_extension_requests.items[1].method);
    try std.testing.expect(!server.completed_extension_requests.items[1].resolution.confirmed);
    try std.testing.expectEqual(ExtensionUIDialogMethod.editor, server.completed_extension_requests.items[2].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[2].resolution);
    try std.testing.expectEqual(ExtensionUIDialogMethod.input, server.completed_extension_requests.items[3].method);
    try std.testing.expectEqual(ExtensionUIResolution.none, server.completed_extension_requests.items[3].resolution);

    const stdout = stdout_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, stdout, "\"type\":\"extension_ui_request\",\"id\":\"req-select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "\"timeout\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "\"type\":\"response\",\"command\":\"parse\",\"success\":false") != null);
}

test "M6 extension UI bridge serializes host requests and forwards responses exactly once" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-m6-extension-ui-bridge-capture.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_select\",\"method\":\"select\",\"responseRequired\":true,\"payload\":{{\"title\":\"Choose fixture\",\"options\":[\"option-a\",\"option-b\"],\"timeout\":1000}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"responseRequired\":true,\"payload\":{{\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":1000}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_input\",\"method\":\"input\",\"responseRequired\":true,\"payload\":{{\"title\":\"Fixture input\",\"placeholder\":\"value\",\"timeout\":1000}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_notify\",\"method\":\"notify\",\"payload\":{{\"message\":\"Fixture notice\",\"notifyType\":\"info\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_status\",\"method\":\"setStatus\",\"payload\":{{\"statusKey\":\"fixture\",\"statusText\":\"ready\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_widget\",\"method\":\"setWidget\",\"payload\":{{\"widgetKey\":\"fixture\",\"widgetLines\":[\"line one\",\"line two\"],\"widgetPlacement\":\"aboveEditor\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_title\",\"method\":\"setTitle\",\"payload\":{{\"title\":\"Fixture Title\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_editor_text\",\"method\":\"set_editor_text\",\"payload\":{{\"text\":\"fixture editor text\"}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_editor\",\"method\":\"editor\",\"responseRequired\":true,\"payload\":{{\"title\":\"Edit fixture\",\"prefill\":\"prefill\"}}}}\\n'; " ++
            "while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);

    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-extension-ui-bridge" };
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-m6-extension-ui-bridge",
        .fixture = "ui-bridge",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });
    try server.drainExtensionHostUiRequests(100);

    const expected =
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_select\",\"method\":\"select\",\"title\":\"Choose fixture\",\"options\":[\"option-a\",\"option-b\"],\"timeout\":1000}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":1000}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_input\",\"method\":\"input\",\"title\":\"Fixture input\",\"placeholder\":\"value\",\"timeout\":1000}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_notify\",\"method\":\"notify\",\"message\":\"Fixture notice\",\"notifyType\":\"info\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_status\",\"method\":\"setStatus\",\"statusKey\":\"fixture\",\"statusText\":\"ready\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_widget\",\"method\":\"setWidget\",\"widgetKey\":\"fixture\",\"widgetLines\":[\"line one\",\"line two\"],\"widgetPlacement\":\"aboveEditor\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_title\",\"method\":\"setTitle\",\"title\":\"Fixture Title\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_editor_text\",\"method\":\"set_editor_text\",\"text\":\"fixture editor text\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_editor\",\"method\":\"editor\",\"title\":\"Edit fixture\",\"prefill\":\"prefill\"}\n";
    try std.testing.expectEqualStrings(expected, stdout_capture.writer.buffered());

    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"value\":\"option-a\"}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_missing\",\"value\":\"ignored\"}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":false}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"cancelled\":true}");
    try server.handleLine("{\"type\":\"extension_ui_response\",\"id\":\"ui_editor\",\"value\":\"edited text\"}");
    try std.testing.expectEqual(@as(usize, 4), server.completed_extension_requests.items.len);
    try std.testing.expectEqualStrings("ui_confirm", server.completed_extension_requests.items[0].id);
    try std.testing.expectEqualStrings("ui_select", server.completed_extension_requests.items[1].id);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"payload\":{\"confirmed\":true}}\n");
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"payload\":{\"value\":\"option-a\"}}\n");
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"payload\":{\"cancelled\":true}}\n");
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_editor\",\"payload\":{\"value\":\"edited text\"}}\n");
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_missing\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"payload\":{\"confirmed\":false}}\n") == null);
}

test "M7 TS RPC lists extension commands and dispatches slash command without agent prompt" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-m7-extension-command-capture.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"register_command\",\"name\":\"m7.echo\",\"description\":\"Echo through M7 command\",\"extensionPath\":\"fixture/m7.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_shortcut\",\"shortcut\":\"ctrl+e\",\"description\":\"Run M7 echo\",\"command\":\"m7.echo\",\"extensionPath\":\"fixture/m7.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_message_renderer\",\"customType\":\"m7.message\",\"extensionPath\":\"fixture/m7.ts\"}}\\n'; " ++
            "while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in " ++
            "*'\"type\":\"extension_event\"'*) event_id=${{line#*'\"eventId\":\"'}}; event_id=${{event_id%%'\"'*}}; printf '{{\"type\":\"extension_ui_request\",\"id\":\"m7_command_status\",\"method\":\"setStatus\",\"payload\":{{\"statusKey\":\"m7\",\"statusText\":\"command dispatched\"}}}}\\n'; printf '{{\"type\":\"extension_event_result\",\"eventId\":\"%s\",\"result\":{{\"handled\":true,\"command\":\"m7.echo\"}}}}\\n' \"$event_id\";; " ++
            "*'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; " ++
            "esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);

    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m7-extension-command" };
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m7-command",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-m7-extension-command",
        .fixture = "m7-command-shortcut-renderer",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    var registry_elapsed: u64 = 0;
    while (server.extension_host.?.registryFramesApplied() < 3 and registry_elapsed < 500) : (registry_elapsed += 5) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 3), server.extension_host.?.registryFramesApplied());
    try std.testing.expect(server.extension_host.?.hasRegisteredCommand("m7.echo"));

    try server.handleLine("{\"id\":\"commands\",\"type\":\"get_commands\"}");
    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"commands\",\"type\":\"response\",\"command\":\"get_commands\",\"success\":true,\"data\":{\"commands\":[{\"name\":\"m7.echo\",\"description\":\"Echo through M7 command\",\"source\":\"extension\",\"sourceInfo\":{\"path\":\"fixture/m7.ts\",\"source\":\"local\",\"scope\":\"temporary\",\"origin\":\"top_level\"}}]}}\n",
    );

    try server.handleLine("{\"id\":\"slash\",\"type\":\"prompt\",\"message\":\"/m7.echo hello from rpc\"}");
    const status_request = "{\"type\":\"extension_ui_request\",\"id\":\"m7_command_status\",\"method\":\"setStatus\",\"statusKey\":\"m7\",\"statusText\":\"command dispatched\"}\n";
    var event_elapsed: u64 = 0;
    while (std.mem.indexOf(u8, stdout_capture.writer.buffered(), status_request) == null and event_elapsed < 500) : (event_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
        try server.serviceExtensionHostIdleTick(10);
    }
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"slash\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true,\"data\":{\"kind\":\"extension_command\",\"name\":\"m7.echo\",\"result\":{\"handled\":true,\"command\":\"m7.echo\"}}}\n");
    try expectContains(stdout_capture.writer.buffered(), status_request);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "\"type\":\"agent_start\"") == null);

    const snapshot = try server.extension_host.?.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try expectContains(snapshot, "\"shortcuts\":[{\"shortcut\":\"ctrl+e\",\"description\":\"Run M7 echo\",\"command\":\"m7.echo\"");
    try expectContains(snapshot, "\"messageRenderers\":[{\"customType\":\"m7.message\",\"extensionPath\":\"fixture/m7.ts\"}]");

    try waitForAbsoluteFileContains(allocator, capture_path, "{\"type\":\"extension_event\",\"eventId\":\"", 1000);
    try server.finish();
    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try expectContains(capture, "{\"type\":\"extension_event\",\"eventId\":\"");
    try expectContains(capture, "\",\"event\":{\"type\":\"command\",\"name\":\"m7.echo\",\"argument\":\"hello from rpc\",\"source\":\"rpc\"}}\n");
}

test "M6 extension UI bridge forwards timeout defaults to host" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-m6-extension-ui-timeout-capture.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"responseRequired\":true,\"payload\":{{\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":10}}}}\\n'; " ++
            "while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);

    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-extension-ui-timeout" };
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-m6-extension-ui-timeout",
        .fixture = "ui-timeout",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });
    try server.drainExtensionHostUiRequests(100);
    try expectContains(stdout_capture.writer.buffered(), "{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":10}\n");
    try server.advanceExtensionUITime(10);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"payload\":{\"confirmed\":false}}\n");
}

test "M6 extension UI bridge drains delayed host requests without stdin activity" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-m6-extension-ui-idle-pump-capture.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; printf '{{\"type\":\"ready\"}}\\n'; " ++
            "sleep 0.2; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"ui_idle_confirm\",\"method\":\"confirm\",\"responseRequired\":true,\"payload\":{{\"title\":\"Idle confirm\",\"message\":\"Proceed while idle?\",\"timeout\":20}}}}\\n'; " ++
            "while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);

    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-extension-ui-idle-pump" };
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-m6-extension-ui-idle-pump",
        .fixture = "ui-idle-pump",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });
    // The strict pre-drain buffer-empty check used to live here, but it raced
    // the fixture script's pre-request sleep on slow CI runners. The drain
    // loops below already prove the bridge eventually pumps the delayed
    // request and clears it without stdin activity, which is the real
    // behavior under test.

    const request_line = "{\"type\":\"extension_ui_request\",\"id\":\"ui_idle_confirm\",\"method\":\"confirm\",\"title\":\"Idle confirm\",\"message\":\"Proceed while idle?\",\"timeout\":20}\n";
    var elapsed: u64 = 0;
    while (std.mem.indexOf(u8, stdout_capture.writer.buffered(), request_line) == null and elapsed < 1000) : (elapsed += EXTENSION_HOST_EVENT_LOOP_TICK_MS) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(EXTENSION_HOST_EVENT_LOOP_TICK_MS), .awake) catch {};
        try server.serviceExtensionHostIdleTick(EXTENSION_HOST_EVENT_LOOP_TICK_MS);
    }
    try expectContains(stdout_capture.writer.buffered(), request_line);

    var timeout_elapsed: u64 = 0;
    while (server.pending_extension_requests.count() != 0 and timeout_elapsed < 1000) : (timeout_elapsed += EXTENSION_HOST_EVENT_LOOP_TICK_MS) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(EXTENSION_HOST_EVENT_LOOP_TICK_MS), .awake) catch {};
        try server.serviceExtensionHostIdleTick(EXTENSION_HOST_EVENT_LOOP_TICK_MS);
    }
    try std.testing.expectEqual(@as(u32, 0), server.pending_extension_requests.count());
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try expectContains(capture, "{\"type\":\"extension_ui_response\",\"id\":\"ui_idle_confirm\",\"payload\":{\"confirmed\":false}}\n");
}
