const std = @import("std");

const fixture_files = [_][]const u8{
    "commands-input.jsonl",
    "jsonl-framing.jsonl",
    "parse-errors.jsonl",
    "parse-error-corpus.jsonl",
    "responses-basic.jsonl",
    "events-base-stream.jsonl",
    "events-thinking-tool-usage.jsonl",
    "events-session-extras.jsonl",
    "bash-control.input.jsonl",
    "prompt-concurrency-queue-order.input.jsonl",
    "prompt-concurrency-queue-order.jsonl",
    "bash-control.jsonl",
    "extension-ui.jsonl",
    "m6-extension-host.input.jsonl",
    "m6-extension-host.jsonl",
    "m5-simple-prompt.input.jsonl",
    "m5-simple-prompt.jsonl",
    "m5-thinking.input.jsonl",
    "m5-thinking.jsonl",
    "m5-tool.input.jsonl",
    "m5-tool.jsonl",
    "m5-compaction.input.jsonl",
    "m5-compaction.jsonl",
    "m5-retry.input.jsonl",
    "m5-retry.jsonl",
};

fn readFixture(comptime name: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        "test/golden/ts-rpc/" ++ name,
        std.testing.allocator,
        .unlimited,
    );
}

fn readRepoFile(comptime path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        path,
        std.testing.allocator,
        .unlimited,
    );
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn expectValidJsonl(comptime name: []const u8) !void {
    const bytes = try readFixture(name);
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(bytes.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\r\n") == null);

    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        parsed.deinit();
    }
    try std.testing.expect(line_count > 0);
}

test "VAL-UPSYNC-003 TS RPC fixture generator imports current workspace package scope" {
    const generator = try readRepoFile("test/generate-ts-rpc-fixtures.ts");
    defer std.testing.allocator.free(generator);

    try expectContains(generator, "from \"@earendil-works/pi-agent-core\"");
    try expectContains(generator, "from \"@earendil-works/pi-ai\"");
    try expectNotContains(generator, "from \"@mariozechner/pi-agent-core\"");
    try expectNotContains(generator, "from \"@mariozechner/pi-ai\"");
}

test "VAL-UPSYNC-002 extension fixture imports current scope and loader keeps legacy alias" {
    const fixture = try readRepoFile("test/fixtures/extensions/registration-fixture/extension.ts");
    defer std.testing.allocator.free(fixture);

    try expectContains(fixture, "from \"@earendil-works/pi-coding-agent\"");
    try expectNotContains(fixture, "from \"@mariozechner/pi-coding-agent\"");

    const loader = try readRepoFile("../packages/coding-agent/src/core/extensions/loader.ts");
    defer std.testing.allocator.free(loader);

    try expectContains(loader, "\"@earendil-works/pi-coding-agent\": _bundledPiCodingAgent");
    try expectContains(loader, "\"@mariozechner/pi-coding-agent\": _bundledPiCodingAgent");
    try expectContains(loader, "\"@earendil-works/pi-coding-agent\": piCodingAgentEntry");
    try expectContains(loader, "\"@mariozechner/pi-coding-agent\": piCodingAgentEntry");
}

test "TS RPC fixture files are checked in and valid JSONL" {
    inline for (fixture_files) |file| {
        try expectValidJsonl(file);
    }

    const manifest = try readFixture("manifest.json");
    defer std.testing.allocator.free(manifest);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest, .{});
    defer parsed.deinit();
    try expectContains(manifest, "packages/coding-agent/src/modes/rpc/jsonl.ts:10-58");
    try expectContains(manifest, "packages/coding-agent/src/modes/rpc/rpc-mode.ts:369-704");
    try expectContains(manifest, "captureMethod");
    try expectContains(manifest, "runRpcMode");
    try expectContains(manifest, "AgentSession.subscribe");
}

test "TS RPC fixtures do not expose sub-agent readiness replay wire data" {
    inline for (fixture_files) |file| {
        const bytes = try readFixture(file);
        defer std.testing.allocator.free(bytes);
        try expectNotContains(bytes, "sub_agent_readiness");
        try expectNotContains(bytes, "sub_agent_task_invocation");
        try expectNotContains(bytes, "sub_agent_task_result");
    }
}

test "TS RPC response fixtures preserve parse and unsupported-command schema errors" {
    const bytes = try readFixture("responses-basic.jsonl");
    defer std.testing.allocator.free(bytes);

    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command:",
    );
    try expectContains(
        bytes,
        "{\"id\":\"mystery\",\"type\":\"response\",\"command\":\"mystery_command\",\"success\":false,\"error\":\"Unknown command: mystery_command\"}\n",
    );
    try std.testing.expect(std.mem.indexOf(u8, bytes, "mystery_command") != null);
}

