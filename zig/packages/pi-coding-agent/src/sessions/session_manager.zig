const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const common = @import("../tools/common.zig");
const session_search = @import("session_search.zig");
const session_jsonl = @import("session_jsonl.zig");

pub const CURRENT_SESSION_VERSION = session_jsonl.CURRENT_SESSION_VERSION;
pub const BRANCH_SUMMARY_PREFIX =
    "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n";
pub const BRANCH_SUMMARY_SUFFIX = "</summary>";

/// Process-wide monotonic counter used as entropy for generated session entry
/// IDs. It intentionally remains global so IDs keep increasing across all
/// session managers created in this process, and the atomic value keeps that
/// invariant safe when concurrent prompts append session records.
var global_id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub const SessionHeader = session_jsonl.SessionHeader;
pub const SessionMessageEntry = session_jsonl.SessionMessageEntry;
pub const ThinkingLevelChangeEntry = session_jsonl.ThinkingLevelChangeEntry;
pub const ModelChangeEntry = session_jsonl.ModelChangeEntry;
pub const CompactionEntry = session_jsonl.CompactionEntry;
pub const BranchSummaryEntry = session_jsonl.BranchSummaryEntry;
pub const CustomEntry = session_jsonl.CustomEntry;
pub const CustomMessageContent = session_jsonl.CustomMessageContent;
pub const CustomMessageEntry = session_jsonl.CustomMessageEntry;
pub const LabelEntry = session_jsonl.LabelEntry;
pub const SessionInfoEntry = session_jsonl.SessionInfoEntry;
pub const SessionEntry = session_jsonl.SessionEntry;

pub const deinitHeader = session_jsonl.deinitHeader;
pub const deinitEntry = session_jsonl.deinitEntry;
pub const cloneEntry = session_jsonl.cloneEntry;
pub const cloneMessage = session_jsonl.cloneMessage;
pub const deinitMessage = session_jsonl.deinitMessage;
pub const cloneCustomMessageContent = session_jsonl.cloneCustomMessageContent;
pub const createCompactionSummaryMessage = session_jsonl.createCompactionSummaryMessage;
pub const getCompactionSummary = session_jsonl.getCompactionSummary;
pub const cloneContentBlocks = session_jsonl.cloneContentBlocks;
pub const headerToJsonValue = session_jsonl.headerToJsonValue;
pub const entryToJsonValue = session_jsonl.entryToJsonValue;
pub const parseHeaderLine = session_jsonl.parseHeaderLine;
pub const parseEntryLine = session_jsonl.parseEntryLine;
pub const stringifyHeaderLine = session_jsonl.stringifyHeaderLine;
pub const stringifyEntryLine = session_jsonl.stringifyEntryLine;

pub const SessionModelRef = struct {
    api: ?[]const u8 = null,
    provider: []const u8,
    model_id: []const u8,
};

pub const SessionContext = struct {
    messages: []const agent.AgentMessage,
    thinking_level: agent.ThinkingLevel = .off,
    model: ?SessionModelRef = null,

    pub fn deinit(self: *SessionContext, allocator: std.mem.Allocator) void {
        for (@constCast(self.messages)) |*message| {
            deinitMessage(allocator, message);
        }
        allocator.free(@constCast(self.messages));
        self.* = .{
            .messages = &.{},
        };
    }
};

pub const SessionTreeNode = struct {
    entry: *const SessionEntry,
    children: []SessionTreeNode,
    label: ?[]const u8 = null,
    label_timestamp: ?[]const u8 = null,

    pub fn deinit(self: *SessionTreeNode, allocator: std.mem.Allocator) void {
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
        self.* = .{
            .entry = self.entry,
            .children = &.{},
            .label = null,
            .label_timestamp = null,
        };
    }
};

