const std = @import("std");
const package_settings_store = @import("package_settings_store.zig");

/// Focused parser for package-management subcommands. Execution, config IO,
/// self-update, and package resource mutation stay in `package_manager.zig`.
pub const PackageCommand = enum { install, remove, update, list, config };

pub const ConfigKind = package_settings_store.ConfigKind;

pub const ConfigToggleAction = enum { enable, disable };

pub const ConfigOptions = struct {
    /// When set, the config command performs a deterministic
    /// non-interactive toggle (used by tests and CLI parity); when
    /// absent, the command prints a deterministic listing and usage.
    toggle_kind: ?ConfigKind = null,
    toggle_pattern: ?[]u8 = null,
    toggle_action: ConfigToggleAction = .enable,

    fn deinit(self: *ConfigOptions, allocator: std.mem.Allocator) void {
        if (self.toggle_pattern) |value| allocator.free(value);
        self.* = .{};
    }
};

pub const UpdateTarget = union(enum) {
    all,
    self,
    /// --extensions flag: update all extensions (skip self-update).
    extensions,
    source: []const u8,
};

pub const ParsedCommand = struct {
    command: PackageCommand,
    /// Original positional source for install/remove. For update with a
    /// positional non-self target, this is also populated. Owned by the
    /// command parser; freed with `deinit`.
    source: ?[]u8 = null,
    update_target: ?UpdateTarget = null,
    config_options: ConfigOptions = .{},
    local: bool = false,
    force: bool = false,
    help: bool = false,
    /// True when self-update is included in an .all target (i.e. the user
    /// passed --self alongside --extensions or used `pi update self --extensions`).
    /// Used by executeUpdate(.all) to decide whether to also run self-update.
    update_self: bool = false,
    /// First parse-time diagnostic, if any. Mirrors TS where parse
    /// errors are reported as a single line followed by usage.
    parse_error: ?[]u8 = null,

    pub fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        if (self.source) |value| allocator.free(value);
        if (self.parse_error) |value| allocator.free(value);
        self.config_options.deinit(allocator);
        self.* = .{ .command = .install };
    }
};

pub const ParseError = error{
    NotPackageCommand,
} || std.mem.Allocator.Error;

/// Returns true if the first argv token is a recognized package
/// subcommand: `install`, `remove`, `uninstall`, `update`, or `list`.
/// Used by the main entry point to decide whether to dispatch into the
/// package manager before normal CLI argument processing.
pub fn isPackageCommand(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const first = args[0];
    return std.mem.eql(u8, first, "install") or
        std.mem.eql(u8, first, "remove") or
        std.mem.eql(u8, first, "uninstall") or
        std.mem.eql(u8, first, "update") or
        std.mem.eql(u8, first, "list") or
        std.mem.eql(u8, first, "config");
}

