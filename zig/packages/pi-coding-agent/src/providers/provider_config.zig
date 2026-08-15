const std = @import("std");
const ai = @import("ai");
const string_utils = ai.shared.string_utils;
const auth = @import("../auth/auth.zig");
const common = @import("../tools/common.zig");
const provider_info = @import("../core/provider_info.zig");

const faux = ai.providers.faux;

pub const ResolveProviderError = error{
    MissingApiKey,
    UnknownProvider,
    InvalidFauxStopReason,
    InvalidFauxTokensPerSecond,
    InvalidFauxContextWindow,
    InvalidFauxToolArguments,
    InvalidModelMetadata,
};

pub const ProviderAuthStatus = enum {
    missing,
    local,
    runtime,
    stored,
    environment,
};

const OwnedFauxMessage = struct {
    blocks: []faux.FauxContentBlock,

    fn deinit(self: *OwnedFauxMessage, allocator: std.mem.Allocator) void {
        for (self.blocks) |*block| {
            switch (block.*) {
                .tool_call => |*tool_call| {
                    allocator.free(tool_call.id);
                    allocator.free(tool_call.name);
                    common.deinitJsonValue(allocator, tool_call.arguments);
                },
                else => {},
            }
        }
        allocator.free(self.blocks);
        self.* = undefined;
    }
};

pub const ResolvedProviderConfig = struct {
    model: ai.Model,
    api_key: ?[]const u8,
    owned_api_key: ?[]u8 = null,
    auth_status: ProviderAuthStatus = .missing,
    faux_registration: ?faux.FauxProviderRegistration = null,
    owned_faux_messages: ?[]OwnedFauxMessage = null,

    pub fn deinit(self: *ResolvedProviderConfig, allocator: std.mem.Allocator) void {
        if (self.faux_registration) |registration| registration.unregister();
        ai.model_registry.deinitOwnedModel(allocator, &self.model);
        if (self.owned_api_key) |api_key| allocator.free(api_key);
        if (self.owned_faux_messages) |messages| {
            for (messages) |*message| message.deinit(allocator);
            allocator.free(messages);
        }
        self.* = undefined;
    }
};

pub const AvailableModel = struct {
    provider: []const u8,
    model_id: []const u8,
    display_name: []const u8,
    available: bool,
    auth_status: ProviderAuthStatus,
    reasoning: bool,
    tool_calling: bool,
    loaded: bool,
    supports_images: bool,
    context_window: u32,
    max_tokens: u32,
};

pub const ConfiguredCredentials = struct {
    auth_tokens: ?*const std.StringHashMap([]const u8) = null,
    provider_api_keys: ?*const std.StringHashMap([]const u8) = null,

    pub fn lookup(self: ConfiguredCredentials, provider: []const u8) ?[]const u8 {
        if (self.auth_tokens) |auth_tokens| {
            if (auth_tokens.get(provider)) |value| {
                if (isNonEmptyCredentialValue(value)) return value;
            }
        }
        if (self.provider_api_keys) |provider_api_keys| {
            if (provider_api_keys.get(provider)) |value| {
                if (isNonEmptyCredentialValue(value)) return value;
            }
        }
        return null;
    }
};

pub fn resolveProviderConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    model_override: ?[]const u8,
    api_key_override: ?[]const u8,
    configured_api_key: ?[]const u8,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    return resolveProviderConfigWithPolicy(
        allocator,
        io,
        env_map,
        provider,
        model_override,
        api_key_override,
        configured_api_key,
        .{},
    );
}

pub fn resolveProviderConfigAllowMissingCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    model_override: ?[]const u8,
    api_key_override: ?[]const u8,
    configured_api_key: ?[]const u8,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    return resolveProviderConfigWithPolicy(
        allocator,
        io,
        env_map,
        provider,
        model_override,
        api_key_override,
        configured_api_key,
        .{ .allow_missing_credentials = true },
    );
}

const ResolveProviderPolicy = struct {
    allow_missing_credentials: bool = false,
};

fn resolveProviderConfigWithPolicy(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    model_override: ?[]const u8,
    api_key_override: ?[]const u8,
    configured_api_key: ?[]const u8,
    policy: ResolveProviderPolicy,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    const descriptor = if (!std.mem.eql(u8, provider, "faux"))
        ai.model_registry.getProviderConfig(provider) orelse return error.UnknownProvider
    else
        null;

    if (std.mem.eql(u8, provider, "faux") or shouldForceFauxProvider(env_map, provider)) {
        return try resolveFauxProvider(allocator, env_map, provider, model_override, descriptor);
    }

    const provider_descriptor = descriptor.?;
    const resolved_api_key = try auth.resolveApiKey(allocator, io, env_map, provider, api_key_override, configured_api_key);
    const local_provider = isLocalBaseUrl(provider_descriptor.base_url);
    if (resolved_api_key == null and !local_provider and !policy.allow_missing_credentials) return error.MissingApiKey;

    const model_id = model_override orelse provider_descriptor.default_model_id orelse provider;
    const model = ai.model_registry.find(provider, model_id) orelse fallbackModel(provider_descriptor, model_id);
    var owned_model = ai.model_registry.cloneOwnedModel(allocator, model) catch |err| {
        if (resolved_api_key) |api_key| {
            if (api_key.owned_api_key) |owned_api_key| allocator.free(owned_api_key);
        }
        return err;
    };
    errdefer ai.model_registry.deinitOwnedModel(allocator, &owned_model);
    const auth_status: ProviderAuthStatus = if (resolved_api_key) |api_key|
        authStatusFromSource(api_key.source)
    else if (local_provider) .local else .missing;

    return .{
        .model = owned_model,
        .api_key = if (resolved_api_key) |api_key| api_key.api_key else null,
        .owned_api_key = if (resolved_api_key) |api_key| api_key.owned_api_key else null,
        .auth_status = auth_status,
    };
}

