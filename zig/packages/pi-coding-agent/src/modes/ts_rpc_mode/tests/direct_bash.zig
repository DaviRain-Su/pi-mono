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

test "TS RPC direct bash success matches exact BashResult fixture bytes" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"bash_ok\",\"type\":\"bash\",\"command\":\"printf ok\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"bash_ok\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"ok\",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC finish waits for active direct bash result before cleanup" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
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

    try server.handleLine("{\"id\":\"bash_finish\",\"type\":\"bash\",\"command\":\"printf before; sleep 0.05; printf after\"}");
    try server.finish();

    try std.testing.expectEqualStrings(
        "{\"id\":\"bash_finish\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"beforeafter\",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
    try std.testing.expect(!server.hasActiveBashTask());
}

test "TS RPC direct bash failure is a successful BashResult response with exitCode" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"bash_fail\",\"type\":\"bash\",\"command\":\"printf fail; exit 7\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"bash_fail\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"fail\",\"exitCode\":7,\"cancelled\":false,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC direct bash sanitizes control and ANSI output before serializing BashResult" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"bash_sanitize\",\"type\":\"bash\",\"command\":\"printf 'a\\\\033[31mred\\\\033[0m\\\\001b\\\\r\\\\nc'\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"bash_sanitize\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"aredb\\nc\",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC direct bash preserves multibyte UTF-8 split across read boundary" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var command: std.Io.Writer.Allocating = .init(allocator);
    defer command.deinit();
    try command.writer.writeAll("printf '");
    for (0..4095) |_| try command.writer.writeByte('A');
    try command.writer.writeAll("💡END'");

    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    try line.writer.writeAll("{\"id\":\"bash_utf8_split\",\"type\":\"bash\",\"command\":");
    try writeJsonString(allocator, &line.writer, command.written());
    try line.writer.writeAll("}");

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{line.written()},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    var expected_output: std.Io.Writer.Allocating = .init(allocator);
    defer expected_output.deinit();
    for (0..4095) |_| try expected_output.writer.writeByte('A');
    try expected_output.writer.writeAll("💡END");

    var expected: std.Io.Writer.Allocating = .init(allocator);
    defer expected.deinit();
    try expected.writer.writeAll("{\"id\":\"bash_utf8_split\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":");
    try writeJsonString(allocator, &expected.writer, expected_output.written());
    try expected.writer.writeAll(",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n");

    try std.testing.expectEqualStrings(expected.written(), stdout_capture.writer.buffered());
    try expectContains(stdout_capture.writer.buffered(), "💡END");
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "�") == null);
}

test "TS RPC direct bash UTF-8 sanitizer flushes incomplete sequence at end of stream" {
    const allocator = std.testing.allocator;
    const sanitized = try ts_rpc_bash.sanitizeDirectBashOutput(allocator, &.{ 0xf0, 0x9f });
    defer allocator.free(sanitized);
    try std.testing.expectEqualStrings("�", sanitized);
}

test "TS RPC direct bash truncates large output and retains full output path" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"bash_big\",\"type\":\"bash\",\"command\":\"printf BEGIN; yes A | head -c 120000; printf END\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdout_capture.writer.buffered(), .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    const output = data.get("output").?.string;
    const full_output_path = data.get("fullOutputPath").?.string;
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, full_output_path) catch {};

    try std.testing.expect(data.get("truncated").?.bool);
    try std.testing.expect(output.len <= truncate.DEFAULT_MAX_BYTES);
    try expectContains(output, "END");
    try std.testing.expect(std.mem.indexOf(u8, output, "BEGIN") == null);
    try std.testing.expect(std.mem.startsWith(u8, full_output_path, "/tmp/pi-bash-"));

    const full_output = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, full_output_path, allocator, .limited(256 * 1024));
    defer allocator.free(full_output);
    try expectContains(full_output, "BEGIN");
    try expectContains(full_output, "END");
}

test "TS RPC abort_bash interrupts active direct bash and cleans tracked task" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
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

    try server.handleLine("{\"id\":\"bash_abort\",\"type\":\"bash\",\"command\":\"printf 'start\\n'; sleep 5; printf end\"}");
    try waitForActiveBashStarted(&server);
    std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
    try server.handleLine("{\"id\":\"abort\",\"type\":\"abort_bash\"}");
    try server.finish();

    try std.testing.expectEqualStrings(
        "{\"id\":\"abort\",\"type\":\"response\",\"command\":\"abort_bash\",\"success\":true}\n" ++
            "{\"id\":\"bash_abort\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"start\\n\",\"cancelled\":true,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
    try std.testing.expect(!server.hasActiveBashTask());
}

