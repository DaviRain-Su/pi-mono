const std = @import("std");

/// Ordered entries and derived projections for array-backed session storage.
/// Behavioral port of `packages/agent/src/harness/session/array-session-index.ts`.
///
/// Pure in-memory index: no FS/SQLite. Entry string fields are borrowed from the
/// caller for the lifetime of the index state (append/replace).

// ---------------------------------------------------------------------------
// Minimal session types needed by the index (co-located; full harness types later)
// ---------------------------------------------------------------------------

pub const SessionErrorCode = enum {
    not_found,
    invalid_session,
    invalid_entry,
    invalid_fork_target,
    storage,
    unknown,
};

/// Error set for index operations. Mirrors TS `SessionError` codes where used.
pub const Error = error{
    NotFound,
    InvalidSession,
    InvalidEntry,
    /// Mirrors TS `RangeError("Session branch query limit must be a positive integer")`.
    InvalidBranchQueryLimit,
    OutOfMemory,
};

pub const SessionEntryType = enum {
    message,
    thinking_level_change,
    model_change,
    active_tools_change,
    compaction,
    branch_summary,
    custom,
    custom_message,
    label,
    session_info,
    leaf,

    pub fn fromString(s: []const u8) ?SessionEntryType {
        inline for (std.meta.fields(SessionEntryType)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(SessionEntryType, f.name);
        }
        return null;
    }
};

pub const MessageRole = enum {
    user,
    assistant,
    toolResult,
    system,
};

/// Token/cost usage subset used by projection (assistant / compaction / branch_summary).
pub const SessionUsage = struct {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
    cost_total: f64,
};

pub const SessionStats = struct {
    message_count: f64 = 0,
    cached_tokens: f64 = 0,
    uncached_tokens: f64 = 0,
    total_tokens: f64 = 0,
    cost_total: f64 = 0,

    pub fn eql(self: SessionStats, other: SessionStats) bool {
        return self.message_count == other.message_count and
            self.cached_tokens == other.cached_tokens and
            self.uncached_tokens == other.uncached_tokens and
            self.total_tokens == other.total_tokens and
            self.cost_total == other.cost_total;
    }
};

pub const SessionHead = struct {
    leaf_id: ?[]const u8,
};

pub const SessionEntryCursorOptions = struct {
    /// Number of entries already consumed; reading starts at this zero-based sequence.
    after_entry_seq: usize = 0,
    limit: ?usize = null,
};

pub const BranchOrder = enum {
    newest_first,
    oldest_first,
};

pub const SessionBranchQuery = struct {
    /// Entry where traversal starts. Null yields an empty result.
    start: ?[]const u8,
    stop_at_type: ?SessionEntryType = null,
    stop_at_id: ?[]const u8 = null,
    /// Filter returned entries by type after determining traversal bounds.
    type_filter: ?SessionEntryType = null,
    custom_type: ?[]const u8 = null,
    order: BranchOrder = .newest_first,
    limit: ?usize = null,
};

/// Minimal tree entry surface for the array index. Fields not needed by the pure
/// index (full message body, model change payloads, etc.) are omitted.
pub const SessionTreeEntry = struct {
    type: SessionEntryType,
    id: []const u8,
    parent_id: ?[]const u8 = null,
    timestamp: []const u8 = "",

    /// message
    message_role: ?MessageRole = null,
    message_usage: ?SessionUsage = null,

    /// compaction / branch_summary usage
    usage: ?SessionUsage = null,
    /// compaction
    first_kept_entry_id: ?[]const u8 = null,
    /// When true, path-to-root stops at this compaction (retained tail present).
    retained_tail: bool = false,

    /// custom / custom_message
    custom_type: ?[]const u8 = null,

    /// label target / leaf target
    target_id: ?[]const u8 = null,
    /// label text; null or whitespace-only clears the label in projection
    label: ?[]const u8 = null,

    /// session_info
    name: ?[]const u8 = null,
};

