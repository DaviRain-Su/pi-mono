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

test "TS RPC M2 get_state get_messages and get_commands use TS response bytes" {
    const allocator = std.testing.allocator;
    const model = ai.Model{
        .id = "fixture-model",
        .name = "Fixture Model",
        .api = "faux",
        .provider = "faux",
        .base_url = "https://example.invalid",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1234,
        .max_tokens = 321,
    };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
        .model = model,
        .thinking_level = .high,
    });
    defer session.deinit();
    _ = try session.session_manager.appendSessionInfo("fixture session");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "hello" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "hi" } };
    try session.agent.setMessages(&[_]agent.AgentMessage{
        .{ .user = .{ .content = user_content, .timestamp = 11 } },
        .{ .assistant = .{
            .content = assistant_content,
            .api = "faux",
            .provider = "faux",
            .model = "fixture-model",
            .usage = .{ .input = 1, .output = 2, .cache_read = 3, .cache_write = 4, .total_tokens = 10 },
            .stop_reason = .stop,
            .timestamp = 12,
        } },
    });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"state\",\"type\":\"get_state\"}",
            "{\"id\":\"messages\",\"type\":\"get_messages\"}",
            "{\"id\":\"commands\",\"type\":\"get_commands\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const expected = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"state\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{{\"model\":{{\"id\":\"fixture-model\",\"name\":\"Fixture Model\",\"api\":\"faux\",\"provider\":\"faux\",\"baseUrl\":\"https://example.invalid\",\"reasoning\":true,\"input\":[\"text\",\"image\"],\"cost\":{{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0}},\"contextWindow\":1234,\"maxTokens\":321}},\"thinkingLevel\":\"high\",\"isStreaming\":false,\"isCompacting\":false,\"steeringMode\":\"one-at-a-time\",\"followUpMode\":\"one-at-a-time\",\"sessionId\":\"{s}\",\"sessionName\":\"fixture session\",\"autoCompactionEnabled\":false,\"messageCount\":2,\"pendingMessageCount\":0}}}}\n" ++
            "{{\"id\":\"messages\",\"type\":\"response\",\"command\":\"get_messages\",\"success\":true,\"data\":{{\"messages\":[{{\"role\":\"user\",\"content\":\"hello\",\"timestamp\":11}},{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":\"hi\"}}],\"api\":\"faux\",\"provider\":\"faux\",\"model\":\"fixture-model\",\"usage\":{{\"input\":1,\"output\":2,\"cacheRead\":3,\"cacheWrite\":4,\"totalTokens\":10,\"cost\":{{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}}}},\"stopReason\":\"stop\",\"timestamp\":12}}]}}}}\n" ++
            "{{\"id\":\"commands\",\"type\":\"response\",\"command\":\"get_commands\",\"success\":true,\"data\":{{\"commands\":[]}}}}\n",
        .{session.session_manager.getSessionId()},
    );
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, stdout_capture.writer.buffered());
}

test "TS RPC M2 steer follow_up and abort controls use TS responses and queue updates" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
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
        &.{
            "{\"id\":\"s\",\"type\":\"steer\",\"message\":\"steer now\"}",
            "{\"id\":\"f\",\"type\":\"follow_up\",\"message\":\"follow later\"}",
            "{\"id\":\"a\",\"type\":\"abort\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"type\":\"queue_update\",\"steering\":[\"steer now\"],\"followUp\":[]}\n" ++
            "{\"id\":\"s\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer now\"],\"followUp\":[\"follow later\"]}\n" ++
            "{\"id\":\"f\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n" ++
            "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC M3 model thinking and queue controls use TS response bytes" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m3",
        .system_prompt = "system",
        .model = ai.model_registry.getDefault().find("faux", "faux-1").?,
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
        &.{
            "{\"id\":\"model\",\"type\":\"set_model\",\"provider\":\"anthropic\",\"modelId\":\"claude-sonnet-4-5\"}",
            "{\"id\":\"missing\",\"type\":\"set_model\",\"provider\":\"anthropic\",\"modelId\":\"missing-model\"}",
            "{\"id\":\"cycle_model\",\"type\":\"cycle_model\"}",
            "{\"id\":\"think\",\"type\":\"set_thinking_level\",\"level\":\"high\"}",
            "{\"id\":\"cycle_think\",\"type\":\"cycle_thinking_level\"}",
            "{\"id\":\"steer_mode\",\"type\":\"set_steering_mode\",\"mode\":\"all\"}",
            "{\"id\":\"follow_mode\",\"type\":\"set_follow_up_mode\",\"mode\":\"one-at-a-time\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"model\",\"type\":\"response\",\"command\":\"set_model\",\"success\":true,\"data\":{\"id\":\"claude-sonnet-4-5\",\"name\":\"Claude Sonnet 4.5 (latest)\",\"api\":\"anthropic-messages\",\"provider\":\"anthropic\",\"baseUrl\":\"https://api.anthropic.com\",\"reasoning\":true,\"input\":[\"text\",\"image\"],\"cost\":{\"input\":3,\"output\":15,\"cacheRead\":0.3,\"cacheWrite\":3.75},\"contextWindow\":200000,\"maxTokens\":64000}}\n",
    );
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"missing\",\"type\":\"response\",\"command\":\"set_model\",\"success\":false,\"error\":\"Model not found: anthropic/missing-model\"}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"cycle_model\",\"type\":\"response\",\"command\":\"cycle_model\",\"success\":true,\"data\":null}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"think\",\"type\":\"response\",\"command\":\"set_thinking_level\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"cycle_think\",\"type\":\"response\",\"command\":\"cycle_thinking_level\",\"success\":true,\"data\":{\"level\":\"off\"}}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"steer_mode\",\"type\":\"response\",\"command\":\"set_steering_mode\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"follow_mode\",\"type\":\"response\",\"command\":\"set_follow_up_mode\",\"success\":true}\n");
    try std.testing.expectEqual(agent.QueueMode.all, session.agent.steering_queue.mode);
    try std.testing.expectEqual(agent.QueueMode.one_at_a_time, session.agent.follow_up_queue.mode);
}

