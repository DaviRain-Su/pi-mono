const std = @import("std");
const model_registry = @import("model_registry.zig");
const http_client = @import("http_client.zig");
const string_utils = @import("shared/string_utils.zig");
const types = @import("types.zig");

const DEFAULT_CONTEXT_WINDOW: u32 = 128000;
const DEFAULT_MAX_TOKENS: u32 = 16384;
const TEXT_INPUTS = [_][]const u8{"text"};
const TEXT_AND_IMAGE_INPUTS = [_][]const u8{ "text", "image" };
/// Maximum JSON response bytes accepted by model discovery HTTP fetches.
/// Public/provider model catalogs are normally small; using the shared 32 MiB
/// one-shot HTTP cap keeps large legitimate local catalogs working while
/// preventing unbounded JSON allocation before parsing.
const max_model_discovery_json_bytes: usize = http_client.max_response_body_bytes;

pub const DiscoveryKind = enum {
    auto,
    openai,
    ollama,
    pi,
};

pub const DiscoveryOptions = struct {
    kind: DiscoveryKind = .auto,
    models_url: ?[]const u8 = null,
    loaded_models_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    timeout_ms: u32 = 0,
    aborted: ?*const std.atomic.Value(bool) = null,
};

pub const DiscoverySummary = struct {
    registered_models: usize = 0,
    loaded_models: usize = 0,
};

const ParsedInputTypes = struct {
    items: []const []const u8,
    owned: bool = false,

    fn deinit(self: ParsedInputTypes, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.items);
    }
};

pub fn discoverAndRegister(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *model_registry.ModelRegistry,
    provider: model_registry.ProviderConfig,
    options: DiscoveryOptions,
) !DiscoverySummary {
    const kind = resolveKind(provider.base_url, options.kind);
    return switch (kind) {
        .auto => unreachable,
        .openai, .pi => discoverOpenAICompatible(allocator, io, registry, provider, options, kind),
        .ollama => discoverOllama(allocator, io, registry, provider, options),
    };
}

pub fn registerModelsFromJson(
    allocator: std.mem.Allocator,
    registry: *model_registry.ModelRegistry,
    provider: model_registry.ProviderConfig,
    root: std.json.Value,
) !usize {
    const model_array = findModelArray(root) orelse return 0;
    var count: usize = 0;

    for (model_array.items) |item| {
        switch (item) {
            .object => |object| {
                if (try registerModelObject(allocator, registry, provider, object, loadedListContains(root, getString(object, &.{ "id", "model" }) orelse ""), null)) {
                    count += 1;
                }
            },
            .string => |id| {
                try registerMinimalModel(registry, provider, id, id, false);
                count += 1;
            },
            else => {},
        }
    }

    return count;
}

pub fn registerLoadedModelsFromJson(
    allocator: std.mem.Allocator,
    registry: *model_registry.ModelRegistry,
    provider: model_registry.ProviderConfig,
    root: std.json.Value,
) !usize {
    const loaded_array = findLoadedArray(root) orelse return 0;
    registry.clearLoadedForProvider(provider.provider);

    var count: usize = 0;
    for (loaded_array.items) |item| {
        switch (item) {
            .object => |object| {
                if (try registerModelObject(allocator, registry, provider, object, true, true)) {
                    count += 1;
                }
            },
            .string => |id| {
                if (!registry.setModelLoaded(provider.provider, id, true)) {
                    try registerMinimalModel(registry, provider, id, id, true);
                }
                count += 1;
            },
            else => {},
        }
    }
    return count;
}

