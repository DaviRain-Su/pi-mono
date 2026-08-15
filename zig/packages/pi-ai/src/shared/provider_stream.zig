const builtin = @import("builtin");
const std = @import("std");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("provider_error.zig");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");

pub fn runSetupOrEmit(
    comptime setup_fn: anytype,
    setup_args: anytype,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    options: ?types.StreamOptions,
) anyerror!void {
    @call(.auto, setup_fn, setup_args) catch |err| {
        const any_err: anyerror = err;
        if (any_err == error.OutOfMemory) return error.OutOfMemory;
        if (builtin.mode == .Debug) {
            std.log.debug("provider setup error (captured as stream event): api={s} provider={s} model={s} err={s}", .{
                model.api,
                model.provider,
                model.id,
                @errorName(any_err),
            });
        }
        emitSetupRuntimeFailure(stream_ptr, model, options, err);
    };
}

/// comptime factory that returns a struct with the standard `stream`
/// and `streamSimple` boilerplate shared by every provider that follows
/// the `streamProduction` pattern.  `api_name` becomes the struct's `api`
/// constant; `ProductionFn` is the provider-specific setup routine (must
/// match the signature
/// `fn(allocator, io, model, context, options, *AssistantMessageEventStream) !void`).
///
/// Usage in a provider file:
/// ```zig
/// const Base = provider_stream.DefineProvider("openai-completions", streamProduction);
/// pub const OpenAIProvider = struct {
///     pub const api = Base.api;
///     pub const stream = Base.stream;
///     pub const streamSimple = Base.streamSimple;
/// };
/// ```
///
/// Providers that need a custom `streamSimple` (e.g. Bedrock's token
/// adjustment) should NOT re-export `Base.streamSimple` and instead
/// define their own.
pub fn DefineProvider(comptime api_name: []const u8, comptime ProductionFn: anytype) type {
    return struct {
        pub const api = api_name;

        pub fn stream(
            allocator: std.mem.Allocator,
            io: std.Io,
            model: types.Model,
            context: types.Context,
            options: ?types.StreamOptions,
        ) !event_stream.AssistantMessageEventStream {
            var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
            errdefer stream_instance.deinit();

            try runSetupOrEmit(
                ProductionFn,
                .{ allocator, io, model, context, options, &stream_instance },
                &stream_instance,
                model,
                options,
            );
            return stream_instance;
        }

        pub fn streamSimple(
            allocator: std.mem.Allocator,
            io: std.Io,
            model: types.Model,
            context: types.Context,
            options: ?types.StreamOptions,
        ) !event_stream.AssistantMessageEventStream {
            return try stream(allocator, io, model, context, options);
        }
    };
}

pub fn emitSetupRuntimeFailure(
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    options: ?types.StreamOptions,
    err: anyerror,
) void {
    const effective_err = if (provider_error.isAbortRequested(options)) error.RequestAborted else err;
    const message = provider_error.makeTerminalRuntimeMessage(model, effective_err);
    provider_error.pushTerminalRuntimeError(stream_ptr, message);
}

pub fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    if (headers.fetchRemove(name)) |removed| {
        allocator.free(removed.key);
        allocator.free(removed.value);
    }
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try headers.put(owned_name, owned_value);
}

pub fn putOwnedHeaderCaseInsensitive(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    try removeOwnedHeaderCaseInsensitive(allocator, headers, name);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try headers.put(owned_name, owned_value);
}

pub fn mergeHeaders(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try putOwnedHeader(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

pub fn mergeHeadersCaseInsensitive(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try putOwnedHeaderCaseInsensitive(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

pub fn containsHeaderCaseInsensitive(headers: *const std.StringHashMap([]const u8), name: []const u8) bool {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return true;
    }
    return false;
}

pub fn deinitOwnedHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

pub fn normalizedResponseHeaders(
    allocator: std.mem.Allocator,
    maybe_headers: ?std.StringHashMap([]const u8),
) !std.StringHashMap([]const u8) {
    var normalized = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &normalized);

    if (maybe_headers) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            const lower = try std.ascii.allocLowerString(allocator, entry.key_ptr.*);
            defer allocator.free(lower);
            try putOwnedHeader(allocator, &normalized, lower, entry.value_ptr.*);
        }
    }

    return normalized;
}

pub fn invokeOnResponse(
    allocator: std.mem.Allocator,
    callback: *const fn (u16, std.StringHashMap([]const u8), types.Model) anyerror!void,
    status: u16,
    maybe_headers: ?std.StringHashMap([]const u8),
    model: types.Model,
) !void {
    var response_headers = try normalizedResponseHeaders(allocator, maybe_headers);
    defer deinitOwnedHeaders(allocator, &response_headers);
    try callback(status, response_headers, model);
}

