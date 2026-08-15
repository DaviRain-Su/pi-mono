const builtin = @import("builtin");
const std = @import("std");
const agent = @import("agent");
const tui = @import("tui");
const auth = @import("../auth/auth.zig");
const provider_config = @import("../providers/provider_config.zig");
const session_mod = @import("../sessions/session.zig");
const common = @import("../tools/common.zig");
const shared = @import("shared.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");

const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const LiveResources = shared.LiveResources;
const configuredApiKeyForProvider = shared.configuredApiKeyForProvider;
const overrideApiKeyForProvider = shared.overrideApiKeyForProvider;
const SelectorOverlay = overlays.SelectorOverlay;
const AuthFlow = overlays.AuthFlow;
const loadAuthOverlay = overlays.loadAuthOverlay;
const AppState = rendering.AppState;

pub fn handleLoginSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argument: ?[]const u8,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
) !void {
    if (argument) |provider_id| {
        try beginLoginFlow(allocator, io, env_map, provider_id, null, app_state, auth_flow);
        return;
    }
    overlay.* = try loadAuthOverlay(allocator, .login, null);
}

pub fn beginLoginFlow(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
    auth_type: ?auth.ProviderAuthType,
    app_state: *AppState,
    auth_flow: *?AuthFlow,
) !void {
    const provider = if (auth_type) |value|
        auth.findSupportedProviderByAuthType(provider_id, value)
    else
        auth.findSupportedProvider(provider_id);
    if (provider) |resolved_provider| {
        if (auth_flow.*) |*existing| existing.deinit(allocator);
        auth_flow.* = null;

        if (resolved_provider.auth_type == .api_key) {
            const intro = try std.fmt.allocPrint(
                allocator,
                "{s} API key login started. Paste the API key or credential string into the prompt below.",
                .{resolved_provider.name},
            );
            defer allocator.free(intro);
            try app_state.appendInfo(intro);
            try app_state.setStatus("Paste the API key and press Enter, or Esc to cancel");
            auth_flow.* = .{ .api_key = .{
                .provider_id = resolved_provider.id,
                .provider_name = resolved_provider.name,
            } };
            return;
        }

        if (std.mem.eql(u8, resolved_provider.id, "github-copilot")) {
            const copilot = auth.startGitHubCopilotLogin(allocator, io, env_map) catch |err| {
                if (try auth.formatOAuthClientConfigError(allocator, env_map, resolved_provider.id, err)) |message| {
                    defer allocator.free(message);
                    try app_state.appendError(message);
                    return;
                }
                return err;
            };
            openBrowserBestEffort(io, copilot.verification_uri);

            const intro = try std.fmt.allocPrint(
                allocator,
                "GitHub Copilot login started. Open {s} and enter code `{s}`.",
                .{ copilot.verification_uri, copilot.user_code },
            );
            defer allocator.free(intro);
            try app_state.appendInfo(intro);
            try app_state.setStatus("Finish the browser login, then press Enter to complete authentication");
            auth_flow.* = .{ .copilot_device = copilot };
            return;
        }

        var browser_session = auth.startBrowserLogin(allocator, io, env_map, resolved_provider.id) catch |err| {
            if (try auth.formatOAuthClientConfigError(allocator, env_map, resolved_provider.id, err)) |message| {
                defer allocator.free(message);
                try app_state.appendError(message);
                return;
            }
            return err;
        };
        errdefer browser_session.deinit(allocator);

        var callback_listener: ?*auth.OAuthCallbackListener = start_callback_listener_for_session_fn(
            allocator,
            io,
            &browser_session,
        ) catch |err| switch (err) {
            error.AddressInUse, error.AddressUnavailable => null,
            else => return err,
        };
        errdefer if (callback_listener) |listener| listener.destroy();

        openBrowserBestEffort(io, browser_session.auth_url);

        const intro = if (callback_listener) |listener|
            try std.fmt.allocPrint(
                allocator,
                "{s} login started. A local callback listener is waiting at {s}. If the browser cannot reach it, paste the full localhost callback URL into the prompt.",
                .{ resolved_provider.name, listener.redirect_uri },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "{s} login started. Could not start the local callback listener, so paste the full localhost callback URL into the prompt after browser login.",
                .{resolved_provider.name},
            );
        defer allocator.free(intro);
        try app_state.appendInfo(intro);
        try app_state.appendInfo(browser_session.auth_url);
        try app_state.setStatus(if (callback_listener != null)
            "Waiting for localhost callback. You can paste the callback URL manually, or Esc to cancel"
        else
            "Local callback listener unavailable. Paste the callback URL manually, or Esc to cancel");
        auth_flow.* = .{ .browser_redirect = .{
            .session = browser_session,
            .callback_listener = callback_listener,
        } };
        callback_listener = null;
        return;
    }

    const message = try std.fmt.allocPrint(allocator, "Unsupported login provider: {s}", .{provider_id});
    defer allocator.free(message);
    try app_state.appendError(message);
}