fn discoverOpenAICompatible(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *model_registry.ModelRegistry,
    provider: model_registry.ProviderConfig,
    options: DiscoveryOptions,
    kind: DiscoveryKind,
) !DiscoverySummary {
    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const owned_models_url = if (options.models_url) |url|
        try allocator.dupe(u8, url)
    else
        try joinUrl(allocator, provider.base_url, "models");
    defer allocator.free(owned_models_url);

    var models_json = try requestJson(allocator, &client, .GET, owned_models_url, options.api_key, null, options.timeout_ms, options.aborted);
    defer models_json.deinit();

    var summary = DiscoverySummary{};
    summary.registered_models = try registerModelsFromJson(allocator, registry, provider, models_json.value);

    if (options.loaded_models_url != null or kind == .pi) {
        const owned_loaded_url = if (options.loaded_models_url) |url|
            try allocator.dupe(u8, url)
        else
            try joinUrl(allocator, provider.base_url, "loaded_models");
        defer allocator.free(owned_loaded_url);

        var loaded_json = requestJson(allocator, &client, .GET, owned_loaded_url, options.api_key, null, options.timeout_ms, options.aborted) catch return summary;
        defer loaded_json.deinit();
        summary.loaded_models = try registerLoadedModelsFromJson(allocator, registry, provider, loaded_json.value);
    }

    return summary;
}

fn discoverOllama(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *model_registry.ModelRegistry,
    provider: model_registry.ProviderConfig,
    options: DiscoveryOptions,
) !DiscoverySummary {
    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const root_url = try stripOpenAISuffix(allocator, provider.base_url);
    defer allocator.free(root_url);

    const owned_models_url = if (options.models_url) |url|
        try allocator.dupe(u8, url)
    else
        try joinUrl(allocator, root_url, "api/tags");
    defer allocator.free(owned_models_url);

    var tags_json = try requestJson(allocator, &client, .GET, owned_models_url, options.api_key, null, options.timeout_ms, options.aborted);
    defer tags_json.deinit();

    const owned_loaded_url = if (options.loaded_models_url) |url|
        try allocator.dupe(u8, url)
    else
        try joinUrl(allocator, root_url, "api/ps");
    defer allocator.free(owned_loaded_url);

    var maybe_loaded_json = requestJson(allocator, &client, .GET, owned_loaded_url, options.api_key, null, options.timeout_ms, options.aborted) catch null;
    defer if (maybe_loaded_json) |*loaded_json| loaded_json.deinit();

    var summary = DiscoverySummary{};
    const tags_array = findOllamaModelArray(tags_json.value) orelse return summary;
    for (tags_array.items) |item| {
        if (item != .object) continue;
        const tag_object = item.object;
        const id = getString(tag_object, &.{ "model", "name", "id" }) orelse continue;
        const name = getString(tag_object, &.{ "name", "model", "id" }) orelse id;
        const loaded = if (maybe_loaded_json) |loaded_json| loadedEndpointContains(loaded_json.value, id) else false;

        const show_url = try joinUrl(allocator, root_url, "api/show");
        defer allocator.free(show_url);

        var show_json = requestOllamaShow(allocator, &client, show_url, options.api_key, id, options.timeout_ms, options.aborted) catch null;
        if (show_json) |*parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                _ = try registerOllamaShowObject(allocator, registry, provider, id, parsed.value.object, loaded);
            } else {
                try registerMinimalModel(registry, provider, id, name, loaded);
            }
        } else {
            try registerMinimalModel(registry, provider, id, name, loaded);
        }
        summary.registered_models += 1;
    }

    if (maybe_loaded_json) |loaded_json| {
        summary.loaded_models = countLoadedEntries(loaded_json.value);
    }

    return summary;
}

fn requestOllamaShow(
    allocator: std.mem.Allocator,
    client: *http_client.HttpClient,
    url: []const u8,
    api_key: ?[]const u8,
    model_id: []const u8,
    timeout_ms: u32,
    aborted: ?*const std.atomic.Value(bool),
) !std.json.Parsed(std.json.Value) {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer object.deinit(allocator);
    try object.put(allocator, "model", .{ .string = model_id });
    const body = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    defer allocator.free(body);
    return requestJson(allocator, client, .POST, url, api_key, body, timeout_ms, aborted);
}