pub fn listAvailableModels(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ?ai.Model,
    configured_credentials: ConfiguredCredentials,
) ![]AvailableModel {
    const summaries = try ai.model_registry.listSummaries(allocator);
    defer allocator.free(summaries);

    var models = std.ArrayList(AvailableModel).empty;
    errdefer models.deinit(allocator);

    for (summaries) |summary| {
        const is_current = if (current_model) |model| modelMatchesReference(model, summary.provider, summary.id) else false;
        const auth_status = try resolveAvailableProviderAuthStatus(allocator, env_map, summary.provider, configured_credentials);
        const credentials_available = auth_status != .missing;
        try models.append(allocator, .{
            .provider = summary.provider,
            .model_id = summary.id,
            .display_name = summary.name,
            .available = is_current or credentials_available,
            .auth_status = auth_status,
            .reasoning = summary.reasoning,
            .tool_calling = summary.tool_calling,
            .loaded = summary.loaded,
            .supports_images = hasInputType(summary.input_types, "image"),
            .context_window = summary.context_window,
            .max_tokens = summary.max_tokens,
        });
    }

    if (current_model) |model| {
        var seen = false;
        for (models.items) |entry| {
            if (std.mem.eql(u8, entry.provider, model.provider) and std.mem.eql(u8, entry.model_id, model.id)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            try models.append(allocator, .{
                .provider = model.provider,
                .model_id = model.id,
                .display_name = model.name,
                .available = true,
                .auth_status = .missing,
                .reasoning = model.reasoning,
                .tool_calling = model.tool_calling,
                .loaded = model.loaded,
                .supports_images = hasInputType(model.input_types, "image"),
                .context_window = model.context_window,
                .max_tokens = model.max_tokens,
            });
        }
    }

    std.mem.sort(AvailableModel, models.items, {}, lessThanAvailableModel);
    return try models.toOwnedSlice(allocator);
}

pub fn filterConfiguredModels(
    allocator: std.mem.Allocator,
    available: []const AvailableModel,
) ![]AvailableModel {
    var filtered = std.ArrayList(AvailableModel).empty;
    errdefer filtered.deinit(allocator);

    for (available) |entry| {
        if (entry.available) try filtered.append(allocator, entry);
    }

    return try filtered.toOwnedSlice(allocator);
}

pub fn findInitialDefaultModel(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    configured_credentials: ConfiguredCredentials,
) !?ai.Model {
    for (ai.model_registry.builtInProviderConfigs()) |provider| {
        if (std.mem.eql(u8, provider.provider, "faux")) continue;
        if (try preferredInitialDefaultProvider(allocator, env_map, provider.provider, configured_credentials)) |preferred| {
            const model_id = preferred.default_model_id orelse preferred.provider;
            return ai.model_registry.find(preferred.provider, model_id) orelse fallbackModel(preferred, model_id);
        }
        if (!try hasProviderCredentials(allocator, env_map, provider.provider, configured_credentials)) continue;

        const model_id = provider.default_model_id orelse provider.provider;
        return ai.model_registry.find(provider.provider, model_id) orelse fallbackModel(provider, model_id);
    }
    return null;
}

pub fn filterAvailableModels(
    allocator: std.mem.Allocator,
    available: []const AvailableModel,
    patterns: []const []const u8,
) ![]AvailableModel {
    if (patterns.len == 0) return allocator.dupe(AvailableModel, available);

    var filtered = std.ArrayList(AvailableModel).empty;
    errdefer filtered.deinit(allocator);

    for (patterns) |pattern| {
        for (available) |entry| {
            if (availableModelMatchesPattern(entry, pattern)) {
                if (!availableModelAlreadyIncluded(filtered.items, entry)) {
                    try filtered.append(allocator, entry);
                }
            }
        }
    }

    return try filtered.toOwnedSlice(allocator);
}

fn availableModelAlreadyIncluded(models: []const AvailableModel, candidate: AvailableModel) bool {
    for (models) |model| {
        if (std.mem.eql(u8, model.provider, candidate.provider) and
            std.mem.eql(u8, model.model_id, candidate.model_id))
        {
            return true;
        }
    }
    return false;
}

pub fn resolveProviderErrorMessage(err: anyerror, provider: []const u8) []const u8 {
    return switch (err) {
        error.MissingApiKey => missingApiKeyMessage(provider),
        error.UnknownProvider => "Unsupported provider. Use --list-models to see available providers and models, or configure a custom provider.",
        error.InvalidFauxStopReason => "Invalid PI_FAUX_STOP_REASON. Expected stop, length, tool_use, error, or aborted.",
        error.InvalidFauxTokensPerSecond => "Invalid PI_FAUX_TOKENS_PER_SECOND. Expected an integer.",
        error.InvalidFauxContextWindow => "Invalid PI_FAUX_CONTEXT_WINDOW. Expected an integer.",
        error.InvalidFauxToolArguments => "Invalid PI_FAUX_TOOL_ARGS_JSON. Expected a JSON object or value.",
        else => @errorName(err),
    };
}

pub fn providerDisplayName(provider: []const u8) []const u8 {
    return provider_info.displayNameFor(provider) orelse provider;
}

pub fn providerAuthStatusLabel(status: ProviderAuthStatus) []const u8 {
    return switch (status) {
        .missing => "needs auth",
        .local => "local",
        .runtime => "--api-key",
        .stored => "saved",
        .environment => "env",
    };
}

fn authStatusFromSource(source: auth.CredentialSource) ProviderAuthStatus {
    return switch (source) {
        .runtime => .runtime,
        .stored => .stored,
        .environment => .environment,
    };
}

fn shouldForceFauxProvider(env_map: *const std.process.Environ.Map, provider: []const u8) bool {
    const value = env_map.get("PI_FAUX_FORCE") orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "*") or
        std.mem.eql(u8, value, provider);
}

fn isNonEmptyCredentialValue(value: []const u8) bool {
    return std.mem.trim(u8, value, &std.ascii.whitespace).len > 0;
}

fn lessThanAvailableModel(_: void, lhs: AvailableModel, rhs: AvailableModel) bool {
    const provider_order = std.ascii.orderIgnoreCase(lhs.provider, rhs.provider);
    if (provider_order != .eq) return provider_order == .lt;
    return std.ascii.orderIgnoreCase(lhs.model_id, rhs.model_id) == .lt;
}

fn hasInputType(input_types: []const []const u8, expected: []const u8) bool {
    for (input_types) |input_type| {
        if (std.ascii.eqlIgnoreCase(input_type, expected)) return true;
    }
    return false;
}

fn modelMatchesReference(model: ai.Model, provider: []const u8, model_id: []const u8) bool {
    return std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id);
}

fn availableModelMatchesPattern(entry: AvailableModel, raw_pattern: []const u8) bool {
    const pattern = normalizeModelPattern(raw_pattern);
    if (pattern.len == 0) return false;

    if (std.mem.indexOfScalar(u8, pattern, '/')) |slash_index| {
        const provider_pattern = std.mem.trim(u8, pattern[0..slash_index], &std.ascii.whitespace);
        const model_pattern = std.mem.trim(u8, pattern[slash_index + 1 ..], &std.ascii.whitespace);
        if (provider_pattern.len == 0 or model_pattern.len == 0) return false;

        return fieldMatches(entry.provider, provider_pattern, true) and
            (fieldMatches(entry.model_id, model_pattern, false) or
                fieldMatches(entry.display_name, model_pattern, false));
    }

    return fieldMatches(entry.model_id, pattern, false) or
        fieldMatches(entry.display_name, pattern, false) or
        fieldMatches(entry.provider, pattern, false);
}

