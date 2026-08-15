const session_mod = @import("../sessions/session.zig");

pub fn installSessionUiCallbacks(
    session: *session_mod.AgentSession,
    retry_callback: session_mod.RetryLifecycleCallback,
    compaction_callback: session_mod.CompactionLifecycleCallback,
) void {
    session.setRetryLifecycleCallback(retry_callback);
    session.setCompactionLifecycleCallback(compaction_callback);
}

pub fn clearSessionUiCallbacks(session: *session_mod.AgentSession) void {
    session.clearRetryLifecycleCallback();
    session.clearCompactionLifecycleCallback();
}

test "installSessionUiCallbacks sets and clears lifecycle handlers" {
    const allocator = @import("std").testing.allocator;
    const std = @import("std");
    const provider_config = @import("../providers/provider_config.zig");

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/hooks-test",
        .system_prompt = "sys",
        .model = provider.model,
        .api_key = provider.api_key,
    });
    defer session.deinit();

    const RetryFixture = struct {
        fn callback(context: ?*anyopaque, event: session_mod.RetryLifecycleEvent) anyerror!void {
            _ = context;
            _ = event;
        }
    };
    const CompactionFixture = struct {
        fn callback(context: ?*anyopaque, event: session_mod.CompactionLifecycleEvent) anyerror!void {
            _ = context;
            _ = event;
        }
    };

    installSessionUiCallbacks(
        &session,
        .{ .callback = RetryFixture.callback },
        .{ .callback = CompactionFixture.callback },
    );
    clearSessionUiCallbacks(&session);
}
