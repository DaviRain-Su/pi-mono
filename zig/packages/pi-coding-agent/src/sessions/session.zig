const std = @import("std");
const ai = @import("ai");
const string_utils = ai.shared.string_utils;
const agent = @import("agent");
const extension_runtime = @import("../extensions/extension_runtime.zig");
const runtime_hooks = @import("../runtime/hooks.zig");
const extension_protocol = @import("../extensions/extension_protocol.zig");
const session_manager = @import("session_manager.zig");
const session_compaction = @import("session_compaction.zig");
const session_retry = @import("session_retry.zig");
const session_json_helpers = @import("session_json_helpers.zig");
const tools_common = @import("../tools/common.zig");
const stream_adapter = @import("../stream_adapter.zig");

pub const CompactionSettings = session_compaction.CompactionSettings;
pub const CompactionReason = session_compaction.CompactionReason;
pub const CompactionLifecycleEvent = session_compaction.CompactionLifecycleEvent;
pub const CompactionLifecycleCallback = session_compaction.CompactionLifecycleCallback;
pub const CompactionResult = session_compaction.CompactionResult;
pub const RetrySettings = session_retry.RetrySettings;
pub const RetryLifecycleEvent = session_retry.RetryLifecycleEvent;
pub const RetryLifecycleCallback = session_retry.RetryLifecycleCallback;

const makeObject = session_json_helpers.makeObject;
const putString = session_json_helpers.putString;
const putBool = session_json_helpers.putBool;
const putInt = session_json_helpers.putInt;
const putValue = session_json_helpers.putValue;
const putMessageSummary = session_json_helpers.putMessageSummary;
const putMessagesSummary = session_json_helpers.putMessagesSummary;
const toolResultMessageEntry = session_json_helpers.toolResultMessageEntry;
const makeToolResultPayload = session_json_helpers.makeToolResultPayload;
const contentBlocksToJsonArray = session_json_helpers.contentBlocksToJsonArray;

const findLastAssistantMessage = session_compaction.findLastAssistantMessage;
const isContextOverflow = session_compaction.isContextOverflow;
const shouldAutoCompact = session_compaction.shouldAutoCompact;
const estimateContextTokens = session_compaction.estimateContextTokens;
const prepareCompaction = session_compaction.prepareCompaction;
const prepareManualCompaction = session_compaction.prepareManualCompaction;
const buildCompactionSummary = session_compaction.buildCompactionSummary;

const isRetryableError = session_retry.isRetryableError;
const exponentialBackoffMs = session_retry.exponentialBackoffMs;
const sleepMilliseconds = session_retry.sleepMilliseconds;

pub const QueuedInput = struct {
    text: []u8,
    images: []ai.ImageContent,

    pub fn deinit(self: *QueuedInput, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.images) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(self.images);
        self.* = undefined;
    }
};

pub const ClearedQueue = struct {
    steering: []QueuedInput,
    follow_up: []QueuedInput,

    pub fn count(self: ClearedQueue) usize {
        return self.steering.len + self.follow_up.len;
    }

    pub fn deinit(self: *ClearedQueue, allocator: std.mem.Allocator) void {
        for (self.steering) |*item| item.deinit(allocator);
        allocator.free(self.steering);
        for (self.follow_up) |*item| item.deinit(allocator);
        allocator.free(self.follow_up);
        self.* = undefined;
    }
};