fn normalizeModelPattern(raw_pattern: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_pattern, &std.ascii.whitespace);
    const colon_index = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return trimmed;
    const suffix = trimmed[colon_index + 1 ..];
    if (isThinkingLevelSuffix(suffix)) return trimmed[0..colon_index];
    return trimmed;
}

fn isThinkingLevelSuffix(value: []const u8) bool {
    return std.mem.eql(u8, value, "off") or
        std.mem.eql(u8, value, "minimal") or
        std.mem.eql(u8, value, "low") or
        std.mem.eql(u8, value, "medium") or
        std.mem.eql(u8, value, "high") or
        std.mem.eql(u8, value, "xhigh");
}

fn fieldMatches(field: []const u8, pattern: []const u8, exact_when_plain: bool) bool {
    if (pattern.len == 0) return false;
    if (hasWildcard(pattern)) return wildcardMatchIgnoreCase(pattern, field);
    if (exact_when_plain) return std.ascii.eqlIgnoreCase(field, pattern);
    return string_utils.containsIgnoreCase(field, pattern);
}

fn hasWildcard(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?[") != null;
}

fn wildcardMatchIgnoreCase(pattern: []const u8, text: []const u8) bool {
    return wildcardMatchIgnoreCaseRecursive(pattern, text, 0, 0);
}

fn wildcardMatchIgnoreCaseRecursive(pattern: []const u8, text: []const u8, pattern_index: usize, text_index: usize) bool {
    var p = pattern_index;
    var t = text_index;

    while (p < pattern.len) : (p += 1) {
        switch (pattern[p]) {
            '*' => {
                var next_pattern = p + 1;
                while (next_pattern < pattern.len and pattern[next_pattern] == '*') : (next_pattern += 1) {}
                if (next_pattern == pattern.len) return true;

                var candidate = t;
                while (candidate <= text.len) : (candidate += 1) {
                    if (wildcardMatchIgnoreCaseRecursive(pattern, text, next_pattern, candidate)) return true;
                }
                return false;
            },
            '?' => {
                if (t >= text.len) return false;
                t += 1;
            },
            else => {
                if (t >= text.len) return false;
                if (!std.ascii.eqlIgnoreCase(pattern[p .. p + 1], text[t .. t + 1])) return false;
                t += 1;
            },
        }
    }

    return t == text.len;
}

fn resolveFauxProvider(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    model_override: ?[]const u8,
    descriptor: ?ai.model_registry.ProviderConfig,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    const tokens_per_second = if (env_map.get("PI_FAUX_TOKENS_PER_SECOND")) |value|
        std.fmt.parseInt(u32, value, 10) catch return error.InvalidFauxTokensPerSecond
    else
        null;

    const context_window = if (env_map.get("PI_FAUX_CONTEXT_WINDOW")) |value|
        std.fmt.parseInt(u32, value, 10) catch return error.InvalidFauxContextWindow
    else
        null;

    const selected_model_id = model_override orelse if (descriptor) |provider_descriptor|
        provider_descriptor.default_model_id orelse provider
    else
        provider;
    const registered_model = ai.model_registry.find(provider, selected_model_id);

    var faux_model_definition: ?faux.FauxModelDefinition = null;
    if (descriptor != null or model_override != null or context_window != null) {
        faux_model_definition = .{
            .id = selected_model_id,
            .name = if (registered_model) |model| model.name else selected_model_id,
            .reasoning = if (registered_model) |model| model.reasoning else false,
            .input = if (registered_model) |model| model.input_types else null,
            .cost = if (registered_model) |model| model.cost else null,
            .context_window = context_window orelse if (registered_model) |model| model.context_window else null,
            .max_tokens = if (registered_model) |model| model.max_tokens else null,
        };
    }

    var faux_model_definitions: [1]faux.FauxModelDefinition = undefined;
    const faux_models: ?[]const faux.FauxModelDefinition = if (faux_model_definition) |definition| blk: {
        faux_model_definitions[0] = definition;
        break :blk faux_model_definitions[0..];
    } else null;

    const registration = try faux.registerFauxProvider(allocator, .{
        .api = if (descriptor) |provider_descriptor| provider_descriptor.api else null,
        .provider = provider,
        .models = faux_models,
        .tokens_per_second = tokens_per_second,
    });
    errdefer registration.unregister();

    const owned_messages = try buildOwnedFauxMessages(allocator, env_map);
    errdefer {
        for (owned_messages) |*message| message.deinit(allocator);
        allocator.free(owned_messages);
    }

    if (owned_messages.len == 1) {
        try registration.setResponses(&[_]faux.FauxResponseStep{
            .{ .message = faux.fauxAssistantMessage(owned_messages[0].blocks, .{
                .stop_reason = parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse
                    return error.InvalidFauxStopReason,
                .error_message = env_map.get("PI_FAUX_ERROR_MESSAGE") orelse defaultFauxErrorMessage(
                    parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse .stop,
                ),
            }) },
        });
    } else {
        const final_stop_reason = parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse
            return error.InvalidFauxStopReason;
        try registration.setResponses(&[_]faux.FauxResponseStep{
            .{ .message = faux.fauxAssistantMessage(owned_messages[0].blocks, .{
                .stop_reason = .tool_use,
            }) },
            .{ .message = faux.fauxAssistantMessage(owned_messages[1].blocks, .{
                .stop_reason = final_stop_reason,
                .error_message = env_map.get("PI_FAUX_ERROR_MESSAGE") orelse defaultFauxErrorMessage(final_stop_reason),
            }) },
        });
    }

    var owned_model = try ai.model_registry.cloneOwnedModel(allocator, registration.getModel());
    errdefer ai.model_registry.deinitOwnedModel(allocator, &owned_model);

    return .{
        .model = owned_model,
        .api_key = null,
        .auth_status = .local,
        .faux_registration = registration,
        .owned_faux_messages = owned_messages,
    };
}

fn buildOwnedFauxMessages(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
) (ResolveProviderError || std.mem.Allocator.Error)![]OwnedFauxMessage {
    const thinking = env_map.get("PI_FAUX_THINKING");
    if (env_map.get("PI_FAUX_TOOL_NAME")) |tool_name| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, env_map.get("PI_FAUX_TOOL_ARGS_JSON") orelse "{}", .{}) catch
            return error.InvalidFauxToolArguments;
        defer parsed.deinit();

        const first_block_count: usize = if (thinking != null) 2 else 1;
        const first_blocks = try allocator.alloc(faux.FauxContentBlock, first_block_count);
        var first_index: usize = 0;
        if (thinking) |thinking_text| {
            first_blocks[first_index] = faux.fauxThinking(thinking_text);
            first_index += 1;
        }
        const tool_args = try common.cloneJsonValue(allocator, parsed.value);
        defer common.deinitJsonValue(allocator, tool_args);
        first_blocks[first_index] = faux.fauxToolCall(allocator, tool_name, tool_args, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        const second_blocks = try allocator.alloc(faux.FauxContentBlock, 1);
        second_blocks[0] = faux.fauxText(env_map.get("PI_FAUX_TOOL_FINAL_RESPONSE") orelse "Tool execution complete");

        const messages = try allocator.alloc(OwnedFauxMessage, 2);
        messages[0] = .{ .blocks = first_blocks };
        messages[1] = .{ .blocks = second_blocks };
        return messages;
    }

    const block_count: usize = if (thinking != null) 2 else 1;
    const blocks = try allocator.alloc(faux.FauxContentBlock, block_count);
    var index: usize = 0;
    if (thinking) |thinking_text| {
        blocks[index] = faux.fauxThinking(thinking_text);
        index += 1;
    }
    blocks[index] = faux.fauxText(env_map.get("PI_FAUX_RESPONSE") orelse "faux response");

    const messages = try allocator.alloc(OwnedFauxMessage, 1);
    messages[0] = .{ .blocks = blocks };
    return messages;
}