const SessionEntryProjection = struct {
    name: ?[]const u8 = null,
    labels_by_id: std.StringHashMapUnmanaged([]const u8) = .empty,
    stats: SessionStats = .{},

    fn deinit(self: *SessionEntryProjection, allocator: std.mem.Allocator) void {
        self.labels_by_id.deinit(allocator);
        self.* = .{};
    }
};

fn applyProjection(projection: *SessionEntryProjection, allocator: std.mem.Allocator, entry: SessionTreeEntry) Error!void {
    switch (entry.type) {
        .session_info => {
            if (entry.name) |n| {
                const trimmed = std.mem.trim(u8, n, &std.ascii.whitespace);
                projection.name = if (trimmed.len == 0) null else trimmed;
            } else {
                projection.name = null;
            }
        },
        .label => {
            const target = entry.target_id orelse return;
            if (entry.label) |lab| {
                const trimmed = std.mem.trim(u8, lab, &std.ascii.whitespace);
                if (trimmed.len == 0) {
                    _ = projection.labels_by_id.remove(target);
                } else {
                    try projection.labels_by_id.put(allocator, target, trimmed);
                }
            } else {
                _ = projection.labels_by_id.remove(target);
            }
        },
        else => {},
    }

    if (entry.type == .message) {
        projection.stats.message_count += 1;
    }

    const usage: ?SessionUsage = blk: {
        switch (entry.type) {
            .message => {
                if (entry.message_role == .assistant) break :blk entry.message_usage;
                break :blk null;
            },
            .compaction, .branch_summary => break :blk entry.usage,
            else => break :blk null,
        }
    };

    if (usage) |u| {
        projection.stats.cached_tokens += u.cache_read;
        projection.stats.uncached_tokens += u.input + u.cache_write;
        projection.stats.total_tokens += u.input + u.output + u.cache_read + u.cache_write;
        projection.stats.cost_total += u.cost_total;
    }
}

// ---------------------------------------------------------------------------
// ArraySessionIndex
// ---------------------------------------------------------------------------