pub const SessionSearchInfo = session_search.SessionSearchInfo;
pub const SessionSearchSortMode = session_search.SessionSearchSortMode;
pub const SessionSearchNameFilter = session_search.SessionSearchNameFilter;
pub const SessionSearchField = session_search.SessionSearchField;
pub const SessionSearchTokenKind = session_search.SessionSearchTokenKind;
pub const SessionSearchToken = session_search.SessionSearchToken;
pub const SessionSearchQueryMode = session_search.SessionSearchQueryMode;
pub const ParsedSessionSearchQuery = session_search.ParsedSessionSearchQuery;
pub const SessionSearchMatch = session_search.SessionSearchMatch;
pub const SessionSearchOptions = session_search.SessionSearchOptions;
pub const SessionSearchResults = session_search.SessionSearchResults;
pub const parseSessionSearchQuery = session_search.parseSessionSearchQuery;
pub const filterAndSortSessions = session_search.filterAndSortSessions;

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    header: SessionHeader,
    runtime_cwd: []const u8,
    session_dir: []const u8,
    session_file: ?[]const u8,
    persist: bool,
    entries: std.ArrayList(SessionEntry),
    by_id: std.StringHashMap(usize),
    labels_by_id: std.StringHashMap([]const u8),
    label_timestamps_by_id: std.StringHashMap([]const u8),
    leaf_id: ?[]const u8,
    last_persisted_hash: ?u64,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
    ) !SessionManager {
        var manager = try initEmpty(allocator, io, cwd, session_dir, true, null);
        errdefer manager.deinit();
        try manager.persistToDisk();
        return manager;
    }

    pub fn createWithParent(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
        parent_session: ?[]const u8,
    ) !SessionManager {
        var manager = try initEmpty(allocator, io, cwd, session_dir, true, parent_session);
        errdefer manager.deinit();
        try manager.persistToDisk();
        return manager;
    }

    pub fn inMemory(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
    ) !SessionManager {
        return initEmpty(allocator, io, cwd, "", false, null);
    }

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        session_file: []const u8,
        cwd_override: ?[]const u8,
    ) !SessionManager {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
        return openWithWarningWriter(allocator, io, session_file, cwd_override, &stderr_writer.interface);
    }

    fn openWithWarningWriter(
        allocator: std.mem.Allocator,
        io: std.Io,
        session_file: []const u8,
        cwd_override: ?[]const u8,
        warning_writer: ?*std.Io.Writer,
    ) !SessionManager {
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, session_file, allocator, .unlimited);
        defer allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const header_line = lines.next() orelse return error.InvalidSessionFile;
        var header = try parseHeaderLine(allocator, header_line);
        errdefer deinitHeader(allocator, &header);

        const runtime_cwd = try allocator.dupe(u8, cwd_override orelse header.cwd);
        errdefer allocator.free(runtime_cwd);

        var manager = SessionManager{
            .allocator = allocator,
            .io = io,
            .header = header,
            .runtime_cwd = runtime_cwd,
            .session_dir = try deriveSessionDir(allocator, session_file),
            .session_file = try allocator.dupe(u8, session_file),
            .persist = true,
            .entries = .empty,
            .by_id = std.StringHashMap(usize).init(allocator),
            .labels_by_id = std.StringHashMap([]const u8).init(allocator),
            .label_timestamps_by_id = std.StringHashMap([]const u8).init(allocator),
            .leaf_id = null,
            .last_persisted_hash = std.hash.Wyhash.hash(0, bytes),
        };
        errdefer manager.deinit();

        var skipped_corrupted_lines: usize = 0;
        var line_number: usize = 2;
        while (lines.next()) |line| : (line_number += 1) {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            const entry = parseEntryLine(allocator, line) catch |err| {
                skipped_corrupted_lines += 1;
                if (warning_writer) |writer| {
                    logCorruptedSessionLine(writer, session_file, line_number, err) catch {};
                }
                continue;
            };
            try manager.appendLoadedEntry(entry);
        }

        if (skipped_corrupted_lines > 0 and warning_writer != null) {
            logCorruptedSessionDataLoss(
                warning_writer.?,
                session_file,
                skipped_corrupted_lines,
            ) catch {};
            warning_writer.?.flush() catch {};
        }

        return manager;
    }

    pub fn continueRecent(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
    ) !SessionManager {
        const latest = try findMostRecentSession(allocator, io, session_dir);
        defer if (latest) |path| allocator.free(path);

        if (latest) |path| {
            return open(allocator, io, path, cwd);
        }

        return create(allocator, io, cwd, session_dir);
    }

    pub fn deinit(self: *SessionManager) void {
        for (self.entries.items) |*entry| deinitEntry(self.allocator, entry);
        self.entries.deinit(self.allocator);
        self.by_id.deinit();
        self.labels_by_id.deinit();
        self.label_timestamps_by_id.deinit();
        deinitHeader(self.allocator, &self.header);
        self.allocator.free(self.runtime_cwd);
        self.allocator.free(self.session_dir);
        if (self.session_file) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn isPersisted(self: *const SessionManager) bool {
        return self.persist;
    }

    pub fn getHeader(self: *const SessionManager) SessionHeader {
        return self.header;
    }

    pub fn getCwd(self: *const SessionManager) []const u8 {
        return self.runtime_cwd;
    }

    pub fn getSessionDir(self: *const SessionManager) []const u8 {
        return self.session_dir;
    }

    pub fn getSessionId(self: *const SessionManager) []const u8 {
        return self.header.id;
    }

    pub fn getSessionFile(self: *const SessionManager) ?[]const u8 {
        return self.session_file;
    }

    pub fn getSessionName(self: *const SessionManager) ?[]const u8 {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            switch (self.entries.items[index]) {
                .session_info => |entry| {
                    const name = entry.name orelse return null;
                    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
                    if (trimmed.len == 0) return null;
                    return trimmed;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn getLeafId(self: *const SessionManager) ?[]const u8 {
        return self.leaf_id;
    }

    pub fn getEntries(self: *const SessionManager) []const SessionEntry {
        return self.entries.items;
    }

    pub fn getEntry(self: *const SessionManager, id: []const u8) ?*const SessionEntry {
        const index = self.by_id.get(id) orelse return null;
        return &self.entries.items[index];
    }

    pub fn appendMessage(self: *SessionManager, message: agent.AgentMessage) ![]const u8 {
        try self.ensureDiskNotModified();
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const entry = SessionEntry{
            .message = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .message = try cloneMessage(self.allocator, message),
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendThinkingLevelChange(self: *SessionManager, thinking_level: agent.ThinkingLevel) ![]const u8 {
        try self.ensureDiskNotModified();
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const entry = SessionEntry{
            .thinking_level_change = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .thinking_level = thinking_level,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendModelChange(self: *SessionManager, provider: []const u8, model_id: []const u8) ![]const u8 {
        try self.ensureDiskNotModified();
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const entry = SessionEntry{
            .model_change = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .provider = try self.allocator.dupe(u8, provider),
                .model_id = try self.allocator.dupe(u8, model_id),
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendCompaction(
        self: *SessionManager,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u32,
    ) ![]const u8 {
        try self.ensureDiskNotModified();
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const summary_message = try createCompactionSummaryMessage(self.allocator, summary, 0);
        errdefer {
            var cleanup = summary_message;
            deinitMessage(self.allocator, &cleanup);
        }

        const entry = SessionEntry{
            .compaction = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .first_kept_entry_id = try self.allocator.dupe(u8, first_kept_entry_id),
                .tokens_before = tokens_before,
                .message = summary_message,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendCustomEntry(self: *SessionManager, custom_type: []const u8, data: ?std.json.Value) ![]const u8 {
        try self.ensureDiskNotModified();
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const owned_data = if (data) |value| try common.cloneJsonValue(self.allocator, value) else null;
        errdefer if (owned_data) |value| common.deinitJsonValue(self.allocator, value);

        const entry = SessionEntry{
            .custom = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .custom_type = try self.allocator.dupe(u8, custom_type),
                .data = owned_data,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendCustomMessageEntry(
        self: *SessionManager,
        custom_type: []const u8,
        content: CustomMessageContent,
        display: bool,
        details: ?std.json.Value,
    ) ![]const u8 {
        try self.ensureDiskNotModified();
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const owned_content = try cloneCustomMessageContent(self.allocator, content);
        errdefer {
            var cleanup_content = owned_content;
            cleanup_content.deinit(self.allocator);
        }

        const owned_details = if (details) |value| try common.cloneJsonValue(self.allocator, value) else null;
        errdefer if (owned_details) |value| common.deinitJsonValue(self.allocator, value);

        const entry = SessionEntry{
            .custom_message = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .custom_type = try self.allocator.dupe(u8, custom_type),
                .content = owned_content,
                .details = owned_details,
                .display = display,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendSessionInfo(self: *SessionManager, name: []const u8) ![]const u8 {
        try self.ensureDiskNotModified();
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
        const owned_name = if (trimmed.len == 0) null else try self.allocator.dupe(u8, trimmed);
        errdefer if (owned_name) |value| self.allocator.free(value);

        const entry = SessionEntry{
            .session_info = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .name = owned_name,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn getLabel(self: *const SessionManager, id: []const u8) ?[]const u8 {
        return self.labels_by_id.get(id);
    }

    pub fn appendLabelChange(self: *SessionManager, target_id: []const u8, label: ?[]const u8) ![]const u8 {
        try self.ensureDiskNotModified();
        if (self.getEntry(target_id) == null) return error.EntryNotFound;

        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const trimmed = if (label) |value| std.mem.trim(u8, value, &std.ascii.whitespace) else "";
        const owned_label = if (trimmed.len == 0) null else try self.allocator.dupe(u8, trimmed);
        errdefer if (owned_label) |value| self.allocator.free(value);

        const entry = SessionEntry{
            .label = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .target_id = try self.allocator.dupe(u8, target_id),
                .label = owned_label,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn branch(self: *SessionManager, entry_id: []const u8) !void {
        if (self.getEntry(entry_id) == null) return error.EntryNotFound;
        self.leaf_id = entry_id;
    }

    pub fn branchWithSummary(
        self: *SessionManager,
        branch_from_id: ?[]const u8,
        summary: []const u8,
        details: ?std.json.Value,
        from_hook: ?bool,
    ) ![]const u8 {
        try self.ensureDiskNotModified();
        if (branch_from_id) |entry_id| {
            if (self.getEntry(entry_id) == null) return error.EntryNotFound;
        }
        self.leaf_id = branch_from_id;

        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const owned_details = if (details) |value| try common.cloneJsonValue(self.allocator, value) else null;
        errdefer if (owned_details) |value| common.deinitJsonValue(self.allocator, value);

        const entry = SessionEntry{
            .branch_summary = .{
                .id = id,
                .parent_id = if (branch_from_id) |entry_id| try self.allocator.dupe(u8, entry_id) else null,
                .timestamp = timestamp,
                .from_id = try self.allocator.dupe(u8, branch_from_id orelse "root"),
                .summary = try self.allocator.dupe(u8, summary),
                .details = owned_details,
                .from_hook = from_hook,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn resetLeaf(self: *SessionManager) void {
        self.leaf_id = null;
    }

    /// Create a new session manager containing only the path from root to
    /// `leaf_id`. The returned manager owns cloned entries and has a fresh
    /// session id. For persisted managers, it writes a new session file in the
    /// same session directory with the current file recorded as parent.
    pub fn createBranchedSession(self: *const SessionManager, leaf_id: []const u8) !SessionManager {
        const path = try self.getBranch(self.allocator, leaf_id);
        defer self.allocator.free(path);
        if (path.len == 0) return error.EntryNotFound;

        var manager = try initEmpty(
            self.allocator,
            self.io,
            self.getCwd(),
            self.session_dir,
            self.persist,
            if (self.persist) self.session_file else null,
        );
        errdefer manager.deinit();

        for (path) |entry| {
            if (entry.* == .label) continue;
            try manager.appendLoadedEntry(try cloneEntry(self.allocator, entry.*));
        }

        try appendBranchedLabelEntries(self, &manager, path);

        try manager.persistToDisk();
        return manager;
    }

    pub fn buildSessionContext(self: *const SessionManager, allocator: std.mem.Allocator) !SessionContext {
        if (self.leaf_id == null) {
            return .{ .messages = try allocator.alloc(agent.AgentMessage, 0) };
        }

        const branch_entries = try self.getBranch(allocator, null);
        defer allocator.free(branch_entries);

        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer {
            for (messages.items) |*message| deinitMessage(allocator, message);
            messages.deinit(allocator);
        }

        var thinking_level = agent.ThinkingLevel.off;
        var model: ?SessionModelRef = null;
        var latest_compaction: ?*const CompactionEntry = null;

        for (branch_entries) |entry| {
            switch (entry.*) {
                .message => |message_entry| {
                    updateModelFromMessage(&model, message_entry.message);
                },
                .thinking_level_change => |thinking_entry| {
                    thinking_level = thinking_entry.thinking_level;
                },
                .model_change => |model_entry| {
                    model = .{
                        .provider = model_entry.provider,
                        .model_id = model_entry.model_id,
                    };
                },
                .compaction => |*compaction_entry| {
                    latest_compaction = compaction_entry;
                },
                .branch_summary, .custom, .custom_message, .label, .session_info, .active_tools_change => {},
            }
        }

        if (latest_compaction) |compaction_entry| {
            try appendClonedVisibleMessage(&messages, compaction_entry.message, allocator);

            const compaction_index = findEntryIndex(branch_entries, compaction_entry.id) orelse return error.InvalidSessionTree;
            var found_first_kept = false;
            var index: usize = 0;
            while (index < compaction_index) : (index += 1) {
                const entry = branch_entries[index];
                if (std.mem.eql(u8, entry.id(), compaction_entry.first_kept_entry_id)) {
                    found_first_kept = true;
                }
                if (found_first_kept) {
                    try appendContextEntry(&messages, entry.*, allocator, &model);
                }
            }

            index = compaction_index + 1;
            while (index < branch_entries.len) : (index += 1) {
                try appendContextEntry(&messages, branch_entries[index].*, allocator, &model);
            }
        } else {
            for (branch_entries) |entry| {
                try appendContextEntry(&messages, entry.*, allocator, &model);
            }
        }

        return .{
            .messages = try messages.toOwnedSlice(allocator),
            .thinking_level = thinking_level,
            .model = model,
        };
    }

    pub fn getBranch(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        from_id: ?[]const u8,
    ) ![]const *const SessionEntry {
        const start_id = from_id orelse self.leaf_id orelse return try allocator.alloc(*const SessionEntry, 0);
        var current = self.getEntry(start_id) orelse return error.EntryNotFound;

        var reversed = std.ArrayList(*const SessionEntry).empty;
        defer reversed.deinit(allocator);

        while (true) {
            try reversed.append(allocator, current);
            const parent_id = current.parentId() orelse break;
            current = self.getEntry(parent_id) orelse return error.InvalidSessionTree;
        }

        const ordered = try allocator.alloc(*const SessionEntry, reversed.items.len);
        for (reversed.items, 0..) |entry, index| {
            ordered[reversed.items.len - index - 1] = entry;
        }
        return ordered;
    }

    pub fn getTree(self: *const SessionManager, allocator: std.mem.Allocator) ![]SessionTreeNode {
        var roots = std.ArrayList(SessionTreeNode).empty;
        errdefer {
            for (roots.items) |*root| root.deinit(allocator);
            roots.deinit(allocator);
        }

        for (self.entries.items) |*entry| {
            if (entry.parentId() == null) {
                try roots.append(allocator, try self.buildTreeNode(allocator, entry));
            }
        }

        return try roots.toOwnedSlice(allocator);
    }

    pub fn exportJson(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        io: std.Io,
        output_path: []const u8,
    ) !void {
        var entries = std.json.Array.init(allocator);
        errdefer common.deinitJsonValue(allocator, .{ .array = entries });

        for (self.entries.items) |entry| {
            try entries.append(try entryToJsonValue(allocator, entry));
        }

        var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer common.deinitJsonValue(allocator, .{ .object = root });
        try common.putValue(allocator, &root, "header", try headerToJsonValue(allocator, self.header));
        try common.putValue(allocator, &root, "entries", .{ .array = entries });

        const json_value = std.json.Value{ .object = root };
        defer common.deinitJsonValue(allocator, json_value);
        const bytes = try std.json.Stringify.valueAlloc(allocator, json_value, .{ .whitespace = .indent_2 });
        defer allocator.free(bytes);
        try common.writeFileAbsolute(io, output_path, bytes, true);
    }

    fn buildTreeNode(self: *const SessionManager, allocator: std.mem.Allocator, entry: *const SessionEntry) !SessionTreeNode {
        const child_count = self.countChildren(entry.id());
        var children = try allocator.alloc(SessionTreeNode, child_count);
        errdefer allocator.free(children);

        var index: usize = 0;
        for (self.entries.items) |*candidate| {
            const parent_id = candidate.parentId() orelse continue;
            if (!std.mem.eql(u8, parent_id, entry.id())) continue;
            children[index] = try self.buildTreeNode(allocator, candidate);
            index += 1;
        }

        return .{
            .entry = entry,
            .children = children,
            .label = self.labels_by_id.get(entry.id()),
            .label_timestamp = self.label_timestamps_by_id.get(entry.id()),
        };
    }

    fn countChildren(self: *const SessionManager, parent_id: []const u8) usize {
        var count: usize = 0;
        for (self.entries.items) |*entry| {
            const candidate_parent = entry.parentId() orelse continue;
            if (std.mem.eql(u8, candidate_parent, parent_id)) count += 1;
        }
        return count;
    }

    fn appendLoadedEntry(self: *SessionManager, entry: SessionEntry) !void {
        switch (entry) {
            .label => |label_entry| {
                if (label_entry.label) |label| {
                    try self.labels_by_id.put(label_entry.target_id, label);
                    try self.label_timestamps_by_id.put(label_entry.target_id, label_entry.timestamp);
                } else {
                    _ = self.labels_by_id.remove(label_entry.target_id);
                    _ = self.label_timestamps_by_id.remove(label_entry.target_id);
                }
            },
            else => {},
        }
        try self.entries.append(self.allocator, entry);
        const index = self.entries.items.len - 1;
        try self.by_id.put(entry.id(), index);
        self.leaf_id = entry.id();
    }

    fn appendEntry(self: *SessionManager, entry: SessionEntry) !void {
        try self.appendLoadedEntry(entry);
        try self.persistToDiskAfterPreflight();
    }

    /// Forces a full rewrite of the session JSONL file from the in-memory
    /// header and entries.
    pub fn persistToDiskNow(self: *SessionManager) !void {
        try self.persistToDisk();
    }

    fn persistToDisk(self: *SessionManager) !void {
        try self.ensureDiskNotModified();
        try self.persistToDiskAfterPreflight();
    }

    fn persistToDiskAfterPreflight(self: *SessionManager) !void {
        if (!self.persist) return;
        const path = self.session_file orelse return;

        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.allocator);

        const header_line = try stringifyHeaderLine(self.allocator, self.header);
        defer self.allocator.free(header_line);
        try bytes.appendSlice(self.allocator, header_line);
        try bytes.append(self.allocator, '\n');

        for (self.entries.items) |entry| {
            const line = try stringifyEntryLine(self.allocator, entry);
            defer self.allocator.free(line);
            try bytes.appendSlice(self.allocator, line);
            try bytes.append(self.allocator, '\n');
        }

        try common.writeFileAbsolute(self.io, path, bytes.items, true);
        self.last_persisted_hash = std.hash.Wyhash.hash(0, bytes.items);
    }

    fn ensureDiskNotModified(self: *SessionManager) !void {
        if (!self.persist) return;
        const expected_hash = self.last_persisted_hash orelse return;
        const path = self.session_file orelse return;
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), self.io, path, self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return error.SessionConcurrentModification,
            else => return err,
        };
        defer self.allocator.free(bytes);
        if (std.hash.Wyhash.hash(0, bytes) != expected_hash) {
            return error.SessionConcurrentModification;
        }
    }
};

pub fn findMostRecentSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    var best_name: ?[]const u8 = null;
    defer if (best_name) |name| allocator.free(name);

    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        if (best_name == null or std.mem.order(u8, entry.name, best_name.?) == .gt) {
            if (best_name) |previous| allocator.free(previous);
            best_name = try allocator.dupe(u8, entry.name);
        }
    }

    if (best_name) |name| {
        return try std.fs.path.join(allocator, &[_][]const u8{ session_dir, name });
    }

    return null;
}

/// Hard cap on the bytes consumed by `readSessionHeader`. The JSONL header is
/// a single short JSON object describing the session metadata; capping the
/// preflight read keeps the lifecycle preflight bounded even when the session
/// file is multi-megabyte. Mirrors the cap used by the migration first-line
/// reader.
pub const MAX_SESSION_HEADER_BYTES: usize = 64 * 1024;

/// Reads only the first JSONL line of `session_file` and parses it as a
/// `SessionHeader`. Used by lifecycle preflight code that needs the stored
/// cwd before constructing a full session/runtime/provider stack. The read
/// is bounded by `MAX_SESSION_HEADER_BYTES`; if the first line exceeds that
/// cap the function returns `error.InvalidSessionFile` so callers can fall
/// through to the heavier session-manager path. Caller must call
/// `freeSessionHeader` to release the returned strings.
pub fn readSessionHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_file: []const u8,
) !SessionHeader {
    const file = try std.Io.Dir.openFile(.cwd(), io, session_file, .{});
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    defer reader.file.close(io);

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (line.items.len < MAX_SESSION_HEADER_BYTES) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err.?,
        };
        if (byte == '\n') break;
        try line.append(allocator, byte);
    }

    if (line.items.len >= MAX_SESSION_HEADER_BYTES) {
        return error.InvalidSessionFile;
    }
    if (line.items.len == 0) return error.InvalidSessionFile;

    return try parseHeaderLine(allocator, line.items);
}

/// Releases ownership of strings allocated by `readSessionHeader`.
pub fn freeSessionHeader(allocator: std.mem.Allocator, header: *SessionHeader) void {
    deinitHeader(allocator, header);
    header.* = .{
        .id = "",
        .timestamp = "",
        .cwd = "",
        .parent_session = null,
    };
}

pub fn listAllSessionsUnder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
) ![]SessionSearchInfo {
    var sessions = std.ArrayList(SessionSearchInfo).empty;
    errdefer {
        for (sessions.items) |*session| session.deinit(allocator);
        sessions.deinit(allocator);
    }

    collectSessionsUnder(allocator, io, root_dir, &sessions) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    std.mem.sort(SessionSearchInfo, sessions.items, {}, struct {
        fn lessThan(_: void, lhs: SessionSearchInfo, rhs: SessionSearchInfo) bool {
            const modified_order = std.mem.order(u8, lhs.modified_timestamp, rhs.modified_timestamp);
            if (modified_order != .eq) return modified_order == .gt;
            return std.mem.order(u8, lhs.path, rhs.path) == .lt;
        }
    }.lessThan);

    return try sessions.toOwnedSlice(allocator);
}

pub fn searchSessionsUnder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    query: []const u8,
    options: SessionSearchOptions,
) !SessionSearchResults {
    const sessions = try listAllSessionsUnder(allocator, io, root_dir);
    errdefer {
        for (@constCast(sessions)) |*session| session.deinit(allocator);
        allocator.free(@constCast(sessions));
    }

    const matches = try filterAndSortSessions(allocator, sessions, query, options);
    errdefer allocator.free(matches);

    return .{
        .sessions = sessions,
        .matches = matches,
    };
}

fn collectSessionsUnder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    sessions: *std.ArrayList(SessionSearchInfo),
) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, root_dir, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &[_][]const u8{ root_dir, entry.name });
        defer allocator.free(child_path);

        switch (entry.kind) {
            .directory => try collectSessionsUnder(allocator, io, child_path, sessions),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
                const session_info = buildSessionSearchInfo(allocator, io, child_path) catch continue;
                try sessions.append(allocator, session_info);
            },
            else => {},
        }
    }
}

fn buildSessionSearchInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_file: []const u8,
) !SessionSearchInfo {
    var manager = try SessionManager.openWithWarningWriter(allocator, io, session_file, null, null);
    defer manager.deinit();

    const header = manager.getHeader();

    var all_messages = std.ArrayList(u8).empty;
    defer all_messages.deinit(allocator);

    var first_message: ?[]u8 = null;
    defer if (first_message) |message| allocator.free(message);

    var message_count: usize = 0;
    var modified_timestamp = header.timestamp;

    for (manager.getEntries()) |entry| {
        modified_timestamp = entry.timestamp();

        switch (entry) {
            .message => |message_entry| {
                message_count += 1;
                try appendMessageSearchText(&all_messages, allocator, message_entry.message);

                if (first_message == null and message_entry.message == .user) {
                    first_message = try blocksToSearchTextAlloc(allocator, message_entry.message.user.content);
                }
            },
            .compaction => |compaction_entry| try appendMessageSearchText(&all_messages, allocator, compaction_entry.message),
            .branch_summary => |branch_summary_entry| try appendSearchText(&all_messages, allocator, branch_summary_entry.summary),
            .custom_message => |custom_message_entry| try appendCustomMessageContentSearchText(&all_messages, allocator, custom_message_entry.content),
            else => {},
        }
    }

    const owned_name = if (manager.getSessionName()) |name| try allocator.dupe(u8, name) else null;
    errdefer if (owned_name) |name| allocator.free(name);

    const owned_path = try allocator.dupe(u8, session_file);
    errdefer allocator.free(owned_path);
    const owned_id = try allocator.dupe(u8, header.id);
    errdefer allocator.free(owned_id);
    const owned_cwd = try allocator.dupe(u8, header.cwd);
    errdefer allocator.free(owned_cwd);
    const owned_parent_session = if (header.parent_session) |parent_session|
        try allocator.dupe(u8, parent_session)
    else
        null;
    errdefer if (owned_parent_session) |parent_session| allocator.free(parent_session);
    const owned_created = try allocator.dupe(u8, header.timestamp);
    errdefer allocator.free(owned_created);
    const owned_modified = try allocator.dupe(u8, modified_timestamp);
    errdefer allocator.free(owned_modified);
    const owned_first_message = if (first_message) |message|
        try allocator.dupe(u8, message)
    else
        try allocator.dupe(u8, "(no messages)");
    errdefer allocator.free(owned_first_message);
    const owned_all_messages = try allocator.dupe(u8, all_messages.items);
    errdefer allocator.free(owned_all_messages);
    const search_text = try std.fmt.allocPrint(
        allocator,
        "{s} {s} {s} {s}",
        .{
            header.id,
            owned_name orelse "",
            all_messages.items,
            header.cwd,
        },
    );
    errdefer allocator.free(search_text);

    return .{
        .path = owned_path,
        .id = owned_id,
        .cwd = owned_cwd,
        .name = owned_name,
        .parent_session = owned_parent_session,
        .created_timestamp = owned_created,
        .modified_timestamp = owned_modified,
        .message_count = message_count,
        .first_message = owned_first_message,
        .all_messages_text = owned_all_messages,
        .search_text = search_text,
    };
}

fn appendMessageSearchText(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    message: agent.AgentMessage,
) !void {
    switch (message) {
        .user => |user_message| try appendContentBlocksSearchText(out, allocator, user_message.content),
        .assistant => |assistant_message| try appendContentBlocksSearchText(out, allocator, assistant_message.content),
        .tool_result => |tool_result| try appendContentBlocksSearchText(out, allocator, tool_result.content),
    }
}

fn appendCustomMessageContentSearchText(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    content: CustomMessageContent,
) !void {
    switch (content) {
        .text => |text| try appendSearchText(out, allocator, text),
        .blocks => |blocks| try appendContentBlocksSearchText(out, allocator, blocks),
    }
}

fn appendContentBlocksSearchText(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    blocks: []const ai.ContentBlock,
) !void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| try appendSearchText(out, allocator, text.text),
            .thinking => |thinking| try appendSearchText(out, allocator, thinking.thinking),
            .tool_call => |tool_call| try appendSearchText(out, allocator, tool_call.name),
            .image => {},
        }
    }
}

fn appendSearchText(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, ' ');
    try out.appendSlice(allocator, trimmed);
}

fn blocksToSearchTextAlloc(
    allocator: std.mem.Allocator,
    blocks: []const ai.ContentBlock,
) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendContentBlocksSearchText(&out, allocator, blocks);
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn initEmpty(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    session_dir: []const u8,
    persist: bool,
    parent_session: ?[]const u8,
) !SessionManager {
    const session_id = try generateSessionId(allocator);
    errdefer allocator.free(session_id);

    const timestamp = try nowTimestamp(allocator, io);
    errdefer allocator.free(timestamp);

    const session_dir_copy = try allocator.dupe(u8, session_dir);
    errdefer allocator.free(session_dir_copy);

    const session_file = if (persist)
        try buildSessionFilePath(allocator, session_dir, timestamp, session_id)
    else
        null;
    errdefer if (session_file) |path| allocator.free(path);

    const header_cwd = try allocator.dupe(u8, cwd);
    errdefer allocator.free(header_cwd);

    const runtime_cwd = try allocator.dupe(u8, cwd);
    errdefer allocator.free(runtime_cwd);

    const parent_session_copy = if (parent_session) |path| try allocator.dupe(u8, path) else null;
    errdefer if (parent_session_copy) |path| allocator.free(path);

    return .{
        .allocator = allocator,
        .io = io,
        .header = .{
            .id = session_id,
            .timestamp = timestamp,
            .cwd = header_cwd,
            .parent_session = parent_session_copy,
        },
        .runtime_cwd = runtime_cwd,
        .session_dir = session_dir_copy,
        .session_file = session_file,
        .persist = persist,
        .entries = .empty,
        .by_id = std.StringHashMap(usize).init(allocator),
        .labels_by_id = std.StringHashMap([]const u8).init(allocator),
        .label_timestamps_by_id = std.StringHashMap([]const u8).init(allocator),
        .leaf_id = null,
        .last_persisted_hash = null,
    };
}

fn branchContainsEntry(branch: []const *const SessionEntry, id: []const u8) bool {
    for (branch) |entry| {
        if (std.mem.eql(u8, entry.id(), id)) return true;
    }
    return false;
}

fn orderedLabelTargetIndex(targets: []const []const u8, target_id: []const u8) ?usize {
    for (targets, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, target_id)) return index;
    }
    return null;
}

