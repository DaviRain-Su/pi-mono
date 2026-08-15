const std = @import("std");
const ai = @import("ai");
const coding_agent = @import("coding_agent");
const auth = coding_agent.auth;
const common = coding_agent.tools.common;
const config_mod = coding_agent.config_impl;
const cli = @import("args.zig");
const auth_command = @import("auth_command.zig");
const model_resolver = @import("model_resolver.zig");

const AuthCommandKind = auth_command.AuthCommandKind;

pub fn dispatchAuthCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !?u8 {
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], "auth")) return null;
    if (auth_command.isAuthCommandHelp(argv)) {
        try auth_command.printAuthCommandHelp(stdout);
        return 0;
    }

    var command = auth_command.parseAuthCommand(allocator, argv) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try stderr.print("Error: {s}\n", .{auth_command.parseAuthCommandErrorMessage(err, argv)});
            return 1;
        },
    } orelse return null;
    defer command.deinit(allocator);

    var parsed = cli.parseArgs(allocator, command.args) catch |err| {
        try stderr.print("Error: {s}\n", .{parseArgsErrorMessage(err)});
        return if (command.kind == .check) 2 else 1;
    };
    defer parsed.deinit(allocator);

    if (parsed.unknown_flags) |flags| {
        if (flags.len > 0) {
            try stderr.print("Unknown option --{s} for \"{s}\".\n", .{ flags[0].name, auth_command.getAuthCommandName(command.kind) });
            try stderr.print("Use \"pi --help\" or \"{s}\".\n", .{auth_command.getAuthCommandUsage(command.kind)});
            return 1;
        }
    }

    const requested = auth_command.validateAuthCommandArgs(&parsed, command.kind) catch |err| {
        try stderr.print("Error: {s}\n", .{validateErrorMessage(err, command.kind)});
        return if (command.kind == .check) 2 else 1;
    };

    const provider = try resolveProviderId(allocator, requested.provider, requested.model) orelse {
        if (requested.provider) |provider_id| {
            if (command.kind == .check) {
                return try writeCheckResult(stdout, command, .{
                    .status = .not_ready,
                    .provider = provider_id,
                    .reason = "provider_not_found",
                }, null);
            }
            try stderr.print("Error: Unknown provider \"{s}\". Use --list-models to see available providers.\n", .{provider_id});
            return 1;
        }
        try stderr.print("Error: Model \"{s}\" not found. Use --list-models to see available models.\n", .{requested.model.?});
        return if (command.kind == .check) 2 else 1;
    };
    defer allocator.free(provider);

    const agent_dir = try config_mod.resolveAgentDir(allocator, env_map);
    defer allocator.free(agent_dir);
    const auth_path = try std.fs.path.join(allocator, &.{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    return switch (command.kind) {
        .api_key, .bearer_token => try printCredential(
            allocator,
            io,
            env_map,
            auth_path,
            provider,
            command.kind,
            command.min_expiry_ms,
            stdout,
            stderr,
        ),
        .check => try runAuthCheck(
            allocator,
            io,
            env_map,
            auth_path,
            provider,
            command,
            stdout,
        ),
    };
}

const CheckStatus = enum { ready, not_ready, invalid };

const CheckResult = struct {
    status: CheckStatus,
    provider: []const u8,
    reason: ?[]const u8 = null,
    auth_type: ?[]const u8 = null,
};

fn printCredential(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    auth_path: []const u8,
    provider: []const u8,
    kind: AuthCommandKind,
    min_expiry_ms: ?u64,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    _ = min_expiry_ms;
    var stored = try loadStoredEntry(allocator, io, auth_path, provider);
    defer if (stored) |*value| value.deinit(allocator);

    const stored_type = if (stored) |value| storedAuthType(value.entry) else null;
    if (kind == .api_key and stored_type == .oauth) {
        try stderr.print("Error: Provider \"{s}\" is configured with OAuth, not an API key\n", .{provider});
        return 1;
    }
    if (kind == .bearer_token and stored_type != .oauth) {
        try stderr.print("Error: Provider \"{s}\" is not configured with an OAuth bearer token\n", .{provider});
        return 1;
    }

    if (kind == .api_key) {
        const stored_key = if (stored) |value| auth.buildApiKeyFromStoredEntry(allocator, provider, value.entry) catch null else null;
        defer if (stored_key) |key| allocator.free(key);
        const resolved = try auth.resolveApiKey(allocator, io, env_map, provider, null, if (stored_key) |key| key else null);
        defer if (resolved) |value| {
            if (value.owned_api_key) |owned| allocator.free(owned);
        };
        if (resolved) |value| {
            try stdout.print("{s}\n", .{value.api_key});
            return 0;
        }
        try stderr.writeAll("Error: No usable API key is configured\n");
        return 1;
    }

    if (stored) |value| {
        const token = try auth.buildApiKeyFromStoredEntryRefreshing(allocator, io, env_map, auth_path, provider, value.entry);
        if (token) |access| {
            defer allocator.free(access);
            try stdout.print("{s}\n", .{access});
            return 0;
        }
    }
    try stderr.writeAll("Error: No usable OAuth bearer token is configured\n");
    return 1;
}

fn runAuthCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    auth_path: []const u8,
    provider: []const u8,
    command: auth_command.AuthCommand,
    stdout: *std.Io.Writer,
) !u8 {
    if (ai.provider_info.providerInfoFor(provider) == null) {
        return writeCheckResult(stdout, command, .{
            .status = .not_ready,
            .provider = provider,
            .reason = "provider_not_found",
        }, null);
    }

    var stored = try loadStoredEntry(allocator, io, auth_path, provider);
    defer if (stored) |*value| value.deinit(allocator);
    const stored_type = if (stored) |value| storedAuthType(value.entry) else null;

    const env_key = try auth.resolveApiKey(allocator, io, env_map, provider, null, null);
    defer if (env_key) |value| {
        if (value.owned_api_key) |owned| allocator.free(owned);
    };

    if (stored_type == null and env_key == null) {
        return writeCheckResult(stdout, command, .{
            .status = .not_ready,
            .provider = provider,
            .reason = "credentials_not_configured",
        }, null);
    }

    const auth_type: []const u8 = if (stored_type) |value|
        switch (value) {
            .oauth => "oauth",
            .api_key => "api_key",
        }
    else
        "api_key";

    var credential: ?[]u8 = null;
    defer if (credential) |value| allocator.free(value);
    if (command.credentials) {
        if (stored) |value| {
                credential = if (command.no_refresh)
                try auth.buildApiKeyFromStoredEntry(allocator, provider, value.entry)
            else
                try auth.buildApiKeyFromStoredEntryRefreshing(allocator, io, env_map, auth_path, provider, value.entry);
        } else if (env_key) |value| {
            credential = try allocator.dupe(u8, value.api_key);
        }
        if (credential == null) {
            return writeCheckResult(stdout, command, .{
                .status = .not_ready,
                .provider = provider,
                .reason = "credential_not_available",
            }, null);
        }
    }

    return writeCheckResult(stdout, command, .{
        .status = .ready,
        .provider = provider,
        .auth_type = auth_type,
    }, credential);
}

