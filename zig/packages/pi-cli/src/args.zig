const std = @import("std");

pub const Mode = enum {
    text,
    json,
    rpc,
    ts_rpc,
};

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const ParseError = error{
    MissingOptionValue,
    InvalidMode,
    InvalidThinkingLevel,
    UnknownOption,
};

pub const ParseArgsError = ParseError || std.mem.Allocator.Error;

/// Mirrors the TypeScript `Args.unknownFlags` map entry shape. Long
/// (`--*`) flags that are not part of the built-in CLI option set are
/// accepted at parse time so that extension-registered flags can be
/// surfaced after extension discovery completes. Boolean flags appear
/// when the next argv token starts with `-` or `@` or is absent;
/// string flags consume the following token (or use `--foo=bar`).
pub const UnknownFlagValue = union(enum) {
    boolean: bool,
    string: []const u8,
};

pub const UnknownFlag = struct {
    name: []const u8,
    value: UnknownFlagValue,
};

pub const Args = struct {
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const []const u8 = null,
    thinking: ?ThinkingLevel = null,
    extensions: ?[]const []const u8 = null,
    no_extensions: bool = false,
    skills: ?[]const []const u8 = null,
    no_skills: bool = false,
    prompt_templates: ?[]const []const u8 = null,
    no_prompt_templates: bool = false,
    themes: ?[]const []const u8 = null,
    no_themes: bool = false,
    @"continue": bool = false,
    @"resume": bool = false,
    session: ?[]const u8 = null,
    fork: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    models: ?[]const []const u8 = null,
    list_models: bool = false,
    list_models_search: ?[]const u8 = null,
    no_session: bool = false,
    print: bool = false,

    mode: Mode = .text,
    tools: ?[]const []const u8 = null,
    no_tools: bool = false,
    no_builtin_tools: bool = false,
    no_context_files: bool = false,
    offline: bool = false,
    verbose: bool = false,
    @"export": ?[]const u8 = null,
    help: bool = false,
    version: bool = false,
    messages: ?[]const []const u8 = null,
    prompt: ?[]const u8 = null,
    prompt_owned: bool = false,
    file_args: ?[]const []const u8 = null,
    unknown_flags: ?[]const UnknownFlag = null,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        if (self.extensions) |extensions| allocator.free(extensions);
        if (self.append_system_prompt) |append_system_prompt| allocator.free(append_system_prompt);
        if (self.skills) |skills| allocator.free(skills);
        if (self.prompt_templates) |prompt_templates| allocator.free(prompt_templates);
        if (self.themes) |themes| allocator.free(themes);
        if (self.tools) |tools| allocator.free(tools);
        if (self.models) |models| allocator.free(models);
        if (self.messages) |messages| allocator.free(messages);
        if (self.file_args) |file_args| allocator.free(file_args);
        if (self.unknown_flags) |flags| allocator.free(flags);
        if (self.prompt_owned and self.prompt != null) allocator.free(self.prompt.?);
        self.* = undefined;
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) ParseArgsError!Args {
    var result = Args{};
    errdefer result.deinit(allocator);
    var messages_builder = std.ArrayList([]const u8).empty;
    var messages_transferred = false;
    defer if (!messages_transferred) messages_builder.deinit(allocator);
    var file_args_builder = std.ArrayList([]const u8).empty;
    var file_args_transferred = false;
    defer if (!file_args_transferred) file_args_builder.deinit(allocator);
    var extensions_builder = std.ArrayList([]const u8).empty;
    var extensions_transferred = false;
    defer if (!extensions_transferred) extensions_builder.deinit(allocator);
    var append_system_prompt_builder = std.ArrayList([]const u8).empty;
    var append_system_prompt_transferred = false;
    defer if (!append_system_prompt_transferred) append_system_prompt_builder.deinit(allocator);
    var skills_builder = std.ArrayList([]const u8).empty;
    var skills_transferred = false;
    defer if (!skills_transferred) skills_builder.deinit(allocator);
    var prompt_templates_builder = std.ArrayList([]const u8).empty;
    var prompt_templates_transferred = false;
    defer if (!prompt_templates_transferred) prompt_templates_builder.deinit(allocator);
    var themes_builder = std.ArrayList([]const u8).empty;
    var themes_transferred = false;
    defer if (!themes_transferred) themes_builder.deinit(allocator);
    var unknown_flags_builder = std.ArrayList(UnknownFlag).empty;
    var unknown_flags_transferred = false;
    defer if (!unknown_flags_transferred) unknown_flags_builder.deinit(allocator);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.version = true;
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.model = argv[i];
        } else if (std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.provider = argv[i];
        } else if (std.mem.eql(u8, arg, "--api-key") or std.mem.eql(u8, arg, "-k")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.api_key = argv[i];
        } else if (std.mem.eql(u8, arg, "--extension") or std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            try extensions_builder.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-extensions") or std.mem.eql(u8, arg, "-ne")) {
            result.no_extensions = true;
        } else if (std.mem.eql(u8, arg, "--skill")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            try skills_builder.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-skills") or std.mem.eql(u8, arg, "-ns")) {
            result.no_skills = true;
        } else if (std.mem.eql(u8, arg, "--prompt-template")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            try prompt_templates_builder.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-prompt-templates") or std.mem.eql(u8, arg, "-np")) {
            result.no_prompt_templates = true;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            try themes_builder.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-themes")) {
            result.no_themes = true;
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.thinking = parseThinkingLevel(argv[i]) orelse return error.InvalidThinkingLevel;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            result.@"continue" = true;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "-r")) {
            result.@"resume" = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.session = argv[i];
        } else if (std.mem.eql(u8, arg, "--fork")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.fork = argv[i];
        } else if (std.mem.eql(u8, arg, "--session-dir")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.session_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--models")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            if (result.models) |models| {
                allocator.free(models);
                result.models = null;
            }
            result.models = try parseCommaSeparatedList(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--list-models")) {
            result.list_models = true;
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-") and !std.mem.startsWith(u8, argv[i + 1], "@")) {
                i += 1;
                result.list_models_search = argv[i];
            }
        } else if (std.mem.eql(u8, arg, "--no-session")) {
            result.no_session = true;
        } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            result.print = true;
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "@") and (!std.mem.startsWith(u8, argv[i + 1], "-") or std.mem.startsWith(u8, argv[i + 1], "---"))) {
                i += 1;
                try messages_builder.append(allocator, argv[i]);
            }
        } else if (std.mem.eql(u8, arg, "--mode") or std.mem.eql(u8, arg, "-mode")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.mode = parseMode(argv[i]) orelse return error.InvalidMode;
        } else if (std.mem.eql(u8, arg, "--tools") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            if (result.tools) |tools| {
                allocator.free(tools);
                result.tools = null;
            }
            result.tools = try parseToolList(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-tools") or std.mem.eql(u8, arg, "-nt")) {
            result.no_tools = true;
        } else if (std.mem.eql(u8, arg, "--no-builtin-tools") or std.mem.eql(u8, arg, "-nbt")) {
            result.no_builtin_tools = true;
        } else if (std.mem.eql(u8, arg, "--system-prompt") or std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.system_prompt = argv[i];
        } else if (std.mem.eql(u8, arg, "--append-system-prompt")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            try append_system_prompt_builder.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-context-files") or std.mem.eql(u8, arg, "-nc")) {
            result.no_context_files = true;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            result.offline = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            result.verbose = true;
        } else if (std.mem.eql(u8, arg, "--export")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.@"export" = argv[i];
        } else if (std.mem.startsWith(u8, arg, "@")) {
            try file_args_builder.append(allocator, arg[1..]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // Long flag we do not recognize. Mirror TypeScript
            // `parseArgs` behavior in `packages/coding-agent/src/cli/args.ts`
            // by collecting the flag (and optional next-token value) into
            // `unknown_flags` so extensions registered later can either
            // claim the flag or produce an `Unknown option:` diagnostic.
            const eq_index_opt = std.mem.indexOfScalar(u8, arg, '=');
            if (eq_index_opt) |eq_index| {
                const flag_name = arg[2..eq_index];
                const flag_value = arg[eq_index + 1 ..];
                try unknown_flags_builder.append(allocator, .{
                    .name = flag_name,
                    .value = .{ .string = flag_value },
                });
            } else {
                const flag_name = arg[2..];
                if (i + 1 < argv.len) {
                    const next = argv[i + 1];
                    if (next.len > 0 and !std.mem.startsWith(u8, next, "-") and !std.mem.startsWith(u8, next, "@")) {
                        try unknown_flags_builder.append(allocator, .{
                            .name = flag_name,
                            .value = .{ .string = next },
                        });
                        i += 1;
                        continue;
                    }
                }
                try unknown_flags_builder.append(allocator, .{
                    .name = flag_name,
                    .value = .{ .boolean = true },
                });
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Single-dash short options not in the built-in set remain a
            // hard error. TypeScript surfaces these as a parse-time
            // diagnostic; Zig keeps the existing fail-fast behavior so
            // the caller can render `Error: Unknown option`.
            return error.UnknownOption;
        } else {
            try messages_builder.append(allocator, arg);
        }
    }

    if (messages_builder.items.len > 0) {
        result.messages = try messages_builder.toOwnedSlice(allocator);
        messages_transferred = true;
    }

    if (file_args_builder.items.len > 0) {
        result.file_args = try file_args_builder.toOwnedSlice(allocator);
        file_args_transferred = true;
    }
    if (extensions_builder.items.len > 0) {
        result.extensions = try extensions_builder.toOwnedSlice(allocator);
        extensions_transferred = true;
    }
    if (append_system_prompt_builder.items.len > 0) {
        result.append_system_prompt = try append_system_prompt_builder.toOwnedSlice(allocator);
        append_system_prompt_transferred = true;
    }
    if (skills_builder.items.len > 0) {
        result.skills = try skills_builder.toOwnedSlice(allocator);
        skills_transferred = true;
    }
    if (prompt_templates_builder.items.len > 0) {
        result.prompt_templates = try prompt_templates_builder.toOwnedSlice(allocator);
        prompt_templates_transferred = true;
    }
    if (themes_builder.items.len > 0) {
        result.themes = try themes_builder.toOwnedSlice(allocator);
        themes_transferred = true;
    }
    if (unknown_flags_builder.items.len > 0) {
        result.unknown_flags = try unknown_flags_builder.toOwnedSlice(allocator);
        unknown_flags_transferred = true;
    }

    return result;
}

/// Minimal description of an extension-registered CLI flag used for
/// help-text rendering. Mirrors the subset of the TypeScript
/// `ExtensionFlag` shape that the help formatter needs.
pub const ExtensionFlagInfo = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    type_kind: enum { boolean, string } = .boolean,
    extension_path: []const u8 = "",
};