pub const ArraySessionIndex = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(SessionTreeEntry) = .empty,
    by_id: std.StringHashMapUnmanaged(SessionTreeEntry) = .empty,
    leaf_id: ?[]const u8 = null,
    projection: SessionEntryProjection = .{},

    pub fn init(allocator: std.mem.Allocator) ArraySessionIndex {
        return .{ .allocator = allocator };
    }

    pub fn initWithEntries(allocator: std.mem.Allocator, entries: []const SessionTreeEntry) Error!ArraySessionIndex {
        var self = init(allocator);
        errdefer self.deinit();
        try self.replace(entries);
        return self;
    }

    pub fn deinit(self: *ArraySessionIndex) void {
        self.entries.deinit(self.allocator);
        self.by_id.deinit(self.allocator);
        self.projection.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn has(self: *const ArraySessionIndex, id: []const u8) bool {
        return self.by_id.contains(id);
    }

    pub fn append(self: *ArraySessionIndex, entry: SessionTreeEntry) Error!void {
        if (self.by_id.contains(entry.id)) return error.InvalidEntry;
        try self.entries.append(self.allocator, entry);
        try self.by_id.put(self.allocator, entry.id, entry);
        self.leaf_id = if (entry.type == .leaf) entry.target_id else entry.id;
        try applyProjection(&self.projection, self.allocator, entry);
    }

    pub fn replace(self: *ArraySessionIndex, entries: []const SessionTreeEntry) Error!void {
        var next_entries: std.ArrayList(SessionTreeEntry) = .empty;
        errdefer next_entries.deinit(self.allocator);
        var next_by_id: std.StringHashMapUnmanaged(SessionTreeEntry) = .empty;
        errdefer next_by_id.deinit(self.allocator);
        var next_projection: SessionEntryProjection = .{};
        errdefer next_projection.deinit(self.allocator);
        var next_leaf_id: ?[]const u8 = null;

        for (entries) |entry| {
            if (next_by_id.contains(entry.id)) return error.InvalidEntry;
            try next_entries.append(self.allocator, entry);
            try next_by_id.put(self.allocator, entry.id, entry);
            next_leaf_id = if (entry.type == .leaf) entry.target_id else entry.id;
            try applyProjection(&next_projection, self.allocator, entry);
        }

        self.entries.deinit(self.allocator);
        self.by_id.deinit(self.allocator);
        self.projection.deinit(self.allocator);

        self.entries = next_entries;
        self.by_id = next_by_id;
        self.leaf_id = next_leaf_id;
        self.projection = next_projection;
    }

    pub fn readHead(self: *const ArraySessionIndex) Error!SessionHead {
        if (self.leaf_id) |id| {
            if (!self.by_id.contains(id)) return error.InvalidSession;
        }
        return .{ .leaf_id = self.leaf_id };
    }

    pub fn readEntry(self: *const ArraySessionIndex, id: []const u8) ?SessionTreeEntry {
        return self.by_id.get(id);
    }

    /// Returns a borrowed slice into the ordered entry list (valid until next mutating call).
    pub fn readEntries(self: *const ArraySessionIndex, options: SessionEntryCursorOptions) []const SessionTreeEntry {
        const start = options.after_entry_seq;
        if (start >= self.entries.items.len) return &.{};
        const rest = self.entries.items[start..];
        if (options.limit) |lim| {
            if (lim == 0) return &.{};
            if (lim < rest.len) return rest[0..lim];
        }
        return rest;
    }

    /// Walk parent chain from `query.start`, apply stop/filter/limit.
    /// Returned slice is owned by `allocator` (entry string fields remain borrowed).
    pub fn findEntriesOnBranch(
        self: *const ArraySessionIndex,
        allocator: std.mem.Allocator,
        query: SessionBranchQuery,
    ) Error![]SessionTreeEntry {
        if (query.limit) |lim| {
            if (lim == 0) return error.InvalidBranchQueryLimit;
        }
        if (query.start == null) {
            return try allocator.alloc(SessionTreeEntry, 0);
        }
        const start_id = query.start.?;

        var path_from_start: std.ArrayList(SessionTreeEntry) = .empty;
        defer path_from_start.deinit(allocator);

        var visited: std.StringHashMapUnmanaged(void) = .empty;
        defer visited.deinit(allocator);

        var current = self.by_id.get(start_id) orelse return error.NotFound;

        while (true) {
            if (visited.contains(current.id)) return error.InvalidSession;
            try visited.put(allocator, current.id, {});
            try path_from_start.append(allocator, current);

            // Newest-first: stop when we hit stop bounds while walking to root.
            if (query.order != .oldest_first) {
                if (matchesStop(current, query)) break;
            }

            const parent_id = current.parent_id orelse break;
            const parent = self.by_id.get(parent_id) orelse return error.InvalidSession;
            current = parent;
        }

        // Build traversal order
        var traversal: []SessionTreeEntry = undefined;
        if (query.order == .oldest_first) {
            // reverse path_from_start into a new slice
            const n = path_from_start.items.len;
            traversal = try allocator.alloc(SessionTreeEntry, n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                traversal[i] = path_from_start.items[n - 1 - i];
            }
        } else {
            traversal = try allocator.dupe(SessionTreeEntry, path_from_start.items);
        }
        defer allocator.free(traversal);

        // Oldest-first: stop after first matching entry (inclusive) in traversal order.
        const bounded: []const SessionTreeEntry = blk: {
            if (query.order == .oldest_first) {
                if (findStopIndex(traversal, query)) |stop_index| {
                    break :blk traversal[0 .. stop_index + 1];
                }
            }
            break :blk traversal;
        };

        var filtered: std.ArrayList(SessionTreeEntry) = .empty;
        errdefer filtered.deinit(allocator);
        for (bounded) |entry| {
            if (query.type_filter) |tf| {
                if (entry.type != tf) continue;
            }
            if (query.custom_type) |ct| {
                if (entry.type != .custom or entry.custom_type == null or !std.mem.eql(u8, entry.custom_type.?, ct)) {
                    continue;
                }
            }
            try filtered.append(allocator, entry);
            if (query.limit) |lim| {
                if (filtered.items.len >= lim) break;
            }
        }
        return try filtered.toOwnedSlice(allocator);
    }

    pub fn getLabel(self: *const ArraySessionIndex, id: []const u8) ?[]const u8 {
        return self.projection.labels_by_id.get(id);
    }

    pub fn getName(self: *const ArraySessionIndex) ?[]const u8 {
        return self.projection.name;
    }

    pub fn getStats(self: *const ArraySessionIndex) SessionStats {
        return self.projection.stats;
    }

    /// Path from root (or compaction boundary) to leaf, oldest-first.
    /// Returned slice owned by `allocator`.
    pub fn readPathToRootOrCompaction(
        self: *const ArraySessionIndex,
        allocator: std.mem.Allocator,
        requested_leaf_id: ?[]const u8,
    ) Error![]SessionTreeEntry {
        if (requested_leaf_id == null) {
            return try allocator.alloc(SessionTreeEntry, 0);
        }
        const leaf = requested_leaf_id.?;

        var path: std.ArrayList(SessionTreeEntry) = .empty;
        errdefer path.deinit(allocator);

        var stop_at_entry_id: ?[]const u8 = null;
        var current = self.by_id.get(leaf) orelse return error.NotFound;

        while (true) {
            try path.append(allocator, current);
            if (stop_at_entry_id) |sid| {
                if (std.mem.eql(u8, current.id, sid)) break;
            }
            if (current.type == .compaction) {
                if (current.retained_tail) break;
                stop_at_entry_id = current.first_kept_entry_id;
            }
            const parent_id = current.parent_id orelse break;
            const parent = self.by_id.get(parent_id) orelse return error.InvalidSession;
            current = parent;
        }

        // reverse to oldest-first
        const n = path.items.len;
        var i: usize = 0;
        while (i < n / 2) : (i += 1) {
            const tmp = path.items[i];
            path.items[i] = path.items[n - 1 - i];
            path.items[n - 1 - i] = tmp;
        }
        return try path.toOwnedSlice(allocator);
    }

    fn matchesStop(entry: SessionTreeEntry, query: SessionBranchQuery) bool {
        if (query.stop_at_id) |sid| {
            if (std.mem.eql(u8, entry.id, sid)) return true;
        }
        if (query.stop_at_type) |st| {
            if (entry.type == st) return true;
        }
        return false;
    }

    fn findStopIndex(traversal: []const SessionTreeEntry, query: SessionBranchQuery) ?usize {
        for (traversal, 0..) |entry, i| {
            if (matchesStop(entry, query)) return i;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Offline tests on shipped public API
// ---------------------------------------------------------------------------

fn msg(id: []const u8, parent_id: ?[]const u8, role: MessageRole) SessionTreeEntry {
    return .{
        .type = .message,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .message_role = role,
    };
}

fn msgUsage(id: []const u8, parent_id: ?[]const u8, usage: SessionUsage) SessionTreeEntry {
    return .{
        .type = .message,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .message_role = .assistant,
        .message_usage = usage,
    };
}

fn custom(id: []const u8, parent_id: ?[]const u8, custom_type: []const u8) SessionTreeEntry {
    return .{
        .type = .custom,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .custom_type = custom_type,
    };
}

fn compactionEntry(
    id: []const u8,
    parent_id: ?[]const u8,
    first_kept: ?[]const u8,
    retained_tail: bool,
    usage: ?SessionUsage,
) SessionTreeEntry {
    return .{
        .type = .compaction,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .first_kept_entry_id = first_kept,
        .retained_tail = retained_tail,
        .usage = usage,
    };
}

fn branchSummaryEntry(id: []const u8, parent_id: ?[]const u8, usage: SessionUsage) SessionTreeEntry {
    return .{
        .type = .branch_summary,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .usage = usage,
    };
}

fn labelEntry(id: []const u8, parent_id: ?[]const u8, target_id: []const u8, label: ?[]const u8) SessionTreeEntry {
    return .{
        .type = .label,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .target_id = target_id,
        .label = label,
    };
}

fn sessionInfo(id: []const u8, parent_id: ?[]const u8, name: ?[]const u8) SessionTreeEntry {
    return .{
        .type = .session_info,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .name = name,
    };
}

fn leafEntry(id: []const u8, parent_id: ?[]const u8, target_id: ?[]const u8) SessionTreeEntry {
    return .{
        .type = .leaf,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .target_id = target_id,
    };
}

fn expectIds(entries: []const SessionTreeEntry, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, entries.len);
    for (entries, expected) |e, id| {
        try std.testing.expectEqualStrings(id, e.id);
    }
}

// Pi: packages/agent/src/harness/session/array-session-index.ts "append/replace uniqueness"
test "ArraySessionIndex append and replace reject duplicate ids" {
    const allocator = std.testing.allocator;
    var idx = ArraySessionIndex.init(allocator);
    defer idx.deinit();

    try idx.append(msg("a", null, .user));
    try std.testing.expect(idx.has("a"));
    try std.testing.expectError(error.InvalidEntry, idx.append(msg("a", null, .user)));

    try std.testing.expectError(error.InvalidEntry, idx.replace(&.{
        msg("x", null, .user),
        msg("x", "x", .assistant),
    }));
}

// Pi: packages/agent/src/harness/session/array-session-index.ts "readHead/readEntry/readEntries"
test "ArraySessionIndex readHead readEntry readEntries cursor" {
    const allocator = std.testing.allocator;
    var idx = ArraySessionIndex.init(allocator);
    defer idx.deinit();

    try idx.append(msg("root", null, .user));
    try idx.append(msg("child", "root", .assistant));
    try idx.append(leafEntry("leaf1", "child", "root"));

    const head = try idx.readHead();
    try std.testing.expectEqualStrings("root", head.leaf_id.?);

    try std.testing.expect(idx.readEntry("missing") == null);
    try std.testing.expectEqualStrings("child", idx.readEntry("child").?.id);

    const all = idx.readEntries(.{});
    try expectIds(all, &.{ "root", "child", "leaf1" });

    const after = idx.readEntries(.{ .after_entry_seq = 1, .limit = 1 });
    try expectIds(after, &.{"child"});

    // Leaf pointing at missing target → invalid_session on readHead
    try idx.append(leafEntry("leaf2", "leaf1", "gone"));
    try std.testing.expectError(error.InvalidSession, idx.readHead());
}

// Pi: packages/agent/test/harness/branch-query.test.ts "identical in-memory query semantics"
test "ArraySessionIndex findEntriesOnBranch branch query semantics" {
    const allocator = std.testing.allocator;
    var idx = ArraySessionIndex.init(allocator);
    defer idx.deinit();

    // root -> custom -> child -> compaction -> recentCustom -> tail
    // sibling branched from root
    try idx.append(msg("root", null, .user));
    try idx.append(custom("custom", "root", "note"));
    try idx.append(msg("child", "custom", .assistant));
    try idx.append(compactionEntry("compaction", "child", "child", true, null));
    try idx.append(custom("recentCustom", "compaction", "note"));
    try idx.append(msg("tail", "recentCustom", .user));
    try idx.append(msg("sibling", "root", .user));

    // default newest-first from sibling
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{ .start = "sibling" });
        defer allocator.free(branch);
        try expectIds(branch, &.{ "sibling", "root" });
    }

    // start null
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{ .start = null });
        defer allocator.free(branch);
        try std.testing.expectEqual(@as(usize, 0), branch.len);
    }

    // oldestFirst full path from tail
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{ .start = "tail", .order = .oldest_first });
        defer allocator.free(branch);
        try expectIds(branch, &.{ "root", "custom", "child", "compaction", "recentCustom", "tail" });
    }

    // stopAtType compaction newest-first
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{ .start = "tail", .stop_at_type = .compaction });
        defer allocator.free(branch);
        try expectIds(branch, &.{ "tail", "recentCustom", "compaction" });
    }

    // stopAtType compaction + type message
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{
            .start = "tail",
            .stop_at_type = .compaction,
            .type_filter = .message,
        });
        defer allocator.free(branch);
        try expectIds(branch, &.{"tail"});
    }

    // stopAtId child oldestFirst
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{
            .start = "tail",
            .stop_at_id = "child",
            .order = .oldest_first,
        });
        defer allocator.free(branch);
        try expectIds(branch, &.{ "root", "custom", "child" });
    }

    // stopAtType custom newest-first
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{ .start = "tail", .stop_at_type = .custom });
        defer allocator.free(branch);
        try expectIds(branch, &.{ "tail", "recentCustom" });
    }

    // stopAtType custom oldestFirst
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{
            .start = "tail",
            .stop_at_type = .custom,
            .order = .oldest_first,
        });
        defer allocator.free(branch);
        try expectIds(branch, &.{ "root", "custom" });
    }

    // type message oldestFirst
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{
            .start = "tail",
            .type_filter = .message,
            .order = .oldest_first,
        });
        defer allocator.free(branch);
        try expectIds(branch, &.{ "root", "child", "tail" });
    }

    // customType note
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{ .start = "tail", .custom_type = "note" });
        defer allocator.free(branch);
        try expectIds(branch, &.{ "recentCustom", "custom" });
    }

    // limit 1 newest-first
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{ .start = "tail", .limit = 1 });
        defer allocator.free(branch);
        try expectIds(branch, &.{"tail"});
    }

    // type message oldestFirst limit 1
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{
            .start = "tail",
            .type_filter = .message,
            .order = .oldest_first,
            .limit = 1,
        });
        defer allocator.free(branch);
        try expectIds(branch, &.{"root"});
    }

    // not_found
    try std.testing.expectError(error.NotFound, idx.findEntriesOnBranch(allocator, .{ .start = "missing" }));

    // limit 0
    try std.testing.expectError(error.InvalidBranchQueryLimit, idx.findEntriesOnBranch(allocator, .{
        .start = "tail",
        .limit = 0,
    }));
}

