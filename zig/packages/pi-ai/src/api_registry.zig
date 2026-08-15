const std = @import("std");
const types = @import("types.zig");
const event_stream = @import("event_stream.zig");
const register_builtins = @import("providers/register_builtins.zig");

pub const StreamFunction = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) anyerror!event_stream.AssistantMessageEventStream;

pub const ApiProvider = struct {
    api: types.Api,
    stream: StreamFunction,
    stream_simple: StreamFunction,
};

const STATIC_BUILTINS = blk: {
    const providers = register_builtins.builtInProviders();
    var entries: [providers.len]struct { []const u8, ApiProvider } = undefined;
    for (providers, 0..) |provider, index| {
        entries[index] = .{
            provider.api,
            .{
                .api = provider.api,
                .stream = provider.stream,
                .stream_simple = provider.stream_simple,
            },
        };
    }
    break :blk std.StaticStringMap(ApiProvider).initComptime(entries);
};

// Process-wide override table. Mutated at startup (provider registration) and
// in tests; reads happen on every `ai.stream` call from any thread.
//
// Allocator choice: c_allocator gives small-grained heap allocations (the
// override map is typically empty or holds <10 entries). The previous
// page_allocator wasted a full page per HashMap grow.
//
// Init synchronization: `init_state` uses Acquire/Release ordering so a thread
// that observes init_state == done can safely read `overrides`. The double-
// checked pattern (cheap unsynchronized read in `get`) is safe because once
// init_state transitions to done it never goes back.
const InitState = enum(u8) { uninitialized = 0, initializing = 1, done = 2 };
var init_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(InitState.uninitialized));
var overrides: std.StringHashMap(ApiProvider) = undefined;

pub fn init() void {
    if (init_state.load(.acquire) == @intFromEnum(InitState.done)) return;
    // Race the .initializing slot. Loser spins until winner transitions to done.
    if (init_state.cmpxchgStrong(
        @intFromEnum(InitState.uninitialized),
        @intFromEnum(InitState.initializing),
        .acq_rel,
        .acquire,
    )) |actual| {
        // Lost the race; another thread is initializing. Spin briefly.
        _ = actual;
        while (init_state.load(.acquire) != @intFromEnum(InitState.done)) {
            std.Thread.yield() catch {};
        }
        return;
    }
    overrides = std.StringHashMap(ApiProvider).init(std.heap.c_allocator);
    init_state.store(@intFromEnum(InitState.done), .release);
}

/// True iff the override table has been initialized. Read-side fast path.
fn isInitialized() bool {
    return init_state.load(.acquire) == @intFromEnum(InitState.done);
}

pub fn register(provider: ApiProvider) !void {
    init();
    try overrides.put(provider.api, provider);
}

pub fn get(api: types.Api) ?ApiProvider {
    if (isInitialized()) {
        if (overrides.get(api)) |provider| return provider;
    }
    return STATIC_BUILTINS.get(api);
}

pub fn getApiCount() usize {
    const static_count: usize = STATIC_BUILTINS.kvs.len;
    return static_count + if (isInitialized()) overrides.count() else 0;
}

pub fn unregister(api: types.Api) void {
    if (!isInitialized()) return;
    _ = overrides.remove(api);
}

pub fn clear() void {
    if (!isInitialized()) return;
    overrides.clearAndFree();
}

pub fn resetForTesting() void {
    if (isInitialized()) {
        overrides.clearAndFree();
    }
    register_builtins.clearProviderOverrides();
}

pub fn resetToBuiltIns() void {
    clear();
}

