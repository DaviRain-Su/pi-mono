//! POC: prove that `std.json.Stringify.value` on a declarative Zig struct
//! produces the SAME byte-for-byte JSON as the current ObjectMap-based
//! payload-builder approach.
//!
//! If every assertion in this file holds, the per-provider migration to
//! struct-based payloads (project_json_serializer_followup memory) is
//! viable using stdlib alone, no custom serializer needed for the
//! straightforward cases.
//!
//! This file is throwaway — once the first real provider migration lands
//! it should be deleted.

const std = @import("std");
const provider_json = @import("provider_json.zig");
const provider_json_put = @import("provider_json_put.zig");

const putIntegerValue = provider_json_put.putIntegerValue;
const putFloatValue = provider_json_put.putFloatValue;
const putStringValue = provider_json_put.putStringValue;
const putBoolValue = provider_json_put.putBoolValue;

const testing = std.testing;

/// Helper: serialize an ObjectMap-built `std.json.Value` and return the
/// owned JSON string the caller must free.
fn stringifyValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Helper: serialize a Zig struct via reflection with omit-null-optionals,
/// return owned JSON string.
fn stringifyStruct(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{
        .emit_null_optional_fields = false,
    });
}

// =============================================================================
// CASE 1: simple object with two optional fields (mirrors
//         bedrock.buildInferenceConfigValue).
// =============================================================================

test "POC bedrock-style inferenceConfig: both fields present" {
    const allocator = testing.allocator;

    // Current path: ObjectMap + put helpers.
    const object_path = blk: {
        var config = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = config });
        try putIntegerValue(allocator, &config, "maxTokens", @as(u32, 1024));
        try putFloatValue(allocator, &config, "temperature", 0.7);
        break :blk std.json.Value{ .object = config };
    };
    defer provider_json.freeValue(allocator, object_path);
    const old_json = try stringifyValue(allocator, object_path);
    defer allocator.free(old_json);

    // New path: declarative struct + reflection.
    const InferenceConfig = struct {
        maxTokens: ?u32 = null,
        temperature: ?f64 = null,
    };
    const new_json = try stringifyStruct(allocator, InferenceConfig{
        .maxTokens = 1024,
        .temperature = 0.7,
    });
    defer allocator.free(new_json);

    try testing.expectEqualStrings(old_json, new_json);
}

test "POC bedrock-style inferenceConfig: only maxTokens set (temperature omitted)" {
    const allocator = testing.allocator;

    const object_path = blk: {
        var config = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = config });
        try putIntegerValue(allocator, &config, "maxTokens", @as(u32, 256));
        break :blk std.json.Value{ .object = config };
    };
    defer provider_json.freeValue(allocator, object_path);
    const old_json = try stringifyValue(allocator, object_path);
    defer allocator.free(old_json);

    const InferenceConfig = struct {
        maxTokens: ?u32 = null,
        temperature: ?f64 = null,
    };
    const new_json = try stringifyStruct(allocator, InferenceConfig{ .maxTokens = 256 });
    defer allocator.free(new_json);

    try testing.expectEqualStrings(old_json, new_json);
}

test "POC bedrock-style inferenceConfig: empty object when both fields null" {
    const allocator = testing.allocator;

    const object_path = blk: {
        const config = try provider_json.initObject(allocator);
        break :blk std.json.Value{ .object = config };
    };
    defer provider_json.freeValue(allocator, object_path);
    const old_json = try stringifyValue(allocator, object_path);
    defer allocator.free(old_json);

    const InferenceConfig = struct {
        maxTokens: ?u32 = null,
        temperature: ?f64 = null,
    };
    const new_json = try stringifyStruct(allocator, InferenceConfig{});
    defer allocator.free(new_json);

    try testing.expectEqualStrings(old_json, new_json);
}

// =============================================================================
// CASE 2: object with nested object (mirrors how cache_control etc. is built).
// =============================================================================

test "POC nested object: anthropic-style cache_control { type: ephemeral, ttl: 1h }" {
    const allocator = testing.allocator;

    const object_path = blk: {
        var cache_control = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = cache_control });
        try putStringValue(allocator, &cache_control, "type", "ephemeral");
        try putStringValue(allocator, &cache_control, "ttl", "1h");
        break :blk std.json.Value{ .object = cache_control };
    };
    defer provider_json.freeValue(allocator, object_path);
    const old_json = try stringifyValue(allocator, object_path);
    defer allocator.free(old_json);

    const CacheControl = struct {
        type: []const u8,
        ttl: ?[]const u8 = null,
    };
    const new_json = try stringifyStruct(allocator, CacheControl{
        .type = "ephemeral",
        .ttl = "1h",
    });
    defer allocator.free(new_json);

    try testing.expectEqualStrings(old_json, new_json);
}

test "POC nested object: cache_control with ttl omitted" {
    const allocator = testing.allocator;

    const object_path = blk: {
        var cache_control = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = cache_control });
        try putStringValue(allocator, &cache_control, "type", "ephemeral");
        break :blk std.json.Value{ .object = cache_control };
    };
    defer provider_json.freeValue(allocator, object_path);
    const old_json = try stringifyValue(allocator, object_path);
    defer allocator.free(old_json);

    const CacheControl = struct {
        type: []const u8,
        ttl: ?[]const u8 = null,
    };
    const new_json = try stringifyStruct(allocator, CacheControl{ .type = "ephemeral" });
    defer allocator.free(new_json);

    try testing.expectEqualStrings(old_json, new_json);
}

