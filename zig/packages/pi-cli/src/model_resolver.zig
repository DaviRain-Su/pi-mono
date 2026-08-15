const std = @import("std");
const ai = @import("ai");
const string_utils = ai.shared.string_utils;
const cli = @import("args.zig");

pub const ResolveCliModelResult = struct {
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    thinking: ?cli.ThinkingLevel = null,
    warning: ?[]u8 = null,
    error_message: ?[]u8 = null,
    owned_model_name: ?[]u8 = null,

    pub fn deinit(self: *ResolveCliModelResult, allocator: std.mem.Allocator) void {
        if (self.warning) |warning| allocator.free(warning);
        if (self.error_message) |message| allocator.free(message);
        if (self.owned_model_name) |model_name| allocator.free(model_name);
        self.* = undefined;
    }
};

const ParsedPattern = struct {
    model: ?ai.model_registry.ModelSummary = null,
    thinking: ?cli.ThinkingLevel = null,
};

pub const HasConfiguredAuth = struct {
    ctx: *const anyopaque,
    func: *const fn (ctx: *const anyopaque, provider: []const u8) bool,

    pub fn check(self: HasConfiguredAuth, provider: []const u8) bool {
        return self.func(self.ctx, provider);
    }
};

pub fn resolveCliModel(
    allocator: std.mem.Allocator,
    cli_provider: ?[]const u8,
    cli_model: ?[]const u8,
) !ResolveCliModelResult {
    return resolveCliModelWithAuth(allocator, cli_provider, cli_model, null);
}

pub fn resolveCliModelWithAuth(
    allocator: std.mem.Allocator,
    cli_provider: ?[]const u8,
    cli_model: ?[]const u8,
    has_auth: ?HasConfiguredAuth,
) !ResolveCliModelResult {
    const model_pattern = cli_model orelse return .{};

    const summaries = try ai.model_registry.listSummaries(allocator);
    defer allocator.free(summaries);

    if (summaries.len == 0) {
        return .{
            .error_message = try allocator.dupe(u8, "No models available. Check your installation or add models to models.json."),
        };
    }

    var provider = if (cli_provider) |value| canonicalProvider(summaries, value) else null;
    if (cli_provider != null and provider == null) {
        return .{
            .error_message = try std.fmt.allocPrint(
                allocator,
                "Unknown provider \"{s}\". Use --list-models to see available providers/models.",
                .{cli_provider.?},
            ),
        };
    }

    var pattern = model_pattern;
    var inferred_provider = false;
    if (provider == null) {
        if (std.mem.indexOfScalar(u8, model_pattern, '/')) |slash_index| {
            const maybe_provider = model_pattern[0..slash_index];
            if (canonicalProvider(summaries, maybe_provider)) |canonical| {
                provider = canonical;
                pattern = model_pattern[slash_index + 1 ..];
                inferred_provider = true;
            }
        }
    }

    if (provider == null) {
        if (try resolveExactMatchesAcrossProviders(allocator, summaries, model_pattern, has_auth)) |resolved| {
            return resolved;
        }
    }

    if (cli_provider != null and provider != null) {
        const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{provider.?});
        defer allocator.free(prefix);
        if (startsWithIgnoreCase(model_pattern, prefix)) {
            pattern = model_pattern[prefix.len..];
        }
    }

    const parsed = parseModelPattern(pattern, summaries, provider, false);
    if (parsed.model) |model| {
        if (inferred_provider) {
            if (preferAuthenticatedRawId(summaries, model_pattern, model, has_auth)) |raw| {
                return .{
                    .provider_name = raw.provider,
                    .model_name = raw.id,
                };
            }
        }
        return .{
            .provider_name = model.provider,
            .model_name = model.id,
            .thinking = parsed.thinking,
        };
    }

    if (inferred_provider) {
        if (findExactReferenceMatch(summaries, model_pattern, null)) |exact| {
            return .{
                .provider_name = exact.provider,
                .model_name = exact.id,
            };
        }

        const fallback = parseModelPattern(model_pattern, summaries, null, false);
        if (fallback.model) |model| {
            return .{
                .provider_name = model.provider,
                .model_name = model.id,
                .thinking = fallback.thinking,
            };
        }
    }

    if (provider) |resolved_provider| {
        const warning = try std.fmt.allocPrint(
            allocator,
            "Model \"{s}\" not found for provider \"{s}\". Using custom model id.",
            .{ pattern, resolved_provider },
        );
        return .{
            .provider_name = resolved_provider,
            .model_name = pattern,
            .warning = warning,
            .owned_model_name = if (pattern.ptr == model_pattern.ptr and pattern.len == model_pattern.len)
                null
            else
                try allocator.dupe(u8, pattern),
        };
    }

    return .{
        .error_message = try std.fmt.allocPrint(
            allocator,
            "Model \"{s}\" not found. Use --list-models to see available models.",
            .{model_pattern},
        ),
    };
}

