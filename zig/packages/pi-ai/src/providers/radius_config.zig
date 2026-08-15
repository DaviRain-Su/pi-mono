const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const provider_error = @import("../shared/provider_error.zig");

pub const DEFAULT_RADIUS_GATEWAY = "https://radius.pi.dev";

pub const RadiusGatewayModel = struct {
    id: []const u8,
    name: []const u8,
    reasoning: bool,
    input: []const []const u8,
    cost: types.ModelCost,
    context_window: u32,
    max_tokens: u32,
};

pub const RadiusGatewayConfig = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    models: []RadiusGatewayModel,

    pub fn deinit(self: *RadiusGatewayConfig) void {
        self.allocator.free(self.base_url);
        for (self.models) |model| {
            self.allocator.free(model.id);
            self.allocator.free(model.name);
            for (model.input) |input_type| self.allocator.free(input_type);
            self.allocator.free(model.input);
        }
        self.allocator.free(self.models);
        self.* = undefined;
    }
};

pub const OwnedRadiusModels = struct {
    allocator: std.mem.Allocator,
    models: []types.Model,

    pub fn deinit(self: *OwnedRadiusModels) void {
        for (self.models) |model| {
            self.allocator.free(model.id);
            self.allocator.free(model.name);
            self.allocator.free(model.base_url);
            for (model.input_types) |input_type| self.allocator.free(input_type);
            self.allocator.free(model.input_types);
        }
        self.allocator.free(self.models);
        self.* = undefined;
    }
};

pub fn normalizeRadiusGatewayUrl(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const prefix: []const u8 = if (hasHttpScheme(value)) "" else "https://";
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') end -= 1;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, value[0..end] });
}

pub fn buildRadiusConfigUrl(allocator: std.mem.Allocator, gateway: []const u8) ![]u8 {
    return joinGatewayPath(allocator, gateway, "/v1/config");
}

pub fn sanitizeRadiusGatewayConfig(allocator: std.mem.Allocator, value: std.json.Value) !?RadiusGatewayConfig {
    if (value != .object) return null;
    const base_url = jsonString(value.object, "baseUrl") orelse return null;
    const models_value = value.object.get("models") orelse return null;
    if (models_value != .array) return null;

    const owned_base_url = try allocator.dupe(u8, base_url);
    errdefer allocator.free(owned_base_url);

    var models: std.ArrayList(RadiusGatewayModel) = .empty;
    errdefer {
        for (models.items) |model| {
            allocator.free(model.id);
            allocator.free(model.name);
            for (model.input) |input_type| allocator.free(input_type);
            allocator.free(model.input);
        }
        models.deinit(allocator);
    }

    for (models_value.array.items) |item| {
        if (try cloneGatewayModel(allocator, item)) |model| {
            try models.append(allocator, model);
        }
    }

    return .{
        .allocator = allocator,
        .base_url = owned_base_url,
        .models = try models.toOwnedSlice(allocator),
    };
}

pub fn getRadiusModelsFromConfig(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    config: RadiusGatewayConfig,
) !OwnedRadiusModels {
    const models = try allocator.alloc(types.Model, config.models.len);
    errdefer allocator.free(models);

    var filled: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < filled) : (index += 1) {
            allocator.free(models[index].id);
            allocator.free(models[index].name);
            allocator.free(models[index].base_url);
            for (models[index].input_types) |input_type| allocator.free(input_type);
            allocator.free(models[index].input_types);
        }
    }

    for (config.models, 0..) |source, index| {
        models[index] = try modelFromGatewayModel(allocator, provider_id, config.base_url, source);
        filled = index + 1;
    }

    return .{
        .allocator = allocator,
        .models = models,
    };
}

pub fn loadRadiusGatewayConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    gateway: []const u8,
    api_key: ?[]const u8,
) !RadiusGatewayConfig {
    const url = try buildRadiusConfigUrl(allocator, gateway);
    defer allocator.free(url);

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("accept", "application/json");

    const authorization = if (api_key) |key|
        try std.fmt.allocPrint(allocator, "Bearer {s}", .{key})
    else
        null;
    defer if (authorization) |header| allocator.free(header);
    if (authorization) |header| try headers.put("authorization", header);

    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .headers = headers,
    });
    defer streaming.deinit();

    const body = try streaming.readAllBounded(allocator, http_client.max_response_body_bytes);
    defer allocator.free(body);

    if (streaming.status < 200 or streaming.status >= 300) return error.RadiusConfigHttpError;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidRadiusConfig;
    defer parsed.deinit();

    return (try sanitizeRadiusGatewayConfig(allocator, parsed.value)) orelse error.InvalidRadiusConfig;
}

