const std = @import("std");
const types = @import("../types.zig");

/// Coerce an optional JSON integer-or-null into a u32, clamping negatives to 0
/// and non-integer types to 0. Centralized so every OpenAI-family provider
/// applies the same coercion (previously duplicated in openai_responses,
/// openai_codex_responses, and azure_openai_responses).
pub fn jsonIntegerToU32(maybe_value: ?std.json.Value) u32 {
    const value = maybe_value orelse return 0;
    return switch (value) {
        .integer => |integer| @intCast(@max(@as(i64, 0), integer)),
        else => 0,
    };
}

/// Parse usage tokens from an OpenAI Responses API `usage` object.
///
/// Shape (Responses API):
///   {
///     "input_tokens": int,
///     "output_tokens": int,
///     "total_tokens": int,
///     "input_tokens_details": { "cached_tokens": int }
///   }
///
/// Semantics:
///   - `input` = `input_tokens - cached_tokens` (saturating at 0)
///   - `cache_read` = `cached_tokens`
///   - `cache_write` = 0 (Responses API doesn't report writes separately)
///   - `total_tokens` = reported value, falling back to the sum of components
pub fn parseResponsesUsage(value: std.json.Value) types.Usage {
    var usage = types.Usage.init();
    if (value != .object) return usage;

    const input_tokens = jsonIntegerToU32(value.object.get("input_tokens"));
    const output_tokens = jsonIntegerToU32(value.object.get("output_tokens"));
    const total_tokens = jsonIntegerToU32(value.object.get("total_tokens"));

    var cached_tokens: u32 = 0;
    if (value.object.get("input_tokens_details")) |details| {
        if (details == .object) {
            cached_tokens = jsonIntegerToU32(details.object.get("cached_tokens"));
        }
    }

    usage.input = if (input_tokens >= cached_tokens) input_tokens - cached_tokens else 0;
    usage.output = output_tokens;
    usage.cache_read = cached_tokens;
    usage.cache_write = 0;
    usage.total_tokens = if (total_tokens > 0)
        total_tokens
    else
        usage.input + usage.output + usage.cache_read + usage.cache_write;
    return usage;
}

/// Parse usage tokens from an OpenAI Chat Completions / OpenRouter-compatible
/// `usage` object.
///
/// Shape (Chat API + OpenRouter extensions):
///   {
///     "prompt_tokens": int,
///     "completion_tokens": int,
///     "prompt_tokens_details": {
///       "cached_tokens": int,           // cache-read hits
///       "cache_write_tokens": int       // OpenRouter-only, not in OpenAI spec
///     },
///     "prompt_cache_hit_tokens": int    // DeepSeek-compatible fallback for cached_tokens
///   }
///
/// Semantics (matches the TypeScript implementation in
/// `packages/ai/src/providers/openai-chat.ts`):
///   - `cache_read` = `prompt_tokens_details.cached_tokens
///                    ?? prompt_cache_hit_tokens ?? 0`
///   - `cache_write` = `prompt_tokens_details.cache_write_tokens ?? 0`
///   - `input` = `prompt_tokens - cache_read - cache_write` (saturating at 0)
///   - `output` = `completion_tokens` (already includes reasoning tokens)
///
/// IMPORTANT: do **not** subtract `cache_write` from `cached_tokens`. The old
/// "subtract writes" path under-reported spec-compliant providers; the current
/// behavior is what OpenAI/OpenRouter document. See commit 3c46e419.
pub fn parseChatUsage(value: std.json.Value) types.Usage {
    var usage = types.Usage.init();
    if (value != .object) return usage;

    const prompt_tokens = jsonIntegerToU32(value.object.get("prompt_tokens"));
    const completion_tokens = jsonIntegerToU32(value.object.get("completion_tokens"));

    // A boolean flag is needed because `cached_tokens = 0` is a valid explicit
    // value that must not trigger the prompt_cache_hit_tokens fallback (the
    // semantics match TypeScript's `??` nullish coalescing operator).
    var reported_cached_tokens: u32 = 0;
    var found_cached_tokens = false;
    var cache_write_tokens: u32 = 0;

    if (value.object.get("prompt_tokens_details")) |details| {
        if (details == .object) {
            if (details.object.get("cached_tokens")) |ct| {
                if (ct == .integer) {
                    reported_cached_tokens = @as(u32, @intCast(@max(@as(i64, 0), ct.integer)));
                    found_cached_tokens = true;
                }
            }
            if (details.object.get("cache_write_tokens")) |cwt| {
                if (cwt == .integer) cache_write_tokens = @as(u32, @intCast(@max(@as(i64, 0), cwt.integer)));
            }
        }
    }

    if (!found_cached_tokens) {
        if (value.object.get("prompt_cache_hit_tokens")) |pcht| {
            if (pcht == .integer) reported_cached_tokens = @as(u32, @intCast(@max(@as(i64, 0), pcht.integer)));
        }
    }

    const cache_read = reported_cached_tokens;
    const cache_total = cache_read + cache_write_tokens;
    const input = if (cache_total >= prompt_tokens) @as(u32, 0) else prompt_tokens - cache_total;

    usage.input = input;
    usage.output = completion_tokens;
    usage.cache_read = cache_read;
    usage.cache_write = cache_write_tokens;
    usage.total_tokens = input + completion_tokens + cache_read + cache_write_tokens;
    return usage;
}

const testing = std.testing;

fn parseObject(comptime json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json_text, .{});
}