pub const AgentSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    system_prompt: []const u8,
    agent: agent.Agent,
    session_manager: *session_manager.SessionManager,
    subscriber: agent.AgentSubscriber,
    subscribed: bool,
    extension_event_subscriber: agent.AgentSubscriber,
    extension_event_subscribed: bool,
    compaction_settings: CompactionSettings,
    retry_settings: RetrySettings,
    retry_attempt: u32,
    retry_lifecycle_callback: ?RetryLifecycleCallback,
    compaction_lifecycle_callback: ?CompactionLifecycleCallback,
    retry_abort_requested: std.atomic.Value(bool),
    retry_delay_active: std.atomic.Value(bool),
    overflow_recovery_attempted: bool,
    compaction_active: std.atomic.Value(bool),
    extension_hook_context: ?*ExtensionHookContext,

    pub const CreateOptions = struct {
        cwd: []const u8,
        system_prompt: []const u8 = "",
        model: ?ai.Model = null,
        api_key: ?[]const u8 = null,
        thinking_level: agent.ThinkingLevel = .off,
        tools: []const agent.AgentTool = &.{},
        session_dir: ?[]const u8 = null,
        compaction: CompactionSettings = .{},
        retry: RetrySettings = .{},
        extension_hosts: []const extension_runtime.RuntimeAdapter = &.{},
        extension_hook_timeout_ms: u64 = 1000,
    };

    pub const OpenOptions = struct {
        session_file: []const u8,
        cwd_override: ?[]const u8 = null,
        system_prompt: []const u8 = "",
        model: ?ai.Model = null,
        api_key: ?[]const u8 = null,
        thinking_level: agent.ThinkingLevel = .off,
        tools: []const agent.AgentTool = &.{},
        compaction: CompactionSettings = .{},
        retry: RetrySettings = .{},
        extension_hosts: []const extension_runtime.RuntimeAdapter = &.{},
        extension_hook_timeout_ms: u64 = 1000,
    };

    pub const ManagedOptions = struct {
        cwd: []const u8,
        system_prompt: []const u8 = "",
        model: ?ai.Model = null,
        api_key: ?[]const u8 = null,
        thinking_level: agent.ThinkingLevel = .off,
        tools: []const agent.AgentTool = &.{},
        compaction: CompactionSettings = .{},
        retry: RetrySettings = .{},
        extension_hosts: []const extension_runtime.RuntimeAdapter = &.{},
        extension_hook_timeout_ms: u64 = 1000,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: CreateOptions,
    ) !AgentSession {
        const manager = try allocator.create(session_manager.SessionManager);
        errdefer allocator.destroy(manager);
        manager.* = if (options.session_dir) |session_dir|
            try session_manager.SessionManager.create(allocator, io, options.cwd, session_dir)
        else
            try session_manager.SessionManager.inMemory(allocator, io, options.cwd);
        errdefer manager.deinit();

        var instance = try initWithManager(
            allocator,
            io,
            options.cwd,
            options.system_prompt,
            options.model,
            options.api_key,
            options.thinking_level,
            options.tools,
            options.compaction,
            options.retry,
            options.extension_hosts,
            options.extension_hook_timeout_ms,
            manager,
        );
        if (options.model) |model| {
            _ = try instance.session_manager.appendModelChange(model.provider, model.id);
        }
        if (options.thinking_level != .off) {
            _ = try instance.session_manager.appendThinkingLevelChange(options.thinking_level);
        }
        return instance;
    }

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: OpenOptions,
    ) !AgentSession {
        const manager = try allocator.create(session_manager.SessionManager);
        errdefer allocator.destroy(manager);
        manager.* = try session_manager.SessionManager.open(allocator, io, options.session_file, options.cwd_override);
        errdefer manager.deinit();

        const effective_cwd = options.cwd_override orelse manager.getCwd();
        return initWithManager(
            allocator,
            io,
            effective_cwd,
            options.system_prompt,
            options.model,
            options.api_key,
            options.thinking_level,
            options.tools,
            options.compaction,
            options.retry,
            options.extension_hosts,
            options.extension_hook_timeout_ms,
            manager,
        );
    }

    /// Takes ownership of `manager`. Caller must destroy the manager pointer if
    /// this function returns an error.
    pub fn createWithManager(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *session_manager.SessionManager,
        options: ManagedOptions,
    ) !AgentSession {
        return initWithManager(
            allocator,
            io,
            options.cwd,
            options.system_prompt,
            options.model,
            options.api_key,
            options.thinking_level,
            options.tools,
            options.compaction,
            options.retry,
            options.extension_hosts,
            options.extension_hook_timeout_ms,
            manager,
        );
    }

    pub fn deinit(self: *AgentSession) void {
        if (self.extension_hook_context) |ctx| {
            emitSessionShutdownHook(self.allocator, ctx, "quit") catch {};
        }
        if (self.subscribed) {
            _ = self.agent.unsubscribe(self.subscriber);
            self.subscribed = false;
        }
        if (self.extension_event_subscribed) {
            _ = self.agent.unsubscribe(self.extension_event_subscriber);
            self.extension_event_subscribed = false;
        }
        self.agent.deinit();
        if (self.extension_hook_context) |hook_context| {
            hook_context.deinit(self.allocator);
            self.allocator.destroy(hook_context);
            self.extension_hook_context = null;
        }
        self.session_manager.deinit();
        self.allocator.destroy(self.session_manager);
    }

    pub fn prompt(self: *AgentSession, input: anytype) !void {
        if (try self.runHookedPrompt(input, null)) return;
        try self.agent.prompt(input);
        try self.runPostPromptMaintenance();
        try self.flushExtensionHookDiagnostics();
    }

    pub fn promptWithAcceptedCallback(
        self: *AgentSession,
        input: anytype,
        accepted_callback: ?agent.PromptAcceptedCallback,
    ) !void {
        if (try self.runHookedPrompt(input, accepted_callback)) return;
        try self.agent.promptWithAcceptedCallback(input, accepted_callback);
        try self.runPostPromptMaintenance();
        try self.flushExtensionHookDiagnostics();
    }

    pub fn steer(self: *AgentSession, text: []const u8, images: []const ai.ImageContent) !void {
        var message = try queuedUserMessage(self.allocator, text, images);
        defer deinitQueuedUserMessage(self.allocator, &message);
        try self.agent.steer(message);
    }

    pub fn followUp(self: *AgentSession, text: []const u8, images: []const ai.ImageContent) !void {
        var message = try queuedUserMessage(self.allocator, text, images);
        defer deinitQueuedUserMessage(self.allocator, &message);
        try self.agent.followUp(message);
    }

    pub fn clearQueue(self: *AgentSession, allocator: std.mem.Allocator) !ClearedQueue {
        const steering_messages = try self.agent.takeSteeringMessages(allocator);
        defer {
            agent.deinitMessageSlice(allocator, steering_messages);
            allocator.free(steering_messages);
        }

        const follow_up_messages = try self.agent.takeFollowUpMessages(allocator);
        defer {
            agent.deinitMessageSlice(allocator, follow_up_messages);
            allocator.free(follow_up_messages);
        }

        return .{
            .steering = try queuedInputsFromMessages(allocator, steering_messages),
            .follow_up = try queuedInputsFromMessages(allocator, follow_up_messages),
        };
    }

    pub fn isStreaming(self: *const AgentSession) bool {
        return self.agent.isStreaming();
    }

    pub fn isCompacting(self: *const AgentSession) bool {
        return self.compaction_active.load(.seq_cst);
    }

    pub fn compact(self: *AgentSession, custom_instructions: ?[]const u8) !CompactionResult {
        if (self.extension_hook_context) |ctx| {
            const cancelled = emitSessionBeforeCompactHook(self.allocator, ctx, custom_instructions) catch false;
            if (cancelled) return error.SessionBeforeCompactCancelled;
        }
        return try self.runCompactionWithLifecycle(.manual, custom_instructions, false);
    }

    pub fn setRetryLifecycleCallback(self: *AgentSession, callback: RetryLifecycleCallback) void {
        self.retry_lifecycle_callback = callback;
    }

    pub fn clearRetryLifecycleCallback(self: *AgentSession) void {
        self.retry_lifecycle_callback = null;
    }

    pub fn setExtensionHosts(self: *AgentSession, extension_hosts: []const extension_runtime.RuntimeAdapter, timeout_ms: u64) !void {
        if (self.extension_event_subscribed) {
            _ = self.agent.unsubscribe(self.extension_event_subscriber);
            self.extension_event_subscribed = false;
        }
        if (self.extension_hook_context) |hook_context| {
            hook_context.deinit(self.allocator);
            self.allocator.destroy(hook_context);
            self.extension_hook_context = null;
        }
        if (extension_hosts.len == 0) {
            self.agent.transform_context = null;
            self.agent.transform_context_context = null;
            self.agent.before_tool_call = null;
            self.agent.after_tool_call = null;
            self.agent.extension_hook_context = null;
            return;
        }
        const context = try self.allocator.create(ExtensionHookContext);
        errdefer self.allocator.destroy(context);
        context.* = .{
            .allocator = self.allocator,
            .hosts = try runtime_hooks.wrapRuntimeAdapters(self.allocator, extension_hosts),
            .owns_hosts = true,
            .timeout_ms = timeout_ms,
            .diagnostics = .empty,
        };
        self.extension_hook_context = context;
        self.agent.transform_context = transformContextHook;
        self.agent.transform_context_context = context;
        self.agent.before_tool_call = beforeToolCallHook;
        self.agent.after_tool_call = afterToolCallHook;
        self.agent.extension_hook_context = context;
        self.extension_event_subscriber = .{
            .context = context,
            .callback = handleExtensionLifecycleEvent,
        };
        try self.agent.subscribe(self.extension_event_subscriber);
        self.extension_event_subscribed = true;
    }

    pub fn setCompactionLifecycleCallback(self: *AgentSession, callback: CompactionLifecycleCallback) void {
        self.compaction_lifecycle_callback = callback;
    }

    pub fn clearCompactionLifecycleCallback(self: *AgentSession) void {
        self.compaction_lifecycle_callback = null;
    }

    pub fn abortRetry(self: *AgentSession) void {
        self.retry_abort_requested.store(true, .seq_cst);
    }

    pub fn isRetrying(self: *const AgentSession) bool {
        return self.retry_delay_active.load(.seq_cst);
    }

    pub fn navigateTo(self: *AgentSession, entry_id: ?[]const u8) !void {
        if (entry_id) |id| {
            try self.session_manager.branch(id);
        } else {
            self.session_manager.resetLeaf();
        }
        try self.reloadFromSession();
    }

    pub const NavigateTreeOptions = struct {
        summarize: bool = false,
        summary_text: ?[]const u8 = null,
        label: ?[]const u8 = null,
    };

    pub const NavigateTreeResult = struct {
        editor_text: ?[]u8 = null,
        summary_entry_id: ?[]const u8 = null,

        pub fn deinit(self: *NavigateTreeResult, allocator: std.mem.Allocator) void {
            if (self.editor_text) |text| allocator.free(text);
            self.* = .{};
        }
    };

    pub fn navigateTree(
        self: *AgentSession,
        allocator: std.mem.Allocator,
        target_id: []const u8,
        options: NavigateTreeOptions,
    ) !NavigateTreeResult {
        if (self.session_manager.getLeafId()) |leaf_id| {
            if (std.mem.eql(u8, leaf_id, target_id)) return .{};
        }
        if (self.extension_hook_context) |ctx| {
            const cancelled = emitSessionBeforeTreeHook(self.allocator, ctx, target_id, self.session_manager.getLeafId()) catch false;
            if (cancelled) return error.SessionBeforeTreeCancelled;
        }

        const target_entry = self.session_manager.getEntry(target_id) orelse return error.EntryNotFound;
        const new_leaf_id = treeNavigationLeaf(target_entry);
        const editor_text = try treeNavigationEditorText(allocator, target_entry);
        errdefer if (editor_text) |text| allocator.free(text);

        var summary_entry_id: ?[]const u8 = null;
        if (options.summarize) {
            const summary = options.summary_text orelse "Branch summary";
            summary_entry_id = try self.session_manager.branchWithSummary(new_leaf_id, summary, null, false);
            if (options.label) |label| {
                _ = try self.session_manager.appendLabelChange(summary_entry_id.?, label);
            }
        } else if (new_leaf_id) |id| {
            try self.session_manager.branch(id);
            if (options.label) |label| {
                _ = try self.session_manager.appendLabelChange(target_id, label);
            }
        } else {
            self.session_manager.resetLeaf();
            if (options.label) |label| {
                _ = try self.session_manager.appendLabelChange(target_id, label);
            }
        }

        try self.reloadFromSession();
        const final_leaf_id = self.session_manager.getLeafId();
        if (self.extension_hook_context) |ctx| {
            emitSessionTreeHook(self.allocator, ctx, final_leaf_id, target_id, false) catch {};
        }
        return .{
            .editor_text = editor_text,
            .summary_entry_id = summary_entry_id,
        };
    }

    pub fn setThinkingLevel(self: *AgentSession, thinking_level: agent.ThinkingLevel) !void {
        try self.setThinkingLevelWithSource(thinking_level, "agent_session");
    }

    pub fn setThinkingLevelWithSource(self: *AgentSession, thinking_level: agent.ThinkingLevel, source: []const u8) !void {
        const previous = self.agent.getThinkingLevel();
        self.agent.setThinkingLevel(thinking_level);
        _ = try self.session_manager.appendThinkingLevelChange(thinking_level);
        if (self.extension_hook_context) |ctx| {
            try emitThinkingLevelSelectHook(self.allocator, ctx, thinking_level, previous);
        }
        _ = source;
    }

    pub fn setModel(self: *AgentSession, model: ai.Model) !void {
        const previous = self.agent.getModel();
        self.agent.setModel(model);
        _ = try self.session_manager.appendModelChange(model.provider, model.id);
        if (self.extension_hook_context) |ctx| {
            try emitModelSelectHook(self.allocator, ctx, model, previous, "set");
        }
    }

    pub fn emitUserBashEvent(self: *AgentSession, command: []const u8, exclude_from_context: bool) !void {
        if (self.extension_hook_context) |ctx| {
            try emitUserBashHook(self.allocator, ctx, command, exclude_from_context, self.cwd);
        }
    }

    pub fn emitSessionTreeEvent(self: *AgentSession, new_leaf_id: ?[]const u8, old_leaf_id: ?[]const u8, from_extension: bool) !void {
        if (self.extension_hook_context) |ctx| {
            try emitSessionTreeHook(self.allocator, ctx, new_leaf_id, old_leaf_id, from_extension);
        }
    }

    pub fn emitResourcesDiscoverEvent(self: *AgentSession, reason: []const u8) !void {
        if (self.extension_hook_context) |ctx| {
            try emitResourcesDiscoverHook(self.allocator, ctx, self.cwd, reason);
        }
    }

    pub fn setApiKey(self: *AgentSession, api_key: ?[]const u8) void {
        self.agent.setApiKey(api_key);
    }

    fn runPostPromptMaintenance(self: *AgentSession) !void {
        while (true) {
            const last_assistant = findLastAssistantMessage(self.agent.getMessages()) orelse {
                self.retry_attempt = 0;
                self.overflow_recovery_attempted = false;
                return;
            };

            if (last_assistant.stop_reason != .error_reason) {
                if (self.retry_attempt > 0) {
                    try self.emitRetryLifecycleEvent(.{ .end = .{
                        .success = true,
                        .attempt = self.retry_attempt,
                    } });
                }
                self.retry_attempt = 0;
                self.overflow_recovery_attempted = false;
            }

            if (try self.handleOverflowCompaction(last_assistant)) continue;
            if (try self.handleRetryableError(last_assistant)) continue;
            if (try self.handleThresholdCompaction(last_assistant)) continue;
            return;
        }
    }

    fn handleOverflowCompaction(self: *AgentSession, last_assistant: ai.AssistantMessage) !bool {
        if (!self.compaction_settings.enabled) return false;
        if (!isContextOverflow(last_assistant, self.agent.getModel().context_window)) return false;
        if (self.overflow_recovery_attempted) return false;

        self.overflow_recovery_attempted = true;
        _ = removeLastAssistantError(self);
        _ = try self.runCompactionWithLifecycle(.overflow, null, true);
        try self.agent.continueRun();
        return true;
    }

    fn handleThresholdCompaction(self: *AgentSession, last_assistant: ai.AssistantMessage) !bool {
        _ = last_assistant;
        if (!self.compaction_settings.enabled) return false;
        const context_window = self.agent.getModel().context_window;
        if (context_window == 0) return false;
        if (!shouldAutoCompact(estimateContextTokens(self.agent.getMessages()), context_window, self.compaction_settings)) return false;
        _ = self.runCompactionWithLifecycle(.threshold, null, false) catch |err| switch (err) {
            error.NothingToCompact => return false,
            else => return err,
        };
        if (self.agent.hasQueuedMessages()) {
            try self.agent.continueRun();
            return true;
        }
        return false;
    }

    fn handleRetryableError(self: *AgentSession, last_assistant: ai.AssistantMessage) !bool {
        if (!self.retry_settings.enabled) return false;
        if (!isRetryableError(last_assistant, self.agent.getModel().context_window)) return false;

        self.retry_attempt += 1;
        if (self.retry_attempt > self.retry_settings.max_retries) {
            try self.emitRetryLifecycleEvent(.{ .end = .{
                .success = false,
                .attempt = self.retry_attempt - 1,
                .final_error = last_assistant.error_message,
            } });
            self.retry_attempt = 0;
            return false;
        }

        const error_message = last_assistant.error_message orelse "Unknown error";
        const delay_ms = exponentialBackoffMs(self.retry_settings.base_delay_ms, self.retry_attempt);
        try self.emitRetryLifecycleEvent(.{ .start = .{
            .attempt = self.retry_attempt,
            .max_attempts = self.retry_settings.max_retries,
            .delay_ms = delay_ms,
            .error_message = error_message,
        } });

        _ = removeLastAssistantError(self);
        const slept = try self.sleepRetryDelay(delay_ms);
        if (!slept) {
            const cancelled_attempt = self.retry_attempt;
            self.retry_attempt = 0;
            try self.emitRetryLifecycleEvent(.{ .end = .{
                .success = false,
                .attempt = cancelled_attempt,
                .final_error = "Retry cancelled",
            } });
            return false;
        }
        try self.agent.continueRun();
        return true;
    }

    fn emitRetryLifecycleEvent(self: *AgentSession, event: RetryLifecycleEvent) !void {
        if (self.retry_lifecycle_callback) |callback| {
            try callback.callback(callback.context, event);
        }
    }

    fn emitCompactionLifecycleEvent(self: *AgentSession, event: CompactionLifecycleEvent) !void {
        if (self.compaction_lifecycle_callback) |callback| {
            try callback.callback(callback.context, event);
        }
    }

    fn sleepRetryDelay(self: *AgentSession, delay_ms: u64) !bool {
        self.retry_abort_requested.store(false, .seq_cst);
        self.retry_delay_active.store(true, .seq_cst);
        defer self.retry_delay_active.store(false, .seq_cst);

        var remaining = delay_ms;
        while (remaining > 0) {
            if (self.retry_abort_requested.load(.seq_cst)) return false;
            const step = @min(remaining, @as(u64, 10));
            try sleepMilliseconds(self.io, step);
            remaining -= step;
        }
        return !self.retry_abort_requested.load(.seq_cst);
    }

    fn runCompactionWithLifecycle(
        self: *AgentSession,
        reason: CompactionReason,
        custom_instructions: ?[]const u8,
        will_retry: bool,
    ) !CompactionResult {
        try self.emitCompactionLifecycleEvent(.{ .start = .{ .reason = reason } });
        const result = self.runCompaction(custom_instructions) catch |err| {
            try self.emitCompactionLifecycleEvent(.{ .end = .{
                .reason = reason,
                .result = null,
                .aborted = false,
                .will_retry = false,
                .error_message = @errorName(err),
            } });
            return err;
        };
        try self.emitCompactionLifecycleEvent(.{ .end = .{
            .reason = reason,
            .result = result,
            .aborted = false,
            .will_retry = will_retry,
            .error_message = null,
        } });
        if (self.extension_hook_context) |ctx| {
            emitSessionCompactHook(self.allocator, ctx, false) catch {};
        }
        return result;
    }

    fn runCompaction(self: *AgentSession, custom_instructions: ?[]const u8) !CompactionResult {
        self.compaction_active.store(true, .seq_cst);
        defer self.compaction_active.store(false, .seq_cst);

        const branch_entries = try self.session_manager.getBranch(self.allocator, null);
        defer self.allocator.free(branch_entries);

        const preparation = prepareCompaction(branch_entries, self.compaction_settings.keep_recent_tokens) orelse
            prepareManualCompaction(branch_entries) orelse
            return error.NothingToCompact;

        const summary = try buildCompactionSummary(
            self.allocator,
            branch_entries,
            preparation.summary_start_index,
            preparation.first_kept_entry_index,
            custom_instructions,
        );
        defer self.allocator.free(summary);

        const first_kept_entry_id = branch_entries[preparation.first_kept_entry_index].id();
        const compaction_id = try self.session_manager.appendCompaction(
            summary,
            first_kept_entry_id,
            preparation.tokens_before,
        );
        try self.reloadFromSession();

        const entry = self.session_manager.getEntry(compaction_id) orelse return error.InvalidSessionTree;
        if (entry.* != .compaction) return error.InvalidSessionTree;
        return .{
            .summary = try session_manager.getCompactionSummary(entry.compaction),
            .first_kept_entry_id = entry.compaction.first_kept_entry_id,
            .tokens_before = entry.compaction.tokens_before,
        };
    }

    fn initWithManager(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        system_prompt: []const u8,
        model: ?ai.Model,
        api_key: ?[]const u8,
        thinking_level: agent.ThinkingLevel,
        tools: []const agent.AgentTool,
        compaction_settings: CompactionSettings,
        retry_settings: RetrySettings,
        extension_hosts: []const extension_runtime.RuntimeAdapter,
        extension_hook_timeout_ms: u64,
        manager: *session_manager.SessionManager,
    ) !AgentSession {
        var session_context = try manager.buildSessionContext(allocator);
        defer session_context.deinit(allocator);

        const effective_model = resolveModel(model, session_context.model);
        const effective_thinking_level = if (session_context.thinking_level != .off)
            session_context.thinking_level
        else
            thinking_level;

        const extension_hook_context: ?*ExtensionHookContext = if (extension_hosts.len > 0) blk: {
            const context = try allocator.create(ExtensionHookContext);
            errdefer allocator.destroy(context);
            context.* = .{
                .allocator = allocator,
                .hosts = try runtime_hooks.wrapRuntimeAdapters(allocator, extension_hosts),
                .owns_hosts = true,
                .timeout_ms = extension_hook_timeout_ms,
                .diagnostics = .empty,
            };
            break :blk context;
        } else null;
        errdefer if (extension_hook_context) |context| {
            context.deinit(allocator);
            allocator.destroy(context);
        };

        var agent_instance = try agent.Agent.init(allocator, .{
            .system_prompt = system_prompt,
            .model = effective_model,
            .api_key = api_key,
            .session_id = manager.getSessionId(),
            .thinking_level = effective_thinking_level,
            .tools = tools,
            .messages = session_context.messages,
            .io = io,
            .stream_fn = stream_adapter.streamSimple,
            .transform_context = if (extension_hook_context != null) transformContextHook else null,
            .transform_context_context = if (extension_hook_context) |context| context else null,
            .before_tool_call = if (extension_hook_context != null) beforeToolCallHook else null,
            .after_tool_call = if (extension_hook_context != null) afterToolCallHook else null,
            .extension_hook_context = if (extension_hook_context) |context| context else null,
        });
        errdefer agent_instance.deinit();

        var instance = AgentSession{
            .allocator = allocator,
            .io = io,
            .cwd = cwd,
            .system_prompt = system_prompt,
            .agent = agent_instance,
            .session_manager = manager,
            .subscriber = .{
                .context = manager,
                .callback = handleSessionManagerEvent,
            },
            .subscribed = false,
            .extension_event_subscriber = .{
                .context = extension_hook_context,
                .callback = handleExtensionLifecycleEvent,
            },
            .extension_event_subscribed = false,
            .compaction_settings = compaction_settings,
            .retry_settings = retry_settings,
            .retry_attempt = 0,
            .retry_lifecycle_callback = null,
            .compaction_lifecycle_callback = null,
            .retry_abort_requested = std.atomic.Value(bool).init(false),
            .retry_delay_active = std.atomic.Value(bool).init(false),
            .overflow_recovery_attempted = false,
            .compaction_active = std.atomic.Value(bool).init(false),
            .extension_hook_context = extension_hook_context,
        };

        try instance.agent.subscribe(instance.subscriber);
        instance.subscribed = true;
        if (extension_hook_context) |context| {
            instance.extension_event_subscriber.context = context;
            try instance.agent.subscribe(instance.extension_event_subscriber);
            instance.extension_event_subscribed = true;
            emitSessionStartHook(allocator, context, "startup") catch {};
            emitResourcesDiscoverHook(allocator, context, cwd, "startup") catch {};
        }
        return instance;
    }

    fn reloadFromSession(self: *AgentSession) !void {
        var context = try self.session_manager.buildSessionContext(self.allocator);
        defer context.deinit(self.allocator);

        try self.agent.setMessages(context.messages);
        self.agent.setThinkingLevel(context.thinking_level);

        if (context.model) |restored_model| {
            var current = self.agent.getModel();
            if (restored_model.api) |api_name| current.api = api_name;
            current.provider = restored_model.provider;
            current.id = restored_model.model_id;
            current.name = restored_model.model_id;
            self.agent.setModel(current);
        }
    }

    fn runHookedPrompt(
        self: *AgentSession,
        input: anytype,
        accepted_callback: ?agent.PromptAcceptedCallback,
    ) !bool {
        if (self.extension_hook_context == null) return false;
        const Input = @TypeOf(input);
        if (comptime isStringLike(Input)) {
            const original_text: []const u8 = input;
            const hooked_text = try self.runInputHook(original_text) orelse return true;
            defer self.allocator.free(hooked_text);
            const prompt_text = try self.runBeforeAgentStartHook(hooked_text) orelse return true;
            defer self.allocator.free(prompt_text.text);
            defer if (prompt_text.system_prompt) |system_prompt| self.allocator.free(system_prompt);
            const previous_system_prompt = self.agent.getSystemPrompt();
            if (prompt_text.system_prompt) |system_prompt| self.agent.setSystemPrompt(system_prompt);
            defer self.agent.setSystemPrompt(previous_system_prompt);
            try self.agent.promptWithAcceptedCallback(prompt_text.text, accepted_callback);
            try self.runPostPromptMaintenance();
            try self.flushExtensionHookDiagnostics();
            return true;
        }
        if (comptime isTextWithImagesPrompt(Input)) {
            const original_text: []const u8 = input.text;
            const hooked_text = try self.runInputHook(original_text) orelse return true;
            defer self.allocator.free(hooked_text);
            const prompt_text = try self.runBeforeAgentStartHook(hooked_text) orelse return true;
            defer self.allocator.free(prompt_text.text);
            defer if (prompt_text.system_prompt) |system_prompt| self.allocator.free(system_prompt);
            const previous_system_prompt = self.agent.getSystemPrompt();
            if (prompt_text.system_prompt) |system_prompt| self.agent.setSystemPrompt(system_prompt);
            defer self.agent.setSystemPrompt(previous_system_prompt);
            try self.agent.promptWithAcceptedCallback(.{ .text = prompt_text.text, .images = input.images }, accepted_callback);
            try self.runPostPromptMaintenance();
            try self.flushExtensionHookDiagnostics();
            return true;
        }
        return false;
    }

    const PromptHookText = struct {
        text: []u8,
        system_prompt: ?[]u8 = null,
    };

    fn runInputHook(self: *AgentSession, text: []const u8) !?[]u8 {
        const context = self.extension_hook_context orelse return try self.allocator.dupe(u8, text);
        if (!context.hasHook("input")) return try self.allocator.dupe(u8, text);
        var event = try makeObject(self.allocator);
        defer tools_common.deinitJsonValue(self.allocator, event);
        try putString(self.allocator, &event.object, "type", "input");
        try putString(self.allocator, &event.object, "text", text);
        try putString(self.allocator, &event.object, "source", "agent_session");
        var invocation = (try context.invokeDetailed(self.allocator, "input", event)) orelse return try self.allocator.dupe(u8, text);
        defer invocation.deinit(self.allocator);
        if (hookHandled(invocation.result)) {
            try self.appendHookDiagnostic("input", invocation.extension_id, invocation.result);
            return null;
        }
        return try self.allocator.dupe(u8, stringField(invocation.result, "text") orelse stringField(invocation.result, "input") orelse stringField(invocation.result, "prompt") orelse text);
    }

    fn runBeforeAgentStartHook(self: *AgentSession, text: []const u8) !?PromptHookText {
        const context = self.extension_hook_context orelse return .{ .text = try self.allocator.dupe(u8, text) };
        if (!context.hasHook("before_agent_start")) return .{ .text = try self.allocator.dupe(u8, text) };
        var event = try makeObject(self.allocator);
        defer tools_common.deinitJsonValue(self.allocator, event);
        try putString(self.allocator, &event.object, "type", "before_agent_start");
        try putString(self.allocator, &event.object, "text", text);
        try putString(self.allocator, &event.object, "systemPrompt", self.agent.getSystemPrompt());
        var invocation = (try context.invokeDetailed(self.allocator, "before_agent_start", event)) orelse return .{ .text = try self.allocator.dupe(u8, text) };
        defer invocation.deinit(self.allocator);
        if (hookHandled(invocation.result)) {
            try self.appendHookDiagnostic("before_agent_start", invocation.extension_id, invocation.result);
            return null;
        }
        return .{
            .text = try self.allocator.dupe(u8, stringField(invocation.result, "text") orelse stringField(invocation.result, "input") orelse stringField(invocation.result, "prompt") orelse text),
            .system_prompt = if (stringField(invocation.result, "systemPrompt") orelse stringField(invocation.result, "system_prompt")) |system_prompt| try self.allocator.dupe(u8, system_prompt) else null,
        };
    }

    fn appendHookDiagnostic(self: *AgentSession, hook_name: []const u8, extension_id: []const u8, result: std.json.Value) !void {
        const reason = hookReason(result);
        const diagnostic = try std.fmt.allocPrint(
            self.allocator,
            "Extension hook suppressed turn extensionId={s} hook={s} reason={s}",
            .{ extension_id, hook_name, reason },
        );
        defer self.allocator.free(diagnostic);
        var message = try makeDiagnosticAssistantMessage(self.allocator, self.agent.getModel(), diagnostic);
        defer agent.deinitMessage(self.allocator, &message);
        try self.agent.appendMessage(message);
        _ = try self.session_manager.appendMessage(message);
    }

    fn flushExtensionHookDiagnostics(self: *AgentSession) !void {
        const context = self.extension_hook_context orelse return;
        if (context.diagnostics.items.len == 0) return;
        var diagnostics = context.diagnostics;
        context.diagnostics = .empty;
        defer diagnostics.deinit(self.allocator);
        for (diagnostics.items) |diagnostic| {
            defer self.allocator.free(diagnostic);
            var message = try makeDiagnosticAssistantMessage(self.allocator, self.agent.getModel(), diagnostic);
            defer agent.deinitMessage(self.allocator, &message);
            try self.agent.appendMessage(message);
            _ = try self.session_manager.appendMessage(message);
        }
    }
};

