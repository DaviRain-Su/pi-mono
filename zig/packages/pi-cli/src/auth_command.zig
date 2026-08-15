const std = @import("std");
const cli = @import("args.zig");

pub const DEFAULT_BEARER_TOKEN_MIN_EXPIRY_MS: u64 = 30 * 60_000;

pub const AuthCommandKind = enum {
    check,
    api_key,
    bearer_token,
};

pub const AuthCommand = struct {
    kind: AuthCommandKind,
    args: []const []const u8,
    json: bool = false,
    credentials: bool = false,
    no_refresh: bool = false,
    min_expiry_ms: ?u64 = null,
    args_owned: bool = false,

    pub fn deinit(self: *AuthCommand, allocator: std.mem.Allocator) void {
        if (self.args_owned and self.args.len > 0) allocator.free(self.args);
        self.* = undefined;
    }
};

pub const AuthCommandError = error{
    UnknownAuthCommand,
    InvalidAuthOption,
    InvalidMinExpiry,
    MissingProviderOrModel,
    UnexpectedAuthArgs,
};

pub fn getAuthCommandName(kind: AuthCommandKind) []const u8 {
    return switch (kind) {
        .check => "auth check",
        .api_key => "auth print-api-key",
        .bearer_token => "auth print-bearer-token",
    };
}

pub fn getAuthCommandUsage(kind: AuthCommandKind) []const u8 {
    return switch (kind) {
        .check => "pi auth check --provider <provider> [--json] [--credentials] [--no-refresh]",
        .api_key => "pi auth print-api-key --provider <provider> [--model <model>]",
        .bearer_token => "pi auth print-bearer-token --provider <provider> [--model <model>] [--min-expiry <duration>]",
    };
}

pub fn isAuthCommandHelp(args: []const []const u8) bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "auth")) return false;
    if (args.len == 1) return true;
    if (std.mem.eql(u8, args[1], "help")) return true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

pub fn printAuthCommandHelp(stdout: *std.Io.Writer) !void {
    try stdout.writeAll(
        \\Usage:
        \\  pi auth print-api-key [--provider <provider>] [--model <model>]
        \\  pi auth print-bearer-token [--provider <provider>] [--model <model>] [--min-expiry <duration>]
        \\  pi auth check [--provider <provider>] [--model <model>] [--json] [--credentials] [--no-refresh]
        \\
        \\Auth commands require at least one of --provider or --model. Checks refresh expired OAuth credentials by default; --no-refresh prevents this. --credentials emits the credential, or includes it in JSON output.
    );
}

pub fn parseAuthCommand(allocator: std.mem.Allocator, args: []const []const u8) !?AuthCommand {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "auth")) return null;
    if (args.len < 2) return error.UnknownAuthCommand;

    const kind: AuthCommandKind = if (std.mem.eql(u8, args[1], "check"))
        .check
    else if (std.mem.eql(u8, args[1], "print-api-key"))
        .api_key
    else if (std.mem.eql(u8, args[1], "print-bearer-token"))
        .bearer_token
    else
        return error.UnknownAuthCommand;

    var command_args = std.ArrayList([]const u8).empty;
    errdefer command_args.deinit(allocator);
    var json = false;
    var credentials = false;
    var no_refresh = false;
    var min_expiry_ms: ?u64 = null;

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--min-expiry")) {
            if (kind != .bearer_token) return error.InvalidAuthOption;
            index += 1;
            if (index >= args.len) return error.InvalidMinExpiry;
            min_expiry_ms = parseMinExpiry(args[index]) orelse return error.InvalidMinExpiry;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--credentials") or std.mem.eql(u8, arg, "--no-refresh")) {
            if (kind != .check) return error.InvalidAuthOption;
            if (std.mem.eql(u8, arg, "--json")) json = true;
            if (std.mem.eql(u8, arg, "--credentials")) credentials = true;
            if (std.mem.eql(u8, arg, "--no-refresh")) no_refresh = true;
            continue;
        }
        try command_args.append(allocator, arg);
    }

    return .{
        .kind = kind,
        .args = try command_args.toOwnedSlice(allocator),
        .json = json,
        .credentials = credentials,
        .no_refresh = no_refresh,
        .min_expiry_ms = min_expiry_ms,
        .args_owned = true,
    };
}

pub fn parseAuthCommandErrorMessage(err: anyerror, args: []const []const u8) []const u8 {
    return switch (err) {
        error.UnknownAuthCommand => "Unknown auth command. Use \"pi auth print-api-key\", \"pi auth print-bearer-token\", or \"pi auth check\".",
        error.InvalidAuthOption => invalidOptionMessage(args),
        error.InvalidMinExpiry => "--min-expiry must use a duration such as 30m or 1h",
        error.MissingProviderOrModel => "Auth commands require --provider <provider> or --model <model>",
        error.UnexpectedAuthArgs => "Auth commands only accept --provider and --model",
        else => "Failed to parse auth command",
    };
}