fn requestJson(
    allocator: std.mem.Allocator,
    client: *http_client.HttpClient,
    method: http_client.HttpMethod,
    url: []const u8,
    api_key: ?[]const u8,
    body: ?[]const u8,
    timeout_ms: u32,
    aborted: ?*const std.atomic.Value(bool),
) !std.json.Parsed(std.json.Value) {
    return requestJsonWithCap(allocator, client, method, url, api_key, body, max_model_discovery_json_bytes, timeout_ms, aborted);
}

fn requestJsonWithCap(
    allocator: std.mem.Allocator,
    client: *http_client.HttpClient,
    method: http_client.HttpMethod,
    url: []const u8,
    api_key: ?[]const u8,
    body: ?[]const u8,
    max_response_body_bytes: usize,
    timeout_ms: u32,
    aborted: ?*const std.atomic.Value(bool),
) !std.json.Parsed(std.json.Value) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("Accept", "application/json");
    if (body != null) try headers.put("Content-Type", "application/json");

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    if (api_key) |key| {
        if (std.mem.trim(u8, key, &std.ascii.whitespace).len > 0) {
            auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
            try headers.put("Authorization", auth_header.?);
        }
    }

    const response = try client.request(.{
        .method = method,
        .url = url,
        .headers = headers,
        .body = body,
        .max_response_body_bytes = max_response_body_bytes,
        .timeout_ms = timeout_ms,
        .aborted = aborted,
    });
    defer response.deinit();

    return std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
}

fn registerModelObject(
    allocator: std.mem.Allocator,
    registry: *model_registry.ModelRegistry,
    provider: model_registry.ProviderConfig,
    object: std.json.ObjectMap,
    fallback_loaded: bool,
    force_loaded: ?bool,
) !bool {
    const id = getString(object, &.{ "id", "model", "name" }) orelse return false;
    const name = getString(object, &.{ "name", "display_name", "displayName", "model", "id" }) orelse id;
    var input_types = try parseInputTypes(allocator, object);
    defer input_types.deinit(allocator);

    const capabilities_present = object.get("capabilities") != null;
    const reasoning = parseBoolAliases(object, &.{ "thinking", "reasoning", "supportsThinking", "supports_thinking" }) orelse
        capabilitiesContain(object, &.{ "thinking", "reasoning" });
    const tool_calling = parseBoolAliases(object, &.{ "toolCalling", "tool_calling", "supportsTools", "supports_tools", "functionCalling", "function_calling", "tools" }) orelse
        if (capabilitiesPresentAndLacksTools(capabilities_present, object)) false else true;
    const loaded = force_loaded orelse (parseBoolAliases(object, &.{"loaded"}) orelse fallback_loaded);

    try registry.registerModel(.{
        .id = id,
        .name = name,
        .api = provider.api,
        .provider = provider.provider,
        .base_url = provider.base_url,
        .reasoning = reasoning,
        .thinking_level_map = parseThinkingLevelMap(object),
        .tool_calling = tool_calling,
        .loaded = loaded,
        .input_types = input_types.items,
        .cost = .{},
        .context_window = parseU32Aliases(object, &.{ "contextWindow", "context_window", "contextLength", "context_length", "maxContextLength", "max_context_length", "max_model_len", "n_ctx", "n_ctx_train" }) orelse DEFAULT_CONTEXT_WINDOW,
        .max_tokens = parseU32Aliases(object, &.{ "maxTokens", "max_tokens", "maxOutputTokens", "max_output_tokens", "maxCompletionTokens", "max_completion_tokens" }) orelse DEFAULT_MAX_TOKENS,
    });
    return true;
}

