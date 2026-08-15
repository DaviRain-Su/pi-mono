const std = @import("std");
const builtin = @import("builtin");
const ai = @import("ai");
const agent = @import("agent");
const ts_rpc_wire = @import("ts_rpc_wire.zig");
const ts_rpc_bash = @import("ts_rpc_bash.zig");
const ts_rpc_state_json = @import("ts_rpc_state_json.zig");
const json_event_wire = @import("json_event_wire.zig");
const common = @import("../tools/common.zig");
const truncate = @import("../tools/truncate.zig");
const session_mod = @import("../sessions/session.zig");
const session_advanced = @import("../sessions/session_advanced.zig");
const session_cwd_mod = @import("../sessions/session_cwd.zig");
const session_manager_mod = @import("../sessions/session_manager.zig");
const extension_runtime = @import("../extensions/extension_runtime.zig");

pub const RunTsRpcModeOptions = struct {
    extension_ui_parity_scenario: bool = false,
    extension_host: ?ExtensionHostOptions = null,
};

pub const ExtensionHostOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    extension_path: ?[]const u8 = null,
    marker: []const u8,
    fixture: []const u8,
    ready_timeout_ms: u64 = 1000,
    shutdown_timeout_ms: u64 = 1000,
};

const PromptStreamingBehavior = enum {
    steer,
    follow_up,
};

const SessionReplacementResult = struct {
    cancelled: bool = false,
    selected_text: ?[]u8 = null,

    fn deinit(self: *SessionReplacementResult, allocator: std.mem.Allocator) void {
        if (self.selected_text) |text| allocator.free(text);
        self.* = undefined;
    }
};

const DeferredResponsePriority = enum(u8) {
    queued_prompt = 0,
    abort = 1,
    queue_control = 2,
    bash_completion = 3,
};

const DEFERRED_RESPONSE_FLUSH_INTERVAL_MS = 50;
const EXTENSION_HOST_EVENT_LOOP_TICK_MS = 10;
const EXTENSION_COMMAND_ACK_TIMEOUT_MS = 1000;

pub const command_types = ts_rpc_wire.command_types;
pub const isKnownCommandType = ts_rpc_wire.isKnownCommandType;
const TsRpcCommand = ts_rpc_wire.TsRpcCommand;
const stripTrailingCarriageReturn = ts_rpc_wire.stripTrailingCarriageReturn;
const writeJsonString = ts_rpc_wire.writeJsonString;

const DeferredResponse = struct {
    id: ?[]u8,
    command: []u8,
    data_json: ?[]u8 = null,
    priority: DeferredResponsePriority,
    sequence: usize,

    fn deinit(self: *DeferredResponse, allocator: std.mem.Allocator) void {
        if (self.id) |id_string| allocator.free(id_string);
        allocator.free(self.command);
        if (self.data_json) |data| allocator.free(data);
        self.* = undefined;
    }
};

const ExtensionUIDialogMethod = enum {
    select,
    confirm,
    input,
    editor,
};

const ExtensionUIResolution = union(enum) {
    none,
    value: []u8,
    confirmed: bool,

    fn clone(allocator: std.mem.Allocator, resolution: ExtensionUIResolution) !ExtensionUIResolution {
        return switch (resolution) {
            .none => .none,
            .confirmed => |confirmed| .{ .confirmed = confirmed },
            .value => |value| .{ .value = try allocator.dupe(u8, value) },
        };
    }

    fn deinit(self: *ExtensionUIResolution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .value => |value| allocator.free(value),
            else => {},
        }
        self.* = undefined;
    }
};

const PendingExtensionUIRequest = struct {
    method: ExtensionUIDialogMethod,
    timeout_ms: ?u64 = null,
    elapsed_ms: u64 = 0,

    fn defaultResolution(self: PendingExtensionUIRequest) ExtensionUIResolution {
        return switch (self.method) {
            .confirm => .{ .confirmed = false },
            .select, .input, .editor => .none,
        };
    }
};

const ResolvedExtensionUIRequest = struct {
    id: []u8,
    method: ExtensionUIDialogMethod,
    resolution: ExtensionUIResolution,

    fn deinit(self: *ResolvedExtensionUIRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.resolution.deinit(allocator);
        self.* = undefined;
    }
};

const PromptTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *TsRpcServer,
    session: *session_mod.AgentSession,
    id: ?[]u8,
    message: []u8,
    images: []ai.ImageContent,
    response_sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: *TsRpcServer,
        session: *session_mod.AgentSession,
        id: ?[]const u8,
        message: []u8,
        images: []ai.ImageContent,
    ) !*PromptTask {
        const task = try allocator.create(PromptTask);
        errdefer allocator.destroy(task);
        task.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .session = session,
            .id = if (id) |id_string| try allocator.dupe(u8, id_string) else null,
            .message = message,
            .images = images,
        };
        return task;
    }

    fn spawn(self: *PromptTask) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *PromptTask) void {
        defer self.done.store(true, .seq_cst);
        self.session.promptWithAcceptedCallback(
            .{ .text = self.message, .images = self.images },
            .{ .context = self, .callback = writePromptAccepted },
        ) catch |err| {
            if (!self.response_sent.load(.seq_cst)) {
                // Only write error to stdout when there is a TS-RPC request ID to respond to.
                // Background tasks (sendUserMessage) have id = null and must not pollute stdout.
                if (self.id != null) {
                    self.server.writeCommandError(self.id, "prompt", err) catch {};
                }
                self.response_sent.store(true, .seq_cst);
            }
        };
    }

    fn isDone(self: *const PromptTask) bool {
        return self.done.load(.seq_cst);
    }

    fn waitForResponse(self: *const PromptTask) void {
        while (!self.response_sent.load(.seq_cst)) {
            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
        }
    }

    fn joinAndDestroy(self: *PromptTask) void {
        if (self.thread) |thread| {
            thread.join();
        }
        if (self.id) |id_string| self.allocator.free(id_string);
        self.allocator.free(self.message);
        ts_rpc_state_json.deinitImages(self.allocator, self.images);
        self.allocator.destroy(self);
    }

    fn writePromptAccepted(context: ?*anyopaque) !void {
        const self: *PromptTask = @ptrCast(@alignCast(context.?));
        // Only write the TS-RPC acceptance response when there is a request ID.
        // Background tasks (from sendUserMessage) have id = null and must not
        // pollute the TS-RPC output stream.
        if (self.id != null) {
            try self.server.writeSuccessResponseNoData(self.id, "prompt");
            // Signal the main thread that the response has been written before
            // waiting. This allows the dispatcher to process already-buffered
            // JSONL input (abort, steer, follow_up, etc.) before agent events begin.
            self.response_sent.store(true, .seq_cst);
            // Wait until rapid controls are handled in dispatcher order instead
            // of racing the prompt worker. The wait must come after
            // response_sent.store so the main thread unblocks first.
            self.server.waitForPromptStart();
        }
    }
};

const TsRpcSessionHost = struct {
    server: *TsRpcServer,

    pub fn init(server: *TsRpcServer) TsRpcSessionHost {
        return .{ .server = server };
    }

    fn current(self: *TsRpcSessionHost) *session_mod.AgentSession {
        return self.server.session.?;
    }

    fn newSession(self: *TsRpcSessionHost, parent_session: ?[]const u8) !SessionReplacementResult {
        const old = self.current();
        var manager = try self.server.allocator.create(session_manager_mod.SessionManager);
        errdefer self.server.allocator.destroy(manager);
        manager.* = if (old.session_manager.isPersisted())
            try session_manager_mod.SessionManager.createWithParent(
                self.server.allocator,
                self.server.io,
                old.cwd,
                old.session_manager.getSessionDir(),
                parent_session,
            )
        else
            try session_manager_mod.SessionManager.inMemory(self.server.allocator, self.server.io, old.cwd);
        errdefer manager.deinit();

        try self.replaceWithManager(manager, manager.getCwd(), "new", null);
        return .{ .cancelled = false };
    }

    fn switchSession(self: *TsRpcSessionHost, session_path: []const u8) !SessionReplacementResult {
        const old = self.current();
        var manager = try self.server.allocator.create(session_manager_mod.SessionManager);
        errdefer self.server.allocator.destroy(manager);
        manager.* = try session_manager_mod.SessionManager.open(
            self.server.allocator,
            self.server.io,
            session_path,
            null,
        );
        errdefer manager.deinit();

        // Atomically reject the switch when the stored cwd no longer exists
        // before tearing down the current runtime. This matches TS
        // `RuntimeHost.switchSession` which throws `MissingSessionCwdError`
        // before mutating active session state.
        if (session_cwd_mod.getMissingSessionCwdIssue(self.server.io, manager, old.cwd) != null) {
            return error.MissingSessionCwd;
        }

        try self.replaceWithManager(manager, manager.getCwd(), "resume", session_path);
        return .{ .cancelled = false };
    }

    fn fork(self: *TsRpcSessionHost, entry_id: []const u8, position: enum { before, at }) !SessionReplacementResult {
        const old = self.current();
        const selected_entry = old.session_manager.getEntry(entry_id) orelse return error.InvalidEntryIdForForking;
        const target_leaf_id: ?[]const u8 = switch (position) {
            .at => selected_entry.id(),
            .before => blk: {
                if (selected_entry.* != .message) return error.InvalidEntryIdForForking;
                if (selected_entry.message.message != .user) return error.InvalidEntryIdForForking;
                break :blk selected_entry.message.parent_id;
            },
        };
        const selected_text = if (position == .before)
            try textBlocksConcat(self.server.allocator, selected_entry.message.message.user.content)
        else
            null;
        errdefer if (selected_text) |text| self.server.allocator.free(text);

        var manager = try self.server.allocator.create(session_manager_mod.SessionManager);
        errdefer self.server.allocator.destroy(manager);
        manager.* = if (target_leaf_id) |leaf_id|
            try old.session_manager.createBranchedSession(leaf_id)
        else if (old.session_manager.isPersisted())
            try session_manager_mod.SessionManager.createWithParent(
                self.server.allocator,
                self.server.io,
                old.cwd,
                old.session_manager.getSessionDir(),
                old.session_manager.getSessionFile(),
            )
        else
            try session_manager_mod.SessionManager.inMemory(self.server.allocator, self.server.io, old.cwd);
        errdefer manager.deinit();

        try self.replaceWithManager(manager, manager.getCwd(), "fork", null);
        return .{ .cancelled = false, .selected_text = selected_text };
    }

    fn clone(self: *TsRpcSessionHost) !SessionReplacementResult {
        const leaf_id = self.current().session_manager.getLeafId() orelse return error.CannotCloneSessionNoCurrentEntrySelected;
        return try self.fork(leaf_id, .at);
    }

    fn replaceWithManager(
        self: *TsRpcSessionHost,
        manager: *session_manager_mod.SessionManager,
        cwd: []const u8,
        reason: []const u8,
        explicit_target_session_file: ?[]const u8,
    ) !void {
        const old = self.current();
        const previous_session_file = if (old.session_manager.getSessionFile()) |file| try self.server.allocator.dupe(u8, file) else null;
        defer if (previous_session_file) |file| self.server.allocator.free(file);
        const target_session_file = explicit_target_session_file orelse manager.getSessionFile();
        const old_model = old.agent.getModel();
        const replacement_model = ai.model_registry.getDefault().find(old_model.provider, old_model.id) orelse old_model;
        const options = session_mod.AgentSession.ManagedOptions{
            .cwd = cwd,
            .system_prompt = old.system_prompt,
            .model = replacement_model,
            .api_key = old.agent.getApiKey(),
            .thinking_level = old.agent.getThinkingLevel(),
            .tools = old.agent.getTools(),
            .compaction = old.compaction_settings,
            .retry = old.retry_settings,
        };
        var replacement = session_mod.AgentSession.createWithManager(
            self.server.allocator,
            self.server.io,
            manager,
            options,
        ) catch |err| {
            manager.deinit();
            self.server.allocator.destroy(manager);
            return err;
        };
        replacement.agent.steering_queue.mode = old.agent.steering_queue.mode;
        replacement.agent.follow_up_queue.mode = old.agent.follow_up_queue.mode;
        errdefer replacement.deinit();

        self.server.cancelAndJoinPromptTasks();
        self.server.cancelAndJoinBashTasks();
        if (self.server.extension_host) |ext_host| {
            self.server.emitSessionShutdownEvent(ext_host, reason, previous_session_file, target_session_file);
        }
        self.server.detachFromCurrentSession();
        old.deinit();
        old.* = replacement;
        try self.server.attachToCurrentSession();
        if (self.server.extension_host) |ext_host| {
            self.server.emitSessionStartEvent(ext_host, reason, previous_session_file, old.session_manager.getSessionFile());
        }
    }
};

const TsRpcServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ?*session_mod.AgentSession,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    output_mutex: std.Io.Mutex = .init,
    subscriber: ?agent.AgentSubscriber = null,
    prompt_tasks: std.ArrayList(*PromptTask) = .empty,
    bash_manager: ts_rpc_bash.Manager,
    deferred_responses: std.ArrayList(DeferredResponse) = .empty,
    deferred_responses_mutex: std.Io.Mutex = .init,
    deferred_flush_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deferred_flush_input_backlog: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    input_dispatch_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deferred_flush_last_activity_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    deferred_flush_thread: ?std.Thread = null,
    next_deferred_response_sequence: usize = 0,
    pending_extension_requests: std.StringHashMap(PendingExtensionUIRequest),
    completed_extension_requests: std.ArrayList(ResolvedExtensionUIRequest) = .empty,
    extension_host: ?extension_runtime.RuntimeAdapter = null,
    suppress_events: bool = false,
    finished: bool = false,
    /// Incremented on each turn_start event so extension frames carry sequential turnIndex values.
    turn_index: usize = 0,
    /// IDs of pending wait_for_idle requests from the extension host. Each ID is resolved
    /// (and the response sent back to the host) when the agent becomes idle.
    pending_wait_for_idle_ids: std.ArrayList([]u8) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        session: ?*session_mod.AgentSession,
        stdout_writer: *std.Io.Writer,
        stderr_writer: *std.Io.Writer,
    ) TsRpcServer {
        return .{
            .allocator = allocator,
            .io = io,
            .session = session,
            .stdout_writer = stdout_writer,
            .stderr_writer = stderr_writer,
            .bash_manager = ts_rpc_bash.Manager.init(allocator, io),
            .pending_extension_requests = std.StringHashMap(PendingExtensionUIRequest).init(allocator),
        };
    }

    pub fn start(self: *TsRpcServer) !void {
        try self.attachToCurrentSession();
        self.deferred_flush_stop.store(false, .seq_cst);
        self.markDeferredFlushActivity();
        self.deferred_flush_thread = try std.Thread.spawn(.{}, deferredFlushMain, .{self});
    }

    pub fn startExtensionHost(self: *TsRpcServer, options: ExtensionHostOptions) !void {
        if (self.extension_host != null) return error.ExtensionHostAlreadyStarted;
        const host = try extension_runtime.startRuntimeAdapter(self.allocator, self.io, .{ .process_jsonl = .{
            .argv = options.argv,
            .cwd = options.cwd,
            .extension_path = options.extension_path,
            .initialize = .{
                .marker = options.marker,
                .cwd = options.cwd orelse "",
                .fixture = options.fixture,
            },
            .shutdown_timeout_ms = options.shutdown_timeout_ms,
        } });
        errdefer host.deinit();
        try host.waitForReady(options.ready_timeout_ms);
        self.extension_host = host;
        try self.drainExtensionHostUiRequests(50);
    }

    pub fn finish(self: *TsRpcServer) !void {
        if (self.finished) return;
        self.finished = true;
        self.deferred_flush_stop.store(true, .seq_cst);
        if (self.deferred_flush_thread) |thread| {
            thread.join();
            self.deferred_flush_thread = null;
        }
        try self.flushDeferredResponses();
        if (self.hasInFlightPrompt()) {
            self.abortActivePromptWork();
        }
        for (self.prompt_tasks.items) |task| {
            task.joinAndDestroy();
        }
        self.prompt_tasks.clearRetainingCapacity();
        self.joinBashTasks();
        try self.flushDeferredResponses();
        self.detachFromCurrentSession();
        self.prompt_tasks.deinit(self.allocator);
        self.prompt_tasks = .empty;
        self.deferred_responses.deinit(self.allocator);
        self.deferred_responses = .empty;
        self.bash_manager.deinit();
        if (self.extension_host) |host| {
            const previous_session_file = if (self.session) |session| session.session_manager.getSessionFile() else null;
            self.emitSessionShutdownEvent(host, "quit", previous_session_file, null);
            host.deinit();
            self.extension_host = null;
        }
        self.deinitExtensionUIState();
        try self.stdout_writer.flush();
        try self.stderr_writer.flush();
    }

    fn attachToCurrentSession(self: *TsRpcServer) !void {
        if (self.subscriber != null) return;
        if (self.session) |session| {
            self.subscriber = .{
                .context = self,
                .callback = handleTsRpcAgentEvent,
            };
            try session.agent.subscribe(self.subscriber.?);
            session.setRetryLifecycleCallback(.{
                .context = self,
                .callback = handleTsRpcRetryLifecycleEvent,
            });
        }
    }

    fn detachFromCurrentSession(self: *TsRpcServer) void {
        if (self.session) |session| {
            session.clearRetryLifecycleCallback();
            if (self.subscriber) |subscriber| {
                _ = session.agent.unsubscribe(subscriber);
                self.subscriber = null;
            }
        }
    }

    fn cancelAndJoinPromptTasks(self: *TsRpcServer) void {
        if (self.hasInFlightPrompt()) {
            self.abortActivePromptWork();
        }
        for (self.prompt_tasks.items) |task| {
            task.joinAndDestroy();
        }
        self.prompt_tasks.clearRetainingCapacity();
    }

    pub fn hasInFlightPrompt(self: *const TsRpcServer) bool {
        for (self.prompt_tasks.items) |task| {
            if (!task.isDone()) return true;
        }
        return false;
    }

    /// Returns true when the agent is currently streaming or a prompt task is in flight.
    fn isAgentBusy(self: *const TsRpcServer) bool {
        if (self.session) |session| {
            if (session.isStreaming()) return true;
        }
        return self.hasInFlightPrompt();
    }

    /// Resolve all pending wait_for_idle requests when the agent is idle.
    /// Sends extension_ui_response back to the host for each pending ID and removes
    /// it from the list. Safe to call repeatedly; no-op when agent is still busy or
    /// no requests are pending.
    fn resolveWaitForIdleRequests(self: *TsRpcServer) !void {
        if (self.pending_wait_for_idle_ids.items.len == 0) return;
        if (self.isAgentBusy()) return;
        const host = self.extension_host;
        var i: usize = self.pending_wait_for_idle_ids.items.len;
        while (i > 0) {
            i -= 1;
            const id = self.pending_wait_for_idle_ids.orderedRemove(i);
            defer self.allocator.free(id);
            if (host) |h| {
                try h.sendExtensionUiResponse(id, "{}");
            }
        }
    }

    fn markDeferredFlushActivity(self: *TsRpcServer) void {
        self.deferred_flush_last_activity_ms.store(self.deferredFlushNowMs(), .seq_cst);
    }

    fn setInputDispatchActive(self: *TsRpcServer, active: bool) void {
        self.input_dispatch_active.store(active, .seq_cst);
        self.markDeferredFlushActivity();
    }

    pub fn setDeferredFlushInputBacklog(self: *TsRpcServer, has_backlog: bool) void {
        self.deferred_flush_input_backlog.store(has_backlog, .seq_cst);
        if (has_backlog) self.markDeferredFlushActivity();
    }

    fn shouldHoldPromptStart(self: *TsRpcServer) bool {
        return self.deferred_flush_input_backlog.load(.seq_cst) or
            self.input_dispatch_active.load(.seq_cst) or
            self.hasPromptStartDeferredResponses();
    }

    fn waitForPromptStart(self: *TsRpcServer) void {
        while (!self.deferred_flush_stop.load(.seq_cst) and self.shouldHoldPromptStart()) {
            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
        }
    }

    fn shouldHoldDeferredFlush(self: *TsRpcServer) bool {
        if (self.deferred_flush_input_backlog.load(.seq_cst)) return true;
        const last_activity_ms = self.deferred_flush_last_activity_ms.load(.seq_cst);
        if (last_activity_ms == 0) return false;
        return self.deferredFlushNowMs() - last_activity_ms < DEFERRED_RESPONSE_FLUSH_INTERVAL_MS;
    }

    fn deferredFlushNowMs(self: *TsRpcServer) i64 {
        return @intCast(@divFloor(std.Io.Clock.now(.awake, self.io).nanoseconds, std.time.ns_per_ms));
    }

    pub fn abortActivePromptWork(self: *TsRpcServer) void {
        if (self.session) |session| {
            session.abortRetry();
            session.agent.abort();
        }
    }

    fn bashCompletionCallbacks(self: *TsRpcServer) ts_rpc_bash.CompletionCallbacks {
        return .{
            .context = self,
            .writeCommandError = writeBashCommandError,
            .enqueueBashResult = enqueueBashResult,
        };
    }

    fn writeBashCommandError(context: *anyopaque, id: ?[]const u8, err: anyerror) void {
        const self: *TsRpcServer = @ptrCast(@alignCast(context));
        self.writeCommandError(id, "bash", err) catch {};
    }

    fn enqueueBashResult(context: *anyopaque, id: ?[]const u8, data_json: []const u8, response_sequence: usize) void {
        const self: *TsRpcServer = @ptrCast(@alignCast(context));
        self.enqueueDeferredRawData(id, "bash", data_json, .bash_completion, response_sequence) catch {};
    }

    fn reapCompletedBashTasks(self: *TsRpcServer) void {
        self.bash_manager.reapCompleted();
    }

    pub fn hasActiveBashTask(self: *TsRpcServer) bool {
        return self.bash_manager.hasActiveTask();
    }

    pub fn activeBashTaskStarted(self: *TsRpcServer) bool {
        return self.bash_manager.activeTaskStarted();
    }

    pub fn hasUnfinishedBashTask(self: *TsRpcServer) bool {
        return self.bash_manager.hasUnfinishedTask();
    }

    fn abortActiveBashTask(self: *TsRpcServer) void {
        self.bash_manager.abortActiveTask();
    }

    pub fn cancelAndJoinBashTasks(self: *TsRpcServer) void {
        self.bash_manager.cancelAndJoinAll();
    }

    fn joinBashTasks(self: *TsRpcServer) void {
        self.bash_manager.joinAll();
    }

    fn deinitExtensionUIState(self: *TsRpcServer) void {
        var pending_iterator = self.pending_extension_requests.iterator();
        while (pending_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_extension_requests.deinit();

        for (self.completed_extension_requests.items) |*resolved| {
            resolved.deinit(self.allocator);
        }
        self.completed_extension_requests.deinit(self.allocator);
        self.completed_extension_requests = .empty;

        for (self.pending_wait_for_idle_ids.items) |id| self.allocator.free(id);
        self.pending_wait_for_idle_ids.deinit(self.allocator);
        self.pending_wait_for_idle_ids = .empty;
    }

    pub fn registerPendingExtensionUIRequest(
        self: *TsRpcServer,
        id: []const u8,
        method: ExtensionUIDialogMethod,
        timeout_ms: ?u64,
    ) !void {
        if (self.pending_extension_requests.fetchRemove(id)) |removed| {
            self.allocator.free(removed.key);
        }
        try self.pending_extension_requests.put(
            try self.allocator.dupe(u8, id),
            .{
                .method = method,
                .timeout_ms = timeout_ms,
            },
        );
    }

    fn resolvePendingExtensionUIRequest(
        self: *TsRpcServer,
        id: []const u8,
        resolution: ExtensionUIResolution,
    ) !bool {
        if (self.pending_extension_requests.fetchRemove(id)) |removed| {
            defer self.allocator.free(removed.key);
            try self.completed_extension_requests.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, id),
                .method = removed.value.method,
                .resolution = try ExtensionUIResolution.clone(self.allocator, resolution),
            });
            return true;
        }
        return false;
    }

    pub fn cancelPendingExtensionUIRequest(self: *TsRpcServer, id: []const u8) !bool {
        if (self.pending_extension_requests.get(id)) |pending| {
            const default_resolution = pending.defaultResolution();
            const did_resolve = try self.resolvePendingExtensionUIRequest(id, default_resolution);
            if (did_resolve) try self.forwardExtensionUIResolutionToHost(id, default_resolution);
            return did_resolve;
        }
        return false;
    }

    fn forwardExtensionUIResolutionToHost(self: *TsRpcServer, id: []const u8, resolution: ExtensionUIResolution) !void {
        const host = self.extension_host orelse return;
        var payload: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload.deinit();
        switch (resolution) {
            .none => try payload.writer.writeAll("{\"cancelled\":true}"),
            .value => |value| {
                try payload.writer.writeAll("{\"value\":");
                try writeJsonString(self.allocator, &payload.writer, value);
                try payload.writer.writeAll("}");
            },
            .confirmed => |confirmed| {
                try payload.writer.writeAll("{\"confirmed\":");
                try payload.writer.writeAll(if (confirmed) "true" else "false");
                try payload.writer.writeAll("}");
            },
        }
        try host.sendExtensionUiResponse(id, payload.written());
    }

    pub fn advanceExtensionUITime(self: *TsRpcServer, elapsed_ms: u64) !void {
        var timed_out_ids = std.ArrayList([]u8).empty;
        defer {
            for (timed_out_ids.items) |id| self.allocator.free(id);
            timed_out_ids.deinit(self.allocator);
        }

        var iterator = self.pending_extension_requests.iterator();
        while (iterator.next()) |entry| {
            const timeout_ms = entry.value_ptr.timeout_ms orelse continue;
            entry.value_ptr.elapsed_ms += elapsed_ms;
            if (entry.value_ptr.elapsed_ms >= timeout_ms) {
                try timed_out_ids.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
            }
        }

        for (timed_out_ids.items) |id| {
            _ = try self.cancelPendingExtensionUIRequest(id);
        }
    }

    fn handleExtensionUIResponse(self: *TsRpcServer, object: std.json.ObjectMap) !void {
        const id = requiredString(object, "id") catch return;

        if (object.get("cancelled")) |cancelled_value| {
            if (cancelled_value == .bool and cancelled_value.bool) {
                _ = try self.cancelPendingExtensionUIRequest(id);
                return;
            }
        }
        if (object.get("value")) |value| {
            if (value == .string) {
                const resolution = ExtensionUIResolution{ .value = @constCast(value.string) };
                if (try self.resolvePendingExtensionUIRequest(id, resolution)) {
                    try self.forwardExtensionUIResolutionToHost(id, resolution);
                }
                return;
            }
        }
        if (object.get("confirmed")) |confirmed| {
            if (confirmed == .bool) {
                const resolution = ExtensionUIResolution{ .confirmed = confirmed.bool };
                if (try self.resolvePendingExtensionUIRequest(id, resolution)) {
                    try self.forwardExtensionUIResolutionToHost(id, resolution);
                }
                return;
            }
        }
    }

    pub fn handleLine(self: *TsRpcServer, line: []const u8) !void {
        self.setInputDispatchActive(true);
        defer self.setInputDispatchActive(false);
        self.markDeferredFlushActivity();
        defer self.markDeferredFlushActivity();

        const ts_line = stripTrailingCarriageReturn(line);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, ts_line, .{}) catch {
            const message = try self.parseErrorMessage(ts_line);
            defer self.allocator.free(message);
            try self.writeErrorResponse(null, "parse", message);
            return;
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("type")) |type_value| {
                if (type_value == .string and std.mem.eql(u8, type_value.string, "extension_ui_response")) {
                    try self.handleExtensionUIResponse(parsed.value.object);
                    return;
                }
            }
        }

        const object = switch (parsed.value) {
            .object => |object| object,
            else => {
                try self.writeUnknownCommand(null);
                return;
            },
        };

        const id = if (object.get("id")) |id_value| switch (id_value) {
            .string => |id_string| id_string,
            else => null,
        } else null;

        const command_type = if (object.get("type")) |type_value| switch (type_value) {
            .string => |type_string| type_string,
            else => null,
        } else null;

        const command = command_type orelse {
            try self.writeUnknownCommand(null);
            return;
        };

        // navigate_to is a Zig-only extension command not in the TypeScript protocol.
        // Allow it through without the isKnownCommandType gate.
        if (!std.mem.eql(u8, command, "navigate_to") and !isKnownCommandType(command)) {
            try self.writeUnsupportedCommandType(id, command);
            return;
        }

        try self.handleCommand(id, command, object);
    }

    fn handleCommand(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        object: std.json.ObjectMap,
    ) !void {
        self.reapCompletedBashTasks();
        const session = self.session orelse {
            try self.writeNotImplemented(id, command);
            return;
        };

        // navigate_to is a Zig-only extension command not in the TypeScript
        // protocol. It is gated separately above isKnownCommandType, so it
        // never appears in the TsRpcCommand enum; handle it before the switch.
        if (std.mem.eql(u8, command, "navigate_to")) {
            const entry_id = requiredString(object, "entryId") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const old_leaf_id_raw = session.session_manager.getLeafId();
            const old_leaf_id = if (old_leaf_id_raw) |lid| try self.allocator.dupe(u8, lid) else null;
            defer if (old_leaf_id) |lid| self.allocator.free(lid);
            if (self.extension_host) |ext_host| self.emitSessionBeforeTreeEvent(ext_host, entry_id);
            session.navigateTo(entry_id) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const new_leaf_id = session.session_manager.getLeafId();
            if (self.extension_host) |ext_host| self.emitSessionTreeEvent(ext_host, new_leaf_id, old_leaf_id);
            try self.writeSuccessResponseNoData(id, command);
            return;
        }

        const tag = std.meta.stringToEnum(TsRpcCommand, command) orelse {
            try self.writeNotImplemented(id, command);
            return;
        };

        switch (tag) {
            .prompt => {
                const message = requiredString(object, "message") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                const images = ts_rpc_state_json.parseImages(self.allocator, object) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                var images_owned = true;
                defer if (images_owned) ts_rpc_state_json.deinitImages(self.allocator, images);
                const streaming_behavior = parsePromptStreamingBehavior(object) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };

                if (try self.tryDispatchExtensionPromptCommand(id, command, message)) {
                    return;
                }

                // Emit input extension event before agent processes the message
                if (self.extension_host) |host| self.emitExtensionInputEvent(host, message, "rpc");

                if (session.isStreaming() or self.hasInFlightPrompt()) {
                    const behavior = streaming_behavior orelse {
                        try self.writeErrorResponse(
                            id,
                            command,
                            "Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.",
                        );
                        return;
                    };
                    switch (behavior) {
                        .steer => session.steer(message, images) catch |err| {
                            try self.writeCommandError(id, command, err);
                            return;
                        },
                        .follow_up => session.followUp(message, images) catch |err| {
                            try self.writeCommandError(id, command, err);
                            return;
                        },
                    }
                    try self.writeQueueUpdate();
                    try self.enqueueDeferredSuccess(id, command, .queued_prompt);
                    return;
                }

                const message_copy = self.allocator.dupe(u8, message) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                var message_owned = true;
                defer if (message_owned) self.allocator.free(message_copy);

                const task = PromptTask.create(self.allocator, self.io, self, session, id, message_copy, images) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                images_owned = false;
                message_owned = false;
                self.prompt_tasks.append(self.allocator, task) catch |err| {
                    task.joinAndDestroy();
                    try self.writeCommandError(id, command, err);
                    return;
                };
                task.spawn() catch |err| {
                    _ = self.prompt_tasks.pop();
                    task.joinAndDestroy();
                    try self.writeCommandError(id, command, err);
                    return;
                };
                task.waitForResponse();
            },

            .steer => {
                const message = requiredString(object, "message") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                const images = ts_rpc_state_json.parseImages(self.allocator, object) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                defer ts_rpc_state_json.deinitImages(self.allocator, images);
                session.steer(message, images) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                try self.writeQueueUpdate();
                if (session.isStreaming() or self.hasInFlightPrompt()) {
                    try self.enqueueDeferredSuccess(id, command, .queue_control);
                } else {
                    try self.writeSuccessResponseNoData(id, command);
                }
            },

            .follow_up => {
                const message = requiredString(object, "message") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                const images = ts_rpc_state_json.parseImages(self.allocator, object) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                defer ts_rpc_state_json.deinitImages(self.allocator, images);
                session.followUp(message, images) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                try self.writeQueueUpdate();
                if (session.isStreaming() or self.hasInFlightPrompt()) {
                    try self.enqueueDeferredSuccess(id, command, .queue_control);
                } else {
                    try self.writeSuccessResponseNoData(id, command);
                }
            },

            .abort => {
                const defer_response = session.isStreaming() or self.hasInFlightPrompt();
                if (defer_response) {
                    try self.enqueueDeferredSuccess(id, command, .abort);
                } else {
                    self.abortActivePromptWork();
                    try self.writeSuccessResponseNoData(id, command);
                }
            },

            .new_session => {
                const parent_session = optionalString(object, "parentSession") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                if (self.extension_host) |ext_host| {
                    // For new sessions, targetSessionFile is undefined (the new session file
                    // doesn't exist yet). parentSession is the old session being shut down,
                    // not the target for the switch event.
                    self.emitSessionBeforeSwitchEvent(ext_host, "new", null);
                }
                var host = TsRpcSessionHost.init(self);
                const result = host.newSession(parent_session) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                _ = result;
                try self.writeSuccessResponseRawData(id, command, "{\"cancelled\":false}");
            },

            .get_state => {
                const data = try ts_rpc_state_json.buildStateJson(self.allocator, session);
                defer self.allocator.free(data);
                try self.writeSuccessResponseRawData(id, command, data);
            },

            .set_model => {
                const provider = requiredString(object, "provider") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                const model_id = requiredString(object, "modelId") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                const model = ai.model_registry.getDefault().find(provider, model_id) orelse {
                    const message = try std.fmt.allocPrint(self.allocator, "Model not found: {s}/{s}", .{ provider, model_id });
                    defer self.allocator.free(message);
                    try self.writeErrorResponse(id, command, message);
                    return;
                };
                const prev_model = session.agent.getModel();
                const changed = !modelsEqual(prev_model, model);
                session.setModel(model) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                if (changed) {
                    if (self.extension_host) |host| self.emitExtensionModelSelectEvent(host, session.agent.getModel(), prev_model, "set");
                }
                const data = try ts_rpc_state_json.buildModelJson(self.allocator, model);
                defer self.allocator.free(data);
                try self.writeSuccessResponseRawData(id, command, data);
            },

            .cycle_model => {
                try self.writeSuccessResponseRawData(id, command, "null");
            },

            .get_available_models => {
                const data = try ts_rpc_state_json.buildAvailableModelsJson(self.allocator);
                defer self.allocator.free(data);
                try self.writeSuccessResponseRawData(id, command, data);
            },

            .set_thinking_level => {
                const level = ts_rpc_state_json.parseThinkingLevel(object, "level") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                const prev_level = session.agent.getThinkingLevel();
                const effective_level = clampAgentThinkingLevel(session.agent.getModel(), level);
                session.setThinkingLevelWithSource(effective_level, "set") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                if (effective_level != prev_level) {
                    if (self.extension_host) |host| self.emitExtensionThinkingLevelSelectEvent(host, effective_level, prev_level, "set");
                }
                try self.writeSuccessResponseNoData(id, command);
            },

            .cycle_thinking_level => {
                const model = session.agent.getModel();
                if (!model.reasoning) {
                    try self.writeSuccessResponseRawData(id, command, "null");
                    return;
                }
                const prev_level = session.agent.getThinkingLevel();
                const next_level = ts_rpc_state_json.nextSupportedThinkingLevel(model, prev_level);
                session.setThinkingLevelWithSource(next_level, "cycle") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                if (next_level != prev_level) {
                    if (self.extension_host) |host| self.emitExtensionThinkingLevelSelectEvent(host, next_level, prev_level, "cycle");
                }
                const data = try std.fmt.allocPrint(self.allocator, "{{\"level\":\"{s}\"}}", .{ts_rpc_state_json.thinkingLevelName(next_level)});
                defer self.allocator.free(data);
                try self.writeSuccessResponseRawData(id, command, data);
            },

            .set_steering_mode => {
                session.agent.steering_queue.mode = ts_rpc_state_json.parseQueueMode(object, "mode") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                try self.writeSuccessResponseNoData(id, command);
            },

            .set_follow_up_mode => {
                session.agent.follow_up_queue.mode = ts_rpc_state_json.parseQueueMode(object, "mode") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                try self.writeSuccessResponseNoData(id, command);
            },

            .compact => {
                const custom_instructions = optionalString(object, "customInstructions") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                if (self.extension_host) |ext_host| self.emitSessionBeforeCompactEvent(ext_host, custom_instructions);
                try self.writeCompactionStartEvent("manual");
                const result = session.compact(custom_instructions) catch |err| {
                    try self.writeCompactionEndEvent("manual", null, true, false);
                    try self.writeCommandError(id, command, err);
                    return;
                };
                const data = try ts_rpc_state_json.buildCompactionResultJson(self.allocator, result);
                defer self.allocator.free(data);
                try self.writeCompactionEndEvent("manual", data, false, false);
                if (self.extension_host) |ext_host| self.emitSessionCompactEvent(ext_host);
                try self.writeSuccessResponseRawData(id, command, data);
            },

            .set_auto_compaction => {
                session.compaction_settings.enabled = parseRequiredBool(object, "enabled") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                try self.writeSuccessResponseNoData(id, command);
            },

            .set_auto_retry => {
                session.retry_settings.enabled = parseRequiredBool(object, "enabled") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                try self.writeSuccessResponseNoData(id, command);
            },

            .abort_retry => {
                session.abortRetry();
                try self.writeSuccessResponseNoData(id, command);
            },

            .bash => {
                const bash_command = requiredString(object, "command") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                self.bash_manager.start(self.bashCompletionCallbacks(), session.cwd, id, bash_command) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
            },

            .abort_bash => {
                self.output_mutex.lockUncancelable(self.io);
                defer self.output_mutex.unlock(self.io);
                self.abortActiveBashTask();
                try self.writeSuccessResponseNoDataLocked(id, command);
            },

            .get_session_stats => {
                const data = try ts_rpc_state_json.buildSessionStatsJson(self.allocator, session);
                defer self.allocator.free(data);
                try self.writeSuccessResponseRawData(id, command, data);
            },

            .export_html => {
                const output_path = optionalString(object, "outputPath") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                const path = session_advanced.exportToHtml(self.allocator, self.io, session, output_path) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                defer self.allocator.free(path);
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                defer out.deinit();
                try out.writer.writeAll("{\"path\":");
                try writeJsonString(self.allocator, &out.writer, path);
                try out.writer.writeAll("}");
                try self.writeSuccessResponseRawData(id, command, out.written());
            },

            .switch_session => {
                const session_path = requiredString(object, "sessionPath") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                if (self.extension_host) |ext_host| {
                    self.emitSessionBeforeSwitchEvent(ext_host, "resume", session_path);
                }
                var host = TsRpcSessionHost.init(self);
                var result = host.switchSession(session_path) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                defer result.deinit(self.allocator);
                try self.writeSuccessResponseRawData(id, command, "{\"cancelled\":false}");
            },

            .fork => {
                const entry_id = requiredString(object, "entryId") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                if (self.extension_host) |ext_host| {
                    self.emitSessionBeforeForkEvent(ext_host, entry_id, "before");
                }
                var host = TsRpcSessionHost.init(self);
                var result = host.fork(entry_id, .before) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                defer result.deinit(self.allocator);
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                defer out.deinit();
                try out.writer.writeAll("{\"text\":");
                try writeJsonString(self.allocator, &out.writer, result.selected_text orelse "");
                try out.writer.writeAll(",\"cancelled\":false}");
                try self.writeSuccessResponseRawData(id, command, out.written());
            },

            .clone => {
                if (self.extension_host) |ext_host| {
                    if (session.session_manager.getLeafId()) |leaf_id| {
                        self.emitSessionBeforeForkEvent(ext_host, leaf_id, "at");
                    }
                }
                var host = TsRpcSessionHost.init(self);
                var result = host.clone() catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                defer result.deinit(self.allocator);
                try self.writeSuccessResponseRawData(id, command, "{\"cancelled\":false}");
            },

            .get_fork_messages => {
                const data = try ts_rpc_state_json.buildForkMessagesJson(self.allocator, session);
                defer self.allocator.free(data);
                try self.writeSuccessResponseRawData(id, command, data);
            },

            .get_last_assistant_text => {
                const text = try lastAssistantTextAlloc(self.allocator, session);
                defer if (text) |value| self.allocator.free(value);
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                defer out.deinit();
                try out.writer.writeAll("{\"text\":");
                if (text) |value| {
                    try writeJsonString(self.allocator, &out.writer, value);
                } else {
                    try out.writer.writeAll("null");
                }
                try out.writer.writeAll("}");
                try self.writeSuccessResponseRawData(id, command, out.written());
            },

            .set_session_name => {
                const raw_name = requiredString(object, "name") catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                const name = std.mem.trim(u8, raw_name, &std.ascii.whitespace);
                if (name.len == 0) {
                    try self.writeErrorResponse(id, command, "Session name cannot be empty");
                    return;
                }
                _ = session.session_manager.appendSessionInfo(name) catch |err| {
                    try self.writeCommandError(id, command, err);
                    return;
                };
                try self.writeSessionInfoChangedEvent(name);
                try self.writeSuccessResponseNoData(id, command);
            },

            .get_messages => {
                const data = try ts_rpc_state_json.buildMessagesJson(self.allocator, session.agent.getMessages());
                defer self.allocator.free(data);
                try self.writeSuccessResponseRawData(id, command, data);
            },

            .get_commands => {
                const data = try self.buildCommandsJson();
                defer self.allocator.free(data);
                try self.writeSuccessResponseRawData(id, command, data);
            },
        }
    }

    fn writeCommandError(self: *TsRpcServer, id: ?[]const u8, command: []const u8, err: anyerror) !void {
        try self.writeErrorResponse(id, command, @errorName(err));
    }

    fn writeNotImplemented(self: *TsRpcServer, id: ?[]const u8, command: []const u8) !void {
        const message = try std.fmt.allocPrint(self.allocator, "Not implemented: {s}", .{command});
        defer self.allocator.free(message);
        try self.writeErrorResponse(id, command, message);
    }

    fn writeUnknownCommand(self: *TsRpcServer, command: ?[]const u8) !void {
        const message = if (command) |command_name|
            try std.fmt.allocPrint(self.allocator, "Unknown command: {s}", .{command_name})
        else
            try self.allocator.dupe(u8, "Unknown command: undefined");
        defer self.allocator.free(message);
        try self.writeErrorResponse(null, command, message);
    }

    fn writeUnsupportedCommandType(self: *TsRpcServer, id: ?[]const u8, command: []const u8) !void {
        const message = try std.fmt.allocPrint(
            self.allocator,
            "$.type: unsupported RPC command type \"{s}\"",
            .{command},
        );
        defer self.allocator.free(message);
        try self.writeErrorResponse(id, command, message);
    }

    fn buildCommandsJson(self: *TsRpcServer) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.writeAll("{\"commands\":[");
        if (self.extension_host) |host| {
            var context = ExtensionCommandsJsonContext{
                .allocator = self.allocator,
                .writer = &out.writer,
            };
            try host.withRegistry(&context, writeExtensionCommandsJsonCallback);
        }
        try out.writer.writeAll("]}");
        return try self.allocator.dupe(u8, out.written());
    }

    fn tryDispatchExtensionPromptCommand(
        self: *TsRpcServer,
        id: ?[]const u8,
        response_command: []const u8,
        message: []const u8,
    ) !bool {
        const host = self.extension_host orelse return false;
        const invocation = parseSlashCommandInvocation(message) orelse return false;
        if (!host.hasRegisteredCommand(invocation.name)) return false;

        const event = try extensionCommandEventValue(self.allocator, invocation.name, invocation.argument);
        defer common.deinitJsonValue(self.allocator, event);
        const result = host.invokeExtensionEvent(self.allocator, "command", event, EXTENSION_COMMAND_ACK_TIMEOUT_MS) catch |err| {
            try self.writeCommandError(id, response_command, err);
            try self.drainExtensionHostUiRequests(50);
            return true;
        };
        defer if (result) |value| common.deinitJsonValue(self.allocator, value);
        if (result) |value| {
            const data = try extensionCommandResultDataJson(self.allocator, invocation.name, value);
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, response_command, data);
        } else {
            const failure_message = try std.fmt.allocPrint(self.allocator, "Extension command did not acknowledge: {s}", .{invocation.name});
            defer self.allocator.free(failure_message);
            try self.writeErrorResponse(id, response_command, failure_message);
        }
        try self.drainExtensionHostUiRequests(50);
        return true;
    }

    fn parseErrorMessage(self: *TsRpcServer, line: []const u8) ![]u8 {
        const detail = try ts_rpc_wire.jsonParseErrorDetail(self.allocator, line);
        defer self.allocator.free(detail);
        return try std.fmt.allocPrint(self.allocator, "Failed to parse command: {s}", .{detail});
    }

    pub fn writeSuccessResponseNoData(self: *TsRpcServer, id: ?[]const u8, command: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.writeSuccessResponseNoDataLocked(id, command);
    }

    fn writeSuccessResponseNoDataLocked(self: *TsRpcServer, id: ?[]const u8, command: []const u8) !void {
        try ts_rpc_wire.writeSuccessResponseNoData(self.allocator, self.stdout_writer, id, command);
        try self.stdout_writer.flush();
    }

    pub fn writeSuccessResponseRawData(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        data_json: []const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        try ts_rpc_wire.writeSuccessResponseRawData(self.allocator, self.stdout_writer, id, command, data_json);
        try self.stdout_writer.flush();
    }

    pub fn writeErrorResponse(self: *TsRpcServer, id: ?[]const u8, command: ?[]const u8, message: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        try ts_rpc_wire.writeErrorResponse(self.allocator, self.stdout_writer, id, command, message);
        try self.stdout_writer.flush();
    }

    fn writeFailureResponseRawData(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        message: []const u8,
        data_json: []const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        try self.stdout_writer.writeAll("{");
        try ts_rpc_wire.writeIdField(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll("\"type\":\"response\",\"command\":");
        try writeJsonString(self.allocator, self.stdout_writer, command);
        try self.stdout_writer.writeAll(",\"success\":false,\"error\":");
        try writeJsonString(self.allocator, self.stdout_writer, message);
        try self.stdout_writer.writeAll(",\"data\":");
        try self.stdout_writer.writeAll(data_json);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    pub fn writeExtensionUISelectRequest(
        self: *TsRpcServer,
        id: []const u8,
        title: []const u8,
        options: []const []const u8,
        timeout_ms: ?u64,
    ) !void {
        try self.registerPendingExtensionUIRequest(id, .select, timeout_ms);
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try ts_rpc_wire.writeExtensionUISelectRequest(self.allocator, self.stdout_writer, id, title, options, timeout_ms);
        try self.stdout_writer.flush();
    }

    pub fn writeExtensionUIConfirmRequest(
        self: *TsRpcServer,
        id: []const u8,
        title: []const u8,
        message: []const u8,
        timeout_ms: ?u64,
    ) !void {
        try self.registerPendingExtensionUIRequest(id, .confirm, timeout_ms);
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try ts_rpc_wire.writeExtensionUIConfirmRequest(self.allocator, self.stdout_writer, id, title, message, timeout_ms);
        try self.stdout_writer.flush();
    }

    pub fn writeExtensionUIInputRequest(
        self: *TsRpcServer,
        id: []const u8,
        title: []const u8,
        placeholder: ?[]const u8,
        timeout_ms: ?u64,
    ) !void {
        try self.registerPendingExtensionUIRequest(id, .input, timeout_ms);
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try ts_rpc_wire.writeExtensionUIInputRequest(self.allocator, self.stdout_writer, id, title, placeholder, timeout_ms);
        try self.stdout_writer.flush();
    }

    pub fn writeExtensionUIEditorRequest(
        self: *TsRpcServer,
        id: []const u8,
        title: []const u8,
        prefill: ?[]const u8,
    ) !void {
        try self.registerPendingExtensionUIRequest(id, .editor, null);
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try ts_rpc_wire.writeExtensionUIEditorRequest(self.allocator, self.stdout_writer, id, title, prefill);
        try self.stdout_writer.flush();
    }

    pub fn writeExtensionUINotifyRequest(
        self: *TsRpcServer,
        id: []const u8,
        message: []const u8,
        notify_type: ?[]const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try ts_rpc_wire.writeExtensionUINotifyRequest(self.allocator, self.stdout_writer, id, message, notify_type);
        try self.stdout_writer.flush();
    }

    pub fn writeExtensionUISetStatusRequest(
        self: *TsRpcServer,
        id: []const u8,
        status_key: []const u8,
        status_text: ?[]const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try ts_rpc_wire.writeExtensionUISetStatusRequest(self.allocator, self.stdout_writer, id, status_key, status_text);
        try self.stdout_writer.flush();
    }

    pub fn writeExtensionUISetWidgetRequest(
        self: *TsRpcServer,
        id: []const u8,
        widget_key: []const u8,
        widget_lines: ?[]const []const u8,
        widget_placement: ?[]const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try ts_rpc_wire.writeExtensionUISetWidgetRequest(self.allocator, self.stdout_writer, id, widget_key, widget_lines, widget_placement);
        try self.stdout_writer.flush();
    }

    pub fn writeExtensionUISetTitleRequest(self: *TsRpcServer, id: []const u8, title: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try ts_rpc_wire.writeExtensionUISetTitleRequest(self.allocator, self.stdout_writer, id, title);
        try self.stdout_writer.flush();
    }

    pub fn writeExtensionUISetEditorTextRequest(self: *TsRpcServer, id: []const u8, text: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try ts_rpc_wire.writeExtensionUISetEditorTextRequest(self.allocator, self.stdout_writer, id, text);
        try self.stdout_writer.flush();
    }

    fn emitExtensionUIParityScenario(self: *TsRpcServer) !void {
        const select_options = [_][]const u8{ "option-a", "option-b" };
        const widget_lines = [_][]const u8{ "line one", "line two" };

        try self.writeExtensionUISelectRequest("ui_select", "Choose fixture", &select_options, 1000);
        try self.writeExtensionUIConfirmRequest("ui_confirm", "Confirm fixture", "Proceed?", 1000);
        try self.writeExtensionUIInputRequest("ui_input", "Fixture input", "value", 1000);
        try self.writeExtensionUINotifyRequest("ui_notify", "Fixture notice", "info");
        try self.writeExtensionUISetStatusRequest("ui_status", "fixture", "ready");
        try self.writeExtensionUISetWidgetRequest("ui_widget", "fixture", &widget_lines, "aboveEditor");
        try self.writeExtensionUISetTitleRequest("ui_title", "Fixture Title");
        try self.writeExtensionUISetEditorTextRequest("ui_editor_text", "fixture editor text");
        try self.writeExtensionUIEditorRequest("ui_editor", "Edit fixture", "prefill");
    }

    fn drainAvailableExtensionHostUiRequests(self: *TsRpcServer) !usize {
        const host = self.extension_host orelse return 0;
        var drained_count: usize = 0;
        while (true) {
            const requests = try host.takeUiRequests(self.allocator);
            {
                defer {
                    for (requests) |*request| request.deinit(self.allocator);
                    self.allocator.free(requests);
                }
                if (requests.len == 0) return drained_count;
                drained_count += requests.len;
                for (requests) |*request| {
                    try self.writeExtensionUIRequestFromHost(request.*);
                }
            }
        }
    }

    pub fn drainExtensionHostUiRequests(self: *TsRpcServer, idle_ms: u64) !void {
        if (self.extension_host == null) return;
        var idle_elapsed: u64 = 0;
        while (true) {
            const drained_count = try self.drainAvailableExtensionHostUiRequests();
            if (drained_count != 0) {
                idle_elapsed = 0;
                continue;
            }
            if (idle_elapsed >= idle_ms) return;
            const remaining = idle_ms - idle_elapsed;
            const sleep_ms: i64 = @intCast(if (remaining < EXTENSION_HOST_EVENT_LOOP_TICK_MS) remaining else EXTENSION_HOST_EVENT_LOOP_TICK_MS);
            if (sleep_ms == 0) return;
            std.Io.sleep(self.io, .fromMilliseconds(sleep_ms), .awake) catch {};
            idle_elapsed += @intCast(sleep_ms);
        }
    }

    pub fn serviceExtensionHostIdleTick(self: *TsRpcServer, elapsed_ms: u64) !void {
        _ = try self.drainAvailableExtensionHostUiRequests();
        if (elapsed_ms != 0) try self.advanceExtensionUITime(elapsed_ms);
        _ = try self.drainAvailableExtensionHostUiRequests();
        try self.resolveWaitForIdleRequests();
    }

    pub fn writeExtensionUIRequestFromHost(self: *TsRpcServer, request: extension_runtime.ExtensionUiRequest) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, request.payload_json, .{}) catch return;
        defer parsed.deinit();
        const payload = switch (parsed.value) {
            .object => |object| object,
            else => return,
        };

        if (try self.writeExtensionUIDialogRequestFromHost(request, payload)) return;
        if (try self.writeExtensionUISurfaceRequestFromHost(request, payload)) return;
        if (try self.writeExtensionCommandContextRequestFromHost(request, payload)) return;
    }

    fn writeExtensionUIDialogRequestFromHost(
        self: *TsRpcServer,
        request: extension_runtime.ExtensionUiRequest,
        payload: std.json.ObjectMap,
    ) !bool {
        if (std.mem.eql(u8, request.method, "select")) {
            const title = requiredString(payload, "title") catch return true;
            const options = try requiredStringArray(self.allocator, payload, "options");
            defer self.allocator.free(options);
            try self.writeExtensionUISelectRequest(request.id, title, options, optionalU64(payload, "timeout"));
            return true;
        }
        if (std.mem.eql(u8, request.method, "confirm")) {
            const title = requiredString(payload, "title") catch return true;
            const message = requiredString(payload, "message") catch return true;
            try self.writeExtensionUIConfirmRequest(request.id, title, message, optionalU64(payload, "timeout"));
            return true;
        }
        if (std.mem.eql(u8, request.method, "input")) {
            const title = requiredString(payload, "title") catch return true;
            const placeholder = optionalString(payload, "placeholder") catch return true;
            try self.writeExtensionUIInputRequest(request.id, title, placeholder, optionalU64(payload, "timeout"));
            return true;
        }
        if (std.mem.eql(u8, request.method, "editor")) {
            const title = requiredString(payload, "title") catch return true;
            const prefill = optionalString(payload, "prefill") catch return true;
            try self.writeExtensionUIEditorRequest(request.id, title, prefill);
            return true;
        }
        return false;
    }

    fn writeExtensionUISurfaceRequestFromHost(
        self: *TsRpcServer,
        request: extension_runtime.ExtensionUiRequest,
        payload: std.json.ObjectMap,
    ) !bool {
        if (std.mem.eql(u8, request.method, "notify")) {
            const message = requiredString(payload, "message") catch return true;
            const notify_type = optionalString(payload, "notifyType") catch return true;
            try self.writeExtensionUINotifyRequest(request.id, message, notify_type);
            return true;
        }
        if (std.mem.eql(u8, request.method, "setStatus")) {
            const status_key = requiredString(payload, "statusKey") catch return true;
            const status_text = optionalString(payload, "statusText") catch return true;
            try self.writeExtensionUISetStatusRequest(request.id, status_key, status_text);
            return true;
        }
        if (std.mem.eql(u8, request.method, "setWidget")) {
            const widget_key = requiredString(payload, "widgetKey") catch return true;
            const widget_lines = try optionalStringArray(self.allocator, payload, "widgetLines");
            defer if (widget_lines) |lines| self.allocator.free(lines);
            const widget_placement = optionalString(payload, "widgetPlacement") catch return true;
            try self.writeExtensionUISetWidgetRequest(request.id, widget_key, widget_lines, widget_placement);
            return true;
        }
        if (std.mem.eql(u8, request.method, "setTitle")) {
            const title = requiredString(payload, "title") catch return true;
            try self.writeExtensionUISetTitleRequest(request.id, title);
            return true;
        }
        if (std.mem.eql(u8, request.method, "set_editor_text")) {
            const text = requiredString(payload, "text") catch return true;
            try self.writeExtensionUISetEditorTextRequest(request.id, text);
            return true;
        }
        return false;
    }

    fn writeExtensionCommandContextRequestFromHost(
        self: *TsRpcServer,
        request: extension_runtime.ExtensionUiRequest,
        payload: std.json.ObjectMap,
    ) !bool {
        if (std.mem.eql(u8, request.method, "wait_for_idle")) {
            try self.handleExtensionWaitForIdleRequest(request.id);
            return true;
        }
        if (std.mem.eql(u8, request.method, "send_custom_message")) {
            try self.handleExtensionSendCustomMessageRequest(request.id, payload);
            return true;
        }
        if (std.mem.eql(u8, request.method, "send_user_message")) {
            try self.handleExtensionSendUserMessageRequest(request.id, payload);
            return true;
        }
        return false;
    }

    fn handleExtensionWaitForIdleRequest(self: *TsRpcServer, id: []const u8) !void {
        if (!self.isAgentBusy()) {
            try self.sendExtensionUiResponseIfPresent(id, "{}");
        } else {
            const id_copy = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(id_copy);
            try self.pending_wait_for_idle_ids.append(self.allocator, id_copy);
        }
    }

    fn handleExtensionSendCustomMessageRequest(
        self: *TsRpcServer,
        id: []const u8,
        payload: std.json.ObjectMap,
    ) !void {
        const session = self.session orelse return;
        const custom_type_or_null = optionalString(payload, "customType") catch {
            try self.sendExtensionUiResponseIfPresent(id, "{\"error\":\"customType must be a string\"}");
            return;
        };
        const custom_type = custom_type_or_null orelse "extension.message";
        const display = optionalBool(payload, "display") orelse true;
        const trigger_turn = optionalBool(payload, "triggerTurn") orelse false;
        const deliver_as = optionalString(payload, "deliverAs") catch {
            try self.sendExtensionUiResponseIfPresent(id, "{\"error\":\"deliverAs must be a string\"}");
            return;
        };

        if (try self.rejectUnsupportedNextTurn(id, deliver_as)) return;

        const content_text = extensionPayloadText(payload, "content");
        const content: session_manager_mod.CustomMessageContent = .{ .text = content_text };
        const details = payload.get("details");
        _ = try session.session_manager.appendCustomMessageEntry(custom_type, content, display, details);

        if (session.isStreaming() or self.hasInFlightPrompt()) {
            deliverExtensionCustomTextWhileBusy(session, content_text, deliver_as);
        } else if (trigger_turn) {
            try self.startExtensionPromptTask(session, content_text);
        }

        try self.sendExtensionUiResponseIfPresent(id, "{}");
    }

    fn handleExtensionSendUserMessageRequest(
        self: *TsRpcServer,
        id: []const u8,
        payload: std.json.ObjectMap,
    ) !void {
        const session = self.session orelse return;
        const text = optionalString(payload, "text") catch {
            try self.sendExtensionUiResponseIfPresent(id, "{\"error\":\"text must be a string\"}");
            return;
        } orelse "";
        const deliver_as = optionalString(payload, "deliverAs") catch {
            try self.sendExtensionUiResponseIfPresent(id, "{\"error\":\"deliverAs must be a string\"}");
            return;
        };

        if (try self.rejectUnsupportedNextTurn(id, deliver_as)) return;

        if (session.isStreaming() or self.hasInFlightPrompt()) {
            deliverExtensionUserTextWhileBusy(session, text, deliver_as);
        } else {
            try self.startExtensionPromptTask(session, text);
        }

        try self.sendExtensionUiResponseIfPresent(id, "{}");
    }

    fn sendExtensionUiResponseIfPresent(self: *TsRpcServer, id: []const u8, payload_json: []const u8) !void {
        if (self.extension_host) |host| try host.sendExtensionUiResponse(id, payload_json);
    }

    fn rejectUnsupportedNextTurn(self: *TsRpcServer, id: []const u8, deliver_as: ?[]const u8) !bool {
        if (deliver_as) |mode| {
            if (std.mem.eql(u8, mode, "nextTurn")) {
                try self.sendExtensionUiResponseIfPresent(id, "{\"error\":\"deliverAs nextTurn is not yet supported\"}");
                return true;
            }
        }
        return false;
    }

    fn extensionPayloadText(payload: std.json.ObjectMap, key: []const u8) []const u8 {
        const value = payload.get(key) orelse return "";
        return if (value == .string) value.string else "";
    }

    fn deliverExtensionCustomTextWhileBusy(
        session: *session_mod.AgentSession,
        text: []const u8,
        deliver_as: ?[]const u8,
    ) void {
        if (deliver_as) |mode| {
            if (std.mem.eql(u8, mode, "steer")) {
                session.steer(text, &.{}) catch {};
            } else if (std.mem.eql(u8, mode, "followUp")) {
                session.followUp(text, &.{}) catch {};
            }
        }
    }

    fn deliverExtensionUserTextWhileBusy(
        session: *session_mod.AgentSession,
        text: []const u8,
        deliver_as: ?[]const u8,
    ) void {
        const is_steer = if (deliver_as) |mode| std.mem.eql(u8, mode, "steer") else false;
        if (is_steer) {
            session.steer(text, &.{}) catch {};
        } else {
            session.followUp(text, &.{}) catch {};
        }
    }

    fn startExtensionPromptTask(self: *TsRpcServer, session: *session_mod.AgentSession, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);
        const images = try self.allocator.alloc(ai.ImageContent, 0);
        const task = try PromptTask.create(self.allocator, self.io, self, session, null, text_copy, images);
        try self.prompt_tasks.append(self.allocator, task);
        task.spawn() catch {
            _ = self.prompt_tasks.pop();
            task.joinAndDestroy();
        };
    }

    fn writeEvent(self: *TsRpcServer, event: agent.AgentEvent) !void {
        if (self.suppress_events) return;
        const value = try json_event_wire.agentEventToJsonValue(self.allocator, event);
        defer common.deinitJsonValue(self.allocator, value);
        const line = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(line);

        // Forward agent events through the runtime facade using best-effort delivery.
        if (self.extension_host) |host| {
            switch (event.event_type) {
                .turn_start => {
                    self.emitExtensionTurnStartFrame(host);
                    self.turn_index += 1;
                },
                .turn_end => self.emitExtensionTurnEndFrame(host, line),
                else => host.sendExtensionEventFrame(line),
            }
            // Emit the typed tool_call / tool_result companion frames that the
            // extension event API exposes separately from the execution lifecycle events.
            switch (event.event_type) {
                .tool_execution_start => self.emitExtensionToolCallEvent(host, event),
                .tool_execution_end => self.emitExtensionToolResultEvent(host, event),
                else => {},
            }
        }

        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.print("{s}\n", .{line});
        try self.stdout_writer.flush();
    }

    /// Emit a `tool_call` extension event frame when a tool starts executing.
    /// Mirrors the TS `ToolCallEvent` wire format: type, toolCallId, toolName, input.
    fn emitExtensionToolCallEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, event: agent.AgentEvent) void {
        const tool_call_id = event.tool_call_id orelse return;
        const tool_name = event.tool_name orelse return;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"tool_call\",\"toolCallId\":") catch return;
        writeJsonString(self.allocator, &out.writer, tool_call_id) catch return;
        out.writer.writeAll(",\"toolName\":") catch return;
        writeJsonString(self.allocator, &out.writer, tool_name) catch return;
        out.writer.writeAll(",\"input\":") catch return;
        if (event.args) |args| {
            const args_json = std.json.Stringify.valueAlloc(self.allocator, args, .{}) catch return;
            defer self.allocator.free(args_json);
            out.writer.writeAll(args_json) catch return;
        } else {
            out.writer.writeAll("{}") catch return;
        }
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `tool_result` extension event frame when a tool finishes executing.
    /// Mirrors the TS `ToolResultEvent` wire format: type, toolCallId, toolName,
    /// input (original call args from event.args), content, isError.
    /// thinking and tool_call content blocks are skipped (not emitted as empty text).
    fn emitExtensionToolResultEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, event: agent.AgentEvent) void {
        const tool_call_id = event.tool_call_id orelse return;
        const tool_name = event.tool_name orelse return;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"tool_result\",\"toolCallId\":") catch return;
        writeJsonString(self.allocator, &out.writer, tool_call_id) catch return;
        out.writer.writeAll(",\"toolName\":") catch return;
        writeJsonString(self.allocator, &out.writer, tool_name) catch return;
        // Retain original tool-call args as input (TS ToolResultEvent.input = call arguments).
        out.writer.writeAll(",\"input\":") catch return;
        if (event.args) |args| {
            const args_json = std.json.Stringify.valueAlloc(self.allocator, args, .{}) catch return;
            defer self.allocator.free(args_json);
            out.writer.writeAll(args_json) catch return;
        } else {
            out.writer.writeAll("{}") catch return;
        }
        out.writer.writeAll(",\"content\":[") catch return;
        if (event.result) |result| {
            var first = true;
            for (result.content) |block| {
                switch (block) {
                    .text => |text| {
                        if (!first) out.writer.writeAll(",") catch return;
                        first = false;
                        out.writer.writeAll("{\"type\":\"text\",\"text\":") catch return;
                        writeJsonString(self.allocator, &out.writer, text.text) catch return;
                        out.writer.writeAll("}") catch return;
                    },
                    .image => |image| {
                        if (!first) out.writer.writeAll(",") catch return;
                        first = false;
                        out.writer.writeAll("{\"type\":\"image\",\"mimeType\":") catch return;
                        writeJsonString(self.allocator, &out.writer, image.mime_type) catch return;
                        out.writer.writeAll(",\"data\":") catch return;
                        writeJsonString(self.allocator, &out.writer, image.data) catch return;
                        out.writer.writeAll("}") catch return;
                    },
                    // thinking and tool_call blocks are intentionally skipped —
                    // they should not appear in the tool_result.content wire frame.
                    else => {},
                }
            }
        }
        out.writer.writeAll("],\"isError\":") catch return;
        out.writer.writeAll(if (event.is_error orelse false) "true" else "false") catch return;
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `model_select` extension event frame when the active model changes.
    /// Mirrors the TS `ModelSelectEvent` wire format.
    fn emitExtensionModelSelectEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, model: ai.Model, prev_model: ai.Model, source: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"model_select\",\"model\":") catch return;
        ts_rpc_state_json.writeModelJson(self.allocator, &out.writer, model) catch return;
        out.writer.writeAll(",\"previousModel\":") catch return;
        ts_rpc_state_json.writeModelJson(self.allocator, &out.writer, prev_model) catch return;
        out.writer.writeAll(",\"source\":") catch return;
        writeJsonString(self.allocator, &out.writer, source) catch return;
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `thinking_level_select` extension event frame when the thinking level changes.
    /// Mirrors the TS `ThinkingLevelSelectEvent` wire format.
    fn emitExtensionThinkingLevelSelectEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, level: agent.ThinkingLevel, prev_level: agent.ThinkingLevel, source: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"thinking_level_select\",\"level\":") catch return;
        writeJsonString(self.allocator, &out.writer, ts_rpc_state_json.thinkingLevelName(level)) catch return;
        out.writer.writeAll(",\"previousLevel\":") catch return;
        writeJsonString(self.allocator, &out.writer, ts_rpc_state_json.thinkingLevelName(prev_level)) catch return;
        out.writer.writeAll(",\"source\":") catch return;
        writeJsonString(self.allocator, &out.writer, source) catch return;
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit an `input` extension event frame when user input is received.
    /// Mirrors the TS `InputEvent` wire format: type, text, source.
    fn emitExtensionInputEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, text: []const u8, source: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"input\",\"text\":") catch return;
        writeJsonString(self.allocator, &out.writer, text) catch return;
        out.writer.writeAll(",\"source\":") catch return;
        writeJsonString(self.allocator, &out.writer, source) catch return;
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `turn_start` extension event frame with the current turnIndex and timestamp.
    /// Mirrors the TS TurnStartEvent wire format: type, turnIndex, timestamp.
    fn emitExtensionTurnStartFrame(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter) void {
        const ts_ms = @divFloor(std.Io.Clock.now(.awake, self.io).nanoseconds, std.time.ns_per_ms);
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.print("{{\"type\":\"turn_start\",\"turnIndex\":{d},\"timestamp\":{d}}}", .{
            self.turn_index,
            ts_ms,
        }) catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit a `turn_end` extension event frame with turnIndex injected after the
    /// type field. The base_frame (from json_event_wire) carries message and
    /// toolResults; this function prepends the parity fields before forwarding to the host.
    /// Note: TS TurnEndEvent does not declare a timestamp field; timestamp is only on turn_start.
    fn emitExtensionTurnEndFrame(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, base_frame: []const u8) void {
        const base_prefix = "{\"type\":\"turn_end\"";
        if (!std.mem.startsWith(u8, base_frame, base_prefix)) {
            host.sendExtensionEventFrame(base_frame);
            return;
        }
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.print("{s},\"turnIndex\":{d}", .{
            base_prefix,
            if (self.turn_index == 0) 0 else self.turn_index - 1,
        }) catch return;
        out.writer.writeAll(base_frame[base_prefix.len..]) catch return;
        host.sendExtensionEventFrame(out.written());
    }

    // -------------------------------------------------------------------------
    // Session lifecycle extension event helpers
    // -------------------------------------------------------------------------

    /// One field in a session-lifecycle extension event payload sent through
    /// host.sendExtensionEventFrame. Used by writeTsRpcEvent so each
    /// emitSession*Event helper stays a small declarative wrapper instead of
    /// repeating the `Allocating writer / writeAll braces / catch return`
    /// scaffolding for every event.
    const TsRpcEventField = union(enum) {
        /// Always emit `"key": "value"`.
        string: struct { key: []const u8, value: []const u8 },
        /// Emit `"key": "value"` when present, `"key": null` when absent.
        nullable_string: struct { key: []const u8, value: ?[]const u8 },
        /// Emit `"key": "value"` when present; omit the property entirely when absent.
        optional_string: struct { key: []const u8, value: ?[]const u8 },
        /// Always emit `"key": true|false`.
        boolean_literal: struct { key: []const u8, value: bool },
    };

    fn writeTsRpcEvent(
        self: *TsRpcServer,
        host: extension_runtime.RuntimeAdapter,
        event_type: []const u8,
        fields: []const TsRpcEventField,
    ) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":") catch return;
        writeJsonString(self.allocator, &out.writer, event_type) catch return;
        for (fields) |field| switch (field) {
            .string => |s| {
                out.writer.writeAll(",") catch return;
                writeJsonString(self.allocator, &out.writer, s.key) catch return;
                out.writer.writeAll(":") catch return;
                writeJsonString(self.allocator, &out.writer, s.value) catch return;
            },
            .nullable_string => |o| {
                out.writer.writeAll(",") catch return;
                writeJsonString(self.allocator, &out.writer, o.key) catch return;
                out.writer.writeAll(":") catch return;
                if (o.value) |v| {
                    writeJsonString(self.allocator, &out.writer, v) catch return;
                } else {
                    out.writer.writeAll("null") catch return;
                }
            },
            .optional_string => |o| if (o.value) |v| {
                out.writer.writeAll(",") catch return;
                writeJsonString(self.allocator, &out.writer, o.key) catch return;
                out.writer.writeAll(":") catch return;
                writeJsonString(self.allocator, &out.writer, v) catch return;
            },
            .boolean_literal => |b| {
                out.writer.writeAll(",") catch return;
                writeJsonString(self.allocator, &out.writer, b.key) catch return;
                out.writer.writeAll(":") catch return;
                out.writer.writeAll(if (b.value) "true" else "false") catch return;
            },
        };
        out.writer.writeAll("}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit session_before_switch to extension host.
    /// reason: "new" | "resume"
    fn emitSessionBeforeSwitchEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, reason: []const u8, target_file: ?[]const u8) void {
        self.writeTsRpcEvent(host, "session_before_switch", &.{
            .{ .string = .{ .key = "reason", .value = reason } },
            .{ .optional_string = .{ .key = "targetSessionFile", .value = target_file } },
        });
    }

    /// Emit session_start to extension host after the new session is active.
    /// reason: "startup" | "reload" | "new" | "resume" | "fork"
    fn emitSessionStartEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, reason: []const u8, previous_file: ?[]const u8, target_file: ?[]const u8) void {
        self.writeTsRpcEvent(host, "session_start", &.{
            .{ .string = .{ .key = "reason", .value = reason } },
            .{ .optional_string = .{ .key = "previousSessionFile", .value = previous_file } },
            .{ .optional_string = .{ .key = "targetSessionFile", .value = target_file } },
        });
    }

    /// Emit session_shutdown to extension host.
    /// reason: "quit" | "reload" | "new" | "resume" | "fork"
    fn emitSessionShutdownEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, reason: []const u8, previous_file: ?[]const u8, target_file: ?[]const u8) void {
        self.writeTsRpcEvent(host, "session_shutdown", &.{
            .{ .string = .{ .key = "reason", .value = reason } },
            .{ .optional_string = .{ .key = "previousSessionFile", .value = previous_file } },
            .{ .optional_string = .{ .key = "targetSessionFile", .value = target_file } },
        });
    }

    /// Emit session_before_fork to extension host.
    fn emitSessionBeforeForkEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, entry_id: []const u8, position: []const u8) void {
        self.writeTsRpcEvent(host, "session_before_fork", &.{
            .{ .string = .{ .key = "entryId", .value = entry_id } },
            .{ .string = .{ .key = "position", .value = position } },
        });
    }

    /// Emit session_before_compact to extension host.
    fn emitSessionBeforeCompactEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, custom_instructions: ?[]const u8) void {
        self.writeTsRpcEvent(host, "session_before_compact", &.{
            .{ .optional_string = .{ .key = "customInstructions", .value = custom_instructions } },
        });
    }

    /// Emit session_compact to extension host after compaction completes.
    fn emitSessionCompactEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter) void {
        _ = self;
        host.sendExtensionEventFrame("{\"type\":\"session_compact\",\"fromExtension\":false}");
    }

    /// Emit session_before_tree to extension host before navigating the session tree.
    /// `preparation` is a nested object so this stays explicit instead of using
    /// writeTsRpcEvent — TsRpcEventField has no nested-object variant.
    fn emitSessionBeforeTreeEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, target_id: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        out.writer.writeAll("{\"type\":\"session_before_tree\",\"preparation\":{\"targetId\":") catch return;
        writeJsonString(self.allocator, &out.writer, target_id) catch return;
        out.writer.writeAll("}}") catch return;
        host.sendExtensionEventFrame(out.written());
    }

    /// Emit session_tree to extension host after tree navigation completes.
    fn emitSessionTreeEvent(self: *TsRpcServer, host: extension_runtime.RuntimeAdapter, new_leaf_id: ?[]const u8, old_leaf_id: ?[]const u8) void {
        self.writeTsRpcEvent(host, "session_tree", &.{
            .{ .nullable_string = .{ .key = "newLeafId", .value = new_leaf_id } },
            .{ .nullable_string = .{ .key = "oldLeafId", .value = old_leaf_id } },
            .{ .boolean_literal = .{ .key = "fromExtension", .value = false } },
        });
    }

    fn writeQueueUpdate(self: *TsRpcServer) !void {
        const session = self.session orelse return;
        const steering = try session.agent.snapshotSteeringMessages(self.allocator);
        defer {
            agent.deinitMessageSlice(self.allocator, steering);
            self.allocator.free(steering);
        }
        const follow_up = try session.agent.snapshotFollowUpMessages(self.allocator);
        defer {
            agent.deinitMessageSlice(self.allocator, follow_up);
            self.allocator.free(follow_up);
        }

        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"queue_update\",\"steering\":");
        try ts_rpc_state_json.writeQueuedMessageTexts(self.allocator, self.stdout_writer, steering);
        try self.stdout_writer.writeAll(",\"followUp\":");
        try ts_rpc_state_json.writeQueuedMessageTexts(self.allocator, self.stdout_writer, follow_up);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeRetryLifecycleEvent(self: *TsRpcServer, event: session_mod.RetryLifecycleEvent) !void {
        if (self.suppress_events) return;
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        switch (event) {
            .start => |start_event| {
                try self.stdout_writer.writeAll("{\"type\":\"auto_retry_start\",\"attempt\":");
                try self.stdout_writer.print("{d}", .{start_event.attempt});
                try self.stdout_writer.writeAll(",\"maxAttempts\":");
                try self.stdout_writer.print("{d}", .{start_event.max_attempts});
                try self.stdout_writer.writeAll(",\"delayMs\":");
                try self.stdout_writer.print("{d}", .{start_event.delay_ms});
                try self.stdout_writer.writeAll(",\"errorMessage\":");
                try writeJsonString(self.allocator, self.stdout_writer, start_event.error_message);
                try self.stdout_writer.writeAll("}\n");
            },
            .end => |end| {
                try self.stdout_writer.writeAll("{\"type\":\"auto_retry_end\",\"success\":");
                try self.stdout_writer.writeAll(if (end.success) "true" else "false");
                try self.stdout_writer.writeAll(",\"attempt\":");
                try self.stdout_writer.print("{d}", .{end.attempt});
                if (end.final_error) |final_error| {
                    try self.stdout_writer.writeAll(",\"finalError\":");
                    try writeJsonString(self.allocator, self.stdout_writer, final_error);
                }
                try self.stdout_writer.writeAll("}\n");
            },
        }
        try self.stdout_writer.flush();
    }

    fn writeCompactionStartEvent(self: *TsRpcServer, reason: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"compaction_start\",\"reason\":");
        try writeJsonString(self.allocator, self.stdout_writer, reason);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeCompactionEndEvent(
        self: *TsRpcServer,
        reason: []const u8,
        result_json: ?[]const u8,
        aborted: bool,
        will_retry: bool,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"compaction_end\",\"reason\":");
        try writeJsonString(self.allocator, self.stdout_writer, reason);
        if (result_json) |result| {
            try self.stdout_writer.writeAll(",\"result\":");
            try self.stdout_writer.writeAll(result);
        }
        try self.stdout_writer.writeAll(",\"aborted\":");
        try self.stdout_writer.writeAll(if (aborted) "true" else "false");
        try self.stdout_writer.writeAll(",\"willRetry\":");
        try self.stdout_writer.writeAll(if (will_retry) "true" else "false");
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeSessionInfoChangedEvent(self: *TsRpcServer, name: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"session_info_changed\",\"name\":");
        try writeJsonString(self.allocator, self.stdout_writer, name);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn enqueueDeferredSuccess(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        priority: DeferredResponsePriority,
    ) !void {
        self.deferred_responses_mutex.lockUncancelable(self.io);
        defer self.deferred_responses_mutex.unlock(self.io);

        try self.deferred_responses.append(self.allocator, .{
            .id = if (id) |id_string| try self.allocator.dupe(u8, id_string) else null,
            .command = try self.allocator.dupe(u8, command),
            .priority = priority,
            .sequence = self.next_deferred_response_sequence,
        });
        self.next_deferred_response_sequence += 1;
    }

    fn enqueueDeferredRawData(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        data_json: []const u8,
        priority: DeferredResponsePriority,
        sequence: usize,
    ) !void {
        self.deferred_responses_mutex.lockUncancelable(self.io);
        defer self.deferred_responses_mutex.unlock(self.io);

        try self.deferred_responses.append(self.allocator, .{
            .id = if (id) |id_string| try self.allocator.dupe(u8, id_string) else null,
            .command = try self.allocator.dupe(u8, command),
            .data_json = try self.allocator.dupe(u8, data_json),
            .priority = priority,
            .sequence = sequence,
        });
    }

    fn hasPromptStartDeferredResponses(self: *TsRpcServer) bool {
        self.deferred_responses_mutex.lockUncancelable(self.io);
        defer self.deferred_responses_mutex.unlock(self.io);
        for (self.deferred_responses.items) |response| {
            if (response.priority != .bash_completion) return true;
        }
        return false;
    }

    pub fn flushDeferredResponses(self: *TsRpcServer) !void {
        self.deferred_responses_mutex.lockUncancelable(self.io);
        defer self.deferred_responses_mutex.unlock(self.io);

        if (self.deferred_responses.items.len == 0) return;
        var should_abort_after_flush = false;
        std.mem.sort(DeferredResponse, self.deferred_responses.items, {}, lessThanDeferredResponse);
        const hold_bash_completions = self.hasUnfinishedBashTask();
        var keep_count: usize = 0;
        for (self.deferred_responses.items, 0..) |*response, index| {
            if (response.priority == .bash_completion and hold_bash_completions) {
                if (keep_count != index) {
                    self.deferred_responses.items[keep_count] = response.*;
                }
                keep_count += 1;
                continue;
            }
            if (response.data_json) |data_json| {
                try self.writeSuccessResponseRawData(response.id, response.command, data_json);
            } else {
                try self.writeSuccessResponseNoData(response.id, response.command);
            }
            if (std.mem.eql(u8, response.command, "abort")) {
                should_abort_after_flush = true;
            }
            response.deinit(self.allocator);
        }
        self.deferred_responses.shrinkRetainingCapacity(keep_count);
        if (should_abort_after_flush) {
            self.abortActivePromptWork();
        }
    }
};

