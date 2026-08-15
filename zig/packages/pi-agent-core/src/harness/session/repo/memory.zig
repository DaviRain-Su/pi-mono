const std = @import("std");
const array_index = @import("../array_session_index.zig");
const keyed_queue = @import("../keyed_operation_queue.zig");
const shared = @import("shared.zig");

/// In-memory session backend.
/// Behavioral port of `InMemorySessionBackend` in
/// `packages/agent/src/harness/session/memory-repo.ts`.
///
/// Entry string fields on append/fork remain borrowed from the caller (same as
/// ArraySessionIndex). Session id / created_at are owned by the backend.

pub const SessionMetadata = shared.SessionMetadata;
pub const SessionCreateOptions = shared.SessionCreateOptions;
pub const SessionForkOptions = shared.SessionForkOptions;
pub const SessionForkSelection = shared.SessionForkSelection;
pub const Error = shared.Error;

pub const createSessionForkSelection = shared.createSessionForkSelection;
pub const readSessionEntriesForFork = shared.readSessionEntriesForFork;

const ArraySessionIndex = array_index.ArraySessionIndex;
const SessionTreeEntry = array_index.SessionTreeEntry;
const SessionHead = array_index.SessionHead;
const SessionStats = array_index.SessionStats;
const SessionEntryCursorOptions = array_index.SessionEntryCursorOptions;
const SessionBranchQuery = array_index.SessionBranchQuery;
const KeyedOperationQueue = keyed_queue.KeyedOperationQueue;

const InMemorySessionState = struct {
    metadata: SessionMetadata,
    entries: ArraySessionIndex,

    fn deinit(self: *InMemorySessionState, allocator: std.mem.Allocator) void {
        allocator.free(self.metadata.id);
        allocator.free(self.metadata.created_at);
        self.entries.deinit();
        allocator.destroy(self);
    }
};

/// SessionStorage handle returned by create/open/fork.
/// Projections are serialized via the backend's KeyedOperationQueue per session id.
pub const InMemorySessionStorage = struct {
    backend: *InMemorySessionBackend,
    /// Snapshot of metadata at open/create (id/created_at owned by backend state).
    metadata: SessionMetadata,

    pub fn readHead(self: *InMemorySessionStorage) Error!SessionHead {
        return self.backend.readHead(self.metadata.id);
    }

    pub fn readEntry(self: *InMemorySessionStorage, id: []const u8) Error!?SessionTreeEntry {
        return self.backend.readEntry(self.metadata.id, id);
    }

    pub fn readEntries(self: *InMemorySessionStorage, options: SessionEntryCursorOptions) Error![]const SessionTreeEntry {
        return self.backend.readEntries(self.metadata.id, options);
    }

    pub fn appendEntry(self: *InMemorySessionStorage, entry: SessionTreeEntry) Error!void {
        return self.backend.appendEntry(self.metadata.id, entry);
    }

    pub fn findEntriesOnBranch(
        self: *InMemorySessionStorage,
        allocator: std.mem.Allocator,
        query: SessionBranchQuery,
    ) Error![]SessionTreeEntry {
        return self.backend.findEntriesOnBranch(self.metadata.id, allocator, query);
    }

    pub fn readPathToRootOrCompaction(
        self: *InMemorySessionStorage,
        allocator: std.mem.Allocator,
        leaf_id: ?[]const u8,
    ) Error![]SessionTreeEntry {
        return self.backend.readPathToRootOrCompaction(self.metadata.id, allocator, leaf_id);
    }

    pub fn getLabel(self: *InMemorySessionStorage, id: []const u8) Error!?[]const u8 {
        return self.backend.getLabel(self.metadata.id, id);
    }

    pub fn getName(self: *InMemorySessionStorage) Error!?[]const u8 {
        return self.backend.getName(self.metadata.id);
    }

    pub fn getStats(self: *InMemorySessionStorage) Error!SessionStats {
        return self.backend.getStats(self.metadata.id);
    }
};