// Pi: packages/agent/test/harness/branch-query.test.ts "rejects corrupt parent chains"
test "ArraySessionIndex rejects orphan parent and cycles" {
    const allocator = std.testing.allocator;
    var idx = ArraySessionIndex.init(allocator);
    defer idx.deinit();

    try idx.append(msg("orphan", "missing-parent", .user));

    // stop at self — does not walk to missing parent
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{ .start = "orphan", .stop_at_id = "orphan" });
        defer allocator.free(branch);
        try expectIds(branch, &.{"orphan"});
    }
    {
        const branch = try idx.findEntriesOnBranch(allocator, .{ .start = "orphan", .stop_at_type = .message });
        defer allocator.free(branch);
        try expectIds(branch, &.{"orphan"});
    }

    // full walk hits missing parent
    try std.testing.expectError(error.InvalidSession, idx.findEntriesOnBranch(allocator, .{ .start = "orphan" }));

    try idx.append(msg("cycle-a", "cycle-b", .user));
    try idx.append(msg("cycle-b", "cycle-a", .user));
    try std.testing.expectError(error.InvalidSession, idx.findEntriesOnBranch(allocator, .{ .start = "cycle-b" }));
}

// Pi: packages/agent/test/harness/session-backends.test.ts "labels, names, stats"
test "ArraySessionIndex label name and stats projections" {
    const allocator = std.testing.allocator;
    var idx = ArraySessionIndex.init(allocator);
    defer idx.deinit();

    try idx.append(msg("root", null, .user));
    try idx.append(msg("child", "root", .assistant));
    try idx.append(labelEntry("lab1", "child", "root", "checkpoint"));
    try idx.append(sessionInfo("info1", "lab1", " review name "));

    try std.testing.expectEqualStrings("checkpoint", idx.getLabel("root").?);
    try std.testing.expectEqualStrings("review name", idx.getName().?);

    // clear label
    try idx.append(labelEntry("lab2", "info1", "root", "  "));
    try std.testing.expect(idx.getLabel("root") == null);

    // whitespace-only name clears
    try idx.append(sessionInfo("info2", "lab2", "   "));
    try std.testing.expect(idx.getName() == null);

    // usage stats: assistant + compaction + branch_summary
    // Pi: packages/agent/test/harness/session-backends.test.ts "includes assistant and summary usage"
    var stats_idx = ArraySessionIndex.init(allocator);
    defer stats_idx.deinit();

    try stats_idx.append(msgUsage("a1", null, .{
        .input = 10,
        .output = 20,
        .cache_read = 30,
        .cache_write = 40,
        .cost_total = 1,
    }));
    try stats_idx.append(compactionEntry("c1", "a1", null, false, .{
        .input = 1,
        .output = 2,
        .cache_read = 3,
        .cache_write = 4,
        .cost_total = 0.1,
    }));
    try stats_idx.append(branchSummaryEntry("b1", "c1", .{
        .input = 5,
        .output = 6,
        .cache_read = 7,
        .cache_write = 8,
        .cost_total = 0.26,
    }));

    const stats = stats_idx.getStats();
    try std.testing.expect(stats.eql(.{
        .message_count = 1,
        .cached_tokens = 40, // 30+3+7
        .uncached_tokens = 68, // (10+40)+(1+4)+(5+8)
        .total_tokens = 136, // (10+20+30+40)+(1+2+3+4)+(5+6+7+8)
        .cost_total = 1.36,
    }));

    // user messages do not add usage
    try stats_idx.append(msg("u1", "b1", .user));
    try std.testing.expectEqual(@as(f64, 2), stats_idx.getStats().message_count);
    try std.testing.expectEqual(@as(f64, 1.36), stats_idx.getStats().cost_total);
}