/// Shared helper that sends a streaming HTTP POST request through the
/// provided client, invokes the optional `on_response` callback, and
/// returns the `StreamingResponse`.  The caller owns the returned
/// response and must call `response.deinit()`; the caller also owns
/// `client` and must call `client.deinit()` after the response is done.
pub fn executeStreamingRequest(
    client: *http_client.HttpClient,
    url: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    options: ?types.StreamOptions,
    model: types.Model,
) !http_client.StreamingResponse {
    var response = try client.requestStreaming(.{
        .method = .POST,
        .url = url,
        .headers = headers,
        .body = body,
        .timeout_ms = if (options) |stream_options| stream_options.timeout_ms orelse 0 else 0,
        .aborted = if (options) |stream_options| stream_options.signal else null,
    });
    errdefer response.deinit();
    if (options) |stream_options| {
        if (stream_options.on_response) |callback| {
            try invokeOnResponse(client.allocator, callback, response.status, response.response_headers, model);
        }
    }
    return response;
}

/// Type-erased payload-replacement callback. Mirrors
/// `types.StreamOptions.on_payload`: the callback may return null (keep
/// the existing payload) or a fully-owned replacement value that the
/// caller takes ownership of (in which case the old payload must be
/// freed first).
const OnPayloadCallback = *const fn (
    std.mem.Allocator,
    std.json.Value,
    types.Model,
) anyerror!?std.json.Value;

/// Apply the `on_payload` replacement callback if present. Every
/// provider's streamProduction repeats the same block:
/// ```zig
/// if (options) |stream_options| {
///     if (stream_options.on_payload) |callback| {
///         if (try callback(allocator, payload, model)) |replacement| {
///             provider_json.freeValue(allocator, payload);
///             payload = replacement;
///         }
///     }
/// }
/// ```
/// This collapses it to a single line that mutates `payload` in place.
/// Lives here (not in shared/provider_json.zig) because it deals with
/// the StreamOptions callback contract, not generic JSON utilities.
pub fn applyOnPayloadCallback(
    allocator: std.mem.Allocator,
    payload: *std.json.Value,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    const stream_options = options orelse return;
    const callback = stream_options.on_payload orelse return;
    if (try callback(allocator, payload.*, model)) |replacement| {
        const provider_json = @import("provider_json.zig");
        provider_json.freeValue(allocator, payload.*);
        payload.* = replacement;
    }
}

pub fn parseCanonicalSseDataLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const prefix = "data: ";
    if (std.mem.startsWith(u8, trimmed, prefix)) return trimmed[prefix.len..];
    return null;
}

fn removeOwnedHeaderCaseInsensitive(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
) !void {
    var key_to_remove: ?[]const u8 = null;
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
            key_to_remove = entry.key_ptr.*;
            break;
        }
    }
    if (key_to_remove) |key| {
        if (headers.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
        }
    }
}

fn fixtureSetupFailure() !void {
    return error.FixtureProviderSetupFailure;
}

fn fixtureOutOfMemory() !void {
    return error.OutOfMemory;
}

fn fixtureModel() types.Model {
    return .{
        .id = "fixture-model",
        .name = "Fixture Model",
        .api = "fixture-api",
        .provider = "fixture-provider",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
}

test "runSetupOrEmit converts non-OOM setup failure into terminal error_event" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const model = fixtureModel();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try runSetupOrEmit(fixtureSetupFailure, .{}, &stream, model, null);

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings("FixtureProviderSetupFailure", event.error_message.?);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expectEqualStrings("fixture-api", event.message.?.api);
    try std.testing.expectEqualStrings("fixture-provider", event.message.?.provider);
    try std.testing.expectEqualStrings("fixture-model", event.message.?.model);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.api, result.api);
    try std.testing.expectEqualStrings(event.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(event.message.?.model, result.model);
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(event.message.?.stop_reason, result.stop_reason);
}

test "runSetupOrEmit preserves OutOfMemory as a thrown setup error" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const model = fixtureModel();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try std.testing.expectError(
        error.OutOfMemory,
        runSetupOrEmit(fixtureOutOfMemory, .{}, &stream, model, null),
    );
    try std.testing.expect(stream.result() == null);
}