const SlashCommandInvocation = struct {
    name: []const u8,
    argument: []const u8,
};

const ExtensionCommandsJsonContext = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    wrote_command: bool = false,
};

fn writeExtensionCommandsJsonCallback(context: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const json_context: *ExtensionCommandsJsonContext = @ptrCast(@alignCast(context.?));
    const commands = try registry.resolveCommands(json_context.allocator);
    defer {
        for (commands) |command| json_context.allocator.free(command.invocation_name);
        json_context.allocator.free(commands);
    }

    for (commands) |command| {
        if (json_context.wrote_command) try json_context.writer.writeAll(",");
        json_context.wrote_command = true;
        try json_context.writer.writeAll("{\"name\":");
        try writeJsonString(json_context.allocator, json_context.writer, command.invocation_name);
        if (command.description) |description| {
            try json_context.writer.writeAll(",\"description\":");
            try writeJsonString(json_context.allocator, json_context.writer, description);
        }
        try json_context.writer.writeAll(",\"source\":\"extension\",\"sourceInfo\":");
        try writeExtensionCommandSourceInfo(json_context.allocator, json_context.writer, command.extension_path);
        try json_context.writer.writeAll("}");
    }
}

fn writeExtensionCommandSourceInfo(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    extension_path: []const u8,
) !void {
    try writer.writeAll("{\"path\":");
    try writeJsonString(allocator, writer, extension_path);
    try writer.writeAll(",\"source\":\"local\",\"scope\":\"temporary\",\"origin\":\"top_level\"}");
}