fn registerOllamaShowObject(
    allocator: std.mem.Allocator,
    registry: *model_registry.ModelRegistry,
    provider: model_registry.ProviderConfig,
    model_id: []const u8,
    object: std.json.ObjectMap,
    loaded: bool,
) !bool {
    const name = getString(object, &.{ "name", "model", "id" }) orelse model_id;
    var input_types = try parseInputTypes(allocator, object);
    defer input_types.deinit(allocator);

    const capabilities_present = object.get("capabilities") != null;
    const reasoning = parseBoolAliases(object, &.{ "thinking", "reasoning", "supportsThinking", "supports_thinking" }) orelse
        capabilitiesContain(object, &.{ "thinking", "reasoning" });
    const tool_calling = parseBoolAliases(object, &.{ "toolCalling", "tool_calling", "supportsTools", "supports_tools", "functionCalling", "function_calling", "tools" }) orelse
        if (capabilitiesPresentAndLacksTools(capabilities_present, object)) false else true;
    const context_window = parseU32Aliases(object, &.{ "contextWindow", "context_window", "contextLength", "context_length", "num_ctx", "n_ctx" }) orelse
        parseOllamaModelInfoContext(object) orelse DEFAULT_CONTEXT_WINDOW;

    try registry.registerModel(.{
        .id = model_id,
        .name = name,
        .api = provider.api,
        .provider = provider.provider,
        .base_url = provider.base_url,
        .reasoning = reasoning,
        .thinking_level_map = parseThinkingLevelMap(object),
        .tool_calling = tool_calling,
        .loaded = loaded,
        .input_types = input_types.items,
        .cost = .{},
        .context_window = context_window,
        .max_tokens = parseU32Aliases(object, &.{ "maxTokens", "max_tokens", "maxOutputTokens", "max_output_tokens" }) orelse DEFAULT_MAX_TOKENS,
    });
    return true;
}

fn registerMinimalModel(
    registry: *model_registry.ModelRegistry,
    provider: model_registry.ProviderConfig,
    id: []const u8,
    name: []const u8,
    loaded: bool,
) !void {
    try registry.registerModel(.{
        .id = id,
        .name = name,
        .api = provider.api,
        .provider = provider.provider,
        .base_url = provider.base_url,
        .reasoning = false,
        .tool_calling = true,
        .loaded = loaded,
        .input_types = TEXT_INPUTS[0..],
        .cost = .{},
        .context_window = DEFAULT_CONTEXT_WINDOW,
        .max_tokens = DEFAULT_MAX_TOKENS,
    });
}

fn parseInputTypes(allocator: std.mem.Allocator, object: std.json.ObjectMap) !ParsedInputTypes {
    for ([_][]const u8{ "input", "inputTypes", "input_types", "inputModalities", "input_modalities", "modalities" }) |key| {
        if (object.get(key)) |value| {
            if (try parseInputTypesValue(allocator, value)) |parsed| return parsed;
        }
    }

    if (capabilitiesContain(object, &.{ "vision", "image", "images" })) {
        return .{ .items = TEXT_AND_IMAGE_INPUTS[0..] };
    }

    return .{ .items = TEXT_INPUTS[0..] };
}

fn parseInputTypesValue(allocator: std.mem.Allocator, value: std.json.Value) !?ParsedInputTypes {
    var has_text = false;
    var has_image = false;

    switch (value) {
        .string => |text| normalizeInputType(text, &has_text, &has_image),
        .array => |array| {
            for (array.items) |item| {
                if (item == .string) normalizeInputType(item.string, &has_text, &has_image);
            }
        },
        else => return null,
    }

    if (!has_text and !has_image) return null;
    if (has_text and has_image) return .{ .items = TEXT_AND_IMAGE_INPUTS[0..] };
    if (has_text) return .{ .items = TEXT_INPUTS[0..] };

    const image_only = try allocator.alloc([]const u8, 1);
    image_only[0] = "image";
    return .{ .items = image_only, .owned = true };
}

fn normalizeInputType(value: []const u8, has_text: *bool, has_image: *bool) void {
    if (std.ascii.eqlIgnoreCase(value, "text") or
        std.ascii.eqlIgnoreCase(value, "language") or
        std.ascii.eqlIgnoreCase(value, "completion"))
    {
        has_text.* = true;
    } else if (std.ascii.eqlIgnoreCase(value, "image") or
        std.ascii.eqlIgnoreCase(value, "images") or
        std.ascii.eqlIgnoreCase(value, "vision"))
    {
        has_text.* = true;
        has_image.* = true;
    }
}

