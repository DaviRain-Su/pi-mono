const std = @import("std");
const session_mod = @import("../sessions/session.zig");
const bash_tool_mod = @import("../tools/bash.zig");
const bash_execution = @import("bash_execution.zig");

pub const Hooks = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *anyopaque,
    append_start: *const fn (*anyopaque, []const u8, bool) anyerror!usize,
    update: *const fn (*anyopaque, ?usize, []const u8, []const u8, bool) anyerror!void,
    finish: *const fn (*anyopaque, ?usize, []const u8, []const u8, ?u8, bool, bool, ?[]const u8, bool) anyerror!void,
    set_status: *const fn (*anyopaque, []const u8) anyerror!void,
    append_error: *const fn (*anyopaque, []const u8) anyerror!void,
};

pub const UserBashTask = struct {
    session: ?*session_mod.AgentSession = null,
    hooks: ?Hooks = null,
    command: []u8 = &.{},
    exclude_from_context: bool = false,
    item_index: ?usize = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    abort_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn start(
        self: *UserBashTask,
        allocator: std.mem.Allocator,
        session: *session_mod.AgentSession,
        hooks: Hooks,
        command: []const u8,
        exclude_from_context: bool,
    ) !bool {
        if (self.thread != null) return false;

        self.session = session;
        self.hooks = hooks;
        self.command = try allocator.dupe(u8, command);
        errdefer {
            allocator.free(self.command);
            self.command = &.{};
            self.hooks = null;
        }
        self.exclude_from_context = exclude_from_context;
        self.abort_requested.store(false, .seq_cst);
        self.item_index = try hooks.append_start(hooks.context, command, exclude_from_context);
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{ self, allocator });
        return true;
    }

    pub fn abort(self: *UserBashTask) bool {
        if (self.thread == null) return false;
        self.abort_requested.store(true, .seq_cst);
        return true;
    }

    pub fn isActive(self: *const UserBashTask) bool {
        return self.thread != null;
    }

    pub fn poll(self: *UserBashTask, allocator: std.mem.Allocator) bool {
        if (self.thread == null) return false;
        if (self.running.load(.seq_cst)) return false;
        self.finishJoined(allocator);
        return true;
    }

    pub fn deinit(self: *UserBashTask, allocator: std.mem.Allocator) void {
        if (self.thread != null) {
            _ = self.abort();
            if (self.thread) |thread| thread.join();
            self.thread = null;
            if (self.command.len > 0) allocator.free(self.command);
        }
        self.reset();
    }

    fn finishJoined(self: *UserBashTask, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.command.len > 0) allocator.free(self.command);
        self.reset();
    }

    fn reset(self: *UserBashTask) void {
        self.command = &.{};
        self.session = null;
        self.hooks = null;
        self.item_index = null;
        self.exclude_from_context = false;
        self.running.store(false, .seq_cst);
        self.abort_requested.store(false, .seq_cst);
    }

    fn run(self: *UserBashTask, allocator: std.mem.Allocator) void {
        defer self.running.store(false, .seq_cst);

        const session = self.session orelse return;
        const hooks = self.hooks orelse return;
        const command = self.command;
        const item_index = self.item_index;
        const exclude_from_context = self.exclude_from_context;

        const tool = bash_tool_mod.BashTool.init(session.cwd, hooks.io);
        var result = tool.executeWithUpdates(
            allocator,
            .{ .command = command },
            &self.abort_requested,
            self,
            updateCallback,
        ) catch |err| {
            const message = std.fmt.allocPrint(allocator, "Bash command failed: {s}", .{@errorName(err)}) catch return;
            defer allocator.free(message);
            hooks.finish(hooks.context, item_index, command, message, null, false, false, null, exclude_from_context) catch {};
            hooks.set_status(hooks.context, "bash command failed") catch {};
            return;
        };
        defer result.deinit(allocator);

        const raw_output_text = bash_execution.contentBlocksTextAlloc(allocator, result.content) catch return;
        defer allocator.free(raw_output_text);
        const output_text = bash_execution.sanitizeBashToolOutputForDisplayAlloc(allocator, raw_output_text) catch return;
        defer allocator.free(output_text);

        const exit_code = if (result.details) |details| details.exit_code else null;
        const full_output_path = if (result.details) |details| details.full_output_path else null;
        const truncated = if (result.details) |details| details.truncation != null else false;
        const cancelled = self.abort_requested.load(.seq_cst);

        hooks.finish(
            hooks.context,
            item_index,
            command,
            output_text,
            exit_code,
            cancelled,
            truncated,
            full_output_path,
            exclude_from_context,
        ) catch {};

        bash_execution.recordBashExecution(
            allocator,
            session,
            command,
            output_text,
            exit_code,
            cancelled,
            truncated,
            full_output_path,
            exclude_from_context,
        ) catch |err| {
            const message = std.fmt.allocPrint(allocator, "Failed to record bash result: {s}", .{@errorName(err)}) catch return;
            defer allocator.free(message);
            hooks.append_error(hooks.context, message) catch {};
        };
    }

    fn updateCallback(context: ?*anyopaque, result: bash_tool_mod.BashExecutionResult) anyerror!void {
        const self: *UserBashTask = @ptrCast(@alignCast(context.?));
        const hooks = self.hooks orelse return;
        const raw_output_text = try bash_execution.contentBlocksTextAlloc(hooks.allocator, result.content);
        defer hooks.allocator.free(raw_output_text);
        const output_text = try bash_execution.sanitizeBashToolOutputForDisplayAlloc(hooks.allocator, raw_output_text);
        defer hooks.allocator.free(output_text);
        try hooks.update(hooks.context, self.item_index, self.command, output_text, self.exclude_from_context);
    }
};