fn writeCheckResult(
    stdout: *std.Io.Writer,
    command: auth_command.AuthCommand,
    result: CheckResult,
    credential: ?[]const u8,
) !u8 {
    if (command.json) {
        try stdout.writeAll("{\"status\":\"");
        try stdout.writeAll(@tagName(result.status));
        try stdout.writeAll("\",\"provider\":");
        try writeJsonString(stdout, result.provider);
        if (result.reason) |reason| {
            try stdout.writeAll(",\"reason\":");
            try writeJsonString(stdout, reason);
        }
        if (result.auth_type) |auth_type| {
            try stdout.writeAll(",\"authType\":");
            try writeJsonString(stdout, auth_type);
        }
        if (credential) |value| {
            try stdout.writeAll(",\"credentials\":");
            try writeJsonString(stdout, value);
        }
        try stdout.writeAll("}\n");
    } else if (credential) |value| {
        try stdout.print("{s}\n", .{value});
    } else {
        try stdout.print("{s}\n", .{@tagName(result.status)});
    }
    return switch (result.status) {
        .ready => 0,
        .not_ready => 1,
        .invalid => 2,
    };
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn resolveProviderId(
    allocator: std.mem.Allocator,
    cli_provider: ?[]const u8,
    cli_model: ?[]const u8,
) !?[]u8 {
    if (cli_provider) |provider| {
        if (ai.provider_info.providerInfoFor(provider) != null) {
            return @as(?[]u8, try allocator.dupe(u8, provider));
        }
        if (cli_model == null) return null;
    }
    if (cli_model) |model| {
        var resolved = try model_resolver.resolveCliModel(allocator, cli_provider, model);
        defer resolved.deinit(allocator);
        if (resolved.error_message != null or resolved.provider_name == null) return null;
        return @as(?[]u8, try allocator.dupe(u8, resolved.provider_name.?));
    }
    return null;
}

const StoredLookup = struct {
    file: std.json.Value,
    entry: std.json.ObjectMap,

    fn deinit(self: *StoredLookup, allocator: std.mem.Allocator) void {
        common.deinitJsonValue(allocator, self.file);
        self.* = undefined;
    }
};

fn loadStoredEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    provider: []const u8,
) !?StoredLookup {
    const stored = try auth.readStoredCredentialsObject(allocator, io, auth_path);
    if (stored != .object) {
        common.deinitJsonValue(allocator, stored);
        return null;
    }
    const entry = stored.object.get(provider) orelse {
        common.deinitJsonValue(allocator, stored);
        return null;
    };
    if (entry != .object) {
        common.deinitJsonValue(allocator, stored);
        return null;
    }
    return .{ .file = stored, .entry = entry.object };
}