fn parseSlashCommandInvocation(message: []const u8) ?SlashCommandInvocation {
    if (message.len == 0 or message[0] != '/') return null;
    const trimmed = std.mem.trim(u8, message[1..], " \t\r\n");
    if (trimmed.len == 0) return null;
    const name_end = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    return .{
        .name = trimmed[0..name_end],
        .argument = std.mem.trim(u8, trimmed[name_end..], " \t\r\n"),
    };
}

fn extensionCommandEventValue(allocator: std.mem.Allocator, name: []const u8, argument: []const u8) !std.json.Value {
    var event = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    errdefer common.deinitJsonValue(allocator, event);
    try event.object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "command") });
    try event.object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, name) });
    if (argument.len > 0) {
        try event.object.put(allocator, try allocator.dupe(u8, "argument"), .{ .string = try allocator.dupe(u8, argument) });
    }
    try event.object.put(allocator, try allocator.dupe(u8, "source"), .{ .string = try allocator.dupe(u8, "rpc") });
    return event;
}

fn extensionCommandResultDataJson(allocator: std.mem.Allocator, name: []const u8, result: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"extension_command\",\"name\":");
    try writeJsonString(allocator, &out.writer, name);
    try out.writer.writeAll(",\"result\":");
    try std.json.Stringify.value(result, .{}, &out.writer);
    try out.writer.writeAll("}");
    return try allocator.dupe(u8, out.written());
}