test "TS RPC M3 session bash retry compaction controls use TS-compatible response bytes" {
    const allocator = std.testing.allocator;
    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "system",
        .model = model,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "forkable prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = " assistant answer " } };
    try session.agent.setMessages(&[_]agent.AgentMessage{
        .{ .user = .{ .content = user_content, .timestamp = 11 } },
        .{ .assistant = .{
            .content = assistant_content,
            .api = "faux",
            .provider = "faux",
            .model = "fixture-model",
            .usage = .{ .input = 2, .output = 3, .cache_read = 4, .cache_write = 5, .total_tokens = 14, .cost = .{ .total = 0.012 } },
            .stop_reason = .stop,
            .timestamp = 12,
        } },
    });
    const fork_entry_id = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 11 } });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"auto_compact\",\"type\":\"set_auto_compaction\",\"enabled\":true}",
            "{\"id\":\"auto_retry\",\"type\":\"set_auto_retry\",\"enabled\":true}",
            "{\"id\":\"abort_retry\",\"type\":\"abort_retry\"}",
            "{\"id\":\"abort_bash\",\"type\":\"abort_bash\"}",
            "{\"id\":\"bash\",\"type\":\"bash\",\"command\":\"printf rpc-bash\"}",
            "{\"id\":\"name\",\"type\":\"set_session_name\",\"name\":\"  rpc session  \"}",
            "{\"id\":\"last\",\"type\":\"get_last_assistant_text\"}",
            "{\"id\":\"fork_messages\",\"type\":\"get_fork_messages\"}",
            "{\"id\":\"stats\",\"type\":\"get_session_stats\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const expected_fork = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"fork_messages\",\"type\":\"response\",\"command\":\"get_fork_messages\",\"success\":true,\"data\":{{\"messages\":[{{\"entryId\":\"{s}\",\"text\":\"forkable prompt\"}}]}}}}\n",
        .{fork_entry_id},
    );
    defer allocator.free(expected_fork);

    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"auto_compact\",\"type\":\"response\",\"command\":\"set_auto_compaction\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"auto_retry\",\"type\":\"response\",\"command\":\"set_auto_retry\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"abort_retry\",\"type\":\"response\",\"command\":\"abort_retry\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"bash\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"rpc-bash\",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"abort_bash\",\"type\":\"response\",\"command\":\"abort_bash\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"type\":\"session_info_changed\",\"name\":\"rpc session\"}\n{\"id\":\"name\",\"type\":\"response\",\"command\":\"set_session_name\",\"success\":true}\n");
    try expectContains(stdout_capture.writer.buffered(), "{\"id\":\"last\",\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":\"assistant answer\"}}\n");
    try expectContains(stdout_capture.writer.buffered(), expected_fork);
    try expectContains(stdout_capture.writer.buffered(), "\"command\":\"get_session_stats\",\"success\":true,\"data\":{\"sessionId\":");
    try expectContains(stdout_capture.writer.buffered(), "\"tokens\":{\"input\":2,\"output\":3,\"cacheRead\":4,\"cacheWrite\":5,\"total\":14}");
}

test "TS RPC retry lifecycle emits start then success end in TS-compatible order" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("retry ok")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = false,
            .max_retries = 2,
            .base_delay_ms = 1,
        },
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
        &.{
            "{\"id\":\"retry_on\",\"type\":\"set_auto_retry\",\"enabled\":true}",
            "{\"id\":\"retry_prompt\",\"type\":\"prompt\",\"message\":\"please retry\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const output = stdout_capture.writer.buffered();
    const start_event = "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":1,\"errorMessage\":\"503 service unavailable\"}\n";
    const end_event = "{\"type\":\"auto_retry_end\",\"success\":true,\"attempt\":1}\n";
    try expectContains(output, "{\"id\":\"retry_on\",\"type\":\"response\",\"command\":\"set_auto_retry\",\"success\":true}\n");
    try expectContains(output, "{\"id\":\"retry_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, start_event);
    try expectContains(output, end_event);
    try expectOutputOrder(output, "{\"id\":\"retry_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n", start_event);
    try expectOutputOrder(output, start_event, end_event);
    try expectOutputOrder(
        output,
        end_event,
        "{\"type\":\"turn_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"retry ok\"}]",
    );
}

test "TS RPC abort_retry cancels active retry delay and emits failure end" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("should not run")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry-abort",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 250,
        },
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"abort_prompt\",\"type\":\"prompt\",\"message\":\"please retry then abort\"}");
    const start_event = "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":250,\"errorMessage\":\"503 service unavailable\"}\n";
    try waitForOutputContains(&server, &stdout_capture.writer, start_event, 500);
    try server.handleLine("{\"id\":\"abort_retry\",\"type\":\"abort_retry\"}");
    try server.finish();

    const output = stdout_capture.writer.buffered();
    const abort_response = "{\"id\":\"abort_retry\",\"type\":\"response\",\"command\":\"abort_retry\",\"success\":true}\n";
    const end_event = "{\"type\":\"auto_retry_end\",\"success\":false,\"attempt\":1,\"finalError\":\"Retry cancelled\"}\n";
    try expectContains(output, "{\"id\":\"abort_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, start_event);
    try expectContains(output, abort_response);
    try expectContains(output, end_event);
    try expectOutputOrder(output, start_event, abort_response);
    try expectOutputOrder(output, abort_response, end_event);
    try std.testing.expect(std.mem.indexOf(u8, output, "should not run") == null);
}

test "TS RPC new_session aborts active retry delay before rebind" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("should not run after rebind")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry-rebind",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 1000,
        },
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"rebind_prompt\",\"type\":\"prompt\",\"message\":\"please retry then rebind\"}");
    const start_event = "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":1000,\"errorMessage\":\"503 service unavailable\"}\n";
    try waitForOutputContains(&server, &stdout_capture.writer, start_event, 500);
    try waitForSessionRetrying(&session, 500);

    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    try server.handleLine("{\"id\":\"new_during_retry\",\"type\":\"new_session\"}");
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 500);

    const output = stdout_capture.writer.buffered();
    const end_event = "{\"type\":\"auto_retry_end\",\"success\":false,\"attempt\":1,\"finalError\":\"Retry cancelled\"}\n";
    const rebind_response = "{\"id\":\"new_during_retry\",\"type\":\"response\",\"command\":\"new_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n";
    try expectContains(output, "{\"id\":\"rebind_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, start_event);
    try expectContains(output, end_event);
    try expectContains(output, rebind_response);
    try expectOutputOrder(output, start_event, end_event);
    try expectOutputOrder(output, end_event, rebind_response);
    try std.testing.expect(std.mem.indexOf(u8, output, "should not run after rebind") == null);
}

test "TS RPC EOF shutdown aborts active retry delay promptly" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("should not run after shutdown")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry-shutdown",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 1000,
        },
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};

    try server.handleLine("{\"id\":\"shutdown_prompt\",\"type\":\"prompt\",\"message\":\"please retry then shutdown\"}");
    try waitForOutputContains(
        &server,
        &stdout_capture.writer,
        "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":1000,\"errorMessage\":\"503 service unavailable\"}\n",
        500,
    );
    try waitForSessionRetrying(&session, 500);

    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    server.suppress_events = true;
    server.abortActivePromptWork();
    try server.flushDeferredResponses();
    try server.finish();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 500);

    const output = stdout_capture.writer.buffered();
    try expectContains(output, "{\"id\":\"shutdown_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":2,\"delayMs\":1000,\"errorMessage\":\"503 service unavailable\"}\n");
    try std.testing.expect(std.mem.indexOf(u8, output, "should not run after shutdown") == null);
}

