const std = @import("std");

const Config = struct {
    long_function_warning_lines: usize = 160,
    fail_on_warning: bool = false,
};

const EntryKind = enum {
    directory,
    file,
    other,
};

const TreeEntry = struct {
    path: []u8,
    kind: EntryKind,
    transferred_to_file_list: bool = false,
};

const LongFunctionWarning = struct {
    path: []const u8,
    start_line: usize,
    line_count: usize,
    function_name: []u8,
};

const AllowlistedLongFunction = struct {
    path: []const u8,
    function_name: []const u8,
    reason: []const u8,
};

const TestRootWarning = struct {
    path: []const u8,
};

const AllowlistedTestFile = struct {
    path: []const u8,
    reason: []const u8,
};

// These roots intentionally mirror the build graph roots that compile Zig tests.
// If a new split module contains `test` blocks, import it from one of these roots
// (for example the focused TUI/rendering roots) or add a temporary, reasoned
// allowlist entry below. The check is report-only today and becomes useful when
// refactors move tests into leaf modules that would otherwise silently disappear.
const known_test_roots = [_][]const u8{
    "src/main.zig",
    "packages/pi-ai/src/root.zig",
    "packages/pi-agent-core/src/root.zig",
    "packages/pi-coding-agent/src/root.zig",
    "packages/pi-coding-agent/src/tests/interactive_mode_rendering_test_root.zig",
    "packages/pi-tui/src/root.zig",
    "packages/pi-types/src/root.zig",
    "packages/pi-shared/src/root.zig",
    "packages/pi-cli/src/root.zig",
    "src/web_ui/root.zig",
    "test/tidy.zig",
};

