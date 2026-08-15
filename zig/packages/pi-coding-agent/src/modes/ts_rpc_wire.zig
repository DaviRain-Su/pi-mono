const std = @import("std");
const json_format = @import("../shared/json_format.zig");

/// Re-exported from coding_agent/shared/json_format.zig so the historical
/// `ts_rpc_wire.writeJsonString` import path keeps working. Internal callers
/// in this file just use `writeJsonString(...)` via the file-scope alias
/// below; new code should prefer `json_format.writeJsonString` directly.
pub const writeJsonString = json_format.writeJsonString;

/// Wire-protocol command set shared with the TypeScript ts-rpc runtime. Each
/// enum tag's `@tagName` is the byte-exact on-wire `type` string. The field
/// order here is the canonical iteration order surfaced via `command_types`.
///
/// `navigate_to` is intentionally absent — it is a Zig-only escape hatch that
/// bypasses the `isKnownCommandType` gate in `ts_rpc_mode.handleCommand`.
pub const TsRpcCommand = enum {
    prompt,
    steer,
    follow_up,
    abort,
    new_session,
    get_state,
    set_model,
    cycle_model,
    get_available_models,
    set_thinking_level,
    cycle_thinking_level,
    set_steering_mode,
    set_follow_up_mode,
    compact,
    set_auto_compaction,
    set_auto_retry,
    abort_retry,
    bash,
    abort_bash,
    get_session_stats,
    export_html,
    switch_session,
    fork,
    clone,
    get_fork_messages,
    get_last_assistant_text,
    set_session_name,
    get_messages,
    get_commands,
};

pub const command_types: [@typeInfo(TsRpcCommand).@"enum".fields.len][]const u8 = blk: {
    const fields = @typeInfo(TsRpcCommand).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, index| names[index] = field.name;
    break :blk names;
};

pub fn isKnownCommandType(command_type: []const u8) bool {
    return std.meta.stringToEnum(TsRpcCommand, command_type) != null;
}

pub fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (std.mem.endsWith(u8, line, "\r")) return line[0 .. line.len - 1];
    return line;
}

pub fn jsonParseErrorDetail(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const first_index = firstNonJsonWhitespaceIndex(line) orelse
        return try allocator.dupe(u8, "Unexpected end of JSON input");
    const trimmed = line[first_index..];

    // V8 does not expose JSON.parse diagnostics as a stable API, and embedding
    // V8/Node in normal Zig execution is out of scope for ts-rpc mode. This
    // mapper intentionally covers the generated malformed JSONL corpus syntax
    // classes byte-for-byte and falls back only for syntax outside that corpus.
    if (badUnicodeEscapeIndex(line)) |index| {
        return try std.fmt.allocPrint(
            allocator,
            "Bad Unicode escape in JSON at position {d} (line 1 column {d})",
            .{ index, index + 1 },
        );
    }

    if (hasUnterminatedString(line)) {
        return try std.fmt.allocPrint(
            allocator,
            "Unterminated string in JSON at position {d} (line 1 column {d})",
            .{ line.len, line.len + 1 },
        );
    }

    switch (trimmed[0]) {
        '{' => return try objectParseErrorDetail(allocator, line, first_index),
        '[' => return try arrayParseErrorDetail(allocator, line, first_index),
        't' => return try literalParseErrorDetail(allocator, line, first_index, "true"),
        'f' => return try literalParseErrorDetail(allocator, line, first_index, "false"),
        'n' => return try literalParseErrorDetail(allocator, line, first_index, "null"),
        '0'...'9', '-' => return try numberParseErrorDetail(allocator, line, first_index),
        else => return try unexpectedTokenDetail(allocator, line, first_index),
    }
}

pub fn writeSuccessResponseNoData(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: ?[]const u8,
    command: []const u8,
) !void {
    try writer.writeAll("{");
    try writeIdField(allocator, writer, id);
    try writer.writeAll("\"type\":\"response\",\"command\":");
    try writeJsonString(allocator, writer, command);
    try writer.writeAll(",\"success\":true}\n");
}