test "TS RPC set_auto_retry false disables retry lifecycle" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&.{}, .{ .stop_reason = .error_reason, .error_message = "503 service unavailable" }) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{ai.providers.faux.fauxText("unexpected retry")}, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-retry-disabled",
        .system_prompt = "system",
        .model = registration.getModel(),
        .retry = .{
            .enabled = true,
            .max_retries = 2,
            .base_delay_ms = 1,
        },
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
        &.{
            "{\"id\":\"retry_off\",\"type\":\"set_auto_retry\",\"enabled\":false}",
            "{\"id\":\"disabled_prompt\",\"type\":\"prompt\",\"message\":\"do not retry\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const output = stdout_capture.writer.buffered();
    try expectContains(output, "{\"id\":\"retry_off\",\"type\":\"response\",\"command\":\"set_auto_retry\",\"success\":true}\n");
    try expectContains(output, "{\"id\":\"disabled_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"auto_retry_start\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"auto_retry_end\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unexpected retry") == null);
    try std.testing.expectEqual(@as(u32, 0), session.retry_attempt);
}

test "TS RPC M3 session host rebinds new switch fork clone and state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project-cwd");

    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "ts-rpc-session-host",
    });
    defer allocator.free(relative_dir);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "project-cwd",
    });
    defer allocator.free(project_relative);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, relative_dir });
    defer allocator.free(session_dir);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ cwd, project_relative });
    defer allocator.free(project_cwd);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const first_user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    first_user_content[0] = .{ .text = .{ .text = "root prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "root answer" } };
    const second_user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    second_user_content[0] = .{ .text = .{ .text = "fork selected prompt" } };

    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = first_user_content, .timestamp = 11 } });
    _ = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_content,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 12,
    } });
    const fork_entry_id = try session.session_manager.appendMessage(.{ .user = .{ .content = second_user_content, .timestamp = 13 } });
    const fork_entry_id_owned = try allocator.dupe(u8, fork_entry_id);
    defer allocator.free(fork_entry_id_owned);
    try session.navigateTo(fork_entry_id);
    const original_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(original_session_file);
    const original_session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(original_session_id);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    try server.handleLine("{\"id\":\"new\",\"type\":\"new_session\",\"parentSession\":\"parent.jsonl\"}");
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"new\",\"type\":\"response\",\"command\":\"new_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expect(!std.mem.eql(u8, original_session_id, session.session_manager.getSessionId()));

    try server.handleLine("{\"id\":\"new_state\",\"type\":\"get_state\"}");
    const new_state = try ts_rpc_state_json.buildStateJson(allocator, &session);
    defer allocator.free(new_state);
    const expected_new_state = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"new_state\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{s}}}\n",
        .{new_state},
    );
    defer allocator.free(expected_new_state);
    try expectNewOutput(&stdout_capture.writer, &cursor, expected_new_state);
    try std.testing.expectEqual(@as(usize, 0), session.agent.getMessages().len);

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"switch\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{original_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"switch\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expectEqualStrings(original_session_id, session.session_manager.getSessionId());
    try std.testing.expectEqual(@as(usize, 3), session.agent.getMessages().len);

    try server.handleLine("{\"id\":\"new_after_rebind\",\"type\":\"new_session\",\"parentSession\":\"parent-after-rebind.jsonl\"}");
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"new_after_rebind\",\"type\":\"response\",\"command\":\"new_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expectEqualStrings(session.session_manager.getCwd(), session.cwd);
    try std.testing.expectEqual(session.session_manager.getCwd().ptr, session.cwd.ptr);
    try std.testing.expectEqual(@as(usize, 0), session.agent.getMessages().len);

    try server.handleLine(switch_command);
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"switch\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expectEqualStrings(original_session_id, session.session_manager.getSessionId());
    try std.testing.expectEqual(@as(usize, 3), session.agent.getMessages().len);

    try server.handleLine("{\"id\":\"fork_messages\",\"type\":\"get_fork_messages\"}");
    const fork_messages = try ts_rpc_state_json.buildForkMessagesJson(allocator, &session);
    defer allocator.free(fork_messages);
    const expected_fork_messages = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"fork_messages\",\"type\":\"response\",\"command\":\"get_fork_messages\",\"success\":true,\"data\":{s}}}\n",
        .{fork_messages},
    );
    defer allocator.free(expected_fork_messages);
    try expectNewOutput(&stdout_capture.writer, &cursor, expected_fork_messages);

    const fork_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"fork\",\"type\":\"fork\",\"entryId\":\"{s}\"}}",
        .{fork_entry_id_owned},
    );
    defer allocator.free(fork_command);
    try server.handleLine(fork_command);
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"fork\",\"type\":\"response\",\"command\":\"fork\",\"success\":true,\"data\":{\"text\":\"fork selected prompt\",\"cancelled\":false}}\n");
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);

    try server.handleLine("{\"id\":\"clone\",\"type\":\"clone\"}");
    try expectNewOutput(&stdout_capture.writer, &cursor, "{\"id\":\"clone\",\"type\":\"response\",\"command\":\"clone\",\"success\":true,\"data\":{\"cancelled\":false}}\n");
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);

    try server.handleLine("{\"id\":\"name\",\"type\":\"set_session_name\",\"name\":\"  rebound name  \"}");
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"type\":\"session_info_changed\",\"name\":\"rebound name\"}\n{\"id\":\"name\",\"type\":\"response\",\"command\":\"set_session_name\",\"success\":true}\n",
    );

    try server.handleLine("{\"id\":\"clone_state\",\"type\":\"get_state\"}");
    const clone_state = try ts_rpc_state_json.buildStateJson(allocator, &session);
    defer allocator.free(clone_state);
    const expected_clone_state = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"clone_state\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{s}}}\n",
        .{clone_state},
    );
    defer allocator.free(expected_clone_state);
    try expectNewOutput(&stdout_capture.writer, &cursor, expected_clone_state);
    try expectContains(clone_state, "\"sessionName\":\"rebound name\"");
}

test "TS RPC switch_session rejects target with missing stored cwd before tearing down current runtime" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "live-cwd");
    try tmp.dir.createDirPath(std.testing.io, "soon-deleted-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const live_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "live-cwd",
    });
    defer allocator.free(live_relative);
    const live_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, live_relative });
    defer allocator.free(live_cwd);
    const stale_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "soon-deleted-cwd",
    });
    defer allocator.free(stale_relative);
    const stale_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, stale_relative });
    defer allocator.free(stale_cwd);

    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;

    // The "stale" session file is created against an existing cwd which is
    // then deleted, so its stored cwd will fail the missing-cwd guard.
    var stale_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stale_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    const stale_session_file = try allocator.dupe(u8, stale_session.session_manager.getSessionFile().?);
    defer allocator.free(stale_session_file);
    stale_session.deinit();
    try tmp.dir.deleteTree(std.testing.io, "soon-deleted-cwd");

    // The "active" session has a valid cwd and remains the current session.
    var active_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = live_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer active_session.deinit();
    const active_session_id = try allocator.dupe(u8, active_session.session_manager.getSessionId());
    defer allocator.free(active_session_id);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &active_session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"switch_stale\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{stale_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"switch_stale\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":false,\"error\":\"MissingSessionCwd\"}\n",
    );

    // The active session must remain the current session and its cwd must be
    // unchanged after the rejected switch.
    try std.testing.expectEqualStrings(active_session_id, active_session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(live_cwd, active_session.cwd);
    try std.testing.expectEqualStrings(live_cwd, active_session.session_manager.getCwd());
}