test "TS RPC M3 fixtures cover remaining control response and event shapes" {
    const responses = try readFixture("responses-basic.jsonl");
    defer std.testing.allocator.free(responses);
    try expectContains(responses, "\"command\":\"cycle_model\",\"success\":true,\"data\":null");
    try expectContains(responses, "\"command\":\"get_available_models\",\"success\":true,\"data\":{\"models\":[");
    try expectContains(responses, "\"command\":\"compact\",\"success\":true,\"data\":{\"summary\":");
    try expectContains(responses, "\"command\":\"bash\",\"success\":true,\"data\":{\"output\":");
    try expectContains(responses, "\"command\":\"export_html\",\"success\":true,\"data\":{\"path\":");
    try expectContains(responses, "\"command\":\"set_model\",\"success\":false,\"error\":\"Model not found:");
    try expectContains(responses, "\"command\":\"fork\",\"success\":true,\"data\":{\"text\":");
    try expectContains(responses, "\"command\":\"new_session\",\"success\":true,\"data\":{\"cancelled\":false}");
    try expectContains(responses, "\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":false}");
    try expectContains(responses, "\"command\":\"clone\",\"success\":true,\"data\":{\"cancelled\":false}");
    try expectContains(responses, "\"command\":\"get_fork_messages\",\"success\":true,\"data\":{\"messages\":[");
    try expectContains(responses, "\"command\":\"set_session_name\",\"success\":true}");

    const bash = try readFixture("bash-control.jsonl");
    defer std.testing.allocator.free(bash);
    const bash_input = try readFixture("bash-control.input.jsonl");
    defer std.testing.allocator.free(bash_input);
    try expectContains(bash_input, "\"command\":\"printf ok\"");
    try expectContains(bash_input, "\"command\":\"printf fail; exit 7\"");
    try expectContains(bash_input, "\"command\":\"printf 'start\\\\n'; touch /tmp/pi-ts-rpc-bash-control-start; sleep 5; printf end\"");
    try expectContains(bash_input, "\"command\":\"printf 'live\\\\n'; touch /tmp/pi-ts-rpc-bash-control-live; sleep 5; printf done\"");
    try expectContains(bash, "{\"id\":\"bash_ok\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"ok\",\"exitCode\":0,\"cancelled\":false,\"truncated\":false}}\n");
    try expectContains(bash, "{\"id\":\"bash_fail\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"fail\",\"exitCode\":7,\"cancelled\":false,\"truncated\":false}}\n");
    try expectContains(bash, "{\"id\":\"bash_abort\",\"type\":\"response\",\"command\":\"bash\",\"success\":true,\"data\":{\"output\":\"start\\n\",\"cancelled\":true,\"truncated\":false}}\n");
    try expectContains(bash, "{\"id\":\"live_commands\",\"type\":\"response\",\"command\":\"get_commands\",\"success\":true,\"data\":{\"commands\":[]}}\n");

    const events = try readFixture("events-session-extras.jsonl");
    defer std.testing.allocator.free(events);
    try expectContains(events, "{\"type\":\"compaction_start\",\"reason\":\"manual\"}");
    try expectContains(events, "\"type\":\"compaction_end\",\"reason\":\"manual\",\"result\":");
    try expectContains(events, "{\"type\":\"session_info_changed\",\"name\":");
    try expectContains(events, "{\"type\":\"auto_retry_start\",\"attempt\":");
    try expectContains(events, "{\"type\":\"auto_retry_end\",\"success\":");
}

test "TS RPC M4 extension UI fixtures cover request and response variants" {
    const bytes = try readFixture("extension-ui.jsonl");
    defer std.testing.allocator.free(bytes);

    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_select\",\"method\":\"select\",\"title\":\"Choose fixture\",\"options\":[\"option-a\",\"option-b\"],\"timeout\":1000}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":1000}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_input\",\"method\":\"input\",\"title\":\"Fixture input\",\"placeholder\":\"value\",\"timeout\":1000}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_notify\",\"method\":\"notify\",\"message\":\"Fixture notice\",\"notifyType\":\"info\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_status\",\"method\":\"setStatus\",\"statusKey\":\"fixture\",\"statusText\":\"ready\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_widget\",\"method\":\"setWidget\",\"widgetKey\":\"fixture\",\"widgetLines\":[\"line one\",\"line two\"],\"widgetPlacement\":\"aboveEditor\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_title\",\"method\":\"setTitle\",\"title\":\"Fixture Title\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_editor_text\",\"method\":\"set_editor_text\",\"text\":\"fixture editor text\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_editor\",\"method\":\"editor\",\"title\":\"Edit fixture\",\"prefill\":\"prefill\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"value\":\"option-a\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":true}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"cancelled\":true}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm_cancelled\",\"cancelled\":true}\n");
}