const ExtensionHookContext = struct {
    allocator: std.mem.Allocator,
    hosts: []const runtime_hooks.HookRuntime,
    owns_hosts: bool = false,
    timeout_ms: u64,
    next_turn_index: usize = 0,
    active_turn_index: ?usize = null,
    diagnostics: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ExtensionHookContext, allocator: std.mem.Allocator) void {
        for (self.diagnostics.items) |diagnostic| allocator.free(diagnostic);
        self.diagnostics.deinit(allocator);
        if (self.owns_hosts and self.hosts.len > 0) allocator.free(self.hosts);
        self.* = undefined;
    }

    fn recordDiagnostic(self: *ExtensionHookContext, diagnostic: []const u8) !void {
        try self.diagnostics.append(self.allocator, try self.allocator.dupe(u8, diagnostic));
    }

    fn hasHook(self: *const ExtensionHookContext, event_name: []const u8) bool {
        for (self.hosts) |host| {
            if (host.hasHook(event_name)) return true;
        }
        return false;
    }

    fn invoke(self: *const ExtensionHookContext, allocator: std.mem.Allocator, event_name: []const u8, event: std.json.Value) !?std.json.Value {
        if (try self.invokeDetailed(allocator, event_name, event)) |invocation| {
            allocator.free(invocation.extension_id);
            return invocation.result;
        }
        return null;
    }

    const HookInvocation = struct {
        result: std.json.Value,
        extension_id: []u8,

        fn deinit(self: *HookInvocation, allocator: std.mem.Allocator) void {
            tools_common.deinitJsonValue(allocator, self.result);
            allocator.free(self.extension_id);
            self.* = undefined;
        }
    };

    fn invokeDetailed(self: *const ExtensionHookContext, allocator: std.mem.Allocator, event_name: []const u8, event: std.json.Value) !?HookInvocation {
        var last_result: ?std.json.Value = null;
        errdefer if (last_result) |value| tools_common.deinitJsonValue(allocator, value);
        var last_extension_id: ?[]u8 = null;
        errdefer if (last_extension_id) |value| allocator.free(value);
        var dispatch_entries = std.ArrayList(HookDispatchEntry).empty;
        defer dispatch_entries.deinit(allocator);
        for (self.hosts, 0..) |host, host_index| {
            if (!host.hasHook(event_name)) continue;
            try dispatch_entries.append(allocator, hookDispatchEntryForHost(host, event_name, host_index));
        }
        std.mem.sort(HookDispatchEntry, dispatch_entries.items, {}, hookDispatchEntryLessThan);

        for (dispatch_entries.items) |entry| {
            const host = entry.host;
            if (try host.invoke(allocator, event_name, event, self.timeout_ms)) |result| {
                if (last_result) |old| tools_common.deinitJsonValue(allocator, old);
                if (last_extension_id) |old_id| allocator.free(old_id);
                last_result = result;
                last_extension_id = try host.describeSource(allocator, event_name);
            }
        }
        const result = last_result orelse return null;
        last_result = null;
        const extension_id = last_extension_id orelse try allocator.dupe(u8, "unknown-extension");
        last_extension_id = null;
        return .{
            .result = result,
            .extension_id = extension_id,
        };
    }

    fn invokeLifecycle(self: *ExtensionHookContext, allocator: std.mem.Allocator, event: agent.AgentEvent) !void {
        const event_name = switch (event.event_type) {
            .agent_start => "agent_start",
            .agent_end => "agent_end",
            .turn_start => "turn_start",
            .turn_end => "turn_end",
            .message_start => "message_start",
            .message_update => "message_update",
            .message_end => "message_end",
            .tool_execution_start => "tool_execution_start",
            .tool_execution_update => "tool_execution_update",
            .tool_execution_end => "tool_execution_end",
            .before_provider_request => "before_provider_request",
            .after_provider_response => "after_provider_response",
        };
        if (!self.hasHook(event_name)) return;

        if (event.event_type == .turn_start) {
            self.active_turn_index = self.next_turn_index;
            self.next_turn_index += 1;
        }

        const payload = try makeLifecycleEventObject(allocator, event_name, event, self.active_turn_index orelse 0);
        defer tools_common.deinitJsonValue(allocator, payload);
        const result = try self.invoke(allocator, event_name, payload);
        if (result) |value| tools_common.deinitJsonValue(allocator, value);
    }
};