fn joinGatewayPath(allocator: std.mem.Allocator, gateway: []const u8, path: []const u8) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, gateway, "://") orelse return std.fmt.allocPrint(allocator, "{s}{s}", .{ gateway, path });
    const after_scheme = scheme_end + 3;
    if (std.mem.indexOfScalar(u8, gateway[after_scheme..], '/')) |path_start| {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ gateway[0 .. after_scheme + path_start], path });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ gateway, path });
}

fn hasHttpScheme(value: []const u8) bool {
    if (value.len >= 8 and std.ascii.eqlIgnoreCase(value[0..8], "https://")) return true;
    if (value.len >= 7 and std.ascii.eqlIgnoreCase(value[0..7], "http://")) return true;
    return false;
}

fn cloneGatewayModel(allocator: std.mem.Allocator, value: std.json.Value) !?RadiusGatewayModel {
    if (value != .object) return null;
    const id = jsonString(value.object, "id") orelse return null;
    const name = jsonString(value.object, "name") orelse return null;
    const reasoning = jsonBool(value.object, "reasoning") orelse return null;
    const input_value = value.object.get("input") orelse return null;
    if (input_value != .array) return null;
    const cost_value = value.object.get("cost") orelse return null;
    if (cost_value != .object) return null;
    const context_window = jsonU32(value.object, "contextWindow") orelse return null;
    const max_tokens = jsonU32(value.object, "maxTokens") orelse return null;

    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    var input: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (input.items) |input_type| allocator.free(input_type);
        input.deinit(allocator);
    }
    for (input_value.array.items) |item| {
        if (item != .string) continue;
        try input.append(allocator, try allocator.dupe(u8, item.string));
    }

    return .{
        .id = owned_id,
        .name = owned_name,
        .reasoning = reasoning,
        .input = try input.toOwnedSlice(allocator),
        .cost = .{
            .input = jsonF64(cost_value.object, "input"),
            .output = jsonF64(cost_value.object, "output"),
            .cache_read = jsonF64(cost_value.object, "cacheRead"),
            .cache_write = jsonF64(cost_value.object, "cacheWrite"),
        },
        .context_window = context_window,
        .max_tokens = max_tokens,
    };
}

fn modelFromGatewayModel(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    base_url: []const u8,
    source: RadiusGatewayModel,
) !types.Model {
    const id = try allocator.dupe(u8, source.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, source.name);
    errdefer allocator.free(name);
    const owned_base_url = try allocator.dupe(u8, base_url);
    errdefer allocator.free(owned_base_url);

    const input_types = try allocator.alloc([]const u8, source.input.len);
    errdefer allocator.free(input_types);
    var filled: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < filled) : (index += 1) allocator.free(input_types[index]);
    }
    for (source.input, 0..) |input_type, index| {
        input_types[index] = try allocator.dupe(u8, input_type);
        filled = index + 1;
    }

    return .{
        .id = id,
        .name = name,
        .api = "pi-messages",
        .provider = provider_id,
        .base_url = owned_base_url,
        .reasoning = source.reasoning,
        .input_types = input_types,
        .cost = source.cost,
        .context_window = source.context_window,
        .max_tokens = source.max_tokens,
    };
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn jsonU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| std.math.cast(u32, number),
        .float => |number| std.math.cast(u32, @as(i64, @intFromFloat(number))),
        else => null,
    };
}

fn jsonF64(object: std.json.ObjectMap, key: []const u8) f64 {
    const value = object.get(key) orelse return 0;
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => 0,
    };
}

test "normalizeRadiusGatewayUrl adds https and strips trailing slashes" {
    const allocator = std.testing.allocator;

    const defaulted = try normalizeRadiusGatewayUrl(allocator, "radius.pi.dev");
    defer allocator.free(defaulted);
    try std.testing.expectEqualStrings(DEFAULT_RADIUS_GATEWAY, defaulted);

    const slashes = try normalizeRadiusGatewayUrl(allocator, "https://radius.pi.dev///");
    defer allocator.free(slashes);
    try std.testing.expectEqualStrings(DEFAULT_RADIUS_GATEWAY, slashes);

    const http = try normalizeRadiusGatewayUrl(allocator, "HTTP://example.test/gw/");
    defer allocator.free(http);
    try std.testing.expectEqualStrings("HTTP://example.test/gw", http);
}

test "buildRadiusConfigUrl replaces the gateway path like URL(/v1/config)" {
    const allocator = std.testing.allocator;

    const defaulted = try buildRadiusConfigUrl(allocator, DEFAULT_RADIUS_GATEWAY);
    defer allocator.free(defaulted);
    try std.testing.expectEqualStrings("https://radius.pi.dev/v1/config", defaulted);

    const nested = try buildRadiusConfigUrl(allocator, "https://example.test/custom/gw");
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("https://example.test/v1/config", nested);
}