/// Parse a `pi <subcommand> [args...]` invocation. Returns
/// `ParseError.NotPackageCommand` if `args[0]` is not a recognized
/// package subcommand. Otherwise the returned `ParsedCommand` always
/// represents a parseable command; argument-level errors are surfaced
/// through `ParsedCommand.parse_error` so the caller can render them
/// alongside usage text in a single non-zero-exit code path.
pub fn parsePackageCommand(allocator: std.mem.Allocator, args: []const []const u8) ParseError!ParsedCommand {
    if (args.len == 0) return error.NotPackageCommand;
    const raw = args[0];
    var command: PackageCommand = undefined;
    if (std.mem.eql(u8, raw, "install")) {
        command = .install;
    } else if (std.mem.eql(u8, raw, "remove") or std.mem.eql(u8, raw, "uninstall")) {
        command = .remove;
    } else if (std.mem.eql(u8, raw, "update")) {
        command = .update;
    } else if (std.mem.eql(u8, raw, "list")) {
        command = .list;
    } else if (std.mem.eql(u8, raw, "config")) {
        command = .config;
    } else {
        return error.NotPackageCommand;
    }

    var result: ParsedCommand = .{ .command = command };
    errdefer result.deinit(allocator);

    var positional_owned: ?[]u8 = null;
    errdefer if (positional_owned) |value| allocator.free(value);

    // Tracks --toggle <kind> <pattern> for `pi config`. Both args must be
    // present and the kind must resolve before the positional pattern is
    // accepted.
    var saw_toggle_flag = false;
    var pending_toggle_kind: ?ConfigKind = null;
    var pending_toggle_pattern_owned: ?[]u8 = null;
    errdefer if (pending_toggle_pattern_owned) |value| allocator.free(value);

    // Tracks --self, --extensions, --extension <source> for `pi update`.
    var saw_self_flag = false;
    var saw_extensions_flag = false;
    var saw_extension_source_owned: ?[]u8 = null;
    errdefer if (saw_extension_source_owned) |value| allocator.free(value);

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--local")) {
            if (command == .install or command == .remove or command == .config) {
                result.local = true;
            } else {
                if (result.parse_error == null) {
                    result.parse_error = try std.fmt.allocPrint(
                        allocator,
                        "Unknown option {s} for \"{s}\".",
                        .{ arg, packageCommandName(command) },
                    );
                }
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            if (command == .update) {
                result.force = true;
            } else {
                if (result.parse_error == null) {
                    result.parse_error = try std.fmt.allocPrint(
                        allocator,
                        "Unknown option {s} for \"{s}\".",
                        .{ arg, packageCommandName(command) },
                    );
                }
            }
            continue;
        }
        if (command == .config and std.mem.eql(u8, arg, "--toggle")) {
            saw_toggle_flag = true;
            const kind_arg_index = index + 1;
            const pattern_arg_index = index + 2;
            if (pattern_arg_index >= args.len) {
                if (result.parse_error == null) {
                    result.parse_error = try allocator.dupe(
                        u8,
                        "--toggle requires <kind> and <pattern> arguments.",
                    );
                }
                index = args.len; // stop scanning further
                continue;
            }
            const kind_arg = args[kind_arg_index];
            const pattern_arg = args[pattern_arg_index];
            const kind = ConfigKind.fromString(kind_arg) orelse {
                if (result.parse_error == null) {
                    result.parse_error = try std.fmt.allocPrint(
                        allocator,
                        "Unknown --toggle kind {s}. Expected extensions, skills, prompts, or themes.",
                        .{kind_arg},
                    );
                }
                index = pattern_arg_index;
                continue;
            };
            pending_toggle_kind = kind;
            if (pending_toggle_pattern_owned) |value| allocator.free(value);
            pending_toggle_pattern_owned = try allocator.dupe(u8, pattern_arg);
            index = pattern_arg_index;
            continue;
        }
        if (command == .config and (std.mem.eql(u8, arg, "--enable") or std.mem.eql(u8, arg, "--disable"))) {
            result.config_options.toggle_action = if (std.mem.eql(u8, arg, "--enable"))
                .enable
            else
                .disable;
            continue;
        }
        if (std.mem.eql(u8, arg, "--self")) {
            if (command == .update) {
                saw_self_flag = true;
            } else {
                if (result.parse_error == null) {
                    result.parse_error = try std.fmt.allocPrint(
                        allocator,
                        "Unknown option {s} for \"{s}\".",
                        .{ arg, packageCommandName(command) },
                    );
                }
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--extensions")) {
            if (command == .update) {
                saw_extensions_flag = true;
            } else {
                if (result.parse_error == null) {
                    result.parse_error = try std.fmt.allocPrint(
                        allocator,
                        "Unknown option {s} for \"{s}\".",
                        .{ arg, packageCommandName(command) },
                    );
                }
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--extension")) {
            if (command != .update) {
                if (result.parse_error == null) {
                    result.parse_error = try std.fmt.allocPrint(
                        allocator,
                        "Unknown option {s} for \"{s}\".",
                        .{ arg, packageCommandName(command) },
                    );
                }
                continue;
            }
            const next_index = index + 1;
            if (next_index >= args.len or std.mem.startsWith(u8, args[next_index], "-")) {
                if (result.parse_error == null) {
                    result.parse_error = try allocator.dupe(u8, "Missing value for --extension.");
                }
                continue;
            }
            if (saw_extension_source_owned != null) {
                if (result.parse_error == null) {
                    result.parse_error = try allocator.dupe(u8, "--extension can only be provided once.");
                }
            } else {
                saw_extension_source_owned = try allocator.dupe(u8, args[next_index]);
            }
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            if (result.parse_error == null) {
                result.parse_error = try std.fmt.allocPrint(
                    allocator,
                    "Unknown option {s} for \"{s}\".",
                    .{ arg, packageCommandName(command) },
                );
            }
            continue;
        }
        if (positional_owned != null) {
            if (result.parse_error == null) {
                result.parse_error = try std.fmt.allocPrint(
                    allocator,
                    "Unexpected argument {s}.",
                    .{arg},
                );
            }
            continue;
        }
        positional_owned = try allocator.dupe(u8, arg);
    }

    if (command == .config and saw_toggle_flag and result.parse_error == null) {
        if (pending_toggle_kind == null or pending_toggle_pattern_owned == null) {
            if (result.parse_error == null) {
                result.parse_error = try allocator.dupe(
                    u8,
                    "--toggle requires <kind> and <pattern> arguments.",
                );
            }
        } else {
            result.config_options.toggle_kind = pending_toggle_kind;
            result.config_options.toggle_pattern = pending_toggle_pattern_owned;
            pending_toggle_pattern_owned = null;
        }
    }

    if (positional_owned) |value| {
        result.source = value;
        positional_owned = null;
    }

    if ((command == .install or command == .remove) and result.source == null and !result.help and result.parse_error == null) {
        result.parse_error = try std.fmt.allocPrint(
            allocator,
            "Missing {s} source.",
            .{packageCommandName(command)},
        );
    }

    if (command == .update and !result.help) {
        // Conflict detection and update_target resolution incorporating
        // --self, --extensions, --extension <source>, and positional sources.
        if (saw_extension_source_owned) |ext_src| {
            // --extension <source> conflicts with --self, --extensions, or positional.
            if (saw_self_flag or saw_extensions_flag) {
                allocator.free(ext_src);
                saw_extension_source_owned = null;
                if (result.parse_error == null) {
                    result.parse_error = try allocator.dupe(
                        u8,
                        "--extension cannot be combined with --self or --extensions.",
                    );
                }
            } else if (result.source != null) {
                allocator.free(ext_src);
                saw_extension_source_owned = null;
                if (result.parse_error == null) {
                    result.parse_error = try allocator.dupe(
                        u8,
                        "--extension cannot be combined with a positional source.",
                    );
                }
            } else {
                // No conflict: --extension source becomes the update target.
                result.source = ext_src;
                saw_extension_source_owned = null;
            }
        } else if (result.source != null) {
            // Positional source + --self/--extensions conflict check.
            const val = result.source.?;
            const source_is_self = std.mem.eql(u8, val, "self") or std.mem.eql(u8, val, "pi");
            if (!source_is_self and (saw_extensions_flag or saw_self_flag)) {
                if (result.parse_error == null) {
                    result.parse_error = try allocator.dupe(
                        u8,
                        "Positional update targets cannot be combined with --self or --extensions.",
                    );
                }
            }
        }

        if (result.parse_error == null) {
            if (result.source) |value| {
                const source_is_self = std.mem.eql(u8, value, "self") or std.mem.eql(u8, value, "pi");
                if (source_is_self) {
                    // "self"/"pi" positional + --extensions means update all
                    // (self-update + extension update).
                    if (saw_extensions_flag) {
                        result.update_target = .all;
                        result.update_self = true;
                    } else {
                        result.update_target = .self;
                    }
                } else {
                    result.update_target = .{ .source = value };
                }
            } else if (saw_self_flag and saw_extensions_flag) {
                // --self + --extensions: update both self and all extensions.
                result.update_target = .all;
                result.update_self = true;
            } else if (saw_self_flag) {
                result.update_target = .self;
            } else if (saw_extensions_flag) {
                result.update_target = .extensions;
            } else {
                result.update_target = .all;
            }
        }
    }

    // Safety cleanup: free extension source if not consumed above.
    if (saw_extension_source_owned) |value| {
        allocator.free(value);
    }

    return result;
}

pub fn packageCommandName(command: PackageCommand) []const u8 {
    return switch (command) {
        .install => "install",
        .remove => "remove",
        .update => "update",
        .list => "list",
        .config => "config",
    };
}

pub fn packageCommandUsage(command: PackageCommand) []const u8 {
    return switch (command) {
        .install => "pi install <source> [-l]",
        .remove => "pi remove <source> [-l]",
        .update => "pi update [source|self|pi] [--self] [--extensions] [--extension <source>] [--force]",
        .list => "pi list",
        .config => "pi config [--toggle <kind> <pattern> --enable|--disable] [-l]",
    };
}

test "parsePackageCommand rejects non-package commands" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotPackageCommand, parsePackageCommand(allocator, &.{}));
    try std.testing.expectError(error.NotPackageCommand, parsePackageCommand(allocator, &.{"unrelated"}));
    try std.testing.expectError(error.NotPackageCommand, parsePackageCommand(allocator, &.{"--prompt"}));
}