fn appendBranchedLabelEntries(
    source: *const SessionManager,
    manager: *SessionManager,
    branch_path: []const *const SessionEntry,
) !void {
    var ordered_targets = std.ArrayList([]const u8).empty;
    defer ordered_targets.deinit(source.allocator);

    for (source.entries.items) |entry| {
        if (entry != .label) continue;
        const label_entry = entry.label;
        if (!branchContainsEntry(branch_path, label_entry.target_id)) continue;

        if (label_entry.label == null) {
            if (orderedLabelTargetIndex(ordered_targets.items, label_entry.target_id)) |index| {
                _ = ordered_targets.orderedRemove(index);
            }
            continue;
        }

        if (orderedLabelTargetIndex(ordered_targets.items, label_entry.target_id) == null) {
            try ordered_targets.append(source.allocator, label_entry.target_id);
        }
    }

    for (ordered_targets.items) |target_id| {
        const resolved_label = source.labels_by_id.get(target_id) orelse continue;
        const label_timestamp = source.label_timestamps_by_id.get(target_id) orelse continue;

        var id: ?[]u8 = try generateUniqueId(manager.allocator, &manager.by_id);
        errdefer if (id) |value| manager.allocator.free(value);

        var parent_id: ?[]u8 = if (manager.leaf_id) |leaf_id| try manager.allocator.dupe(u8, leaf_id) else null;
        errdefer if (parent_id) |value| manager.allocator.free(value);

        var timestamp: ?[]u8 = try manager.allocator.dupe(u8, label_timestamp);
        errdefer if (timestamp) |value| manager.allocator.free(value);

        var owned_target_id: ?[]u8 = try manager.allocator.dupe(u8, target_id);
        errdefer if (owned_target_id) |value| manager.allocator.free(value);

        var owned_label: ?[]u8 = try manager.allocator.dupe(u8, resolved_label);
        errdefer if (owned_label) |value| manager.allocator.free(value);

        var entry = SessionEntry{ .label = .{
            .id = id.?,
            .parent_id = parent_id,
            .timestamp = timestamp.?,
            .target_id = owned_target_id.?,
            .label = owned_label,
        } };
        id = null;
        parent_id = null;
        timestamp = null;
        owned_target_id = null;
        owned_label = null;

        var committed = false;
        errdefer if (!committed) deinitEntry(manager.allocator, &entry);
        try manager.appendLoadedEntry(entry);
        committed = true;
    }
}

