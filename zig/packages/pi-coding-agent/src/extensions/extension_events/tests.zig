const std = @import("std");
const extension_events = @import("../extension_events.zig");

const testing = std.testing;
const EventBus = extension_events.EventBus;
const EventHandlerResult = extension_events.EventHandlerResult;
const ExtensionEvent = extension_events.ExtensionEvent;
const ExtensionEventType = extension_events.ExtensionEventType;
const ResultEventBus = extension_events.ResultEventBus;
const SubAgentReadinessEnvelopeKind = extension_events.SubAgentReadinessEnvelopeKind;
const ToolResultEvent = extension_events.ToolResultEvent;
const eventName = extension_events.eventName;
const eventSurfaceNames = extension_events.eventSurfaceNames;
const subagent_forbidden_fields = extension_events.testing.subagentForbiddenFields();
const validateSubAgentReadinessEnvelope = extension_events.validateSubAgentReadinessEnvelope;

var test_event_received: bool = false;
var test_event_data: []const u8 = "";

fn testHandler(event: ExtensionEvent) !void {
    switch (event) {
        .session_start => |e| {
            test_event_received = true;
            test_event_data = e.reason;
        },
        else => {},
    }
}

test "EventBus subscribes and emits events" {
    test_event_received = false;
    test_event_data = "";

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    try bus.on(.session_start, testHandler, "/tmp/ext.ts");
    try std.testing.expect(bus.hasHandlers(.session_start));
    try std.testing.expect(!bus.hasHandlers(.agent_start));

    const event = ExtensionEvent{
        .session_start = .{
            .reason = "startup",
        },
    };
    try bus.emit(event);

    try std.testing.expect(test_event_received);
    try std.testing.expectEqualStrings("startup", test_event_data);
}

test "EventBus clears extension handlers" {
    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    try bus.on(.session_start, testHandler, "/tmp/ext.ts");
    try std.testing.expect(bus.hasHandlers(.session_start));

    bus.clearExtensionHandlers("/tmp/ext.ts");
    try std.testing.expect(!bus.hasHandlers(.session_start));
}

var g_count: u32 = 0;

fn countingHandler1(_: ExtensionEvent) !void {
    g_count += 1;
}

fn countingHandler2(_: ExtensionEvent) !void {
    g_count += 1;
}

test "EventBus emits to multiple handlers" {
    g_count = 0;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    try bus.on(.agent_start, countingHandler1, "/tmp/ext1.ts");
    try bus.on(.agent_start, countingHandler2, "/tmp/ext2.ts");

    const event = ExtensionEvent{ .agent_start = .{} };
    try bus.emit(event);

    try std.testing.expectEqual(@as(u32, 2), g_count);
}

const resource_skills_1 = [_][]const u8{"/skills/one"};
const resource_prompts_1 = [_][]const u8{"/prompts/one"};
const resource_themes_2 = [_][]const u8{"/themes/two"};

fn resourcesHandlerOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("/work", event.resources_discover.cwd);
    try std.testing.expectEqualStrings("startup", event.resources_discover.reason);
    return .{ .resources_discover = .{
        .skill_paths = &resource_skills_1,
        .prompt_paths = &resource_prompts_1,
    } };
}

fn resourcesHandlerFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.ResourcesDiscoverFixtureFailure;
}

fn resourcesHandlerTwo(_: ExtensionEvent) !EventHandlerResult {
    return .{ .resources_discover = .{
        .theme_paths = &resource_themes_2,
    } };
}

