const std = @import("std");
const extension_runtime = @import("../extensions/extension_runtime.zig");
const json_utils = @import("../json_utils.zig");
const tools_common = @import("../tools/common.zig");

pub const HookSeverity = enum {
    info,
    warning,
    @"error",
};

pub const HookDiagnostic = struct {
    severity: HookSeverity,
    message: []u8,

    pub fn deinit(self: *HookDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const HookMetadata = struct {
    priority: i64 = 0,
    declaration_order: usize = 0,
};

pub const HookRuntime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        has_hook: *const fn (ptr: *anyopaque, event_name: []const u8) bool,
        invoke: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, event_name: []const u8, event: std.json.Value, timeout_ms: u64) anyerror!?std.json.Value,
        metadata: *const fn (ptr: *anyopaque, event_name: []const u8) HookMetadata,
        describe_source: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, event_name: []const u8) anyerror![]u8,
        drain_diagnostics: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]HookDiagnostic,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn hasHook(self: HookRuntime, event_name: []const u8) bool {
        return self.vtable.has_hook(self.ptr, event_name);
    }

    pub fn invoke(
        self: HookRuntime,
        allocator: std.mem.Allocator,
        event_name: []const u8,
        event: std.json.Value,
        timeout_ms: u64,
    ) !?std.json.Value {
        return try self.vtable.invoke(self.ptr, allocator, event_name, event, timeout_ms);
    }

    pub fn metadata(self: HookRuntime, event_name: []const u8) HookMetadata {
        return self.vtable.metadata(self.ptr, event_name);
    }

    pub fn describeSource(self: HookRuntime, allocator: std.mem.Allocator, event_name: []const u8) ![]u8 {
        return try self.vtable.describe_source(self.ptr, allocator, event_name);
    }

    pub fn drainDiagnostics(self: HookRuntime, allocator: std.mem.Allocator) ![]HookDiagnostic {
        return try self.vtable.drain_diagnostics(self.ptr, allocator);
    }

    pub fn deinit(self: HookRuntime) void {
        self.vtable.deinit(self.ptr);
    }
};

pub fn wrapRuntimeAdapter(adapter: *const extension_runtime.RuntimeAdapter) HookRuntime {
    const Box = struct {
        fn hasHook(ptr: *anyopaque, event_name: []const u8) bool {
            const runtime: *const extension_runtime.RuntimeAdapter = @ptrCast(@alignCast(ptr));
            return runtime.hasRegisteredHook(event_name);
        }

        fn invoke(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            event_name: []const u8,
            event: std.json.Value,
            timeout_ms: u64,
        ) anyerror!?std.json.Value {
            const runtime: *const extension_runtime.RuntimeAdapter = @ptrCast(@alignCast(ptr));
            return try runtime.invokeExtensionEvent(allocator, event_name, event, timeout_ms);
        }

        fn metadata(ptr: *anyopaque, event_name: []const u8) HookMetadata {
            const runtime: *const extension_runtime.RuntimeAdapter = @ptrCast(@alignCast(ptr));
            var lookup = HookMetadataLookup{ .event_name = event_name };
            runtime.withRegistry(&lookup, captureHookMetadata) catch {};
            return .{
                .priority = lookup.priority,
                .declaration_order = lookup.declaration_order,
            };
        }

        fn describeSource(ptr: *anyopaque, allocator: std.mem.Allocator, event_name: []const u8) anyerror![]u8 {
            const runtime: *const extension_runtime.RuntimeAdapter = @ptrCast(@alignCast(ptr));
            var lookup = HookSourceLookup{
                .allocator = allocator,
                .event_name = event_name,
            };
            runtime.withRegistry(&lookup, captureHookSource) catch {};
            if (lookup.extension_id) |extension_id| return extension_id;
            return try allocator.dupe(u8, runtime.kind.jsonName());
        }

        fn drainDiagnostics(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]HookDiagnostic {
            const runtime: *const extension_runtime.RuntimeAdapter = @ptrCast(@alignCast(ptr));
            if (runtime.diagnosticCount() == 0) return try allocator.alloc(HookDiagnostic, 0);
            const diagnostics = try allocator.alloc(HookDiagnostic, 1);
            diagnostics[0] = .{
                .severity = .info,
                .message = try std.fmt.allocPrint(allocator, "runtime diagnostics present ({d})", .{runtime.diagnosticCount()}),
            };
            return diagnostics;
        }

        fn deinit(ptr: *anyopaque) void {
            _ = ptr;
        }
    };

    return .{
        .ptr = @constCast(adapter),
        .vtable = &.{
            .has_hook = Box.hasHook,
            .invoke = Box.invoke,
            .metadata = Box.metadata,
            .describe_source = Box.describeSource,
            .drain_diagnostics = Box.drainDiagnostics,
            .deinit = Box.deinit,
        },
    };
}