// Pi: packages/agent/test/harness/session-backends.test.ts "stops branch traversal at retained-tail compaction"
test "ArraySessionIndex readPathToRootOrCompaction retained tail and firstKept" {
    const allocator = std.testing.allocator;
    var idx = ArraySessionIndex.init(allocator);
    defer idx.deinit();

    try idx.append(msg("root", null, .user));
    try idx.append(msg("child", "root", .assistant));
    try idx.append(compactionEntry("compaction", "child", "child", true, null));
    try idx.append(msg("tail", "compaction", .user));

    {
        const path = try idx.readPathToRootOrCompaction(allocator, "tail");
        defer allocator.free(path);
        try expectIds(path, &.{ "compaction", "tail" });
    }

    // without retained tail, stop at firstKeptEntryId
    var idx2 = ArraySessionIndex.init(allocator);
    defer idx2.deinit();
    try idx2.append(msg("r", null, .user));
    try idx2.append(msg("mid", "r", .assistant));
    try idx2.append(msg("kept", "mid", .user));
    try idx2.append(compactionEntry("comp", "kept", "kept", false, null));
    try idx2.append(msg("after", "comp", .user));

    {
        const path = try idx2.readPathToRootOrCompaction(allocator, "after");
        defer allocator.free(path);
        // walks: after, comp (sets stop=kept), kept (matches stop) → reverse
        try expectIds(path, &.{ "kept", "comp", "after" });
    }

    {
        const empty = try idx2.readPathToRootOrCompaction(allocator, null);
        defer allocator.free(empty);
        try std.testing.expectEqual(@as(usize, 0), empty.len);
    }

    try std.testing.expectError(error.NotFound, idx2.readPathToRootOrCompaction(allocator, "nope"));
}

// Pi: packages/agent/src/harness/session/array-session-index.ts "initWithEntries replace rebuilds projection"
test "ArraySessionIndex replace rebuilds leaf and projection" {
    const allocator = std.testing.allocator;
    var idx = try ArraySessionIndex.initWithEntries(allocator, &.{
        msg("a", null, .user),
        labelEntry("l", "a", "a", "old"),
    });
    defer idx.deinit();

    try std.testing.expectEqualStrings("old", idx.getLabel("a").?);
    try std.testing.expectEqualStrings("l", (try idx.readHead()).leaf_id.?);

    try idx.replace(&.{
        msg("b", null, .user),
        sessionInfo("s", "b", "named"),
    });
    try std.testing.expect(idx.getLabel("a") == null);
    try std.testing.expectEqualStrings("named", idx.getName().?);
    try std.testing.expectEqualStrings("s", (try idx.readHead()).leaf_id.?);
    try std.testing.expect(!idx.has("a"));
    try std.testing.expect(idx.has("b"));
}