test "ResultEventBus resources_discover preserves empty success failure and listener order" {
    const allocator = std.testing.allocator;

    var empty_bus = ResultEventBus.init(allocator);
    defer empty_bus.deinit();
    var empty = try empty_bus.emitResourcesDiscover("/work", "startup");
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.skill_paths.len);
    try std.testing.expectEqual(@as(usize, 0), empty.prompt_paths.len);
    try std.testing.expectEqual(@as(usize, 0), empty.theme_paths.len);

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.resources_discover, resourcesHandlerOne, "/tmp/resources-one.ts");
    try bus.on(.resources_discover, resourcesHandlerFailure, "/tmp/resources-fail.ts");
    try bus.on(.resources_discover, resourcesHandlerTwo, "/tmp/resources-two.ts");

    var result = try bus.emitResourcesDiscover("/work", "startup");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.skill_paths.len);
    try std.testing.expectEqualStrings("/skills/one", result.skill_paths[0].path);
    try std.testing.expectEqualStrings("/tmp/resources-one.ts", result.skill_paths[0].extension_path);
    try std.testing.expectEqual(@as(usize, 1), result.prompt_paths.len);
    try std.testing.expectEqualStrings("/prompts/one", result.prompt_paths[0].path);
    try std.testing.expectEqual(@as(usize, 1), result.theme_paths.len);
    try std.testing.expectEqualStrings("/themes/two", result.theme_paths[0].path);
    try std.testing.expectEqualStrings("/tmp/resources-two.ts", result.theme_paths[0].extension_path);

    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("/tmp/resources-fail.ts", bus.errors.items[0].extension_path);
    try std.testing.expectEqualStrings("resources_discover", bus.errors.items[0].event);
    try std.testing.expectEqualStrings("ResourcesDiscoverFixtureFailure", bus.errors.items[0].@"error");
}

fn inputTransformOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.input.data);
    return .{ .input = .{ .action = .transform, .text = "first" } };
}

fn inputTransformTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.input.data);
    return .{ .input = .{ .action = .transform, .text = "second" } };
}

fn inputHandled(_: ExtensionEvent) !EventHandlerResult {
    return .{ .input = .{ .action = .handled } };
}

test "ResultEventBus input results chain transforms and handled short-circuits" {
    const allocator = std.testing.allocator;

    var empty_bus = ResultEventBus.init(allocator);
    defer empty_bus.deinit();
    var empty = try empty_bus.emitInput("base");
    defer empty.deinit(allocator);
    try std.testing.expect(empty.action == .@"continue");
    try std.testing.expect(empty.text == null);

    var transform_bus = ResultEventBus.init(allocator);
    defer transform_bus.deinit();
    try transform_bus.on(.input, inputTransformOne, "/tmp/input-one.ts");
    try transform_bus.on(.input, inputTransformTwo, "/tmp/input-two.ts");
    var transformed = try transform_bus.emitInput("base");
    defer transformed.deinit(allocator);
    try std.testing.expect(transformed.action == .transform);
    try std.testing.expectEqualStrings("second", transformed.text.?);

    var handled_bus = ResultEventBus.init(allocator);
    defer handled_bus.deinit();
    try handled_bus.on(.input, inputTransformOne, "/tmp/input-one.ts");
    try handled_bus.on(.input, inputHandled, "/tmp/input-handled.ts");
    try handled_bus.on(.input, inputTransformTwo, "/tmp/input-two.ts");
    var handled = try handled_bus.emitInput("base");
    defer handled.deinit(allocator);
    try std.testing.expect(handled.action == .handled);
    try std.testing.expect(handled.text == null);
}

const base_tool_content = [_][]const u8{"base"};
const patched_tool_content = [_][]const u8{"first"};

fn toolResultPatchContent(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.tool_result.content[0]);
    return .{ .tool_result = .{
        .content = &patched_tool_content,
        .details = "{\"source\":\"ext1\"}",
    } };
}

fn toolResultPatchError(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.tool_result.content[0]);
    try std.testing.expectEqualStrings("{\"source\":\"ext1\"}", event.tool_result.details.?);
    return .{ .tool_result = .{ .is_error = true } };
}

test "ResultEventBus tool_result returns undefined empty and chains partial patches" {
    const allocator = std.testing.allocator;

    const event = ToolResultEvent{
        .tool_name = "bash",
        .tool_call_id = "call-1",
        .result = "base",
        .content = &base_tool_content,
        .details = "{\"initial\":true}",
        .is_error = false,
    };

    var empty_bus = ResultEventBus.init(allocator);
    defer empty_bus.deinit();
    const empty = try empty_bus.emitToolResult(event);
    try std.testing.expect(empty == null);

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.tool_result, toolResultPatchContent, "/tmp/tool-result-one.ts");
    try bus.on(.tool_result, toolResultPatchError, "/tmp/tool-result-two.ts");

    const patched = (try bus.emitToolResult(event)).?;
    try std.testing.expectEqual(@as(usize, 1), patched.content.len);
    try std.testing.expectEqualStrings("first", patched.content[0]);
    try std.testing.expectEqualStrings("{\"source\":\"ext1\"}", patched.details.?);
    try std.testing.expect(patched.is_error);
}

var lifecycle_order: u32 = 0;

