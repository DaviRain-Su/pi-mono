const std = @import("std");

pub const Mode = enum {
    text,
    json,
    rpc,
};

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const Diagnostic = struct {
    kind: []const u8,
    message: []const u8,
};

pub const UnknownFlag = struct {
    name: []u8,
    value: ?[]u8 = null,
};

pub const Args = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    thinking: ?ThinkingLevel = null,
    continue_session: bool = false,
    resume_session: bool = false,
    help: bool = false,
    version: bool = false,
    mode: ?Mode = null,
    no_session: bool = false,
    session: ?[]const u8 = null,
    fork: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    no_tools: bool = false,
    no_builtin_tools: bool = false,
    no_extensions: bool = false,
    print: bool = false,
    export_path: ?[]const u8 = null,
    no_skills: bool = false,
    no_prompt_templates: bool = false,
    no_themes: bool = false,
    no_context_files: bool = false,
    list_models: ?[]const u8 = null,
    list_models_all: bool = false,
    offline: bool = false,
    verbose: bool = false,
    messages: []const []const u8 = &.{},
    file_args: []const []const u8 = &.{},
    unknown_flags: []UnknownFlag = &.{},
    diagnostics: []Diagnostic = &.{},

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        for (self.unknown_flags) |flag| {
            allocator.free(flag.name);
            if (flag.value) |value| allocator.free(value);
        }
        allocator.free(self.unknown_flags);
        allocator.free(self.messages);
        allocator.free(self.file_args);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const VALID_THINKING_LEVELS = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh" };

pub fn isValidThinkingLevel(level: []const u8) bool {
    return parseThinkingLevel(level) != null;
}

pub fn parseThinkingLevel(level: []const u8) ?ThinkingLevel {
    return std.meta.stringToEnum(ThinkingLevel, level);
}

const FlagKind = enum {
    bool_flag,
    optional_string,
};

const FlagSpec = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    field: []const u8,
    kind: FlagKind,
};

const FLAG_SPECS = [_]FlagSpec{
    .{ .long = "--help", .short = "-h", .field = "help", .kind = .bool_flag },
    .{ .long = "--version", .short = "-v", .field = "version", .kind = .bool_flag },
    .{ .long = "--continue", .short = "-c", .field = "continue_session", .kind = .bool_flag },
    .{ .long = "--resume", .short = "-r", .field = "resume_session", .kind = .bool_flag },
    .{ .long = "--no-session", .field = "no_session", .kind = .bool_flag },
    .{ .long = "--no-tools", .short = "-nt", .field = "no_tools", .kind = .bool_flag },
    .{ .long = "--no-builtin-tools", .short = "-nbt", .field = "no_builtin_tools", .kind = .bool_flag },
    .{ .long = "--no-extensions", .short = "-ne", .field = "no_extensions", .kind = .bool_flag },
    .{ .long = "--no-skills", .short = "-ns", .field = "no_skills", .kind = .bool_flag },
    .{ .long = "--no-prompt-templates", .short = "-np", .field = "no_prompt_templates", .kind = .bool_flag },
    .{ .long = "--no-themes", .field = "no_themes", .kind = .bool_flag },
    .{ .long = "--no-context-files", .short = "-nc", .field = "no_context_files", .kind = .bool_flag },
    .{ .long = "--verbose", .field = "verbose", .kind = .bool_flag },
    .{ .long = "--offline", .field = "offline", .kind = .bool_flag },
    .{ .long = "--provider", .field = "provider", .kind = .optional_string },
    .{ .long = "--model", .field = "model", .kind = .optional_string },
    .{ .long = "--api-key", .field = "api_key", .kind = .optional_string },
    .{ .long = "--system-prompt", .field = "system_prompt", .kind = .optional_string },
    .{ .long = "--session", .field = "session", .kind = .optional_string },
    .{ .long = "--fork", .field = "fork", .kind = .optional_string },
    .{ .long = "--session-dir", .field = "session_dir", .kind = .optional_string },
    .{ .long = "--export", .field = "export_path", .kind = .optional_string },
};