fn storedAuthType(object: std.json.ObjectMap) ?auth.ProviderAuthType {
    const type_value = if (object.get("type")) |value|
        switch (value) {
            .string => |text| text,
            else => null,
        }
    else
        null;
    if (type_value) |text| {
        if (std.mem.eql(u8, text, "oauth")) return .oauth;
        if (std.mem.eql(u8, text, "api_key")) return .api_key;
    }
    if (object.get("key") != null) return .api_key;
    return null;
}

fn parseArgsErrorMessage(err: cli.ParseArgsError) []const u8 {
    return switch (err) {
        error.UnknownOption => "Auth commands only accept --provider and --model",
        error.MissingOptionValue => "Missing option value",
        error.InvalidMode, error.InvalidThinkingLevel, error.InvalidTuiMode => "Invalid option value",
        error.OutOfMemory => "Out of memory",
    };
}

fn validateErrorMessage(err: auth_command.AuthCommandError, kind: AuthCommandKind) []const u8 {
    return switch (err) {
        error.MissingProviderOrModel => if (kind == .check)
            "Auth checks require --provider <provider> or --model <model>"
        else
            "Credential printing requires --provider <provider> or --model <model>",
        error.UnexpectedAuthArgs => "Auth commands only accept --provider and --model",
        else => auth_command.parseAuthCommandErrorMessage(err, &.{}),
    };
}

test "dispatchAuthCommand prints a stored API key" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data = "{\"openai\":{\"type\":\"api_key\",\"key\":\"test-api-key\"}}\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const agent_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "agent" });
    defer allocator.free(agent_rel);
    const agent_dir = try std.fs.path.resolve(allocator, &.{ cwd, agent_rel });
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const code = try dispatchAuthCommand(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "auth", "print-api-key", "--provider", "openai" },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code.?);
    try std.testing.expectEqualStrings("test-api-key\n", stdout_capture.writer.buffered());
}

test "dispatchAuthCommand help does not require credentials" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    const code = try dispatchAuthCommand(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "auth", "--help" },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code.?);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "pi auth print-api-key") != null);
}