fn lifecycleHandlerOne(_: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqual(@as(u32, 0), lifecycle_order);
    lifecycle_order += 1;
    return .none;
}

fn lifecycleHandlerFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.LifecycleFixtureFailure;
}

fn lifecycleHandlerTwo(_: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqual(@as(u32, 1), lifecycle_order);
    lifecycle_order += 1;
    return .none;
}

var session_after_cancel_called = false;

fn sessionBeforeContinue(_: ExtensionEvent) !EventHandlerResult {
    return .none;
}

fn sessionBeforeCancel(_: ExtensionEvent) !EventHandlerResult {
    return .{ .session_before = .{ .cancel = true } };
}

fn sessionBeforeAfterCancel(_: ExtensionEvent) !EventHandlerResult {
    session_after_cancel_called = true;
    return .none;
}

test "ResultEventBus lifecycle isolates errors and session_before first cancel short-circuits" {
    const allocator = std.testing.allocator;

    var lifecycle_bus = ResultEventBus.init(allocator);
    defer lifecycle_bus.deinit();
    lifecycle_order = 0;
    try lifecycle_bus.on(.session_start, lifecycleHandlerOne, "/tmp/lifecycle-one.ts");
    try lifecycle_bus.on(.session_start, lifecycleHandlerFailure, "/tmp/lifecycle-fail.ts");
    try lifecycle_bus.on(.session_start, lifecycleHandlerTwo, "/tmp/lifecycle-two.ts");
    try lifecycle_bus.emitLifecycle(.{ .session_start = .{ .reason = "startup" } });
    try std.testing.expectEqual(@as(u32, 2), lifecycle_order);
    try std.testing.expectEqual(@as(usize, 1), lifecycle_bus.errors.items.len);
    try std.testing.expectEqualStrings("session_start", lifecycle_bus.errors.items[0].event);

    var cancel_bus = ResultEventBus.init(allocator);
    defer cancel_bus.deinit();
    session_after_cancel_called = false;
    try cancel_bus.on(.session_before_switch, sessionBeforeContinue, "/tmp/session-one.ts");
    try cancel_bus.on(.session_before_switch, sessionBeforeCancel, "/tmp/session-cancel.ts");
    try cancel_bus.on(.session_before_switch, sessionBeforeAfterCancel, "/tmp/session-after.ts");
    const cancel = (try cancel_bus.emitSessionBefore(.{ .session_before_switch = .{ .reason = "new" } })).?;
    try std.testing.expect(cancel.cancel);
    try std.testing.expect(!session_after_cancel_called);
}

fn inputImageTransformOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.input.data);
    try std.testing.expectEqualStrings("orig-img", event.input.images[0]);
    return .{ .input = .{ .action = .transform, .text = "with-image" } };
}

const replacement_images = [_][]const u8{"new-img"};

fn inputImageTransformTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("with-image", event.input.data);
    try std.testing.expectEqualStrings("orig-img", event.input.images[0]);
    return .{ .input = .{ .action = .transform, .text = "done", .images = &replacement_images } };
}

test "ResultEventBus input preserves and replaces images through transform chaining" {
    const allocator = std.testing.allocator;
    const original_images = [_][]const u8{"orig-img"};

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.input, inputImageTransformOne, "/tmp/input-image-one.ts");
    try bus.on(.input, inputImageTransformTwo, "/tmp/input-image-two.ts");
    var transformed = try bus.emitInputWithImages("base", &original_images);
    defer transformed.deinit(allocator);
    try std.testing.expect(transformed.action == .transform);
    try std.testing.expectEqualStrings("done", transformed.text.?);
    try std.testing.expectEqualStrings("new-img", transformed.images.?[0]);
}

fn messageEndReplaceOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("user", event.message_end.role);
    try std.testing.expectEqualStrings("base", event.message_end.final_message);
    return .{ .message_end = .{ .role = "user", .message = "first" } };
}

fn messageEndInvalidRole(_: ExtensionEvent) !EventHandlerResult {
    return .{ .message_end = .{ .role = "assistant", .message = "invalid" } };
}

fn messageEndReplaceTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.message_end.final_message);
    return .{ .message_end = .{ .message = "second" } };
}

