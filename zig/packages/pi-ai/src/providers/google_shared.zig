const std = @import("std");

pub const GoogleThinkingLevel = enum {
    THINKING_LEVEL_UNSPECIFIED,
    MINIMAL,
    LOW,
    MEDIUM,
    HIGH,
};

pub fn isThinkingPart(thought: ?bool) bool {
    return thought orelse false;
}

pub fn retainThoughtSignature(existing: ?[]const u8, incoming: ?[]const u8) ?[]const u8 {
    if (incoming) |signature| {
        if (signature.len > 0) return signature;
    }
    return existing;
}

pub fn requiresToolCallId(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "claude-") or std.mem.startsWith(u8, model_id, "gpt-oss-");
}

pub fn resolveThoughtSignature(is_same_provider_and_model: bool, signature: ?[]const u8) ?[]const u8 {
    if (!is_same_provider_and_model) return null;
    const value = signature orelse return null;
    return if (isValidThoughtSignature(value)) value else null;
}

fn isValidThoughtSignature(signature: []const u8) bool {
    if (signature.len == 0 or signature.len % 4 != 0) return false;
    for (signature) |byte| {
        const valid = (byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '+' or
            byte == '/' or
            byte == '=';
        if (!valid) return false;
    }
    return true;
}

pub fn getGeminiMajorVersion(model_id: []const u8) ?usize {
    const prefix = if (startsWithIgnoreCase(model_id, "gemini-live-"))
        "gemini-live-"
    else if (startsWithIgnoreCase(model_id, "gemini-"))
        "gemini-"
    else
        return null;

    var index = prefix.len;
    var value: usize = 0;
    var found_digit = false;
    while (index < model_id.len and std.ascii.isDigit(model_id[index])) : (index += 1) {
        found_digit = true;
        value = value * 10 + model_id[index] - '0';
    }
    return if (found_digit) value else null;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

pub fn supportsMultimodalFunctionResponse(model_id: []const u8) bool {
    if (getGeminiMajorVersion(model_id)) |major| return major >= 3;
    return true;
}

test "google shared identifies thinking parts and retains signatures" {
    try std.testing.expect(isThinkingPart(true));
    try std.testing.expect(!isThinkingPart(null));
    try std.testing.expectEqualStrings("new", retainThoughtSignature("old", "new").?);
    try std.testing.expectEqualStrings("old", retainThoughtSignature("old", "").?);
}

test "google shared validates tool ids and gemini versions" {
    try std.testing.expect(requiresToolCallId("claude-sonnet-4"));
    try std.testing.expect(requiresToolCallId("gpt-oss-120b"));
    try std.testing.expect(!requiresToolCallId("gemini-3-pro"));
    try std.testing.expectEqual(@as(?usize, 3), getGeminiMajorVersion("gemini-3-pro"));
    try std.testing.expect(supportsMultimodalFunctionResponse("gemini-3-pro"));
    try std.testing.expect(!supportsMultimodalFunctionResponse("gemini-2.5-pro"));
}