// VAL-M10-SESSION-003: Resuming an existing session uses the stored session
// cwd rather than the process launch cwd whenever the stored cwd is valid.
test "VAL-M10-SESSION-003 switch_session adopts stored session cwd over launch cwd" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "stored-cwd");
    try tmp.dir.createDirPath(std.testing.io, "launch-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const stored_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "stored-cwd",
    });
    defer allocator.free(stored_relative);
    const stored_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, stored_relative });
    defer allocator.free(stored_cwd);
    const launch_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "launch-cwd",
    });
    defer allocator.free(launch_relative);
    const launch_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, launch_relative });
    defer allocator.free(launch_cwd);

    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;

    // Stored session is created with stored_cwd; this becomes the persisted
    // header cwd and must win over launch_cwd when we switch back to it.
    var stored_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stored_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    const stored_session_file = try allocator.dupe(u8, stored_session.session_manager.getSessionFile().?);
    defer allocator.free(stored_session_file);
    const stored_session_id = try allocator.dupe(u8, stored_session.session_manager.getSessionId());
    defer allocator.free(stored_session_id);
    stored_session.deinit();

    // The "active" session simulates the running process whose launch cwd is
    // a different existing directory.
    var active_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = launch_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer active_session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &active_session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"switch\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{stored_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"switch\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );

    // Stored cwd wins over the prior launch cwd, and the resumed session
    // identity is preserved on disk through the switch.
    try std.testing.expectEqualStrings(stored_session_id, active_session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(stored_cwd, active_session.cwd);
    try std.testing.expectEqualStrings(stored_cwd, active_session.session_manager.getCwd());
    try std.testing.expect(!std.mem.eql(u8, launch_cwd, active_session.cwd));
}

// VAL-M10-SESSION-004 / VAL-M10-SESSION-007: Forking a session preserves the
// parent session metadata, branch ancestry, and cwd identity without
// mutating the parent session file.
test "VAL-M10-SESSION-004 fork preserves parent metadata and parent file is unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "fork-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "fork-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_a[0] = .{ .text = .{ .text = "root prompt" } };
    const assistant_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_a[0] = .{ .text = .{ .text = "root answer" } };
    const user_b = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_b[0] = .{ .text = .{ .text = "fork target prompt" } };

    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_a, .timestamp = 21 } });
    _ = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_a,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 22,
    } });
    const fork_target_id = try session.session_manager.appendMessage(.{ .user = .{ .content = user_b, .timestamp = 23 } });
    const fork_target_id_owned = try allocator.dupe(u8, fork_target_id);
    defer allocator.free(fork_target_id_owned);
    try session.navigateTo(fork_target_id);

    const parent_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(parent_session_file);
    const parent_session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(parent_session_id);
    const parent_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, parent_session_file, allocator, .unlimited);
    defer allocator.free(parent_bytes_before);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    const fork_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"fork\",\"type\":\"fork\",\"entryId\":\"{s}\"}}",
        .{fork_target_id_owned},
    );
    defer allocator.free(fork_command);
    try server.handleLine(fork_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"fork\",\"type\":\"response\",\"command\":\"fork\",\"success\":true,\"data\":{\"text\":\"fork target prompt\",\"cancelled\":false}}\n",
    );

    // The forked session is a new, distinct session that retains the parent
    // cwd and records the parent session file in its persisted header.
    const fork_session_file = session.session_manager.getSessionFile().?;
    try std.testing.expect(!std.mem.eql(u8, parent_session_file, fork_session_file));
    try std.testing.expect(!std.mem.eql(u8, parent_session_id, session.session_manager.getSessionId()));
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());

    const fork_parent = session.session_manager.getHeader().parent_session orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings(parent_session_file, fork_parent);

    // Parent session file on disk is preserved byte-for-byte.
    const parent_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, parent_session_file, allocator, .unlimited);
    defer allocator.free(parent_bytes_after);
    try std.testing.expectEqualStrings(parent_bytes_before, parent_bytes_after);
}

// VAL-M10-SESSION-007: Cloning a session creates a distinct child branch that
// retains the full ancestry up to and including the current leaf entry,
// records the parent session file in its persisted header, preserves the
// parent cwd, leaves the parent session file byte-identical on disk, and
// exposes parent and clone branch views via get_messages that reflect the
// correct cutoff/target ancestry.
test "VAL-M10-SESSION-007 clone preserves branch ancestry and parent file is unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "clone-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "clone-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_a[0] = .{ .text = .{ .text = "root prompt" } };
    const assistant_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_a[0] = .{ .text = .{ .text = "root answer" } };
    const user_b = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_b[0] = .{ .text = .{ .text = "second prompt" } };
    const assistant_b = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_b[0] = .{ .text = .{ .text = "second answer" } };

    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_a, .timestamp = 51 } });
    _ = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_a,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 52,
    } });
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_b, .timestamp = 53 } });
    const leaf_assistant_id = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_b,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 54,
    } });
    const leaf_assistant_id_owned = try allocator.dupe(u8, leaf_assistant_id);
    defer allocator.free(leaf_assistant_id_owned);
    try session.navigateTo(leaf_assistant_id);

    // Snapshot parent identity and persisted bytes before clone runs.
    const parent_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(parent_session_file);
    const parent_session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(parent_session_id);
    const parent_leaf_id = try allocator.dupe(u8, session.session_manager.getLeafId().?);
    defer allocator.free(parent_leaf_id);
    const parent_message_count = session.agent.getMessages().len;
    try std.testing.expectEqual(@as(usize, 4), parent_message_count);
    const parent_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, parent_session_file, allocator, .unlimited);
    defer allocator.free(parent_bytes_before);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    // Capture parent get_messages branch view before clone (the cutoff/target
    // ancestry currently visible on the parent session).
    const parent_branch_messages_before = try ts_rpc_state_json.buildMessagesJson(allocator, session.agent.getMessages());
    defer allocator.free(parent_branch_messages_before);

    try server.handleLine("{\"id\":\"clone\",\"type\":\"clone\"}");
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"clone\",\"type\":\"response\",\"command\":\"clone\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );

    // Cloned session is a new, distinct session. The session id and on-disk
    // file path are different from the parent.
    const clone_session_file = session.session_manager.getSessionFile().?;
    try std.testing.expect(!std.mem.eql(u8, parent_session_file, clone_session_file));
    try std.testing.expect(!std.mem.eql(u8, parent_session_id, session.session_manager.getSessionId()));

    // Clone preserves the parent cwd in its metadata.
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());

    // Clone records the parent session file in its persisted header.
    const clone_parent = session.session_manager.getHeader().parent_session orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings(parent_session_file, clone_parent);

    // Clone retains the full branch ancestry: the leaf entry and message count
    // match the parent at clone time (cutoff/target == leaf assistant id).
    const clone_leaf_id = session.session_manager.getLeafId() orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings(parent_leaf_id, clone_leaf_id);
    try std.testing.expectEqual(parent_message_count, session.agent.getMessages().len);

    // Clone get_messages branch view matches the parent's branch view at the
    // cloned cutoff/target. Both must reflect the same root and second
    // user/assistant pairs in order.
    const clone_branch_messages = try ts_rpc_state_json.buildMessagesJson(allocator, session.agent.getMessages());
    defer allocator.free(clone_branch_messages);
    try std.testing.expectEqualStrings(parent_branch_messages_before, clone_branch_messages);

    // Parent session file on disk is preserved byte-for-byte after clone.
    const parent_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, parent_session_file, allocator, .unlimited);
    defer allocator.free(parent_bytes_after);
    try std.testing.expectEqualStrings(parent_bytes_before, parent_bytes_after);

    // Switch back to the parent session and confirm its branch view is
    // unchanged: the same leaf and the same get_messages output as before
    // the clone occurred.
    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"back\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{parent_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"back\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );
    try std.testing.expectEqualStrings(parent_session_id, session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(parent_leaf_id, session.session_manager.getLeafId().?);
    try std.testing.expectEqual(parent_message_count, session.agent.getMessages().len);
    const parent_branch_messages_after_switch = try ts_rpc_state_json.buildMessagesJson(allocator, session.agent.getMessages());
    defer allocator.free(parent_branch_messages_after_switch);
    try std.testing.expectEqualStrings(parent_branch_messages_before, parent_branch_messages_after_switch);
}