test "ResultEventBus message_end chains same role and reports invalid replacements" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.message_end, messageEndReplaceOne, "/tmp/message-one.ts");
    try bus.on(.message_end, messageEndInvalidRole, "/tmp/message-invalid.ts");
    try bus.on(.message_end, messageEndReplaceTwo, "/tmp/message-two.ts");

    const result = (try bus.emitMessageEnd(.{
        .message_id = "m1",
        .role = "user",
        .final_message = "base",
    })).?;
    try std.testing.expectEqualStrings("user", result.role);
    try std.testing.expectEqualStrings("second", result.message);
    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("message_end handlers must return a message with the same role", bus.errors.items[0].@"error");
}

const context_base = [_][]const u8{"base"};
const context_first = [_][]const u8{ "base", "first" };
const context_second = [_][]const u8{ "base", "first", "second" };

fn contextReplaceOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqual(@as(usize, 1), event.context.messages.len);
    return .{ .context = .{ .messages = &context_first } };
}

fn contextFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.ContextFixtureFailure;
}

fn contextReplaceTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqual(@as(usize, 2), event.context.messages.len);
    return .{ .context = .{ .messages = &context_second } };
}

fn providerReplaceOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.before_provider_request.payload);
    return .{ .before_provider_request = .{ .payload = "first" } };
}

fn providerFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.ProviderFixtureFailure;
}

fn providerReplaceTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.before_provider_request.payload);
    return .{ .before_provider_request = .{ .payload = "second" } };
}

test "ResultEventBus context and provider replacements chain through errors" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.context, contextReplaceOne, "/tmp/context-one.ts");
    try bus.on(.context, contextFailure, "/tmp/context-fail.ts");
    try bus.on(.context, contextReplaceTwo, "/tmp/context-two.ts");
    try bus.on(.before_provider_request, providerReplaceOne, "/tmp/provider-one.ts");
    try bus.on(.before_provider_request, providerFailure, "/tmp/provider-fail.ts");
    try bus.on(.before_provider_request, providerReplaceTwo, "/tmp/provider-two.ts");

    const messages = try bus.emitContext(&context_base);
    const payload = try bus.emitBeforeProviderRequest("base");
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualStrings("second", messages[2]);
    try std.testing.expectEqualStrings("second", payload);
    try std.testing.expectEqual(@as(usize, 2), bus.errors.items.len);
    try std.testing.expectEqualStrings("ContextFixtureFailure", bus.errors.items[0].@"error");
    try std.testing.expectEqualStrings("ProviderFixtureFailure", bus.errors.items[1].@"error");
}

fn beforeAgentStartOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base prompt", event.before_agent_start.system_prompt);
    return .{ .before_agent_start = .{
        .message = "first-message",
        .system_prompt = "first prompt",
    } };
}

fn beforeAgentStartFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.BeforeAgentStartFixtureFailure;
}

fn beforeAgentStartTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first prompt", event.before_agent_start.system_prompt);
    try std.testing.expectEqual(@as(usize, 1), event.before_agent_start.messages.len);
    return .{ .before_agent_start = .{
        .message = "second-message",
        .system_prompt = "second prompt",
    } };
}

test "ResultEventBus before_agent_start aggregates messages and chains system prompt" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.before_agent_start, beforeAgentStartOne, "/tmp/before-one.ts");
    try bus.on(.before_agent_start, beforeAgentStartFailure, "/tmp/before-fail.ts");
    try bus.on(.before_agent_start, beforeAgentStartTwo, "/tmp/before-two.ts");

    var result = (try bus.emitBeforeAgentStart("hello", &.{}, "base prompt")).?;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
    try std.testing.expectEqualStrings("first-message", result.messages[0]);
    try std.testing.expectEqualStrings("second-message", result.messages[1]);
    try std.testing.expectEqualStrings("second prompt", result.system_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("BeforeAgentStartFixtureFailure", bus.errors.items[0].@"error");
}

fn toolCallMutateOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.tool_call.input);
    return .{ .tool_call = .{ .input = "first" } };
}

fn toolCallFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.ToolCallFixtureFailure;
}

fn toolCallBlock(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.tool_call.input);
    return .{ .tool_call = .{ .block = true, .reason = "blocked" } };
}

var tool_call_after_block_called = false;

fn toolCallAfterBlock(_: ExtensionEvent) !EventHandlerResult {
    tool_call_after_block_called = true;
    return .none;
}