pub fn writeSuccessResponseRawData(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: ?[]const u8,
    command: []const u8,
    data_json: []const u8,
) !void {
    try writer.writeAll("{");
    try writeIdField(allocator, writer, id);
    try writer.writeAll("\"type\":\"response\",\"command\":");
    try writeJsonString(allocator, writer, command);
    try writer.writeAll(",\"success\":true,\"data\":");
    try writer.writeAll(data_json);
    try writer.writeAll("}\n");
}

pub fn writeErrorResponse(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: ?[]const u8,
    command: ?[]const u8,
    message: []const u8,
) !void {
    try writer.writeAll("{");
    try writeIdField(allocator, writer, id);
    try writer.writeAll("\"type\":\"response\"");
    if (command) |command_name| {
        try writer.writeAll(",\"command\":");
        try writeJsonString(allocator, writer, command_name);
    }
    try writer.writeAll(",\"success\":false,\"error\":");
    try writeJsonString(allocator, writer, message);
    try writer.writeAll("}\n");
}

pub fn writeExtensionUISelectRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    title: []const u8,
    options: []const []const u8,
    timeout_ms: ?u64,
) !void {
    try writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"method\":\"select\",\"title\":");
    try writeJsonString(allocator, writer, title);
    try writer.writeAll(",\"options\":[");
    for (options, 0..) |option, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, option);
    }
    try writer.writeAll("]");
    if (timeout_ms) |timeout| try writer.print(",\"timeout\":{d}", .{timeout});
    try writer.writeAll("}\n");
}

pub fn writeExtensionUIConfirmRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    title: []const u8,
    message: []const u8,
    timeout_ms: ?u64,
) !void {
    try writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"method\":\"confirm\",\"title\":");
    try writeJsonString(allocator, writer, title);
    try writer.writeAll(",\"message\":");
    try writeJsonString(allocator, writer, message);
    if (timeout_ms) |timeout| try writer.print(",\"timeout\":{d}", .{timeout});
    try writer.writeAll("}\n");
}

pub fn writeExtensionUIInputRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    title: []const u8,
    placeholder: ?[]const u8,
    timeout_ms: ?u64,
) !void {
    try writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"method\":\"input\",\"title\":");
    try writeJsonString(allocator, writer, title);
    if (placeholder) |text| {
        try writer.writeAll(",\"placeholder\":");
        try writeJsonString(allocator, writer, text);
    }
    if (timeout_ms) |timeout| try writer.print(",\"timeout\":{d}", .{timeout});
    try writer.writeAll("}\n");
}

pub fn writeExtensionUIEditorRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    title: []const u8,
    prefill: ?[]const u8,
) !void {
    try writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"method\":\"editor\",\"title\":");
    try writeJsonString(allocator, writer, title);
    if (prefill) |text| {
        try writer.writeAll(",\"prefill\":");
        try writeJsonString(allocator, writer, text);
    }
    try writer.writeAll("}\n");
}

pub fn writeExtensionUINotifyRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    message: []const u8,
    notify_type: ?[]const u8,
) !void {
    try writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"method\":\"notify\",\"message\":");
    try writeJsonString(allocator, writer, message);
    if (notify_type) |kind| {
        try writer.writeAll(",\"notifyType\":");
        try writeJsonString(allocator, writer, kind);
    }
    try writer.writeAll("}\n");
}

pub fn writeExtensionUISetStatusRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    status_key: []const u8,
    status_text: ?[]const u8,
) !void {
    try writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"method\":\"setStatus\",\"statusKey\":");
    try writeJsonString(allocator, writer, status_key);
    if (status_text) |text| {
        try writer.writeAll(",\"statusText\":");
        try writeJsonString(allocator, writer, text);
    }
    try writer.writeAll("}\n");
}

pub fn writeExtensionUISetWidgetRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    widget_key: []const u8,
    widget_lines: ?[]const []const u8,
    widget_placement: ?[]const u8,
) !void {
    try writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"method\":\"setWidget\",\"widgetKey\":");
    try writeJsonString(allocator, writer, widget_key);
    if (widget_lines) |lines| {
        try writer.writeAll(",\"widgetLines\":[");
        for (lines, 0..) |line, index| {
            if (index > 0) try writer.writeAll(",");
            try writeJsonString(allocator, writer, line);
        }
        try writer.writeAll("]");
    }
    if (widget_placement) |placement| {
        try writer.writeAll(",\"widgetPlacement\":");
        try writeJsonString(allocator, writer, placement);
    }
    try writer.writeAll("}\n");
}

pub fn writeExtensionUISetTitleRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    title: []const u8,
) !void {
    try writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"method\":\"setTitle\",\"title\":");
    try writeJsonString(allocator, writer, title);
    try writer.writeAll("}\n");
}

pub fn writeExtensionUISetEditorTextRequest(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    text: []const u8,
) !void {
    try writer.writeAll("{\"type\":\"extension_ui_request\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"method\":\"set_editor_text\",\"text\":");
    try writeJsonString(allocator, writer, text);
    try writer.writeAll("}\n");
}

pub fn writeIdField(allocator: std.mem.Allocator, writer: *std.Io.Writer, id: ?[]const u8) !void {
    if (id) |id_string| {
        try writer.writeAll("\"id\":");
        try writeJsonString(allocator, writer, id_string);
        try writer.writeAll(",");
    }
}

fn objectParseErrorDetail(allocator: std.mem.Allocator, line: []const u8, object_start: usize) ![]u8 {
    const after_open = firstNonJsonWhitespaceIndexFrom(line, object_start + 1) orelse object_start + 1;
    if (after_open >= line.len) {
        return try expectedPropertyNameOrCloseDetail(allocator, after_open);
    }
    if (line[after_open] == '}') {
        if (firstNonJsonWhitespaceIndexFrom(line, after_open + 1)) |extra_index| {
            return try unexpectedNonWhitespaceDetail(allocator, extra_index);
        }
        return try expectedPropertyNameOrCloseDetail(allocator, after_open);
    }
    if (line[after_open] != '"') {
        return try expectedPropertyNameOrCloseDetail(allocator, after_open);
    }

    if (scanJsonStringEnd(line, after_open)) |property_end| {
        const after_property = firstNonJsonWhitespaceIndexFrom(line, property_end + 1) orelse
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        if (line[after_property] != ':') {
            return try std.fmt.allocPrint(
                allocator,
                "Expected ':' after property name in JSON at position {d} (line 1 column {d})",
                .{ after_property, after_property + 1 },
            );
        }
        const value_start = firstNonJsonWhitespaceIndexFrom(line, after_property + 1) orelse
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        if (line[value_start] == '#') {
            return try unexpectedTokenDetail(allocator, line, value_start);
        }
    }

    if (lastNonJsonWhitespaceIndex(line)) |last_index| {
        if (line[last_index] == '}') {
            const before_close = previousNonJsonWhitespaceIndex(line, last_index);
            if (before_close != null and line[before_close.?] == ',') {
                return try std.fmt.allocPrint(
                    allocator,
                    "Expected double-quoted property name in JSON at position {d} (line 1 column {d})",
                    .{ last_index, last_index + 1 },
                );
            }
        }
        if (line[last_index] == ':' or line[last_index] == ',') {
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        }
    }

    return try allocator.dupe(u8, "Unexpected end of JSON input");
}

fn arrayParseErrorDetail(allocator: std.mem.Allocator, line: []const u8, array_start: usize) ![]u8 {
    const after_open = firstNonJsonWhitespaceIndexFrom(line, array_start + 1) orelse array_start + 1;
    if (after_open < line.len and line[after_open] == ']') {
        if (firstNonJsonWhitespaceIndexFrom(line, after_open + 1)) |extra_index| {
            return try unexpectedNonWhitespaceDetail(allocator, extra_index);
        }
    }
    if (lastNonJsonWhitespaceIndex(line)) |last_index| {
        if (line[last_index] == ']') {
            const before_close = previousNonJsonWhitespaceIndex(line, last_index);
            if (before_close != null and line[before_close.?] == ',') {
                return try unexpectedTokenDetail(allocator, line, last_index);
            }
        }
        if (line[last_index] == '[' or line[last_index] == ',') {
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        }
    }

    return try allocator.dupe(u8, "Unexpected end of JSON input");
}