// VAL-M10-SESSION-006: Creating a new session clears prior transient session
// state, message history, and exposes a fresh session id; old session file is
// preserved and can be switched back to.
test "VAL-M10-SESSION-006 new_session clears prior transient state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "new-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "new-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "old prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "old answer" } };
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 31 } });
    const old_assistant_id = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_content,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 32,
    } });
    try session.navigateTo(old_assistant_id);
    try std.testing.expect(session.agent.getMessages().len > 0);

    const old_session_id = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(old_session_id);
    const old_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(old_session_file);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    try server.handleLine("{\"id\":\"new\",\"type\":\"new_session\",\"parentSession\":\"prior.jsonl\"}");
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"new\",\"type\":\"response\",\"command\":\"new_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );

    // New session is fresh: distinct id, no messages, distinct file path,
    // cwd stays anchored to the active runtime cwd.
    try std.testing.expect(!std.mem.eql(u8, old_session_id, session.session_manager.getSessionId()));
    try std.testing.expect(!std.mem.eql(u8, old_session_file, session.session_manager.getSessionFile().?));
    try std.testing.expectEqual(@as(usize, 0), session.agent.getMessages().len);
    try std.testing.expectEqual(@as(usize, 0), session.session_manager.getEntries().len);
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());
    try std.testing.expectEqual(@as(?[]const u8, null), session.session_manager.getLeafId());

    // Persisted parentSession is recorded in the new session header.
    const parent = session.session_manager.getHeader().parent_session orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings("prior.jsonl", parent);

    // The prior session file is preserved on disk (we can switch back to it
    // and observe the original messages).
    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"back\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{old_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"back\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}}\n",
    );
    try std.testing.expectEqualStrings(old_session_id, session.session_manager.getSessionId());
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
}

// VAL-M10-SESSION-008: Reloading an active session preserves the selected
// session id, branch identity, stored cwd, and visible message list when the
// underlying files are unchanged.
test "VAL-M10-SESSION-008 reload preserves session identity and messages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "reload-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "reload-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "reload prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "reload answer" } };
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 41 } });
    const reload_assistant_id = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_content,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 42,
    } });
    try session.navigateTo(reload_assistant_id);

    const session_file_before = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file_before);
    const session_id_before = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(session_id_before);
    const leaf_before = try allocator.dupe(u8, session.session_manager.getLeafId().?);
    defer allocator.free(leaf_before);
    const message_count_before = session.agent.getMessages().len;
    const session_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file_before, allocator, .unlimited);
    defer allocator.free(session_bytes_before);

    // Reload from disk via navigateTo (which delegates to reloadFromSession):
    // identity, cwd, leaf, and messages are preserved when underlying files
    // are unchanged.
    try session.navigateTo(leaf_before);

    try std.testing.expectEqualStrings(session_id_before, session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(session_file_before, session.session_manager.getSessionFile().?);
    try std.testing.expectEqualStrings(leaf_before, session.session_manager.getLeafId().?);
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());
    try std.testing.expectEqual(message_count_before, session.agent.getMessages().len);

    const session_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file_before, allocator, .unlimited);
    defer allocator.free(session_bytes_after);
    try std.testing.expectEqualStrings(session_bytes_before, session_bytes_after);
}

// VAL-M10-SESSION-009: Disconnecting and reconnecting the client to an
// existing TS-RPC runtime preserves active session identity, cwd, and
// messages rather than implicitly creating a new session.
test "VAL-M10-SESSION-009 reconnect to existing runtime preserves session state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "reconnect-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "reconnect-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "reconnect prompt" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "reconnect answer" } };
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 51 } });
    const assistant_id = try session.session_manager.appendMessage(.{ .assistant = .{
        .content = assistant_content,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 52,
    } });
    try session.navigateTo(assistant_id);

    const session_id_before = try allocator.dupe(u8, session.session_manager.getSessionId());
    defer allocator.free(session_id_before);
    const session_file_before = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file_before);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    // First client "connects" to the runtime, queries state, then finishes.
    {
        var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
        try server.start();
        try server.handleLine("{\"id\":\"first\",\"type\":\"get_state\"}");
        const first_state = try ts_rpc_state_json.buildStateJson(allocator, &session);
        defer allocator.free(first_state);
        try expectContains(stdout_capture.writer.buffered(), session_id_before);
        try expectContains(stdout_capture.writer.buffered(), first_state);
        try server.finish();
    }

    // The runtime/session stays alive across client disconnects: identity,
    // cwd, and messages are not reset by a finished server connection.
    try std.testing.expectEqualStrings(session_id_before, session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(session_file_before, session.session_manager.getSessionFile().?);
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
    try std.testing.expectEqualStrings(project_cwd, session.session_manager.getCwd());
    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);

    // Second client "reconnects", retrieves state again, and observes the
    // exact same identity and message count.
    var stdout_capture_two: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture_two.deinit();
    var stderr_capture_two: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture_two.deinit();
    var server2 = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture_two.writer, &stderr_capture_two.writer);
    try server2.start();
    defer server2.finish() catch {};
    try server2.handleLine("{\"id\":\"second\",\"type\":\"get_state\"}");
    try server2.handleLine("{\"id\":\"msgs\",\"type\":\"get_messages\"}");
    try expectContains(stdout_capture_two.writer.buffered(), session_id_before);
    try expectContains(stdout_capture_two.writer.buffered(), "\"messageCount\":2");
    try expectContains(stdout_capture_two.writer.buffered(), "\"command\":\"get_messages\",\"success\":true");

    try std.testing.expectEqualStrings(session_id_before, session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(project_cwd, session.cwd);
}