fn parseFauxStopReason(value: []const u8) ?ai.StopReason {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, value, "error")) return .error_reason;
    if (std.mem.eql(u8, value, "error_reason")) return .error_reason;
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return null;
}

fn defaultFauxErrorMessage(stop_reason: ai.StopReason) ?[]const u8 {
    return switch (stop_reason) {
        .stop, .length, .tool_use => null,
        .error_reason => "Faux response failed",
        .aborted => "Request was aborted",
    };
}

fn fallbackModel(descriptor: ai.model_registry.ProviderConfig, model_id: []const u8) ai.Model {
    return .{
        .id = model_id,
        .name = model_id,
        .api = descriptor.api,
        .provider = descriptor.provider,
        .base_url = descriptor.base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
}

fn hasProviderCredentials(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    configured_credentials: ConfiguredCredentials,
) !bool {
    return (try resolveAvailableProviderAuthStatus(allocator, env_map, provider, configured_credentials)) != .missing;
}

fn preferredInitialDefaultProvider(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    configured_credentials: ConfiguredCredentials,
) !?ai.model_registry.ProviderConfig {
    const preferred = provider_info.preferInitialFor(provider) orelse return null;
    if (try hasProviderCredentials(allocator, env_map, preferred, configured_credentials)) {
        return ai.model_registry.getProviderConfig(preferred);
    }
    return null;
}

fn isLocalBaseUrl(value: []const u8) bool {
    return string_utils.containsIgnoreCase(value, "localhost") or
        string_utils.containsIgnoreCase(value, "127.0.0.1") or
        string_utils.containsIgnoreCase(value, "0.0.0.0") or
        string_utils.containsIgnoreCase(value, "[::1]");
}

fn resolveAvailableProviderAuthStatus(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    configured_credentials: ConfiguredCredentials,
) !ProviderAuthStatus {
    if (shouldForceFauxProvider(env_map, provider)) return .local;
    if (configured_credentials.lookup(provider) != null) return .stored;
    if (!std.mem.eql(u8, provider, "faux")) {
        if (ai.model_registry.getProviderConfig(provider)) |descriptor| {
            if (isLocalBaseUrl(descriptor.base_url)) return .local;
        }
    }

    const api_key = try ai.env_api_keys.getEnvApiKeyFromMap(allocator, env_map, provider);
    defer if (api_key) |value| allocator.free(value);
    if (api_key != null) return .environment;
    return .missing;
}

const MISSING_API_KEY_FALLBACK: []const u8 =
    "Provider credentials required.\nPass --api-key, run /login <provider>, or configure the provider environment variables.";

fn missingApiKeyMessage(provider: []const u8) []const u8 {
    return provider_info.missingApiKeyMessageFor(provider) orelse MISSING_API_KEY_FALLBACK;
}

test "resolveProviderConfig uses canonical defaults from model registry" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("OPENAI_API_KEY", "openai-key");

    var resolved = try resolveProviderConfig(allocator, std.testing.io, &env_map, "openai", null, null, null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("openai-key", resolved.api_key.?);
    try std.testing.expectEqualStrings("gpt-5.4", resolved.model.id);
    try std.testing.expectEqualStrings("GPT-5.4", resolved.model.name);
    try std.testing.expectEqualStrings("openai-responses", resolved.model.api);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", resolved.model.base_url);
    try std.testing.expectEqual(@as(u32, 272000), resolved.model.context_window);
    try std.testing.expectEqual(@as(u32, 128000), resolved.model.max_tokens);
    try std.testing.expectEqual(@as(usize, 2), resolved.model.input_types.len);
    try std.testing.expectEqualStrings("image", resolved.model.input_types[1]);
}

test "resolveProviderConfig owns model strings across registry reload" {
    const allocator = std.testing.allocator;
    defer ai.model_registry.resetForTesting();

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("OPENAI_API_KEY", "openai-key");

    const registry_model = ai.model_registry.find("openai", "gpt-5.4").?;
    var resolved = try resolveProviderConfig(allocator, std.testing.io, &env_map, "openai", null, null, null);
    defer resolved.deinit(allocator);

    try std.testing.expect(registry_model.id.ptr != resolved.model.id.ptr);
    try std.testing.expect(registry_model.name.ptr != resolved.model.name.ptr);
    try std.testing.expect(registry_model.api.ptr != resolved.model.api.ptr);
    try std.testing.expect(registry_model.provider.ptr != resolved.model.provider.ptr);
    try std.testing.expect(registry_model.base_url.ptr != resolved.model.base_url.ptr);
    try std.testing.expect(registry_model.input_types.ptr != resolved.model.input_types.ptr);
    try std.testing.expect(registry_model.input_types[0].ptr != resolved.model.input_types[0].ptr);

    ai.model_registry.clearDefault();

    try std.testing.expectEqualStrings("openai", resolved.model.provider);
    try std.testing.expectEqualStrings("gpt-5.4", resolved.model.id);
    try std.testing.expectEqualStrings("OpenAI", providerDisplayName(resolved.model.provider));
}

test "resolveProviderConfig keeps registry-backed custom provider safe after clear" {
    const allocator = std.testing.allocator;
    defer ai.model_registry.resetForTesting();

    try ai.model_registry.registerProvider(.{
        .provider = "local-registry-backed",
        .api = "openai-completions",
        .base_url = "http://localhost:4321/v1",
        .default_model_id = "local-registry-model",
    });
    try ai.model_registry.registerModel(.{
        .id = "local-registry-model",
        .name = "Local Registry Model",
        .api = "openai-completions",
        .provider = "local-registry-backed",
        .base_url = "http://localhost:4321/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 4096,
        .max_tokens = 1024,
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var resolved = try resolveProviderConfig(allocator, std.testing.io, &env_map, "local-registry-backed", null, null, null);
    defer resolved.deinit(allocator);

    ai.model_registry.clearDefault();

    try std.testing.expectEqualStrings("local-registry-backed", resolved.model.provider);
    try std.testing.expectEqualStrings("local-registry-model", resolved.model.id);
    try std.testing.expectEqualStrings("Local Registry Model", resolved.model.name);
    try std.testing.expectEqualStrings("local-registry-backed", providerDisplayName(resolved.model.provider));
}

test "resolveProviderConfig supports non-legacy built-in providers" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("MISTRAL_API_KEY", "mistral-key");

    var resolved = try resolveProviderConfig(allocator, std.testing.io, &env_map, "mistral", "devstral-medium-latest", null, null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("mistral-key", resolved.api_key.?);
    try std.testing.expectEqualStrings("devstral-medium-latest", resolved.model.id);
    try std.testing.expectEqualStrings("Devstral 2 (latest)", resolved.model.name);
    try std.testing.expectEqualStrings("mistral-conversations", resolved.model.api);
    try std.testing.expectEqualStrings("mistral", resolved.model.provider);
}

test "resolveProviderConfig accepts provider catalog parity providers" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("MOONSHOT_API_KEY", "moonshot-key");
    try env_map.put("KIMI_API_KEY", "kimi-key");
    try env_map.put("DEEPSEEK_API_KEY", "deepseek-key");
    try env_map.put("ZAI_API_KEY", "zai-key");
    try env_map.put("CLOUDFLARE_API_KEY", "cloudflare-key");
    try env_map.put("TOGETHER_API_KEY", "together-key");
    try env_map.put("XIAOMI_API_KEY", "xiaomi-key");
    try env_map.put("XIAOMI_TOKEN_PLAN_CN_API_KEY", "xiaomi-cn-key");
    try env_map.put("XIAOMI_TOKEN_PLAN_AMS_API_KEY", "xiaomi-ams-key");
    try env_map.put("XIAOMI_TOKEN_PLAN_SGP_API_KEY", "xiaomi-sgp-key");

    const cases = [_]struct {
        provider: []const u8,
        expected_key: []const u8,
        model_id: []const u8,
        api: []const u8,
        base_url: []const u8,
        display_name: []const u8,
    }{
        .{ .provider = "moonshotai", .expected_key = "moonshot-key", .model_id = "kimi-k2.6", .api = "openai-completions", .base_url = "https://api.moonshot.ai/v1", .display_name = "Moonshot AI" },
        .{ .provider = "moonshotai-cn", .expected_key = "moonshot-key", .model_id = "kimi-k2.6", .api = "openai-completions", .base_url = "https://api.moonshot.cn/v1", .display_name = "Moonshot AI (China)" },
        .{ .provider = "kimi-code-openai", .expected_key = "kimi-key", .model_id = "kimi-for-coding", .api = "openai-completions", .base_url = "https://api.kimi.com/coding/v1", .display_name = "Kimi Code (OpenAI Compatible)" },
        .{ .provider = "deepseek", .expected_key = "deepseek-key", .model_id = "deepseek-v4-pro", .api = "openai-completions", .base_url = "https://api.deepseek.com", .display_name = "DeepSeek" },
        .{ .provider = "zai", .expected_key = "zai-key", .model_id = "glm-4.7", .api = "openai-completions", .base_url = "https://open.bigmodel.cn/api/coding/paas/v4", .display_name = "ZAI" },
        .{ .provider = "cloudflare-workers-ai", .expected_key = "cloudflare-key", .model_id = "@cf/moonshotai/kimi-k2.6", .api = "openai-completions", .base_url = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1", .display_name = "Cloudflare Workers AI" },
        .{ .provider = "cloudflare-ai-gateway", .expected_key = "cloudflare-key", .model_id = "workers-ai/@cf/moonshotai/kimi-k2.6", .api = "openai-completions", .base_url = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/compat", .display_name = "Cloudflare AI Gateway" },
        .{ .provider = "together", .expected_key = "together-key", .model_id = "moonshotai/Kimi-K2.6", .api = "openai-completions", .base_url = "https://api.together.ai/v1", .display_name = "Together AI" },
        .{ .provider = "xiaomi", .expected_key = "xiaomi-key", .model_id = "mimo-v2.5-pro", .api = "anthropic-messages", .base_url = "https://api.xiaomimimo.com/anthropic", .display_name = "Xiaomi MiMo" },
        .{ .provider = "xiaomi-token-plan-cn", .expected_key = "xiaomi-cn-key", .model_id = "mimo-v2.5-pro", .api = "anthropic-messages", .base_url = "https://token-plan-cn.xiaomimimo.com/anthropic", .display_name = "Xiaomi MiMo Token Plan (China)" },
        .{ .provider = "xiaomi-token-plan-ams", .expected_key = "xiaomi-ams-key", .model_id = "mimo-v2.5-pro", .api = "anthropic-messages", .base_url = "https://token-plan-ams.xiaomimimo.com/anthropic", .display_name = "Xiaomi MiMo Token Plan (Amsterdam)" },
        .{ .provider = "xiaomi-token-plan-sgp", .expected_key = "xiaomi-sgp-key", .model_id = "mimo-v2.5-pro", .api = "anthropic-messages", .base_url = "https://token-plan-sgp.xiaomimimo.com/anthropic", .display_name = "Xiaomi MiMo Token Plan (Singapore)" },
    };

    for (cases) |case| {
        var resolved = try resolveProviderConfig(allocator, std.testing.io, &env_map, case.provider, null, null, null);
        defer resolved.deinit(allocator);

        try std.testing.expectEqualStrings(case.expected_key, resolved.api_key.?);
        try std.testing.expectEqual(ProviderAuthStatus.environment, resolved.auth_status);
        try std.testing.expectEqualStrings(case.provider, resolved.model.provider);
        try std.testing.expectEqualStrings(case.model_id, resolved.model.id);
        try std.testing.expectEqualStrings(case.api, resolved.model.api);
        try std.testing.expectEqualStrings(case.base_url, resolved.model.base_url);
        try std.testing.expectEqualStrings(case.display_name, providerDisplayName(case.provider));
    }
}

test "resolveProviderConfig uses configured api key when env is missing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var resolved = try resolveProviderConfig(allocator, std.testing.io, &env_map, "openai", null, null, "configured-openai-key");
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("configured-openai-key", resolved.api_key.?);
    try std.testing.expectEqual(ProviderAuthStatus.stored, resolved.auth_status);
    try std.testing.expectEqualStrings("gpt-5.4", resolved.model.id);

    var xai_oauth = try resolveProviderConfig(allocator, std.testing.io, &env_map, "xai-oauth", null, null, "stored-xai-oauth-token");
    defer xai_oauth.deinit(allocator);

    try std.testing.expectEqualStrings("stored-xai-oauth-token", xai_oauth.api_key.?);
    try std.testing.expectEqual(ProviderAuthStatus.stored, xai_oauth.auth_status);
    try std.testing.expectEqualStrings("grok-4.3", xai_oauth.model.id);
    try std.testing.expectEqualStrings("openai-responses", xai_oauth.model.api);
}

test "resolveProviderConfigAllowMissingCredentials returns safe missing auth state" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var resolved = try resolveProviderConfigAllowMissingCredentials(allocator, std.testing.io, &env_map, "openai", null, null, null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), resolved.api_key);
    try std.testing.expectEqual(ProviderAuthStatus.missing, resolved.auth_status);
    try std.testing.expectEqualStrings("openai", resolved.model.provider);
    try std.testing.expectEqualStrings("gpt-5.4", resolved.model.id);
}

test "resolveProviderConfig prefers runtime override over stored and environment credentials" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "env-openai-key");

    var resolved = try resolveProviderConfig(
        allocator,
        std.testing.io,
        &env_map,
        "openai",
        null,
        "runtime-openai-key",
        "stored-openai-key",
    );
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(ProviderAuthStatus.runtime, resolved.auth_status);
    try std.testing.expectEqualStrings("runtime-openai-key", resolved.api_key.?);
    try std.testing.expectEqualStrings("gpt-5.4", resolved.model.id);
}