fn invalidOptionMessage(args: []const []const u8) []const u8 {
    if (args.len >= 2 and std.mem.eql(u8, args[1], "print-api-key")) {
        return "--min-expiry is only supported by print-bearer-token";
    }
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--min-expiry")) return "--min-expiry is only supported by print-bearer-token";
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--credentials") or std.mem.eql(u8, arg, "--no-refresh")) {
            return "option is only supported by auth check";
        }
    }
    return "option is only supported by auth check";
}

pub fn validateAuthCommandArgs(args: *const cli.Args, kind: AuthCommandKind) AuthCommandError!struct { provider: ?[]const u8, model: ?[]const u8 } {
    if (args.unknown_flags) |flags| {
        if (flags.len > 0) return error.InvalidAuthOption;
    }
    if (args.api_key != null or (args.messages != null and args.messages.?.len > 0) or (args.file_args != null and args.file_args.?.len > 0)) {
        return error.UnexpectedAuthArgs;
    }
    const provider = trimOptional(args.provider);
    const model = trimOptional(args.model);
    if (provider == null and model == null) return error.MissingProviderOrModel;
    _ = kind;
    return .{ .provider = provider, .model = model };
}

fn trimOptional(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn parseMinExpiry(value: []const u8) ?u64 {
    if (value.len < 2) return null;
    var unit_len: usize = 1;
    if (std.mem.endsWith(u8, value, "ms")) unit_len = 2;
    const amount_text = value[0 .. value.len - unit_len];
    const unit = value[value.len - unit_len ..];
    const amount = std.fmt.parseInt(u64, amount_text, 10) catch return null;
    if (std.mem.eql(u8, unit, "ms")) return amount;
    if (std.mem.eql(u8, unit, "s")) return amount * 1_000;
    if (std.mem.eql(u8, unit, "m")) return amount * 60_000;
    if (std.mem.eql(u8, unit, "h")) return amount * 3_600_000;
    return null;
}

test "parseAuthCommand accepts print and check variants" {
    const allocator = std.testing.allocator;
    var api_key = (try parseAuthCommand(allocator, &.{ "auth", "print-api-key", "--provider", "openai" })).?;
    defer api_key.deinit(allocator);
    try std.testing.expectEqual(AuthCommandKind.api_key, api_key.kind);
    try std.testing.expectEqual(@as(usize, 2), api_key.args.len);
    try std.testing.expectEqualStrings("--provider", api_key.args[0]);
    try std.testing.expect(!api_key.json);

    var bearer = (try parseAuthCommand(allocator, &.{ "auth", "print-bearer-token", "--min-expiry", "30m" })).?;
    defer bearer.deinit(allocator);
    try std.testing.expectEqual(AuthCommandKind.bearer_token, bearer.kind);
    try std.testing.expectEqual(@as(u64, 30 * 60_000), bearer.min_expiry_ms.?);

    var check = (try parseAuthCommand(allocator, &.{ "auth", "check", "--provider", "openai", "--json", "--credentials", "--no-refresh" })).?;
    defer check.deinit(allocator);
    try std.testing.expectEqual(AuthCommandKind.check, check.kind);
    try std.testing.expect(check.json);
    try std.testing.expect(check.credentials);
    try std.testing.expect(check.no_refresh);
    try std.testing.expectEqual(@as(usize, 2), check.args.len);
}

test "parseAuthCommand rejects options on the wrong subcommand" {
    try std.testing.expectError(error.InvalidAuthOption, parseAuthCommand(std.testing.allocator, &.{ "auth", "print-api-key", "--min-expiry", "30m" }));
    try std.testing.expectError(error.InvalidAuthOption, parseAuthCommand(std.testing.allocator, &.{ "auth", "print-api-key", "--json" }));
    try std.testing.expectError(error.UnknownAuthCommand, parseAuthCommand(std.testing.allocator, &.{ "auth", "unknown" }));
    try std.testing.expect(try parseAuthCommand(std.testing.allocator, &.{ "--provider", "openai" }) == null);
}

test "isAuthCommandHelp matches TS help surfaces" {
    try std.testing.expect(isAuthCommandHelp(&.{"auth"}));
    try std.testing.expect(isAuthCommandHelp(&.{ "auth", "--help" }));
    try std.testing.expect(isAuthCommandHelp(&.{ "auth", "print-api-key", "--help" }));
    try std.testing.expect(isAuthCommandHelp(&.{ "auth", "print-bearer-token", "-h" }));
    try std.testing.expect(isAuthCommandHelp(&.{ "auth", "check", "--help" }));
    try std.testing.expect(!isAuthCommandHelp(&.{ "auth", "check", "--provider", "openai" }));
}

test "validateAuthCommandArgs requires provider or model" {
    var empty = cli.Args{};
    try std.testing.expectError(error.MissingProviderOrModel, validateAuthCommandArgs(&empty, .api_key));
    var with_provider = cli.Args{ .provider = "openai" };
    const resolved = try validateAuthCommandArgs(&with_provider, .api_key);
    try std.testing.expectEqualStrings("openai", resolved.provider.?);
}