// VAL-M10-SESSION-010 / subscription isolation: A failed switch_session
// (rejected by the missing-cwd guard) leaves the active session file
// byte-identical, leaves the active subscriber attached for new events, and
// leaves the prior session file undisturbed.
test "VAL-M10-SESSION-010 failed switch leaves session files byte-identical and subscriber intact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "live-cwd");
    try tmp.dir.createDirPath(std.testing.io, "soon-deleted-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const live_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "live-cwd",
    });
    defer allocator.free(live_relative);
    const live_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, live_relative });
    defer allocator.free(live_cwd);
    const stale_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "soon-deleted-cwd",
    });
    defer allocator.free(stale_relative);
    const stale_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, stale_relative });
    defer allocator.free(stale_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;

    var stale_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stale_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    const stale_session_file = try allocator.dupe(u8, stale_session.session_manager.getSessionFile().?);
    defer allocator.free(stale_session_file);
    stale_session.deinit();
    const stale_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, stale_session_file, allocator, .unlimited);
    defer allocator.free(stale_bytes_before);
    try tmp.dir.deleteTree(std.testing.io, "soon-deleted-cwd");

    var active_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = live_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer active_session.deinit();
    const active_session_file = try allocator.dupe(u8, active_session.session_manager.getSessionFile().?);
    defer allocator.free(active_session_file);
    const active_session_id = try allocator.dupe(u8, active_session.session_manager.getSessionId());
    defer allocator.free(active_session_id);
    const active_bytes_before = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, active_session_file, allocator, .unlimited);
    defer allocator.free(active_bytes_before);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &active_session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    var cursor: usize = 0;

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"switch_stale\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{stale_session_file},
    );
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"id\":\"switch_stale\",\"type\":\"response\",\"command\":\"switch_session\",\"success\":false,\"error\":\"MissingSessionCwd\"}\n",
    );

    // Active session identity, cwd, and on-disk bytes are unchanged.
    try std.testing.expectEqualStrings(active_session_id, active_session.session_manager.getSessionId());
    try std.testing.expectEqualStrings(live_cwd, active_session.cwd);
    const active_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, active_session_file, allocator, .unlimited);
    defer allocator.free(active_bytes_after);
    try std.testing.expectEqualStrings(active_bytes_before, active_bytes_after);

    // The would-be target session file is also untouched on disk.
    const stale_bytes_after = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, stale_session_file, allocator, .unlimited);
    defer allocator.free(stale_bytes_after);
    try std.testing.expectEqualStrings(stale_bytes_before, stale_bytes_after);

    // Subscription isolation: the active session subscriber is still attached
    // and routes new events to the existing client. Setting the session name
    // emits a `session_info_changed` event followed by a successful response.
    try server.handleLine("{\"id\":\"name\",\"type\":\"set_session_name\",\"name\":\"after-failed-switch\"}");
    try expectNewOutput(
        &stdout_capture.writer,
        &cursor,
        "{\"type\":\"session_info_changed\",\"name\":\"after-failed-switch\"}\n{\"id\":\"name\",\"type\":\"response\",\"command\":\"set_session_name\",\"success\":true}\n",
    );
}

test "TS RPC M2 queue_update is emitted before response and prompt.streamingBehavior queues while streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const input = try readFixture("prompt-concurrency-queue-order.input.jsonl");
    defer allocator.free(input);
    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        &session,
        input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const fixture = try readFixture("prompt-concurrency-queue-order.jsonl");
    defer allocator.free(fixture);
    try expectPromptConcurrencyQueueInvariant(stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, fixture, "{\"type\":\"agent_start\"}\n") == null);
    try std.testing.expectEqualStrings(fixture, stdout_capture.writer.buffered());
}

test "TS RPC M2 prompt without streamingBehavior rejects while streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();
    session.agent.is_streaming = true;

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"busy\",\"type\":\"prompt\",\"message\":\"second prompt\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"busy\",\"type\":\"response\",\"command\":\"prompt\",\"success\":false,\"error\":\"Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.\"}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC M2 abort command is processed while prompt worker is in flight" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();
    session.agent.stream_fn = blockingUntilAbortStream;

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();

    try server.handleLine("{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"slow prompt\"}");
    try waitForSessionStreaming(&session);
    try std.testing.expect(session.isStreaming());

    try server.handleLine("{\"id\":\"a\",\"type\":\"abort\"}");

    try server.finish();
    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n",
    );
    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"p\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n",
    );
    try expectContains(stdout_capture.writer.buffered(), "\"stopReason\":\"aborted\"");
    const abort_response_index = std.mem.indexOf(u8, stdout_capture.writer.buffered(), "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n").?;
    const agent_end_index = std.mem.indexOf(u8, stdout_capture.writer.buffered(), "{\"type\":\"agent_end\"").?;
    try std.testing.expect(abort_response_index < agent_end_index);
}