pub const ExtensionFlagDiagnosticInfo = struct {
    severity: []const u8,
    code: []const u8,
    owner: []const u8,
    source: []const u8,
    flag_name: []const u8,
    reason: []const u8,
    message: []const u8,
};

pub fn helpText(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return helpTextWithExtensions(allocator, version, &.{});
}

pub fn helpTextWithExtensions(
    allocator: std.mem.Allocator,
    version: []const u8,
    extension_flags: []const ExtensionFlagInfo,
) ![]u8 {
    return helpTextWithExtensionDiagnostics(allocator, version, extension_flags, &.{});
}

pub fn helpTextWithExtensionDiagnostics(
    allocator: std.mem.Allocator,
    version: []const u8,
    extension_flags: []const ExtensionFlagInfo,
    extension_flag_diagnostics: []const ExtensionFlagDiagnosticInfo,
) ![]u8 {
    const base = try renderBaseHelp(allocator, version);
    if (extension_flags.len == 0 and extension_flag_diagnostics.len == 0) return base;
    defer allocator.free(base);

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, base);

    // Insert the extension flags section directly after the existing
    // top-level options listing. Match the TypeScript ordering by
    // appending after the trailing newline written by `renderBaseHelp`.
    try buffer.appendSlice(allocator, "Extension CLI Flags:\n");
    for (extension_flags) |flag| {
        const value_label: []const u8 = if (flag.type_kind == .string) " <value>" else "";
        const description = if (flag.description) |desc| desc else flag.extension_path;
        // Mirror TS padEnd(30) on `--<name><value>` with a 2-space prefix.
        var label_buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "  --{s}{s}", .{ flag.name, value_label }) catch
            return error.OutOfMemory;
        try buffer.appendSlice(allocator, label);
        const padded_target: usize = 30;
        if (label.len < padded_target) {
            var pad_remaining = padded_target - label.len;
            const spaces = "                                ";
            while (pad_remaining > 0) {
                const chunk = @min(pad_remaining, spaces.len);
                try buffer.appendSlice(allocator, spaces[0..chunk]);
                pad_remaining -= chunk;
            }
        }
        try buffer.appendSlice(allocator, description);
        try buffer.append(allocator, '\n');
    }
    if (extension_flag_diagnostics.len > 0) {
        try buffer.appendSlice(allocator, "Extension CLI Flag Diagnostics:\n");
        for (extension_flag_diagnostics) |diagnostic| {
            const diagnostic_line = try std.fmt.allocPrint(
                allocator,
                "  [{s}] {s} owner={s} source={s} flag=--{s} reason={s}: {s}\n",
                .{
                    diagnostic.severity,
                    diagnostic.code,
                    diagnostic.owner,
                    diagnostic.source,
                    diagnostic.flag_name,
                    diagnostic.reason,
                    diagnostic.message,
                },
            );
            defer allocator.free(diagnostic_line);
            try buffer.appendSlice(allocator, diagnostic_line);
        }
    }

    return buffer.toOwnedSlice(allocator);
}