test "resolveProviderConfig can force faux responses for built-in providers" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("PI_FAUX_FORCE", "1");
    try env_map.put("PI_FAUX_RESPONSE", "forced faux response");

    var resolved = try resolveProviderConfig(allocator, std.testing.io, &env_map, "openai", null, null, null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), resolved.api_key);
    try std.testing.expect(resolved.faux_registration != null);
    try std.testing.expectEqualStrings("openai", resolved.model.provider);
    try std.testing.expectEqualStrings("openai-responses", resolved.model.api);
    try std.testing.expectEqualStrings("gpt-5.4", resolved.model.id);
}

test "resolveProviderConfig applies faux context window overrides" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("PI_FAUX_FORCE", "1");
    try env_map.put("PI_FAUX_CONTEXT_WINDOW", "48");
    try env_map.put("PI_FAUX_RESPONSE", "forced faux response");

    var resolved = try resolveProviderConfig(allocator, std.testing.io, &env_map, "anthropic", null, null, null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("anthropic", resolved.model.provider);
    try std.testing.expectEqualStrings("claude-opus-4-7", resolved.model.id);
    try std.testing.expectEqual(@as(u32, 48), resolved.model.context_window);
}

test "listAvailableModels enumerates all built-in providers" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const current_model = ai.model_registry.find("faux", "faux-1").?;
    const models = try listAvailableModels(allocator, &env_map, current_model, .{});
    defer allocator.free(models);

    var found_openai = false;
    var found_anthropic = false;
    var found_google = false;
    var found_github_copilot = false;
    var found_groq = false;
    var found_cerebras = false;
    var found_xai = false;
    var found_xai_oauth = false;
    var found_fireworks = false;
    var found_huggingface = false;
    var found_openrouter = false;
    var found_faux = false;
    var openai_count: usize = 0;

    for (models) |entry| {
        if (std.mem.eql(u8, entry.provider, "openai")) {
            found_openai = true;
            openai_count += 1;
            if (std.mem.eql(u8, entry.model_id, "gpt-5.4")) {
                try std.testing.expectEqualStrings("GPT-5.4", entry.display_name);
                try std.testing.expect(!entry.available);
                try std.testing.expect(entry.supports_images);
            }
        } else if (std.mem.eql(u8, entry.provider, "anthropic")) {
            found_anthropic = true;
            if (std.mem.eql(u8, entry.model_id, "claude-opus-4-7")) {
                try std.testing.expect(entry.reasoning);
            }
        } else if (std.mem.eql(u8, entry.provider, "google")) {
            found_google = true;
        } else if (std.mem.eql(u8, entry.provider, "github-copilot")) {
            found_github_copilot = true;
            if (std.mem.eql(u8, entry.model_id, "gpt-5.4")) {
                try std.testing.expect(entry.supports_images);
                try std.testing.expect(entry.reasoning);
            }
        } else if (std.mem.eql(u8, entry.provider, "groq")) {
            found_groq = true;
        } else if (std.mem.eql(u8, entry.provider, "cerebras")) {
            found_cerebras = true;
        } else if (std.mem.eql(u8, entry.provider, "xai")) {
            found_xai = true;
        } else if (std.mem.eql(u8, entry.provider, "xai-oauth")) {
            found_xai_oauth = true;
            if (std.mem.eql(u8, entry.model_id, "grok-4.3")) {
                try std.testing.expect(!entry.available);
                try std.testing.expect(entry.supports_images);
                try std.testing.expect(entry.reasoning);
            }
        } else if (std.mem.eql(u8, entry.provider, "fireworks")) {
            found_fireworks = true;
        } else if (std.mem.eql(u8, entry.provider, "huggingface")) {
            found_huggingface = true;
        } else if (std.mem.eql(u8, entry.provider, "openrouter")) {
            found_openrouter = true;
            if (std.mem.eql(u8, entry.model_id, "qwen/qwen3-coder:exacto")) {
                try std.testing.expect(!entry.supports_images);
            }
        } else if (std.mem.eql(u8, entry.provider, "faux")) {
            found_faux = true;
            try std.testing.expect(entry.available);
        }
    }

    try std.testing.expect(found_openai);
    try std.testing.expect(found_anthropic);
    try std.testing.expect(found_google);
    try std.testing.expect(found_github_copilot);
    try std.testing.expect(found_groq);
    try std.testing.expect(found_cerebras);
    try std.testing.expect(found_xai);
    try std.testing.expect(found_xai_oauth);
    try std.testing.expect(found_fireworks);
    try std.testing.expect(found_huggingface);
    try std.testing.expect(found_openrouter);
    try std.testing.expect(found_faux);
    try std.testing.expect(openai_count >= 3);
    try std.testing.expect(models.len >= 20);
}