fn updateModelFromMessage(model: *?SessionModelRef, message: agent.AgentMessage) void {
    switch (message) {
        .assistant => |assistant_message| {
            model.* = .{
                .api = assistant_message.api,
                .provider = assistant_message.provider,
                .model_id = assistant_message.model,
            };
        },
        else => {},
    }
}

fn appendContextEntry(
    messages: *std.ArrayList(agent.AgentMessage),
    entry: SessionEntry,
    allocator: std.mem.Allocator,
    model: *?SessionModelRef,
) !void {
    switch (entry) {
        .message => |message_entry| {
            updateModelFromMessage(model, message_entry.message);
            try appendClonedVisibleMessage(messages, message_entry.message, allocator);
        },
        .branch_summary => |branch_summary_entry| {
            var message = try createBranchSummaryContextMessage(
                allocator,
                branch_summary_entry.summary,
                branch_summary_entry.timestamp,
            );
            errdefer deinitMessage(allocator, &message);
            try appendOwnedVisibleMessage(messages, allocator, message);
        },
        .custom_message => |custom_message_entry| {
            if (customMessageExcludedFromContext(custom_message_entry)) return;
            var message = try createCustomContextMessage(
                allocator,
                custom_message_entry.content,
                custom_message_entry.timestamp,
            );
            errdefer deinitMessage(allocator, &message);
            try appendOwnedVisibleMessage(messages, allocator, message);
        },
        .thinking_level_change,
        .model_change,
        .active_tools_change,
        .compaction,
        .custom,
        .label,
        .session_info,
        => {},
    }
}

fn customMessageExcludedFromContext(entry: CustomMessageEntry) bool {
    if (!std.mem.eql(u8, entry.custom_type, "bashExecution")) return false;
    const details = entry.details orelse return false;
    if (details != .object) return false;
    const value = details.object.get("excludeFromContext") orelse return false;
    return value == .bool and value.bool;
}

fn appendClonedVisibleMessage(
    messages: *std.ArrayList(agent.AgentMessage),
    message: agent.AgentMessage,
    allocator: std.mem.Allocator,
) !void {
    var owned = try cloneMessage(allocator, message);
    errdefer deinitMessage(allocator, &owned);
    try appendOwnedVisibleMessage(messages, allocator, owned);
}