fn deferredFlushMain(server: *TsRpcServer) void {
    while (!server.deferred_flush_stop.load(.seq_cst)) {
        std.Io.sleep(server.io, .fromMilliseconds(DEFERRED_RESPONSE_FLUSH_INTERVAL_MS), .awake) catch {};
        if (server.deferred_flush_stop.load(.seq_cst)) break;
        if (server.shouldHoldDeferredFlush()) continue;
        server.flushDeferredResponses() catch {};
    }
}

fn lessThanDeferredResponse(_: void, lhs: DeferredResponse, rhs: DeferredResponse) bool {
    if (@intFromEnum(lhs.priority) != @intFromEnum(rhs.priority)) {
        return @intFromEnum(lhs.priority) < @intFromEnum(rhs.priority);
    }
    return lhs.sequence < rhs.sequence;
}

pub fn runTsRpcMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    options: RunTsRpcModeOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var server = TsRpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    try server.start();
    defer server.finish() catch {};
    if (options.extension_host) |host_options| {
        try server.startExtensionHost(host_options);
    }
    if (options.extension_ui_parity_scenario) {
        try server.emitExtensionUIParityScenario();
    }

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);

    const service_extension_host = options.extension_host != null;
    while (true) {
        if (service_extension_host) {
            try server.serviceExtensionHostIdleTick(0);
            if (stdin_reader.interface.bufferedLen() == 0 and !try pollTsRpcStdin(EXTENSION_HOST_EVENT_LOOP_TICK_MS)) {
                try server.serviceExtensionHostIdleTick(EXTENSION_HOST_EVENT_LOOP_TICK_MS);
                continue;
            }
        }

        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        server.setDeferredFlushInputBacklog(stdin_reader.interface.bufferedLen() > 0);
        if (byte == '\n') {
            try server.handleLine(line_buffer.items);
            line_buffer.clearRetainingCapacity();
            server.setDeferredFlushInputBacklog(stdin_reader.interface.bufferedLen() > 0);
            if (service_extension_host) {
                try server.serviceExtensionHostIdleTick(0);
            } else {
                try server.drainExtensionHostUiRequests(50);
            }
            continue;
        }
        try line_buffer.append(allocator, byte);
    }

    server.setDeferredFlushInputBacklog(false);
    if (line_buffer.items.len > 0) {
        try server.handleLine(line_buffer.items);
        if (service_extension_host) {
            try server.serviceExtensionHostIdleTick(0);
        } else {
            try server.drainExtensionHostUiRequests(50);
        }
    }

    if (server.hasInFlightPrompt()) {
        server.suppress_events = true;
        server.abortActivePromptWork();
    }
    try server.flushDeferredResponses();
    try server.finish();
    return 0;
}

