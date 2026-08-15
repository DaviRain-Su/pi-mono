const std = @import("std");
const tui = @import("tui");
const session_mod = @import("../sessions/session.zig");
const extension_runtime = @import("../extensions/extension_runtime.zig");
const extension_registry = @import("../extensions/extension_registry.zig");
const keybindings_mod = @import("../shared/keybindings.zig");
const shared = @import("shared.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");
const extension_dialog = @import("extension_dialog.zig");

const DialogKind = extension_dialog.DialogKind;
const ExtensionDialog = extension_dialog.ExtensionDialog;

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: ?extension_runtime.RuntimeAdapter = null,
    queued_dialogs: std.ArrayList(ExtensionDialog) = .empty,
    last_registry_frames: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Bridge {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Bridge) void {
        for (self.queued_dialogs.items) |*dialog| dialog.deinit(self.allocator);
        self.queued_dialogs.deinit(self.allocator);
        if (self.host) |host| {
            host.deinit();
            self.host = null;
        }
        self.* = undefined;
    }

    pub fn startFromEnv(
        self: *Bridge,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
    ) !void {
        if (self.host != null) return;
        const entry = env_map.get("PI_M6_EXTENSION_HOST_ENTRY") orelse return;
        if (isEnabledEnv(env_map, "PI_M6_EXTENSION_HOST_DISABLED")) return;
        const runtime = env_map.get("PI_M6_EXTENSION_HOST_RUNTIME") orelse "bun";
        const fixture = env_map.get("PI_M6_EXTENSION_HOST_FIXTURE") orelse "interactive-extension-ui";
        const marker = env_map.get(extension_runtime.HOST_MARKER_ENV) orelse "pi-interactive-extension-host";
        const argv = [_][]const u8{ runtime, entry, marker };
        const host = try extension_runtime.startRuntimeAdapter(self.allocator, self.io, .{ .process_jsonl = .{
            .argv = &argv,
            .cwd = cwd,
            .extension_path = entry,
            .initialize = .{
                .marker = marker,
                .cwd = cwd,
                .fixture = fixture,
            },
        } });
        errdefer host.deinit();
        try host.waitForReady(2000);
        self.host = host;
        self.last_registry_frames = host.registryFramesApplied();
    }

    pub fn commandSink(self: *Bridge) shared.ExtensionCommandSink {
        return .{
            .context = self,
            .callback = dispatchSlashCommand,
        };
    }

    pub fn shortcutSink(self: *Bridge) shared.ExtensionShortcutSink {
        return .{
            .context = self,
            .callback = dispatchExtensionShortcut,
        };
    }

    pub fn service(
        self: *Bridge,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
        terminal: *tui.Terminal,
        editor: *tui.Editor,
        overlay: *?overlays.SelectorOverlay,
        app_state: *rendering.AppState,
        live_resources: *shared.LiveResources,
        session: *session_mod.AgentSession,
        now_ms: i64,
    ) !void {
        try self.startFromEnv(env_map, cwd);
        try self.completeResolvedOverlay(overlay, app_state);
        try self.resolveTimedOutOverlay(overlay, app_state, now_ms);
        try self.closeDialogIfHostExited(overlay, app_state);
        try self.drainHostRequests(env_map, cwd, terminal, editor, overlay, app_state, live_resources, session, now_ms);
        try self.applyHostUiHooks(app_state);
        try self.openNextDialog(overlay, app_state);
    }

    fn applyHostUiHooks(self: *Bridge, app_state: *rendering.AppState) !void {
        const host = self.host orelse return;
        try host.withRegistry(app_state, applyRegistryUiCallback);
    }

    fn drainHostRequests(
        self: *Bridge,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
        terminal: *tui.Terminal,
        editor: *tui.Editor,
        overlay: *?overlays.SelectorOverlay,
        app_state: *rendering.AppState,
        live_resources: *shared.LiveResources,
        session: *session_mod.AgentSession,
        now_ms: i64,
    ) !void {
        const host = self.host orelse return;
        while (true) {
            const requests = try host.takeUiRequests(self.allocator);
            defer {
                for (requests) |*request| request.deinit(self.allocator);
                self.allocator.free(requests);
            }
            if (requests.len == 0) break;
            for (requests) |request| {
                try self.handleHostRequest(request, env_map, cwd, terminal, editor, overlay, app_state, live_resources, session, now_ms);
            }
        }
    }

    fn handleHostRequest(
        self: *Bridge,
        request: extension_runtime.ExtensionUiRequest,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
        terminal: *tui.Terminal,
        editor: *tui.Editor,
        overlay: *?overlays.SelectorOverlay,
        app_state: *rendering.AppState,
        live_resources: *shared.LiveResources,
        session: *session_mod.AgentSession,
        now_ms: i64,
    ) !void {
        _ = overlay;
        if (try dialogFromRequest(self.allocator, request, now_ms)) |dialog| {
            try self.queued_dialogs.append(self.allocator, dialog);
            return;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, request.payload_json, .{}) catch return;
        defer parsed.deinit();
        const payload = switch (parsed.value) {
            .object => |object| object,
            else => return,
        };

        if (std.mem.eql(u8, request.method, "set_editor_text") or std.mem.eql(u8, request.method, "setEditorText")) {
            const text = optionalString(payload, "text") orelse "";
            try editor.setText(text);
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "paste_to_editor") or std.mem.eql(u8, request.method, "pasteToEditor")) {
            const text = optionalString(payload, "text") orelse "";
            _ = try editor.handlePaste(text);
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "get_editor_text") or std.mem.eql(u8, request.method, "getEditorText")) {
            const expanded = try editor.expandedTextAlloc(self.allocator);
            defer self.allocator.free(expanded);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            try out.writer.writeAll("{\"value\":");
            try writeJsonString(self.allocator, &out.writer, expanded);
            try out.writer.writeAll("}");
            try self.respondIfRequired(request, out.written());
            return;
        }
        if (std.mem.eql(u8, request.method, "setTitle")) {
            const title = optionalString(payload, "title") orelse "";
            try setTerminalTitle(self.allocator, terminal, title);
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "setTheme")) {
            const theme_name = optionalString(payload, "theme") orelse optionalString(payload, "name") orelse "";
            if (theme_name.len > 0) {
                live_resources.applyTheme(self.allocator, self.io, env_map, cwd, theme_name) catch {};
            }
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "setHiddenThinkingLabel")) {
            const label = optionalString(payload, "label") orelse "Thinking...";
            try app_state.setHiddenThinkingLabel(label);
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "addAutocompleteProvider") or std.mem.eql(u8, request.method, "add_autocomplete_provider")) {
            const items = try autocompleteItemsFromPayload(self.allocator, payload);
            defer freeSelectItems(self.allocator, items);
            if (items.len > 0) try editor.setAutocompleteItems(items);
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "send_custom_message")) {
            const custom_type = optionalString(payload, "customType") orelse "extension.message";
            const content_text = optionalString(payload, "content") orelse "extension message";
            _ = try session.session_manager.appendCustomMessageEntry(
                custom_type,
                .{ .text = content_text },
                true,
                null,
            );
            try app_state.appendMarkdown(content_text);
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "notify")) {
            const text = optionalString(payload, "message") orelse optionalString(payload, "statusText") orelse "";
            const notify_type = optionalString(payload, "notifyType") orelse optionalString(payload, "type") orelse "info";
            if (text.len > 0) {
                if (std.mem.eql(u8, notify_type, "error")) {
                    try app_state.appendError(text);
                } else if (std.mem.eql(u8, notify_type, "warning")) {
                    const warning = try std.fmt.allocPrint(self.allocator, "Warning: {s}", .{text});
                    defer self.allocator.free(warning);
                    try app_state.appendInfo(warning);
                    try app_state.setStatus(text);
                } else {
                    try app_state.setStatus(text);
                }
            }
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "setStatus")) {
            const key = optionalString(payload, "statusKey") orelse optionalString(payload, "key") orelse "extension";
            const text = optionalString(payload, "statusText") orelse optionalString(payload, "text");
            try app_state.setExtensionFooterStatus(key, text);
            if (text) |status_text| {
                if (status_text.len > 0) try app_state.setStatus(status_text);
            }
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "setWorkingMessage")) {
            try app_state.setWorkingMessage(optionalString(payload, "message"));
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "setWorkingVisible")) {
            app_state.setWorkingVisible(optionalBool(payload, "visible") orelse true);
            try self.respondIfRequired(request, "{}");
            return;
        }
        if (std.mem.eql(u8, request.method, "setWorkingIndicator")) {
            const label = optionalString(payload, "label") orelse optionalString(payload, "message");
            try app_state.setWorkingMessage(label);
            try self.respondIfRequired(request, "{}");
            return;
        }

        try self.respondIfRequired(request, "{\"cancelled\":true}");
    }

    fn respondIfRequired(self: *Bridge, request: extension_runtime.ExtensionUiRequest, payload_json: []const u8) !void {
        if (!request.response_required) return;
        if (self.host) |host| try host.sendExtensionUiResponse(request.id, payload_json);
    }

    fn openNextDialog(self: *Bridge, overlay: *?overlays.SelectorOverlay, app_state: *rendering.AppState) !void {
        if (overlay.* != null or self.queued_dialogs.items.len == 0) return;
        const dialog = self.queued_dialogs.orderedRemove(0);
        overlay.* = .{ .extension_dialog = dialog };
        try app_state.setStatus("extension dialog open");
    }

    fn completeResolvedOverlay(self: *Bridge, overlay: *?overlays.SelectorOverlay, app_state: *rendering.AppState) !void {
        const host = self.host orelse return;
        if (overlay.*) |*overlay_value| {
            if (std.meta.activeTag(overlay_value.*) != .extension_dialog) return;
            if (overlay_value.extension_dialog.resolved_payload_json) |payload| {
                try host.sendExtensionUiResponse(overlay_value.extension_dialog.id, payload);
                overlay_value.deinit(self.allocator);
                overlay.* = null;
                try app_state.setStatus("extension dialog resolved");
            }
        }
    }

    fn resolveTimedOutOverlay(self: *Bridge, overlay: *?overlays.SelectorOverlay, app_state: *rendering.AppState, now_ms: i64) !void {
        _ = app_state;
        if (overlay.*) |*overlay_value| {
            if (std.meta.activeTag(overlay_value.*) != .extension_dialog) return;
            if (overlay_value.extension_dialog.timeout_deadline_ms) |deadline| {
                if (now_ms >= deadline) try overlay_value.extension_dialog.resolveCancel(self.allocator);
            }
        }
    }

    fn closeDialogIfHostExited(self: *Bridge, overlay: *?overlays.SelectorOverlay, app_state: *rendering.AppState) !void {
        const host = self.host orelse return;
        if (host.pendingCount() != 0) return;
        if (overlay.*) |*overlay_value| {
            if (std.meta.activeTag(overlay_value.*) != .extension_dialog) return;
            if (overlay_value.extension_dialog.resolved_payload_json != null) return;
            overlay_value.deinit(self.allocator);
            overlay.* = null;
            try app_state.setStatus("extension dialog cancelled");
        }
    }
};