test "parsePackageCommand records missing source for install" {
    const allocator = std.testing.allocator;
    var parsed = try parsePackageCommand(allocator, &.{"install"});
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.parse_error.?, "Missing install source") != null);
}

test "parsePackageCommand reports unknown options" {
    const allocator = std.testing.allocator;
    var parsed = try parsePackageCommand(allocator, &.{ "install", "--bogus", "./local" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.parse_error.?, "--bogus") != null);
}

test "VAL-PKG-122 self_update --force flag parsed and sets force=true with update_target=self" {
    const allocator = std.testing.allocator;

    // Test that --force is parsed correctly without error.
    var parsed = try parsePackageCommand(allocator, &.{ "update", "self", "--force" });
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.parse_error == null);
    try std.testing.expect(parsed.force == true);
    try std.testing.expect(parsed.update_target != null);
    try std.testing.expect(parsed.update_target.? == .self);
}

test "VAL-PKG-122 self_update --force rejected on non-update commands" {
    const allocator = std.testing.allocator;

    var parsed_install = try parsePackageCommand(allocator, &.{ "install", "./pkg", "--force" });
    defer parsed_install.deinit(allocator);
    try std.testing.expect(parsed_install.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed_install.parse_error.?, "--force") != null);

    var parsed_list = try parsePackageCommand(allocator, &.{ "list", "--force" });
    defer parsed_list.deinit(allocator);
    try std.testing.expect(parsed_list.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed_list.parse_error.?, "--force") != null);
}