pub fn wrapRuntimeAdapters(allocator: std.mem.Allocator, adapters: []const extension_runtime.RuntimeAdapter) ![]HookRuntime {
    if (adapters.len == 0) return try allocator.alloc(HookRuntime, 0);
    const wrapped = try allocator.alloc(HookRuntime, adapters.len);
    for (adapters, 0..) |*adapter, index| {
        wrapped[index] = wrapRuntimeAdapter(adapter);
    }
    return wrapped;
}

const HookMetadataLookup = struct {
    event_name: []const u8,
    priority: i64 = 0,
    declaration_order: usize = 0,
};

fn captureHookMetadata(context: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const lookup: *HookMetadataLookup = @ptrCast(@alignCast(context orelse return));
    for (registry.hooks.items) |hook| {
        if (!std.mem.eql(u8, hook.event_name, lookup.event_name)) continue;
        lookup.priority = hook.priority;
        lookup.declaration_order = hook.declaration_order;
        return;
    }
}

const HookSourceLookup = struct {
    allocator: std.mem.Allocator,
    event_name: []const u8,
    extension_id: ?[]u8 = null,
};

fn captureHookSource(context: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const lookup: *HookSourceLookup = @ptrCast(@alignCast(context orelse return));
    for (registry.hooks.items) |hook| {
        if (!std.mem.eql(u8, hook.event_name, lookup.event_name)) continue;
        lookup.extension_id = try lookup.allocator.dupe(u8, hook.extension_path);
        return;
    }
}

test "hook runtime vtable dispatches through fixture" {
    const Fixture = struct {
        const Self = @This();

        diagnostics_drained: bool = false,

        fn hasHook(ptr: *anyopaque, event_name: []const u8) bool {
            _ = ptr;
            return std.mem.eql(u8, event_name, "message_end");
        }

        fn invoke(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            event_name: []const u8,
            event: std.json.Value,
            timeout_ms: u64,
        ) !?std.json.Value {
            _ = ptr;
            _ = timeout_ms;
            _ = event;

            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer {
                const value: std.json.Value = .{ .object = object };
                tools_common.deinitJsonValue(allocator, value);
            }
            try json_utils.putBool(allocator, &object, "handled", std.mem.eql(u8, event_name, "message_end"));
            return .{ .object = object };
        }

        fn metadata(ptr: *anyopaque, event_name: []const u8) HookMetadata {
            _ = ptr;
            return .{
                .priority = if (std.mem.eql(u8, event_name, "message_end")) 7 else 0,
                .declaration_order = 3,
            };
        }

        fn describeSource(ptr: *anyopaque, allocator: std.mem.Allocator, event_name: []const u8) ![]u8 {
            _ = ptr;
            return try std.fmt.allocPrint(allocator, "fixture:{s}", .{event_name});
        }

        fn drainDiagnostics(ptr: *anyopaque, allocator: std.mem.Allocator) ![]HookDiagnostic {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.diagnostics_drained = true;
            const items = try allocator.alloc(HookDiagnostic, 1);
            items[0] = .{
                .severity = .warning,
                .message = try allocator.dupe(u8, "fixture warning"),
            };
            return items;
        }

        fn deinit(ptr: *anyopaque) void {
            _ = ptr;
        }
    };

    const vtable: HookRuntime.VTable = .{
        .has_hook = Fixture.hasHook,
        .invoke = Fixture.invoke,
        .metadata = Fixture.metadata,
        .describe_source = Fixture.describeSource,
        .drain_diagnostics = Fixture.drainDiagnostics,
        .deinit = Fixture.deinit,
    };

    var fixture = Fixture{};
    const runtime = HookRuntime{
        .ptr = &fixture,
        .vtable = &vtable,
    };

    try std.testing.expect(runtime.hasHook("message_end"));
    try std.testing.expect(!runtime.hasHook("session_start"));
    try std.testing.expectEqual(@as(i64, 7), runtime.metadata("message_end").priority);

    const source = try runtime.describeSource(std.testing.allocator, "message_end");
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("fixture:message_end", source);

    const event_object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    const event_value: std.json.Value = .{ .object = event_object };
    const invoked = (try runtime.invoke(std.testing.allocator, "message_end", event_value, 1000)).?;
    defer tools_common.deinitJsonValue(std.testing.allocator, invoked);
    tools_common.deinitJsonValue(std.testing.allocator, event_value);
    try std.testing.expect(invoked.object.get("handled").?.bool);

    const diagnostics = try runtime.drainDiagnostics(std.testing.allocator);
    defer {
        for (diagnostics) |*diagnostic| diagnostic.deinit(std.testing.allocator);
        std.testing.allocator.free(diagnostics);
    }
    try std.testing.expect(fixture.diagnostics_drained);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("fixture warning", diagnostics[0].message);
}