const long_function_allowlist = [_]AllowlistedLongFunction{
    .{ .path = "packages/pi-ai/src/providers/azure_openai_responses.zig", .function_name = "parseSseStreamLines", .reason = "pre-existing provider SSE parser debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-ai/src/providers/google.zig", .function_name = "parseSseStreamLines", .reason = "pre-existing provider SSE parser debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-ai/src/providers/kimi.zig", .function_name = "parseSseStreamLines", .reason = "pre-existing provider SSE parser debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-ai/src/providers/mistral.zig", .function_name = "parseSseStreamLines", .reason = "pre-existing provider SSE parser debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-ai/src/providers/openai.zig", .function_name = "parseSseStreamLines", .reason = "pre-existing provider SSE parser debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-ai/src/providers/openai.zig", .function_name = "buildRequestPayloadWithCacheRetentionEnv", .reason = "pre-existing OpenAI payload construction debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-ai/src/providers/openai.zig", .function_name = "buildAssistantMessage", .reason = "pre-existing OpenAI response conversion debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-ai/src/providers/openai_codex_responses.zig", .function_name = "parseSseStreamLines", .reason = "pre-existing provider SSE parser debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-ai/src/providers/openai_responses.zig", .function_name = "parseSseStreamLines", .reason = "pre-existing provider SSE parser debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-cli/src/args.zig", .function_name = "parseArgs", .reason = "pre-existing CLI argument parser debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/config/config.zig", .function_name = "loadModelsConfig", .reason = "pre-existing config loader debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/extensions/extension_registry.zig", .function_name = "applyHostFrame", .reason = "pre-existing registry frame dispatcher debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/interactive_mode.zig", .function_name = "runInteractiveMode", .reason = "pre-existing interactive mode orchestration debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/interactive_mode/input_dispatch.zig", .function_name = "handleInputKeyWithModifiers", .reason = "pre-existing key dispatch debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/interactive_mode/slash_commands.zig", .function_name = "handleSlashCommand", .reason = "pre-existing slash command dispatcher debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/packages/package_command_parser.zig", .function_name = "parsePackageCommand", .reason = "extracted package command parser remains tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/sessions/session_html_export.zig", .function_name = "renderSessionHtml", .reason = "pre-existing session HTML renderer debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/sessions/session_manager.zig", .function_name = "parseEntryLine", .reason = "pre-existing session entry parser debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/tools/bash.zig", .function_name = "executeWithUpdates", .reason = "pre-existing bash execution orchestration debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/tools/grep.zig", .function_name = "execute", .reason = "pre-existing grep tool orchestration debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/modes/ts_rpc_mode.zig", .function_name = "handleCommand", .reason = "pre-existing TS-RPC command dispatcher debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/modes/ts_rpc_mode.zig", .function_name = "writeExtensionUIRequestFromHost", .reason = "pre-existing TS-RPC UI bridge serialization debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "packages/pi-coding-agent/src/modes/ts_rpc_mode.zig", .function_name = "emitExtensionTurnEndFrame", .reason = "pre-existing TS-RPC turn-end emission debt tracked by exact function allowlist so new long functions still fail tidy" },
    .{ .path = "src/main.zig", .function_name = "runCliWithInput", .reason = "pre-existing CLI orchestration debt tracked by exact function allowlist so new long functions still fail tidy" },
};

const test_root_coverage_allowlist = [_]AllowlistedTestFile{
    .{ .path = "packages/pi-ai/src/oauth/pkce.zig", .reason = "pre-existing standalone OAuth PKCE scaffold is not reachable from current build roots; keep explicit until OAuth module wiring is updated" },
};

const Tidy = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    files_scanned: usize = 0,
    warnings: usize = 0,
    emit_warnings: bool = true,
    zig_files: std.ArrayList([]u8) = .empty,
    test_files: std.ArrayList([]const u8) = .empty,
    reachable_files: std.StringHashMap(void),
    long_function_warnings: std.ArrayList(LongFunctionWarning) = .empty,
    test_root_warnings: std.ArrayList(TestRootWarning) = .empty,

    fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Tidy {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .reachable_files = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *Tidy) void {
        for (self.zig_files.items) |path| self.allocator.free(path);
        self.zig_files.deinit(self.allocator);
        self.test_files.deinit(self.allocator);

        var reachable_iterator = self.reachable_files.iterator();
        while (reachable_iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.reachable_files.deinit();

        for (self.long_function_warnings.items) |warning| self.allocator.free(warning.function_name);
        self.long_function_warnings.deinit(self.allocator);
        self.test_root_warnings.deinit(self.allocator);
    }

    fn scanTree(self: *Tidy, root_path: []const u8) !void {
        var dir = try std.Io.Dir.openDir(.cwd(), self.io, root_path, .{ .iterate = true });
        defer dir.close(self.io);

        var entries = std.ArrayList(TreeEntry).empty;
        defer {
            for (entries.items) |entry| {
                if (!entry.transferred_to_file_list) self.allocator.free(entry.path);
            }
            entries.deinit(self.allocator);
        }

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            const child_path = try std.fs.path.join(self.allocator, &.{ root_path, entry.name });
            errdefer self.allocator.free(child_path);

            const kind: EntryKind = switch (entry.kind) {
                .directory => .directory,
                .file => .file,
                else => .other,
            };
            try entries.append(self.allocator, .{ .path = child_path, .kind = kind });
        }

        std.mem.sort(TreeEntry, entries.items, {}, struct {
            fn lessThan(_: void, lhs: TreeEntry, rhs: TreeEntry) bool {
                return std.mem.order(u8, lhs.path, rhs.path) == .lt;
            }
        }.lessThan);

        for (entries.items) |*entry| {
            switch (entry.kind) {
                .directory => try self.scanTree(entry.path),
                .file => {
                    if (std.mem.endsWith(u8, entry.path, ".zig")) {
                        try self.zig_files.append(self.allocator, entry.path);
                        entry.transferred_to_file_list = true;
                    }
                },
                .other => {},
            }
        }
    }

    fn runChecks(self: *Tidy) !void {
        std.mem.sort([]u8, self.zig_files.items, {}, struct {
            fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);

        for (self.zig_files.items) |path| try self.scanFile(path);
        try self.scanTestRootCoverage();
        try validateReviewTestMatrix(self.allocator, self.io, "docs/review/05_test_matrix.md");
        try self.emitReport();
    }

    fn emitReport(self: *Tidy) !void {
        std.mem.sort(LongFunctionWarning, self.long_function_warnings.items, {}, struct {
            fn lessThan(_: void, lhs: LongFunctionWarning, rhs: LongFunctionWarning) bool {
                const path_order = std.mem.order(u8, lhs.path, rhs.path);
                if (path_order != .eq) return path_order == .lt;
                if (lhs.start_line != rhs.start_line) return lhs.start_line < rhs.start_line;
                return std.mem.order(u8, lhs.function_name, rhs.function_name) == .lt;
            }
        }.lessThan);

        std.mem.sort(TestRootWarning, self.test_root_warnings.items, {}, struct {
            fn lessThan(_: void, lhs: TestRootWarning, rhs: TestRootWarning) bool {
                return std.mem.order(u8, lhs.path, rhs.path) == .lt;
            }
        }.lessThan);

        if (self.emit_warnings) {
            for (self.long_function_warnings.items) |warning| {
                std.debug.print(
                    "{s}:{d}: warning: function '{s}' is {d} lines; tidy target is <= {d}\n",
                    .{
                        warning.path,
                        warning.start_line,
                        warning.function_name,
                        warning.line_count,
                        self.config.long_function_warning_lines,
                    },
                );
            }
            for (self.test_root_warnings.items) |warning| {
                std.debug.print(
                    "{s}: warning: Zig file contains test blocks but is unreachable from known tidy test roots; import it from a root or add a reasoned allowlist entry\n",
                    .{warning.path},
                );
            }
        }
    }

    fn scanFile(self: *Tidy, path: []const u8) !void {
        self.files_scanned += 1;

        const bytes = try std.Io.Dir.readFileAlloc(
            .cwd(),
            self.io,
            path,
            self.allocator,
            .limited(4 * 1024 * 1024),
        );
        defer self.allocator.free(bytes);

        try self.scanLongFunctions(path, bytes);
        if (hasTestBlock(bytes)) try self.test_files.append(self.allocator, path);
    }

    fn scanLongFunctions(self: *Tidy, path: []const u8, bytes: []const u8) !void {
        _ = try scanLongFunctionsInFile(path, bytes, self.config.long_function_warning_lines, self);
    }

    fn emitLongFunctionWarning(
        self: *Tidy,
        path: []const u8,
        start_line: usize,
        line_count: usize,
        function_name: []const u8,
    ) !void {
        self.warnings += 1;
        try self.long_function_warnings.append(self.allocator, .{
            .path = path,
            .start_line = start_line,
            .line_count = line_count,
            .function_name = try self.allocator.dupe(u8, function_name),
        });
    }

    fn scanTestRootCoverage(self: *Tidy) !void {
        for (known_test_roots) |root| try self.markReachable(root);
        _ = try reportUnreachableTestFiles(
            self,
            self.test_files.items,
            &self.reachable_files,
            &test_root_coverage_allowlist,
        );
    }

    fn markReachable(self: *Tidy, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const entry = try self.reachable_files.getOrPut(owned_path);
        if (entry.found_existing) {
            self.allocator.free(owned_path);
            return;
        }

        const bytes = std.Io.Dir.readFileAlloc(
            .cwd(),
            self.io,
            path,
            self.allocator,
            .limited(4 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var cursor: usize = 0;
        const marker = "@import(\"";
        while (std.mem.indexOfPos(u8, bytes, cursor, marker)) |start| {
            const literal_start = start + marker.len;
            const rest = bytes[literal_start..];
            const quote_index = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            cursor = literal_start + quote_index + 1;

            const import_spec = rest[0..quote_index];
            if (!std.mem.endsWith(u8, import_spec, ".zig")) continue;
            const resolved = try resolveImportPath(self.allocator, path, import_spec);
            defer self.allocator.free(resolved);
            try self.markReachable(resolved);
        }
    }
};

const FunctionSpan = struct {
    start_line: usize,
    function_name: []const u8,
    brace_depth: i32 = 0,
    saw_open_brace: bool = false,
};

const SyntaxLineScan = struct {
    brace_delta: i32 = 0,
    saw_open_brace: bool = false,
    saw_semicolon: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var config = Config{};
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fail-on-warning")) {
            config.fail_on_warning = true;
        } else {
            std.debug.print("unknown tidy argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    var tidy = Tidy.init(init.gpa, init.io, config);
    defer tidy.deinit();
    try tidy.scanTree("src");
    try tidy.scanTree("packages");
    try tidy.scanTree("test");
    try tidy.runChecks();

    std.debug.print(
        "tidy: scanned {d} Zig files, {d} warning(s)\n",
        .{ tidy.files_scanned, tidy.warnings },
    );

    if (config.fail_on_warning and tidy.warnings > 0) return error.TidyWarnings;
}

fn scanLongFunctionsInFile(
    path: []const u8,
    bytes: []const u8,
    threshold: usize,
    tidy: *Tidy,
) !usize {
    var warning_count: usize = 0;
    var span: ?FunctionSpan = null;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| : (line_number += 1) {
        if (span == null) {
            if (functionName(line)) |function_name| {
                span = .{
                    .start_line = line_number,
                    .function_name = function_name,
                };
            }
        }

        if (span) |*active| {
            const syntax = scanSyntaxLine(line);
            active.brace_depth += syntax.brace_delta;
            if (syntax.saw_open_brace) {
                active.saw_open_brace = true;
            }
            if (!active.saw_open_brace and syntax.saw_semicolon) {
                span = null;
                continue;
            }
            if (active.saw_open_brace and active.brace_depth <= 0) {
                const line_count = line_number - active.start_line + 1;
                if (line_count > threshold) {
                    if (!isAllowedLongFunction(path, active.function_name, &long_function_allowlist)) {
                        try tidy.emitLongFunctionWarning(
                            path,
                            active.start_line,
                            line_count,
                            active.function_name,
                        );
                        warning_count += 1;
                    }
                }
                span = null;
            }
        }
    }
    return warning_count;
}

fn isAllowedLongFunction(path: []const u8, function_name: []const u8, allowlist: []const AllowlistedLongFunction) bool {
    for (allowlist) |entry| {
        if (std.mem.eql(u8, entry.path, path) and std.mem.eql(u8, entry.function_name, function_name)) return true;
    }
    return false;
}

fn functionName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    const after_fn = inline for (.{
        "pub inline fn ",
        "pub fn ",
        "inline fn ",
        "export fn ",
        "fn ",
    }) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) break trimmed[prefix.len..];
    } else return null;

    const paren_index = std.mem.indexOfScalar(u8, after_fn, '(') orelse return null;
    if (paren_index == 0) return null;
    return std.mem.trim(u8, after_fn[0..paren_index], " \t");
}

fn braceDelta(line: []const u8) i32 {
    return scanSyntaxLine(line).brace_delta;
}

fn scanSyntaxLine(line: []const u8) SyntaxLineScan {
    var scan = SyntaxLineScan{};
    var index: usize = 0;
    while (index < line.len) {
        const byte = line[index];
        switch (byte) {
            '/' => {
                if (index + 1 < line.len and line[index + 1] == '/') break;
                index += 1;
            },
            '\\' => {
                if (index + 1 < line.len and line[index + 1] == '\\') break;
                index += 1;
            },
            '"' => index = skipQuotedLiteral(line, index, '"'),
            '\'' => index = skipQuotedLiteral(line, index, '\''),
            '{' => {
                scan.brace_delta += 1;
                scan.saw_open_brace = true;
                index += 1;
            },
            '}' => {
                scan.brace_delta -= 1;
                index += 1;
            },
            ';' => {
                scan.saw_semicolon = true;
                index += 1;
            },
            else => index += 1,
        }
    }
    return scan;
}

fn skipQuotedLiteral(line: []const u8, start: usize, quote: u8) usize {
    var index = start + 1;
    while (index < line.len) {
        switch (line[index]) {
            '\\' => {
                index += 1;
                if (index < line.len) index += 1;
            },
            else => |byte| {
                index += 1;
                if (byte == quote) return index;
            },
        }
    }
    return line.len;
}

fn rawBraceDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    for (line) |byte| {
        switch (byte) {
            '{' => delta += 1,
            '}' => delta -= 1,
            else => {},
        }
    }
    return delta;
}