fn applyRegistryUiCallback(context: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const app_state: *rendering.AppState = @ptrCast(@alignCast(context.?));
    try app_state.applyExtensionRegistryUi(registry);
}

fn dialogFromRequest(allocator: std.mem.Allocator, request: extension_runtime.ExtensionUiRequest, now_ms: i64) !?ExtensionDialog {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request.payload_json, .{}) catch return null;
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };

    if (std.mem.eql(u8, request.method, "select")) {
        const title = optionalString(payload, "title") orelse "Select";
        const options = try requiredStringArray(allocator, payload, "options");
        errdefer freeStringList(allocator, options);
        const items = try choicesToItems(allocator, options);
        errdefer freeSelectItems(allocator, items);
        return .{
            .id = try allocator.dupe(u8, request.id),
            .kind = .select,
            .title = try allocator.dupe(u8, title),
            .hint = try allocator.dupe(u8, "↑↓ navigate • Enter select • Esc cancel"),
            .choices = options,
            .items = items,
            .list = .{ .items = items, .max_visible = 8 },
            .editor = tui.Editor.init(allocator),
            .timeout_deadline_ms = timeoutDeadline(payload, now_ms),
        };
    }
    if (std.mem.eql(u8, request.method, "confirm")) {
        const title = optionalString(payload, "title") orelse "Confirm";
        const message = optionalString(payload, "message") orelse "";
        const choices = try cloneStringList(allocator, &.{ "Yes", "No" });
        errdefer freeStringList(allocator, choices);
        const items = try choicesToItems(allocator, choices);
        errdefer freeSelectItems(allocator, items);
        return .{
            .id = try allocator.dupe(u8, request.id),
            .kind = .confirm,
            .title = try allocator.dupe(u8, title),
            .hint = try allocator.dupe(u8, "↑↓ choose • Enter confirm • Esc cancel"),
            .message = try allocator.dupe(u8, message),
            .choices = choices,
            .items = items,
            .list = .{ .items = items, .max_visible = 2 },
            .editor = tui.Editor.init(allocator),
            .timeout_deadline_ms = timeoutDeadline(payload, now_ms),
        };
    }
    if (std.mem.eql(u8, request.method, "input") or std.mem.eql(u8, request.method, "editor")) {
        const is_editor = std.mem.eql(u8, request.method, "editor");
        const title = optionalString(payload, "title") orelse if (is_editor) "Editor" else "Input";
        var editor = tui.Editor.init(allocator);
        errdefer editor.deinit();
        if (is_editor) {
            if (optionalString(payload, "prefill")) |prefill| {
                if (prefill.len > 0) try editor.setText(prefill);
            }
        }
        return .{
            .id = try allocator.dupe(u8, request.id),
            .kind = if (is_editor) .editor else .input,
            .title = try allocator.dupe(u8, title),
            .hint = try allocator.dupe(u8, if (is_editor) "Enter submit • Shift+Enter newline • Esc cancel" else "Enter submit • Esc cancel"),
            .editor = editor,
            .timeout_deadline_ms = if (is_editor) null else timeoutDeadline(payload, now_ms),
        };
    }
    return null;
}