test "registry basic operations" {
    init();
    defer clear();
    clear();

    const dummy_stream: StreamFunction = struct {
        fn f(_: std.mem.Allocator, io: std.Io, model: types.Model, _: types.Context, _: ?types.StreamOptions) anyerror!event_stream.AssistantMessageEventStream {
            var stream = event_stream.createAssistantMessageEventStream(std.heap.page_allocator, io);
            stream.end(.{
                .content = &[_]types.ContentBlock{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = types.Usage.init(),
                .stop_reason = .stop,
                .timestamp = 0,
            });
            return stream;
        }
    }.f;

    try register(.{
        .api = "custom:test:registry-ops",
        .stream = dummy_stream,
        .stream_simple = dummy_stream,
    });

    try std.testing.expectEqual(STATIC_BUILTINS.kvs.len + 1, getApiCount());

    const provider = get("custom:test:registry-ops");
    try std.testing.expect(provider != null);
    try std.testing.expectEqualStrings("custom:test:registry-ops", provider.?.api);

    const not_found = get("nonexistent");
    try std.testing.expect(not_found == null);

    unregister("custom:test:registry-ops");
    try std.testing.expect(get("custom:test:registry-ops") == null);
}

test "built-in providers are accessible via static map" {
    resetForTesting();
    defer clear();

    try std.testing.expectEqual(register_builtins.expectedBuiltInApiCount(), STATIC_BUILTINS.kvs.len);
    for (register_builtins.expectedBuiltInApis()) |api| {
        try std.testing.expect(get(api) != null);
    }
}

test "clear preserves built-in providers and removes overrides" {
    resetForTesting();
    defer clear();

    const dummy_stream: StreamFunction = struct {
        fn f(_: std.mem.Allocator, io: std.Io, model: types.Model, _: types.Context, _: ?types.StreamOptions) anyerror!event_stream.AssistantMessageEventStream {
            var stream = event_stream.createAssistantMessageEventStream(std.heap.page_allocator, io);
            stream.end(.{
                .content = &[_]types.ContentBlock{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = types.Usage.init(),
                .stop_reason = .stop,
                .timestamp = 0,
            });
            return stream;
        }
    }.f;

    try register(.{
        .api = "custom:test:clear",
        .stream = dummy_stream,
        .stream_simple = dummy_stream,
    });

    clear();

    try std.testing.expect(get("custom:test:clear") == null);
    try std.testing.expect(get("openai-completions") != null);
    try std.testing.expect(get("anthropic-messages") != null);
}

test "resetToBuiltIns clears overrides without rebuilding built-ins" {
    resetForTesting();
    defer clear();

    const dummy_stream: StreamFunction = struct {
        fn f(_: std.mem.Allocator, io: std.Io, model: types.Model, _: types.Context, _: ?types.StreamOptions) anyerror!event_stream.AssistantMessageEventStream {
            var stream = event_stream.createAssistantMessageEventStream(std.heap.page_allocator, io);
            stream.end(.{
                .content = &[_]types.ContentBlock{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = types.Usage.init(),
                .stop_reason = .stop,
                .timestamp = 0,
            });
            return stream;
        }
    }.f;

    try register(.{
        .api = "custom:test:reset",
        .stream = dummy_stream,
        .stream_simple = dummy_stream,
    });

    resetToBuiltIns();

    try std.testing.expect(get("custom:test:reset") == null);
    try std.testing.expectEqual(register_builtins.expectedBuiltInApiCount(), STATIC_BUILTINS.kvs.len);
    try std.testing.expect(get("openai-completions") != null);
    try std.testing.expect(get("bedrock-converse-stream") != null);
}

test "register overrides built-in provider and unregister restores it" {
    resetForTesting();
    defer clear();

    const baseline = get("openai-completions") orelse return error.MissingBuiltIn;

    const overriding_stream: StreamFunction = struct {
        fn f(_: std.mem.Allocator, io: std.Io, model: types.Model, _: types.Context, _: ?types.StreamOptions) anyerror!event_stream.AssistantMessageEventStream {
            var stream = event_stream.createAssistantMessageEventStream(std.heap.page_allocator, io);
            stream.end(.{
                .content = &[_]types.ContentBlock{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = types.Usage.init(),
                .stop_reason = .stop,
                .timestamp = 0,
            });
            return stream;
        }
    }.f;

    try register(.{
        .api = "openai-completions",
        .stream = overriding_stream,
        .stream_simple = overriding_stream,
    });

    const overridden = get("openai-completions").?;
    try std.testing.expect(overridden.stream == overriding_stream);
    try std.testing.expect(overridden.stream != baseline.stream);

    unregister("openai-completions");

    const restored = get("openai-completions").?;
    try std.testing.expect(restored.stream == baseline.stream);
}