test "TS RPC live client receives queue_update events and queued control responses before EOF" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();
    session.agent.stream_fn = blockingUntilAbortStream;

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();

    try server.handleLine("{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"slow prompt\"}");
    try waitForSessionStreaming(&session);
    try std.testing.expect(session.isStreaming());

    try server.handleLine("{\"id\":\"s\",\"type\":\"steer\",\"message\":\"steer while live\"}");
    try server.handleLine("{\"id\":\"f\",\"type\":\"follow_up\",\"message\":\"follow while live\"}");
    try server.handleLine("{\"id\":\"ps\",\"type\":\"prompt\",\"message\":\"prompt steer while live\",\"streamingBehavior\":\"steer\"}");
    try server.handleLine("{\"id\":\"pf\",\"type\":\"prompt\",\"message\":\"prompt follow while live\",\"streamingBehavior\":\"followUp\"}");

    const steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\"],\"followUp\":[]}\n";
    const follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\"],\"followUp\":[\"follow while live\"]}\n";
    const prompt_steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\",\"prompt steer while live\"],\"followUp\":[\"follow while live\"]}\n";
    const prompt_follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\",\"prompt steer while live\"],\"followUp\":[\"follow while live\",\"prompt follow while live\"]}\n";

    try waitForServerOutputContains(&server, &stdout_capture.writer, steer_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, follow_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, prompt_steer_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, prompt_follow_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"ps\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"pf\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"s\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"f\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n");
    try std.testing.expect(session.isStreaming());

    try expectOutputOrder(stdout_capture.writer.buffered(), steer_queue_update, "{\"id\":\"s\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n");
    try expectOutputOrder(stdout_capture.writer.buffered(), follow_queue_update, "{\"id\":\"f\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n");
    try expectOutputOrder(stdout_capture.writer.buffered(), prompt_steer_queue_update, "{\"id\":\"ps\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectOutputOrder(stdout_capture.writer.buffered(), prompt_follow_queue_update, "{\"id\":\"pf\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");

    try server.handleLine("{\"id\":\"a\",\"type\":\"abort\"}");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n");

    try server.finish();
}

test "TS RPC M2 prompt response precedes base event stream" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("prompt reply"),
        }, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
        .model = registration.getModel(),
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
        &.{"{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"hello\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"p\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n{\"type\":\"agent_start\"}\n{\"type\":\"turn_start\"}\n",
    );
    try expectPromptLineTypeOrder(stdout_capture.writer.buffered());
}

test "event_emission: turn_start and turn_end frames contain turnIndex and timestamp" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-ts-rpc-event-emission-turn-index.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 1, .max = 1 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("reply one"),
        }, .{}) },
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("reply two"),
        }, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-event-emission-turn-index",
        .system_prompt = "system",
        .model = registration.getModel(),
    });
    defer session.deinit();

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
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-ts-rpc-turn-index" };

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-ts-rpc-turn-index",
        .fixture = "turn-index",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    // Run first prompt (turn 1)
    try server.handleLine("{\"id\":\"p1\",\"type\":\"prompt\",\"message\":\"hello\"}");
    try waitForNoInFlightPrompt(&server, 5000);

    // Run second prompt (turn 1, zero-based) to verify turnIndex increments
    try server.handleLine("{\"id\":\"p2\",\"type\":\"prompt\",\"message\":\"hello again\"}");
    try waitForNoInFlightPrompt(&server, 5000);

    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // turn_start frames must include turnIndex and timestamp
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"turn_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"turnIndex\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"timestamp\":") != null);

    // turn_end frames include turnIndex but NOT timestamp (TS TurnEndEvent has no timestamp field).
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"turn_end\"") != null);
    // turn_start for turn 1 should carry turnIndex:1
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"turnIndex\":1") != null);
    // Verify each turn_end extension event: top-level must have turnIndex, not timestamp.
    // (Nested message objects carry their own timestamp, which is expected.)
    var line_iter = std.mem.tokenizeScalar(u8, capture, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"turn_end\"") != null) {
            try std.testing.expect(std.mem.indexOf(u8, line, "\"turnIndex\":") != null);
            // Parse and check top-level keys: timestamp must not be a top-level field.
            var parsed_line = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed_line.deinit();
            try std.testing.expect(parsed_line.value.object.get("timestamp") == null);
        }
    }
}

// ---------------------------------------------------------------------------
// Session lifecycle extension event tests
// All test names contain "session_lifecycle" to match the --test-filter flag.
// ---------------------------------------------------------------------------

// Helper: returns a shell script that captures all stdin lines to capture_path
// and exits on `{"type":"shutdown"}`.
test "selection_events: model and thinking events emit only on effective changes" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-selection-events.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-selection-events" };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/selection-events",
        .system_prompt = "system",
        .model = ai.model_registry.getDefault().find("faux", "faux-1").?,
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
        .marker = "pi-selection-events",
        .fixture = "selection-events",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    try server.handleLine("{\"id\":\"model1\",\"type\":\"set_model\",\"provider\":\"deepseek\",\"modelId\":\"deepseek-v4-pro\"}");
    try server.handleLine("{\"id\":\"model2\",\"type\":\"set_model\",\"provider\":\"deepseek\",\"modelId\":\"deepseek-v4-pro\"}");
    try server.handleLine("{\"id\":\"think1\",\"type\":\"set_thinking_level\",\"level\":\"low\"}");
    try server.handleLine("{\"id\":\"think2\",\"type\":\"set_thinking_level\",\"level\":\"low\"}");
    try server.handleLine("{\"id\":\"cycle\",\"type\":\"cycle_thinking_level\"}");
    try server.handleLine("{\"id\":\"think3\",\"type\":\"set_thinking_level\",\"level\":\"xhigh\"}");
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    try std.testing.expectEqual(@as(usize, 1), countCapturedEvents(capture, "\"model_select\""));
    try std.testing.expectEqual(@as(usize, 2), countCapturedEvents(capture, "\"thinking_level_select\""));
    try expectContains(capture, "\"type\":\"model_select\"");
    try expectContains(capture, "\"previousModel\":{\"id\":\"faux-1\"");
    try expectContains(capture, "\"model\":{\"id\":\"deepseek-v4-pro\"");
    try expectContains(capture, "\"source\":\"set\"");
    try expectContains(capture, "\"type\":\"thinking_level_select\",\"level\":\"high\",\"previousLevel\":\"off\",\"source\":\"set\"");
    try expectContains(capture, "\"type\":\"thinking_level_select\",\"level\":\"xhigh\",\"previousLevel\":\"high\",\"source\":\"cycle\"");
    try std.testing.expectEqual(agent.ThinkingLevel.xhigh, session.agent.getThinkingLevel());
}