const ShortcutLookup = struct {
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    matched_command: ?[]u8 = null,
    allocator: std.mem.Allocator,
};

fn dispatchExtensionShortcut(
    context: ?*anyopaque,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) anyerror!bool {
    const self: *Bridge = @ptrCast(@alignCast(context orelse return false));
    const host = self.host orelse return false;
    var lookup = ShortcutLookup{
        .key = key,
        .modifiers = modifiers,
        .allocator = self.allocator,
    };
    host.withRegistry(&lookup, captureMatchingShortcut) catch {};
    const command_owned = lookup.matched_command orelse return false;
    defer self.allocator.free(command_owned);
    const slash_command = try std.fmt.allocPrint(self.allocator, "/{s}", .{command_owned});
    defer self.allocator.free(slash_command);
    return try dispatchSlashCommand(self, slash_command);
}

fn captureMatchingShortcut(context: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const lookup: *ShortcutLookup = @ptrCast(@alignCast(context.?));
    if (lookup.matched_command != null) return;
    for (registry.shortcuts.items) |shortcut| {
        const command_text = shortcut.command orelse continue;
        const spec = keybindings_mod.parseKeySpec(shortcut.shortcut) orelse continue;
        if (keybindings_mod.keySpecMatches(spec, lookup.key, lookup.modifiers)) {
            lookup.matched_command = try lookup.allocator.dupe(u8, command_text);
            return;
        }
    }
}