fn parseOllamaModelInfoContext(object: std.json.ObjectMap) ?u32 {
    const model_info = object.get("model_info") orelse return null;
    if (model_info != .object) return null;

    if (parseU32Aliases(model_info.object, &.{ "context_length", "general.context_length", "llama.context_length", "qwen2.context_length", "gemma3.context_length", "mistral.context_length" })) |value| return value;

    var iterator = model_info.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.key_ptr.*, ".context_length") or
            std.mem.endsWith(u8, entry.key_ptr.*, ".context_length_train"))
        {
            if (valueToU32(entry.value_ptr.*)) |value| return value;
        }
    }

    return null;
}

fn findModelArray(root: std.json.Value) ?std.json.Array {
    return switch (root) {
        .array => |array| array,
        .object => |object| blk: {
            for ([_][]const u8{ "models", "data", "cached_models", "cachedModels" }) |key| {
                if (object.get(key)) |value| {
                    if (value == .array) break :blk value.array;
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn findOllamaModelArray(root: std.json.Value) ?std.json.Array {
    return switch (root) {
        .array => |array| array,
        .object => |object| blk: {
            if (object.get("models")) |value| {
                if (value == .array) break :blk value.array;
            }
            break :blk null;
        },
        else => null,
    };
}

fn findLoadedArray(root: std.json.Value) ?std.json.Array {
    return switch (root) {
        .array => |array| array,
        .object => |object| blk: {
            for ([_][]const u8{ "loaded_models", "loadedModels", "loaded", "models", "data" }) |key| {
                if (object.get(key)) |value| {
                    if (value == .array) break :blk value.array;
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn loadedEndpointContains(root: std.json.Value, id: []const u8) bool {
    if (id.len == 0) return false;
    const loaded_array = findLoadedArray(root) orelse return false;
    return arrayContainsModelId(loaded_array, id);
}

fn loadedListContains(root: std.json.Value, id: []const u8) bool {
    if (id.len == 0) return false;
    const loaded_array = switch (root) {
        .object => |object| blk: {
            for ([_][]const u8{ "loaded_models", "loadedModels", "loaded" }) |key| {
                if (object.get(key)) |value| {
                    if (value == .array) break :blk value.array;
                }
            }
            break :blk null;
        },
        else => null,
    };

    if (loaded_array) |array| return arrayContainsModelId(array, id);
    return false;
}

fn arrayContainsModelId(array: std.json.Array, id: []const u8) bool {
    for (array.items) |item| {
        switch (item) {
            .string => |value| if (std.mem.eql(u8, value, id)) return true,
            .object => |object| {
                const loaded_id = getString(object, &.{ "id", "model", "name" }) orelse continue;
                if (std.mem.eql(u8, loaded_id, id)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn countLoadedEntries(root: std.json.Value) usize {
    const loaded_array = findLoadedArray(root) orelse return 0;
    return loaded_array.items.len;
}

fn getString(object: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (object.get(key)) |value| {
            if (value == .string) return value.string;
        }
    }
    return null;
}

fn parseU32Aliases(object: std.json.ObjectMap, keys: []const []const u8) ?u32 {
    for (keys) |key| {
        if (object.get(key)) |value| {
            if (valueToU32(value)) |parsed| return parsed;
        }
    }
    return null;
}

fn valueToU32(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |integer| if (integer > 0 and integer <= std.math.maxInt(u32)) @intCast(integer) else null,
        .float => |float| if (float > 0 and float <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) @intFromFloat(float) else null,
        .number_string => |text| std.fmt.parseInt(u32, text, 10) catch null,
        .string => |text| std.fmt.parseInt(u32, text, 10) catch null,
        else => null,
    };
}

fn parseBoolAliases(object: std.json.ObjectMap, keys: []const []const u8) ?bool {
    for (keys) |key| {
        if (object.get(key)) |value| {
            if (valueToBool(value)) |parsed| return parsed;
        }
    }
    return null;
}

fn valueToBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |boolean| boolean,
        .integer => |integer| integer != 0,
        .string => |text| parseBoolText(text),
        else => null,
    };
}

fn parseBoolText(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on") or
        std.mem.eql(u8, text, "1"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "no") or
        std.ascii.eqlIgnoreCase(text, "off") or
        std.mem.eql(u8, text, "0"))
    {
        return false;
    }
    return null;
}

fn parseThinkingLevelMap(object: std.json.ObjectMap) ?types.ModelThinkingLevelMap {
    const value = object.get("thinkingLevelMap") orelse object.get("thinking_level_map") orelse return null;
    if (value != .object) return null;

    var map = types.ModelThinkingLevelMap{};
    if (parseThinkingLevelMapping(value.object.get("off"))) |mapping| map.off = mapping;
    if (parseThinkingLevelMapping(value.object.get("minimal"))) |mapping| map.minimal = mapping;
    if (parseThinkingLevelMapping(value.object.get("low"))) |mapping| map.low = mapping;
    if (parseThinkingLevelMapping(value.object.get("medium"))) |mapping| map.medium = mapping;
    if (parseThinkingLevelMapping(value.object.get("high"))) |mapping| map.high = mapping;
    if (parseThinkingLevelMapping(value.object.get("xhigh"))) |mapping| map.xhigh = mapping;
    return map;
}

fn parseThinkingLevelMapping(value: ?std.json.Value) ?types.ThinkingLevelMapping {
    const mapping = value orelse return null;
    return switch (mapping) {
        .null => .unsupported,
        .string => |text| .{ .mapped = text },
        else => null,
    };
}

fn capabilitiesPresentAndLacksTools(capabilities_present: bool, object: std.json.ObjectMap) bool {
    return capabilities_present and !capabilitiesContain(object, &.{ "tools", "tool", "tool_calling", "function_calling" });
}

fn capabilitiesContain(object: std.json.ObjectMap, needles: []const []const u8) bool {
    const capabilities = object.get("capabilities") orelse return false;
    return valueContainsAnyString(capabilities, needles);
}

fn valueContainsAnyString(value: std.json.Value, needles: []const []const u8) bool {
    switch (value) {
        .string => |text| return stringMatchesAny(text, needles),
        .array => |array| {
            for (array.items) |item| {
                if (valueContainsAnyString(item, needles)) return true;
            }
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* == .bool and !entry.value_ptr.bool) continue;
                if (stringMatchesAny(entry.key_ptr.*, needles)) return true;
            }
        },
        else => {},
    }
    return false;
}

fn stringMatchesAny(value: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.eqlIgnoreCase(value, needle)) return true;
    }
    return false;
}

fn resolveKind(base_url: []const u8, requested: DiscoveryKind) DiscoveryKind {
    if (requested != .auto) return requested;
    if (string_utils.containsIgnoreCase(base_url, "ollama") or std.mem.indexOf(u8, base_url, ":11434") != null) return .ollama;
    return .openai;
}

fn joinUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    const trimmed_base = trimRightScalar(base_url, '/');
    const trimmed_path = trimLeftScalar(path, '/');
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_base, trimmed_path });
}

fn stripOpenAISuffix(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = trimRightScalar(base_url, '/');
    if (std.mem.endsWith(u8, trimmed, "/v1")) {
        return allocator.dupe(u8, trimmed[0 .. trimmed.len - 3]);
    }
    return allocator.dupe(u8, trimmed);
}

fn trimRightScalar(value: []const u8, scalar: u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == scalar) : (end -= 1) {}
    return value[0..end];
}

fn trimLeftScalar(value: []const u8, scalar: u8) []const u8 {
    var start: usize = 0;
    while (start < value.len and value[start] == scalar) : (start += 1) {}
    return value[start..];
}

const TestJsonServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    response_bodies: []const []const u8,
    thread: ?std.Thread = null,

    fn init(io: std.Io, response_bodies: []const []const u8) !TestJsonServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .response_bodies = response_bodies,
        };
    }

    fn start(self: *TestJsonServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *TestJsonServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn port(self: *const TestJsonServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn url(self: *const TestJsonServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/models", .{self.port()});
    }

    fn run(self: *TestJsonServer) void {
        for (self.response_bodies) |body| {
            const stream = self.server.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => return,
                else => std.debug.panic("test JSON server accept failed: {}", .{err}),
            };
            defer stream.close(self.io);

            readRequestHead(stream) catch |err| std.debug.panic("test JSON server read failed: {}", .{err});
            writeResponse(self.io, stream, body) catch return;
        }
    }

    fn readRequestHead(stream: std.Io.net.Stream) !void {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            tail[count % tail.len] = byte;
            count += 1;

            if (count >= 4) {
                const start_index = count % tail.len;
                const ordered = [_]u8{
                    tail[start_index],
                    tail[(start_index + 1) % tail.len],
                    tail[(start_index + 2) % tail.len],
                    tail[(start_index + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }
    }

    fn writeResponse(io: std.Io, stream: std.Io.net.Stream, body: []const u8) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{body.len},
        );
        try writer.interface.writeAll(body);
        try writer.interface.flush();
    }
};

const TestStalledJsonServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    stall_ms: u64,
    thread: ?std.Thread = null,

    fn init(io: std.Io, stall_ms: u64) !TestStalledJsonServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .stall_ms = stall_ms,
        };
    }

    fn start(self: *TestStalledJsonServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *TestStalledJsonServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn port(self: *const TestStalledJsonServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn url(self: *const TestStalledJsonServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/models", .{self.port()});
    }

    fn run(self: *TestStalledJsonServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("test stalled JSON server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        TestJsonServer.readRequestHead(stream) catch return;
        std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.stall_ms)), .awake) catch {};
    }
};