test "session_lifecycle: replacements emit shutdown before start with previous and target files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project-cwd");

    const repo_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(repo_cwd);
    const project_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "project-cwd",
    });
    defer allocator.free(project_relative);
    const project_cwd = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, project_relative });
    defer allocator.free(project_cwd);
    const session_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache", "tmp", &tmp.sub_path, "sessions",
    });
    defer allocator.free(session_relative);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_cwd, session_relative });
    defer allocator.free(session_dir);

    const model = ai.model_registry.getDefault().find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_cwd,
        .system_prompt = "system",
        .model = model,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "fork prompt" } };
    const fork_entry_id = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 11 } });
    const fork_entry_id_owned = try allocator.dupe(u8, fork_entry_id);
    defer allocator.free(fork_entry_id_owned);
    const original_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(original_session_file);

    const capture_path = "/tmp/pi-session-replacement-lifecycle.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-session-replacement-lifecycle" };

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-session-replacement-lifecycle",
        .fixture = "session-replacement-lifecycle",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    try server.handleLine("{\"id\":\"new\",\"type\":\"new_session\"}");
    const switch_command = try std.fmt.allocPrint(allocator, "{{\"id\":\"resume\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}", .{original_session_file});
    defer allocator.free(switch_command);
    try server.handleLine(switch_command);
    const fork_command = try std.fmt.allocPrint(allocator, "{{\"id\":\"fork\",\"type\":\"fork\",\"entryId\":\"{s}\"}}", .{fork_entry_id_owned});
    defer allocator.free(fork_command);
    try server.handleLine(fork_command);
    try server.handleLine("{\"id\":\"clone\",\"type\":\"clone\"}");
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    try expectEventOrder(capture, "\"type\":\"session_shutdown\",\"reason\":\"new\"", "\"type\":\"session_start\",\"reason\":\"new\"");
    try expectEventOrder(capture, "\"type\":\"session_shutdown\",\"reason\":\"resume\"", "\"type\":\"session_start\",\"reason\":\"resume\"");
    try expectEventOrder(capture, "\"type\":\"session_shutdown\",\"reason\":\"fork\"", "\"type\":\"session_start\",\"reason\":\"fork\"");

    const new_shutdown = findEventLine(capture, "\"session_shutdown\"", "new") orelse return error.ExpectedEventNotFound;
    const new_start = findEventLine(capture, "\"session_start\"", "new") orelse return error.ExpectedEventNotFound;
    const resume_shutdown = findEventLine(capture, "\"session_shutdown\"", "resume") orelse return error.ExpectedEventNotFound;
    const resume_start = findEventLine(capture, "\"session_start\"", "resume") orelse return error.ExpectedEventNotFound;
    const fork_shutdown = findEventLine(capture, "\"session_shutdown\"", "fork") orelse return error.ExpectedEventNotFound;
    const fork_start = findEventLine(capture, "\"session_start\"", "fork") orelse return error.ExpectedEventNotFound;

    for ([_][]const u8{ new_shutdown, new_start, resume_shutdown, resume_start, fork_shutdown, fork_start }) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line, "\"previousSessionFile\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"targetSessionFile\"") != null);
    }
    try expectContains(resume_shutdown, original_session_file);
    try expectContains(resume_start, original_session_file);
    try std.testing.expect(countCapturedEvents(capture, "\"session_start\"") >= 4);
}

test "session_lifecycle: new_session emits session_before_switch and session_shutdown" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-new.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-new" };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
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
        .marker = "pi-sl-new",
        .fixture = "sl-new",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    try server.handleLine("{\"id\":\"n1\",\"type\":\"new_session\"}");
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // session_before_switch must appear with reason "new"
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_before_switch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"reason\":\"new\"") != null);
    // For new sessions, targetSessionFile must be absent from session_before_switch
    // (the new session file doesn't exist yet; parentSession is the old session, not the target).
    var line_iter = std.mem.tokenizeScalar(u8, capture, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"session_before_switch\"") != null) {
            try std.testing.expect(std.mem.indexOf(u8, line, "\"targetSessionFile\"") == null);
        }
    }
    // session_shutdown must appear (from new_session and/or quit)
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_shutdown\"") != null);
}

test "session_lifecycle: fork emits session_before_fork and session_shutdown" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-fork.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-fork" };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
    });
    defer session.deinit();

    // Add a user message so fork has an entryId to work with
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "fork me" } };
    const entry_id = try session.session_manager.appendMessage(.{ .user = .{ .content = user_content, .timestamp = 11 } });
    const entry_id_owned = try allocator.dupe(u8, entry_id);
    defer allocator.free(entry_id_owned);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-sl-fork",
        .fixture = "sl-fork",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    const fork_cmd = try std.fmt.allocPrint(allocator, "{{\"id\":\"f1\",\"type\":\"fork\",\"entryId\":\"{s}\"}}", .{entry_id_owned});
    defer allocator.free(fork_cmd);
    try server.handleLine(fork_cmd);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // session_before_fork must appear with entryId and position
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_before_fork\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"position\":\"before\"") != null);
    // session_shutdown must appear (from fork and/or quit)
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_shutdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"reason\":\"fork\"") != null);
}

test "session_lifecycle: compact emits session_before_compact and session_compact" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-compact.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-compact" };

    // Compact builds a text summary from session entries without calling the LLM.
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
    });
    defer session.deinit();

    // Add 2 message entries so prepareManualCompaction has enough to work with
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const msg1 = try arena.allocator().alloc(ai.ContentBlock, 1);
    msg1[0] = .{ .text = .{ .text = "first message to compact" } };
    const msg2 = try arena.allocator().alloc(ai.ContentBlock, 1);
    msg2[0] = .{ .text = .{ .text = "second message to compact" } };
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = msg1, .timestamp = 11 } });
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = msg2, .timestamp = 12 } });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-sl-compact",
        .fixture = "sl-compact",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    try server.handleLine("{\"id\":\"c1\",\"type\":\"compact\"}");
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // Both before and after compact events must appear
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_before_compact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_compact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"fromExtension\":false") != null);
}

test "session_lifecycle: navigate_to emits session_before_tree and session_tree" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-tree.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-tree" };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
    });
    defer session.deinit();

    // Add messages to create tree entries to navigate between
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const msg_a = try arena.allocator().alloc(ai.ContentBlock, 1);
    msg_a[0] = .{ .text = .{ .text = "root message" } };
    const msg_b = try arena.allocator().alloc(ai.ContentBlock, 1);
    msg_b[0] = .{ .text = .{ .text = "leaf message" } };
    const entry_a = try session.session_manager.appendMessage(.{ .user = .{ .content = msg_a, .timestamp = 11 } });
    const entry_a_owned = try allocator.dupe(u8, entry_a);
    defer allocator.free(entry_a_owned);
    _ = try session.session_manager.appendMessage(.{ .user = .{ .content = msg_b, .timestamp = 12 } });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();
    defer server.finish() catch {};
    try server.startExtensionHost(.{
        .argv = &argv,
        .marker = "pi-sl-tree",
        .fixture = "sl-tree",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    const nav_cmd = try std.fmt.allocPrint(allocator, "{{\"id\":\"t1\",\"type\":\"navigate_to\",\"entryId\":\"{s}\"}}", .{entry_a_owned});
    defer allocator.free(nav_cmd);
    try server.handleLine(nav_cmd);
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // session_before_tree and session_tree must both appear
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_before_tree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_tree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"newLeafId\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"oldLeafId\"") != null);
}

test "session_lifecycle: finish emits session_shutdown with reason quit" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-session-lifecycle-quit.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

    const script = try sessionLifecycleCaptureScript(allocator, capture_path);
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-sl-quit" };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
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
        .marker = "pi-sl-quit",
        .fixture = "sl-quit",
        .ready_timeout_ms = 500,
        .shutdown_timeout_ms = 500,
    });

    // Just finish without any commands - should emit session_shutdown with reason "quit"
    try server.finish();

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // session_shutdown with reason "quit" must appear before the shutdown frame
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"session_shutdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"reason\":\"quit\"") != null);
}

// ─── Extension command context API tests (VAL-EXT-031..036) ──────────────────