fn resolveExactMatchesAcrossProviders(
    allocator: std.mem.Allocator,
    summaries: []const ai.model_registry.ModelSummary,
    reference: []const u8,
    has_auth: ?HasConfiguredAuth,
) !?ResolveCliModelResult {
    var matches: std.ArrayList(ai.model_registry.ModelSummary) = .empty;
    defer matches.deinit(allocator);
    try collectExactMatches(allocator, &matches, summaries, reference);
    if (matches.items.len == 0) return null;
    if (matches.items.len == 1) {
        return .{
            .provider_name = matches.items[0].provider,
            .model_name = matches.items[0].id,
        };
    }

    var authenticated: std.ArrayList(ai.model_registry.ModelSummary) = .empty;
    defer authenticated.deinit(allocator);
    for (matches.items) |summary| {
        if (hasConfiguredAuth(has_auth, summary.provider)) {
            try authenticated.append(allocator, summary);
        }
    }
    if (authenticated.items.len == 1) {
        return .{
            .provider_name = authenticated.items[0].provider,
            .model_name = authenticated.items[0].id,
        };
    }

    const joined = try joinSortedModelRefs(allocator, matches.items);
    defer allocator.free(joined);
    const hint: []const u8 = if (authenticated.items.len == 0)
        "No matching provider is authenticated."
    else
        "More than one matching provider is authenticated.";
    return .{
        .error_message = try std.fmt.allocPrint(
            allocator,
            "Model \"{s}\" is ambiguous across providers: {s}. {s} Use --provider or provider/model.",
            .{ reference, joined, hint },
        ),
    };
}

fn collectExactMatches(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(ai.model_registry.ModelSummary),
    summaries: []const ai.model_registry.ModelSummary,
    reference: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, reference, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    for (summaries) |summary| {
        if (std.ascii.eqlIgnoreCase(summary.id, trimmed) or
            canonicalReferenceMatches(trimmed, summary.provider, summary.id))
        {
            try matches.append(allocator, summary);
        }
    }
}

fn preferAuthenticatedRawId(
    summaries: []const ai.model_registry.ModelSummary,
    raw_id: []const u8,
    inferred: ai.model_registry.ModelSummary,
    has_auth: ?HasConfiguredAuth,
) ?ai.model_registry.ModelSummary {
    if (hasConfiguredAuth(has_auth, inferred.provider)) return null;

    var chosen: ?ai.model_registry.ModelSummary = null;
    for (summaries) |summary| {
        if (std.ascii.eqlIgnoreCase(summary.provider, inferred.provider) and
            std.ascii.eqlIgnoreCase(summary.id, inferred.id))
        {
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(summary.id, raw_id)) continue;
        if (!hasConfiguredAuth(has_auth, summary.provider)) continue;
        if (chosen != null) return null;
        chosen = summary;
    }
    return chosen;
}

fn hasConfiguredAuth(has_auth: ?HasConfiguredAuth, provider: []const u8) bool {
    return if (has_auth) |probe| probe.check(provider) else false;
}