const HookDispatchEntry = struct {
    host: runtime_hooks.HookRuntime,
    host_index: usize,
    priority: i64 = 0,
    declaration_order: usize = 0,
};

fn hookDispatchEntryForHost(host: runtime_hooks.HookRuntime, event_name: []const u8, host_index: usize) HookDispatchEntry {
    const metadata = host.metadata(event_name);
    return .{
        .host = host,
        .host_index = host_index,
        .priority = metadata.priority,
        .declaration_order = metadata.declaration_order,
    };
}

fn hookDispatchEntryLessThan(_: void, lhs: HookDispatchEntry, rhs: HookDispatchEntry) bool {
    if (lhs.priority != rhs.priority) return lhs.priority < rhs.priority;
    if (lhs.declaration_order != rhs.declaration_order) return lhs.declaration_order < rhs.declaration_order;
    return lhs.host_index < rhs.host_index;
}

fn handleExtensionLifecycleEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const hook_context: *ExtensionHookContext = @ptrCast(@alignCast(context orelse return));
    try hook_context.invokeLifecycle(std.heap.page_allocator, event);
}

fn transformContextHook(
    allocator: std.mem.Allocator,
    messages: []const agent.AgentMessage,
    signal: ?*const std.atomic.Value(bool),
    transform_context: ?*anyopaque,
) ![]agent.AgentMessage {
    if (signal) |abort_signal| {
        if (abort_signal.load(.seq_cst)) return @constCast(messages);
    }
    const context: *ExtensionHookContext = @ptrCast(@alignCast(transform_context orelse return @constCast(messages)));
    if (!context.hasHook("context")) return @constCast(messages);
    var event = try makeObject(allocator);
    defer tools_common.deinitJsonValue(allocator, event);
    try putString(allocator, &event.object, "type", "context");
    try putMessagesSummary(allocator, &event.object, messages);
    var invocation = (try context.invokeDetailed(allocator, "context", event)) orelse return @constCast(messages);
    defer invocation.deinit(allocator);
    if (try contextHookContributionDiagnostic(allocator, invocation.extension_id, invocation.result)) |diagnostic| {
        defer allocator.free(diagnostic);
        try context.recordDiagnostic(diagnostic);
        return @constCast(messages);
    }
    const extra = try messagesFromHookResult(allocator, invocation.result);
    if (extra.len == 0) {
        allocator.free(extra);
        return @constCast(messages);
    }
    const output = try allocator.alloc(agent.AgentMessage, messages.len + extra.len);
    @memcpy(output[0..messages.len], messages);
    @memcpy(output[messages.len..], extra);
    allocator.free(extra);
    return output;
}