test "ResultEventBus tool_call exposes mutations, isolates errors, and first block wins" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    tool_call_after_block_called = false;
    try bus.on(.tool_call, toolCallMutateOne, "/tmp/tool-call-one.ts");
    try bus.on(.tool_call, toolCallFailure, "/tmp/tool-call-fail.ts");
    try bus.on(.tool_call, toolCallBlock, "/tmp/tool-call-block.ts");
    try bus.on(.tool_call, toolCallAfterBlock, "/tmp/tool-call-after.ts");

    const result = (try bus.emitToolCall(.{
        .tool_name = "bash",
        .tool_call_id = "call-1",
        .input = "base",
    })).?;
    try std.testing.expect(result.block);
    try std.testing.expectEqualStrings("first", result.input);
    try std.testing.expectEqualStrings("blocked", result.reason.?);
    try std.testing.expect(!tool_call_after_block_called);
    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("ToolCallFixtureFailure", bus.errors.items[0].@"error");
}

fn userBashUndefined(_: ExtensionEvent) !EventHandlerResult {
    return .none;
}

fn userBashFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.UserBashFixtureFailure;
}

fn userBashResult(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("echo hi", event.user_bash.command);
    return .{ .user_bash = .{ .result = "handled" } };
}

var user_bash_after_result_called = false;

fn userBashAfterResult(_: ExtensionEvent) !EventHandlerResult {
    user_bash_after_result_called = true;
    return .{ .user_bash = .{ .result = "skipped" } };
}

test "ResultEventBus user_bash returns first result after undefined and errors" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    user_bash_after_result_called = false;
    try bus.on(.user_bash, userBashUndefined, "/tmp/user-bash-undefined.ts");
    try bus.on(.user_bash, userBashFailure, "/tmp/user-bash-fail.ts");
    try bus.on(.user_bash, userBashResult, "/tmp/user-bash-result.ts");
    try bus.on(.user_bash, userBashAfterResult, "/tmp/user-bash-after.ts");

    const result = (try bus.emitUserBash(.{ .command = "echo hi", .cwd = "/work" })).?;
    try std.testing.expectEqualStrings("handled", result.result.?);
    try std.testing.expect(!user_bash_after_result_called);
    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("UserBashFixtureFailure", bus.errors.items[0].@"error");
}

test "extension event conformance helper covers every supported event surface" {
    const names = eventSurfaceNames();
    try std.testing.expectEqual(@typeInfo(ExtensionEventType).@"enum".fields.len, names.len);
    try std.testing.expectEqualStrings("resources_discover", names[0]);
    try std.testing.expectEqualStrings("input", names[names.len - 1]);
    inline for (@typeInfo(ExtensionEventType).@"enum".fields, 0..) |field, index| {
        const event_type: ExtensionEventType = @enumFromInt(field.value);
        try std.testing.expectEqualStrings(eventName(event_type), names[index]);
    }
}

var subagent_readiness_observed: bool = false;
var subagent_readiness_second_observer_called: bool = false;

fn subAgentReadinessObserver(event: ExtensionEvent) !void {
    try std.testing.expect(event == .sub_agent_readiness);
    try std.testing.expect(event.sub_agent_readiness.read_only);
    try std.testing.expectEqualStrings("recorded", event.sub_agent_readiness.phase);
    try std.testing.expectEqualStrings("agent", event.sub_agent_readiness.owner);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event.sub_agent_readiness.envelope, .{});
    defer parsed.deinit();
    var validation = try validateSubAgentReadinessEnvelope(std.testing.allocator, parsed.value);
    defer validation.deinit(std.testing.allocator);
    try std.testing.expectEqual(SubAgentReadinessEnvelopeKind.task_invocation, validation.valid);

    subagent_readiness_observed = true;
}

fn subAgentReadinessSecondObserver(event: ExtensionEvent) !void {
    try std.testing.expect(event == .sub_agent_readiness);
    subagent_readiness_second_observer_called = true;
}

test "sub-agent readiness events are subscriber observation only" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    subagent_readiness_observed = false;
    subagent_readiness_second_observer_called = false;

    try bus.on(.sub_agent_readiness, subAgentReadinessObserver, "/tmp/readiness-one.ts");
    try bus.on(.sub_agent_readiness, subAgentReadinessSecondObserver, "/tmp/readiness-two.ts");

    try bus.emit(.{ .sub_agent_readiness = .{
        .envelope = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"taskId\":\"task-opaque\",\"sessionId\":\"session-opaque\",\"input\":{\"text\":\"observe only\"},\"cancellation\":{\"state\":\"requested\",\"reason\":\"abort signal requested\"},\"limits\":{\"maxChildren\":0,\"depth\":1,\"turns\":1}}",
        .phase = "recorded",
        .owner = "agent",
        .read_only = true,
    } });

    try std.testing.expect(subagent_readiness_observed);
    try std.testing.expect(subagent_readiness_second_observer_called);
}