test "TS RPC M6 extension host fixtures cover configured response matrix" {
    const input = try readFixture("m6-extension-host.input.jsonl");
    defer std.testing.allocator.free(input);
    const bytes = try readFixture("m6-extension-host.jsonl");
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualStrings(
        "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":true}\n" ++
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"value\":\"option-b\"}\n" ++
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"cancelled\":true}\n" ++
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_editor\",\"value\":\"edited text\"}\n",
        input,
    );
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_select\",\"method\":\"select\",\"title\":\"Choose fixture\",\"options\":[\"option-a\",\"option-b\"],\"timeout\":1000}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_confirm\",\"method\":\"confirm\",\"title\":\"Confirm fixture\",\"message\":\"Proceed?\",\"timeout\":1000}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_input\",\"method\":\"input\",\"title\":\"Fixture input\",\"placeholder\":\"value\",\"timeout\":1000}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_notify\",\"method\":\"notify\",\"message\":\"Fixture notice\",\"notifyType\":\"info\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_status\",\"method\":\"setStatus\",\"statusKey\":\"fixture\",\"statusText\":\"ready\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_widget\",\"method\":\"setWidget\",\"widgetKey\":\"fixture\",\"widgetLines\":[\"line one\",\"line two\"],\"widgetPlacement\":\"aboveEditor\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_title\",\"method\":\"setTitle\",\"title\":\"Fixture Title\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_editor_text\",\"method\":\"set_editor_text\",\"text\":\"fixture editor text\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_editor\",\"method\":\"editor\",\"title\":\"Edit fixture\",\"prefill\":\"prefill\"}\n");
    try expectContains(bytes, "{\"type\":\"extension_ui_request\",\"id\":\"ui_m6_complete\",\"method\":\"setStatus\",\"statusKey\":\"fixture\",\"statusText\":\"complete:option-b:true:cancelled:edited text\"}\n");
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"pid\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "runtime") == null);
}

test "TS RPC parse-error fixtures cover multiple TypeScript JSON.parse messages" {
    const bytes = try readFixture("parse-errors.jsonl");
    defer std.testing.allocator.free(bytes);
    const corpus = try readFixture("parse-error-corpus.jsonl");
    defer std.testing.allocator.free(corpus);

    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected end of JSON input\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected token 'o', \\\"not-json\\\" is not valid JSON\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Expected double-quoted property name in JSON at position 20 (line 1 column 21)\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected token ']', \\\"[1,]\\\" is not valid JSON\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected non-whitespace character after JSON at position 2 (line 1 column 3)\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Expected ':' after property name in JSON at position 5 (line 1 column 6)\"}\n",
    );
    try expectContains(
        bytes,
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Unexpected token '#', \\\"{\\\"a\\\":#}\\\" is not valid JSON\"}\n",
    );
    try expectContains(corpus, "\"name\":\"extra-tokens-after-primitive\",\"input\":\"1 2\"");
    try expectContains(corpus, "\"name\":\"missing-colon\",\"input\":\"{\\\"a\\\" 1}\"");
    try expectContains(corpus, "\"name\":\"invalid-value-token\",\"input\":\"{\\\"a\\\":#}\"");
}

test "TS RPC framing fixture captures LF CRLF final-line and Unicode separator behavior" {
    const bytes = try readFixture("jsonl-framing.jsonl");
    defer std.testing.allocator.free(bytes);

    try expectContains(bytes, "fixture\xe2\x80\xa8session\xe2\x80\xa9name");
    try expectContains(bytes, "\"case\":\"lf-input-reader\"");
    try expectContains(bytes, "\"case\":\"crlf-input-reader\"");
    try expectContains(bytes, "\"case\":\"final-unterminated-input-reader\"");
    try expectContains(bytes, "\"id\":\"framing_lf_a\"");
    try expectContains(bytes, "\"id\":\"framing_crlf_a\"");
    try expectContains(bytes, "\"id\":\"framing_final\"");
    try expectContains(bytes, "\"command\":\"parse\"");
}