fn beforeToolCallHook(
    allocator: std.mem.Allocator,
    before_context: agent.types.BeforeToolCallContext,
    signal: ?*const std.atomic.Value(bool),
) !?agent.types.BeforeToolCallResult {
    if (signal) |abort_signal| {
        if (abort_signal.load(.seq_cst)) return null;
    }
    const context: *ExtensionHookContext = @ptrCast(@alignCast(before_context.context.extension_hook_context orelse return null));
    if (!context.hasHook("tool_call")) return null;
    const event = try toolCallEvent(allocator, "tool_call", before_context.tool_call, before_context.args.*);
    defer tools_common.deinitJsonValue(allocator, event);
    const result = try context.invoke(allocator, "tool_call", event) orelse return null;
    defer tools_common.deinitJsonValue(allocator, result);
    if (objectField(result, "input")) |input| {
        tools_common.deinitJsonValue(allocator, before_context.args.*);
        before_context.args.* = try tools_common.cloneJsonValue(allocator, input);
    }
    if (hookHandled(result) or boolField(result, "block") orelse false) {
        return .{
            .block = true,
            .reason = try allocator.dupe(u8, stringField(result, "reason") orelse stringField(result, "message") orelse "blocked by extension hook"),
            .terminate = boolField(result, "terminate") orelse false,
        };
    }
    return null;
}