test "registerModelsFromJson parses rich model specs" {
    var registry = model_registry.ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerProvider(.{
        .provider = "local-rich",
        .api = "openai-completions",
        .base_url = "http://localhost:1234/v1",
    });
    const provider = registry.getProviderConfig("local-rich").?;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "models": [
        \\    {
        \\      "id": "qwen3-coder",
        \\      "name": "Qwen3 Coder",
        \\      "inputModalities": ["text", "image"],
        \\      "contextWindow": 262144,
        \\      "maxTokens": 32768,
        \\      "thinking": true,
        \\      "toolCalling": true
        \\    }
        \\  ],
        \\  "loadedModels": ["qwen3-coder"]
        \\}
    , .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), try registerModelsFromJson(std.testing.allocator, &registry, provider, parsed.value));
    const model = registry.find("local-rich", "qwen3-coder").?;
    try std.testing.expectEqualStrings("Qwen3 Coder", model.name);
    try std.testing.expectEqual(@as(u32, 262144), model.context_window);
    try std.testing.expectEqual(@as(u32, 32768), model.max_tokens);
    try std.testing.expect(model.reasoning);
    try std.testing.expect(model.tool_calling);
    try std.testing.expect(model.loaded);
    try std.testing.expectEqual(@as(usize, 2), model.input_types.len);
}