test "TS RPC command loop remains live while direct bash is active" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
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

    try server.handleLine("{\"id\":\"live_bash\",\"type\":\"bash\",\"command\":\"printf 'live\\n'; sleep 5; printf done\"}");
    try waitForActiveBashStarted(&server);
    std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
    try server.handleLine("{\"id\":\"live_commands\",\"type\":\"get_commands\"}");
    try waitForOutputContains(
        &server,
        &stdout_capture.writer,
        "{\"id\":\"live_commands\",\"type\":\"response\",\"command\":\"get_commands\",\"success\":true,\"data\":{\"commands\":[]}}\n",
        500,
    );
    try server.handleLine("{\"id\":\"live_abort\",\"type\":\"abort_bash\"}");
    try server.finish();

    try std.testing.expectEqualStrings(
        "{\"id\":\"live_commands\",\"type\":\"response\",\"command\":\"get_commands\",\"success\":true,\"data\":{\"commands\":[]}}\n" ++
            "{\"id\":\"live_abort\",\"type\":\"response\",\"command\":\"abort_bash\",\"success\":true}\n" ++
            "{\"id\":\"live_bash\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"live\\n\",\"cancelled\":true,\"truncated\":false}}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC bash cleanup releases task mutex before joining blocked completion" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
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

    server.deferred_responses_mutex.lockUncancelable(std.testing.io);
    var deferred_responses_locked = true;
    defer if (deferred_responses_locked) server.deferred_responses_mutex.unlock(std.testing.io);

    try server.handleLine("{\"id\":\"cleanup_bash\",\"type\":\"bash\",\"command\":\"printf cleanup\"}");
    try waitForActiveBashStarted(&server);

    const task = server.bash_manager.firstTaskForTest().?;

    const CancelContext = struct {
        server: *TsRpcServer,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(context: *@This()) void {
            context.server.cancelAndJoinBashTasks();
            context.done.store(true, .seq_cst);
        }
    };
    var cancel_context = CancelContext{ .server = &server };
    const cancel_thread = try std.Thread.spawn(.{}, CancelContext.run, .{&cancel_context});

    var abort_spins: usize = 0;
    while (!task.isAbortRequestedForTest() and abort_spins < 1000) : (abort_spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    const cleanup_reached_join = task.isAbortRequestedForTest();

    const ProbeContext = struct {
        server: *TsRpcServer,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(context: *@This()) void {
            _ = context.server.hasUnfinishedBashTask();
            context.done.store(true, .seq_cst);
        }
    };
    var probe_context = ProbeContext{ .server = &server };
    const probe_thread = try std.Thread.spawn(.{}, ProbeContext.run, .{&probe_context});

    var probe_spins: usize = 0;
    while (!probe_context.done.load(.seq_cst) and probe_spins < 100) : (probe_spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    const probe_completed_before_join_unblocked = probe_context.done.load(.seq_cst);

    server.deferred_responses_mutex.unlock(std.testing.io);
    deferred_responses_locked = false;
    cancel_thread.join();
    probe_thread.join();

    try std.testing.expect(cleanup_reached_join);
    try std.testing.expect(probe_completed_before_join_unblocked);
    try std.testing.expect(cancel_context.done.load(.seq_cst));
    try std.testing.expect(!server.hasActiveBashTask());
}

test "TS RPC production bash-control script matches generated TypeScript fixture bytes" {
    const allocator = std.testing.allocator;
    const start_marker = try allocator.dupe(u8, "/tmp/pi-ts-rpc-bash-control-start");
    defer allocator.free(start_marker);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, start_marker) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, start_marker) catch {};
    const live_marker = try allocator.dupe(u8, "/tmp/pi-ts-rpc-bash-control-live");
    defer allocator.free(live_marker);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, live_marker) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, live_marker) catch {};

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var bash_abort_command = std.Io.Writer.Allocating.init(allocator);
    defer bash_abort_command.deinit();
    try bash_abort_command.writer.print("printf 'start\\n'; touch {s}; sleep 5; printf end", .{start_marker});
    var bash_abort_line = std.Io.Writer.Allocating.init(allocator);
    defer bash_abort_line.deinit();
    try bash_abort_line.writer.writeAll("{\"id\":\"bash_abort\",\"type\":\"bash\",\"command\":");
    try writeJsonString(allocator, &bash_abort_line.writer, bash_abort_command.written());
    try bash_abort_line.writer.writeAll("}");

    var live_command = std.Io.Writer.Allocating.init(allocator);
    defer live_command.deinit();
    try live_command.writer.print("printf 'live\\n'; touch {s}; sleep 5; printf done", .{live_marker});
    var live_line = std.Io.Writer.Allocating.init(allocator);
    defer live_line.deinit();
    try live_line.writer.writeAll("{\"id\":\"live_bash\",\"type\":\"bash\",\"command\":");
    try writeJsonString(allocator, &live_line.writer, live_command.written());
    try live_line.writer.writeAll("}");

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"bash_ok\",\"type\":\"bash\",\"command\":\"printf ok\"}");
    try server.handleLine("{\"id\":\"bash_fail\",\"type\":\"bash\",\"command\":\"printf fail; exit 7\"}");
    try server.handleLine(bash_abort_line.written());
    try waitForAbsoluteFile(start_marker, 500);
    try server.handleLine("{\"id\":\"abort\",\"type\":\"abort_bash\"}");
    try server.handleLine(live_line.written());
    try waitForAbsoluteFile(live_marker, 500);
    try server.handleLine("{\"id\":\"live_commands\",\"type\":\"get_commands\"}");
    try server.handleLine("{\"id\":\"live_abort\",\"type\":\"abort_bash\"}");
    try server.finish();

    const expected = try readFixture("bash-control.jsonl");
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, stdout_capture.writer.buffered());
}