pub const InMemorySessionBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions: std.StringHashMapUnmanaged(*InMemorySessionState) = .empty,
    operations: KeyedOperationQueue,
    disposed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Error!InMemorySessionBackend {
        const operations = KeyedOperationQueue.init(allocator, io, .{}) catch |err| switch (err) {
            error.InvalidMaxConcurrentOperations => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{
            .allocator = allocator,
            .io = io,
            .operations = operations,
        };
    }

    pub fn deinit(self: *InMemorySessionBackend) void {
        self.dispose();
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.sessions.deinit(self.allocator);
        self.operations.deinit();
        self.* = undefined;
    }

    /// Mirrors `[Symbol.asyncDispose]`: mark disposed and drain the op queue.
    pub fn dispose(self: *InMemorySessionBackend) void {
        if (self.disposed) {
            self.operations.drain();
            return;
        }
        self.disposed = true;
        self.operations.drain();
    }

    pub fn create(self: *InMemorySessionBackend, options: SessionCreateOptions) Error!InMemorySessionStorage {
        try self.assertOpen();

        const id_owned = if (options.id) |id|
            self.allocator.dupe(u8, id) catch return error.OutOfMemory
        else
            try shared.createSessionId(self.allocator);
        errdefer self.allocator.free(id_owned);

        const created_at = try shared.createTimestamp(self.allocator);
        errdefer self.allocator.free(created_at);

        const CreateCtx = struct {
            backend: *InMemorySessionBackend,
            id_owned: []u8,
            created_at: []u8,
            storage: ?InMemorySessionStorage = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = ctx.backend.allocator.create(InMemorySessionState) catch return error.OutOfMemory;
                state.* = .{
                    .metadata = .{ .id = ctx.id_owned, .created_at = ctx.created_at },
                    .entries = ArraySessionIndex.init(ctx.backend.allocator),
                };
                // Ownership of id/created_at is always on `state` from here.
                ctx.id_owned = &.{};
                ctx.created_at = &.{};

                // Replace any prior session with the same id (TS Map.set overwrite).
                if (ctx.backend.sessions.fetchRemove(state.metadata.id)) |old| {
                    old.value.deinit(ctx.backend.allocator);
                }
                ctx.backend.sessions.put(ctx.backend.allocator, state.metadata.id, state) catch {
                    state.deinit(ctx.backend.allocator);
                    return error.OutOfMemory;
                };
                ctx.storage = .{
                    .backend = ctx.backend,
                    .metadata = state.metadata,
                };
            }
        };

        var ctx = CreateCtx{
            .backend = self,
            .id_owned = id_owned,
            .created_at = created_at,
        };
        // Key must remain valid for the enqueue call; queue dupes it.
        const key = id_owned;
        self.operations.enqueue(key, &ctx, CreateCtx.run) catch |err| {
            if (ctx.id_owned.len != 0) self.allocator.free(ctx.id_owned);
            if (ctx.created_at.len != 0) self.allocator.free(ctx.created_at);
            return mapQueueError(err);
        };
        return ctx.storage orelse return error.InvalidSession;
    }

    pub fn open(self: *InMemorySessionBackend, metadata: SessionMetadata) Error!InMemorySessionStorage {
        try self.assertOpen();

        const OpenCtx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            storage: ?InMemorySessionStorage = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = ctx.backend.getState(ctx.session_id) catch |e| return e;
                ctx.storage = .{
                    .backend = ctx.backend,
                    .metadata = state.metadata,
                };
            }
        };

        var ctx = OpenCtx{ .backend = self, .session_id = metadata.id };
        self.operations.enqueue(metadata.id, &ctx, OpenCtx.run) catch |err| return mapQueueError(err);
        return ctx.storage orelse return error.NotFound;
    }

    pub fn list(self: *InMemorySessionBackend, allocator: std.mem.Allocator) Error![]SessionMetadata {
        try self.assertOpen();

        const ListCtx = struct {
            backend: *InMemorySessionBackend,
            allocator: std.mem.Allocator,
            out: ?[]SessionMetadata = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                var list_buf: std.ArrayList(SessionMetadata) = .empty;
                errdefer list_buf.deinit(ctx.allocator);
                var it = ctx.backend.sessions.valueIterator();
                while (it.next()) |state_ptr| {
                    try list_buf.append(ctx.allocator, state_ptr.*.metadata);
                }
                ctx.out = try list_buf.toOwnedSlice(ctx.allocator);
            }
        };

        var ctx = ListCtx{ .backend = self, .allocator = allocator };
        self.operations.enqueueBarrier(&ctx, ListCtx.run) catch |err| return mapQueueError(err);
        return ctx.out orelse return error.OutOfMemory;
    }

    pub fn delete(self: *InMemorySessionBackend, metadata: SessionMetadata) Error!void {
        try self.assertOpen();

        const DeleteCtx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const kv = ctx.backend.sessions.fetchRemove(ctx.session_id) orelse return;
                kv.value.deinit(ctx.backend.allocator);
            }
        };

        var ctx = DeleteCtx{ .backend = self, .session_id = metadata.id };
        self.operations.enqueue(metadata.id, &ctx, DeleteCtx.run) catch |err| return mapQueueError(err);
    }

    pub fn fork(
        self: *InMemorySessionBackend,
        source: SessionMetadata,
        options: SessionCreateOptions,
        selection: SessionForkSelection,
    ) Error!InMemorySessionStorage {
        try self.assertOpen();

        // Read fork entries under the source key (serialized with source mutations).
        const ReadCtx = struct {
            backend: *InMemorySessionBackend,
            source_id: []const u8,
            selection: SessionForkSelection,
            entries: ?[]SessionTreeEntry = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.source_id);
                ctx.entries = try shared.readSessionEntriesForFork(
                    ctx.backend.allocator,
                    &state.entries,
                    ctx.selection,
                );
            }
        };

        var read_ctx = ReadCtx{
            .backend = self,
            .source_id = source.id,
            .selection = selection,
        };
        self.operations.enqueue(source.id, &read_ctx, ReadCtx.run) catch |err| return mapQueueError(err);
        const source_entries = read_ctx.entries orelse return error.InvalidSession;
        defer self.allocator.free(source_entries);

        const id_owned = if (options.id) |id|
            self.allocator.dupe(u8, id) catch return error.OutOfMemory
        else
            try shared.createSessionId(self.allocator);
        errdefer self.allocator.free(id_owned);

        const created_at = try shared.createTimestamp(self.allocator);
        errdefer self.allocator.free(created_at);

        const ForkCtx = struct {
            backend: *InMemorySessionBackend,
            id_owned: []u8,
            created_at: []u8,
            entries: []const SessionTreeEntry,
            storage: ?InMemorySessionStorage = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                var entries_idx = try ArraySessionIndex.initWithEntries(ctx.backend.allocator, ctx.entries);

                const state = ctx.backend.allocator.create(InMemorySessionState) catch {
                    entries_idx.deinit();
                    return error.OutOfMemory;
                };
                state.* = .{
                    .metadata = .{ .id = ctx.id_owned, .created_at = ctx.created_at },
                    .entries = entries_idx,
                };
                // Ownership of id/created_at is always on `state` from here.
                ctx.id_owned = &.{};
                ctx.created_at = &.{};

                if (ctx.backend.sessions.fetchRemove(state.metadata.id)) |old| {
                    old.value.deinit(ctx.backend.allocator);
                }
                ctx.backend.sessions.put(ctx.backend.allocator, state.metadata.id, state) catch {
                    state.deinit(ctx.backend.allocator);
                    return error.OutOfMemory;
                };
                ctx.storage = .{
                    .backend = ctx.backend,
                    .metadata = state.metadata,
                };
            }
        };

        var fork_ctx = ForkCtx{
            .backend = self,
            .id_owned = id_owned,
            .created_at = created_at,
            .entries = source_entries,
        };
        const key = id_owned;
        self.operations.enqueue(key, &fork_ctx, ForkCtx.run) catch |err| {
            if (fork_ctx.id_owned.len != 0) self.allocator.free(fork_ctx.id_owned);
            if (fork_ctx.created_at.len != 0) self.allocator.free(fork_ctx.created_at);
            return mapQueueError(err);
        };
        return fork_ctx.storage orelse return error.InvalidSession;
    }

    // --- SessionStorage projections (queued per session id) ---

    fn readHead(self: *InMemorySessionBackend, session_id: []const u8) Error!SessionHead {
        try self.assertOpen();
        const Ctx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            result: SessionHead = .{ .leaf_id = null },

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.session_id);
                ctx.result = try state.entries.readHead();
            }
        };
        var ctx = Ctx{ .backend = self, .session_id = session_id };
        self.operations.enqueue(session_id, &ctx, Ctx.run) catch |err| return mapQueueError(err);
        return ctx.result;
    }

    fn readEntry(self: *InMemorySessionBackend, session_id: []const u8, entry_id: []const u8) Error!?SessionTreeEntry {
        try self.assertOpen();
        const Ctx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            entry_id: []const u8,
            result: ?SessionTreeEntry = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.session_id);
                ctx.result = state.entries.readEntry(ctx.entry_id);
            }
        };
        var ctx = Ctx{ .backend = self, .session_id = session_id, .entry_id = entry_id };
        self.operations.enqueue(session_id, &ctx, Ctx.run) catch |err| return mapQueueError(err);
        return ctx.result;
    }

    fn readEntries(
        self: *InMemorySessionBackend,
        session_id: []const u8,
        options: SessionEntryCursorOptions,
    ) Error![]const SessionTreeEntry {
        try self.assertOpen();
        const Ctx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            options: SessionEntryCursorOptions,
            result: []const SessionTreeEntry = &.{},

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.session_id);
                ctx.result = state.entries.readEntries(ctx.options);
            }
        };
        var ctx = Ctx{ .backend = self, .session_id = session_id, .options = options };
        self.operations.enqueue(session_id, &ctx, Ctx.run) catch |err| return mapQueueError(err);
        return ctx.result;
    }

    fn appendEntry(self: *InMemorySessionBackend, session_id: []const u8, entry: SessionTreeEntry) Error!void {
        try self.assertOpen();
        const Ctx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            entry: SessionTreeEntry,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.session_id);
                try state.entries.append(ctx.entry);
            }
        };
        var ctx = Ctx{ .backend = self, .session_id = session_id, .entry = entry };
        self.operations.enqueue(session_id, &ctx, Ctx.run) catch |err| return mapQueueError(err);
    }

    fn findEntriesOnBranch(
        self: *InMemorySessionBackend,
        session_id: []const u8,
        allocator: std.mem.Allocator,
        query: SessionBranchQuery,
    ) Error![]SessionTreeEntry {
        try self.assertOpen();
        const Ctx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            allocator: std.mem.Allocator,
            query: SessionBranchQuery,
            result: ?[]SessionTreeEntry = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.session_id);
                ctx.result = try state.entries.findEntriesOnBranch(ctx.allocator, ctx.query);
            }
        };
        var ctx = Ctx{
            .backend = self,
            .session_id = session_id,
            .allocator = allocator,
            .query = query,
        };
        self.operations.enqueue(session_id, &ctx, Ctx.run) catch |err| return mapQueueError(err);
        return ctx.result orelse return error.OutOfMemory;
    }

    fn readPathToRootOrCompaction(
        self: *InMemorySessionBackend,
        session_id: []const u8,
        allocator: std.mem.Allocator,
        leaf_id: ?[]const u8,
    ) Error![]SessionTreeEntry {
        try self.assertOpen();
        const Ctx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            allocator: std.mem.Allocator,
            leaf_id: ?[]const u8,
            result: ?[]SessionTreeEntry = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.session_id);
                ctx.result = try state.entries.readPathToRootOrCompaction(ctx.allocator, ctx.leaf_id);
            }
        };
        var ctx = Ctx{
            .backend = self,
            .session_id = session_id,
            .allocator = allocator,
            .leaf_id = leaf_id,
        };
        self.operations.enqueue(session_id, &ctx, Ctx.run) catch |err| return mapQueueError(err);
        return ctx.result orelse return error.OutOfMemory;
    }

    fn getLabel(self: *InMemorySessionBackend, session_id: []const u8, id: []const u8) Error!?[]const u8 {
        try self.assertOpen();
        const Ctx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            id: []const u8,
            result: ?[]const u8 = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.session_id);
                ctx.result = state.entries.getLabel(ctx.id);
            }
        };
        var ctx = Ctx{ .backend = self, .session_id = session_id, .id = id };
        self.operations.enqueue(session_id, &ctx, Ctx.run) catch |err| return mapQueueError(err);
        return ctx.result;
    }

    fn getName(self: *InMemorySessionBackend, session_id: []const u8) Error!?[]const u8 {
        try self.assertOpen();
        const Ctx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            result: ?[]const u8 = null,

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.session_id);
                ctx.result = state.entries.getName();
            }
        };
        var ctx = Ctx{ .backend = self, .session_id = session_id };
        self.operations.enqueue(session_id, &ctx, Ctx.run) catch |err| return mapQueueError(err);
        return ctx.result;
    }

    fn getStats(self: *InMemorySessionBackend, session_id: []const u8) Error!SessionStats {
        try self.assertOpen();
        const Ctx = struct {
            backend: *InMemorySessionBackend,
            session_id: []const u8,
            result: SessionStats = .{},

            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const state = try ctx.backend.getState(ctx.session_id);
                ctx.result = state.entries.getStats();
            }
        };
        var ctx = Ctx{ .backend = self, .session_id = session_id };
        self.operations.enqueue(session_id, &ctx, Ctx.run) catch |err| return mapQueueError(err);
        return ctx.result;
    }

    fn assertOpen(self: *const InMemorySessionBackend) Error!void {
        if (self.disposed) return error.Disposed;
    }

    fn getState(self: *InMemorySessionBackend, session_id: []const u8) Error!*InMemorySessionState {
        return self.sessions.get(session_id) orelse return error.NotFound;
    }
};