test "TS RPC event fixtures cover base stream thinking tools usage details and stop reasons" {
    const base = try readFixture("events-base-stream.jsonl");
    defer std.testing.allocator.free(base);
    try expectContains(base, "\"type\":\"agent_start\"");
    try expectContains(base, "\"type\":\"turn_start\"");
    try expectContains(base, "\"type\":\"message_start\"");
    try expectContains(base, "\"type\":\"message_update\"");
    try expectContains(base, "\"type\":\"message_end\"");
    try expectContains(base, "\"type\":\"turn_end\"");
    try expectContains(base, "\"type\":\"agent_end\"");

    const tool = try readFixture("events-thinking-tool-usage.jsonl");
    defer std.testing.allocator.free(tool);
    try expectContains(tool, "\"type\":\"thinking_delta\"");
    try expectContains(tool, "\"type\":\"toolcall_start\"");
    try expectContains(tool, "\"type\":\"toolcall_delta\"");
    try expectContains(tool, "\"type\":\"toolcall_end\"");
    try expectContains(tool, "\"type\":\"tool_execution_start\"");
    try expectContains(tool, "\"type\":\"tool_execution_update\"");
    try expectContains(tool, "\"type\":\"tool_execution_end\"");
    try expectContains(tool, "\"details\":");
    try expectContains(tool, "\"usage\":");
    try expectContains(tool, "\"stopReason\":\"toolUse\"");
    try expectContains(tool, "\"reason\":\"length\"");
    try expectContains(tool, "\"reason\":\"aborted\"");
}

test "TS RPC prompt concurrency fixture captures queue ordering and streamingBehavior" {
    const bytes = try readFixture("prompt-concurrency-queue-order.jsonl");
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualStrings(
        "{\"id\":\"pc_start\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\"],\"followUp\":[]}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\"],\"followUp\":[\"follow while prompt running\"]}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\",\"prompt as steer\"],\"followUp\":[\"follow while prompt running\"]}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer while prompt running\",\"prompt as steer\"],\"followUp\":[\"follow while prompt running\",\"prompt as follow\"]}\n" ++
            "{\"id\":\"pc_prompt_steer\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n" ++
            "{\"id\":\"pc_prompt_follow\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n" ++
            "{\"id\":\"pc_abort\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n" ++
            "{\"id\":\"pc_steer\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n" ++
            "{\"id\":\"pc_follow\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n",
        bytes,
    );
}

test "TS RPC M5 production parity fixtures cover every required scenario" {
    const simple = try readFixture("m5-simple-prompt.jsonl");
    defer std.testing.allocator.free(simple);
    try expectContains(simple, "{\"id\":\"simple_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(simple, "\"type\":\"text_delta\"");
    try expectContains(simple, "\"type\":\"agent_end\"");

    const thinking = try readFixture("m5-thinking.jsonl");
    defer std.testing.allocator.free(thinking);
    try expectContains(thinking, "\"type\":\"thinking_start\"");
    try expectContains(thinking, "\"type\":\"thinking_delta\"");
    try expectContains(thinking, "\"type\":\"thinking_end\"");

    const tool = try readFixture("m5-tool.jsonl");
    defer std.testing.allocator.free(tool);
    try expectContains(tool, "\"type\":\"toolcall_start\"");
    try expectContains(tool, "\"type\":\"toolcall_delta\"");
    try expectContains(tool, "\"type\":\"toolcall_end\"");
    try expectContains(tool, "\"type\":\"tool_execution_start\"");
    try expectContains(tool, "\"type\":\"tool_execution_end\"");
    try expectContains(tool, "\"timestamp\":1766880000008");

    const compaction = try readFixture("m5-compaction.jsonl");
    defer std.testing.allocator.free(compaction);
    try expectContains(compaction, "{\"type\":\"compaction_start\",\"reason\":\"manual\"}\n");
    try expectContains(compaction, "\"command\":\"compact\"");

    const retry = try readFixture("m5-retry.jsonl");
    defer std.testing.allocator.free(retry);
    try expectContains(retry, "\"command\":\"set_auto_retry\"");
    try expectContains(retry, "\"type\":\"auto_retry_start\"");
}

test "TS RPC production and test code do not contain fixture bypass symbols" {
    const allocator = std.testing.allocator;
    const forbidden = [_][]const u8{
        "PI_TS_RPC_" ++ "FIXTURE",
        "runTsRpcPromptConcurrencyQueueOrder" ++ "Fixture",
    };

    try expectTreeDoesNotContain(allocator, "src", &forbidden);
    try expectTreeDoesNotContain(allocator, "test", &forbidden);
}

fn expectTreeDoesNotContain(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    forbidden: []const []const u8,
) !void {
    var dir = try std.Io.Dir.openDir(.cwd(), std.testing.io, root_path, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &[_][]const u8{ root_path, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .directory => try expectTreeDoesNotContain(allocator, child_path, forbidden),
            .file => try expectFileDoesNotContain(allocator, child_path, forbidden),
            else => {},
        }
    }
}

fn expectFileDoesNotContain(
    allocator: std.mem.Allocator,
    path: []const u8,
    forbidden: []const []const u8,
) !void {
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) != null) {
            std.debug.print("forbidden TS-RPC fixture bypass symbol found in {s}: {s}\n", .{ path, needle });
            return error.ForbiddenTsRpcFixtureBypassSymbol;
        }
    }
}