fn afterToolCallHook(
    allocator: std.mem.Allocator,
    after_context: agent.types.AfterToolCallContext,
    signal: ?*const std.atomic.Value(bool),
) !?agent.types.AfterToolCallResult {
    if (signal) |abort_signal| {
        if (abort_signal.load(.seq_cst)) return null;
    }
    const context: *ExtensionHookContext = @ptrCast(@alignCast(after_context.context.extension_hook_context orelse return null));
    if (!context.hasHook("tool_result")) return null;
    var event = try toolCallEvent(allocator, "tool_result", after_context.tool_call, after_context.args);
    defer tools_common.deinitJsonValue(allocator, event);
    try putBool(allocator, &event.object, "isError", after_context.is_error);
    try putToolResultEventFields(allocator, &event.object, after_context.result);
    const result = try context.invoke(allocator, "tool_result", event) orelse return null;
    defer tools_common.deinitJsonValue(allocator, result);
    var patch = agent.types.AfterToolCallResult{};
    errdefer if (patch.content) |content| tools_common.deinitContentBlocks(allocator, content);
    errdefer if (patch.details) |details| tools_common.deinitJsonValue(allocator, details);
    if (objectField(result, "content")) |content_value| {
        patch.content = switch (content_value) {
            .array => try extension_protocol.parseContentBlocks(allocator, content_value),
            .string => |text| try tools_common.makeTextContent(allocator, text),
            else => null,
        };
    }
    if (objectField(result, "details")) |details| {
        patch.details = try tools_common.cloneJsonValue(allocator, details);
    }
    if (boolField(result, "isError") orelse boolField(result, "is_error")) |is_error| {
        patch.is_error = is_error;
    }
    if (boolField(result, "terminate")) |terminate| {
        patch.terminate = terminate;
    }
    if (patch.content == null and patch.details == null and patch.is_error == null and patch.terminate == null) return null;
    return patch;
}

fn makeLifecycleEventObject(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    event: agent.AgentEvent,
    turn_index: usize,
) !std.json.Value {
    var payload = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, payload);
    try putString(allocator, &payload.object, "type", event_name);
    try putInt(allocator, &payload.object, "turnIndex", @intCast(turn_index));
    if (event.tool_call_id) |id| try putString(allocator, &payload.object, "toolCallId", id);
    if (event.tool_name) |name| try putString(allocator, &payload.object, "toolName", name);
    if (event.args) |args| try putValue(allocator, &payload.object, "args", try tools_common.cloneJsonValue(allocator, args));
    if (event.message) |message| try putMessageSummary(allocator, &payload.object, message);
    if (event.messages) |messages| try putMessagesSummary(allocator, &payload.object, messages);
    if (event.tool_results) |tool_results| {
        var array = std.json.Array.init(allocator);
        for (tool_results) |tool_result| {
            const entry = try toolResultMessageEntry(allocator, tool_result);
            try array.append(.{ .object = entry });
        }
        try putValue(allocator, &payload.object, "toolResults", .{ .array = array });
    }
    if (event.partial_result) |partial| {
        try putValue(allocator, &payload.object, "partialResult", try makeToolResultPayload(allocator, partial));
    }
    if (event.result) |result| {
        try putValue(allocator, &payload.object, "result", try makeToolResultPayload(allocator, result));
    }
    if (event.is_error) |is_error| try putBool(allocator, &payload.object, "isError", is_error);
    return payload;
}

fn modelToJsonValue(allocator: std.mem.Allocator, model: ai.Model) !std.json.Value {
    var obj = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, obj);
    try putString(allocator, &obj.object, "id", model.id);
    try putString(allocator, &obj.object, "name", model.name);
    try putString(allocator, &obj.object, "api", model.api);
    try putString(allocator, &obj.object, "provider", model.provider);
    try putString(allocator, &obj.object, "baseUrl", model.base_url);
    try putBool(allocator, &obj.object, "reasoning", model.reasoning);
    return obj;
}

fn thinkingLevelToString(level: agent.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

/// One field in an extension event payload. Used by emitNotificationHook /
/// emitCancellableHook to compose payloads declaratively instead of
/// repeating the `if (hasHook) { makeObject; putString "type" ...; ... }`
/// scaffolding in every emit helper.
///
/// `.json_owned` transfers ownership of `value` to the event object on
/// success. If applyHookField fails before put, the value leaks — same
/// failure mode as the previous hand-rolled helpers, kept for now.
const HookField = union(enum) {
    string: struct { key: []const u8, value: []const u8 },
    boolean: struct { key: []const u8, value: bool },
    optional_string: struct { key: []const u8, value: ?[]const u8 },
    json_owned: struct { key: []const u8, value: std.json.Value },
};

fn applyHookField(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    field: HookField,
) !void {
    switch (field) {
        .string => |s| try putString(allocator, object, s.key, s.value),
        .boolean => |b| try putBool(allocator, object, b.key, b.value),
        .optional_string => |o| if (o.value) |v| {
            try putString(allocator, object, o.key, v);
        } else {
            try putValue(allocator, object, o.key, .null);
        },
        .json_owned => |j| try putValue(allocator, object, j.key, j.value),
    }
}

fn emitNotificationHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    event_name: []const u8,
    fields: []const HookField,
) !void {
    if (!ctx.hasHook(event_name)) return;
    var event = try makeObject(allocator);
    defer tools_common.deinitJsonValue(allocator, event);
    try putString(allocator, &event.object, "type", event_name);
    for (fields) |field| try applyHookField(allocator, &event.object, field);
    const result = try ctx.invoke(allocator, event_name, event);
    if (result) |value| tools_common.deinitJsonValue(allocator, value);
}

fn emitCancellableHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    event_name: []const u8,
    fields: []const HookField,
) !bool {
    if (!ctx.hasHook(event_name)) return false;
    var event = try makeObject(allocator);
    defer tools_common.deinitJsonValue(allocator, event);
    try putString(allocator, &event.object, "type", event_name);
    for (fields) |field| try applyHookField(allocator, &event.object, field);
    const result = try ctx.invoke(allocator, event_name, event) orelse return false;
    defer tools_common.deinitJsonValue(allocator, result);
    return boolField(result, "cancel") orelse false;
}