comptime {
    for (FLAG_SPECS) |spec| {
        if (!@hasField(Args, spec.field)) {
            @compileError("FlagSpec references unknown Args field: " ++ spec.field);
        }
    }
}

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Args {
    var messages: std.ArrayList([]const u8) = .empty;
    errdefer messages.deinit(allocator);
    var file_args: std.ArrayList([]const u8) = .empty;
    errdefer file_args.deinit(allocator);
    var unknown_flags: std.ArrayList(UnknownFlag) = .empty;
    errdefer {
        for (unknown_flags.items) |flag| {
            allocator.free(flag.name);
            if (flag.value) |value| allocator.free(value);
        }
        unknown_flags.deinit(allocator);
    }
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    var result: Args = .{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];

        // Custom-handler flags: bespoke semantics that don't fit a "set this field" pattern.
        if (std.mem.eql(u8, arg, "--mode")) {
            if (takeNext(argv, &index)) |value| result.mode = parseMode(value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--thinking")) {
            if (takeNext(argv, &index)) |value| {
                if (parseThinkingLevel(value)) |level| {
                    result.thinking = level;
                } else {
                    try diagnostics.append(allocator, .{ .kind = "warning", .message = "Invalid thinking level" });
                }
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            result.print = true;
            if (peek(argv, index + 1)) |next| {
                if (!std.mem.startsWith(u8, next, "@") and (!std.mem.startsWith(u8, next, "-") or std.mem.startsWith(u8, next, "---"))) {
                    try messages.append(allocator, next);
                    index += 1;
                }
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--list-models")) {
            if (peek(argv, index + 1)) |next| {
                if (!std.mem.startsWith(u8, next, "-") and !std.mem.startsWith(u8, next, "@")) {
                    result.list_models = next;
                    index += 1;
                } else {
                    result.list_models_all = true;
                }
            } else {
                result.list_models_all = true;
            }
            continue;
        }

        // Table-driven flag dispatch: first matching spec wins.
        var matched = false;
        inline for (FLAG_SPECS) |spec| {
            if (!matched) {
                const hit = std.mem.eql(u8, arg, spec.long) or
                    (spec.short != null and std.mem.eql(u8, arg, spec.short.?));
                if (hit) {
                    switch (spec.kind) {
                        .bool_flag => @field(result, spec.field) = true,
                        .optional_string => if (takeNext(argv, &index)) |value| {
                            @field(result, spec.field) = value;
                        },
                    }
                    matched = true;
                }
            }
        }
        if (matched) continue;

        // Remaining positional/unknown handling.
        if (std.mem.startsWith(u8, arg, "@")) {
            try file_args.append(allocator, arg[1..]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try appendUnknownFlag(allocator, &unknown_flags, argv, &index);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try diagnostics.append(allocator, .{ .kind = "error", .message = "Unknown option" });
        } else {
            try messages.append(allocator, arg);
        }
    }
    result.messages = try messages.toOwnedSlice(allocator);
    result.file_args = try file_args.toOwnedSlice(allocator);
    result.unknown_flags = try unknown_flags.toOwnedSlice(allocator);
    result.diagnostics = try diagnostics.toOwnedSlice(allocator);
    return result;
}

fn parseMode(value: []const u8) ?Mode {
    return std.meta.stringToEnum(Mode, value);
}

fn takeNext(argv: []const []const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= argv.len) return null;
    index.* += 1;
    return argv[index.*];
}

fn peek(argv: []const []const u8, index: usize) ?[]const u8 {
    return if (index < argv.len) argv[index] else null;
}

fn appendUnknownFlag(allocator: std.mem.Allocator, flags: *std.ArrayList(UnknownFlag), argv: []const []const u8, index: *usize) !void {
    const arg = argv[index.*];
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
        try flags.append(allocator, .{ .name = try allocator.dupe(u8, arg[2..eq]), .value = try allocator.dupe(u8, arg[eq + 1 ..]) });
        return;
    }
    const name = arg[2..];
    if (peek(argv, index.* + 1)) |next| {
        if (!std.mem.startsWith(u8, next, "-") and !std.mem.startsWith(u8, next, "@")) {
            index.* += 1;
            try flags.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = try allocator.dupe(u8, next) });
            return;
        }
    }
    try flags.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = null });
}

test "parseArgs separates messages files and extension flags" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--model", "sonnet", "@prompt.md", "--plan", "deep", "hello" };
    var parsed = try parseArgs(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("sonnet", parsed.model.?);
    try std.testing.expectEqualStrings("prompt.md", parsed.file_args[0]);
    try std.testing.expectEqualStrings("plan", parsed.unknown_flags[0].name);
    try std.testing.expectEqualStrings("hello", parsed.messages[0]);
}

test "parseArgs --print captures prompt and treats yaml frontmatter as message" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--print", "---\ntitle: hi\n---\nbody" };
    var parsed = try parseArgs(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.print);
    try std.testing.expectEqual(@as(usize, 1), parsed.messages.len);
    try std.testing.expectEqualStrings("---\ntitle: hi\n---\nbody", parsed.messages[0]);
}

test "parseArgs --print without prompt leaves messages empty" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--print", "--verbose" };
    var parsed = try parseArgs(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.print);
    try std.testing.expect(parsed.verbose);
    try std.testing.expectEqual(@as(usize, 0), parsed.messages.len);
}

test "parseArgs --list-models without arg sets list_models_all" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"--list-models"};
    var parsed = try parseArgs(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.list_models_all);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.list_models);
}

test "parseArgs --list-models with provider captures provider value" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--list-models", "anthropic" };
    var parsed = try parseArgs(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(!parsed.list_models_all);
    try std.testing.expectEqualStrings("anthropic", parsed.list_models.?);
}

test "parseArgs --thinking with invalid level emits warning diagnostic" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--thinking", "turbo" };
    var parsed = try parseArgs(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(?ThinkingLevel, null), parsed.thinking);
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics.len);
    try std.testing.expectEqualStrings("warning", parsed.diagnostics[0].kind);
}

test "parseArgs --mode parses valid mode" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--mode", "rpc" };
    var parsed = try parseArgs(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(?Mode, .rpc), parsed.mode);
}

test "parseArgs short bool flags toggle target field" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "-c", "-nt", "-nbt", "-ne" };
    var parsed = try parseArgs(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.continue_session);
    try std.testing.expect(parsed.no_tools);
    try std.testing.expect(parsed.no_builtin_tools);
    try std.testing.expect(parsed.no_extensions);
}