fn dispatchSlashCommand(context: ?*anyopaque, raw_command: []const u8) anyerror!bool {
    const self: *Bridge = @ptrCast(@alignCast(context orelse return false));
    const host = self.host orelse return false;
    const command_name = slashCommandName(raw_command) orelse return false;
    if (!host.hasRegisteredCommand(command_name)) return false;
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"type\":\"command\",\"name\":");
    try writeJsonString(self.allocator, &out.writer, command_name);
    const argument = slashCommandArgument(raw_command);
    if (argument.len > 0) {
        try out.writer.writeAll(",\"argument\":");
        try writeJsonString(self.allocator, &out.writer, argument);
    }
    try out.writer.writeAll("}");
    host.sendExtensionEventFrame(out.written());
    return true;
}

fn slashCommandName(raw_command: []const u8) ?[]const u8 {
    if (raw_command.len == 0 or raw_command[0] != '/') return null;
    const trimmed = std.mem.trim(u8, raw_command[1..], " \t\r\n");
    if (trimmed.len == 0) return null;
    const split = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    return trimmed[0..split];
}

fn slashCommandArgument(raw_command: []const u8) []const u8 {
    const name = slashCommandName(raw_command) orelse return "";
    const after_slash = raw_command[1..];
    if (after_slash.len <= name.len) return "";
    return std.mem.trim(u8, after_slash[name.len..], " \t\r\n");
}