fn emitModelSelectHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    model: ai.Model,
    previous_model: ai.Model,
    source: []const u8,
) !void {
    if (!ctx.hasHook("model_select")) return;
    var event = try makeObject(allocator);
    defer tools_common.deinitJsonValue(allocator, event);
    try putString(allocator, &event.object, "type", "model_select");
    try putOwnedJsonField(allocator, &event.object, "model", try modelToJsonValue(allocator, model));
    try putOwnedJsonField(allocator, &event.object, "previousModel", try modelToJsonValue(allocator, previous_model));
    try putString(allocator, &event.object, "source", source);
    const result = try ctx.invoke(allocator, "model_select", event);
    if (result) |value| tools_common.deinitJsonValue(allocator, value);
}

fn putOwnedJsonField(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) !void {
    const owned = value;
    errdefer tools_common.deinitJsonValue(allocator, owned);
    try putValue(allocator, object, key, owned);
}

fn emitThinkingLevelSelectHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    level: agent.ThinkingLevel,
    previous_level: agent.ThinkingLevel,
) !void {
    return emitNotificationHook(allocator, ctx, "thinking_level_select", &.{
        .{ .string = .{ .key = "level", .value = thinkingLevelToString(level) } },
        .{ .string = .{ .key = "previousLevel", .value = thinkingLevelToString(previous_level) } },
    });
}

fn emitSessionStartHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    reason: []const u8,
) !void {
    return emitNotificationHook(allocator, ctx, "session_start", &.{
        .{ .string = .{ .key = "reason", .value = reason } },
    });
}

fn emitSessionShutdownHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    reason: []const u8,
) !void {
    return emitNotificationHook(allocator, ctx, "session_shutdown", &.{
        .{ .string = .{ .key = "reason", .value = reason } },
    });
}

fn emitSessionCompactHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    from_extension: bool,
) !void {
    return emitNotificationHook(allocator, ctx, "session_compact", &.{
        .{ .boolean = .{ .key = "fromExtension", .value = from_extension } },
    });
}

fn emitUserBashHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    command: []const u8,
    exclude_from_context: bool,
    cwd: []const u8,
) !void {
    return emitNotificationHook(allocator, ctx, "user_bash", &.{
        .{ .string = .{ .key = "command", .value = command } },
        .{ .boolean = .{ .key = "excludeFromContext", .value = exclude_from_context } },
        .{ .string = .{ .key = "cwd", .value = cwd } },
    });
}

fn emitSessionTreeHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    new_leaf_id: ?[]const u8,
    old_leaf_id: ?[]const u8,
    from_extension: bool,
) !void {
    return emitNotificationHook(allocator, ctx, "session_tree", &.{
        .{ .optional_string = .{ .key = "newLeafId", .value = new_leaf_id } },
        .{ .optional_string = .{ .key = "oldLeafId", .value = old_leaf_id } },
        .{ .boolean = .{ .key = "fromExtension", .value = from_extension } },
    });
}

fn emitResourcesDiscoverHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    cwd: []const u8,
    reason: []const u8,
) !void {
    return emitNotificationHook(allocator, ctx, "resources_discover", &.{
        .{ .string = .{ .key = "cwd", .value = cwd } },
        .{ .string = .{ .key = "reason", .value = reason } },
    });
}

fn emitSessionBeforeCompactHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    custom_instructions: ?[]const u8,
) !bool {
    // customInstructions is omitted when null (matches TS schema where the
    // property is optional, not nullable). HookField has no "omit-if-absent"
    // variant, so dispatch to two emit*Hook calls with different field lists.
    if (custom_instructions) |instructions| {
        return emitCancellableHook(allocator, ctx, "session_before_compact", &.{
            .{ .string = .{ .key = "customInstructions", .value = instructions } },
        });
    }
    return emitCancellableHook(allocator, ctx, "session_before_compact", &.{});
}

fn emitSessionBeforeTreeHook(
    allocator: std.mem.Allocator,
    ctx: *ExtensionHookContext,
    target_id: []const u8,
    old_leaf_id: ?[]const u8,
) !bool {
    return emitCancellableHook(allocator, ctx, "session_before_tree", &.{
        .{ .string = .{ .key = "targetId", .value = target_id } },
        .{ .optional_string = .{ .key = "oldLeafId", .value = old_leaf_id } },
    });
}

fn toolCallEvent(allocator: std.mem.Allocator, event_name: []const u8, tool_call: ai.ToolCall, args: std.json.Value) !std.json.Value {
    var event = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, event);
    try putString(allocator, &event.object, "type", event_name);
    try putString(allocator, &event.object, "toolName", tool_call.name);
    try putString(allocator, &event.object, "toolCallId", tool_call.id);
    try putValue(allocator, &event.object, "input", try tools_common.cloneJsonValue(allocator, args));
    return event;
}

fn putToolResultEventFields(allocator: std.mem.Allocator, object: *std.json.ObjectMap, result: agent.types.AgentToolResult) !void {
    try putValue(allocator, object, "content", try contentBlocksToJsonArray(allocator, result.content));
    if (result.details) |details| try putValue(allocator, object, "details", try tools_common.cloneJsonValue(allocator, details));
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = objectField(value, key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(value: std.json.Value, key: []const u8) ?bool {
    const field = objectField(value, key) orelse return null;
    return switch (field) {
        .bool => |flag| flag,
        else => null,
    };
}

fn hookHandled(value: std.json.Value) bool {
    if (boolField(value, "handled") orelse false) return true;
    if (boolField(value, "block") orelse false) return true;
    if (stringField(value, "action")) |action| {
        return std.mem.eql(u8, action, "handled") or std.mem.eql(u8, action, "block") or std.mem.eql(u8, action, "deny");
    }
    return false;
}

fn hookReason(value: std.json.Value) []const u8 {
    return stringField(value, "reason") orelse
        stringField(value, "message") orelse
        stringField(value, "error") orelse
        stringField(value, "action") orelse
        if (boolField(value, "handled") orelse false) "handled" else "blocked";
}

const HookSourceLookup = struct {
    allocator: std.mem.Allocator,
    event_name: []const u8,
    extension_id: ?[]u8 = null,
};

fn describeHookSource(allocator: std.mem.Allocator, host: extension_runtime.RuntimeAdapter, event_name: []const u8) ![]u8 {
    var lookup = HookSourceLookup{
        .allocator = allocator,
        .event_name = event_name,
    };
    host.withRegistry(&lookup, captureHookSource) catch {};
    if (lookup.extension_id) |extension_id| return extension_id;
    return try allocator.dupe(u8, host.kind.jsonName());
}

fn captureHookSource(context: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const lookup: *HookSourceLookup = @ptrCast(@alignCast(context orelse return));
    for (registry.hooks.items) |hook| {
        if (!std.mem.eql(u8, hook.event_name, lookup.event_name)) continue;
        lookup.extension_id = try lookup.allocator.dupe(u8, hook.extension_path);
        return;
    }
}

fn makeDiagnosticAssistantMessage(allocator: std.mem.Allocator, model: ai.Model, diagnostic: []const u8) !agent.AgentMessage {
    const content = try tools_common.makeTextContent(allocator, diagnostic);
    errdefer {
        allocator.free(content[0].text.text);
        allocator.free(content);
    }
    return .{ .assistant = .{
        .role = try allocator.dupe(u8, "assistant"),
        .content = content,
        .tool_calls = null,
        .api = try allocator.dupe(u8, model.api),
        .provider = try allocator.dupe(u8, model.provider),
        .model = try allocator.dupe(u8, model.id),
        .usage = ai.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = try allocator.dupe(u8, diagnostic),
        .timestamp = agent.types.nowMilliseconds(),
    } };
}

fn contextHookContributionDiagnostic(allocator: std.mem.Allocator, extension_id: []const u8, result: std.json.Value) !?[]u8 {
    if (result != .object) {
        return try formatContextHookContributionDiagnostic(allocator, extension_id, "$", "expected object result");
    }
    const messages = result.object.get("messages") orelse return null;
    if (messages != .array) {
        return try formatContextHookContributionDiagnostic(allocator, extension_id, "$.messages", "expected array");
    }
    for (messages.array.items, 0..) |message, index| {
        switch (message) {
            .string => {},
            .object => {
                if (stringField(message, "content") != null or stringField(message, "text") != null) continue;
                if (objectField(message, "content") != null) {
                    const path = try std.fmt.allocPrint(allocator, "$.messages[{d}].content", .{index});
                    defer allocator.free(path);
                    return try formatContextHookContributionDiagnostic(allocator, extension_id, path, "expected string");
                }
                if (objectField(message, "text") != null) {
                    const path = try std.fmt.allocPrint(allocator, "$.messages[{d}].text", .{index});
                    defer allocator.free(path);
                    return try formatContextHookContributionDiagnostic(allocator, extension_id, path, "expected string");
                }
                const path = try std.fmt.allocPrint(allocator, "$.messages[{d}]", .{index});
                defer allocator.free(path);
                return try formatContextHookContributionDiagnostic(allocator, extension_id, path, "missing string content or text field");
            },
            else => {
                const path = try std.fmt.allocPrint(allocator, "$.messages[{d}]", .{index});
                defer allocator.free(path);
                return try formatContextHookContributionDiagnostic(allocator, extension_id, path, "expected string or object");
            },
        }
    }
    return null;
}

fn formatContextHookContributionDiagnostic(
    allocator: std.mem.Allocator,
    extension_id: []const u8,
    path: []const u8,
    message: []const u8,
) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Invalid extension context hook contribution extensionId={s} hook=context path={s}: {s}",
        .{ extension_id, path, message },
    );
}