test "sub-agent readiness envelopes validate identity lineage invocation and result wire shape" {
    const allocator = std.testing.allocator;
    const invocation_json =
        \\{"type":"sub_agent_task_invocation","agentId":"agent-opaque","runId":"run-opaque","taskId":"task-opaque","sessionId":"session-opaque","toolCallId":"tool-call-opaque","parentAgentId":"parent-agent","parentRunId":"parent-run","parentTaskId":"parent-task","parentSessionId":"parent-session","parentId":"parent-record","route":"delegate","input":{"text":"summarize"},"limits":{"maxChildren":0,"depth":1,"turns":3,"timeoutMs":2500,"outputBytes":4096,"outputLines":80,"toolScopes":["read-only"]},"cancellation":{"signalId":"cancel-1","state":"pending","parentRunId":"parent-run","parentTaskId":"parent-task"},"metadata":{"substrateOnly":true}}
    ;
    var invocation = try std.json.parseFromSlice(std.json.Value, allocator, invocation_json, .{});
    defer invocation.deinit();
    var invocation_validation = try validateSubAgentReadinessEnvelope(allocator, invocation.value);
    defer invocation_validation.deinit(allocator);
    try std.testing.expect(invocation_validation == .valid);
    try std.testing.expectEqual(SubAgentReadinessEnvelopeKind.task_invocation, invocation_validation.valid);

    const result_json =
        \\{"type":"sub_agent_task_result","agentId":"agent-opaque","runId":"run-opaque","taskId":"task-opaque","sessionId":"session-opaque","parentAgentId":"parent-agent","parentRunId":"parent-run","parentTaskId":"parent-task","parentSessionId":"parent-session","status":"completed","content":[{"type":"text","text":"done"}],"details":{"replaySafe":true},"startedAt":10,"completedAt":20,"usage":{"inputTokens":1,"outputTokens":2,"totalTokens":3,"toolCalls":0},"resourceSummary":{"turns":1,"outputBytes":128,"outputLines":2,"childrenStarted":0,"limitDetails":{"outputBytes":{"limit":4096,"actual":5000,"truncated":true,"reason":"output truncated"},"timeoutMs":{"limit":2500,"actual":2500,"truncated":false},"toolScopes":["read-only"]}}}
    ;
    var result = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer result.deinit();
    var result_validation = try validateSubAgentReadinessEnvelope(allocator, result.value);
    defer result_validation.deinit(allocator);
    try std.testing.expect(result_validation == .valid);
    try std.testing.expectEqual(SubAgentReadinessEnvelopeKind.task_result, result_validation.valid);
}

test "sub-agent readiness envelope validation rejects missing ids product fields and invalid result status" {
    const allocator = std.testing.allocator;
    const invalid_cases = [_]struct {
        json: []const u8,
        path: []const u8,
        message: []const u8,
    }{
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{}}",
            .path = "$.agentId",
            .message = "must not be empty",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"sessionId\":\"session\",\"input\":{}}",
            .path = "$.taskId",
            .message = "missing required field",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"spawnPolicy\":{\"automatic\":true}}",
            .path = "$.spawnPolicy",
            .message = "product UX/spawn policy is not allowed",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"complete\",\"startedAt\":1,\"completedAt\":2}",
            .path = "$.status",
            .message = "unsupported task status \"complete\"",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"limits\":{\"toolScopes\":[\"\"]}}",
            .path = "$.limits.toolScopes[0]",
            .message = "must not be empty",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"cancellation\":{\"state\":\"aborted\",\"propagatedFrom\":\"parent-run\"}}",
            .path = "$.cancellation.state",
            .message = "unsupported cancellation state \"aborted\"",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"cancellation\":{\"state\":\"propagated\",\"parentRunId\":\"\"}}",
            .path = "$.cancellation.parentRunId",
            .message = "must not be empty",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"limits\":{\"maxChildren\":-1}}",
            .path = "$.limits.maxChildren",
            .message = "expected non-negative integer",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"limits\":{\"timeoutMs\":9007199254740992}}",
            .path = "$.limits.timeoutMs",
            .message = "expected non-negative integer",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"completed\",\"startedAt\":1,\"completedAt\":2,\"resourceSummary\":{\"limitDetails\":{\"outputBytes\":{\"limit\":-1}}}}",
            .path = "$.resourceSummary.limitDetails.outputBytes.limit",
            .message = "expected non-negative number",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"completed\",\"startedAt\":1,\"completedAt\":2,\"resourceSummary\":{\"limitDetails\":{\"outputBytes\":{\"limit\":4096,\"actual\":5000}}}}",
            .path = "$.resourceSummary.limitDetails.outputBytes.truncated",
            .message = "missing required field",
        },
    };

    for (invalid_cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, case.json, .{});
        defer parsed.deinit();
        var validation = try validateSubAgentReadinessEnvelope(allocator, parsed.value);
        defer validation.deinit(allocator);
        try std.testing.expect(validation == .invalid);
        try std.testing.expectEqualStrings(case.path, validation.invalid.path);
        try std.testing.expectEqualStrings(case.message, validation.invalid.message);
    }
}