fn mapQueueError(err: anyerror) Error {
    return switch (err) {
        error.NotFound => error.NotFound,
        error.InvalidSession => error.InvalidSession,
        error.InvalidEntry => error.InvalidEntry,
        error.InvalidForkTarget => error.InvalidForkTarget,
        error.Disposed => error.Disposed,
        error.InvalidBranchQueryLimit => error.InvalidBranchQueryLimit,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSession,
    };
}

// Backward-compatible stub name used by older imports.
pub const MemorySessionRepo = InMemorySessionBackend;

// ---------------------------------------------------------------------------
// Offline tests on shipped public APIs (backend + storage, appendEntry)
// ---------------------------------------------------------------------------

fn userMsg(id: []const u8, parent_id: ?[]const u8) SessionTreeEntry {
    return .{
        .type = .message,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .message_role = .user,
    };
}

fn asstMsg(id: []const u8, parent_id: ?[]const u8) SessionTreeEntry {
    return .{
        .type = .message,
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2026-01-01T00:00:00.000Z",
        .message_role = .assistant,
    };
}

fn expectIds(entries: []const SessionTreeEntry, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, entries.len);
    for (entries, expected) |e, id| {
        try std.testing.expectEqualStrings(id, e.id);
    }
}

// Pi: packages/agent/test/harness/repo.test.ts "opens, deletes, and forks by metadata"
test "InMemorySessionBackend opens deletes and forks by metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var backend = try InMemorySessionBackend.init(allocator, io);
    defer backend.deinit();

    var storage = try backend.create(.{ .id = "session-1" });
    try std.testing.expectEqualStrings("session-1", storage.metadata.id);

    try storage.appendEntry(userMsg("user1", null));
    try storage.appendEntry(asstMsg("asst1", "user1"));
    try storage.appendEntry(userMsg("user2", "asst1"));

    const reopened = try backend.open(storage.metadata);
    try std.testing.expectEqualStrings(storage.metadata.id, reopened.metadata.id);
    try std.testing.expectEqualStrings(storage.metadata.created_at, reopened.metadata.created_at);

    const listed = try backend.list(allocator);
    defer allocator.free(listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("session-1", listed[0].id);

    // fork before user2 → path excluding user2
    var forked = try backend.fork(
        storage.metadata,
        .{ .id = "session-2" },
        createSessionForkSelection(.{ .entry_id = "user2" }),
    );
    try expectIds(try forked.readEntries(.{}), &.{ "user1", "asst1" });

    // full-session fork selection
    var full_fork = try backend.fork(storage.metadata, .{ .id = "session-3" }, .all);
    try expectIds(try full_fork.readEntries(.{}), &.{ "user1", "asst1", "user2" });

    // through_entry (position: at)
    var through_fork = try backend.fork(
        storage.metadata,
        .{ .id = "session-4" },
        createSessionForkSelection(.{ .entry_id = "asst1", .position = .at }),
    );
    try expectIds(try through_fork.readEntries(.{}), &.{ "user1", "asst1" });

    // before assistant (not a user message) → invalid_fork_target
    try std.testing.expectError(
        error.InvalidForkTarget,
        backend.fork(
            storage.metadata,
            .{ .id = "session-5" },
            createSessionForkSelection(.{ .entry_id = "asst1" }),
        ),
    );
    try std.testing.expectError(
        error.InvalidForkTarget,
        backend.fork(
            storage.metadata,
            .{ .id = "session-6" },
            createSessionForkSelection(.{ .entry_id = "missing" }),
        ),
    );

    // Copy id before delete: backend frees session-owned metadata strings on delete.
    const deleted_id = try allocator.dupe(u8, storage.metadata.id);
    defer allocator.free(deleted_id);
    try backend.delete(storage.metadata);
    try std.testing.expectError(error.NotFound, backend.open(.{ .id = deleted_id, .created_at = "" }));
}

