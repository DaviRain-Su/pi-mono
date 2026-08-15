const std = @import("std");
const tui = @import("tui");
const config_mod = @import("../config/config.zig");
const session_mod = @import("../sessions/session.zig");

pub fn showTerminalProgress(runtime_config: ?*const config_mod.RuntimeConfig) bool {
    return if (runtime_config) |config| config.showTerminalProgress() else false;
}

pub fn writeTerminalProgress(terminal: *tui.Terminal, active: bool) !void {
    if (!terminal.capabilities().osc_9_4_progress) return;
    try terminal.write(tui.terminal_osc.osc9_4Progress(active));
}

pub fn writePromptReadyMarkers(terminal: *tui.Terminal) !void {
    if (!terminal.capabilities().osc_133_semantic_zones) return;
    try terminal.write(tui.terminal_osc.osc133PromptStart());
    try terminal.write(tui.terminal_osc.osc133PromptEnd());
}

pub fn writeCommandStartMarker(terminal: *tui.Terminal) !void {
    if (!terminal.capabilities().osc_133_semantic_zones) return;
    try terminal.write(tui.terminal_osc.osc133CommandStart());
}

pub fn writeCommandDoneAndPromptReady(terminal: *tui.Terminal, success: bool) !void {
    if (!terminal.capabilities().osc_133_semantic_zones) return;
    try terminal.write(tui.terminal_osc.osc133CommandDone(if (success) 0 else 1));
    try writePromptReadyMarkers(terminal);
}

pub fn writeCompletionNotification(
    allocator: std.mem.Allocator,
    terminal: *tui.Terminal,
    title: []const u8,
    body: []const u8,
) !void {
    if (!terminal.capabilities().osc_777_notify) return;
    const sequence = try tui.terminal_osc.osc777NotifyAlloc(allocator, title, body);
    defer allocator.free(sequence);
    try terminal.write(sequence);
}

pub fn updateInteractiveTerminalTitle(
    allocator: std.mem.Allocator,
    terminal: *tui.Terminal,
    session: *const session_mod.AgentSession,
    last_title: *?[]u8,
) !void {
    const cwd_basename = std.fs.path.basename(session.cwd);
    const title = if (session.session_manager.getSessionName()) |name|
        try std.fmt.allocPrint(allocator, "pi - {s} - {s}", .{ name, cwd_basename })
    else
        try std.fmt.allocPrint(allocator, "pi - {s}", .{cwd_basename});
    defer allocator.free(title);

    if (last_title.*) |existing| {
        if (std.mem.eql(u8, existing, title)) return;
        allocator.free(existing);
        last_title.* = null;
    }

    const sequence = try tui.terminal_osc.windowTitleAlloc(allocator, title);
    defer allocator.free(sequence);
    try terminal.write(sequence);
    last_title.* = try allocator.dupe(u8, title);
}