fn setTerminalTitle(allocator: std.mem.Allocator, terminal: *tui.Terminal, title: []const u8) !void {
    const sequence = try std.fmt.allocPrint(allocator, "\x1b]0;{s}\x07", .{title});
    defer allocator.free(sequence);
    try terminal.write(sequence);
}

fn isEnabledEnv(env_map: *const std.process.Environ.Map, key: []const u8) bool {
    const value = env_map.get(key) orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes");
}

fn timeoutDeadline(payload: std.json.ObjectMap, now_ms: i64) ?i64 {
    const timeout = optionalU64(payload, "timeout") orelse return null;
    if (timeout == 0) return null;
    return now_ms + @as(i64, @intCast(timeout));
}

fn optionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalU64(object: std.json.ObjectMap, field: []const u8) ?u64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (number >= 0) @intFromFloat(number) else null,
        else => null,
    };
}

fn optionalBool(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn requiredStringArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8) ![][]u8 {
    const value = object.get(field) orelse return try allocator.alloc([]u8, 0);
    if (value != .array) return try allocator.alloc([]u8, 0);
    var result = try allocator.alloc([]u8, value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| allocator.free(item);
        allocator.free(result);
    }
    for (value.array.items, 0..) |item, index| {
        result[index] = try allocator.dupe(u8, if (item == .string) item.string else "");
        initialized += 1;
    }
    return result;
}

fn cloneStringList(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    var result = try allocator.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| allocator.free(item);
        allocator.free(result);
    }
    for (values, 0..) |value, index| {
        result[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn choicesToItems(allocator: std.mem.Allocator, choices: []const []const u8) ![]tui.SelectItem {
    var items = try allocator.alloc(tui.SelectItem, choices.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
        }
        allocator.free(items);
    }
    for (choices, 0..) |choice, index| {
        items[index] = .{
            .value = try allocator.dupe(u8, choice),
            .label = try allocator.dupe(u8, choice),
        };
        initialized += 1;
    }
    return items;
}

fn autocompleteItemsFromPayload(allocator: std.mem.Allocator, payload: std.json.ObjectMap) ![]tui.SelectItem {
    const value = payload.get("items") orelse return try allocator.alloc(tui.SelectItem, 0);
    if (value != .array) return try allocator.alloc(tui.SelectItem, 0);
    var items = try allocator.alloc(tui.SelectItem, value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }
    for (value.array.items, 0..) |item_value, index| {
        const value_text = switch (item_value) {
            .string => |text| text,
            .object => |object| optionalString(object, "value") orelse "",
            else => "",
        };
        const label_text = switch (item_value) {
            .object => |object| optionalString(object, "label") orelse value_text,
            else => value_text,
        };
        const description_text = switch (item_value) {
            .object => |object| optionalString(object, "description"),
            else => null,
        };
        items[index] = .{
            .value = try allocator.dupe(u8, value_text),
            .label = try allocator.dupe(u8, label_text),
            .description = if (description_text) |description| try allocator.dupe(u8, description) else null,
        };
        initialized += 1;
    }
    return items;
}

const freeStringList = @import("../slice_utils.zig").freeStringSlice;

fn freeSelectItems(allocator: std.mem.Allocator, items: []tui.SelectItem) void {
    for (items) |item| {
        allocator.free(@constCast(item.value));
        allocator.free(@constCast(item.label));
        if (item.description) |description| allocator.free(@constCast(description));
    }
    allocator.free(items);
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

test "extension dialog resolves select confirm input editor and cancel payloads" {
    const allocator = std.testing.allocator;
    var request = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "select-1"),
        .method = try allocator.dupe(u8, "select"),
        .response_required = true,
        .payload_json = try allocator.dupe(u8, "{\"title\":\"Pick one\",\"options\":[\"alpha\",\"beta\"],\"timeout\":1000}"),
    };
    defer request.deinit(allocator);

    var dialog = (try dialogFromRequest(allocator, request, 10)).?;
    defer dialog.deinit(allocator);
    try std.testing.expectEqual(DialogKind.select, dialog.kind);
    try extension_dialog.handleDialogKey(allocator, &dialog, .down, .{}, null);
    try extension_dialog.handleDialogKey(allocator, &dialog, .enter, .{}, null);
    try std.testing.expectEqualStrings("{\"value\":\"beta\"}", dialog.resolved_payload_json.?);
}