test "listAvailableModels surfaces provider catalog parity auth states" {
    const allocator = std.testing.allocator;

    const cases = [_]struct {
        provider: []const u8,
        model_id: []const u8,
        env_var: []const u8,
    }{
        .{ .provider = "moonshotai", .model_id = "kimi-k2.6", .env_var = "MOONSHOT_API_KEY" },
        .{ .provider = "moonshotai-cn", .model_id = "kimi-k2.6", .env_var = "MOONSHOT_API_KEY" },
        .{ .provider = "kimi-code-openai", .model_id = "kimi-for-coding", .env_var = "KIMI_API_KEY" },
        .{ .provider = "deepseek", .model_id = "deepseek-v4-pro", .env_var = "DEEPSEEK_API_KEY" },
        .{ .provider = "zai", .model_id = "glm-4.7", .env_var = "ZAI_API_KEY" },
        .{ .provider = "cloudflare-workers-ai", .model_id = "@cf/moonshotai/kimi-k2.6", .env_var = "CLOUDFLARE_API_KEY" },
        .{ .provider = "cloudflare-ai-gateway", .model_id = "workers-ai/@cf/moonshotai/kimi-k2.6", .env_var = "CLOUDFLARE_API_KEY" },
        .{ .provider = "together", .model_id = "moonshotai/Kimi-K2.6", .env_var = "TOGETHER_API_KEY" },
        .{ .provider = "xiaomi", .model_id = "mimo-v2.5-pro", .env_var = "XIAOMI_API_KEY" },
        .{ .provider = "xiaomi-token-plan-cn", .model_id = "mimo-v2.5-pro", .env_var = "XIAOMI_TOKEN_PLAN_CN_API_KEY" },
        .{ .provider = "xiaomi-token-plan-ams", .model_id = "mimo-v2.5-pro", .env_var = "XIAOMI_TOKEN_PLAN_AMS_API_KEY" },
        .{ .provider = "xiaomi-token-plan-sgp", .model_id = "mimo-v2.5-pro", .env_var = "XIAOMI_TOKEN_PLAN_SGP_API_KEY" },
    };

    var env_map_all = std.process.Environ.Map.init(allocator);
    defer env_map_all.deinit();
    for (cases) |case| try env_map_all.put(case.env_var, "env-key");

    const env_models = try listAvailableModels(allocator, &env_map_all, null, .{});
    defer allocator.free(env_models);
    for (cases) |case| {
        try expectAvailableModel(env_models, case.provider, case.model_id, .environment, true);
    }

    var env_map_empty = std.process.Environ.Map.init(allocator);
    defer env_map_empty.deinit();

    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    defer provider_api_keys.deinit();
    for (cases) |case| try provider_api_keys.put(case.provider, "stored-key");

    const stored_models = try listAvailableModels(allocator, &env_map_empty, null, .{ .provider_api_keys = &provider_api_keys });
    defer allocator.free(stored_models);
    for (cases) |case| {
        try expectAvailableModel(stored_models, case.provider, case.model_id, .stored, true);
    }

    const missing_models = try listAvailableModels(allocator, &env_map_empty, null, .{});
    defer allocator.free(missing_models);
    for (cases) |case| {
        try expectAvailableModel(missing_models, case.provider, case.model_id, .missing, false);
    }
}