fn callbackProviderKind(kind: auth.BrowserLoginKind) auth.OAuthCallbackProviderKind {
    return switch (kind) {
        .anthropic => .anthropic,
        .openai_codex => .openai_codex,
        .xai_oauth => .xai_oauth,
    };
}

fn startCallbackListenerForSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    browser_session: *const auth.BrowserLoginSession,
) !*auth.OAuthCallbackListener {
    var attempts: usize = 0;
    while (attempts < 400) : (attempts += 1) {
        const listener = auth.OAuthCallbackListener.create(
            allocator,
            io,
            callbackProviderKind(browser_session.kind),
            browser_session.state,
        ) catch |err| switch (err) {
            error.AddressInUse, error.AddressUnavailable => {
                std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
                continue;
            },
            else => return err,
        };
        errdefer listener.destroy();
        try listener.start();
        return listener;
    }
    return error.AddressInUse;
}

pub const StartCallbackListenerForSessionFn = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    browser_session: *const auth.BrowserLoginSession,
) anyerror!*auth.OAuthCallbackListener;

pub var start_callback_listener_for_session_fn: StartCallbackListenerForSessionFn = startCallbackListenerForSession;

pub fn cancelAuthFlow(
    allocator: std.mem.Allocator,
    auth_flow: *?AuthFlow,
    app_state: *AppState,
) !void {
    if (auth_flow.*) |*value| {
        value.deinit(allocator);
        auth_flow.* = null;
    }
    try app_state.setStatus("login cancelled");
}

pub fn pollAuthFlowCallback(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    editor: *tui.Editor,
    auth_flow: *?AuthFlow,
    live_resources: *LiveResources,
) !void {
    if (auth_flow.* == null) return;
    switch (auth_flow.*.?) {
        .browser_redirect => |redirect| {
            const listener = redirect.callback_listener orelse return;
            const callback_url = listener.takeCompletedCallbackUrl() orelse return;
            defer allocator.free(callback_url);
            try app_state.setStatus("Received localhost OAuth callback; completing login");
            try submitAuthFlowInput(
                allocator,
                io,
                env_map,
                callback_url,
                session,
                current_provider,
                options,
                app_state,
                editor,
                auth_flow,
                live_resources,
            );
        },
        else => return,
    }
}