test "VAL-PKG-130 --self flag resolves update_target to .self" {
    const allocator = std.testing.allocator;
    var parsed = try parsePackageCommand(allocator, &.{ "update", "--self" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error == null);
    try std.testing.expect(parsed.update_target != null);
    const target = parsed.update_target.?;
    try std.testing.expect(target == .self);
}

test "VAL-PKG-137 --force accepted only on update command" {
    const allocator = std.testing.allocator;

    // Accepted on update.
    var p_update = try parsePackageCommand(allocator, &.{ "update", "--force" });
    defer p_update.deinit(allocator);
    try std.testing.expect(p_update.parse_error == null);
    try std.testing.expect(p_update.force == true);

    // Rejected on install.
    var p_install = try parsePackageCommand(allocator, &.{ "install", "./pkg", "--force" });
    defer p_install.deinit(allocator);
    try std.testing.expect(p_install.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, p_install.parse_error.?, "--force") != null);

    // Rejected on list.
    var p_list = try parsePackageCommand(allocator, &.{ "list", "--force" });
    defer p_list.deinit(allocator);
    try std.testing.expect(p_list.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, p_list.parse_error.?, "--force") != null);
}

test "VAL-PKG-138 --self rejected on non-update commands" {
    const allocator = std.testing.allocator;

    var p_install = try parsePackageCommand(allocator, &.{ "install", "npm:foo", "--self" });
    defer p_install.deinit(allocator);
    try std.testing.expect(p_install.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, p_install.parse_error.?, "--self") != null);

    var p_list = try parsePackageCommand(allocator, &.{ "list", "--self" });
    defer p_list.deinit(allocator);
    try std.testing.expect(p_list.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, p_list.parse_error.?, "--self") != null);
}

test "VAL-PKG-139 --extensions rejected on non-update commands" {
    const allocator = std.testing.allocator;

    var p_install = try parsePackageCommand(allocator, &.{ "install", "npm:foo", "--extensions" });
    defer p_install.deinit(allocator);
    try std.testing.expect(p_install.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, p_install.parse_error.?, "--extensions") != null);

    var p_list = try parsePackageCommand(allocator, &.{ "list", "--extensions" });
    defer p_list.deinit(allocator);
    try std.testing.expect(p_list.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, p_list.parse_error.?, "--extensions") != null);
}

test "parsePackageCommand accepts help without requiring positional source" {
    const allocator = std.testing.allocator;

    var install_help = try parsePackageCommand(allocator, &.{ "install", "--help" });
    defer install_help.deinit(allocator);
    try std.testing.expect(install_help.help);
    try std.testing.expect(install_help.parse_error == null);

    var remove_help = try parsePackageCommand(allocator, &.{ "remove", "-h" });
    defer remove_help.deinit(allocator);
    try std.testing.expect(remove_help.help);
    try std.testing.expect(remove_help.parse_error == null);
}

test "parsePackageCommand records config toggle options" {
    const allocator = std.testing.allocator;

    var parsed = try parsePackageCommand(allocator, &.{ "config", "--toggle", "extensions", "extras/main.ts", "--disable", "--local" });
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.parse_error == null);
    try std.testing.expectEqual(PackageCommand.config, parsed.command);
    try std.testing.expect(parsed.local);
    try std.testing.expect(parsed.config_options.toggle_kind != null);
    try std.testing.expectEqual(ConfigKind.extensions, parsed.config_options.toggle_kind.?);
    try std.testing.expectEqual(ConfigToggleAction.disable, parsed.config_options.toggle_action);
    try std.testing.expectEqualStrings("extras/main.ts", parsed.config_options.toggle_pattern.?);
}
