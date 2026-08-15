const std = @import("std");
const array_index = @import("../array_session_index.zig");

/// Shared session repo helpers/types.
/// Pure fork selection/read from `packages/agent/src/harness/session/repository.ts`.

pub const SessionRecord = struct {
    id: []const u8,
    path: []const u8,
};

pub const SessionMetadata = struct {
    id: []const u8,
    created_at: []const u8,
};

pub const SessionCreateOptions = struct {
    id: ?[]const u8 = null,
};

pub const ForkPosition = enum {
    before,
    at,
};

pub const SessionForkOptions = struct {
    entry_id: ?[]const u8 = null,
    position: ForkPosition = .before,
    id: ?[]const u8 = null,
};

/// Fork selection for built-in repositories.
/// Mirrors `SessionForkSelection` in `packages/agent/src/harness/types.ts`.
pub const SessionForkSelection = union(enum) {
    /// Copy all persisted entries in append order.
    all,
    /// Copy the target's active path, excluding the target; target must be a user message.
    before_user_message: []const u8,
    /// Copy the target's active path, including the target.
    through_entry: []const u8,
};

pub const Error = error{
    NotFound,
    InvalidSession,
    InvalidEntry,
    InvalidForkTarget,
    /// Mirrors TS `SessionError("storage", "In-memory session repository is disposed")`.
    Disposed,
    InvalidBranchQueryLimit,
    OutOfMemory,
};

var next_session_seq: std.atomic.Value(u64) = .init(1);

/// Mirrors `createSessionId` (unique id; tests usually pass an explicit id).
pub fn createSessionId(allocator: std.mem.Allocator) Error![]u8 {
    const n = next_session_seq.fetchAdd(1, .monotonic);
    const ms = nowMilliseconds();
    return std.fmt.allocPrint(allocator, "sess-{d}-{d}", .{ n, ms }) catch return error.OutOfMemory;
}

fn nowMilliseconds() i64 {
    var now: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&now, null);
    return @as(i64, @intCast(now.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(now.usec)), std.time.us_per_ms);
}

/// Mirrors `createTimestamp` (ISO-8601 UTC milliseconds).
pub fn createTimestamp(allocator: std.mem.Allocator) Error![]u8 {
    const ms = nowMilliseconds();
    if (ms < 0) {
        return std.fmt.allocPrint(allocator, "1970-01-01T00:00:00.000Z", .{}) catch return error.OutOfMemory;
    }
    const total_ms: u64 = @intCast(ms);
    const secs: u64 = total_ms / 1000;
    const millis: u64 = total_ms % 1000;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_sec = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_sec.getHoursIntoDay(),
            day_sec.getMinutesIntoHour(),
            day_sec.getSecondsIntoMinute(),
            millis,
        },
    ) catch return error.OutOfMemory;
}

/// Mirrors `createSessionForkSelection` in repository.ts.
pub fn createSessionForkSelection(options: SessionForkOptions) SessionForkSelection {
    const entry_id = options.entry_id orelse return .all;
    return switch (options.position) {
        .at => .{ .through_entry = entry_id },
        .before => .{ .before_user_message = entry_id },
    };
}

/// Mirrors `readSessionEntriesForFork` in repository.ts.
/// Returned slice is owned by `allocator`; entry string fields remain borrowed from `source`.
pub fn readSessionEntriesForFork(
    allocator: std.mem.Allocator,
    source: *const array_index.ArraySessionIndex,
    selection: SessionForkSelection,
) Error![]array_index.SessionTreeEntry {
    switch (selection) {
        .all => {
            const all = source.readEntries(.{});
            return allocator.dupe(array_index.SessionTreeEntry, all) catch return error.OutOfMemory;
        },
        .through_entry => |entry_id| {
            const target = source.readEntry(entry_id) orelse return error.InvalidForkTarget;
            return source.readPathToRootOrCompaction(allocator, target.id) catch |err| switch (err) {
                error.NotFound => return error.InvalidForkTarget,
                error.InvalidSession => return error.InvalidSession,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSession,
            };
        },
        .before_user_message => |entry_id| {
            const target = source.readEntry(entry_id) orelse return error.InvalidForkTarget;
            if (target.type != .message or target.message_role != .user) {
                return error.InvalidForkTarget;
            }
            return source.readPathToRootOrCompaction(allocator, target.parent_id) catch |err| switch (err) {
                error.NotFound => return error.InvalidForkTarget,
                error.InvalidSession => return error.InvalidSession,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSession,
            };
        },
    }
}

// ---------------------------------------------------------------------------
// Offline tests for pure fork helpers
// ---------------------------------------------------------------------------

fn msg(id: []const u8, parent_id: ?[]const u8, role: array_index.MessageRole) array_index.SessionTreeEntry {
    return .{
        .type = .message,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .message_role = role,
    };
}

// Pi: packages/agent/src/harness/session/repository.ts "createSessionForkSelection"
test "createSessionForkSelection maps entryId and position" {
    try std.testing.expect(createSessionForkSelection(.{}) == .all);
    try std.testing.expect(createSessionForkSelection(.{ .entry_id = null }) == .all);

    const before = createSessionForkSelection(.{ .entry_id = "u1" });
    try std.testing.expect(before == .before_user_message);
    try std.testing.expectEqualStrings("u1", before.before_user_message);

    const through = createSessionForkSelection(.{ .entry_id = "a1", .position = .at });
    try std.testing.expect(through == .through_entry);
    try std.testing.expectEqualStrings("a1", through.through_entry);
}

// Pi: packages/agent/src/harness/session/repository.ts "readSessionEntriesForFork"
test "readSessionEntriesForFork selection kinds" {
    const allocator = std.testing.allocator;
    var idx = array_index.ArraySessionIndex.init(allocator);
    defer idx.deinit();

    try idx.append(msg("user1", null, .user));
    try idx.append(msg("asst1", "user1", .assistant));
    try idx.append(msg("user2", "asst1", .user));

    {
        const entries = try readSessionEntriesForFork(allocator, &idx, .all);
        defer allocator.free(entries);
        try std.testing.expectEqual(@as(usize, 3), entries.len);
        try std.testing.expectEqualStrings("user1", entries[0].id);
        try std.testing.expectEqualStrings("user2", entries[2].id);
    }

    {
        const entries = try readSessionEntriesForFork(allocator, &idx, .{ .before_user_message = "user2" });
        defer allocator.free(entries);
        try std.testing.expectEqual(@as(usize, 2), entries.len);
        try std.testing.expectEqualStrings("user1", entries[0].id);
        try std.testing.expectEqualStrings("asst1", entries[1].id);
    }

    {
        const entries = try readSessionEntriesForFork(allocator, &idx, .{ .through_entry = "asst1" });
        defer allocator.free(entries);
        try std.testing.expectEqual(@as(usize, 2), entries.len);
        try std.testing.expectEqualStrings("user1", entries[0].id);
        try std.testing.expectEqualStrings("asst1", entries[1].id);
    }

    try std.testing.expectError(
        error.InvalidForkTarget,
        readSessionEntriesForFork(allocator, &idx, .{ .before_user_message = "asst1" }),
    );
    try std.testing.expectError(
        error.InvalidForkTarget,
        readSessionEntriesForFork(allocator, &idx, .{ .before_user_message = "missing" }),
    );
}
