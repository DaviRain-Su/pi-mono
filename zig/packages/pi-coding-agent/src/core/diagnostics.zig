const std = @import("std");
const json_utils = @import("../json_utils.zig");
const common = @import("../tools/common.zig");

pub const DIAGNOSTIC_ENVELOPE_SCHEMA_VERSION = "diagnostic-envelope.v0";
pub const DIAGNOSTIC_REDACTED_VALUE = "[REDACTED]";

pub const DiagnosticSeverity = enum {
    info,
    warning,
    @"error",

    pub fn jsonName(self: DiagnosticSeverity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }
};

pub const DiagnosticPhase = enum {
    load,
    event,
    call,
    resolve,
    write,
    unload,
    initialize,
    runtime,
    schema,

    pub fn jsonName(self: DiagnosticPhase) []const u8 {
        return @tagName(self);
    }
};

pub const DiagnosticRuntimeKind = enum {
    typescript,
    process_jsonl,
    wasm,
    native,
    remote,
    unknown,

    pub fn jsonName(self: DiagnosticRuntimeKind) []const u8 {
        return @tagName(self);
    }
};

pub const DiagnosticSourceV0 = struct {
    path: ?[]const u8 = null,
    resource_path: ?[]const u8 = null,
    base_dir: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    source: ?[]const u8 = null,
    runtime_kind: ?DiagnosticRuntimeKind = null,
    package_root: ?[]const u8 = null,
    descriptor_id: ?[]const u8 = null,
};

pub const DiagnosticEnvelopeInput = struct {
    severity: DiagnosticSeverity,
    phase: DiagnosticPhase,
    runtime_kind: DiagnosticRuntimeKind,
    category: []const u8,
    message: []const u8,
    recovery_hint: ?[]const u8 = null,
    source: ?DiagnosticSourceV0 = null,
    extension_identity: ?[]const u8 = null,
    event: ?[]const u8 = null,
    capability: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    path: ?[]const u8 = null,
    details: ?std.json.Value = null,
};

pub fn redactDiagnosticString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var redacted = try allocator.dupe(u8, value);
    errdefer allocator.free(redacted);
    try redactAfterToken(allocator, &redacted, "Bearer ");
    try redactAfterToken(allocator, &redacted, "Basic ");
    try redactAssignment(allocator, &redacted, "API_KEY=");
    try redactAssignment(allocator, &redacted, "TOKEN=");
    try redactAssignment(allocator, &redacted, "PASSWORD=");
    try redactAssignment(allocator, &redacted, "SECRET=");
    if (std.mem.indexOf(u8, redacted, "sk-")) |index| {
        const end = scanSecretEnd(redacted, index);
        try replaceRange(allocator, &redacted, index, end, DIAGNOSTIC_REDACTED_VALUE);
    }
    return redacted;
}

pub fn createDiagnosticEnvelope(allocator: std.mem.Allocator, input: DiagnosticEnvelopeInput) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try json_utils.putString(allocator, &object, "schemaVersion", DIAGNOSTIC_ENVELOPE_SCHEMA_VERSION);
    try json_utils.putString(allocator, &object, "severity", input.severity.jsonName());
    try json_utils.putString(allocator, &object, "phase", input.phase.jsonName());
    try json_utils.putString(allocator, &object, "runtimeKind", input.runtime_kind.jsonName());
    try json_utils.putString(allocator, &object, "category", input.category);
    const message = try redactDiagnosticString(allocator, input.message);
    defer allocator.free(message);
    try json_utils.putString(allocator, &object, "message", message);
    const hint = try redactDiagnosticString(allocator, input.recovery_hint orelse "Review the extension configuration and retry.");
    defer allocator.free(hint);
    try json_utils.putString(allocator, &object, "recoveryHint", hint);
    if (input.source) |source| try json_utils.putValue(allocator, &object, "source", try sourceValue(allocator, source));
    if (input.extension_identity) |value| try putRedactedString(allocator, &object, "extensionIdentity", value);
    if (input.event) |value| try putRedactedString(allocator, &object, "event", value);
    if (input.capability) |value| try putRedactedString(allocator, &object, "capability", value);
    if (input.operation) |value| try putRedactedString(allocator, &object, "operation", value);
    if (input.path) |value| try putRedactedString(allocator, &object, "path", value);
    if (input.details) |details| try json_utils.putValue(allocator, &object, "details", details);
    return .{ .object = object };
}

fn sourceValue(allocator: std.mem.Allocator, source: DiagnosticSourceV0) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    if (source.path) |value| try putRedactedString(allocator, &object, "path", value);
    if (source.resource_path) |value| try putRedactedString(allocator, &object, "resourcePath", value);
    if (source.base_dir) |value| try putRedactedString(allocator, &object, "baseDir", value);
    if (source.scope) |value| try putRedactedString(allocator, &object, "scope", value);
    if (source.origin) |value| try putRedactedString(allocator, &object, "origin", value);
    if (source.source) |value| try putRedactedString(allocator, &object, "source", value);
    if (source.runtime_kind) |value| try json_utils.putString(allocator, &object, "runtimeKind", value.jsonName());
    if (source.package_root) |value| try putRedactedString(allocator, &object, "packageRoot", value);
    if (source.descriptor_id) |value| try putRedactedString(allocator, &object, "descriptorId", value);
    return .{ .object = object };
}

fn putRedactedString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    const redacted = try redactDiagnosticString(allocator, value);
    defer allocator.free(redacted);
    try json_utils.putString(allocator, object, key, redacted);
}

fn redactAfterToken(allocator: std.mem.Allocator, value: *[]u8, token: []const u8) !void {
    if (std.mem.indexOf(u8, value.*, token)) |index| {
        const start = index + token.len;
        const end = scanSecretEnd(value.*, start);
        try replaceRange(allocator, value, start, end, DIAGNOSTIC_REDACTED_VALUE);
    }
}

fn redactAssignment(allocator: std.mem.Allocator, value: *[]u8, key: []const u8) !void {
    if (std.mem.indexOf(u8, value.*, key)) |index| {
        const start = index + key.len;
        const end = scanSecretEnd(value.*, start);
        try replaceRange(allocator, value, start, end, DIAGNOSTIC_REDACTED_VALUE);
    }
}

fn scanSecretEnd(value: []const u8, start: usize) usize {
    var end = start;
    while (end < value.len) : (end += 1) {
        switch (value[end]) {
            ' ', '\n', '\t', '\r', '"', '\'', '&', ';', ',' => break,
            else => {},
        }
    }
    return end;
}

fn replaceRange(allocator: std.mem.Allocator, value: *[]u8, start: usize, end: usize, replacement: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(value.*[0..start]);
    try out.writer.writeAll(replacement);
    try out.writer.writeAll(value.*[end..]);
    allocator.free(value.*);
    value.* = try out.toOwnedSlice();
}

test "diagnostic envelope redacts bearer tokens" {
    const allocator = std.testing.allocator;
    var envelope = try createDiagnosticEnvelope(allocator, .{
        .severity = .@"error",
        .phase = .event,
        .runtime_kind = .typescript,
        .category = "x",
        .message = "Authorization: Bearer token-secret",
    });
    defer common.deinitJsonValue(allocator, envelope);
    try std.testing.expect(std.mem.indexOf(u8, envelope.object.get("message").?.string, DIAGNOSTIC_REDACTED_VALUE) != null);
}