test "jsonIntegerToU32 handles null, non-integer, and negative" {
    try testing.expectEqual(@as(u32, 0), jsonIntegerToU32(null));
    try testing.expectEqual(@as(u32, 0), jsonIntegerToU32(.{ .string = "5" }));
    try testing.expectEqual(@as(u32, 0), jsonIntegerToU32(.{ .integer = -3 }));
    try testing.expectEqual(@as(u32, 42), jsonIntegerToU32(.{ .integer = 42 }));
}

test "parseResponsesUsage subtracts cached_tokens from input_tokens" {
    var parsed = try parseObject(
        \\{"input_tokens":100,"output_tokens":50,"total_tokens":150,"input_tokens_details":{"cached_tokens":20}}
    );
    defer parsed.deinit();
    const usage = parseResponsesUsage(parsed.value);
    try testing.expectEqual(@as(u32, 80), usage.input);
    try testing.expectEqual(@as(u32, 50), usage.output);
    try testing.expectEqual(@as(u32, 20), usage.cache_read);
    try testing.expectEqual(@as(u32, 0), usage.cache_write);
    try testing.expectEqual(@as(u32, 150), usage.total_tokens);
}

test "parseResponsesUsage saturates input at zero when cached exceeds input" {
    var parsed = try parseObject(
        \\{"input_tokens":10,"output_tokens":5,"input_tokens_details":{"cached_tokens":30}}
    );
    defer parsed.deinit();
    const usage = parseResponsesUsage(parsed.value);
    try testing.expectEqual(@as(u32, 0), usage.input);
    try testing.expectEqual(@as(u32, 30), usage.cache_read);
}

test "parseResponsesUsage falls back to sum when total_tokens missing" {
    var parsed = try parseObject(
        \\{"input_tokens":7,"output_tokens":3,"input_tokens_details":{"cached_tokens":2}}
    );
    defer parsed.deinit();
    const usage = parseResponsesUsage(parsed.value);
    try testing.expectEqual(@as(u32, 5), usage.input);
    try testing.expectEqual(@as(u32, 3), usage.output);
    try testing.expectEqual(@as(u32, 2), usage.cache_read);
    try testing.expectEqual(@as(u32, 5 + 3 + 2), usage.total_tokens);
}

test "parseChatUsage applies OpenRouter cache_read + cache_write semantics" {
    var parsed = try parseObject(
        \\{"prompt_tokens":100,"completion_tokens":50,"prompt_tokens_details":{"cached_tokens":20,"cache_write_tokens":10}}
    );
    defer parsed.deinit();
    const usage = parseChatUsage(parsed.value);
    try testing.expectEqual(@as(u32, 70), usage.input); // 100 - 20 - 10
    try testing.expectEqual(@as(u32, 50), usage.output);
    try testing.expectEqual(@as(u32, 20), usage.cache_read);
    try testing.expectEqual(@as(u32, 10), usage.cache_write);
    try testing.expectEqual(@as(u32, 150), usage.total_tokens);
}

test "parseChatUsage falls back to prompt_cache_hit_tokens when details missing" {
    var parsed = try parseObject(
        \\{"prompt_tokens":50,"completion_tokens":10,"prompt_cache_hit_tokens":15}
    );
    defer parsed.deinit();
    const usage = parseChatUsage(parsed.value);
    try testing.expectEqual(@as(u32, 35), usage.input);
    try testing.expectEqual(@as(u32, 15), usage.cache_read);
}

test "parseChatUsage does NOT use prompt_cache_hit_tokens fallback when explicit cached_tokens=0" {
    var parsed = try parseObject(
        \\{"prompt_tokens":50,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":0},"prompt_cache_hit_tokens":15}
    );
    defer parsed.deinit();
    const usage = parseChatUsage(parsed.value);
    try testing.expectEqual(@as(u32, 50), usage.input); // cached_tokens=0 wins
    try testing.expectEqual(@as(u32, 0), usage.cache_read);
}

test "parseChatUsage saturates input at zero when cache totals exceed prompt" {
    var parsed = try parseObject(
        \\{"prompt_tokens":15,"completion_tokens":4,"prompt_tokens_details":{"cache_write_tokens":20}}
    );
    defer parsed.deinit();
    const usage = parseChatUsage(parsed.value);
    try testing.expectEqual(@as(u32, 0), usage.input);
    try testing.expectEqual(@as(u32, 20), usage.cache_write);
}

// Cross-provider invariant: every Responses-API provider must funnel through
// the shared `parseResponsesUsage` (no local re-implementation). Comptime
// equality check on the function pointer locks this in — if someone copies a
// local parseUsage back into a provider, this test stops compiling. Add a new
// row whenever a new Responses-family provider is introduced.
test "all Responses-API providers route usage parsing through shared helper" {
    const openai_responses = @import("../providers/openai_responses.zig");
    const openai_codex_responses = @import("../providers/openai_codex_responses.zig");
    const azure_openai_responses = @import("../providers/azure_openai_responses.zig");

    try testing.expectEqual(
        @intFromPtr(&parseResponsesUsage),
        @intFromPtr(&openai_responses.parseUsage),
    );
    try testing.expectEqual(
        @intFromPtr(&parseResponsesUsage),
        @intFromPtr(&openai_codex_responses.parseUsage),
    );
    try testing.expectEqual(
        @intFromPtr(&parseResponsesUsage),
        @intFromPtr(&azure_openai_responses.parseUsage),
    );
}