fn appendOwnedVisibleMessage(
    messages: *std.ArrayList(agent.AgentMessage),
    allocator: std.mem.Allocator,
    message: agent.AgentMessage,
) !void {
    var owned = message;
    switch (message) {
        .assistant => |assistant_message| {
            if (assistant_message.stop_reason == .error_reason or assistant_message.stop_reason == .aborted) {
                deinitMessage(allocator, &owned);
                return;
            }
        },
        else => {},
    }
    try messages.append(allocator, owned);
}

fn createBranchSummaryContextMessage(
    allocator: std.mem.Allocator,
    summary: []const u8,
    timestamp: []const u8,
) !agent.AgentMessage {
    const text = try std.fmt.allocPrint(
        allocator,
        "{s}{s}\n{s}",
        .{ BRANCH_SUMMARY_PREFIX, summary, BRANCH_SUMMARY_SUFFIX },
    );
    errdefer allocator.free(text);
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = text } };
    return .{ .user = .{
        .role = try allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = parseContextTimestamp(timestamp),
    } };
}

fn createCustomContextMessage(
    allocator: std.mem.Allocator,
    content: CustomMessageContent,
    timestamp: []const u8,
) !agent.AgentMessage {
    return .{ .user = .{
        .role = try allocator.dupe(u8, "user"),
        .content = switch (content) {
            .text => |text| try common.makeTextContent(allocator, text),
            .blocks => |blocks| try cloneContentBlocks(allocator, blocks),
        },
        .timestamp = parseContextTimestamp(timestamp),
    } };
}

fn parseContextTimestamp(timestamp: []const u8) i64 {
    return std.fmt.parseInt(i64, timestamp, 10) catch 0;
}

fn findEntryIndex(entries: []const *const SessionEntry, id: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id(), id)) return index;
    }
    return null;
}

fn buildSessionFilePath(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    timestamp: []const u8,
    session_id: []const u8,
) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}_{s}.jsonl", .{ timestamp, session_id });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &[_][]const u8{ session_dir, filename });
}

fn deriveSessionDir(allocator: std.mem.Allocator, session_file: []const u8) ![]u8 {
    const dirname = std.fs.path.dirname(session_file) orelse ".";
    return allocator.dupe(u8, dirname);
}

fn nowTimestamp(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const nanos = std.Io.Clock.now(.real, io).nanoseconds;
    return std.fmt.allocPrint(allocator, "{d}", .{nanos});
}

fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    const counter = global_id_counter.fetchAdd(1, .seq_cst);
    return std.fmt.allocPrint(allocator, "{d}-{d}", .{ counter, counter + 1 });
}

fn generateUniqueId(allocator: std.mem.Allocator, by_id: *const std.StringHashMap(usize)) ![]u8 {
    while (true) {
        const counter = global_id_counter.fetchAdd(1, .seq_cst);
        const candidate = try std.fmt.allocPrint(allocator, "{x:0>8}", .{counter});
        if (!by_id.contains(candidate)) return candidate;
        allocator.free(candidate);
    }
}

fn logCorruptedSessionLine(
    writer: *std.Io.Writer,
    session_file: []const u8,
    line_number: usize,
    err: anyerror,
) !void {
    try writer.print(
        "Warning: skipped corrupted session line {d} in {s}: {s}\n",
        .{ line_number, session_file, @errorName(err) },
    );
}

fn logCorruptedSessionDataLoss(
    writer: *std.Io.Writer,
    session_file: []const u8,
    skipped_corrupted_lines: usize,
) !void {
    try writer.print(
        "Warning: loaded session {s} with {d} corrupted line{s} skipped; valid entries were preserved but some session data was lost.\n",
        .{
            session_file,
            skipped_corrupted_lines,
            if (skipped_corrupted_lines == 1) "" else "s",
        },
    );
}

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn userTextMessage(allocator: std.mem.Allocator, text: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .user = .{
        .role = try allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = timestamp,
    } };
}

fn assistantTextMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    model: ai.Model,
    timestamp: i64,
) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .assistant = .{
        .role = try allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try allocator.dupe(u8, model.api),
        .provider = try allocator.dupe(u8, model.provider),
        .model = try allocator.dupe(u8, model.id),
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

fn toolResultTextMessage(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
    timestamp: i64,
) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .tool_result = .{
        .role = try allocator.dupe(u8, "toolResult"),
        .tool_call_id = try allocator.dupe(u8, tool_call_id),
        .tool_name = try allocator.dupe(u8, tool_name),
        .content = blocks,
        .details = null,
        .is_error = false,
        .timestamp = timestamp,
    } };
}

fn sessionSearchTestModel() ai.Model {
    return .{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
}

fn countJsonLines(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn parseJsonTestValue(allocator: std.mem.Allocator, json: []const u8) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    return try common.cloneJsonValue(allocator, parsed.value);
}

test "readSessionHeader reads only the JSONL header without loading entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/preflight", session_dir);
    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);
    const expected_id = try std.testing.allocator.dupe(u8, manager.getSessionId());
    defer std.testing.allocator.free(expected_id);
    manager.deinit();

    var header = try readSessionHeader(std.testing.allocator, std.testing.io, session_file);
    defer freeSessionHeader(std.testing.allocator, &header);
    try std.testing.expectEqualStrings("/tmp/preflight", header.cwd);
    try std.testing.expectEqualStrings(expected_id, header.id);
    try std.testing.expect(header.parent_session == null);
}

test "readSessionHeader returns error.FileNotFound for missing files" {
    const result = readSessionHeader(std.testing.allocator, std.testing.io, "/tmp/this/does/not/exist.jsonl");
    try std.testing.expectError(error.FileNotFound, result);
}

test "readSessionHeader is bounded and ignores oversized session bodies" {
    // Builds a JSONL file whose header line is small but whose body is
    // significantly larger than `MAX_SESSION_HEADER_BYTES`. The bounded
    // preflight read must successfully parse the header without loading the
    // entire body, regardless of trailing content size.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(allocator, relative_dir);
    defer allocator.free(session_dir);

    var manager = try SessionManager.create(allocator, std.testing.io, "/tmp/preflight-bounded", session_dir);
    const session_file = try allocator.dupe(u8, manager.getSessionFile().?);
    defer allocator.free(session_file);
    manager.deinit();

    // Append an enormous body line (>= MAX_SESSION_HEADER_BYTES) to confirm
    // that the bounded read does not allocate the whole file.
    const original_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(original_bytes);

    const oversize_payload_len = MAX_SESSION_HEADER_BYTES * 8;
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(allocator);
    try rebuilt.appendSlice(allocator, original_bytes);
    if (rebuilt.items.len == 0 or rebuilt.items[rebuilt.items.len - 1] != '\n') {
        try rebuilt.append(allocator, '\n');
    }
    // A single huge non-header line. The preflight must stop at the header
    // newline that precedes it.
    try rebuilt.appendNTimes(allocator, 'X', oversize_payload_len);
    try rebuilt.append(allocator, '\n');
    try common.writeFileAbsolute(std.testing.io, session_file, rebuilt.items, true);

    var header = try readSessionHeader(allocator, std.testing.io, session_file);
    defer freeSessionHeader(allocator, &header);
    try std.testing.expectEqualStrings("/tmp/preflight-bounded", header.cwd);
}

test "readSessionHeader returns InvalidSessionFile when first line exceeds the byte cap" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer allocator.free(relative_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, relative_dir);
    const session_file = try std.fs.path.join(allocator, &[_][]const u8{ relative_dir, "oversized.jsonl" });
    defer allocator.free(session_file);

    // Build a synthetic >cap first line with no newline before the cap.
    var oversize: std.ArrayList(u8) = .empty;
    defer oversize.deinit(allocator);
    try oversize.appendNTimes(allocator, 'A', MAX_SESSION_HEADER_BYTES + 16);

    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = session_file,
        .data = oversize.items,
    });

    const result = readSessionHeader(allocator, std.testing.io, session_file);
    try std.testing.expectError(error.InvalidSessionFile, result);
}

test "session manager creates empty session with metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    try std.testing.expectEqualStrings("/tmp/project", manager.getCwd());
    try std.testing.expect(manager.getSessionFile() != null);
    try std.testing.expectEqual(@as(usize, 0), manager.getEntries().len);
    try std.testing.expect(manager.getLeafId() == null);
    try std.testing.expectEqual(CURRENT_SESSION_VERSION, CURRENT_SESSION_VERSION);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, manager.getSessionFile().?, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    try std.testing.expect(countJsonLines(written) == 1);
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"type\":\"session\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"cwd\":\"/tmp/project\""));
}

test "session manager persists messages to jsonl and resumes from disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    _ = try manager.appendMessage(user);

    var assistant = try assistantTextMessage(std.testing.allocator, "world", model, 2);
    defer deinitMessage(std.testing.allocator, &assistant);
    _ = try manager.appendMessage(assistant);

    const tool_result_timestamp = agent.nowMilliseconds();
    try std.testing.expect(tool_result_timestamp > 0);
    var tool_result = try toolResultTextMessage(std.testing.allocator, "tool-1", "bash", "tool output", tool_result_timestamp);
    defer deinitMessage(std.testing.allocator, &tool_result);
    _ = try manager.appendMessage(tool_result);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqual(@as(usize, 4), countJsonLines(written));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"user\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"assistant\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"toolResult\""));

    var reopened = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("world", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("tool output", context.messages[2].tool_result.content[0].text.text);
    try std.testing.expectEqual(tool_result_timestamp, context.messages[2].tool_result.timestamp);
    try std.testing.expectEqualStrings("faux", context.model.?.provider);
    try std.testing.expectEqualStrings("faux-session", context.model.?.model_id);
}