test "listAvailableModels treats configured credentials as available" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var auth_tokens = std.StringHashMap([]const u8).init(allocator);
    defer auth_tokens.deinit();
    try auth_tokens.put("kimi", "stored-kimi-key");

    const models = try listAvailableModels(allocator, &env_map, null, .{ .auth_tokens = &auth_tokens });
    defer allocator.free(models);

    var saw_kimi = false;
    for (models) |entry| {
        if (std.mem.eql(u8, entry.provider, "kimi") and std.mem.eql(u8, entry.model_id, "kimi-k2.6")) {
            saw_kimi = true;
            try std.testing.expect(entry.available);
        }
    }

    try std.testing.expect(saw_kimi);
}

test "findInitialDefaultModel uses configured kimi credentials" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var auth_tokens = std.StringHashMap([]const u8).init(allocator);
    defer auth_tokens.deinit();
    try auth_tokens.put("kimi", "stored-kimi-key");

    const model = (try findInitialDefaultModel(allocator, &env_map, .{ .auth_tokens = &auth_tokens })).?;
    try std.testing.expectEqualStrings("kimi", model.provider);
    try std.testing.expectEqualStrings("kimi-k2.6", model.id);
}

test "KIMI_API_KEY configures Kimi Code providers without legacy Kimi" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("KIMI_API_KEY", "kimi-key");

    const models = try listAvailableModels(allocator, &env_map, null, .{});
    defer allocator.free(models);

    var saw_kimi = false;
    var saw_kimi_coding = false;
    var saw_kimi_code_openai = false;
    for (models) |entry| {
        if (std.mem.eql(u8, entry.provider, "kimi") and std.mem.eql(u8, entry.model_id, "kimi-k2.6")) {
            saw_kimi = true;
            try std.testing.expect(!entry.available);
        }
        if (std.mem.eql(u8, entry.provider, "kimi-coding") and std.mem.eql(u8, entry.model_id, "kimi-for-coding")) {
            saw_kimi_coding = true;
            try std.testing.expect(entry.available);
        }
        if (std.mem.eql(u8, entry.provider, "kimi-code-openai") and std.mem.eql(u8, entry.model_id, "kimi-for-coding")) {
            saw_kimi_code_openai = true;
            try std.testing.expect(entry.available);
        }
    }

    try std.testing.expect(saw_kimi);
    try std.testing.expect(saw_kimi_coding);
    try std.testing.expect(saw_kimi_code_openai);

    const configured = try filterConfiguredModels(allocator, models);
    defer allocator.free(configured);
    try std.testing.expectEqual(@as(usize, 2), configured.len);
    var configured_kimi_coding = false;
    var configured_kimi_code_openai = false;
    for (configured) |entry| {
        if (std.mem.eql(u8, entry.provider, "kimi-coding")) {
            configured_kimi_coding = true;
            try std.testing.expectEqualStrings("kimi-for-coding", entry.model_id);
        }
        if (std.mem.eql(u8, entry.provider, "kimi-code-openai")) {
            configured_kimi_code_openai = true;
            try std.testing.expectEqualStrings("kimi-for-coding", entry.model_id);
        }
    }
    try std.testing.expect(configured_kimi_coding);
    try std.testing.expect(configured_kimi_code_openai);

    const model = (try findInitialDefaultModel(allocator, &env_map, .{})).?;
    try std.testing.expectEqualStrings("kimi-coding", model.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", model.id);
}

