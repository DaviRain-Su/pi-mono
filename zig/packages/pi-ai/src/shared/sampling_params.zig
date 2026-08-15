const std = @import("std");
const types = @import("../types.zig");
const provider_json = @import("provider_json.zig");

/// Merge `Model.sampling_params` then `StreamOptions.sampling_params` onto a
/// request object. Request keys win. Mirrors TS `Object.assign` last onto
/// completions/responses/Azure params.
pub fn mergeSamplingParams(
    allocator: std.mem.Allocator,
    payload: *std.json.Value,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    if (payload.* != .object) return;
    if (model.sampling_params) |params| try assignObject(allocator, &payload.object, params);
    if (options) |opts| {
        if (opts.sampling_params) |params| try assignObject(allocator, &payload.object, params);
    }
}

pub fn stringifyWithSamplingParams(
    allocator: std.mem.Allocator,
    payload: anytype,
    model: types.Model,
    options: ?types.StreamOptions,
) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, payload, .{
        .emit_null_optional_fields = false,
    });
    if (model.sampling_params == null and (options == null or options.?.sampling_params == null)) {
        return bytes;
    }
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    var owned = try provider_json.cloneValue(allocator, parsed.value);
    defer provider_json.freeValue(allocator, owned);
    try mergeSamplingParams(allocator, &owned, model, options);
    return try std.json.Stringify.valueAlloc(allocator, owned, .{
        .emit_null_optional_fields = false,
    });
}

fn assignObject(allocator: std.mem.Allocator, dest: *std.json.ObjectMap, source: std.json.Value) !void {
    if (source != .object) return;
    var iterator = source.object.iterator();
    while (iterator.next()) |entry| {
        const cloned = try provider_json.cloneValue(allocator, entry.value_ptr.*);
        errdefer provider_json.freeValue(allocator, cloned);
        if (dest.getPtr(entry.key_ptr.*)) |existing| {
            provider_json.freeValue(allocator, existing.*);
            existing.* = cloned;
        } else {
            try dest.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), cloned);
        }
    }
}

test "mergeSamplingParams applies model then request overrides" {
    const allocator = std.testing.allocator;

    var model_object = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = model_object });
    try model_object.put(allocator, try allocator.dupe(u8, "top_p"), .{ .float = 0.9 });
    try model_object.put(allocator, try allocator.dupe(u8, "seed"), .{ .integer = 1 });

    var request_object = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = request_object });
    try request_object.put(allocator, try allocator.dupe(u8, "seed"), .{ .integer = 7 });

    var payload_object = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = payload_object });
    try payload_object.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt") });

    var payload: std.json.Value = .{ .object = payload_object };
    const model = types.Model{
        .id = "gpt",
        .name = "GPT",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
        .sampling_params = .{ .object = model_object },
    };
    try mergeSamplingParams(allocator, &payload, model, .{
        .sampling_params = .{ .object = request_object },
    });
    payload_object = payload.object;

    try std.testing.expectEqual(@as(f64, 0.9), payload_object.get("top_p").?.float);
    try std.testing.expectEqual(@as(i64, 7), payload_object.get("seed").?.integer);
    try std.testing.expectEqualStrings("gpt", payload_object.get("model").?.string);
}