test "session manager denies stale concurrent persisted writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    var first = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer first.deinit();
    const session_file = try std.testing.allocator.dupe(u8, first.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    var second = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer second.deinit();

    var first_user = try userTextMessage(std.testing.allocator, "first writer", 1);
    defer deinitMessage(std.testing.allocator, &first_user);
    _ = try first.appendMessage(first_user);

    var second_user = try userTextMessage(std.testing.allocator, "stale writer", 2);
    defer deinitMessage(std.testing.allocator, &second_user);
    try std.testing.expectError(error.SessionConcurrentModification, second.appendMessage(second_user));

    var reopened = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer reopened.deinit();
    var context = try reopened.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), context.messages.len);
    try std.testing.expectEqualStrings("first writer", context.messages[0].user.content[0].text.text);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "first writer") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "stale writer") == null);
}

test "session context excludes aborted assistant messages from replay" {
    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var manager = try SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    _ = try manager.appendMessage(user);

    var aborted = try assistantTextMessage(std.testing.allocator, "partial signed output", model, 2);
    defer deinitMessage(std.testing.allocator, &aborted);
    aborted.assistant.stop_reason = .aborted;
    aborted.assistant.error_message = try std.testing.allocator.dupe(u8, "aborted");
    _ = try manager.appendMessage(aborted);

    var next = try userTextMessage(std.testing.allocator, "continue", 3);
    defer deinitMessage(std.testing.allocator, &next);
    _ = try manager.appendMessage(next);

    var context = try manager.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("continue", context.messages[1].user.content[0].text.text);
}

test "session manager persists session names and labels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    const user_id = try manager.appendMessage(user);

    _ = try manager.appendSessionInfo("Night Shift");
    _ = try manager.appendLabelChange(user_id, "bookmark");

    try std.testing.expectEqualStrings("Night Shift", manager.getSessionName().?);
    try std.testing.expectEqualStrings("bookmark", manager.getLabel(user_id).?);

    const tree = try manager.getTree(std.testing.allocator);
    defer {
        for (tree) |*node| node.deinit(std.testing.allocator);
        std.testing.allocator.free(tree);
    }

    try std.testing.expectEqual(@as(usize, 1), tree.len);
    try std.testing.expectEqualStrings("bookmark", tree[0].label.?);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"session_info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"name\":\"Night Shift\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"label\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"label\":\"bookmark\"") != null);

    var reopened = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer reopened.deinit();

    try std.testing.expectEqualStrings("Night Shift", reopened.getSessionName().?);
    try std.testing.expectEqualStrings("bookmark", reopened.getLabel(user_id).?);
}

test "session manager createBranchedSession recreates label parent chain from branch tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var first = try userTextMessage(std.testing.allocator, "first", 1);
    defer deinitMessage(std.testing.allocator, &first);
    const first_id = try manager.appendMessage(first);

    var second = try assistantTextMessage(std.testing.allocator, "second", model, 2);
    defer deinitMessage(std.testing.allocator, &second);
    const second_id = try manager.appendMessage(second);

    var third = try userTextMessage(std.testing.allocator, "third", 3);
    defer deinitMessage(std.testing.allocator, &third);
    _ = try manager.appendMessage(third);

    const obsolete_first_label_id = try manager.appendLabelChange(first_id, "first draft");
    const second_label_id = try manager.appendLabelChange(second_id, "second label");
    const final_first_label_id = try manager.appendLabelChange(first_id, "first final");

    var branched = try manager.createBranchedSession(second_id);
    defer branched.deinit();

    const entries = branched.getEntries();
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expect(entries[0] == .message);
    try std.testing.expect(entries[1] == .message);
    try std.testing.expect(entries[2] == .label);
    try std.testing.expect(entries[3] == .label);
    try std.testing.expectEqualStrings(first_id, entries[0].message.id);
    try std.testing.expectEqualStrings(second_id, entries[1].message.id);

    try std.testing.expect(entries[2].label.parent_id != null);
    try std.testing.expectEqualStrings(second_id, entries[2].label.parent_id.?);
    try std.testing.expectEqualStrings(first_id, entries[2].label.target_id);
    try std.testing.expectEqualStrings("first final", entries[2].label.label.?);
    try std.testing.expect(!std.mem.eql(u8, obsolete_first_label_id, entries[2].label.id));
    try std.testing.expect(!std.mem.eql(u8, final_first_label_id, entries[2].label.id));

    try std.testing.expect(entries[3].label.parent_id != null);
    try std.testing.expectEqualStrings(entries[2].label.id, entries[3].label.parent_id.?);
    try std.testing.expectEqualStrings(second_id, entries[3].label.target_id);
    try std.testing.expectEqualStrings("second label", entries[3].label.label.?);
    try std.testing.expect(!std.mem.eql(u8, second_label_id, entries[3].label.id));

    try std.testing.expectEqualStrings("first final", branched.getLabel(first_id).?);
    try std.testing.expectEqualStrings("second label", branched.getLabel(second_id).?);
}

test "session manager persists branch summaries and custom entry types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    const user_id = try manager.appendMessage(user);

    const custom_data = try parseJsonTestValue(std.testing.allocator, "{\"step\":1,\"state\":\"warm\"}");
    defer common.deinitJsonValue(std.testing.allocator, custom_data);
    _ = try manager.appendCustomEntry("ext.state", custom_data);

    const custom_details = try parseJsonTestValue(std.testing.allocator, "{\"visible\":true}");
    defer common.deinitJsonValue(std.testing.allocator, custom_details);
    _ = try manager.appendCustomMessageEntry(
        "ext.note",
        .{ .text = "remember this branch" },
        true,
        custom_details,
    );

    const branch_details = try parseJsonTestValue(std.testing.allocator, "{\"files\":[\"a.txt\",\"b.txt\"]}");
    defer common.deinitJsonValue(std.testing.allocator, branch_details);
    const summary_id = try manager.branchWithSummary(manager.getLeafId(), "branched away from alternate draft", branch_details, true);

    _ = try manager.appendLabelChange(user_id, "bookmark");
    _ = try manager.appendSessionInfo("Night Shift");

    var context = try manager.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("remember this branch", context.messages[1].user.content[0].text.text);
    try std.testing.expect(std.mem.indexOf(u8, context.messages[2].user.content[0].text.text, "branched away from alternate draft") != null);

    try std.testing.expectEqualStrings("Night Shift", manager.getSessionName().?);
    try std.testing.expectEqualStrings("bookmark", manager.getLabel(user_id).?);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"custom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"custom_message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"branch_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"customType\":\"ext.note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"fromHook\":true") != null);

    var reopened = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer reopened.deinit();

    try std.testing.expectEqualStrings("Night Shift", reopened.getSessionName().?);
    try std.testing.expectEqualStrings("bookmark", reopened.getLabel(user_id).?);

    const reopened_summary = reopened.getEntry(summary_id);
    try std.testing.expect(reopened_summary != null);
    try std.testing.expect(reopened_summary.?.* == .branch_summary);
    try std.testing.expectEqualStrings("branched away from alternate draft", reopened_summary.?.branch_summary.summary);
    try std.testing.expectEqual(true, reopened_summary.?.branch_summary.from_hook.?);

    const entries = reopened.getEntries();
    try std.testing.expectEqual(@as(usize, 6), entries.len);
    try std.testing.expect(entries[1] == .custom);
    try std.testing.expect(entries[2] == .custom_message);
    try std.testing.expect(entries[3] == .branch_summary);

    var reopened_context = try reopened.buildSessionContext(std.testing.allocator);
    defer reopened_context.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), reopened_context.messages.len);
    try std.testing.expect(std.mem.indexOf(u8, reopened_context.messages[2].user.content[0].text.text, BRANCH_SUMMARY_PREFIX) != null);
}

test "session manager replays sub-agent readiness records as data only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/subagent-project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "delegate safely", 1);
    defer deinitMessage(std.testing.allocator, &user);
    const user_id = try manager.appendMessage(user);

    const readiness_data = try parseJsonTestValue(
        std.testing.allocator,
        "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"taskId\":\"task-opaque\",\"sessionId\":\"session-opaque\",\"parentRunId\":\"parent-run\",\"parentSessionId\":\"parent-session\",\"input\":{\"text\":\"summarize\"},\"limits\":{\"maxChildren\":0,\"depth\":1,\"turns\":3,\"timeoutMs\":2500,\"outputBytes\":4096,\"outputLines\":80,\"toolScopes\":[\"read-only\"]},\"cancellation\":{\"signalId\":\"cancel-1\",\"state\":\"pending\",\"parentRunId\":\"parent-run\",\"parentTaskId\":\"parent-task\"}}",
    );
    defer common.deinitJsonValue(std.testing.allocator, readiness_data);
    const readiness_id = try manager.appendCustomEntry("sub_agent.readiness", readiness_data);

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
    var assistant = try assistantTextMessage(std.testing.allocator, "readiness metadata recorded", model, 2);
    defer deinitMessage(std.testing.allocator, &assistant);
    _ = try manager.appendMessage(assistant);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"customType\":\"sub_agent.readiness\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"sub_agent_task_invocation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"spawnPolicy\"") == null);

    var reopened = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer reopened.deinit();

    const readiness_entry = reopened.getEntry(readiness_id);
    try std.testing.expect(readiness_entry != null);
    try std.testing.expect(readiness_entry.?.* == .custom);
    try std.testing.expectEqualStrings(readiness_id, readiness_entry.?.custom.id);
    try std.testing.expectEqualStrings("sub_agent.readiness", readiness_entry.?.custom.custom_type);
    try std.testing.expectEqualStrings(user_id, readiness_entry.?.custom.parent_id.?);
    try std.testing.expect(readiness_entry.?.custom.timestamp.len > 0);
    try std.testing.expect(readiness_entry.?.custom.data != null);
    const data_object = readiness_entry.?.custom.data.?.object;
    try std.testing.expectEqualStrings("sub_agent_task_invocation", data_object.get("type").?.string);
    try std.testing.expectEqualStrings("task-opaque", data_object.get("taskId").?.string);
    try std.testing.expectEqualStrings("parent-session", data_object.get("parentSessionId").?.string);
    try std.testing.expectEqualStrings("parent-run", data_object.get("parentRunId").?.string);
    try std.testing.expectEqualStrings("pending", data_object.get("cancellation").?.object.get("state").?.string);

    var context = try reopened.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("delegate safely", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("readiness metadata recorded", context.messages[1].assistant.content[0].text.text);
}