fn pollTsRpcStdin(timeout_ms: i32) !bool {
    if (builtin.os.tag == .windows) {
        const stdin_handle = std.Io.File.stdin().handle;
        const timeout: std.os.windows.LARGE_INTEGER = -@as(i64, @intCast(timeout_ms)) * 10000;
        const status = std.os.windows.ntdll.NtWaitForSingleObject(stdin_handle, .FALSE, &timeout);
        return status == .SUCCESS;
    } else {
        var fds = [_]std.posix.pollfd{
            .{
                .fd = 0,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        return (try std.posix.poll(fds[0..], timeout_ms)) > 0;
    }
}

fn handleTsRpcAgentEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const server: *TsRpcServer = @ptrCast(@alignCast(context.?));
    try server.writeEvent(event);
    if (event.event_type == .message_end) {
        if (event.message) |message| {
            switch (message) {
                .assistant => |assistant| {
                    if (assistant.stop_reason != .error_reason) {
                        if (server.session) |session| {
                            if (session.retry_attempt > 0) {
                                try server.writeRetryLifecycleEvent(.{ .end = .{
                                    .success = true,
                                    .attempt = session.retry_attempt,
                                } });
                                session.retry_attempt = 0;
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }
}

fn handleTsRpcRetryLifecycleEvent(context: ?*anyopaque, event: session_mod.RetryLifecycleEvent) !void {
    const server: *TsRpcServer = @ptrCast(@alignCast(context.?));
    try server.writeRetryLifecycleEvent(event);
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingRequiredField;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn requiredStringArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = object.get(key) orelse return error.MissingRequiredField;
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidFieldType,
    };
    var result = try allocator.alloc([]const u8, array.items.len);
    errdefer allocator.free(result);
    for (array.items, 0..) |item, index| {
        result[index] = switch (item) {
            .string => |string| string,
            else => return error.InvalidFieldType,
        };
    }
    return result;
}

fn optionalStringArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]const []const u8 {
    if (object.get(key) == null) return null;
    return try requiredStringArray(allocator, object, key);
}

fn optionalU64(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
}

fn parseRequiredBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.MissingRequiredField;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidFieldType,
    };
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn modelsEqual(lhs: ai.Model, rhs: ai.Model) bool {
    return std.mem.eql(u8, lhs.provider, rhs.provider) and
        std.mem.eql(u8, lhs.id, rhs.id) and
        std.mem.eql(u8, lhs.api, rhs.api);
}

fn clampAgentThinkingLevel(model: ai.Model, requested: agent.ThinkingLevel) agent.ThinkingLevel {
    return switch (ai.model_registry.clampThinkingLevel(model, agentThinkingLevelToModel(requested))) {
        .off => .off,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

fn agentThinkingLevelToModel(level: agent.ThinkingLevel) ai.ModelThinkingLevel {
    return switch (level) {
        .off => .off,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

fn parsePromptStreamingBehavior(object: std.json.ObjectMap) !?PromptStreamingBehavior {
    const value = object.get("streamingBehavior") orelse return null;
    const behavior = switch (value) {
        .string => |string| string,
        else => return error.InvalidFieldType,
    };
    if (std.mem.eql(u8, behavior, "steer")) return .steer;
    if (std.mem.eql(u8, behavior, "followUp")) return .follow_up;
    return error.InvalidFieldType;
}

fn textBlocksConcat(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (blocks) |block| {
        switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            else => {},
        }
    }
    const text = std.mem.trim(u8, out.items, &std.ascii.whitespace);
    const owned = try allocator.dupe(u8, text);
    out.deinit(allocator);
    return owned;
}

fn lastAssistantTextAlloc(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) !?[]u8 {
    const messages = session.agent.getMessages();
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .assistant => |assistant_message| {
                if (assistant_message.stop_reason == .aborted and assistant_message.content.len == 0) continue;
                const text = try textBlocksConcat(allocator, assistant_message.content);
                if (text.len == 0) {
                    allocator.free(text);
                    return null;
                }
                return text;
            },
            else => {},
        }
    }
    return null;
}

const TestingTsRpcServer = TsRpcServer;
const TestingExtensionUIDialogMethod = ExtensionUIDialogMethod;
const TestingExtensionUIResolution = ExtensionUIResolution;

pub const testing = struct {
    pub const TsRpcServer = TestingTsRpcServer;
    pub const ExtensionUIDialogMethod = TestingExtensionUIDialogMethod;
    pub const ExtensionUIResolution = TestingExtensionUIResolution;
    pub const extension_host_event_loop_tick_ms = EXTENSION_HOST_EVENT_LOOP_TICK_MS;
};

test {
    _ = @import("ts_rpc_mode/tests.zig");
}