test "owned provider headers merge replace and deinit safely" {
    const allocator = std.testing.allocator;
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
    try putOwnedHeader(allocator, &headers, "Content-Type", "text/event-stream");
    try std.testing.expectEqual(@as(u32, 1), headers.count());
    try std.testing.expectEqualStrings("text/event-stream", headers.get("Content-Type").?);

    var extra = std.StringHashMap([]const u8).init(allocator);
    defer extra.deinit();
    try extra.put("X-Provider", "fixture");
    try extra.put("Content-Type", "application/x-ndjson");

    try mergeHeaders(allocator, &headers, extra);
    try std.testing.expectEqual(@as(u32, 2), headers.count());
    try std.testing.expectEqualStrings("application/x-ndjson", headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("fixture", headers.get("X-Provider").?);
}

test "owned provider header insertion releases partial allocations on OOM" {
    var fail_index: usize = 0;
    while (fail_index < 6) : (fail_index += 1) {
        {
            var failing_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            const allocator = failing_state.allocator();
            var headers = std.StringHashMap([]const u8).init(allocator);
            defer deinitOwnedHeaders(allocator, &headers);

            putOwnedHeader(allocator, &headers, "Content-Type", "application/json") catch |err| switch (err) {
                error.OutOfMemory => continue,
            };
        }
    }
}

test "case-insensitive provider header insertion replaces prior spelling" {
    const allocator = std.testing.allocator;
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try putOwnedHeader(allocator, &headers, "Authorization", "Bearer old");
    try putOwnedHeaderCaseInsensitive(allocator, &headers, "authorization", "Bearer new");

    try std.testing.expectEqual(@as(u32, 1), headers.count());
    try std.testing.expect(headers.get("Authorization") == null);
    try std.testing.expectEqualStrings("Bearer new", headers.get("authorization").?);
    try std.testing.expect(containsHeaderCaseInsensitive(&headers, "AUTHORIZATION"));
}

test "case-insensitive owned provider header insertion releases partial allocations on OOM" {
    var fail_index: usize = 0;
    while (fail_index < 6) : (fail_index += 1) {
        {
            var failing_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            const allocator = failing_state.allocator();
            var headers = std.StringHashMap([]const u8).init(allocator);
            defer deinitOwnedHeaders(allocator, &headers);

            putOwnedHeaderCaseInsensitive(allocator, &headers, "Authorization", "Bearer fixture") catch |err| switch (err) {
                error.OutOfMemory => continue,
            };
        }
    }
}

test "normalized response headers lower-case names for callback lookup" {
    const allocator = std.testing.allocator;
    var original = std.StringHashMap([]const u8).init(allocator);
    defer original.deinit();
    try original.put("X-Fixture-Response", "callback-fixture");
    try original.put("Content-Type", "text/event-stream");

    var normalized = try normalizedResponseHeaders(allocator, original);
    defer deinitOwnedHeaders(allocator, &normalized);

    try std.testing.expect(normalized.get("X-Fixture-Response") == null);
    try std.testing.expectEqualStrings("callback-fixture", normalized.get("x-fixture-response").?);
    try std.testing.expectEqualStrings("text/event-stream", normalized.get("content-type").?);
}

test "canonical SSE data-line helper extracts only canonical data fields" {
    try std.testing.expectEqualStrings("{}", parseCanonicalSseDataLine("data: {}").?);
    try std.testing.expectEqualStrings("[DONE]", parseCanonicalSseDataLine(" \tdata: [DONE]\r").?);
    try std.testing.expect(parseCanonicalSseDataLine("data:{}") == null);
    try std.testing.expect(parseCanonicalSseDataLine("event: message") == null);
    try std.testing.expect(parseCanonicalSseDataLine(": comment") == null);
    try std.testing.expect(parseCanonicalSseDataLine("") == null);
}

const CANONICAL_SSE_LINE_FUZZ_SMOKE_SEED: u64 = 0x5eed_55e1_0000_0020;

test "VAL-REFACTOR-020 deterministic canonical SSE data-line fuzz smoke" {
    var prng = std.Random.DefaultPrng.init(CANONICAL_SSE_LINE_FUZZ_SMOKE_SEED);
    const random = prng.random();

    for (0..96) |case_index| {
        var line_buffer: [96]u8 = undefined;
        const len = random.uintLessThan(usize, line_buffer.len);
        for (line_buffer[0..len]) |*byte| {
            byte.* = switch (random.uintLessThan(u8, 8)) {
                0 => ' ',
                1 => '\t',
                2 => '\r',
                3 => ':',
                4 => 'a',
                5 => 'd',
                6 => '{',
                else => @as(u8, 0x20) + random.uintLessThan(u8, 0x5f),
            };
        }

        const line = line_buffer[0..len];
        const expected = expectedCanonicalSseDataLine(line);
        const actual = parseCanonicalSseDataLine(line);
        if (expected) |expected_data| {
            if (actual == null or !std.mem.eql(u8, actual.?, expected_data)) {
                reportCanonicalSseLineFuzzFailure(CANONICAL_SSE_LINE_FUZZ_SMOKE_SEED, case_index, line);
                return error.CanonicalSseLineFuzzMismatch;
            }
        } else if (actual != null) {
            reportCanonicalSseLineFuzzFailure(CANONICAL_SSE_LINE_FUZZ_SMOKE_SEED, case_index, line);
            return error.CanonicalSseLineFuzzMismatch;
        }
    }
}

fn expectedCanonicalSseDataLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len < 6) return null;
    if (!std.mem.eql(u8, trimmed[0..6], "data: ")) return null;
    return trimmed[6..];
}

fn reportCanonicalSseLineFuzzFailure(seed: u64, case_index: usize, line: []const u8) void {
    std.debug.print("Canonical SSE data-line fuzz smoke failure seed=0x{x} case={d} minimized_input={s}\n", .{
        seed,
        case_index,
        line,
    });
}