test "session manager logs corrupted lines while preserving valid entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    _ = try manager.appendMessage(user);

    var assistant = try assistantTextMessage(std.testing.allocator, "world", model, 2);
    defer deinitMessage(std.testing.allocator, &assistant);
    _ = try manager.appendMessage(assistant);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(std.testing.allocator);

    var lines = std.mem.splitScalar(u8, written, '\n');
    const header_line = lines.next().?;
    const user_line = lines.next().?;
    const assistant_line = lines.next().?;

    try rebuilt.appendSlice(std.testing.allocator, header_line);
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, user_line);
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, "{\"type\":\"corrupted\"}");
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, assistant_line);
    try rebuilt.append(std.testing.allocator, '\n');

    try common.writeFileAbsolute(std.testing.io, session_file, rebuilt.items, true);

    var warning_capture: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer warning_capture.deinit();

    var reopened = try SessionManager.openWithWarningWriter(
        std.testing.allocator,
        std.testing.io,
        session_file,
        null,
        &warning_capture.writer,
    );
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("world", context.messages[1].assistant.content[0].text.text);

    const warnings = warning_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, warnings, "line 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "UnsupportedSessionEntryType") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "data was lost") != null);
}

test "session manager skips invalid json shapes without panicking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    _ = try manager.appendMessage(user);

    var assistant = try assistantTextMessage(std.testing.allocator, "world", model, 2);
    defer deinitMessage(std.testing.allocator, &assistant);
    _ = try manager.appendMessage(assistant);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(std.testing.allocator);

    var lines = std.mem.splitScalar(u8, written, '\n');
    const header_line = lines.next().?;
    const user_line = lines.next().?;
    const assistant_line = lines.next().?;

    try rebuilt.appendSlice(std.testing.allocator, header_line);
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, user_line);
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(
        std.testing.allocator,
        "{\"type\":\"message\",\"id\":\"bad-object\",\"parentId\":null,\"timestamp\":\"2026-04-25T00:00:00.000Z\",\"message\":[]}",
    );
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(
        std.testing.allocator,
        "{\"type\":\"message\",\"id\":\"bad-array\",\"parentId\":\"bad-object\",\"timestamp\":\"2026-04-25T00:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"oops\"},\"api\":\"faux\",\"provider\":\"faux\",\"model\":\"faux-session\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0},\"stopReason\":\"stop\",\"timestamp\":2}}",
    );
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, assistant_line);
    try rebuilt.append(std.testing.allocator, '\n');

    try common.writeFileAbsolute(std.testing.io, session_file, rebuilt.items, true);

    var warning_capture: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer warning_capture.deinit();

    var reopened = try SessionManager.openWithWarningWriter(
        std.testing.allocator,
        std.testing.io,
        session_file,
        null,
        &warning_capture.writer,
    );
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("world", context.messages[1].assistant.content[0].text.text);

    const warnings = warning_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, warnings, "line 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "line 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "InvalidSessionFile") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "2 corrupted lines skipped") != null);
}

test "session manager supports branching and branch navigation" {
    var manager = try SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    defer manager.deinit();

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var first = try userTextMessage(std.testing.allocator, "first", 1);
    defer deinitMessage(std.testing.allocator, &first);
    const first_id = try manager.appendMessage(first);

    var second = try assistantTextMessage(std.testing.allocator, "second", model, 2);
    defer deinitMessage(std.testing.allocator, &second);
    const second_id = try manager.appendMessage(second);

    var third = try userTextMessage(std.testing.allocator, "third", 3);
    defer deinitMessage(std.testing.allocator, &third);
    _ = try manager.appendMessage(third);

    try manager.branch(first_id);

    var alternate = try userTextMessage(std.testing.allocator, "alternate", 4);
    defer deinitMessage(std.testing.allocator, &alternate);
    const alternate_id = try manager.appendMessage(alternate);

    var branch = try manager.getBranch(std.testing.allocator, null);
    defer std.testing.allocator.free(branch);

    try std.testing.expectEqual(@as(usize, 2), branch.len);
    try std.testing.expectEqualStrings(first_id, branch[0].id());
    try std.testing.expectEqualStrings(alternate_id, branch[1].id());

    var tree = try manager.getTree(std.testing.allocator);
    defer {
        for (tree) |*root| root.deinit(std.testing.allocator);
        std.testing.allocator.free(tree);
    }

    try std.testing.expectEqual(@as(usize, 1), tree.len);
    try std.testing.expectEqualStrings(first_id, tree[0].entry.id());
    try std.testing.expectEqual(@as(usize, 2), tree[0].children.len);
    try std.testing.expectEqualStrings(second_id, tree[0].children[0].entry.id());
    try std.testing.expectEqualStrings(alternate_id, tree[0].children[1].entry.id());

    try manager.branch(second_id);
    var resumed_branch = try manager.buildSessionContext(std.testing.allocator);
    defer resumed_branch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), resumed_branch.messages.len);
    try std.testing.expectEqualStrings("second", resumed_branch.messages[1].assistant.content[0].text.text);
}

test "session search scans all session files and ranks name and content matches by relevance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_relative = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "search-root",
    });
    defer std.testing.allocator.free(root_relative);
    const search_root = try makeAbsoluteTestPath(std.testing.allocator, root_relative);
    defer std.testing.allocator.free(search_root);

    const project_a_sessions = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        search_root,
        "project-a",
        ".pi",
        "sessions",
    });
    defer std.testing.allocator.free(project_a_sessions);
    const project_b_sessions = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        search_root,
        "project-b",
        ".pi",
        "sessions",
    });
    defer std.testing.allocator.free(project_b_sessions);

    const model = sessionSearchTestModel();

    var night_shift = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project-a", project_a_sessions);
    defer night_shift.deinit();
    _ = try night_shift.appendSessionInfo("Night Shift");

    var night_shift_user = try userTextMessage(std.testing.allocator, "investigate auth timeout", 1);
    defer deinitMessage(std.testing.allocator, &night_shift_user);
    _ = try night_shift.appendMessage(night_shift_user);

    var night_shift_assistant = try assistantTextMessage(std.testing.allocator, "auth retry fixed after inspecting logs", model, 2);
    defer deinitMessage(std.testing.allocator, &night_shift_assistant);
    _ = try night_shift.appendMessage(night_shift_assistant);

    const night_shift_path = try std.testing.allocator.dupe(u8, night_shift.getSessionFile().?);
    defer std.testing.allocator.free(night_shift_path);

    var parser_panic = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project-b", project_b_sessions);
    defer parser_panic.deinit();

    var parser_user = try userTextMessage(std.testing.allocator, "parser panic while compiling release build", 3);
    defer deinitMessage(std.testing.allocator, &parser_user);
    _ = try parser_panic.appendMessage(parser_user);

    var parser_assistant = try assistantTextMessage(std.testing.allocator, "panic came from stale generated parser output", model, 4);
    defer deinitMessage(std.testing.allocator, &parser_assistant);
    _ = try parser_panic.appendMessage(parser_assistant);

    const parser_path = try std.testing.allocator.dupe(u8, parser_panic.getSessionFile().?);
    defer std.testing.allocator.free(parser_path);

    var checklist = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project-b", project_b_sessions);
    defer checklist.deinit();

    var checklist_user = try userTextMessage(std.testing.allocator, "night shift release checklist", 5);
    defer deinitMessage(std.testing.allocator, &checklist_user);
    _ = try checklist.appendMessage(checklist_user);

    var checklist_assistant = try assistantTextMessage(std.testing.allocator, "review migrations and smoke tests", model, 6);
    defer deinitMessage(std.testing.allocator, &checklist_assistant);
    _ = try checklist.appendMessage(checklist_assistant);

    const checklist_path = try std.testing.allocator.dupe(u8, checklist.getSessionFile().?);
    defer std.testing.allocator.free(checklist_path);

    const all_sessions = try listAllSessionsUnder(std.testing.allocator, std.testing.io, search_root);
    defer {
        for (@constCast(all_sessions)) |*session| session.deinit(std.testing.allocator);
        std.testing.allocator.free(@constCast(all_sessions));
    }

    try std.testing.expectEqual(@as(usize, 3), all_sessions.len);

    var name_results = try searchSessionsUnder(std.testing.allocator, std.testing.io, search_root, "name:\"Night Shift\"", .{});
    defer name_results.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), name_results.matches.len);
    const name_match = name_results.sessions[name_results.matches[0].session_index];
    try std.testing.expectEqualStrings("Night Shift", name_match.name.?);
    try std.testing.expectEqualStrings(night_shift_path, name_match.path);

    var content_results = try searchSessionsUnder(std.testing.allocator, std.testing.io, search_root, "content:\"parser panic\"", .{});
    defer content_results.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), content_results.matches.len);
    const content_match = content_results.sessions[content_results.matches[0].session_index];
    try std.testing.expectEqualStrings(parser_path, content_match.path);
    try std.testing.expect(std.mem.indexOf(u8, content_match.all_messages_text, "parser panic") != null);

    var relevance_results = try searchSessionsUnder(std.testing.allocator, std.testing.io, search_root, "night shift", .{});
    defer relevance_results.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), relevance_results.matches.len);
    const first_relevance = relevance_results.sessions[relevance_results.matches[0].session_index];
    const second_relevance = relevance_results.sessions[relevance_results.matches[1].session_index];
    try std.testing.expectEqualStrings(night_shift_path, first_relevance.path);
    try std.testing.expectEqualStrings(checklist_path, second_relevance.path);

    const named_only = try filterAndSortSessions(
        std.testing.allocator,
        all_sessions,
        "",
        .{ .sort_mode = .recent, .name_filter = .named },
    );
    defer std.testing.allocator.free(named_only);

    try std.testing.expectEqual(@as(usize, 1), named_only.len);
    try std.testing.expectEqualStrings(night_shift_path, all_sessions[named_only[0].session_index].path);
}