fn hasTestBlock(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "test \"") or std.mem.startsWith(u8, trimmed, "test {")) return true;
    }
    return false;
}

fn validateReviewTestMatrix(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const bytes = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        path,
        allocator,
        .limited(512 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    validateReviewTestMatrixBytes(bytes) catch |err| {
        std.debug.print(
            "{s}: error: matrix row contains unresolved missing/partial/unknown cell marker\n",
            .{path},
        );
        return err;
    };
}

fn validateReviewTestMatrixBytes(bytes: []const u8) !void {
    var in_matrix = false;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| : (line_number += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "## Matrix")) {
            in_matrix = true;
            continue;
        }
        if (in_matrix and std.mem.startsWith(u8, trimmed, "## Evidence notes")) {
            return;
        }
        if (!in_matrix or !std.mem.startsWith(u8, trimmed, "|")) continue;
        if (std.mem.startsWith(u8, trimmed, "| Provider ") or std.mem.startsWith(u8, trimmed, "|---")) continue;

        if (std.mem.indexOf(u8, trimmed, "❌") != null or
            std.mem.indexOf(u8, trimmed, "⚠️") != null or
            hasUnknownMatrixCell(trimmed))
        {
            return error.UnresolvedReviewMatrixCell;
        }
    }
}

fn hasUnknownMatrixCell(line: []const u8) bool {
    var cells = std.mem.splitScalar(u8, line, '|');
    _ = cells.next();
    while (cells.next()) |cell| {
        const trimmed = std.mem.trim(u8, cell, " \t\r");
        if (std.mem.eql(u8, trimmed, "?")) return true;
    }
    return false;
}