fn renderBaseHelp(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\pi - AI assistant (Zig rewrite) v{s}
        \\
        \\Usage:
        \\  pi [options] [@files...] [messages...]
        \\
        \\Commands:
        \\  pi install <source> [-l]       Install extension source and add to settings
        \\  pi remove <source> [-l]        Remove extension source from settings
        \\  pi uninstall <source> [-l]     Alias for remove
        \\  pi update [source]             Update installed extensions (offline no-op for local fixtures)
        \\  pi list                        List installed extensions from settings
        \\  pi config                      Manage package resource toggles in settings
        \\  pi <command> --help            Show help for install/remove/uninstall/update/list/config
        \\
        \\Note: release/binary packaging (self-update, packaged installers) is not
        \\implemented in this build; package commands operate on local fixtures only.
        \\
        \\Options:
        \\  --model <model>                Model ID (default depends on provider)
        \\  --provider <provider>          Provider name (default: openai)
        \\  --api-key <key>                API key (defaults to provider env vars)
        \\  --thinking <level>             Thinking level: off, minimal, low, medium, high, xhigh
        \\  --extension, -e <path>         Load an extension file or directory (repeatable)
        \\  --no-extensions, -ne           Disable default extension discovery
        \\  --skill <path>                 Load a skill file or directory (repeatable)
        \\  --no-skills, -ns               Disable default skill discovery
        \\  --prompt-template <path>       Load a prompt template file or directory (repeatable)
        \\  --no-prompt-templates, -np     Disable default prompt template discovery
        \\  --theme <path>                 Load a theme file or directory (repeatable)
        \\  --no-themes                    Disable default theme discovery
        \\  --continue, -c                 Continue a previous session
        \\  --resume, -r                   Resume the latest session
        \\  --session <id|path>            Use a specific session identifier or path
        \\  --fork <id|path>               Fork a specific session into a new session
        \\  --session-dir <dir>            Directory for session storage and lookup
        \\  --no-session                   Run without session persistence
        \\  --models <patterns>            Comma-separated model patterns for model selection
        \\  --list-models [search]         List available models and exit
        \\  --print, -p                    Non-interactive mode
        \\  --mode, -mode <mode>           Output mode: text, json, rpc, json-rpc (default: text; ts-rpc aliases rpc)
        \\  --tools, -t <names>            Comma-separated tool allowlist
        \\  --no-tools, -nt                Disable built-in tools by default
        \\  --no-builtin-tools, -nbt       Disable built-in tools by default but keep custom tools enabled
        \\  --system-prompt <text>         Replace the default system prompt
        \\  --append-system-prompt <text>  Append text to the system prompt (repeatable)
        \\  --no-context-files, -nc        Disable AGENTS.md and CLAUDE.md discovery and loading
        \\  --export <file>                Export session file to HTML or JSONL and exit
        \\  --verbose                      Force verbose startup
        \\  --offline                      Disable startup network operations
        \\  --help, -h                     Show this help
        \\  --version, -v                  Show version
        \\
        \\Examples:
        \\  pi --help
        \\  pi --version
        \\  pi --model gpt-4.1 --provider openai "Summarize this repository"
        \\  pi --session-dir ./tmp/sessions --print "Summarize this repository"
        \\  pi @prompt.md @screenshot.png "What changed in this image?"
        \\  pi --models anthropic/*,*gpt-5*
        \\  pi --list-models sonnet
        \\  pi --print --mode json "Explain the latest session"
        \\  pi --tools read,grep,ls "Inspect the codebase"
        \\
    ,
        .{version},
    );
}

pub fn versionText(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "pi version {s}\n", .{version});
}

fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    // TypeScript `--mode rpc` is the JSONL command protocol implemented by
    // `ts_rpc_mode.zig`. Keep the older Zig JSON-RPC protocol available under
    // an explicit compatibility spelling.
    if (std.mem.eql(u8, value, "rpc")) return .ts_rpc;
    if (std.mem.eql(u8, value, "ts-rpc")) return .ts_rpc;
    if (std.mem.eql(u8, value, "json-rpc")) return .rpc;
    return null;
}

fn parseThinkingLevel(value: []const u8) ?ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

fn parseCommaSeparatedList(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var items = std.ArrayList([]const u8).empty;
    errdefer items.deinit(allocator);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len == 0) continue;
        try items.append(allocator, trimmed);
    }

    return try items.toOwnedSlice(allocator);
}

fn parseToolList(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    return parseCommaSeparatedList(allocator, value);
}

test "parse args supports expected CLI flags" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{
        "--model",
        "gpt-4.1",
        "--provider",
        "openai",
        "--api-key",
        "secret",
        "--extension",
        "extensions/review.ts",
        "--no-extensions",
        "--skill",
        "skills/reviewer",
        "--no-skills",
        "--prompt-template",
        "prompts/fix.md",
        "--no-prompt-templates",
        "--theme",
        "themes/night.json",
        "--no-themes",
        "--thinking",
        "high",
        "--continue",
        "--resume",
        "--session",
        "session-123",
        "--fork",
        "session-456",
        "--session-dir",
        "./sessions",
        "--models",
        "anthropic/*,*gpt-5*",
        "--list-models",
        "sonnet",
        "--no-session",
        "--print",
        "-mode",
        "json",
        "-t",
        "read, grep,ls",
        "-nt",
        "--no-builtin-tools",
        "--no-context-files",
        "--offline",
        "--verbose",
        "--export",
        "session.jsonl",
        "@prompt.md",
        "@image.png",
        "Summarize the repository",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqualStrings("gpt-4.1", args.model.?);
    try std.testing.expectEqualStrings("openai", args.provider.?);
    try std.testing.expectEqualStrings("secret", args.api_key.?);
    try std.testing.expectEqual(@as(usize, 1), args.extensions.?.len);
    try std.testing.expectEqualStrings("extensions/review.ts", args.extensions.?[0]);
    try std.testing.expect(args.no_extensions);
    try std.testing.expectEqual(@as(usize, 1), args.skills.?.len);
    try std.testing.expectEqualStrings("skills/reviewer", args.skills.?[0]);
    try std.testing.expect(args.no_skills);
    try std.testing.expectEqual(@as(usize, 1), args.prompt_templates.?.len);
    try std.testing.expectEqualStrings("prompts/fix.md", args.prompt_templates.?[0]);
    try std.testing.expect(args.no_prompt_templates);
    try std.testing.expectEqual(@as(usize, 1), args.themes.?.len);
    try std.testing.expectEqualStrings("themes/night.json", args.themes.?[0]);
    try std.testing.expect(args.no_themes);
    try std.testing.expectEqual(ThinkingLevel.high, args.thinking.?);
    try std.testing.expect(args.@"continue");
    try std.testing.expect(args.@"resume");
    try std.testing.expectEqualStrings("session-123", args.session.?);
    try std.testing.expectEqualStrings("session-456", args.fork.?);
    try std.testing.expectEqualStrings("./sessions", args.session_dir.?);
    try std.testing.expectEqual(@as(usize, 2), args.models.?.len);
    try std.testing.expectEqualStrings("anthropic/*", args.models.?[0]);
    try std.testing.expectEqualStrings("*gpt-5*", args.models.?[1]);
    try std.testing.expect(args.list_models);
    try std.testing.expectEqualStrings("sonnet", args.list_models_search.?);
    try std.testing.expect(args.no_session);
    try std.testing.expect(args.print);
    try std.testing.expectEqual(Mode.json, args.mode);
    try std.testing.expect(args.no_tools);
    try std.testing.expect(args.no_builtin_tools);
    try std.testing.expect(args.no_context_files);
    try std.testing.expect(args.offline);
    try std.testing.expect(args.verbose);
    try std.testing.expectEqualStrings("session.jsonl", args.@"export".?);
    try std.testing.expectEqual(@as(usize, 1), args.messages.?.len);
    try std.testing.expectEqualStrings("Summarize the repository", args.messages.?[0]);
    try std.testing.expectEqual(@as(usize, 2), args.file_args.?.len);
    try std.testing.expectEqualStrings("prompt.md", args.file_args.?[0]);
    try std.testing.expectEqualStrings("image.png", args.file_args.?[1]);
    try std.testing.expectEqual(@as(usize, 3), args.tools.?.len);
    try std.testing.expectEqualStrings("read", args.tools.?[0]);
    try std.testing.expectEqualStrings("grep", args.tools.?[1]);
    try std.testing.expectEqualStrings("ls", args.tools.?[2]);
}

test "parse args accepts TS RPC mode" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{ "--mode", "rpc" });
    defer args.deinit(allocator);

    try std.testing.expectEqual(Mode.ts_rpc, args.mode);
}

test "parse args keeps legacy JSON-RPC mode under explicit json-rpc spelling" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{ "--mode", "json-rpc" });
    defer args.deinit(allocator);

    try std.testing.expectEqual(Mode.rpc, args.mode);
}

test "parse args accepts TS-compatible short tool aliases" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{ "-nt", "-t", "read,bash" });
    defer args.deinit(allocator);

    try std.testing.expect(args.no_tools);
    try std.testing.expectEqual(@as(usize, 2), args.tools.?.len);
    try std.testing.expectEqualStrings("read", args.tools.?[0]);
    try std.testing.expectEqualStrings("bash", args.tools.?[1]);
}

test "parse args preserves repeatable append system prompt order" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{
        "--append-system-prompt",
        "First appended chunk.",
        "--append-system-prompt",
        "Second appended chunk.",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), args.append_system_prompt.?.len);
    try std.testing.expectEqualStrings("First appended chunk.", args.append_system_prompt.?[0]);
    try std.testing.expectEqualStrings("Second appended chunk.", args.append_system_prompt.?[1]);
}

test "parse args consumes print prompt that starts with YAML frontmatter" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{ "-p", "---\ntitle: hello\n---\nSay hi." });
    defer args.deinit(allocator);

    try std.testing.expect(args.print);
    try std.testing.expectEqual(@as(usize, 1), args.messages.?.len);
    try std.testing.expectEqualStrings("---\ntitle: hello\n---\nSay hi.", args.messages.?[0]);
}

test "parse args collects unknown long flags as boolean by default" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{ "--plan", "--verbose" });
    defer args.deinit(allocator);

    try std.testing.expect(args.unknown_flags != null);
    try std.testing.expectEqual(@as(usize, 1), args.unknown_flags.?.len);
    try std.testing.expectEqualStrings("plan", args.unknown_flags.?[0].name);
    try std.testing.expect(args.unknown_flags.?[0].value == .boolean);
    try std.testing.expect(args.unknown_flags.?[0].value.boolean);
    try std.testing.expect(args.verbose);
}

test "parse args collects unknown long flag with following string value" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{ "--model-alias", "claude-haiku" });
    defer args.deinit(allocator);

    try std.testing.expect(args.unknown_flags != null);
    try std.testing.expectEqual(@as(usize, 1), args.unknown_flags.?.len);
    try std.testing.expectEqualStrings("model-alias", args.unknown_flags.?[0].name);
    try std.testing.expect(args.unknown_flags.?[0].value == .string);
    try std.testing.expectEqualStrings("claude-haiku", args.unknown_flags.?[0].value.string);
}

test "parse args collects unknown long flag with equals form" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{"--plan-mode=ready"});
    defer args.deinit(allocator);

    try std.testing.expect(args.unknown_flags != null);
    try std.testing.expectEqual(@as(usize, 1), args.unknown_flags.?.len);
    try std.testing.expectEqualStrings("plan-mode", args.unknown_flags.?[0].name);
    try std.testing.expect(args.unknown_flags.?[0].value == .string);
    try std.testing.expectEqualStrings("ready", args.unknown_flags.?[0].value.string);
}

test "parse args still rejects unknown short options" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownOption, parseArgs(allocator, &.{"-x"}));
}

test "helpTextWithExtensions includes registered extension flags" {
    const allocator = std.testing.allocator;
    const flags = [_]ExtensionFlagInfo{
        .{
            .name = "plan",
            .description = "Enable plan mode",
            .type_kind = .boolean,
            .extension_path = "/tmp/plan.ts",
        },
        .{
            .name = "model-alias",
            .description = null,
            .type_kind = .string,
            .extension_path = "/tmp/alias.ts",
        },
    };
    const help = try helpTextWithExtensions(allocator, "0.1.0", &flags);
    defer allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "Extension CLI Flags:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Enable plan mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--model-alias <value>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "/tmp/alias.ts") != null);
}

test "helpTextWithExtensionDiagnostics includes rejected extension flag diagnostics" {
    const allocator = std.testing.allocator;
    const diagnostics = [_]ExtensionFlagDiagnosticInfo{.{
        .severity = "error",
        .code = "extension_flag.builtin_collision",
        .owner = "/tmp/ext.ts",
        .source = "/tmp/ext.ts",
        .flag_name = "model",
        .reason = "collides with built-in option",
        .message = "Extension flag \"--model\" from /tmp/ext.ts collides with a built-in option",
    }};
    const help = try helpTextWithExtensionDiagnostics(allocator, "0.1.0", &.{}, &diagnostics);
    defer allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "Extension CLI Flag Diagnostics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "extension_flag.builtin_collision") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "owner=/tmp/ext.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "source=/tmp/ext.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "flag=--model") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "reason=collides with built-in option") != null);
}

test "parse args supports help and version" {
    const allocator = std.testing.allocator;

    var help_args = try parseArgs(allocator, &.{"--help"});
    defer help_args.deinit(allocator);
    try std.testing.expect(help_args.help);

    var version_args = try parseArgs(allocator, &.{"--version"});
    defer version_args.deinit(allocator);
    try std.testing.expect(version_args.version);
}

test "parse args accepts provider flag" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{ "--provider", "faux" });
    defer args.deinit(allocator);

    try std.testing.expect(args.unknown_flags == null);
    try std.testing.expectEqualStrings("faux", args.provider.?);
}

test "parse args frees previous tool list when --tools is repeated" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{
        "--tools",
        "read,grep",
        "--tools",
        "ls",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), args.tools.?.len);
    try std.testing.expectEqualStrings("ls", args.tools.?[0]);
}

test "parse args frees previous model list when --models is repeated" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{
        "--models",
        "anthropic/*,openai/*",
        "--models",
        "faux/*",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), args.models.?.len);
    try std.testing.expectEqualStrings("faux/*", args.models.?[0]);
}

test "parse args supports list-models without a search term" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{"--list-models"});
    defer args.deinit(allocator);

    try std.testing.expect(args.list_models);
    try std.testing.expect(args.list_models_search == null);
}

test "parse args keeps multiple positional messages separate" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{
        "Summarize",
        "the",
        "repository",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), args.messages.?.len);
    try std.testing.expectEqualStrings("Summarize", args.messages.?[0]);
    try std.testing.expectEqualStrings("the", args.messages.?[1]);
    try std.testing.expectEqualStrings("repository", args.messages.?[2]);
}

test "parse args keeps @file arguments separate from the prompt" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{
        "@notes.md",
        "Explain",
        "@diagram.png",
        "this",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), args.messages.?.len);
    try std.testing.expectEqualStrings("Explain", args.messages.?[0]);
    try std.testing.expectEqualStrings("this", args.messages.?[1]);
    try std.testing.expectEqual(@as(usize, 2), args.file_args.?.len);
    try std.testing.expectEqualStrings("notes.md", args.file_args.?[0]);
    try std.testing.expectEqualStrings("diagram.png", args.file_args.?[1]);
}

test "parse args rejects invalid thinking level" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidThinkingLevel, parseArgs(allocator, &.{ "--thinking", "turbo" }));
}

test "help text mentions expected flags" {
    const allocator = std.testing.allocator;
    const help = try helpText(allocator, "0.1.0");
    defer allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "--model <model>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--provider <provider>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--api-key <key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--thinking <level>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--extension, -e <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-extensions, -ne") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--skill <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-skills, -ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--prompt-template <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-prompt-templates, -np") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--theme <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-themes") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--continue, -c") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--resume, -r") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session <id|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--fork <id|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session-dir <dir>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-session") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--models <patterns>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--list-models [search]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--print, -p") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--mode, -mode <mode>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "rpc, json-rpc") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--append-system-prompt <text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "repeatable") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--tools, -t <names>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-tools, -nt") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-builtin-tools, -nbt") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-context-files, -nc") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--export <file>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--offline") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--help, -h") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "[@files...] [messages...]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Examples:") != null);
}

test "VAL-M12-PKG-013 top-level help lists package and config commands" {
    const allocator = std.testing.allocator;
    const help = try helpText(allocator, "0.1.0");
    defer allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "pi install <source>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "pi remove <source>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "pi uninstall <source>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "pi update [source]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "pi list") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "pi config") != null);
    // Existing core options must still appear after the new Commands block.
    try std.testing.expect(std.mem.indexOf(u8, help, "--model <model>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "release/binary packaging") != null);
}

test "version text prints version" {
    const allocator = std.testing.allocator;
    const version = try versionText(allocator, "0.1.0");
    defer allocator.free(version);

    try std.testing.expectEqualStrings("pi version 0.1.0\n", version);
}