test "local custom providers do not require api keys" {
    const allocator = std.testing.allocator;
    defer ai.model_registry.resetForTesting();

    try ai.model_registry.registerProvider(.{
        .provider = "local-noauth",
        .api = "openai-completions",
        .base_url = "http://localhost:1234/v1",
        .default_model_id = "local-model",
    });
    try ai.model_registry.registerModel(.{
        .id = "local-model",
        .name = "Local Model",
        .api = "openai-completions",
        .provider = "local-noauth",
        .base_url = "http://localhost:1234/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 4096,
        .max_tokens = 1024,
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const models = try listAvailableModels(allocator, &env_map, null, .{});
    defer allocator.free(models);

    var saw_local = false;
    for (models) |entry| {
        if (std.mem.eql(u8, entry.provider, "local-noauth") and std.mem.eql(u8, entry.model_id, "local-model")) {
            saw_local = true;
            try std.testing.expect(entry.available);
        }
    }
    try std.testing.expect(saw_local);

    var resolved = try resolveProviderConfig(allocator, std.testing.io, &env_map, "local-noauth", null, null, null);
    defer resolved.deinit(allocator);
    try std.testing.expectEqualStrings("local-model", resolved.model.id);
    try std.testing.expect(resolved.api_key == null);
}

test "blank configured credentials do not make models selectable" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var auth_tokens = std.StringHashMap([]const u8).init(allocator);
    defer auth_tokens.deinit();
    try auth_tokens.put("openai", "");

    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    defer provider_api_keys.deinit();
    try provider_api_keys.put("anthropic", "   ");

    const models = try listAvailableModels(allocator, &env_map, null, .{
        .auth_tokens = &auth_tokens,
        .provider_api_keys = &provider_api_keys,
    });
    defer allocator.free(models);

    const configured = try filterConfiguredModels(allocator, models);
    defer allocator.free(configured);

    for (configured) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.provider, "openai"));
        try std.testing.expect(!std.mem.eql(u8, entry.provider, "anthropic"));
        try std.testing.expect(!std.mem.eql(u8, entry.provider, "faux"));
    }
    try std.testing.expectEqual(@as(usize, 0), configured.len);
}

test "resolveProviderErrorMessage includes provider-specific env and login guidance" {
    const openai = resolveProviderErrorMessage(error.MissingApiKey, "openai");
    try std.testing.expect(std.mem.indexOf(u8, openai, "OPENAI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, openai, "/login openai") != null);

    const openai_responses = resolveProviderErrorMessage(error.MissingApiKey, "openai-responses");
    try std.testing.expect(std.mem.indexOf(u8, openai_responses, "OpenAI Responses credentials required") != null);
    try std.testing.expect(std.mem.indexOf(u8, openai_responses, "/login openai-responses") != null);

    const opencode_go = resolveProviderErrorMessage(error.MissingApiKey, "opencode-go");
    try std.testing.expect(std.mem.indexOf(u8, opencode_go, "OpenCode Go credentials required") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_go, "/login opencode-go") != null);

    const copilot = resolveProviderErrorMessage(error.MissingApiKey, "github-copilot");
    try std.testing.expect(std.mem.indexOf(u8, copilot, "COPILOT_GITHUB_TOKEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot, "/login github-copilot") != null);

    const moonshot = resolveProviderErrorMessage(error.MissingApiKey, "moonshotai");
    try std.testing.expect(std.mem.indexOf(u8, moonshot, "MOONSHOT_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, moonshot, "/login moonshotai") != null);

    const kimi_code_openai = resolveProviderErrorMessage(error.MissingApiKey, "kimi-code-openai");
    try std.testing.expect(std.mem.indexOf(u8, kimi_code_openai, "KIMI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, kimi_code_openai, "/login kimi-code-openai") != null);

    const deepseek = resolveProviderErrorMessage(error.MissingApiKey, "deepseek");
    try std.testing.expect(std.mem.indexOf(u8, deepseek, "DEEPSEEK_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, deepseek, "/login deepseek") != null);

    const zai = resolveProviderErrorMessage(error.MissingApiKey, "zai");
    try std.testing.expect(std.mem.indexOf(u8, zai, "ZAI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, zai, "/login zai") != null);

    const cloudflare_gateway = resolveProviderErrorMessage(error.MissingApiKey, "cloudflare-ai-gateway");
    try std.testing.expect(std.mem.indexOf(u8, cloudflare_gateway, "CLOUDFLARE_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, cloudflare_gateway, "/login cloudflare-ai-gateway") != null);

    const together = resolveProviderErrorMessage(error.MissingApiKey, "together");
    try std.testing.expect(std.mem.indexOf(u8, together, "TOGETHER_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, together, "/login together") != null);

    const xiaomi_sgp = resolveProviderErrorMessage(error.MissingApiKey, "xiaomi-token-plan-sgp");
    try std.testing.expect(std.mem.indexOf(u8, xiaomi_sgp, "XIAOMI_TOKEN_PLAN_SGP_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, xiaomi_sgp, "/login xiaomi-token-plan-sgp") != null);

    const unsupported = resolveProviderErrorMessage(error.UnknownProvider, "unknown");
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "--list-models") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "custom provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "moonshotai") == null);
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "xiaomi-token-plan-sgp") == null);
}

test "filterAvailableModels supports scoped glob fuzzy and thinking suffix patterns" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const available = try listAvailableModels(allocator, &env_map, ai.model_registry.find("faux", "faux-1").?, .{});
    defer allocator.free(available);

    const anthropic_only = try filterAvailableModels(allocator, available, &.{"anthropic/sonnet"});
    defer allocator.free(anthropic_only);
    try std.testing.expect(anthropic_only.len > 0);
    for (anthropic_only) |entry| {
        try std.testing.expectEqualStrings("anthropic", entry.provider);
        try std.testing.expect(string_utils.containsIgnoreCase(entry.model_id, "sonnet"));
    }

    const globbed = try filterAvailableModels(allocator, available, &.{"openrouter/*kimi-k2.6"});
    defer allocator.free(globbed);
    try std.testing.expectEqual(@as(usize, 1), globbed.len);
    try std.testing.expectEqualStrings("openrouter", globbed[0].provider);
    try std.testing.expectEqualStrings("moonshotai/kimi-k2.6", globbed[0].model_id);

    const with_thinking = try filterAvailableModels(allocator, available, &.{"claude-sonnet:high"});
    defer allocator.free(with_thinking);
    try std.testing.expect(with_thinking.len > 0);
}

fn expectAvailableModel(
    models: []const AvailableModel,
    provider: []const u8,
    model_id: []const u8,
    auth_status: ProviderAuthStatus,
    available: bool,
) !void {
    for (models) |entry| {
        if (std.mem.eql(u8, entry.provider, provider) and std.mem.eql(u8, entry.model_id, model_id)) {
            try std.testing.expectEqual(auth_status, entry.auth_status);
            try std.testing.expectEqual(available, entry.available);
            return;
        }
    }
    return error.TestExpectedEqual;
}