test "extension bridge editor APIs mutate editor and hidden thinking label" {
    const allocator = std.testing.allocator;
    var bridge = Bridge.init(allocator, std.testing.io);
    defer bridge.queued_dialogs.deinit(allocator);
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var state = try rendering.AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.appendItemLocked(.thinking, "private chain");

    const LocalBackend = struct {
        fn enterRawMode(_: *anyopaque) !void {}
        fn restoreMode(_: *anyopaque) !void {}
        fn write(_: *anyopaque, _: []const u8) !void {}
        fn getSize(_: *anyopaque) !tui.Size {
            return .{ .width = 80, .height = 24 };
        }
        fn backend(self: *@This()) tui.Backend {
            return .{
                .ptr = self,
                .enterRawModeFn = enterRawMode,
                .restoreModeFn = restoreMode,
                .writeFn = write,
                .getSizeFn = getSize,
            };
        }
    };
    var terminal_backend = LocalBackend{};
    var terminal = tui.Terminal.init(terminal_backend.backend());
    try terminal.start();
    defer terminal.stop();
    var live = shared.LiveResources.init(.{
        .cwd = "",
        .system_prompt = "",
        .session_dir = "",
        .provider = "faux",
    });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative_tmp_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(relative_tmp_path);
    const cwd_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd_path);
    const tmp_path = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd_path, relative_tmp_path });
    defer allocator.free(tmp_path);
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = tmp_path,
        .system_prompt = "",
        .session_dir = tmp_path,
    });
    defer session.deinit();
    var overlay: ?overlays.SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var request = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "set-text"),
        .method = try allocator.dupe(u8, "set_editor_text"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"text\":\"from extension\"}"),
    };
    defer request.deinit(allocator);
    try bridge.handleHostRequest(request, &env_map, tmp_path, &terminal, &editor, &overlay, &state, &live, &session, 0);
    try std.testing.expectEqualStrings("from extension", editor.text());

    var label_request = extension_runtime.ExtensionUiRequest{
        .id = try allocator.dupe(u8, "label"),
        .method = try allocator.dupe(u8, "setHiddenThinkingLabel"),
        .response_required = false,
        .payload_json = try allocator.dupe(u8, "{\"label\":\"Hidden thoughts\"}"),
    };
    defer label_request.deinit(allocator);
    try state.setThinkingBlockVisibility(true);
    try bridge.handleHostRequest(label_request, &env_map, tmp_path, &terminal, &editor, &overlay, &state, &live, &session, 0);
    try std.testing.expectEqualStrings("Hidden thoughts", state.chat.items.items[1].text);
}