pub fn submitAuthFlowInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    trimmed: []const u8,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    editor: *tui.Editor,
    auth_flow: *?AuthFlow,
    live_resources: *LiveResources,
) !void {
    const active = auth_flow.* orelse return;
    switch (active) {
        .browser_redirect => |redirect| {
            if (trimmed.len == 0) {
                try app_state.setStatus("Paste the redirect URL before pressing Enter");
                return;
            }

            switch (redirect.session.kind) {
                .anthropic, .openai_codex, .xai_oauth => {},
            }
            var credential = try auth.completeBrowserLogin(allocator, io, &redirect.session, trimmed);
            defer credential.deinit(allocator);
            try persistLoginCredential(
                allocator,
                io,
                env_map,
                session,
                current_provider,
                redirect.session.provider_id,
                redirect.session.provider_name,
                &credential,
                options,
                app_state,
                auth_flow,
                live_resources,
            );
        },
        .copilot_device => |copilot| {
            var result = try auth.pollGitHubCopilotLogin(allocator, io, &copilot);
            defer result.deinit(allocator);
            switch (result) {
                .pending => |message| {
                    try app_state.setStatus(message);
                    return;
                },
                .completed => |oauth_credential| {
                    var credential = auth.StoredCredential{ .oauth = .{
                        .access = try allocator.dupe(u8, oauth_credential.access),
                        .refresh = try allocator.dupe(u8, oauth_credential.refresh),
                        .expires = oauth_credential.expires,
                    } };
                    defer credential.deinit(allocator);
                    try persistLoginCredential(
                        allocator,
                        io,
                        env_map,
                        session,
                        current_provider,
                        copilot.provider_id,
                        copilot.provider_name,
                        &credential,
                        options,
                        app_state,
                        auth_flow,
                        live_resources,
                    );
                },
            }
        },
        .api_key => |api_key_prompt| {
            if (trimmed.len == 0) {
                try app_state.setStatus("Paste the API key before pressing Enter");
                return;
            }

            var credential = auth.StoredCredential{
                .api_key = try allocator.dupe(u8, trimmed),
            };
            defer credential.deinit(allocator);
            try persistLoginCredential(
                allocator,
                io,
                env_map,
                session,
                current_provider,
                api_key_prompt.provider_id,
                api_key_prompt.provider_name,
                &credential,
                options,
                app_state,
                auth_flow,
                live_resources,
            );
        },
    }

    editor.reset();
}

pub fn persistLoginCredential(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    provider_id: []const u8,
    provider_name: []const u8,
    credential: *const auth.StoredCredential,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    auth_flow: *?AuthFlow,
    live_resources: *LiveResources,
) !void {
    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("Authentication storage is unavailable in this session");
        return;
    };

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    try auth.upsertStoredCredential(allocator, io, auth_path, provider_id, credential);

    if (auth_flow.*) |*value| value.deinit(allocator);
    auth_flow.* = null;

    _ = try live_resources.reload(allocator, io, env_map, options.cwd);

    if (std.mem.eql(u8, session.agent.getModel().provider, provider_id)) {
        const resolved = provider_config.resolveProviderConfig(
            allocator,
            io,
            env_map,
            provider_id,
            session.agent.getModel().id,
            overrideApiKeyForProvider(options, provider_id),
            configuredApiKeyForProvider(live_resources.runtime_config, provider_id),
        ) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Saved credentials for {s}, but could not activate them: {s}", .{
                provider_name,
                provider_config.resolveProviderErrorMessage(err, provider_id),
            });
            defer allocator.free(message);
            try app_state.appendError(message);
            return;
        };
        current_provider.deinit(allocator);
        current_provider.* = resolved;
        session.agent.setModel(resolved.model);
        session.setApiKey(resolved.api_key);
    }

    const message = try std.fmt.allocPrint(allocator, "Logged in to {s}. Credentials saved to {s}.", .{ provider_name, auth_path });
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("logged in");
}

pub const OpenBrowserFn = *const fn (context: ?*anyopaque, io: std.Io, url: []const u8) void;

pub var open_browser_context: ?*anyopaque = null;
pub var open_browser_fn: OpenBrowserFn = defaultOpenBrowserBestEffort;

pub fn openBrowserBestEffort(io: std.Io, url: []const u8) void {
    open_browser_fn(open_browser_context, io, url);
}