test "sanitizeRadiusGatewayConfig keeps valid models and drops invalid ones" {
    const allocator = std.testing.allocator;
    const raw =
        \\{
        \\  "baseUrl": "https://radius.pi.dev/v1",
        \\  "models": [
        \\    {
        \\      "id": "auto",
        \\      "name": "Radius Auto",
        \\      "reasoning": true,
        \\      "input": ["text", "image"],
        \\      "cost": {"input": 1.5, "output": 2, "cacheRead": 0.1, "cacheWrite": 0.2},
        \\      "contextWindow": 200000,
        \\      "maxTokens": 16384
        \\    },
        \\    {"id": "broken"},
        \\    "skip-me"
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var config = (try sanitizeRadiusGatewayConfig(allocator, parsed.value)).?;
    defer config.deinit();

    try std.testing.expectEqualStrings("https://radius.pi.dev/v1", config.base_url);
    try std.testing.expectEqual(@as(usize, 1), config.models.len);
    try std.testing.expectEqualStrings("auto", config.models[0].id);
    try std.testing.expectEqualStrings("Radius Auto", config.models[0].name);
    try std.testing.expect(config.models[0].reasoning);
    try std.testing.expectEqual(@as(usize, 2), config.models[0].input.len);
    try std.testing.expectEqualStrings("text", config.models[0].input[0]);
    try std.testing.expectEqualStrings("image", config.models[0].input[1]);
    try std.testing.expectEqual(@as(f64, 1.5), config.models[0].cost.input);
    try std.testing.expectEqual(@as(f64, 2), config.models[0].cost.output);
    try std.testing.expectEqual(@as(f64, 0.1), config.models[0].cost.cache_read);
    try std.testing.expectEqual(@as(f64, 0.2), config.models[0].cost.cache_write);
    try std.testing.expectEqual(@as(u32, 200000), config.models[0].context_window);
    try std.testing.expectEqual(@as(u32, 16384), config.models[0].max_tokens);

    var models = try getRadiusModelsFromConfig(allocator, "radius", config);
    defer models.deinit();
    try std.testing.expectEqual(@as(usize, 1), models.models.len);
    try std.testing.expectEqualStrings("pi-messages", models.models[0].api);
    try std.testing.expectEqualStrings("radius", models.models[0].provider);
    try std.testing.expectEqualStrings("https://radius.pi.dev/v1", models.models[0].base_url);
    try std.testing.expectEqualStrings("auto", models.models[0].id);
}

test "sanitizeRadiusGatewayConfig rejects payloads without baseUrl or models" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"models\":[]}", .{});
    defer parsed.deinit();
    try std.testing.expect(try sanitizeRadiusGatewayConfig(allocator, parsed.value) == null);
}

test "loadRadiusGatewayConfig reads a gateway catalog" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const body =
        \\{"baseUrl":"https://radius.pi.dev/v1","models":[{"id":"auto","name":"Radius Auto","reasoning":false,"input":["text"],"cost":{"input":0,"output":0},"contextWindow":8192,"maxTokens":4096}]}
    ;
    var server = try provider_error.TestStatusServer.init(io, 200, "OK", "", body);
    defer server.deinit();
    try server.start();
    const gateway = try server.url(allocator);
    defer allocator.free(gateway);

    var config = try loadRadiusGatewayConfig(allocator, io, gateway, "radius-key");
    defer config.deinit();
    try std.testing.expectEqualStrings("https://radius.pi.dev/v1", config.base_url);
    try std.testing.expectEqual(@as(usize, 1), config.models.len);
    try std.testing.expectEqualStrings("auto", config.models[0].id);
}

test "loadRadiusGatewayConfig surfaces HTTP and invalid catalog failures" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var missing = try provider_error.TestStatusServer.init(io, 404, "Not Found", "", "gone");
    defer missing.deinit();
    try missing.start();
    const missing_gateway = try missing.url(allocator);
    defer allocator.free(missing_gateway);
    try std.testing.expectError(error.RadiusConfigHttpError, loadRadiusGatewayConfig(allocator, io, missing_gateway, null));

    var invalid = try provider_error.TestStatusServer.init(io, 200, "OK", "", "{\"nope\":true}");
    defer invalid.deinit();
    try invalid.start();
    const invalid_gateway = try invalid.url(allocator);
    defer allocator.free(invalid_gateway);
    try std.testing.expectError(error.InvalidRadiusConfig, loadRadiusGatewayConfig(allocator, io, invalid_gateway, null));
}