test "sub-agent readiness envelope validation rejects every forbidden product policy field" {
    const allocator = std.testing.allocator;

    for (subagent_forbidden_fields) |field| {
        const invocation_json = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{{}},\"{s}\":{{\"automatic\":true}}}}",
            .{field},
        );
        defer allocator.free(invocation_json);
        var invocation = try std.json.parseFromSlice(std.json.Value, allocator, invocation_json, .{});
        defer invocation.deinit();
        var invocation_validation = try validateSubAgentReadinessEnvelope(allocator, invocation.value);
        defer invocation_validation.deinit(allocator);
        const expected_path = try std.fmt.allocPrint(allocator, "$.{s}", .{field});
        defer allocator.free(expected_path);
        try std.testing.expect(invocation_validation == .invalid);
        try std.testing.expectEqualStrings(expected_path, invocation_validation.invalid.path);
        try std.testing.expectEqualStrings("product UX/spawn policy is not allowed", invocation_validation.invalid.message);

        const result_json = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"completed\",\"startedAt\":1,\"completedAt\":2,\"{s}\":{{\"automatic\":true}}}}",
            .{field},
        );
        defer allocator.free(result_json);
        var result = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
        defer result.deinit();
        var result_validation = try validateSubAgentReadinessEnvelope(allocator, result.value);
        defer result_validation.deinit(allocator);
        try std.testing.expect(result_validation == .invalid);
        try std.testing.expectEqualStrings(expected_path, result_validation.invalid.path);
        try std.testing.expectEqualStrings("product UX/spawn policy is not allowed", result_validation.invalid.message);
    }
}

test "sub-agent readiness envelope validation rejects nested product and trust fields" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        json: []const u8,
        path: []const u8,
    }{
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"metadata\":{\"safe\":true,\"nested\":{\"workflowPreset\":\"review\"}}}",
            .path = "$.metadata.nested.workflowPreset",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"completed\",\"startedAt\":1,\"completedAt\":2,\"details\":{\"nested\":{\"publisher\":\"marketplace\"}}}",
            .path = "$.details.nested.publisher",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"failed\",\"startedAt\":1,\"completedAt\":2,\"error\":{\"reason\":\"failed\",\"details\":{\"remoteUrl\":\"https://example.invalid/ext.wasm\"}}}",
            .path = "$.error.details.remoteUrl",
        },
    };

    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, case.json, .{});
        defer parsed.deinit();
        var validation = try validateSubAgentReadinessEnvelope(allocator, parsed.value);
        defer validation.deinit(allocator);
        try std.testing.expect(validation == .invalid);
        try std.testing.expectEqualStrings(case.path, validation.invalid.path);
        try std.testing.expectEqualStrings("product UX/spawn policy is not allowed", validation.invalid.message);
    }
}

test "extension event surface matches TypeScript parity fixture" {
    const fixture_path = "../packages/coding-agent/test/fixtures/extension-event-surface-names.json";
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, fixture_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .array);
    const fixture_names = parsed.value.array.items;
    const names = eventSurfaceNames();
    try std.testing.expectEqual(names.len, fixture_names.len);

    for (names, fixture_names) |zig_name, fixture_name| {
        try std.testing.expect(fixture_name == .string);
        try std.testing.expectEqualStrings(zig_name, fixture_name.string);
    }
}