fn literalParseErrorDetail(
    allocator: std.mem.Allocator,
    line: []const u8,
    start_index: usize,
    literal: []const u8,
) ![]u8 {
    var offset: usize = 0;
    while (offset < literal.len and start_index + offset < line.len and line[start_index + offset] == literal[offset]) {
        offset += 1;
    }

    if (offset == literal.len) {
        const after_literal = firstNonJsonWhitespaceIndexFrom(line, start_index + literal.len);
        if (after_literal) |token_index| return try unexpectedNonWhitespaceDetail(allocator, token_index);
        return try allocator.dupe(u8, "Unexpected end of JSON input");
    }

    if (start_index + offset >= line.len) {
        return try allocator.dupe(u8, "Unexpected end of JSON input");
    }
    return try unexpectedTokenDetail(allocator, line, start_index + offset);
}

fn numberParseErrorDetail(allocator: std.mem.Allocator, line: []const u8, start_index: usize) ![]u8 {
    var index = start_index;
    if (index < line.len and line[index] == '-') index += 1;
    while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    if (index < line.len and line[index] == '.') {
        index += 1;
        while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    }
    if (index < line.len and (line[index] == 'e' or line[index] == 'E')) {
        index += 1;
        if (index < line.len and (line[index] == '+' or line[index] == '-')) index += 1;
        while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    }
    if (firstNonJsonWhitespaceIndexFrom(line, index)) |extra_index| {
        return try unexpectedNonWhitespaceDetail(allocator, extra_index);
    }
    return try allocator.dupe(u8, "Unexpected end of JSON input");
}

fn unexpectedNonWhitespaceDetail(allocator: std.mem.Allocator, index: usize) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Unexpected non-whitespace character after JSON at position {d} (line 1 column {d})",
        .{ index, index + 1 },
    );
}

fn unexpectedTokenDetail(allocator: std.mem.Allocator, line: []const u8, token_index: usize) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Unexpected token '{c}', \"{s}\" is not valid JSON",
        .{ line[token_index], line },
    );
}

fn expectedPropertyNameOrCloseDetail(allocator: std.mem.Allocator, index: usize) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Expected property name or '}}' in JSON at position {d} (line 1 column {d})",
        .{ index, index + 1 },
    );
}

fn hasUnterminatedString(line: []const u8) bool {
    var in_string = false;
    var escaped = false;
    for (line) |byte| {
        if (!in_string) {
            if (byte == '"') in_string = true;
            continue;
        }
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '"') {
            in_string = false;
        }
    }
    return in_string;
}

fn badUnicodeEscapeIndex(line: []const u8) ?usize {
    var in_string = false;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (!in_string) {
            if (byte == '"') in_string = true;
            continue;
        }
        if (byte == '"') {
            in_string = false;
            continue;
        }
        if (byte != '\\') continue;
        index += 1;
        if (index >= line.len) return null;
        if (line[index] != 'u') continue;
        var digit: usize = 0;
        while (digit < 4) : (digit += 1) {
            const hex_index = index + 1 + digit;
            if (hex_index >= line.len) return null;
            if (!isHexDigit(line[hex_index])) return hex_index;
        }
        index += 4;
    }
    return null;
}

fn scanJsonStringEnd(line: []const u8, start_quote: usize) ?usize {
    if (start_quote >= line.len or line[start_quote] != '"') return null;
    var index = start_quote + 1;
    while (index < line.len) : (index += 1) {
        if (line[index] == '"') return index;
        if (line[index] == '\\') {
            index += 1;
            if (index >= line.len) return null;
            if (line[index] == 'u') index += 4;
        }
    }
    return null;
}

fn firstNonJsonWhitespaceIndex(line: []const u8) ?usize {
    return firstNonJsonWhitespaceIndexFrom(line, 0);
}