fn joinSortedModelRefs(
    allocator: std.mem.Allocator,
    matches: []const ai.model_registry.ModelSummary,
) ![]u8 {
    const refs = try allocator.alloc([]u8, matches.len);
    var filled: usize = 0;
    errdefer {
        for (refs[0..filled]) |ref| allocator.free(ref);
        allocator.free(refs);
    }
    for (matches, 0..) |summary, index| {
        refs[index] = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ summary.provider, summary.id });
        filled = index + 1;
    }
    std.mem.sort([]u8, refs, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (refs, 0..) |ref, index| {
        if (index > 0) try joined.appendSlice(allocator, ", ");
        try joined.appendSlice(allocator, ref);
    }
    const result = try joined.toOwnedSlice(allocator);
    for (refs) |ref| allocator.free(ref);
    allocator.free(refs);
    return result;
}

fn parseModelPattern(
    pattern: []const u8,
    summaries: []const ai.model_registry.ModelSummary,
    provider: ?[]const u8,
    allow_invalid_thinking_fallback: bool,
) ParsedPattern {
    if (tryMatchModel(summaries, pattern, provider)) |model| {
        return .{ .model = model };
    }

    const colon_index = std.mem.lastIndexOfScalar(u8, pattern, ':') orelse return .{};
    const prefix = pattern[0..colon_index];
    const suffix = pattern[colon_index + 1 ..];
    if (parseThinkingLevel(suffix)) |thinking| {
        const parsed = parseModelPattern(prefix, summaries, provider, allow_invalid_thinking_fallback);
        if (parsed.model) |model| {
            return .{ .model = model, .thinking = thinking };
        }
        return parsed;
    }

    if (!allow_invalid_thinking_fallback) return .{};
    return parseModelPattern(prefix, summaries, provider, allow_invalid_thinking_fallback);
}

fn tryMatchModel(
    summaries: []const ai.model_registry.ModelSummary,
    pattern: []const u8,
    provider: ?[]const u8,
) ?ai.model_registry.ModelSummary {
    if (findExactReferenceMatch(summaries, pattern, provider)) |exact| return exact;

    var best: ?ai.model_registry.ModelSummary = null;
    for (summaries) |summary| {
        if (provider) |provider_name| {
            if (!std.ascii.eqlIgnoreCase(summary.provider, provider_name)) continue;
        }
        if (!string_utils.containsIgnoreCase(summary.id, pattern) and !string_utils.containsIgnoreCase(summary.name, pattern)) continue;

        if (isBetterFuzzyCandidate(summary, best, provider == null)) best = summary;
    }

    return best;
}