pub fn defaultOpenBrowserBestEffort(_: ?*anyopaque, io: std.Io, url: []const u8) void {
    const argv = switch (builtin.os.tag) {
        .macos => [_][]const u8{ "open", url },
        .windows => [_][]const u8{ "cmd", "/c", "start", url },
        else => [_][]const u8{ "xdg-open", url },
    };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

pub var test_auth_flow: ?AuthFlow = null;

pub const BrowserOpenCapture = struct {
    called: bool = false,
    url: ?[]const u8 = null,

    pub fn capture(context: ?*anyopaque, _: std.Io, url: []const u8) void {
        const self: *BrowserOpenCapture = @ptrCast(@alignCast(context.?));
        self.called = true;
        self.url = url;
    }
};

pub fn handleLogoutSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    argument: ?[]const u8,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("Logout is unavailable in this session");
        return;
    };

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    if (argument) |provider_id| {
        try logoutProviderById(
            allocator,
            io,
            env_map,
            session,
            current_provider,
            provider_id,
            options,
            app_state,
            live_resources,
        );
        return;
    }

    const providers = try auth.listStoredProviders(allocator, io, auth_path);
    defer allocator.free(providers);
    if (providers.len == 0) {
        try app_state.setStatus("No providers logged in. Use /login first.");
        return;
    }

    overlay.* = try loadAuthOverlay(allocator, .logout, providers);
}

pub fn logoutProviderById(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    provider_name: []const u8,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    live_resources: *LiveResources,
) !void {
    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("Logout is unavailable in this session");
        return;
    };

    const model_id = try allocator.dupe(u8, session.agent.getModel().id);
    defer allocator.free(model_id);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    const removed = try auth.removeStoredCredential(allocator, io, auth_path, provider_name);
    const affects_current_provider = std.mem.eql(u8, session.agent.getModel().provider, provider_name);
    if (affects_current_provider) {
        try clearResolvedProviderApiKey(allocator, current_provider);
        session.setApiKey(null);
    }

    _ = try live_resources.reload(allocator, io, env_map, options.cwd);

    if (affects_current_provider) {
        const resolved = provider_config.resolveProviderConfig(
            allocator,
            io,
            env_map,
            provider_name,
            model_id,
            overrideApiKeyForProvider(options, provider_name),
            configuredApiKeyForProvider(live_resources.runtime_config, provider_name),
        ) catch |err| switch (err) {
            error.MissingApiKey => null,
            else => return err,
        };

        if (resolved) |next_provider| {
            current_provider.deinit(allocator);
            current_provider.* = next_provider;
            session.agent.setModel(next_provider.model);
            session.setApiKey(next_provider.api_key);
        }
    }

    const message = if (removed)
        try std.fmt.allocPrint(allocator, "Removed stored authentication for provider `{s}`.", .{provider_name})
    else
        try std.fmt.allocPrint(allocator, "No stored authentication found for provider `{s}`.", .{provider_name});
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("logged out");
}

pub fn clearResolvedProviderApiKey(
    allocator: std.mem.Allocator,
    current_provider: *provider_config.ResolvedProviderConfig,
) !void {
    if (current_provider.owned_api_key) |api_key| allocator.free(api_key);
    current_provider.owned_api_key = null;
    current_provider.api_key = null;
}

pub fn removeStoredAuthToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    provider_name: []const u8,
) !bool {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, auth_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    var next_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const next_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, next_value);
    }

    var removed = false;
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, provider_name)) {
            removed = true;
            continue;
        }
        try next_object.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            try common.cloneJsonValue(allocator, entry.value_ptr.*),
        );
    }
    if (!removed) {
        const next_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, next_value);
        return false;
    }

    const next_value: std.json.Value = .{ .object = next_object };
    defer common.deinitJsonValue(allocator, next_value);

    const serialized = try std.json.Stringify.valueAlloc(allocator, next_value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, auth_path, serialized, true);
    return true;
}