test "discoverAndRegister accepts normal capped model discovery fixture" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const model_fixture =
        \\{
        \\  "models": [
        \\    {"id": "fixture-text", "name": "Fixture Text", "context_window": 64000},
        \\    {"id": "fixture-vision", "name": "Fixture Vision", "capabilities": ["vision"]}
        \\  ]
        \\}
    ;
    const responses = [_][]const u8{model_fixture};

    var server = try TestJsonServer.init(io, &responses);
    defer server.deinit();
    try server.start();

    const models_url = try server.url(allocator);
    defer allocator.free(models_url);

    var registry = model_registry.ModelRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.{
        .provider = "fixture-provider",
        .api = "openai-completions",
        .base_url = "http://127.0.0.1/v1",
    });
    const provider = registry.getProviderConfig("fixture-provider").?;

    const summary = try discoverAndRegister(allocator, io, &registry, provider, .{
        .kind = .openai,
        .models_url = models_url,
    });

    try std.testing.expectEqual(@as(usize, 2), summary.registered_models);
    try std.testing.expectEqualStrings("Fixture Text", registry.find("fixture-provider", "fixture-text").?.name);
    try std.testing.expectEqual(@as(u32, 64000), registry.find("fixture-provider", "fixture-text").?.context_window);
    try std.testing.expectEqual(@as(usize, 2), registry.find("fixture-provider", "fixture-vision").?.input_types.len);
}