const SESSION_JSONL_REPLAY_FUZZ_SMOKE_SEED: u64 = 0x5eed_5e55_10ab_0004;

const SessionJsonlFuzzExpectation = enum {
    valid_branch_context,
    invalid_parent_context_error,
};

test "VAL-REFACTOR-010 deterministic session JSONL replay fuzz smoke" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(SESSION_JSONL_REPLAY_FUZZ_SMOKE_SEED);
    const random = prng.random();

    const malformed_lines = [_][]const u8{
        "not-json",
        "{\"type\":\"message\",\"id\":\"partial\"",
        "{\"type\":\"message\",\"id\":7,\"parentId\":null,\"timestamp\":\"2026-05-06T00:00:03.000Z\",\"message\":{}}",
        "{\"type\":\"unknown\",\"id\":\"ignored\",\"parentId\":null,\"timestamp\":\"2026-05-06T00:00:04.000Z\"}",
    };

    var valid_body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer valid_body_writer.deinit();
    try valid_body_writer.writer.writeAll(sessionFuzzHeaderLine());
    try valid_body_writer.writer.writeAll(sessionFuzzUserLine("u1", "null", "root prompt", 1));
    try valid_body_writer.writer.writeAll(sessionFuzzAssistantLine("a1", "\"u1\"", "root answer", 2));
    try valid_body_writer.writer.writeAll(malformed_lines[random.intRangeLessThan(usize, 0, malformed_lines.len)]);
    try valid_body_writer.writer.writeByte('\n');
    try valid_body_writer.writer.writeAll(sessionFuzzModelLine("m1", "\"a1\"", 3));
    try valid_body_writer.writer.writeAll(sessionFuzzBranchSummaryLine("b1", "\"m1\"", "a1", "alternate branch summary", 4));
    try valid_body_writer.writer.writeAll(malformed_lines[random.intRangeLessThan(usize, 0, malformed_lines.len)]);
    try valid_body_writer.writer.writeByte('\n');
    try valid_body_writer.writer.writeAll(sessionFuzzLabelLine("l1", "\"b1\"", "u1", "bookmark", 5));

    runSessionJsonlFuzzCase(
        allocator,
        "valid-with-malformed-partial-and-branch-summary",
        valid_body_writer.written(),
        .valid_branch_context,
    ) catch |err| {
        reportSessionJsonlFuzzFailure(SESSION_JSONL_REPLAY_FUZZ_SMOKE_SEED, "valid-with-malformed-partial-and-branch-summary", valid_body_writer.written());
        return err;
    };

    var invalid_parent_writer: std.Io.Writer.Allocating = .init(allocator);
    defer invalid_parent_writer.deinit();
    try invalid_parent_writer.writer.writeAll(sessionFuzzHeaderLine());
    try invalid_parent_writer.writer.writeAll(sessionFuzzUserLine("root", "null", "root prompt", 1));
    try invalid_parent_writer.writer.writeAll(sessionFuzzUserLine("orphan", "\"missing-parent\"", "orphan prompt", 2));

    runSessionJsonlFuzzCase(
        allocator,
        "invalid-parent-context-rebuild",
        invalid_parent_writer.written(),
        .invalid_parent_context_error,
    ) catch |err| {
        reportSessionJsonlFuzzFailure(SESSION_JSONL_REPLAY_FUZZ_SMOKE_SEED, "invalid-parent-context-rebuild", invalid_parent_writer.written());
        return err;
    };
}

fn runSessionJsonlFuzzCase(
    allocator: std.mem.Allocator,
    label: []const u8,
    body: []const u8,
    expectation: SessionJsonlFuzzExpectation,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "session-replay-fuzz.jsonl",
    });
    defer allocator.free(relative_path);
    const session_file = try makeAbsoluteTestPath(allocator, relative_path);
    defer allocator.free(session_file);
    try common.writeFileAbsolute(std.testing.io, session_file, body, true);

    var warnings: std.Io.Writer.Allocating = .init(allocator);
    defer warnings.deinit();

    var manager = try SessionManager.openWithWarningWriter(
        allocator,
        std.testing.io,
        session_file,
        null,
        &warnings.writer,
    );
    defer manager.deinit();

    switch (expectation) {
        .valid_branch_context => {
            var context = try manager.buildSessionContext(allocator);
            defer context.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 3), context.messages.len);
            try std.testing.expectEqualStrings("root prompt", context.messages[0].user.content[0].text.text);
            try std.testing.expectEqualStrings("root answer", context.messages[1].assistant.content[0].text.text);
            try std.testing.expect(std.mem.indexOf(u8, context.messages[2].user.content[0].text.text, "alternate branch summary") != null);
            try std.testing.expect(context.model != null);
            try std.testing.expectEqualStrings("faux-session-fuzz", context.model.?.model_id);
            try std.testing.expectEqualStrings("bookmark", manager.getLabel("u1").?);
            try std.testing.expect(std.mem.indexOf(u8, warnings.writer.buffered(), "corrupted line") != null);
        },
        .invalid_parent_context_error => {
            try std.testing.expectError(error.InvalidSessionTree, manager.buildSessionContext(allocator));
            try std.testing.expectError(error.InvalidSessionTree, manager.getBranch(allocator, null));
        },
    }

    _ = label;
}

fn sessionFuzzHeaderLine() []const u8 {
    return "{\"type\":\"session\",\"id\":\"session-fuzz\",\"timestamp\":\"2026-05-06T00:00:00.000Z\",\"cwd\":\"/tmp/session-fuzz\",\"parentSession\":\"/tmp/parent-session.jsonl\"}\n";
}

fn sessionFuzzUserLine(id: []const u8, parent_id_json: []const u8, text: []const u8, timestamp: i64) []const u8 {
    _ = timestamp;
    if (std.mem.eql(u8, id, "u1")) {
        _ = parent_id_json;
        _ = text;
        return "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"timestamp\":\"2026-05-06T00:00:01.000Z\",\"message\":{\"role\":\"user\",\"content\":\"root prompt\",\"timestamp\":1}}\n";
    }
    if (std.mem.eql(u8, id, "root")) {
        _ = parent_id_json;
        _ = text;
        return "{\"type\":\"message\",\"id\":\"root\",\"parentId\":null,\"timestamp\":\"2026-05-06T00:00:01.000Z\",\"message\":{\"role\":\"user\",\"content\":\"root prompt\",\"timestamp\":1}}\n";
    }
    _ = parent_id_json;
    _ = text;
    return "{\"type\":\"message\",\"id\":\"orphan\",\"parentId\":\"missing-parent\",\"timestamp\":\"2026-05-06T00:00:02.000Z\",\"message\":{\"role\":\"user\",\"content\":\"orphan prompt\",\"timestamp\":2}}\n";
}

fn sessionFuzzAssistantLine(id: []const u8, parent_id_json: []const u8, text: []const u8, timestamp: i64) []const u8 {
    _ = id;
    _ = parent_id_json;
    _ = text;
    _ = timestamp;
    return "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":\"u1\",\"timestamp\":\"2026-05-06T00:00:02.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"root answer\"}],\"api\":\"faux\",\"provider\":\"faux\",\"model\":\"faux-session-fuzz\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0},\"stopReason\":\"stop\",\"timestamp\":2}}\n";
}

fn sessionFuzzModelLine(id: []const u8, parent_id_json: []const u8, timestamp: i64) []const u8 {
    _ = id;
    _ = parent_id_json;
    _ = timestamp;
    return "{\"type\":\"model_change\",\"id\":\"m1\",\"parentId\":\"a1\",\"timestamp\":\"2026-05-06T00:00:03.000Z\",\"provider\":\"faux\",\"modelId\":\"faux-session-fuzz\"}\n";
}

fn sessionFuzzBranchSummaryLine(id: []const u8, parent_id_json: []const u8, from_id: []const u8, summary: []const u8, timestamp: i64) []const u8 {
    _ = id;
    _ = parent_id_json;
    _ = from_id;
    _ = summary;
    _ = timestamp;
    return "{\"type\":\"branch_summary\",\"id\":\"b1\",\"parentId\":\"m1\",\"timestamp\":\"2026-05-06T00:00:04.000Z\",\"fromId\":\"a1\",\"summary\":\"alternate branch summary\",\"fromHook\":true}\n";
}

fn sessionFuzzLabelLine(id: []const u8, parent_id_json: []const u8, target_id: []const u8, label: []const u8, timestamp: i64) []const u8 {
    _ = id;
    _ = parent_id_json;
    _ = target_id;
    _ = label;
    _ = timestamp;
    return "{\"type\":\"label\",\"id\":\"l1\",\"parentId\":\"b1\",\"timestamp\":\"2026-05-06T00:00:05.000Z\",\"targetId\":\"u1\",\"label\":\"bookmark\"}\n";
}

fn reportSessionJsonlFuzzFailure(seed: u64, label: []const u8, input: []const u8) void {
    std.debug.print("Session JSONL fuzz smoke failure seed=0x{x} case={s} smallest_repro_jsonl={s}", .{
        seed,
        label,
        input,
    });
}