// Pi: packages/agent/test/harness/repo.test.ts "delegates full-session fork selection without opening the source"
test "InMemorySessionBackend full-session fork selection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var backend = try InMemorySessionBackend.init(allocator, io);
    defer backend.deinit();

    var source = try backend.create(.{ .id = "session-1" });
    try source.appendEntry(userMsg("user1", null));

    var forked = try backend.fork(source.metadata, .{ .id = "session-2" }, .all);
    const entries = try forked.readEntries(.{});
    try expectIds(entries, &.{"user1"});
    try std.testing.expectEqualStrings("session-2", forked.metadata.id);
}

// Pi: packages/agent/test/harness/repo.test.ts "rejects repository operations and session writes after disposal"
test "InMemorySessionBackend rejects ops after dispose" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var backend = try InMemorySessionBackend.init(allocator, io);
    defer backend.deinit();

    var storage = try backend.create(.{ .id = "session-1" });
    backend.dispose();

    try std.testing.expectError(error.Disposed, backend.list(allocator));
    try std.testing.expectError(error.Disposed, storage.appendEntry(userMsg("late", null)));
    try std.testing.expectError(error.Disposed, backend.create(.{ .id = "session-2" }));
}

// Pi: packages/agent/src/harness/session/memory-repo.ts "SessionStorage projections"
test "InMemorySessionStorage projections readHead labels name stats path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var backend = try InMemorySessionBackend.init(allocator, io);
    defer backend.deinit();

    var storage = try backend.create(.{ .id = "session-1" });
    try storage.appendEntry(userMsg("user1", null));
    try storage.appendEntry(asstMsg("asst1", "user1"));
    try storage.appendEntry(.{
        .type = .label,
        .id = "lab1",
        .parent_id = "asst1",
        .timestamp = "2026-01-01T00:00:00.000Z",
        .target_id = "user1",
        .label = "bookmark",
    });
    try storage.appendEntry(.{
        .type = .session_info,
        .id = "info1",
        .parent_id = "lab1",
        .timestamp = "2026-01-01T00:00:00.000Z",
        .name = "demo",
    });

    const head = try storage.readHead();
    try std.testing.expectEqualStrings("info1", head.leaf_id.?);

    try std.testing.expectEqualStrings("user1", (try storage.readEntry("user1")).?.id);
    try std.testing.expect((try storage.readEntry("missing")) == null);

    const label = try storage.getLabel("user1");
    try std.testing.expectEqualStrings("bookmark", label.?);
    try std.testing.expectEqualStrings("demo", (try storage.getName()).?);

    const stats = try storage.getStats();
    try std.testing.expectEqual(@as(f64, 2), stats.message_count);

    const path = try storage.readPathToRootOrCompaction(allocator, "asst1");
    defer allocator.free(path);
    try expectIds(path, &.{ "user1", "asst1" });

    const branch = try storage.findEntriesOnBranch(allocator, .{ .start = "asst1" });
    defer allocator.free(branch);
    try expectIds(branch, &.{ "asst1", "user1" });
}