fn messagesFromHookResult(allocator: std.mem.Allocator, result: std.json.Value) ![]agent.AgentMessage {
    const messages_value = objectField(result, "messages") orelse return allocator.alloc(agent.AgentMessage, 0);
    if (messages_value != .array) return allocator.alloc(agent.AgentMessage, 0);
    var output = std.ArrayList(agent.AgentMessage).empty;
    errdefer {
        agent.deinitMessageSlice(allocator, output.items);
        output.deinit(allocator);
    }
    for (messages_value.array.items) |message_value| {
        if (message_value == .string) {
            try output.append(allocator, try hookUserMessage(allocator, message_value.string));
        } else if (message_value == .object) {
            const content = stringField(message_value, "content") orelse stringField(message_value, "text") orelse continue;
            try output.append(allocator, try hookUserMessage(allocator, content));
        }
    }
    return try output.toOwnedSlice(allocator);
}

fn hookUserMessage(allocator: std.mem.Allocator, text: []const u8) !agent.AgentMessage {
    const content = try tools_common.makeTextContent(allocator, text);
    return .{ .user = .{
        .content = content,
        .timestamp = agent.types.nowMilliseconds(),
    } };
}

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == u8,
        else => false,
    };
}

fn isTextWithImagesPrompt(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, "text") and @hasField(T, "images"),
        else => false,
    };
}

fn queuedUserMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    images: []const ai.ImageContent,
) !agent.AgentMessage {
    const content = try allocator.alloc(ai.ContentBlock, 1 + images.len);
    content[0] = .{ .text = .{ .text = text } };
    for (images, 0..) |image, index| {
        content[index + 1] = .{ .image = image };
    }
    return .{ .user = .{
        .content = content,
        .timestamp = 0,
    } };
}

fn deinitQueuedUserMessage(allocator: std.mem.Allocator, message: *agent.AgentMessage) void {
    switch (message.*) {
        .user => |user_message| allocator.free(user_message.content),
        else => {},
    }
}

fn queuedInputsFromMessages(
    allocator: std.mem.Allocator,
    messages: []const agent.AgentMessage,
) ![]QueuedInput {
    if (messages.len == 0) return try allocator.alloc(QueuedInput, 0);

    const queued = try allocator.alloc(QueuedInput, messages.len);
    var initialized: usize = 0;
    errdefer {
        for (queued[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(queued);
    }

    for (messages, 0..) |message, index| {
        queued[index] = try queuedInputFromMessage(allocator, message);
        initialized += 1;
    }

    return queued;
}

fn queuedInputFromMessage(allocator: std.mem.Allocator, message: agent.AgentMessage) !QueuedInput {
    const user_message = switch (message) {
        .user => |user| user,
        else => return error.InvalidQueuedMessage,
    };

    var text_block: []const u8 = "";
    var image_count: usize = 0;
    for (user_message.content) |block| {
        switch (block) {
            .text => |text| {
                if (text_block.len == 0) text_block = text.text;
            },
            .image => image_count += 1,
            else => {},
        }
    }

    const images = try allocator.alloc(ai.ImageContent, image_count);
    var image_index: usize = 0;
    errdefer {
        for (images[0..image_index]) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(images);
    }

    for (user_message.content) |block| {
        switch (block) {
            .image => |image| {
                images[image_index] = .{
                    .data = try allocator.dupe(u8, image.data),
                    .mime_type = try allocator.dupe(u8, image.mime_type),
                };
                image_index += 1;
            },
            else => {},
        }
    }

    return .{
        .text = try allocator.dupe(u8, text_block),
        .images = images,
    };
}

fn resolveModel(explicit_model: ?ai.Model, restored: ?session_manager.SessionModelRef) ai.Model {
    if (explicit_model) |model| return model;
    if (restored) |restored_model| {
        var model = agent.DEFAULT_MODEL;
        if (restored_model.api) |api_name| model.api = api_name;
        model.provider = restored_model.provider;
        model.id = restored_model.model_id;
        model.name = restored_model.model_id;
        return model;
    }
    return agent.DEFAULT_MODEL;
}

fn treeNavigationLeaf(entry: *const session_manager.SessionEntry) ?[]const u8 {
    return switch (entry.*) {
        .message => |message_entry| switch (message_entry.message) {
            .user => message_entry.parent_id,
            else => entry.id(),
        },
        .custom_message => |custom_message_entry| custom_message_entry.parent_id,
        else => entry.id(),
    };
}

fn treeNavigationEditorText(allocator: std.mem.Allocator, entry: *const session_manager.SessionEntry) !?[]u8 {
    return switch (entry.*) {
        .message => |message_entry| switch (message_entry.message) {
            .user => |user_message| try contentBlocksTextAlloc(allocator, user_message.content),
            else => null,
        },
        .custom_message => |custom_message_entry| switch (custom_message_entry.content) {
            .text => |text| try allocator.dupe(u8, text),
            .blocks => |blocks| try contentBlocksTextAlloc(allocator, blocks),
        },
        else => null,
    };
}

fn contentBlocksTextAlloc(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    for (blocks) |block| {
        if (block == .text) try writer.writer.writeAll(block.text.text);
    }
    return try allocator.dupe(u8, writer.written());
}

fn handleSessionManagerEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const manager: *session_manager.SessionManager = @ptrCast(@alignCast(context.?));
    if (event.event_type != .message_end) return;
    if (event.message) |message| {
        _ = try manager.appendMessage(message);
    }
}

fn removeLastAssistantError(self: *AgentSession) bool {
    const messages = self.agent.getMessages();
    if (messages.len == 0) return false;
    switch (messages[messages.len - 1]) {
        .assistant => |assistant_message| {
            if (assistant_message.stop_reason != .error_reason) return false;
            _ = self.agent.removeLastMessage();
            return true;
        },
        else => return false,
    }
}

const TestingExtensionHookContext = ExtensionHookContext;

pub const testing = struct {
    pub const ExtensionHookContext = TestingExtensionHookContext;

    pub fn reloadFromSession(session: *AgentSession) !void {
        return session.reloadFromSession();
    }

    pub fn callBeforeToolCallHook(
        allocator: std.mem.Allocator,
        before_context: agent.types.BeforeToolCallContext,
        signal: ?*const std.atomic.Value(bool),
    ) !?agent.types.BeforeToolCallResult {
        return beforeToolCallHook(allocator, before_context, signal);
    }

    pub fn callAfterToolCallHook(
        allocator: std.mem.Allocator,
        after_context: agent.types.AfterToolCallContext,
        signal: ?*const std.atomic.Value(bool),
    ) !?agent.types.AfterToolCallResult {
        return afterToolCallHook(allocator, after_context, signal);
    }

    pub fn invokeLifecycle(
        hook_context: *TestingExtensionHookContext,
        allocator: std.mem.Allocator,
        event: agent.AgentEvent,
    ) !void {
        return hook_context.invokeLifecycle(allocator, event);
    }
};

test {
    _ = session_compaction;
    _ = session_retry;
    _ = session_json_helpers;
}