fn resolveImportPath(allocator: std.mem.Allocator, importer_path: []const u8, import_spec: []const u8) ![]u8 {
    const base_dir = std.fs.path.dirname(importer_path) orelse "";
    const joined = if (base_dir.len == 0)
        try allocator.dupe(u8, import_spec)
    else
        try std.fs.path.join(allocator, &.{ base_dir, import_spec });
    defer allocator.free(joined);
    return normalizeRelativePath(allocator, joined);
}

fn normalizeRelativePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var segments = std.ArrayList([]const u8).empty;
    defer segments.deinit(allocator);

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(allocator, part);
    }

    return std.mem.join(allocator, "/", segments.items);
}

fn reportUnreachableTestFiles(
    tidy: *Tidy,
    test_files: []const []const u8,
    reachable_files: *std.StringHashMap(void),
    allowlist: []const AllowlistedTestFile,
) !usize {
    var warning_count: usize = 0;
    for (test_files) |path| {
        if (reachable_files.contains(path)) continue;
        if (isAllowedUnreachableTest(path, allowlist)) continue;
        tidy.warnings += 1;
        warning_count += 1;
        try tidy.test_root_warnings.append(tidy.allocator, .{ .path = path });
    }
    return warning_count;
}

fn isAllowedUnreachableTest(path: []const u8, allowlist: []const AllowlistedTestFile) bool {
    for (allowlist) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

test "functionName recognizes common Zig function declarations" {
    try std.testing.expectEqualStrings("main", functionName("pub fn main() void {").?);
    try std.testing.expectEqualStrings("helper", functionName("fn helper() void {").?);
    try std.testing.expectEqualStrings("scan", functionName("inline fn scan() void {").?);
    try std.testing.expectEqual(@as(?[]const u8, null), functionName("const value = 1;"));
}

test "scanLongFunctions reports only functions above threshold" {
    const source =
        \\fn short() void {
        \\}
        \\fn long() void {
        \\    if (true) {
        \\    }
        \\}
    ;
    var tidy = Tidy{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .config = .{ .long_function_warning_lines = 3 },
        .emit_warnings = false,
        .reachable_files = std.StringHashMap(void).init(std.testing.allocator),
    };
    defer tidy.deinit();
    const warnings = try scanLongFunctionsInFile("sample.zig", source, 3, &tidy);
    try std.testing.expectEqual(@as(usize, 1), warnings);
    try std.testing.expectEqual(@as(usize, 1), tidy.warnings);
    try std.testing.expectEqual(@as(usize, 1), tidy.long_function_warnings.items.len);
    try std.testing.expectEqualStrings("long", tidy.long_function_warnings.items[0].function_name);
}

test "scanLongFunctions ignores braces in strings comments and multiline strings" {
    const source =
        \\fn literalBraces() void {
        \\    const open = "{";
        \\    const close = "}";
        \\    const escaped = "\"{\"";
        \\    const character = '{';
        \\    // { comment brace should not extend the function
        \\    const multiline =
        \\        \\{
        \\        \\}
        \\    ;
        \\}
        \\fn realLong() void {
        \\    const value = 1;
        \\    if (true) {
        \\        _ = value;
        \\    }
        \\    if (false) {
        \\    }
        \\    if (true) {
        \\    }
        \\    if (false) {
        \\    }
        \\    if (true) {
        \\    }
        \\}
    ;
    var tidy = Tidy{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .config = .{ .long_function_warning_lines = 11 },
        .emit_warnings = false,
        .reachable_files = std.StringHashMap(void).init(std.testing.allocator),
    };
    defer tidy.deinit();
    const warnings = try scanLongFunctionsInFile("sample.zig", source, 11, &tidy);
    try std.testing.expectEqual(@as(usize, 1), warnings);
    try std.testing.expectEqual(@as(usize, 1), tidy.warnings);
    try std.testing.expectEqual(@as(usize, 1), tidy.long_function_warnings.items.len);
    try std.testing.expectEqual(@as(usize, 12), tidy.long_function_warnings.items[0].start_line);
    try std.testing.expectEqualStrings("realLong", tidy.long_function_warnings.items[0].function_name);
}

test "scanLongFunctions treats real scopes and prototypes separately from comments" {
    const source =
        \\fn declared() void; // { not a body
        \\fn realScope() void {
        \\    if (true) {
        \\        // } comment brace should not close the scope
        \\    }
        \\}
    ;
    var tidy = Tidy{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .config = .{ .long_function_warning_lines = 3 },
        .emit_warnings = false,
        .reachable_files = std.StringHashMap(void).init(std.testing.allocator),
    };
    defer tidy.deinit();
    const warnings = try scanLongFunctionsInFile("sample.zig", source, 3, &tidy);
    try std.testing.expectEqual(@as(usize, 1), warnings);
    try std.testing.expectEqual(@as(usize, 1), tidy.warnings);
    try std.testing.expectEqual(@as(usize, 1), tidy.long_function_warnings.items.len);
    try std.testing.expectEqual(@as(usize, 2), tidy.long_function_warnings.items[0].start_line);
    try std.testing.expectEqualStrings("realScope", tidy.long_function_warnings.items[0].function_name);
}

test "scanSyntaxLine ignores literal and comment braces while counting real syntax" {
    const line =
        \\if (ready) { const text = "{\"}"; const char = '}'; } // {
    ;
    const scan = scanSyntaxLine(line);
    try std.testing.expectEqual(@as(i32, 0), scan.brace_delta);
    try std.testing.expect(scan.saw_open_brace);
    try std.testing.expect(scan.saw_semicolon);

    try std.testing.expectEqual(@as(i32, 1), rawBraceDelta(
        \\if (ready) {
    ));
}

test "scanLongFunctions suppresses exact allowlisted legacy functions" {
    const source =
        \\fn parseSseStreamLines() void {
        \\    if (true) {
        \\    }
        \\}
    ;
    var tidy = Tidy{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .config = .{ .long_function_warning_lines = 3 },
        .emit_warnings = false,
        .reachable_files = std.StringHashMap(void).init(std.testing.allocator),
    };
    defer tidy.deinit();
    const warnings = try scanLongFunctionsInFile("packages/pi-ai/src/providers/openai.zig", source, 3, &tidy);
    try std.testing.expectEqual(@as(usize, 0), warnings);
    try std.testing.expectEqual(@as(usize, 0), tidy.warnings);
    try std.testing.expectEqual(@as(usize, 0), tidy.long_function_warnings.items.len);
}

test "resolveImportPath normalizes relative Zig imports" {
    const allocator = std.testing.allocator;
    const resolved = try resolveImportPath(allocator, "src/coding_agent/root.zig", "../ai/types.zig");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("src/ai/types.zig", resolved);
}

test "test-root coverage reports unreachable test modules and respects allowlist" {
    var tidy = Tidy{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .config = .{},
        .emit_warnings = false,
        .reachable_files = std.StringHashMap(void).init(std.testing.allocator),
    };
    defer tidy.deinit();

    try tidy.reachable_files.put(try std.testing.allocator.dupe(u8, "src/reached.zig"), {});
    const test_files = [_][]const u8{
        "src/reached.zig",
        "src/unreachable.zig",
        "src/allowed.zig",
    };
    const allowlist = [_]AllowlistedTestFile{.{
        .path = "src/allowed.zig",
        .reason = "fixture proves intentional standalone tests can be temporarily allowed",
    }};

    const warnings = try reportUnreachableTestFiles(&tidy, &test_files, &tidy.reachable_files, &allowlist);
    try std.testing.expectEqual(@as(usize, 1), warnings);
    try std.testing.expectEqual(@as(usize, 1), tidy.warnings);
    try std.testing.expectEqual(@as(usize, 1), tidy.test_root_warnings.items.len);
    try std.testing.expectEqualStrings("src/unreachable.zig", tidy.test_root_warnings.items[0].path);
}

test "hasTestBlock detects named and anonymous Zig tests" {
    try std.testing.expect(hasTestBlock("test \"named\" {}"));
    try std.testing.expect(hasTestBlock("test { _ = 1; }"));
    try std.testing.expect(!hasTestBlock("pub fn main() void {}"));
    try std.testing.expect(!hasTestBlock("std.debug.print(\"Comparator negative self-test {s}\", .{name});"));
}

test "review matrix check rejects unresolved missing partial and unknown cells" {
    const clean =
        \\# Test Coverage Matrix
        \\
        \\## Matrix
        \\
        \\| Provider | S1 | S2 |
        \\|---|---|---|
        \\| faux | ✅ | Deferred |
        \\
        \\## Evidence notes
    ;
    try validateReviewTestMatrixBytes(clean);

    const missing =
        \\## Matrix
        \\| Provider | S1 |
        \\|---|---|
        \\| faux | ❌ |
        \\## Evidence notes
    ;
    try std.testing.expectError(error.UnresolvedReviewMatrixCell, validateReviewTestMatrixBytes(missing));

    const partial =
        \\## Matrix
        \\| Provider | S1 |
        \\|---|---|
        \\| faux | ⚠️ |
        \\## Evidence notes
    ;
    try std.testing.expectError(error.UnresolvedReviewMatrixCell, validateReviewTestMatrixBytes(partial));

    const unknown =
        \\## Matrix
        \\| Provider | S1 |
        \\|---|---|
        \\| faux | ? |
        \\## Evidence notes
    ;
    try std.testing.expectError(error.UnresolvedReviewMatrixCell, validateReviewTestMatrixBytes(unknown));
}
