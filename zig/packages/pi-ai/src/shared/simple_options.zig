const std = @import("std");
const types = @import("../types.zig");

pub const AdjustedThinkingTokens = struct {
    max_tokens: u32,
    thinking_budget: u32,
};

/// Build a StreamOptions baseline from optional simple options + an explicit
/// api_key override. Same-named fields are propagated via comptime iteration
/// so the two structs stay in sync as fields are added; only fields with
/// different names or fallback semantics are handled explicitly below.
pub fn buildBaseOptions(
    model: types.Model,
    options: ?types.SimpleStreamOptions,
    api_key: ?[]const u8,
) types.StreamOptions {
    var opts: types.StreamOptions = .{};

    if (options) |value| {
        inline for (@typeInfo(types.SimpleStreamOptions).@"struct".fields) |field| {
            if (comptime @hasField(types.StreamOptions, field.name)) {
                @field(opts, field.name) = @field(value, field.name);
            }
        }
        // Generic reasoning maps onto Bedrock-specific knobs at this layer;
        // anthropic / responses / mistral mappings happen later in stream.zig.
        opts.provider.bedrock = .{
            .reasoning = value.reasoning,
            .thinking_budgets = value.thinking_budgets,
        };
        opts.max_tokens = value.max_tokens orelse defaultMaxTokens(model);
    } else {
        opts.max_tokens = defaultMaxTokens(model);
    }

    // Explicit api_key parameter wins over any value carried in SimpleStreamOptions.
    if (api_key) |key| opts.api_key = key;

    return opts;
}

pub fn clampReasoning(effort: ?types.ThinkingLevel) ?types.ThinkingLevel {
    return switch (effort orelse return null) {
        .xhigh => .high,
        else => |value| value,
    };
}

pub fn adjustMaxTokensForThinking(
    base_max_tokens: u32,
    model_max_tokens: u32,
    reasoning_level: types.ThinkingLevel,
    custom_budgets: ?types.ThinkingBudgets,
) AdjustedThinkingTokens {
    const budgets = custom_budgets orelse types.ThinkingBudgets{};
    const min_output_tokens: u32 = 1024;
    const level = clampReasoning(reasoning_level).?;
    var thinking_budget = switch (level) {
        .minimal => budgets.minimal,
        .low => budgets.low,
        .medium => budgets.medium,
        .high, .xhigh => budgets.high,
    };

    const max_tokens = @min(base_max_tokens +| thinking_budget, model_max_tokens);
    if (max_tokens <= thinking_budget) {
        thinking_budget = if (max_tokens > min_output_tokens) max_tokens - min_output_tokens else 0;
    }

    return .{
        .max_tokens = max_tokens,
        .thinking_budget = thinking_budget,
    };
}

fn defaultMaxTokens(model: types.Model) ?u32 {
    if (model.max_tokens == 0) return null;
    return model.max_tokens;
}

test "buildBaseOptions applies defaults and explicit api key override" {
    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const options = types.SimpleStreamOptions{
        .temperature = 0.25,
        .api_key = "fallback-key",
        .cache_retention = .long,
        .session_id = "session-123",
        .max_retry_delay_ms = 1234,
    };

    const base = buildBaseOptions(model, options, "provided-key");
    try std.testing.expectEqual(@as(?f32, 0.25), base.temperature);
    try std.testing.expectEqual(@as(?u32, 64000), base.max_tokens);
    try std.testing.expectEqualStrings("provided-key", base.api_key.?);
    try std.testing.expectEqual(types.CacheRetention.long, base.cache_retention);
    try std.testing.expectEqualStrings("session-123", base.session_id.?);
    try std.testing.expectEqual(@as(u32, 1234), base.max_retry_delay_ms);
}

test "buildBaseOptions supports websocket_cached transport flag" {
    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const options = types.SimpleStreamOptions{
        .transport = .websocket_cached,
    };

    const base = buildBaseOptions(model, options, null);
    // Ensure the transport value is propagated through
    try std.testing.expect(base.transport == .websocket_cached);
}

test "buildBaseOptions respects short cache retention and session_id usage" {
    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const options = types.SimpleStreamOptions{
        .cache_retention = .short,
        .session_id = "sess-1",
    };

    const base = buildBaseOptions(model, options, null);
    try std.testing.expectEqual(types.CacheRetention.short, base.cache_retention);
    try std.testing.expectEqualStrings("sess-1", base.session_id.?);
}

test "clampReasoning downgrades xhigh only" {
    try std.testing.expectEqual(@as(?types.ThinkingLevel, .high), clampReasoning(.xhigh));
    try std.testing.expectEqual(@as(?types.ThinkingLevel, .medium), clampReasoning(.medium));
    try std.testing.expectEqual(@as(?types.ThinkingLevel, null), clampReasoning(null));
}

test "adjustMaxTokensForThinking uses default budgets" {
    const adjusted = adjustMaxTokensForThinking(4000, 10000, .medium, null);
    try std.testing.expectEqual(@as(u32, 10000), adjusted.max_tokens);
    try std.testing.expectEqual(@as(u32, 8192), adjusted.thinking_budget);
}

test "adjustMaxTokensForThinking preserves output space when capped" {
    const adjusted = adjustMaxTokensForThinking(500, 900, .high, null);
    try std.testing.expectEqual(@as(u32, 900), adjusted.max_tokens);
    try std.testing.expectEqual(@as(u32, 0), adjusted.thinking_budget);
}