fn findExactReferenceMatch(
    summaries: []const ai.model_registry.ModelSummary,
    reference: []const u8,
    provider: ?[]const u8,
) ?ai.model_registry.ModelSummary {
    const trimmed = std.mem.trim(u8, reference, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    var canonical_match: ?ai.model_registry.ModelSummary = null;
    for (summaries) |summary| {
        if (provider) |provider_name| {
            if (!std.ascii.eqlIgnoreCase(summary.provider, provider_name)) continue;
        }
        if (canonicalReferenceMatches(trimmed, summary.provider, summary.id)) {
            if (canonical_match != null) return null;
            canonical_match = summary;
        }
    }
    if (canonical_match) |match| return match;

    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash_index| {
        const ref_provider = std.mem.trim(u8, trimmed[0..slash_index], &std.ascii.whitespace);
        const ref_model = std.mem.trim(u8, trimmed[slash_index + 1 ..], &std.ascii.whitespace);
        if (ref_provider.len > 0 and ref_model.len > 0) {
            var provider_match: ?ai.model_registry.ModelSummary = null;
            for (summaries) |summary| {
                if (provider) |provider_name| {
                    if (!std.ascii.eqlIgnoreCase(summary.provider, provider_name)) continue;
                }
                if (std.ascii.eqlIgnoreCase(summary.provider, ref_provider) and std.ascii.eqlIgnoreCase(summary.id, ref_model)) {
                    if (provider_match != null) return null;
                    provider_match = summary;
                }
            }
            if (provider_match) |match| return match;
        }
    }

    var id_match: ?ai.model_registry.ModelSummary = null;
    for (summaries) |summary| {
        if (provider) |provider_name| {
            if (!std.ascii.eqlIgnoreCase(summary.provider, provider_name)) continue;
        }
        if (!std.ascii.eqlIgnoreCase(summary.id, trimmed)) continue;
        if (id_match != null) return null;
        id_match = summary;
    }
    return id_match;
}

fn canonicalProvider(
    summaries: []const ai.model_registry.ModelSummary,
    provider: []const u8,
) ?[]const u8 {
    for (summaries) |summary| {
        if (std.ascii.eqlIgnoreCase(summary.provider, provider)) return summary.provider;
    }
    for (ai.model_registry.builtInProviderConfigs()) |config| {
        if (std.ascii.eqlIgnoreCase(config.provider, provider)) return config.provider;
    }
    return null;
}

fn canonicalReferenceMatches(reference: []const u8, provider: []const u8, model_id: []const u8) bool {
    if (reference.len != provider.len + 1 + model_id.len) return false;
    if (!std.ascii.eqlIgnoreCase(reference[0..provider.len], provider)) return false;
    if (reference[provider.len] != '/') return false;
    return std.ascii.eqlIgnoreCase(reference[provider.len + 1 ..], model_id);
}

fn parseThinkingLevel(value: []const u8) ?cli.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

fn isAlias(id: []const u8) bool {
    if (std.mem.endsWith(u8, id, "-latest")) return true;
    if (id.len < 9) return true;
    const suffix = id[id.len - 9 ..];
    if (suffix[0] != '-') return true;
    for (suffix[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return true;
    }
    return false;
}

fn isBetterFuzzyCandidate(
    candidate: ai.model_registry.ModelSummary,
    current: ?ai.model_registry.ModelSummary,
    prefer_direct_providers: bool,
) bool {
    const existing = current orelse return true;

    if (prefer_direct_providers) {
        const candidate_rank = fuzzyProviderRank(candidate.provider);
        const existing_rank = fuzzyProviderRank(existing.provider);
        if (candidate_rank != existing_rank) return candidate_rank < existing_rank;
    }

    const candidate_alias = isAlias(candidate.id);
    const existing_alias = isAlias(existing.id);
    if (candidate_alias != existing_alias) return candidate_alias;

    return stringGreater(candidate.id, existing.id);
}

fn fuzzyProviderRank(provider: []const u8) u8 {
    return if (isAggregatorProvider(provider)) 1 else 0;
}

fn isAggregatorProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "amazon-bedrock") or
        std.mem.eql(u8, provider, "azure-openai-responses") or
        std.mem.eql(u8, provider, "cloudflare-ai-gateway") or
        std.mem.eql(u8, provider, "cloudflare-workers-ai") or
        std.mem.eql(u8, provider, "fireworks") or
        std.mem.eql(u8, provider, "google-vertex") or
        std.mem.eql(u8, provider, "github-copilot") or
        std.mem.eql(u8, provider, "huggingface") or
        std.mem.eql(u8, provider, "opencode") or
        std.mem.eql(u8, provider, "opencode-go") or
        std.mem.eql(u8, provider, "openrouter") or
        std.mem.eql(u8, provider, "vercel-ai-gateway");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn stringGreater(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .gt;
}

test "resolveCliModel resolves provider-prefixed model ids" {
    const allocator = std.testing.allocator;
    var result = try resolveCliModel(allocator, null, "openai/gpt-5.4");
    defer result.deinit(allocator);

    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openai", result.provider_name.?);
    try std.testing.expectEqualStrings("gpt-5.4", result.model_name.?);
}

test "resolveCliModel supports fuzzy matching and thinking suffix" {
    const allocator = std.testing.allocator;
    var result = try resolveCliModel(allocator, null, "sonnet:high");
    defer result.deinit(allocator);

    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("anthropic", result.provider_name.?);
    try std.testing.expectEqualStrings("claude-sonnet-5", result.model_name.?);
    try std.testing.expectEqual(cli.ThinkingLevel.high, result.thinking.?);
}

test "resolveCliModel prefers provider split over gateway raw id when provider model exists" {
    const allocator = std.testing.allocator;
    var result = try resolveCliModel(allocator, null, "zai/glm-5.2");
    defer result.deinit(allocator);

    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("zai", result.provider_name.?);
    try std.testing.expectEqualStrings("glm-5.2", result.model_name.?);
}

test "resolveCliModel falls back to exact raw slash model id when inferred provider has no match" {
    const allocator = std.testing.allocator;
    var result = try resolveCliModel(allocator, null, "openai/gpt-3.5-turbo:batch");
    defer result.deinit(allocator);

    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openrouter", result.provider_name.?);
    try std.testing.expectEqualStrings("openai/gpt-3.5-turbo:batch", result.model_name.?);
}

test "resolveCliModel preserves explicit provider custom model ids" {
    const allocator = std.testing.allocator;
    var result = try resolveCliModel(allocator, "openrouter", "openrouter/openai/ghost-model");
    defer result.deinit(allocator);

    try std.testing.expect(result.error_message == null);
    try std.testing.expect(result.warning != null);
    try std.testing.expectEqualStrings("openrouter", result.provider_name.?);
    try std.testing.expectEqualStrings("openai/ghost-model", result.model_name.?);
}

test "resolveCliModel reports missing fuzzy matches without provider" {
    const allocator = std.testing.allocator;
    var result = try resolveCliModel(allocator, null, "definitely-not-a-real-model");
    defer result.deinit(allocator);

    try std.testing.expect(result.provider_name == null);
    try std.testing.expect(result.model_name == null);
    try std.testing.expect(result.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "not found") != null);
}