fn firstNonJsonWhitespaceIndexFrom(line: []const u8, start: usize) ?usize {
    var index = start;
    while (index < line.len) : (index += 1) {
        if (!isJsonWhitespace(line[index])) return index;
    }
    return null;
}

fn lastNonJsonWhitespaceIndex(line: []const u8) ?usize {
    var index = line.len;
    while (index > 0) {
        index -= 1;
        if (!isJsonWhitespace(line[index])) return index;
    }
    return null;
}

fn previousNonJsonWhitespaceIndex(line: []const u8, before: usize) ?usize {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!isJsonWhitespace(line[index])) return index;
    }
    return null;
}

fn isJsonWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn isHexDigit(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'a' and byte <= 'f') or
        (byte >= 'A' and byte <= 'F');
}

test "TS RPC wire response frames preserve TypeScript field order" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeSuccessResponseNoData(allocator, &out.writer, "abc", "prompt");
    try std.testing.expectEqualStrings(
        "{\"id\":\"abc\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeSuccessResponseRawData(allocator, &out.writer, null, "get_state", "{\"cwd\":\"/tmp\"}");
    try std.testing.expectEqualStrings(
        "{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{\"cwd\":\"/tmp\"}}\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeErrorResponse(allocator, &out.writer, "bad", "parse", "Unexpected token");
    try std.testing.expectEqualStrings(
        "{\"id\":\"bad\",\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Unexpected token\"}\n",
        out.written(),
    );
}

test "TS RPC wire extension UI frames preserve TypeScript field order" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const options = [_][]const u8{ "one", "two" };
    try writeExtensionUISelectRequest(allocator, &out.writer, "ui_select", "Choose", &options, 1000);
    try std.testing.expectEqualStrings(
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_select\",\"method\":\"select\",\"title\":\"Choose\",\"options\":[\"one\",\"two\"],\"timeout\":1000}\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeExtensionUINotifyRequest(allocator, &out.writer, "ui_notify_warning", "Check this", "warning");
    try std.testing.expectEqualStrings(
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_notify_warning\",\"method\":\"notify\",\"message\":\"Check this\",\"notifyType\":\"warning\"}\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeExtensionUINotifyRequest(allocator, &out.writer, "ui_notify_error", "Broken", "error");
    try std.testing.expectEqualStrings(
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_notify_error\",\"method\":\"notify\",\"message\":\"Broken\",\"notifyType\":\"error\"}\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeExtensionUISetStatusRequest(allocator, &out.writer, "ui_status_set", "extension", "ready");
    try std.testing.expectEqualStrings(
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_status_set\",\"method\":\"setStatus\",\"statusKey\":\"extension\",\"statusText\":\"ready\"}\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeExtensionUISetStatusRequest(allocator, &out.writer, "ui_status_clear", "extension", null);
    try std.testing.expectEqualStrings(
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_status_clear\",\"method\":\"setStatus\",\"statusKey\":\"extension\"}\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeExtensionUISetWidgetRequest(allocator, &out.writer, "ui_widget", "status", &options, "aboveEditor");
    try std.testing.expectEqualStrings(
        "{\"type\":\"extension_ui_request\",\"id\":\"ui_widget\",\"method\":\"setWidget\",\"widgetKey\":\"status\",\"widgetLines\":[\"one\",\"two\"],\"widgetPlacement\":\"aboveEditor\"}\n",
        out.written(),
    );
}

test "TS RPC wire parse diagnostics preserve TypeScript shapes" {
    const allocator = std.testing.allocator;

    const empty = try jsonParseErrorDetail(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("Unexpected end of JSON input", empty);

    const unicode = try jsonParseErrorDetail(allocator, "{\"x\":\"\\u12xz\"}");
    defer allocator.free(unicode);
    try std.testing.expectEqualStrings("Bad Unicode escape in JSON at position 10 (line 1 column 11)", unicode);

    const extra = try jsonParseErrorDetail(allocator, "{} trailing");
    defer allocator.free(extra);
    try std.testing.expectEqualStrings(
        "Unexpected non-whitespace character after JSON at position 3 (line 1 column 4)",
        extra,
    );
}