test "discoverAndRegister propagates timeout through capped request path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStalledJsonServer.init(io, 500);
    defer server.deinit();
    try server.start();

    const models_url = try server.url(allocator);
    defer allocator.free(models_url);

    var registry = model_registry.ModelRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.{
        .provider = "timeout-provider",
        .api = "openai-completions",
        .base_url = "http://127.0.0.1/v1",
    });
    const provider = registry.getProviderConfig("timeout-provider").?;

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const summary = discoverAndRegister(allocator, io, &registry, provider, .{
        .kind = .openai,
        .models_url = models_url,
        .timeout_ms = 100,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(http_client.HttpError.Timeout, summary);
    try std.testing.expect(elapsed_ms < server.stall_ms);
}

test "model discovery JSON fetch rejects oversized response before parsing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const responses = [_][]const u8{"not-json-but-over-cap"};

    var server = try TestJsonServer.init(io, &responses);
    defer server.deinit();
    try server.start();

    const models_url = try server.url(allocator);
    defer allocator.free(models_url);

    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const parsed = requestJsonWithCap(allocator, &client, .GET, models_url, null, null, 8, 0, null);
    try std.testing.expectError(http_client.HttpError.ResponseBodyTooLarge, parsed);
}

test "registerLoadedModelsFromJson marks and registers loaded models" {
    var registry = model_registry.ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerProvider(.{
        .provider = "local-loaded",
        .api = "openai-completions",
        .base_url = "http://localhost:1234/v1",
    });
    const provider = registry.getProviderConfig("local-loaded").?;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "loaded_models": [
        \\    {"id": "loaded-rich", "context_window": 64000, "tool_calling": false},
        \\    "loaded-minimal"
        \\  ]
        \\}
    , .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), try registerLoadedModelsFromJson(std.testing.allocator, &registry, provider, parsed.value));
    try std.testing.expect(registry.find("local-loaded", "loaded-rich").?.loaded);
    try std.testing.expect(!registry.find("local-loaded", "loaded-rich").?.tool_calling);
    try std.testing.expect(registry.find("local-loaded", "loaded-minimal").?.loaded);
}

test "ollama ps models count as loaded endpoint entries" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "models": [
        \\    {"model": "qwen3:latest"}
        \\  ]
        \\}
    , .{});
    defer parsed.deinit();

    try std.testing.expect(loadedEndpointContains(parsed.value, "qwen3:latest"));
    try std.testing.expect(!loadedListContains(parsed.value, "qwen3:latest"));
}

test "ollama show metadata maps capabilities and context" {
    var registry = model_registry.ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerProvider(.{
        .provider = "ollama",
        .api = "openai-completions",
        .base_url = "http://localhost:11434/v1",
    });
    const provider = registry.getProviderConfig("ollama").?;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "capabilities": ["completion", "tools", "thinking", "vision"],
        \\  "model_info": {
        \\    "qwen2.context_length": 131072
        \\  }
        \\}
    , .{});
    defer parsed.deinit();

    try std.testing.expect(try registerOllamaShowObject(std.testing.allocator, &registry, provider, "qwen3:latest", parsed.value.object, true));
    const model = registry.find("ollama", "qwen3:latest").?;
    try std.testing.expect(model.reasoning);
    try std.testing.expect(model.tool_calling);
    try std.testing.expect(model.loaded);
    try std.testing.expectEqual(@as(u32, 131072), model.context_window);
    try std.testing.expectEqual(@as(usize, 2), model.input_types.len);
}