fn testAuthProbe(ctx: *const anyopaque, provider: []const u8) bool {
    const names: *const []const []const u8 = @ptrCast(@alignCast(ctx));
    for (names.*) |name| {
        if (std.mem.eql(u8, name, provider)) return true;
    }
    return false;
}

test "resolveCliModel prefers the sole authenticated provider for an ambiguous bare id" {
    const allocator = std.testing.allocator;
    const names: []const []const u8 = &.{"openai"};
    var result = try resolveCliModelWithAuth(allocator, null, "gpt-5.4", .{
        .ctx = @ptrCast(&names),
        .func = testAuthProbe,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openai", result.provider_name.?);
    try std.testing.expectEqualStrings("gpt-5.4", result.model_name.?);
}

test "resolveCliModel requires --provider when a bare id is ambiguous" {
    const allocator = std.testing.allocator;
    var none = try resolveCliModel(allocator, null, "gpt-5.4");
    defer none.deinit(allocator);
    try std.testing.expect(none.provider_name == null);
    try std.testing.expect(none.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, none.error_message.?, "ambiguous across providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, none.error_message.?, "openai/gpt-5.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, none.error_message.?, "github-copilot/gpt-5.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, none.error_message.?, "No matching provider is authenticated.") != null);

    const names: []const []const u8 = &.{ "openai", "github-copilot" };
    var both = try resolveCliModelWithAuth(allocator, null, "gpt-5.4", .{
        .ctx = @ptrCast(&names),
        .func = testAuthProbe,
    });
    defer both.deinit(allocator);
    try std.testing.expect(both.provider_name == null);
    try std.testing.expect(std.mem.indexOf(u8, both.error_message.?, "More than one matching provider is authenticated.") != null);
}

test "resolveCliModel prefers an authenticated raw id over an unauthenticated inferred provider" {
    const allocator = std.testing.allocator;
    const names: []const []const u8 = &.{"openrouter"};
    var result = try resolveCliModelWithAuth(allocator, null, "xiaomi/mimo-v2.5-pro", .{
        .ctx = @ptrCast(&names),
        .func = testAuthProbe,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openrouter", result.provider_name.?);
    try std.testing.expectEqualStrings("xiaomi/mimo-v2.5-pro", result.model_name.?);
}
