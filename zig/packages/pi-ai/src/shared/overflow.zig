const std = @import("std");
const string_utils = @import("string_utils.zig");
const types = @import("../types.zig");

const overflow_patterns = [_][]const u8{
    "prompt is too long",
    "request_too_large",
    "input is too long for requested model",
    "exceeds the context window",
    "input token count",
    "maximum prompt length is",
    "reduce the length of the messages",
    "maximum context length is",
    "maximum context length of", // OpenAI-compatible proxies (LiteLLM)
    "is longer than the model's context length",
    "is longer than the models context length",
    "exceeds the limit of",
    "exceeds the available context size",
    "greater than the context length",
    "context window exceeds limit",
    "exceeded model token limit",
    "too large for model with",
    "model_context_window_exceeded",
    "prompt too long; exceeded",
    "overflow",
    "context length exceeded",
    "context_length_exceeded",
    "too many tokens",
    "token limit exceeded",
};

const non_overflow_patterns = [_][]const u8{
    "throttling error",
    "service unavailable",
    "rate limit",
    "too many requests",
};

pub fn isContextOverflow(message: types.AssistantMessage, context_window: ?u32) bool {
    if (message.stop_reason == .error_reason) {
        const error_message = message.error_message orelse return false;
        if (!matchesAny(error_message, &non_overflow_patterns) and matchesOverflow(error_message)) {
            return true;
        }
    }

    if (context_window) |window| {
        if (window > 0 and message.stop_reason == .stop and supportsSilentOverflowDetection(message)) {
            const input_tokens = message.usage.input + message.usage.cache_read;
            if (input_tokens > window) return true;
        }
    }

    return false;
}

fn matchesOverflow(message: []const u8) bool {
    if (matchesAny(message, &overflow_patterns)) return true;
    return startsWithStatusNoBody(message, "400") or startsWithStatusNoBody(message, "413");
}

fn matchesAny(message: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (string_utils.containsIgnoreCase(message, pattern)) return true;
    }
    return false;
}

fn startsWithStatusNoBody(message: []const u8, prefix: []const u8) bool {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;
    return string_utils.containsIgnoreCase(trimmed, "(no body)");
}

fn supportsSilentOverflowDetection(message: types.AssistantMessage) bool {
    return string_utils.containsIgnoreCase(message.provider, "zai") or string_utils.containsIgnoreCase(message.provider, "z.ai");
}

test "isContextOverflow detects provider error patterns" {
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "Your input exceeds the context window of this model.",
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, 32768));
}

test "isContextOverflow detects LiteLLM-wrapped OpenAI maximum context length errors" {
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "openai-completions",
        .provider = "litellm",
        .model = "gpt-4o-mini",
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "Error: 503 litellm.ServiceUnavailableError: litellm.MidStreamFallbackError: litellm.APIConnectionError: APIConnectionError: OpenAIException - Requested token count exceeds the model's maximum context length of 131072 tokens.",
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, 131072));
}

test "isContextOverflow detects Together context length messages" {
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "openai-completions",
        .provider = "together",
        .model = "moonshotai/Kimi-K2.6",
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "The input (300000 tokens) is longer than the model's context length (262144 tokens).",
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, 262144));
}

test "isContextOverflow ignores rate limit style non overflow errors" {
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .model = "claude",
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "Throttling error: Too many tokens, please wait before trying again.",
        .timestamp = 0,
    };

    try std.testing.expect(!isContextOverflow(message, 200000));
}

test "isContextOverflow detects silent usage based overflow" {
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "google-generative-ai",
        .provider = "zai",
        .model = "glm-4.5",
        .usage = .{
            .input = 1200,
            .cache_read = 100,
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, 1000));
}

test "isContextOverflow returns false for ordinary stops" {
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-sonnet-4",
        .usage = .{
            .input = 512,
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try std.testing.expect(!isContextOverflow(message, 4096));
}