// =============================================================================
// CASE 3: top-level payload with mixed required/optional, bool, nested.
//         (mirrors a stripped-down anthropic buildRequestPayload.)
// =============================================================================

test "POC top-level payload: model + max_tokens + stream + nested thinking" {
    const allocator = testing.allocator;

    const object_path = blk: {
        var payload = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = payload });
        try putStringValue(allocator, &payload, "model", "claude-sonnet-4-7");
        try putIntegerValue(allocator, &payload, "max_tokens", @as(u32, 8192));
        try putBoolValue(allocator, &payload, "stream", true);
        const thinking_value: std.json.Value = inner: {
            var thinking = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = thinking });
            try putStringValue(allocator, &thinking, "type", "enabled");
            try putIntegerValue(allocator, &thinking, "budget_tokens", @as(u32, 1024));
            break :inner std.json.Value{ .object = thinking };
        };
        try provider_json_put.putObjectValue(allocator, &payload, "thinking", thinking_value);
        break :blk std.json.Value{ .object = payload };
    };
    defer provider_json.freeValue(allocator, object_path);
    const old_json = try stringifyValue(allocator, object_path);
    defer allocator.free(old_json);

    const Thinking = struct {
        type: []const u8,
        budget_tokens: u32,
    };
    const Payload = struct {
        model: []const u8,
        max_tokens: u32,
        stream: bool,
        thinking: ?Thinking = null,
    };
    const new_json = try stringifyStruct(allocator, Payload{
        .model = "claude-sonnet-4-7",
        .max_tokens = 8192,
        .stream = true,
        .thinking = .{ .type = "enabled", .budget_tokens = 1024 },
    });
    defer allocator.free(new_json);

    try testing.expectEqualStrings(old_json, new_json);
}

// =============================================================================
// CASE 4: slice of u8 vs string.  Validates that a `[]const u8` field is
//         emitted as a JSON string, not a byte array.
// =============================================================================

test "POC []const u8 field serializes as JSON string" {
    const allocator = testing.allocator;

    const Wrapper = struct {
        text: []const u8,
    };
    const json = try stringifyStruct(allocator, Wrapper{ .text = "hello world" });
    defer allocator.free(json);

    try testing.expectEqualStrings("{\"text\":\"hello world\"}", json);
}

// =============================================================================
// CASE 5: slice of struct → JSON array of objects.
// =============================================================================

test "POC []Message → JSON array of objects" {
    const allocator = testing.allocator;

    const Message = struct {
        role: []const u8,
        content: []const u8,
    };

    const messages = [_]Message{
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .content = "hello!" },
    };

    const Conversation = struct {
        messages: []const Message,
    };

    const json = try stringifyStruct(allocator, Conversation{ .messages = &messages });
    defer allocator.free(json);

    try testing.expectEqualStrings(
        "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"assistant\",\"content\":\"hello!\"}]}",
        json,
    );
}

// =============================================================================
// CASE 6: custom jsonStringify — escape hatch for provider-specific shapes
//         (e.g. AnthropicToolChoice tagged union → { type: tool, name: foo }).
// =============================================================================

test "POC custom jsonStringify on a tagged union" {
    const allocator = testing.allocator;

    const ToolChoice = union(enum) {
        auto,
        any,
        tool: []const u8,

        // Note: the doc comment in std/json/Stringify.zig says `self: *@This()`
        // but stdlib's own example (std.json.Value) and the actual call site
        // (`v.jsonStringify(self)`) take @This() by value. Trust the example.
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type");
            switch (self) {
                .auto => try jw.write("auto"),
                .any => try jw.write("any"),
                .tool => |name| {
                    try jw.write("tool");
                    try jw.objectField("name");
                    try jw.write(name);
                },
            }
            try jw.endObject();
        }
    };

    // IMPORTANT: `const x = ToolChoice.auto;` infers as the enum tag type
    // (because tag access on a union(enum) is ambiguous), which sends
    // serialization down the enum path → `"auto"` not `{"type":"auto"}`.
    // Force the union type with an explicit annotation.
    const tc_auto: ToolChoice = .auto;
    const json_auto = try std.json.Stringify.valueAlloc(allocator, tc_auto, .{});
    defer allocator.free(json_auto);
    try testing.expectEqualStrings("{\"type\":\"auto\"}", json_auto);

    const tc_tool: ToolChoice = .{ .tool = "read" };
    const json_tool = try std.json.Stringify.valueAlloc(allocator, tc_tool, .{});
    defer allocator.free(json_tool);
    try testing.expectEqualStrings("{\"type\":\"tool\",\"name\":\"read\"}", json_tool);
}

// =============================================================================
// CASE 7: embedding a pre-built std.json.Value (e.g. tool_call.arguments which
//         is parsed JSON of unknown shape).
// =============================================================================

test "POC embed std.json.Value field for dynamic content" {
    const allocator = testing.allocator;

    // Build a dynamic value (the kind tool_call.arguments holds).
    var arg_object = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = arg_object });
    try putStringValue(allocator, &arg_object, "path", "/tmp/x");
    try putIntegerValue(allocator, &arg_object, "lines", @as(u32, 42));

    const ToolUse = struct {
        name: []const u8,
        arguments: std.json.Value,
    };

    const tool_use = ToolUse{ .name = "read", .arguments = .{ .object = arg_object } };
    const json = try std.json.Stringify.valueAlloc(allocator, tool_use, .{});
    defer allocator.free(json);

    // std.json.Value's own jsonStringify handles the nested object; we just
    // need to confirm both keys appear.
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"read\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"path\":\"/tmp/x\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"lines\":42") != null);
}
